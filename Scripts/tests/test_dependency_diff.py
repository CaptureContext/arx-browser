"""The dependency diff Danger shows on pull requests (DEV-1281), on throwaway Git repositories."""

import io
import json
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from Scripts import dependency_diff


def resolved(*pins, host="https://github.com/example"):
    return json.dumps({
        "originHash": "0",
        "pins": [
            {
                "identity": identity,
                "kind": "remoteSourceControl",
                "location": f"{host}/{identity}.git",
                "state": state,
            }
            for identity, state in pins
        ],
        "version": 3,
    }, indent=2)


MANIFEST = """// swift-tools-version: 6.4
import PackageDescription

let package = Package(
	name: "dependencies",
	dependencies: [
		.package(
			url: "https://github.com/example/alpha.git",
			.upToNextMajor(from: "1.0.0")
		),
		.package(path: "../core"),
		.package(url: "https://github.com/example/beta", exact: "2.0.0"),
	]
)
"""

NOTICES = """# Third-party notices

| Package | Version | Licence | Copyright |
| -- | -- | -- | -- |
| [alpha](https://github.com/example/alpha) | 1.0.0 | MIT | 2026 Example |
| [beta](https://github.com/example/beta) | 2.0.0 | Apache-2.0 | Example |
"""


GITMODULES = """[submodule "Forks/gamma"]
	path = Forks/gamma
	url = https://github.com/example/gamma.git
"""


class Repository:
    def __init__(self, directory):
        self.root = Path(directory)
        self.git("init", "--quiet", "--initial-branch=main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "commit.gpgsign", "false")
        self.gitlinks = {}

    def git(self, *arguments):
        return subprocess.run(
            ["git", *arguments], cwd=self.root, check=True, capture_output=True, text=True
        ).stdout.strip()

    def write(self, path, text):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def commit(self, message):
        self.git("add", "--all")
        # `add --all` drops a gitlink that has no checkout, so put each back.
        for path, object_id in self.gitlinks.items():
            self.git("update-index", "--add", "--cacheinfo", f"160000,{object_id},{path}")
        self.git("commit", "--quiet", "--allow-empty", "--message", message)
        return self.git("rev-parse", "HEAD")

    def gitlink(self, path, object_id):
        self.gitlinks[path] = object_id
        self.git("update-index", "--add", "--cacheinfo", f"160000,{object_id},{path}")


class DependencyDiffTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repository = Repository(self.directory.name)
        self.repository.write("Package.resolved", resolved(("alpha", {"revision": "a" * 40, "version": "1.0.0"})))
        self.repository.write("Packages/dependencies/Package.resolved", resolved(
            ("alpha", {"revision": "a" * 40, "version": "1.0.0"}),
            ("beta", {"revision": "b" * 40, "version": "2.0.0"}),
        ))
        self.repository.write("Packages/dependencies/Package.swift", MANIFEST)
        self.repository.write("THIRD_PARTY_NOTICES.md", NOTICES)
        self.repository.gitlink("Forks/gamma", "c" * 40)
        self.repository.write(".gitmodules", GITMODULES)
        self.base = self.repository.commit("Base")

    def compare(self, head=None):
        root = self.repository.root
        tree = dependency_diff.Tree(head, root) if head else dependency_diff.WorkTree(root)
        return dependency_diff.compare(dependency_diff.Tree(self.base, root), tree)

    def test_an_unchanged_tree_has_no_changes(self):
        self.assertEqual(self.compare(self.repository.commit("Nothing")), [])
        self.assertEqual(dependency_diff.markdown([]), "No dependency changes.\n")
        self.assertEqual(dependency_diff.report([])["label"], None)

    def test_a_new_package_shows_in_every_source(self):
        self.repository.write("Packages/dependencies/Package.resolved", resolved(
            ("alpha", {"revision": "a" * 40, "version": "1.0.0"}),
            ("beta", {"revision": "b" * 40, "version": "2.0.0"}),
            ("delta", {"branch": "main", "revision": "d" * 40}),
        ))
        self.repository.write("Packages/dependencies/Package.swift", MANIFEST.replace(
            "\t]\n", '\t\t.package(url: "https://github.com/example/delta.git", branch: "main"),\n\t]\n'
        ))
        self.repository.write("THIRD_PARTY_NOTICES.md", NOTICES + "| [delta](https://github.com/example/delta) | main | MIT | Example |\n")
        changes = self.compare(self.repository.commit("Add delta"))

        self.assertEqual(
            [(change.source, change.name, change.change, change.after) for change in changes],
            [
                ("pin", "delta", "added", "main @ ddddddd"),
                ("manifest", "https://github.com/example/delta", "added", 'branch: "main"'),
                ("notice", "delta", "added", "main, MIT"),
            ],
        )
        self.assertEqual(changes[0].files, ("Packages/dependencies/Package.resolved",))
        report = dependency_diff.report(changes)
        self.assertEqual(report["label"], "new dependency")
        self.assertEqual(report["added"], ["delta", "https://github.com/example/delta"])

    def test_a_bumped_and_a_removed_package(self):
        self.repository.write("Package.resolved", resolved(("alpha", {"revision": "e" * 40, "version": "1.1.0"})))
        self.repository.write("Packages/dependencies/Package.resolved", resolved(
            ("alpha", {"revision": "e" * 40, "version": "1.1.0"}),
        ))
        self.repository.write("Packages/dependencies/Package.swift", MANIFEST.replace(
            '\t\t.package(url: "https://github.com/example/beta", exact: "2.0.0"),\n', ""
        ).replace('from: "1.0.0"', 'from: "1.1.0"'))
        changes = self.compare(self.repository.commit("Bump alpha, drop beta"))

        self.assertIn(
            dependency_diff.Change(
                "pin", "alpha", "changed", "1.0.0 @ aaaaaaa", "1.1.0 @ eeeeeee",
                ("Package.resolved", "Packages/dependencies/Package.resolved"),
            ),
            changes,
        )
        self.assertIn(
            dependency_diff.Change("pin", "beta", "removed", "2.0.0 @ bbbbbbb", "", ("Packages/dependencies/Package.resolved",)),
            changes,
        )
        self.assertIn(
            dependency_diff.Change(
                "manifest", "https://github.com/example/alpha", "changed",
                '.upToNextMajor(from: "1.0.0")', '.upToNextMajor(from: "1.1.0")',
                ("Packages/dependencies/Package.swift",),
            ),
            changes,
        )
        self.assertIn(
            dependency_diff.Change(
                "manifest", "https://github.com/example/beta", "removed", 'exact: "2.0.0"', "",
                ("Packages/dependencies/Package.swift",),
            ),
            changes,
        )
        self.assertEqual(dependency_diff.report(changes)["added"], [])
        self.assertEqual(dependency_diff.report(changes)["label"], "new dependency")

    def test_a_moved_fork_and_the_working_tree(self):
        self.repository.gitlink("Forks/gamma", "f" * 40)
        self.repository.write("THIRD_PARTY_NOTICES.md", NOTICES.replace("| 2.0.0 | Apache-2.0", "| 2.1.0 | Apache-2.0"))
        changes = self.compare()

        self.assertEqual(changes, [
            dependency_diff.Change("notice", "beta", "changed", "2.0.0, Apache-2.0", "2.1.0, Apache-2.0", ("THIRD_PARTY_NOTICES.md",)),
            dependency_diff.Change(
                "fork", "Forks/gamma", "changed", "ccccccc from https://github.com/example/gamma",
                "fffffff from https://github.com/example/gamma", ("Forks/gamma",),
            ),
        ])
        table = dependency_diff.markdown(changes)
        self.assertIn("| `beta` | changed | 2.0.0, Apache-2.0 | 2.1.0, Apache-2.0 | THIRD_PARTY_NOTICES.md |", table)
        self.assertIn(
            "| `Forks/gamma` | changed | ccccccc from https://github.com/example/gamma | "
            "fffffff from https://github.com/example/gamma | Fork (submodule): `Forks/gamma` |",
            table,
        )

    def test_a_fork_pointed_at_another_remote(self):
        self.repository.write(".gitmodules", GITMODULES.replace("example/gamma", "someone/gamma"))
        changes = self.compare(self.repository.commit("Move gamma's remote"))

        self.assertEqual(changes, [dependency_diff.Change(
            "fork", "Forks/gamma", "changed", "ccccccc from https://github.com/example/gamma",
            "ccccccc from https://github.com/someone/gamma", ("Forks/gamma",),
        )])

    def test_a_new_revision_under_the_same_version(self):
        self.repository.write("Package.resolved", resolved(("alpha", {"revision": "1" * 40, "version": "1.0.0"})))
        changes = self.compare(self.repository.commit("Retag alpha"))

        self.assertEqual(changes, [
            dependency_diff.Change("pin", "alpha", "changed", "1.0.0 @ aaaaaaa", "1.0.0 @ 1111111, 1.0.0 @ aaaaaaa", (
                "Package.resolved", "Packages/dependencies/Package.resolved",
            )),
        ])

    def test_a_pin_from_another_source(self):
        self.repository.write(
            "Package.resolved",
            resolved(("alpha", {"revision": "a" * 40, "version": "1.0.0"}), host="https://example.org/mirror"),
        )
        changes = self.compare(self.repository.commit("Mirror alpha"))

        self.assertEqual(len(changes), 1)
        self.assertIn("<remoteSourceControl https://example.org/mirror/alpha>", changes[0].after)
        self.assertNotIn("example.org", changes[0].before)
        self.assertEqual(dependency_diff.pin_state({"repositoryURL": "https://x/y.git", "state": {"version": "1"}}), "1 <https://x/y>")

    def test_a_package_added_to_another_manifest_with_the_same_rule(self):
        self.repository.write("Packages/core/Package.swift", MANIFEST.replace('name: "dependencies"', 'name: "core"'))
        changes = self.compare(self.repository.commit("Use alpha and beta in core"))

        self.assertEqual([(change.name, change.change) for change in changes], [
            ("https://github.com/example/alpha", "changed"),
            ("https://github.com/example/beta", "changed"),
        ])
        self.assertEqual(changes[1].before, 'exact: "2.0.0" in Packages/dependencies/Package.swift')
        self.assertEqual(
            changes[1].after, 'exact: "2.0.0" in Packages/core/Package.swift, Packages/dependencies/Package.swift'
        )

    def test_package_calls_keep_nested_parentheses_and_strings(self):
        calls = dependency_diff.package_calls(
            '.package(url: "https://x/a(b).git", .upToNextMinor(from: "0.2.0")), .package(path: "../core")'
        )
        self.assertEqual(calls, ['url: "https://x/a(b).git", .upToNextMinor(from: "0.2.0")', 'path: "../core"'])

    def test_main_compares_with_the_merge_base_and_writes_both_files(self):
        self.repository.git("switch", "--quiet", "--create", "feature")
        self.repository.write("Package.resolved", resolved(
            ("alpha", {"revision": "a" * 40, "version": "1.0.0"}),
            ("zeta", {"revision": "9" * 40, "version": "0.1.0"}),
        ))
        head = self.repository.commit("Add zeta")
        self.repository.git("switch", "--quiet", "main")
        self.repository.write("Package.resolved", resolved(("alpha", {"revision": "e" * 40, "version": "1.1.0"})))
        self.repository.commit("Bump alpha on main")
        output = self.repository.root / "out"

        with redirect_stdout(io.StringIO()) as printed:
            dependency_diff.main(
                ["--base", "main", "--head", head, "--markdown", str(output / "deps.md"), "--json", str(output / "deps.json")],
                root=self.repository.root,
            )

        report = json.loads((output / "deps.json").read_text())
        # main's own bump isn't the pull request's change.
        self.assertEqual([(change["name"], change["change"]) for change in report["changes"]], [("zeta", "added")])
        self.assertEqual((output / "deps.md").read_text(), printed.getvalue())

    def test_an_unreadable_package_resolved_is_an_error(self):
        self.repository.write("Package.resolved", "{")
        with self.assertRaisesRegex(ValueError, "Package.resolved isn't valid JSON"):
            self.compare(self.repository.commit("Break it"))


if __name__ == "__main__":
    unittest.main()
