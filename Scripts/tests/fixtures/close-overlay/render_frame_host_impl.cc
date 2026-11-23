// Minimal pinned Chromium anchors; overlay tests require exact matching.
#include "content/browser/renderer_host/render_frame_host_impl.h"

namespace content {

void RenderFrameHostImpl::DispatchBeforeUnload(BeforeUnloadType type,
                                               bool is_reload) {

  // In renderer-initiated navigations, don't check for beforeunload in the

        base::BindOnce(&RenderFrameHostManager::BeforeUnloadCompleted,
                       owner_->GetRenderFrameHostManager().GetWeakPtr(),
                       /*proceed=*/true));

void RenderFrameHostImpl::ResetWaitingState() {
  // We don't allow resetting waiting state when the RenderFrameHost is either
  // in BackForwardCache or in pending deletion state, as we don't allow
  // navigations from either of these two states.
  CHECK(!IsInBackForwardCache());
  CHECK(!IsPendingDeletion());

  // Whenever we reset the RFH state, we should not be waiting for beforeunload
  // or close acks.  We clear them here to be safe, since they can cause
  // navigations to be ignored in DidCommitProvisionalLoad.
  if (is_waiting_for_beforeunload_completion_) {
    is_waiting_for_beforeunload_completion_ = false;
    if (beforeunload_timeout_) {
      beforeunload_timeout_->Stop();
    }
    has_shown_beforeunload_dialog_ = false;
    beforeunload_pending_replies_.clear();
  }
  send_before_unload_start_time_ = base::TimeTicks();
  page_close_state_ = PageCloseState::kNotClosing;
}

RenderFrameHostImpl::~RenderFrameHostImpl() {

          [](base::WeakPtr<RenderFrameHostImpl> impl, bool proceed,

            TRACE_EVENT("navigation",
                        "RenderFrameHostImpl::SendBeforeUnload."

          rfh));
}

void RenderFrameHostImpl::ContinueNavigationAfterBeforeUnloadCheck

      base::BindOnce(&RenderFrameHostImpl::ProcessBeforeUnloadCompleted,
                     weak_ptr_factory_.GetWeakPtr(), proceed,
                     /*treat_as_final_completion_callback=*/true,
                     approx_renderer_start_time, base::TimeTicks::Now(),
                     BeforeUnloadExecutionMode::kSync));

      &RenderFrameHostImpl::ProcessBeforeUnloadCompleted, GetWeakPtr(),
      /*proceed=*/true, /*treat_as_final_completion_callback=*/false,
      /*renderer_before_unload_start_time=*/send_before_unload_start_time_,
      /*renderer_before_unload_end_time=*/base::TimeTicks::Now(),
      execution_mode);

         bool showed_dialog) {
        if (!self) {
          return;
        }
        FrameTreeNode* frame = self->frame_tree_node();

      execution_mode == BeforeUnloadExecutionMode::kForLegacy, showed_dialog);

  CHECK(owner_);  // Only active documents are subject to BeforeUnload.
