"""`make engine-anchor-check` (DEV-955): the sparse tree's patching, sources and file discovery,
and the report. Chromium, Helium and the archives are fakes; nothing reaches the network."""

import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

from Scripts.engine import anchors, overlay

PATCH = """\
Description: a Helium patch touching two files.

--- a/chrome/a.cc
+++ b/chrome/a.cc
@@ -2,3 +2,4 @@ namespace {
 two
-three
+THREE
+three and a half
 four
--- a/chrome/b.sql
+++ b/chrome/b.sql
@@ -1,2 +1,1 @@
--- a SQL comment that starts like a header
 SELECT 1;
--- /dev/null
+++ b/chrome/new.h
@@ -0,0 +1,2 @@
+#pragma once
+// Helium's own file
\\ No newline at end of file
"""


class DiffTests(unittest.TestCase):
    def test_splits_files_by_hunk_lengths(self):
        result = anchors.sections(PATCH)
        self.assertEqual([(section.old, section.new) for section in result],
                         [("chrome/a.cc", "chrome/a.cc"), ("chrome/b.sql", "chrome/b.sql"), (None, "chrome/new.h")])
        self.assertEqual(result[1].hunks[0].lines, ["--- a SQL comment that starts like a header\n", " SELECT 1;\n"])

    def test_applies_hunks_with_offsets(self):
        section = anchors.sections(PATCH)[0]
        text = "zero\none\ntwo\nthree\nfour\n"  # one line more than the hunk expects
        self.assertEqual(anchors.apply_section(text, section), "zero\none\ntwo\nTHREE\nthree and a half\nfour\n")

    def test_later_hunks_follow_earlier_ones(self):
        patch = ("--- a/x\n+++ b/x\n@@ -1,2 +1,3 @@\n a\n+a2\n b\n@@ -5,2 +6,2 @@\n e\n-f\n+F\n")
        section = anchors.sections(patch)[0]
        self.assertEqual(anchors.apply_section("a\nb\nc\nd\ne\nf\n", section), "a\na2\nb\nc\nd\ne\nF\n")

    def test_ignores_whitespace_and_fuzzes_context_like_gnu_patch(self):
        patch = "--- a/x\n+++ b/x\n@@ -1,4 +1,4 @@\n context\n-old\n+new\n gone\n tail\n"
        section = anchors.sections(patch)[0]
        # The file's own context lines stay, trailing spaces and all.
        self.assertEqual(anchors.apply_section("context  \nold\ngone\ntail\n", section), "context  \nnew\ngone\ntail\n")
        # Upstream changed the last two context lines; fuzz 2 drops them.
        self.assertEqual(anchors.apply_section("context\nold\nchanged\nlines\n", section), "context\nnew\nchanged\nlines\n")

    def test_a_hunk_that_doesnt_apply_names_the_file(self):
        section = anchors.sections(PATCH)[0]
        with self.assertRaisesRegex(ValueError, "doesn't apply to chrome/a.cc"):
            anchors.apply_section("something else entirely\n", section)

    def test_creates_and_deletes_files(self):
        created = anchors.sections(PATCH)[2]
        self.assertEqual(anchors.apply_section(None, created), "#pragma once\n// Helium's own file")
        deleted = anchors.sections("--- a/old.cc\n+++ /dev/null\n@@ -1 +0,0 @@\n-gone\n")[0]
        self.assertIsNone(anchors.apply_section("gone\n", deleted))

    def test_series_order_and_comments(self):
        with tempfile.TemporaryDirectory() as directory:
            patches = Path(directory)
            (patches / "series").write_text("# heading\nfirst.patch\n\nsub/second.patch # why\n")
            self.assertEqual(anchors.series(patches), [patches / "first.patch", patches / "sub/second.patch"])


class SourceTests(unittest.TestCase):
    def test_domain_substitution_touches_only_listed_files(self):
        with tempfile.TemporaryDirectory() as directory:
            helium = Path(directory)
            (helium / "domain_substitution.list").write_text("chrome/a.cc\n")
            (helium / "domain_regex.list").write_text(r"google(\.com)#9oo91e\g<1>" + "\n")
            substitute = anchors.DomainSubstitution(helium)
            self.assertEqual(substitute("chrome/a.cc", "www.google.com"), "www.9oo91e.com")
            self.assertEqual(substitute("chrome/b.cc", "www.google.com"), "www.google.com")

    def test_chromium_reads_deps_repositories_at_their_pins(self):
        deps = ("deps = {\n  'src/base/allocator/partition_allocator': {\n"
                "    'url': Var('chromium_git') + '/chromium/src/base/allocator/partition_allocator.git' + '@' + '"
                + "a" * 40 + "',\n  },\n  'src/third_party/x': Var('chromium_git') + '/external/x.git' + '@' + '" + "b" * 40 + "',\n"
                "  'src/third_party/y': Var('chromium_git') + '/external/y.git' + '@' + Var('y_revision'),\n}\n"
                "vars = {\n  'y_revision': '" + "c" * 40 + "',\n}\n")
        requests = []

        def fetch(repository, revision, path):
            requests.append((repository, revision, path))
            return deps if path == "DEPS" else f"{repository}:{path}"

        chromium = anchors.Chromium("157.0.8103.78", fetch)
        self.assertEqual(chromium.read("base/allocator/partition_allocator/src/shim.h"),
                         "chromium/src/base/allocator/partition_allocator:src/shim.h")
        self.assertEqual(chromium.read("third_party/x/y.cc"), "external/x:y.cc")
        self.assertEqual(chromium.read("chrome/a.cc"), "chromium/src:chrome/a.cc")
        self.assertEqual(chromium.read("third_party/y/z.cc"), "external/y:z.cc")
        self.assertIn(("external/y", "c" * 40, "z.cc"), requests)
        self.assertEqual(requests[0], ("chromium/src", "refs/tags/157.0.8103.78", "DEPS"))
        self.assertEqual(requests[1][1], "a" * 40)

    def deps(self, directory, archive):
        helium = Path(directory)
        (helium / "deps.ini").write_text(
            "[ublock_origin]\nversion = 1.75.4\n"
            "url = https://example.invalid/uBlock0_%(version)s.chromium.zip\n"
            f"sha256 = {hashlib.sha256(archive).hexdigest()}\n"
            "download_filename = ublock-origin-%(version)s.zip\noutput_path = third_party/ublock\n"
            "strip_leading_dirs = uBlock0.chromium\n")
        downloads = []
        return anchors.Deps(helium, download=lambda url: downloads.append(url) or archive), downloads

    def test_reads_files_from_a_deps_archive_once(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr("uBlock0.chromium/background.html", "<script></script>\n")
        with tempfile.TemporaryDirectory() as directory:
            deps, downloads = self.deps(directory, buffer.getvalue())
            self.assertTrue(deps.covers("third_party/ublock/background.html"))
            self.assertFalse(deps.covers("third_party/ublockx/a"))
            self.assertEqual(deps.read("third_party/ublock/background.html"), "<script></script>\n")
            self.assertIsNone(deps.read("third_party/ublock/missing.js"))
            self.assertEqual(downloads, ["https://example.invalid/uBlock0_1.75.4.chromium.zip"])

    def test_rejects_an_archive_that_isnt_the_pinned_one(self):
        with tempfile.TemporaryDirectory() as directory:
            deps, _ = self.deps(directory, b"pinned")
            deps.download = lambda url: b"tampered"
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                deps.read("third_party/ublock/background.html")


class SparseTreeTests(unittest.TestCase):
    UPSTREAM = {"chrome/a.cc": "one\ntwo\nthree\nfour\n", "chrome/b.cc": "alpha\n"}

    def tree(self, root):
        patches = {}
        for section in anchors.sections(PATCH):
            patches.setdefault(section.path, []).append((Path("helium/x.patch"), section))
        reads = []
        tree = anchors.SparseTree(root, lambda relative: reads.append(relative) or self.UPSTREAM.get(relative),
                                  patches, lambda relative, text: text.replace("alpha", "ALPHA"))
        return tree, reads

    def test_fetches_each_file_an_overlay_opens_and_reports_missing_anchors(self):
        def apply(source, team=""):
            overlay.replace_once(source / "chrome/a.cc", "THREE\n", "THREE\n// Arx\n")
            overlay.replace_once(source / "chrome/b.cc", "ALPHA\n", "ALPHA\n// Arx\n")
            overlay.replace_once(source / "chrome/new.h", "#pragma once\n", "#pragma once\n// Arx\n")
            overlay.replace_once(source / "chrome/gone.cc", "anchor\n", "anchor\n// Arx\n")
            (source / "chrome/arx/bridge.mm").write_text("// Arx's own file\n")

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(overlay, "apply", apply):
            root = Path(directory)
            tree, reads = self.tree(root)
            missing, stopped = tree.run()
            self.assertIsNone(stopped)
            self.assertEqual([(entry[2].relative_to(root).as_posix(), entry[3]) for entry in missing],
                             [("chrome/gone.cc", 0)])
            self.assertEqual((root / "chrome/a.cc").read_text(), "one\ntwo\nTHREE\n// Arx\nthree and a half\nfour\n")
            self.assertEqual((root / "chrome/b.cc").read_text(), "ALPHA\n// Arx\n")
            self.assertEqual((root / "chrome/new.h").read_text(), "#pragma once\n// Arx\n// Helium's own file")
            self.assertEqual((root / "chrome/arx/bridge.mm").read_text(), "// Arx's own file\n")
            self.assertEqual(tree.absent, ["chrome/gone.cc"])
            self.assertEqual(sorted(set(reads)), ["chrome/a.cc", "chrome/arx/bridge.mm", "chrome/b.cc", "chrome/gone.cc", "chrome/new.h"])
            self.assertEqual(len(reads), len(set(reads)))

    def test_a_patch_that_doesnt_apply_is_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            tree, _ = self.tree(Path(directory))
            tree.read = lambda relative: "unrelated\n"
            self.assertTrue(tree.materialize("chrome/a.cc"))
            self.assertEqual(tree.failures, ["helium/x.patch: A hunk at line 2 doesn't apply to chrome/a.cc"])

    def test_a_missing_file_outside_the_tree_propagates(self):
        def apply(source, team=""):
            (Path(source).parent / "elsewhere/file").read_text()

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(overlay, "apply", apply):
            root = Path(directory) / "src"
            root.mkdir()
            tree, _ = self.tree(root)
            with self.assertRaises(FileNotFoundError):
                tree.run()


class CheckTests(unittest.TestCase):
    def test_reports_anchors_and_the_vendored_bootstrap_files(self):
        def fetch_helium(destination, lock):
            macos, helium = destination / "helium-macos", destination / "helium-macos/helium-chromium"
            for patches in (helium / "patches", macos / "patches"):
                patches.mkdir(parents=True)
            (helium / "patches/series").write_text("a.patch\n")
            (helium / "patches/a.patch").write_text("--- a/chrome/a.cc\n+++ b/chrome/a.cc\n@@ -1 +1 @@\n-one\n+ONE\n")
            (macos / "patches/series").write_text("")
            (helium / "domain_substitution.list").write_text("")
            (helium / "domain_regex.list").write_text("")
            (helium / "deps.ini").write_text("")
            return macos, helium

        def apply(source, team=""):
            overlay.replace_once(source / "chrome/a.cc", "ONE\n", "ONE\n// Arx\n")
            overlay.replace_once(source / "chrome/a.cc", "two\n", "2\n")

        upstream = {"chrome/a.cc": "one\n", "LICENSE": "BSD\n", "base/x.h": "changed\n"}
        chromium = mock.Mock(read=lambda relative: upstream.get(relative))
        lock = {"helium_macos": {"version": "0.21.4.1"}, "chromium": "157.0.8103.92"}
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(overlay, "apply", apply):
            work = Path(directory)
            manifest = work / "manifest.json"
            manifest.write_text(json.dumps({"files": [
                {"source": "LICENSE", "sha256": hashlib.sha256(b"BSD\n").hexdigest()},
                {"source": "base/x.h", "sha256": "0" * 64},
                {"source": "base/gone.h", "sha256": "0" * 64}]}))
            result = anchors.check(work=work, lock=lock, chromium=chromium, fetch_helium=fetch_helium, manifest=manifest)
        self.assertFalse(anchors.clean(result))
        self.assertEqual(result["missing"], [{"overlay": "test_engine_anchors.py", "line": result["missing"][0]["line"],
                                              "path": "chrome/a.cc", "found": 0, "anchor": "two"}])
        self.assertEqual(result["bootstrap"], [("LICENSE", "unchanged"), ("base/x.h", "changed: refresh the vendored copy"),
                                               ("base/gone.h", "not found at this release")])
        report = anchors.markdown(result)
        self.assertIn("### Overlay anchors at helium-macos 0.21.4.1 (Chromium 157.0.8103.92)", report)
        self.assertIn("| `test_engine_anchors.py:", report)
        self.assertIn("| `chrome/a.cc` | 0 | `two` |", report)
        self.assertIn("- `base/x.h`: changed: refresh the vendored copy", report)

    def test_a_clean_report(self):
        result = {"helium_macos": "0.21.4.1", "chromium": "157.0.8103.92", "missing": [], "stopped": None,
                  "absent": [], "patch_failures": [], "unsimulated": ["chrome/app/generated_resources.grd"],
                  "files": 200, "bootstrap": [("LICENSE", "unchanged")]}
        self.assertTrue(anchors.clean(result))
        report = anchors.markdown(result)
        self.assertIn("Every overlay applies (200 upstream files checked).", report)
        self.assertIn("- `chrome/app/generated_resources.grd`", report)


if __name__ == "__main__":
    unittest.main()
