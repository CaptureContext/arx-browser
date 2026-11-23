"""make perf-gate: a release against the previous one, with thresholds and overrides (DEV-902)."""

import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from Scripts import perf_gate


def results(*, cold=1.0, warm=0.5, switch=40.0, memory_one=300.0, memory_twenty=900.0, cpu=0.4, native=True):
    """A benchmark results.json, as make benchmark writes it, with the gate's metrics."""
    arx = {
        "first_launch_s": cold + 0.3,
        "launch_marks": {"first": {"FirstPagePainted": cold}, "warm": {"FirstPagePainted": {"median": warm}}},
        "warm_launch_s": {"median": warm + 0.2},
        "idle_one_tab": {"footprint_mb": memory_one, "cpu_percent": cpu},
        "tabs": {"steps": [{"tabs": 20, "footprint_mb": memory_twenty}], "switch": {"visible_ms": {"median": switch + 5}}},
    }
    if native:
        arx["native"] = {"steps": [{"tabs": 20, "switch": {"shown_ms": {"median": switch}}}]}
    return {"browsers": {"Arx": arx, "Chrome": {"skipped": "--skip-chrome"}}}


class PerfGateTests(unittest.TestCase):
    def setUp(self):
        self.limits = perf_gate.thresholds()

    def test_reads_every_metric_and_falls_back_when_the_native_step_was_skipped(self):
        values = perf_gate.metric_values(results())
        self.assertEqual(values, {
            "cold_launch_s": 1.0, "warm_launch_s": 0.5, "tab_switch_ms": 40.0,
            "memory_1_tab_mb": 300.0, "memory_20_tabs_mb": 900.0, "idle_cpu_percent": 0.4,
        })
        self.assertEqual(perf_gate.metric_values(results(native=False))["tab_switch_ms"], 45.0)

    def test_a_failed_benchmark_is_an_error(self):
        with self.assertRaisesRegex(ValueError, "failed"):
            perf_gate.metric_values({"browsers": {"Arx": {"error": "Arx didn't start"}}})
        # Launches measured, then the tab step failed: still a failed run, not a missing baseline.
        partial = results()
        partial["browsers"]["Arx"]["error"] = "headless step timed out"
        with self.assertRaisesRegex(ValueError, "timed out"):
            perf_gate.metric_values(partial)

    def test_the_same_numbers_pass(self):
        rows = perf_gate.compare(perf_gate.metric_values(results()), perf_gate.metric_values(results()), self.limits)
        self.assertEqual(perf_gate.verdict(rows), {"passed": True, "regressions": []})

    def test_a_regression_needs_both_thresholds(self):
        previous = perf_gate.metric_values(results())
        # +20 % but only +8 MB: noise on a small number.
        small = perf_gate.compare(previous, perf_gate.metric_values(results(memory_one=308.0, cpu=0.48)), self.limits)
        self.assertTrue(perf_gate.verdict(small)["passed"])
        # +100 MB and +33 %: a regression.
        large = perf_gate.compare(previous, perf_gate.metric_values(results(memory_one=400.0)), self.limits)
        outcome = perf_gate.verdict(large)
        self.assertFalse(outcome["passed"])
        self.assertEqual(outcome["regressions"], ["Memory, 1 tab"])

    def test_getting_faster_or_smaller_never_fails(self):
        previous = perf_gate.metric_values(results())
        rows = perf_gate.compare(previous, perf_gate.metric_values(results(cold=0.5, switch=10, memory_twenty=500)), self.limits)
        self.assertTrue(perf_gate.verdict(rows)["passed"])
        self.assertEqual({row["verdict"] for row in rows}, {"better", "within threshold"})

    def test_a_metric_the_release_didnt_measure_fails_and_a_missing_baseline_doesnt(self):
        previous = perf_gate.metric_values(results())
        current = dict(previous, tab_switch_ms=None)
        self.assertFalse(perf_gate.verdict(perf_gate.compare(previous, current, self.limits))["passed"])
        rows = perf_gate.compare(dict(previous, tab_switch_ms=None), previous, self.limits)
        self.assertTrue(perf_gate.verdict(rows)["passed"])
        self.assertIn("no baseline", {row["verdict"] for row in rows})

    def test_an_override_passes_with_a_reason_and_records_it(self):
        rows = perf_gate.compare(perf_gate.metric_values(results()), perf_gate.metric_values(results(cold=2.0)), self.limits)
        with self.assertRaises(ValueError):
            perf_gate.verdict(rows, "ok")
        outcome = perf_gate.verdict(rows, "  Engine 156 launches slower; DEV-999 fixes it  ")
        self.assertTrue(outcome["passed"])
        self.assertEqual(outcome["overridden"], "Engine 156 launches slower; DEV-999 fixes it")
        self.assertEqual(outcome["regressions"], ["First launch → first paint"])

    def test_sessions_alternate_and_take_the_median(self):
        calls = []
        values = iter([1.0, 2.0, 1.2, 1.4])
        with tempfile.TemporaryDirectory() as directory, patch.object(perf_gate, "OUTPUT", Path(directory)):
            def run(arguments):
                calls.append(arguments[1])
                folder = Path(directory) / f"run{len(calls)}"
                folder.mkdir()
                (folder / "results.json").write_text(json.dumps(results(cold=next(values))))
            runs = perf_gate.measure({"previous": "old.app", "current": "new.app"}, 2, 6, run, options=[])
        self.assertEqual(calls, ["old.app", "new.app", "new.app", "old.app"])
        self.assertEqual([run["cold_launch_s"] for run in runs["previous"]], [1.0, 1.4])
        self.assertEqual([run["cold_launch_s"] for run in runs["current"]], [2.0, 1.2])
        self.assertEqual(perf_gate.combine(runs["current"])["cold_launch_s"], 1.6)

    def test_compare_mode_writes_the_report_and_fails_on_a_regression(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "previous.json").write_text(json.dumps(results()))
            (root / "current.json").write_text(json.dumps(results(switch=80.0)))
            with patch("builtins.print"), self.assertRaisesRegex(ValueError, "Tab switch"):
                perf_gate.main(["--compare", str(root / "previous.json"), str(root / "current.json"), "--output", str(root / "gate")])
            gate = json.loads((root / "gate/gate.json").read_text())
            self.assertFalse(gate["passed"])
            self.assertIn("| regressed |", (root / "gate/gate.md").read_text())

            with patch("builtins.print"):
                perf_gate.main([
                    "--compare", str(root / "previous.json"), str(root / "current.json"),
                    "--output", str(root / "gate2"), "--override", "Switching waits for the new animation (DEV-1000).",
                ])
            self.assertEqual(json.loads((root / "gate2/gate.json").read_text())["overridden"], "Switching waits for the new animation (DEV-1000).")

    def test_the_benchmark_accepts_every_option_the_gate_passes(self):
        from Scripts import benchmark
        options = perf_gate.benchmark_options()
        parsed = benchmark.parse(["--app", "/x/Arx.app", "--launches", "6", *options])
        self.assertTrue(parsed.skip_chrome)
        self.assertEqual(parsed.tabs, [perf_gate.GATE_TABS])

    def test_optional_options_are_left_out_when_the_benchmark_refuses_them(self):
        def strict(arguments):
            if "--freeze-wait" in arguments:
                raise SystemExit(2)
        self.assertNotIn("--freeze-wait", perf_gate.benchmark_options(strict))
        self.assertIn("--freeze-wait", perf_gate.benchmark_options(lambda arguments: None))

    def test_a_session_that_missed_a_metric_leaves_it_unmeasured(self):
        complete = perf_gate.metric_values(results())
        partial = dict(complete, memory_20_tabs_mb=None, tab_switch_ms=None)
        combined = perf_gate.combine([complete, partial])
        self.assertIsNone(combined["memory_20_tabs_mb"])
        self.assertIsNone(combined["tab_switch_ms"])
        self.assertEqual(combined["memory_1_tab_mb"], 300.0)
        rows = perf_gate.compare(complete, combined, self.limits)
        self.assertFalse(perf_gate.verdict(rows)["passed"])

    # MARK: - Baselines per Mac model

    MAC = {"model": "Mac16,10", "chip": "Apple M4", "memory_gb": 24, "macos": "27.0"}

    @staticmethod
    def app(root, version="0.4.0", build="20"):
        app = Path(root) / f"Arx-{build}.app"
        (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
        (app / "Contents/MacOS/Arx").write_text("")
        with (app / "Contents/Info.plist").open("wb") as target:
            plistlib.dump({"CFBundleShortVersionString": version, "CFBundleVersion": build}, target)
        return app

    def gate(self, root, *arguments, values=None):
        """Runs the gate on a fake app with this Mac's model, the benchmark replaced by `values`."""
        measured = perf_gate.metric_values(results(**(values or {})))
        runs = {"current": [dict(measured, path="x")]}
        with patch.object(perf_gate, "measure", return_value=runs) as measure, patch("builtins.print"):
            perf_gate.main([
                "--current", str(self.app(root)), "--baselines", str(Path(root) / "baselines"),
                "--output", str(Path(root) / "gate"), *arguments,
            ], mac=self.MAC)
        return measure

    def test_a_mac_without_a_baseline_needs_a_reason_and_can_record_one(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(ValueError, r"No baseline for this Mac model \(Mac16,10\)"):
                self.gate(root, "--record")
            self.assertFalse((Path(root) / "baselines").exists())

            self.gate(root, "--override", "The first release on this Mac.", "--record")
            gate = json.loads((Path(root) / "gate/gate.json").read_text())
            self.assertEqual(gate["skipped"], "The first release on this Mac.")
            baseline = json.loads((Path(root) / "baselines/Mac16,10.json").read_text())
            self.assertEqual(baseline["release"], "0.4.0 (20)")
            self.assertEqual((baseline["model"], baseline["chip"], baseline["memory_gb"]), ("Mac16,10", "Apple M4", 24))
            self.assertEqual(baseline["metrics"]["memory_1_tab_mb"], 300.0)
            self.assertEqual(baseline["note"], "The first release on this Mac.")
            self.assertEqual(json.loads((Path(root) / "gate/baseline.json").read_text()), baseline)

    def test_the_release_is_compared_with_its_mac_models_committed_baseline(self):
        with tempfile.TemporaryDirectory() as root:
            perf_gate.write_baseline(Path(root) / "baselines/Mac16,10.json", perf_gate.baseline_record(
                perf_gate.metric_values(results()), self.MAC, release="0.3.0 (12)", sessions=2, launches=6,
            ))
            # Only the release is measured: the baseline stands for the previous one.
            measure = self.gate(root, values={"warm": 0.51})
            self.assertEqual(list(measure.call_args.args[0]), ["current"])
            gate = json.loads((Path(root) / "gate/gate.json").read_text())
            self.assertTrue(gate["passed"])
            self.assertIn("Mac16,10.json, 0.3.0 (12)", (Path(root) / "gate/gate.md").read_text())

            with self.assertRaisesRegex(ValueError, "Warm launch"):
                self.gate(root, "--record", values={"warm": 0.9})
            # A failed gate records nothing.
            baseline = json.loads((Path(root) / "baselines/Mac16,10.json").read_text())
            self.assertEqual(baseline["release"], "0.3.0 (12)")

            self.gate(root, "--record", "--override", "Warm launch waits on the new engine; DEV-999.", values={"warm": 0.9})
            baseline = json.loads((Path(root) / "baselines/Mac16,10.json").read_text())
            self.assertEqual((baseline["release"], baseline["metrics"]["warm_launch_s"]), ("0.4.0 (20)", 0.9))

    def test_only_a_release_measured_here_can_be_recorded(self):
        # Results files carry no trustworthy Mac model: they may come from another Mac.
        with tempfile.TemporaryDirectory() as root:
            for name in ("previous.json", "current.json"):
                (Path(root) / name).write_text(json.dumps(results()))
            with self.assertRaisesRegex(ValueError, "--record"):
                perf_gate.main([
                    "--compare", str(Path(root) / "previous.json"), str(Path(root) / "current.json"),
                    "--record", "--baselines", str(Path(root) / "baselines"),
                ], mac=self.MAC)
            self.assertFalse((Path(root) / "baselines").exists())

    def test_baselines_are_named_by_model_and_hold_every_metric(self):
        self.assertEqual(perf_gate.baseline_path("Mac16,10", "b"), Path("b/Mac16,10.json"))
        for model in (None, "", "../Mac16,10", "Mac16"):
            with self.assertRaises(ValueError):
                perf_gate.baseline_path(model)
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "Mac16,10.json"
            self.assertIsNone(perf_gate.read_baseline(path))
            path.write_text(json.dumps({"metrics": {"cold_launch_s": 1.0}}))
            with self.assertRaisesRegex(ValueError, "every metric"):
                perf_gate.read_baseline(path)
        partial = perf_gate.metric_values(results())
        partial["tab_switch_ms"] = None
        with self.assertRaisesRegex(ValueError, "tab_switch_ms"):
            perf_gate.baseline_record(partial, self.MAC, release=None, sessions=1, launches=1)

    def test_committed_baselines_hold_every_metric(self):
        for path in perf_gate.BASELINES.glob("*.json"):
            with self.subTest(path.name):
                baseline = perf_gate.read_baseline(path)
                self.assertEqual(path.stem, baseline["model"])

    def test_unfinished_workloads_are_not_measurements(self):
        loaded = results(native=False)
        loaded["options"] = {"switches": 20}
        arx = loaded["browsers"]["Arx"]
        arx["tabs"]["steps"][0].update(tabs=20, loaded=20)
        arx["tabs"]["switch"].update(visible_reported=20, receipt_ms={"median": 3, "n": 20})
        arx["tabs"]["switch"]["visible_ms"]["n"] = 20
        values = perf_gate.metric_values(loaded)
        self.assertEqual((values["memory_20_tabs_mb"], values["tab_switch_ms"]), (900.0, 45.0))

        # Five pages never loaded, and 19 switches timed out.
        arx["tabs"]["steps"][0]["loaded"] = 15
        arx["tabs"]["switch"]["visible_reported"] = 1
        arx["tabs"]["switch"]["visible_ms"]["n"] = 1
        values = perf_gate.metric_values(loaded)
        self.assertIsNone(values["memory_20_tabs_mb"])
        self.assertIsNone(values["tab_switch_ms"])
        self.assertEqual(values["memory_1_tab_mb"], 300.0)

    def test_every_metric_has_a_threshold(self):
        self.assertEqual(set(self.limits), {metric.key for metric in perf_gate.METRICS})


if __name__ == "__main__":
    unittest.main()
