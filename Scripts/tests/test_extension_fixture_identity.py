"""Keep the native-owned fixture identity equal to UnpackedInstaller's realpath."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine.overlay import PACKAGE


class ExtensionFixtureIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        root = Path(cls.directory.name)
        source = (PACKAGE / "Native/extensions_bridge.mm").read_text()
        begin = source.index("bool InitializeExtensions(")
        initialize = source[begin:source.index("\nvoid ShutdownExtensions", begin)]
        begin = source.index("  void Initialize(")
        bridge_initialize = source[begin:source.index("\n  bool enabled()", begin)]
        begin = source.index("  base::FilePath FixturePath()")
        fixture_path = source[begin:source.index("\n  void Ready(", begin)]
        constants = source[source.index("constexpr char kFixtureManifest"):source.index("\n// Startup-only diagnostics")]
        program = (HARNESS.replace("FIXTURE_CONSTANTS", constants)
                   .replace("BRIDGE_INITIALIZE", bridge_initialize)
                   .replace("FIXTURE_PATH", fixture_path)
                   .replace("INITIALIZE_EXTENSIONS", initialize))
        path = root / "identity.cc"
        path.write_text(program)
        cls.executable = root / "identity"
        result = subprocess.run(
            ["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
             str(path), "-o", str(cls.executable)],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode:
            raise AssertionError(result.stderr)

    def run_scenario(self, scenario):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [str(self.executable), scenario, directory],
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_symlink_alias_matches_installer_path(self):
        self.run_scenario("alias")

    def test_unresolvable_created_path_fails_closed(self):
        self.run_scenario("unresolved")

    def test_ordinary_startup_has_no_fixture_or_filesystem_access(self):
        self.run_scenario("ordinary")


HARNESS = r"""
#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <limits.h>
#include <map>
#include <vector>
#include <cstdint>
#include <string>
namespace fs = std::filesystem;
namespace base {
template<class T> using WeakPtr = T*;
template<class Signature> struct OnceCallback { void Run(bool) {} };
template<class F, class... Args> int BindRepeating(F, Args...) { return 0; }
bool fail_resolution = false;
int resolutions = 0, writes = 0;
struct FilePath {
  fs::path value;
  bool empty() const { return value.empty(); }
  FilePath AppendASCII(const std::string& name) const { return {value / name}; }
  bool operator==(const FilePath&) const = default;
};
bool CreateDirectory(const FilePath& path) {
  return fs::create_directories(path.value) || fs::is_directory(path.value);
}
bool WriteFile(const FilePath& path, const std::string& contents) {
  ++writes;
  std::ofstream file(path.value);
  file << contents;
  return file.good();
}
FilePath MakeAbsoluteFilePath(const FilePath& path) {
  ++resolutions;
  char resolved[PATH_MAX];
  // Matches pinned base/files/file_util_posix.cc: filesystem lookup resolves
  // the alias, rather than only making a lexically absolute path.
  if (fail_resolution || !realpath(path.value.c_str(), resolved)) return {};
  return {resolved};
}
}
struct ArxEngineCallbacks {};
namespace extensions { struct Extension {}; }
namespace content { struct BrowserContext {}; }
int options_registrations = 0;
struct ChromeRuntimeAPIDelegate {
  static void SetEmbedderOptionsPageOpener(int) { ++options_registrations; }
};
// These independent boundaries have their own extracted-production tests.
int webstore_configurations = 0;
void ConfigureWebstoreInstalls(const ArxEngineCallbacks&, bool, const std::string&) { ++webstore_configurations; }
base::FilePath OwnedSettingsDiagnosticProfile() { return {}; }
int hook_configurations = 0;
void ConfigureEmbedderHooks(bool) { ++hook_configurations; }
FIXTURE_CONSTANTS
class Extensions {
 public:
BRIDGE_INITIALIZE
FIXTURE_PATH
  ArxEngineCallbacks callbacks_;
  bool enabled_ = false;
  base::FilePath fixture_path_;
  base::FilePath settings_diagnostic_profile_;
  struct WeakFactory { Extensions* GetWeakPtr() { return nullptr; } } weak_factory_;
  void OpenRuntimeOptions(const extensions::Extension*, content::BrowserContext*, base::OnceCallback<void(bool)>) {
    assert(false); // This harness only checks registration, not options dispatch.
  }
  std::map<uint32_t, std::vector<uint8_t>> install_fixtures_;
};
Extensions& Bridge() { static Extensions bridge; return bridge; }
bool PrepareInstallFixtures(const base::FilePath&, std::map<uint32_t, std::vector<uint8_t>>&) {
  assert(false); // This harness verifies only legacy unpacked/ordinary startup.
  return false;
}
int messaging_initializations = 0;
bool InitializeNativeMessagingFixture(const base::FilePath& root, const base::FilePath& extension) {
  ++messaging_initializations;
  assert(extension.value == fs::canonical(root.value / "extension"));
  return true; // Messaging behavior is covered by its separate production harness.
}
INITIALIZE_EXTENSIONS
int main(int argc, char** argv) {
  assert(argc == 3);
  const std::string scenario(argv[1]);
  const fs::path root(argv[2]);
  if (scenario == "ordinary") {
    assert(InitializeExtensions({}, false, {}, false, {}));
    assert(Bridge().FixturePath().empty());
    assert(options_registrations == 1);
    assert(base::writes == 0 && base::resolutions == 0);
    assert(messaging_initializations == 0);
    return 0;
  }
  fs::create_directory(root / "owned");
  fs::create_directory_symlink(root / "owned", root / "alias");
  base::fail_resolution = scenario == "unresolved";
  const bool started = InitializeExtensions({}, true, {root / "alias"}, false, {});
  assert(base::writes == 10 && base::resolutions == 1);
  if (scenario == "unresolved") {
    assert(options_registrations == 0);
    assert(!started && Bridge().FixturePath().empty() && !Bridge().enabled_);
    assert(messaging_initializations == 0);
    return 0;
  }
  assert(started);
  assert(options_registrations == 1);
  assert(messaging_initializations == 1);
  const auto installer_path = base::MakeAbsoluteFilePath({root / "alias/extension"});
  assert(Bridge().FixturePath() == installer_path);
  assert(Bridge().FixturePath().value == fs::canonical(root / "owned/extension"));
  assert(Bridge().FixturePath().value != root / "alias/extension");
  assert(fs::file_size(Bridge().FixturePath().value / "manifest.json") > 0);
}
"""
