"""Owned launch interception and exact fixture setup/receipt boundaries.

Registration/real dialog rendering are deliberately not performed by unit tests.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from Scripts.core import external_consent_smoke as fixture
from Scripts.engine import page_consent_overlay
from Scripts.engine.config import PACKAGE
from Scripts.tests.test_media_freeze import method


class ExternalConsentFixtureTests(unittest.TestCase):
    def root(self, directory):
        root = Path(directory).resolve()
        (root / 'profile').mkdir(mode=0o700)
        executable = root / 'Arx.app/Contents/MacOS/Arx'
        executable.parent.mkdir(parents=True)
        executable.touch()
        return root

    def test_unique_owned_handler_exact_registration_cleanup_and_one_use(self):
        with tempfile.TemporaryDirectory(prefix='app-smoke-') as directory:
            root = self.root(directory)
            with patch.object(fixture.subprocess, 'run') as run:
                handler = fixture.prepare(root, root / 'Arx.app')
                token = (root / '.arx-external-consent').read_text()
                self.assertEqual(len(token), 32)
                self.assertEqual(handler.environment, {'ARX_EXTERNAL_CONSENT_FIXTURE_ROOT': str(root)})
                self.assertIn('return 73;', run.call_args_list[0].kwargs['input'])
                self.assertEqual(run.call_args_list[2].args[0], [str(fixture.LSREGISTER), '-f', str(handler.bundle)])
                self.assertNotIn('mailto:', (root / 'external-consent/cancel.html').read_text())
                self.assertIn('rel="noopener"', (root / 'external-consent/noopener.html').read_text())
                for phase in (*fixture.BLANK_HTTP_PHASES, *fixture.BLANK_DIALOG_PHASES, *fixture.BLANK_DENIED_PHASES):
                    html = (root / ('external-consent/' + phase + '.html')).read_text()
                    self.assertIn("window.open('about:blank','_blank')", html)
                    self.assertIn("child.sessionStorage.getItem('arx-blank-proof')", html)
                immediate = (root / 'external-consent/blank-http-immediate.html').read_text()
                delayed = (root / 'external-consent/blank-http-delayed.html').read_text()
                self.assertNotIn('setTimeout', immediate)
                self.assertIn('setTimeout(()=>{child.location=target;},250)', delayed)
                with self.assertRaises(FileExistsError):
                    fixture.prepare(root, root / 'Arx.app')
                handler.cleanup()
                self.assertEqual(run.call_args.args[0], [str(fixture.LSREGISTER), '-u', str(handler.bundle)])

    def test_existing_nonprivate_symlink_and_changed_bundle_are_refused(self):
        with tempfile.TemporaryDirectory(prefix='app-smoke-') as directory:
            root = self.root(directory)
            (root / 'profile').chmod(0o755)
            with self.assertRaises(ValueError):
                fixture.prepare(root, root / 'Arx.app')
            (root / 'profile').chmod(0o700)
            link = root / 'app-smoke-link'
            link.symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError):
                fixture.prepare(link, root / 'Arx.app')
            with patch.object(fixture.subprocess, 'run'):
                handler = fixture.prepare(root, root / 'Arx.app')
                handler.bundle.rename(root / 'preserved-owned-bundle')
                handler.bundle.mkdir()
                with self.assertRaises(ValueError):
                    handler.cleanup()

    def test_exact_receipts_reject_missing_visibility_drain_and_extra_launch(self):
        with tempfile.TemporaryDirectory(prefix='app-smoke-') as directory:
            root = Path(directory)
            records = ['armed', 'os-attempt:accept:intercepted']
            records += [f'dialog:{phase}:visible' for phase in fixture.DIALOG_PHASES]
            records += [f'child:{phase}:drained' for phase in fixture.PHASES]
            records += ['os-attempt:blank-accept:intercepted']
            records += [f'dialog:{phase}:visible' for phase in fixture.BLANK_DIALOG_PHASES]
            records += [f'published:{phase}:requested' for phase in (*fixture.BLANK_DIALOG_PHASES, *fixture.BLANK_DENIED_PHASES)]
            records += [f'published:{phase}:drained' for phase in fixture.BLANK_DIALOG_PHASES]
            path = root / 'external-consent.receipt'
            path.write_text('\n'.join(records))
            fixture.verify(root, '\n'.join((fixture.MARKER, *fixture.BLANK_MARKERS)), '')
            for omitted in records:
                path.write_text('\n'.join(record for record in records if record != omitted))
                with self.subTest(omitted=omitted), self.assertRaises(ValueError):
                    fixture.verify(root, '\n'.join((fixture.MARKER, *fixture.BLANK_MARKERS)), '')
            path.write_text('\n'.join(records + ['os-attempt:accept:intercepted']))
            with self.assertRaises(ValueError):
                fixture.verify(root, '\n'.join((fixture.MARKER, *fixture.BLANK_MARKERS)), '')

    def test_production_final_boundary_never_dispatches_after_interception(self):
        signature = '''void LaunchUrlWithoutSecurityCheckWithDelegate(
    const GURL& url,
    content::WebContents* web_contents,
    content::WeakDocumentPtr initiator_document,
    ExternalProtocolHandler::Delegate* delegate) {'''
        inserted = next(new for _, old, new in page_consent_overlay.patches() if old == signature)
        body = inserted.split(signature, 1)[1]
        harness = '''#include <cassert>
#include <functional>
struct GURL {};
namespace content { struct WebContents {}; using WeakDocumentPtr = int; }
struct ExternalProtocolHandler { struct Delegate {}; };
int completions = 0, os = 0, intercepts = 0;
bool source = true;
namespace base {
struct ScopedClosureRunner {
  std::function<void()> callback;
  explicit ScopedClosureRunner(std::function<void()> value) : callback(value) {}
  ~ScopedClosureRunner() { callback(); }
};
}
std::function<void()> EmbeddedExternalCompletion(content::WebContents*) { return [] { ++completions; }; }
bool EmbeddedExternalSourceCurrent(content::WebContents*, int) { return source; }
struct Interceptor {
  std::function<void(const GURL&, content::WebContents*)> callback;
  explicit operator bool() const { return bool(callback); }
  void Run(const GURL& url, content::WebContents* contents) { callback(url, contents); }
  template<class F> Interceptor& operator=(F value) { callback = value; return *this; }
};
Interceptor& OwnedFixtureLaunchInterceptor() {
  static Interceptor interceptor;
  return interceptor;
}
''' + signature + body + '''
  (void)delegate; ++os;
}
int main() {
 GURL url; content::WebContents contents;
 LaunchUrlWithoutSecurityCheckWithDelegate(url, &contents, 1, nullptr);
 assert(os == 1 && completions == 1);
 OwnedFixtureLaunchInterceptor() = [](const auto&, auto*) { ++intercepts; };
 LaunchUrlWithoutSecurityCheckWithDelegate(url, &contents, 1, nullptr);
 assert(os == 1 && intercepts == 1 && completions == 2);
 source = false;
 LaunchUrlWithoutSecurityCheckWithDelegate(url, &contents, 1, nullptr);
 assert(os == 1 && intercepts == 1 && completions == 3);
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'boundary.cc'
            source.write_text(harness)
            binary = root / 'boundary'
            result = subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                '-fsanitize=address,undefined', str(source), '-o', str(binary)],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            subprocess.run([str(binary)], check=True, capture_output=True, timeout=5)

    def test_real_dialog_guard_keeps_all_predicates_and_value_free_failure_mask(self):
        native = (PACKAGE / 'Native/external_consent_fixture.mm').read_text()
        prefix = method(native, 'void DialogShown(').split('  const auto generation =', 1)[0]
        harness = (Path(__file__).parent / 'fixtures/external_fixture_dialog.cc').read_text()
        harness = harness.replace('// PRODUCTION_DIALOG_GUARD', prefix + '}')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'dialog.cc'
            source.write_text(harness)
            binary = root / 'dialog'
            result = subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                '-Wno-unused-parameter', '-fsanitize=address,undefined', str(source), '-o', str(binary)],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_production_initialization_requires_mock_private_exact_root_and_one_use(self):
        native = (PACKAGE / 'Native/external_consent_fixture.mm').read_text()
        harness = (Path(__file__).parent / 'fixtures/external_fixture_initialization.cc').read_text()
        signatures = {
            'STATE': 'struct Fixture', 'GET_STATE': 'Fixture& State()',
            'RECORD': 'void Record(', 'OWNED_DIRECTORY': 'bool OwnedDirectory(',
            'OWNED_HANDLER_PROGRAM': 'bool OwnedHandlerProgram(',
            'INITIALIZE': 'bool Initialize(', 'RESET': 'void Reset()',
        }
        for marker, signature in signatures.items():
            body = method(native, signature) + (';' if marker == 'STATE' else '')
            harness = harness.replace('// PRODUCTION_' + marker, body)
        with tempfile.TemporaryDirectory(prefix='app-smoke-') as directory:
            root = self.root(directory)
            source = root / 'initialize.mm'
            source.write_text(harness)
            binary = root / 'initialize'
            result = subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                '-fsanitize=address,undefined', '-framework', 'Foundation', str(source), '-o', str(binary)],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary), str(root)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / 'external-consent.receipt').read_text().splitlines(),
                ['armed', 'os-attempt:accept:intercepted', 'FAIL:unexpected-os-attempt', 'FAIL:unexpected-os-attempt'])

    def test_swift_early_admission_refuses_missing_explicit_profile_before_workspace(self):
        source = PACKAGE.parents[1] / 'Packages/features/Sources/AppFeature/ExternalConsentFixture.swift'
        harness = Path(__file__).parent / 'fixtures/ExternalConsentAdmission.swift'
        with tempfile.TemporaryDirectory(prefix='app-smoke-') as directory:
            root = self.root(directory)
            binary = root / 'admission'
            result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-D', 'DEBUG',
                '-parse-as-library', '-module-cache-path', str(root / 'swift-cache'),
                str(source), str(harness), '-o', str(binary)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary), str(root)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('ARX_EXTERNAL_ADMISSION_CHECKS_PASSED', result.stdout)
            self.assertFalse((root / 'profile/arx-workspace.json').exists())
        startup = (PACKAGE.parents[1] / 'Packages/features/Sources/AppFeature/BrowserApplication.swift').read_text()
        self.assertLess(startup.index('ExternalConsentFixture.load('), startup.index('seedWorkspace()'))
        self.assertLess(startup.index('ExternalConsentFixture.load('), startup.index('let profile ='))
        self.assertIn('|| externalConsentFixture != nil', startup)
        self.assertNotIn('|| ExternalConsentSmoke.requested', startup)
