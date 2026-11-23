"""Find password managers' native messaging hosts where they install them (DEV-889).

Chromium looks for `<host>.json` in the browser's own user-data folder, then
(Helium's change) Chrome's per-user folder, Chromium's system folder and
Chrome's system folder. Arx's user-data folder is a profile root deep inside
`dev.capturecontext.arx`, which no installer knows about, and Chromium's
per-user folder isn't searched at all, so a host that a desktop app installed
only for Chromium was never found.

The lookup order after this overlay, first match wins:

1. Arx's user-data folder (`chrome::DIR_USER_NATIVE_MESSAGING`; the owned test
   fixture writes its host there),
2. `~/Library/Application Support/dev.capturecontext.arx/NativeMessagingHosts`,
   Arx's own folder, where a person or an installer can put a host for Arx alone,
3. `~/Library/Application Support/Google/Chrome/NativeMessagingHosts`,
4. `~/Library/Application Support/Chromium/NativeMessagingHosts`,
5. `/Library/Application Support/dev.capturecontext.arx/NativeMessagingHosts`,
6. `/Library/Application Support/Chromium/NativeMessagingHosts`,
7. `/Library/Google/Chrome/NativeMessagingHosts`.

Per-user folders are searched only when Chromium allows user-level hosts (the
`NativeMessagingUserLevelHosts` policy), as before. A host's own manifest still
decides which extensions may connect (`allowed_origins`), and Chromium still
launches it the same way. If an anchor changes, the build stops.
"""
from .overlay import replace_once

SOURCE = "chrome/browser/extensions/api/messaging/launch_context_posix.cc"

INCLUDE = '#include "chrome/common/chrome_paths.h"\n'

ARX_INCLUDE = '''#include "chrome/common/chrome_paths.h"
#include "chrome/common/chrome_paths_internal.h"
'''

HELPER = """}  // namespace

// static
base::FilePath LaunchContext::FindManifest("""

ARX_HELPER = """// Arx (DEV-889): `<folder>/NativeMessagingHosts/<host>.json`, or empty.
base::FilePath FindArxManifestIn(const base::FilePath& folder,
                                 const std::string& host_name) {
  if (folder.empty()) {
    return base::FilePath();
  }
  base::FilePath path = folder.Append(FILE_PATH_LITERAL("NativeMessagingHosts"))
                            .Append(host_name + ".json");
  return base::PathExists(path) ? path : base::FilePath();
}

}  // namespace

// static
base::FilePath LaunchContext::FindManifest("""

USER = """  if (allow_user_level_hosts) {
    result = FindManifestInDir(chrome::DIR_USER_NATIVE_MESSAGING, host_name);
  }
"""

ARX_USER = """  if (allow_user_level_hosts) {
    result = FindManifestInDir(chrome::DIR_USER_NATIVE_MESSAGING, host_name);
  }

  // Arx (DEV-889): Arx's own per-user folder before Chrome's.
  base::FilePath arx_own;
  if (result.empty() && allow_user_level_hosts &&
      chrome::GetDefaultUserDataDirectory(&arx_own)) {
    result = FindArxManifestIn(arx_own, host_name);
  }
"""

CHROME_USER = """  if (result.empty() && allow_user_level_hosts) {
    result = FindManifestInDir(chrome::DIR_CHROME_USER_NATIVE_MESSAGING, host_name);
  }
"""

ARX_CHROME_USER = """  if (result.empty() && allow_user_level_hosts) {
    result = FindManifestInDir(chrome::DIR_CHROME_USER_NATIVE_MESSAGING, host_name);
  }

  // Arx (DEV-889): Chromium's per-user folder, which desktop apps fill for
  // Chromium, then Arx's own system-wide folder.
  base::FilePath arx_support;
  if (result.empty() && allow_user_level_hosts &&
      base::PathService::Get(base::DIR_APP_DATA, &arx_support)) {
    result = FindArxManifestIn(
        arx_support.Append(FILE_PATH_LITERAL("Chromium")), host_name);
  }
  if (result.empty()) {
    result = FindArxManifestIn(
        base::FilePath(FILE_PATH_LITERAL(
            "/Library/Application Support/dev.capturecontext.arx")),
        host_name);
  }
"""


def patches():
    yield SOURCE, INCLUDE, ARX_INCLUDE
    yield SOURCE, HELPER, ARX_HELPER
    yield SOURCE, USER, ARX_USER
    yield SOURCE, CHROME_USER, ARX_CHROME_USER


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
