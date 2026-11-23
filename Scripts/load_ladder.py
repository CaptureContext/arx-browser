"""`make load-ladder`: how many tabs Arx holds before the Mac feels it (DEV-1027).

Two ladders on headless Arx, each on fresh throwaway storage under
`~/Library/Caches/arx-benchmark/`, with loopback fixture pages only (`core/benchmark_fixture.py`):

  awake     tabs opened through Arx's MCP helper behind the selected one, as ⌘-click opens
            them, then left to load and settle
  unloaded  tabs written into the profile's workspace and Arx started again, so they come back
            as a relaunch restores them: listed, not loaded until selected

At each step, for `--idle` seconds nobody touches Arx: CPU and wakeups of every process it owns,
and their memory. Then for `--probe` seconds a one-item `browser_inventory` every 200 ms times
how long Arx takes to answer, which its main thread does: the main-thread lag a person would
feel (headless Arx runs no stall watchdog). Then `--switches` tab switches are timed by their
`selectTab` round trip. The Mac's memory pressure and how much its swap grew are read last.

A ladder stops at the first step that breaks any limit in `LIMITS` and names the limits it
broke; the step before is its ceiling. Results go to `build/load-ladder/<UTC time>/results.json`
and `results.md`. `--record` writes the ceilings to
`Scripts/perf-baselines/load/<model>.json`. See `Scripts/README.md` ("Load ladder").

Options (`make load-ladder ARGS='…'`):
  --app PATH            measure this Arx.app instead of building one (signed, Release)
  --configuration C     build configuration when building (default Release)
  --ladders L           awake, unloaded or both (default awake,unloaded)
  --awake-steps 1,10    tab counts for the awake ladder (default AWAKE_STEPS)
  --unloaded-steps 100  tab counts for the unloaded ladder (default UNLOADED_STEPS)
  --idle SECONDS        quiet window per step (default 10)
  --probe SECONDS       main-thread probe window per step (default 5)
  --switches N          tab switches per step (default 5)
  --restore-settle S    seconds an unloaded step waits after its relaunch is ready before
                        measuring (default RESTORE_SETTLE, 120): past uBlock's post-launch list
                        update and the selfie it saves after one
  --warmup SECONDS      seconds each ladder's new profile runs with one tab before its first
                        step (default benchmark.WARMUP_S, 180): Chromium's component updater and
                        uBlock's list update write their data in the first minutes, and uBlock
                        compiles its lists after every launch until it has saved them
  --record              write the ceilings to Scripts/perf-baselines/load/<model>.json
  --keep                keep the throwaway profiles
  --quick               a short check that both ladders run: 5 and 10 tabs each, 3 s idle,
                        2 s probe, 3 switches, a 30 s restore settle, no warm-up unless
                        --warmup says. Its numbers are
                        not a baseline.
"""

import argparse
import json
import os
import random
import shutil
import signal
import statistics
import subprocess
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from . import benchmark
from .core import benchmark_fixture, process_metrics
from .core.paths import ROOT

# Arx allows an MCP client 256 mutations an app session (BrowserAutomation, `limitExceeded`):
# every open, close and switch counts, so the awake ladder fits 200 tabs with 5 switches a step.
AWAKE_STEPS = (1, 10, 20, 40, 60, 80, 100, 150, 200)
MUTATION_BUDGET = 256
UNLOADED_STEPS = (100, 250, 500, 1000, 2000, 4000)
LADDERS = ("awake", "unloaded")
SETTLE = 10  # seconds after a step's pages report loaded before measuring
# Seconds after a relaunch is ready before an unloaded step measures. uBlock's updater runs 37 s
# after every launch and diff-updates any list that changed upstream, then saves its selfie some
# 55 s later (about 100 MB, Scripts/README.md "Persistence"). With 30 s, the quiet window
# (33 to 43 s after launch) straddled that update whenever a list had changed: a Mac mini's
# baseline broke at 100 restored tabs on 18% CPU in the extension processes and 13 MB written by
# the browser, while the same rung idles at 0.5% when no list changed (DEV-1180).
RESTORE_SETTLE = 120
PROBE_INTERVAL = 0.2
SLOW_MS = 100  # a main-thread answer or a switch slower than this is a hitch a person notices
QUICK = {"awake_steps": "5,10", "unloaded_steps": "5,10", "idle": 3, "probe": 2, "switches": 3, "warmup": 0,
         "restore_settle": 30}
OUTPUT = ROOT / "build/load-ladder"
BASELINES = Path(__file__).with_name("perf-baselines") / "load"  # apart from the perf gate's <model>.json

# What "the Mac doesn't feel it" means, as numbers. The wakeup limit is provisional: the first
# quiet-machine run calibrates it (DEV-1027).
LIMITS = {
    "pages_not_loaded": 0,           # awake pages that never reported loaded
    "idle_cpu_percent": 15.0,        # % of one core, every Arx process, nobody touching it
    "idle_wakeups_per_second": 1000.0,
    "slow_probes": 1,                # probe intervals held by main-thread answers over SLOW_MS while
                                     # idle (slow_slots): one can be the Mac's on a busy machine
    "slow_switches": 1,              # switches whose selectTab took over SLOW_MS
    "memory_pressure": 1,            # kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical
    "swap_growth_mb": 512.0,         # swap used since the ladder started
}
REASONS = {
    "pages_not_loaded": "{value} pages never loaded",
    "idle_cpu_percent": "idle CPU {value:.1f}% > {limit:.0f}%",
    "idle_wakeups_per_second": "{value:.0f} idle wakeups/s > {limit:.0f}",
    "slow_probes": "{value} probe intervals with a main-thread answer over {slow} ms while idle > {limit}",
    "slow_switches": "{value} switches over {slow} ms > {limit}",
    "memory_pressure": "macOS reports memory pressure (level {value})",
    "swap_growth_mb": "swap grew {value:.0f} MB > {limit:.0f} MB",
}


def main(arguments=()):
    options = parse(arguments)
    started = datetime.now(timezone.utc)
    output = OUTPUT / started.strftime("%Y%m%dT%H%M%SZ")
    output.mkdir(parents=True, exist_ok=True)
    app = Path(options.app).resolve() if options.app else benchmark.build(options.configuration)
    benchmark.PROFILES.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix=started.strftime("ladder-%Y%m%dT%H%M%S-"), dir=benchmark.PROFILES))
    results = {"started": started.isoformat(), "machine": benchmark.machine(), "quick": options.quick,
               "app": str(app), "version": benchmark.bundle_version(app), "limits": LIMITS,
               "slow_ms": SLOW_MS, "options": {key: value for key, value in vars(options).items()}, "ladders": {}}
    try:
        with benchmark_fixture.Server() as server:
            for name in options.ladders:
                ladder = Awake if name == "awake" else Unloaded
                steps = options.awake_steps if name == "awake" else options.unloaded_steps
                runner = ladder(app, scratch / name, server, options, output / f"{name}.log")
                results["ladders"][name] = climb(steps, runner.step, start=runner.start, finish=runner.stop)
                write(output, results)
    finally:
        write(output, results)
        if not options.keep:
            shutil.rmtree(scratch, ignore_errors=True)
    print(f"Load ladder results: {output / 'results.md'}", flush=True)
    for name, ladder in results["ladders"].items():
        print(f"  {name}: {summary_line(ladder)}", flush=True)
    failed = failed_ladders(results)
    if failed:
        # After the report is written, so what was measured is kept; nothing is recorded, and
        # `execute` turns this into exit 1.
        raise ValueError(f"Load ladder: {', '.join(failed)} stopped on a failure, not a limit; "
                         f"no baseline recorded. See {output / 'results.md'}")
    if options.record and not options.quick:
        path = record(results)
        print(f"Load ladder baseline: {path}", flush=True)
    return 0


def failed_ladders(results):
    """Ladders that stopped because something failed, so their ceiling measures nothing."""
    return [name for name, ladder in results["ladders"].items() if ladder.get("error")]


def parse(arguments):
    parser = argparse.ArgumentParser(prog="make load-ladder ARGS=")
    parser.add_argument("--app")
    parser.add_argument("--configuration", default="Release")
    parser.add_argument("--ladders", default=",".join(LADDERS))
    parser.add_argument("--awake-steps", default=",".join(map(str, AWAKE_STEPS)))
    parser.add_argument("--unloaded-steps", default=",".join(map(str, UNLOADED_STEPS)))
    parser.add_argument("--idle", type=float, default=10)
    parser.add_argument("--probe", type=float, default=5)
    parser.add_argument("--switches", type=int, default=5)
    parser.add_argument("--warmup", type=float, default=benchmark.WARMUP_S)
    parser.add_argument("--restore-settle", type=float, default=RESTORE_SETTLE)
    parser.add_argument("--record", action="store_true")
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--quick", action="store_true")
    arguments = list(arguments)
    if "--quick" in arguments:
        # Defaults, so an option given beside --quick still counts.
        parser.set_defaults(**QUICK)
    options = parser.parse_args(arguments)
    options.ladders = [name.strip() for name in options.ladders.split(",") if name.strip()]
    unknown = [name for name in options.ladders if name not in LADDERS]
    if unknown or not options.ladders:
        parser.error(f"--ladders takes {', '.join(LADDERS)}")
    options.awake_steps = steps(parser, options.awake_steps)
    options.unloaded_steps = steps(parser, options.unloaded_steps)
    return options


def steps(parser, text):
    """Tab counts, rising: a ladder that went down would measure fewer tabs than it had open."""
    try:
        values = [int(value) for value in text.split(",") if value.strip()]
    except ValueError:
        parser.error(f"steps are tab counts: {text}")
    if not values or any(value < 1 for value in values) or values != sorted(set(values)):
        parser.error(f"steps must be positive and rising: {text}")
    return values


# MARK: - The ladder

class Unmeasurable(Exception):
    """A step this harness can't drive, such as more MCP mutations than Arx allows a client:
    the ladder ends there without a broken limit or a failure."""


def broken(step, limits=LIMITS):
    """The limits `step` breaks, as `(key, reason)` in `LIMITS` order. A missing value breaks
    nothing: a ladder that can't read swap still stops on CPU."""
    result = []
    for key, limit in limits.items():
        value = step.get(key)
        if value is not None and value > limit:
            result.append((key, REASONS[key].format(value=value, limit=limit, slow=SLOW_MS)))
    return result


def climb(counts, measure, start=None, finish=None):
    """Measures each count in turn and stops at the first that breaks a limit or fails.

    `measure(count)` returns the step's numbers. The ceiling is the last count that passed: None
    when the first step broke, the top count when none did (`complete`).
    """
    ladder = {"steps": [], "ceiling": None, "broke_at": None, "broken": [], "error": None, "complete": False,
              "unmeasurable": None}
    try:
        if start:
            start()
        for count in counts:
            try:
                step = measure(count)
            except Unmeasurable as reason:
                ladder["unmeasurable"] = f"{count} tabs: {reason}"
                break
            except Exception as error:  # Kept with the steps before it, as the benchmark keeps a browser's.
                ladder.update(broke_at=count, error=f"{type(error).__name__}: {error}")
                break
            step["tabs"] = count
            step["broken"] = [reason for _, reason in broken(step)]
            ladder["steps"].append(step)
            if step["broken"]:
                ladder.update(broke_at=count, broken=[key for key, _ in broken(step)])
                break
            ladder["ceiling"] = count
        else:
            ladder["complete"] = True
    except Exception as error:
        ladder["error"] = f"{type(error).__name__}: {error}"
    finally:
        if finish:
            try:
                finish()
            except Exception as error:
                ladder["error"] = ladder["error"] or f"{type(error).__name__}: {error}"
    return ladder


def summary_line(ladder):
    if ladder.get("error") and ladder.get("broke_at") is None and not ladder["steps"]:
        return f"didn't run: {ladder['error']}"
    if ladder["complete"]:
        return f"held every step, up to {ladder['ceiling']} tabs"
    if ladder.get("unmeasurable"):
        held = f"held every step, up to {ladder['ceiling']} tabs" if ladder["ceiling"] else "measured no step"
        return f"{held}; stopped before {ladder['unmeasurable']}"
    ceiling = f"holds {ladder['ceiling']} tabs" if ladder["ceiling"] else "broke at the first step"
    if ladder.get("error"):
        return f"{ceiling}; stopped at {ladder['broke_at']} tabs: {ladder['error']}"
    reasons = ladder["steps"][-1]["broken"] if ladder["steps"] else []
    return f"{ceiling}; {ladder['broke_at']} tabs broke: {'; '.join(reasons)}"


# MARK: - System

def sysctl(name):
    result = subprocess.run(["sysctl", "-n", name], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def memory_pressure():
    value = sysctl("kern.memorystatus_vm_pressure_level")
    return int(value) if value.isdecimal() else None


def swap_used_mb(text=None):
    """`used` from `vm.swapusage`: `total = 2048.00M  used = 1081.25M  free = 966.75M  (encrypted)`."""
    words = (sysctl("vm.swapusage") if text is None else text).split()
    try:
        value = words[words.index("used") + 2]
    except (ValueError, IndexError):
        return None
    units = {"K": 1 / 1024, "M": 1, "G": 1024}
    try:
        return float(value[:-1]) * units[value[-1]] if value[-1] in units else float(value) / 2**20
    except ValueError:
        return None


def slow(values):
    return sum(1 for value in values if value > SLOW_MS)


def slow_slots(answers, interval=PROBE_INTERVAL):
    """Slow main-thread answers, each counted once more for every probe interval it held: one
    6-second answer is a sustained stall that kept 30 probes from being sent, not one hitch."""
    return sum(1 + int(value // (interval * 1000)) for value in answers if value > SLOW_MS)


def switch_targets(tab_ids, count, rng, current=None):
    """`count` tabs to switch to, never the one selected just before, `current` for the first:
    selecting the selected tab isn't a switch."""
    targets = []
    for _ in range(count):
        current = rng.choice([tab_id for tab_id in tab_ids if tab_id != current])
        targets.append(current)
    return targets


def milliseconds(values):
    if not values:
        return None
    ordered = sorted(values)
    return {"count": len(values), "median": statistics.median(ordered), "worst": ordered[-1],
            "p90": ordered[min(len(ordered) - 1, int(0.9 * len(ordered)))]}


# MARK: - Headless Arx

class Ladder:
    """One ladder's headless Arx on its own profile, measured step by step."""

    switches = True  # whether a step times tab switches
    settle = SETTLE

    def __init__(self, app, storage, server, options, log):
        self.app, self.storage, self.server, self.options, self.log_path = app, storage, server, options, log
        self.profile = storage / "headless"
        self.run, self.client, self.log_file = None, None, None
        self.tab_ids = []
        self.selected = None  # the tab the last switch selected
        self.mutations = 0  # MCP mutations this app session: opens, closes, switches
        self.swap_start = None

    def say(self, message):
        print(f"[load ladder: {type(self).__name__.lower()}] {message}", flush=True)

    def launch(self, timeout=600):
        from .headless_smoke import Client, Run
        self.profile.mkdir(parents=True, exist_ok=True)
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self.log_file = self.log_path.open("a")
        begun = time.monotonic()
        self.run = Run(self.app, self.log_file, "--profile", str(self.profile), "--allow", "read,manage",
                       "--viewport", "1440x900", "--timeout", "86400")
        ready = self.run.wait_for("ready", timeout=timeout)
        self.client = Client(Path(ready["configuration"]))
        return time.monotonic() - begun

    def stop(self):
        if self.client:
            try:
                self.client.close()
            except Exception:
                pass
            self.client = None
        if self.run and self.run.process.poll() is None:
            os.kill(self.run.process.pid, signal.SIGTERM)
            self.run.finish(timeout=120)
        self.run = None
        if self.log_file:
            self.log_file.close()
            self.log_file = None

    def warm_up(self, keep=False):
        """Runs the new profile with one tab for `--warmup` seconds, then closes the tab unless `keep`."""
        tab_id, _ = benchmark.open_tab(self.client, self.server.tab_url(1, f"warmup-{type(self).__name__.lower()}"))
        self.mutations += 1
        if self.options.warmup:
            self.say(f"warm-up ({self.options.warmup:.0f} s)")
            time.sleep(self.options.warmup)
        if not keep:
            benchmark.close_tab(self.client, tab_id)
            self.mutations += 1

    @property
    def pid(self):
        return self.run.process.pid

    def measure(self, step):
        """The quiet window, the main-thread probes, the switches and the Mac's memory, into `step`."""
        time.sleep(self.settle)
        before, begun = process_metrics.sample_tree(self.pid), time.monotonic()
        time.sleep(self.options.idle)
        after = process_metrics.sample_tree(self.pid)
        idle = process_metrics.delta(before, after, time.monotonic() - begun)
        probes, probe_errors = self.probe(self.options.probe)
        switches = self.switch(self.options.switches) if self.switches else None
        swap = swap_used_mb()
        step.update(
            idle_cpu_percent=idle["cpu_percent"], idle_wakeups_per_second=idle["wakeups_per_second"],
            footprint_mb=after.footprint / 2**20, renderers=after.count("renderer"),
            processes=len(after.processes), by_role=process_metrics.by_role(before, after, self.options.idle),
            probe_ms=milliseconds(probes), slow_probes=slow_slots(probes), probe_errors=probe_errors,
            switch_ms=milliseconds(switches or []), slow_switches=None if switches is None else slow(switches),
            memory_pressure=memory_pressure(), swap_used_mb=swap,
            swap_growth_mb=None if swap is None or self.swap_start is None else max(0.0, swap - self.swap_start),
            load_average=os.getloadavg()[0],
        )
        self.say(f"{step['tabs']} tabs: {step['footprint_mb']:.0f} MB, idle CPU {step['idle_cpu_percent']:.1f}%, "
                 f"{step['idle_wakeups_per_second']:.0f} wakeups/s, worst answer "
                 f"{(step['probe_ms'] or {}).get('worst', 0):.0f} ms, worst switch {(step['switch_ms'] or {}).get('worst', 0):.0f} ms")
        return step

    def probe(self, seconds):
        """Milliseconds Arx took to answer a one-item inventory, every PROBE_INTERVAL for `seconds`,
        and how many requests it answered with an error (`busy`, say), which aren't timed: a fast
        refusal isn't an answer."""
        answers, errors, deadline = [], 0, time.monotonic() + seconds
        while time.monotonic() < deadline:
            begun = time.monotonic()
            result, reply = self.client.call("browser_inventory", {"limit": 1})
            elapsed = (time.monotonic() - begun) * 1000
            if result.get("isError") or "items" not in (reply or {}):
                errors += 1
            else:
                answers.append(elapsed)
            time.sleep(max(0.0, PROBE_INTERVAL - (time.monotonic() - begun)))
        if not answers:
            raise ValueError(f"Arx answered none of {errors} inventory requests")
        return answers, errors

    def switch(self, count):
        """`selectTab` round trips to tabs this ladder opened, picked at random, the same ones each
        run. Only those: `selectTab` refuses a tab with no page (`notLoaded`)."""
        if len(self.tab_ids) < 2:
            return []
        receipts = []
        for tab_id in switch_targets(self.tab_ids, count, random.Random(1027 + len(self.tab_ids)), self.selected):
            item = next((entry for entry in benchmark.inventory(self.client) if entry["id"] == tab_id), None)
            if item is None:
                raise ValueError(f"tab {tab_id} is gone from the inventory")
            begun = time.monotonic()
            result, reply = self.client.call("browser_command", {
                "operationID": str(uuid.uuid4()), "action": "selectTab", "targetID": tab_id,
                "expectedRevision": item["revision"],
            })
            receipts.append((time.monotonic() - begun) * 1000)
            self.mutations += 1
            if result.get("isError") or (reply or {}).get("kind") == "error":
                raise ValueError("selectTab failed: " + json.dumps(reply))
            self.selected = tab_id
            time.sleep(0.3)
        return receipts


class Awake(Ladder):
    """Tabs opened through MCP and kept loaded, one more batch at each step."""

    def start(self):
        self.opened = 0
        self.launch()
        self.warm_up()
        self.swap_start = swap_used_mb()

    def step(self, count):
        needed = count - self.opened + (self.options.switches if count > 1 else 0)
        if self.mutations + needed > MUTATION_BUDGET:
            raise Unmeasurable(f"{self.mutations} of the {MUTATION_BUDGET} MCP mutations Arx allows a client "
                               f"are used, and this step needs {needed} more")
        begun = time.monotonic()
        while self.opened < count:
            self.opened += 1
            tab_id, _ = benchmark.open_tab(self.client, self.server.tab_url(self.opened, "awake"))
            self.mutations += 1
            self.tab_ids.append(tab_id)
        identifiers = [self.server.tab_id(index, "awake") for index in range(1, count + 1)]
        loaded = self.server.beacons.wait_all("loaded", identifiers, 30 + count)
        step = {"tabs": count, "loaded": loaded, "pages_not_loaded": count - loaded,
                "open_and_load_s": time.monotonic() - begun}
        return self.measure(step)


class Unloaded(Ladder):
    """Tabs restored into the workspace of a stopped Arx, which starts again with them.

    Its steps time no switches: `selectTab` refuses a tab with no page yet (`notLoaded`), and a
    restored tab has none until a person selects it, so this ladder measures what the restored
    rows themselves cost.
    """

    switches = False

    @property
    def settle(self):
        return self.options.restore_settle

    def start(self):
        # A first run warms the profile up and leaves the workspace and space to add the tabs to.
        self.launch()
        self.warm_up(keep=True)
        self.stop()
        if not (self.profile / "arx-workspace.json").is_file():
            raise ValueError("headless Arx left no workspace to restore tabs into")
        self.swap_start = swap_used_mb()

    def step(self, count):
        workspace = self.profile / "arx-workspace.json"
        workspace.write_text(json.dumps(with_tabs(json.loads(workspace.read_text()), [
            {"title": f"Load ladder {index}", "url": self.server.tab_url(index, f"unloaded{count}")}
            for index in range(1, count + 1)
        ])))
        launch_s = self.launch()
        identifiers = [self.server.tab_id(index, f"unloaded{count}") for index in range(1, count + 1)]
        # Restored tabs aren't loaded until selected; the ones that loaded, the selected one among
        # them, are counted.
        time.sleep(2)
        step = {"tabs": count, "launch_to_ready_s": launch_s,
                "loaded_at_restore": self.server.beacons.wait_all("loaded", identifiers, 0)}
        try:
            return self.measure(step)
        finally:
            self.stop()


def with_tabs(workspace, restorations):
    """`workspace` with its first space's unpinned tabs replaced by tabs restoring `restorations`.

    Every other tab, pinned ones and Favorites included, is left as it was. A selection that was
    one of the replaced tabs moves to the first restored one, as a relaunch has one selected tab:
    validation refuses a selection of a tab that isn't there.
    """
    organization = workspace["organization"]
    space = organization["spaces"][0]
    previous = set(space.get("unpinnedTabs", []))
    organization["tabs"] = [tab for tab in organization["tabs"] if tab["id"] not in previous]
    space["unpinnedTabs"] = []
    for restoration in restorations:
        identifier = str(uuid.uuid4()).upper()
        organization["tabs"].append({"id": identifier, "profileID": space["profileID"], "restoration": restoration})
        space["unpinnedTabs"].append(identifier)
    if space.get("selectedTabID") in previous:
        if space["unpinnedTabs"]:
            space["selectedTabID"] = space["unpinnedTabs"][0]
        else:
            space.pop("selectedTabID")
    return workspace


# MARK: - Report and baseline

def write(output, results):
    (output / "results.json").write_text(json.dumps(results, indent=2, default=str))
    (output / "results.md").write_text(report(results))


def report(results):
    machine = results.get("machine", {})
    lines = ["# Load ladder", ""]
    if results.get("quick"):
        lines += ["**Quick run (`--quick`): a check that the ladders run. Its numbers are not a baseline.**", ""]
    lines += [
        f"{machine.get('model', '?')}, {machine.get('chip', '?')}, {machine.get('memory', '?')}, "
        f"macOS {machine.get('macos', '?')}, on {machine.get('power', '?')} power; Arx {results.get('version', '?')} "
        f"at {machine.get('commit', '?')}; started {results.get('started', '?')}, "
        f"load average {fixed((machine.get('load_average') or [None])[0], 1)}.",
        "",
        "Limits: " + "; ".join(f"`{key}` {value}" for key, value in results.get("limits", LIMITS).items())
        + f"; slow means over {results.get('slow_ms', SLOW_MS)} ms.",
        "",
    ]
    for name, ladder in results.get("ladders", {}).items():
        lines += [f"## {name.capitalize()} tabs", "", f"**{summary_line(ladder)}**", "", *table(name, ladder), ""]
    return "\n".join(lines)


def table(name, ladder):
    first = "Loaded" if name == "awake" else "Loaded at restore"
    timing = "Open and load" if name == "awake" else "Launch to ready"
    header = ["Tabs", first, timing, "Idle CPU", "Wakeups/s", "Memory", "Renderers",
              "Slow answers (worst)", "Slow switches (worst)", "Pressure", "Swap growth", "Broke"]
    rows = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    for step in ladder.get("steps", []):
        loaded = step.get("loaded", step.get("loaded_at_restore"))
        seconds = step.get("open_and_load_s", step.get("launch_to_ready_s"))
        rows.append("| " + " | ".join([
            str(step["tabs"]), str(loaded), f"{fixed(seconds, 1)} s", f"{fixed(step.get('idle_cpu_percent'), 1)}%",
            fixed(step.get("idle_wakeups_per_second"), 0), f"{fixed(step.get('footprint_mb'), 0)} MB",
            str(step.get("renderers", "–")), worst(step, "slow_probes", "probe_ms"),
            worst(step, "slow_switches", "switch_ms"), str(step.get("memory_pressure", "–")),
            f"{fixed(step.get('swap_growth_mb'), 0)} MB", "; ".join(step.get("broken", [])) or "–",
        ]) + " |")
    return rows


def worst(step, count, timings):
    values = step.get(timings) or {}
    return f"{step.get(count, '–')} ({fixed(values.get('worst'), 0)} ms)" if values else "–"


def fixed(value, places):
    return "–" if value is None else f"{value:.{places}f}"


def record(results, directory=BASELINES):
    """Writes the ceilings to `load/<model>.json`, a folder of its own: the perf gate reads every
    `<model>.json` beside it as one of its baselines."""
    machine = results["machine"]
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{machine.get('model', 'unknown')}.json"
    baseline = {key: machine.get(key) for key in ("model", "chip", "memory", "macos")}
    baseline.update(
        release=results.get("version"), recorded=results.get("started"), limits=results.get("limits"),
        slow_ms=results.get("slow_ms"),
        ladders={name: {"ceiling": ladder["ceiling"], "broke_at": ladder["broke_at"], "broken": ladder["broken"],
                        "complete": ladder["complete"], "steps": [step["tabs"] for step in ladder["steps"]],
                        "unmeasurable": ladder.get("unmeasurable"), "error": ladder["error"]}
                 for name, ladder in results["ladders"].items()},
    )
    path.write_text(json.dumps(baseline, indent=2) + "\n")
    return path
