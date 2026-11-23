"""The benchmark's fixture, process counters and report, without launching a browser."""

import json
import os
import socket
import threading
import time
import unittest
import urllib.request

from Scripts import benchmark
from Scripts.core import benchmark_fixture, process_metrics


class FixtureTests(unittest.TestCase):
    def test_pages_report_ready_and_beacons_are_timed(self):
        with benchmark_fixture.Server() as server:
            page = urllib.request.urlopen(server.start_url("abc")).read().decode()
            self.assertIn('data-id="abc"', page)
            self.assertIn("event=${event}", page)
            tab = urllib.request.urlopen(f"http://127.0.0.1:{server.port}/tab/7").read().decode()
            self.assertIn('data-id="7"', tab)
            self.assertIsNone(server.beacons.wait("ready", "abc", 0.05))
            marker = time.monotonic()
            urllib.request.urlopen(f"http://127.0.0.1:{server.port}/beacon?event=ready&id=abc").read()
            arrived = server.beacons.wait("ready", "abc", 1)
            self.assertGreaterEqual(arrived, marker)
            self.assertEqual(server.beacons.wait_all("ready", ["abc", "7"], 0.05), 1)

    def test_wait_since_skips_earlier_arrivals_of_the_same_page(self):
        beacons = benchmark_fixture.Beacons()
        beacons.record("visible", "3")
        marker = time.monotonic()
        self.assertIsNone(beacons.wait_since("visible", "3", marker, 0.05))
        threading.Timer(0.05, beacons.record, args=("visible", "3")).start()
        self.assertGreaterEqual(beacons.wait_since("visible", "3", marker, 1), marker)
        beacons.forget("visible", ["3"])
        self.assertIsNone(beacons.wait("visible", "3", 0.01))

    def test_tabs_are_separate_sites(self):
        server = benchmark_fixture.Server.__new__(benchmark_fixture.Server)
        server.port, server.hosts = 8000, "loopback"
        self.assertEqual(server.tab_url(12), "http://t12.localhost:8000/tab/12")
        self.assertEqual(server.tab_url(12, "arx"), "http://t12.localhost:8000/tab/12?run=arx")
        self.assertEqual(server.tab_id(12, "arx"), "arx-12")

    def test_same_site_hosts_share_one_reserved_domain(self):
        with benchmark_fixture.Server("same-site") as server:
            self.assertEqual(server.tab_url(3, "arx"), f"http://t3.arx-bench.test:{server.port}/tab/3?run=arx")
        self.assertEqual(benchmark_fixture.HOST_RESOLVER_RULES, "MAP *.arx-bench.test 127.0.0.1")
        with self.assertRaises(ValueError):
            benchmark_fixture.Server("anywhere")

    def test_pages_report_shown_lifecycle_and_mark(self):
        with benchmark_fixture.Server() as server:
            self.assertTrue(server.start_url("s", mark=True).endswith("/start?id=s&mark=1"))
            page = urllib.request.urlopen(server.start_url("s", mark=True)).read().decode()
            for fragment in ("report('shown')", "navigator.sendBeacon(`/beacon?event=freeze", "report('resume')",
                             "report('marked')", f"performance.now() + {benchmark_fixture.MARK_MS}"):
                self.assertIn(fragment, page)
            request = urllib.request.Request(f"http://127.0.0.1:{server.port}/beacon?event=freeze&id=s",
                                             data=b"", method="POST")
            urllib.request.urlopen(request).read()
            self.assertIsNotNone(server.beacons.wait("freeze", "s", 1))

    def test_a_page_is_frozen_while_its_last_lifecycle_beacon_is_freeze(self):
        beacons = benchmark_fixture.Beacons()
        beacons.record("freeze", "1")
        beacons.record("freeze", "2")
        beacons.record("resume", "2")
        beacons.record("freeze", "3")
        beacons.record("resume", "3")
        beacons.record("freeze", "3")
        self.assertEqual(beacons.frozen(["1", "2", "3", "4"]), (2, 3))

    def test_a_burst_of_connections_is_queued_not_reset(self):
        # Before the server accepts anything, as when its accept loop falls behind a burst of
        # background tabs or restored tabs' icons. A backlog of 5 reset all but the first few.
        server = benchmark_fixture.Server()
        connections = []
        try:
            for _ in range(60):
                connection = socket.socket()
                connection.setblocking(False)
                connection.connect_ex(("127.0.0.1", server.port))
                connections.append(connection)
            time.sleep(0.2)
            refused = 0
            for connection in connections:
                try:
                    connection.send(b"GET /beacon?event=loaded&id=1 HTTP/1.0\r\n\r\n")
                except OSError:
                    refused += 1
            self.assertEqual(refused, 0)
        finally:
            for connection in connections:
                connection.close()
            server.server.server_close()

    def test_pages_send_a_failed_beacon_again(self):
        page = benchmark_fixture.tab_page("1")
        self.assertIn(f"attempt < {benchmark_fixture.BEACON_ATTEMPTS}", page)
        self.assertIn("report(event, attempt + 1)", page)

    def test_a_live_page_keeps_a_websocket_open_until_the_server_notices_its_end(self):
        tick = benchmark_fixture.LIVE_TICK
        benchmark_fixture.LIVE_TICK = 0.05
        try:
            with benchmark_fixture.Server() as server:
                self.assertEqual(server.tab_url(12, "arx", live=True), f"http://t12.localhost:{server.port}/tab/12?run=arx&live=1")
                self.assertTrue(server.tab_url(3, live=True).endswith("/tab/3?live=1"))
                base = f"http://127.0.0.1:{server.port}/tab/4?run=arx"
                self.assertIn("new WebSocket(`ws://${location.host}/socket?id=${id}`)",
                              urllib.request.urlopen(base + "&live=1").read().decode())
                self.assertNotIn("WebSocket", urllib.request.urlopen(base).read().decode())
                connection = socket.create_connection(("127.0.0.1", server.port), timeout=5)
                connection.sendall(b"GET /socket?id=arx-4 HTTP/1.1\r\nHost: t4.localhost\r\nUpgrade: websocket\r\n"
                                   b"Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                                   b"Sec-WebSocket-Version: 13\r\n\r\n")
                reply = b""
                while b"tick 1" not in reply:
                    reply += connection.recv(4096)
                # RFC 6455's own example key and answer, as HTTP/1.1: Chromium rejects a 1.0 upgrade.
                self.assertTrue(reply.startswith(b"HTTP/1.1 101 "))
                self.assertIn(b"Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", reply)
                self.assertEqual(server.beacons.connections(["arx-4", "arx-5"]), (1, 1))
                connection.close()
                self.assertIsNotNone(server.beacons.wait("socket-closed", "arx-4", 5))
                self.assertEqual(server.beacons.connections(["arx-4"]), (0, 1))
        finally:
            benchmark_fixture.LIVE_TICK = tick

    def test_run_tag_keeps_browsers_apart_and_pages_report_load_before_paint(self):
        with benchmark_fixture.Server() as server:
            page = urllib.request.urlopen(server.tab_url(3, "chrome10").replace("t3.localhost", "127.0.0.1")).read().decode()
            self.assertIn('data-id="chrome10-3"', page)
            self.assertLess(page.index("report('loaded')"), page.index("report('ready')"))


class ProcessMetricsTests(unittest.TestCase):
    def test_reads_own_counters_and_cpu_advances(self):
        before = process_metrics.usage(os.getpid())
        self.assertGreater(before.footprint, 0)
        # Spin for 0.2 s of this process's CPU time, however busy the Mac is.
        cpu_start, wall_start = time.process_time(), time.monotonic()
        while time.process_time() - cpu_start < 0.2 and time.monotonic() - wall_start < 10:
            pass
        after = process_metrics.usage(os.getpid())
        self.assertGreater(after.cpu_seconds - before.cpu_seconds, 0.1)
        self.assertLess(after.cpu_seconds - before.cpu_seconds, time.monotonic() - wall_start + 0.5)

    def test_missing_process_reads_as_none(self):
        self.assertIsNone(process_metrics.usage(999_999))

    def test_a_tree_whose_browser_exited_is_a_failure_not_an_empty_sample(self):
        with self.assertRaises(ValueError):
            process_metrics.sample_tree(999_999)
        self.assertIn(os.getpid(), process_metrics.sample_tree(os.getpid()).processes)

    def test_role_comes_from_the_command_line(self):
        role = process_metrics.role
        self.assertEqual(role("/x/Arx Helper (Renderer).app/Contents/MacOS/Arx Helper (Renderer) --type=renderer --foo"),
                         "renderer")
        self.assertEqual(role("/x/Helper (Renderer) --type=renderer --extension-process --renderer-client-id=7"),
                         "extension")
        self.assertEqual(role("/x/Helper (GPU) --type=gpu-process --gpu-preferences=AB"), "gpu")
        self.assertEqual(role("/x/Helper --type=utility --utility-sub-type=network.mojom.NetworkService"), "network")
        self.assertEqual(role("/x/Helper --type=utility --utility-sub-type=storage.mojom.StorageService"), "storage")
        self.assertEqual(role("/x/Helper --type=utility --utility-sub-type=audio.mojom.AudioService"), "audio")
        self.assertEqual(role("/x/Helper --type=utility --utility-sub-type=video_capture.mojom.VideoCaptureService"),
                         "utility:VideoCaptureService")
        self.assertEqual(role("/x/Helper --type=utility"), "utility")
        self.assertEqual(role("/usr/bin/osascript -l JavaScript"), "other")
        self.assertEqual(process_metrics.switches("/a b/c --x=1 --flag --y=a=b"), {"x": "1", "flag": "", "y": "a=b"})

    def test_role_order_puts_the_browser_first_and_utilities_by_name(self):
        names = ["utility:Zed", "extension", "browser", "other", "renderer", "utility:Alpha", "gpu", "network"]
        self.assertEqual(sorted(names, key=process_metrics.role_order),
                         ["browser", "gpu", "network", "renderer", "extension", "utility:Alpha", "utility:Zed", "other"])

    def test_costs_per_process_type(self):
        def usage(cpu, wakeups, footprint=2**20):
            return process_metrics.Usage(footprint, 1, cpu, wakeups, 0, 0)

        before = process_metrics.TreeSample({1: ("browser", usage(1.0, 10)), 2: ("renderer", usage(2.0, 0)),
                                             3: ("renderer", usage(1.0, 0))})
        after = process_metrics.TreeSample({1: ("browser", usage(1.5, 30, 3 * 2**20)), 2: ("renderer", usage(3.0, 10)),
                                            3: ("renderer", usage(1.0, 10)), 4: ("extension", usage(0.2, 5))})
        table = process_metrics.by_role(before, after, 10)
        self.assertEqual(list(table), ["browser", "renderer", "extension"])
        self.assertAlmostEqual(table["browser"]["cpu_percent"], 5.0)
        self.assertAlmostEqual(table["browser"]["footprint_mb"], 3.0)
        self.assertEqual(table["renderer"]["processes"], 2)
        self.assertAlmostEqual(table["renderer"]["cpu_percent"], 10.0)
        self.assertAlmostEqual(table["renderer"]["wakeups_per_second"], 2.0)
        self.assertAlmostEqual(table["extension"]["cpu_percent"], 2.0)

    def test_delta_counts_new_processes_from_zero_and_drops_exited_ones(self):
        def usage(cpu, wakeups, written):
            return process_metrics.Usage(1, 1, cpu, wakeups, written, 0)

        before = process_metrics.TreeSample({1: ("browser", usage(1.0, 10, 100)), 2: ("renderer", usage(5.0, 0, 0))})
        after = process_metrics.TreeSample({1: ("browser", usage(1.5, 30, 300)), 3: ("renderer", usage(0.5, 10, 50))})
        result = process_metrics.delta(before, after, 10)
        self.assertAlmostEqual(result["cpu_percent"], 10.0)
        self.assertAlmostEqual(result["wakeups_per_second"], 3.0)
        self.assertEqual(result["bytes_written"], 250)

    def test_continuous_clock_runs_with_monotonic_and_never_behind_it(self):
        # time.monotonic() is Mach absolute time on macOS; the continuous clock adds time asleep.
        first = process_metrics.continuous_seconds() - time.monotonic()
        time.sleep(0.05)
        second = process_metrics.continuous_seconds() - time.monotonic()
        self.assertGreaterEqual(first, -0.01)
        self.assertAlmostEqual(first, second, delta=0.01)


class LaunchClockTests(unittest.TestCase):
    """DEV-939: signposts are stamped on the continuous clock, which runs on while the Mac sleeps."""

    class Marks:
        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

        def offsets(self, pid, begun):
            self.begun = begun
            return {"ProcessStart": 0.1}

    class Launched(benchmark.Browser):
        def launch(self, url):
            self.process = type("Process", (), {"pid": 7})()

        def launch_marks(self):
            return self.marks

    def test_marks_are_offsets_from_the_continuous_clock_at_exec(self):
        slept = 32661.0
        server = type("Server", (), {})()
        server.start_url = lambda identifier, mark=False: "http://127.0.0.1/start"
        server.beacons = benchmark_fixture.Beacons()
        browser = self.Launched(None, None, server, None)
        browser.marks = self.Marks()
        original = process_metrics.continuous_seconds
        process_metrics.continuous_seconds = lambda: time.monotonic() + slept
        try:
            exec_monotonic = time.monotonic()
            threading.Timer(0.05, server.beacons.record, args=("ready", "start")).start()
            browser.timed_launch("first", timeout=2)
        finally:
            process_metrics.continuous_seconds = original
        self.assertAlmostEqual(browser.marks.begun, exec_monotonic + slept, delta=0.05)
        self.assertEqual(browser.last_marks, {"ProcessStart": 0.1})


class ReportTests(unittest.TestCase):
    def test_table_has_a_column_per_browser_and_names_skipped_ones(self):
        results = {
            "started": "2026-11-09T05:00:00+00:00",
            "machine": {"model": "Mac16,8", "chip": "Apple M4 Pro", "cores": 14, "memory": "48 GB",
                        "macos": "27.3", "power": "AC", "commit": "abc1234", "dirty": False},
            "browsers": {
                "Arx": {"version": "1.0 (1)", "first_launch_s": 1.234,
                        "warm_launch_s": {"median": 0.5},
                        "tabs": {"steps": [{"tabs": 10, "footprint_mb": 900.4, "renderers": 10}]}},
                "Chrome": {"skipped": "not installed"},
            },
        }
        text = benchmark.report(results)
        self.assertIn("| Measure | Arx | Chrome |", text)
        self.assertIn("| First launch, new profile → page usable | 1.23 s | – |", text)
        self.assertIn("| 10 tabs: memory | 900 MB | – |", text)
        self.assertNotIn("100 tabs: memory", text)
        self.assertIn("Chrome: skipped (not installed)", text)

    def test_tab_rows_follow_the_measured_counts(self):
        results = {"started": "2026-11-09T05:00:00+00:00",
                   "machine": {"model": "M", "chip": "C", "cores": 1, "memory": "1 GB", "macos": "27",
                               "power": "AC", "commit": "x", "dirty": False},
                   "browsers": {"Arx": {"tabs": {"steps": [{"tabs": 20, "footprint_mb": 1.0},
                                                           {"tabs": 200, "footprint_mb": 2.0}]}}}}
        text = benchmark.report(results)
        self.assertIn("| 20 tabs: memory | 1 MB |", text)
        self.assertIn("| 200 tabs: memory | 2 MB |", text)

    def test_open_tab_rows_show_the_command_apart_from_its_inventory_read(self):
        results = {"started": "2026-11-14T05:00:00+00:00",
                   "machine": {"model": "M", "chip": "C", "cores": 1, "memory": "1 GB", "macos": "27",
                               "power": "AC", "commit": "x", "dirty": False},
                   "browsers": {"Arx": {"tabs": {"steps": [{"tabs": 100, "open_command_ms": {"median": 150.0},
                                                            "open_receipt_ms": {"median": 40.0}}]}}}}
        text = benchmark.report(results)
        self.assertIn("| 100 tabs: openTab via MCP (median) | 150 ms |", text)
        self.assertIn("| 100 tabs: openTab via MCP, command alone (median) | 40 ms |", text)

    def test_engine_version_comes_from_the_measured_app(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Arx.app"
            versions = app / "Contents/Frameworks/Arx Framework.framework/Versions"
            (versions / "150.0.1.2").mkdir(parents=True)
            (versions / "Current").symlink_to("150.0.1.2")
            self.assertEqual(benchmark.engine_version(app), "Chromium 150.0.1.2")
            self.assertIsNone(benchmark.engine_version(Path(directory) / "Missing.app"))

    def test_launch_marks_are_offsets_from_exec_in_the_measured_process(self):
        tick = process_metrics.TICKS_TO_SECONDS
        begun = 1000.0
        lines = [
            'Filtering the log data using "subsystem == ..."\n',
            json.dumps({"processID": 7, "signpostName": "ProcessStart", "machTimestamp": round(1000.1 / tick)}),
            json.dumps({"processID": 8, "signpostName": "WindowShown", "machTimestamp": round(1000.2 / tick)}),
            json.dumps({"processID": 7, "signpostName": "WindowShown", "machTimestamp": round(1000.5 / tick)}),
            json.dumps({"processID": 7, "signpostName": "WindowShown", "machTimestamp": round(1009.0 / tick)}),
            json.dumps({"processID": 7, "signpostName": "SidebarRow.body", "machTimestamp": round(1000.6 / tick)}),
        ]
        offsets = benchmark.launch_offsets(lines, 7, begun)
        self.assertEqual(set(offsets), {"ProcessStart", "WindowShown"})
        self.assertAlmostEqual(offsets["ProcessStart"], 0.1, places=4)
        self.assertAlmostEqual(offsets["WindowShown"], 0.5, places=4)
        warm = benchmark.marks_summary([{"ProcessStart": 0.1, "WindowShown": 0.4}, {"ProcessStart": 0.3}])
        self.assertEqual(warm["ProcessStart"]["median"], 0.2)
        self.assertEqual(warm["WindowShown"]["n"], 1)
        self.assertNotIn("FirstPagePainted", warm)
        self.assertEqual(benchmark.marks({"ProcessStart": 0.1, "WindowShown": 0.5}), "0.10 / 0.50 / – s")

    def test_page_renderer_is_the_busy_one_and_the_rest_are_named(self):
        def usage(cpu):
            return process_metrics.Usage(2**20, 1, cpu, 0, 0, 0)

        before = process_metrics.TreeSample({1: ("browser", usage(1)), 2: ("renderer", usage(1)),
                                             3: ("renderer", usage(1)), 4: ("extension", usage(1))})
        after = process_metrics.TreeSample({1: ("browser", usage(2)), 2: ("renderer", usage(1.01)),
                                            3: ("renderer", usage(1.38)), 4: ("extension", usage(3))},
                                           {3: "/x --type=renderer --renderer-client-id=5"})
        self.assertEqual(benchmark.busiest_renderer(before, after, 0.2), 3)
        self.assertIsNone(benchmark.busiest_renderer(before, after, 0.5))
        listing = benchmark.process_listing(before, after, 10, 3)
        self.assertEqual([row["name"] for row in listing],
                         ["browser", "renderer without a page (spare)", "start page renderer", "extension renderer"])
        self.assertEqual(listing[2]["renderer_client_id"], "5")
        self.assertAlmostEqual(listing[3]["cpu_percent"], 20.0)

    def test_installed_extensions_are_named_from_preferences_or_manifests(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for profile in ("Default", "Private"):
                (root / profile).mkdir()
            unpacked = root / "Default/Extensions/abc/1.0"
            (unpacked / "_locales/en").mkdir(parents=True)
            (unpacked / "manifest.json").write_text(json.dumps(
                {"name": "__MSG_extName__", "default_locale": "en", "background": {"page": "background.html"}}))
            (unpacked / "_locales/en/messages.json").write_text(json.dumps({"extName": {"message": "uBlock Origin"}}))
            (root / "Default/Preferences").write_text(json.dumps({"extensions": {"settings": {
                "abc": {"path": "abc/1.0", "location": 1, "state": 1},
                "mhjfbmdgcfjbbpaeojofohoefgiehjai": {"location": 5},
            }}}))
            (root / "Private/Secure Preferences").write_text(json.dumps({"extensions": {"settings": {
                "xyz": {"location": 1, "state": 0, "manifest": {"name": "Worker", "background": {"service_worker": "w.js"}}},
            }}}))
            (root / "Broken").mkdir()
            (root / "Broken/Preferences").write_text("{")
            found = {(item["profile"], item["id"]): item for item in benchmark.installed_extensions(root)}
        self.assertEqual(found[("Default", "abc")]["name"], "uBlock Origin")
        self.assertEqual(found[("Default", "abc")]["background"], "page")
        self.assertTrue(found[("Default", "abc")]["enabled"])
        self.assertEqual(found[("Default", "mhjfbmdgcfjbbpaeojofohoefgiehjai")]["name"], "Chromium PDF Viewer")
        self.assertEqual(found[("Private", "xyz")]["background"], "service worker")
        self.assertFalse(found[("Private", "xyz")]["enabled"])
        self.assertEqual(len(found), 3)

    def test_report_has_native_rows_freezing_and_per_process_tables(self):
        role = {"processes": 1, "footprint_mb": 100.0, "cpu_percent": 1.5, "wakeups_per_second": 20.0,
                "bytes_written": 0}
        results = {"started": "2026-11-13T05:00:00+00:00", "options": {"fixture_hosts": "same-site"},
                   "machine": {"model": "M", "chip": "C", "cores": 1, "memory": "1 GB", "macos": "27",
                               "power": "AC", "commit": "x", "dirty": False},
                   "browsers": {"Arx": {
                       "launch_marks": {"first": {"ProcessStart": 0.05, "WindowShown": 0.6, "FirstPagePainted": 0.9},
                                        "warm": {"ProcessStart": {"median": 0.04}}},
                       "idle_one_tab": {"renderers": 4, "extension_renderers": 2,
                                        "by_role": {"browser": role, "extension": {**role, "processes": 2}},
                                        "process_listing": [{"pid": 9, "name": "extension renderer", "footprint_mb": 50.0,
                                                             "cpu_percent": 0.1, "wakeups_per_second": 3.0}],
                                        "extensions": [{"profile": "Default", "name": "uBlock Origin",
                                                        "background": "page", "enabled": True}]},
                       "native": {"steps": [{"tabs": 10, "new_tab_ms": {"median": 120.0},
                                             "command_bar_ms": {"median": 30.0}, "footprint_mb": 900.0,
                                             "renderers": 8, "extension_renderers": 2,
                                             "switch": {"shown_ms": {"median": 40.0}, "shown_reported": 30},
                                             "idle": {"cpu_percent": 2.0, "by_role": {"renderer": role}}}],
                                  "freezing": {"waited_s": 390, "pages": 10, "frozen": 4, "ever_frozen": 5,
                                               "footprint_mb": 800.0, "idle": {"cpu_percent": 1.0, "by_role": {"gpu": role}}}},
                   }}}
        text = benchmark.report(results)
        self.assertIn("one site (`t<N>.arx-bench.test`)", text)
        self.assertIn("| First launch: exec → process start / window shown / first paint | 0.05 / 0.60 / 0.90 s |", text)
        self.assertIn("(medians) | 0.04 / – / – s |", text)
        self.assertIn("| Idle, 1 tab: renderers (extension) | 4 (2) |", text)
        self.assertIn("| 10 tabs, windowed: new tab, ⌘T → page ready (median) | 120 ms |", text)
        self.assertIn("| 10 tabs, windowed: switch, ⌃Tab → page shown (median) | 40 ms |", text)
        self.assertIn("| 10 tabs, windowed: renderers (extension) | 8 (2) |", text)
        self.assertIn("| Frozen pages after the freeze wait (ever frozen) | 4 of 10 (5) |", text)
        self.assertIn("## Arx: cost per process type", text)
        self.assertIn("| Idle, 1 tab | extension | 2 | 100 MB | 1.5% | 20/s |", text)
        self.assertIn("| 10 tabs, windowed | renderer |", text)
        self.assertIn("| After 390 s | gpu |", text)
        self.assertIn("| 9 | extension renderer | 50 MB | 0.1% | 3/s |", text)
        self.assertIn("uBlock Origin (Default, background page)", text)

    def test_per_process_tables_say_how_each_browser_opened_its_tabs(self):
        role = {"processes": 3, "footprint_mb": 10.0, "cpu_percent": 0.5, "wakeups_per_second": 4.0,
                "bytes_written": 0}
        step = {"tabs": 10, "idle": {"by_role": {"renderer": role}}}
        results = {"started": "2026-11-13T05:00:00+00:00",
                   "machine": {"model": "M", "chip": "C", "cores": 1, "memory": "1 GB", "macos": "27",
                               "power": "AC", "commit": "x", "dirty": False},
                   "browsers": {"Arx": {"tabs": {"steps": [step]}}, "Chrome": {"tabs": {"steps": [step]}}}}
        text = benchmark.report(results)
        self.assertIn("## Arx: cost per process type", text)
        self.assertIn("| 10 tabs, headless | renderer | 3 |", text)
        self.assertIn("## Chrome: cost per process type", text)
        self.assertIn("| 10 tabs, command line | renderer | 3 |", text)

    def test_incomplete_tab_steps_are_marked_in_the_report(self):
        results = {"started": "2026-11-13T05:00:00+00:00",
                   "machine": {"model": "M", "chip": "C", "cores": 1, "memory": "1 GB", "macos": "27",
                               "power": "AC", "commit": "x", "dirty": False},
                   "browsers": {"Arx": {"tabs": {"steps": [{"tabs": 10, "loaded": 10, "footprint_mb": 1.0},
                                                           {"tabs": 50, "loaded": 37, "footprint_mb": 2.0}]}}}}
        text = benchmark.report(results)
        self.assertIn("| 10 tabs: pages loaded | 10 of 10 |", text)
        self.assertIn("| 50 tabs: pages loaded | 37 of 50 |", text)
        self.assertIn("Arx, 50 tabs: only 37 pages loaded", text)
        self.assertNotIn("Arx, 10 tabs: only", text)

    def test_inventory_starts_again_when_a_cursor_goes_stale(self):
        class Client:
            def __init__(self):
                self.replies = iter([{"items": [{"id": "old"}], "nextCursor": "c"}, {"code": "staleCursor"},
                                     {"items": [{"id": "new"}]}])

            def call(self, *_):
                return {}, next(self.replies)

        from unittest import mock
        with mock.patch.object(benchmark.time, "sleep"):
            self.assertEqual(benchmark.inventory(Client()), [{"id": "new"}])

    def test_a_failed_warm_launch_keeps_what_was_measured_before_it(self):
        from types import SimpleNamespace
        from unittest import mock

        class Stub(benchmark.Browser):
            launches = 0

            def timed_launch(self, label, timeout=90):
                self.launches += 1
                if self.launches == 3:
                    raise ValueError(f"{label} never reported ready")
                self.last_marks = {"ProcessStart": 0.1}
                return float(self.launches)

            def idle(self, seconds, listing=False):
                return {"footprint_mb": 1.0}

            def stop(self, timeout=30):
                pass

        browser = Stub(None, None, None, SimpleNamespace(idle=1, launches=5))
        with mock.patch.object(benchmark.time, "sleep"), self.assertRaises(ValueError):
            browser.launch_series()
        self.assertEqual(browser.partial["first_launch_s"], 1.0)
        self.assertEqual(browser.partial["idle_one_tab"]["footprint_mb"], 1.0)
        self.assertEqual(browser.partial["warm_launch_s"]["values"], [2.0])
        self.assertEqual(browser.partial["launch_marks"]["warm"]["ProcessStart"]["n"], 1)

    def test_native_control_tab_is_next_tab_not_the_recent_tab_switcher(self):
        # The switcher picks when ⌃ is let go, which the driver's key events never do (DEV-544).
        self.assertEqual(benchmark.ARX_ENVIRONMENT["ARX_RECENT_TAB_SWITCHER"], "0")

    def test_slow_native_switches_are_counted_not_dropped(self):
        self.assertEqual(benchmark.switch_cell({"shown_ms": {"median": 40.0}, "shown_reported": 27, "missed": 3}),
                         "40 ms (3 of 30 over 3 s)")
        self.assertEqual(benchmark.switch_cell({"shown_ms": {"median": 40.0}, "shown_reported": 30, "missed": 0}),
                         "40 ms")
        self.assertEqual(benchmark.switch_cell(None), "–")

    def test_a_failed_quit_request_still_ends_the_process(self):
        import subprocess
        import sys
        from types import SimpleNamespace

        class Stub(benchmark.Browser):
            def quit(self):
                raise subprocess.TimeoutExpired("osascript", 20)

        browser = Stub(None, None, None, SimpleNamespace())
        browser.process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        browser.stop(timeout=0.1)
        self.assertIsNotNone(browser.process.poll())

    def test_the_benchmark_builds_apart_from_other_builds(self):
        from unittest import mock
        from Scripts import build_app
        with mock.patch.object(build_app, "main", return_value="/tmp/Arx.app") as main:
            benchmark.build("Release")
        options = main.call_args.kwargs
        self.assertEqual(options["derived_data"].name, "BenchmarkDerivedData")
        self.assertIn(f"SYMROOT={options['derived_data'] / 'Build/Products'}", options["build_settings"])
        self.assertTrue(options["signed"])

    def test_driver_matches_replies_to_commands_and_ignores_other_output(self):
        import subprocess
        import sys
        echo = ("import json, sys\n"
                "print('Chromium noise', flush=True)\n"
                "for line in sys.stdin:\n"
                "    command = json.loads(line)\n"
                "    print('ARX_BENCHMARK_DRIVER ' + json.dumps({'id': command['id'] - 1, 'ok': False}), flush=True)\n"
                "    print('ARX_BENCHMARK_DRIVER ' + json.dumps({'id': command['id'], 'ok': command['action'] == 'key',"
                " 'echo': command}), flush=True)\n")
        process = subprocess.Popen([sys.executable, "-c", echo], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        try:
            driver = benchmark.Driver(process)
            driver.key("tab", "\t", "control")
            reply = driver.send("key", keyCode=17, characters="t", modifiers=["command"])
            self.assertEqual(reply["echo"]["keyCode"], 17)
            with self.assertRaises(ValueError):
                driver.require("insertText", text="x")
        finally:
            process.stdin.close()
            process.wait(timeout=5)
            process.stdout.close()

    def test_patched_environment_restores_what_was_there(self):
        os.environ.pop("ARX_BENCHMARK_TEST_A", None)
        os.environ["ARX_BENCHMARK_TEST_B"] = "old"
        with benchmark.patched_environment({"ARX_BENCHMARK_TEST_A": "1", "ARX_BENCHMARK_TEST_B": "new"}):
            self.assertEqual(os.environ["ARX_BENCHMARK_TEST_A"], "1")
            self.assertEqual(os.environ["ARX_BENCHMARK_TEST_B"], "new")
        self.assertNotIn("ARX_BENCHMARK_TEST_A", os.environ)
        self.assertEqual(os.environ.pop("ARX_BENCHMARK_TEST_B"), "old")

    def test_options(self):
        options = benchmark.parse(["--tabs", "50,10,50", "--launches", "2"])
        self.assertEqual(options.tabs, [10, 50])
        self.assertEqual(options.launches, 2)
        self.assertEqual((options.fixture_hosts, options.freeze_wait, options.skip_native), ("loopback", 390, False))
        self.assertEqual(benchmark.parse(["--fixture-hosts", "same-site"]).fixture_hosts, "same-site")
        self.assertEqual((options.live_connections, benchmark.parse(["--live-connections", "0.2"]).live_connections),
                         (0.0, 0.2))
        with self.assertRaises(SystemExit):
            benchmark.parse(["--live-connections", "1.5"])

    def test_the_headless_profile_warms_up_by_default(self):
        # Past uBlock's selfie, about 150 s into a new profile (DEV-682).
        self.assertEqual(benchmark.WARMUP_S, 180)
        self.assertEqual(benchmark.parse([]).warmup, benchmark.WARMUP_S)
        self.assertEqual(benchmark.parse(["--no-warmup"]).warmup, 0)
        self.assertEqual(benchmark.parse(["--quick"]).warmup, 5)
        self.assertEqual(benchmark.parse(["--quick", "--no-warmup"]).warmup, 0)

    def test_warm_up_opens_one_tab_waits_and_closes_it(self):
        from types import SimpleNamespace
        from unittest import mock

        class Client:
            def __init__(self):
                self.commands = []

            def call(self, tool, arguments):
                if tool == "browser_inventory":
                    return {}, {"items": [{"id": "space", "kind": "space", "revision": 1},
                                          {"id": "tab", "kind": "tab", "revision": 2}]}
                self.commands.append((arguments["action"], arguments["targetID"], arguments.get("url")))
                return {}, {"kind": "committed", "targetID": "tab"}

        with benchmark_fixture.Server() as server:
            logged = []
            arx = SimpleNamespace(server=server, options=SimpleNamespace(warmup=0.3), log=logged.append)
            headless, client = benchmark.Headless(arx), Client()
            server.beacons.record("loaded", "warmup-1")
            with mock.patch.object(benchmark.time, "sleep") as sleep:
                result = headless.warm_up(client)
            self.assertEqual([command[:2] for command in client.commands], [("openTab", "space"), ("closeTab", "tab")])
            self.assertIn("/tab/1?run=warmup", client.commands[0][2])
            self.assertGreater(sleep.call_args[0][0], 0.2)  # what's left of the warm-up after opening
            self.assertEqual((result["tab_loaded"], result["tab_closed"]), (True, True))
            self.assertIn("duration_s", result)
            arx.options.warmup = 0
            self.assertIsNone(headless.warm_up(client))
            self.assertEqual(logged, [])

    def test_a_warm_up_tab_that_stays_open_is_reported_not_a_failure(self):
        from types import SimpleNamespace

        class Client:
            def call(self, tool, arguments):
                if tool == "browser_inventory":
                    return {}, {"items": [{"id": "space", "kind": "space", "revision": 1},
                                          {"id": "tab", "kind": "tab", "revision": 2}]}
                if arguments["action"] == "closeTab":
                    return {"isError": True}, {"kind": "error", "code": "staleTarget"}
                return {}, {"kind": "committed", "targetID": "tab"}

        with benchmark_fixture.Server() as server:
            logged = []
            arx = SimpleNamespace(server=server, options=SimpleNamespace(warmup=0.01), log=logged.append)
            result = benchmark.Headless(arx).warm_up(Client())
        self.assertFalse(result["tab_closed"])
        self.assertIn("didn't close", logged[0])

    def test_restore_leaves_out_the_warm_up_tab(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "arx-workspace.json"
            workspace.write_text(json.dumps({"organization": {"tabs": [], "spaces": [{"profileID": "p"}]}}))
            headless = {"organization": {"tabs": [
                {"restoration": {"url": "http://t1.localhost:1/tab/1?run=warmup"}},
                {"restoration": {"url": "http://t1.localhost:1/tab/1?run=arx"}}]}}
            self.assertEqual(benchmark.merge_tabs(workspace, headless), 1)

    def test_report_shows_the_warm_up_or_says_there_was_none(self):
        machine = {"model": "M", "chip": "C", "cores": 1, "memory": "1 GB", "macos": "27", "power": "AC",
                   "commit": "x", "dirty": False}
        warmed = {"started": "2026-11-14T05:00:00+00:00", "options": {"warmup": 180}, "machine": machine,
                  "browsers": {"Arx": {"tabs": {"warmup": {"duration_s": 180.4}, "steps": []}}}}
        self.assertIn("| Headless warm-up before the tab steps | 180.40 s |", benchmark.report(warmed))
        cold = {**warmed, "options": {"warmup": 0}, "browsers": {"Arx": {"tabs": {"warmup": None, "steps": []}}}}
        text = benchmark.report(cold)
        self.assertIn("No headless warm-up (`--no-warmup`)", text)
        self.assertNotIn("| Headless warm-up before the tab steps |", text)

    def test_live_tabs_are_spread_evenly_through_every_count(self):
        self.assertEqual([index for index in range(1, 21) if benchmark.live_tab(index, 0.2)], [5, 10, 15, 20])
        self.assertEqual(sum(benchmark.live_tab(index, 0.3) for index in range(1, 11)), 3)
        self.assertEqual(sum(benchmark.live_tab(index, 0.3) for index in range(1, 101)), 30)
        self.assertFalse(any(benchmark.live_tab(index, 0) for index in range(1, 101)))
        self.assertTrue(all(benchmark.live_tab(index, 1) for index in range(1, 101)))

    def test_only_the_engines_feature_flags_are_recorded(self):
        flags = benchmark.feature_flags({"ARX_SPARE_LIVE_CONNECTIONS": "off", "ARX_TOKEN": "secret", "HOME": "/"})
        self.assertEqual(flags, {"ARX_SPARE_LIVE_CONNECTIONS": "off"})

    def test_report_counts_live_pages_apart_and_names_the_feature_flags(self):
        results = {"started": "2026-11-14T05:00:00+00:00", "options": {"live_connections": 0.2},
                   "feature_flags": {"ARX_SPARE_LIVE_CONNECTIONS": "off"},
                   "machine": {"model": "M", "chip": "C", "cores": 1, "memory": "1 GB", "macos": "27",
                               "power": "AC", "commit": "x", "dirty": False},
                   "browsers": {"Arx": {"native": {"steps": [], "freezing": {
                       "waited_s": 390, "pages": 50, "frozen": 45, "ever_frozen": 50, "footprint_mb": 1.0,
                       "live": {"pages": 10, "frozen": 9, "ever_frozen": 10, "connected": 1, "ever_connected": 10}}}}}}
        text = benchmark.report(results)
        self.assertIn("20% of the tabs kept a WebSocket open", text)
        self.assertIn("Feature flags from the environment: `ARX_SPARE_LIVE_CONNECTIONS=off`.", text)
        self.assertIn("| Live pages frozen after the freeze wait (ever frozen) | 9 of 10 (10) |", text)
        self.assertIn("| Live pages still connected after the freeze wait | 1 of 10 |", text)

    def test_quick_runs_every_step_briefly_and_says_so(self):
        options = benchmark.parse(["--quick"])
        self.assertEqual((options.launches, options.idle, options.tabs, options.switches, options.freeze_wait),
                         (1, 5, [3], 3, 20))
        self.assertTrue(options.skip_chrome)
        results = {"started": "2026-11-13T05:00:00+00:00", "options": vars(options),
                   "machine": {"model": "M", "chip": "C", "cores": 1, "memory": "1 GB", "macos": "27",
                               "power": "AC", "commit": "x", "dirty": False},
                   "browsers": {"Arx": {"first_launch_s": 1.0}}}
        self.assertIn("Quick run", benchmark.report(results))


if __name__ == "__main__":
    unittest.main()
