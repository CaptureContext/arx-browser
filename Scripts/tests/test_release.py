"""Release signing order, entitlement checks and missing configuration, without codesign or the network."""

import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from Scripts import release, signing, tasks
from Scripts.engine.bundle import HELPERS


MACHO = b"\xcf\xfa\xed\xfe" + bytes(12)


def write_macho(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(MACHO)
    path.chmod(0o755)


def write_bundle(path, executable):
    contents = path / "Contents"
    contents.mkdir(parents=True)
    with (contents / "Info.plist").open("wb") as output:
        plistlib.dump(
            {"CFBundleExecutable": executable, "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "7"},
            output,
        )
    write_macho(contents / "MacOS" / executable)


def make_profile(directory, kind=signing.DEVELOPER_ID, contents=b"profile"):
    path = Path(directory) / f"{kind}.provisionprofile"
    path.write_bytes(contents)
    return signing.Profile(path, "PROFILE-UUID", kind)


def make_signer(directory, *, developer_id=True):
    kind = signing.DEVELOPER_ID if developer_id else signing.DEVELOPMENT
    return release.Signer("A" * 40, "TEAM123456", developer_id, make_profile(directory, kind))


def make_app(root, *, helpers=HELPERS):
    """An app laid out like the real one, with stand-in Mach-O files."""
    app = root / "Arx.app"
    write_bundle(app, "Arx")
    write_macho(app / "Contents/Helpers/ArxMCP")
    write_bundle(app / "Contents/Helpers/ArxFairPlay.app", "ArxFairPlay")
    framework = app / "Contents/Frameworks/Arx Framework.framework"
    version = framework / "Versions/1.0"
    write_macho(version / "Arx Framework")
    (version / "Resources").mkdir(parents=True)
    (version / "Resources/install.sh").write_text("#!/bin/sh\n")
    for name in helpers:
        write_bundle(version / "Helpers" / f"{name}.app", name)
    write_macho(version / "Helpers/chrome_crashpad_handler")
    write_macho(version / "Libraries/libaperitif.dylib")
    (framework / "Versions/Current").symlink_to("1.0")
    for name in ("Arx Framework", "Helpers", "Libraries", "Resources"):
        (framework / name).symlink_to(f"Versions/Current/{name}")
    return app


def add_sparkle(app):
    """Sparkle.framework as its Swift package ships it: Autoupdate, Updater.app and two XPC services."""
    framework = app / "Contents/Frameworks/Sparkle.framework"
    version = framework / "Versions/B"
    write_macho(version / "Sparkle")
    write_macho(version / "Autoupdate")
    write_bundle(version / "Updater.app", "Updater")
    write_bundle(version / "XPCServices/Installer.xpc", "Installer")
    write_bundle(version / "XPCServices/Downloader.xpc", "Downloader")
    (framework / "Versions/Current").symlink_to("B")
    for name in ("Sparkle", "Autoupdate", "Updater.app", "XPCServices"):
        (framework / name).symlink_to(f"Versions/Current/{name}")
    return framework


class SigningOrderTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.app = make_app(self.root)

    def test_signs_inside_out_with_the_app_last(self):
        parts = release.code_parts(self.app)
        paths = [part.path for part in parts]
        self.assertEqual(paths[-1], self.app)
        for index, path in enumerate(paths):
            for later in paths[index + 1:]:
                self.assertFalse(
                    path in later.parents,
                    f"{path.name} is signed before {later.name}, which it contains",
                )
        framework = self.app / "Contents/Frameworks/Arx Framework.framework"
        self.assertLess(paths.index(framework / "Versions/1.0/Libraries/libaperitif.dylib"), paths.index(framework))
        self.assertLess(paths.index(framework / "Versions/1.0/Helpers/Arx Helper (GPU).app"), paths.index(framework))

    def test_each_piece_of_code_is_signed_once_through_its_real_path(self):
        paths = [part.path for part in release.code_parts(self.app)]
        self.assertEqual(len(paths), len(set(paths)))
        relative = {str(path.relative_to(self.app)) for path in paths}
        version = "Contents/Frameworks/Arx Framework.framework/Versions/1.0"
        self.assertEqual(relative, {
            ".", "Contents/Helpers/ArxMCP", "Contents/Helpers/ArxFairPlay.app",
            "Contents/Frameworks/Arx Framework.framework",
            f"{version}/Helpers/chrome_crashpad_handler", f"{version}/Libraries/libaperitif.dylib",
            *(f"{version}/Helpers/{name}.app" for name in HELPERS),
        })

    def test_helpers_get_their_own_entitlements_and_options(self):
        parts = {part.path.name: part for part in release.code_parts(self.app)}
        for name in ("Arx Helper (Renderer)", "Arx Helper (Aperitif Renderer)"):
            self.assertEqual(parts[f"{name}.app"].entitlements, release.ENTITLEMENTS / "helper-renderer.plist")
            self.assertEqual(parts[f"{name}.app"].options, release.JIT_RUNTIME)
        for name in ("Arx Helper (GPU)", "Arx Helper (Aperitif GPU)"):
            self.assertEqual(parts[f"{name}.app"].entitlements, release.ENTITLEMENTS / "helper-gpu.plist")
        for name in ("Arx Helper", "Arx Helper (Alerts)", "Arx Helper (Aperitif)", "Arx Helper (Aperitif Alerts)"):
            self.assertIsNone(parts[f"{name}.app"].entitlements)
            self.assertEqual(parts[f"{name}.app"].options, release.FULL_RUNTIME)
        self.assertEqual(parts["Arx.app"].entitlements, release.APP_ENTITLEMENTS)
        self.assertEqual(parts["ArxMCP"].options, release.FULL_RUNTIME)
        # DEV-1144: the FairPlay helper keeps its sandbox.
        self.assertEqual(parts["ArxFairPlay.app"].entitlements, release.SANDBOXED_HELPERS["ArxFairPlay"])
        self.assertEqual(parts["ArxFairPlay.app"].options, release.FULL_RUNTIME)
        self.assertIsNone(parts["libaperitif.dylib"].options)
        self.assertIsNone(parts["Arx Framework.framework"].options)

    def test_the_fairplay_helper_is_sandboxed_with_outgoing_network_only(self):
        with release.SANDBOXED_HELPERS["ArxFairPlay"].open("rb") as source:
            self.assertEqual(plistlib.load(source), {
                "com.apple.security.app-sandbox": True,
                "com.apple.security.network.client": True,
            })

    def test_entitlement_files_grant_the_jit_chromium_needs(self):
        for name in set(release.JIT_HELPERS.values()):
            with (release.ENTITLEMENTS / name).open("rb") as source:
                self.assertTrue(plistlib.load(source).get(release.JIT), name)

    def signing_paths(self):
        source = self.root / "Arx.entitlements"
        with source.open("wb") as output:
            plistlib.dump({
                "com.apple.security.device.camera": True,
                release.ICLOUD_CONTAINERS: ["iCloud.dev.capturecontext.arx"],
                release.ICLOUD_ENVIRONMENT: "$(ARX_ICLOUD_ENVIRONMENT)",
                release.APS_ENVIRONMENT: "$(ARX_APS_ENVIRONMENT)",
            }, output)
        return (
            patch.object(release, "APP_ENTITLEMENTS", source),
            patch.object(release, "SIGNING_ENTITLEMENTS", self.root / "release/Arx.entitlements"),
        )

    def signed_app_entitlements(self, signer):
        source, destination = self.signing_paths()
        with source, destination, patch.object(release, "run") as run:
            release.sign(self.app, signer)
        command = [call.args[0] for call in run.call_args_list][-1]
        with Path(command[command.index("--entitlements") + 1]).open("rb") as rendered:
            return command, plistlib.load(rendered)

    def test_developer_id_embeds_its_profile_and_production_environments(self):
        signer = make_signer(self.root, developer_id=True)
        command, entitlements = self.signed_app_entitlements(signer)
        self.assertEqual(command[-1], str(self.app))
        self.assertEqual((self.app / release.EMBEDDED_PROFILE).read_bytes(), signer.profile.path.read_bytes())
        self.assertEqual(entitlements[release.ICLOUD_ENVIRONMENT], "Production")
        self.assertEqual(entitlements[release.APS_ENVIRONMENT], "production")
        self.assertEqual(entitlements[release.ICLOUD_CONTAINERS], ["iCloud.dev.capturecontext.arx"])
        self.assertEqual(entitlements[release.APPLICATION_IDENTIFIER], "TEAM123456.dev.capturecontext.arx")
        self.assertEqual(entitlements[release.TEAM_IDENTIFIER], "TEAM123456")
        self.assertTrue(entitlements["com.apple.security.device.camera"])

    def test_development_identity_embeds_the_development_profile(self):
        signer = make_signer(self.root, developer_id=False)
        _, entitlements = self.signed_app_entitlements(signer)
        self.assertEqual((self.app / release.EMBEDDED_PROFILE).read_bytes(), signer.profile.path.read_bytes())
        self.assertEqual(entitlements[release.ICLOUD_ENVIRONMENT], "Development")
        self.assertEqual(entitlements[release.APS_ENVIRONMENT], "development")

    def test_only_the_app_gets_the_icloud_entitlements(self):
        source, destination = self.signing_paths()
        with source, destination, patch.object(release, "run") as run:
            release.sign(self.app, make_signer(self.root))
        commands = [call.args[0] for call in run.call_args_list]
        for command in commands[:-1]:
            if "--entitlements" in command:
                self.assertIn(Path(command[command.index("--entitlements") + 1]).parent, {release.ENTITLEMENTS})

    def test_sign_never_uses_deep_and_timestamps_developer_id(self):
        signer = make_signer(self.root, developer_id=True)
        source, destination = self.signing_paths()
        with source, destination, patch.object(release, "run") as run:
            release.sign(self.app, signer)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(commands[-1][-1], str(self.app))
        for command in commands:
            self.assertNotIn("--deep", command)
            self.assertIn("--timestamp", command)
            self.assertEqual(command[command.index("--sign") + 1], "A" * 40)

    def test_a_developer_id_signature_can_leave_the_timestamp_server_out(self):
        signer = make_signer(self.root, developer_id=True)
        source, destination = self.signing_paths()
        with source, destination, patch.object(release, "run") as run:
            release.sign(self.app, signer, timestamp=False)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertTrue(commands)
        for command in commands:
            self.assertIn("--timestamp=none", command)
            self.assertNotIn("--timestamp", command)

    def test_development_dry_run_skips_the_timestamp_server(self):
        signer = make_signer(self.root, developer_id=False)
        arguments = release.sign_arguments(release.code_parts(self.app)[-1], signer)
        self.assertIn("--timestamp=none", arguments)

    def test_sparkle_is_signed_inside_out_with_the_hardened_runtime(self):
        framework = add_sparkle(self.app)
        version = framework / "Versions/B"
        parts = release.code_parts(self.app)
        paths = [part.path for part in parts]
        by_path = {part.path: part for part in parts}
        for inner in ("Autoupdate", "Updater.app", "XPCServices/Installer.xpc", "XPCServices/Downloader.xpc"):
            self.assertLess(paths.index(version / inner), paths.index(framework), inner)
            self.assertEqual(by_path[version / inner].options, release.FULL_RUNTIME, inner)
        # Symlinks at the framework's top level aren't signed a second time.
        self.assertNotIn(framework / "Autoupdate", paths)
        self.assertTrue(by_path[version / "XPCServices/Downloader.xpc"].preserve_entitlements)
        self.assertFalse(by_path[version / "XPCServices/Installer.xpc"].preserve_entitlements)

    def test_sparkles_downloader_keeps_its_entitlements(self):
        add_sparkle(self.app)
        signer = make_signer(self.root)
        parts = {part.path.name: part for part in release.code_parts(self.app)}
        downloader = release.sign_arguments(parts["Downloader.xpc"], signer)
        installer = release.sign_arguments(parts["Installer.xpc"], signer)
        self.assertIn("--preserve-metadata=entitlements", downloader)
        self.assertNotIn("--entitlements", downloader)
        self.assertNotIn("--preserve-metadata=entitlements", installer)

    def test_missing_chromium_helper_fails(self):
        app = make_app(self.root / "partial", helpers=HELPERS[:-1])
        with self.assertRaisesRegex(ValueError, "Arx Helper \\(Aperitif Alerts\\)"):
            release.code_parts(app)


class CheckTests(unittest.TestCase):
    def part(self, name, *, options=release.FULL_RUNTIME):
        return release.Part(Path(f"/Arx.app/{name}"), options, None, name.endswith(".app"))

    def test_debug_entitlements_are_rejected(self):
        problems = release.entitlement_problems(self.part("Arx.app"), {"com.apple.security.get-task-allow": True})
        self.assertEqual(len(problems), 1)
        self.assertIn("get-task-allow", problems[0])

    def test_jit_is_required_for_renderer_and_gpu_helpers_only(self):
        self.assertTrue(release.entitlement_problems(self.part("Arx Helper (Renderer).app"), {}))
        self.assertFalse(release.entitlement_problems(self.part("Arx Helper (GPU).app"), {release.JIT: True}))
        self.assertTrue(release.entitlement_problems(self.part("Arx Helper.app"), {release.JIT: True}))
        self.assertTrue(release.entitlement_problems(self.part("Arx.app"), {release.JIT: True}))
        self.assertFalse(release.entitlement_problems(self.part("Arx.app"), {"com.apple.security.device.camera": True}))

    def test_unsigned_foreign_and_unhardened_code_is_rejected(self):
        part = self.part("Contents/Helpers/ArxMCP")
        self.assertIn("unsigned", release.signature_problems(part, "code object is not signed at all", "TEAM123456")[0])
        foreign = "TeamIdentifier=OTHER12345\nCodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1"
        self.assertIn("not signed by team", release.signature_problems(part, foreign, "TEAM123456")[0])
        unhardened = "TeamIdentifier=TEAM123456\nCodeDirectory v=20500 size=1 flags=0x0(none) hashes=1"
        self.assertIn("hardened runtime", release.signature_problems(part, unhardened, "TEAM123456")[0])
        valid = "TeamIdentifier=TEAM123456\nCodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1"
        self.assertEqual(release.signature_problems(part, valid, "TEAM123456"), [])

    def test_development_shell_fails_the_check_before_codesign(self):
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(Path(directory))
            write_macho(app / "Contents/MacOS/Arx.debug.dylib")
            signer = make_signer(directory)
            with patch.object(release, "run") as run, self.assertRaisesRegex(ValueError, "development-only code"):
                release.check(app, signer)
            run.assert_not_called()

    def test_app_without_the_expected_profile_or_environment_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(Path(directory))
            profile = make_profile(directory)
            entitlements = {
                release.ICLOUD_CONTAINERS: ["iCloud.dev.capturecontext.arx"],
                release.ICLOUD_ENVIRONMENT: "Production",
                release.APS_ENVIRONMENT: "production",
                **release.identity_entitlements("TEAM123456"),
            }
            self.assertIn("embedded.provisionprofile", release.profile_problems(app, entitlements, profile, "TEAM123456")[0])
            (app / release.EMBEDDED_PROFILE).write_bytes(b"another profile")
            self.assertIn("isn't the developer id profile", release.profile_problems(app, entitlements, profile, "TEAM123456")[0])
            (app / release.EMBEDDED_PROFILE).write_bytes(b"profile")
            self.assertEqual(release.profile_problems(app, entitlements, profile, "TEAM123456"), [])
            unidentified = {key: value for key, value in entitlements.items() if key != release.APPLICATION_IDENTIFIER}
            self.assertIn(release.APPLICATION_IDENTIFIER, release.profile_problems(app, unidentified, profile, "TEAM123456")[0])
            self.assertIn(release.TEAM_IDENTIFIER, release.profile_problems(app, entitlements, profile, "OTHER12345")[-1])
            development = {**entitlements, release.ICLOUD_ENVIRONMENT: "Development"}
            self.assertIn("Development", release.profile_problems(app, development, profile, "TEAM123456")[0])
            self.assertIn(release.ICLOUD_CONTAINERS, release.profile_problems(app, {**entitlements, release.ICLOUD_CONTAINERS: []}, profile, "TEAM123456")[0])

    def test_signer_pairs_each_identity_with_its_own_profile(self):
        def options(*arguments):
            return release.parser().parse_args(list(arguments))
        profiles = {}
        def profile(kind, fingerprint):
            profiles[kind] = fingerprint
            return signing.Profile(Path("/profile"), "UUID", kind)
        with (
            patch.object(release.signing, "team", return_value="TEAM123456"),
            patch.object(release.signing, "developer_id", return_value="D" * 40),
            patch.object(release.signing, "identity", return_value="A" * 40),
            patch.object(release.signing, "profile", side_effect=profile),
        ):
            self.assertEqual(release.signer(options()).profile.kind, signing.DEVELOPER_ID)
            self.assertEqual(release.signer(options("--development-identity")).profile.kind, signing.DEVELOPMENT)
        self.assertEqual(profiles, {signing.DEVELOPER_ID: "D" * 40, signing.DEVELOPMENT: "A" * 40})

    def test_unnotarized_developer_id_passes_only_before_notarization(self):
        rejected = subprocess.CompletedProcess([], 3, stdout="", stderr="rejected\nsource=Unnotarized Developer ID")
        with patch.object(release.subprocess, "run", return_value=rejected):
            release.assess(Path("/Arx.app"), "execute", notarized=False)
            with self.assertRaisesRegex(ValueError, "Gatekeeper rejected"):
                release.assess(Path("/Arx.app"), "execute")


class ConfigurationTests(unittest.TestCase):
    def test_missing_developer_id_explains_the_one_time_portal_step(self):
        listing = subprocess.CompletedProcess([], 0, stdout=f'1) {"A" * 40} "Apple Development: Someone (TEAM123456)"')
        with patch.dict(os.environ, {"DEVELOPMENT_TEAM": "TEAM123456"}), patch.object(signing.subprocess, "run", return_value=listing):
            with self.assertRaisesRegex(ValueError, "created once in the Apple Developer portal"):
                signing.developer_id()

    def test_developer_id_of_another_team_is_not_used(self):
        listing = subprocess.CompletedProcess([], 0, stdout=(
            f'1) {"A" * 40} "Developer ID Application: Other (OTHER12345)"\n'
            f'2) {"B" * 40} "Developer ID Application: Arx (TEAM123456)"\n'
        ))
        with patch.dict(os.environ, {"DEVELOPMENT_TEAM": "TEAM123456", "ARX_RELEASE_IDENTITY": ""}), patch.object(signing.subprocess, "run", return_value=listing):
            self.assertEqual(signing.developer_id(), "B" * 40)

    def test_missing_team_fails(self):
        with patch.dict(os.environ, {"DEVELOPMENT_TEAM": ""}), self.assertRaisesRegex(ValueError, "DEVELOPMENT_TEAM"):
            signing.developer_id()

    def test_missing_notary_key_fails_before_building(self):
        environment = {
            "ARX_NOTARY_KEYCHAIN_PROFILE": "", "APP_STORE_CONNECT_API_KEY_KEY_ID": "KEY",
            "APP_STORE_CONNECT_API_KEY_ISSUER_ID": "", "APP_STORE_CONNECT_API_KEY_KEY_FILEPATH": "",
            "APP_STORE_CONNECT_API_KEY_KEY_CONTENT": "",
        }
        with (
            patch.dict(os.environ, environment),
            patch.object(release.signing, "developer_id", return_value="A" * 40),
            patch.object(release.signing, "team", return_value="TEAM123456"),
            patch.object(release.signing, "profile"),
            patch.object(release, "build") as build,
        ):
            with self.assertRaisesRegex(ValueError, "--skip-notarize"):
                release.main([])
            build.assert_not_called()

    def test_inline_notary_key_is_written_privately_and_never_echoed(self):
        environment = {
            "ARX_NOTARY_KEYCHAIN_PROFILE": "", "APP_STORE_CONNECT_API_KEY_KEY_ID": "KEYID",
            "APP_STORE_CONNECT_API_KEY_ISSUER_ID": "ISSUER", "APP_STORE_CONNECT_API_KEY_KEY_FILEPATH": "",
            "APP_STORE_CONNECT_API_KEY_KEY_CONTENT": "secret-key", "APP_STORE_CONNECT_API_KEY_IS_KEY_CONTENT_BASE64": "false",
        }
        with patch.dict(os.environ, environment), tempfile.TemporaryDirectory() as directory:
            credentials = release.notary_credentials(directory)
            key = Path(credentials[credentials.index("--key") + 1])
            self.assertEqual(key.read_text(), "secret-key")
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            accepted = subprocess.CompletedProcess([], 0, stdout='{"id": "1", "status": "Accepted"}', stderr="")
            with patch.object(release.subprocess, "run", return_value=accepted), patch("builtins.print") as output:
                release.notarytool(["submit", "Arx.zip", "--wait"], credentials)
            echoed = " ".join(str(call.args) for call in output.call_args_list)
            for secret in ("KEYID", "ISSUER", str(key)):
                self.assertNotIn(secret, echoed)

    def test_keychain_cleanup_only_touches_the_named_throwaway_keychain(self):
        with patch.dict(os.environ, {"ARX_RELEASE_KEYCHAIN": ""}), patch.object(signing, "run") as run:
            signing.release_cleanup()
        run.assert_not_called()
        with patch.dict(os.environ, {"ARX_RELEASE_KEYCHAIN": "arx-release-1-1"}), patch.object(signing, "run") as run:
            signing.release_cleanup()
        run.assert_called_once_with(["fastlane", "mac", "release_keychain_cleanup"])

    def test_dry_runs_drop_notarization(self):
        def options(*arguments):
            return release.parser().parse_args(list(arguments))
        self.assertEqual(release.selected_steps(options()), list(release.STEPS))
        for arguments in (["--skip-notarize"], ["--development-identity"]):
            steps = release.selected_steps(options(*arguments))
            self.assertFalse(set(release.NOTARIZE_STEPS) & set(steps))
            self.assertIn("sign-dmg", steps)
        self.assertEqual(release.selected_steps(options("--only", "dmg", "--only", "checksum")), ["dmg", "checksum"])
        with self.assertRaisesRegex(ValueError, "Unknown release steps"):
            release.selected_steps(options("--skip", "staple"))

    def test_make_passes_options_only_to_release_commands(self):
        with patch.dict(tasks.COMMANDS, {"dmg": Mock(), "signing-check": Mock(), "cloudkit-probe": Mock()}):
            self.assertEqual(tasks.main(["dmg", "--skip-notarize"]), 0)
            tasks.COMMANDS["dmg"].assert_called_once_with(["--skip-notarize"])
            self.assertEqual(tasks.main(["cloudkit-probe", "--app", "Arx.app"]), 0)
            tasks.COMMANDS["cloudkit-probe"].assert_called_once_with(["--app", "Arx.app"])
            self.assertEqual(tasks.main(["signing-check", "--unexpected"]), 0)
            tasks.COMMANDS["signing-check"].assert_not_called()


class DiskImageTests(unittest.TestCase):
    def test_name_and_checksum_follow_the_app_version_and_build(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(release, "RELEASE", Path(directory)):
            app = make_app(Path(directory))
            image = release.disk_image(app)
            self.assertEqual(image.name, "Arx-1.2.3-7-arm64.dmg")
            image.write_bytes(b"disk image")
            checksum = release.checksum(image)
            self.assertEqual(checksum.name, "Arx-1.2.3-7-arm64.dmg.sha256")
            self.assertTrue(checksum.read_text().endswith("  Arx-1.2.3-7-arm64.dmg\n"))

    def test_the_newest_disk_image_is_never_the_arx_dmg_copy(self):
        # make appcast's Arx.dmg is a copy of a release's disk image, not a build of its own.
        with tempfile.TemporaryDirectory() as directory, patch.object(release, "RELEASE", Path(directory)):
            image = Path(directory) / "Arx-1.2.3-7-arm64.dmg"
            image.write_bytes(b"disk image")
            copy = Path(directory) / "Arx.dmg"
            copy.write_bytes(b"disk image")
            os.utime(image, (1, 1))
            os.utime(copy, (2, 2))
            self.assertEqual(release.latest_disk_image(), image)

    def test_the_update_channel_comes_from_the_app(self):
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(Path(directory))
            # Builds from before channels have no ArxUpdateChannel and are Stable.
            self.assertEqual(release.channel(app), "stable")
            self.assertEqual(release.channel_problems(app, "stable"), [])
            info = app / "Contents/Info.plist"
            with info.open("rb") as source:
                values = plistlib.load(source)
            values["ArxUpdateChannel"] = "beta"
            with info.open("wb") as output:
                plistlib.dump(values, output)
            self.assertEqual(release.channel(app), "beta")
            self.assertTrue(any("--channel stable" in problem for problem in release.channel_problems(app, "stable")))

    def test_the_release_build_passes_its_channel(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(release.versioning, "next_build_number", return_value=8),
            patch.object(release.versioning, "marketing_version", return_value="1.2.3"),
            patch.object(release.build_app, "main", return_value=Path(directory) / "Arx.app") as build_app,
            patch.object(release, "stage"),
            patch.object(release, "keep_dsym"),
            patch.object(release, "report_size"),
            patch("builtins.print"),
        ):
            release.build(update_channel="beta")
        self.assertIn("ARX_UPDATE_CHANNEL=beta", build_app.call_args.kwargs["build_settings"])
        self.assertEqual(release.parser().parse_args([]).channel, "stable")
        with patch("sys.stderr"), self.assertRaises(SystemExit):
            release.parser().parse_args(["--channel", "nightly"])

    def test_checksum_must_exist_name_the_image_and_match(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "Arx-1.2.3-arm64.dmg"
            image.write_bytes(b"disk image")
            self.assertIn("missing", release.checksum_problems(image)[0])
            sidecar = release.checksum(image)
            self.assertEqual(release.checksum_problems(image), [])
            image.write_bytes(b"tampered disk image")
            self.assertIn("doesn't match", release.checksum_problems(image)[0])
            sidecar.write_text(f"{release.sha256(image)}  Arx-9.9.9-arm64.dmg\n")
            self.assertIn("doesn't name", release.checksum_problems(image)[0])

    def test_verify_rejects_a_bad_checksum_or_format_before_mounting(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "Arx-1.2.3-arm64.dmg"
            image.write_bytes(b"disk image")
            with (
                patch.object(release.signing, "team", return_value="TEAM123456"),
                patch.object(release, "run") as run,
            ):
                with self.assertRaisesRegex(ValueError, "missing"):
                    release.verify([str(image), "--allow-unnotarized"])
                release.checksum(image)
                with patch.object(release, "image_format", return_value="UDZO"), self.assertRaisesRegex(ValueError, "UDZO"):
                    release.verify([str(image), "--allow-unnotarized"])
            run.assert_not_called()

    def test_verify_without_an_installed_profile_still_requires_one_embedded(self):
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(Path(directory))
            signed = "TeamIdentifier=TEAM123456\nCodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1"
            with (
                patch.object(release, "run"),
                patch.object(release, "_codesign_details", return_value=signed),
                patch.object(release, "_entitlements", return_value={}),
            ):
                problems = release.code_problems(app, "TEAM123456")
                self.assertTrue(any("embedded.provisionprofile" in problem for problem in problems))
                (app / release.EMBEDDED_PROFILE).write_bytes(b"profile")
                problems = release.code_problems(app, "TEAM123456")
                self.assertFalse(any("embedded.provisionprofile" in problem for problem in problems))
                # Renderer and GPU helpers without the JIT entitlement are still caught off this Mac.
                self.assertTrue(any(release.JIT in problem for problem in problems))

    def test_settings_lay_out_the_app_on_the_designed_background(self):
        namespace = {"defines": {"app": "/build/release/Arx.app", "background": str(release.DMG_BACKGROUND)}}
        exec(release.DMG_SETTINGS.read_text(), namespace)
        settings = SimpleNamespace(**namespace)
        self.assertEqual(settings.format, "ULFO")
        self.assertEqual(settings.files, ["/build/release/Arx.app"])
        # The artwork tells people to double-click Arx, which moves itself to Applications.
        self.assertEqual(settings.symlinks, {})
        # The title bar's 28 points above the 600 x 432 artwork.
        self.assertEqual(settings.window_rect[1], (600, 460))
        self.assertEqual(settings.icon_size, 128)
        # The 128-point slot at (236, 114) in the design, as its centre.
        self.assertEqual(settings.icon_locations["Arx.app"], (300, 178))
        # The hidden background file stays below the window for people who show hidden files.
        self.assertGreater(settings.icon_locations[".background.tiff"][1], 460)
        background = Path(settings.background)
        self.assertEqual(background, release.DMG_BACKGROUND)
        self.assertTrue(background.is_file())
        self.assertTrue(background.with_name("dmg-background@2x.png").is_file())


if __name__ == "__main__":
    unittest.main()
