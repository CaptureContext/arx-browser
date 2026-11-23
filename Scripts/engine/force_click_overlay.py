"""Let Arx take a Force Click on a link before Chromium's Look Up (ABI24).

The page view asks its responder delegate first. When Arx takes the press, the
view skips Look Up, drops the drags of that press so the link isn't dragged,
and releases it with Control held, which Blink never turns into a click. Over
anything that isn't a link, Chromium's behavior is unchanged.

Applied after `gesture_overlay`, whose delegate include it extends.
"""
from .overlay import replace_once

PROTOCOL = "content/public/browser/render_widget_host_view_mac_delegate.h"
VIEW = "content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm"
DELEGATE = "chrome/browser/renderer_host/chrome_render_widget_host_view_mac_delegate.mm"


def patches():
    yield PROTOCOL, "- (BOOL)handleEvent:(NSEvent*)event;", """- (BOOL)handleEvent:(NSEvent*)event;

// Arx: a Force Click at the pointer. YES when the embedder took it; the press
// then skips Look Up and never completes as a click.
- (BOOL)arxHandleForceClick:(NSEvent*)event;"""

    yield VIEW, "@implementation RenderWidgetHostViewCocoa {\n", """@implementation RenderWidgetHostViewCocoa {
  // Arx: the embedder took this press as a Force Click.
  BOOL _arxForceClickTaken;
"""
    yield VIEW, "  _mouseEventWasIgnored = NO;\n", """  _mouseEventWasIgnored = NO;

  // Arx: a taken Force Click must not drag the link or click it on release.
  if (type == NSEventTypeLeftMouseDown)
    _arxForceClickTaken = NO;
  if (_arxForceClickTaken && type == NSEventTypeLeftMouseDragged)
    return;
  const bool arxReleaseTakenPress =
      _arxForceClickTaken && type == NSEventTypeLeftMouseUp;
  if (arxReleaseTakenPress)
    _arxForceClickTaken = NO;
"""
    yield VIEW, """  _lastMouseScreenPosition = event.PositionInScreen();
  _hostHelper->RouteOrProcessMouseEvent(event);
}""", """  // Blink dispatches no click for a left release with Control held.
  if (arxReleaseTakenPress) {
    event.SetModifiers(event.GetModifiers() |
                       blink::WebInputEvent::Modifiers::kControlKey);
  }

  _lastMouseScreenPosition = event.PositionInScreen();
  _hostHelper->RouteOrProcessMouseEvent(event);
}"""
    yield VIEW, """- (void)forceTouchEvent:(NSEvent*)theEvent {
  if (ui::ForceClickInvokesQuickLook())""", """// Arx: offers a pressed Force Click to the embedder once per press. A
// three-finger Look Up tap has no pressed button and is never offered.
- (BOOL)arxTakeForceClick:(NSEvent*)theEvent {
  if (_arxForceClickTaken)
    return YES;
  if (!_hasOpenMouseDown || !(NSEvent.pressedMouseButtons & 1) ||
      ![_responderDelegate respondsToSelector:@selector(arxHandleForceClick:)])
    return NO;
  _arxForceClickTaken = [_responderDelegate arxHandleForceClick:theEvent];
  return _arxForceClickTaken;
}

- (void)forceTouchEvent:(NSEvent*)theEvent {
  if ([self arxTakeForceClick:theEvent])
    return;
  if (ui::ForceClickInvokesQuickLook())"""
    yield VIEW, "- (void)quickLookWithEvent:(NSEvent*)event {\n", """- (void)quickLookWithEvent:(NSEvent*)event {
  if ([self arxTakeForceClick:event])
    return;
"""

    yield DELEGATE, '#include "chrome/browser/arx/gestures/controller.h"', (
        '#include "chrome/browser/arx/gestures/controller.h"\n'
        '#include "chrome/browser/arx/engine_bridge.h"')
    yield DELEGATE, "- (BOOL)handleEvent:(NSEvent*)event {\n", """- (BOOL)arxHandleForceClick:(NSEvent*)event {
  auto* contents = self.webContents;
  return contents && arx::HandleLinkForceClick(contents);
}

- (BOOL)handleEvent:(NSEvent*)event {
"""


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
