"""Let an embedder with nobody to answer cancel subresource HTTP auth prompts."""
from .overlay import replace_once

HEADER = "chrome/browser/ui/login/http_auth_coordinator.h"
SOURCE = "chrome/browser/ui/login/http_auth_coordinator.cc"


def patches():
    yield HEADER, '#include "base/memory/raw_ptr.h"\n', '#include "base/functional/callback.h"\n#include "base/memory/raw_ptr.h"\n'
    yield HEADER, "  // Exposed for testing.\n  virtual void CreateLoginTabHelper(", '''  // An embedder without a person to answer prompts (an unattended run) may
  // cancel a subframe or subresource challenge instead of building a login
  // prompt. Return true to cancel. Extensions and enterprise proxy handling
  // still run first; primary main-frame challenges keep Chrome's own path.
  using EmbedderPromptCancellation =
      base::RepeatingCallback<bool(content::WebContents*)>;
  static void SetEmbedderPromptCancellation(
      EmbedderPromptCancellation cancellation);

  // Exposed for testing.
  virtual void CreateLoginTabHelper('''
    yield SOURCE, '#include "base/task/sequenced_task_runner.h"\n', '#include "base/no_destructor.h"\n#include "base/task/sequenced_task_runner.h"\n'
    yield SOURCE, "HttpAuthCoordinator::HttpAuthCoordinator() = default;\n", '''static HttpAuthCoordinator::EmbedderPromptCancellation&
EmbeddedPromptCancellation() {
  static base::NoDestructor<HttpAuthCoordinator::EmbedderPromptCancellation>
      cancellation;
  return *cancellation;
}

// static
void HttpAuthCoordinator::SetEmbedderPromptCancellation(
    EmbedderPromptCancellation cancellation) {
  EmbeddedPromptCancellation() = std::move(cancellation);
}

HttpAuthCoordinator::HttpAuthCoordinator() = default;
'''
    yield SOURCE, "  // If there is no WebContentsModalDialogManager, then a dialog cannot be\n", '''  // An embedder with nobody to answer cancels instead of building a prompt
  // that no one could see or close. Cancelling may destroy `this`.
  if (EmbeddedPromptCancellation()) {
    auto cancellation = EmbeddedPromptCancellation();
    if (cancellation.Run(web_contents_.get())) {
      std::move(callback_).Run(std::nullopt);
      return;
    }
  }

  // If there is no WebContentsModalDialogManager, then a dialog cannot be
'''


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
