"""`make benchmark`: a repeatable performance run for Arx, and Chrome when it's installed.

Every browser gets fresh throwaway storage under `~/Library/Caches/arx-benchmark/` and
loads only loopback fixture pages (`core/benchmark_fixture.py`). The user's own profiles
are never read. Arx is started from its executable with `ARX_ENGINE_PROFILE`, so a copy
of Arx that is already running (the same bundle ID) is never asked to quit or open
anything. Quitting goes to the exact process this run started.

Results go to `build/benchmarks/<UTC time>/results.json` and `results.md`, with the
hardware, macOS, app, engine and Git versions. See `Scripts/README.md` ("Benchmark").

Options (`make benchmark ARGS='…'`):
  --app PATH          measure this Arx.app instead of building one
  --configuration C   build configuration when building (default Release)
  --launches N        warm launches to time (default 5)
  --idle SECONDS      idle window for CPU and wakeups (default 30)
  --tabs 10,50,100    tab counts for the memory steps
  --switches N        tab switches to time (default 30)
  --chrome PATH       Chrome.app to compare with (default: /Applications/Google Chrome.app if present)
  --skip-chrome       measure only Arx
  --keep              keep the throwaway profiles
  --serve             only serve the fixture pages, for timing other browsers by hand
  --fixture-hosts H   loopback (default: every tab its own t<N>.localhost site) or same-site
                      (t<N>.arx-bench.test, one site, so tabs may share renderers)
  --freeze-wait S     how long the native step leaves its shown tabs before counting frozen
                      pages (default 390: Chromium protects a tab for 5 minutes after it was visible)
  --skip-native       leave out the windowed native step (shortcut timings and freezing)
  --no-warmup         start the headless tab steps at once instead of after the warm-up (see WARMUP_S)
  --live-connections F  the fraction of tabs, 0 to 1 (default 0), whose page keeps a WebSocket open
                      to the fixture server, spread evenly (DEV-879); the freezing step then
                      counts their frozen pages and open connections apart
  --quick             a short check that every step runs: 1 warm launch, 5 s idle, 3 tabs,
                      3 switches, 20 s freeze wait, no Chrome. Its numbers are not a baseline.
"""

import argparse
import json
import math
import os
import selectors
import platform
import plistlib
import queue
import random
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from .core import benchmark_fixture, process_metrics
from .core.paths import ROOT

PROFILES = Path.home() / "Library/Caches/arx-benchmark"  # Not /private/tmp: Arx canonicalizes it to /tmp.
CHROME = Path("/Applications/Google Chrome.app")
SETTLE = 10  # seconds after tabs report ready before memory is sampled
ARX_ENVIRONMENT = {
    "ARX_SKIP_ONBOARDING": "1", "ARX_SKIP_DEFAULT_BROWSER": "1", "ARX_SKIP_RELOCATION": "1",
    "ARX_SKIP_AGENT_TOOLS": "1", "ARX_SKIP_AGENTS": "1", "ARX_SKIP_REMOTE_SUGGESTIONS": "1",
    "ARX_SKIP_UPDATES": "1",
    # Runs seed and rewrite the JSON workspace: SQLite, on by default (DEV-1143), stays off.
    "ARX_SQLITE_WORKSPACE": "0",
    # The native step's ⌃Tab is Next Tab, as before DEV-544: the recent-tab switcher waits for ⌃ to
    # be let go, and the driver's key events carry ⌃ without ever releasing it, so no switch landed.
    "ARX_RECENT_TAB_SWITCHER": "0",
}
# Feature flags the engine reads from the environment (engine_bridge.mm, FeatureFlag); a run
# records the ones that are set, so an A/B's report says which side it is.
FEATURE_FLAGS = ("ARX_BACK_FORWARD_CACHE_SIZE", "ARX_BOOTSTRAP_BACKGROUND_PAGES", "ARX_IDLE_TRIM",
                 "ARX_MEMORY_PURGE_ON_FREEZE", "ARX_SPARE_LIVE_CONNECTIONS", "ARX_SPARE_RENDERER")
# Seconds the headless profile runs with one tab before the tab steps: on a new profile Chromium's
# component updater and uBlock's first list update write some 20 MB about a minute in, and uBlock
# saves its selfie 53 s after its last list change, 150 to 170 MB about 150 s in. Either would
# otherwise land in a tab step's idle window (DEV-682). `--no-warmup` turns it off.
WARMUP_S = 180
QUICK = {"launches": 1, "idle": 5, "tabs": "3", "switches": 3, "freeze_wait": 20, "skip_chrome": True,
         "warmup": 5}
LAUNCH_MARKS = ("ProcessStart", "WindowShown", "FirstPagePainted")
# Extensions every Chromium profile has; named here because their manifests aren't in the profile.
COMPONENT_EXTENSIONS = {
    "mhjfbmdgcfjbbpaeojofohoefgiehjai": "Chromium PDF Viewer",
    "ahfgeienlihckogmohjhadlkjgocpleb": "Web Store",
    "nkeimhogjdpnpccoofpliimaahmaaome": "Google Hangouts (WebRTC logs)",
    "fignfifoniblkonapihmkfakmlgkbkcf": "Google Network Speech",
}


def main(arguments=()):
    options = parse(arguments)
    if options.serve:
        return serve(options.fixture_hosts)
    started = datetime.now(timezone.utc)
    output = ROOT / "build/benchmarks" / started.strftime("%Y%m%dT%H%M%SZ")
    output.mkdir(parents=True, exist_ok=True)
    app = Path(options.app).resolve() if options.app else build(options.configuration)
    PROFILES.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix=started.strftime("%Y%m%dT%H%M%S-"), dir=PROFILES))
    results = {"started": started.isoformat(), "machine": machine(), "options": vars(options),
               "feature_flags": feature_flags(os.environ), "browsers": {}}
    try:
        with benchmark_fixture.Server(options.fixture_hosts) as server:
            results["browsers"]["Arx"] = measure(Arx(app, scratch / "arx", server, options))
            write(output, results)
            chrome = Path(options.chrome) if options.chrome else CHROME
            if options.skip_chrome:
                results["browsers"]["Chrome"] = {"skipped": "--skip-chrome"}
            elif not (chrome / "Contents/MacOS/Google Chrome").is_file():
                results["browsers"]["Chrome"] = {"skipped": f"not installed at {chrome}"}
            else:
                results["browsers"]["Chrome"] = measure(Chrome(chrome, scratch / "chrome", server, options))
    finally:
        write(output, results)
        if not options.keep:
            shutil.rmtree(scratch, ignore_errors=True)
    print(f"Benchmark results: {output / 'results.md'}", flush=True)
    failed = [name for name, browser in results["browsers"].items() if "error" in browser]
    if failed:
        # After the report is written, so what was measured is kept; `execute` turns this into exit 1.
        raise ValueError(f"Benchmark: {', '.join(failed)} stopped early; see {output / 'results.md'}")
    return 0


def measure(browser):
    """The browser's results, or what failed: one browser's failure keeps the others' numbers."""
    try:
        return browser.run()
    except Exception as error:
        browser.log(f"failed: {error}")
        return {"error": str(error), **browser.partial}


def serve(hosts="loopback"):
    """Serves the fixture and prints each page's beacon, for browsers this script doesn't drive."""
    with benchmark_fixture.Server(hosts) as server:
        print(f"Start page: {server.start_url('manual')}")
        print(f"Tab pages: {server.tab_url(1)} … {server.tab_url(100)}")
        if hosts == "same-site":
            print(f"Start the browser with --host-resolver-rules='{benchmark_fixture.HOST_RESOLVER_RULES}'.")
        print("Each line below is a page reporting it is usable or became visible. Ctrl-C stops.", flush=True)
        original = server.beacons.record

        def record(event, identifier):
            original(event, identifier)
            print(f"{datetime.now().strftime('%H:%M:%S.%f')[:-3]} {event} {identifier}", flush=True)

        server.beacons.record = record
        try:
            threading.Event().wait()
        except KeyboardInterrupt:
            return 0


def parse(arguments):
    parser = argparse.ArgumentParser(prog="make benchmark ARGS=")
    parser.add_argument("--app")
    parser.add_argument("--configuration", default="Release")
    parser.add_argument("--launches", type=int, default=5)
    parser.add_argument("--idle", type=int, default=30)
    parser.add_argument("--tabs", default="10,50,100")
    parser.add_argument("--switches", type=int, default=30)
    parser.add_argument("--chrome")
    parser.add_argument("--skip-chrome", action="store_true")
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--fixture-hosts", choices=benchmark_fixture.HOSTS, default="loopback")
    parser.add_argument("--freeze-wait", type=int, default=390)
    parser.add_argument("--skip-native", action="store_true")
    parser.add_argument("--live-connections", type=float, default=0.0)
    parser.add_argument("--no-warmup", dest="warmup", action="store_const", const=0, default=WARMUP_S)
    parser.add_argument("--quick", action="store_true")
    options = parser.parse_args(list(arguments))
    if not 0 <= options.live_connections <= 1:
        parser.error("--live-connections is a fraction of the tabs, from 0 to 1")
    if options.quick:
        for name, value in QUICK.items():
            if name != "warmup" or options.warmup:  # --no-warmup stays off in a quick run
                setattr(options, name, value)
    options.tabs = sorted({int(value) for value in options.tabs.split(",") if value})
    return options


def feature_flags(environment):
    return {name: environment[name] for name in FEATURE_FLAGS if name in environment}


def live_tab(index, fraction):
    """Whether tab `index` (from 1) keeps a WebSocket open: `fraction` of the tabs, spread evenly,
    so every tab count gets its share (0.2 makes tabs 5, 10, 15 … live)."""
    return math.floor(index * fraction + 1e-9) > math.floor((index - 1) * fraction + 1e-9)


def build(configuration):
    """Builds into DerivedData and product paths of its own: `make run`'s build/DerivedData, or a
    custom Xcode output location, may hold a bundle that is running."""
    from . import build_app
    from .tools.xcodebuild import isolated_build_settings
    derived_data = ROOT / "build/BenchmarkDerivedData"
    return Path(build_app.main(log="benchmark-build.log", signed=True, require_engine=True,
                               configuration=configuration, derived_data=derived_data,
                               build_settings=isolated_build_settings(derived_data))).resolve()


# MARK: - Machine and versions

def machine():
    def sysctl(name):
        return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True).stdout.strip()

    def command(*arguments):
        result = subprocess.run(arguments, capture_output=True, text=True, cwd=ROOT)
        return result.stdout.strip() if result.returncode == 0 else None

    hardware = json.loads(command("system_profiler", "-json", "SPHardwareDataType") or "{}")
    hardware = (hardware.get("SPHardwareDataType") or [{}])[0]
    power = command("pmset", "-g", "batt") or ""
    return {
        "model": hardware.get("machine_model") or sysctl("hw.model"),
        "chip": hardware.get("chip_type") or sysctl("machdep.cpu.brand_string"),
        "cores": f"{sysctl('hw.ncpu')} ({sysctl('hw.perflevel0.physicalcpu')} performance, "
                 f"{sysctl('hw.perflevel1.physicalcpu')} efficiency)",
        "memory": hardware.get("physical_memory") or f"{int(sysctl('hw.memsize')) // 2**30} GB",
        "macos": f"{platform.mac_ver()[0]} ({command('sw_vers', '-buildVersion')})",
        "power": "AC" if "AC Power" in power else ("battery" if "Battery Power" in power else "unknown"),
        "commit": command("git", "rev-parse", "--short", "HEAD"),
        "dirty": bool(command("git", "status", "--porcelain", "--untracked-files=no")),
        "load_average": os.getloadavg(),
    }


def bundle_version(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    return f"{info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')})"


# MARK: - Shared steps

class Browser:
    name = "browser"

    def __init__(self, app, storage, server, options):
        self.app, self.storage, self.server, self.options = app, storage, server, options
        self.process = None
        self.launched = None  # monotonic time of the last timed launch's exec
        self.last_marks = {}
        self.partial = {}  # results so far, kept when a later step fails

    def log(self, message):
        print(f"[{self.name}] {message}", flush=True)

    def tab_url(self, index, run):
        return self.server.tab_url(index, run, live=live_tab(index, self.options.live_connections))

    def timed_launch(self, label, timeout=90):
        """Seconds from exec until a page reports it is usable, and the launch marks.

        The start URL stays the same across launches: a browser that restores its last
        session (Arx does, and ignores the start URL once a workspace exists) reloads it.
        Its `mark=1` makes the page keep its renderer busy three seconds after it's ready
        (`page_renderer`); launch timing has ended by then.
        """
        with self.launch_marks() as marks:
            begun = time.monotonic()
            # Signposts are stamped on the continuous clock, which runs on while the Mac sleeps.
            begun_continuous = process_metrics.continuous_seconds()
            self.launch(self.server.start_url("start", mark=True))
            arrived = self.server.beacons.wait_any_since("ready", begun, timeout)
            if arrived is None:
                raise ValueError(f"{self.name} {label}: the start page never reported ready")
            self.launched = begun
        self.last_marks = marks.offsets(self.process.pid, begun_continuous)
        return arrived - begun

    def launch_marks(self):
        """Signposts read during a launch; only Arx emits them."""
        return NoMarks()

    def page_renderer(self):
        """The renderer showing the start page: the one busy for MARK_MS after `marked`."""
        before = process_metrics.sample_tree(self.process.pid)
        marked = self.server.beacons.wait_any_since("marked", self.launched, 10)
        after = process_metrics.sample_tree(self.process.pid)
        if marked is None:
            return None
        return busiest_renderer(before, after, benchmark_fixture.MARK_MS / 1000 / 2)

    def idle(self, seconds, listing=False):
        """CPU, wakeups and disk writes over an idle window, after a short settle, in all and per
        process type. With `listing`, also each process, with renderers named."""
        page = self.page_renderer() if listing else None
        time.sleep(SETTLE)
        before, begun = process_metrics.sample_tree(self.process.pid), time.monotonic()
        time.sleep(seconds)
        after = process_metrics.sample_tree(self.process.pid)
        elapsed = time.monotonic() - begun
        result = process_metrics.delta(before, after, elapsed)
        result.update(memory(after))
        result["by_role"] = process_metrics.by_role(before, after, elapsed)
        if listing:
            result["process_listing"] = process_listing(before, after, elapsed, page)
        return result

    def stop(self, timeout=30):
        if not self.process or self.process.poll() is not None:
            return
        try:
            self.quit()
        except (OSError, subprocess.SubprocessError) as error:
            # Still this run's own process: fall through to SIGTERM and SIGKILL below.
            self.log(f"quit request failed ({error}); terminating PID {self.process.pid}")
        try:
            self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()

    def launch_series(self):
        """The first launch on new storage, then warm relaunches on the same storage.

        Each number goes into `partial` as soon as it's measured, so a later launch that
        fails keeps the earlier ones in the report.
        """
        result = self.partial
        result["first_launch_s"] = self.timed_launch("first")
        result["launch_marks"] = {"first": self.last_marks, "warm": {}}
        idle = self.idle(self.options.idle, listing=True)
        idle["extensions"] = self.extensions()
        result["idle_one_tab"] = idle
        self.stop()
        warm, warm_marks = [], []
        result["warm_launch_s"] = None
        for index in range(self.options.launches):
            time.sleep(2)
            warm.append(self.timed_launch(f"warm{index}"))
            warm_marks.append(self.last_marks)
            result["warm_launch_s"] = summary(warm)
            result["launch_marks"]["warm"] = marks_summary(warm_marks)
            time.sleep(1)
            self.stop()

    def extensions(self):
        return []


def memory(sample):
    """Footprint in all and per process type. `renderers` counts every renderer, extension ones too."""
    roles = {}
    for role, usage in sample.processes.values():
        roles.setdefault(role, [0, 0])
        roles[role][0] += 1
        roles[role][1] += usage.footprint
    return {
        "footprint_mb": sample.footprint / 2**20,
        "resident_mb": sample.resident / 2**20,
        "processes": len(sample.processes),
        "renderers": sample.count("renderer") + sample.count("extension"),
        "extension_renderers": sample.count("extension"),
        "memory_by_role": {role: {"count": count, "footprint_mb": total / 2**20} for role, (count, total)
                           in sorted(roles.items(), key=lambda item: process_metrics.role_order(item[0]))},
    }


def busiest_renderer(before, after, minimum_seconds):
    """The non-extension renderer that used the most CPU between the samples, if it used at least
    `minimum_seconds`: the one running the start page's busy mark."""
    best, best_cpu = None, minimum_seconds
    for pid, (role, cpu, _, _) in process_metrics.changes(before, after).items():
        if role == "renderer" and cpu >= best_cpu:
            best, best_cpu = pid, cpu
    return best


def process_listing(before, after, seconds, page_renderer):
    """Every process of the tree with what it is, footprint, CPU and wakeups, in role order.

    A renderer is the start page's when it ran the page's busy mark, an extension renderer when
    started with `--extension-process` (a background page; `extensions` lists what's installed),
    and otherwise has no page: Chromium's spare renderer, kept ready for the next navigation.
    """
    names = {"renderer": "renderer without a page (spare)", "extension": "extension renderer"}
    rows = []
    for pid, (role, cpu, wakeups, _) in process_metrics.changes(before, after).items():
        name = "start page renderer" if pid == page_renderer else names.get(role, role)
        switches = process_metrics.switches(after.arguments.get(pid, ""))
        rows.append({"pid": pid, "role": role, "name": name,
                     "renderer_client_id": switches.get("renderer-client-id"),
                     "footprint_mb": after.processes[pid][1].footprint / 2**20,
                     "cpu_percent": 100 * cpu / seconds, "wakeups_per_second": wakeups / seconds})
    return sorted(rows, key=lambda row: (process_metrics.role_order(row["role"]), row["name"], row["pid"]))


def installed_extensions(user_data):
    """Extensions recorded in each Chromium profile's preferences under `user_data`, with names."""
    found = []
    for preferences in sorted(user_data.glob("*/Preferences")) + sorted(user_data.glob("*/Secure Preferences")):
        try:
            settings = json.loads(preferences.read_text()).get("extensions", {}).get("settings", {})
        except (OSError, ValueError):
            continue
        for identifier, entry in sorted(settings.items()):
            if not isinstance(entry, dict) or any(item["id"] == identifier and item["profile"] == preferences.parent.name
                                                  for item in found):
                continue
            manifest = entry.get("manifest") or read_manifest(preferences.parent / "Extensions", entry.get("path"))
            background = (manifest or {}).get("background", {})
            found.append({
                "profile": preferences.parent.name, "id": identifier,
                "name": extension_name(manifest, preferences.parent / "Extensions", entry.get("path"))
                or COMPONENT_EXTENSIONS.get(identifier, identifier),
                "location": entry.get("location"),
                "enabled": entry.get("state", 1) == 1 and not entry.get("disable_reasons"),
                "background": ("service worker" if "service_worker" in background
                               else "page" if background else None),
            })
    return found


def read_manifest(extensions, path):
    if not path:
        return None
    directory = Path(path) if Path(path).is_absolute() else extensions / path
    try:
        return json.loads((directory / "manifest.json").read_text())
    except (OSError, ValueError):
        return None


def extension_name(manifest, extensions, path):
    """The manifest's name, with a `__MSG_key__` name looked up in its default locale."""
    name = (manifest or {}).get("name")
    if not name or not (name.startswith("__MSG_") and name.endswith("__")):
        return name
    key = name[len("__MSG_"):-2]
    directory = Path(path) if path and Path(path).is_absolute() else extensions / (path or "")
    try:
        messages = json.loads((directory / "_locales" / manifest.get("default_locale", "en") / "messages.json").read_text())
    except (OSError, ValueError):
        return name
    entry = next((value for item, value in messages.items() if item.lower() == key.lower()), {})
    return entry.get("message", name)


class NoMarks:
    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def offsets(self, pid, begun):
        return {}


class LaunchMarks:
    """`log stream` of Arx's Launch signposts while a launch runs.

    Each signpost carries `machTimestamp`, Mach continuous time. That isn't the clock
    `time.monotonic()` reads on macOS (Mach absolute time, which stops while the Mac sleeps),
    so the harness reads the continuous clock at exec too (`process_metrics.continuous_seconds`)
    and marks are offsets from that. A filtered live stream costs far less than recording
    an Instruments trace (`xctrace`) and, unlike `log show`, doesn't depend on signposts
    having been persisted.
    """

    PREDICATE = 'subsystem == "dev.capturecontext.arx" AND category == "Launch"'

    def __init__(self, settle=1.0):
        self.settle, self.lines, self.process = settle, [], None

    def __enter__(self):
        self.process = subprocess.Popen(
            ["/usr/bin/log", "stream", "--signpost", "--style", "ndjson", "--predicate", self.PREDICATE],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        # The first line says the filter is installed; signposts before it would be missed.
        ready = selectors.DefaultSelector()
        ready.register(self.process.stdout, selectors.EVENT_READ)
        if ready.select(10):
            self.process.stdout.readline()
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()
        return self

    def read(self):
        for line in self.process.stdout:
            self.lines.append(line.decode(errors="replace"))

    def __exit__(self, *_):
        time.sleep(self.settle)  # the stream delivers a little after the event
        self.process.terminate()
        self.process.wait(timeout=10)
        self.reader.join(timeout=5)
        return False

    def offsets(self, pid, begun):
        return launch_offsets(self.lines, pid, begun)


def launch_offsets(lines, pid, begun):
    """Seconds from `begun` (Mach continuous seconds) to the first of each launch mark `pid` emitted."""
    offsets = {}
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        name = event.get("signpostName")
        if event.get("processID") != pid or name not in LAUNCH_MARKS or name in offsets:
            continue
        offsets[name] = event["machTimestamp"] * process_metrics.TICKS_TO_SECONDS - begun
    return offsets


def marks_summary(runs):
    """Median and range of each mark over several launches."""
    return {name: summary([run[name] for run in runs if name in run]) for name in LAUNCH_MARKS
            if any(name in run for run in runs)}


def summary(values):
    if not values:
        return None
    return {"median": statistics.median(values), "min": min(values), "max": max(values), "n": len(values),
            "values": values}


class FileWrites:
    """Counts rewrites of one file by polling its identity; a write replaces or touches it."""

    def __init__(self, path, interval=0.05):
        self.path, self.interval = path, interval
        self.writes, self.last_size = 0, 0
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.poll, daemon=True)

    def identity(self):
        try:
            status = self.path.stat()
            return (status.st_ino, status.st_mtime_ns, status.st_size)
        except FileNotFoundError:
            return None

    def poll(self):
        previous = self.identity()
        while not self.stopped.wait(self.interval):
            current = self.identity()
            if current and current != previous:
                self.writes += 1
                self.last_size = current[2]
            previous = current

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stopped.set()
        self.thread.join()


# MARK: - Arx

class Arx(Browser):
    name = "Arx"

    def run(self):
        self.storage.mkdir(parents=True)
        result = self.partial
        result.update(version=bundle_version(self.app), app=str(self.app), engine=engine_version(self.app))
        try:
            self.log("launch series (windowed)")
            self.launch_series()
            self.log("tab scaling (headless, through the bundled MCP helper)")
            result["tabs"] = Headless(self).run()
            self.log("large workspace restore (windowed)")
            result["restore"] = self.restore()
            if not self.options.skip_native:
                self.log("native tab commands, shortcuts and freezing (windowed)")
                result["native"] = Native(self).run()
        finally:
            self.stop()
        return result

    def fixture_environment(self):
        """What the engine needs for the chosen fixture hosts."""
        return {"ARX_BENCHMARK_FIXTURE_HOSTS": "1"} if self.server.hosts == "same-site" else {}

    def environment(self, profile, url):
        return dict(os.environ, **ARX_ENVIRONMENT, **self.fixture_environment(),
                    ARX_ENGINE_PROFILE=str(profile), ARX_ENGINE_URL=url)

    def launch(self, url, profile=None, driver=False):
        profile = profile or self.storage / "windowed"
        profile.mkdir(parents=True, exist_ok=True)
        environment = self.environment(profile, url)
        if driver:
            environment["ARX_BENCHMARK_DRIVER"] = "1"
        self.process = subprocess.Popen(
            [str(self.app / "Contents/MacOS/Arx")], env=environment,
            stdin=subprocess.PIPE if driver else subprocess.DEVNULL,
            stdout=subprocess.PIPE if driver else subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    def launch_marks(self):
        return LaunchMarks()

    def extensions(self):
        return installed_extensions(self.storage / "windowed")

    def quit(self):
        """Asks this run's own process, by PID, to quit as Command-Q would. Never by bundle ID."""
        executable = str(self.app / "Contents/MacOS/Arx")
        script = (
            "ObjC.import('AppKit');"
            f"const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier({self.process.pid});"
            f"(!app.isNil() && app.executableURL.path.js === {json.dumps(executable)}) ? (app.terminate, 'ok') : 'none';"
        )
        subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, timeout=20)

    def restore(self):
        """Relaunches windowed Arx on its own profile with the headless run's tabs added.

        A headless profile has no window to restore, so its tabs are copied into the windowed
        profile's only space (`arx-workspace.json`, the format this commit writes). The selected
        start page then reports back once the window is up and its page is usable.
        """
        source = self.storage / "headless/arx-workspace.json"
        if not source.is_file():
            return {"skipped": "the headless run left no workspace"}
        # In place: a copied profile fails Arx's installation-identity check (ownershipChanged).
        profile = self.storage / "windowed"
        workspace = profile / "arx-workspace.json"
        added = merge_tabs(workspace, json.loads(source.read_text()))
        begun = time.monotonic()
        self.launch(self.server.start_url("start"), profile=profile)
        arrived = self.server.beacons.wait_any_since("ready", begun, 120)
        if arrived is None:
            raise ValueError(f"large workspace restore: the start page never reported ready ({added} tabs restored)")
        result = {"tabs": added, "workspace_kb": workspace.stat().st_size / 1024, "launch_to_ready_s": arrived - begun}
        result["idle"] = self.idle(self.options.idle)
        self.stop()
        return result


def merge_tabs(workspace, headless):
    """Appends the headless workspace's fixture tabs to the first space of `workspace`."""
    data = json.loads(workspace.read_text())
    organization = data["organization"]
    space = organization["spaces"][0]
    added = 0
    for tab in headless["organization"]["tabs"]:
        url = tab.get("restoration", {}).get("url", "")
        if "/tab/" not in url or "run=warmup" in url:  # the warm-up tab isn't one of the measured ones
            continue
        identifier = str(uuid.uuid4()).upper()
        organization["tabs"].append({"id": identifier, "profileID": space["profileID"],
                                     "restoration": tab["restoration"]})
        space.setdefault("unpinnedTabs", []).append(identifier)
        added += 1
    workspace.write_text(json.dumps(data))
    return added


def engine_version(app):
    """The Chromium version bundled in `app`: the engine framework's version directory."""
    versions = app / "Contents/Frameworks/Arx Framework.framework/Versions"
    names = sorted(entry.name for entry in versions.iterdir() if entry.name != "Current") if versions.is_dir() else []
    return f"Chromium {names[-1]}" if len(names) == 1 else None


class Headless:
    """`Arx --headless` with a persistent throwaway profile, driven through its MCP helper.

    Headless Arx has the same composition, engine and workspace as the windowed app, and
    its MCP boundary can open and select tabs. Its window is transparent, so these numbers
    leave out the cost of drawing to the screen.
    """

    def __init__(self, arx):
        self.arx = arx

    def run(self):
        from .headless_smoke import Client, Run
        profile = self.arx.storage / "headless"
        profile.mkdir(parents=True, exist_ok=True)
        log = (ROOT / "build/logs/runtime").joinpath("benchmark-headless.log")
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open("w") as stderr, patched_environment(self.arx.fixture_environment()):
            run = Run(self.arx.app, stderr, "--profile", str(profile), "--allow", "read,manage",
                      "--viewport", "1440x900", "--timeout", "3600")
            self.arx.process = run.process
            ready = run.wait_for("ready")
            client = Client(Path(ready["configuration"]))
            try:
                return self.measure(client, profile)
            finally:
                client.close()
                os.kill(run.process.pid, signal.SIGTERM)
                run.finish(timeout=60)

    def measure(self, client, profile):
        server, options = self.arx.server, self.arx.options
        steps = []
        warmup = self.warm_up(client)
        # Kept in `partial` as measured, so a later count or the switches failing keeps the earlier steps.
        results = self.arx.partial["tabs"] = {
            "warmup": warmup, "baseline": memory(process_metrics.sample_tree(self.arx.process.pid)), "steps": steps,
        }
        opened, tab_ids = 0, []
        with FileWrites(profile / "arx-workspace.json") as writes:
            for count in options.tabs:
                before = process_metrics.sample_tree(self.arx.process.pid)
                begun = time.monotonic()
                open_times, command_times = [], []
                while opened < count:
                    opened += 1
                    started = time.monotonic()
                    tab_id, command_seconds = open_tab(client, self.arx.tab_url(opened, "arx"))
                    tab_ids.append(tab_id)
                    open_times.append(time.monotonic() - started)
                    command_times.append(command_seconds)
                identifiers = [server.tab_id(index, "arx") for index in range(1, count + 1)]
                loaded = server.beacons.wait_all("loaded", identifiers, 30 + count)
                load_seconds = time.monotonic() - begun
                if loaded < count:
                    self.arx.log(f"{count} tabs: only {loaded} pages loaded; the report marks this step")
                time.sleep(SETTLE)
                after = process_metrics.sample_tree(self.arx.process.pid)
                opening = process_metrics.delta(before, after, time.monotonic() - begun)
                step = {"tabs": count, "loaded": loaded, "open_and_load_s": load_seconds,
                        "open_command_ms": summary([value * 1000 for value in open_times]),
                        "open_receipt_ms": summary([value * 1000 for value in command_times]),
                        "opening_bytes_written": opening["bytes_written"], **memory(after)}
                quiet = process_metrics.sample_tree(self.arx.process.pid)
                quiet_begun = time.monotonic()
                time.sleep(options.idle)
                after_idle = process_metrics.sample_tree(self.arx.process.pid)
                elapsed = time.monotonic() - quiet_begun
                idle = process_metrics.delta(quiet, after_idle, elapsed)
                idle["by_role"] = process_metrics.by_role(quiet, after_idle, elapsed)
                step["idle"] = idle
                steps.append(step)
                self.arx.log(f"{count} tabs: {step['footprint_mb']:.0f} MB, {step['renderers']} renderers, "
                             f"idle CPU {idle['cpu_percent']:.1f}%")
            results["switch"] = self.switch(client, tab_ids)
            results["workspace"] = {"writes_during_run": writes.writes, "size_kb": writes.last_size / 1024}
        return results

    def warm_up(self, client):
        """Runs the new profile with one tab for `--warmup` seconds from opening it, then closes it.

        The profile's first page is when Arx hands uBlock its settings, and a minute or so in,
        Chromium's component updater and uBlock's list update download and store their data. Both
        happen once per profile; after the warm-up the tab steps and their idle windows measure
        steady state. A tab that doesn't close is reported and left open, not a failure.
        """
        seconds = self.arx.options.warmup
        if not seconds:
            return None
        server = self.arx.server
        begun = time.monotonic()
        tab_id, _ = open_tab(client, server.tab_url(1, "warmup"))
        loaded = server.beacons.wait("loaded", server.tab_id(1, "warmup"), min(seconds, 30)) is not None
        time.sleep(max(0.0, seconds - (time.monotonic() - begun)))
        closed = close_tab(client, tab_id)
        if not closed:
            self.arx.log("warm-up: its tab didn't close; the tab steps count it")
        return {"duration_s": time.monotonic() - begun, "tab_loaded": loaded, "tab_closed": closed}

    def switch(self, client, tab_ids):
        """Round trip of `selectTab` through MCP, and until the page reports it became visible."""
        rng = random.Random(682)
        receipts, visible = [], []
        for _ in range(self.arx.options.switches):
            tab_id = rng.choice(tab_ids)
            item = next(entry for entry in inventory(client) if entry["id"] == tab_id)
            identifier = self.arx.server.tab_id(tab_ids.index(tab_id) + 1, "arx")
            marker = time.monotonic()
            result, reply = client.call("browser_command", {
                "operationID": str(uuid.uuid4()), "action": "selectTab", "targetID": tab_id,
                "expectedRevision": item["revision"],
            })
            receipts.append((time.monotonic() - marker) * 1000)
            if result.get("isError"):
                raise ValueError("selectTab failed: " + json.dumps(reply))
            arrived = self.arx.server.beacons.wait_since("visible", identifier, marker, 2)
            if arrived is not None:
                visible.append((arrived - marker) * 1000)
            time.sleep(0.3)
        return {"receipt_ms": summary(receipts), "visible_ms": summary(visible),
                "visible_reported": len(visible)}


class patched_environment:
    """Adds variables to this process's environment for a child that inherits it."""

    def __init__(self, values):
        self.values, self.saved = values, {}

    def __enter__(self):
        self.saved = {name: os.environ.get(name) for name in self.values}
        os.environ.update(self.values)

    def __exit__(self, *_):
        for name, value in self.saved.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
        return False


def inventory(client, attempts=20):
    """Every granted item, following `nextCursor`: 100 tabs don't fit one page.

    A page answers `staleTarget` or `staleCursor` when the tree changed since the first page
    (tabs still loading do that), so the whole listing starts again.
    """
    for _ in range(attempts):
        items, cursor = [], None
        while True:
            arguments = {"limit": 100, **({"cursor": cursor} if cursor else {})}
            _, page = client.call("browser_inventory", arguments)
            if "items" not in page:
                break
            items += page["items"]
            cursor = page.get("nextCursor")
            if not cursor:
                return items
        if page.get("code") not in ("staleTarget", "staleCursor", "busy"):
            raise ValueError("browser_inventory failed: " + json.dumps(page))
        time.sleep(0.2)
    raise ValueError("browser_inventory kept answering " + json.dumps(page))


def space(client):
    """The first page is enough: spaces come before their tabs."""
    _, page = client.call("browser_inventory", {"limit": 100})
    found = next((item for item in page.get("items", []) if item["kind"] == "space"), None)
    return found or next(item for item in inventory(client) if item["kind"] == "space")


def open_tab(client, url):
    """The new tab's ID, and how long `browser_command` alone took.

    `open_command_ms` also counts the `browser_inventory` page that finds the space's current
    revision first, whose size grows with the tab count up to 100 items (DEV-934);
    `open_receipt_ms` is the command alone.
    """
    target = space(client)
    started = time.monotonic()
    result, command = client.call("browser_command", {
        "operationID": str(uuid.uuid4()), "action": "openTab", "targetID": target["id"],
        "expectedRevision": target["revision"], "url": url, "focus": False,
    })
    elapsed = time.monotonic() - started
    if result.get("isError") or command.get("kind") == "error":
        raise ValueError("openTab failed: " + json.dumps(result.get("structuredContent")))
    return command["targetID"], elapsed


def close_tab(client, tab_id):
    """Sends the tab to the Tab Archive (`closeTab`); whether it went."""
    item = next((entry for entry in inventory(client) if entry["id"] == tab_id), None)
    if item is None:
        return False
    result, reply = client.call("browser_command", {
        "operationID": str(uuid.uuid4()), "action": "closeTab", "targetID": tab_id,
        "expectedRevision": item["revision"],
    })
    return not result.get("isError") and (reply or {}).get("kind") != "error"


class Driver:
    """Talks to windowed Arx's `BenchmarkDriver` (AppFeature) over its stdin and stdout.

    A thread keeps reading Arx's stdout, so a long idle wait never fills the pipe.
    """

    PREFIX = "ARX_BENCHMARK_DRIVER "
    KEYS = {"t": 17, "tab": 48, "return": 36}  # ANSI key codes; Tab and Return are the same on every layout

    def __init__(self, process):
        self.process, self.next_id = process, 0
        self.replies = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            text = line.decode(errors="replace").strip()
            if text.startswith(self.PREFIX):
                self.replies.put(json.loads(text[len(self.PREFIX):]))

    def send(self, action, timeout=10, **arguments):
        self.next_id += 1
        command = {"id": self.next_id, "action": action, **arguments}
        self.process.stdin.write(json.dumps(command).encode() + b"\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        while True:
            try:
                reply = self.replies.get(timeout=max(0.0, deadline - time.monotonic()))
            except queue.Empty:
                raise ValueError("Arx's benchmark driver didn't answer; is this build older than DEV-939?") from None
            if reply.get("id") == self.next_id:
                return reply

    def key(self, name, characters, *modifiers):
        reply = self.send("key", keyCode=self.KEYS[name], characters=characters, modifiers=list(modifiers))
        if not reply.get("ok"):
            raise ValueError(f"key {name} failed: {reply}")

    def require(self, action, **arguments):
        reply = self.send(action, **arguments)
        if not reply.get("ok"):
            raise ValueError(f"{action} failed: {reply.get('detail')}")


class Native:
    """Windowed Arx driven by synthesized keys, as a person would: ⌘T, an address and Return
    for a new tab, ⌃Tab to switch, every tab shown in turn. Then it leaves the tabs alone long
    enough for Chromium to freeze background pages and counts the frozen ones.

    New tab: from ⌘T until the new page reports `ready` (loaded and painted twice); the
    command bar's part is until its empty field has focus. Switch: from ⌃Tab until the newly
    selected page reports `shown` (visible and painted twice). Keys go through Arx's own event
    queue (`BenchmarkDriver`), not the WindowServer, so the run needs no Accessibility permission;
    the window must be visible and Arx frontmost, so leave the Mac alone while it runs.
    """

    def __init__(self, arx):
        self.arx = arx

    def run(self):
        arx, server, options = self.arx, self.arx.server, self.arx.options
        run = f"native-{uuid.uuid4().hex[:6]}"
        begun = time.monotonic()
        arx.launch(server.start_url(run), profile=arx.storage / "native", driver=True)
        driver = Driver(arx.process)  # reads stdout from the start, so a full pipe never blocks Arx
        if server.beacons.wait_any_since("ready", begun, 90) is None:
            raise ValueError("native step: the start page never reported ready")
        for attempt in range(5):  # macOS may refuse activation while another app is in use
            if driver.send("activate").get("ok"):
                break
            time.sleep(1)
        else:
            raise ValueError("native step: Arx couldn't become the active app")
        steps, opened, identifiers = [], 0, []
        result = arx.partial["native"] = {"steps": steps}  # kept if a later count fails
        try:
            for count in options.tabs:
                new_tab, command_bar = [], []
                while opened < count:
                    opened += 1
                    identifiers.append(server.tab_id(opened, run))
                    shown, bar = self.new_tab(driver, arx.tab_url(opened, run), identifiers[-1])
                    new_tab.append(shown * 1000)
                    command_bar.append(bar * 1000)
                time.sleep(SETTLE)
                before, quiet_begun = process_metrics.sample_tree(arx.process.pid), time.monotonic()
                time.sleep(options.idle)
                after = process_metrics.sample_tree(arx.process.pid)
                elapsed = time.monotonic() - quiet_begun
                idle = process_metrics.delta(before, after, elapsed)
                idle["by_role"] = process_metrics.by_role(before, after, elapsed)
                step = {"tabs": count, "new_tab_ms": summary(new_tab), "command_bar_ms": summary(command_bar),
                        **memory(after), "idle": idle}
                steps.append(step)  # before the switches, so their failure keeps this step's numbers
                step["switch"] = self.switches(driver, count)
                arx.log(f"{count} tabs, native: new tab {step['new_tab_ms']['median']:.0f} ms, "
                        f"switch {lookup(step, ('switch', 'shown_ms', 'median')) or float('nan'):.0f} ms, "
                        f"{step['footprint_mb']:.0f} MB, {step['renderers']} renderers")
            result["freezing"] = self.freezing(identifiers)
            return result
        finally:
            arx.stop()

    def new_tab(self, driver, url, identifier):
        server = self.arx.server
        begun = time.monotonic()
        driver.key("t", "t", "command")
        driver.require("awaitTextInput", timeout=5)
        bar = time.monotonic() - begun
        driver.require("insertText", text=url)
        driver.key("return", "\r")
        arrived = server.beacons.wait_since("ready", identifier, begun, 30)
        if arrived is None:
            hint = (" Same-site hosts need an engine with DEV-939's host rule." if server.hosts == "same-site" else "")
            raise ValueError(f"native new tab {identifier} never reported ready.{hint}")
        return arrived - begun, bar

    def switches(self, driver, count):
        """⌃Tab to the next tab, timed until that page is shown again."""
        if count < 2:
            return None
        visible, shown, missed = [], [], 0
        for _ in range(self.arx.options.switches):
            begun = time.monotonic()
            driver.key("tab", "\t", "control")
            arrived = self.arx.server.beacons.wait_any_since("shown", begun, 3)
            seen = self.arx.server.beacons.wait_any_since("visible", begun, 0)
            if arrived is not None:
                shown.append((arrived - begun) * 1000)
            else:
                missed += 1  # slower than 3 s or no switch at all: counted, never left out silently
            if seen is not None:
                visible.append((seen - begun) * 1000)
            time.sleep(0.3)
        if self.arx.options.switches and not shown:
            raise ValueError(f"native step, {count} tabs: no ⌃Tab showed a page within 3 s")
        return {"shown_ms": summary(shown), "visible_ms": summary(visible), "shown_reported": len(shown),
                "missed": missed}

    def freezing(self, identifiers):
        """After every tab was shown, waits `--freeze-wait`, measuring the last idle window of it."""
        arx, options = self.arx, self.arx.options
        wait = max(options.freeze_wait, options.idle)
        time.sleep(wait - options.idle)
        before, begun = process_metrics.sample_tree(arx.process.pid), time.monotonic()
        time.sleep(options.idle)
        after = process_metrics.sample_tree(arx.process.pid)
        elapsed = time.monotonic() - begun
        idle = process_metrics.delta(before, after, elapsed)
        idle["by_role"] = process_metrics.by_role(before, after, elapsed)
        beacons = arx.server.beacons
        frozen, ever = beacons.frozen(identifiers)
        arx.log(f"after {wait} s: {frozen} of {len(identifiers)} pages frozen ({ever} ever)")
        result = {"waited_s": wait, "pages": len(identifiers), "frozen": frozen, "ever_frozen": ever,
                  **memory(after), "idle": idle}
        # Tab N is identifiers[N - 1]; the live ones kept a WebSocket open to the fixture (DEV-879).
        live = [identifier for index, identifier in enumerate(identifiers, start=1)
                if live_tab(index, options.live_connections)]
        if live:
            live_frozen, live_ever = beacons.frozen(live)
            connected, opened = beacons.connections(live)
            result["live"] = {"pages": len(live), "frozen": live_frozen, "ever_frozen": live_ever,
                              "connected": connected, "ever_connected": opened}
            arx.log(f"live pages: {live_frozen} of {len(live)} frozen ({live_ever} ever), "
                    f"{connected} still connected ({opened} ever)")
        return result


# MARK: - Chrome

class Chrome(Browser):
    name = "Chrome"

    def run(self):
        result = self.partial
        result.update(version=bundle_version(self.app), app=str(self.app))
        try:
            self.launch_series()
            self.tabs()
        finally:
            self.stop()
        return result

    def arguments(self, urls):
        return [str(self.app / "Contents/MacOS/Google Chrome"), f"--user-data-dir={self.storage}",
                "--no-first-run", "--no-default-browser-check", "--disable-sync",
                "--disable-background-networking", "--password-store=basic", "--use-mock-keychain",
                *([f"--host-resolver-rules={benchmark_fixture.HOST_RESOLVER_RULES}"]
                  if self.server.hosts == "same-site" else []), *urls]

    def launch(self, url, urls=()):
        self.storage.mkdir(parents=True, exist_ok=True)
        self.process = subprocess.Popen(self.arguments([url, *urls]), stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def quit(self):
        self.process.send_signal(signal.SIGTERM)  # Chrome shuts down cleanly on SIGTERM.

    def extensions(self):
        return installed_extensions(self.storage)

    def tabs(self):
        """Fresh launches with N tab URLs on the command line, which opens them all."""
        steps = []
        self.partial["tabs"] = {"steps": steps}  # kept as measured if a later count fails
        for count in self.options.tabs:
            time.sleep(2)
            run = f"chrome{count}-{uuid.uuid4().hex[:6]}"
            urls = [self.tab_url(index, run) for index in range(1, count + 1)]
            identifiers = [self.server.tab_id(index, run) for index in range(1, count + 1)]
            begun = time.monotonic()
            self.launch(self.server.start_url(run), urls)
            loaded = self.server.beacons.wait_all("loaded", identifiers, 30 + count)
            load_seconds = time.monotonic() - begun
            if loaded < count:
                self.log(f"{count} tabs: only {loaded} pages loaded; the report marks this step")
            time.sleep(SETTLE)
            step = {"tabs": count, "loaded": loaded, "open_and_load_s": load_seconds,
                    **memory(process_metrics.sample_tree(self.process.pid))}
            quiet, quiet_begun = process_metrics.sample_tree(self.process.pid), time.monotonic()
            time.sleep(self.options.idle)
            after_idle = process_metrics.sample_tree(self.process.pid)
            elapsed = time.monotonic() - quiet_begun
            step["idle"] = process_metrics.delta(quiet, after_idle, elapsed)
            step["idle"]["by_role"] = process_metrics.by_role(quiet, after_idle, elapsed)
            steps.append(step)
            self.stop()
        return self.partial["tabs"]


# MARK: - Report

def write(output, results):
    (output / "results.json").write_text(json.dumps(results, indent=2, default=str))
    (output / "results.md").write_text(report(results))


def report(results):
    machine_info = results["machine"]
    lines = [
        f"# Arx benchmark, {results['started'][:16].replace('T', ' ')} UTC", "",
        f"{machine_info['model']}, {machine_info['chip']}, {machine_info['cores']} cores, {machine_info['memory']}, "
        f"macOS {machine_info['macos']}, power: {machine_info['power']}, commit {machine_info['commit']}"
        f"{' (dirty)' if machine_info['dirty'] else ''}.", "",
    ]
    options = results.get("options", {})
    if options.get("quick"):
        lines += ["**Quick run (`--quick`):** a check that every step works, with too few samples for a baseline.", ""]
    if options.get("fixture_hosts") == "same-site":
        lines += ["Tabs were served from one site (`t<N>.arx-bench.test`), so same-site tabs may share renderers.", ""]
    if options.get("live_connections"):
        lines += [f"{options['live_connections']:.0%} of the tabs kept a WebSocket open to the fixture server "
                  "(`--live-connections`, DEV-879).", ""]
    if options.get("warmup") == 0:
        lines += ["No headless warm-up (`--no-warmup`): a new profile's first-run downloads may land in the "
                  "tab steps and their idle windows.", ""]
    flags = results.get("feature_flags") or {}
    if flags:
        lines += ["Feature flags from the environment: "
                  + ", ".join(f"`{name}={value}`" for name, value in flags.items()) + ".", ""]
    browsers = results["browsers"]
    names = list(browsers)
    lines += ["| Measure | " + " | ".join(names) + " |", "|---" * (len(names) + 1) + "|"]
    def counts(key):
        return sorted({step["tabs"] for browser in browsers.values() if isinstance(browser.get(key), dict)
                       for step in browser[key].get("steps", [])})

    expansions = {TAB_ROWS: [r for count in counts("tabs") for r in tab_rows(count)],
                  NATIVE_ROWS: [r for count in counts("native") for r in native_rows(count)]}
    rows = [row for entry in ROWS for row in expansions.get(entry, [entry])]
    for label, path, fmt in rows:
        cells = [fmt(lookup(browsers[name], path)) for name in names]
        if any(cell != "–" for cell in cells):
            lines.append(f"| {label} | " + " | ".join(cells) + " |")
    for name in names:
        if "error" in browsers[name]:
            lines.append(f"\n{name}: stopped early ({browsers[name]['error']}).")
        if "skipped" in browsers[name]:
            lines.append(f"\n{name}: skipped ({browsers[name]['skipped']}).")
        elif "version" in browsers[name]:
            lines.append(f"\n{name} {browsers[name]['version']}"
                         + (f", {browsers[name]['engine']}" if browsers[name].get("engine") else "") + ".")
    for name in names:
        for step in incomplete_steps(browsers[name]):
            lines.append(f"\n{name}, {step['tabs']} tabs: only {step['loaded']} pages loaded, so that step's "
                         "numbers aren't comparable.")
    for name in names:
        lines += role_table(name, browsers[name]) + listing_table(name, browsers[name])
    return "\n".join(lines) + "\n"


def incomplete_steps(browser):
    """Tab steps where fewer pages reported `load` than were opened."""
    return [step for step in lookup(browser, ("tabs", "steps")) or []
            if step.get("loaded") is not None and step["loaded"] < step["tabs"]]


def role_steps(name, browser):
    """(label, step) for every measured window that has per-process-type numbers."""
    found = [("Idle, 1 tab", lookup(browser, ("idle_one_tab",)))]
    opened = "headless" if name == "Arx" else "command line"  # how the tab step opened its tabs
    for step in lookup(browser, ("tabs", "steps")) or []:
        found.append((f"{step['tabs']} tabs, {opened}", {**step, "by_role": lookup(step, ("idle", "by_role"))}))
    for step in lookup(browser, ("native", "steps")) or []:
        found.append((f"{step['tabs']} tabs, windowed", {**step, "by_role": lookup(step, ("idle", "by_role"))}))
    freezing = lookup(browser, ("native", "freezing"))
    if freezing:
        found.append((f"After {freezing['waited_s']} s", {**freezing, "by_role": lookup(freezing, ("idle", "by_role"))}))
    restore = lookup(browser, ("restore", "idle"))
    if restore:
        found.append(("Restored workspace", restore))
    return [(label, step) for label, step in found if step and step.get("by_role")]


def role_table(name, browser):
    """Memory, CPU and wakeups per process type, so a browser-side timer and a busy page differ."""
    steps = role_steps(name, browser)
    if not steps:
        return []
    lines = ["", f"## {name}: cost per process type", "",
             "| Window | Type | Processes | Memory | CPU (% of one core) | Wakeups |", "|---|---|---|---|---|---|"]
    for label, step in steps:
        for role, row in step["by_role"].items():
            lines.append(f"| {label} | {role} | {row['processes']} | {megabytes(row['footprint_mb'])} | "
                         f"{percent(row['cpu_percent'])} | {per_second(row['wakeups_per_second'])} |")
    return lines


def listing_table(name, browser):
    """Each process at 1 tab, renderers named, and the extensions the profile has."""
    listing = lookup(browser, ("idle_one_tab", "process_listing"))
    if not listing:
        return []
    lines = ["", f"## {name}: processes at 1 tab", "",
             "| PID | Process | Memory | CPU | Wakeups |", "|---|---|---|---|---|"]
    for row in listing:
        lines.append(f"| {row['pid']} | {row['name']} | {megabytes(row['footprint_mb'])} | "
                     f"{percent(row['cpu_percent'])} | {per_second(row['wakeups_per_second'])} |")
    extensions = lookup(browser, ("idle_one_tab", "extensions")) or []
    if extensions:
        lines += ["", "Extensions in the profile: " + "; ".join(
            f"{item['name']} ({item['profile']}{', background ' + item['background'] if item['background'] else ''}"
            f"{'' if item['enabled'] else ', disabled'})" for item in extensions) + "."]
    return lines


def lookup(value, path):
    for key in path:
        if isinstance(key, int) and isinstance(value, list):
            value = next((step for step in value if step.get("tabs") == key), None)
        elif isinstance(value, dict):
            value = value.get(key)
        else:
            return None
        if value is None:
            return None
    return value


def seconds(value):
    return "–" if value is None else f"{value:.2f} s"


def milliseconds(value):
    return "–" if value is None else f"{value:.0f} ms"


def megabytes(value):
    return "–" if value is None else f"{value:,.0f} MB"


def percent(value):
    return "–" if value is None else f"{value:.1f}%"


def per_second(value):
    return "–" if value is None else f"{value:,.0f}/s"


def kilobytes(value):
    return "–" if value is None else f"{value / 1024:,.0f} KB"


def marks(value):
    """Launch marks as `0.12 / 0.80 / 1.05 s`, a dash for a mark the build doesn't emit."""
    if not value:
        return "–"
    return " / ".join(f"{value[name]:.2f}" if name in value else "–" for name in LAUNCH_MARKS) + " s"


def switch_cell(value):
    """The median switch, and how many switches showed no page within the time limit."""
    median = lookup(value, ("shown_ms", "median"))
    if median is None:
        return "–"
    missed = value.get("missed") or 0
    return milliseconds(median) + (f" ({missed} of {missed + value['shown_reported']} over 3 s)" if missed else "")


def plain(value):
    return "–" if value is None else str(value)


def tab_rows(count):
    return [
        (f"{count} tabs: pages loaded", ("tabs", "steps", count),
         lambda step: "–" if not step or step.get("loaded") is None else f"{step['loaded']} of {step['tabs']}"),
        (f"{count} tabs: memory", ("tabs", "steps", count, "footprint_mb"), megabytes),
        (f"{count} tabs: renderers", ("tabs", "steps", count, "renderers"), plain),
        (f"{count} tabs: open and load all", ("tabs", "steps", count, "open_and_load_s"), seconds),
        (f"{count} tabs: idle CPU", ("tabs", "steps", count, "idle", "cpu_percent"), percent),
        (f"{count} tabs: idle wakeups", ("tabs", "steps", count, "idle", "wakeups_per_second"), per_second),
        (f"{count} tabs: idle disk writes", ("tabs", "steps", count, "idle", "bytes_written"), kilobytes),
        (f"{count} tabs: openTab via MCP (median)", ("tabs", "steps", count, "open_command_ms", "median"),
         milliseconds),
        (f"{count} tabs: openTab via MCP, command alone (median)",
         ("tabs", "steps", count, "open_receipt_ms", "median"), milliseconds),
    ]


def native_rows(count):
    return [
        (f"{count} tabs, windowed: new tab, ⌘T → page ready (median)", ("native", "steps", count, "new_tab_ms", "median"),
         milliseconds),
        (f"{count} tabs, windowed: ⌘T → command bar focused (median)",
         ("native", "steps", count, "command_bar_ms", "median"), milliseconds),
        (f"{count} tabs, windowed: switch, ⌃Tab → page shown (median)", ("native", "steps", count, "switch"),
         switch_cell),
        (f"{count} tabs, windowed, every tab shown: memory", ("native", "steps", count, "footprint_mb"), megabytes),
        (f"{count} tabs, windowed: renderers (extension)", ("native", "steps", count),
         lambda step: "–" if not step else f"{step['renderers']} ({step['extension_renderers']})"),
        (f"{count} tabs, windowed: idle CPU", ("native", "steps", count, "idle", "cpu_percent"), percent),
        (f"{count} tabs, windowed: idle wakeups", ("native", "steps", count, "idle", "wakeups_per_second"), per_second),
    ]


TAB_ROWS = object()  # Where the rows for each measured tab count go.
NATIVE_ROWS = object()  # Where the windowed native rows for each tab count go.
ROWS = [
    ("First launch, new profile → page usable", ("first_launch_s",), seconds),
    ("First launch: exec → process start / window shown / first paint", ("launch_marks", "first"), marks),
    ("Warm launch → page usable (median)", ("warm_launch_s", "median"), seconds),
    ("Warm launch: exec → process start / window shown / first paint (medians)", ("launch_marks", "warm"),
     lambda value: marks({name: entry["median"] for name, entry in (value or {}).items()} if value else None)),
    ("Idle, 1 tab: memory (all processes)", ("idle_one_tab", "footprint_mb"), megabytes),
    ("Idle, 1 tab: processes", ("idle_one_tab", "processes"), plain),
    ("Idle, 1 tab: renderers (extension)", ("idle_one_tab",),
     lambda step: "–" if not step or "extension_renderers" not in step
     else f"{step['renderers']} ({step['extension_renderers']})"),
    ("Idle, 1 tab: CPU (% of one core)", ("idle_one_tab", "cpu_percent"), percent),
    ("Idle, 1 tab: wakeups", ("idle_one_tab", "wakeups_per_second"), per_second),
    ("Idle, 1 tab: disk writes per idle window", ("idle_one_tab", "bytes_written"), kilobytes),
    ("Headless warm-up before the tab steps", ("tabs", "warmup", "duration_s"), seconds),
    TAB_ROWS,
    ("selectTab via MCP, receipt (median)", ("tabs", "switch", "receipt_ms", "median"), milliseconds),
    ("selectTab → page visible (median)", ("tabs", "switch", "visible_ms", "median"), milliseconds),
    ("Workspace file writes while opening tabs", ("tabs", "workspace", "writes_during_run"), plain),
    ("Workspace file size", ("tabs", "workspace", "size_kb"), lambda value: "–" if value is None else f"{value:,.0f} KB"),
    ("Restore large workspace → page usable", ("restore", "launch_to_ready_s"), seconds),
    ("Restored workspace: memory", ("restore", "idle", "footprint_mb"), megabytes),
    ("Restored workspace: idle CPU", ("restore", "idle", "cpu_percent"), percent),
    NATIVE_ROWS,
    ("Frozen pages after the freeze wait (ever frozen)", ("native", "freezing"),
     lambda value: "–" if not value else f"{value['frozen']} of {value['pages']} ({value['ever_frozen']})"),
    ("Live pages frozen after the freeze wait (ever frozen)", ("native", "freezing", "live"),
     lambda value: "–" if not value else f"{value['frozen']} of {value['pages']} ({value['ever_frozen']})"),
    ("Live pages still connected after the freeze wait", ("native", "freezing", "live"),
     lambda value: "–" if not value else f"{value['connected']} of {value['pages']}"),
    ("After the freeze wait: memory", ("native", "freezing", "footprint_mb"), megabytes),
    ("After the freeze wait: idle CPU", ("native", "freezing", "idle", "cpu_percent"), percent),
    ("After the freeze wait: idle wakeups", ("native", "freezing", "idle", "wakeups_per_second"), per_second),
]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
