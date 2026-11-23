#include "chrome/browser/arx/popup_host.h"

#import <AppKit/AppKit.h>
#include "base/strings/sys_string_conversions.h"
#include "base/memory/raw_ptr.h"
#include "components/blocked_content/popup_blocker_tab_helper.h"
#include "components/blocked_content/url_list_manager.h"
#include "content/public/browser/web_contents.h"

@interface ARXPopupMenuTarget : NSObject {
  base::RepeatingCallback<arx::PopupHost::Entries()> entries_;
  base::RepeatingCallback<void(int32_t)> open_;
  NSMenu* menu_;
}
- (instancetype)initWithEntries:(base::RepeatingCallback<arx::PopupHost::Entries()>)entries
                          open:(base::RepeatingCallback<void(int32_t)>)open;
- (NSMenu*)menu;
- (void)show:(NSButton*)sender;
- (void)cancel;
@end

@implementation ARXPopupMenuTarget
- (instancetype)initWithEntries:(base::RepeatingCallback<arx::PopupHost::Entries()>)entries
                          open:(base::RepeatingCallback<void(int32_t)>)open {
  if ((self = [super init])) { entries_ = std::move(entries); open_ = std::move(open); }
  return self;
}
- (NSMenu*)menu {
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Blocked pop-ups"];
  menu.autoenablesItems = NO;
  const auto entries = entries_.Run();
  for (const auto& [identifier, url] : entries) {
    NSMenuItem* item = [[NSMenuItem alloc]
        initWithTitle:base::SysUTF8ToNSString("Open " + url)
        action:@selector(open:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = @(identifier);
    [menu addItem:item];
  }
  return menu;
}
- (void)show:(NSButton*)sender {
  if (!sender.window || !sender.window.visible || sender.window.miniaturized ||
      sender.hiddenOrHasHiddenAncestor || entries_.Run().empty()) return;
  menu_ = [self menu];
  [menu_ popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds)) inView:sender];
  menu_ = nil;
}
- (void)open:(NSMenuItem*)sender {
  if ([sender.representedObject isKindOfClass:[NSNumber class]])
    open_.Run([sender.representedObject intValue]);
}
- (void)cancel { [menu_ cancelTrackingWithoutAnimation]; menu_ = nil; }
@end

namespace arx {
class PopupHost::Impl final : public blocked_content::UrlListManager::Observer {
 public:
  Impl(content::WebContents* contents, base::RepeatingCallback<void(int32_t)> blocked,
       base::RepeatingCallback<Entries()> entries, base::RepeatingCallback<void(int32_t)> open)
      : contents_(contents), blocked_(std::move(blocked)), entries_(std::move(entries)) {
    auto* helper = blocked_content::PopupBlockerTabHelper::FromWebContents(contents_);
    helper->manager()->AddObserver(this);
    target_ = [[ARXPopupMenuTarget alloc] initWithEntries:entries_ open:std::move(open)];
    button_ = [NSButton buttonWithTitle:@"Pop-up blocked" target:target_ action:@selector(show:)];
    button_.accessibilityLabel = @"Blocked pop-ups. Choose a pop-up to open.";
    button_.toolTip = @"This page tried to open a pop-up. Choose one to open.";
    button_.translatesAutoresizingMaskIntoConstraints = NO;
    button_.hidden = YES;
    NSView* view = contents_->GetNativeView().GetNativeNSView();
    [view addSubview:button_];
    [NSLayoutConstraint activateConstraints:@[
      [button_.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-12],
      [button_.leadingAnchor constraintGreaterThanOrEqualToAnchor:view.leadingAnchor constant:12],
      [button_.topAnchor constraintEqualToAnchor:view.topAnchor constant:12],
      [button_.widthAnchor constraintLessThanOrEqualToConstant:240],
      [button_.heightAnchor constraintEqualToConstant:28],
    ]];
  }
  ~Impl() override {
    [target_ cancel];
    [button_ removeFromSuperview];
    if (auto* helper = blocked_content::PopupBlockerTabHelper::FromWebContents(contents_))
      helper->manager()->RemoveObserver(this);
  }
  void BlockedUrlAdded(int32_t id, const GURL&) override {
    blocked_.Run(id);
    Refresh();
  }
  void Refresh() {
    const auto count = entries_.Run().size();
    button_.hidden = !count;
    button_.menu = count ? [target_ menu] : nil;
    button_.identifier = @"ArxBlockedPopups";
    button_.title = count == 1 ? @"Pop-up blocked" :
        [NSString stringWithFormat:@"%lu pop-ups blocked", static_cast<unsigned long>(count)];
    if (!count) [target_ cancel];
  }
 private:
  raw_ptr<content::WebContents> contents_;
  base::RepeatingCallback<void(int32_t)> blocked_;
  base::RepeatingCallback<Entries()> entries_;
  ARXPopupMenuTarget* __strong target_;
  NSButton* __strong button_;
};
PopupHost::PopupHost(content::WebContents* contents, base::RepeatingCallback<void(int32_t)> blocked,
                     base::RepeatingCallback<Entries()> entries, base::RepeatingCallback<void(int32_t)> open)
    : impl_(std::make_unique<Impl>(contents, std::move(blocked), std::move(entries), std::move(open))) {}
PopupHost::~PopupHost() = default;
void PopupHost::Refresh() { impl_->Refresh(); }
}  // namespace arx
