"""Arx's video Picture-in-Picture window (no ABI change).

Chromium's views overlay window stays the PiP surface. Arx restyles its
controls in its own layout (DEV-1295, Figma's "Scrim" variant; round glass
buttons and a glass progress capsule before it): bare white SF Symbols over
Chromium's scrims, a light dim over the video that darkens towards the top
and bottom edges. Close top left (no minimize); captions, mute and
back-to-tab top right; play/pause between the skip buttons in the centre;
the elapsed time and the duration over a progress bar across the bottom, or
a red badge for live media. Chromium's circular ink drop lights the hovered
button. Chromium lays the controls out first and Arx moves them afterwards,
so Chromium's visibility, hit testing and state handling are unchanged.

On macOS (DEV-825) the window has continuous 16-point corners and rests at a
corner 16 points inside a screen's visible frame (24 before DEV-848). Arx takes over Chromium's
press-drag and adds a two-finger trackpad drag: both throw the window with
projected momentum onto the nearest resting position, with a slightly bouncy,
interruptible spring (critically damped with Reduce Motion). A pinch resizes
it with its aspect ratio and size limits. Chromium still resizes it from its
edges. The math is `Packages/engine/Native/pip/arx_pip_motion.h` and the AppKit
side `arx_pip_window_motion.mm`, both copied in as whole files.

DEV-852: the window joins every Space, other apps' full-screen ones included,
from before it's first shown, as a non-activating floating window the way
Chromium's Glic window is; throws stay on screen and across at most one
neighbouring display; displays changing put it back at its corner; and the
time labels are sized for the widest time the duration allows, so they never
cut off ("0:…").

DEV-948: the site's own Document PiP window (Google Meet's call controls),
which Arx opens in Chromium's standalone host, joins full-screen Spaces the
same way before it's shown.

DEV-962: both windows are created as non-activating panels. macOS decides
whether a window may join another app's full-screen Space when the window is
created, and Chromium only turns on activation independence afterwards, so
until now both stayed off other apps' full-screen Spaces. They ask for
NSWindowStyleMaskNonactivatingPanel, which NativeWidgetMacNSWindow records
before AppKit's own init and answers from, and strips from the real style.
"""
import shutil

from .overlay import replace_once

VIEWS_H = "chrome/browser/ui/views/overlay/video_overlay_window_views.h"
VIEWS = "chrome/browser/ui/views/overlay/video_overlay_window_views.cc"
WIDGET_H = "chrome/browser/ui/views/overlay/video_overlay_window_native_widget_mac.h"
WIDGET = "chrome/browser/ui/views/overlay/video_overlay_window_native_widget_mac.mm"
BUILD = "chrome/browser/ui/views/overlay/BUILD.gn"
# DEV-948: the site's own Document PiP window (Google Meet's call), which Arx
# opens in Chromium's standalone host.
DOCUMENT_HOST = "chrome/browser/ui/views/picture_in_picture/document_pip_host.cc"
DOCUMENT_WIDGET = "chrome/browser/ui/views/picture_in_picture/document_pip_native_widget_mac.mm"
# DEV-962: every views window on macOS; see the module's notes.
NSWINDOW = "components/remote_cocoa/app_shim/native_widget_mac_nswindow.mm"
OVERLAY = "chrome/browser/ui/views/overlay"

# DEV-825's whole files: the motion math and the AppKit motion controller,
# copied from Packages/engine/Native/pip on every application.
SOURCES = ["arx_pip_motion.h", "arx_pip_window_motion.h", "arx_pip_window_motion.mm"]

# DEV-825's native widget hunk: the motion controller's lifetime. DEV-852
# also hands it the media smoke's time-label check.
WIDGET_MOTION_ANCHOR = """VideoOverlayWindowNativeWidgetMac::~VideoOverlayWindowNativeWidgetMac() =
    default;
"""
WIDGET_MOTION_DEV825 = """VideoOverlayWindowNativeWidgetMac::~VideoOverlayWindowNativeWidgetMac() {
  ArxStopMotion();
}

void VideoOverlayWindowNativeWidgetMac::OnWindowInitialized() {
  NSWindow* window = GetNativeWindow().GetNativeNSWindow();
  if (!window || arx_motion_) {
    return;
  }
  // Where Chromium would start a native window drag. The motion stops calling
  // this before the widget goes away.
  __weak NSWindow* weak_window = window;
  VideoOverlayWindowNativeWidgetMac* native_widget = this;
  BOOL (^draggable)(NSPoint) = ^BOOL(NSPoint location) {
    NSWindow* target = weak_window;
    views::Widget* widget = native_widget->GetWidget();
    NSView* content = target.contentView;
    if (!target || !widget || !content) {
      return NO;
    }
    const NSPoint local = [content convertPoint:location fromView:nil];
    const gfx::Point point(static_cast<int>(local.x),
                           static_cast<int>(NSHeight(content.bounds) - local.y));
    return widget->GetNonClientComponent(point) == HTCAPTION;
  };
  ArxPiPWindowMotion* motion =
      [[ArxPiPWindowMotion alloc] initWithWindow:window
                           isDraggableBackground:draggable];
  arx_motion_ = (void*)CFBridgingRetain(motion);
}

void VideoOverlayWindowNativeWidgetMac::OnWindowDestroying(
    gfx::NativeWindow window) {
  ArxStopMotion();
}

void VideoOverlayWindowNativeWidgetMac::ArxStopMotion() {
  if (!arx_motion_) {
    return;
  }
  ArxPiPWindowMotion* motion = CFBridgingRelease(arx_motion_);
  arx_motion_ = nullptr;
  [motion invalidate];
}
"""
WIDGET_MOTION = WIDGET_MOTION_DEV825.replace("""  ArxPiPWindowMotion* motion =
      [[ArxPiPWindowMotion alloc] initWithWindow:window
                           isDraggableBackground:draggable];
  arx_motion_ = (void*)CFBridgingRetain(motion);
""", """  ArxPiPWindowMotion* motion =
      [[ArxPiPWindowMotion alloc] initWithWindow:window
                           isDraggableBackground:draggable];
  // DEV-852: the overnight media smoke's time-label check.
  motion.timeLabelsFit = ^BOOL(double elapsed, double duration) {
    views::Widget* widget = native_widget->GetWidget();
    return widget && static_cast<VideoOverlayWindowViews*>(widget)
                         ->ArxTimeLabelsFit(base::Seconds(elapsed),
                                            base::Seconds(duration));
  };
  arx_motion_ = (void*)CFBridgingRetain(motion);
""")

# Hunks whose inserted text a later change replaced, as (file, upstream
# anchor, the earlier inserted text): DEV-540's text that DEV-825 replaced,
# DEV-825's inset that DEV-848 replaced, and DEV-825's motion lifetime that
# DEV-852 replaced. A tree patched earlier holds the
# old text; applying puts the upstream anchor back first, so the new hunk
# applies once instead of beside the old one. Remove an entry once no
# prepared tree predates the change that replaced it. DEV-852's 16-point time
# labels join them below `patches()`, derived from the current hunks.
PREVIOUS = (
    # DEV-825's motion lifetime, replaced by DEV-852's, which adds the smoke's
    # time-label check.
    (WIDGET, WIDGET_MOTION_ANCHOR, WIDGET_MOTION_DEV825),
    # DEV-825's 24-point resting inset, replaced by DEV-848's 16.
    (VIEWS, """  // Keep a margin distance of 2% the average of the two window size
  // differences, keeping the margins consistent.
  int buffer = (window_diff_width + window_diff_height) / 2 * 0.02;
""", """  // Arx (DEV-825): rest 24 points inside the work area's edges, as
  // ArxPiPWindowMotion's snap positions (arx_pip::kEdgeInset) do.
  int buffer = 24;
"""),
    (VIEWS, "    origin.SetToMin(default_origin);\n", """    origin.SetToMin(default_origin);
    // Arx: and never above or left of the work area.
    origin.SetToMax(work_area.origin());
"""),
    (WIDGET_H, """  void PopulateCreateWindowParams(
      const views::Widget::InitParams& widget_params,
      remote_cocoa::mojom::CreateWindowParams* params) override;
""", """  void PopulateCreateWindowParams(
      const views::Widget::InitParams& widget_params,
      remote_cocoa::mojom::CreateWindowParams* params) override;
  // Arx: trackpad move and pinch, and keeping the window on screen.
  void OnWindowInitialized() override;
  void OnWindowDestroying(gfx::NativeWindow window) override;

 private:
  void ArxRemoveEventMonitor();
  // The AppKit local event monitor, retained through CFBridgingRetain.
  void* arx_event_monitor_ = nullptr;
"""),
    (WIDGET, """VideoOverlayWindowNativeWidgetMac::~VideoOverlayWindowNativeWidgetMac() =
    default;
""", """VideoOverlayWindowNativeWidgetMac::~VideoOverlayWindowNativeWidgetMac() {
  ArxRemoveEventMonitor();
}

namespace {

// The largest frame with `frame`'s aspect ratio that fits `area`, moved
// inside it.
NSRect ArxConstrainedFrame(NSRect frame, NSRect area) {
  if (NSIsEmptyRect(area) || frame.size.width <= 0 || frame.size.height <= 0) {
    return frame;
  }
  const CGFloat scale = std::min({1.0, area.size.width / frame.size.width,
                                  area.size.height / frame.size.height});
  frame.size.width = std::floor(frame.size.width * scale);
  frame.size.height = std::floor(frame.size.height * scale);
  frame.origin.x = std::clamp(frame.origin.x, NSMinX(area),
                              NSMaxX(area) - frame.size.width);
  frame.origin.y = std::clamp(frame.origin.y, NSMinY(area),
                              NSMaxY(area) - frame.size.height);
  return frame;
}

NSRect ArxVisibleFrame(NSWindow* window) {
  NSScreen* screen = window.screen ?: NSScreen.mainScreen;
  return screen ? screen.visibleFrame : NSZeroRect;
}

// Scales `frame` about its centre by `factor`, keeping its aspect ratio and
// the window's size limits.
NSRect ArxScaledFrame(NSWindow* window, NSRect frame, CGFloat factor) {
  const NSSize min = window.minSize;
  const NSSize max = window.maxSize;
  CGFloat scale = std::max<CGFloat>(factor, 0.1);
  if (min.width > 0) {
    scale = std::max(scale, min.width / frame.size.width);
  }
  if (min.height > 0) {
    scale = std::max(scale, min.height / frame.size.height);
  }
  if (max.width > 0) {
    scale = std::min(scale, max.width / frame.size.width);
  }
  if (max.height > 0) {
    scale = std::min(scale, max.height / frame.size.height);
  }
  const NSSize size = NSMakeSize(frame.size.width * scale,
                                 frame.size.height * scale);
  return NSMakeRect(NSMidX(frame) - size.width / 2,
                    NSMidY(frame) - size.height / 2, size.width, size.height);
}

}  // namespace

void VideoOverlayWindowNativeWidgetMac::OnWindowInitialized() {
  NSWindow* window = GetNativeWindow().GetNativeNSWindow();
  if (!window || arx_event_monitor_) {
    return;
  }
  __weak NSWindow* weak_window = window;
  id monitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel |
                                           NSEventMaskMagnify |
                                           NSEventMaskLeftMouseUp
                                   handler:^NSEvent*(NSEvent* event) {
        NSWindow* target = weak_window;
        if (!target || event.window != target) {
          return event;
        }
        const NSRect area = ArxVisibleFrame(target);
        switch (event.type) {
          case NSEventTypeScrollWheel: {
            // A two-finger drag moves the window under the fingers; a
            // mouse wheel and momentum after lifting do nothing.
            if (!event.hasPreciseScrollingDeltas ||
                event.momentumPhase != NSEventPhaseNone) {
              return nil;
            }
            const CGFloat direction =
                event.isDirectionInvertedFromDevice ? 1 : -1;
            NSRect frame = target.frame;
            frame.origin.x += direction * event.scrollingDeltaX;
            frame.origin.y -= direction * event.scrollingDeltaY;
            [target setFrame:ArxConstrainedFrame(frame, area) display:YES];
            return nil;
          }
          case NSEventTypeMagnify: {
            const NSRect frame = ArxScaledFrame(
                target, target.frame, 1 + event.magnification);
            [target setFrame:ArxConstrainedFrame(frame, area) display:YES];
            return nil;
          }
          case NSEventTypeLeftMouseUp: {
            // After a press-drag or an edge resize, ease back on screen.
            dispatch_async(dispatch_get_main_queue(), ^{
              NSWindow* settled = weak_window;
              if (!settled) {
                return;
              }
              const NSRect frame = ArxConstrainedFrame(
                  settled.frame, ArxVisibleFrame(settled));
              if (NSEqualRects(frame, settled.frame)) {
                return;
              }
              [settled setFrame:frame display:YES animate:YES];
            });
            return event;
          }
          default:
            return event;
        }
      }];
  arx_event_monitor_ = (void*)CFBridgingRetain(monitor);
}

void VideoOverlayWindowNativeWidgetMac::OnWindowDestroying(
    gfx::NativeWindow window) {
  ArxRemoveEventMonitor();
}

void VideoOverlayWindowNativeWidgetMac::ArxRemoveEventMonitor() {
  if (!arx_event_monitor_) {
    return;
  }
  id monitor = CFBridgingRelease(arx_event_monitor_);
  arx_event_monitor_ = nullptr;
  [NSEvent removeMonitor:monitor];
}
"""),
)


# DEV-1295: the members and the controls hunk, Figma's "Scrim" variant: bare
# white symbols over Chromium's scrims in place of DEV-540's glass buttons and
# progress capsule. The `_DEV852` texts are what a tree patched before it
# holds; PREVIOUS (below `patches()`) puts their anchors back.
MEMBERS_ANCHOR = "  raw_ptr<views::View> title_view_ = nullptr;\n"
MEMBERS_DEV852 = """  raw_ptr<views::View> title_view_ = nullptr;
  // Arx: the glass capsule behind the progress bar and time, and the
  // duration at its right end; `timestamp_` keeps the elapsed time.
  raw_ptr<views::View> arx_progress_backing_ = nullptr;
  raw_ptr<views::Label> arx_duration_ = nullptr;
"""
MEMBERS = """  raw_ptr<views::View> title_view_ = nullptr;
  // Arx: the duration at the progress bar's right end; `timestamp_` keeps the
  // elapsed time.
  raw_ptr<views::Label> arx_duration_ = nullptr;
"""

CONTROLS_ANCHOR = "gfx::Rect VideoOverlayWindowViews::GetBackToTabControlsBounds() {\n"
CONTROLS_DEV852 = """namespace {

// Arx's PiP control metrics, in DIPs.
constexpr int kArxMargin = 10;
constexpr int kArxSmall = 30;
constexpr int kArxGap = 6;
constexpr int kArxPlay = 56;
constexpr int kArxSkip = 40;
constexpr int kArxCenterGap = 18;
constexpr int kArxBar = 32;
constexpr int kArxBarPadding = 14;
constexpr int kArxProgressHeight = 26;

// Glass tints: the play button is the darkest, so it reads first.
constexpr SkColor kArxGlassTint = SkColorSetARGB(0x4d, 0x30, 0x30, 0x34);
constexpr SkColor kArxPlayTint = SkColorSetARGB(0x80, 0x10, 0x10, 0x12);

// A rounded glass surface: blurred video behind a tint and a bright rim.
void ArxGlass(views::View* view, float radius, SkColor tint = kArxGlassTint) {
  if (!view) {
    return;
  }
  if (!view->layer()) {
    view->SetPaintToLayer();
  }
  view->layer()->SetFillsBoundsOpaquely(false);
  view->layer()->SetRoundedCornerRadius(gfx::RoundedCornersF(radius));
  view->layer()->SetIsFastRoundedCorner(true);
  view->layer()->SetBackgroundBlur(24);
  view->SetBackground(views::CreateSolidBackground(tint));
  view->SetBorder(views::CreateRoundedRectBorder(
      1, radius, SkColorSetARGB(0x5c, 0xff, 0xff, 0xff)));
}

// SF Symbol point sizes for the small, skip and play buttons.
constexpr int kArxSymbolSmall = 13;
constexpr int kArxSymbolSkip = 18;
constexpr int kArxSymbolPlay = 24;

void ArxSymbol(views::ImageButton* button, const char* name, int point_size) {
#if BUILDFLAG(IS_MAC)
  if (!button) {
    return;
  }
  const gfx::ImageSkia image = ArxSymbolImage(name, point_size);
  if (image.isNull()) {
    return;
  }
  button->SetImageModel(views::Button::STATE_NORMAL,
                        ui::ImageModel::FromImageSkia(image));
  button->SetImageModel(views::Button::STATE_DISABLED,
                        ui::ImageModel::FromImageSkia(image));
#endif
}

void ArxPlace(views::View* view, int x, int y, int size) {
  if (view) {
    view->SetBounds(x, y, size, size);
  }
}

}  // namespace

void VideoOverlayWindowViews::ArxStyleControls() {
  for (views::View* view : std::initializer_list<views::View*>{
           close_controls_view_, minimize_button_, back_to_tab_button_,
           toggle_mute_button_, live_caption_button_,
           previous_track_controls_view_, next_track_controls_view_,
           toggle_camera_button_, toggle_microphone_button_}) {
    ArxGlass(view, kArxSmall / 2.f);
  }
  ArxGlass(replay_10_seconds_button_, kArxSkip / 2.f);
  ArxGlass(forward_10_seconds_button_, kArxSkip / 2.f);
  ArxGlass(play_pause_controls_view_, kArxPlay / 2.f, kArxPlayTint);
  ArxGlass(hang_up_button_, kArxPlay / 2.f,
           SkColorSetARGB(0xd9, 0xd9, 0x30, 0x25));

  // The capsule sits behind the progress bar and the time.
  arx_progress_backing_ = playback_controls_container_view_->AddChildViewAt(
      std::make_unique<views::View>(), 0);
  ArxGlass(arx_progress_backing_, kArxBar / 2.f);
  arx_progress_backing_->SetCanProcessEventsWithinSubtree(false);

  timestamp_->SetEnabledColor(kColorPipWindowForeground);
  auto duration = std::make_unique<views::Label>(
      std::u16string(), views::style::CONTEXT_LABEL, views::style::STYLE_BODY_4);
  duration->SetEnabledColor(kColorPipWindowForeground);
  duration->SetBackgroundColor(SK_ColorTRANSPARENT);
  duration->SetHorizontalAlignment(gfx::ALIGN_RIGHT);
  arx_duration_ = playback_controls_container_view_->AddChildView(
      std::move(duration));

  // The capsule's blur needs a layer, and a layer draws over siblings that
  // paint into their parent; layered, the bar and times stay above it.
  for (views::View* view : std::initializer_list<views::View*>{
           progress_view_, timestamp_, live_status_, arx_duration_}) {
    view->SetPaintToLayer();
    view->layer()->SetFillsBoundsOpaquely(false);
  }
}

void VideoOverlayWindowViews::ArxApplySymbols() {
  ArxSymbol(close_controls_view_, "xmark", kArxSymbolSmall);
  ArxSymbol(minimize_button_, "minus", kArxSymbolSmall);
  ArxSymbol(back_to_tab_button_, "pip.exit", kArxSymbolSmall);
  ArxSymbol(live_caption_button_, "captions.bubble", kArxSymbolSmall);
  ArxSymbol(toggle_mute_button_,
            arx_media_muted_ ? "speaker.slash.fill" : "speaker.wave.2.fill",
            kArxSymbolSmall);
  ArxSymbol(previous_track_controls_view_, "backward.end.fill",
            kArxSymbolSmall);
  ArxSymbol(next_track_controls_view_, "forward.end.fill", kArxSymbolSmall);
  ArxSymbol(replay_10_seconds_button_, "gobackward.10", kArxSymbolSkip);
  ArxSymbol(forward_10_seconds_button_, "goforward.10", kArxSymbolSkip);
  ArxSymbol(play_pause_controls_view_,
            playback_state_for_testing_ == kPlaying  ? "pause.fill"
            : playback_state_for_testing_ == kPaused ? "play.fill"
                                                     : "arrow.counterclockwise",
            kArxSymbolPlay);
  ArxSymbol(toggle_microphone_button_,
            arx_microphone_muted_ ? "mic.slash.fill" : "mic.fill",
            kArxSymbolSkip);
  ArxSymbol(toggle_camera_button_,
            arx_camera_on_ ? "video.fill" : "video.slash.fill", kArxSymbolSkip);
  ArxSymbol(hang_up_button_, "phone.down.fill", kArxSymbolPlay);
}

void VideoOverlayWindowViews::ArxLayoutControls() {
  const gfx::Size size = GetBounds().size();
  const int width = size.width();
  const int height = size.height();

  // The site's origin and favicon would sit under the top-left buttons.
  favicon_view_->SetSize({0, 0});
  origin_->SetSize({0, 0});

  // Top left: close, then minimize.
  ArxPlace(close_controls_view_, kArxMargin, kArxMargin, kArxSmall);
  ArxPlace(minimize_button_, kArxMargin + kArxSmall + kArxGap, kArxMargin,
           kArxSmall);

  // Top right, from the edge inwards: back to tab, mute, captions.
  int x = width - kArxMargin - kArxSmall;
  for (views::View* view : std::initializer_list<views::View*>{
           back_to_tab_button_, toggle_mute_button_, live_caption_button_}) {
    if (!view || !view->GetVisible()) {
      continue;
    }
    ArxPlace(view, x, kArxMargin, kArxSmall);
    x -= kArxSmall + kArxGap;
  }
  if (live_caption_button_ && live_caption_dialog_) {
    live_caption_dialog_->SetPosition(
        {live_caption_button_->bounds().right() - live_caption_dialog_->width(),
         kArxMargin + kArxSmall + kArxGap});
  }

  // Centre row: play/pause between the skip buttons, tracks outside them.
  const int cx = width / 2;
  const int cy = height / 2;
  const int skip_offset = kArxPlay / 2 + kArxCenterGap;
  ArxPlace(play_pause_controls_view_, cx - kArxPlay / 2, cy - kArxPlay / 2,
           kArxPlay);
  ArxPlace(replay_10_seconds_button_, cx - skip_offset - kArxSkip,
           cy - kArxSkip / 2, kArxSkip);
  ArxPlace(forward_10_seconds_button_, cx + skip_offset, cy - kArxSkip / 2,
           kArxSkip);
  const int track_offset = skip_offset + kArxSkip + kArxCenterGap;
  ArxPlace(previous_track_controls_view_, cx - track_offset - kArxSmall,
           cy - kArxSmall / 2, kArxSmall);
  ArxPlace(next_track_controls_view_, cx + track_offset, cy - kArxSmall / 2,
           kArxSmall);

  // Video calls: hang up centred between camera and microphone.
  ArxPlace(hang_up_button_, cx - kArxPlay / 2, cy - kArxPlay / 2, kArxPlay);
  ArxPlace(toggle_camera_button_, cx - skip_offset - kArxSkip,
           cy - kArxSkip / 2, kArxSkip);
  ArxPlace(toggle_microphone_button_, cx + skip_offset, cy - kArxSkip / 2,
           kArxSkip);

  // Bottom: the progress bar and the time inside one glass capsule.
  const gfx::Rect bar(kArxMargin, height - kArxMargin - kArxBar,
                      std::max(0, width - 2 * kArxMargin), kArxBar);
  if (arx_progress_backing_) {
    arx_progress_backing_->SetBoundsRect(bar);
    arx_progress_backing_->SetVisible(progress_view_->GetVisible());
  }
  // Elapsed time, the bar, then the duration; live media shows its label
  // and the bar alone. Each label is as tall as its own line (see
  // ArxSizeTimeLabel), centred in the capsule.
  auto fit = [&](views::Label* label) {
    const gfx::Size preferred = label->GetPreferredSize(
        views::SizeBounds(bar.width() / 3, kArxBar));
    return gfx::Size(std::min(preferred.width(), bar.width() / 3),
                     std::min(preferred.height(), kArxBar));
  };
  auto place = [&](views::Label* label, int x, gfx::Size size) {
    label->SetBounds(x, bar.y() + (kArxBar - size.height()) / 2, size.width(),
                     size.height());
  };
  int left = bar.x() + kArxBarPadding;
  int right = bar.right() - kArxBarPadding;
  if (is_live_) {
    const gfx::Size live = fit(live_status_);
    place(live_status_, left, live);
    left += live.width() + kArxGap;
  } else {
    const gfx::Size elapsed = fit(timestamp_);
    place(timestamp_, left, elapsed);
    left += elapsed.width() + kArxGap + 2;
  }
  if (arx_duration_) {
    arx_duration_->SetVisible(!is_live_ && timestamp_->GetVisible());
    const gfx::Size duration = fit(arx_duration_);
    const int duration_width = duration.width();
    place(arx_duration_, right - duration_width, duration);
    if (arx_duration_->GetVisible()) {
      right -= duration_width + kArxGap + 2;
    }
  }
  progress_view_->SetBounds(left, bar.y() + (kArxBar - kArxProgressHeight) / 2,
                            std::max(0, right - left), kArxProgressHeight);

  // Resizing makes Chromium redraw its own icons; put the symbols back.
  ArxApplySymbols();
}

gfx::Rect VideoOverlayWindowViews::GetBackToTabControlsBounds() {
"""
CONTROLS = """namespace {

// Arx's PiP control metrics, in DIPs (DEV-1295, Figma's "Scrim" variant).
constexpr int kArxMargin = 10;
constexpr int kArxSmall = 28;
constexpr int kArxGap = 4;
constexpr int kArxPlay = 56;
constexpr int kArxSkip = 40;
constexpr int kArxCenterGap = 28;
// The times and the bar sit this far in from the sides; the times' centre and
// the bar's centre this far up from the bottom.
constexpr int kArxEdge = 14;
constexpr int kArxTimesCenter = 30;
constexpr int kArxBarCenter = 14;
// Chromium's progress view draws its bar in the middle of this height.
constexpr int kArxBarHeight = 26;
// The scrims darken this far in from the top and the bottom.
constexpr int kArxTopScrim = 72;
constexpr int kArxBottomScrim = 96;

// A light dim over the whole video, so the centre symbols read on a bright
// frame; the duration a little dimmer than the elapsed time; live media's
// badge.
constexpr SkColor kArxVideoDim = SkColorSetARGB(0x1f, 0x00, 0x00, 0x00);
constexpr SkColor kArxDuration = SkColorSetARGB(0xb3, 0xff, 0xff, 0xff);
constexpr SkColor kArxLive = SkColorSetARGB(0xff, 0xeb, 0x38, 0x33);

// A rounded glass surface: blurred video behind a tint and a bright rim.
// Only a call's hang-up button keeps one, in red.
void ArxGlass(views::View* view, float radius, SkColor tint) {
  if (!view) {
    return;
  }
  if (!view->layer()) {
    view->SetPaintToLayer();
  }
  view->layer()->SetFillsBoundsOpaquely(false);
  view->layer()->SetRoundedCornerRadius(gfx::RoundedCornersF(radius));
  view->layer()->SetIsFastRoundedCorner(true);
  view->layer()->SetBackgroundBlur(24);
  view->SetBackground(views::CreateSolidBackground(tint));
  view->SetBorder(views::CreateRoundedRectBorder(
      1, radius, SkColorSetARGB(0x5c, 0xff, 0xff, 0xff)));
}

// SF Symbol point sizes: close, the media buttons, skip and play.
constexpr int kArxSymbolClose = 13;
constexpr int kArxSymbolMedia = 15;
constexpr int kArxSymbolSkip = 21;
constexpr int kArxSymbolPlay = 32;

void ArxSymbol(views::ImageButton* button, const char* name, int point_size) {
#if BUILDFLAG(IS_MAC)
  if (!button) {
    return;
  }
  const gfx::ImageSkia image = ArxSymbolImage(name, point_size);
  if (image.isNull()) {
    return;
  }
  button->SetImageModel(views::Button::STATE_NORMAL,
                        ui::ImageModel::FromImageSkia(image));
  button->SetImageModel(views::Button::STATE_DISABLED,
                        ui::ImageModel::FromImageSkia(image));
#endif
}

void ArxPlace(views::View* view, int x, int y, int size) {
  if (view) {
    view->SetBounds(x, y, size, size);
  }
}

}  // namespace

void VideoOverlayWindowViews::ArxStyleControls() {
  // The buttons are bare white symbols over the video. Chromium's circular
  // ink drop, in the same white, lights the one under the pointer.
  ArxGlass(hang_up_button_, kArxPlay / 2.f,
           SkColorSetARGB(0xd9, 0xd9, 0x30, 0x25));

  // Scrims: a light dim over the whole video, darker towards the top and the
  // bottom where the buttons and the time sit. They fade with the controls.
  controls_scrim_view_->SetBackground(
      views::CreateSolidBackground(kArxVideoDim));
  controls_top_scrim_view_->SetBackground(std::make_unique<GradientBackground>(
      SkColor4f{0, 0, 0, 0.5f}, SkColor4f{0, 0, 0, 0}));
  controls_bottom_scrim_view_->SetBackground(
      std::make_unique<GradientBackground>(SkColor4f{0, 0, 0, 0},
                                           SkColor4f{0, 0, 0, 0.6f}));

  timestamp_->SetEnabledColor(kColorPipWindowForeground);
  auto duration = std::make_unique<views::Label>(
      std::u16string(), views::style::CONTEXT_LABEL, views::style::STYLE_BODY_4);
  duration->SetEnabledColor(kArxDuration);
  duration->SetBackgroundColor(SK_ColorTRANSPARENT);
  duration->SetHorizontalAlignment(gfx::ALIGN_RIGHT);
  arx_duration_ = playback_controls_container_view_->AddChildView(
      std::move(duration));

  // Live media: a red badge in place of the times. ArxSizeTimeLabel counts
  // its padding.
  live_status_->SetEnabledColor(SK_ColorWHITE);
  live_status_->SetBackground(views::CreateRoundedRectBackground(kArxLive, 5.f));
  live_status_->SetBorder(views::CreateEmptyBorder(gfx::Insets::VH(1, 7)));
}

void VideoOverlayWindowViews::ArxApplySymbols() {
  ArxSymbol(close_controls_view_, "xmark", kArxSymbolClose);
  ArxSymbol(minimize_button_, "minus", kArxSymbolClose);
  ArxSymbol(back_to_tab_button_, "pip.exit", kArxSymbolMedia);
  ArxSymbol(live_caption_button_, "captions.bubble", kArxSymbolMedia);
  ArxSymbol(toggle_mute_button_,
            arx_media_muted_ ? "speaker.slash.fill" : "speaker.wave.2.fill",
            kArxSymbolMedia);
  ArxSymbol(previous_track_controls_view_, "backward.end.fill",
            kArxSymbolMedia);
  ArxSymbol(next_track_controls_view_, "forward.end.fill", kArxSymbolMedia);
  ArxSymbol(replay_10_seconds_button_, "gobackward.10", kArxSymbolSkip);
  ArxSymbol(forward_10_seconds_button_, "goforward.10", kArxSymbolSkip);
  ArxSymbol(play_pause_controls_view_,
            playback_state_for_testing_ == kPlaying  ? "pause.fill"
            : playback_state_for_testing_ == kPaused ? "play.fill"
                                                     : "arrow.counterclockwise",
            kArxSymbolPlay);
  ArxSymbol(toggle_microphone_button_,
            arx_microphone_muted_ ? "mic.slash.fill" : "mic.fill",
            kArxSymbolSkip);
  ArxSymbol(toggle_camera_button_,
            arx_camera_on_ ? "video.fill" : "video.slash.fill", kArxSymbolSkip);
  ArxSymbol(hang_up_button_, "phone.down.fill", 24);
}

void VideoOverlayWindowViews::ArxLayoutControls() {
  const gfx::Size size = GetBounds().size();
  const int width = size.width();
  const int height = size.height();

  // The site's origin and favicon would sit under the top-left buttons.
  favicon_view_->SetSize({0, 0});
  origin_->SetSize({0, 0});

  // The scrims hug the edges they darken.
  controls_top_scrim_view_->SetBounds(0, 0, width, kArxTopScrim);
  controls_bottom_scrim_view_->SetBounds(0, height - kArxBottomScrim, width,
                                         kArxBottomScrim);

  // Top left: close alone. The design has no minimize; Back to Tab and Close
  // remain the ways out.
  ArxPlace(close_controls_view_, kArxMargin, kArxMargin, kArxSmall);
  if (minimize_button_) {
    minimize_button_->SetVisible(false);
  }

  // Top right, from the edge inwards: back to tab, mute, captions.
  int x = width - kArxMargin - kArxSmall;
  for (views::View* view : std::initializer_list<views::View*>{
           back_to_tab_button_, toggle_mute_button_, live_caption_button_}) {
    if (!view || !view->GetVisible()) {
      continue;
    }
    ArxPlace(view, x, kArxMargin, kArxSmall);
    x -= kArxSmall + kArxGap;
  }
  if (live_caption_button_ && live_caption_dialog_) {
    live_caption_dialog_->SetPosition(
        {live_caption_button_->bounds().right() - live_caption_dialog_->width(),
         kArxMargin + kArxSmall + kArxGap});
  }

  // Centre row: play/pause between the skip buttons, tracks outside them.
  const int cx = width / 2;
  const int cy = height / 2;
  const int skip_offset = kArxPlay / 2 + kArxCenterGap;
  ArxPlace(play_pause_controls_view_, cx - kArxPlay / 2, cy - kArxPlay / 2,
           kArxPlay);
  ArxPlace(replay_10_seconds_button_, cx - skip_offset - kArxSkip,
           cy - kArxSkip / 2, kArxSkip);
  ArxPlace(forward_10_seconds_button_, cx + skip_offset, cy - kArxSkip / 2,
           kArxSkip);
  const int track_offset = skip_offset + kArxSkip + kArxCenterGap;
  ArxPlace(previous_track_controls_view_, cx - track_offset - kArxSmall,
           cy - kArxSmall / 2, kArxSmall);
  ArxPlace(next_track_controls_view_, cx + track_offset, cy - kArxSmall / 2,
           kArxSmall);

  // Video calls: hang up centred between camera and microphone.
  ArxPlace(hang_up_button_, cx - kArxPlay / 2, cy - kArxPlay / 2, kArxPlay);
  ArxPlace(toggle_camera_button_, cx - skip_offset - kArxSkip,
           cy - kArxSkip / 2, kArxSkip);
  ArxPlace(toggle_microphone_button_, cx + skip_offset, cy - kArxSkip / 2,
           kArxSkip);

  // Bottom: the elapsed time at the left and the duration at the right, over
  // a bar across the whole width; live media shows its badge instead of the
  // times. Each label is as tall as its own line (see ArxSizeTimeLabel).
  const int left = kArxEdge;
  const int right = width - kArxEdge;
  const int times_center = height - kArxTimesCenter;
  auto fit = [&](views::Label* label) {
    const gfx::Size preferred = label->GetPreferredSize(
        views::SizeBounds(width / 3, kArxSmall));
    return gfx::Size(std::min(preferred.width(), width / 3),
                     std::min(preferred.height(), kArxSmall));
  };
  auto place = [&](views::Label* label, int x, gfx::Size size) {
    label->SetBounds(x, times_center - size.height() / 2, size.width(),
                     size.height());
  };
  place(is_live_ ? live_status_.get() : timestamp_.get(), left,
        fit(is_live_ ? live_status_.get() : timestamp_.get()));
  if (arx_duration_) {
    arx_duration_->SetVisible(!is_live_ && timestamp_->GetVisible());
    const gfx::Size duration = fit(arx_duration_);
    place(arx_duration_, right - duration.width(), duration);
  }
  progress_view_->SetBounds(left, height - kArxBarCenter - kArxBarHeight / 2,
                            std::max(0, right - left), kArxBarHeight);

  // Resizing makes Chromium redraw its own icons; put the symbols back.
  ArxApplySymbols();
}

gfx::Rect VideoOverlayWindowViews::GetBackToTabControlsBounds() {
"""


def patches():
    yield VIEWS_H, "  void SetUpViews();\n", """  void SetUpViews();

  // Arx: glass controls in Arx's layout, applied after Chromium's own.
  void ArxStyleControls();
  void ArxChromiumUpdateControlsBounds();
  void ArxLayoutControls();
  // Arx: SF Symbols in place of Chromium's icons, re-applied after Chromium
  // updates a button's image.
  void ArxApplySymbols();
  bool arx_media_muted_ = false;
  bool arx_microphone_muted_ = false;
  bool arx_camera_on_ = false;
"""
    yield VIEWS_H, MEMBERS_ANCHOR, MEMBERS

    # DEV-852: string widths for the time labels.
    yield VIEWS, '#include "ui/views/controls/label.h"\n', """#include "ui/views/controls/label.h"

#include <cmath>
#include <initializer_list>

#include "ui/gfx/text_utils.h"
"""
    # DEV-852: shown over other apps' full-screen Spaces. Set before the
    # window is first shown, since AppKit settles a window's Spaces when it's
    # ordered in, and re-ordering it ends Picture in Picture. Activation
    # independence makes it a non-activating floating window, as Chromium's
    # Glic window is (glic_floating_ui.cc); ArxPiPWindowMotion adds
    # canJoinAllApplications in OnWindowInitialized. It stays at the floating
    # level, as Glic's does. Joining another app's full-screen Space also needs
    # the window to be a non-activating panel from creation (DEV-962, below).
    yield VIEWS, "  overlay_window->OnRootViewReady();\n", """  overlay_window->OnRootViewReady();
#if BUILDFLAG(IS_MAC)
  // Arx (DEV-852): over full-screen apps, without activating Arx.
  overlay_window->SetActivationIndependence(true);
  overlay_window->SetCanAppearInExistingFullscreenSpaces(true);
#endif
"""
    # DEV-948: a call's Document PiP shows over full-screen apps too, set
    # right after Init and before Show for the same reason as ArxPiP's above.
    # Chromium creates it at the floating level on every Space already.
    yield DOCUMENT_HOST, "  widget_->Init(std::move(params));\n", """  widget_->Init(std::move(params));
#if BUILDFLAG(IS_MAC)
  // Arx (DEV-948): over full-screen apps, without activating Arx.
  widget_->SetActivationIndependence(true);
  widget_->SetCanAppearInExistingFullscreenSpaces(true);
#endif
"""
    # DEV-962: macOS lets a window into another app's full-screen Space only
    # when it is a non-activating panel at creation. Activation independence
    # comes too late for that, so a window asks for the panel style when it's
    # created; the window class records it before AppKit's init reads it.
    yield NSWINDOW, "  BOOL _activationIndependence;\n", """  BOOL _activationIndependence;
  // Arx (DEV-962): created as a non-activating panel; see the init below.
  BOOL _arxNonactivatingAtCreation;
"""
    yield NSWINDOW, """  DCHECK(NSEqualRects(contentRect, ui::kWindowSizeDeterminedLater));
  if ((self = [super initWithContentRect:ui::kWindowSizeDeterminedLater
""", """  DCHECK(NSEqualRects(contentRect, ui::kWindowSizeDeterminedLater));
  // Arx (DEV-962): AppKit decides during init whether the window may join
  // other apps' full-screen Spaces, from -_isNonactivatingPanel, so a window
  // created with the panel style answers YES from here on. The style itself is
  // only valid for NSPanel and is not passed on.
  _arxNonactivatingAtCreation =
      (windowStyle & NSWindowStyleMaskNonactivatingPanel) != 0;
  windowStyle &= ~NSWindowStyleMaskNonactivatingPanel;
  if ((self = [super initWithContentRect:ui::kWindowSizeDeterminedLater
"""
    yield NSWINDOW, """  if (_activationIndependence) {
    return YES;
  }
  return [super _isNonactivatingPanel];
""", """  if (_activationIndependence || _arxNonactivatingAtCreation) {
    return YES;
  }
  return [super _isNonactivatingPanel];
"""
    yield WIDGET, "  params->style_mask = NSWindowStyleMaskFullSizeContentView;\n", """  // Arx (DEV-962): a non-activating panel from creation, so it can join other
  // apps' full-screen Spaces.
  params->style_mask = NSWindowStyleMaskFullSizeContentView |
                       NSWindowStyleMaskNonactivatingPanel;
"""
    yield DOCUMENT_WIDGET, """  params->style_mask = NSWindowStyleMaskFullSizeContentView |
                       NSWindowStyleMaskTitled | NSWindowStyleMaskResizable;
""", """  // Arx (DEV-962): a non-activating panel from creation, so a call's window
  // can join other apps' full-screen Spaces.
  params->style_mask = NSWindowStyleMaskFullSizeContentView |
                       NSWindowStyleMaskTitled | NSWindowStyleMaskResizable |
                       NSWindowStyleMaskNonactivatingPanel;
"""
    # DEV-852: the media smoke checks the time labels through this.
    yield VIEWS_H, "  void SetMediaPosition(const media_session::MediaPosition& position) override;\n", """  void SetMediaPosition(const media_session::MediaPosition& position) override;
  // Arx (DEV-852): shows `current_time` of `duration`, reports whether every
  // time label shows its whole text, then shows the real position again.
  // For the overnight media smoke.
  bool ArxTimeLabelsFit(base::TimeDelta current_time, base::TimeDelta duration);
"""
    # DEV-852: the time labels are sized for the widest time the duration's
    # format allows, so "0:09" becoming "0:10" or "9:59" becoming "10:00"
    # never cuts the label off, and the controls are laid out again when that
    # width changes. ArxLayoutControls takes each label's preferred width.
    yield VIEWS, "void VideoOverlayWindowViews::UpdateTimestampLabel(base::TimeDelta current_time,\n", """namespace {

// Arx (DEV-852): how wide `text` can get in `label`: every digit drawn as the
// font's widest one, plus the label's insets and a point for rounding.
int ArxWidestTextWidth(const views::Label* label, std::u16string text) {
  const gfx::FontList& font = label->font_list();
  char16_t widest = u'0';
  float widest_width = 0;
  for (char16_t digit = u'0'; digit <= u'9'; ++digit) {
    const float width = gfx::GetStringWidthF(std::u16string(1, digit), font);
    if (width > widest_width) {
      widest = digit;
      widest_width = width;
    }
  }
  for (char16_t& character : text) {
    if (character >= u'0' && character <= u'9') {
      character = widest;
    }
  }
  return static_cast<int>(std::ceil(gfx::GetStringWidthF(text, font))) +
         label->GetInsets().width() + 1;
}

// Sizes `label` for the widest of `texts`, as tall as its own line (its
// style's line height or its font, whichever is taller: 18 points for the
// times' STYLE_BODY_4); whether its size changed. A shorter label clips the
// line, which views::Label reports as truncated at any scale.
bool ArxSizeTimeLabel(views::Label* label,
                      std::initializer_list<std::u16string> texts) {
  if (!label) {
    return false;
  }
  int width = 0;
  for (const std::u16string& text : texts) {
    width = std::max(width, ArxWidestTextWidth(label, text));
  }
  const gfx::Size size(width,
                       label->GetLineHeight() + label->GetInsets().height());
  const bool changed = label->GetPreferredSize(views::SizeBounds()) != size;
  label->SetPreferredSize(size);
  return changed;
}

}  // namespace

bool VideoOverlayWindowViews::ArxTimeLabelsFit(base::TimeDelta current_time,
                                               base::TimeDelta duration) {
  UpdateTimestampLabel(current_time, duration);
  bool fits = true;
  for (views::Label* label : std::initializer_list<views::Label*>{
           timestamp_, arx_duration_, live_status_}) {
    if (label && label->GetVisible() && label->IsDisplayTextTruncated()) {
      fits = false;
    }
  }
  UpdateTimestampLabel(position_.GetPosition(), position_.duration());
  return fits;
}

void VideoOverlayWindowViews::UpdateTimestampLabel(base::TimeDelta current_time,
"""
    yield VIEWS, """  if (was_live != is_live_) {
    OnUpdateControlsBounds();
  }
""", """  // Arx (DEV-852): elapsed time never outgrows the duration, so both labels
  // take the width of the duration's format at its widest; live media's
  // label takes its own.
  bool arx_resized = false;
  if (is_live_) {
    arx_resized |= ArxSizeTimeLabel(
        live_status_, {std::u16string(live_status_->GetText())});
  } else {
    const std::u16string arx_duration_text =
        global_media_controls::GetFormattedDuration(duration);
    arx_resized |= ArxSizeTimeLabel(
        timestamp_, {std::u16string(timestamp_->GetText()), arx_duration_text});
    arx_resized |= ArxSizeTimeLabel(arx_duration_, {arx_duration_text});
  }
  if (was_live != is_live_ || arx_resized) {
    OnUpdateControlsBounds();
  }
"""

    yield VIEWS, '#include "ui/views/background.h"\n', """#include "ui/views/background.h"
#include "chrome/browser/ui/color/chrome_color_id.h"
#include "ui/compositor/layer.h"
#include "ui/gfx/geometry/rounded_corners_f.h"
#include "ui/views/border.h"
"""
    # Resting 16 points inside the work area, as ArxPiPWindowMotion's snap
    # positions do (DEV-825, 16 since DEV-848).
    yield VIEWS, """  // Keep a margin distance of 2% the average of the two window size
  // differences, keeping the margins consistent.
  int buffer = (window_diff_width + window_diff_height) / 2 * 0.02;
""", """  // Arx (DEV-848): rest 16 points inside the work area's edges, as
  // ArxPiPWindowMotion's snap positions (arx_pip::kEdgeInset) do.
  int buffer = 16;
"""
    yield VIEWS, "    origin.SetToMin(default_origin);\n", """    origin.SetToMin(default_origin);
    // Arx (DEV-825): and at least the inset from the top and left edges.
    origin.SetToMax(work_area.origin() + gfx::Vector2d(buffer, buffer));
"""
    yield VIEWS, """#if BUILDFLAG(IS_CHROMEOS)
  resize_handle_view_ =
      controls_container_view_->AddChildView(std::move(resize_handle_view));
#endif
}
""", """#if BUILDFLAG(IS_CHROMEOS)
  resize_handle_view_ =
      controls_container_view_->AddChildView(std::move(resize_handle_view));
#endif

  ArxStyleControls();
}
"""
    yield VIEWS, """void VideoOverlayWindowViews::OnUpdateControlsBounds() {
  controls_container_view_->SetSize(GetBounds().size());
""", """void VideoOverlayWindowViews::OnUpdateControlsBounds() {
  // Arx: Chromium lays the controls out, then Arx moves them into place.
  ArxChromiumUpdateControlsBounds();
  ArxLayoutControls();
}

void VideoOverlayWindowViews::ArxChromiumUpdateControlsBounds() {
  controls_container_view_->SetSize(GetBounds().size());
"""
    # A white bar on a grey track, like the rest of the controls.
    yield VIEWS, """          /*playing_foreground_color_id=*/ui::kColorSysPrimary,
          /*playing_background_color_id=*/ui::kColorSysStateDisabled,
          /*paused_foreground_color_id=*/ui::kColorSysStateDisabled,""", """          /*playing_foreground_color_id=*/kColorPipWindowForeground,
          /*playing_background_color_id=*/ui::kColorSysStateDisabled,
          /*paused_foreground_color_id=*/kColorPipWindowForeground,"""
    # Elapsed time on the left of the bar, the duration on the right.
    yield VIEWS, """    timestamp_->SetText(base::StrCat(
        {global_media_controls::GetFormattedDuration(current_time), u" / ",
         global_media_controls::GetFormattedDuration(duration)}));""", """    timestamp_->SetText(
        global_media_controls::GetFormattedDuration(current_time));
    if (arx_duration_) {
      arx_duration_->SetText(
          global_media_controls::GetFormattedDuration(duration));
    }"""
    yield VIEWS, """  play_pause_controls_view_->SetPlaybackState(playback_state);
}""", """  play_pause_controls_view_->SetPlaybackState(playback_state);
  ArxApplySymbols();
}"""
    yield VIEWS, """  toggle_microphone_button_->SetMutedState(muted);
}""", """  toggle_microphone_button_->SetMutedState(muted);
  arx_microphone_muted_ = muted;
  ArxApplySymbols();
}"""
    yield VIEWS, """  toggle_camera_button_->SetCameraState(turned_on);
}""", """  toggle_camera_button_->SetCameraState(turned_on);
  arx_camera_on_ = turned_on;
  ArxApplySymbols();
}"""
    yield VIEWS, """  if (toggle_mute_button_) {
    toggle_mute_button_->SetMutedState(muted);
  }
}""", """  if (toggle_mute_button_) {
    toggle_mute_button_->SetMutedState(muted);
  }
  arx_media_muted_ = muted;
  ArxApplySymbols();
}"""
    yield VIEWS, CONTROLS_ANCHOR, CONTROLS

    yield WIDGET_H, """  void PopulateCreateWindowParams(
      const views::Widget::InitParams& widget_params,
      remote_cocoa::mojom::CreateWindowParams* params) override;
""", """  void PopulateCreateWindowParams(
      const views::Widget::InitParams& widget_params,
      remote_cocoa::mojom::CreateWindowParams* params) override;
  // Arx (DEV-825): corners, throwing, two-finger move and pinch.
  void OnWindowInitialized() override;
  void OnWindowDestroying(gfx::NativeWindow window) override;

 private:
  void ArxStopMotion();
  // The window's ArxPiPWindowMotion, retained through CFBridgingRetain.
  void* arx_motion_ = nullptr;
"""
    yield WIDGET_H, "#endif  // CHROME_BROWSER_UI_VIEWS_OVERLAY_VIDEO_OVERLAY_WINDOW_NATIVE_WIDGET_MAC_H_", """// Arx: an SF Symbol drawn in the PiP foreground colour, or a null image when
// the system has no symbol with that name.
gfx::ImageSkia ArxSymbolImage(const char* name, int point_size);

#endif  // CHROME_BROWSER_UI_VIEWS_OVERLAY_VIDEO_OVERLAY_WINDOW_NATIVE_WIDGET_MAC_H_"""
    yield WIDGET, WIDGET_MOTION_ANCHOR, WIDGET_MOTION
    yield WIDGET, '#include "chrome/browser/ui/views/overlay/video_overlay_window_native_widget_mac.h"\n', """#include "chrome/browser/ui/views/overlay/video_overlay_window_native_widget_mac.h"

#import "chrome/browser/ui/views/overlay/arx_pip_window_motion.h"
#include "ui/base/hit_test.h"
#include "ui/views/widget/widget.h"
"""
    yield BUILD, """    sources += [ "video_overlay_window_native_widget_mac.mm" ]
""", """    sources += [
      "arx_pip_motion.h",
      "arx_pip_window_motion.h",
      "arx_pip_window_motion.mm",
      "video_overlay_window_native_widget_mac.mm",
    ]
"""
    yield BUILD, """    frameworks = [ "Cocoa.framework" ]
""", """    frameworks = [
      "Cocoa.framework",
      "QuartzCore.framework",
    ]
"""
    yield WIDGET_H, '#include "ui/views/widget/native_widget_mac.h"\n', """#include "ui/gfx/image/image_skia.h"
#include "ui/views/widget/native_widget_mac.h"
"""
    yield WIDGET, "#import <Cocoa/Cocoa.h>\n", """#import <Cocoa/Cocoa.h>

#include <algorithm>
#include <cmath>
#include <map>
#include <string>
#include <utility>

#include "base/no_destructor.h"
#include "ui/gfx/image/image.h"

gfx::ImageSkia ArxSymbolImage(const char* name, int point_size) {
  static base::NoDestructor<std::map<std::pair<std::string, int>, gfx::ImageSkia>>
      cache;
  const auto key = std::make_pair(std::string(name), point_size);
  if (auto found = cache->find(key); found != cache->end()) {
    return found->second;
  }
  NSImage* symbol = [NSImage imageWithSystemSymbolName:@(name)
                              accessibilityDescription:nil];
  symbol = [symbol imageWithSymbolConfiguration:
                       [NSImageSymbolConfiguration
                           configurationWithPointSize:point_size
                                               weight:NSFontWeightSemibold]];
  if (!symbol) {
    return gfx::ImageSkia();
  }
  NSImage* tinted = [NSImage imageWithSize:symbol.size
                                   flipped:NO
                            drawingHandler:^BOOL(NSRect rect) {
                              [symbol drawInRect:rect];
                              [NSColor.whiteColor set];
                              NSRectFillUsingOperation(
                                  rect, NSCompositingOperationSourceAtop);
                              return YES;
                            }];
  gfx::ImageSkia image = gfx::Image(tinted).AsImageSkia();
  cache->emplace(key, image);
  return image;
}
"""


# DEV-852's time labels were 16 points tall until they took their own line's
# height. The two hunks that held that text, as a tree patched before then has
# them: each (new, earlier) fragment put back.
TIME_LABEL_HEIGHT_FRAGMENTS = (
    ("""// Sizes `label` for the widest of `texts`, as tall as its own line (its
// style's line height or its font, whichever is taller: 18 points for the
// times' STYLE_BODY_4); whether its size changed. A shorter label clips the
// line, which views::Label reports as truncated at any scale.
""", """// Sizes `label` for the widest of `texts`; whether its width changed.
"""),
    ("""  const gfx::Size size(width,
                       label->GetLineHeight() + label->GetInsets().height());
  const bool changed = label->GetPreferredSize(views::SizeBounds()) != size;
  label->SetPreferredSize(size);
""", """  const bool changed =
      label->GetPreferredSize(views::SizeBounds()).width() != width;
  label->SetPreferredSize(gfx::Size(width, kArxTimeHeight));
"""),
    ("""constexpr int kArxProgressHeight = 26;
""", """constexpr int kArxProgressHeight = 26;
constexpr int kArxTimeHeight = 16;
"""),
    ("""  // and the bar alone. Each label is as tall as its own line (see
  // ArxSizeTimeLabel), centred in the capsule.
  auto fit = [&](views::Label* label) {
    const gfx::Size preferred = label->GetPreferredSize(
        views::SizeBounds(bar.width() / 3, kArxBar));
    return gfx::Size(std::min(preferred.width(), bar.width() / 3),
                     std::min(preferred.height(), kArxBar));
  };
  auto place = [&](views::Label* label, int x, gfx::Size size) {
    label->SetBounds(x, bar.y() + (kArxBar - size.height()) / 2, size.width(),
                     size.height());
  };
  int left = bar.x() + kArxBarPadding;
  int right = bar.right() - kArxBarPadding;
  if (is_live_) {
    const gfx::Size live = fit(live_status_);
    place(live_status_, left, live);
    left += live.width() + kArxGap;
  } else {
    const gfx::Size elapsed = fit(timestamp_);
    place(timestamp_, left, elapsed);
    left += elapsed.width() + kArxGap + 2;
  }
  if (arx_duration_) {
    arx_duration_->SetVisible(!is_live_ && timestamp_->GetVisible());
    const gfx::Size duration = fit(arx_duration_);
    const int duration_width = duration.width();
    place(arx_duration_, right - duration_width, duration);
""", """  // and the bar alone.
  const int time_y = bar.y() + (kArxBar - kArxTimeHeight) / 2;
  auto fit = [&](views::Label* label) {
    return std::min(
        label->GetPreferredSize(views::SizeBounds(bar.width() / 3, kArxTimeHeight))
            .width(),
        bar.width() / 3);
  };
  int left = bar.x() + kArxBarPadding;
  int right = bar.right() - kArxBarPadding;
  if (is_live_) {
    const int live_width = fit(live_status_);
    live_status_->SetBounds(left, time_y, live_width, kArxTimeHeight);
    left += live_width + kArxGap;
  } else {
    const int elapsed_width = fit(timestamp_);
    timestamp_->SetBounds(left, time_y, elapsed_width, kArxTimeHeight);
    left += elapsed_width + kArxGap + 2;
  }
  if (arx_duration_) {
    arx_duration_->SetVisible(!is_live_ && timestamp_->GetVisible());
    const int duration_width = fit(arx_duration_);
    arx_duration_->SetBounds(right - duration_width, time_y, duration_width,
                             kArxTimeHeight);
"""),
)


def _with_time_label_height_reverted(text):
    for new, earlier in TIME_LABEL_HEIGHT_FRAGMENTS:
        text = text.replace(new, earlier)
    return text


PREVIOUS += tuple(
    (relative, before, _with_time_label_height_reverted(after))
    for relative, before, after in patches()
    if relative == VIEWS and any(new in after for new, _ in TIME_LABEL_HEIGHT_FRAGMENTS)
)

# DEV-1295 replaced the glass controls: a tree patched before it holds
# DEV-852's members and controls, or, older still, those controls with the
# 16-point time labels.
PREVIOUS += (
    (VIEWS_H, MEMBERS_ANCHOR, MEMBERS_DEV852),
    (VIEWS, CONTROLS_ANCHOR, _with_time_label_height_reverted(CONTROLS_DEV852)),
    (VIEWS, CONTROLS_ANCHOR, CONTROLS_DEV852),
)


def revert_previous(source):
    """Puts back the upstream anchor where a hunk still holds an earlier change's text."""
    for relative, before, previous in PREVIOUS:
        path = source / relative
        if not path.is_file():
            continue
        text = path.read_text()
        if text.count(previous) == 1:
            path.write_text(text.replace(previous, before, 1))


def apply(source):
    from .config import PACKAGE

    destination = source / OVERLAY
    destination.mkdir(parents=True, exist_ok=True)
    for name in SOURCES:
        shutil.copy2(PACKAGE / "Native/pip" / name, destination / name)
    revert_previous(source)
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
