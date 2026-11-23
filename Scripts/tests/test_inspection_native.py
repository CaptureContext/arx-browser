"""Run production inspection safety/identity/retirement bodies with deterministic peers."""

from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from Scripts.engine import artifact, inspection_overlay
from Scripts.engine.config import PACKAGE


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


class InspectionNativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        root = Path(cls.directory.name)
        renderer = (PACKAGE / "Native/inspection/inspector.cc").read_text()
        browser = (PACKAGE / "Native/inspection_bridge.mm").read_text()
        fixture = (Path(__file__).parent / "fixtures/inspection_policy.cc").read_text()
        fixture = fixture.replace("// PRODUCTION_SAFETY", section(renderer, "bool IsTag(", "base::ListValue Omissions("))
        fixture = fixture.replace("// PRODUCTION_FORGET", section(browser, "  void Forget(", "  void Invalidate("))
        (root / "contract.cc").write_text(fixture)
        cls.executable = root / "contract"
        result = subprocess.run(
            ["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
             "-fsanitize=address,undefined", "-I", str(PACKAGE / "Native/inspection"),
             str(root / "contract.cc"), "-o", str(cls.executable)],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode:
            raise AssertionError(result.stderr)

    def run_scenario(self, name):
        result = subprocess.run([str(self.executable), name], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_shadow_including_actual_former_password_and_value_ancestry(self):
        self.run_scenario("password")

    def test_only_exact_own_labels_survive_and_output_reserves_escaping(self):
        self.run_scenario("names")

    def test_plain_buttons_are_named_by_their_own_words_and_inputs_by_value(self):
        self.run_scenario("buttons")

    def test_dom_replacement_id_reuse_disconnect_and_document_change_reject(self):
        self.run_scenario("reference")

    def test_repeated_expiry_revoke_and_cancel_send_once_and_keep_physical_slot(self):
        self.run_scenario("retirement")

    def test_global_handle_and_request_budgets_are_hard(self):
        self.run_scenario("limits")

    def test_overlay_is_repeatable_and_rejects_every_changed_anchor(self):
        patches = inspection_overlay.patches()
        for changed in [None, *range(len(patches))]:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for relative, old, _ in patches:
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with path.open("a") as stream:
                        stream.write(old + "\n")
                if changed is not None:
                    relative, old, _ = patches[changed]
                    path = root / relative
                    path.write_text(path.read_text().replace(old, "changed upstream anchor", 1))
                    with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                        inspection_overlay.apply(root)
                else:
                    inspection_overlay.apply(root)
                    first = {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}
                    inspection_overlay.apply(root)
                    self.assertEqual(first, {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()})

    def test_renderer_overlay_participates_in_exact_artifact_fingerprint(self):
        original = Path.read_bytes
        before = artifact.identity()
        for name in ("inspection_overlay.py", "form_actions_overlay.py", "scroll_actions_overlay.py", "keypress_actions_overlay.py"):
            def changed(path):
                value = original(path)
                return value + b"\nchanged" if path.name == name else value
            with self.subTest(name=name), patch.object(Path, "read_bytes", changed):
                self.assertNotEqual(before, artifact.identity())
