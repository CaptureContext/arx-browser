"""Bound owned fixture evidence; native pixel/state execution is a separate gate."""

import concurrent.futures
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import urlopen
import uuid

from Scripts.core import document_capture_fixture as fixture
from Scripts.engine import document_capture_prototype as prototype


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if not fixture.serve(self):
            self.send_error(404)

    def log_message(self, *_):
        pass


class DocumentCaptureFixtureTests(unittest.TestCase):
    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.origin = "http://127.0.0.1:" + str(self.server.server_port)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def get(self, path):
        try:
            with urlopen(self.origin + path, timeout=2) as result:
                return result.status, result.read()
        except HTTPError as error:
            return error.code, error.read()

    @staticmethod
    def evidence(sample=1):
        values = {key: 0 for key in fixture.COUNTS | fixture.NUMBERS | fixture.FLAGS}
        values.update(sample=sample, viewportWidth=1000, viewportHeight=700, layoutWidth=985,
                      documentWidth=1000, documentHeight=2400, scrollY=550,
                      deviceScale=2, visualScale=1, ready=1, focused=1,
                      selectionEnd=1)
        return values

    def main(self):
        run = str(uuid.uuid4())
        status, body = self.get("/document-capture/main?" + urlencode({"run": run, "mode": "plain"}))
        self.assertEqual(status, 200)
        self.assertIn(b"background:rgb(255,0,0)", body)
        self.assertIn(b"scrollTo(0,550)", body)
        return run

    def test_state_is_owned_bounded_monotonic_and_value_free(self):
        run = self.main()
        prefix = "/document-capture/"
        self.assertEqual(self.get(prefix + "state/" + run)[0], 404)
        values = self.evidence()
        self.assertEqual(self.get(prefix + "report/" + run + "?" + urlencode(values))[0], 204)
        status, body = self.get(prefix + "state/" + run)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["documentHeight"], 2400)
        self.assertEqual(self.get(prefix + "report/" + run + "?" + urlencode(values))[0], 400)
        for field, value in (("scrollX", "nan"), ("deviceScale", "inf"), ("sample", 10001),
                             ("frames", 2), ("secret", "do not retain")):
            bad = self.evidence(sample=2)
            bad[field] = value
            self.assertEqual(self.get(prefix + "report/" + run + "?" + urlencode(bad))[0], 400)
        self.assertEqual(json.loads(self.get(prefix + "state/" + run)[1])["sample"], 1)

    def test_routes_and_frame_command_cannot_target_profile_files_or_other_runs(self):
        run = self.main()
        prefix = "/document-capture/"
        self.assertEqual(json.loads(self.get(prefix + "poll/" + run)[1]), {"command": "none"})
        self.assertEqual(self.get(prefix + "command/" + run + "?action=add-frame")[0], 204)
        self.assertEqual(json.loads(self.get(prefix + "poll/" + run)[1]), {"command": "add-frame"})
        for path in ("/profile/Default/Preferences", "/", "/.arx-engine-smoke",
                     prefix + "frame?run=" + str(uuid.uuid4()),
                     prefix + "command/" + run + "?action=arbitrary",
                     prefix + "main?run=" + run + "&mode=plain"):
            self.assertIn(self.get(path)[0], (404, 409))
        self.assertEqual(self.get(prefix + "frame?run=" + run)[0], 200)
        self.assertEqual(self.get(prefix + "destination?run=" + run)[0], 200)

    def test_run_admission_has_a_fixed_capacity_and_rejects_malformed_queries(self):
        for _ in range(fixture.MAXIMUM_RUNS):
            self.main()
        self.assertEqual(self.get("/document-capture/main?run=" + str(uuid.uuid4()) + "&mode=plain")[0], 409)
        for query in ("run=bad&mode=plain", "run=" + str(uuid.uuid4()) + "&mode=arbitrary",
                      "run=" + str(uuid.uuid4()) + "&mode=plain&mode=oversize"):
            self.assertEqual(self.get("/document-capture/main?" + query)[0], 400)

    def test_variants_keep_lazy_requests_visible_and_loading_release_is_a_fixed_command(self):
        run = self.main()
        prefix = "/document-capture/"
        self.get(prefix + "report/" + run + "?" + urlencode(self.evidence()))
        self.assertEqual(json.loads(self.get(prefix + "state/" + run)[1])["lazyRequests"], 0)
        self.assertEqual(self.get(prefix + "lazy/" + run)[0], 404)
        self.assertEqual(json.loads(self.get(prefix + "state/" + run)[1])["lazyRequests"], 1)
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            pending = executor.submit(self.get, prefix + "hold/" + run)
            self.assertEqual(self.get(prefix + "command/" + run + "?action=release-load")[0], 204)
            status, body = pending.result(timeout=3)
            self.assertEqual(status, 200)
            self.assertEqual(body, b"/* owned empty loading fixture */")
        for mode in ("horizontal", "fixed", "sticky", "canvas", "animation", "frame", "lazy", "loading", "zoom"):
            token = str(uuid.uuid4())
            self.assertEqual(self.get(prefix + "main?run=" + token + "&mode=" + mode)[0], 200)
        self.assertEqual(self.get(prefix + "hold/" + str(uuid.uuid4()))[0], 404)
        self.assertEqual(self.get(prefix + "command/" + run + "?action=eval")[0], 404)

    def test_pixel_contract_rejects_viewport_crops_blank_images_and_repeated_bands(self):
        source = r'''
#include <cassert>
#include "fixture_contract.h"
int main() {
 using namespace arx::document::testing;
 for (double scale : {1.0, 2.0, 2.5}) {
   const int band = std::lround(kBandHeight * scale);
   const int height = band * 3;
   const int width = std::lround(900 * scale);
   auto exact = [band](int, int y) { return kColors[y / band]; };
   assert(FullDocumentPixels(width, height, scale, exact));
   assert(!FullDocumentPixels(width, 700, scale, exact));
   assert(!FullDocumentPixels(width, height * 2, scale, exact));
   assert(!FullDocumentPixels(width, height, scale, [](int, int) { return 0xffffffffu; }));
   assert(!FullDocumentPixels(width, height, scale, [band](int, int y) { return kColors[(y % 700) / band]; }));
   assert(!FullDocumentPixels(width, height, scale, [band](int, int y) { return y > band * 2 ? kColors[0] : kColors[y / band]; }));
   assert(GeometryMatchesCSS(width, height, 125.5 * scale, 550 * scale,
       900, 2400, 125.5, 550, scale, scale == 2.5 ? 2 : scale, scale == 2.5 ? 1.25 : 1));
   assert(!GeometryMatchesCSS(width, height, 125.5, 550,
       900, 2400, 125.5, 550, scale, 1, 1.25));
   // Actual fixed/sticky pixel assertion: one correctly mapped document marker,
   // no duplicate at viewport coordinates, no CSS-only or double-scaled placement.
   const int top = std::lround(570 * scale), bottom = top + std::lround(24 * scale);
   auto marker = [top, bottom](int, int y) { return y >= top && y < bottom ? 0xff000000u : kColors[0]; };
   assert(SingleMarkerPixels(width, height, 64, 570, 80, 24, scale, marker));
   assert(!SingleMarkerPixels(width, height, 64, 20, 80, 24, scale, marker));
   assert(!SingleMarkerPixels(width, height, 64, 570 * 2, 80, 24, scale, marker));
   assert(!SingleMarkerPixels(width, height, 64, 570, 80, 24, scale,
       [top, bottom](int, int y) { return (y >= top && y < bottom) || y < bottom - top ? 0xff000000u : kColors[0]; }));
   const auto before = ViewportPixels(width, 700, exact);
   const auto after = ViewportPixels(width, 700, [](int, int) { return kColors[1]; });
   assert(before != after);
 }
 ViewportSamples baseline{}, current{};
 baseline.fill(kColors[0]); current.fill(kColors[0]);
 assert(ObserveRepaint(baseline, current, 0) == RepaintObservation::kPending);
 current.fill(0xff00ffff);
 assert(ObserveRepaint(baseline, current, 999) == RepaintObservation::kReady);
 current.fill(0xff02ffff);  // observed GPU/display readback, 2/255 in red
 assert(ObserveRepaint(baseline, current, 999) == RepaintObservation::kReady);
 current.fill(0xff02fdfd);  // every channel at its explicit 2-LSB boundary
 assert(ObserveRepaint(baseline, current, 1) == RepaintObservation::kReady);
 for (uint32_t rejected : {0xff03ffffu, 0xff00fcffu, 0xff00fffcu,
                           0xfe00ffffu, 0xffffffffu, 0xffff00ffu, 0xffff0000u, 0u}) {
   current.fill(rejected);
   assert(ObserveRepaint(baseline, current, 1) == RepaintObservation::kPending);
 }
 current.fill(0xff02ffff);
 assert(ObserveRepaint(baseline, current, 1000) == RepaintObservation::kTimeout);
 assert(ObserveRepaint(baseline, current, -1) == RepaintObservation::kTimeout);
 current[1] = kColors[0];
 assert(ObserveRepaint(baseline, current, 999) == RepaintObservation::kPending);
 baseline[0] = kColors[1]; current.fill(0xff00ffff);
 assert(ObserveRepaint(baseline, current, 1) == RepaintObservation::kInvalidBaseline);

}
'''
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "pixel.cc").write_text(source)
            compiled = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                "-fsanitize=address,undefined", "-I", str(prototype.PROTOTYPE),
                str(root / "pixel.cc"), "-o", str(root / "pixel"),
            ], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run([str(root / "pixel")], capture_output=True, text=True)
            self.assertEqual(executed.returncode, 0, executed.stderr)
