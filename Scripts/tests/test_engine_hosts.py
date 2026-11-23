"""make engine-hosts: the engine's hard-coded hosts, and the check on Helium and Google ones (DEV-930)."""

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from Scripts.engine import build, hosts


def framework(root, strings, *, helper_strings=()):
    """A framework laid out like the engine's, with Mach-O files holding the given strings."""
    root = Path(root) / "Arx Framework.framework"
    version = root / "Versions/156.0.0.0"
    for path, values in (
        (version / "Arx Framework", strings),
        (version / "Helpers/Arx Helper (Renderer).app/Contents/MacOS/Arx Helper (Renderer)", helper_strings),
    ):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"\xcf\xfa\xed\xfe" + b"\0".join(value.encode() for value in ["padding", *values]) + b"\0")
    (version / "Resources").mkdir(parents=True)
    (version / "Resources/resources.pak").write_bytes(b"https://crash.helium.computer/crash")
    (root / "Versions/Current").symlink_to("156.0.0.0")
    return root


def allowlist(directory, entries):
    path = Path(directory) / "allowed-hosts.json"
    path.write_text(json.dumps(entries))
    return path


class EngineHostsTests(unittest.TestCase):
    def test_families(self):
        for host in ("crash.helium.computer", "helium.computer", "services.helium.imput.net"):
            self.assertTrue(hosts.is_helium(host), host)
        self.assertFalse(hosts.is_helium("helium-services-are-disabled.qjz9zk"))
        for host in ("www.google.com", "dns.google", "chromeenterprise.google", "update.googleapis.com",
                     "ohttp-relay-safebrowsing-chrome.google.fastly-edge.com", "youtube.com", "www.gstatic.com",
                     "scan.webprotect-us.goog", "chromestorage.goog", "goo.gle", "www.google.de", "google.fr",
                     "google.com.au", "www.google.co.uk"):
            self.assertTrue(hosts.is_google(host), host)
        for host in ("login.microsoftonline.com", "duckduckgo.com", "googlefan.example", "notgoogle.com"):
            self.assertFalse(hosts.is_google(host), host)

    def test_a_clean_framework_passes_and_lists_every_url_host(self):
        with tempfile.TemporaryDirectory() as directory:
            root = framework(directory, [
                "Learn more: https://support.google.com/chrome?p=bluetooth",
                "https://duckduckgo.com/?q={searchTerms}",
                "https://helium-services-are-disabled.qjz9zk",
            ], helper_strings=["wss://example.org/socket"])
            allowed = allowlist(directory, [{"host": "support.google.com", "reason": "Help links."}])
            report = Path(directory) / "hosts.txt"
            with patch("builtins.print"):
                findings = hosts.check(root, allowed_path=allowed, report_path=report)
            self.assertEqual(
                set(findings.urls),
                {"support.google.com", "duckduckgo.com", "helium-services-are-disabled.qjz9zk", "example.org"},
            )
            text = report.read_text()
            self.assertIn("support.google.com  # Help links.", text)
            self.assertIn("example.org", text)

    def test_helium_hosts_fail_in_urls_and_bare_and_resource_packs_are_skipped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = framework(directory, ["https://services.helium.imput.net"], helper_strings=["helium.computer"])
            allowed = allowlist(directory, [])
            with self.assertRaisesRegex(ValueError, "Helium URL host services.helium.imput.net") as raised:
                hosts.check(root, allowed_path=allowed, report_path=Path(directory) / "hosts.txt")
            self.assertIn("Helium host name helium.computer", str(raised.exception))
            # The .pak's crash.helium.computer isn't read.
            self.assertNotIn("crash.helium.computer", str(raised.exception))

    def test_an_unlisted_google_url_host_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = framework(directory, ["https://www.google.com/search?q={searchTerms}", "lens.google.com"])
            allowed = allowlist(directory, [])
            with self.assertRaisesRegex(ValueError, "Google URL host www.google.com"):
                hosts.check(root, allowed_path=allowed, report_path=Path(directory) / "hosts.txt")

    def test_the_allowlist_needs_reasons_and_never_allows_helium(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "reason"):
                hosts.allowed_hosts(allowlist(directory, [{"host": "www.google.com"}]))
            with self.assertRaisesRegex(ValueError, "Helium"):
                hosts.allowed_hosts(allowlist(directory, [{"host": "crash.helium.computer", "reason": "no"}]))

    def test_the_committed_allowlist_is_reviewed(self):
        entries = json.loads(hosts.ALLOWED.read_text())
        allowed = hosts.allowed_hosts()
        self.assertEqual(len(allowed), len(entries), "a host is listed twice")
        self.assertTrue(all(hosts.is_google(host) for host in allowed))
        self.assertEqual([entry["host"] for entry in entries if entry.get("review")], [])
        # Taken out of the engine by services_overlay.py, so they mustn't be allowed back in.
        for host in ("lens.google.com", "chromeenterprise.google", "chromestorage.goog",
                     "scan.webprotect-us.goog", "scan.webprotect-eu.goog",
                     "ohttp-relay-safebrowsing-chrome.google.fastly-edge.com"):
            self.assertNotIn(host, allowed)

    def test_the_engine_build_checks_hosts_before_it_completes(self):
        order = []
        with (
            patch.object(build.artifact, "identity", return_value={"a": 1}),
            patch.object(build.artifact, "STAMP"),
            patch.object(build.artifact, "complete", side_effect=lambda: order.append("complete")),
            patch.object(build, "configure", return_value={}),
            patch.object(build, "check_native"),
            patch.object(build, "compile_targets"),
            patch.object(build.hosts, "check", side_effect=lambda _: order.append("hosts")),
            patch.object(build.branding_overlay, "check_framework", side_effect=lambda _: order.append("branding")),
            patch("builtins.print"),
        ):
            build.main()
        # DEV-1100: nor one that bundles Helium's logo or names Helium.
        self.assertEqual(order, ["hosts", "branding", "complete"])

        with (
            patch.object(build.artifact, "identity", return_value={"a": 1}),
            patch.object(build.artifact, "STAMP"),
            patch.object(build.artifact, "complete") as complete,
            patch.object(build, "configure", return_value={}),
            patch.object(build, "check_native"),
            patch.object(build, "compile_targets"),
            patch.object(build.hosts, "check", side_effect=ValueError("Helium URL host")),
            self.assertRaises(ValueError),
        ):
            build.main()
        complete.assert_not_called()

        # DEV-1100: Helium's logo or name in the built framework stops the build too.
        with (
            patch.object(build.artifact, "identity", return_value={"a": 1}),
            patch.object(build.artifact, "STAMP"),
            patch.object(build.artifact, "complete") as complete,
            patch.object(build, "configure", return_value={}),
            patch.object(build, "check_native"),
            patch.object(build, "compile_targets"),
            patch.object(build.hosts, "check"),
            patch.object(build.branding_overlay, "check_framework", side_effect=ValueError("Helium's logo")),
            self.assertRaises(ValueError),
        ):
            build.main()
        complete.assert_not_called()


if __name__ == "__main__":
    unittest.main()
