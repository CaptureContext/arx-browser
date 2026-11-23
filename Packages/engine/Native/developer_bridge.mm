#include "chrome/browser/arx/developer_bridge.h"
#include "chrome/browser/arx/devtools_bridge.h"

#include <algorithm>
#include <climits>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <optional>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/json/string_escape.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/escape.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "components/arx_inspection/developer.mojom.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/global_request_id.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "net/base/net_errors.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_access_result.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_partition_key_collection.h"
#include "net/http/http_response_headers.h"
#include "services/network/public/cpp/request_destination.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "third_party/blink/public/common/arx_developer_world_id.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "third_party/blink/public/mojom/loader/resource_load_info.mojom.h"
#include "url/gurl.h"

static_assert(ISOLATED_WORLD_ID_ARX_DEVELOPER == blink::kArxDeveloperWorldId,
              "Blink's developer-world hooks must key on Arx's isolated world");
static_assert(ISOLATED_WORLD_ID_ARX_TRANSLATION == blink::kArxTranslationWorldId,
              "Blink's hooks must key on Arx's translation world too");

namespace arx {
namespace {
constexpr size_t kMaximumEntries = 500;
constexpr size_t kMaximumMessageBytes = 2048;
constexpr size_t kMaximumURLBytes = 2048;
constexpr size_t kMaximumSourceBytes = 65536;
constexpr uint32_t kMaximumResultBytes = 262144;
constexpr uint32_t kMaximumTimeout = 30000;
constexpr uint32_t kMaximumReadLimit = 200;
constexpr size_t kMaximumRequests = 8;
constexpr size_t kMinimumRedactedBytes = 8;
constexpr char kRedacted[] = "[redacted]";

void ReplyLater(DeveloperReply reply, uint64_t request, uint64_t page, ArxDeveloperStatus status,
                std::string json = std::string()) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
      [](DeveloperReply reply, uint64_t request, uint64_t page, ArxDeveloperStatus status,
         std::string json) {
        reply(request, page, status,
              json.empty() ? nullptr : reinterpret_cast<const uint8_t*>(json.data()), json.size());
      }, reply, request, page, status, std::move(json)));
}

bool Live(content::WebContents* contents) {
  return contents && !contents->IsBeingDestroyed() && !contents->IsCrashed();
}

bool Ordinary(content::WebContents* contents) {
  return Live(contents) && !contents->GetBrowserContext()->IsOffTheRecord();
}

std::string Bounded(std::string_view text, size_t bytes) {
  std::string output;
  base::TruncateUTF8ToByteSize(text, bytes, &output);
  return output;
}

bool SensitiveKey(std::string_view key) {
  const std::string lowered = base::ToLowerASCII(
      base::UnescapeURLComponent(key, base::UnescapeRule::SPACES |
                                 base::UnescapeRule::URL_SPECIAL_CHARS_EXCEPT_PATH_SEPARATORS));
  for (std::string_view token : {"token", "auth", "key", "secret", "pass", "pwd", "session", "sid",
                                 "sig", "code", "credential", "jwt", "bearer", "cookie", "ticket",
                                 "otp", "state", "nonce", "assertion", "saml"}) {
    if (lowered.find(token) != std::string::npos) return true;
  }
  return false;
}

// Every string in value, recursively, with cookie values replaced.
void Redact(base::Value& value, const std::vector<std::string>& cookie_values) {
  if (value.is_string()) {
    RedactDeveloperText(value.GetString(), cookie_values);
  } else if (value.is_dict()) {
    for (auto [key, child] : value.GetDict()) Redact(child, cookie_values);
  } else if (value.is_list()) {
    for (auto& child : value.GetList()) Redact(child, cookie_values);
  }
}

// The cookie values a page's own URL can see, HttpOnly and partitioned
// included, for redaction only. A lost cookie manager answers with none.
void WithCookieValues(content::WebContents* contents, const GURL& url,
                      base::OnceCallback<void(std::vector<std::string>)> done) {
  auto* manager = contents->GetBrowserContext()->GetDefaultStoragePartition()
      ->GetCookieManagerForBrowserProcess();
  auto collect = base::BindOnce(
      [](base::OnceCallback<void(std::vector<std::string>)> done,
         const net::CookieAccessResultList& included, const net::CookieAccessResultList&) {
        std::vector<std::string> values;
        for (const auto& item : included) values.push_back(item.cookie.Value());
        std::move(done).Run(std::move(values));
      }, std::move(done));
  manager->GetCookieList(url, net::CookieOptions::MakeAllInclusive(),
                         net::CookiePartitionKeyCollection::ContainsAll(),
                         mojo::WrapCallbackWithDefaultInvokeIfNotRun(
                             std::move(collect), net::CookieAccessResultList(),
                             net::CookieAccessResultList()));
}

std::string Write(const base::Value& value) {
  std::string json;
  base::JSONWriter::Write(value, &json);
  return json;
}

const char* Level(blink::mojom::ConsoleMessageLevel level) {
  switch (level) {
    case blink::mojom::ConsoleMessageLevel::kVerbose: return "verbose";
    case blink::mojom::ConsoleMessageLevel::kInfo: return "info";
    case blink::mojom::ConsoleMessageLevel::kWarning: return "warning";
    case blink::mojom::ConsoleMessageLevel::kError: return "error";
  }
  return "info";
}

double Now() { return base::Time::Now().InMillisecondsFSinceUnixEpoch(); }

// One page's console and network logs, kept here and read on request: nothing
// streams to Swift or the app's store.
class DeveloperLog final : public content::WebContentsObserver {
 public:
  explicit DeveloperLog(content::WebContents* contents) : WebContentsObserver(contents) {}

  base::DictValue Read(ArxDeveloperLogKind kind, uint64_t after, uint32_t limit) const {
    const Ring& ring = kind == ARX_DEVELOPER_LOG_CONSOLE ? console_ : network_;
    base::ListValue entries;
    uint64_t next = after;
    for (const auto& [sequence, entry] : ring.entries) {
      if (sequence <= after) continue;
      if (entries.size() >= limit) break;
      entries.Append(entry.Clone());
      next = sequence;
    }
    const uint64_t first = ring.entries.empty() ? ring.next : ring.entries.front().first;
    const uint64_t dropped = first > after + 1 ? first - after - 1 : 0;
    base::DictValue result;
    result.Set("capturing", true);
    result.Set("entries", std::move(entries));
    result.Set("next", static_cast<int>(std::min<uint64_t>(next, INT_MAX)));
    result.Set("dropped", static_cast<int>(std::min<uint64_t>(dropped, INT_MAX)));
    return result;
  }

  void OnDidAddMessageToConsole(content::RenderFrameHost* frame,
                                blink::mojom::ConsoleMessageLevel level,
                                const std::u16string& message, int32_t line,
                                const std::u16string& source,
                                const std::optional<std::u16string>&) override {
    base::DictValue entry;
    entry.Set("level", Level(level));
    entry.Set("message", Bounded(base::UTF16ToUTF8(message), kMaximumMessageBytes));
    const GURL source_url(base::UTF16ToUTF8(source));
    if (source_url.is_valid()) entry.Set("source", SanitizedDeveloperURL(source_url));
    if (line > 0) entry.Set("line", line);
    entry.Set("mainFrame", frame && frame->IsInPrimaryMainFrame());
    entry.Set("time", Now());
    Add(console_, std::move(entry));
  }

  void ResourceLoadComplete(content::RenderFrameHost* frame, const content::GlobalRequestID&,
                            const GURL&, const blink::mojom::ResourceLoadInfo& info) override {
    base::DictValue entry;
    entry.Set("method", Bounded(info.method, 16));
    entry.Set("url", SanitizedDeveloperURL(info.final_url));
    if (info.http_status_code > 0) entry.Set("status", info.http_status_code);
    entry.Set("type", network::RequestDestinationToString(
        info.request_destination, network::EmptyRequestDestinationOption::kUseFiveCharEmptyString));
    if (!info.mime_type.empty()) entry.Set("mimeType", Bounded(info.mime_type, 128));
    entry.Set("cached", info.was_cached);
    entry.Set("bytes", static_cast<double>(info.raw_body_bytes.InBytes()));
    if (info.net_error != net::OK) entry.Set("error", net::ErrorToShortString(info.net_error));
    entry.Set("mainFrame", frame && frame->IsInPrimaryMainFrame());
    entry.Set("time", Now());
    Add(network_, std::move(entry));
  }

  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsSameDocument() || !navigation->GetURL().is_valid()) return;
    base::DictValue entry;
    entry.Set("method", navigation->IsPost() ? "POST" : "GET");
    entry.Set("url", SanitizedDeveloperURL(navigation->GetURL()));
    const auto* headers = navigation->GetResponseHeaders();
    if (headers && headers->response_code() > 0) entry.Set("status", headers->response_code());
    entry.Set("type", navigation->IsInMainFrame() ? "document" : "iframe");
    if (navigation->GetNetErrorCode() != net::OK)
      entry.Set("error", net::ErrorToShortString(navigation->GetNetErrorCode()));
    entry.Set("mainFrame", navigation->IsInPrimaryMainFrame());
    entry.Set("time", Now());
    Add(network_, std::move(entry));
  }

 private:
  struct Ring {
    std::deque<std::pair<uint64_t, base::DictValue>> entries;
    uint64_t next = 1;
  };

  static void Add(Ring& ring, base::DictValue entry) {
    if (ring.next >= INT_MAX) return;
    const uint64_t sequence = ring.next++;
    entry.Set("sequence", static_cast<int>(sequence));
    ring.entries.emplace_back(sequence, std::move(entry));
    while (ring.entries.size() > kMaximumEntries) ring.entries.pop_front();
  }

  Ring console_, network_;
};

std::map<uint64_t, std::unique_ptr<DeveloperLog>>& Logs() {
  static base::NoDestructor<std::map<uint64_t, std::unique_ptr<DeveloperLog>>> logs;
  return *logs;
}

class ScriptRequest;
std::map<uint64_t, std::unique_ptr<ScriptRequest>>& Requests() {
  static base::NoDestructor<std::map<uint64_t, std::unique_ptr<ScriptRequest>>> requests;
  return *requests;
}

ArxDeveloperStatus Status(developer::mojom::ScriptStatus status) {
  switch (status) {
    case developer::mojom::ScriptStatus::kOK: return ARX_DEVELOPER_OK;
    case developer::mojom::ScriptStatus::kException: return ARX_DEVELOPER_EXCEPTION;
    case developer::mojom::ScriptStatus::kSyntax: return ARX_DEVELOPER_SYNTAX;
    case developer::mojom::ScriptStatus::kLimit: return ARX_DEVELOPER_LIMIT;
    case developer::mojom::ScriptStatus::kUnavailable: return ARX_DEVELOPER_UNSUPPORTED;
    case developer::mojom::ScriptStatus::kInvalid: return ARX_DEVELOPER_INVALID;
    case developer::mojom::ScriptStatus::kFailed: return ARX_DEVELOPER_FAILED;
  }
  return ARX_DEVELOPER_FAILED;
}

// One logical reply per request. The renderer may answer after the reply;
// a late answer is dropped. Every reply also lets the request go, a timeout too
// (DEV-1135): a renderer that never answers can't keep its page's queue or an
// app-wide slot.
class ScriptRequest final : public content::WebContentsObserver {
 public:
  ScriptRequest(content::WebContents* contents, uint64_t page, uint64_t request,
                uint32_t maximum_bytes, uint32_t timeout_ms, bool translation,
                DeveloperReply reply)
      : WebContentsObserver(contents), page_(page), request_(request),
        maximum_bytes_(maximum_bytes), translation_(translation), reply_(reply),
        document_(contents->GetPrimaryMainFrame()->GetWeakDocumentPtr()) {
    timeout_.Start(FROM_HERE, base::Milliseconds(timeout_ms),
        base::BindOnce(&ScriptRequest::TimedOut, weak_.GetWeakPtr()));
  }

  uint64_t page() const { return page_; }
  bool translation() const { return translation_; }

  void Start(const std::string& source) {
    auto* frame = web_contents()->GetPrimaryMainFrame();
    frame->GetRemoteAssociatedInterfaces()->GetInterface(&runner_);
    runner_.set_disconnect_handler(base::BindOnce(&ScriptRequest::Gone, weak_.GetWeakPtr()));
    auto done = base::BindOnce(&ScriptRequest::Evaluated, weak_.GetWeakPtr());
    if (translation_) {
      runner_->EvaluateTranslation(source, maximum_bytes_, std::move(done));
    } else {
      runner_->Evaluate(source, maximum_bytes_, std::move(done));
    }
  }

  void Fail(ArxDeveloperStatus status) {
    if (replied_) return;
    replied_ = true;
    timeout_.Stop();
    ReplyLater(reply_, request_, page_, status);
  }

  void DidStartNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsInPrimaryMainFrame() && !navigation->IsSameDocument()) {
      Fail(ARX_DEVELOPER_STALE);
      Drain();
    }
  }
  void PrimaryPageWillBeDeactivated(content::Page&) override { Gone(); }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override { Gone(); }
  void WebContentsDestroyed() override { Gone(); }

 private:
  bool IsCurrent() const {
    auto* frame = document_.AsRenderFrameHostIfValid();
    return frame && web_contents() && web_contents()->GetPrimaryMainFrame() == frame;
  }

  void Evaluated(developer::mojom::ScriptStatus status, const std::string& result) {
    if (replied_) { Drain(); return; }
    if (!IsCurrent()) { Fail(ARX_DEVELOPER_STALE); Drain(); return; }
    const ArxDeveloperStatus native = Status(status);
    const bool has_body = native == ARX_DEVELOPER_OK || native == ARX_DEVELOPER_EXCEPTION ||
        native == ARX_DEVELOPER_SYNTAX;
    if (!has_body) { Fail(native); Drain(); return; }
    if (result.size() > maximum_bytes_ + 4096) { Fail(ARX_DEVELOPER_LIMIT); Drain(); return; }
    auto parsed = base::JSONReader::Read(result, base::JSON_PARSE_RFC);
    if (!parsed || !parsed->is_dict()) { Fail(ARX_DEVELOPER_FAILED); Drain(); return; }
    WithCookieValues(web_contents(), web_contents()->GetPrimaryMainFrame()->GetLastCommittedURL(),
        base::BindOnce(&ScriptRequest::Deliver, weak_.GetWeakPtr(), native, std::move(*parsed)));
  }

  void Deliver(ArxDeveloperStatus status, base::Value body, std::vector<std::string> cookies) {
    if (replied_) { Drain(); return; }
    if (!IsCurrent()) { Fail(ARX_DEVELOPER_STALE); Drain(); return; }
    Redact(body, cookies);
    replied_ = true;
    timeout_.Stop();
    ReplyLater(reply_, request_, page_, status, Write(body));
    Drain();
  }

  void Gone() { Fail(ARX_DEVELOPER_STALE); Drain(); }

  // The request goes before the reply is delivered, both posted in that order, so a
  // caller that asks again on the timeout finds the page and its slot free. The
  // renderer's late answer, if any, finds no request and is dropped.
  void TimedOut() {
    if (replied_) return;
    Drain();
    Fail(ARX_DEVELOPER_TIMEOUT);
  }

  void Drain() {
    // The owner's address only, never followed: this can run twice, and a pointer bound into
    // the task would dangle once the first run erases the owner.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](uint64_t request, uintptr_t owner) {
          auto found = Requests().find(request);
          if (found != Requests().end() && reinterpret_cast<uintptr_t>(found->second.get()) == owner)
            Requests().erase(found);
        }, request_, reinterpret_cast<uintptr_t>(this)));
  }

  const uint64_t page_, request_;
  const uint32_t maximum_bytes_;
  // ABI57: the translation world instead of the developer world.
  const bool translation_;
  const DeveloperReply reply_;
  const content::WeakDocumentPtr document_;
  bool replied_ = false;
  mojo::AssociatedRemote<developer::mojom::ScriptRunner> runner_;
  base::OneShotTimer timeout_;
  base::WeakPtrFactory<ScriptRequest> weak_{this};
};
}  // namespace

std::string SanitizedDeveloperURL(const GURL& url) {
  if (!url.is_valid()) return std::string();
  if (!url.SchemeIsHTTPOrHTTPS() && !url.SchemeIsWSOrWSS()) return std::string(url.scheme()) + ":";
  GURL::Replacements replacements;
  replacements.ClearUsername();
  replacements.ClearPassword();
  replacements.ClearRef();
  std::string query;
  if (url.has_query()) {
    const std::string original(url.query());
    for (std::string_view piece : base::SplitStringPiece(original, "&", base::KEEP_WHITESPACE,
                                                          base::SPLIT_WANT_ALL)) {
      if (!query.empty()) query += '&';
      const size_t equals = piece.find('=');
      if (equals != std::string_view::npos && SensitiveKey(piece.substr(0, equals))) {
        query.append(piece.substr(0, equals));
        query += "=redacted";
      } else {
        query.append(piece);
      }
    }
    replacements.SetQueryStr(query);
  }
  return Bounded(url.ReplaceComponents(replacements).spec(), kMaximumURLBytes);
}

void RedactDeveloperText(std::string& text, const std::vector<std::string>& cookie_values) {
  for (const auto& value : cookie_values) {
    if (value.size() < kMinimumRedactedBytes) continue;
    std::string escaped;
    base::EscapeJSONString(value, /*put_in_quotes=*/false, &escaped);
    for (const std::string& needle :
         {value, escaped, base::EscapeQueryParamValue(value, /*use_plus=*/false)}) {
      if (needle.size() >= kMinimumRedactedBytes)
        base::ReplaceSubstringsAfterOffset(&text, 0, needle, kRedacted);
    }
  }
}

namespace {
void RunScriptRequest(content::WebContents* contents, uint64_t page, uint64_t request,
                    const char* source, uint32_t maximum_bytes, uint32_t timeout_ms,
                    bool translation, DeveloperReply reply) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const size_t length = source ? strnlen(source, kMaximumSourceBytes + 1) : 0;
  if (!request || !length || length > kMaximumSourceBytes || !maximum_bytes ||
      maximum_bytes > kMaximumResultBytes || !timeout_ms || timeout_ms > kMaximumTimeout ||
      Requests().contains(request) || !base::IsStringUTF8(std::string_view(source, length))) {
    ReplyLater(reply, request, page, ARX_DEVELOPER_INVALID);
    return;
  }
  // Agent scripts never run in a private page; the app's translation does.
  if (!(translation ? Live(contents) : Ordinary(contents))) {
    ReplyLater(reply, request, page, ARX_DEVELOPER_UNAVAILABLE);
    return;
  }
  auto* frame = contents->GetPrimaryMainFrame();
  if (!frame || !frame->IsRenderFrameLive()) {
    ReplyLater(reply, request, page, ARX_DEVELOPER_UNAVAILABLE);
    return;
  }
  if (!frame->GetLastCommittedURL().SchemeIsHTTPOrHTTPS() || frame->IsErrorDocument()) {
    ReplyLater(reply, request, page, ARX_DEVELOPER_UNSUPPORTED);
    return;
  }
  // Translation and agent scripts are counted apart, so neither waits on the other.
  const bool page_busy = std::any_of(Requests().begin(), Requests().end(),
      [page, translation](const auto& item) {
        return item.second->page() == page && item.second->translation() == translation;
      });
  const size_t running = std::count_if(Requests().begin(), Requests().end(),
      [translation](const auto& item) { return item.second->translation() == translation; });
  if (page_busy || running >= kMaximumRequests) {
    ReplyLater(reply, request, page, ARX_DEVELOPER_BUSY);
    return;
  }
  auto& owned = Requests()[request];
  owned = std::make_unique<ScriptRequest>(contents, page, request, maximum_bytes, timeout_ms,
                                          translation, reply);
  owned->Start(std::string(source, length));
}
}  // namespace

void EvaluateDeveloperScript(content::WebContents* contents, uint64_t page, uint64_t request,
                             const char* source, uint32_t maximum_bytes, uint32_t timeout_ms,
                             DeveloperReply reply) {
  RunScriptRequest(contents, page, request, source, maximum_bytes, timeout_ms,
                 /*translation=*/false, reply);
}

void EvaluateTranslationScript(content::WebContents* contents, uint64_t page, uint64_t request,
                               const char* source, uint32_t maximum_bytes, uint32_t timeout_ms,
                               DeveloperReply reply) {
  RunScriptRequest(contents, page, request, source, maximum_bytes, timeout_ms,
                 /*translation=*/true, reply);
}

void PingPage(content::WebContents* contents, uint64_t page, uint64_t request,
              uint32_t timeout_ms, base::RepeatingCallback<bool()> held, DeveloperReply reply) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!request || !timeout_ms || timeout_ms > kMaximumTimeout) {
    ReplyLater(reply, request, page, ARX_DEVELOPER_INVALID);
    return;
  }
  auto* frame = contents && !contents->IsBeingDestroyed() && !contents->IsCrashed()
                    ? contents->GetPrimaryMainFrame() : nullptr;
  // A page DevTools may hold on a breakpoint can't be told from a hung one.
  if (!frame || !frame->IsRenderFrameLive() || DevToolsIsOpen(contents)) {
    ReplyLater(reply, request, page, ARX_DEVELOPER_UNAVAILABLE);
    return;
  }
  // Whichever comes first, the answer or the deadline, replies.
  auto replied = base::MakeRefCounted<base::RefCountedData<bool>>(false);
  frame->ExecuteJavaScriptInIsolatedWorld(
      u"0",
      base::BindOnce([](scoped_refptr<base::RefCountedData<bool>> replied, DeveloperReply reply,
                        uint64_t request, uint64_t page, base::Value) {
        if (replied->data) return;
        replied->data = true;
        reply(request, page, ARX_DEVELOPER_OK, nullptr, 0);
      }, replied, reply, request, page),
      ISOLATED_WORLD_ID_CHROME_INTERNAL);
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
      base::BindOnce([](scoped_refptr<base::RefCountedData<bool>> replied, DeveloperReply reply,
                        uint64_t request, uint64_t page, base::RepeatingCallback<bool()> held) {
        if (replied->data) return;
        replied->data = true;
        // A dialog, a freeze or DevTools that came while the ping waited isn't a hang either.
        reply(request, page, held && held.Run() ? ARX_DEVELOPER_UNAVAILABLE : ARX_DEVELOPER_TIMEOUT,
              nullptr, 0);
      }, replied, reply, request, page, std::move(held)),
      base::Milliseconds(timeout_ms));
}

bool SetDeveloperLog(content::WebContents* contents, uint64_t page, bool enabled) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!enabled) {
    Logs().erase(page);
    return true;
  }
  if (!Ordinary(contents)) return false;
  auto& log = Logs()[page];
  if (!log) log = std::make_unique<DeveloperLog>(contents);
  return true;
}

void ReadDeveloperLog(content::WebContents* contents, uint64_t page, uint64_t request,
                      ArxDeveloperLogKind kind, uint64_t after, uint32_t limit,
                      DeveloperReply reply) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!request || !limit || limit > kMaximumReadLimit ||
      (kind != ARX_DEVELOPER_LOG_CONSOLE && kind != ARX_DEVELOPER_LOG_NETWORK)) {
    ReplyLater(reply, request, page, ARX_DEVELOPER_INVALID);
    return;
  }
  if (!Ordinary(contents)) { ReplyLater(reply, request, page, ARX_DEVELOPER_UNAVAILABLE); return; }
  auto found = Logs().find(page);
  if (found == Logs().end()) {
    base::DictValue idle;
    idle.Set("capturing", false);
    idle.Set("entries", base::ListValue());
    idle.Set("next", static_cast<int>(std::min<uint64_t>(after, INT_MAX)));
    idle.Set("dropped", 0);
    ReplyLater(reply, request, page, ARX_DEVELOPER_OK, Write(base::Value(std::move(idle))));
    return;
  }
  base::Value result(found->second->Read(kind, after, limit));
  WithCookieValues(contents, contents->GetPrimaryMainFrame()->GetLastCommittedURL(),
      base::BindOnce([](DeveloperReply reply, uint64_t request, uint64_t page, base::Value result,
                        std::vector<std::string> cookies) {
        Redact(result, cookies);
        ReplyLater(reply, request, page, ARX_DEVELOPER_OK, Write(result));
      }, reply, request, page, std::move(result)));
}

void CancelDeveloperRequest(uint64_t request) {
  auto found = Requests().find(request);
  if (found == Requests().end()) return;
  found->second->Fail(ARX_DEVELOPER_CANCELLED);
  Requests().erase(found);
}

void ForgetDeveloperPage(uint64_t page) {
  Logs().erase(page);
  for (auto it = Requests().begin(); it != Requests().end();) {
    if (it->second->page() == page) {
      it->second->Fail(ARX_DEVELOPER_STALE);
      it = Requests().erase(it);
    } else {
      ++it;
    }
  }
}

void StopDevelopers() {
  for (auto& [request, owned] : Requests()) owned->Fail(ARX_DEVELOPER_UNAVAILABLE);
  Requests().clear();
  Logs().clear();
}
}  // namespace arx
