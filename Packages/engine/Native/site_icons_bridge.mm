#include "chrome/browser/arx/site_icons_bridge.h"

#include <algorithm>
#include <atomic>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/check.h"
#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/task/cancelable_task_tracker.h"
#include "base/task/single_thread_task_runner.h"
#include "base/timer/timer.h"
#include "chrome/browser/arx/site_icon_links.h"
#include "chrome/browser/favicon/favicon_service_factory.h"
#include "chrome/browser/history/history_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/favicon/core/favicon_driver_observer.h"
#include "components/favicon/core/favicon_service.h"
#include "components/favicon_base/favicon_types.h"
#include "components/history/core/browser/history_backend.h"
#include "components/history/core/browser/history_db_task.h"
#include "components/history/core/browser/history_service.h"
#include "components/keyed_service/core/service_access_type.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "net/base/data_url.h"
#include "net/base/isolation_info.h"
#include "net/base/load_flags.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "net/http/http_request_headers.h"
#include "net/cookies/site_for_cookies.h"
#include "net/http/http_response_headers.h"
#include "net/url_request/redirect_info.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/data_decoder/public/cpp/data_decoder.h"
#include "services/data_decoder/public/cpp/decode_image.h"
#include "services/network/public/cpp/ip_address_space_util.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/mojom/client_security_state.mojom.h"
#include "services/network/public/mojom/ip_address_space.mojom.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/cpp/simple_url_loader_stream_consumer.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "skia/ext/image_operations.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_rep.h"
#include "url/gurl.h"
#include "url/origin.h"
#include "url/url_constants.h"

namespace arx {
namespace {
constexpr size_t kMaximumRequests = 16;
constexpr size_t kMaximumBytes = 64 * 1024;
constexpr int kIconPixels = 32;
// A miss fetches the page head and up to kMaximumCandidates icons in sequence.
constexpr base::TimeDelta kRequestTimeout = base::Seconds(15);
constexpr base::TimeDelta kFetchTimeout = base::Seconds(6);
constexpr size_t kMaximumIconDownloadBytes = 256 * 1024;
constexpr uint64_t kMaximumDecodedBytes = 16 * 1024 * 1024;
// ABI51 (DEV-940): a redirect chain sends at most its last 8 addresses.
constexpr size_t kMaximumRedirectURLs = 8;
constexpr size_t kMaximumURLBytes = 8192;

// The page is fetched with the profile's cookies for its own site, as loading it
// would (DEV-1108), but sets none, and is read as text, never rendered. Icons
// are fetched without cookies.
constexpr net::NetworkTrafficAnnotationTag kTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("arx_site_icon_fetch", R"(
      semantics {
        sender: "Arx site icons"
        description:
          "Fetches the icon of a page the user saved as a Favorite, pinned or "
          "saved tab when the profile has no icon for it yet, because the "
          "page has not loaded in this profile. Arx reads the head of the "
          "app's directory or the site's root page (never the saved page) for "
          "declared icons, falling back to /favicon.ico, from the site itself."
        trigger:
          "The sidebar or another Arx surface shows a saved page whose icon "
          "is missing from the profile's favicon database."
        data:
          "The site's root or app directory, with the profile's cookies for "
          "that site, as loading it would send; cookies it sets are not "
          "saved. Icon URLs, without cookies."
        destination: WEBSITE
        internal { contacts { email: "arx@capturecontext.dev" } }
        user_data { type: NONE }
        last_reviewed: "2026-11-16"
      }
      policy {
        cookies_allowed: YES
        cookies_store: "user"
        setting: "Remove the Favorite or pinned tab."
        policy_exception_justification: "Not implemented."
      })");

// The bitmap fitted inside `limit` pixels, never upscaled.
SkBitmap Fit(const SkBitmap& source, int limit) {
  const auto [width, height] = site_icons::FitIcon(source.width(), source.height(), limit);
  if (width == source.width() && height == source.height()) return source;
  return skia::ImageOperations::Resize(source, skia::ImageOperations::RESIZE_BEST,
                                       width, height);
}

// The site's root page, never the saved page itself: a saved URL may be a
// one-time link (a sign-in token, an unsubscribe or a confirmation) that a GET
// consumes. Credentials, path, query and fragment never leave.
GURL RootURL(const GURL& url) {
  GURL::Replacements replacements;
  replacements.ClearUsername();
  replacements.ClearPassword();
  return url.ReplaceComponents(replacements).GetWithEmptyPath();
}

// Icons a lookup fetches are stored with this fragment on their icon URL, so a
// later lookup tells them from ones fetched before DEV-1108, which may be the
// icon of the page a site's root redirected to (a sign-in page's) and are
// fetched again. The fragment never reaches the network: FetchURL drops it.
constexpr char kFetchedMarker[] = "arx-site-icon-2";

GURL Marked(const GURL& icon_url) {
  GURL::Replacements replacements;
  replacements.SetRefStr(kFetchedMarker);
  const GURL marked = icon_url.ReplaceComponents(replacements);
  return marked.is_valid() ? marked : icon_url;
}

bool IsMarked(const GURL& icon_url) {
  return icon_url.has_ref() && icon_url.ref() == kFetchedMarker;
}

history::HistoryService* History(Profile* profile) {
  return profile ? HistoryServiceFactory::GetForProfile(profile, ServiceAccessType::IMPLICIT_ACCESS)
                 : nullptr;
}

// Forgets a page's mapping to an icon fetched before DEV-1108, on the history
// backend's sequence: the comparison and the deletion run together, so a page
// load's own icon write lands wholly before (and wins) or after them.
class ForgetLegacyIcon final : public history::HistoryDBTask {
 public:
  using Done = base::OnceCallback<void(bool forgotten, favicon_base::FaviconRawBitmapResult current)>;

  ForgetLegacyIcon(GURL page_url, GURL legacy, Done done)
      : page_url_(std::move(page_url)), legacy_(std::move(legacy)), done_(std::move(done)) {}

  bool RunOnDBThread(history::HistoryBackend* backend, history::HistoryDatabase*) override {
    const auto results = backend->GetFaviconsForURL(
        page_url_, {favicon_base::IconType::kFavicon}, {kIconPixels}, /*fallback_to_host=*/false);
    const auto current = std::find_if(results.begin(), results.end(),
                                       [](const auto& result) { return result.is_valid(); });
    if (current != results.end() &&
        (current->fetched_because_of_page_visit || current->icon_url != legacy_)) {
      current_ = *current;
      return true;
    }
    if (current != results.end())
      backend->DeleteFaviconMappings({page_url_}, favicon_base::IconType::kFavicon);
    forgotten_ = true;
    return true;
  }

  void DoneRunOnMainThread() override { std::move(done_).Run(forgotten_, current_); }

 private:
  const GURL page_url_;
  const GURL legacy_;
  Done done_;
  bool forgotten_ = false;
  favicon_base::FaviconRawBitmapResult current_;
};

GURL FetchURL(const GURL& url) {
  GURL::Replacements replacements;
  replacements.ClearUsername();
  replacements.ClearPassword();
  replacements.ClearRef();
  return url.ReplaceComponents(replacements);
}

// `client_space` is the address space of the page that declared the resource.
// Known, the request carries it with Local Network Access blocking, as
// Chromium's own browser-process fetchers do: a public page can't make Arx
// reach localhost or the intranet, redirects included.
//
// `credentialed` (DEV-1108) sends the profile's cookies for the page's own site,
// as one of its own pages' same-site requests would: a signed-in app answers
// with its own page and icon instead of a sign-in page's. The first party stays
// the saved site, so another site's SameSite cookies never go along, and a
// redirect to another site isn't followed (`Request::Redirected`). Cookies the
// response sets are never saved. Icons are fetched without cookies.
std::unique_ptr<network::SimpleURLLoader> Loader(
    const GURL& url, const char* accept,
    network::mojom::IPAddressSpace client_space = network::mojom::IPAddressSpace::kUnknown,
    bool credentialed = false) {
  auto request = std::make_unique<network::ResourceRequest>();
  request->url = url;
  request->method = net::HttpRequestHeaders::kGetMethod;
  request->credentials_mode = credentialed ? network::mojom::CredentialsMode::kInclude
                                           : network::mojom::CredentialsMode::kOmit;
  request->load_flags = net::LOAD_DO_NOT_SAVE_COOKIES;
  request->headers.SetHeader(net::HttpRequestHeaders::kAccept, accept);
  if (client_space != network::mojom::IPAddressSpace::kUnknown || credentialed)
    request->trusted_params = network::ResourceRequest::TrustedParams();
  if (credentialed) {
    const url::Origin origin = url::Origin::Create(url);
    request->site_for_cookies = net::SiteForCookies::FromOrigin(origin);
    request->request_initiator = origin;
    request->trusted_params->isolation_info = net::IsolationInfo::Create(
        net::IsolationInfo::RequestType::kOther, origin, origin,
        net::SiteForCookies::FromOrigin(origin));
  }
  if (client_space != network::mojom::IPAddressSpace::kUnknown) {
    auto security = network::mojom::ClientSecurityState::New();
    security->ip_address_space = client_space;
    security->is_web_secure_context = true;
    security->local_network_access_request_policy =
        network::mojom::LocalNetworkAccessRequestPolicy::kBlock;
    request->trusted_params->client_security_state = std::move(security);
  }
  auto loader = network::SimpleURLLoader::Create(std::move(request), kTrafficAnnotation);
  loader->SetTimeoutDuration(kFetchTimeout);
  return loader;
}

bool Succeeded(const network::SimpleURLLoader& loader) {
  const auto* info = loader.ResponseInfo();
  if (!info || !info->headers) return false;
  const int code = info->headers->response_code();
  return code >= 200 && code < 300;
}

// A favicon URL Swift may compare, or empty: unknown, invalid or too long (an
// inline data: icon can be large).
std::string IconSpec(const GURL& icon_url) {
  if (!icon_url.is_valid() || icon_url.spec().size() > kMaximumURLBytes) return std::string();
  return icon_url.spec();
}

void Reply(SiteIconCompleted completed, uint64_t request, ArxSiteIconStatus status,
           std::vector<uint8_t> png = {}, uint32_t width = 0, uint32_t height = 0,
           const GURL& icon_url = GURL()) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
      base::BindOnce([](SiteIconCompleted completed, uint64_t request,
                        ArxSiteIconStatus status, std::vector<uint8_t> png,
                        uint32_t width, uint32_t height, std::string icon_url) {
        completed(request, status, png.data(), png.size(), width, height,
                  icon_url.c_str());
      }, completed, request, status, std::move(png), width, height, IconSpec(icon_url)));
}

class Request;
std::map<uint64_t, std::unique_ptr<Request>>& Requests() {
  static base::NoDestructor<std::map<uint64_t, std::unique_ptr<Request>>> requests;
  return *requests;
}

class Request final : public ProfileObserver,
                      public network::SimpleURLLoaderStreamConsumer {
 public:
  Request(Profile* profile, uint64_t id, SiteIconCompleted completed)
      : id_(id), completed_(completed) {
    profile_.Observe(profile);
  }

  void Start(favicon::FaviconService* service, const GURL& page_url, bool may_fetch) {
    service_ = service;
    page_url_ = page_url;
    may_fetch_ = may_fetch;
    timer_.Start(FROM_HERE, kRequestTimeout, base::BindOnce(
        &Request::Unresolved, weak_.GetWeakPtr(), ARX_SITE_ICON_TIMEOUT));
    // Exact page only: another page on the host may be another app's icon.
    service->GetRawFaviconForPageURL(
        page_url, {favicon_base::IconType::kFavicon}, kIconPixels,
        /*fallback_to_host=*/false,
        base::BindOnce(&Request::Received, weak_.GetWeakPtr()), &tracker_);
  }

  void OnProfileWillBeDestroyed(Profile*) override {
    Finish(ARX_SITE_ICON_UNAVAILABLE, {}, 0, 0);
  }

  // The page head, streamed only until its icons are known.
  void OnDataReceived(std::string_view data, base::OnceClosure resume) override {
    if (!SiteIconFetchEnabled()) {
      // Finishing resets the loader, which stops the body; allowed in its callback.
      Unresolved(ARX_SITE_ICON_MISSING);
      return;
    }
    const size_t room = site_icons::kMaximumHeadBytes - head_.size();
    head_.append(data.substr(0, std::min(room, data.size())));
    if (!Succeeded(*loader_)) {
      FetchIcons(/*declared=*/false);
      return;
    }
    if (head_.size() >= site_icons::kMaximumHeadBytes ||
        site_icons::ParseIconLinks(head_).complete) {
      FetchIcons(/*declared=*/true);
      return;
    }
    std::move(resume).Run();
  }

  void OnComplete(bool success) override {
    FetchIcons(/*declared=*/Succeeded(*loader_));
  }

  void OnRetry(base::OnceClosure start_retry) override {}

  // Settings turned fetching off: a lookup past the database read stops now.
  void StopFetching() {
    if (loader_ || decoder_) Unresolved(ARX_SITE_ICON_MISSING);
  }

 private:
  void Received(const favicon_base::FaviconRawBitmapResult& result) {
    // An icon fetched before DEV-1108 may be another host's: the page the
    // site's root redirected to. A lookup that may fetch fetches the site's own
    // and replaces the old one once that has an answer (`legacy_`); a
    // database-only read reports a miss, so a row that shows the page later
    // reads with fetching. Icons a page load stored are never touched.
    if (result.is_valid() && !result.fetched_because_of_page_visit &&
        !IsMarked(result.icon_url)) {
      if (!may_fetch_) {
        Finish(ARX_SITE_ICON_MISSING, {}, 0, 0);
        return;
      }
      if (SiteIconFetchEnabled()) {
        legacy_ = result;
        FetchPage();
        return;
      }
    }
    if (!result.is_valid()) {
      if (may_fetch_ && SiteIconFetchEnabled()) {
        FetchPage();
      } else {
        Finish(ARX_SITE_ICON_MISSING, {}, 0, 0);
      }
      return;
    }
    Answer(result);
  }

  // Answers with an icon from the profile's database.
  void Answer(const favicon_base::FaviconRawBitmapResult& result) {
    const auto size = result.pixel_size;
    if (result.bitmap_data->size() > kMaximumBytes || size.IsEmpty() ||
        size.width() > kIconPixels || size.height() > kIconPixels) {
      Finish(ARX_SITE_ICON_LIMIT, {}, 0, 0);
      return;
    }
    // Postpones eviction of a fetched (on-demand) icon still in use; a no-op
    // for icons a page load stored.
    if (result.expired && result.icon_url.is_valid())
      service_->TouchOnDemandFavicon(result.icon_url);
    const auto* bytes = result.bitmap_data->front();
    Finish(ARX_SITE_ICON_SUCCESS,
           std::vector<uint8_t>(bytes, bytes + result.bitmap_data->size()),
           size.width(), size.height(), result.icon_url);
  }

  // A miss: read the icons the site's root page declares, as a page load
  // would, through this profile's own network context and nobody else's.
  void FetchPage() {
    Profile* profile = profile_.GetSource();
    if (!profile || profile->IsOffTheRecord() || !SiteIconFetchEnabled()) {
      Unresolved(ARX_SITE_ICON_MISSING);
      return;
    }
    auto* partition = profile->GetDefaultStoragePartition();
    factory_ = partition->GetURLLoaderFactoryForBrowserProcess();
    // A literal address or localhost is its own space; any other host counts as
    // public. The network service checks that against the address it actually
    // connects to (through a proxy too, with no lookup of our own), so neither
    // the root page, its redirects nor a declared icon can make a public site
    // reach localhost or the intranet. An intranet Favorite therefore gets its
    // icon only when it loads.
    root_space_ = network::GetAddressSpaceFromUrl(RootURL(page_url_))
                      .value_or(network::mojom::IPAddressSpace::kPublic);
    // The app's own directory first, on a host with several apps, then the
    // site's root (DEV-1108).
    pages_.clear();
    next_page_ = 0;
    const std::string directory = site_icons::AppDirectory(page_url_.path());
    if (!directory.empty()) pages_.push_back(RootURL(page_url_).Resolve(directory));
    pages_.push_back(RootURL(page_url_));
    FetchNextPage();
  }

  // Streams the next page's head with the profile's cookies (DEV-1108).
  void FetchNextPage() {
    head_.clear();
    loader_ = Loader(pages_[next_page_++], "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
                     root_space_, /*credentialed=*/true);
    loader_->SetOnRedirectCallback(
        base::BindRepeating(&Request::Redirected, weak_.GetWeakPtr()));
    loader_->DownloadAsStream(factory_.get(), this);
  }

  // A page request carries the profile's cookies, so it never follows a
  // redirect to another site: that site's page couldn't speak for the saved
  // one anyway, and a saved site mustn't steer an authenticated request
  // elsewhere. The page gives way to the next one (DEV-1108).
  void Redirected(const GURL&, const net::RedirectInfo& redirect,
                  const network::mojom::URLResponseHead&, std::vector<std::string>*) {
    if (net::registry_controlled_domains::SameDomainOrHost(
            page_url_, redirect.new_url,
            net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES))
      return;
    // Deleting the loader inside its callback is allowed; it stops the request.
    loader_.reset();
    head_.clear();
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&Request::FetchNextIcon, weak_.GetWeakPtr()));
  }

  void FetchIcons(bool declared) {
    // Icons are fetched from the page's address space, or the site's when the
    // page didn't answer.
    page_space_ = root_space_;
    // No response at all (offline, a name that doesn't resolve) says nothing
    // about the site's icons.
    if (loader_ && (!loader_->ResponseInfo() || !loader_->ResponseInfo()->headers))
      transport_failed_ = true;
    if (loader_ && loader_->ResponseInfo() &&
        loader_->ResponseInfo()->response_address_space != network::mojom::IPAddressSpace::kUnknown)
      page_space_ = loader_->ResponseInfo()->response_address_space;
    GURL page = loader_ ? loader_->GetFinalURL() : GURL();
    if (!page.is_valid()) page = page_url_;
    // Deleting the loader inside its callback is allowed; it stops the body.
    loader_.reset();
    // A root that redirected to another host (Google's apps send a visitor
    // without cookies to the sign-in page) shows that host's icons, not the
    // site's: only the site's own /favicon.ico is tried then (DEV-1108).
    const bool speaks = site_icons::SpeaksForHost(page_url_.host(), page.host());
    if (speaks && page.SchemeIsHTTPOrHTTPS()) speaking_roots_.push_back(RootURL(page));
    if (declared && speaks) {
      const auto links = site_icons::ParseIconLinks(head_);
      GURL base = page;
      if (links.base) {
        const GURL declared_base = page.Resolve(*links.base);
        if (declared_base.SchemeIsHTTPOrHTTPS()) base = declared_base;
      }
      for (const auto& link : site_icons::RankIconLinks(links.icons)) {
        const GURL icon = base.Resolve(link.href);
        if ((icon.SchemeIsHTTPOrHTTPS() || icon.SchemeIs(url::kDataScheme)) &&
            icon.spec().size() <= 8192)
          Candidate(icon);
      }
    }
    head_.clear();
    head_.shrink_to_fit();
    FetchNextIcon();
  }

  void Candidate(const GURL& url) {
    if (!url.is_valid()) return;
    for (const auto& known : candidates_)
      if (known == url) return;
    candidates_.push_back(url);
  }

  void FetchNextIcon() {
    // Settings may have turned fetching off since this lookup started.
    if (!SiteIconFetchEnabled()) {
      Unresolved(ARX_SITE_ICON_MISSING);
      return;
    }
    if (next_candidate_ >= candidates_.size()) {
      // This page's icons are used up: the next page's, then /favicon.ico of
      // each page that answered for the site, then the saved site's own.
      if (next_page_ < pages_.size()) {
        FetchNextPage();
        return;
      }
      if (!fallbacks_added_) {
        fallbacks_added_ = true;
        for (const auto& root : speaking_roots_) Candidate(root.Resolve("/favicon.ico"));
        Candidate(RootURL(page_url_).Resolve("/favicon.ico"));
      }
      if (next_candidate_ >= candidates_.size()) {
        Exhausted();
        return;
      }
    }
    icon_url_ = candidates_[next_candidate_++];
    if (icon_url_.SchemeIs(url::kDataScheme)) {
      std::string mime, charset, data;
      if (!net::DataURL::Parse(icon_url_, &mime, &charset, &data) ||
          data.empty() || data.size() > kMaximumIconDownloadBytes) {
        FetchNextIcon();
        return;
      }
      // Like a page load, the database keys an inline icon by its data: URL.
      Decode(std::move(data));
      return;
    }
    loader_ = Loader(FetchURL(icon_url_), "image/avif,image/webp,image/png,image/*;q=0.8,*/*;q=0.5",
                     page_space_);
    loader_->DownloadToString(factory_.get(),
        base::BindOnce(&Request::ReceivedIcon, weak_.GetWeakPtr()),
        kMaximumIconDownloadBytes);
  }

  void ReceivedIcon(std::optional<std::string> body) {
    if (!SiteIconFetchEnabled()) {
      Unresolved(ARX_SITE_ICON_MISSING);
      return;
    }
    const bool succeeded = loader_ && Succeeded(*loader_);
    if (loader_ && (!loader_->ResponseInfo() || !loader_->ResponseInfo()->headers))
      transport_failed_ = true;
    loader_.reset();
    if (!succeeded || !body || body->empty()) {
      FetchNextIcon();
      return;
    }
    Decode(std::move(*body));
  }

  // Images are decoded out of process, in the sandboxed data decoder.
  void Decode(std::string bytes) {
    if (!decoder_) decoder_ = std::make_unique<data_decoder::DataDecoder>();
    data_decoder::DecodeImage(decoder_.get(), base::as_byte_span(bytes),
        data_decoder::mojom::ImageCodec::kDefault, /*shrink_to_fit=*/false,
        kMaximumDecodedBytes, gfx::Size(kIconPixels, kIconPixels),
        base::BindOnce(&Request::Decoded, weak_.GetWeakPtr()));
  }

  void Decoded(const SkBitmap& bitmap) {
    if (!SiteIconFetchEnabled()) {
      Unresolved(ARX_SITE_ICON_MISSING);
      return;
    }
    if (bitmap.drawsNothing() || bitmap.width() <= 0 || bitmap.height() <= 0) {
      FetchNextIcon();
      return;
    }
    SkBitmap large = Fit(bitmap, kIconPixels);
    SkBitmap small = Fit(bitmap, kIconPixels / 2);
    auto png = gfx::PNGCodec::EncodeBGRASkBitmap(large, /*discard_transparency=*/false);
    if (large.drawsNothing() || small.drawsNothing() || !png || png->empty() ||
        png->size() > kMaximumBytes) {
      FetchNextIcon();
      return;
    }
    gfx::ImageSkia image(gfx::ImageSkiaRep(small, 1.0f));
    // A 2x representation only when it is exactly twice the 1x one; otherwise
    // the favicon service scales the 1x one itself.
    if (large.width() == small.width() * 2 && large.height() == small.height() * 2)
      image.AddRepresentation(gfx::ImageSkiaRep(large, 2.0f));
    const uint32_t width = large.width();
    const uint32_t height = large.height();
    // On-demand icons are stored expired: the page's own icon replaces them on
    // its first load, and unused ones are evicted. They never overwrite one.
    pending_image_ = gfx::Image(image);
    pending_png_ = std::move(*png);
    pending_width_ = width;
    pending_height_ = height;
    // The old icon goes first: a stored one blocks an on-demand write.
    if (legacy_) {
      Revalidate(After::kStore);
      return;
    }
    Store();
  }

  void Store() {
    icon_url_ = Marked(icon_url_);
    service_->SetOnDemandFavicons(page_url_, icon_url_, favicon_base::IconType::kFavicon,
        std::move(pending_image_),
        base::BindOnce(&Request::Stored, weak_.GetWeakPtr(), std::move(pending_png_),
                       pending_width_, pending_height_));
  }

  void Stored(std::vector<uint8_t> png, uint32_t width, uint32_t height, bool) {
    Finish(ARX_SITE_ICON_SUCCESS, std::move(png), width, height, icon_url_);
  }

  // Ends without an answer of the lookup's own: an icon fetched before DEV-1108
  // stays, as does what it shows, and a later lookup tries again.
  void Unresolved(ArxSiteIconStatus status) {
    if (!legacy_) {
      Finish(status, {}, 0, 0);
      return;
    }
    const favicon_base::FaviconRawBitmapResult legacy = std::move(*legacy_);
    legacy_.reset();
    Answer(legacy);
  }

  // Every candidate failed. When the site answered, it has no icon to give:
  // an icon fetched before DEV-1108 goes, and the miss names it, so the app
  // forgets its own copy too. When a request got no response at all, nothing
  // was learned and the old icon stays.
  void Exhausted() {
    if (!legacy_) {
      Finish(ARX_SITE_ICON_MISSING, {}, 0, 0);
    } else if (transport_failed_) {
      Unresolved(ARX_SITE_ICON_MISSING);
    } else {
      Revalidate(After::kMiss);
    }
  }

  enum class After { kStore, kMiss };

  // Forgets the icon fetched before DEV-1108 unless a page load stored the
  // page's own meanwhile, which wins (`ForgetLegacyIcon`).
  void Revalidate(After after) {
    const GURL legacy = legacy_->icon_url;
    legacy_.reset();
    auto* history = History(profile_.GetSource());
    if (!history) {
      Revalidated(after, legacy, /*forgotten=*/false, {});
      return;
    }
    history->ScheduleDBTask(
        FROM_HERE,
        std::make_unique<ForgetLegacyIcon>(page_url_, legacy,
            base::BindOnce(&Request::Revalidated, weak_.GetWeakPtr(), after, legacy)),
        &tracker_);
  }

  void Revalidated(After after, const GURL& legacy, bool forgotten,
                   favicon_base::FaviconRawBitmapResult current) {
    if (current.is_valid()) {
      Answer(current);
      return;
    }
    if (after == After::kStore) {
      // Runs on the history backend after the deletion, and stores nothing
      // over an icon a page load stored since.
      Store();
    } else {
      Finish(ARX_SITE_ICON_MISSING, {}, 0, 0, forgotten ? legacy : GURL());
    }
  }

  void Finish(ArxSiteIconStatus status, std::vector<uint8_t> png,
              uint32_t width, uint32_t height, const GURL& icon_url = GURL()) {
    // Detach before publishing; a completion can reenter cancellation/shutdown.
    auto owned = Requests().extract(id_);
    if (owned.empty()) return;
    timer_.Stop();
    tracker_.TryCancelAll();
    loader_.reset();
    decoder_.reset();
    weak_.InvalidateWeakPtrs();
    profile_.Reset();
    Reply(completed_, id_, status, std::move(png), width, height, icon_url);
  }

  const uint64_t id_;
  const SiteIconCompleted completed_;
  raw_ptr<favicon::FaviconService> service_ = nullptr;
  GURL page_url_;
  bool may_fetch_ = false;
  network::mojom::IPAddressSpace root_space_ = network::mojom::IPAddressSpace::kUnknown;
  network::mojom::IPAddressSpace page_space_ = network::mojom::IPAddressSpace::kUnknown;
  GURL icon_url_;
  // The database's icon fetched before DEV-1108, replaced once the refetch has
  // an answer.
  std::optional<favicon_base::FaviconRawBitmapResult> legacy_;
  // The pages whose heads may declare the icon, in order, and the roots of
  // those that answered for the site (DEV-1108).
  std::vector<GURL> pages_;
  size_t next_page_ = 0;
  std::vector<GURL> speaking_roots_;
  bool fallbacks_added_ = false;
  // A page or icon request got no response at all.
  bool transport_failed_ = false;
  // The decoded icon, kept while the old mapping is read again.
  gfx::Image pending_image_;
  std::vector<uint8_t> pending_png_;
  uint32_t pending_width_ = 0;
  uint32_t pending_height_ = 0;
  std::string head_;
  std::vector<GURL> candidates_;
  size_t next_candidate_ = 0;
  scoped_refptr<network::SharedURLLoaderFactory> factory_;
  std::unique_ptr<network::SimpleURLLoader> loader_;
  std::unique_ptr<data_decoder::DataDecoder> decoder_;
  base::CancelableTaskTracker tracker_;
  base::OneShotTimer timer_;
  base::ScopedObservation<Profile, ProfileObserver> profile_{this};
  base::WeakPtrFactory<Request> weak_{this};
};

class Observation final : public SiteIconObservation,
                          public content::WebContentsObserver,
                          public favicon::FaviconDriverObserver {
 public:
  Observation(uint64_t page, content::WebContents* contents, SiteIconChanged changed,
              SiteIconRedirected redirected)
      : content::WebContentsObserver(contents), page_(page), changed_(changed),
        redirected_(redirected) {
    auto* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
    // Unlike Chrome's convenience helper, never redirect an OTR profile to its
    // parent. These icons are exclusively for persistent ordinary Favorites.
    favicon::ContentFaviconDriver::CreateForWebContents(contents,
        FaviconServiceFactory::GetForProfile(profile, ServiceAccessType::IMPLICIT_ACCESS));
    driver_.Observe(favicon::ContentFaviconDriver::FromWebContents(contents));
  }

  void OnFaviconUpdated(favicon::FaviconDriver* driver,
                        NotificationIconType type, const GURL& icon_url, bool,
                        const gfx::Image&) override {
    if (type != NON_TOUCH_16_DIP || !web_contents()) return;
    const GURL url = driver->GetActiveURL();
    auto* frame = web_contents()->GetPrimaryMainFrame();
    if (!url.SchemeIsHTTPOrHTTPS() || url.spec().size() > kMaximumURLBytes || !frame) return;
    pending_url_ = url;
    pending_icon_url_ = icon_url;
    icon_reported_ = true;
    pending_document_ = frame->GetWeakDocumentPtr();
    if (notification_posted_) return;
    notification_posted_ = true;
    // The normal driver enqueues the profile database update before notifying
    // observers. Swift may now issue a DB-only lookup on that same backend.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&Observation::Changed, weak_.GetWeakPtr()));
  }

 private:
  void Changed() {
    notification_posted_ = false;
    const auto document = pending_document_;
    const auto url = pending_url_;
    if (!web_contents() || !document.AsRenderFrameHostIfValid() ||
        document.AsRenderFrameHostIfValid() != web_contents()->GetPrimaryMainFrame() ||
        driver_.GetSource()->GetActiveURL() != url) return;
    changed_(page_, url.spec().c_str(), IconSpec(pending_icon_url_).c_str());
  }

 public:
  // ABI51 (DEV-940). A server redirect's middle addresses may never reach a page
  // snapshot, yet the favicon database maps the page's icon to them too.
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (!navigation->IsInPrimaryMainFrame() || !navigation->HasCommitted()) return;
    if (navigation->IsSameDocument()) {
      // Until the page's icon is known, Chromium maps it to same-document
      // addresses too (pushState, replaceState), which snapshots may coalesce.
      const GURL& url = navigation->GetURL();
      if (icon_reported_ || !url.SchemeIsHTTPOrHTTPS() || url.spec().size() > kMaximumURLBytes)
        return;
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
          base::BindOnce(&Observation::Redirected, weak_.GetWeakPtr(),
                         std::vector<std::string>{url.spec()}, /*truncated=*/false));
      return;
    }
    icon_reported_ = false;
    const std::vector<GURL>& chain = navigation->GetRedirectChain();
    if (chain.size() < 2) return;
    const size_t first =
        chain.size() > kMaximumRedirectURLs ? chain.size() - kMaximumRedirectURLs : 0;
    std::vector<std::string> urls;
    bool truncated = first > 0;
    for (size_t index = first; index < chain.size(); ++index) {
      const GURL& url = chain[index];
      if (url.SchemeIsHTTPOrHTTPS() && url.spec().size() <= kMaximumURLBytes) {
        urls.push_back(url.spec());
      } else if (url.SchemeIsHTTPOrHTTPS()) {
        truncated = true;
      }
    }
    if (urls.size() < 2 && !truncated) return;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&Observation::Redirected, weak_.GetWeakPtr(), std::move(urls),
                       truncated));
  }

 private:
  void Redirected(std::vector<std::string> urls, bool truncated) {
    if (!web_contents()) return;
    std::vector<const char*> pointers;
    pointers.reserve(urls.size());
    for (const auto& url : urls) pointers.push_back(url.c_str());
    redirected_(page_, pointers.data(), pointers.size(), truncated);
  }

  const uint64_t page_;
  const SiteIconChanged changed_;
  const SiteIconRedirected redirected_;
  bool notification_posted_ = false;
  // Whether the driver reported an icon since the last cross-document commit.
  bool icon_reported_ = false;
  GURL pending_url_;
  GURL pending_icon_url_;
  content::WeakDocumentPtr pending_document_;
  base::ScopedObservation<favicon::FaviconDriver, favicon::FaviconDriverObserver> driver_{this};
  base::WeakPtrFactory<Observation> weak_{this};
};
std::atomic<bool>& FetchEnabled() {
  static std::atomic<bool> enabled{true};
  return enabled;
}

}  // namespace

std::unique_ptr<SiteIconObservation> ObserveSiteIcons(
    uint64_t page, content::WebContents* contents, SiteIconChanged changed,
    SiteIconRedirected redirected) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!contents || contents->GetBrowserContext()->IsOffTheRecord()) return nullptr;
  return std::make_unique<Observation>(page, contents, changed, redirected);
}

void SetSiteIconFetchEnabled(bool enabled) { FetchEnabled().store(enabled); }

bool SiteIconFetchEnabled() { return FetchEnabled().load(); }

void LookupSiteIcon(Profile* profile, const GURL& page_url, bool may_fetch,
                    uint64_t request, SiteIconCompleted completed) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  // A duplicate cannot publish a result using the original request's identity.
  // Swift allocates monotonically increasing IDs for the runtime lifetime.
  if (Requests().contains(request)) return;
  if (!request || !page_url.SchemeIsHTTPOrHTTPS() ||
      page_url.spec().size() > 8192) {
    Reply(completed, request, ARX_SITE_ICON_INVALID);
    return;
  }
  if (!profile || profile->IsOffTheRecord()) {
    Reply(completed, request, ARX_SITE_ICON_UNAVAILABLE);
    return;
  }
  if (Requests().size() >= kMaximumRequests) {
    Reply(completed, request, ARX_SITE_ICON_BUSY);
    return;
  }
  auto* service = FaviconServiceFactory::GetForProfile(profile, ServiceAccessType::IMPLICIT_ACCESS);
  if (!service) {
    Reply(completed, request, ARX_SITE_ICON_UNAVAILABLE);
    return;
  }
  auto value = std::make_unique<Request>(profile, request, completed);
  auto* pointer = value.get();
  Requests().emplace(request, std::move(value));
  pointer->Start(service, page_url, may_fetch);
}

void CancelSiteIcon(uint64_t request) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  Requests().erase(request);
}

void StopSiteIconFetches() {
  std::vector<uint64_t> ids;
  for (const auto& [id, request] : Requests()) ids.push_back(id);
  // Finishing detaches each request from the map, so look each up again.
  for (const uint64_t id : ids) {
    auto found = Requests().find(id);
    if (found != Requests().end()) found->second->StopFetching();
  }
}

void StopSiteIcons() {
  Requests().clear();
}
}  // namespace arx
