"""Check the Swift Testing width `make test` runs with (DEV-970)."""

import unittest

from Scripts import test


class TestParallelismTests(unittest.TestCase):
    def test_default_width_caps_swift_testing(self):
        self.assertEqual(test.environment({})[test.PARALLELIZATION_WIDTH], "8")

    def test_test_parallelism_sets_the_width(self):
        self.assertEqual(test.environment({"TEST_PARALLELISM": " 3 "})[test.PARALLELIZATION_WIDTH], "3")

    def test_an_explicit_swift_testing_width_wins(self):
        base = {"TEST_PARALLELISM": "3", test.PARALLELIZATION_WIDTH: "1"}
        self.assertEqual(test.environment(base)[test.PARALLELIZATION_WIDTH], "1")

    def test_other_variables_pass_through(self):
        self.assertEqual(test.environment({"BUILD_JOBS": "2"})["BUILD_JOBS"], "2")

    def test_invalid_widths_are_refused(self):
        for value in ("0", "-1", "many"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                test.environment({"TEST_PARALLELISM": value})


if __name__ == "__main__":
    unittest.main()
