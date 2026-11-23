"""`make sidebar-scroll`: frame pacing while the sidebar scrolls in Arx's real window (DEV-1238).

For each workspace size (`--tabs`, 30, 150 and 400 by default) Arx starts windowed on fresh
throwaway storage under `~/Library/Caches/arx-benchmark/`, its one space holding that many
restored tabs (loopback fixture pages from `core/benchmark_fixture.py`, not loaded until
selected). The driver (`sidebar_scroll_driver.swift`, built here with `swiftc`) then scrolls
the sidebar from outside the app, so any commit's build can be measured without a hook in it:

  - phased trackpad scroll events, one a frame on the screen's display link, down the list and
    back up in legs, each leg a gesture with a short glide after the fingers lift;
  - with the pointer resting over the sidebar (`inside`: rows pass under it, their hover
    included) and over the page (`outside`), the events going to the sidebar either way;
  - a ScreenCaptureKit stream of the sidebar notes when each new frame of it reaches the
    screen: gaps over 1.5 refresh intervals are dropped frames;
  - Arx's main-thread and whole-process CPU over the run, from `proc_pidinfo`.

Each tab count and pointer position runs `--runs` times; the table shows the medians, and
`results.json` keeps every run. It needs the window in front and nobody at the Mac, and the
app running the command needs Accessibility and Screen Recording permission (`preflight`).

Options (`make sidebar-scroll ARGS='…'`):
  --app PATH            measure this Arx.app instead of building one (signed, Release)
  --ref REF             build REF (a commit, branch or tag) in a detached worktree under
                        build/sidebar-scroll/ and measure that, with this checkout's harness
  --configuration C     build configuration when building (default Release)
  --tabs 30,150,400     workspace sizes
  --pointer P           inside, outside or both (default inside,outside)
  --runs N              runs per size and pointer position (default 3)
  --seconds S           scrolling per run (default 6)
  --speed PTS           points a second the fingers move (default 840: 14 a frame at 60 Hz)
  --leg PTS             points each leg scrolls before turning back (default: the driver's,
                        from the tab count and the window's height, so the list never reaches
                        its end)
  --settle S            seconds after each launch before the first run (default 30)
  --warmup S            seconds the new profile's first launch runs before any count (default 60)
  --output DIR          where results go (default build/sidebar-scroll/<UTC time>)
  --keep                keep the throwaway profile
  --compare A B         print two results.json files side by side and exit
  --self-test           check the driver and this script without the screen, and exit
"""

import argparse
import hashlib
import json
import os
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

from .core.paths import ROOT

DRIVER_SOURCE = Path(__file__).with_name("sidebar_scroll_driver.swift")
BUILD = ROOT / "build/sidebar-scroll"
PROFILES = Path.home() / "Library/Caches/arx-benchmark"  # Not /private/tmp: Arx canonicalizes it to /tmp.
TABS = (30, 150, 400)
POINTERS = ("inside", "outside")
# The table's columns: (heading, key in a run, decimals).
COLUMNS = (
    ("dropped", "dropped", 0),
    ("missed", "missed_intervals", 0),
    ("worst ms", "worst_gap_ms", 1),
    ("p95 ms", "p95_gap_ms", 1),
    ("main CPU %", "main_cpu_percent", 1),
    ("main ms/frame", "main_cpu_ms_per_frame", 2),
    ("process ms", "process_cpu_ms", 0),
)


def main(arguments=()):
    options = parse(arguments)
    if options.self_test:
        return self_test()
    if options.compare:
        print(compare(*(json.loads(Path(path).read_text()) for path in options.compare)))
        return 0
    driver = build_driver()
    missing = preflight(driver)
    if missing:
        print("The app running this command needs " + " and ".join(missing)
              + " in System Settings › Privacy & Security. Grant them, then run it again.", file=sys.stderr)
        return 3
    app = Path(options.app).resolve() if options.app else build_app(options)
    output = Path(options.output) if options.output else BUILD / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output.mkdir(parents=True, exist_ok=True)
    from . import benchmark
    results = {
        "date": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "machine": benchmark.machine(),
        "app": {"path": str(app), "version": benchmark.bundle_version(app), "commit": app_commit(app, options),
                "engine": benchmark.engine_version(app)},
        "options": {"tabs": options.tabs, "pointers": options.pointer, "runs": options.runs,
                    "seconds": options.seconds, "speed": options.speed, "leg": options.leg},
        "counts": [],
    }
    try:
        measure(app, driver, options, output, results)
    finally:
        write(output, results)
    print(table(results))
    print(f"\nResults: {output / 'results.json'}")
    return 0 if complete(results, options) else 1


def parse(arguments):
    parser = argparse.ArgumentParser(prog="make sidebar-scroll", description=__doc__.split("\n")[0])
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--app")
    source.add_argument("--ref")
    parser.add_argument("--configuration", default="Release")
    parser.add_argument("--tabs", default=",".join(map(str, TABS)))
    parser.add_argument("--pointer", default=",".join(POINTERS))
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--seconds", type=float, default=6.0)
    parser.add_argument("--speed", type=float, default=840.0)
    parser.add_argument("--leg", type=float)
    parser.add_argument("--settle", type=float, default=30.0)
    parser.add_argument("--warmup", type=float, default=60.0)
    parser.add_argument("--output")
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--compare", nargs=2, metavar=("A", "B"))
    parser.add_argument("--self-test", action="store_true")
    options = parser.parse_args(list(arguments))
    try:
        options.tabs = [int(value) for value in options.tabs.split(",") if value.strip()]
    except ValueError:
        parser.error("--tabs is a comma-separated list of tab counts")
    if not options.tabs or any(count < 1 for count in options.tabs):
        parser.error("--tabs needs at least one positive tab count")
    options.pointer = [value.strip() for value in options.pointer.split(",") if value.strip()]
    if not options.pointer or any(value not in POINTERS for value in options.pointer):
        parser.error("--pointer is inside, outside or both")
    if options.runs < 1:
        parser.error("--runs is at least 1")
    if not 0.5 < options.seconds <= 120:
        parser.error("--seconds is in (0.5, 120]")
    if options.speed <= 0 or (options.leg is not None and options.leg <= 0):
        parser.error("--speed and --leg are positive")
    return options


# MARK: - Driver

def build_driver(source=DRIVER_SOURCE, directory=BUILD):
    """The driver, compiled once per version of its source."""
    digest = hashlib.sha256(source.read_bytes()).hexdigest()[:12]
    binary = directory / f"driver-{digest}"
    if not binary.is_file():
        directory.mkdir(parents=True, exist_ok=True)
        partial = binary.with_suffix(".partial")
        subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "5", "-o", str(partial), str(source)], check=True)
        partial.replace(binary)
    return binary


def preflight(driver):
    """The permissions the driver lacks, by name."""
    result = subprocess.run([str(driver), "preflight"], capture_output=True, text=True)
    try:
        return json.loads(result.stdout).get("missing", [])
    except json.JSONDecodeError:
        return [f"a working driver ({result.stderr.strip() or result.returncode})"]


def drive(driver, pid, pointer, options, tabs, output):
    """One run of the driver against `pid`; its JSON, or {"error": …}."""
    command = [str(driver), "run", "--pid", str(pid), "--pointer", pointer, "--seconds", str(options.seconds),
               "--speed", str(options.speed), "--output", str(output)]
    command += ["--leg", str(options.leg)] if options.leg else ["--rows", str(tabs)]
    # The driver finishes a pair of legs (1,500 points each at most), which can outlast --seconds.
    pair = 2 * 1500 / options.speed
    result = subprocess.run(command, capture_output=True, text=True, timeout=(options.seconds + pair) * 2 + 90)
    try:
        answer = json.loads(output.read_text())
    except (OSError, json.JSONDecodeError):
        answer = {"error": result.stderr.strip() or f"the driver exited with {result.returncode} and wrote nothing"}
    return answer


# MARK: - The app

def build_app(options):
    from . import benchmark
    if not options.ref:
        return benchmark.build(options.configuration)
    return build_ref(options.ref, options.configuration)


def build_ref(ref, configuration):
    """Builds `ref` in a detached worktree of its own, with its own build scripts, sharing this
    checkout's engine as every worktree does, and returns its app."""
    commit = subprocess.run(["git", "rev-parse", "--verify", f"{ref}^{{commit}}"], cwd=ROOT,
                            capture_output=True, text=True, check=True).stdout.strip()
    worktree = BUILD / f"ref-{commit[:10]}"
    if not worktree.is_dir():
        subprocess.run(["git", "worktree", "add", "--detach", str(worktree), commit], cwd=ROOT, check=True)
        subprocess.run(["git", "-c", "protocol.file.allow=always", "submodule", "update", "--init"],
                       cwd=worktree, check=True)
    engine = worktree / ".build/engine"
    if not engine.exists():
        engine.parent.mkdir(parents=True, exist_ok=True)
        engine.symlink_to((ROOT / ".build/engine").resolve())
    # The signing team comes from the local, untracked .env, which a new worktree lacks.
    environment_file = worktree / ".env"
    if (ROOT / ".env").is_file() and not environment_file.exists():
        environment_file.symlink_to(ROOT / ".env")
    subprocess.run(["mise", "trust"], cwd=worktree, capture_output=True)
    print(f"[sidebar scroll] building {ref} ({commit[:10]}) in {worktree}", flush=True)
    script = ("import sys; from Scripts import benchmark; "
              f"print('APP=' + str(benchmark.build({configuration!r})))")
    result = subprocess.run(["mise", "exec", "--", "python3", "-c", script], cwd=worktree,
                            stdout=subprocess.PIPE, text=True)
    sys.stdout.write(result.stdout)
    lines = [line for line in result.stdout.splitlines() if line.startswith("APP=")]
    if result.returncode != 0 or not lines:
        raise SystemExit(f"building {ref} failed; see its build log under {worktree / 'build/logs'}")
    return Path(lines[-1][4:]).resolve()


def app_commit(app, options):
    if options.ref:
        return subprocess.run(["git", "rev-parse", "--short", options.ref], cwd=ROOT,
                              capture_output=True, text=True).stdout.strip()
    if options.app:
        return None  # an app given by path: its commit is whatever built it
    return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()


class Arx:
    """Windowed Arx on throwaway storage, started from its executable as `make benchmark` does,
    and quit by its own PID, never by bundle ID."""

    def __init__(self, app, profile, server):
        from . import benchmark
        self.app, self.profile, self.server = app, profile, server
        self.environment = dict(os.environ, **benchmark.ARX_ENVIRONMENT, ARX_ENGINE_PROFILE=str(profile))
        self.process = None

    def launch(self, url):
        self.profile.mkdir(parents=True, exist_ok=True)
        self.process = subprocess.Popen([str(self.app / "Contents/MacOS/Arx")],
                                        env=dict(self.environment, ARX_ENGINE_URL=url),
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return self.process.pid

    def quit(self, timeout=60):
        if not self.process or self.process.poll() is not None:
            return
        executable = str(self.app / "Contents/MacOS/Arx")
        script = (
            "ObjC.import('AppKit');"
            f"const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier({self.process.pid});"
            f"(!app.isNil() && app.executableURL.path.js === {json.dumps(executable)}) ? (app.terminate, 'ok') : 'none';"
        )
        subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, timeout=20)
        try:
            self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.kill(self.process.pid, signal.SIGKILL)
            self.process.wait(timeout=10)


def measure(app, driver, options, output, results):
    from . import load_ladder
    from .core import benchmark_fixture
    PROFILES.mkdir(parents=True, exist_ok=True)
    storage = Path(tempfile.mkdtemp(prefix="sidebar-scroll-", dir=PROFILES))
    profile = storage / "windowed"
    try:
        with benchmark_fixture.Server() as server:
            arx = Arx(app, profile, server)
            say(f"first launch on a new profile, {options.warmup:.0f} s warm-up")
            begun = time.monotonic()
            arx.launch(server.start_url("start"))
            try:
                if server.beacons.wait_any_since("ready", begun, 120) is None:
                    raise SystemExit("Arx's first launch never showed its start page")
                time.sleep(options.warmup)
            finally:
                arx.quit()
            workspace = profile / "arx-workspace.json"
            if not workspace.is_file():
                raise SystemExit("Arx left no workspace to put tabs in")
            pristine = json.loads(workspace.read_text())
            for count in options.tabs:
                entry = {"tabs": count, "runs": {pointer: [] for pointer in options.pointer}}
                results["counts"].append(entry)
                workspace.write_text(json.dumps(load_ladder.with_tabs(json.loads(json.dumps(pristine)), [
                    {"title": f"Sidebar scroll {index}", "url": server.tab_url(index, f"scroll{count}")}
                    for index in range(1, count + 1)
                ])))
                say(f"{count} tabs: launch, {options.settle:.0f} s settle")
                begun = time.monotonic()
                pid = arx.launch(server.start_url(f"scroll{count}"))
                try:
                    # The selected tab, the first restored one, loads; the rest wait to be selected.
                    entry["first_page_loaded"] = server.beacons.wait("loaded", server.tab_id(1, f"scroll{count}"), 120) is not None
                    entry["launch_s"] = round(time.monotonic() - begun, 1)
                    time.sleep(options.settle)
                    for run in range(1, options.runs + 1):
                        # Alternating which position goes first, so neither always follows the other.
                        order = options.pointer if run % 2 else list(reversed(options.pointer))
                        for pointer in order:
                            answer = drive(driver, pid, pointer, options, count,
                                           output / f"run-{count}-{pointer}-{run}.json")
                            entry["runs"][pointer].append(answer)
                            say(f"{count} tabs, pointer {pointer}, run {run}: " + describe(answer))
                            if answer.get("error"):
                                entry["error"] = answer["error"]
                                break
                            time.sleep(1)
                        if entry.get("error"):
                            break
                finally:
                    arx.quit()
                entry["median"] = {pointer: medians(runs) for pointer, runs in entry["runs"].items()}
                if entry.get("error"):
                    break
    finally:
        if not options.keep:
            shutil.rmtree(storage, ignore_errors=True)


def complete(results, options):
    """Whether every size asked for was measured without an error and has a valid run at each
    pointer position."""
    measured = {count["tabs"]: count for count in results["counts"]}
    for tabs in options.tabs:
        count = measured.get(tabs)
        if not count or count.get("error"):
            return False
        if any(not (count.get("median") or {}).get(pointer, {}).get("runs") for pointer in options.pointer):
            return False
    return True


def say(message):
    print(f"[sidebar scroll] {message}", flush=True)


def describe(answer):
    if answer.get("error"):
        return "error: " + answer["error"]
    return (f"{answer.get('frames', 0)} frames, {answer.get('dropped', 0)} dropped, worst "
            f"{answer.get('worst_gap_ms', 0):.1f} ms, main CPU {answer.get('main_cpu_percent', 0):.0f}%"
            + ("" if answer.get("arx_frontmost_at_end", True) else " (Arx lost the front: not valid)"))


# MARK: - Report

def medians(runs):
    """Each column's median over the runs that finished; a run that lost the front or whose own
    clock stalled (the harness was late, not Arx) is left out and counted."""
    valid = [run for run in runs if not run.get("error") and valid_run(run)]
    summary = {"runs": len(valid), "invalid": len(runs) - len(valid)}
    for _, key, _ in COLUMNS + (("frames", "frames", 0),):
        values = [run[key] for run in valid if isinstance(run.get(key), (int, float))]
        summary[key] = statistics.median(values) if values else None
    return summary


def valid_run(run):
    """Arx stayed in front, and the driver's own display link kept time: while it stalls no
    events go out, so the list stops and its missing frames aren't Arx's. A stall of up to two
    and a half intervals, and a missed interval in a hundred, are allowed."""
    refresh = run.get("refresh_ms") or 0
    worst = run.get("harness_worst_gap_ms", 0)
    missed = run.get("harness_missed_intervals", run.get("harness_dropped", 0))
    return (run.get("arx_frontmost_at_end", True)
            and missed <= max(2, run.get("scroll_frames", 0) // 100)
            and (not refresh or worst <= refresh * 2.5))


def table(results):
    """One row per tab count and pointer position: the medians."""
    heading = ["tabs", "pointer", "runs"] + [name for name, _, _ in COLUMNS]
    rows = []
    for count in results["counts"]:
        for pointer, summary in (count.get("median") or {}).items():
            row = [str(count["tabs"]), pointer, f"{summary['runs']}" + (f" (+{summary['invalid']} invalid)" if summary["invalid"] else "")]
            row += [cell(summary.get(key), places) for _, key, places in COLUMNS]
            rows.append(row)
        if count.get("error"):
            rows.append([str(count["tabs"]), "error", count["error"][:60]] + [""] * len(COLUMNS))
    app = results.get("app", {})
    title = f"Sidebar scroll, {app.get('commit') or app.get('path', '?')}"
    refresh = next((run["refresh_ms"] for count in results["counts"] for runs in count["runs"].values()
                    for run in runs if run.get("refresh_ms")), None)
    if refresh:
        title += f", {1000 / refresh:.0f} Hz"
    return title + "\n" + render([heading] + rows)


def cell(value, places):
    if value is None:
        return "-"
    return f"{value:.{places}f}"


def render(rows):
    widths = [max(len(row[index]) for row in rows) for index in range(len(rows[0]))]
    lines = ["  ".join(text.ljust(width) if index < 3 else text.rjust(width)
                       for index, (text, width) in enumerate(zip(row, widths))) for row in rows]
    lines.insert(1, "  ".join("-" * width for width in widths))
    return "\n".join(lines)


def compare(before, after):
    """Two results side by side: each median as before → after."""
    heading = ["tabs", "pointer"] + [name for name, _, _ in COLUMNS]
    rows = []
    previous = {count["tabs"]: count.get("median") or {} for count in before["counts"]}
    for count in after["counts"]:
        for pointer, summary in (count.get("median") or {}).items():
            old = previous.get(count["tabs"], {}).get(pointer, {})
            rows.append([str(count["tabs"]), pointer] + [
                f"{cell(old.get(key), places)} → {cell(summary.get(key), places)}" for _, key, places in COLUMNS])
    names = [results.get("app", {}).get("commit") or results.get("app", {}).get("path", "?") for results in (before, after)]
    return f"Sidebar scroll, {names[0]} → {names[1]}\n" + render([heading] + rows)


def write(output, results):
    output.mkdir(parents=True, exist_ok=True)
    (output / "results.json").write_text(json.dumps(results, indent=2))
    if results["counts"]:
        (output / "results.txt").write_text(table(results) + "\n")


# MARK: - Self-test

def self_test():
    """The driver's own checks (frame statistics, scroll script, CPU counters), then the unit
    tests of this script. Neither needs the screen or Arx."""
    driver = build_driver()
    checked = subprocess.run([str(driver), "self-test"])
    if checked.returncode != 0:
        return checked.returncode
    return subprocess.run([sys.executable, "-m", "unittest", "Scripts.tests.test_sidebar_scroll", "-v"], cwd=ROOT).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
