"""Exercise pinned pre-install update flow and the production consent authority.

Small peers count the install/grant boundary around actual Chromium methods;
this is not a replacement for the signed CRX/native installation fixture.
"""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from Scripts.engine import extension_install_overlay

FIXTURES = Path(__file__).parent / "fixtures/extension-install"
NATIVE = Path(__file__).parents[2] / "Packages/engine/Native"


def prepare(root):
    target = root / "extensions/browser"
    target.mkdir(parents=True)
    for name in ("crx_installer.h", "crx_installer.cc"):
        shutil.copy2(FIXTURES / name, target / name)
    return target


class ExtensionInstallTests(unittest.TestCase):
    def test_initial_post_refusal_releases_only_new_physical_slot_and_keepalive(self):
        source = (NATIVE / "extensions_install_bridge.mm").read_text()
        start = source.index("    operations_.emplace(request, std::move(operation));")
        admission = source[start:source.index("\n  }", start)]
        program = r'''
#include <cassert>
#include <cstdint>
#include <map>
#include <memory>
#include <vector>
#define FROM_HERE 0
namespace base { template<typename... T> int BindOnce(T...) { return 0; } }
struct Runner {
  bool accept = false;
  int posted = 0;
  bool PostTaskAndReplyWithResult(int, int, int) { ++posted; return accept; }
};
namespace extensions { Runner runner; Runner* GetExtensionFileTaskRunner() { return &runner; } }
struct StagedCRX { static int Write(std::vector<uint8_t>) { assert(false); return 0; } };
int keepalives = 0;
struct Operation { Operation() { ++keepalives; } ~Operation() { --keepalives; } };
class Installs {
 public:
  std::map<uint64_t, std::unique_ptr<Operation>> operations_;
  struct WeakFactory { int GetWeakPtr() { return 0; } } weak_factory_;
  void Staged(int) { assert(false); }
  bool Begin(uint64_t request) {
    std::vector<uint8_t> bytes{1,2,3};
    auto operation = std::make_unique<Operation>();
    // ADMISSION
  }
};
int main() {
  Installs installs;
  installs.operations_.emplace(7, std::make_unique<Operation>());
  assert(keepalives == 1);
  assert(!installs.Begin(8));
  assert(extensions::runner.posted == 1);
  assert(keepalives == 1 && installs.operations_.size() == 1 && installs.operations_.contains(7));
  extensions::runner.accept = true;
  assert(installs.Begin(9));
  assert(extensions::runner.posted == 2);
  assert(keepalives == 2 && installs.operations_.contains(7) && installs.operations_.contains(9));
  installs.operations_.clear();
  assert(keepalives == 0);
}
'''.replace("// ADMISSION", admission)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "post.cc"
            source.write_text(program)
            executable = root / "post"
            subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                            "-fsanitize=address,undefined", str(source), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=10)

    def test_overlay_is_idempotent_and_every_changed_anchor_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = prepare(root)
            extension_install_overlay.apply(root)
            first = {p.name: p.read_bytes() for p in target.iterdir()}
            extension_install_overlay.apply(root)
            self.assertEqual(first, {p.name: p.read_bytes() for p in target.iterdir()})
        for path, before, _ in extension_install_overlay.patches():
            with self.subTest(anchor=before), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                source = root / path
                source.write_text(source.read_text().replace(before, "changed pinned anchor", 1))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    extension_install_overlay.apply(root)

    def test_explicit_update_prompts_before_mutation_and_consumes_exact_proof(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = prepare(root)
            extension_install_overlay.apply(root)
            source = (target / "crx_installer.cc").read_text()
            def method(name):
                start = source.index("void CrxInstaller::" + name + "(")
                return source[start:source.index("\n}\n", start) + 3]
            confirm = method("ConfirmInstall")
            # Keep the exact production branch deciding prompt versus commit;
            # kiosk/web-extent setup is covered by full native syntax/acceptance.
            start = confirm.index("  // User-downloaded installations require an install prompt client")
            confirm = "void CrxInstaller::ConfirmInstall() {\n" + confirm[start:]
            methods = method("CheckUpdateFromSettingsPage") + confirm + method("OnInstallPromptDone")
            contract = (FIXTURES / "contract.cc").read_text().replace("// HEADER", (target / "crx_installer.h").read_text())
            contract = contract.replace("// METHODS", methods)
            path = root / "contract.cc"
            path.write_text(contract)
            executable = root / "contract"
            subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                            "-fsanitize=address,undefined", "-I", str(NATIVE), str(path), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=10)
