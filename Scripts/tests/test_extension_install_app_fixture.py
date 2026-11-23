import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zipfile
import io

from Scripts.core import extension_install_app_fixture as fixture


def fields(data):
    def varint(index):
        result = shift = 0
        while True:
            byte = data[index]
            index += 1
            result |= (byte & 127) << shift
            if byte < 128:
                return result, index
            shift += 7
            if shift > 63:
                raise ValueError("Malformed protobuf fixture")
    result = {}
    offset = 0
    while offset < len(data):
        tag, offset = varint(offset)
        if tag & 7 != 2:
            raise ValueError("Unexpected protobuf fixture type")
        size, offset = varint(offset)
        if offset + size > len(data):
            raise ValueError("Truncated protobuf fixture")
        result[tag >> 3] = data[offset:offset + size]
        offset += size
    return result


class ExtensionInstallAppFixtureTests(unittest.TestCase):
    def test_fixed_packages_have_real_signatures_immutable_ids_and_escalation(self):
        with tempfile.TemporaryDirectory(prefix="app-extension-install-smoke-") as temp:
            root = Path(temp).resolve()
            config = fixture.prepare(root)
            self.assertEqual((root / ".arx-extension-settings-smoke").read_bytes(), fixture.SENTINEL)
            identities = {}
            for name in fixture.FILES:
                package = (root / name).read_bytes()
                self.assertEqual(hashlib.sha256(package).hexdigest(), config["packages"][name])
                self.assertEqual(package[:4], b"Cr24")
                version, length = struct.unpack("<II", package[4:12])
                self.assertEqual(version, 3)
                self.assertLess(length, 16384)
                header = fields(package[12:12 + length])
                proof = fields(header[2])
                identity = fields(header[10000])[1]
                self.assertEqual(identity, hashlib.sha256(proof[1]).digest()[:16])
                identities[name] = identity
                (root / "verify-public.der").write_bytes(proof[1])
                (root / "verify-signature").write_bytes(proof[2])
                payload = fixture.CONTEXT + struct.pack("<I", len(header[10000])) + header[10000] + package[12 + length:]
                verified = subprocess.run([
                    "/usr/bin/openssl", "dgst", "-sha256", "-keyform", "DER",
                    "-verify", str(root / "verify-public.der"), "-signature", str(root / "verify-signature"),
                ], input=payload, capture_output=True)
                self.assertEqual(verified.returncode == 0, name != "corrupt.crx")
                if name != "corrupt.crx":
                    with zipfile.ZipFile(io.BytesIO(package[12 + length:])) as archive:
                        self.assertEqual(set(archive.namelist()), {"manifest.json", "worker.js", "content.js", "popup.html",
                                                                   "window-probe.js", "window.html", "window.js"})
                        manifest = json.loads(archive.read("manifest.json"))
                        self.assertEqual(manifest["manifest_version"], 3)
                        self.assertEqual("nativeMessaging" in manifest["permissions"], name != "v1.crx")
                        self.assertEqual("tabs" in manifest["permissions"], name != "v1.crx")
                        self.assertEqual(manifest["host_permissions"], ["http://127.0.0.1/*"])
                        self.assertEqual(manifest["action"], {"default_popup": "popup.html"})
                        self.assertEqual(manifest["content_scripts"][0]["matches"],
                                         ["http://127.0.0.1/extension-settings-probe.html*"])
                        # DEV-1240: the probe that opens the extension's own window, which
                        # needs no permission beyond storage (its session storage).
                        self.assertEqual(manifest["content_scripts"][1],
                                         {"matches": ["http://127.0.0.1/extension-window-probe.html*",
                                                      "http://127.0.0.1/extension-tab-probe.html*"],
                                          "js": ["window-probe.js"], "run_at": "document_idle"})
                        worker = archive.read("worker.js").decode()
                        self.assertIn("chrome.windows.create({url:'window.html',type:'popup'", worker)
                        self.assertIn("chrome.windows.remove(state.extensionWindow", worker)
                        # DEV-1314: the same page opened with chrome.tabs.create.
                        self.assertIn("chrome.tabs.create({url:'window.html'}", worker)
                        self.assertIn("'owned-tab-open'", archive.read("window-probe.js").decode())
            self.assertEqual(identities["v1.crx"], identities["v2.crx"])
            self.assertNotEqual(identities["v1.crx"], identities["other-key.crx"])
            self.assertEqual(identities["v1.crx"], identities["corrupt.crx"])
            expected_id = "".join(chr(97 + nibble) for byte in identities["v1.crx"] for nibble in (byte >> 4, byte & 15))
            self.assertEqual(config["extensionID"], expected_id)
            for name in (*fixture.FILES, "fixture-key.pem", "other-key.pem", ".arx-extension-settings-smoke"):
                self.assertEqual((root / name).stat().st_mode & 0o777, 0o600)
            self.assertEqual((root / "profile").stat().st_mode & 0o777, 0o700)
            manifest = json.loads((root / fixture.UNPACKED / "manifest.json").read_text())
            self.assertEqual((manifest["manifest_version"], manifest["version"]), (3, "1.0"))
            self.assertEqual(manifest["content_scripts"][0]["matches"],
                             ["http://127.0.0.1/extension-settings-probe.html*"])
            with self.assertRaises(json.JSONDecodeError):
                json.loads((root / fixture.UNPACKED_INVALID / "manifest.json").read_text())
            self.assertEqual((root / fixture.UNPACKED_UNREADABLE).stat().st_mode & 0o777, 0)
            self.assertFalse((root / fixture.UNPACKED_MISSING).exists())
            fixture.restore_permissions(root)
            self.assertEqual((root / fixture.UNPACKED_UNREADABLE).stat().st_mode & 0o777, 0o700)
            with self.assertRaisesRegex(ValueError, "empty"):
                fixture.prepare(root)

    def test_foreign_or_public_root_is_refused_before_key_generation(self):
        with tempfile.TemporaryDirectory(prefix="foreign-") as temp:
            with self.assertRaises(ValueError):
                fixture.prepare(Path(temp).resolve())
        with tempfile.TemporaryDirectory(prefix="app-extension-install-smoke-") as temp:
            root = Path(temp).resolve()
            root.chmod(0o755)
            with self.assertRaises(ValueError):
                fixture.prepare(root)
            self.assertEqual(list(root.iterdir()), [])
