#include "chrome/browser/arx/autofill_bridge.h"

#import <LocalAuthentication/LocalAuthentication.h>

#include <cstring>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/callback_list.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "base/i18n/rtl.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/autofill/chrome_autofill_client.h"
#include "components/autofill/core/common/autofill_prefs.h"
#include "components/prefs/pref_service.h"
#include "components/autofill/core/browser/filling/filling_product.h"
#include "components/autofill/core/browser/foundations/autofill_client.h"
#include "components/autofill/core/browser/suggestions/suggestion.h"
#include "components/autofill/core/browser/suggestions/suggestion_hiding_reason.h"
#include "components/autofill/core/browser/suggestions/suggestion_type.h"
#include "components/autofill/core/browser/ui/autofill_suggestion_delegate.h"
#include "components/input/native_web_keyboard_event.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/focused_node_details.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/browser/host_zoom_map.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "third_party/blink/public/common/input/web_input_event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/geometry/rect_f.h"

namespace arx {
namespace {
using autofill::AutofillSuggestionDelegate;
using autofill::ChromeAutofillClient;
using autofill::FillingProduct;
using autofill::Suggestion;
using autofill::SuggestionHidingReason;
using autofill::SuggestionType;
using SessionId = autofill::AutofillClient::SuggestionUiSessionId;

constexpr size_t kMaximumItems = 64;
constexpr size_t kMaximumTextBytes = 256;
constexpr size_t kMaximumReasonBytes = 256;
// As Chrome's popup: a choice this soon after a list appears was meant for the
// page under it, and is ignored.
constexpr base::TimeDelta kIgnoreEarlyAccepts = base::Milliseconds(500);

std::optional<std::string> Reason(const char* text) {
  const size_t length = text ? strnlen(text, kMaximumReasonBytes + 1) : 0;
  if (!length || length > kMaximumReasonBytes) return std::nullopt;
  return std::string(text, length);
}

// What the app may show for a suggestion. Anything else is left out.
enum class Kind {
  kNone, kPassword, kAddress, kCard, kText, kUndo,
  kManagePasswords, kManageAddresses, kManageCards,
};

Kind KindOf(SuggestionType type) {
  switch (type) {
    case SuggestionType::kPasswordEntry:
    case SuggestionType::kAccountStoragePasswordEntry:
      return Kind::kPassword;
    case SuggestionType::kAddressEntry:
    case SuggestionType::kAddressFieldByFieldFilling:
    case SuggestionType::kAddressEntryOnTyping:
      return Kind::kAddress;
    // Local cards only; server and virtual cards need Google Payments.
    case SuggestionType::kCreditCardEntry:
      return Kind::kCard;
    case SuggestionType::kAutocompleteEntry:
    case SuggestionType::kDatalistEntry:
      return Kind::kText;
    case SuggestionType::kUndo:
      return Kind::kUndo;
    case SuggestionType::kAllSavedPasswordsEntry:
      return Kind::kManagePasswords;
    case SuggestionType::kManageAddress:
      return Kind::kManageAddresses;
    case SuggestionType::kManageCreditCard:
      return Kind::kManageCards;
    default:
      return Kind::kNone;
  }
}

const char* KindName(Kind kind) {
  switch (kind) {
    case Kind::kPassword: return "password";
    case Kind::kAddress: return "address";
    case Kind::kCard: return "card";
    case Kind::kText: return "text";
    case Kind::kUndo: return "undo";
    case Kind::kManagePasswords: return "managePasswords";
    case Kind::kManageAddresses: return "manageAddresses";
    case Kind::kManageCards: return "manageCards";
    case Kind::kNone: return "none";
  }
  return "none";
}

// Opened in the app's Settings instead of Chrome's settings page.
const char* SettingsOf(Kind kind) {
  switch (kind) {
    case Kind::kManagePasswords: return "passwords";
    case Kind::kManageAddresses: return "addresses";
    case Kind::kManageCards: return "cards";
    default: return nullptr;
  }
}

const char* ProductName(FillingProduct product) {
  switch (product) {
    case FillingProduct::kPassword: return "password";
    case FillingProduct::kAddress: return "address";
    case FillingProduct::kCreditCard: return "card";
    default: return "other";
  }
}

std::string Bounded(const std::u16string& text) {
  std::string value = base::UTF16ToUTF8(text);
  if (value.size() <= kMaximumTextBytes) return value;
  size_t end = kMaximumTextBytes;
  while (end > 0 && (static_cast<unsigned char>(value[end]) & 0xC0) == 0x80) --end;
  return value.substr(0, end);
}

// Chrome labels a password suggestion with dots for its password; the app
// shows only the account and its site.
bool Masked(const std::u16string& text) {
  if (text.empty()) return false;
  for (char16_t c : text)
    if (c != u'•' && c != u'●' && c != u'*' && c != u' ') return false;
  return true;
}

bool NeedsAuthentication(Kind kind, ArxAutofillAuthentication mode) {
  switch (kind) {
    case Kind::kCard: return true;
    case Kind::kPassword: return mode != ARX_AUTOFILL_FILL_PASSWORDS_WITHOUT_ASKING;
    default: return false;
  }
}

struct Showing {
  SessionId id;
  // What the app knows this list by. A new list (shown or updated) gets a new
  // one, so a choice made from a list the page has since replaced is refused.
  uint64_t token = 0;
  // When the app was sent this list.
  base::TimeTicks shown_at;
  std::vector<Suggestion> suggestions;
  FillingProduct product = FillingProduct::kNone;
  base::WeakPtr<AutofillSuggestionDelegate> delegate;
  autofill::FormGlobalId form;
  autofill::FieldGlobalId field;
  gfx::RectF bounds;
  bool rtl = false;
  int selected = -1;
  // OnSuggestionsShown was delivered, so OnSuggestionsHidden must follow.
  bool shown = false;
  content::WeakDocumentPtr document;
  content::GlobalRenderFrameHostId keys_frame;
  content::RenderWidgetHost::KeyPressEventCallback keys;
};

class Embedder;

// A fill waiting for the device owner.
struct Pending {
  uint64_t page = 0;
  // Suggestion has no default constructor.
  std::optional<Suggestion> suggestion;
  AutofillSuggestionDelegate::SuggestionMetadata metadata;
  autofill::FormGlobalId form;
  autofill::FieldGlobalId field;
  base::WeakPtr<AutofillSuggestionDelegate> delegate;
  content::WeakDocumentPtr document;
  content::WeakDocumentPtr main;
  LAContext* context = nil;
};

class PageWatch final : public content::WebContentsObserver {
 public:
  PageWatch(content::WebContents* contents, uint64_t page);

  void OnVisibilityChanged(content::Visibility visibility) override;
  void FrameSizeChanged(content::RenderFrameHost* frame, const gfx::Size&) override;
  void OnWebContentsLostFocus(content::RenderWidgetHost*) override;
  void OnFocusChangedInPage(const content::FocusedNodeDetails&) override;
  void RenderFrameDeleted(content::RenderFrameHost* frame) override;
  void RenderFrameHostStateChanged(content::RenderFrameHost* frame,
                                   content::RenderFrameHost::LifecycleState old_state,
                                   content::RenderFrameHost::LifecycleState new_state) override;
  void DidFinishNavigation(content::NavigationHandle* navigation) override;
  void PrimaryPageChanged(content::Page&) override;
  void WebContentsDestroyed() override;

 private:
  const uint64_t page_;
  base::CallbackListSubscription zoom_;
};

// The frame the suggestions' field is in.
content::RenderFrameHost* FieldFrame(content::WebContents* contents,
                                     const autofill::FieldGlobalId& field) {
  content::RenderFrameHost* found = nullptr;
  contents->ForEachRenderFrameHost([&](content::RenderFrameHost* frame) {
    if (!found && autofill::LocalFrameToken(frame->GetFrameToken().value()) == field.frame_token)
      found = frame;
  });
  return found;
}

class Embedder final : public ChromeAutofillClient::EmbedderSuggestions {
 public:
  AutofillSuggestionsChanged changed = nullptr;
  ArxAutofillAuthentication authentication = ARX_AUTOFILL_ASK_DEVICE_OWNER;
  bool addresses = true;
  bool cards = true;
  std::map<uint64_t, base::WeakPtr<content::WebContents>> pages;
  std::map<uint64_t, std::unique_ptr<PageWatch>> watches;
  std::map<uint64_t, Showing> sessions;
  // The session the app was last told is shown, per page.
  std::map<uint64_t, uint64_t> told;
  std::string password_reason, card_reason;
  std::map<uint64_t, Pending> pending;
  uint64_t next_fill = 1;
  uint64_t next_token = 1;

  std::optional<uint64_t> PageOf(const content::WebContents* contents) const {
    for (const auto& [page, weak] : pages)
      if (weak.get() == contents) return page;
    return std::nullopt;
  }

  // ChromeAutofillClient::EmbedderSuggestions:
  bool Show(content::WebContents* contents, SessionId id,
            const autofill::AutofillClient::PopupOpenArgs& args,
            base::WeakPtr<AutofillSuggestionDelegate> delegate) override {
    const auto page = PageOf(contents);
    // Not an Arx page Arx attached clients to: leave it to Chrome.
    if (!page || !changed) return false;
    // A new query: a fill still waiting for the device owner was for another.
    CancelPending(*page);
    Retire(*page);
    // Only for the field that has focus: suggestions for an iframe that lost
    // it on the way here are dropped.
    auto* frame = FieldFrame(contents, args.field_id);
    if (!frame || frame != contents->GetFocusedFrame() || !delegate ||
        Count(args.suggestions) == 0) {
      TellHidden(*page, nullptr);
      return true;
    }
    Showing& session = sessions[*page];
    session.id = id;
    session.suggestions = args.suggestions;
    session.product = delegate->GetMainFillingProduct();
    session.delegate = delegate;
    session.form = args.form_id;
    session.field = args.field_id;
    session.bounds = args.element_bounds;
    session.rtl = args.text_direction == base::i18n::RIGHT_TO_LEFT;
    session.document = frame->GetWeakDocumentPtr();
    const autofill::FieldGlobalId expected = delegate->GetQueriedFieldId();
    // Like Chrome's popup, after the current task: the delegate finishes
    // asking first, and a newer query for another field wins.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
        [](uint64_t page, SessionId id, autofill::FieldGlobalId expected) {
          Self().Present(page, id, expected);
        }, *page, id, expected));
    return true;
  }

  bool Update(content::WebContents* contents, const std::vector<Suggestion>& suggestions,
              FillingProduct product) override {
    const auto page = PageOf(contents);
    if (!page) return false;
    auto found = sessions.find(*page);
    if (found == sessions.end()) return false;
    if (product != found->second.product || Count(suggestions) == 0) {
      End(*page, SuggestionHidingReason::kStaleData, nullptr);
      return true;
    }
    found->second.suggestions = suggestions;
    found->second.selected = -1;
    if (found->second.shown) Notify(*page, /*fresh=*/true);
    return true;
  }

  void Hide(content::WebContents* contents, SuggestionHidingReason reason,
            std::optional<FillingProduct> product) override {
    const auto page = PageOf(contents);
    if (!page) return;
    auto found = sessions.find(*page);
    if (found != sessions.end() && product && *product != found->second.product) return;
    End(*page, reason, nullptr);
  }

  std::optional<SessionId> Session(const content::WebContents* contents) const override {
    const auto page = PageOf(contents);
    if (!page) return std::nullopt;
    auto found = sessions.find(*page);
    if (found == sessions.end()) return std::nullopt;
    return found->second.id;
  }

  base::span<const Suggestion> Suggestions(const content::WebContents* contents) const override {
    const auto page = PageOf(contents);
    auto found = page ? sessions.find(*page) : sessions.end();
    if (found == sessions.end()) return {};
    return found->second.suggestions;
  }

  // The app answers.
  bool Accept(uint64_t page, uint64_t id, uint32_t index) {
    auto found = sessions.find(page);
    if (found == sessions.end() || found->second.token != id ||
        index >= found->second.suggestions.size())
      return false;
    auto& session = found->second;
    if (!Exported(session.suggestions, index)) return false;
    // Too early: ignored, and the list stays.
    if (base::TimeTicks::Now() - session.shown_at < kIgnoreEarlyAccepts) return true;
    const Suggestion& suggestion = session.suggestions[index];
    const Kind kind = KindOf(suggestion.type);
    if (const char* settings = SettingsOf(kind)) {
      End(page, SuggestionHidingReason::kAcceptSuggestion, settings);
      return true;
    }
    auto* main = MainFrame(page);
    if (!main || !session.document.AsRenderFrameHostIfValid() || !session.delegate) {
      End(page, SuggestionHidingReason::kStaleData, nullptr);
      return false;
    }

    Pending fill;
    fill.page = page;
    fill.suggestion = suggestion;
    fill.metadata.multi_index = {index};
    fill.form = session.form;
    fill.field = session.field;
    fill.delegate = session.delegate;
    fill.document = session.document;
    fill.main = main->GetWeakDocumentPtr();

    if (!NeedsAuthentication(kind, authentication)) {
      // Chrome's order: the delegate fills, then hides the suggestions.
      fill.delegate->DidAcceptSuggestion(*fill.suggestion, fill.metadata, fill.form, fill.field);
      End(page, SuggestionHidingReason::kAcceptSuggestion, nullptr);
      return true;
    }

    const std::string& reason = kind == Kind::kCard ? card_reason : password_reason;
    // As Chrome does before its own reauthentication: the suggestions go
    // first, and the fill waits for the device owner.
    End(page, SuggestionHidingReason::kAcceptSuggestion, nullptr);
    if (authentication == ARX_AUTOFILL_REFUSE_AUTHENTICATED_FILLS) return true;
    LAContext* context = [[LAContext alloc] init];
    NSError* error = nil;
    if (reason.empty() ||
        ![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error])
      return true;
    // One fill waits at a time; a newer choice replaces it.
    for (auto& [token, waiting] : pending) [waiting.context invalidate];
    pending.clear();
    const uint64_t token = next_fill++;
    fill.context = context;
    pending.emplace(token, std::move(fill));
    auto runner = base::SingleThreadTaskRunner::GetCurrentDefault();
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:base::SysUTF8ToNSString(reason)
                      reply:^(BOOL success, NSError*) {
                        runner->PostTask(FROM_HERE, base::BindOnce(
                            [](uint64_t token, bool success) { Self().Authenticated(token, success); },
                            token, success == YES));
                      }];
    return true;
  }

  void Select(uint64_t page, uint64_t id, int32_t index) {
    auto found = sessions.find(page);
    if (found == sessions.end() || found->second.token != id) return;
    const auto& suggestions = found->second.suggestions;
    if (index < 0 || !Exported(suggestions, static_cast<size_t>(index))) index = -1;
    found->second.selected = index;
  }

  void Dismiss(uint64_t page, uint64_t id) {
    auto found = sessions.find(page);
    if (found == sessions.end() || found->second.token != id) return;
    End(page, SuggestionHidingReason::kUserAborted, nullptr);
  }

  // The field's frame went away, left the active page or navigated: its
  // suggestions and any fill waiting for them go too.
  void FrameChanged(uint64_t page) {
    for (auto it = pending.begin(); it != pending.end();) {
      if (it->second.page == page && !it->second.document.AsRenderFrameHostIfValid()) {
        [it->second.context invalidate];
        it = pending.erase(it);
      } else {
        ++it;
      }
    }
    auto found = sessions.find(page);
    if (found == sessions.end()) return;
    auto* frame = found->second.document.AsRenderFrameHostIfValid();
    if (!frame || !frame->IsActive())
      End(page, SuggestionHidingReason::kViewDestroyed, nullptr);
  }

  // Drops a page's fill waiting for the device owner.
  void CancelPending(uint64_t page) {
    for (auto it = pending.begin(); it != pending.end();) {
      if (it->second.page == page) {
        [it->second.context invalidate];
        it = pending.erase(it);
      } else {
        ++it;
      }
    }
  }

  void Forget(uint64_t page) {
    End(page, SuggestionHidingReason::kTabGone, nullptr);
    CancelPending(page);
    told.erase(page);
    watches.erase(page);
    pages.erase(page);
  }

  void Stop() {
    std::vector<uint64_t> shown;
    for (const auto& [page, session] : sessions) shown.push_back(page);
    for (uint64_t page : shown) End(page, SuggestionHidingReason::kViewDestroyed, nullptr);
    for (auto& [token, waiting] : pending) [waiting.context invalidate];
    pending.clear();
    told.clear();
    watches.clear();
    pages.clear();
    changed = nullptr;
  }

  // Ends a page's suggestions: no keys, the delegate told, the app told.
  void End(uint64_t page, SuggestionHidingReason reason, const char* settings) {
    auto found = sessions.find(page);
    if (found == sessions.end()) return TellHidden(page, settings);
    Showing session = std::move(found->second);
    sessions.erase(found);
    ReleaseKeys(session);
    if (session.shown) {
      if (session.delegate) {
        session.delegate->ClearPreviewedForm();
        session.delegate->OnSuggestionsHidden(reason);
      }
    }
    TellHidden(page, settings);
  }

  // A newer Show replaces the page's session. The delegate hears of it after
  // the current task, as with Chrome's popup; the app only once the new one is
  // shown or fails to.
  void Retire(uint64_t page) {
    auto found = sessions.find(page);
    if (found == sessions.end()) return;
    Showing session = std::move(found->second);
    sessions.erase(found);
    ReleaseKeys(session);
    if (!session.shown || !session.delegate) return;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
        [](base::WeakPtr<AutofillSuggestionDelegate> delegate) {
          if (!delegate) return;
          delegate->ClearPreviewedForm();
          delegate->OnSuggestionsHidden(SuggestionHidingReason::kStaleData);
        }, session.delegate));
  }

  void TellHidden(uint64_t page, const char* settings) {
    auto told_session = told.find(page);
    if (told_session == told.end()) return;
    const uint64_t id = told_session->second;
    told.erase(told_session);
    base::DictValue body;
    body.Set("state", "hidden");
    if (settings) body.Set("open", settings);
    Post(page, id, std::move(body));
  }

  static Embedder& Self();

 private:
  static bool Selectable(const Suggestion& suggestion) {
    return KindOf(suggestion.type) != Kind::kNone && suggestion.IsAcceptable();
  }

  // Selectable and among the first kMaximumItems the app was sent: the arrow
  // keys, a selection and an accept reach only what the app can show.
  static bool Exported(const std::vector<Suggestion>& suggestions, size_t index) {
    if (index >= suggestions.size() || !Selectable(suggestions[index])) return false;
    size_t before = 0;
    for (size_t i = 0; i < index; ++i)
      if (Selectable(suggestions[i])) ++before;
    return before < kMaximumItems;
  }

  static size_t Count(const std::vector<Suggestion>& suggestions) {
    size_t count = 0;
    for (const auto& suggestion : suggestions)
      if (Selectable(suggestion)) ++count;
    return count;
  }

  content::RenderFrameHost* MainFrame(uint64_t page) {
    auto found = pages.find(page);
    auto* contents = found == pages.end() ? nullptr : found->second.get();
    return contents ? contents->GetPrimaryMainFrame() : nullptr;
  }

  void Present(uint64_t page, SessionId id, autofill::FieldGlobalId expected) {
    auto found = sessions.find(page);
    if (found == sessions.end() || found->second.id != id || found->second.shown) return;
    auto& session = found->second;
    auto* frame = session.document.AsRenderFrameHostIfValid();
    auto page_found = pages.find(page);
    auto* contents = page_found == pages.end() ? nullptr : page_found->second.get();
    if (!session.delegate || !frame || !contents || contents->GetFocusedFrame() != frame ||
        (expected && session.delegate->GetQueriedFieldId() != expected)) {
      sessions.erase(found);
      TellHidden(page, nullptr);
      return;
    }
    session.shown = true;
    session.keys_frame = frame->GetGlobalId();
    session.keys = base::BindRepeating(
        [](uint64_t page, uint32_t id, const input::NativeWebKeyboardEvent& event) {
          return Self().Key(page, id, event);
        }, page, id.value());
    frame->GetRenderWidgetHost()->AddKeyPressEventCallback(session.keys);
    session.delegate->OnSuggestionsShown(session.suggestions, {});
    // The delegate may have hidden them while it was told.
    if (sessions.contains(page) && sessions.at(page).id == id) Notify(page, /*fresh=*/true);
  }

  // Arrows move the selection, Return fills the selected suggestion, Escape
  // closes. Everything else, and anything with a modifier, reaches the page.
  bool Key(uint64_t page, uint32_t id, const input::NativeWebKeyboardEvent& event) {
    auto found = sessions.find(page);
    if (found == sessions.end() || found->second.id.value() != id) return false;
    if (event.GetType() != blink::WebInputEvent::Type::kRawKeyDown) return false;
    constexpr int kModifiers = blink::WebInputEvent::kShiftKey | blink::WebInputEvent::kControlKey |
        blink::WebInputEvent::kAltKey | blink::WebInputEvent::kMetaKey;
    if (event.GetModifiers() & kModifiers) return false;
    auto& session = found->second;
    switch (event.windows_key_code) {
      case ui::VKEY_DOWN:
      case ui::VKEY_UP: {
        const int count = static_cast<int>(session.suggestions.size());
        const int step = event.windows_key_code == ui::VKEY_DOWN ? 1 : -1;
        int index = session.selected;
        for (int tries = 0; tries < count; ++tries) {
          index = index < 0 ? (step > 0 ? 0 : count - 1) : (index + step + count) % count;
          if (Exported(session.suggestions, static_cast<size_t>(index))) break;
        }
        session.selected = index;
        Notify(page);
        return true;
      }
      case ui::VKEY_RETURN: {
        if (session.selected < 0) return false;
        // Never inside Chromium's key handling.
        base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
            [](uint64_t page, uint64_t token, int index) {
              Self().Accept(page, token, static_cast<uint32_t>(index));
            }, page, session.token, session.selected));
        return true;
      }
      case ui::VKEY_ESCAPE:
        base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
            [](uint64_t page, uint64_t token) { Self().Dismiss(page, token); }, page,
            session.token));
        return true;
      default:
        return false;
    }
  }

  static void ReleaseKeys(Showing& session) {
    if (!session.keys) return;
    if (auto* frame = content::RenderFrameHost::FromID(session.keys_frame))
      frame->GetRenderWidgetHost()->RemoveKeyPressEventCallback(session.keys);
    session.keys.Reset();
  }

  void Authenticated(uint64_t token, bool success) {
    auto found = pending.find(token);
    if (found == pending.end()) return;
    Pending fill = std::move(found->second);
    pending.erase(found);
    fill.context = nil;
    auto* main = MainFrame(fill.page);
    // A navigation, another document or a closed page while asking: nothing fills.
    // Chrome's password delegate fills its latest queried field, whatever IDs
    // it is given: a page that moved the query meanwhile gets nothing.
    if (!success || !fill.delegate || !main || fill.main.AsRenderFrameHostIfValid() != main ||
        !fill.document.AsRenderFrameHostIfValid() ||
        fill.delegate->GetQueriedFieldId() != fill.field)
      return;
    fill.delegate->DidAcceptSuggestion(*fill.suggestion, fill.metadata, fill.form, fill.field);
  }

  // fresh: a new list, under a new token; otherwise only the selection moved.
  void Notify(uint64_t page, bool fresh = false) {
    auto found = sessions.find(page);
    if (found == sessions.end()) return;
    auto& session = found->second;
    if (fresh || !session.token) {
      session.token = next_token++;
      session.shown_at = base::TimeTicks::Now();
    }
    base::ListValue items;
    for (size_t index = 0; index < session.suggestions.size() && items.size() < kMaximumItems;
         ++index) {
      const Suggestion& suggestion = session.suggestions[index];
      if (!Selectable(suggestion)) continue;
      const Kind kind = KindOf(suggestion.type);
      base::DictValue item;
      item.Set("index", static_cast<int>(index));
      item.Set("kind", KindName(kind));
      item.Set("title", Bounded(suggestion.main_text.value));
      // A password from another subdomain names its site here, not in its
      // labels, which hold only the masked password.
      if (kind == Kind::kPassword && !suggestion.additional_label.empty() &&
          !Masked(suggestion.additional_label)) {
        item.Set("subtitle", Bounded(suggestion.additional_label));
      }
      for (const auto& row : suggestion.labels) {
        if (item.Find("subtitle")) break;
        if (row.empty() || row[0].value.empty() || (kind == Kind::kPassword && Masked(row[0].value)))
          continue;
        item.Set("subtitle", Bounded(row[0].value));
      }
      items.Append(std::move(item));
    }
    base::DictValue body;
    body.Set("state", "shown");
    body.Set("product", ProductName(session.product));
    body.Set("x", session.bounds.x());
    body.Set("y", session.bounds.y());
    body.Set("width", session.bounds.width());
    body.Set("height", session.bounds.height());
    body.Set("rtl", session.rtl);
    body.Set("selected", session.selected);
    body.Set("items", std::move(items));
    told[page] = session.token;
    Post(page, session.token, std::move(body));
  }

  void Post(uint64_t page, uint64_t id, base::DictValue body) {
    std::string json;
    base::JSONWriter::Write(base::Value(std::move(body)), &json);
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
        [](uint64_t page, uint64_t id, std::string json) {
          auto changed = Self().changed;
          if (!changed) return;
          changed(page, id, reinterpret_cast<const uint8_t*>(json.data()), json.size());
        }, page, id, std::move(json)));
  }
};

Embedder& Embedder::Self() {
  static base::NoDestructor<Embedder> embedder;
  return *embedder;
}

PageWatch::PageWatch(content::WebContents* contents, uint64_t page)
    : content::WebContentsObserver(contents), page_(page) {
  // A zoom moves the field under the suggestions.
  if (auto* zoom = content::HostZoomMap::GetForWebContents(contents)) {
    zoom_ = zoom->AddZoomLevelChangedCallback(base::BindRepeating(
        [](uint64_t page, const content::HostZoomMap::ZoomLevelChange&) {
          Embedder::Self().End(page, SuggestionHidingReason::kContentAreaMoved, nullptr);
        }, page));
  }
}

void PageWatch::FrameSizeChanged(content::RenderFrameHost* frame, const gfx::Size&) {
  if (frame && frame->IsInPrimaryMainFrame())
    Embedder::Self().End(page_, SuggestionHidingReason::kContentAreaMoved, nullptr);
}

void PageWatch::OnVisibilityChanged(content::Visibility visibility) {
  if (visibility == content::Visibility::HIDDEN)
    Embedder::Self().End(page_, SuggestionHidingReason::kTabGone, nullptr);
}

// Focus left the page, for the command bar or another pane: as Chrome's popup.
void PageWatch::OnWebContentsLostFocus(content::RenderWidgetHost*) {
  Embedder::Self().End(page_, SuggestionHidingReason::kFocusChanged, nullptr);
}

// The page moved focus to another element (not a window losing focus to the
// Touch ID prompt): a fill waiting for the device owner would land elsewhere.
void PageWatch::OnFocusChangedInPage(const content::FocusedNodeDetails&) {
  Embedder::Self().CancelPending(page_);
}

// Checked after the current task: a deleted frame's document pointer is
// invalid only once Chromium finishes deleting it.
void PageWatch::RenderFrameDeleted(content::RenderFrameHost*) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
      [](uint64_t page) { Embedder::Self().FrameChanged(page); }, page_));
}

void PageWatch::RenderFrameHostStateChanged(content::RenderFrameHost*,
                                            content::RenderFrameHost::LifecycleState,
                                            content::RenderFrameHost::LifecycleState) {
  Embedder::Self().FrameChanged(page_);
}

void PageWatch::DidFinishNavigation(content::NavigationHandle* navigation) {
  if (navigation->HasCommitted() && !navigation->IsSameDocument())
    Embedder::Self().FrameChanged(page_);
}

void PageWatch::PrimaryPageChanged(content::Page&) {
  Embedder::Self().CancelPending(page_);
  Embedder::Self().End(page_, SuggestionHidingReason::kStaleData, nullptr);
}

void PageWatch::WebContentsDestroyed() {
  Embedder::Self().End(page_, SuggestionHidingReason::kTabGone, nullptr);
}
}  // namespace

void StartAutofill(AutofillSuggestionsChanged changed) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  Embedder::Self().changed = changed;
  ChromeAutofillClient::SetEmbedderSuggestions(&Embedder::Self());
}

void StopAutofill() {
  ChromeAutofillClient::SetEmbedderSuggestions(nullptr);
  Embedder::Self().Stop();
}

void AttachAutofillPage(content::WebContents* contents, uint64_t page) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!contents || contents->GetBrowserContext()->IsOffTheRecord()) return;
  auto& embedder = Embedder::Self();
  embedder.pages[page] = contents->GetWeakPtr();
  embedder.watches[page] = std::make_unique<PageWatch>(contents, page);
}

void ForgetAutofillPage(uint64_t page) {
  Embedder::Self().Forget(page);
}

bool AcceptAutofillSuggestion(uint64_t page, uint64_t session, uint32_t index) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return Embedder::Self().Accept(page, session, index);
}

void SelectAutofillSuggestion(uint64_t page, uint64_t session, int32_t index) {
  Embedder::Self().Select(page, session, index);
}

void DismissAutofillSuggestions(uint64_t page, uint64_t session) {
  Embedder::Self().Dismiss(page, session);
}

void ApplyAutofillProducts(PrefService* prefs) {
  if (!prefs) return;
  const auto& embedder = Embedder::Self();
  auto set = [prefs](const char* name, bool value) {
    if (prefs->GetBoolean(name) != value) prefs->SetBoolean(name, value);
  };
  set(autofill::prefs::kAutofillProfileEnabled, embedder.addresses);
  set(autofill::prefs::kAutofillCreditCardEnabled, embedder.cards);
  set(autofill::prefs::kAutofillPaymentMethodsMandatoryReauth, false);
}

void SetAutofillProducts(bool addresses, bool cards) {
  auto& embedder = Embedder::Self();
  embedder.addresses = addresses;
  embedder.cards = cards;
  for (const auto& [page, weak] : embedder.pages) {
    auto* contents = weak.get();
    if (!contents || contents->GetBrowserContext()->IsOffTheRecord()) continue;
    ApplyAutofillProducts(Profile::FromBrowserContext(contents->GetBrowserContext())->GetPrefs());
  }
}

void SetAutofillAuthentication(ArxAutofillAuthentication mode, const char* password_reason,
                               const char* card_reason) {
  auto& embedder = Embedder::Self();
  // Without a reason a fill that needs the device owner is refused.
  embedder.password_reason = Reason(password_reason).value_or(std::string());
  embedder.card_reason = Reason(card_reason).value_or(std::string());
  switch (mode) {
    case ARX_AUTOFILL_ASK_DEVICE_OWNER:
    case ARX_AUTOFILL_FILL_PASSWORDS_WITHOUT_ASKING:
    case ARX_AUTOFILL_REFUSE_AUTHENTICATED_FILLS:
      Embedder::Self().authentication = mode;
      return;
  }
  Embedder::Self().authentication = ARX_AUTOFILL_ASK_DEVICE_OWNER;
}
}  // namespace arx
