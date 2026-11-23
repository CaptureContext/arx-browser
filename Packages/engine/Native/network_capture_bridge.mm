#include "chrome/browser/arx/network_capture_bridge.h"

#include <algorithm>
#include <array>
#include <climits>
#include <deque>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/containers/span.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/scoped_refptr.h"
#include "base/no_destructor.h"
#include "base/strings/string_util.h"
#include "base/values.h"
#include "chrome/browser/arx/developer_bridge.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/web_contents.h"
#include "url/gurl.h"

namespace arx {
namespace {

constexpr size_t kMaximumEntries = 500;
// Each body is cut at 1 MiB, and a page keeps at most 32 MiB of them; older
// bodies go first and their entries say so.
constexpr size_t kMaximumBodyBytes = 1024 * 1024;
constexpr size_t kMaximumKeptBodyBytes = 32 * 1024 * 1024;
// Responses larger than this on the wire aren't fetched at all.
constexpr double kMaximumFetchedBytes = 4 * 1024 * 1024;
constexpr size_t kMaximumHeaders = 64;
constexpr size_t kMaximumHeaderValueBytes = 4096;

std::string Bounded(std::string_view text, size_t bytes) {
  std::string result;
  base::TruncateUTF8ToByteSize(text, bytes, &result);
  return result;
}

// Headers whose value is a URL, sanitized like the request URL itself.
bool URLHeader(std::string_view name) {
  const std::string lower = base::ToLowerASCII(name);
  return lower == "location" || lower == "content-location" || lower == "referer";
}

// `base` is the URL the headers came with, for relative URL-valued headers.
base::DictValue Headers(const base::DictValue* headers, const GURL& base) {
  base::DictValue result;
  if (!headers) return result;
  for (const auto [name, value] : *headers) {
    if (result.size() >= kMaximumHeaders) break;
    if (!value.is_string()) continue;
    // The name stays so an agent knows the header was sent; its value never leaves.
    std::string text = value.GetString();
    if (SensitiveHeader(name)) {
      text = "[redacted]";
    } else if (URLHeader(name)) {
      // A redirect's Location can carry an OAuth code or token, as the request URL can. A
      // value that doesn't resolve to a URL is hidden rather than passed through.
      const GURL url = base.is_valid() ? base.Resolve(text) : GURL(text);
      text = url.is_valid() ? SanitizedDeveloperURL(url) : std::string("[redacted]");
    }
    result.Set(Bounded(name, 256), Bounded(text, kMaximumHeaderValueBytes));
  }
  return result;
}

// An entry gets its sequence number only once it's complete (finished or
// failed, with its body when one was fetched), so a reader paging with `after`
// never sees a half-filled entry it would then skip.
struct Entry {
  uint64_t id = 0;
  uint64_t sequence = 0;
  base::DictValue value;
  size_t body_bytes = 0;
};

// One page's requests, through its own DevTools protocol session. Nothing
// streams to Swift: entries are read on request, like the developer logs.
class NetworkCapture final : public content::DevToolsAgentHostClient {
 public:
  explicit NetworkCapture(content::WebContents* contents)
      : host_(content::DevToolsAgentHost::GetOrCreateFor(contents)) {}

  ~NetworkCapture() override {
    if (host_ && attached_) host_->DetachClient(this);
  }

  bool Start() {
    attached_ = host_ && host_->AttachClient(this);
    if (!attached_) return false;
    base::DictValue params;
    params.Set("maxTotalBufferSize", 64 * 1024 * 1024);
    params.Set("maxResourceBufferSize", static_cast<int>(kMaximumBodyBytes));
    params.Set("maxPostDataSize", static_cast<int>(kMaximumBodyBytes));
    Send("Network.enable", std::move(params));
    return true;
  }

  std::string Read(uint64_t after, uint32_t limit, uint32_t body_bytes) const {
    std::vector<const Entry*> published;
    uint64_t first = next_sequence_;
    for (const auto& entry : entries_) {
      if (!entry.sequence) continue;
      first = std::min(first, entry.sequence);
      if (entry.sequence > after) published.push_back(&entry);
    }
    std::sort(published.begin(), published.end(),
              [](const Entry* lhs, const Entry* rhs) { return lhs->sequence < rhs->sequence; });
    base::ListValue entries;
    uint64_t next = after;
    for (const Entry* entry : published) {
      if (entries.size() >= limit) break;
      base::DictValue value = entry->value.Clone();
      for (const char* key : {"requestBody", "responseBody"}) {
        const std::string* body = value.FindString(key);
        if (!body) continue;
        if (body_bytes == 0) {
          value.Remove(key);
        } else if (body->size() > body_bytes) {
          value.Set(std::string(key) + "Truncated", true);
          value.Set(key, Bounded(*body, body_bytes));
        }
      }
      entries.Append(std::move(value));
      next = entry->sequence;
    }
    const uint64_t dropped = first > after + 1 ? first - after - 1 : 0;
    base::DictValue result;
    result.Set("capturing", attached_);
    result.Set("entries", std::move(entries));
    result.Set("next", static_cast<int>(std::min<uint64_t>(next, INT_MAX)));
    result.Set("dropped", static_cast<int>(std::min<uint64_t>(dropped, INT_MAX)));
    std::string json;
    base::JSONWriter::Write(result, &json);
    return json;
  }

  // content::DevToolsAgentHostClient:
  void DispatchProtocolMessage(content::DevToolsAgentHost*,
                               base::span<const uint8_t> message) override {
    const std::string_view text(reinterpret_cast<const char*>(message.data()), message.size());
    std::optional<base::DictValue> value = base::JSONReader::ReadDict(text, base::JSON_PARSE_RFC);
    if (!value) return;
    if (std::optional<int> id = value->FindInt("id")) {
      Reply(*id, *value);
      return;
    }
    const std::string* method = value->FindString("method");
    const base::DictValue* params = value->FindDict("params");
    if (!method || !params) return;
    if (*method == "Network.requestWillBeSent") RequestWillBeSent(*params);
    else if (*method == "Network.responseReceived") ResponseReceived(*params);
    else if (*method == "Network.loadingFinished") LoadingFinished(*params);
    else if (*method == "Network.loadingFailed") LoadingFailed(*params);
  }

  void AgentHostClosed(content::DevToolsAgentHost*) override { attached_ = false; }

  bool MayAttachToURL(const GURL&, bool is_webui) override { return !is_webui; }

 private:
  void Send(const char* method, base::DictValue params, int* id = nullptr) {
    if (!host_ || !attached_) return;
    const int message_id = next_message_++;
    if (id) *id = message_id;
    base::DictValue message;
    message.Set("id", message_id);
    message.Set("method", method);
    message.Set("params", std::move(params));
    std::string json;
    base::JSONWriter::Write(message, &json);
    host_->DispatchProtocolMessage(this, base::as_byte_span(json));
  }

  Entry* Find(const std::string& request_id) {
    auto found = pending_.find(request_id);
    return found == pending_.end() ? nullptr : FindID(found->second);
  }

  Entry* FindID(uint64_t id) {
    for (auto& entry : entries_)
      if (entry.id == id) return &entry;
    return nullptr;
  }

  void Publish(Entry& entry) {
    if (entry.sequence || next_sequence_ >= INT_MAX) return;
    entry.sequence = next_sequence_++;
    entry.value.Set("sequence", static_cast<int>(entry.sequence));
  }

  void RequestWillBeSent(const base::DictValue& params) {
    const std::string* request_id = params.FindString("requestId");
    const base::DictValue* request = params.FindDict("request");
    if (!request_id || !request) return;
    // A redirect reuses the request ID: the hop it ends keeps the redirect's response.
    if (Entry* previous = Find(*request_id)) {
      if (const base::DictValue* redirect = params.FindDict("redirectResponse")) Respond(*previous, *redirect);
      previous->value.Set("redirected", true);
      Publish(*previous);
    }
    pending_.erase(*request_id);
    // Only the web: a tab that goes back to a local file, or a data: or blob: URL, keeps
    // nothing, so a file's contents never reach a reader.
    const std::string* target = request->FindString("url");
    if (!target || !GURL(*target).SchemeIsHTTPOrHTTPS()) return;
    Entry entry;
    entry.id = next_id_++;
    const std::string* method = request->FindString("method");
    entry.value.Set("method", Bounded(method ? *method : "GET", 16));
    const std::string* url = request->FindString("url");
    entry.value.Set("url", SanitizedDeveloperURL(GURL(url ? *url : "")));
    if (const std::string* type = params.FindString("type")) entry.value.Set("type", Bounded(*type, 32));
    entry.value.Set("requestHeaders", Headers(request->FindDict("headers"), GURL(url ? *url : "")));
    if (const std::string* body = request->FindString("postData")) {
      entry.value.Set("requestBody", Bounded(*body, kMaximumBodyBytes));
      if (body->size() > kMaximumBodyBytes) entry.value.Set("requestBodyTruncated", true);
      entry.body_bytes += std::min(body->size(), kMaximumBodyBytes);
    } else if (request->FindBool("hasPostData").value_or(false)) {
      entry.value.Set("requestBodyOmitted", true);
    }
    if (std::optional<double> wall = params.FindDouble("wallTime")) entry.value.Set("time", *wall * 1000);
    if (std::optional<double> start = params.FindDouble("timestamp")) entry.value.Set("start", *start);
    pending_[*request_id] = entry.id;
    entries_.push_back(std::move(entry));
    Trim();
  }

  void Respond(Entry& entry, const base::DictValue& response) {
    if (std::optional<int> status = response.FindInt("status")) entry.value.Set("status", *status);
    if (std::optional<double> status = response.FindDouble("status")) entry.value.Set("status", static_cast<int>(*status));
    if (const std::string* text = response.FindString("statusText")) entry.value.Set("statusText", Bounded(*text, 128));
    if (const std::string* mime = response.FindString("mimeType")) entry.value.Set("mimeType", Bounded(*mime, 128));
    if (const std::string* protocol = response.FindString("protocol")) entry.value.Set("protocol", Bounded(*protocol, 32));
    const std::string* url = response.FindString("url");
    entry.value.Set("responseHeaders", Headers(response.FindDict("headers"), GURL(url ? *url : "")));
  }

  void ResponseReceived(const base::DictValue& params) {
    const std::string* request_id = params.FindString("requestId");
    const base::DictValue* response = params.FindDict("response");
    Entry* entry = request_id ? Find(*request_id) : nullptr;
    if (entry && response) Respond(*entry, *response);
  }

  void LoadingFinished(const base::DictValue& params) {
    const std::string* request_id = params.FindString("requestId");
    if (!request_id) return;
    Entry* entry = Find(*request_id);
    if (!entry) {
      pending_.erase(*request_id);
      return;
    }
    const double bytes = params.FindDouble("encodedDataLength").value_or(0);
    entry->value.Set("bytes", bytes);
    Finish(*entry, params);
    if (bytes <= kMaximumFetchedBytes) {
      base::DictValue body;
      body.Set("requestId", *request_id);
      int id = 0;
      Send("Network.getResponseBody", std::move(body), &id);
      if (id) {
        bodies_[id] = entry->id;
      } else {
        Publish(*entry);
      }
    } else {
      entry->value.Set("responseBodyOmitted", true);
      Publish(*entry);
    }
    pending_.erase(*request_id);
  }

  void LoadingFailed(const base::DictValue& params) {
    const std::string* request_id = params.FindString("requestId");
    if (!request_id) return;
    if (Entry* entry = Find(*request_id)) {
      if (const std::string* error = params.FindString("errorText")) entry->value.Set("error", Bounded(*error, 64));
      if (params.FindBool("canceled").value_or(false)) entry->value.Set("canceled", true);
      Finish(*entry, params);
      Publish(*entry);
    }
    pending_.erase(*request_id);
  }

  void Finish(Entry& entry, const base::DictValue& params) {
    const std::optional<double> end = params.FindDouble("timestamp");
    const std::optional<double> start = entry.value.FindDouble("start");
    if (end && start) entry.value.Set("duration", std::max(0.0, (*end - *start) * 1000));
    entry.value.Remove("start");
  }

  void Reply(int id, const base::DictValue& message) {
    auto found = bodies_.find(id);
    if (found == bodies_.end()) return;
    const uint64_t entry_id = found->second;
    bodies_.erase(found);
    Entry* entry = FindID(entry_id);
    if (!entry) return;
    const base::DictValue* result = message.FindDict("result");
    const std::string* body = result ? result->FindString("body") : nullptr;
    if (body) {
      if (result->FindBool("base64Encoded").value_or(false)) entry->value.Set("responseBodyBase64", true);
      entry->value.Set("responseBody", Bounded(*body, kMaximumBodyBytes));
      if (body->size() > kMaximumBodyBytes) entry->value.Set("responseBodyTruncated", true);
      entry->body_bytes += std::min(body->size(), kMaximumBodyBytes);
    } else {
      entry->value.Set("responseBodyOmitted", true);
    }
    Publish(*entry);
    Trim();
  }

  // At most kMaximumEntries entries and kMaximumKeptBodyBytes of bodies.
  void Trim() {
    while (entries_.size() > kMaximumEntries) {
      const uint64_t evicted = entries_.front().id;
      entries_.pop_front();
      // Its request may still be running; forget it so the maps stay bounded too.
      std::erase_if(pending_, [&](const auto& item) { return item.second == evicted; });
      std::erase_if(bodies_, [&](const auto& item) { return item.second == evicted; });
    }
    size_t kept = 0;
    for (const auto& entry : entries_) kept += entry.body_bytes;
    for (auto& entry : entries_) {
      if (kept <= kMaximumKeptBodyBytes) break;
      if (!entry.body_bytes) continue;
      kept -= entry.body_bytes;
      entry.body_bytes = 0;
      for (const char* key : {"requestBody", "responseBody"}) {
        if (entry.value.Remove(key)) entry.value.Set(std::string(key) + "Omitted", true);
      }
    }
  }

  scoped_refptr<content::DevToolsAgentHost> host_;
  bool attached_ = false;
  int next_message_ = 1;
  uint64_t next_id_ = 1;
  uint64_t next_sequence_ = 1;
  std::deque<Entry> entries_;
  std::map<std::string, uint64_t> pending_;
  std::map<int, uint64_t> bodies_;
};

std::map<uint64_t, std::unique_ptr<NetworkCapture>>& Captures() {
  static base::NoDestructor<std::map<uint64_t, std::unique_ptr<NetworkCapture>>> captures;
  return *captures;
}

}  // namespace

bool SensitiveHeader(std::string_view name) {
  const std::string lower = base::ToLowerASCII(name);
  if (lower == "cookie" || lower == "set-cookie" || lower == "set-cookie2" ||
      lower == "authorization" || lower == "proxy-authorization" || lower == "www-authenticate" ||
      lower == "proxy-authenticate")
    return true;
  static constexpr std::array<std::string_view, 9> kParts = {
      "auth", "token", "secret", "session", "cookie", "password", "csrf", "xsrf", "key"};
  for (const auto part : kParts)
    if (lower.find(part) != std::string::npos) return true;
  return false;
}

bool SetNetworkCapture(content::WebContents* contents, uint64_t page, bool enabled) {
  if (!enabled) {
    Captures().erase(page);
    return true;
  }
  if (!contents || contents->GetBrowserContext()->IsOffTheRecord()) return false;
  if (Captures().contains(page)) return true;
  auto capture = std::make_unique<NetworkCapture>(contents);
  if (!capture->Start()) return false;
  Captures()[page] = std::move(capture);
  return true;
}

std::string ReadNetworkCapture(uint64_t page, uint64_t after, uint32_t limit, uint32_t body_bytes) {
  auto found = Captures().find(page);
  if (found == Captures().end()) return std::string();
  return found->second->Read(after, std::clamp<uint32_t>(limit, 1, 200),
                             std::min<uint32_t>(body_bytes, kMaximumBodyBytes));
}

void ForgetNetworkCapture(uint64_t page) {
  Captures().erase(page);
}

void StopNetworkCaptures() {
  std::map<uint64_t, std::unique_ptr<NetworkCapture>> removed;
  Captures().swap(removed);
}

}  // namespace arx
