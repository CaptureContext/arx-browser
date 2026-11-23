"""make appcast and the Sparkle settings in the project spec (DEV-859), without Sparkle's tools or a keychain."""

import base64
import plistlib
import re
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from Scripts import appcast
from Scripts.core.paths import ROOT


REPOSITORY = "example/arx-releases"
KEY = "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="
SIGNATURE = "c2lnbmF0dXJl"


def write_image(directory, version, build):
    path = Path(directory) / f"Arx-{version}-{build}-arm64.dmg"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(f"disk image {build}".encode())
    return path


def write_app(directory, *, version="0.2.0", build="5", key=KEY, feed=None, beta_feed=None, channel="stable"):
    app = Path(directory) / "Arx.app"
    (app / "Contents").mkdir(parents=True)
    with (app / "Contents/Info.plist").open("wb") as output:
        plistlib.dump({
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "SUPublicEDKey": key,
            "SUFeedURL": feed or appcast.feed_url(REPOSITORY),
            "ArxBetaFeedURL": beta_feed or appcast.beta_feed_url(REPOSITORY),
            "ArxUpdateChannel": channel,
        }, output)
    return app


def appcast_xml(image_name, build, *, deltas=()):
    delta_enclosures = "".join(
        f'<enclosure url="https://example.com/{name}" sparkle:deltaFrom="{source}" '
        f'sparkle:edSignature="delta" length="1" type="application/octet-stream"/>'
        for name, source in deltas
    )
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        f'<rss version="2.0" xmlns:sparkle="{appcast.SPARKLE}"><channel><item>'
        f"<title>{build}</title><sparkle:version>{build}</sparkle:version>"
        f"<sparkle:deltas>{delta_enclosures}</sparkle:deltas>"
        f'<enclosure url="https://github.com/{REPOSITORY}/releases/download/0.2.0/{image_name}" '
        f'sparkle:edSignature="{SIGNATURE}" length="10" type="application/octet-stream"/>'
        "</item></channel></rss>"
    )


class DiskImageTests(unittest.TestCase):
    def test_reads_version_and_build_from_make_dmgs_name(self):
        image = appcast.parse_image("/x/Arx-0.2.0-12-arm64.dmg")
        self.assertEqual((image.version, image.build, image.tag), ("0.2.0", 12, "0.2.0"))

    def test_other_names_are_refused(self):
        for name in ("Arx.dmg", "Arx-0.2.0-arm64.dmg", "Arx-0.2.0-twelve-arm64.dmg", "Other-0.2.0-12-arm64.dmg"):
            with self.subTest(name), self.assertRaises(ValueError):
                appcast.parse_image(Path("/x") / name)

    def test_previous_releases_must_be_older_builds(self):
        with tempfile.TemporaryDirectory() as directory:
            write_image(directory, "0.1.0", 3)
            write_image(directory, "0.1.0", 4)
            current = appcast.parse_image(Path(directory) / "Arx-0.2.0-5-arm64.dmg")
            self.assertEqual([image.build for image in appcast.previous_images(directory, current)], [3, 4])

            write_image(directory, "0.2.0", 5)
            with self.assertRaisesRegex(ValueError, "isn't newer"):
                appcast.previous_images(directory, current)

    def test_a_version_released_with_another_build_is_refused(self):
        # The tag is the version alone, so 0.1.0 can't be released twice.
        with tempfile.TemporaryDirectory() as directory:
            write_image(directory, "0.1.0", 3)
            current = appcast.parse_image(Path(directory) / "Arx-0.1.0-4-arm64.dmg")
            with self.assertRaisesRegex(ValueError, r"Version 0\.1\.0 was already released as Arx-0\.1\.0-3-arm64\.dmg.*Bump the version"):
                appcast.previous_images(directory, current)
            # A previous folder with two builds of one older version, from before tags lost the
            # build, is still fine.
            write_image(directory, "0.1.0", 4)
            newer = appcast.parse_image(Path(directory) / "Arx-0.1.1-5-arm64.dmg")
            self.assertEqual([image.build for image in appcast.previous_images(directory, newer)], [3, 4])

    def test_arx_dmg_beside_the_previous_releases_changes_nothing(self):
        # Every release carries a copy named Arx.dmg; downloaded with the others, it isn't a release.
        with tempfile.TemporaryDirectory() as directory:
            write_image(directory, "0.1.0", 3)
            write_image(directory, "0.1.1", 4)
            current = appcast.parse_image(Path(directory) / "Arx-0.2.0-5-arm64.dmg")
            before = appcast.previous_images(directory, current)
            (Path(directory) / appcast.DOWNLOAD_IMAGE).write_bytes(b"disk image 4")
            self.assertEqual(appcast.previous_images(directory, current), before)
            self.assertEqual([image.build for image in before], [3, 4])

    def test_an_empty_folder_is_a_first_release(self):
        with tempfile.TemporaryDirectory() as directory:
            current = appcast.parse_image("/x/Arx-0.1.0-3-arm64.dmg")
            self.assertEqual(appcast.previous_images(directory, current), [])

    def test_a_missing_folder_is_refused(self):
        current = appcast.parse_image("/x/Arx-0.1.0-3-arm64.dmg")
        with self.assertRaises(ValueError):
            appcast.previous_images("/nonexistent/arx-releases", current)


class ConfigurationTests(unittest.TestCase):
    def test_repository_must_be_owner_and_name(self):
        self.assertEqual(appcast.repository(" example/arx "), "example/arx")
        for value in ("", "example", "https://github.com/example/arx", "ARX_RELEASES_OWNER/ARX_RELEASES_REPOSITORY"):
            with self.subTest(value), self.assertRaises(ValueError):
                appcast.repository(value)

    def test_feed_and_downloads_live_in_the_repositorys_releases(self):
        image = appcast.parse_image("/x/Arx-0.2.0-5-arm64.dmg")
        self.assertEqual(
            appcast.feed_url(REPOSITORY),
            "https://github.com/example/arx-releases/releases/latest/download/appcast.xml",
        )
        self.assertEqual(
            appcast.download_prefix(REPOSITORY, image),
            "https://github.com/example/arx-releases/releases/download/0.2.0/",
        )

    def test_the_app_must_match_the_image_and_trust_a_key(self):
        image = appcast.parse_image("/x/Arx-0.2.0-5-arm64.dmg")
        with tempfile.TemporaryDirectory() as directory:
            good = appcast.app_info(write_app(Path(directory) / "good"))
            self.assertEqual(appcast.app_problems(good, image, REPOSITORY), [])

            keyless = appcast.app_info(write_app(Path(directory) / "keyless", key=""))
            self.assertTrue(any("SUPublicEDKey" in problem for problem in appcast.app_problems(keyless, image, REPOSITORY)))

            placeholder = appcast.feed_url("ARX_RELEASES_OWNER/ARX_RELEASES_REPOSITORY")
            unpublished = appcast.app_info(write_app(Path(directory) / "feed", feed=placeholder))
            self.assertTrue(any("SUFeedURL" in problem for problem in appcast.app_problems(unpublished, image, REPOSITORY)))

            older = appcast.app_info(write_app(Path(directory) / "older", build="4"))
            self.assertTrue(any("build" in problem for problem in appcast.app_problems(older, image, REPOSITORY)))

    def test_generate_appcast_lists_only_the_new_release_and_never_gets_the_key(self):
        image = appcast.parse_image("/x/Arx-0.2.0-5-arm64.dmg")
        arguments = appcast.generate_arguments(Path("/bin"), Path("/out"), REPOSITORY, image)
        self.assertEqual(arguments[0], "/bin/generate_appcast")
        self.assertEqual(arguments[arguments.index("--maximum-versions") + 1], "1")
        self.assertEqual(arguments[arguments.index("--versions") + 1], "5")
        self.assertEqual(arguments[arguments.index("--account") + 1], appcast.KEY_ACCOUNT)
        self.assertEqual(arguments[arguments.index("--download-url-prefix") + 1], appcast.download_prefix(REPOSITORY, image))
        for option in ("-s", "--ed-key-file", "-f"):
            self.assertNotIn(option, arguments)
        self.assertEqual(arguments[-1], "/out")

    def test_the_release_command_is_only_text(self):
        image = appcast.parse_image("/x/Arx-0.2.0-5-arm64.dmg")
        command, feed = appcast.release_commands(
            REPOSITORY, image, [Path("/out/Arx-0.2.0-5-arm64.dmg"), Path("/out/appcast.xml")], Path("/out"),
        )
        self.assertTrue(command.startswith("gh release create 0.2.0 --repo example/arx-releases --title 0.2.0"))
        self.assertIn("--latest", command)
        self.assertNotIn("--prerelease", command)
        self.assertTrue(command.endswith("/out/Arx-0.2.0-5-arm64.dmg /out/appcast.xml"))
        # A stable release is the newest build of all, so it replaces the Beta feed too.
        self.assertEqual(feed, "gh release upload beta-feed --repo example/arx-releases --clobber /out/appcast-beta.xml")

    def test_a_beta_release_is_a_prerelease_that_only_moves_the_beta_feed(self):
        image = appcast.parse_image("/x/Arx-0.3.0-6-arm64.dmg")
        command, feed = appcast.release_commands(
            REPOSITORY, image, [Path("/out/Arx-0.3.0-6-arm64.dmg")], Path("/out"), "beta", Path("/notes.md"),
        )
        self.assertTrue(command.startswith("gh release create 0.3.0 --repo example/arx-releases"))
        self.assertIn("--prerelease --latest=false", command)
        self.assertNotIn("appcast.xml", command)
        self.assertIn("--notes-file /notes.md", command)
        self.assertIn("--title 0.3.0 ", command)
        self.assertTrue(feed.endswith("/out/appcast-beta.xml"))

    def test_the_beta_feed_is_a_fixed_prereleases_asset(self):
        self.assertEqual(
            appcast.beta_feed_url(REPOSITORY),
            "https://github.com/example/arx-releases/releases/download/beta-feed/appcast-beta.xml",
        )
        setup = appcast.beta_feed_setup_command(REPOSITORY)
        self.assertTrue(setup.startswith("gh release create beta-feed --repo example/arx-releases --prerelease --latest=false"))

    def test_the_app_must_be_built_for_the_channel_and_read_both_feeds(self):
        image = appcast.parse_image("/x/Arx-0.2.0-5-arm64.dmg")
        with tempfile.TemporaryDirectory() as directory:
            beta = appcast.app_info(write_app(Path(directory) / "beta", channel="beta"))
            self.assertEqual(appcast.app_problems(beta, image, REPOSITORY, "beta"), [])
            self.assertTrue(any("--channel stable" in problem for problem in appcast.app_problems(beta, image, REPOSITORY)))

            stable = appcast.app_info(write_app(Path(directory) / "stable"))
            self.assertTrue(any("--channel beta" in problem for problem in appcast.app_problems(stable, image, REPOSITORY, "beta")))

            placeholder = appcast.beta_feed_url("ARX_RELEASES_OWNER/ARX_RELEASES_REPOSITORY")
            unpublished = appcast.app_info(write_app(Path(directory) / "feed", beta_feed=placeholder))
            self.assertTrue(any("ArxBetaFeedURL" in problem for problem in appcast.app_problems(unpublished, image, REPOSITORY)))

    def test_release_notes_are_short_markdown(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(appcast.notes_problems(None), [])
            self.assertTrue(appcast.notes_problems(root / "missing.md"))
            (root / "notes.txt").write_text("Hello")
            self.assertTrue(appcast.notes_problems(root / "notes.txt"))
            (root / "empty.md").write_text("  \n")
            self.assertTrue(appcast.notes_problems(root / "empty.md"))
            (root / "notes.md").write_text("- Update channels\n")
            self.assertEqual(appcast.notes_problems(root / "notes.md"), [])

    def test_notes_are_embedded_and_link_the_full_notes(self):
        image = appcast.parse_image("/x/Arx-0.2.0-5-arm64.dmg")
        plain = appcast.generate_arguments(Path("/bin"), Path("/out"), REPOSITORY, image)
        self.assertNotIn("--embed-release-notes", plain)
        self.assertEqual(plain[plain.index("--full-release-notes-url") + 1], appcast.FULL_RELEASE_NOTES)
        embedded = appcast.generate_arguments(
            Path("/bin"), Path("/out"), REPOSITORY, image, full_notes="https://example.com/notes", embed_notes=True,
        )
        self.assertIn("--embed-release-notes", embedded)
        self.assertEqual(embedded[embedded.index("--full-release-notes-url") + 1], "https://example.com/notes")
        self.assertEqual(appcast.notes_name(image), "Arx-0.2.0-5-arm64.md")

    def test_every_release_carries_arx_dmg(self):
        image = appcast.parse_image("/x/Arx-0.2.0-5-arm64.dmg")
        for channel, feeds in (("stable", ["appcast.xml"]), ("beta", [])):
            with self.subTest(channel), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                (output / "Arx5-4.delta").write_bytes(b"delta")
                names = [path.name for path in appcast.release_assets(output, image, channel)]
                self.assertEqual(names, ["Arx-0.2.0-5-arm64.dmg", "Arx.dmg", "Arx5-4.delta", *feeds])

    def test_arx_dmg_is_a_copy_of_the_versioned_image(self):
        image = appcast.parse_image("/x/Arx-0.2.0-5-arm64.dmg")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / image.path.name).write_bytes(b"disk image 5")
            copy = appcast.stage_download_image(output, image)
            self.assertEqual(copy, output / "Arx.dmg")
            self.assertEqual(copy.read_bytes(), b"disk image 5")

    def test_feeds_per_channel(self):
        for channel, expected in (("stable", ["appcast-beta.xml", "appcast.xml"]), ("beta", ["appcast-beta.xml"])):
            with self.subTest(channel), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                (output / "appcast.xml").write_text("<rss/>")
                feeds = appcast.write_feeds(output, channel)
                self.assertEqual(sorted(path.name for path in output.glob("*.xml")), expected)
                self.assertEqual(sorted(path.name for path in feeds), expected)
                self.assertTrue(all(path.read_text() == "<rss/>" for path in feeds))


class OutputTests(unittest.TestCase):
    def test_the_output_may_not_hold_the_releases_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = write_image(root / "release", "0.2.0", 5)
            app = write_app(root / "release")
            previous = root / "release/appcast"
            previous.mkdir()
            inputs = [image, previous, app]
            # The previous release's own output folder, or the folder make dmg writes to.
            self.assertTrue(appcast.overlap_problems(previous, inputs))
            self.assertTrue(appcast.overlap_problems(root / "release", inputs))
            self.assertEqual(appcast.overlap_problems(root / "release/next", inputs), [])

    def test_an_overlapping_output_stops_before_anything_is_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = write_image(root / "release", "0.2.0", 5)
            app = write_app(root / "release")
            previous = root / "previous"
            older = write_image(previous, "0.1.0", 4)
            with patch.object(appcast, "run") as run, self.assertRaisesRegex(ValueError, "another --output"):
                appcast.main([
                    str(image), "--repository", REPOSITORY, "--previous", str(previous),
                    "--output", str(previous), "--app", str(app),
                ])
            run.assert_not_called()
            self.assertTrue(older.is_file())
            self.assertTrue(image.is_file())


class AppcastTests(unittest.TestCase):
    def test_reads_the_new_images_signature_not_a_deltas(self):
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / "appcast.xml"
            feed.write_text(appcast_xml("Arx-0.2.0-5-arm64.dmg", 5, deltas=[("Arx5-4.delta", 4)]))
            self.assertEqual(appcast.enclosure_signature(feed, "Arx-0.2.0-5-arm64.dmg"), SIGNATURE)
            self.assertEqual(appcast.appcast_versions(feed), ["5"])
            with self.assertRaises(ValueError):
                appcast.enclosure_signature(feed, "Arx-0.2.0-6-arm64.dmg")

    def test_makes_the_release_folder_without_publishing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = write_image(root / "release", "0.2.0", 5)
            previous = root / "previous"
            write_image(previous, "0.1.0", 3)
            write_image(previous, "0.1.0", 4)
            # The previous release's Arx.dmg, downloaded with its versioned disk image.
            (previous / appcast.DOWNLOAD_IMAGE).write_bytes(b"disk image 4")
            app = write_app(root)
            output = root / "out"
            bin_directory = root / "bin"
            for name in appcast.TOOLS:
                (bin_directory / name).parent.mkdir(parents=True, exist_ok=True)
                (bin_directory / name).touch()
            commands = []

            def run(arguments, **_):
                commands.append([str(argument) for argument in arguments])
                if Path(arguments[0]).name == "generate_appcast":
                    folder = Path(arguments[-1])
                    # generate_appcast reads every disk image here as an update: no Arx.dmg yet.
                    self.assertEqual(sorted(path.name for path in folder.glob("*.dmg")), [
                        "Arx-0.1.0-3-arm64.dmg", "Arx-0.1.0-4-arm64.dmg", "Arx-0.2.0-5-arm64.dmg",
                    ])
                    (folder / "Arx5-4.delta").write_bytes(b"delta")
                    (folder / "Arx5-3.delta").write_bytes(b"delta")
                    (folder / "appcast.xml").write_text(
                        appcast_xml(image.name, 5, deltas=[("Arx5-4.delta", 4), ("Arx5-3.delta", 3)])
                    )
                return ""

            printed = []
            with (
                patch.object(appcast, "run", side_effect=run),
                patch.object(appcast, "TOOL_DIRECTORIES", (bin_directory,)),
                patch.object(appcast, "public_key", return_value=KEY),
                patch("builtins.print", side_effect=lambda *values, **_: printed.append(" ".join(map(str, values)))),
            ):
                appcast.main([
                    str(image), "--repository", REPOSITORY, "--previous", str(previous),
                    "--output", str(output), "--app", str(app),
                ])

            programs = [Path(command[0]).name for command in commands]
            self.assertEqual(programs, ["codesign", "xcrun", "generate_appcast", "sign_update"])
            self.assertEqual(commands[1], ["xcrun", "stapler", "validate", str(image.resolve())])
            self.assertEqual(commands[-1][1:], [
                "--account", appcast.KEY_ACCOUNT, "--verify", str(output.resolve() / image.name), SIGNATURE,
            ])
            self.assertNotIn("gh", programs)
            gh = next(line for line in printed if line.startswith("gh release create 0.2.0 "))
            self.assertIn("Arx5-3.delta", gh)
            self.assertIn("appcast.xml", gh)
            self.assertNotIn("Arx-0.1.0-4-arm64.dmg", gh)
            self.assertTrue(any(line.startswith("gh release upload beta-feed") for line in printed))
            self.assertTrue((output / "appcast-beta.xml").is_file())
            self.assertIn(f" {output.resolve() / 'Arx-0.2.0-5-arm64.dmg'} {output.resolve() / 'Arx.dmg'} ", gh)
            self.assertEqual((output / "Arx.dmg").read_bytes(), image.read_bytes())
            self.assertEqual(sorted(path.name for path in output.glob("*.dmg")), [
                "Arx-0.1.0-3-arm64.dmg", "Arx-0.1.0-4-arm64.dmg", "Arx-0.2.0-5-arm64.dmg", "Arx.dmg",
            ])

    def test_a_different_keychain_key_stops_before_signing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = write_image(root / "release", "0.2.0", 5)
            (root / "previous").mkdir()
            app = write_app(root)
            bin_directory = root / "bin"
            bin_directory.mkdir()
            for name in appcast.TOOLS:
                (bin_directory / name).touch()
            with (
                patch.object(appcast, "run") as run,
                patch.object(appcast, "TOOL_DIRECTORIES", (bin_directory,)),
                patch.object(appcast, "public_key", return_value="another key"),
                self.assertRaisesRegex(ValueError, "isn't the one the app trusts"),
            ):
                appcast.main([
                    str(image), "--repository", REPOSITORY, "--previous", str(root / "previous"),
                    "--output", str(root / "out"), "--app", str(app),
                ])
            run.assert_not_called()


class ProjectSettingsTests(unittest.TestCase):
    """The app's Info.plist takes Sparkle's feed and key from build settings, and the defaults keep
    the updater off: an empty key and a placeholder feed that AppUpdaterClient refuses."""

    def setUp(self):
        self.spec = (ROOT / ".xcodegen/macOS.yml").read_text()

    def setting(self, name):
        match = re.search(rf"^\s+{name}:\s*(.*)$", self.spec, re.MULTILINE)
        self.assertIsNotNone(match, f"{name} is missing from .xcodegen/macOS.yml")
        return match.group(1).strip()

    def test_info_plist_reads_feed_and_key_from_build_settings(self):
        self.assertEqual(self.setting("SUFeedURL"), "$(ARX_UPDATE_FEED_URL)")
        self.assertEqual(self.setting("SUPublicEDKey"), "$(ARX_UPDATE_PUBLIC_ED_KEY)")
        self.assertEqual(self.setting("ArxBetaFeedURL"), "$(ARX_UPDATE_BETA_FEED_URL)")
        self.assertEqual(self.setting("ArxUpdateChannel"), "$(ARX_UPDATE_CHANNEL)")

    def test_builds_are_stable_and_both_feeds_are_the_arx_repositorys_releases(self):
        self.assertEqual(self.setting("ARX_UPDATE_CHANNEL"), "stable")
        self.assertEqual(self.setting("ARX_UPDATE_FEED_URL"), appcast.feed_url(appcast.RELEASES_REPOSITORY))
        self.assertEqual(self.setting("ARX_UPDATE_BETA_FEED_URL"), appcast.beta_feed_url(appcast.RELEASES_REPOSITORY))
        self.assertEqual(appcast.repository(appcast.RELEASES_REPOSITORY), appcast.RELEASES_REPOSITORY)
        self.assertEqual(appcast.parser().parse_args(["--previous", "x"]).repository, appcast.RELEASES_REPOSITORY)

    def test_the_update_key_is_a_public_ed25519_key(self):
        # AppUpdaterClient.Configuration treats an empty SUPublicEDKey as no updater, so the
        # setting holds the 32-byte public key generate_keys printed, in Base64.
        key = self.setting("ARX_UPDATE_PUBLIC_ED_KEY").strip('"')
        self.assertEqual(len(base64.b64decode(key, validate=True)), 32)

    def test_helium_keeps_its_own_updater_off(self):
        # Arx's Sparkle lives in the app; the engine build leaves Helium's disabled.
        self.assertIn("enable_sparkle=false", (ROOT / "Scripts/engine/build.py").read_text())

if __name__ == "__main__":
    unittest.main()
