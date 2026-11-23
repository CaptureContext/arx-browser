// Arx (DEV-825, DEV-852). Copied to chrome/browser/ui/views/overlay by
// Scripts/engine/pip_overlay.py.

#import "chrome/browser/ui/views/overlay/arx_pip_window_motion.h"

#import <QuartzCore/QuartzCore.h>

#include <cmath>
#include <cstdlib>
#include <vector>

#include "chrome/browser/ui/views/overlay/arx_pip_motion.h"

namespace {

arx_pip::Rect ToRect(NSRect rect) {
  return {NSMinX(rect), NSMinY(rect), NSWidth(rect), NSHeight(rect)};
}

NSRect ToNSRect(arx_pip::Rect rect) {
  return NSMakeRect(rect.x, rect.y, rect.width, rect.height);
}

arx_pip::Point ToPoint(NSPoint point) {
  return {point.x, point.y};
}

// AppKit reports an unbounded content size as CGFLOAT_MAX; the math wants 0.
arx_pip::Size ToLimit(NSSize size) {
  constexpr CGFloat kUnbounded = 1e7;
  return {
      size.width >= kUnbounded ? 0 : size.width,
      size.height >= kUnbounded ? 0 : size.height,
  };
}

std::vector<arx_pip::Rect> VisibleFrames() {
  std::vector<arx_pip::Rect> frames;
  for (NSScreen* screen in NSScreen.screens) {
    frames.push_back(ToRect(screen.visibleFrame));
  }
  return frames;
}

// The screen holding most of `window`, else the one nearest its centre. Not
// NSScreen.mainScreen, which is the key window's screen (DEV-852).
NSScreen* NearestScreen(NSWindow* window) {
  if (window.screen) {
    return window.screen;
  }
  NSArray<NSScreen*>* screens = NSScreen.screens;
  const std::vector<arx_pip::Rect> areas = VisibleFrames();
  const int index =
      arx_pip::AreaIndex(areas, ToRect(window.frame).Center());
  return index >= 0 && static_cast<NSUInteger>(index) < screens.count
             ? screens[static_cast<NSUInteger>(index)]
             : nil;
}

NSRect VisibleFrame(NSWindow* window) {
  NSScreen* screen = NearestScreen(window);
  return screen ? screen.visibleFrame : NSZeroRect;
}

CGDirectDisplayID DisplayID(NSScreen* screen) {
  NSNumber* number = screen.deviceDescription[@"NSScreenNumber"];
  return number ? number.unsignedIntValue : kCGNullDirectDisplay;
}

// The index in NSScreen.screens of display `display`, or -1.
int ScreenIndex(CGDirectDisplayID display) {
  if (display == kCGNullDirectDisplay) {
    return -1;
  }
  NSArray<NSScreen*>* screens = NSScreen.screens;
  for (NSUInteger index = 0; index < screens.count; ++index) {
    if (DisplayID(screens[index]) == display) {
      return static_cast<int>(index);
    }
  }
  return -1;
}

// Lets the window join every Space, other apps' full-screen ones included,
// before Chromium first orders it in: AppKit settles a window's Spaces only
// when it's ordered in, and ordering it out again ends Picture in Picture
// (DEV-852). VideoOverlayWindowViews also gives it activation independence,
// so it behaves as a non-activating panel, as Chromium's floating Glic window
// does.
void JoinAllSpaces(NSWindow* window) {
  NSWindowCollectionBehavior behavior = window.collectionBehavior;
  // Each excludes canJoinAllSpaces or canJoinAllApplications.
  behavior &= ~(NSWindowCollectionBehaviorMoveToActiveSpace |
                NSWindowCollectionBehaviorPrimary |
                NSWindowCollectionBehaviorAuxiliary |
                NSWindowCollectionBehaviorFullScreenPrimary |
                NSWindowCollectionBehaviorFullScreenNone);
  behavior |= NSWindowCollectionBehaviorCanJoinAllSpaces |
              NSWindowCollectionBehaviorFullScreenAuxiliary |
              NSWindowCollectionBehaviorCanJoinAllApplications;
  window.collectionBehavior = behavior;
  window.hidesOnDeactivate = NO;
}

bool SameOrigin(NSRect a, NSRect b) {
  return std::abs(NSMinX(a) - NSMinX(b)) < 0.5 &&
         std::abs(NSMinY(a) - NSMinY(b)) < 0.5;
}

bool SameSize(NSRect a, NSRect b) {
  return std::abs(NSWidth(a) - NSWidth(b)) < 0.5 &&
         std::abs(NSHeight(a) - NSHeight(b)) < 0.5;
}

bool SameFrame(NSRect a, NSRect b) {
  return SameOrigin(a, b) && SameSize(a, b);
}

}  // namespace

@implementation ArxPiPWindowMotion {
  __weak NSWindow* _window;
  BOOL (^_isDraggableBackground)(NSPoint);
  id _localMonitor;
  id _globalMonitor;
  id _screenObserver;
  // The media smoke's observers (DEV-852).
  NSArray<id>* _smokeObservers;

  // A press-drag on the video: the pointer's offset from the window origin.
  BOOL _dragging;
  NSPoint _grabOffset;
  // A two-finger trackpad drag and a pinch in progress.
  BOOL _scrolling;
  BOOL _pinching;
  // Window origins during a drag, for the release velocity.
  std::vector<arx_pip::Sample> _samples;
  // The frame when the last press on the window began, to tell Chromium's
  // edge resize from a click, and whether that press stopped a settle.
  NSRect _frameAtPress;
  BOOL _interruptedAtPress;

  // The settle in flight, driven by the target screen's display link.
  CADisplayLink* _displayLink;
  arx_pip::Settler _settler;
  // Where the window rests, or is settling: the display and its corner, so a
  // display change keeps both (DEV-852).
  CGDirectDisplayID _restDisplay;
  int _restCorner;
  // A re-snap after a display change is waiting for the next turn.
  BOOL _resnapScheduled;
}

- (instancetype)initWithWindow:(NSWindow*)window
         isDraggableBackground:(BOOL (^)(NSPoint))isDraggableBackground {
  if ((self = [super init])) {
    _window = window;
    _isDraggableBackground = [isDraggableBackground copy];
    _frameAtPress = NSZeroRect;
    _restDisplay = kCGNullDirectDisplay;
    _restCorner = -1;
    JoinAllSpaces(window);

    __weak ArxPiPWindowMotion* weakSelf = self;
    _localMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown |
                                             NSEventMaskLeftMouseDragged |
                                             NSEventMaskLeftMouseUp |
                                             NSEventMaskScrollWheel |
                                             NSEventMaskMagnify
                                     handler:^NSEvent*(NSEvent* event) {
                                       ArxPiPWindowMotion* motion = weakSelf;
                                       return motion ? [motion handleEvent:event]
                                                     : event;
                                     }];
    // Pinches that AppKit routes elsewhere while Arx isn't active.
    _globalMonitor = [NSEvent
        addGlobalMonitorForEventsMatchingMask:NSEventMaskMagnify
                                      handler:^(NSEvent* event) {
                                        [weakSelf handleEvent:event];
                                      }];

    // Displays coming, going, rearranging or changing resolution, and the
    // Dock or menu bar moving: back to the same corner (DEV-852).
    _screenObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSApplicationDidChangeScreenParametersNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification*) {
                  [weakSelf scheduleResnap];
                }];

    [self observeSmokeChecks];

    // Chromium attaches the content view after the window is initialized.
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf applyCorners];
    });
  }
  return self;
}

- (void)invalidate {
  [self stopSettling];
  if (_localMonitor) {
    [NSEvent removeMonitor:_localMonitor];
    _localMonitor = nil;
  }
  if (_globalMonitor) {
    [NSEvent removeMonitor:_globalMonitor];
    _globalMonitor = nil;
  }
  if (_screenObserver) {
    [NSNotificationCenter.defaultCenter removeObserver:_screenObserver];
    _screenObserver = nil;
  }
  for (id observer in _smokeObservers) {
    [NSNotificationCenter.defaultCenter removeObserver:observer];
  }
  _smokeObservers = nil;
  _timeLabelsFit = nil;
  _isDraggableBackground = nil;
  _dragging = NO;
  _scrolling = NO;
  _pinching = NO;
}

- (void)dealloc {
  [self invalidate];
}

#pragma mark - Smoke checks

- (void)observeSmokeChecks {
  const char* root = std::getenv("ARX_MEDIA_SMOKE_ROOT");
  if (!root || !*root) {
    return;
  }
  NSWindow* window = _window;
  __weak ArxPiPWindowMotion* weakSelf = self;
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  id release = [center
      addObserverForName:@"ArxPiPSmokeRelease"
                  object:window
                   queue:nil
              usingBlock:^(NSNotification* note) {
                ArxPiPWindowMotion* motion = weakSelf;
                NSMutableDictionary* reply = note.userInfo[@"reply"];
                if (!motion || ![reply isKindOfClass:NSMutableDictionary.class]) {
                  return;
                }
                const arx_pip::Point velocity{
                    [note.userInfo[@"x"] doubleValue],
                    [note.userInfo[@"y"] doubleValue]};
                [motion releaseWithVelocity:velocity];
                reply[@"handled"] = @YES;
              }];
  id labels = [center
      addObserverForName:@"ArxPiPSmokeTimeLabels"
                  object:window
                   queue:nil
              usingBlock:^(NSNotification* note) {
                ArxPiPWindowMotion* motion = weakSelf;
                NSMutableDictionary* reply = note.userInfo[@"reply"];
                NSArray* times = note.userInfo[@"times"];
                if (!motion || !motion.timeLabelsFit ||
                    ![reply isKindOfClass:NSMutableDictionary.class] ||
                    ![times isKindOfClass:NSArray.class]) {
                  return;
                }
                BOOL fits = YES;
                for (NSArray* pair in times) {
                  if (![pair isKindOfClass:NSArray.class] || pair.count != 2) {
                    return;
                  }
                  fits = motion.timeLabelsFit([pair[0] doubleValue],
                                              [pair[1] doubleValue]) &&
                         fits;
                }
                reply[@"fits"] = @(fits);
              }];
  id rest = [center
      addObserverForName:@"ArxPiPSmokeRest"
                  object:window
                   queue:nil
              usingBlock:^(NSNotification* note) {
                ArxPiPWindowMotion* motion = weakSelf;
                NSMutableDictionary* reply = note.userInfo[@"reply"];
                if (!motion || ![reply isKindOfClass:NSMutableDictionary.class]) {
                  return;
                }
                reply[@"display"] = @(motion->_restCorner >= 0
                                          ? static_cast<int64_t>(
                                                motion->_restDisplay)
                                          : -1);
                reply[@"corner"] = @(motion->_restCorner);
              }];
  _smokeObservers = @[ release, labels, rest ];
}

#pragma mark - Corners

- (void)applyCorners {
  NSWindow* window = _window;
  NSView* content = window.contentView;
  if (!content) {
    return;
  }
  content.wantsLayer = YES;
  content.layer.cornerRadius = arx_pip::kCornerRadius;
  content.layer.cornerCurve = kCACornerCurveContinuous;
  content.layer.masksToBounds = YES;
  // The shadow follows the rounded content.
  window.hasShadow = YES;
  [window invalidateShadow];
}

#pragma mark - Events

- (BOOL)isPointerOverWindow:(NSWindow*)window event:(NSEvent*)event {
  return event.window == window ||
         NSPointInRect(NSEvent.mouseLocation, window.frame);
}

- (NSEvent*)handleEvent:(NSEvent*)event {
  NSWindow* window = _window;
  if (!window || !window.visible || !_isDraggableBackground) {
    return event;
  }
  switch (event.type) {
    case NSEventTypeLeftMouseDown:
      return [self mouseDown:event window:window];
    case NSEventTypeLeftMouseDragged:
      return [self mouseDragged:event window:window];
    case NSEventTypeLeftMouseUp:
      return [self mouseUp:event window:window];
    case NSEventTypeScrollWheel:
      return [self scroll:event window:window];
    case NSEventTypeMagnify:
      return [self magnify:event window:window];
    default:
      return event;
  }
}

- (NSEvent*)mouseDown:(NSEvent*)event window:(NSWindow*)window {
  if (event.window != window) {
    return event;
  }
  _frameAtPress = window.frame;
  // Any press on a settling window stops it where it is: a grab, an edge
  // resize, or a click on a control. Release settles it again.
  _interruptedAtPress = _displayLink != nil;
  [self stopSettling];
  if (!_isDraggableBackground(event.locationInWindow)) {
    return event;
  }
  const NSPoint pointer = NSEvent.mouseLocation;
  const NSPoint origin = window.frame.origin;
  _grabOffset = NSMakePoint(pointer.x - origin.x, pointer.y - origin.y);
  _dragging = YES;
  _samples.clear();
  [self sample:event window:window];
  // Taken from Chromium, which would start a native window drag instead.
  return nil;
}

- (NSEvent*)mouseDragged:(NSEvent*)event window:(NSWindow*)window {
  if (!_dragging) {
    return event;
  }
  const NSPoint pointer = NSEvent.mouseLocation;
  [window setFrameOrigin:NSMakePoint(pointer.x - _grabOffset.x,
                                     pointer.y - _grabOffset.y)];
  [self sample:event window:window];
  return nil;
}

- (NSEvent*)mouseUp:(NSEvent*)event window:(NSWindow*)window {
  if (_dragging) {
    _dragging = NO;
    [self sample:event window:window];
    [self releaseWithVelocity:arx_pip::Velocity(_samples, event.timestamp)];
    return nil;
  }
  if (event.window == window && !NSIsEmptyRect(_frameAtPress)) {
    // After Chromium's edge resize, or a press that stopped a settle, settle
    // once the frame is final. A plain click on a control of a resting window
    // leaves it alone.
    __weak ArxPiPWindowMotion* weakSelf = self;
    const NSRect before = _frameAtPress;
    const BOOL interrupted = _interruptedAtPress;
    dispatch_async(dispatch_get_main_queue(), ^{
      ArxPiPWindowMotion* motion = weakSelf;
      NSWindow* settled = motion ? motion->_window : nil;
      if (settled && (interrupted || !SameFrame(before, settled.frame))) {
        [motion settleWithVelocity:arx_pip::Point()];
      }
    });
  }
  _frameAtPress = NSZeroRect;
  _interruptedAtPress = NO;
  return event;
}

- (NSEvent*)scroll:(NSEvent*)event window:(NSWindow*)window {
  if (!_scrolling && ![self isPointerOverWindow:window event:event]) {
    return event;
  }
  // A mouse wheel and momentum after lifting the fingers do nothing over the
  // window; the throw already carries the momentum.
  if (!event.hasPreciseScrollingDeltas ||
      event.momentumPhase != NSEventPhaseNone) {
    return nil;
  }
  const NSEventPhase phase = event.phase;
  if (phase & (NSEventPhaseMayBegin | NSEventPhaseBegan)) {
    [self stopSettling];
    _scrolling = YES;
    _samples.clear();
  }
  if (phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) {
    if (_scrolling) {
      _scrolling = NO;
      [self sample:event window:window];
      [self releaseWithVelocity:arx_pip::Velocity(_samples, event.timestamp)];
    }
    return nil;
  }
  if (phase == NSEventPhaseNone) {
    // Precise scrolling without phases (some mice) has no end to settle on,
    // so it doesn't move the window.
    return nil;
  }
  if (!_scrolling) {
    // A gesture that began elsewhere and slid over the window.
    return event;
  }
  // The window moves under the fingers, but never off every screen
  // (DEV-852).
  const CGFloat direction = event.isDirectionInvertedFromDevice ? 1 : -1;
  arx_pip::Rect frame = ToRect(window.frame);
  frame.x += direction * event.scrollingDeltaX;
  frame.y -= direction * event.scrollingDeltaY;
  frame = arx_pip::KeptOnScreen(VisibleFrames(), frame);
  [window setFrameOrigin:NSMakePoint(frame.x, frame.y)];
  [self sample:event window:window];
  return nil;
}

- (NSEvent*)magnify:(NSEvent*)event window:(NSWindow*)window {
  if (!_pinching && ![self isPointerOverWindow:window event:event]) {
    return event;
  }
  const NSEventPhase phase = event.phase;
  if (phase & (NSEventPhaseMayBegin | NSEventPhaseBegan)) {
    [self stopSettling];
    _pinching = YES;
  }
  if (!(phase & (NSEventPhaseEnded | NSEventPhaseCancelled))) {
    [self stopSettling];
    const arx_pip::Rect scaled = arx_pip::ScaledFrame(
        ToRect(window.frame), 1 + event.magnification,
        ToPoint(NSEvent.mouseLocation), ToLimit(window.contentMinSize),
        ToLimit(window.contentMaxSize));
    const arx_pip::Rect frame =
        arx_pip::ConstrainedFrame(scaled, ToRect(VisibleFrame(window)));
    [window setFrame:ToNSRect(frame) display:YES];
  }
  if ((phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) ||
      phase == NSEventPhaseNone) {
    _pinching = NO;
    [self settleWithVelocity:arx_pip::Point()];
  }
  return nil;
}

- (void)sample:(NSEvent*)event window:(NSWindow*)window {
  _samples.push_back({event.timestamp, ToPoint(window.frame.origin)});
  // Only the last tenth of a second counts; keep a little more.
  while (_samples.size() > 64) {
    _samples.erase(_samples.begin());
  }
}

#pragma mark - Settling

// A drag or two-finger move ended: settle with its velocity, unless the
// window is off every screen, which snaps it straight to the nearest corner
// (DEV-852).
- (void)releaseWithVelocity:(arx_pip::Point)velocity {
  NSWindow* window = _window;
  if (window && !window.screen) {
    [self snapToNearestCorner];
    return;
  }
  [self settleWithVelocity:velocity];
}

- (void)settleWithVelocity:(arx_pip::Point)velocity {
  NSWindow* window = _window;
  if (!window) {
    return;
  }
  // The resting corner on the screen the throw lands on, and the size the
  // window takes there: its aspect ratio within Chromium's limits for that
  // screen, so Chromium needn't resize it.
  const arx_pip::SnapTarget snap =
      arx_pip::Snap(VisibleFrames(), ToRect(window.frame), velocity,
                    ToLimit(window.contentMinSize));
  [self settleOnto:snap velocity:velocity];
}

- (void)settleOnto:(arx_pip::SnapTarget)snap velocity:(arx_pip::Point)velocity {
  NSWindow* window = _window;
  [self stopSettling];
  NSArray<NSScreen*>* screens = NSScreen.screens;
  if (!window || snap.area_index < 0 ||
      static_cast<NSUInteger>(snap.area_index) >= screens.count) {
    return;
  }
  NSScreen* screen = screens[static_cast<NSUInteger>(snap.area_index)];
  _restDisplay = DisplayID(screen);
  _restCorner = snap.corner;
  const arx_pip::Settle settle = arx_pip::SettleFor(
      NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion);
  _settler = arx_pip::Settler(
      snap, settle.spring, ToRect(window.frame),
      settle.carries_velocity ? velocity : arx_pip::Point(),
      CACurrentMediaTime());
  // The target screen's display link, not the window's: the window's stops
  // firing once no part of the window is on any display, which used to leave
  // a hard throw stranded off screen (DEV-852).
  if (@available(macOS 14.0, *)) {
    _displayLink = [screen displayLinkWithTarget:self
                                        selector:@selector(step:)];
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop
                       forMode:NSRunLoopCommonModes];
  } else {
    [self restAt:snap window:window];
  }
}

// Puts the window at the corner nearest it, on the nearest screen, at once.
// The safety net for anything that leaves it off screen or between corners
// (DEV-852).
- (void)snapToNearestCorner {
  NSWindow* window = _window;
  [self stopSettling];
  if (!window) {
    return;
  }
  const std::vector<arx_pip::Rect> areas = VisibleFrames();
  const arx_pip::SnapTarget snap =
      arx_pip::Snap(areas, ToRect(window.frame), arx_pip::Point(),
                    ToLimit(window.contentMinSize));
  [self restAt:snap window:window];
}

- (void)restAt:(arx_pip::SnapTarget)snap window:(NSWindow*)window {
  NSArray<NSScreen*>* screens = NSScreen.screens;
  if (snap.area_index < 0 ||
      static_cast<NSUInteger>(snap.area_index) >= screens.count) {
    return;
  }
  _restDisplay = DisplayID(screens[static_cast<NSUInteger>(snap.area_index)]);
  _restCorner = snap.corner;
  [self apply:ToNSRect(arx_pip::CornerFrame(snap.area, snap.corner, snap.size,
                                            {0, 0}))
           to:window];
  // Chromium may override the size; the corner follows it.
  const NSRect applied = window.frame;
  [self apply:ToNSRect(arx_pip::CornerFrame(
                  snap.area, snap.corner,
                  {NSWidth(applied), NSHeight(applied)}, {0, 0}))
           to:window];
  [window invalidateShadow];
}

- (void)step:(CADisplayLink*)link {
  NSWindow* window = _window;
  if (!window) {
    [self stopSettling];
    return;
  }
  const CFTimeInterval now = link.targetTimestamp;
  const arx_pip::Settler::Step next =
      _settler.Next(ToRect(window.frame), now);
  switch (next.action) {
    case arx_pip::Settler::Action::kStop:
      // Something else moved the window mid-settle (Chromium, or AppKit as
      // it crossed screens): rather than leave it between corners, or off
      // screen, put it at the nearest one (DEV-852).
      [self snapToNearestCorner];
      return;

    case arx_pip::Settler::Action::kApply:
      [self apply:ToNSRect(next.frame) to:window];
      _settler.Applied(next.frame, ToRect(window.frame), now);
      return;

    case arx_pip::Settler::Action::kFinish:
      [self stopSettling];
      [self apply:ToNSRect(next.frame) to:window];
      // Chromium may still override the size; the corner follows it.
      [self apply:ToNSRect(_settler.Finished(ToRect(window.frame))) to:window];
      [window invalidateShadow];
      if (!window.screen) {
        [self snapToNearestCorner];
      }
      return;
  }
}

#pragma mark - Displays

- (void)scheduleResnap {
  if (_resnapScheduled) {
    return;
  }
  _resnapScheduled = YES;
  // A turn later, once AppKit has moved windows for the new arrangement and
  // Chromium has applied the new screen's size limits.
  __weak ArxPiPWindowMotion* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weakSelf resnap];
  });
}

// Back to the corner it rested at, on the same display if it's still there,
// else the nearest corner on the nearest display, without velocity
// (DEV-852). A drag, two-finger move or pinch in progress settles on its own
// release instead.
- (void)resnap {
  _resnapScheduled = NO;
  NSWindow* window = _window;
  if (!window || !window.visible || !_isDraggableBackground || _dragging ||
      _scrolling || _pinching) {
    return;
  }
  const std::vector<arx_pip::Rect> areas = VisibleFrames();
  int index = -1;
  int corner = _restCorner;
  if (corner >= 0) {
    index = ScreenIndex(_restDisplay);
  } else {
    // Not moved yet: it's where Chromium opened it, the bottom-right corner
    // of its screen (high x, low y), and stays there.
    corner = 1;
    index = ScreenIndex(DisplayID(NearestScreen(window)));
  }
  const arx_pip::SnapTarget snap =
      arx_pip::Resnap(areas, ToRect(window.frame), index, corner,
                      ToLimit(window.contentMinSize));
  if (!window.screen) {
    [self stopSettling];
    [self restAt:snap window:window];
    return;
  }
  [self settleOnto:snap velocity:arx_pip::Point()];
}

- (void)apply:(NSRect)frame to:(NSWindow*)window {
  if (SameSize(frame, window.frame)) {
    if (!SameOrigin(frame, window.frame)) {
      [window setFrameOrigin:frame.origin];
    }
  } else {
    [window setFrame:frame display:YES];
  }
}

- (void)stopSettling {
  [_displayLink invalidate];
  _displayLink = nil;
}

@end
