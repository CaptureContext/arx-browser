"""Opt-in, identity-bound before-unload completion for Arx-owned primary frames."""

from .overlay import replace_once


MATCH_IMPLEMENTATION = '''bool RenderFrameHostImpl::ArxBeforeUnloadMatches(
    RenderFrameHostImpl* current, base::WeakPtr<RenderFrameHostImpl> original,
    const ArxBeforeUnloadRequest& request) {
  // Untouched Chromium rounds keep their existing behavior. An old unowned
  // ACK may not resolve a new owned round, nor vice versa.
  if (!request && (!current || !current->arx_before_unload_request_)) return true;
  return request && original && current == original.get() &&
      current->arx_before_unload_request_ == request && !request->is_null();
}
'''

FINISH_IMPLEMENTATION = '''void RenderFrameHostImpl::FinishArxBeforeUnload(std::optional<bool> result) {
  auto request = std::move(arx_before_unload_request_);
  if (!request || request->is_null()) return;
  // Clear ownership before posting. Old closures retain this distinct, empty
  // identity, so an allocator cannot recycle it for a newer round.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(std::move(*request), result));
}
'''

START_IMPLEMENTATION = '''bool RenderFrameHostImpl::DispatchBeforeUnloadForArx(ArxBeforeUnloadCallback callback) {
  if (!callback || !owner_ || !IsOutermostMainFrame() ||
      is_waiting_for_beforeunload_completion_ || arx_before_unload_request_) return false;
  DispatchBeforeUnload(BeforeUnloadType::TAB_CLOSE, false, std::move(callback));
  return true;
}
'''


PUBLIC_HEADER = '''// Arx's opt-in before-unload boundary; ordinary Chromium dispatch is unchanged.
#ifndef CONTENT_PUBLIC_BROWSER_ARX_BEFORE_UNLOAD_H_
#define CONTENT_PUBLIC_BROWSER_ARX_BEFORE_UNLOAD_H_

#include <optional>

#include "base/functional/callback_forward.h"
#include "content/common/content_export.h"

namespace content {
class RenderFrameHost;

// Returns false without taking ownership if a round is already pending.
// The callback receives nullopt if its exact round is reset or destroyed.
CONTENT_EXPORT bool DispatchBeforeUnloadForArx(
    RenderFrameHost* frame, base::OnceCallback<void(std::optional<bool>)> callback);
}  // namespace content

#endif  // CONTENT_PUBLIC_BROWSER_ARX_BEFORE_UNLOAD_H_
'''

PUBLIC_IMPLEMENTATION = '''bool DispatchBeforeUnloadForArx(
    RenderFrameHost* frame, base::OnceCallback<void(std::optional<bool>)> callback) {
  return frame && static_cast<RenderFrameHostImpl*>(frame)->DispatchBeforeUnloadForArx(
      std::move(callback));
}

'''


def apply(source):
    header = source / "content/browser/renderer_host/render_frame_host_impl.h"
    implementation = source / "content/browser/renderer_host/render_frame_host_impl.cc"
    replace_once(header,
        "  void DispatchBeforeUnload(BeforeUnloadType type, bool is_reload);",
        '''  // Arx-only opt-in. nullopt means the exact round was reset/destroyed.
  using ArxBeforeUnloadCallback = base::OnceCallback<void(std::optional<bool>)>;
  using ArxBeforeUnloadRequest = std::shared_ptr<ArxBeforeUnloadCallback>;
  bool DispatchBeforeUnloadForArx(ArxBeforeUnloadCallback callback);
  void DispatchBeforeUnload(BeforeUnloadType type, bool is_reload,
                            ArxBeforeUnloadCallback arx_callback = {});''')
    replace_once(header, "  void ResetWaitingState();", '''  void ResetWaitingState();
  static bool ArxBeforeUnloadMatches(RenderFrameHostImpl* current,
      base::WeakPtr<RenderFrameHostImpl> original, const ArxBeforeUnloadRequest& request);
  void FinishArxBeforeUnload(std::optional<bool> result);
  ArxBeforeUnloadRequest arx_before_unload_request_;''')
    replace_once(implementation,
        "void RenderFrameHostImpl::DispatchBeforeUnload(BeforeUnloadType type,\n                                               bool is_reload) {",
        MATCH_IMPLEMENTATION + "\n" + FINISH_IMPLEMENTATION + "\n" + START_IMPLEMENTATION + '''
void RenderFrameHostImpl::DispatchBeforeUnload(BeforeUnloadType type,
                                               bool is_reload,
                                               ArxBeforeUnloadCallback arx_callback) {''')
    replace_once(implementation,
        "  CHECK(owner_);  // Only active documents are subject to BeforeUnload.",
        "  CHECK(owner_);  // Only active documents are subject to BeforeUnload.\n" +
        "  // A new ordinary round must not inherit an owned round's deferred ACK.\n" +
        "  if (!arx_callback && arx_before_unload_request_) ResetWaitingState();")
    replace_once(implementation,
        "  // In renderer-initiated navigations, don't check for beforeunload in the",
        '''  if (arx_callback) {
    CHECK(!arx_before_unload_request_);
    arx_before_unload_request_ = std::make_shared<ArxBeforeUnloadCallback>(std::move(arx_callback));
  }

  // In renderer-initiated navigations, don't check for beforeunload in the''')
    replace_once(implementation,
        '''        base::BindOnce(&RenderFrameHostManager::BeforeUnloadCompleted,
                       owner_->GetRenderFrameHostManager().GetWeakPtr(),
                       /*proceed=*/true));''',
        '''        base::BindOnce([](base::WeakPtr<RenderFrameHostImpl> self,
                          base::WeakPtr<RenderFrameHostManager> manager,
                          ArxBeforeUnloadRequest request) {
          if (!request) {
            // The upstream manager callback survives replacement of an unowned
            // initiating RFH. It still cannot resolve a newer Arx-owned round.
            auto* current = manager ? manager->current_frame_host() : nullptr;
            if (current && current->arx_before_unload_request_) return;
            if (manager) manager->BeforeUnloadCompleted(true);
            return;
          }
          if (!self || !ArxBeforeUnloadMatches(self.get(), self, request)) return;
          self->FinishArxBeforeUnload(true);
        }, GetWeakPtr(), owner_->GetRenderFrameHostManager().GetWeakPtr(), arx_before_unload_request_));''')
    replace_once(implementation,
        "  page_close_state_ = PageCloseState::kNotClosing;\n}",
        "  page_close_state_ = PageCloseState::kNotClosing;\n  FinishArxBeforeUnload(std::nullopt);\n}")
    replace_once(implementation,
        "RenderFrameHostImpl::~RenderFrameHostImpl() {",
        "RenderFrameHostImpl::~RenderFrameHostImpl() {\n  FinishArxBeforeUnload(std::nullopt);")
    # The renderer ACK must carry the initiating frame/round, not rediscover
    # ownership after a reset or a later request on the same surviving RFH.
    replace_once(implementation,
        "          [](base::WeakPtr<RenderFrameHostImpl> impl, bool proceed,",
        "          [](base::WeakPtr<RenderFrameHostImpl> impl,\n             base::WeakPtr<RenderFrameHostImpl> initiator, ArxBeforeUnloadRequest request, bool proceed,")
    replace_once(implementation,
        '''            TRACE_EVENT("navigation",
                        "RenderFrameHostImpl::SendBeforeUnload."''',
        '''            if (!ArxBeforeUnloadMatches(impl->GetBeforeUnloadInitiator(), initiator, request)) return;

            TRACE_EVENT("navigation",
                        "RenderFrameHostImpl::SendBeforeUnload."''')
    replace_once(implementation,
        "          rfh));\n}\n\nvoid RenderFrameHostImpl::ContinueNavigationAfterBeforeUnloadCheck",
        "          rfh, GetWeakPtr(), arx_before_unload_request_));\n}\n\nvoid RenderFrameHostImpl::ContinueNavigationAfterBeforeUnloadCheck")
    replace_once(implementation,
        '''      base::BindOnce(&RenderFrameHostImpl::ProcessBeforeUnloadCompleted,
                     weak_ptr_factory_.GetWeakPtr(), proceed,
                     /*treat_as_final_completion_callback=*/true,
                     approx_renderer_start_time, base::TimeTicks::Now(),
                     BeforeUnloadExecutionMode::kSync));''',
        '''      base::BindOnce([](base::WeakPtr<RenderFrameHostImpl> self,
                        ArxBeforeUnloadRequest request, bool proceed,
                        base::TimeTicks start, base::TimeTicks end) {
        if (!self || !ArxBeforeUnloadMatches(self->GetBeforeUnloadInitiator(), self, request)) return;
        self->ProcessBeforeUnloadCompleted(proceed, true, start, end, BeforeUnloadExecutionMode::kSync);
      }, GetWeakPtr(), arx_before_unload_request_, proceed,
      approx_renderer_start_time, base::TimeTicks::Now()));''')
    replace_once(implementation,
        '''      &RenderFrameHostImpl::ProcessBeforeUnloadCompleted, GetWeakPtr(),
      /*proceed=*/true, /*treat_as_final_completion_callback=*/false,
      /*renderer_before_unload_start_time=*/send_before_unload_start_time_,
      /*renderer_before_unload_end_time=*/base::TimeTicks::Now(),
      execution_mode);''',
        '''      [](base::WeakPtr<RenderFrameHostImpl> self, ArxBeforeUnloadRequest request,
         base::TimeTicks start, base::TimeTicks end, BeforeUnloadExecutionMode mode) {
        if (!self || !ArxBeforeUnloadMatches(self->GetBeforeUnloadInitiator(), self, request)) return;
        self->ProcessBeforeUnloadCompleted(true, false, start, end, mode);
      }, GetWeakPtr(), arx_before_unload_request_, send_before_unload_start_time_,
      base::TimeTicks::Now(), execution_mode);''')
    replace_once(implementation,
        '''         bool showed_dialog) {
        if (!self) {
          return;
        }
        FrameTreeNode* frame = self->frame_tree_node();''',
        '''         bool showed_dialog, ArxBeforeUnloadRequest request) {
        if (!self || !ArxBeforeUnloadMatches(self.get(), self, request)) return;
        if (request) { self->FinishArxBeforeUnload(proceed); return; }
        FrameTreeNode* frame = self->frame_tree_node();''')
    replace_once(implementation,
        "      execution_mode == BeforeUnloadExecutionMode::kForLegacy, showed_dialog);",
        "      execution_mode == BeforeUnloadExecutionMode::kForLegacy, showed_dialog, arx_before_unload_request_);")

    # Keep Arx's native target on content/public/browser. The exported shim avoids
    # widening internal content visibility or changing the public RFH vtable.
    public_directory = source / "content/public/browser"
    public_header = public_directory / "arx_before_unload.h"
    if public_header.exists() and public_header.read_text() != PUBLIC_HEADER:
        raise ValueError(f"Engine overlay anchor changed: {public_header}")
    public_header.write_text(PUBLIC_HEADER)
    public_build = public_directory / "BUILD.gn"
    replace_once(public_build,
        '    "anchor_element_preconnect_delegate.h",',
        '    "anchor_element_preconnect_delegate.h",\n    "arx_before_unload.h",')
    replace_once(implementation,
        '#include "content/browser/renderer_host/render_frame_host_impl.h"',
        '#include "content/browser/renderer_host/render_frame_host_impl.h"\n'
        '#include "content/public/browser/arx_before_unload.h"')
    replace_once(implementation,
        "namespace content {",
        "namespace content {\n\n" + PUBLIC_IMPLEMENTATION)
