"""Native menu authority and browser-only coordinate proof; never applies shared overlays."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine import link_context_overlay
from Scripts.engine.config import PACKAGE


class LinkContextTests(unittest.TestCase):
    def test_bounded_coordinates_and_nonreusable_authority(self):
        source = r'''
#include "link_context_policy.h"
#include <cassert>
#include <limits>
int main() {
  arx::LinkContextAuthority authority;
  assert(!authority.Open(1, 2, false, 1, 2, 400, 300));
  for (double value : {-1.0, 400.0, std::numeric_limits<double>::infinity(),
                       std::numeric_limits<double>::quiet_NaN()})
    assert(!authority.Open(1, 2, true, value, 2, 400, 300));
  assert(!authority.Open(0, 2, true, 1, 2, 400, 300));
  assert(!authority.Open(1, 0, true, 1, 2, 400, 300));
  assert(!authority.Open(1, 2, true, 1, 300, 400, 300));
  assert(authority.Open(1, 2, true, 1, 2, 400, 300));
  assert(authority.Current(1, 2, true));
  assert(!authority.Current(1, 3, true));
  assert(!authority.Current(1, 2, false));
  assert(!authority.Dismiss(7));
  assert(authority.Current(1, 2, true));
  assert(authority.Open(2, 2, true, 2, 3, 400, 300));
  assert(!authority.Current(1, 2, true));
  assert(!authority.Dismiss(1));
  assert(authority.Dismiss(2));
  assert(!authority.Current(2, 2, true));
}'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test.cc").write_text(source)
            result = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
                "-fsanitize=address,undefined", "-include", "initializer_list",
                "-I", str(PACKAGE / "Native"), str(root / "test.cc"), "-o", str(root / "test"),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "test")], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_typed_proof_cannot_be_supplied_by_untrusted_renderer_and_patch_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            header = root / "content/public/browser/context_menu_params.h"
            implementation = root / "content/browser/renderer_host/render_frame_host_impl.cc"
            header.parent.mkdir(parents=True)
            implementation.parent.mkdir(parents=True)
            header.write_text("struct ContextMenuParams : UntrustworthyContextMenuParams {\n  bool is_subframe = false;\n};\n")
            implementation.write_text("  gfx::PointF transformed_point_f;\n  if (transform_succeeded) {\n    validated_params.y = root_point.y();\n  }\n")
            link_context_overlay.apply(root)
            expected = (header.read_text(), implementation.read_text())
            link_context_overlay.apply(root)
            self.assertEqual(expected, (header.read_text(), implementation.read_text()))
            self.assertIn("bool arx_root_coordinates_valid = false;", expected[0])
            self.assertIn("validated_params.arx_root_coordinates_valid = false;", expected[1])
            self.assertIn("view == root_view", expected[1])
            self.assertIn("validated_params.y = root_point.y();\n    validated_params.arx_root_coordinates_valid = true;", expected[1])

    def test_native_seam_uses_filtered_link_and_both_live_documents(self):
        source = (PACKAGE / "Native/engine_bridge.mm").read_text()
        method = source[source.index("  bool HandleContextMenu("):source.index("  bool Navigate(")]
        self.assertIn("params.link_url", method)
        self.assertNotIn("params.unfiltered_link_url", method)
        self.assertNotIn("params.selection_text", method)
        self.assertIn("source.GetWeakDocumentPtr()", method)
        self.assertIn("GetPrimaryMainFrame()->GetWeakDocumentPtr()", method)
        self.assertIn("params.arx_root_coordinates_valid", method)
        self.assertIn("source->GetOutermostMainFrame() == primary", method)


class LinkContextHTTPTests(unittest.TestCase):
    def test_only_owned_routes_expose_fixed_fixture_bytes(self):
        from io import BytesIO
        from types import SimpleNamespace
        from Scripts.core import link_context_fixture
        from unittest.mock import Mock

        for route in ("main", "frame", "frame-destination", "destination", "schemes", "unknown", "main?url=https://other.example/"):
            handler = SimpleNamespace(path="/link-context/" + route, send_response=Mock(),
                                      send_header=Mock(), end_headers=Mock(), wfile=BytesIO())
            self.assertTrue(link_context_fixture.serve(handler))
            expected = 404 if route == "unknown" or "?" in route else 200
            handler.send_response.assert_called_once_with(expected)
            self.assertLess(len(handler.wfile.getvalue()), 2048)
            if expected == 404:
                self.assertEqual(handler.wfile.getvalue(), b"")
        handler.path = "/profile/Default/Preferences"
        self.assertFalse(link_context_fixture.serve(handler))

    def test_context_menu_pages_and_the_image_are_served(self):
        from io import BytesIO
        from types import SimpleNamespace
        from Scripts.core import link_context_fixture
        from unittest.mock import Mock, call

        for route, kind in (("menu-field", "text/html; charset=utf-8"), ("menu-words", "text/html; charset=utf-8"),
                            ("menu-media", "text/html; charset=utf-8"), ("pixel.png", "image/png")):
            handler = SimpleNamespace(path="/link-context/" + route, send_response=Mock(),
                                      send_header=Mock(), end_headers=Mock(), wfile=BytesIO())
            self.assertTrue(link_context_fixture.serve(handler))
            handler.send_response.assert_called_once_with(200)
            self.assertIn(call("Content-Type", kind), handler.send_header.call_args_list)
            body = handler.wfile.getvalue()
            if route == "pixel.png":
                self.assertTrue(body.startswith(b"\x89PNG"))
            else:
                self.assertIn(b"Arx context menus ready", body)
        handler = SimpleNamespace(path="/link-context/pixel.png?x=1", send_response=Mock(),
                                  send_header=Mock(), end_headers=Mock(), wfile=BytesIO())
        self.assertTrue(link_context_fixture.serve(handler))
        handler.send_response.assert_called_once_with(404)
