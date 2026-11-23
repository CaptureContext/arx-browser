"""Extracted production attribution/admission; real renderer/window fixtures separate."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine.config import PACKAGE
from Scripts.engine import page_consent_overlay
from Scripts.tests.test_media_freeze import method


class PublishedBlankChildTests(unittest.TestCase):
    def test_actual_one_use_admission_and_callback_profile_lifetime(self):
        native = (PACKAGE / 'Native/page_consent_host.mm').read_text()
        begin = native.index('class PublishedBlankAttribution final')
        end = native.index('// Real platform sheet;', begin)
        production = native[begin:end]
        # AppKit attachment mechanics need the actual owned window fixture. All
        # decision/navigation/admission/refcount methods below are production.
        production = production.replace(method(production, '  void CaptureHost()'), '''  void CaptureHost() {
    if (!host_ && child_ && child_->attached) host_ = std::make_unique<SourceHost>(child_.get());
  }''')
        harness = (Path(__file__).parent / 'fixtures/published_blank_child.cc').read_text()
        bootstrap = next(new for _, old, new in page_consent_overlay.patches()
                         if old == 'bool NavigationRequest::IsNavigatingFromInitialEmptyDocument() const {')
        bootstrap = method(bootstrap, 'bool NavigationRequest::IsInitialSynchronousAboutBlankForEmbedding()')
        harness = harness.replace('// PRODUCTION_BOOTSTRAP_QUERY',
                                  bootstrap.replace('NavigationRequest::', ''))
        harness = harness.replace('// PRODUCTION_CLASS', production)
        harness = harness.replace('// PRODUCTION_ADMISSION', method(native, '  void BindPublishedBlank('))
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'blank.cc'
            source.write_text(harness)
            binary = source.with_suffix('')
            compiled = subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(PACKAGE / 'Native'),
                str(source), '-o', str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(executed.returncode, 0, executed.stderr)

    def test_creation_proof_transfers_only_after_accepted_publication_before_resume(self):
        native = (PACKAGE / 'Native/engine_bridge.mm').read_text()
        adoption = method(native, '  content::WebContents* AddNewContents(')
        binding = adoption.index('BindPublishedBlankChildProvenance(')
        self.assertLess(adoption.index('auto source_weak = source->GetWeakPtr()'), adoption.index('OfferContents('))
        self.assertLess(adoption.index('OfferContents('), binding)
        self.assertLess(binding, adoption.index('ResumeLoadingCreatedWebContents()'))
        self.assertIn('const bool initially_blank = has_user_gesture &&', adoption)
        self.assertIn('proof.mapped().opener', adoption)
        self.assertIn('proof.mapped().primary', adoption)
        self.assertIn('page->popup_host_epoch_ == host_epoch', adoption)
        for forbidden in ('PermitLaunchUrl', 'GetOpener()', 'user_gesture = true', 'SetHasUserGesture'):
            self.assertNotIn(forbidden, adoption)
