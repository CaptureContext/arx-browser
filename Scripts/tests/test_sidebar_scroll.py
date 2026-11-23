"""The sidebar scroll benchmark's options, scroll legs and report, and its driver's own checks,
without launching Arx or touching the screen (DEV-1238)."""

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from Scripts import sidebar_scroll


def run(**values):
    answer = {"frames": 700, "refresh_ms": 8.33, "dropped": 2, "missed_intervals": 3, "worst_gap_ms": 33.3,
              "p95_gap_ms": 8.4, "main_cpu_percent": 40.0, "main_cpu_ms_per_frame": 3.3, "process_cpu_ms": 4000,
              "events": 740, "scroll_frames": 720, "harness_dropped": 0,
              "harness_missed_intervals": 0, "harness_worst_gap_ms": 9.0, "arx_frontmost_at_end": True}
    answer.update(values)
    return answer


class OptionTests(unittest.TestCase):
    def test_defaults_cover_the_ticket(self):
        options = sidebar_scroll.parse([])
        self.assertEqual(options.tabs, [30, 150, 400])
        self.assertEqual(options.pointer, ["inside", "outside"])
        self.assertIsNone(options.app)
        self.assertIsNone(options.ref)

    def test_rejects_bad_values(self):
        for arguments in (["--tabs", "0"], ["--tabs", "a"], ["--pointer", "above"], ["--runs", "0"],
                          ["--seconds", "0.2"], ["--leg", "-1"], ["--app", "A.app", "--ref", "main"]):
            with self.subTest(arguments=arguments), self.assertRaises(SystemExit):
                sidebar_scroll.parse(arguments)

    def test_takes_a_ref_or_an_app(self):
        self.assertEqual(sidebar_scroll.parse(["--ref", "d9354f34^1"]).ref, "d9354f34^1")
        self.assertEqual(sidebar_scroll.parse(["--app", "Arx.app", "--pointer", "outside"]).pointer, ["outside"])


class CompletenessTests(unittest.TestCase):
    def test_every_size_and_pointer_needs_a_valid_run(self):
        options = sidebar_scroll.parse(["--tabs", "400"])
        good = ReportTests.results({"inside": [run()], "outside": [run()]})
        self.assertTrue(sidebar_scroll.complete(good, options))
        lost = ReportTests.results({"inside": [run()], "outside": [run(arx_frontmost_at_end=False)]})
        self.assertFalse(sidebar_scroll.complete(lost, options))
        self.assertFalse(sidebar_scroll.complete(good, sidebar_scroll.parse(["--tabs", "150,400"])))
        good["counts"][0]["error"] = "no window"
        self.assertFalse(sidebar_scroll.complete(good, options))


class ReportTests(unittest.TestCase):
    def test_medians_leave_out_runs_that_lost_the_front_or_whose_clock_stalled(self):
        summary = sidebar_scroll.medians([
            run(dropped=1), run(dropped=3), run(dropped=50, arx_frontmost_at_end=False),
            run(dropped=60, harness_dropped=1, harness_missed_intervals=40),
            run(dropped=30, harness_dropped=1, harness_missed_intervals=1, harness_worst_gap_ms=500),
            {"error": "no window"},
        ])
        self.assertEqual(summary["runs"], 2)
        self.assertEqual(summary["invalid"], 4)
        self.assertEqual(summary["dropped"], 2)
        self.assertEqual(summary["frames"], 700)

    def test_no_valid_run_gives_empty_cells(self):
        summary = sidebar_scroll.medians([run(arx_frontmost_at_end=False)])
        self.assertIsNone(summary["dropped"])
        self.assertIn("-", sidebar_scroll.table(self.results({"inside": [run(arx_frontmost_at_end=False)]})))

    def test_table_has_a_row_per_count_and_pointer_and_names_the_rate(self):
        results = self.results({"inside": [run(), run()], "outside": [run(dropped=0)]})
        text = sidebar_scroll.table(results)
        self.assertIn("abc1234", text)
        self.assertIn("120 Hz", text)
        lines = text.splitlines()
        self.assertTrue(lines[1].startswith("tabs"))
        self.assertEqual(len([line for line in lines if line.startswith("400")]), 2)

    def test_an_error_shows_in_the_table(self):
        results = self.results({"inside": [{"error": "no window"}]})
        results["counts"][0]["error"] = "no window"
        self.assertIn("no window", sidebar_scroll.table(results))

    def test_compare_shows_before_and_after(self):
        before = self.results({"inside": [run(dropped=9)]}, commit="old")
        after = self.results({"inside": [run(dropped=2)]}, commit="new")
        text = sidebar_scroll.compare(before, after)
        self.assertIn("old → new", text)
        self.assertIn("9 → 2", text)

    def test_results_are_written_as_json_and_a_table(self):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory)
        sidebar_scroll.write(directory, self.results({"inside": [run()]}))
        self.assertEqual(json.loads((directory / "results.json").read_text())["counts"][0]["tabs"], 400)
        self.assertIn("dropped", (directory / "results.txt").read_text())

    @staticmethod
    def results(runs, commit="abc1234"):
        return {"app": {"commit": commit}, "counts": [{
            "tabs": 400, "runs": runs,
            "median": {pointer: sidebar_scroll.medians(values) for pointer, values in runs.items()},
        }]}


@unittest.skipUnless(shutil.which("xcrun"), "needs Xcode's swiftc")
class DriverTests(unittest.TestCase):
    def test_the_driver_builds_once_and_passes_its_own_checks(self):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory)
        driver = sidebar_scroll.build_driver(directory=directory)
        self.assertEqual(sidebar_scroll.build_driver(directory=directory), driver)
        result = subprocess.run([str(driver), "self-test"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_driver_refuses_a_run_without_a_process(self):
        driver = sidebar_scroll.build_driver()
        for arguments, message in ((["--seconds", "2"], "--pid"), (["--pid", "1"], "--rows or --leg"),
                                   (["--pid", "1", "--rows", "30", "--window", "big"], "--window")):
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(driver), "run", *arguments], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn(message, result.stderr)


if __name__ == "__main__":
    unittest.main()
