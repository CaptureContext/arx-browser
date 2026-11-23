"""make install and make update: quitting, the atomic swap, refusing without an install and the
relaunch decision, with fake runners and temporary directories instead of /Applications."""

import io
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import Mock, call, patch

from Scripts import install, release, tasks, versioning


def write_app(path, marker):
    (path / "Contents").mkdir(parents=True)
    (path / "Contents/marker").write_text(marker)
    return path


def marker(app):
    return (app / "Contents/marker").read_text()


def fake_ditto(arguments, **_):
    if arguments[0] == "ditto":
        source, destination = map(Path, arguments[1:])
        shutil.copytree(source, destination, symlinks=True)
    return ""


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class QuitTests(unittest.TestCase):
    installed = Path("/Applications/Arx.app")

    def test_nothing_running_needs_no_quit(self):
        running = Mock(return_value=0)
        was_running = install.quit_running(self.installed, running=running, sleep=Mock(side_effect=AssertionError))
        self.assertFalse(was_running)
        running.assert_called_once_with(quitting=True, path=self.installed)

    def test_waits_until_arx_has_quit(self):
        clock = FakeClock()
        running = Mock(side_effect=[1, 1, 1, 0])
        self.assertTrue(install.quit_running(self.installed, running=running, sleep=clock.sleep, clock=clock))
        self.assertEqual(
            running.call_args_list,
            [call(quitting=True, path=self.installed), *[call(path=self.installed)] * 3],
        )

    def test_stops_when_arx_does_not_quit(self):
        clock = FakeClock()
        running = Mock(return_value=1)
        with self.assertRaisesRegex(ValueError, "didn't quit within 3 seconds"):
            install.quit_running(self.installed, running=running, timeout=3, sleep=clock.sleep, clock=clock)
        # Only the polite Command-Q request, then polling; never anything stronger.
        self.assertEqual(running.call_args_list[0], call(quitting=True, path=self.installed))
        self.assertTrue(all(entry == call(path=self.installed) for entry in running.call_args_list[1:]))

    def test_only_the_installed_copy_is_asked_to_quit(self):
        script = Mock(return_value="0\n")
        with patch.object(install.build_app, "run", script):
            install.quit_running(self.installed)
        source = script.call_args.args[0][-1]
        self.assertIn('"/Applications/Arx.app"', source)
        self.assertIn("terminate", source)
        self.assertNotIn("forceTerminate", source)


class SwapTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.installed = self.root / "Arx.app"
        self.new = write_app(install.staged_path(self.installed), "new")

    def test_the_staged_copy_sits_next_to_the_installed_app(self):
        self.assertEqual(self.new, self.root / ".Arx.app.new")

    def test_swaps_with_an_installed_app_in_one_rename(self):
        write_app(self.installed, "old")
        install.swap(self.new, self.installed)
        self.assertEqual(marker(self.installed), "new")
        self.assertEqual(marker(self.new), "old")

    def test_moves_into_place_when_nothing_is_installed(self):
        install.swap(self.new, self.installed)
        self.assertEqual(marker(self.installed), "new")
        self.assertFalse(self.new.exists())

    def test_never_overwrites_an_app_that_appeared_meanwhile(self):
        rename = Mock()
        install.swap(self.new, self.installed, rename=rename)
        rename.assert_called_once_with(self.new, self.installed, install.RENAME_EXCL)
        write_app(self.installed, "old")
        with self.assertRaises(FileExistsError):
            install.renamex(self.new, self.installed, install.RENAME_EXCL)
        self.assertEqual(marker(self.installed), "old")


class ReplaceTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.app = write_app(self.root / "build/Arx.app", "new")
        self.installed = self.root / "Applications/Arx.app"
        self.installed.parent.mkdir()
        runner = patch.object(install, "run", side_effect=fake_ditto)
        self.run = runner.start()
        self.addCleanup(runner.stop)

    def replace(self, *, running=False, requested_open=False, quit=None):
        launch = Mock()
        install.replace(
            self.app, self.installed, requested_open=requested_open,
            quit=quit or Mock(return_value=running), launch=launch,
        )
        return launch

    def test_replaces_the_installed_app_and_cleans_up(self):
        write_app(self.installed, "old")
        launch = self.replace()
        self.assertEqual(marker(self.installed), "new")
        self.assertFalse(install.staged_path(self.installed).exists())
        launch.assert_not_called()
        commands = [entry.args[0][0] for entry in self.run.call_args_list]
        self.assertEqual(commands, ["ditto", "codesign"])

    def test_relaunches_when_it_was_running(self):
        write_app(self.installed, "old")
        launch = self.replace(running=True)
        launch.assert_called_once_with(self.installed)

    def test_opens_when_asked(self):
        launch = self.replace(requested_open=True)
        launch.assert_called_once_with(self.installed)

    def test_the_relaunch_decision(self):
        self.assertTrue(install.should_relaunch(True, False))
        self.assertTrue(install.should_relaunch(False, True))
        self.assertFalse(install.should_relaunch(False, False))

    def test_a_failed_quit_leaves_the_installed_app_alone(self):
        write_app(self.installed, "old")
        with self.assertRaises(ValueError):
            self.replace(quit=Mock(side_effect=ValueError("didn't quit")))
        self.assertEqual(marker(self.installed), "old")
        self.assertFalse(install.staged_path(self.installed).exists())

    def test_a_failed_signature_check_leaves_the_installed_app_alone(self):
        write_app(self.installed, "old")
        def failing(arguments, **options):
            if arguments[0] == "codesign":
                raise ValueError("invalid signature")
            return fake_ditto(arguments, **options)
        self.run.side_effect = failing
        quit = Mock()
        with self.assertRaises(ValueError):
            self.replace(quit=quit)
        quit.assert_not_called()
        self.assertEqual(marker(self.installed), "old")
        self.assertFalse(install.staged_path(self.installed).exists())

    def test_a_failed_swap_leaves_the_installed_app_alone(self):
        write_app(self.installed, "old")
        with patch.object(install, "swap", side_effect=OSError("rename failed")), self.assertRaises(OSError):
            self.replace()
        self.assertEqual(marker(self.installed), "old")
        self.assertFalse(install.staged_path(self.installed).exists())

    def test_replaces_a_leftover_staged_copy(self):
        write_app(install.staged_path(self.installed), "stale")
        self.replace()
        self.assertEqual(marker(self.installed), "new")


class MainTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.installed = Path(directory.name) / "Arx.app"
        self.steps = Mock()
        for name in ("signer", "build", "sign", "check"):
            patcher = patch.object(release, name, getattr(self.steps, name))
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(install, "replace", self.steps.replace)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_update_refuses_without_an_installed_app(self):
        with self.assertRaisesRegex(ValueError, "Run make install"):
            install.main([], command="update", installed=self.installed)
        self.assertEqual(self.steps.mock_calls, [])

    def test_install_timestamps_its_signature_unless_told_not_to(self):
        install.main([], command="install", installed=self.installed)
        self.assertTrue(self.steps.sign.call_args.kwargs["timestamp"])

        install.main(["--no-timestamp"], command="install", installed=self.installed)
        self.assertFalse(self.steps.sign.call_args.kwargs["timestamp"])

    def test_install_works_without_an_installed_app(self):
        install.main(["--open"], command="install", installed=self.installed)
        names = [entry[0] for entry in self.steps.mock_calls]
        self.assertEqual(names, ["signer", "build", "sign", "check", "replace"])
        self.assertFalse(self.steps.signer.call_args.args[0].development_identity)
        self.steps.build.assert_called_once_with(bump=False, destination=install.STAGING)
        self.steps.replace.assert_called_once_with(install.STAGING, self.installed, requested_open=True)

    def test_update_replaces_an_installed_app(self):
        write_app(self.installed, "old")
        install.main([], command="update", installed=self.installed)
        self.steps.replace.assert_called_once_with(install.STAGING, self.installed, requested_open=False)

    def test_make_passes_arguments_through(self):
        for command in ("install", "update"):
            with patch.dict(tasks.COMMANDS, {command: Mock(return_value=0)}):
                self.assertEqual(tasks.main([command, "--open"]), 0)
                tasks.COMMANDS[command].assert_called_once_with(["--open"])


class BuildNumberTests(unittest.TestCase):
    def test_install_builds_keep_the_build_number(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = Path(directory) / "settings.yml"
            text = "settings:\n  base:\n    MARKETING_VERSION: 0.1.0\n    CURRENT_PROJECT_VERSION: '41'\n"
            settings.write_text(text)
            destination = Path(directory) / "install/Arx.app"
            with patch.object(versioning, "SETTINGS", settings), \
                    patch.object(release.build_app, "main", return_value=Path("/tmp/Arx.app")) as build, \
                    patch.object(release, "stage") as stage, patch.dict("os.environ", {"ARX_BUILD_NUMBER": "99"}):
                release.build(bump=False, destination=destination)
            self.assertIn("CURRENT_PROJECT_VERSION=41", build.call_args.kwargs["build_settings"])
            stage.assert_called_once_with(Path("/tmp/Arx.app"), destination)
            self.assertEqual(settings.read_text(), text)


class SymbolTests(unittest.TestCase):
    def test_the_dsym_is_archived_next_to_the_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "DerivedData/Arx.app"
            dsym = root / "DerivedData/Arx.app.dSYM/Contents/Resources/DWARF"
            dsym.mkdir(parents=True)
            (dsym / "Arx").write_bytes(b"dwarf")
            with patch.object(release, "DSYMS", root / "dSYMs"), \
                    patch("sys.stdout", new_callable=io.StringIO):
                archive = release.keep_dsym(app, "0.1.0", "41")
            self.assertEqual(archive, root / f"dSYMs/Arx-0.1.0-41-{release.ARCHITECTURE}.dSYM.zip")
            with zipfile.ZipFile(archive) as contents:
                self.assertIn("Arx.app.dSYM/Contents/Resources/DWARF/Arx", contents.namelist())

    def test_a_missing_dsym_warns_without_failing(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertIsNone(release.keep_dsym(Path(directory) / "Arx.app", "0.1.0", "41"))
        self.assertIn("can't be symbolicated", output.getvalue())

    def test_bundle_size_counts_links_once(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "Arx.app"
            (bundle / "Versions/A").mkdir(parents=True)
            (bundle / "Versions/A/Engine").write_bytes(b"x" * 1000)
            (bundle / "Versions/Current").symlink_to("A")
            (bundle / "Engine").symlink_to("Versions/Current/Engine")
            self.assertLess(release.size_in_bytes(bundle), 1100)


if __name__ == "__main__":
    unittest.main()
