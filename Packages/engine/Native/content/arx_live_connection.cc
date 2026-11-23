// Copied by Scripts/engine/live_connection_overlay.py to
// content/browser/renderer_host/arx_live_connection.cc.

#include "content/public/browser/arx_live_connection.h"

#include "content/browser/renderer_host/render_frame_host_impl.h"
#include "content/public/browser/web_contents.h"
#include "third_party/blink/public/common/scheduler/web_scheduler_tracked_feature.h"

namespace content {

BASE_FEATURE(kArxSpareLiveConnections, base::FEATURE_ENABLED_BY_DEFAULT);

bool ArxFrameHoldsLiveConnection(RenderFrameHost* frame) {
  if (!frame) {
    return false;
  }
  using Feature = blink::scheduler::WebSchedulerTrackedFeature;
  // A WebSocket is kWebSocket only while DisconnectWebSocketOnBFCache is off;
  // a WebTransport's own kWebTransport never reaches the browser. The sticky
  // features are what Blink reports for both while the document lives.
  constexpr blink::scheduler::WebSchedulerTrackedFeatures kLiveConnections = {
      Feature::kWebSocket, Feature::kWebSocketSticky,
      Feature::kWebTransportSticky};
  return static_cast<RenderFrameHostImpl*>(frame)
      ->GetBackForwardCacheDisablingFeatures()
      .HasAny(kLiveConnections);
}

bool ArxPageHoldsLiveConnection(WebContents* contents) {
  if (!contents || contents->IsBeingDestroyed() ||
      !base::FeatureList::IsEnabled(kArxSpareLiveConnections)) {
    return false;
  }
  RenderFrameHost* main_frame = contents->GetPrimaryMainFrame();
  if (!main_frame) {
    return false;
  }
  bool holds = false;
  main_frame->ForEachRenderFrameHostWithAction([&holds](RenderFrameHost* frame) {
    holds = ArxFrameHoldsLiveConnection(frame);
    return holds ? RenderFrameHost::FrameIterationAction::kStop
                 : RenderFrameHost::FrameIterationAction::kContinue;
  });
  return holds;
}

}  // namespace content
