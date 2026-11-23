"""Execute precise production inventory invalidation and compatible pref dispatch."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from Scripts.engine import artifact, extension_inventory_overlay
from Scripts.engine.config import PACKAGE
from Scripts.tests.test_media_freeze import method


class ExtensionInventoryTests(unittest.TestCase):
    def fixture(self, root):
        for relative, old, _ in extension_inventory_overlay.patches():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open('a') as stream:
                stream.write(old + '\n')

    def test_pristine_idempotence_and_changed_anchors_fail_closed(self):
        for changed in [None, *range(len(list(extension_inventory_overlay.patches())))]:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.fixture(root)
                if changed is not None:
                    relative, old, _ = list(extension_inventory_overlay.patches())[changed]
                    path = root / relative
                    path.write_text(path.read_text().replace(old, 'unexpected upstream', 1))
                    with self.assertRaisesRegex(ValueError, 'overlay anchor changed'):
                        extension_inventory_overlay.apply(root)
                else:
                    extension_inventory_overlay.apply(root)
                    first = {p: p.read_bytes() for p in root.rglob('*') if p.is_file()}
                    extension_inventory_overlay.apply(root)
                    self.assertEqual(first, {p: p.read_bytes() for p in root.rglob('*') if p.is_file()})

    def test_actual_dispatch_noise_security_aba_and_failed_snapshot(self):
        source = (PACKAGE / 'Native/extensions_bridge.mm').read_text()
        methods = ['OnExtensionPrefsUpdated', 'OnExtensionPrefUpdated',
                   'OnExtensionLoaded', 'OnExtensionReady', 'OnExtensionUnloaded',
                   'OnExtensionEnabled', 'OnExtensionInstalled', 'OnExtensionUninstalled',
                   'OnExtensionDisableReasonsChanged', 'OnExtensionRuntimePermissionsChanged']
        observers = '\n'.join(method(source, '  void ' + name + '(').replace(' override', '')
                              for name in methods)
        changed = method(source, '  void Changed()')
        read_tail = source[source.index('    if (*json != last_json_)'):source.index('\n  void OnExtensionLoaded')]
        default = next(new for _, old, new in extension_inventory_overlay.patches()
                       if old.startswith('  virtual void OnExtensionPrefsUpdated'))
        forwarding = method(default, '  virtual void OnExtensionPrefUpdated(')
        harness = (Path(__file__).parent / 'fixtures/extension_inventory.cc').read_text()
        harness = harness.replace('// OBSERVERS', observers).replace('// CHANGED', changed)
        harness = harness.replace('// READ_TAIL', read_tail).replace('// DEFAULT_FORWARDING', forwarding)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'inventory.cc'
            source.write_text(harness)
            binary = source.with_suffix('')
            built = subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra',
                '-Werror', '-Wno-unused-parameter', '-fsanitize=address,undefined',
                '-fno-omit-frame-pointer', str(source), '-o', str(binary)],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(built.returncode, 0, built.stderr)
            ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            diagnostics = ran.stderr.splitlines()
            self.assertEqual(len(diagnostics), 64)
            self.assertTrue(all('category=0 key=?' in line and line.endswith('truncated=1')
                                and len(line) < 180 for line in diagnostics))

    def test_owned_settings_diagnostics_root_requires_exact_canonical_private_marker(self):
        source = (PACKAGE / 'Native/extensions_bridge.mm').read_text()
        body = method(source, 'base::FilePath OwnedSettingsDiagnosticProfile()')
        harness = (Path(__file__).parent / 'fixtures/extension_inventory_root.cc').read_text()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'root.cc'
            path.write_text(harness.replace('// PRODUCTION_ROOT', body))
            binary = path.with_suffix('')
            built = subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                '-fsanitize=address,undefined', str(path), '-o', str(binary)],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(built.returncode, 0, built.stderr)
            ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(ran.returncode, 0, ran.stderr)
        self.assertIn('profile->GetOriginalProfile()->GetPath()', source)
        self.assertIn('settings_diagnostic_profile_.IsParent(path)', source)

    def test_overlay_is_applied_copied_and_fingerprinted(self):
        overlay = (PACKAGE.parents[1] / 'Scripts/engine/overlay.py').read_text()
        self.assertIn('apply_extension_inventory(source)', overlay)
        before = artifact.identity()
        read = Path.read_bytes
        def changed(path):
            value = read(path)
            return value + b'changed' if path.name == 'extension_inventory_overlay.py' else value
        with patch.object(Path, 'read_bytes', changed):
            self.assertNotEqual(before, artifact.identity())
