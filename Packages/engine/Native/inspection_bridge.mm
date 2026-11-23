#include "chrome/browser/arx/inspection_bridge.h"

#include <map>
#include <bit>
#include <cmath>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "base/timer/timer.h"
#include "base/unguessable_token.h"
#include "base/strings/string_util.h"
#include "crypto/hash.h"
#include "chrome/browser/profiles/profile.h"
#include "components/arx_inspection/inspection.mojom.h"
#include "components/arx_inspection/policy.h"
#include "components/arx_inspection/click_policy.h"
#include "components/arx_inspection/pointer_policy.h"
#include "components/arx_inspection/keyboard_policy.h"
#include "chrome/browser/arx/file_chooser_bridge.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/browser/page.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "third_party/blink/public/common/tokens/tokens.h"

namespace arx {
namespace {
using inspection::mojom::Status;
size_t pending_count = 0;
size_t snapshot_count = 0;
size_t physical_click_count = 0;
// One renderer pipe per inspected frame of a page.
constexpr size_t kMaximumFrameRemotes = 16;
inspection::ClickReceipts& ClickReceipts() {
  static base::NoDestructor<inspection::ClickReceipts> receipts;
  return *receipts;
}
void ReplyClickLater(ReferenceClickReply reply, uint64_t request, uint64_t page,
                    int32_t disposition, int32_t status) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
      base::BindOnce(reply, request, page, disposition, status));
}
class Inspection;
std::map<uint64_t, std::unique_ptr<Inspection>>& Pages() {
  static base::NoDestructor<std::map<uint64_t, std::unique_ptr<Inspection>>> pages;
  return *pages;
}

void ReplyLater(InspectionReply reply, uint64_t request, uint64_t page, ArxInspectionStatus status) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
      base::BindOnce(reply, request, page, status, nullptr, 0));
}

ArxInspectionStatus Availability(content::WebContents* contents) {
  if (!contents || contents->IsBeingDestroyed() ||
      contents->GetBrowserContext()->IsOffTheRecord() || contents->IsCrashed())
    return ARX_INSPECTION_UNAVAILABLE;
  auto* frame = contents->GetPrimaryMainFrame();
  if (!frame || !frame->IsRenderFrameLive() || contents->IsLoading()) return ARX_INSPECTION_NOT_READY;
  if (!frame->GetLastCommittedURL().SchemeIsHTTPOrHTTPS() || frame->IsErrorDocument())
    return ARX_INSPECTION_UNSUPPORTED;
  return ARX_INSPECTION_SUCCESS;
}

// ABI25 frames: the primary page's ordinary HTTP(S) frames, never fenced trees.
content::RenderFrameHost* InspectableFrame(content::WebContents* contents, const std::string& frame) {
  auto* main = contents ? contents->GetPrimaryMainFrame() : nullptr;
  if (!main || frame.empty()) return main;
  content::RenderFrameHost* found = nullptr;
  main->ForEachRenderFrameHost([&](content::RenderFrameHost* host) {
    if (!found && host->GetFrameToken().ToString() == frame) found = host;
  });
  if (!found || found->IsFencedFrameRoot() || found->IsNestedWithinFencedFrame() ||
      !found->IsActive() || !found->IsRenderFrameLive() || found->IsErrorDocument() ||
      !found->GetLastCommittedURL().SchemeIsHTTPOrHTTPS() || &found->GetPage() != &main->GetPage())
    return nullptr;
  return found;
}

class Inspection final : public content::WebContentsObserver {
 public:
  Inspection(content::WebContents* contents, uint64_t page)
      : WebContentsObserver(contents), page_(page) {}
  ~Inspection() override {
    Invalidate(ARX_INSPECTION_UNAVAILABLE);
    pending_count -= pending_.size();
    snapshot_count -= snapshots_.size();
    physical_click_count -= clicks_.size();
  }

  void Inspect(uint64_t request, const std::string& scope, const std::string& frame,
               ArxInspectionLimits limits, uint32_t window_start, uint32_t flags,
               InspectionReply reply) {
    auto native = inspection::mojom::Limits::New(limits.maximum_nodes,
        limits.maximum_text_bytes, limits.maximum_references,
        limits.maximum_output_bytes, limits.timeout_ms, window_start,
        (flags & ARX_INSPECTION_FORM_VALUES) != 0, (flags & ARX_INSPECTION_BOUNDS) != 0);
    if (!inspection::ValidLimits(*native) || !inspection::ValidToken(scope) ||
        (flags & ~(ARX_INSPECTION_FORM_VALUES | ARX_INSPECTION_BOUNDS)) ||
        (!frame.empty() && !inspection::ValidToken(frame))) {
      ReplyLater(reply, request, page_, ARX_INSPECTION_INVALID);
      return;
    }
    auto* host = InspectableFrame(web_contents(), frame);
    if (!host) { ReplyLater(reply, request, page_, ARX_INSPECTION_UNSUPPORTED); return; }
    const auto token = host->GetFrameToken().ToString();
    Prune();
    // A newer read of one frame retires that frame's older references only.
    std::vector<std::string> superseded;
    for (const auto& [id, owned] : snapshots_) {
      if (owned.scope == scope && owned.frame == token) superseded.push_back(id);
    }
    for (const auto& id : superseded) Forget(id);
    // Reserve a whole snapshot's maximum handle budget before submitting IPC.
    if (snapshot_count >= inspection::kMaximumSnapshots ||
        snapshots_.size() >= inspection::kMaximumPageSnapshots || !Prepare(request, host)) {
      ReplyLater(reply, request, page_, ARX_INSPECTION_BUSY);
      return;
    }
    const auto snapshot = base::UnguessableToken::Create().ToString();
    snapshots_.emplace(snapshot, Snapshot{scope, host->GetWeakDocumentPtr(), token,
        base::TimeTicks::Now() + base::Seconds(inspection::kReferenceSeconds), false, false});
    ++snapshot_count;
    pending_.emplace(request, Pending{scope, snapshot, token, reply, false, true});
    ++pending_count;
    (*Remote(token))->Inspect(scope, snapshot, std::move(native), base::BindOnce(
        &Inspection::Received, weak_.GetWeakPtr(), request));
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
        base::BindOnce(&Inspection::Timeout, weak_.GetWeakPtr(), request),
        base::Milliseconds(limits.timeout_ms));
    StartExpiry();
  }

  void Validate(uint64_t request, const std::string& scope, const std::string& snapshot,
                 const std::string& reference, InspectionReply reply) {
    if (!inspection::ValidToken(reference) || !Current(scope, snapshot)) {
      ReplyLater(reply, request, page_, ARX_INSPECTION_STALE);
      return;
    }
    const auto frame = snapshots_.at(snapshot).frame;
    if (!Prepare(request, InspectableFrame(web_contents(), frame))) {
      ReplyLater(reply, request, page_, ARX_INSPECTION_BUSY);
      return;
    }
    pending_.emplace(request, Pending{scope, snapshot, frame, reply, false, false});
    ++pending_count;
    (*Remote(frame))->Validate(scope, snapshot, reference, base::BindOnce(
        [](base::WeakPtr<Inspection> owner, uint64_t request, Status status) {
          if (owner) owner->Received(request, status, {});
        }, weak_.GetWeakPtr(), request));
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
        base::BindOnce(&Inspection::Timeout, weak_.GetWeakPtr(), request),
        base::Milliseconds(inspection::kMaximumTimeout));
  }

  void Click(uint64_t request, const std::string& scope, const std::string& snapshot,
             const std::string& reference, const std::string& operation,
             uint32_t timeout_ms, ReferenceClickReply reply) {
    auto* remote = ActionRemote(scope, snapshot);
    if (!remote) {
      ReplyClickLater(reply, request, page_, ARX_CLICK_NOT_DISPATCHED, ARX_CLICK_STALE);
      return;
    }
    if (!clicks_.empty() || physical_click_count >= inspection::kMaximumPhysicalClicks) {
      ReplyClickLater(reply, request, page_, ARX_CLICK_NOT_DISPATCHED, ARX_CLICK_BUSY);
      return;
    }
    clicks_.emplace(request, PendingClick{scope, snapshot, snapshots_.at(snapshot).frame, operation, reply});
    ++physical_click_count;
    ClickReceipts().Record(operation, inspection::Dispatch::kPossible);
    (*remote)->Click(scope, snapshot, reference, operation,
        base::BindOnce(&Inspection::ReceivedClick, weak_.GetWeakPtr(), request));
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
        base::BindOnce(&Inspection::CancelClick, weak_.GetWeakPtr(), request, ARX_CLICK_TIMEOUT),
        base::Milliseconds(timeout_ms));
  }

  void FormAction(uint64_t request, const std::string& scope, const std::string& snapshot,
                  const std::string& reference, const std::string& operation,
                  ArxFormActionKind kind, const std::vector<uint8_t>& payload,
                  uint32_t timeout_ms, ReferenceClickReply reply) {
    auto* remote = ActionRemote(scope, snapshot);
    if (!remote) {
      ReplyClickLater(reply, request, page_, ARX_FORM_NOT_DISPATCHED, ARX_FORM_STALE);
      return;
    }
    if (!clicks_.empty() || physical_click_count >= inspection::kMaximumPhysicalClicks) {
      ReplyClickLater(reply, request, page_, ARX_FORM_NOT_DISPATCHED, ARX_FORM_BUSY);
      return;
    }
    clicks_.emplace(request, PendingClick{scope, snapshot, snapshots_.at(snapshot).frame, operation, reply,
                                          false, ARX_CLICK_POSSIBLY_DISPATCHED, static_cast<uint32_t>(kind)});
    ++physical_click_count;
    ClickReceipts().Record(operation, inspection::Dispatch::kPossible);
    // Real input may open a file chooser the app can then answer (ABI30).
    if (inspection::IsPointerKind(static_cast<uint32_t>(kind)) ||
        inspection::IsKeyboardKind(static_cast<uint32_t>(kind))) ArmFileChooser(page_);
    if (inspection::IsFormStateKind(static_cast<uint32_t>(kind))) {
      (*remote)->FormStateAction(scope, snapshot, reference, operation,
          static_cast<inspection::mojom::FormActionKind>(kind), payload,
          base::BindOnce(&Inspection::ReceivedFormAction, weak_.GetWeakPtr(), request));
    } else if (inspection::IsKeyboardKind(static_cast<uint32_t>(kind))) {
      (*remote)->KeyboardAction(scope, snapshot, reference, operation,
          static_cast<inspection::mojom::FormActionKind>(kind), payload,
          base::BindOnce(&Inspection::ReceivedFormAction, weak_.GetWeakPtr(), request));
    } else if (inspection::IsPointerKind(static_cast<uint32_t>(kind))) {
      (*remote)->PointerAction(scope, snapshot, reference, operation,
          static_cast<inspection::mojom::FormActionKind>(kind), payload,
          base::BindOnce(&Inspection::ReceivedFormAction, weak_.GetWeakPtr(), request));
    } else {
      (*remote)->FormAction(scope, snapshot, reference, operation,
          static_cast<inspection::mojom::FormActionKind>(kind), payload,
          base::BindOnce(&Inspection::ReceivedFormAction, weak_.GetWeakPtr(), request));
    }
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
        base::BindOnce(&Inspection::CancelClick, weak_.GetWeakPtr(), request, ARX_CLICK_TIMEOUT),
        base::Milliseconds(timeout_ms));
  }

  void Scroll(uint64_t request, const std::string& scope, const std::string& snapshot,
                  const std::string& reference, const std::string& operation,
                  ArxScrollAxis axis, double delta_css_pixels,
                  uint32_t timeout_ms, ReferenceClickReply reply) {
    auto* remote = ActionRemote(scope, snapshot);
    if (!remote) {
      ReplyClickLater(reply, request, page_, ARX_SCROLL_NOT_DISPATCHED, ARX_SCROLL_STALE);
      return;
    }
    if (!clicks_.empty() || physical_click_count >= inspection::kMaximumPhysicalClicks) {
      ReplyClickLater(reply, request, page_, ARX_SCROLL_NOT_DISPATCHED, ARX_SCROLL_BUSY);
      return;
    }
    clicks_.emplace(request, PendingClick{scope, snapshot, snapshots_.at(snapshot).frame, operation, reply});
    ++physical_click_count;
    ClickReceipts().Record(operation, inspection::Dispatch::kPossible);
    (*remote)->Scroll(scope, snapshot, reference, operation,
        static_cast<inspection::mojom::ScrollAxis>(axis), delta_css_pixels,
        base::BindOnce(&Inspection::ReceivedScroll, weak_.GetWeakPtr(), request));
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
        base::BindOnce(&Inspection::CancelClick, weak_.GetWeakPtr(), request, ARX_CLICK_TIMEOUT),
        base::Milliseconds(timeout_ms));
  }

  void CancelClick(uint64_t request, ArxClickStatus status = ARX_CLICK_CANCELLED) {
    auto found = clicks_.find(request);
    if (found == clicks_.end() || found->second.replied) return;
    found->second.replied = true;
    // Once submitted to the renderer, cancellation cannot retract an event that
    // may already have run. Preserve a known reply when cancellation races its
    // posted delivery; otherwise return uncertainty and retain physical capacity.
    const auto disposition = found->second.disposition;
    ClickReceipts().Record(found->second.operation, static_cast<inspection::Dispatch>(disposition));
    Forget(found->second.snapshot);
    ReplyClickLater(found->second.reply, request, page_, disposition, status);
  }

  bool Current(const std::string& scope, const std::string& snapshot) {
    Prune();
    auto found = snapshots_.find(snapshot);
    if (found == snapshots_.end() || !found->second.ready || found->second.retired ||
        found->second.scope != scope || Availability(web_contents()) != ARX_INSPECTION_SUCCESS)
      return false;
    auto* host = InspectableFrame(web_contents(), found->second.frame);
    return host && found->second.document.AsRenderFrameHostIfValid() == host;
  }

  void Cancel(uint64_t request, ArxInspectionStatus status = ARX_INSPECTION_CANCELLED) {
    auto found = pending_.find(request);
    if (found == pending_.end() || found->second.replied) return;
    found->second.replied = true;
    Forget(found->second.snapshot);
    ReplyLater(found->second.reply, request, page_, status);
    // Keep physical admission occupied until the renderer returns/disconnects.
  }

  void Revoke(const std::string& scope) {
    for (const auto& [request, click] : clicks_) {
      if (click.scope == scope) CancelClick(request, ARX_CLICK_NOT_AUTHORIZED);
    }
    for (auto& [request, pending] : pending_) {
      if (pending.scope == scope) Cancel(request);
    }
    std::vector<std::string> snapshots;
    for (const auto& [id, snapshot] : snapshots_) {
      if (snapshot.scope == scope) snapshots.push_back(id);
    }
    for (const auto& id : snapshots) Forget(id);
  }

  void DidStartNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsInPrimaryMainFrame()) Invalidate(ARX_INSPECTION_STALE);
  }
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsInPrimaryMainFrame() && navigation->HasCommitted()) {
      Invalidate(ARX_INSPECTION_STALE);
    } else if (navigation->HasCommitted()) {
      // A subframe document replacement retires only that frame's work.
      InvalidateFrames(ARX_INSPECTION_STALE);
    }
  }
  void RenderFrameDeleted(content::RenderFrameHost* host) override {
    InvalidateFrames(ARX_INSPECTION_STALE, host->GetFrameToken().ToString());
  }
  void PrimaryPageWillBeDeactivated(content::Page&) override { Invalidate(ARX_INSPECTION_STALE); }
  // DEV-943: a document entering the back/forward cache keeps its renderer
  // frame and pipe. Retire them as if the frame had gone, so a cached frame
  // never holds this page's frame slots or the shared request capacity, and a
  // restored document starts with a fresh pipe and no snapshots.
  void RenderFrameHostStateChanged(content::RenderFrameHost* host,
                                   content::RenderFrameHost::LifecycleState,
                                   content::RenderFrameHost::LifecycleState state) override {
    if (state != content::RenderFrameHost::LifecycleState::kInBackForwardCache) return;
    const auto token = host->GetFrameToken().ToString();
    if (remotes_.contains(token)) Retire(token, ARX_INSPECTION_STALE);
  }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override { Disconnected(); }
  void WebContentsDestroyed() override { Disconnected(); }

 private:
  struct Snapshot {
    std::string scope;
    content::WeakDocumentPtr document;
    std::string frame;
    base::TimeTicks expires;
    bool ready, retired;
  };
  struct PendingClick {
    std::string scope, snapshot, frame, operation;
    ReferenceClickReply reply;
    bool replied = false;
    int32_t disposition = ARX_CLICK_POSSIBLY_DISPATCHED;
    uint32_t kind = 0;  // ClickBinding kind; decides whether the snapshot is consumed.
  };
  struct Pending {
    std::string scope, snapshot, frame;
    InspectionReply reply;
    bool replied, inspection;
  };
  struct FrameRemote {
    content::WeakDocumentPtr document;
    mojo::AssociatedRemote<inspection::mojom::Inspector> remote;
  };
  mojo::AssociatedRemote<inspection::mojom::Inspector>* Remote(const std::string& frame) {
    auto found = remotes_.find(frame);
    return found == remotes_.end() || !found->second.remote.is_bound() ? nullptr : &found->second.remote;
  }
  mojo::AssociatedRemote<inspection::mojom::Inspector>* ActionRemote(
      const std::string& scope, const std::string& snapshot) {
    if (!Current(scope, snapshot)) return nullptr;
    return Remote(snapshots_.at(snapshot).frame);
  }
  bool FrameBusy(const std::string& frame) const {
    for (const auto& [request, pending] : pending_) if (pending.frame == frame) return true;
    for (const auto& [request, click] : clicks_) if (click.frame == frame) return true;
    return false;
  }
  bool Prepare(uint64_t request, content::RenderFrameHost* host) {
    if (!request || !host || pending_count >= inspection::kMaximumRequests || pending_.contains(request) ||
        Availability(web_contents()) != ARX_INSPECTION_SUCCESS) return false;
    const auto token = host->GetFrameToken().ToString();
    auto found = remotes_.find(token);
    if (found != remotes_.end() && found->second.document.AsRenderFrameHostIfValid() != host) {
      if (FrameBusy(token)) return false;
      remotes_.erase(found);
      found = remotes_.end();
    }
    if (found == remotes_.end()) {
      if (remotes_.size() >= kMaximumFrameRemotes) return false;
      auto& owned = remotes_[token];
      owned.document = host->GetWeakDocumentPtr();
      host->GetRemoteAssociatedInterfaces()->GetInterface(&owned.remote);
      owned.remote.set_disconnect_handler(base::BindOnce(
          &Inspection::FrameDisconnected, weak_.GetWeakPtr(), token));
    }
    return true;
  }
  void StartExpiry() {
    if (!expiry_.IsRunning()) expiry_.Start(FROM_HERE, base::Seconds(1), this, &Inspection::Prune);
  }
  void Prune() {
    std::vector<std::string> expired;
    const auto now = base::TimeTicks::Now();
    for (const auto& [id, snapshot] : snapshots_) {
      if (snapshot.expires <= now) expired.push_back(id);
    }
    for (const auto& id : expired) Forget(id);
    if (snapshots_.empty()) expiry_.Stop();
  }
  void Forget(const std::string& snapshot) {
    auto found = snapshots_.find(snapshot);
    if (found == snapshots_.end()) return;
    auto* remote = Remote(found->second.frame);
    if (!found->second.retired && remote) (*remote)->Forget(snapshot);
    found->second.retired = true;
    for (const auto& [request, pending] : pending_) {
      if (pending.inspection && pending.snapshot == snapshot) {
        // Keep the global handle reservation until physical IPC drainage.
        return;
      }
    }
    snapshots_.erase(found);
    --snapshot_count;
  }
  void Invalidate(ArxInspectionStatus status) {
    const auto click_status = status == ARX_INSPECTION_STALE ? ARX_CLICK_STALE : ARX_CLICK_UNAVAILABLE;
    for (const auto& [request, click] : clicks_) CancelClick(request, click_status);
    for (auto& [request, pending] : pending_) Cancel(request, status);
    std::vector<std::string> snapshots;
    for (const auto& [id, snapshot] : snapshots_) snapshots.push_back(id);
    for (const auto& id : snapshots) Forget(id);
  }
  // Retires work of `frame`, or of every frame whose document is no longer the one it read.
  void InvalidateFrames(ArxInspectionStatus status, const std::string& frame = {}) {
    std::set<std::string> stale;
    for (const auto& [id, snapshot] : snapshots_) {
      auto* host = InspectableFrame(web_contents(), snapshot.frame);
      if (snapshot.frame == frame || !host || snapshot.document.AsRenderFrameHostIfValid() != host)
        stale.insert(id);
    }
    const auto click_status = status == ARX_INSPECTION_STALE ? ARX_CLICK_STALE : ARX_CLICK_UNAVAILABLE;
    for (const auto& [request, click] : clicks_) {
      if (stale.contains(click.snapshot)) CancelClick(request, click_status);
    }
    for (auto& [request, pending] : pending_) {
      if (stale.contains(pending.snapshot)) Cancel(request, status);
    }
    for (const auto& id : stale) Forget(id);
  }
  void FrameDisconnected(const std::string& frame) {
    if (frame == web_contents()->GetPrimaryMainFrame()->GetFrameToken().ToString()) {
      Disconnected();
      return;
    }
    Retire(frame, ARX_INSPECTION_UNAVAILABLE);
  }
  // Ends all work of one frame other than the primary main frame and drops its pipe.
  void Retire(const std::string& frame, ArxInspectionStatus status) {
    InvalidateFrames(status, frame);
    // The pipe is gone: no renderer callback can drain these anymore.
    for (auto it = pending_.begin(); it != pending_.end();) {
      if (it->second.frame != frame) { ++it; continue; }
      const auto snapshot = it->second.snapshot;
      it = pending_.erase(it);
      --pending_count;
      Forget(snapshot);
    }
    for (auto it = clicks_.begin(); it != clicks_.end();) {
      if (it->second.frame != frame) { ++it; continue; }
      it = clicks_.erase(it);
      --physical_click_count;
    }
    for (auto it = snapshots_.begin(); it != snapshots_.end();) {
      if (it->second.frame != frame) { ++it; continue; }
      it = snapshots_.erase(it);
      --snapshot_count;
    }
    remotes_.erase(frame);
  }
  void Disconnected() {
    Invalidate(ARX_INSPECTION_UNAVAILABLE);
    remotes_.clear();
    pending_count -= pending_.size();
    pending_.clear();
    physical_click_count -= clicks_.size();
    clicks_.clear();
    snapshot_count -= snapshots_.size();
    snapshots_.clear();
  }
  void Timeout(uint64_t request) { Cancel(request, ARX_INSPECTION_TIMEOUT); }

  // Child frame tokens from the renderer become the child frames' own IDs, the
  // ones inspect_frame accepts. Unresolvable or ineligible frames lose the field.
  bool ResolveFrames(base::DictValue& value, content::RenderFrameHost* parent) {
    auto* nodes = value.FindList("nodes");
    if (!nodes) return false;
    for (auto& entry : *nodes) {
      auto* node = entry.GetIfDict();
      if (!node) return false;
      const auto* token = node->FindString("frame");
      const auto remote = node->FindBool("frameRemote");
      if (!token) { node->Remove("frameRemote"); continue; }
      content::RenderFrameHost* child = nullptr;
      if (auto parsed = base::UnguessableToken::DeserializeFromString(*token)) {
        const auto process = parent->GetProcess()->GetDeprecatedID();
        child = remote.value_or(false)
            ? content::RenderFrameHost::FromPlaceholderToken(process, blink::RemoteFrameToken(*parsed))
            : content::RenderFrameHost::FromFrameToken(
                  content::GlobalRenderFrameHostToken(process, blink::LocalFrameToken(*parsed)));
      }
      const auto id = child && child->GetParent() == parent
          ? child->GetFrameToken().ToString() : std::string();
      node->Remove("frameRemote");
      if (id.empty() || !InspectableFrame(web_contents(), id)) node->Remove("frame");
      else node->Set("frame", id);
    }
    return true;
  }

  void Received(uint64_t request, Status status, const std::vector<uint8_t>& json) {
    auto found = pending_.find(request);
    if (found == pending_.end()) return;
    if (found->second.replied) {
      const auto snapshot = found->second.snapshot;
      pending_.erase(found);
      --pending_count;
      Forget(snapshot);
      return;
    }
    auto snapshot = snapshots_.find(found->second.snapshot);
    auto* host = snapshot == snapshots_.end() ? nullptr
        : InspectableFrame(web_contents(), snapshot->second.frame);
    ArxInspectionStatus result = static_cast<ArxInspectionStatus>(status);
    if (snapshot == snapshots_.end() || snapshot->second.retired || !host ||
        Availability(web_contents()) != ARX_INSPECTION_SUCCESS ||
        snapshot->second.document.AsRenderFrameHostIfValid() != host)
      result = ARX_INSPECTION_STALE;
    std::vector<uint8_t> output = json;
    if (result == ARX_INSPECTION_SUCCESS && found->second.inspection) {
      if (json.empty() || json.size() > inspection::kMaximumOutputBytes) result = ARX_INSPECTION_LIMIT;
      else {
        auto value = base::JSONReader::ReadDict(std::string_view(
            reinterpret_cast<const char*>(json.data()), json.size()), base::JSON_PARSE_RFC);
        const auto* id = value ? value->FindString("snapshotID") : nullptr;
        const auto* frame = value ? value->FindString("frameID") : nullptr;
        if (!id || *id != found->second.snapshot || !frame || *frame != snapshot->second.frame ||
            !ResolveFrames(*value, host))
          result = ARX_INSPECTION_INVALID;
        else if (auto written = base::WriteJson(*value);
                 !written || written->size() > inspection::kMaximumOutputBytes)
          result = ARX_INSPECTION_LIMIT;
        else {
          output.assign(written->begin(), written->end());
          snapshot->second.ready = true;
        }
      }
    }
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&Inspection::Deliver, weak_.GetWeakPtr(), request, result, std::move(output)));
  }

  void Deliver(uint64_t request, ArxInspectionStatus status, const std::vector<uint8_t>& json) {
    auto found = pending_.find(request);
    if (found == pending_.end()) return;
    if (!found->second.replied && status == ARX_INSPECTION_SUCCESS &&
        !Current(found->second.scope, found->second.snapshot)) status = ARX_INSPECTION_STALE;
    const auto pending = found->second;
    pending_.erase(found);
    --pending_count;
    if (pending.replied) { Forget(pending.snapshot); return; }
    if (status != ARX_INSPECTION_SUCCESS) Forget(pending.snapshot);
    // No use of this after the external callback; Swift can close the page.
    pending.reply(request, page_, status,
        status == ARX_INSPECTION_SUCCESS && pending.inspection ? json.data() : nullptr,
        status == ARX_INSPECTION_SUCCESS && pending.inspection ? json.size() : 0);
  }
  void ReceivedClick(uint64_t request, inspection::mojom::ClickDisposition disposition,
                     inspection::mojom::ClickStatus status) {
    auto found = clicks_.find(request);
    if (found == clicks_.end()) return;
    found->second.disposition = static_cast<ArxClickDisposition>(disposition);
    ClickReceipts().Record(found->second.operation, static_cast<inspection::Dispatch>(disposition));
    // A click may itself navigate or close its document. Never relabel a
    // renderer-confirmed dispatch as not-dispatched just because it did so.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&Inspection::DeliverClick, weak_.GetWeakPtr(), request,
                      static_cast<ArxClickStatus>(status)));
  }
  void ReceivedFormAction(uint64_t request, inspection::mojom::FormDisposition disposition,
                          inspection::mojom::FormStatus status) {
    auto found = clicks_.find(request);
    if (found == clicks_.end()) return;
    found->second.disposition = static_cast<int32_t>(disposition);
    ClickReceipts().Record(found->second.operation, static_cast<inspection::Dispatch>(disposition));
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&Inspection::DeliverClick, weak_.GetWeakPtr(), request,
                      static_cast<int32_t>(status)));
  }
  void ReceivedScroll(uint64_t request, inspection::mojom::ScrollDisposition disposition,
                          inspection::mojom::ScrollStatus status) {
    auto found = clicks_.find(request);
    if (found == clicks_.end()) return;
    found->second.disposition = static_cast<int32_t>(disposition);
    ClickReceipts().Record(found->second.operation, static_cast<inspection::Dispatch>(disposition));
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&Inspection::DeliverClick, weak_.GetWeakPtr(), request,
                      static_cast<int32_t>(status)));
  }
  void DeliverClick(uint64_t request, int32_t status) {
    auto found = clicks_.find(request);
    if (found == clicks_.end()) return;
    const auto pending = found->second;
    clicks_.erase(found);
    --physical_click_count;
    if (pending.replied) return;
    // A consuming action retires its snapshot; the caller inspects the
    // resulting page state for new references. DEV-669: a clean non-consuming
    // action keeps it, and the renderer still checks the DOM version before
    // the next action, so any mutation retires those references.
    if (inspection::ConsumesSnapshot(pending.kind) || status != ARX_FORM_OK ||
        pending.disposition != ARX_FORM_DISPATCHED)
      Forget(pending.snapshot);
    pending.reply(request, page_, pending.disposition, status);
  }

  const uint64_t page_;
  std::map<std::string, FrameRemote> remotes_;
  std::map<std::string, Snapshot> snapshots_;
  std::map<uint64_t, Pending> pending_;
  std::map<uint64_t, PendingClick> clicks_;
  base::RepeatingTimer expiry_;
  base::WeakPtrFactory<Inspection> weak_{this};
};
}  // namespace

void InspectPage(content::WebContents* contents, uint64_t page, uint64_t request,
                 const char* scope, ArxInspectionLimits limits, InspectionReply reply) {
  InspectFrame(contents, page, request, scope, "", {limits, 0, 0}, reply);
}

void InspectFrame(content::WebContents* contents, uint64_t page, uint64_t request,
                  const char* scope, const char* frame, ArxInspectionWindow window,
                  InspectionReply reply) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const auto status = Availability(contents);
  if (status != ARX_INSPECTION_SUCCESS) { ReplyLater(reply, request, page, status); return; }
  auto& owner = Pages()[page];
  if (!owner) owner = std::make_unique<Inspection>(contents, page);
  owner->Inspect(request, scope ? scope : "", frame ? frame : "", window.limits,
                 window.window_start, window.flags, reply);
}

void ValidateInspectionReference(uint64_t page, uint64_t request, const char* scope,
                                 const char* snapshot, const char* reference, InspectionReply reply) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto found = Pages().find(page);
  if (found == Pages().end() || !scope || !snapshot || !reference) {
    ReplyLater(reply, request, page, ARX_INSPECTION_STALE);
    return;
  }
  found->second->Validate(request, scope, snapshot, reference, reply);
}

bool InspectionDocumentIsCurrent(uint64_t page, const char* scope, const char* snapshot) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto found = Pages().find(page);
  return found != Pages().end() && scope && snapshot && found->second->Current(scope, snapshot);
}

void ClickInspectionReference(uint64_t page, uint64_t request, const char* scope,
                              const char* snapshot, const char* reference,
                              const char* operation, uint32_t timeout_ms,
                              ReferenceClickReply reply) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto& receipts = ClickReceipts();
  if (operation && inspection::ValidToken(operation) && receipts.Find(operation)) {
    auto disposition = inspection::Dispatch::kPossible;
    if (scope && snapshot && reference && inspection::ValidToken(scope) &&
        inspection::ValidToken(snapshot) && inspection::ValidToken(reference))
      disposition = receipts.Duplicate(operation, {page, scope, snapshot, reference});
    ReplyClickLater(reply, request, page, static_cast<ArxClickDisposition>(disposition),
                   ARX_CLICK_DUPLICATE);
    return;
  }
  if (!request || !scope || !snapshot || !reference || !operation ||
      !inspection::ValidToken(scope) || !inspection::ValidToken(snapshot) ||
      !inspection::ValidToken(reference) || !inspection::ValidToken(operation) ||
      !timeout_ms || timeout_ms > inspection::kMaximumTimeout) {
    ReplyClickLater(reply, request, page, ARX_CLICK_NOT_DISPATCHED, ARX_CLICK_INVALID);
    return;
  }
  const inspection::ClickBinding binding{page, scope, snapshot, reference};
  if (!receipts.Reserve(operation, binding)) {
    ReplyClickLater(reply, request, page, ARX_CLICK_NOT_DISPATCHED, ARX_CLICK_LIMIT);
    return;
  }
  auto found = Pages().find(page);
  if (found == Pages().end()) {
    ReplyClickLater(reply, request, page, ARX_CLICK_NOT_DISPATCHED, ARX_CLICK_STALE);
    return;
  }
  found->second->Click(request, scope, snapshot, reference, operation, timeout_ms, reply);
}

void PerformInspectionFormAction(uint64_t page, uint64_t request, const char* scope,
                                 const char* snapshot, const char* reference,
                                 const char* operation, ArxFormActionKind kind,
                                 const uint8_t* bytes, size_t length, uint32_t timeout_ms,
                                 ReferenceClickReply reply) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const bool pointer = inspection::IsPointerKind(static_cast<uint32_t>(kind));
  const bool keyboard = inspection::IsKeyboardKind(static_cast<uint32_t>(kind));
  const bool form_state = inspection::IsFormStateKind(static_cast<uint32_t>(kind));
  const bool valid_kind = kind == ARX_FORM_REPLACE_TEXT || kind == ARX_FORM_SELECT_VALUE ||
      kind == ARX_FORM_KEYPRESS || pointer || keyboard || form_state;
  const size_t maximum = kind == ARX_FORM_REPLACE_TEXT ? 32768 : kind == ARX_FORM_KEYPRESS ? 32
      : pointer ? inspection::kMaximumPointerPayload
      : kind == ARX_FORM_TYPE ? inspection::kMaximumTypedBytes
      : kind == ARX_FORM_KEY_CHORD ? inspection::kMaximumKeyChordBytes
      : kind == ARX_FORM_SET_CHECKED ? 1
      : kind == ARX_FORM_SELECT_VALUES ? inspection::kMaximumSelectValuesBytes : 4096;
  const bool bounded_payload = valid_kind && length <= maximum && (bytes || !length);
  const bool valid_binding = scope && snapshot && reference &&
      inspection::ValidToken(scope) && inspection::ValidToken(snapshot) &&
      inspection::ValidToken(reference) && bounded_payload;
  inspection::ClickBinding binding{page, valid_binding ? scope : "",
                                  valid_binding ? snapshot : "", valid_binding ? reference : "",
                                  static_cast<uint32_t>(kind)};
  if (bounded_payload) {
    crypto::hash::Hasher hash(crypto::hash::kSha256);
    hash.Update("Arx.FormActionPayload.v1");
    std::array<uint8_t, 16> prefix{};
    for (size_t i = 0; i < 8; ++i) {
      prefix[i] = static_cast<uint64_t>(kind) >> (i * 8);
      prefix[i + 8] = static_cast<uint64_t>(length) >> (i * 8);
    }
    hash.Update(prefix);
    hash.Update(base::span(bytes, length));
    hash.Finish(binding.payload_digest);
  }
  auto& receipts = ClickReceipts();
  if (operation && inspection::ValidToken(operation) && receipts.Find(operation)) {
    const auto disposition = valid_binding ? receipts.Duplicate(operation, binding)
                                          : inspection::Dispatch::kPossible;
    ReplyClickLater(reply, request, page, static_cast<int32_t>(disposition), ARX_FORM_DUPLICATE);
    return;
  }
  if (!request || !valid_binding || !operation || !inspection::ValidToken(operation) ||
      !timeout_ms || timeout_ms > inspection::kMaximumTimeout) {
    ReplyClickLater(reply, request, page, ARX_FORM_NOT_DISPATCHED,
                   length > maximum ? ARX_FORM_LIMIT : ARX_FORM_INVALID);
    return;
  }
  const std::string_view payload(reinterpret_cast<const char*>(bytes), length);
  inspection::PointerPayload pointer_payload;
  uint32_t chord_modifiers = 0;
  std::string chord_key;
  if (!base::IsStringUTF8(payload) || payload.find('\0') != std::string_view::npos ||
      (pointer && (!inspection::ParsePointerPayload(static_cast<uint32_t>(kind), payload, &pointer_payload) ||
                   pointer_payload.has_point != (std::string_view(reference) == snapshot))) ||
      (kind == ARX_FORM_TYPE && payload.empty()) ||
      (kind == ARX_FORM_SET_CHECKED && payload != "1" && payload != "0") ||
      (kind == ARX_FORM_SELECT_VALUES && (payload.empty() || payload.front() != '[')) ||
      (kind == ARX_FORM_KEY_CHORD && !inspection::ParseKeyChord(payload, &chord_modifiers, &chord_key))) {
    ReplyClickLater(reply, request, page, ARX_FORM_NOT_DISPATCHED, ARX_FORM_INVALID_VALUE);
    return;
  }
  if (!receipts.Reserve(operation, binding)) {
    ReplyClickLater(reply, request, page, ARX_FORM_NOT_DISPATCHED, ARX_FORM_LIMIT);
    return;
  }
  auto found = Pages().find(page);
  if (found == Pages().end()) {
    ReplyClickLater(reply, request, page, ARX_FORM_NOT_DISPATCHED, ARX_FORM_STALE);
    return;
  }
  std::vector<uint8_t> owned;
  if (length) owned.assign(bytes, bytes + length);
  found->second->FormAction(request, scope, snapshot, reference, operation, kind,
                            owned, timeout_ms, reply);
}

void ScrollInspectionReference(uint64_t page, uint64_t request, const char* scope,
                               const char* snapshot, const char* reference,
                               const char* operation, ArxScrollAxis axis,
                               double delta_css_pixels, uint32_t timeout_ms, ReferenceClickReply reply) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const bool valid_delta = (axis == ARX_SCROLL_HORIZONTAL || axis == ARX_SCROLL_VERTICAL) &&
      std::isfinite(delta_css_pixels) && std::abs(delta_css_pixels) <= 8192;
  const bool valid_binding = scope && snapshot && reference &&
      inspection::ValidToken(scope) && inspection::ValidToken(snapshot) &&
      inspection::ValidToken(reference) && valid_delta;
  inspection::ClickBinding binding{page, valid_binding ? scope : "",
      valid_binding ? snapshot : "", valid_binding ? reference : "", 3};
  if (valid_delta) {
    // Canonical numeric payload, shared byte-for-byte with Swift's binding.
    const uint64_t bits = std::bit_cast<uint64_t>(delta_css_pixels == 0 ? 0.0 : delta_css_pixels);
    std::array<uint8_t, 16> payload{};
    for (size_t i = 0; i < 8; ++i) {
      payload[i] = static_cast<uint64_t>(axis) >> (i * 8);
      payload[i + 8] = bits >> (i * 8);
    }
    crypto::hash::Hasher hash(crypto::hash::kSha256);
    hash.Update("Arx.ScrollActionPayload.v1");
    hash.Update(payload);
    hash.Finish(binding.payload_digest);
  }
  auto& receipts = ClickReceipts();
  if (operation && inspection::ValidToken(operation) && receipts.Find(operation)) {
    const auto disposition = valid_binding ? receipts.Duplicate(operation, binding)
                                          : inspection::Dispatch::kPossible;
    ReplyClickLater(reply, request, page, static_cast<int32_t>(disposition), ARX_SCROLL_DUPLICATE);
    return;
  }
  if (!valid_delta) {
    ReplyClickLater(reply, request, page, ARX_SCROLL_NOT_DISPATCHED, ARX_SCROLL_INVALID_DELTA);
    return;
  }
  if (!request || !valid_binding || !operation || !inspection::ValidToken(operation) ||
      !timeout_ms || timeout_ms > inspection::kMaximumTimeout) {
    ReplyClickLater(reply, request, page, ARX_SCROLL_NOT_DISPATCHED, ARX_SCROLL_INVALID);
    return;
  }
  if (!receipts.Reserve(operation, binding)) {
    ReplyClickLater(reply, request, page, ARX_SCROLL_NOT_DISPATCHED, ARX_SCROLL_LIMIT);
    return;
  }
  auto found = Pages().find(page);
  if (found == Pages().end()) {
    ReplyClickLater(reply, request, page, ARX_SCROLL_NOT_DISPATCHED, ARX_SCROLL_STALE);
    return;
  }
  found->second->Scroll(request, scope, snapshot, reference, operation, axis,
                        delta_css_pixels, timeout_ms, reply);
}

void CancelReferenceClick(uint64_t request) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  for (auto& [id, page] : Pages()) page->CancelClick(request);
}

void CancelInspection(uint64_t request) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  for (auto& [id, page] : Pages()) page->Cancel(request);
}
void RevokeInspectionScope(const char* scope) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!scope) return;
  for (auto& [id, page] : Pages()) page->Revoke(scope);
}
void ForgetInspectionPage(uint64_t page) { Pages().erase(page); }
void StopInspections() { Pages().clear(); ClickReceipts().Clear(); }
}  // namespace arx
