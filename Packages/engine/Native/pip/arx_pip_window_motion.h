// Arx (DEV-825, DEV-852): how the Picture in Picture window looks, moves and settles.
// Copied to chrome/browser/ui/views/overlay by Scripts/engine/pip_overlay.py
// and owned by VideoOverlayWindowNativeWidgetMac.

#ifndef CHROME_BROWSER_UI_VIEWS_OVERLAY_ARX_PIP_WINDOW_MOTION_H_
#define CHROME_BROWSER_UI_VIEWS_OVERLAY_ARX_PIP_WINDOW_MOTION_H_

#import <Cocoa/Cocoa.h>

// Gives the window continuous 16-point corners, lets it join every Space
// (other apps' full-screen ones included, DEV-852) and drives its movement:
// - A press-drag on the video (where Chromium would start a native window
//   drag) and a two-finger trackpad drag move the window 1:1; the two-finger
//   drag keeps part of it on a screen. On release the window's velocity is
//   projected forward, as UIKit's projection does but no farther than one
//   screen's width or height, and the window settles on the nearest resting
//   position to that point: a corner 16 points inside the visible frame of
//   the screen the point lands on. The settle is a slightly bouncy spring
//   that starts at the release velocity, bounded so the bounce stays inside
//   that screen; with Reduce Motion it's critically damped and starts at
//   rest. It runs on that screen's display link, so it keeps going while the
//   window is between screens. The window also resizes, faster than it
//   moves, to fit that screen within Chromium's cap with its aspect ratio
//   kept (arx_pip::Settler), and the corner stays exact through any resize,
//   Chromium's included.
//   Phase-less precise scrolling (some mice) doesn't move the window.
// - A pinch resizes the window about the pointer, keeping its aspect ratio
//   and Chromium's size limits, inside the visible frame of its screen (or
//   the nearest one), then settles it on the nearest resting position.
// - After Chromium's own edge resize the window settles the same way.
// - When displays change, it settles back to the same corner of the same
//   display, or the nearest corner of the nearest display.
// - Anything that leaves it off screen or between corners (a release with
//   the window off every screen, a settle stopped by another move, or one
//   that ends off screen) puts it at the nearest corner at once.
// Any press (a grab, an edge resize, a click on a control), a pinch or a
// two-finger drag stops a settling window where it is, and it settles again
// on release. The clicks themselves are left to Chromium.
@interface ArxPiPWindowMotion : NSObject

// `isDraggableBackground` reports whether a point in window coordinates is
// where Chromium would start a window drag (its HTCAPTION area).
- (instancetype)initWithWindow:(NSWindow*)window
         isDraggableBackground:(BOOL (^)(NSPoint))isDraggableBackground
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Removes the event monitors and stops any settle. Call before the window
// goes away; nothing calls `isDraggableBackground` or `timeLabelsFit`
// afterwards.
- (void)invalidate;

// The overnight media smoke's checks (DEV-852), answered only when the
// process has ARX_MEDIA_SMOKE_ROOT, as the smoke runner sets it. Each is an
// in-process NSNotification whose object is the PiP window and whose
// userInfo carries an NSMutableDictionary under "reply":
// - "ArxPiPSmokeRelease" with NSNumber "x" and "y": releases the window as
//   if a drag ended at that velocity, in points per second. Replies
//   "handled".
// - "ArxPiPSmokeTimeLabels" with "times", an array of [elapsed, duration]
//   pairs in seconds: shows each in turn and replies "fits", whether no time
//   label was cut off at any of them, then shows the real time again.
// - "ArxPiPSmokeRest": replies "display" and "corner", where the window
//   rests or is settling, or -1.
// Whether, for each [elapsed, duration] in seconds, the time labels show
// the whole time; set by the native widget.
@property(nonatomic, copy) BOOL (^timeLabelsFit)(double elapsed, double duration);

@end

#endif  // CHROME_BROWSER_UI_VIEWS_OVERLAY_ARX_PIP_WINDOW_MOTION_H_
