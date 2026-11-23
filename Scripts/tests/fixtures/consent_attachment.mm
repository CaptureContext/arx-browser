#import <AppKit/AppKit.h>
#include <cassert>
// PRODUCTION_ATTACHMENT
int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSWindow* first = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 200)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    NSWindow* second = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 200)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    first.releasedWhenClosed = NO;
    second.releasedWhenClosed = NO;
    NSView* source = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
    first.contentView = source;
    ArxConsentAttachmentView* observer = [[ArxConsentAttachmentView alloc] initWithFrame:NSZeroRect];
    __block NSUInteger changes = 0, completed = 0;
    observer.willChange = ^{ ++changes; };
    observer.didChange = ^{ ++completed; };
    [source addSubview:observer];
    assert(observer.window == first && changes && completed);
    const NSUInteger initial = changes;
    first.contentView = [[NSView alloc] initWithFrame:NSZeroRect];
    second.contentView = source;
    second.contentView = [[NSView alloc] initWithFrame:NSZeroRect];
    first.contentView = source;
    // No run loop or timer tick between moving away and back to the exact host.
    assert(observer.window == first && changes >= initial + 4);
    const NSUInteger before_hide = changes;
    source.hidden = YES;
    assert(changes > before_hide);
    source.hidden = NO;
    assert(!first.visible && !second.visible); // Never show these owned windows.
    observer.willChange = nil;
    observer.didChange = nil;
    [observer removeFromSuperview];
    [first close];
    [second close];
  }
}
