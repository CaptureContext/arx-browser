"""make style reads each tool's warnings, prints them one way and never fails on findings (DEV-1280)."""

import contextlib
import io
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from Scripts import style, tasks
from Scripts.core.paths import ROOT


class StyleTests(unittest.TestCase):
    def test_parses_each_tools_warnings(self):
        swiftformat = (
            "Running SwiftFormat...\n"
            f"{ROOT}/Packages/a/A.swift:3:1: error: (typeSugar) Prefer shorthand syntax.\n"
            "Source input did not pass lint check.\n"
        )
        swiftlint = f"{ROOT}/Sources/B.swift:6:9: warning: Explicit ACL Violation: Be explicit (explicit_acl)\n"
        stylecheck = "Packages/c/C.swift:10:2: warning: [dense-span] 80 lines in a row\nStyleCheck: 1 findings\n"

        self.assertEqual(
            style.parse(swiftformat, "swiftformat"),
            [style.Finding("Packages/a/A.swift", 3, 1, "swiftformat/typeSugar", "Prefer shorthand syntax.")],
        )
        self.assertEqual(
            style.parse(swiftlint, "swiftlint"),
            [style.Finding("Sources/B.swift", 6, 9, "swiftlint/explicit_acl", "Explicit ACL Violation: Be explicit")],
        )
        self.assertEqual(
            style.parse(stylecheck, "StyleCheck"),
            [style.Finding("Packages/c/C.swift", 10, 2, "dense-span", "80 lines in a row")],
        )

    def test_prints_warnings_and_github_annotations(self):
        finding = style.Finding("A, B.swift", 4, 2, "swiftlint/explicit_acl", "50% done:\nnext")
        self.assertEqual(
            style.format_finding(finding, github=False),
            "A, B.swift:4:2: warning: [swiftlint/explicit_acl] 50% done:\nnext",
        )
        self.assertEqual(
            style.format_finding(finding, github=True),
            "::warning file=A%2C B.swift,line=4,col=2,title=swiftlint/explicit_acl::50%25 done:%0Anext",
        )

    def test_missing_tools_are_skipped_and_findings_do_not_fail(self):
        output = io.StringIO()
        with (
            patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}),
            patch.object(style, "swift_files", return_value=["A.swift"]),
            patch.object(style.shutil, "which", return_value=None),
            patch.object(style, "build_style_check", return_value="StyleCheck"),
            patch.object(style, "execute_tool", return_value="A.swift:1:1: warning: [dense-span] dense\n") as tool,
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(tasks.main(["style"]), 0)
        tool.assert_called_once_with("StyleCheck", ["StyleCheck", "A.swift"], ROOT)
        self.assertIn("swiftformat: skipped, not installed", output.getvalue())
        self.assertIn("swiftlint: skipped, not installed", output.getvalue())
        self.assertIn("A.swift:1:1: warning: [dense-span] dense", output.getvalue())
        self.assertIn("StyleCheck (Packages/tools): 1 in 1 files (dense-span 1)", output.getvalue())

    def test_every_tool_gets_the_same_explicit_files(self):
        files = ["Packages/core/Sources/A.swift", "Packages/core/Tests/ATests/ATests.swift", "Scripts/B.swift"]
        calls = {}

        def tool(name, arguments, root):
            calls[name] = arguments
            return ""

        output = io.StringIO()
        with (
            patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}),
            patch.object(style, "swift_files", return_value=files),
            patch.object(style.shutil, "which", side_effect=lambda name: name),
            patch.object(style, "describe", side_effect=lambda name, binary, root: f"{name} 1.0"),
            patch.object(style, "build_style_check", return_value="StyleCheck"),
            patch.object(style, "execute_tool", side_effect=tool),
            contextlib.redirect_stdout(output),
        ):
            style.main()
        # No tool is handed a directory to walk, which once took in vendor/bundle and Packages/*/.build.
        self.assertEqual(calls["swiftformat"], ["swiftformat", "--lint", *files])
        self.assertEqual(calls["swiftlint"][-1:], ["Packages/core/Sources/A.swift"])
        self.assertIn("--force-exclude", calls["swiftlint"])
        self.assertEqual(calls["StyleCheck"], ["StyleCheck", *files])
        self.assertIn("swiftformat 1.0: 0 in 3 files", output.getvalue())
        self.assertIn("swiftlint 1.0: 0 in 1 files", output.getvalue())

    def test_selects_only_arxs_own_swift_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            (root / ".gitignore").write_text("ignored/\n")
            own = ["Packages/core/Sources/A.swift", "Packages/core/Tests/ATests/ATests.swift", "Scripts/B.swift"]
            foreign = [
                "vendor/bundle/ruby/3.2.0/gems/fastlane/Snapshot.swift",
                "Packages/core/.build/checkouts/swift-syntax/C.swift",
                "build/D.swift",
                "Forks/swift-syntax/E.swift",
                ".swiftpm/F.swift",
                "ignored/G.swift",
                "Packages/extensions/Sources/Files/Files.swift",
                "Packages/core/Sources/README.md",
            ]
            for path in own + foreign:
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_text("let a = 1\n")
            self.assertEqual(style.swift_files(root), sorted(own))

    def test_production_files_match_the_swiftlint_config(self):
        self.assertTrue(style.is_production("Packages/core/Sources/BrowserCore/Tab.swift"))
        self.assertTrue(style.is_production("Containers/macOS/main.swift"))
        for path in [
            "Packages/core/Tests/BrowserCoreTests/TabTests.swift",
            "Packages/core/Package.swift",
            "Package.swift",
            "Scripts/fixtures/RoutingLauncher.swift",
            "Previews/AppUI/Tests/PreviewTests.swift",
            "Packages/engine/Prototypes/DocumentCapture/main.swift",
        ]:
            self.assertFalse(style.is_production(path), path)
        config = (ROOT / ".swiftlint.yml").read_text()
        included = re.findall(r"^included:\n((?:  - .*\n)+)", config, re.M)[0]
        excluded = re.findall(r"^excluded:\n((?:  - .*\n)+)", config, re.M)[0]
        self.assertEqual(
            sorted(f"{name}/" for name in re.findall(r"- (\S+)", included)), sorted(style.PRODUCTION_ROOTS),
        )
        for pattern in style.NOT_PRODUCTION:
            self.assertIn(f"  - {pattern.removesuffix('/*')}\n", excluded)

    def test_summary_names_the_binary_that_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "mise.toml").write_text('[tools]\nswiftlint = "0.65.1"\n')
            completed = subprocess.CompletedProcess([], 0, "0.61.0\n", "")
            with patch.object(style.subprocess, "run", return_value=completed):
                self.assertEqual(
                    style.describe("swiftlint", "/opt/homebrew/bin/swiftlint", root),
                    "swiftlint 0.61.0, not the 0.65.1 mise.toml pins: /opt/homebrew/bin/swiftlint",
                )
            pinned = subprocess.CompletedProcess([], 0, "0.65.1\n", "")
            with patch.object(style.subprocess, "run", return_value=pinned):
                self.assertEqual(style.describe("swiftlint", "swiftlint", root), "swiftlint 0.65.1")

    def test_a_crashing_tool_fails(self):
        with patch.object(style.subprocess, "run", return_value=subprocess.CompletedProcess([], 70, "", "boom")):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(subprocess.CalledProcessError):
                style.execute_tool("swiftformat", ["swiftformat", "--lint", "."])
        with patch.object(style.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "")):
            self.assertEqual(style.execute_tool("swiftformat", ["swiftformat", "--lint", "."]), "")


if __name__ == "__main__":
    unittest.main()
