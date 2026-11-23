"""Let the embedder refuse extension background pages in one regular profile (DEV-944).

Arx starts the engine with a bootstrap profile that never shows a page; it only
parents private contexts. Helium loads uBlock Origin into every regular profile
as a component extension with a persistent background page, so the bootstrap
profile kept a whole renderer for a uBlock instance that filters nothing. uBlock
is `"incognito": "split"`: a private context gets its own instance and never
reaches the parent's.

`ChromeProcessManagerDelegate::SetEmbedderBackgroundPageRefusal` installs a
plain function the delegate asks about each regular profile before it allows
background pages there. Off-the-record contexts are never asked, so a private
context's own split-mode instance is unaffected. Without a hook Chrome's policy
is unchanged. If an anchor changes, the build stops.
"""
from .overlay import replace_once

HEADER = "chrome/browser/extensions/chrome_process_manager_delegate.h"
SOURCE = "chrome/browser/extensions/chrome_process_manager_delegate.cc"

SETTER = """  void StartTearDown();

 private:
"""

ARX_SETTER = """  void StartTearDown();

  // Arx (DEV-944): the embedder may refuse every extension background page in
  // a regular profile that never shows pages. It's asked only about regular
  // profiles; off-the-record contexts keep Chrome's policy. Install it on the
  // UI thread before profiles load. Null (the default) refuses nothing.
  using EmbedderBackgroundPageRefusal = bool (*)(Profile* profile);
  static void SetEmbedderBackgroundPageRefusal(
      EmbedderBackgroundPageRefusal refusal);

 private:
"""

HOOK = """namespace extensions {

ChromeProcessManagerDelegate::ChromeProcessManagerDelegate() {
"""

ARX_HOOK = """namespace extensions {

namespace {

ChromeProcessManagerDelegate::EmbedderBackgroundPageRefusal
    g_embedder_background_page_refusal = nullptr;

}  // namespace

// static
void ChromeProcessManagerDelegate::SetEmbedderBackgroundPageRefusal(
    EmbedderBackgroundPageRefusal refusal) {
  g_embedder_background_page_refusal = refusal;
}

ChromeProcessManagerDelegate::ChromeProcessManagerDelegate() {
"""

ALLOWED = """  Profile* profile = Profile::FromBrowserContext(context);

  bool is_normal_session = !profile->IsGuestSession() &&
"""

ARX_ALLOWED = """  Profile* profile = Profile::FromBrowserContext(context);

  // Arx (DEV-944): a regular profile the embedder never shows pages in.
  if (g_embedder_background_page_refusal && !profile->IsOffTheRecord() &&
      g_embedder_background_page_refusal(profile)) {
    return false;
  }

  bool is_normal_session = !profile->IsGuestSession() &&
"""


def patches():
    yield HEADER, SETTER, ARX_SETTER
    yield SOURCE, HOOK, ARX_HOOK
    yield SOURCE, ALLOWED, ARX_ALLOWED


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
