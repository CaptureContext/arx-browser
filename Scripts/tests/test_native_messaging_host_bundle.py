"""Only explicit owned extension acceptance bundles the signed echo executable."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from Scripts.engine import host


class NativeMessagingHostBundleTests(unittest.TestCase):
    def test_fixture_executable_is_opt_in_and_present_before_application_signing(self):
        for fixture in (False, True):
            with self.subTest(fixture=fixture), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app = root / "Arx Engine Host.app"
                binaries = root / "bin"
                binaries.mkdir()
                (binaries / "ChromiumHost").write_bytes(b"owned compiled host")
                commands = []

                def run(command, **kwargs):
                    commands.append(command)
                    if "--show-bin-path" in command:
                        return str(binaries)
                    if command[:2] == ["xcrun", "clang"]:
                        self.assertEqual(command[-2], "-o")
                        self.assertEqual(Path(command[-1]), app / "Contents/MacOS/ArxNativeMessagingFixture")
                        self.assertEqual(Path(command[-3]).name, "native_message_host.c")
                        Path(command[-1]).write_bytes(b"owned compiled echo fixture")
                    return ""

                def sign(destination):
                    self.assertEqual(destination, app)
                    self.assertEqual((app / "Contents/MacOS/ArxNativeMessagingFixture").exists(), fixture)

                with (
                    patch.object(host, "APP", app),
                    patch.object(host.bundle, "require", return_value=root / "framework"),
                    patch.object(host.bundle, "validate_application"),
                    patch.object(host, "run", side_effect=run),
                    patch.object(host.signing, "sign", side_effect=sign) as signing,
                ):
                    host.main(native_messaging_fixture=fixture)
                    signing.assert_called_once_with(app)
                self.assertEqual(sum(command[:2] == ["xcrun", "clang"] for command in commands), int(fixture))
