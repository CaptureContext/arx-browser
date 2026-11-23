"""Little Arx Space smoke acceptance; these never launch the application."""

import unittest

from Scripts import little_arx_space_smoke as space_smoke


class LittleArxSpaceSmokeTests(unittest.TestCase):
    ARX = "\n".join((space_smoke.READY, *space_smoke.ARX_MARKERS)) + "\n"
    FIXTURE = space_smoke.FIXTURE_MARKER + "\n"

    def test_both_sides_passing_is_success(self):
        space_smoke.verify(0, self.ARX, 0, self.FIXTURE)

    def test_the_fixture_failing_fails_the_smoke(self):
        with self.assertRaisesRegex(ValueError, "fixture app"):
            space_smoke.verify(0, self.ARX, 1, "")

    def test_a_missing_arx_phase_fails_the_smoke(self):
        for marker in space_smoke.ARX_MARKERS:
            with self.subTest(marker=marker), self.assertRaisesRegex(ValueError, "Arx saw"):
                space_smoke.verify(0, self.ARX.replace(marker, ""), 0, self.FIXTURE)

    def test_arx_failing_after_its_markers_fails_the_smoke(self):
        with self.assertRaisesRegex(ValueError, "Arx saw"):
            space_smoke.verify(1, self.ARX, 0, self.FIXTURE)


if __name__ == "__main__":
    unittest.main()
