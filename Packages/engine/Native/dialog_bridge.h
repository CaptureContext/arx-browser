#ifndef ARX_DIALOG_BRIDGE_H
#define ARX_DIALOG_BRIDGE_H

#include <optional>
#include <string>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "chrome/browser/arx/ChromiumBridge.h"
#include "content/public/browser/javascript_dialog_manager.h"

namespace arx {
// ABI31. Forwards a page's JavaScript dialogs to the interactive manager and
// remembers the one it is showing, so the app can read and answer it. The
// user can still answer it themselves; whichever answer comes first wins.
class PageDialogs final : public content::JavaScriptDialogManager {
 public:
  explicit PageDialogs(content::JavaScriptDialogManager* inner);
  ~PageDialogs() override;

  void RunJavaScriptDialog(content::WebContents* contents, content::RenderFrameHost* frame,
                           content::JavaScriptDialogType type, const std::u16string& message,
                           const std::u16string& default_prompt, DialogClosedCallback callback,
                           bool* did_suppress_message) override;
  void RunBeforeUnloadDialog(content::WebContents* contents, content::RenderFrameHost* frame,
                             bool is_reload, DialogClosedCallback callback) override;
  bool HandleJavaScriptDialog(content::WebContents* contents, bool accept,
                              const std::u16string* prompt_override) override;
  void CancelDialogs(content::WebContents* contents, bool reset_state) override;

  // Strings are borrowed until the next call.
  bool Pending(ArxPageDialog* dialog);
  ArxPageDialogStatus Answer(content::WebContents* contents, uint64_t token, bool accept,
                             const char* prompt_text);

 private:
  struct Dialog {
    uint64_t token;
    ArxPageDialogKind kind;
    std::string message, default_prompt;
  };
  void Closed(uint64_t token);
  DialogClosedCallback Wrap(uint64_t token, DialogClosedCallback callback);

  raw_ptr<content::JavaScriptDialogManager> inner_;
  std::optional<Dialog> pending_;
  base::WeakPtrFactory<PageDialogs> weak_{this};
};

// Arx's own permission sheet for a page, read and answered the same way. An
// accept allows this time when the permission supports it, otherwise allows;
// a decline dismisses without blocking. Borrowed strings as above.
bool PagePermissionPrompt(content::WebContents* contents, ArxPageDialog* dialog);
ArxPageDialogStatus AnswerPagePermissionPrompt(content::WebContents* contents, uint64_t token,
                                               bool accept);

// ABI56 (DEV-963). The app draws ordinary site permission prompts while this
// is on: the engine reports them (PagePermissionPromptChanged) instead of
// showing its sheet, then takes the person's answer, rechecked as its own
// sheet's would be. Other prompts keep the sheet.
void SetPagePromptsHosted(bool hosted);
bool CopyHostedPagePermissionPrompt(content::WebContents* contents, uint64_t token,
                                    std::string* json);
ArxPageDialogStatus AnswerHostedPagePermissionPrompt(content::WebContents* contents,
                                                     uint64_t token,
                                                     ArxPagePermissionDecision decision,
                                                     ArxPagePermissionAccuracy accuracy);
}  // namespace arx

#endif
