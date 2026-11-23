"""The profile release smoke's oracle (DEV-880), without building the app."""
import subprocess
import tempfile
import unittest
from pathlib import Path

from Scripts import profile_release_smoke as fixture, tasks


def process(stdout, returncode=0):
    return subprocess.CompletedProcess(["Arx"], returncode, stdout, "")


SUCCESS = "".join(f"ARX_PROFILE_RELEASE_PHASE_{phase}\n" for phase in fixture.PHASES) + \
    "ARX_PROFILE_RELEASE_SMOKE_SUCCESS\n"


class ProfileReleaseSmokeTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.profile = Path(directory.name)
        for key in (fixture.SETTINGS, fixture.PAGE):
            (self.profile / f"Arx-{key}").mkdir()

    def test_passes_when_used_profiles_loaded_and_the_unused_one_never_did(self):
        fixture.verify(process(SUCCESS), self.profile)

    def test_an_unused_profile_that_loaded_fails(self):
        (self.profile / f"Arx-{fixture.UNTOUCHED}").mkdir()
        with self.assertRaisesRegex(ValueError, "nothing used"):
            fixture.verify(process(SUCCESS), self.profile)

    def test_a_profile_that_never_loaded_on_first_use_fails(self):
        (self.profile / f"Arx-{fixture.PAGE}").rmdir()
        with self.assertRaisesRegex(ValueError, "never loaded"):
            fixture.verify(process(SUCCESS), self.profile)

    def test_missing_phases_and_failed_runs_fail(self):
        with self.assertRaisesRegex(ValueError, "skipped RELEASED"):
            fixture.verify(process(SUCCESS.replace("ARX_PROFILE_RELEASE_PHASE_RELEASED\n", "")), self.profile)
        with self.assertRaisesRegex(ValueError, "failed"):
            fixture.verify(process(SUCCESS, returncode=1), self.profile)

    def test_the_environment_shortens_the_grace_period_and_names_the_fixture(self):
        env = fixture.environment(self.profile, 8080)
        self.assertEqual(env["ARX_PROFILE_RELEASE_GRACE_SECONDS"], "4")
        self.assertEqual(env["ARX_PROFILE_RELEASE_SMOKE_URL"], "http://127.0.0.1:8080/")
        self.assertIs(tasks.COMMANDS["profile-release-smoke"], fixture.main)


if __name__ == "__main__":
    unittest.main()
