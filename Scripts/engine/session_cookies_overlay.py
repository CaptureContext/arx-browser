"""Keep a profile's session cookies when Arx loads it again in the same run (DEV-880).

Arx releases idle profiles, and Chromium destroys them. When something needs the
profile again, Chromium loads it fresh, and `ProfileImpl::ShouldRestoreOldSessionCookies`
answers false unless the last session crashed or the startup preference restores
it, so the cookie store deletes every session cookie and sites sign the person out.
An idle release isn't the end of the browsing session: the embedder may now say
which profile paths keep their session cookies (`ProfileManager::SetArxSessionKeeper`),
and the answer is true for those. Unset, Chromium's policy is unchanged. If an
anchor changes, the build stops instead of shipping the sign-outs.
"""
from .overlay import replace_once

MANAGER = "chrome/browser/profiles/profile_manager.h"
PROFILE = "chrome/browser/profiles/profile_impl.cc"

KEEP_ALIVE = "  void ClearFirstBrowserWindowKeepAlive(Profile* profile);\n"

ARX_KEEP_ALIVE = KEEP_ALIVE + """
  // Arx (DEV-880): profile paths whose session cookies survive their next load
  // in this run, because the embedder released the profile and loads it again.
  // Unset keeps Chromium's policy.
  void SetArxSessionKeeper(
      base::RepeatingCallback<bool(const base::FilePath&)> keeper) {
    arx_session_keeper_ = std::move(keeper);
  }
  bool ArxKeepsSession(const base::FilePath& path) const {
    return arx_session_keeper_ && arx_session_keeper_.Run(path);
  }
  base::RepeatingCallback<bool(const base::FilePath&)> arx_session_keeper_;
"""

RESTORE = """bool ProfileImpl::ShouldRestoreOldSessionCookies() {
#if BUILDFLAG(IS_ANDROID)
"""

ARX_RESTORE = """bool ProfileImpl::ShouldRestoreOldSessionCookies() {
  // Arx (DEV-880): a profile the embedder released and loads again keeps the
  // session cookies it had; the browsing session didn't end.
  if (ProfileManager* manager = g_browser_process->profile_manager();
      manager && manager->ArxKeepsSession(GetPath())) {
    return true;
  }
#if BUILDFLAG(IS_ANDROID)
"""


def patches():
    yield MANAGER, KEEP_ALIVE, ARX_KEEP_ALIVE
    yield PROFILE, RESTORE, ARX_RESTORE


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
