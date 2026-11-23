"""Native messaging host lookup (DEV-889): Arx's and Chromium's folders join Chrome's."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import native_messaging_overlay

UPSTREAM = '''#include "chrome/common/chrome_paths.h"
#include "net/base/file_stream.h"

namespace extensions {

namespace {

base::FilePath FindManifestInDir(int dir_key, const std::string& host_name) {
  return base::FilePath();
}

}  // namespace

// static
base::FilePath LaunchContext::FindManifest(const std::string& host_name,
                                           bool allow_user_level_hosts,
                                           std::string& error_message) {
  base::FilePath result;
  if (allow_user_level_hosts) {
    result = FindManifestInDir(chrome::DIR_USER_NATIVE_MESSAGING, host_name);
  }

  // FIXME: this is not supported on windows,
  // because idrgaf about windows. make a patch
  if (result.empty() && allow_user_level_hosts) {
    result = FindManifestInDir(chrome::DIR_CHROME_USER_NATIVE_MESSAGING, host_name);
  }

  if (result.empty()) {
    result = FindManifestInDir(chrome::DIR_NATIVE_MESSAGING, host_name);
  }

  if (result.empty()) {
    result = FindManifestInDir(chrome::DIR_CHROME_NATIVE_MESSAGING, host_name);
  }
  return result;
}
'''


def prepare(root):
    path = root / native_messaging_overlay.SOURCE
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(UPSTREAM)
    return path


class NativeMessagingOverlayTests(unittest.TestCase):
    def test_searches_arx_then_chrome_then_chromium_then_system_folders(self):
        with tempfile.TemporaryDirectory() as directory:
            path = prepare(Path(directory))
            native_messaging_overlay.apply(Path(directory))
            first = path.read_text()
            native_messaging_overlay.apply(Path(directory))
            self.assertEqual(first, path.read_text())

            order = [
                "chrome::DIR_USER_NATIVE_MESSAGING",
                "chrome::GetDefaultUserDataDirectory(&arx_own)",
                "chrome::DIR_CHROME_USER_NATIVE_MESSAGING",
                'FILE_PATH_LITERAL("Chromium")',
                '"/Library/Application Support/dev.capturecontext.arx"',
                "chrome::DIR_NATIVE_MESSAGING,",
                "chrome::DIR_CHROME_NATIVE_MESSAGING",
            ]
            body = first[first.index("LaunchContext::FindManifest("):]
            positions = [body.index(needle) for needle in order]
            self.assertEqual(positions, sorted(positions))
            # Arx's two per-user lookups stay behind Chromium's user-level policy.
            self.assertEqual(body.count("result.empty() && allow_user_level_hosts &&"), 2)
            self.assertIn('#include "chrome/common/chrome_paths_internal.h"', first)

    def test_changed_anchor_stops_the_build(self):
        with tempfile.TemporaryDirectory() as directory:
            path = prepare(Path(directory))
            path.write_text(UPSTREAM.replace("DIR_CHROME_USER_NATIVE_MESSAGING", "DIR_OTHER"))
            with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                native_messaging_overlay.apply(Path(directory))


if __name__ == "__main__":
    unittest.main()
