"""A FileStream deleted at shutdown drops its descriptor's guard before closing it."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import file_stream_guard_overlay as overlay


def prepare(root, patches):
    for relative, old, _ in patches:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


# Upstream's guard and unguard, as file_stream_context.cc and the constructor name them.
GUARD = "guardid_t guardid = reinterpret_cast<guardid_t>(this);"


class FileStreamGuardOverlayTests(unittest.TestCase):
    def test_apply_is_repeatable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root, overlay.patches())
            overlay.apply(root)
            first = snapshot(root)
            overlay.apply(root)
            self.assertEqual(first, snapshot(root))

    def test_the_destructor_drops_its_own_guard_before_the_file_closes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root, overlay.patches())
            overlay.apply(root)
            source = (root / overlay.SOURCE).read_text()
            self.assertNotIn("FileStream::Context::~Context() = default;", source)
            destructor = source[source.index("FileStream::Context::~Context() {"):]
            destructor = destructor[:destructor.index("\n}\n")]
            # Only while the file is still open, on the Mac, with the guard and flags the
            # Context set, and moving to no guard: the members' destructors then close it.
            self.assertIn("#if BUILDFLAG(IS_MAC)", destructor)
            self.assertIn("if (file_.IsValid()) {", destructor)
            self.assertIn(GUARD, destructor)
            self.assertIn("file_.GetPlatformFile(), &guardid, GUARD_CLOSE | GUARD_DUP,\n"
                          "        /*nguard=*/nullptr, /*nguardflags=*/0, /*fdflagsp=*/nullptr);",
                          destructor)
            # A failure doesn't stop shutdown in a release build, and the call always runs.
            self.assertIn("const int unguarded = change_fdguard_np(", destructor)
            self.assertIn("DPCHECK(unguarded == 0);", destructor)
            self.assertNotIn("file_.Close()", destructor)

    def test_changed_anchor_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root, [(relative, old.replace("= default", "=default"), new)
                           for relative, old, new in overlay.patches()])
            with self.assertRaisesRegex(ValueError, "anchor changed"):
                overlay.apply(root)

    def test_the_overlay_is_applied_compiled_and_identifies_the_engine(self):
        engine = Path(__file__).parents[1] / "engine"
        self.assertIn("apply_file_stream_guard(source)", (engine / "overlay.py").read_text())
        self.assertIn('"Scripts/engine/file_stream_guard_overlay.py"', (engine / "artifact.py").read_text())
        self.assertIn('"//net/base/file_stream_context_posix.cc"', (engine / "build.py").read_text())


if __name__ == "__main__":
    unittest.main()
