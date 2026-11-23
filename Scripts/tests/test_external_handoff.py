"""Production one-child authority and deferred physical cleanup.

Actual created-window ordering and native modal hosting need the signed renderer
fixture; fake task scheduling here proves only ownership/cancellation boundaries.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest
from Scripts.engine.config import PACKAGE
from Scripts.tests.test_media_freeze import method


class ExternalHandoffTests(unittest.TestCase):
    def test_production_authority_and_stale_reentrant_completion(self):
        native = (PACKAGE / 'Native/page_consent_host.mm').read_text()
        owner = native[native.index('class ExternalChild final'):]
        harness = (Path(__file__).parent / 'fixtures/external_handoff.cc').read_text()
        for marker, signature in [('FINISH', '  void Finish()'), ('CURRENT', '  bool Current() const'),
                                  ('CHECK', '  void CheckSource()')]:
            harness = harness.replace('// PRODUCTION_' + marker, method(owner, signature))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'external.cc'
            source.write_text(harness)
            binary = root / 'external'
            result = subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(PACKAGE / 'Native'),
                str(source), '-o', str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_resume_after_adoption_and_hidden_lane_does_not_publish_tabs(self):
        native = (PACKAGE / 'Native/engine_bridge.mm').read_text()
        adoption = method(native, '  content::WebContents* AddNewContents(')
        self.assertIn('if (!has_user_gesture ||', adoption)
        external = adoption[adoption.index('if (IsPageExternalTarget(source, target))'):adoption.index('// The source callback')]
        self.assertIn('AdoptPageExternalTarget', external)
        self.assertNotIn('OfferContents', external)
        self.assertLess(adoption.index('OfferContents('), adoption.index('ResumeLoadingCreatedWebContents()'))
        owner = (PACKAGE / 'Native/page_consent_host.mm').read_text()
        self.assertIn('ExternalChild::Pending().size() >= 16', owner)
        self.assertIn('ProfileIOData::IsHandledURL(target)', owner)
        self.assertIn('registry->IsHandledProtocol(target.scheme())', owner)
