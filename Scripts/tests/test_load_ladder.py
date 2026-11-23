"""The load ladder's stop rule, report and baseline (DEV-1027), without launching Arx."""

import json
import tempfile
import unittest
from pathlib import Path

from Scripts import load_ladder


def calm(**changes):
    """A step that breaks nothing, with `changes`."""
    step = {"pages_not_loaded": 0, "idle_cpu_percent": 2.0, "idle_wakeups_per_second": 120.0, "slow_probes": 0,
            "slow_switches": 0, "memory_pressure": 1, "swap_growth_mb": 0.0}
    step.update(changes)
    return step


class StopRuleTests(unittest.TestCase):
    def test_a_calm_step_breaks_nothing(self):
        self.assertEqual(load_ladder.broken(calm()), [])

    def test_each_limit_breaks_only_past_its_value(self):
        for key, limit in load_ladder.LIMITS.items():
            with self.subTest(key=key):
                self.assertEqual(load_ladder.broken(calm(**{key: limit})), [])
                past = limit + (1 if isinstance(limit, int) else 0.5)
                self.assertEqual([name for name, _ in load_ladder.broken(calm(**{key: past}))], [key])

    def test_reasons_name_the_limit_and_come_in_order(self):
        reasons = load_ladder.broken(calm(memory_pressure=4, idle_cpu_percent=31.24, slow_switches=3))
        self.assertEqual([key for key, _ in reasons], ["idle_cpu_percent", "slow_switches", "memory_pressure"])
        self.assertEqual(reasons[0][1], "idle CPU 31.2% > 15%")
        self.assertEqual(reasons[1][1], "3 switches over 100 ms > 1")
        self.assertEqual(reasons[2][1], "macOS reports memory pressure (level 4)")

    def test_a_value_that_could_not_be_read_breaks_nothing(self):
        self.assertEqual(load_ladder.broken(calm(swap_growth_mb=None, memory_pressure=None)), [])


class ClimbTests(unittest.TestCase):
    def test_it_stops_at_the_first_broken_step_and_keeps_the_one_before(self):
        measured = []

        def measure(count):
            measured.append(count)
            return calm(idle_cpu_percent=count / 2)

        ladder = load_ladder.climb([10, 20, 40, 80], measure)
        self.assertEqual(measured, [10, 20, 40])
        self.assertEqual((ladder["ceiling"], ladder["broke_at"], ladder["broken"]), (20, 40, ["idle_cpu_percent"]))
        self.assertEqual([step["tabs"] for step in ladder["steps"]], [10, 20, 40])
        self.assertEqual(ladder["steps"][-1]["broken"], ["idle CPU 20.0% > 15%"])
        self.assertFalse(ladder["complete"])
        self.assertEqual(load_ladder.summary_line(ladder), "holds 20 tabs; 40 tabs broke: idle CPU 20.0% > 15%")

    def test_a_ladder_that_never_breaks_is_complete(self):
        ladder = load_ladder.climb([1, 10], lambda count: calm())
        self.assertEqual((ladder["ceiling"], ladder["broke_at"], ladder["complete"]), (10, None, True))
        self.assertEqual(load_ladder.summary_line(ladder), "held every step, up to 10 tabs")

    def test_a_first_step_that_breaks_has_no_ceiling(self):
        ladder = load_ladder.climb([5, 10], lambda count: calm(slow_probes=2))
        self.assertEqual((ladder["ceiling"], ladder["broke_at"]), (None, 5))
        self.assertTrue(load_ladder.summary_line(ladder).startswith("broke at the first step; 5 tabs broke:"))

    def test_a_step_that_fails_stops_the_ladder_and_keeps_the_steps_before(self):
        def measure(count):
            if count == 20:
                raise ValueError("selectTab failed")
            return calm()

        ladder = load_ladder.climb([10, 20, 40], measure)
        self.assertEqual((ladder["ceiling"], ladder["broke_at"]), (10, 20))
        self.assertEqual(ladder["error"], "ValueError: selectTab failed")
        self.assertEqual([step["tabs"] for step in ladder["steps"]], [10])
        self.assertEqual(load_ladder.summary_line(ladder), "holds 10 tabs; stopped at 20 tabs: ValueError: selectTab failed")

    def test_a_step_the_harness_cant_drive_ends_the_ladder_without_failing_it(self):
        def measure(count):
            if count == 300:
                raise load_ladder.Unmeasurable("250 of the 256 MCP mutations Arx allows a client are used")
            return calm()

        ladder = load_ladder.climb([100, 200, 300], measure)
        self.assertEqual((ladder["ceiling"], ladder["broke_at"], ladder["error"], ladder["complete"]),
                         (200, None, None, False))
        self.assertEqual(load_ladder.failed_ladders({"ladders": {"awake": ladder}}), [])
        self.assertEqual(load_ladder.summary_line(ladder), "held every step, up to 200 tabs; stopped before "
                         "300 tabs: 250 of the 256 MCP mutations Arx allows a client are used")

    def test_the_default_awake_ladder_fits_the_mcp_mutation_budget(self):
        options = load_ladder.parse([])
        opens = options.awake_steps[-1]
        switches = options.switches * sum(1 for count in options.awake_steps if count > 1)
        self.assertLessEqual(opens + 2 + switches, load_ladder.MUTATION_BUDGET)

    def test_finish_runs_even_when_start_fails(self):
        finished = []

        def start():
            raise ValueError("no ready event")

        ladder = load_ladder.climb([10], lambda count: calm(), start=start, finish=lambda: finished.append(True))
        self.assertEqual(finished, [True])
        self.assertEqual(ladder["steps"], [])
        self.assertEqual(load_ladder.summary_line(ladder), "didn't run: ValueError: no ready event")


class OptionTests(unittest.TestCase):
    def test_defaults_climb_both_ladders(self):
        options = load_ladder.parse([])
        self.assertEqual(options.ladders, ["awake", "unloaded"])
        self.assertEqual(options.awake_steps, list(load_ladder.AWAKE_STEPS))
        self.assertEqual(options.unloaded_steps, list(load_ladder.UNLOADED_STEPS))

    def test_quick_is_a_tiny_ladder(self):
        options = load_ladder.parse(["--quick"])
        self.assertEqual((options.awake_steps, options.unloaded_steps), ([5, 10], [5, 10]))
        self.assertEqual((options.idle, options.probe, options.switches, options.warmup), (3, 2, 3, 0))
        # An option given beside --quick still counts.
        self.assertEqual(load_ladder.parse(["--quick", "--warmup", "180"]).warmup, 180)
        self.assertEqual(load_ladder.parse([]).warmup, load_ladder.benchmark.WARMUP_S)

    def test_unloaded_steps_settle_past_ublocks_list_update(self):
        # uBlock updates its lists 37 s after a launch and saves its selfie about 55 s later.
        self.assertGreaterEqual(load_ladder.parse([]).restore_settle, 37 + 55)
        self.assertEqual(load_ladder.parse(["--quick"]).restore_settle, 30)
        self.assertEqual(load_ladder.parse(["--quick", "--restore-settle", "90"]).restore_settle, 90)
        ladder = load_ladder.Unloaded(None, Path("/tmp"), None, load_ladder.parse([]), None)
        self.assertEqual(ladder.settle, load_ladder.RESTORE_SETTLE)

    def test_steps_must_rise(self):
        for text in ["10,5", "10,10", "0,5", "x"]:
            with self.subTest(text=text), self.assertRaises(SystemExit):
                load_ladder.parse(["--awake-steps", text])

    def test_unknown_ladders_are_refused(self):
        with self.assertRaises(SystemExit):
            load_ladder.parse(["--ladders", "asleep"])
        self.assertEqual(load_ladder.parse(["--ladders", "unloaded"]).ladders, ["unloaded"])


class SystemTests(unittest.TestCase):
    def test_swap_use_is_read_in_megabytes(self):
        self.assertEqual(load_ladder.swap_used_mb("total = 2048.00M  used = 1081.25M  free = 966.75M  (encrypted)"), 1081.25)
        self.assertEqual(load_ladder.swap_used_mb("total = 4.00G  used = 1.50G  free = 2.50G  (encrypted)"), 1536.0)
        self.assertEqual(load_ladder.swap_used_mb("total = 0.00M  used = 0.00M  free = 0.00M"), 0.0)
        self.assertIsNone(load_ladder.swap_used_mb(""))

    def test_a_long_answer_counts_for_every_probe_interval_it_held(self):
        self.assertEqual(load_ladder.slow_slots([20, 40, 150]), 1)
        self.assertEqual(load_ladder.slow_slots([6000]), 31)
        self.assertEqual(load_ladder.slow_slots([450, 30]), 3)
        self.assertGreater(load_ladder.slow_slots([6000]), load_ladder.LIMITS["slow_probes"])

    def test_switches_never_select_the_tab_just_selected(self):
        import random
        for tabs in (["a", "b"], ["a", "b", "c", "d", "e"]):
            targets = load_ladder.switch_targets(tabs, 50, random.Random(1027))
            self.assertEqual(len(targets), 50)
            self.assertTrue(all(previous != current for previous, current in zip(targets, targets[1:])))
            self.assertTrue(set(targets) <= set(tabs))
        # The tab a step before left selected isn't the first switch of the next.
        for seed in range(50):
            self.assertNotEqual(load_ladder.switch_targets(["a", "b", "c"], 1, random.Random(seed), "a"), ["a"])

    def test_timings_count_slow_ones(self):
        self.assertEqual(load_ladder.slow([12, 100, 101, 250]), 2)
        self.assertEqual(load_ladder.milliseconds([30, 10, 20])["worst"], 30)
        self.assertIsNone(load_ladder.milliseconds([]))


class WorkspaceTests(unittest.TestCase):
    def test_restored_tabs_replace_only_the_first_spaces_unpinned_tabs(self):
        workspace = {"organization": {
            "tabs": [{"id": "PINNED", "profileID": "P", "restoration": {"title": "Pinned", "url": "https://a.test"}},
                     {"id": "OLD", "profileID": "P", "restoration": {"title": "Old", "url": "https://b.test"}}],
            "spaces": [{"id": "S", "profileID": "P", "pinnedTabs": ["PINNED"], "unpinnedTabs": ["OLD"],
                        "selectedTabID": "OLD"}],
        }, "version": 3}
        result = load_ladder.with_tabs(workspace, [{"title": f"T{index}", "url": f"http://t{index}.localhost/"}
                                                   for index in range(3)])
        organization = result["organization"]
        space = organization["spaces"][0]
        self.assertEqual(space["pinnedTabs"], ["PINNED"])
        self.assertEqual(len(space["unpinnedTabs"]), 3)
        self.assertEqual([tab["id"] for tab in organization["tabs"]][0], "PINNED")
        self.assertNotIn("OLD", [tab["id"] for tab in organization["tabs"]])
        restored = [tab for tab in organization["tabs"] if tab["id"] in space["unpinnedTabs"]]
        self.assertEqual([tab["restoration"]["title"] for tab in restored], ["T0", "T1", "T2"])
        self.assertTrue(all(tab["profileID"] == "P" for tab in restored))
        self.assertEqual(result["version"], 3)
        # The selection moves to a tab that's there.
        self.assertEqual(space["selectedTabID"], space["unpinnedTabs"][0])

    def test_a_pinned_selection_stays_and_an_emptied_space_has_none(self):
        workspace = {"organization": {
            "tabs": [{"id": "PINNED", "profileID": "P", "restoration": {"title": "Pinned", "url": "https://a.test"}},
                     {"id": "OLD", "profileID": "P", "restoration": {"title": "Old", "url": "https://b.test"}}],
            "spaces": [{"id": "S", "profileID": "P", "pinnedTabs": ["PINNED"], "unpinnedTabs": ["OLD"],
                        "selectedTabID": "PINNED"}],
        }}
        space = load_ladder.with_tabs(workspace, [{"title": "T", "url": "http://t.localhost/"}])["organization"]["spaces"][0]
        self.assertEqual(space["selectedTabID"], "PINNED")

        workspace["organization"]["spaces"][0]["selectedTabID"] = space["unpinnedTabs"][0]
        emptied = load_ladder.with_tabs(workspace, [])["organization"]["spaces"][0]
        self.assertNotIn("selectedTabID", emptied)


class FailureTests(unittest.TestCase):
    def test_a_ladder_stopped_by_a_failure_is_not_a_ceiling(self):
        def measure(count):
            raise ValueError("no ready event")

        results = {"ladders": {"awake": load_ladder.climb([5], lambda count: calm()),
                               "unloaded": load_ladder.climb([5], measure)}}
        self.assertEqual(load_ladder.failed_ladders(results), ["unloaded"])
        results["ladders"]["unloaded"] = load_ladder.climb([5], lambda count: calm(idle_cpu_percent=90.0))
        # A limit that broke is the answer, not a failure.
        self.assertEqual(load_ladder.failed_ladders(results), [])


class ReportTests(unittest.TestCase):
    def results(self, quick=False):
        awake = load_ladder.climb([5, 10], lambda count: calm(
            idle_cpu_percent=2.5 * count, loaded=count, open_and_load_s=1.5, footprint_mb=300.0, renderers=count,
            probe_ms={"worst": 40.0}, switch_ms={"worst": 80.0}))
        unloaded = load_ladder.climb([5, 10], lambda count: calm(
            loaded_at_restore=0, launch_to_ready_s=2.0, footprint_mb=250.0, renderers=1))
        return {"started": "2026-11-16T10:00:00+00:00", "quick": quick, "version": "0.3.0 (42)",
                "machine": {"model": "Mac16,10", "chip": "Apple M4", "memory": "24 GB", "macos": "27.0 (26A1)",
                            "power": "AC", "commit": "abc1234", "load_average": [3.2, 2.0, 1.0]},
                "limits": load_ladder.LIMITS, "slow_ms": load_ladder.SLOW_MS,
                "ladders": {"awake": awake, "unloaded": unloaded}}

    def test_the_report_names_each_ceiling_and_what_broke(self):
        text = load_ladder.report(self.results())
        self.assertIn("Mac16,10, Apple M4, 24 GB, macOS 27.0 (26A1), on AC power", text)
        self.assertIn("load average 3.2", text)
        self.assertIn("## Awake tabs", text)
        self.assertIn("**holds 5 tabs; 10 tabs broke: idle CPU 25.0% > 15%**", text)
        self.assertIn("## Unloaded tabs", text)
        self.assertIn("**held every step, up to 10 tabs**", text)
        self.assertIn("| 10 | 10 | 1.5 s | 25.0% |", text)
        self.assertIn("| 5 | 0 | 2.0 s |", text)
        self.assertNotIn("not a baseline", text)

    def test_a_quick_report_says_it_is_not_a_baseline(self):
        self.assertIn("Its numbers are not a baseline.", load_ladder.report(self.results(quick=True)))

    def test_the_baseline_keeps_each_ladders_ceiling_per_mac_model(self):
        with tempfile.TemporaryDirectory() as directory:
            path = load_ladder.record(self.results(), Path(directory))
            self.assertEqual(path.name, "Mac16,10.json")
            baseline = json.loads(path.read_text())
        self.assertEqual(baseline["model"], "Mac16,10")
        self.assertEqual(baseline["release"], "0.3.0 (42)")
        self.assertEqual(baseline["ladders"]["awake"]["ceiling"], 5)
        self.assertEqual(baseline["ladders"]["awake"]["broken"], ["idle_cpu_percent"])
        self.assertEqual(baseline["ladders"]["unloaded"], {"ceiling": 10, "broke_at": None, "broken": [],
                                                           "complete": True, "steps": [5, 10],
                                                           "unmeasurable": None, "error": None})
        self.assertEqual(baseline["limits"], load_ladder.LIMITS)

    def test_load_baselines_live_apart_from_the_perf_gates(self):
        # The perf gate reads every perf-baselines/*.json as one of its own.
        self.assertEqual(load_ladder.BASELINES.name, "load")
        self.assertEqual(load_ladder.BASELINES.parent.name, "perf-baselines")


if __name__ == "__main__":
    unittest.main()
