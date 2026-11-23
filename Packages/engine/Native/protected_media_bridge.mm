#include "chrome/browser/arx/protected_media_bridge.h"

#import <Foundation/Foundation.h>

#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "base/values.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "chrome/browser/arx/protected_media_hooks.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_access_result.h"
#include "net/cookies/cookie_constants.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_partition_key_collection.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "url/gurl.h"

namespace arx {
namespace {

// The longest URL either entry point passes on, as the link offers bound theirs.
constexpr size_t kMaximumURLBytes = 8192;

// One handler: with a reason (DEV-1211) or without, as the app set it.
struct Handler {
  ArxProtectedMediaHandler function = nullptr;
  ArxProtectedMediaReasonHandler reason_function = nullptr;
  void* context = nullptr;

  bool is_set() const { return function || reason_function; }
};

Handler& CurrentHandler() {
  // Trivially destructible, so a plain function-local static (NoDestructor refuses it).
  static Handler handler;
  return handler;
}

void Report(uint64_t page, std::string url, int32_t reason) {
  const Handler handler = CurrentHandler();
  // The page may have closed meanwhile; the app ignores a page it doesn't know.
  if (!PageContents(page)) return;
  if (handler.reason_function) {
    handler.reason_function(handler.context, page, url.c_str(), reason);
  } else if (handler.function) {
    handler.function(handler.context, page, url.c_str());
  }
}

int32_t ReasonCode(ProtectedMediaReason reason) {
  switch (reason) {
    case ProtectedMediaReason::kPlaybackFailed: return ARX_PROTECTED_MEDIA_PLAYBACK_FAILED;
    case ProtectedMediaReason::kKeysWithoutMedia: return ARX_PROTECTED_MEDIA_KEYS_WITHOUT_MEDIA;
  }
  return ARX_PROTECTED_MEDIA_PLAYBACK_FAILED;
}

// Content's KeySystemSupportImpl, inside its mojo call: find the Arx page and
// post, so the app never runs inside Chromium's call.
void ProtectedMediaRequested(content::RenderFrameHost* frame, ProtectedMediaReason reason) {
  if (!frame || !CurrentHandler().is_set()) return;
  auto* contents = content::WebContents::FromRenderFrameHost(frame);
  const uint64_t page = contents ? PageIdentifier(contents) : 0;
  if (!page) return;
  const GURL& url = frame->GetMainFrame()->GetLastCommittedURL();
  if (!url.SchemeIsHTTPOrHTTPS() || url.spec().size() > kMaximumURLBytes) return;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&Report, page, url.spec(), ReasonCode(reason)));
}

const char* SameSiteName(net::CookieSameSite same_site) {
  switch (same_site) {
    case net::CookieSameSite::NO_RESTRICTION: return "none";
    case net::CookieSameSite::LAX_MODE: return "lax";
    case net::CookieSameSite::STRICT_MODE: return "strict";
    case net::CookieSameSite::UNSPECIFIED: return "unspecified";
  }
  return "unspecified";
}

std::string CookiesJSON(const net::CookieAccessResultList& included) {
  base::ListValue cookies;
  for (const auto& item : included) {
    const net::CanonicalCookie& cookie = item.cookie;
    if (cookie.IsPartitioned()) continue;
    base::DictValue entry;
    entry.Set("name", cookie.Name());
    entry.Set("value", cookie.Value());
    entry.Set("domain", cookie.Domain());
    entry.Set("path", cookie.Path());
    if (cookie.IsPersistent()) {
      entry.Set("expires", cookie.ExpiryDate().InSecondsFSinceUnixEpoch());
    } else {
      entry.Set("expires", base::Value());
    }
    entry.Set("secure", cookie.IsSecure());
    entry.Set("httpOnly", cookie.IsHttpOnly());
    entry.Set("sameSite", SameSiteName(cookie.SameSite()));
    cookies.Append(std::move(entry));
  }
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(cookies)), &json);
  return json;
}

}  // namespace
}  // namespace arx

extern "C" __attribute__((visibility("default")))
void ArxEngineSetProtectedMediaHandler(ArxProtectedMediaHandler handler, void* context) {
  CHECK([NSThread isMainThread]);
  arx::CurrentHandler() = {handler, nullptr, context};
  arx::SetProtectedMediaObserver(handler ? &arx::ProtectedMediaRequested : nullptr);
}

extern "C" __attribute__((visibility("default")))
void ArxEngineSetProtectedMediaReasonHandler(ArxProtectedMediaReasonHandler handler,
                                             void* context) {
  CHECK([NSThread isMainThread]);
  arx::CurrentHandler() = {nullptr, handler, context};
  arx::SetProtectedMediaObserver(handler ? &arx::ProtectedMediaRequested : nullptr);
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineCopySiteCookies(const char* profile_key, uint64_t page, const char* url,
                              ArxSiteCookiesCallback done, void* context) {
  CHECK([NSThread isMainThread]);
  if (!url || !done || !arx::IsEmbedded()) return false;
  const GURL site(url);
  if (!site.is_valid() || !site.SchemeIsHTTPOrHTTPS() ||
      site.spec().size() > arx::kMaximumURLBytes) return false;

  content::BrowserContext* browser_context = nullptr;
  if (page) {
    if (auto* contents = arx::PageContents(page)) browser_context = contents->GetBrowserContext();
  }
  if (!browser_context) browser_context = arx::LoadedOrdinaryProfile(profile_key ? profile_key : "");
  if (!browser_context) return false;
  auto* manager = browser_context->GetDefaultStoragePartition()->GetCookieManagerForBrowserProcess();
  if (!manager) return false;

  auto reply = base::BindOnce(
      [](ArxSiteCookiesCallback done, void* context, const net::CookieAccessResultList& included,
         const net::CookieAccessResultList&) {
        const std::string json = arx::CookiesJSON(included);
        done(context, json.c_str(), json.size());
      },
      done, context);
  // Partitioned cookies stay behind: WebKit keeps its own partitions.
  manager->GetCookieList(site, net::CookieOptions::MakeAllInclusive(),
                         net::CookiePartitionKeyCollection(),
                         mojo::WrapCallbackWithDefaultInvokeIfNotRun(
                             std::move(reply), net::CookieAccessResultList(),
                             net::CookieAccessResultList()));
  return true;
}
