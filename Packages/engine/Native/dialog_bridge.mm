#include "chrome/browser/arx/dialog_bridge.h"

#include <utility>

#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/rand_util.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"

namespace arx {
namespace {
constexpr size_t kMaximumTextBytes = 4096;

std::string Bounded(const std::u16string& text) {
  std::string value = base::UTF16ToUTF8(text);
  base::TruncateUTF8ToByteSize(value, kMaximumTextBytes, &value);
  return value;
}
}  // namespace

PageDialogs::PageDialogs(content::JavaScriptDialogManager* inner) : inner_(inner) {}
PageDialogs::~PageDialogs() = default;

content::JavaScriptDialogManager::DialogClosedCallback PageDialogs::Wrap(
    uint64_t token, DialogClosedCallback callback) {
  return base::BindOnce(
      [](base::WeakPtr<PageDialogs> owner, uint64_t token, DialogClosedCallback callback,
         bool success, const std::u16string& input) {
        if (owner) owner->Closed(token);
        std::move(callback).Run(success, input);
      },
      weak_.GetWeakPtr(), token, std::move(callback));
}

void PageDialogs::Closed(uint64_t token) {
  if (pending_ && pending_->token == token) pending_.reset();
}

void PageDialogs::RunJavaScriptDialog(content::WebContents* contents,
                                      content::RenderFrameHost* frame,
                                      content::JavaScriptDialogType type,
                                      const std::u16string& message,
                                      const std::u16string& default_prompt,
                                      DialogClosedCallback callback,
                                      bool* did_suppress_message) {
  const uint64_t token = base::RandUint64() | 1;
  const auto kind = type == content::JAVASCRIPT_DIALOG_TYPE_ALERT ? ARX_PAGE_DIALOG_ALERT
      : type == content::JAVASCRIPT_DIALOG_TYPE_CONFIRM ? ARX_PAGE_DIALOG_CONFIRM
      : ARX_PAGE_DIALOG_PROMPT;
  pending_ = Dialog{token, kind, Bounded(message), Bounded(default_prompt)};
  inner_->RunJavaScriptDialog(contents, frame, type, message, default_prompt,
                              Wrap(token, std::move(callback)), did_suppress_message);
  if (*did_suppress_message) Closed(token);
}

void PageDialogs::RunBeforeUnloadDialog(content::WebContents* contents,
                                        content::RenderFrameHost* frame, bool is_reload,
                                        DialogClosedCallback callback) {
  const uint64_t token = base::RandUint64() | 1;
  pending_ = Dialog{token, ARX_PAGE_DIALOG_BEFORE_UNLOAD, std::string(), std::string()};
  inner_->RunBeforeUnloadDialog(contents, frame, is_reload, Wrap(token, std::move(callback)));
}

bool PageDialogs::HandleJavaScriptDialog(content::WebContents* contents, bool accept,
                                         const std::u16string* prompt_override) {
  return inner_->HandleJavaScriptDialog(contents, accept, prompt_override);
}

void PageDialogs::CancelDialogs(content::WebContents* contents, bool reset_state) {
  pending_.reset();
  inner_->CancelDialogs(contents, reset_state);
}

bool PageDialogs::Pending(ArxPageDialog* dialog) {
  if (!pending_ || !dialog) return false;
  *dialog = {pending_->token, pending_->kind, pending_->message.c_str(),
             pending_->default_prompt.c_str(), ""};
  return true;
}

ArxPageDialogStatus PageDialogs::Answer(content::WebContents* contents, uint64_t token,
                                        bool accept, const char* prompt_text) {
  if (!pending_ || pending_->token != token) return ARX_PAGE_DIALOG_STALE;
  std::u16string prompt;
  const bool overrides = prompt_text && pending_->kind == ARX_PAGE_DIALOG_PROMPT && accept;
  if (prompt_text) {
    const std::string_view text(prompt_text);
    if (text.size() > kMaximumTextBytes || !base::IsStringUTF8(text) ||
        (pending_->kind != ARX_PAGE_DIALOG_PROMPT && !text.empty()))
      return ARX_PAGE_DIALOG_INVALID;
    prompt = base::UTF8ToUTF16(text);
  }
  // The dialog may already have been answered by the user and be gone.
  if (!inner_->HandleJavaScriptDialog(contents, accept, overrides ? &prompt : nullptr))
    return ARX_PAGE_DIALOG_STALE;
  Closed(token);
  return ARX_PAGE_DIALOG_OK;
}
}  // namespace arx
