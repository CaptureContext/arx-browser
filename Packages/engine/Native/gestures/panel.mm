#include "chrome/browser/arx/gestures/panel.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>

#include "base/strings/sys_string_conversions.h"
#include "url/gurl.h"

namespace arx::gestures {
namespace {
constexpr CGFloat kRing = 44;
constexpr CGFloat kCircle = 36;
constexpr CGFloat kStroke = 2.5;
constexpr CGFloat kInset = 16;
constexpr CGFloat kArrow = 16;
// The history list (DEV-1276): the Destination Picker's raised glass tile.
constexpr CGFloat kListGap = 8;
constexpr CGFloat kListWidth = 260;
constexpr CGFloat kListPadding = 4;
constexpr CGFloat kListRadius = 14;
constexpr CGFloat kRowHeight = 40;
constexpr CGFloat kRowSpacing = 2;
constexpr CGFloat kRowPitch = kRowHeight + kRowSpacing;
constexpr CGFloat kRowRadius = 10;
constexpr CGFloat kRowLeading = 6;
constexpr CGFloat kRowTrailing = 10.5;
constexpr CGFloat kIconTile = 26;
constexpr CGFloat kIcon = 16;
constexpr CGFloat kIconGap = 6;
constexpr size_t kMaxRows = 5;

bool IsDark(NSAppearance* appearance) {
  return [appearance bestMatchFromAppearancesWithNames:@[
      NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
}

NSColor* Dynamic(NSColor* light, NSColor* dark) {
  return [NSColor colorWithName:nil dynamicProvider:^NSColor*(NSAppearance* appearance) {
    return IsDark(appearance) ? dark : light;
  }];
}

// The ready circle inverts the page's appearance: light on dark, dark on light.
NSColor* CapsuleFill() {
  return Dynamic([NSColor colorWithWhite:0.12 alpha:1], [NSColor colorWithWhite:0.93 alpha:1]);
}
NSColor* CapsuleText() {
  return Dynamic(NSColor.whiteColor, NSColor.blackColor);
}

// Under glass: enough of the page's own background to keep text legible.
NSColor* Frost() {
  return Dynamic([NSColor colorWithWhite:1 alpha:0.82], [NSColor colorWithWhite:0.08 alpha:0.72]);
}

// Arx's chrome text, as the Destination Picker's rows use it.
NSColor* ChromeText(CGFloat alpha) {
  return Dynamic([NSColor colorWithSRGBRed:39 / 255.0 green:34 / 255.0 blue:57 / 255.0 alpha:alpha],
                 [NSColor colorWithSRGBRed:227 / 255.0 green:224 / 255.0 blue:245 / 255.0 alpha:alpha]);
}
NSColor* SelectedFill() {
  return Dynamic([NSColor colorWithWhite:0 alpha:0.08], [NSColor colorWithWhite:0 alpha:0.3]);
}
NSColor* SelectedEdge() {
  return Dynamic([NSColor colorWithWhite:0 alpha:0.06], [NSColor colorWithWhite:0 alpha:0.25]);
}
NSColor* Hairline() {
  return Dynamic([NSColor colorWithWhite:0 alpha:0.08], [NSColor colorWithWhite:1 alpha:0.06]);
}

NSView* AddFrost(NSView* inner) {
  NSView* frost = [[NSView alloc] initWithFrame:inner.bounds];
  frost.wantsLayer = YES;
  [inner addSubview:frost positioned:NSWindowBelow relativeTo:nil];
  return frost;
}

void Run(bool animated, void (^changes)(void)) {
  if (!animated || NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    changes();
    [CATransaction commit];
    return;
  }
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
    context.duration = 0.22;
    context.allowsImplicitAnimation = YES;
    context.timingFunction =
        [CAMediaTimingFunction functionWithControlPoints:0.2 :0.9 :0.25 :1];
    changes();
  }];
}

NSView* Glass(CGFloat radius, NSView** content) {
  if (@available(macOS 26.0, *)) {
    NSGlassEffectView* glass = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
    glass.cornerRadius = radius;
    *content = [[NSView alloc] initWithFrame:NSZeroRect];
    glass.contentView = *content;
    glass.wantsLayer = YES;
    return glass;
  }
  NSVisualEffectView* material = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
  material.material = NSVisualEffectMaterialHUDWindow;
  material.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  material.state = NSVisualEffectStateActive;
  material.wantsLayer = YES;
  material.layer.cornerRadius = radius;
  material.layer.masksToBounds = YES;
  *content = material;
  return material;
}

void SetRadius(NSView* view, CGFloat radius) {
  if (@available(macOS 26.0, *)) {
    if ([view isKindOfClass:NSGlassEffectView.class]) {
      static_cast<NSGlassEffectView*>(view).cornerRadius = radius;
      return;
    }
  }
  view.layer.cornerRadius = radius;
}

NSTextField* Label(CGFloat size, NSFontWeight weight, NSColor* color) {
  NSTextField* label = [NSTextField labelWithString:@""];
  label.font = [NSFont systemFontOfSize:size weight:weight];
  label.textColor = color;
  label.lineBreakMode = NSLineBreakByTruncatingTail;
  label.maximumNumberOfLines = 1;
  return label;
}

// Where an entry sits in the column, counted from the top: the back list runs
// down from the nearest entry, the forward list up from it (DEV-1292).
size_t ListSlot(size_t index, size_t count, Direction direction) {
  return direction == Direction::kBack ? index : count - 1 - index;
}

// The topmost of the shown slots: two above the selected slot, clamped to the
// ends.
size_t ListWindowStart(size_t selected, size_t count) {
  if (count <= kMaxRows) return 0;
  const long start = static_cast<long>(selected) - static_cast<long>(kMaxRows / 2);
  return static_cast<size_t>(std::clamp(start, 0L, static_cast<long>(count - kMaxRows)));
}

}  // namespace

Panel::Panel(NSView* source, Direction direction)
    : source_(source), direction_(direction) {
  if (!source.window || NSIsEmptyRect(source.bounds)) return;
  const NSRect frame = [source.window convertRectToScreen:
      [source convertRect:source.bounds toView:nil]];
  panel_ = [[NSPanel alloc] initWithContentRect:frame
      styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
      backing:NSBackingStoreBuffered defer:NO];
  panel_.releasedWhenClosed = NO;
  panel_.opaque = NO;
  panel_.backgroundColor = NSColor.clearColor;
  panel_.hasShadow = NO;
  panel_.ignoresMouseEvents = YES;
  panel_.hidesOnDeactivate = YES;
  panel_.appearance = source.window.effectiveAppearance;
  panel_.accessibilityLabel = direction == Direction::kBack ? @"Back" : @"Forward";
  NSView* content = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))];
  content.wantsLayer = YES;
  panel_.contentView = content;

  NSMutableArray<NSView*>* frosts = [NSMutableArray array];

  ring_ = [CAShapeLayer layer];
  ring_.fillColor = NSColor.clearColor.CGColor;
  ring_.lineWidth = kStroke;
  ring_.lineCap = kCALineCapRound;
  ring_.strokeEnd = 0;
  [content.layer addSublayer:ring_];

  NSView* inner = nil;
  pill_ = Glass(kCircle / 2, &inner);
  pill_content_ = inner;
  [frosts addObject:AddFrost(inner)];
  pill_.accessibilityElement = YES;
  pill_.accessibilityRole = NSAccessibilityImageRole;
  arrow_ = [NSImageView imageViewWithImage:
      [NSImage imageWithSystemSymbolName:
          direction == Direction::kBack ? @"arrow.left" : @"arrow.right"
                accessibilityDescription:nil]];
  arrow_.symbolConfiguration = [NSImageSymbolConfiguration
      configurationWithPointSize:15 weight:NSFontWeightSemibold];
  fill_ = [[NSView alloc] initWithFrame:NSZeroRect];
  fill_.wantsLayer = YES;
  fill_.alphaValue = 0;
  [pill_content_ addSubview:fill_];
  [pill_content_ addSubview:arrow_];
  [content addSubview:pill_];

  // The list's shadow lives on a plain layer around the glass, which clips.
  tile_ = [[NSView alloc] initWithFrame:NSZeroRect];
  tile_.wantsLayer = YES;
  tile_.layer.masksToBounds = NO;
  tile_.layer.shadowColor = NSColor.blackColor.CGColor;
  tile_.layer.shadowOpacity = 0.25;
  tile_.layer.shadowRadius = 24;
  tile_.layer.shadowOffset = CGSizeMake(0, -8);
  tile_.alphaValue = 0;
  tile_.accessibilityElement = YES;
  tile_.accessibilityRole = NSAccessibilityListRole;
  tile_.accessibilityLabel = panel_.accessibilityLabel;
  NSView* tile_inner = nil;
  tile_glass_ = Glass(kListRadius, &tile_inner);
  tile_content_ = tile_inner;
  tile_content_.wantsLayer = YES;
  tile_content_.layer.cornerRadius = kListRadius;
  tile_content_.layer.masksToBounds = YES;
  tile_content_.layer.borderWidth = 0.5;
  [frosts addObject:AddFrost(tile_content_)];
  column_ = [[NSView alloc] initWithFrame:NSZeroRect];
  [tile_content_ addSubview:column_];
  [tile_ addSubview:tile_glass_];
  [content addSubview:tile_];
  frosts_ = frosts;

  [source.window addChildWindow:panel_ ordered:NSWindowAbove];
  Layout(false);
}

Panel::~Panel() { Dismiss(); }

NSString* Panel::TitleAt(size_t index) const {
  if (index >= entries_.size()) return @"";
  const auto& entry = entries_[index];
  NSString* title = base::SysUTF8ToNSString(entry.title);
  if (title.length) return title;
  return HostAt(index);
}

NSString* Panel::HostAt(size_t index) const {
  if (index >= entries_.size()) return @"";
  const auto& entry = entries_[index];
  const GURL url(entry.url);
  return base::SysUTF8ToNSString(url.has_host() ? url.host() : entry.url);
}

void Panel::SetEntries(const std::vector<HistoryEntry>& entries, NSArray* icons) {
  entries_ = entries;
  icons_ = icons;
  BuildRows();
  Layout(false);
}

// One row per entry in a column as tall as the whole history; the tile shows
// at most five of them and the column slides behind it.
void Panel::BuildRows() {
  for (NSView* row in rows_) [row removeFromSuperview];
  NSMutableArray<NSView*>* rows = [NSMutableArray array];
  NSMutableArray<NSView*>* highlights = [NSMutableArray array];
  const CGFloat width = kListWidth - 2 * kListPadding;
  const CGFloat text_x = kRowLeading + kIconTile + kIconGap;
  const CGFloat text_width = width - text_x - kRowTrailing;
  for (size_t index = 0; index < entries_.size(); ++index) {
    NSView* row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, kRowHeight)];
    row.accessibilityElement = YES;
    row.accessibilityRole = NSAccessibilityRowRole;

    NSView* highlight = [[NSView alloc] initWithFrame:row.bounds];
    highlight.wantsLayer = YES;
    highlight.layer.cornerRadius = kRowRadius;
    highlight.layer.borderWidth = 0.5;
    highlight.alphaValue = 0;
    [row addSubview:highlight];

    NSImage* favicon = index < icons_.count && [icons_[index] isKindOfClass:NSImage.class]
        ? icons_[index] : nil;
    NSImageView* icon = [NSImageView imageViewWithImage:favicon ?: [NSImage
        imageWithSystemSymbolName:@"globe" accessibilityDescription:nil]];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    if (!favicon) {
      icon.symbolConfiguration = [NSImageSymbolConfiguration
          configurationWithPointSize:12 weight:NSFontWeightRegular];
      icon.contentTintColor = ChromeText(0.52);
    }
    icon.frame = NSMakeRect(kRowLeading + (kIconTile - kIcon) / 2,
                            (kRowHeight - kIcon) / 2, kIcon, kIcon);
    [row addSubview:icon];

    NSTextField* title = Label(13, NSFontWeightMedium, ChromeText(0.85));
    title.stringValue = TitleAt(index);
    title.frame = NSMakeRect(text_x, kRowHeight / 2 - 1.5, text_width, 16);
    [row addSubview:title];
    NSTextField* host = Label(11, NSFontWeightRegular, ChromeText(0.52));
    host.stringValue = HostAt(index);
    host.frame = NSMakeRect(text_x, kRowHeight / 2 - 14.5, text_width, 13);
    [row addSubview:host];

    row.accessibilityLabel = title.stringValue;
    [column_ addSubview:row];
    [rows addObject:row];
    [highlights addObject:highlight];
  }
  rows_ = rows;
  highlights_ = highlights;
}

void Panel::Update(double progress, bool armed, size_t selected) {
  if (!panel_) return;
  const bool arming = armed != armed_;
  const bool moved = armed && armed_ && selected != selected_;
  const bool was_filled = filled();
  progress_ = std::isfinite(progress) ? std::clamp(progress, 0.0, 1.0) : 0;
  armed_ = armed;
  selected_ = entries_.empty() ? 0 : std::min(selected, entries_.size() - 1);
  const bool filling = filled() != was_filled;
  // Filling commits the one-step navigation; opening the list and each step
  // through it follow.
  if ((filling && filled()) || (arming && armed) || moved) {
    [NSHapticFeedbackManager.defaultPerformer
        performFeedbackPattern:moved ? NSHapticFeedbackPatternGeneric
                                     : NSHapticFeedbackPatternAlignment
              performanceTime:NSHapticFeedbackPerformanceTimeNow];
  }
  Layout(arming || moved || filling);
}

void Panel::Layout(bool animated) {
  NSView* source = source_;
  if (!panel_ || !source) return;
  const NSRect bounds = panel_.contentView.bounds;
  const bool back = direction_ == Direction::kBack;
  // Always at the view's vertical centre, whatever the pointer's height.
  const CGFloat cy = NSMidY(bounds);
  const CGFloat cx = back ? NSMinX(bounds) + kInset + kRing / 2
                          : NSMaxX(bounds) - kInset - kRing / 2;
  const bool dark = IsDark(panel_.effectiveAppearance);

  const NSRect circle = NSMakeRect(cx - kCircle / 2, cy - kCircle / 2, kCircle, kCircle);
  const NSRect circle_bounds = NSMakeRect(0, 0, kCircle, kCircle);
  const NSRect arrow = NSMakeRect((kCircle - kArrow) / 2, (kCircle - kArrow) / 2, kArrow, kArrow);

  // The list: at most five rows, the selected one level with the arrow. The
  // window of shown slots starts two above the selected slot, clamped to the
  // ends, so the tile moves near the ends and holds still in between. The
  // forward list's slots run bottom up (DEV-1292).
  const size_t count = entries_.size();
  const Direction direction = direction_;
  const size_t shown = std::min(count, kMaxRows);
  const size_t selected_slot = count ? ListSlot(selected_, count, direction) : 0;
  const size_t start = ListWindowStart(selected_slot, count);
  const CGFloat height = shown ? 2 * kListPadding + shown * kRowPitch - kRowSpacing : 0;
  const CGFloat column_height = count ? count * kRowPitch - kRowSpacing : 0;
  const CGFloat above = kListPadding + (selected_slot - start) * kRowPitch + kRowHeight / 2;
  const CGFloat tile_x = back ? cx + kRing / 2 + kListGap : cx - kRing / 2 - kListGap - kListWidth;
  const NSRect tile = NSMakeRect(tile_x, cy + above - height, kListWidth, height);
  const NSRect tile_bounds = NSMakeRect(0, 0, kListWidth, height);
  const NSRect column = NSMakeRect(
      kListPadding, height - kListPadding - column_height + start * kRowPitch,
      kListWidth - 2 * kListPadding, column_height);
  const bool list = armed_ && shown;

  // Ready and armed share the solid circle: release now navigates.
  const bool solid = armed_ || filled();
  NSColor* ink = solid ? CapsuleText() : NSColor.labelColor;

  auto place_list = ^{
    tile_.frame = tile;
    tile_glass_.frame = tile_bounds;
    tile_content_.frame = tile_bounds;
    frosts_.lastObject.frame = tile_bounds;
    column_.frame = column;
    for (size_t index = 0; index < rows_.count && index < count; ++index) {
      const size_t slot = ListSlot(index, count, direction);
      rows_[index].frame = NSMakeRect(0, column_height - slot * kRowPitch - kRowHeight,
                                      NSWidth(column), kRowHeight);
    }
  };
  // A list that isn't showing yet appears where it belongs, then fades in.
  if (tile_.alphaValue == 0) Run(false, place_list);

  Run(animated, ^{
    pill_.frame = circle;
    if (pill_content_ != pill_) pill_content_.frame = circle_bounds;
    arrow_.frame = arrow;
    fill_.frame = circle_bounds;
    frosts_.firstObject.frame = circle_bounds;
    fill_.alphaValue = solid ? 1 : 0;
    SetRadius(pill_, kCircle / 2);
    pill_.alphaValue = armed_ ? 1 : std::clamp(progress_ / 0.2, 0.0, 1.0);
    place_list();
    tile_.alphaValue = list ? 1 : 0;
    for (size_t index = 0; index < highlights_.count; ++index)
      highlights_[index].alphaValue = list && index == selected_ ? 1 : 0;
  });

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  arrow_.contentTintColor = ink;
  fill_.layer.cornerRadius = kCircle / 2;
  frosts_.firstObject.layer.cornerRadius = kCircle / 2;
  frosts_.lastObject.layer.cornerRadius = kListRadius;
  CGPathRef shadow = CGPathCreateWithRoundedRect(tile_bounds, kListRadius, kListRadius, nullptr);
  tile_.layer.shadowPath = shadow;
  CGPathRelease(shadow);
  [panel_.effectiveAppearance performAsCurrentDrawingAppearance:^{
    fill_.layer.backgroundColor = CapsuleFill().CGColor;
    for (NSView* frost in frosts_) frost.layer.backgroundColor = Frost().CGColor;
    tile_content_.layer.borderColor = Hairline().CGColor;
    for (NSView* highlight in highlights_) {
      highlight.layer.backgroundColor = SelectedFill().CGColor;
      highlight.layer.borderColor = SelectedEdge().CGColor;
    }
  }];
  pill_.accessibilityLabel = panel_.accessibilityLabel;
  for (size_t index = 0; index < rows_.count; ++index)
    rows_[index].accessibilitySelected = list && index == selected_;
  ring_.hidden = solid;
  ring_.frame = NSMakeRect(cx - kRing / 2, cy - kRing / 2, kRing, kRing);
  // Starts at the top and runs toward the swiped edge's far side.
  CGMutablePathRef path = CGPathCreateMutable();
  const CGFloat radius = (kRing - kStroke) / 2;
  CGPathAddArc(path, nullptr, kRing / 2, kRing / 2, radius, M_PI_2,
               M_PI_2 + (back ? -2 : 2) * M_PI, back);
  ring_.path = path;
  CGPathRelease(path);
  ring_.strokeColor = [NSColor colorWithWhite:dark ? 0.92 : 0.15 alpha:0.9].CGColor;
  ring_.strokeEnd = progress_;
  [CATransaction commit];
}

void Panel::Dismiss() {
  [panel_.parentWindow removeChildWindow:panel_];
  [panel_ orderOut:nil];
  [panel_ close];
  panel_ = nil;
  pill_ = nil;
  pill_content_ = nil;
  fill_ = nil;
  arrow_ = nil;
  ring_ = nil;
  tile_ = nil;
  tile_glass_ = nil;
  tile_content_ = nil;
  column_ = nil;
  rows_ = nil;
  highlights_ = nil;
  frosts_ = nil;
  icons_ = nil;
  armed_ = false;
}

}  // namespace arx::gestures
