#ifndef ARX_GESTURES_PANEL_H_
#define ARX_GESTURES_PANEL_H_

#import <AppKit/AppKit.h>

#include "chrome/browser/arx/gestures/selection.h"

@class CAShapeLayer;

namespace arx::gestures {

// The swipe indicator, vertically centred in the page view and inset from the
// swiped edge. Until armed it is a glass circle with an arrow inside a ring
// that fills with progress; a closed ring turns the circle solid. Armed, the
// circle stays solid and a raised glass list of the history opens beside it
// (DEV-1276): up to five rows, each with the page's favicon, title and host.
// The selected row is always level with the arrow: near either end of the
// history the list moves, and in between it holds still while the rows scroll
// through it. The back list hangs down from the arrow, nearest entry on top;
// the forward list mirrors it, rising from the arrow with the nearest entry at
// the bottom, so down is back and up is forward (DEV-1292). A nonactivating,
// noninteractive child window: it never takes the
// source responder. The toolbar history menus remain the keyboard and VoiceOver
// route.
class Panel {
 public:
  Panel(NSView* source, Direction direction);
  ~Panel();
  // Nearest first. Empty shows the arrow alone. `icons` matches `entries`
  // index for index; NSNull, or a shorter array, means no favicon.
  void SetEntries(const std::vector<HistoryEntry>& entries, NSArray* icons);
  void Update(double progress, bool armed, size_t selected);
  void Dismiss();
  bool visible() const { return panel_ && panel_.visible; }
  bool armed() const { return visible() && armed_; }
  // The ring has closed: release goes one step, before the list opens.
  bool filled() const { return !armed_ && progress_ >= 1; }

 private:
  void Layout(bool animated);
  void BuildRows();
  NSString* TitleAt(size_t index) const;
  NSString* HostAt(size_t index) const;

  NSView* __weak source_ = nil;
  const Direction direction_;
  NSPanel* __strong panel_ = nil;
  NSView* __strong pill_ = nil;
  NSView* __strong pill_content_ = nil;
  // The ready circle's solid fill, under the arrow.
  NSView* __strong fill_ = nil;
  NSImageView* __strong arrow_ = nil;
  CAShapeLayer* __strong ring_ = nil;
  // The history list: a shadowed tile holding glass, whose content clips the
  // full-length column of rows that scrolls behind it.
  NSView* __strong tile_ = nil;
  NSView* __strong tile_glass_ = nil;
  NSView* __strong tile_content_ = nil;
  NSView* __strong column_ = nil;
  NSArray<NSView*>* __strong rows_ = nil;
  NSArray<NSView*>* __strong highlights_ = nil;
  // Frosted backings so glass stays legible over busy pages: the circle's,
  // then the list's.
  NSArray<NSView*>* __strong frosts_ = nil;
  std::vector<HistoryEntry> entries_;
  NSArray* __strong icons_ = nil;
  double progress_ = 0;
  bool armed_ = false;
  size_t selected_ = 0;
};

}  // namespace arx::gestures
#endif  // ARX_GESTURES_PANEL_H_
