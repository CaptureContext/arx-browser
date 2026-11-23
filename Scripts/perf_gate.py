"""make perf-gate: compare a release with the previous one on this Mac, and fail on a regression (DEV-902).

The previous release's numbers are a baseline committed per Mac model, `perf-baselines/<model>.json`
(`sysctl hw.model`, such as `Mac16,10`). `make benchmark` measures the release for `--sessions`
sessions (default 2) of `--launches` warm launches each (default 6), and each metric's median over
the sessions is compared with the baseline. With `--previous`, both apps are measured instead, one
at a time and alternating. A metric regresses when it is worse by more than both its relative and
its absolute threshold in `perf-gate.json`; the absolute floor keeps noise on small numbers from
failing a release. Any regression fails the gate, unless `--override` gives a reason, which the
result records. A Mac model without a baseline needs `--override` too (its first release).
`--record` makes the release the model's new baseline once the gate passes; commit it with the release.

    make perf-gate ARGS='--current build/release/Arx.app --record'
    make perf-gate ARGS='--current build/release/Arx.app --previous path/to/Previous/Arx.app'
    make perf-gate ARGS='--compare previous/results.json current/results.json'
    make perf-gate ARGS='… --override "Memory grows with the new engine; DEV-123 brings it down"'

Results go to `build/benchmarks/gate-<UTC time>/gate.json` and `gate.md`.
"""

import argparse
import contextlib
import io
import json
import plistlib
import re
import statistics
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .core.paths import ROOT

THRESHOLDS = Path(__file__).with_name("perf-gate.json")
BASELINES = Path(__file__).with_name("perf-baselines")
MODEL = re.compile(r"^[A-Za-z]+[0-9]+,[0-9]+$")
OUTPUT = ROOT / "build/benchmarks"
GATE_TABS = 20
# The benchmark's options for a gate run: Arx only and the 20-tab step.
BENCHMARK_OPTIONS = ("--skip-chrome", "--tabs", str(GATE_TABS), "--switches", "20")
# Options newer benchmarks take; passed only when the benchmark accepts them. A short freeze
# wait keeps the windowed step's tab switch timing without its five-minute wait.
OPTIONAL_BENCHMARK_OPTIONS = (("--freeze-wait", "1"),)
MINIMUM_OVERRIDE = 10


@dataclass(frozen=True)
class Metric:
    key: str
    title: str
    unit: str
    paths: tuple  # tried in order; the first one present is used


METRICS = (
    Metric("cold_launch_s", "First launch → first paint", "s", (
        ("launch_marks", "first", "FirstPagePainted"), ("first_launch_s",),
    )),
    Metric("warm_launch_s", "Warm launch → first paint (median)", "s", (
        ("launch_marks", "warm", "FirstPagePainted", "median"), ("warm_launch_s", "median"),
    )),
    Metric("tab_switch_ms", f"Tab switch → page shown, {GATE_TABS} tabs (median)", "ms", (
        ("native", "steps", GATE_TABS, "switch", "shown_ms", "median"), ("tabs", "switch", "visible_ms", "median"),
    )),
    Metric("memory_1_tab_mb", "Memory, 1 tab", "MB", (("idle_one_tab", "footprint_mb"),)),
    Metric("memory_20_tabs_mb", f"Memory, {GATE_TABS} tabs", "MB", (("tabs", "steps", GATE_TABS, "footprint_mb"),)),
    Metric("idle_cpu_percent", "Idle CPU, 1 tab (% of one core)", "%", (("idle_one_tab", "cpu_percent"),)),
)


# MARK: - Reading results


def find(value, path):
    """Whatever is at `path` in the benchmark's results. Tab-count steps are a list keyed by `tabs`."""
    for key in path:
        if isinstance(value, list) and isinstance(key, int):
            value = next((step for step in value if isinstance(step, dict) and step.get("tabs") == key), None)
        elif isinstance(value, dict):
            value = value.get(key, value.get(str(key)))
        else:
            return None
        if value is None:
            return None
    return value


def complete(arx, path, expected_switches):
    """Whether the workload behind a value finished: every page of a tab step loaded, and every
    tab switch was seen. A step that timed out would otherwise look faster or smaller."""
    if path[:2] == ("tabs", "steps") or path[:2] == ("native", "steps"):
        step = find(arx, path[:3])
        if isinstance(step, dict) and "loaded" in step and step["loaded"] != step.get("tabs"):
            return False
    if "switch" in path:
        switch = find(arx, path[:path.index("switch") + 1]) or {}
        timings = switch.get(path[path.index("switch") + 1]) or {}
        seen = switch.get("visible_reported", timings.get("n")) if "visible_ms" in path else timings.get("n")
        if expected_switches and seen != expected_switches:
            return False
    return True


def lookup(value, path):
    """A number inside the benchmark's results. Tab-count steps are a list keyed by `tabs`."""
    for key in path:
        if isinstance(value, list) and isinstance(key, int):
            value = next((step for step in value if isinstance(step, dict) and step.get("tabs") == key), None)
        elif isinstance(value, dict):
            value = value.get(key, value.get(str(key)))
        else:
            return None
        if value is None:
            return None
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def arx_results(results):
    """Arx's results. A run that failed partway, for either app, fails the gate: its missing
    numbers would otherwise pass as "not measured" or "no baseline". Run it again."""
    arx = (results.get("browsers") or {}).get("Arx") or {}
    if "error" in arx:
        raise ValueError(f"The benchmark failed for Arx: {arx['error']}")
    if not arx:
        raise ValueError("The benchmark has no results for Arx")
    return arx


def metric_values(results):
    """Each metric's value in one benchmark run, or None when it wasn't measured, or its
    workload didn't finish (pages that never loaded, tab switches never seen)."""
    arx = arx_results(results)
    switches = (results.get("options") or {}).get("switches")
    values = {}
    for metric in METRICS:
        values[metric.key] = None
        for path in metric.paths:
            value = lookup(arx, path)
            if value is None:
                continue
            values[metric.key] = value if complete(arx, path, switches) else None
            break
    return values


def combine(runs):
    """The median of each metric over the sessions, or None when any session missed it: a
    session whose step failed must not leave the gate deciding on the others alone."""
    combined = {}
    for metric in METRICS:
        found = [run.get(metric.key) for run in runs]
        combined[metric.key] = statistics.median(found) if found and None not in found else None
    return combined


# MARK: - Comparing


def thresholds(path=THRESHOLDS):
    values = json.loads(Path(path).read_text())
    missing = [metric.key for metric in METRICS if metric.key not in values]
    if missing:
        raise ValueError(f"{Path(path).name} has no threshold for {', '.join(missing)}")
    for key, limit in values.items():
        if not {"relative", "absolute"} <= set(limit):
            raise ValueError(f"{Path(path).name}: {key} needs a relative and an absolute threshold")
    return values


def compare(previous, current, limits):
    """One row per metric: both values, the change and whether it regressed."""
    rows = []
    for metric in METRICS:
        before, after, limit = previous.get(metric.key), current.get(metric.key), limits[metric.key]
        row = {"metric": metric.key, "title": metric.title, "unit": metric.unit,
               "previous": before, "current": after, "threshold": limit}
        if after is None:
            row["verdict"] = "not measured"
            row["regressed"] = True
        elif before is None:
            row["verdict"] = "no baseline"
            row["regressed"] = False
        else:
            change = after - before
            relative = change / before if before else (float("inf") if change > 0 else 0)
            row["change"] = change
            row["relative_change"] = relative
            row["regressed"] = change > limit["absolute"] and relative > limit["relative"]
            row["verdict"] = "regressed" if row["regressed"] else ("better" if change < 0 else "within threshold")
        rows.append(row)
    return rows


def verdict(rows, override=None):
    regressions = [row for row in rows if row["regressed"]]
    if not regressions:
        return {"passed": True, "regressions": []}
    names = [row["title"] for row in regressions]
    if override is None:
        return {"passed": False, "regressions": names}
    reason = override.strip()
    if len(reason) < MINIMUM_OVERRIDE:
        raise ValueError("--override needs a reason of at least a few words")
    return {"passed": True, "regressions": names, "overridden": reason}


# MARK: - Reporting


def formatted(value, unit):
    if value is None:
        return "–"
    if unit == "s":
        return f"{value:.2f} s"
    if unit == "ms":
        return f"{value:.0f} ms"
    if unit == "MB":
        return f"{value:.0f} MB"
    return f"{value:.1f} %"


def markdown(rows, outcome, sources):
    lines = [
        "# Performance gate",
        "",
        f"Previous: {sources['previous']}  ",
        f"Current: {sources['current']}",
    ]
    if sources.get("recorded"):
        lines.append(f"Recorded as the new baseline: {sources['recorded']}")
    lines += [
        "",
        "| Metric | Previous | Current | Change | Threshold | Verdict |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for row in rows:
        change = "–" if row.get("change") is None else (
            f"{'+' if row['change'] >= 0 else ''}{formatted(row['change'], row['unit'])} "
            f"({row['relative_change'] * 100:+.0f} %)"
        )
        limit = row["threshold"]
        threshold = f"+{limit['relative'] * 100:.0f} % and +{formatted(limit['absolute'], row['unit'])}"
        lines.append(
            f"| {row['title']} | {formatted(row['previous'], row['unit'])} | {formatted(row['current'], row['unit'])} "
            f"| {change} | {threshold} | {row['verdict']} |"
        )
    lines.append("")
    if outcome.get("skipped"):
        lines.append(f"Skipped, no previous release to compare with: {outcome['skipped']}")
    elif outcome.get("overridden"):
        lines.append(f"Regressed ({', '.join(outcome['regressions'])}), overridden: {outcome['overridden']}")
    elif outcome["passed"]:
        lines.append("Passed: nothing regressed past its threshold.")
    else:
        lines.append(f"Failed: {', '.join(outcome['regressions'])} regressed past the threshold.")
    return "\n".join(lines) + "\n"


def write(rows, outcome, sources, output=None):
    output = Path(output or OUTPUT / f"gate-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}")
    output.mkdir(parents=True, exist_ok=True)
    (output / "gate.json").write_text(json.dumps({"sources": sources, "rows": rows, **outcome}, indent=2) + "\n")
    (output / "gate.md").write_text(markdown(rows, outcome, sources))
    return output


# MARK: - Baselines


def sysctl(name):
    try:
        return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def this_mac():
    """The Mac model a baseline belongs to, and details people read in the file."""
    memory = sysctl("hw.memsize")
    try:
        system = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        system = None
    return {
        "model": sysctl("hw.model"),
        "chip": sysctl("machdep.cpu.brand_string"),
        "memory_gb": round(int(memory) / 2**30) if memory and memory.isdigit() else None,
        "macos": system,
    }


def baseline_path(model, directory=BASELINES):
    if not model or not MODEL.match(model):
        raise ValueError(f"Can't tell this Mac's model ({model!r}); pass --model, such as Mac16,10")
    return Path(directory) / f"{model}.json"


def read_baseline(path):
    """A committed baseline's metrics, or None when this Mac model has none yet."""
    path = Path(path)
    if not path.exists():
        return None
    baseline = json.loads(path.read_text())
    metrics = baseline.get("metrics")
    if not isinstance(metrics, dict) or not {metric.key for metric in METRICS} <= set(metrics):
        raise ValueError(f"{path.name} needs a value for every metric: {', '.join(metric.key for metric in METRICS)}")
    return baseline


def app_release(app):
    """`<version> (<build>)` of an Arx.app, or None for a results file."""
    plist = Path(app) / "Contents/Info.plist"
    if not plist.is_file():
        return None
    with plist.open("rb") as source:
        info = plistlib.load(source)
    return f"{info.get('CFBundleShortVersionString', '?')} ({info.get('CFBundleVersion', '?')})"


def baseline_record(metrics, mac, *, release, sessions, launches, note=None, now=None):
    """The file `--record` commits: the release's metrics and what they were measured on."""
    missing = [metric.key for metric in METRICS if metrics.get(metric.key) is None]
    if missing:
        raise ValueError(f"Not recorded: the release didn't measure {', '.join(missing)}")
    record = {
        **mac,
        "release": release,
        "recorded": (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sessions": sessions,
        "launches": launches,
        "metrics": {metric.key: metrics[metric.key] for metric in METRICS},
    }
    if note:
        record["note"] = note
    return record


def write_baseline(path, record):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record, indent=2) + "\n")
    return path


# MARK: - Measuring


def newest_results(after):
    """The results.json of the benchmark run that started after `after`."""
    runs = sorted(
        (path for path in OUTPUT.glob("*/results.json") if path.stat().st_mtime >= after),
        key=lambda path: path.stat().st_mtime,
    )
    if not runs:
        raise ValueError("The benchmark wrote no results")
    return runs[-1]


def benchmark_options(parse=None):
    """The gate's benchmark options, with each optional one the benchmark's parser accepts."""
    if parse is None:
        from . import benchmark
        parse = benchmark.parse
    options = list(BENCHMARK_OPTIONS)
    for option in OPTIONAL_BENCHMARK_OPTIONS:
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                parse([*BENCHMARK_OPTIONS, *option])
        except SystemExit:
            continue
        options += option
    return options


def measure(apps, sessions, launches, run_benchmark=None, options=None):
    """Benchmarks each app once per session, alternating which goes first, and returns the runs
    per app. One app at a time, so they never compete for the Mac."""
    if run_benchmark is None:
        from . import benchmark
        run_benchmark = benchmark.main
    options = benchmark_options() if options is None else options
    runs = {name: [] for name in apps}
    for session in range(sessions):
        order = list(apps.items()) if session % 2 == 0 else list(reversed(apps.items()))
        for name, app in order:
            started = datetime.now().timestamp()
            run_benchmark(["--app", str(app), "--launches", str(launches), *options])
            path = newest_results(started)
            runs[name].append({"path": str(path), **metric_values(json.loads(path.read_text()))})
    return runs


def parser():
    result = argparse.ArgumentParser(prog="make perf-gate", description=__doc__.splitlines()[0])
    result.add_argument("--current", type=Path, help="the release being made, an Arx.app")
    result.add_argument("--previous", type=Path,
                        help="the previous release's Arx.app, measured here instead of this Mac model's baseline")
    result.add_argument("--compare", nargs=2, type=Path, metavar=("PREVIOUS", "CURRENT"),
                        help="compare two benchmark results.json files instead of measuring")
    result.add_argument("--sessions", type=int, default=2, help="benchmark sessions per app (default 2)")
    result.add_argument("--launches", type=int, default=6, help="warm launches per session (default 6)")
    result.add_argument("--override", help="pass despite regressions; the reason is recorded")
    result.add_argument("--record", action="store_true",
                        help="once the gate passes, make the release this Mac model's baseline (commit it)")
    result.add_argument("--model", help="the Mac model whose baseline to use (default: this Mac's, sysctl hw.model)")
    result.add_argument("--baselines", type=Path, default=BASELINES, help=argparse.SUPPRESS)
    result.add_argument("--output", type=Path, help="where gate.json and gate.md go")
    return result


def main(arguments=(), mac=None):
    options = parser().parse_args(list(arguments))
    limits = thresholds()
    mac = dict(mac or this_mac())
    if options.model:
        mac["model"] = options.model
    release = None
    baseline = None
    if options.compare and options.record:
        raise ValueError("--record needs the release measured here (--current); results files can come from another Mac.")
    if options.compare:
        previous_path, current_path = options.compare
        previous = metric_values(json.loads(previous_path.read_text()))
        current = metric_values(json.loads(current_path.read_text()))
        sources = {"previous": str(previous_path), "current": str(current_path)}
    else:
        if not options.current:
            raise ValueError("Pass --current with the release's Arx.app, or --compare with two results.json files.")
        apps = {"current": options.current}
        if options.previous:
            apps = {"previous": options.previous, "current": options.current}
        else:
            path = baseline_path(mac["model"], options.baselines)
            baseline = read_baseline(path)
        for app in apps.values():
            if not (app / "Contents/MacOS/Arx").is_file():
                raise ValueError(f"No Arx app at {app}")
        if options.sessions < 1 or options.launches < 1:
            raise ValueError("--sessions and --launches need to be at least 1")
        if not options.previous and baseline is None and not (options.override or "").strip():
            raise ValueError(
                f"No baseline for this Mac model ({mac['model']}) in {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}. "
                "For its first release, pass --override with the reason and --record to make one."
            )
        release = app_release(options.current)
        runs = measure(apps, options.sessions, options.launches)
        current = combine(runs["current"])
        if options.previous:
            previous = combine(runs["previous"])
            sources = {"previous": str(options.previous), "current": str(options.current), "runs": runs}
        else:
            previous = baseline["metrics"] if baseline else {}
            label = f"{path.name}, {baseline.get('release') or 'unknown release'}" if baseline else f"none for {mac['model']}"
            sources = {"previous": label, "current": f"{options.current} ({release})", "runs": runs, "mac": mac}
    if baseline is None and not options.compare and not options.previous:
        reason = options.override.strip()
        if len(reason) < MINIMUM_OVERRIDE:
            raise ValueError("--override needs a reason of at least a few words")
        rows = compare({}, current, limits)
        outcome = {"passed": True, "regressions": [], "skipped": reason}
        unmeasured = [row["title"] for row in rows if row["verdict"] == "not measured"]
        if unmeasured:
            outcome = {"passed": False, "regressions": unmeasured}
    else:
        rows = compare(previous, current, limits)
        outcome = verdict(rows, options.override)
    record = None
    if options.record and outcome["passed"]:
        record = baseline_record(
            current, mac, release=release, sessions=options.sessions, launches=options.launches,
            note=outcome.get("overridden") or outcome.get("skipped"),
        )
        recorded = write_baseline(baseline_path(mac["model"], options.baselines), record)
        sources["recorded"] = str(recorded.relative_to(ROOT) if recorded.is_relative_to(ROOT) else recorded)
    output = write(rows, outcome, sources, options.output)
    if record:
        # A copy next to the report, for a CI run whose checkout is thrown away.
        write_baseline(output / "baseline.json", record)
    print((output / "gate.md").read_text(), flush=True)
    if not outcome["passed"]:
        raise ValueError(
            f"Performance gate failed: {', '.join(outcome['regressions'])}. "
            "Fix it, or pass --override with the reason it should ship."
        )
