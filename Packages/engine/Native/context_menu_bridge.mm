#include "chrome/browser/arx/context_menu_bridge.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <array>
#include <initializer_list>
#include <utility>
#include <string>
#include <string_view>

#include "base/no_destructor.h"
#include "chrome/browser/arx/extension_menu_items.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/spellchecker/spellcheck_custom_dictionary.h"
#include "chrome/browser/spellchecker/spellcheck_factory.h"
#include "chrome/browser/spellchecker/spellcheck_service.h"
#include "components/prefs/pref_service.h"
#include "components/spellcheck/browser/pref_names.h"
#include "components/spellcheck/browser/spellcheck_platform.h"
#include "components/spellcheck/common/spellcheck_features.h"
#include "components/spellcheck/spellcheck_buildflags.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/referrer.h"
#include "net/http/http_request_headers.h"
#include "third_party/blink/public/common/loader/network_utils.h"
#include "third_party/blink/public/common/context_menu_data/context_menu_data.h"
#include "third_party/blink/public/common/context_menu_data/edit_flags.h"
#include "third_party/blink/public/mojom/context_menu/context_menu.mojom.h"
#include "third_party/blink/public/mojom/forms/form_control_type.mojom-shared.h"
#include "third_party/blink/public/mojom/frame/media_player_action.mojom.h"
#include "ui/base/cocoa/menu_utils.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/gfx/text_elider.h"
#include "url/gurl.h"

@interface ARXContextMenuTarget : NSObject
@property(nonatomic) NSInteger chosen;
- (void)choose:(NSMenuItem*)sender;
@end

@implementation ARXContextMenuTarget
- (instancetype)init {
  if ((self = [super init])) _chosen = arx::kContextMenuNothing;
  return self;
}
- (void)choose:(NSMenuItem*)sender { self.chosen = sender.tag; }
@end

namespace arx {
namespace {

using Titles = std::array<std::string, ARX_CONTEXT_MENU_ITEM_COUNT>;

// Chrome offers up to five spelling suggestions.
constexpr size_t kMaxSuggestions = 5;
// Chrome's elided selection in "Look Up “…”" and "Search … for “…”".
constexpr size_t kTitleSelectionLength = 50;
constexpr size_t kMaxURLBytes = 8192;
constexpr size_t kMaxTextBytes = 4096;

Titles& ContextMenuTitles() {
  static base::NoDestructor<Titles> titles;
  return *titles;
}

const std::string& Title(int item) { return ContextMenuTitles()[item]; }

bool IsPassword(const content::ContextMenuParams& params) {
  return params.form_control_type == blink::mojom::FormControlType::kInputPassword;
}

bool HasFlag(int flags, int flag) { return (flags & flag) != 0; }

// An address the app may open or download: http(s), no credentials, bounded.
bool AppURL(const GURL& url) {
  return url.is_valid() && url.SchemeIsHTTPOrHTTPS() && !url.has_username() &&
      !url.has_password() && !url.spec().empty() && url.spec().size() <= kMaxURLBytes;
}

// What Copy … Address copies: any valid address but data: and blob:, which
// can be huge or mean nothing outside the page.
bool CopyableURL(const GURL& url) {
  return url.is_valid() && !url.SchemeIs("data") && !url.SchemeIsBlob() &&
      url.spec().size() <= kMaxURLBytes;
}

// What Save … As saves through the frame, as Chrome's Save Image As: a web,
// data: or blob: address the page loaded.
bool SavableURL(const GURL& url) {
  return url.is_valid() && (url.SchemeIsHTTPOrHTTPS() || url.SchemeIs("data") || url.SchemeIsBlob());
}

// An image with an address to save, or one whose pixels the renderer saves.
bool SavableImage(const content::ContextMenuParams& params) {
  return SavableURL(params.src_url) || (params.has_image_contents && params.src_url.is_empty());
}

// Chrome's Save Image, Video or Audio As: the frame's own request, with the
// frame's referrer, as a download that asks where to save it.
void SaveAs(content::WebContents* contents, content::RenderFrameHost* frame,
            const content::ContextMenuParams& params) {
  if (params.media_type == blink::mojom::ContextMenuDataMediaType::kImage &&
      params.has_image_contents && params.src_url.is_empty()) {
    frame->SaveImageAt(params.x, params.y);
    return;
  }
  if (!SavableURL(params.src_url)) return;
  net::HttpRequestHeaders headers;
  if (params.media_type == blink::mojom::ContextMenuDataMediaType::kImage)
    headers.SetHeaderIfMissing(net::HttpRequestHeaders::kAccept,
                               blink::network_utils::ImageAcceptHeader());
  const content::Referrer referrer = content::Referrer::SanitizeForRequest(
      params.src_url,
      content::Referrer(params.frame_url.GetAsReferrer(), params.referrer_policy));
  // As Chrome: a standalone image or media document is the frame's own
  // resource, so a POST-backed one is saved with its POST.
  contents->SaveFrameWithHeaders(params.src_url, referrer, headers.ToString(),
                                 params.suggested_filename, frame,
                                 /*is_subresource=*/!params.is_image_media_plugin_document);
}

// The selection shown in a title: one line, at most 50 characters.
std::u16string TitleSelection(const std::u16string& selection) {
  std::u16string line;
  base::ReplaceChars(selection, u"\r\n\t", u" ", &line);
  return gfx::TruncateString(base::CollapseWhitespace(line, true), kTitleSelectionLength,
                             gfx::WORD_BREAK);
}

// The title with its first "{}" replaced by the shortened selection.
NSString* SelectionTitle(int item, const std::u16string& selection) {
  std::u16string title = base::UTF8ToUTF16(Title(item));
  const size_t marker = title.find(u"{}");
  if (marker != std::u16string::npos) title.replace(marker, 2, TitleSelection(selection));
  return base::SysUTF16ToNSString(title);
}

bool SelectionItems(const content::ContextMenuParams& params) {
  return !params.selection_text.empty() && !IsPassword(params) &&
      !base::TrimWhitespace(params.selection_text, base::TRIM_ALL).empty();
}

PrefService* Prefs(content::WebContents* contents) {
  Profile* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  return profile ? profile->GetPrefs() : nullptr;
}

void WriteToPasteboard(const GURL& url) {
  NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
  [pasteboard clearContents];
  [pasteboard setString:base::SysUTF8ToNSString(url.spec()) forType:NSPasteboardTypeString];
}

void MediaAction(content::RenderFrameHost* frame, const content::ContextMenuParams& params,
                 blink::mojom::MediaPlayerActionType type, bool enable) {
  frame->ExecuteMediaPlayerActionAtLocation(gfx::Point(params.x, params.y),
                                            blink::mojom::MediaPlayerAction(type, enable));
}

// Builds one menu. Items Arx runs report through the target; the AppKit
// submenus (Substitutions, Speech) target the render widget's own view, which
// validates and carries them out as Chrome's Edit menu does.
class MenuBuilder {
 public:
  MenuBuilder(NSMenu* menu, ARXContextMenuTarget* target, uint64_t host_items)
      : menu_(menu), target_(target), host_items_(host_items) {}

  void Add(int item, bool enabled, NSMenu* into = nil) {
    AddTitled(item, base::SysUTF8ToNSString(Title(item)), enabled, into);
  }

  NSMenuItem* AddTitled(int item, NSString* title, bool enabled, NSMenu* into = nil) {
    if (IsAppContextMenuItem(item) && !(host_items_ & (uint64_t{1} << item))) return nil;
    NSMenuItem* entry = [(into ? into : menu_) addItemWithTitle:title action:@selector(choose:)
                                            keyEquivalent:@""];
    entry.target = target_;
    entry.tag = item;
    entry.enabled = enabled;
    return entry;
  }

  void AddChecked(int item, bool enabled, bool checked, NSMenu* into = nil) {
    AddTitled(item, base::SysUTF8ToNSString(Title(item)), enabled, into).state =
        checked ? NSControlStateValueOn : NSControlStateValueOff;
  }

  // A submenu of AppKit actions on view, validated by it (autoenabled).
  void AddResponderSubmenu(int title, NSView* view,
                           std::initializer_list<std::pair<int, SEL>> items) {
    NSMenu* submenu = [[NSMenu alloc] initWithTitle:base::SysUTF8ToNSString(Title(title))];
    submenu.autoenablesItems = YES;
    for (const auto& [item, action] : items) {
      if (![view respondsToSelector:action]) continue;
      NSMenuItem* entry = [submenu addItemWithTitle:base::SysUTF8ToNSString(Title(item))
                                             action:action
                                      keyEquivalent:@""];
      entry.target = view;
    }
    if (!submenu.numberOfItems) return;
    NSMenuItem* holder = [menu_ addItemWithTitle:submenu.title action:nil keyEquivalent:@""];
    holder.submenu = submenu;
    holder.enabled = YES;
  }

  NSMenu* NewSubmenu(int title) {
    NSMenu* submenu = [[NSMenu alloc] initWithTitle:base::SysUTF8ToNSString(Title(title))];
    submenu.autoenablesItems = NO;
    NSMenuItem* holder = [menu_ addItemWithTitle:submenu.title action:nil keyEquivalent:@""];
    holder.submenu = submenu;
    holder.enabled = YES;
    return submenu;
  }

  // A separator between groups, never first, last or doubled.
  void Separate() {
    NSMenuItem* last = menu_.itemArray.lastObject;
    if (last && !last.separatorItem) [menu_ addItem:[NSMenuItem separatorItem]];
  }

  void Finish() {
    NSMenuItem* last = menu_.itemArray.lastObject;
    if (last.separatorItem) [menu_ removeItem:last];
  }

  NSMenu* menu() const { return menu_; }

 private:
  NSMenu* menu_;
  ARXContextMenuTarget* target_;
  uint64_t host_items_;
};

void AddSpelling(MenuBuilder& builder, const content::ContextMenuParams& params) {
  if (!params.misspelled_word.empty()) {
    const size_t count = std::min(params.dictionary_suggestions.size(), kMaxSuggestions);
    for (size_t index = 0; index < count; ++index) {
      NSMenuItem* entry = builder.AddTitled(
          kContextMenuSuggestion + static_cast<int>(index),
          base::SysUTF16ToNSString(params.dictionary_suggestions[index]), true);
      // Bold, as AppKit and Safari show guesses.
      entry.attributedTitle = [[NSAttributedString alloc]
          initWithString:entry.title
              attributes:@{NSFontAttributeName : [NSFontManager.sharedFontManager
                                                     convertFont:[NSFont menuFontOfSize:0]
                                                     toHaveTrait:NSBoldFontMask]}];
    }
    if (!count) builder.Add(ARX_CONTEXT_MENU_NO_GUESSES, false);
    builder.Separate();
    builder.Add(ARX_CONTEXT_MENU_LEARN_SPELLING, true);
    builder.Separate();
  }
}

void AddEditableItems(MenuBuilder& builder, content::WebContents* contents, NSView* view,
                      const content::ContextMenuParams& params) {
  const int flags = params.edit_flags;
  const bool password = IsPassword(params);
  if (!password) AddSpelling(builder, params);
  if (SelectionItems(params)) {
    builder.AddTitled(ARX_CONTEXT_MENU_LOOK_UP,
                      SelectionTitle(ARX_CONTEXT_MENU_LOOK_UP, params.selection_text), true);
    builder.Separate();
  }
  // As Chromium's own editable menu on the Mac.
  builder.Add(ARX_CONTEXT_MENU_UNDO, HasFlag(flags, blink::ContextMenuDataEditFlags::kCanUndo));
  builder.Add(ARX_CONTEXT_MENU_REDO, HasFlag(flags, blink::ContextMenuDataEditFlags::kCanRedo));
  builder.Separate();
  builder.Add(ARX_CONTEXT_MENU_CUT, HasFlag(flags, blink::ContextMenuDataEditFlags::kCanCut));
  builder.Add(ARX_CONTEXT_MENU_COPY, HasFlag(flags, blink::ContextMenuDataEditFlags::kCanCopy));
  const bool paste = HasFlag(flags, blink::ContextMenuDataEditFlags::kCanPaste);
  builder.Add(ARX_CONTEXT_MENU_PASTE, paste);
  builder.Add(ARX_CONTEXT_MENU_PASTE_AND_MATCH_STYLE, paste);
  builder.Add(ARX_CONTEXT_MENU_SELECT_ALL,
              HasFlag(flags, blink::ContextMenuDataEditFlags::kCanSelectAll));
  builder.Separate();
  if (SelectionItems(params)) {
    builder.AddTitled(ARX_CONTEXT_MENU_SEARCH_SELECTION,
                      SelectionTitle(ARX_CONTEXT_MENU_SEARCH_SELECTION, params.selection_text),
                      true);
    builder.Add(ARX_CONTEXT_MENU_SHARE_SELECTION, true);
    builder.Separate();
  }
  if (password) return;

  // Spelling and Grammar: Chrome's own spellchecking preference.
  if (PrefService* prefs = Prefs(contents)) {
    NSMenu* spelling = builder.NewSubmenu(ARX_CONTEXT_MENU_SPELLING);
    const auto* preference = prefs->FindPreference(spellcheck::prefs::kSpellCheckEnable);
    builder.AddChecked(ARX_CONTEXT_MENU_CHECK_SPELLING_WHILE_TYPING,
                       preference && !preference->IsManaged(),
                       prefs->GetBoolean(spellcheck::prefs::kSpellCheckEnable), spelling);
  }
  builder.AddResponderSubmenu(ARX_CONTEXT_MENU_SUBSTITUTIONS, view, {
      {ARX_CONTEXT_MENU_SHOW_SUBSTITUTIONS, @selector(orderFrontSubstitutionsPanel:)},
      {ARX_CONTEXT_MENU_SMART_QUOTES, @selector(toggleAutomaticQuoteSubstitution:)},
      {ARX_CONTEXT_MENU_SMART_DASHES, @selector(toggleAutomaticDashSubstitution:)},
      {ARX_CONTEXT_MENU_TEXT_REPLACEMENT, @selector(toggleAutomaticTextReplacement:)},
  });
  builder.AddResponderSubmenu(ARX_CONTEXT_MENU_SPEECH, view, {
      {ARX_CONTEXT_MENU_START_SPEAKING, @selector(startSpeaking:)},
      {ARX_CONTEXT_MENU_STOP_SPEAKING, @selector(stopSpeaking:)},
  });
  builder.Separate();
}

void AddSelectionItems(MenuBuilder& builder, NSView* view,
                       const content::ContextMenuParams& params) {
  // Copy for any selection, also one of only spaces; the rest need words.
  const bool words = SelectionItems(params);
  if (words) {
    builder.AddTitled(ARX_CONTEXT_MENU_LOOK_UP,
                      SelectionTitle(ARX_CONTEXT_MENU_LOOK_UP, params.selection_text), true);
    builder.Separate();
  }
  builder.Add(ARX_CONTEXT_MENU_COPY,
              HasFlag(params.edit_flags, blink::ContextMenuDataEditFlags::kCanCopy));
  builder.Separate();
  if (!words) return;
  builder.AddTitled(ARX_CONTEXT_MENU_SEARCH_SELECTION,
                    SelectionTitle(ARX_CONTEXT_MENU_SEARCH_SELECTION, params.selection_text),
                    true);
  builder.Add(ARX_CONTEXT_MENU_SHARE_SELECTION, true);
  builder.Separate();
  builder.AddResponderSubmenu(ARX_CONTEXT_MENU_SPEECH, view, {
      {ARX_CONTEXT_MENU_START_SPEAKING, @selector(startSpeaking:)},
      {ARX_CONTEXT_MENU_STOP_SPEAKING, @selector(stopSpeaking:)},
  });
  builder.Separate();
}

void AddImageItems(MenuBuilder& builder, const content::ContextMenuParams& params) {
  builder.Add(ARX_CONTEXT_MENU_OPEN_IMAGE_IN_NEW_TAB, AppURL(params.src_url));
  builder.Add(ARX_CONTEXT_MENU_DOWNLOAD_IMAGE, SavableImage(params));
  builder.Separate();
  builder.Add(ARX_CONTEXT_MENU_COPY_IMAGE, params.has_image_contents);
  builder.Add(ARX_CONTEXT_MENU_COPY_IMAGE_ADDRESS, CopyableURL(params.src_url));
  builder.Separate();
}

void AddMediaItems(MenuBuilder& builder, const content::ContextMenuParams& params, bool video) {
  using Data = blink::ContextMenuData;
  const int flags = params.media_flags;
  const bool error = HasFlag(flags, Data::kMediaInError);
  builder.AddChecked(ARX_CONTEXT_MENU_LOOP, !error && HasFlag(flags, Data::kMediaCanLoop),
                     HasFlag(flags, Data::kMediaLoop));
  builder.AddChecked(ARX_CONTEXT_MENU_SHOW_CONTROLS,
                     !error && HasFlag(flags, Data::kMediaCanToggleControls),
                     HasFlag(flags, Data::kMediaControls));
  if (video) {
    builder.AddChecked(ARX_CONTEXT_MENU_PICTURE_IN_PICTURE,
                       !error && HasFlag(flags, Data::kMediaCanPictureInPicture),
                       HasFlag(flags, Data::kMediaPictureInPicture));
    builder.Add(ARX_CONTEXT_MENU_COPY_VIDEO_FRAME,
                !error && HasFlag(flags, Data::kMediaHasReadableVideoFrame) &&
                    !HasFlag(flags, Data::kMediaEncrypted));
  }
  builder.Separate();
  const bool savable = SavableURL(params.src_url) && HasFlag(flags, Data::kMediaCanSave);
  builder.Add(video ? ARX_CONTEXT_MENU_OPEN_VIDEO_IN_NEW_TAB : ARX_CONTEXT_MENU_OPEN_AUDIO_IN_NEW_TAB,
              AppURL(params.src_url));
  builder.Add(video ? ARX_CONTEXT_MENU_DOWNLOAD_VIDEO : ARX_CONTEXT_MENU_DOWNLOAD_AUDIO, savable);
  builder.Add(video ? ARX_CONTEXT_MENU_COPY_VIDEO_ADDRESS : ARX_CONTEXT_MENU_COPY_AUDIO_ADDRESS,
              CopyableURL(params.src_url));
  builder.Separate();
}

}  // namespace

void ConfigureContextMenus(const char* const* titles, size_t count) {
  Titles copied;
  if (titles && count == ARX_CONTEXT_MENU_ITEM_COUNT) {
    for (size_t index = 0; index < count; ++index) {
      const char* title = titles[index];
      if (!title || strnlen(title, 257) > 256) { copied = {}; break; }
      copied[index] = title;
    }
  }
  ContextMenuTitles() = std::move(copied);
}

bool ContextMenusConfigured() {
  for (const auto& title : ContextMenuTitles())
    if (title.empty()) return false;
  return true;
}

ContextMenuKind ContextMenuKindFor(const content::ContextMenuParams& params) {
  if (params.is_editable) return ContextMenuKind::kEditable;
  // Checkboxes, buttons, selects and other controls keep what they had, and so
  // do links the link menu didn't take (non-http(s), in a non-web page...).
  if (params.form_control_type.has_value() || !params.link_url.is_empty() ||
      !params.unfiltered_link_url.is_empty()) return ContextMenuKind::kNone;
  switch (params.media_type) {
    case blink::mojom::ContextMenuDataMediaType::kImage: return ContextMenuKind::kImage;
    case blink::mojom::ContextMenuDataMediaType::kVideo: return ContextMenuKind::kVideo;
    case blink::mojom::ContextMenuDataMediaType::kAudio: return ContextMenuKind::kAudio;
    case blink::mojom::ContextMenuDataMediaType::kNone:
      return params.selection_text.empty() ? ContextMenuKind::kNone : ContextMenuKind::kSelection;
    default: return ContextMenuKind::kNone;
  }
}

bool IsAppContextMenuItem(int item) {
  switch (item) {
    case ARX_CONTEXT_MENU_SEARCH_SELECTION:
    case ARX_CONTEXT_MENU_SHARE_SELECTION:
    case ARX_CONTEXT_MENU_OPEN_IMAGE_IN_NEW_TAB:
    case ARX_CONTEXT_MENU_OPEN_VIDEO_IN_NEW_TAB:
    case ARX_CONTEXT_MENU_OPEN_AUDIO_IN_NEW_TAB:
    // Arx's media bridge refuses PiP a page asks for; the app enters ArxPiP.
    case ARX_CONTEXT_MENU_PICTURE_IN_PICTURE: return true;
    default: return false;
  }
}

ContextMenuSelection RunContextMenu(content::WebContents* contents,
                                    const content::ContextMenuParams& params,
                                    uint64_t host_items, const std::string& inspect_title) {
  ContextMenuSelection none;
  const ContextMenuKind kind = ContextMenuKindFor(params);
  if (!contents || kind == ContextMenuKind::kNone || !ContextMenusConfigured()) return none;
  content::RenderWidgetHostView* widget = contents->GetRenderWidgetHostView();
  NSView* view = widget ? widget->GetNativeView().GetNativeNSView() : nil;
  if (!view || !view.window || !view.window.visible || view.window.miniaturized ||
      view.hiddenOrHasHiddenAncestor) return none;

  ARXContextMenuTarget* target = [[ARXContextMenuTarget alloc] init];
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
  menu.autoenablesItems = NO;
  MenuBuilder builder(menu, target, host_items);
  switch (kind) {
    case ContextMenuKind::kEditable: AddEditableItems(builder, contents, view, params); break;
    case ContextMenuKind::kSelection: AddSelectionItems(builder, view, params); break;
    case ContextMenuKind::kImage: AddImageItems(builder, params); break;
    case ContextMenuKind::kVideo: AddMediaItems(builder, params, true); break;
    case ContextMenuKind::kAudio: AddMediaItems(builder, params, false); break;
    case ContextMenuKind::kNone: break;
  }
  // DEV-890: extensions' items, before Inspect Element as in Chrome.
  auto extensions = std::make_shared<ExtensionMenuItems>(contents, params);
  extensions->AppendTo(menu, target, @selector(choose:));
  if (!inspect_title.empty()) {
    builder.Separate();
    NSMenuItem* inspect = [menu addItemWithTitle:base::SysUTF8ToNSString(inspect_title)
                                          action:@selector(choose:)
                                   keyEquivalent:@""];
    inspect.target = target;
    inspect.tag = kContextMenuInspect;
    inspect.enabled = YES;
  }
  builder.Finish();
  if (!menu.numberOfItems) return none;

  // As Chrome's RenderViewContextMenuMacCocoa: the click's own event when there
  // is one, else one at the menu's point, on the render widget's view.
  const NSPoint point =
      NSMakePoint(params.x, view.isFlipped ? params.y : NSHeight(view.bounds) - params.y);
  NSEvent* event = ui::EventForPositioningContextMenuRelativeToWindow(
      [view convertPoint:point toView:nil], view.window);
  ui::ShowContextMenu(menu, event, view, /*allow_nested_tasks=*/true);

  ContextMenuSelection selection;
  selection.item = static_cast<int>(target.chosen);
  if (ExtensionMenuItems::IsCommand(selection.item)) {
    selection.extension_command = selection.item;
    selection.item = kContextMenuExtension;
    selection.extensions = std::move(extensions);
    return selection;
  }
  if (selection.item >= kContextMenuSuggestion) {
    const size_t index = static_cast<size_t>(selection.item - kContextMenuSuggestion);
    if (index >= params.dictionary_suggestions.size() || index >= kMaxSuggestions) return none;
    selection.suggestion = params.dictionary_suggestions[index];
    selection.item = kContextMenuSuggestion;
  }
  return selection;
}

void PerformContextMenuItem(content::WebContents* contents, content::RenderFrameHost* frame,
                            const content::ContextMenuParams& params,
                            const ContextMenuSelection& selection) {
  if (!contents || !frame) return;
  using Action = blink::mojom::MediaPlayerActionType;
  using Data = blink::ContextMenuData;
  switch (selection.item) {
    case kContextMenuExtension:
      if (selection.extensions)
        selection.extensions->Execute(selection.extension_command, contents, frame);
      break;
    case kContextMenuSuggestion: contents->ReplaceMisspelling(selection.suggestion); break;
    case ARX_CONTEXT_MENU_UNDO: contents->Undo(); break;
    case ARX_CONTEXT_MENU_REDO: contents->Redo(); break;
    case ARX_CONTEXT_MENU_CUT: contents->Cut(); break;
    case ARX_CONTEXT_MENU_COPY: contents->Copy(); break;
    case ARX_CONTEXT_MENU_PASTE: contents->Paste(); break;
    case ARX_CONTEXT_MENU_PASTE_AND_MATCH_STYLE: contents->PasteAndMatchStyle(); break;
    case ARX_CONTEXT_MENU_SELECT_ALL: contents->SelectAll(); break;
    case ARX_CONTEXT_MENU_LEARN_SPELLING: {
      // As Chrome's Add to Dictionary: the profile's custom dictionary, and
      // macOS's own spellchecker, which Chromium uses on the Mac.
      if (params.misspelled_word.empty()) break;
      SpellcheckService* spellcheck =
          SpellcheckServiceFactory::GetForContext(contents->GetBrowserContext());
      if (!spellcheck) break;
      spellcheck->GetCustomDictionary()->AddWord(base::UTF16ToUTF8(params.misspelled_word));
#if BUILDFLAG(USE_BROWSER_SPELLCHECKER)
      if (spellcheck::UseBrowserSpellChecker())
        spellcheck_platform::AddWord(spellcheck->platform_spell_checker(), params.misspelled_word);
#endif
      break;
    }
    case ARX_CONTEXT_MENU_CHECK_SPELLING_WHILE_TYPING: {
      PrefService* prefs = Prefs(contents);
      if (!prefs) break;
      const auto* preference = prefs->FindPreference(spellcheck::prefs::kSpellCheckEnable);
      if (!preference || preference->IsManaged()) break;
      prefs->SetBoolean(spellcheck::prefs::kSpellCheckEnable,
                        !prefs->GetBoolean(spellcheck::prefs::kSpellCheckEnable));
      break;
    }
    case ARX_CONTEXT_MENU_LOOK_UP:
      if (auto* view = frame->GetRenderWidgetHost()->GetView()) view->ShowDefinitionForSelection();
      break;
    case ARX_CONTEXT_MENU_COPY_IMAGE: frame->CopyImageAt(params.x, params.y); break;
    case ARX_CONTEXT_MENU_DOWNLOAD_IMAGE:
    case ARX_CONTEXT_MENU_DOWNLOAD_VIDEO:
    case ARX_CONTEXT_MENU_DOWNLOAD_AUDIO: SaveAs(contents, frame, params); break;
    case ARX_CONTEXT_MENU_COPY_IMAGE_ADDRESS:
    case ARX_CONTEXT_MENU_COPY_VIDEO_ADDRESS:
    case ARX_CONTEXT_MENU_COPY_AUDIO_ADDRESS:
      if (CopyableURL(params.src_url)) WriteToPasteboard(params.src_url);
      break;
    case ARX_CONTEXT_MENU_LOOP:
      MediaAction(frame, params, Action::kLoop, !HasFlag(params.media_flags, Data::kMediaLoop));
      break;
    case ARX_CONTEXT_MENU_SHOW_CONTROLS:
      MediaAction(frame, params, Action::kControls,
                  !HasFlag(params.media_flags, Data::kMediaControls));
      break;
    case ARX_CONTEXT_MENU_COPY_VIDEO_FRAME:
      MediaAction(frame, params, Action::kCopyVideoFrame, true);
      break;
    default: break;
  }
}

bool ContextMenuPayload(const content::ContextMenuParams& params, int item, std::string* url,
                        std::string* text) {
  url->clear();
  text->clear();
  switch (item) {
    case ARX_CONTEXT_MENU_SEARCH_SELECTION:
    case ARX_CONTEXT_MENU_SHARE_SELECTION: {
      if (!SelectionItems(params)) return false;
      base::TruncateUTF8ToByteSize(base::UTF16ToUTF8(params.selection_text), kMaxTextBytes, text);
      return !text->empty() && text->find('\0') == std::string::npos;
    }
    case ARX_CONTEXT_MENU_PICTURE_IN_PICTURE:
      return params.media_type == blink::mojom::ContextMenuDataMediaType::kVideo;
    case ARX_CONTEXT_MENU_OPEN_IMAGE_IN_NEW_TAB:
    case ARX_CONTEXT_MENU_OPEN_VIDEO_IN_NEW_TAB:
    case ARX_CONTEXT_MENU_OPEN_AUDIO_IN_NEW_TAB:
      if (!AppURL(params.src_url)) return false;
      *url = params.src_url.spec();
      return true;
    default: return false;
  }
}

}  // namespace arx
