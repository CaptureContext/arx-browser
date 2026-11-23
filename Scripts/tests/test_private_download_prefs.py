"""Execute production private_download_prefs.mm (DEV-729) against fake prefs and profiles."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine.overlay import PACKAGE


class PrivateDownloadPrefsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        root = Path(cls.directory.name)
        production = (PACKAGE / "Native/private_download_prefs.mm").read_text()
        implementation = production[production.index("namespace arx {"):]
        harness = (Path(__file__).parent / "fixtures/private_download_prefs.cc").read_text()
        source = root / "prefs.cc"
        source.write_text(harness.replace("// IMPLEMENTATION", implementation))
        cls.executable = root / "prefs"
        result = subprocess.run(
            ["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
             "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
             str(source), "-o", str(cls.executable)],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode:
            raise AssertionError(result.stderr)

    def run_scenario(self, name):
        result = subprocess.run([str(self.executable), name], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_copies_the_openers_values_now_and_on_change_without_writing_back(self):
        self.run_scenario("copies")

    def test_managed_values_are_left_alone(self):
        self.run_scenario("managed")

    def test_refuses_an_ordinary_private_side_or_a_private_opener(self):
        self.run_scenario("refuses")

    def test_opener_destruction_detaches_at_once(self):
        self.run_scenario("opener-destroyed")

    def test_private_destruction_detaches_at_once(self):
        self.run_scenario("private-destroyed")

    def test_relinking_survives_the_old_links_queued_erase(self):
        self.run_scenario("relink")


if __name__ == "__main__":
    unittest.main()
