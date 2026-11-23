"""Execute production authority, native work lifetime and final consent decision.

The macOS sheet, real renderer source proofs and OS media pipeline require the
owned native acceptance fixture; these deterministic checks are not that gate.
"""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from Scripts.engine import artifact, page_consent_overlay
from Scripts.engine.config import PACKAGE
from Scripts.tests.test_media_freeze import method


class PageConsentTests(unittest.TestCase):
    def test_upgrades_previous_callback_blocks_without_duplicate_definitions(self):
        previous = json.loads((Path(__file__).parent /
            'fixtures/page-consent-previous-interceptor.json').read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            page_consent_overlay.apply(root)
            expected = {p: p.read_bytes() for p in root.rglob('*') if p.is_file()}
            patches = {(p, a): n for p, a, n in page_consent_overlay.patches()}
            for block in previous:
                path = root / block['path']
                body = patches[(block['path'], block['anchor'])]
                self.assertEqual(path.read_text().count(body), 1)
                path.write_text(path.read_text().replace(body, block['body'], 1))
            page_consent_overlay.apply(root)
            self.assertEqual(expected, {p: p.read_bytes() for p in root.rglob('*') if p.is_file()})
            page_consent_overlay.apply(root)
            self.assertEqual(expected, {p: p.read_bytes() for p in root.rglob('*') if p.is_file()})

    def fixture(self, root):
        for relative, old, _ in page_consent_overlay.patches():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open('a') as stream:
                stream.write(old + '\n')

    def test_overlay_idempotence_and_every_anchor_fails_closed(self):
        patches = list(page_consent_overlay.patches())
        for changed in [None, *range(len(patches))]:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.fixture(root)
                if changed is not None:
                    relative, old, _ = patches[changed]
                    path = root / relative
                    path.write_text(path.read_text().replace(old, 'unexpected upstream', 1))
                    with self.assertRaisesRegex(ValueError, 'overlay anchor changed'):
                        page_consent_overlay.apply(root)
                else:
                    page_consent_overlay.apply(root)
                    first = {p: p.read_bytes() for p in root.rglob('*') if p.is_file()}
                    page_consent_overlay.apply(root)
                    self.assertEqual(first, {p: p.read_bytes() for p in root.rglob('*') if p.is_file()})

    def test_production_revoke_no_aba_physical_work_and_external_consent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            page_consent_overlay.apply(root)
            dialog = (root / 'chrome/browser/ui/views/external_protocol_dialog.cc').read_text()
            # The fixture contains only patch anchors. Append the upstream pinned
            # body after the modified signature to execute its actual side effects.
            signature = next(new for _, old, new in page_consent_overlay.patches()
                             if old == 'void ExternalProtocolDialog::OnDialogAccepted() {') + '\n}'
            upstream = (Path(__file__).parent / 'fixtures/external_protocol_accept.cc').read_text()
            body = method(upstream, 'void ExternalProtocolDialog::OnDialogAccepted()').split('{', 1)[1]
            signature = signature[:-1] + body
            native = (PACKAGE / 'Native/page_consent_host.mm').read_text()
            harness = (Path(__file__).parent / 'fixtures/consent_authority.cc').read_text()
            harness = harness.replace('// MEDIA_WORK', method(native, 'struct MediaWork') + ';')
            harness = harness.replace('// EXISTING_DEVICE_GRANTS', method(native, 'bool ExistingDeviceGrants('))
            harness = harness.replace('// PATH_PREDICATE', method(native, 'bool HasPageConsentWorkForPath('))
            harness = harness.replace('// EXTERNAL_ACCEPT', signature)
            source = root / 'consent.cc'
            source.write_text(harness)
            binary = root / 'consent'
            result = subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(PACKAGE / 'Native'),
                str(source), '-o', str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            subprocess.run([str(binary)], check=True, capture_output=True, timeout=5)

    def test_guard_retained_through_async_shell_lookup_and_before_remembering(self):
        patches = list(page_consent_overlay.patches())
        worker = next(new for _, old, new in patches if old.startswith('  content::WebContents* web_contents = web_contents_getter.Run();'))
        self.assertIn('source_guard && !source_guard.Run()', worker)
        callback = next(new for _, old, new in patches if 'g_external_protocol_handler_delegate);\n\n  // Start the check' in old)
        self.assertIn('std::move(source_guard)', callback)
        source = (PACKAGE / 'Native/page_consent_host.mm').read_text()
        decision = method(source, '  void Decide(')
        self.assertLess(decision.index('!Current()'), decision.index('delegate->SetDecisionTime()'))
        self.assertIn('delegate_->GetCurrentPrompt() == this', source)
        self.assertIn('request.url_origin == frame->GetLastCommittedOrigin()', source)
        self.assertIn('primary.AsRenderFrameHostIfValid() != contents->GetPrimaryMainFrame()', source)

    def test_overlay_participates_in_exact_fingerprint(self):
        before = artifact.identity()
        read = Path.read_bytes
        def changed(path):
            value = read(path)
            return value + b'changed' if path.name == 'page_consent_overlay.py' else value
        with patch.object(Path, 'read_bytes', changed):
            self.assertNotEqual(before, artifact.identity())

    def test_native_attachment_move_away_back_and_hide_are_synchronous(self):
        native = (PACKAGE / 'Native/page_consent_host.mm').read_text()
        start = native.index('@interface ArxConsentAttachmentView')
        end = native.index('\nnamespace arx {', start)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'attachment.mm'
            harness = (Path(__file__).parent / 'fixtures/consent_attachment.mm').read_text()
            source.write_text(harness.replace('// PRODUCTION_ATTACHMENT', native[start:end]))
            binary = root / 'attachment'
            result = subprocess.run(['xcrun', 'clang++', '-std=c++20', '-fobjc-arc',
                '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                '-framework', 'AppKit', str(source), '-o', str(binary)],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            subprocess.run([str(binary)], check=True, capture_output=True, timeout=10)

    def test_direct_enterprise_allowlist_launch_has_final_source_guard(self):
        patches = list(page_consent_overlay.patches())
        launch = next(new for _, old, new in patches if old.startswith(
            'void LaunchUrlWithoutSecurityCheckWithDelegate('))
        guard = launch.index('if (!EmbeddedExternalSourceCurrent(web_contents, initiator_document))')
        self.assertGreater(guard, launch.index('void LaunchUrlWithoutSecurityCheckWithDelegate('))
        self.assertIn('return !guard || guard.Run();', launch)
        self.assertIn('if (!manager || !manager->delegate()) return true;', launch)
