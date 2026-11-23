"""Prepare the per-Page macOS history owner against pinned Chromium.

Existing Chrome responder identity is preserved. The isolated native fixture
uses the same controller with browser-owned continuous input points.
"""
from pathlib import Path
import shutil

from .config import PACKAGE
from .overlay import replace_once


CAPTURE = """  virtual std::optional<input::HistoryGestureAck> CaptureHistoryGestureAck(
      const blink::WebGestureEvent& event) { return std::nullopt; }

"""


def apply(source: Path):
    source = Path(source)
    destination = source / "chrome/browser/arx/gestures"
    destination.mkdir(parents=True, exist_ok=True)
    for name in ["ownership.h", "selection.h", "panel.h", "panel.mm",
                 "controller.h", "controller.mm", "fixture.h", "fixture.mm"]:
        shutil.copy2(PACKAGE / "Native/gestures" / name, destination / name)
    shutil.copy2(PACKAGE / "Native/gestures/ack.h",
                 source / "components/input/arx_history_gesture.h")

    event = source / "components/input/event_with_latency_info.h"
    replace_once(event, '#include "base/check_op.h"',
                 '#include "base/check_op.h"\n#include "components/input/arx_history_gesture.h"')
    replace_once(event, "  mutable ui::LatencyInfo latency;", """  mutable ui::LatencyInfo latency;
  std::optional<HistoryGestureAck> arx_history;
""")
    replace_once(event, "    return event.CanCoalesce(other.event);", """    if (arx_history.has_value() != other.arx_history.has_value() ||
        (arx_history && arx_history->identity != other.arx_history->identity))
      return false;
    return event.CanCoalesce(other.event);""")

    queue = source / "components/input/gesture_event_queue.cc"
    replace_once(queue,
                 "    : GestureEventWithLatencyInfo(event.event, event.latency),",
                 "    : GestureEventWithLatencyInfo(std::move(event)),")

    client = source / "components/input/input_router_client.h"
    replace_once(client, "  virtual ~InputRouterClient() = default;\n", "  virtual ~InputRouterClient() = default;\n\n" + CAPTURE)
    delegate = source / "components/input/render_input_router_delegate.h"
    replace_once(delegate, '#include "cc/trees/render_frame_metadata.h"',
                 '#include "cc/trees/render_frame_metadata.h"\n#include "components/input/arx_history_gesture.h"')
    replace_once(delegate, "  virtual ~RenderInputRouterDelegate() = default;\n",
                 "  virtual ~RenderInputRouterDelegate() = default;\n\n" + CAPTURE)
    router_header = source / "components/input/render_input_router.h"
    replace_once(router_header, "  // InputRouterImplClient overrides.\n", """  // InputRouterImplClient overrides.
  std::optional<HistoryGestureAck> CaptureHistoryGestureAck(
      const blink::WebGestureEvent& event) override;
""")
    router = source / "components/input/render_input_router.cc"
    replace_once(router, "void RenderInputRouter::DidOverscroll(", """std::optional<HistoryGestureAck> RenderInputRouter::CaptureHistoryGestureAck(
    const blink::WebGestureEvent& event) {
  return delegate_->CaptureHistoryGestureAck(event);
}

void RenderInputRouter::DidOverscroll(""")
    input_router = source / "components/input/input_router_impl.cc"
    replace_once(input_router, "  GestureEventWithLatencyInfo gesture_event(original_gesture_event);", """  GestureEventWithLatencyInfo gesture_event(original_gesture_event);
  // Capture before debounce/coalescing/deferral, never on a delayed ACK.
  if (!gesture_event.arx_history)
    gesture_event.arx_history = client_->CaptureHistoryGestureAck(gesture_event.event);""")
    replace_once(input_router, """  if (overscroll) {
    DCHECK_EQ(WebInputEvent::Type::kGestureScrollUpdate,
              gesture_event.event.GetType());
    DidOverscroll(std::move(overscroll));
  }

  // |gesture_event_queue_| will forward to OnGestureEventAck when appropriate.
  gesture_event_queue_.ProcessGestureAck(""", """  if (overscroll) {
    DCHECK_EQ(WebInputEvent::Type::kGestureScrollUpdate,
              gesture_event.event.GetType());
  }

  // The reply closure retains the exact browser-local dispatch identity and
  // its own renderer overscroll result. Legacy untagged callbacks stay intact.
  if (gesture_event.arx_history && gesture_event.arx_history->callback) {
    auto alive = weak_this_;
    gesture_event.arx_history->callback.Run(
        source != blink::mojom::InputEventResultSource::kBrowser,
        state == blink::mojom::InputEventResultState::kConsumed,
        overscroll ? std::optional<bool>(overscroll->overscroll_behavior.PropagatesXScroll())
                   : std::nullopt);
    if (!alive) return;
  }
  if (overscroll) DidOverscroll(std::move(overscroll));

  // |gesture_event_queue_| will forward to OnGestureEventAck when appropriate.
  gesture_event_queue_.ProcessGestureAck(""")

    host = source / "content/public/browser/render_widget_host.h"
    replace_once(host, '#include "components/input/input_event_source.h"',
                 '#include "components/input/input_event_source.h"\n#include "components/input/arx_history_gesture.h"')
    replace_once(host, "    virtual ~InputEventObserver() = default;\n", """    virtual ~InputEventObserver() = default;
    virtual std::optional<input::HistoryGestureAck> CaptureHistoryGestureAck(
        const RenderWidgetHost& host, const blink::WebGestureEvent& event) {
      return std::nullopt;
    }
""")
    host_header = source / "content/browser/renderer_host/render_widget_host_impl.h"
    replace_once(host_header, "  bool PreHandleGestureEvent(const blink::WebGestureEvent& event) override;", """  std::optional<input::HistoryGestureAck> CaptureHistoryGestureAck(
      const blink::WebGestureEvent& event) override;
  bool PreHandleGestureEvent(const blink::WebGestureEvent& event) override;""")
    host_impl = source / "content/browser/renderer_host/render_widget_host_impl.cc"
    readiness = source / "content/public/browser/arx_gesture_fixture.h"
    readiness.write_text("""// Read-only input readiness for Arx's owned native gesture fixture.
#ifndef CONTENT_PUBLIC_BROWSER_ARX_GESTURE_FIXTURE_H_
#define CONTENT_PUBLIC_BROWSER_ARX_GESTURE_FIXTURE_H_
#include "content/common/content_export.h"
namespace content {
class RenderWidgetHost;
// Paint/visual completion does not imply browser input paint-holding ended.
// Observes the real router only; never activates it or changes admission.
CONTENT_EXPORT bool IsInputRouterActiveForArxGestureFixture(RenderWidgetHost* host);
}  // namespace content
#endif
""")
    public_build = source / "content/public/browser/BUILD.gn"
    replace_once(public_build, '    "render_widget_host.h",',
                 '    "render_widget_host.h",\n    "arx_gesture_fixture.h",')
    replace_once(host_impl,
        '#include "content/browser/renderer_host/render_widget_host_impl.h"',
        '#include "content/browser/renderer_host/render_widget_host_impl.h"\n'
        '#include "content/public/browser/arx_gesture_fixture.h"')

    replace_once(host_impl, "bool RenderWidgetHostImpl::PreHandleGestureEvent(", """std::optional<input::HistoryGestureAck> RenderWidgetHostImpl::CaptureHistoryGestureAck(
    const blink::WebGestureEvent& event) {
  std::optional<input::HistoryGestureAck> owner;
  for (auto& observer : input_event_observers_) {
    auto candidate = observer.CaptureHistoryGestureAck(*this, event);
    if (!candidate) continue;
    if (owner) return std::nullopt;  // Conflicting owners fail closed.
    owner = std::move(candidate);
  }
  return owner;
}

bool RenderWidgetHostImpl::PreHandleGestureEvent(""")

    replace_once(host_impl,
        "std::optional<input::HistoryGestureAck> RenderWidgetHostImpl::CaptureHistoryGestureAck(",
        """bool IsInputRouterActiveForArxGestureFixture(RenderWidgetHost* host) {
  auto* implementation = host ? RenderWidgetHostImpl::From(host) : nullptr;
  return implementation && implementation->input_router() &&
      implementation->input_router()->IsActive();
}

std::optional<input::HistoryGestureAck> RenderWidgetHostImpl::CaptureHistoryGestureAck(""")

    chrome = source / "chrome/browser/renderer_host/chrome_render_widget_host_view_mac_delegate.mm"
    replace_once(chrome, '#include "base/strings/sys_string_conversions.h"',
                 '#include "base/strings/sys_string_conversions.h"\n'
                 '#include "chrome/browser/arx/gestures/controller.h"')
    replace_once(chrome, """- (BOOL)handleEvent:(NSEvent*)event {
  return [_historySwiper handleEvent:event];
}""", """- (BOOL)handleEvent:(NSEvent*)event {
  auto* contents = self.webContents;
  if (auto* owner = contents ? arx::gestures::Controller::FromWebContents(contents) : nullptr) {
    if (owner->HandleEvent(event)) return YES;
    if (owner->BlocksChromeHistory()) {
      // Let the existing swiper reset its recognition state at the boundary;
      // ownership still prevents its pending -> potential transition.
      if (event.type == NSEventTypeScrollWheel && event.phase == NSEventPhaseBegan)
        [_historySwiper handleEvent:event];
      return NO;
    }
  }
  return [_historySwiper handleEvent:event];
}""")
    for phase, call in [("Began", "TouchesBegan(event, self.nsView)"),
                        ("Moved", "TouchesMoved(event)"),
                        ("Cancelled", "TouchesEnded(event, true)"),
                        ("Ended", "TouchesEnded(event, false)")]:
        old = f"- (void)touches{phase}WithEvent:(NSEvent*)event {{\n"
        keep_alive = (
            "  [[maybe_unused]] __attribute__((objc_precise_lifetime))\n"
            "      ChromeRenderWidgetHostViewMacDelegate* keepAlive = self;\n"
            if phase == "Ended" else ""
        )
        new = old + keep_alive + (
            "  if (self.webContents) {\n"
            "    if (auto* owner = arx::gestures::Controller::FromWebContents(self.webContents))\n"
            f"      owner->{call};\n"
            "  }\n"
        )
        replace_once(chrome, old, new)
    replace_once(chrome, "  return !swiping_control || swiping_control->ShouldAllowHistorySwiping();", """  auto* owner = arx::gestures::Controller::FromWebContents(webContents);
  return (!swiping_control || swiping_control->ShouldAllowHistorySwiping()) &&
         (!owner || !owner->BlocksChromeHistory());""")

    build = source / "chrome/browser/arx/BUILD.gn"
    replace_once(build, '    "close_authority.h",', '    "close_authority.h",\n    "gestures/ownership.h",\n    "gestures/selection.h",\n    "gestures/panel.h",\n    "gestures/panel.mm",\n    "gestures/controller.h",\n    "gestures/controller.mm",\n    "gestures/fixture.h",\n    "gestures/fixture.mm",')
    replace_once(build, '    "//components/arx_inspection:mojom",',
                 '    "//components/arx_inspection:mojom",\n'
                 '    "//chrome/browser/renderer_host:history_swiping_control",\n'
                 '    "//chrome/browser/ui/cocoa",\n'
                 '    "//components/input",\n'
                 '    "//ui/events",')
    renderer_build = source / "chrome/browser/renderer_host/BUILD.gn"
    replace_once(renderer_build,
                 '    sources = [ "chrome_render_widget_host_view_mac_delegate.mm" ]\n    deps = [',
                 '    sources = [ "chrome_render_widget_host_view_mac_delegate.mm" ]\n    deps = [\n'
                 '      "//chrome/browser/arx",')
    build = source / "components/input/BUILD.gn"
    replace_once(build, '    "event_with_latency_info.h",',
                 '    "event_with_latency_info.h",\n    "arx_history_gesture.h",')
