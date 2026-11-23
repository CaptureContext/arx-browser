"""Exercise exact opt-in RFH identity/reset bodies and every pinned overlay anchor."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from Scripts.engine import close_overlay

FIXTURES = Path(__file__).parent / "fixtures"


def prepare(root):
    target = root / "content/browser/renderer_host"
    target.mkdir(parents=True)
    for name in ("render_frame_host_impl.h", "render_frame_host_impl.cc"):
        shutil.copy2(FIXTURES / "close-overlay" / name, target / name)
    public = root / "content/public/browser"
    public.mkdir(parents=True)
    shutil.copy2(FIXTURES / "close-overlay/public_browser.BUILD.gn", public / "BUILD.gn")
    return target


class CloseOverlayTests(unittest.TestCase):
    def test_idempotent_and_each_changed_anchor_is_rejected(self):
        import ast
        tree = ast.parse(Path(close_overlay.__file__).read_text())
        anchors = [(node.args[0].id, ast.literal_eval(node.args[1])) for node in ast.walk(tree)
                   if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                   and node.func.id == "replace_once"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = prepare(root)
            close_overlay.apply(root)
            first = {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}
            close_overlay.apply(root)
            self.assertEqual(first, {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()})
            source = (target / "render_frame_host_impl.cc").read_text()
            self.assertEqual(source.count("ArxBeforeUnloadMatches("), 6)
            self.assertIn("if (current && current->arx_before_unload_request_) return;", source)
            self.assertIn("if (manager) manager->BeforeUnloadCompleted(true);", source)
        for name, anchor in anchors:
            with self.subTest(anchor=anchor[:70]), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                target = prepare(root)
                path = {
                    "header": target / "render_frame_host_impl.h",
                    "implementation": target / "render_frame_host_impl.cc",
                    "public_build": root / "content/public/browser/BUILD.gn",
                }[name]
                path.write_text(path.read_text().replace(anchor, "changed pinned upstream anchor", 1))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    close_overlay.apply(root)

    def test_reset_releases_exact_round_and_delayed_ack_cannot_resolve_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = prepare(root)
            close_overlay.apply(root)
            implementation = (target / "render_frame_host_impl.cc").read_text()
            start = implementation.index("void RenderFrameHostImpl::ResetWaitingState() {")
            reset = implementation[start:implementation.index("\n}", start) + 2]
            methods = close_overlay.MATCH_IMPLEMENTATION + close_overlay.FINISH_IMPLEMENTATION + reset
            source = root / "contract.cc"
            transition = "  if (!arx_callback && arx_before_unload_request_) ResetWaitingState();"
            self.assertIn(transition, implementation)
            no_handler_start = implementation.index("          if (!request) {")
            no_handler = implementation[no_handler_start:implementation.index("        }, GetWeakPtr()", no_handler_start)]
            source.write_text((FIXTURES / "before_unload_identity.cc").read_text()
                              .replace("// PRODUCTION_METHODS", methods)
                              .replace("// PRODUCTION_ORDINARY_TRANSITION", transition)
                              .replace("// PRODUCTION_NO_HANDLER", no_handler))
            executable = root / "contract"
            result = subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
                                     "-fsanitize=address,undefined", str(source), "-o", str(executable)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
