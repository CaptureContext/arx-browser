"""Development signing fails closed and never selects another team's identity."""

import datetime
import hashlib
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from Scripts import build_app, signing


TEAM = "TEAM123456"
CERTIFICATE = b"certificate"
FINGERPRINT = hashlib.sha1(CERTIFICATE).hexdigest().upper()
NOW = datetime.datetime(2026, 11, 8, 12, 0, tzinfo=datetime.timezone.utc)


def development_profile():
    return signing.Profile(Path("/profiles/development.provisionprofile"), "DEV-UUID", signing.DEVELOPMENT)


def signed_app(directory):
    app = Path(directory) / "Arx.app"
    (app / "Contents").mkdir(parents=True)
    (app / "Contents/embedded.provisionprofile").write_bytes(b"profile")
    return app


def profile_contents(kind=signing.DEVELOPMENT, **changes):
    contents = {
        "Name": signing.PROFILE_NAMES[kind],
        "UUID": f"{kind}-uuid",
        "TeamIdentifier": [TEAM],
        "Entitlements": {
            "com.apple.application-identifier": f"{TEAM}.dev.capturecontext.arx",
            "com.apple.developer.icloud-container-identifiers": ["iCloud.dev.capturecontext.arx"],
            "com.apple.developer.icloud-services": "*",
            "com.apple.developer.icloud-container-environment": (
                ["Production", "Development"] if kind == signing.DEVELOPMENT else "Production"
            ),
            "com.apple.developer.aps-environment": "development" if kind == signing.DEVELOPMENT else "production",
        },
        "DeveloperCertificates": [CERTIFICATE],
        "CreationDate": datetime.datetime(2026, 11, 8),
        "ExpirationDate": datetime.datetime(2027, 11, 8),
    }
    if kind == signing.DEVELOPMENT:
        contents["ProvisionedDevices"] = ["device"]
    else:
        contents["ProvisionsAllDevices"] = True
    contents.update(changes)
    return contents


class ProfileTests(unittest.TestCase):
    def test_debug_builds_are_arx_dev(self):
        self.assertEqual(signing.bundle_id("Debug"), "dev.capturecontext.arx.dev")
        self.assertEqual(signing.bundle_id("Release"), "dev.capturecontext.arx")
        self.assertEqual(signing.profile_name(signing.DEVELOPMENT, signing.DEV_BUNDLE_ID),
                         "match Development dev.capturecontext.arx.dev macos")

    def test_arx_dev_needs_its_own_profile(self):
        release = profile_contents(signing.DEVELOPMENT)
        self.assertTrue(signing.profile_problems(release, signing.DEVELOPMENT, TEAM, FINGERPRINT, bundle=signing.DEV_BUNDLE_ID, now=NOW))
        dev = profile_contents(
            signing.DEVELOPMENT,
            Name=signing.profile_name(signing.DEVELOPMENT, signing.DEV_BUNDLE_ID),
            Entitlements={**release["Entitlements"], "com.apple.application-identifier": f"{TEAM}.{signing.DEV_BUNDLE_ID}"},
        )
        self.assertEqual(signing.profile_problems(dev, signing.DEVELOPMENT, TEAM, FINGERPRINT, bundle=signing.DEV_BUNDLE_ID, now=NOW), [])
        self.assertTrue(signing.profile_problems(dev, signing.DEVELOPMENT, TEAM, FINGERPRINT, now=NOW))

    def test_match_profile_for_the_identity_is_usable(self):
        for kind in (signing.DEVELOPMENT, signing.DEVELOPER_ID):
            self.assertEqual(signing.profile_problems(profile_contents(kind), kind, TEAM, FINGERPRINT, now=NOW), [], kind)

    def test_profiles_that_cannot_sign_this_app_are_rejected(self):
        cases = {
            "another profile name": profile_contents(Name="match Development dev.capturecontext.other macos"),
            "another team": profile_contents(TeamIdentifier=["OTHER12345"]),
            "another app identifier": profile_contents(Entitlements={"com.apple.application-identifier": f"{TEAM}.other"}),
            "expired": profile_contents(ExpirationDate=datetime.datetime(2026, 1, 1)),
            "signing certificate": profile_contents(DeveloperCertificates=[b"another certificate"]),
        }
        for problem, contents in cases.items():
            problems = signing.profile_problems(contents, signing.DEVELOPMENT, TEAM, FINGERPRINT, now=NOW)
            self.assertTrue(any(problem in entry for entry in problems), (problem, problems))
        self.assertTrue(signing.profile_problems(None, signing.DEVELOPMENT, TEAM, FINGERPRINT, now=NOW))

    def test_development_and_developer_id_profiles_are_not_interchangeable(self):
        direct = profile_contents(signing.DEVELOPER_ID)
        self.assertTrue(signing.profile_problems(direct, signing.DEVELOPMENT, TEAM, FINGERPRINT, now=NOW))
        development = profile_contents(signing.DEVELOPMENT)
        self.assertTrue(signing.profile_problems(development, signing.DEVELOPER_ID, TEAM, FINGERPRINT, now=NOW))
        renamed = profile_contents(signing.DEVELOPMENT, Name=signing.PROFILE_NAMES[signing.DEVELOPER_ID])
        self.assertIn("not a Developer ID profile", signing.profile_problems(renamed, signing.DEVELOPER_ID, TEAM, FINGERPRINT, now=NOW))

    def installed(self, directory, profiles):
        directory = Path(directory)
        decoded = {}
        for name, contents in profiles.items():
            path = directory / name
            path.write_bytes(b"cms")
            decoded[path] = contents
        return (
            patch.object(signing, "PROFILE_DIRECTORIES", (directory, directory / "missing")),
            patch.object(signing, "decode_profile", side_effect=lambda path: decoded[Path(path)]),
            patch.dict(os.environ, {"DEVELOPMENT_TEAM": TEAM, "ARX_DEVELOPMENT_PROFILE": "", "ARX_DEVELOPER_ID_PROFILE": ""}),
        )

    def test_selects_the_newest_matching_profile_by_name(self):
        with tempfile.TemporaryDirectory() as directory:
            directories, decode, environment = self.installed(directory, {
                "old.provisionprofile": profile_contents(UUID="old", CreationDate=datetime.datetime(2026, 1, 1)),
                "new.provisionprofile": profile_contents(UUID="new"),
                "other-app.provisionprofile": profile_contents(UUID="other", Name="match Development dev.capturecontext.other macos", CreationDate=datetime.datetime(2026, 12, 1)),
                "direct.provisionprofile": profile_contents(signing.DEVELOPER_ID, UUID="direct"),
                "ios.mobileprovision": profile_contents(UUID="ios", CreationDate=datetime.datetime(2026, 12, 1)),
            })
            with directories, decode, environment:
                found = signing.profile(signing.DEVELOPMENT, FINGERPRINT)
                self.assertEqual((found.uuid, found.path.name), ("new", "new.provisionprofile"))
                self.assertEqual((found.icloud_environment, found.aps_environment), ("Development", "development"))
                direct = signing.profile(signing.DEVELOPER_ID, FINGERPRINT)
                self.assertEqual(direct.uuid, "direct")
                self.assertEqual((direct.icloud_environment, direct.aps_environment), ("Production", "production"))

    def test_override_path_is_validated_like_an_installed_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            directories, decode, environment = self.installed(directory, {
                "chosen.provisionprofile": profile_contents(UUID="chosen"),
                "newer.provisionprofile": profile_contents(UUID="newer", CreationDate=datetime.datetime(2026, 12, 1)),
            })
            with directories, decode, environment:
                with patch.dict(os.environ, {"ARX_DEVELOPMENT_PROFILE": str(Path(directory) / "chosen.provisionprofile")}):
                    self.assertEqual(signing.profile(signing.DEVELOPMENT, FINGERPRINT).uuid, "chosen")
                    with self.assertRaisesRegex(ValueError, "No usable developer id"):
                        signing.profile(signing.DEVELOPER_ID, FINGERPRINT)

    def test_profiles_without_the_icloud_and_push_grants_are_rejected(self):
        def without(kind, key, value=None):
            contents = profile_contents(kind)
            entitlements = dict(contents["Entitlements"])
            if value is None:
                entitlements.pop(key)
            else:
                entitlements[key] = value
            return signing.profile_problems({**contents, "Entitlements": entitlements}, kind, TEAM, FINGERPRINT, now=NOW)
        prefix = "com.apple.developer."
        self.assertEqual(without(signing.DEVELOPMENT, prefix + "icloud-container-identifiers"), ["doesn't grant the iCloud container"])
        self.assertEqual(without(signing.DEVELOPMENT, prefix + "icloud-services", ["CloudDocuments"]), ["doesn't grant CloudKit"])
        self.assertEqual(without(signing.DEVELOPMENT, prefix + "icloud-services", ["CloudKit"]), [])
        self.assertEqual(without(signing.DEVELOPMENT, prefix + "aps-environment"), ["doesn't grant development push"])
        self.assertEqual(
            without(signing.DEVELOPER_ID, prefix + "icloud-container-environment", "Development"),
            ["doesn't grant the Production iCloud environment"],
        )

    def test_override_outside_xcodes_directory_is_installed_by_uuid(self):
        with tempfile.TemporaryDirectory() as directory:
            xcode = Path(directory) / "Xcode"
            override = Path(directory) / "elsewhere/chosen.provisionprofile"
            override.parent.mkdir()
            override.write_bytes(b"profile")
            with patch.object(signing, "PROFILE_DIRECTORIES", (xcode,)):
                installed = signing.install_for_xcode(signing.Profile(override, "CHOSEN", signing.DEVELOPMENT))
                self.assertEqual(installed, xcode / "CHOSEN.provisionprofile")
                self.assertEqual(installed.read_bytes(), b"profile")
                in_place = xcode / "installed.provisionprofile"
                in_place.write_bytes(b"match")
                self.assertEqual(signing.install_for_xcode(signing.Profile(in_place, "MATCH", signing.DEVELOPMENT)), in_place)
                self.assertFalse((xcode / "MATCH.provisionprofile").exists())
                legacy = Path(directory) / "MobileDevice/legacy.provisionprofile"
                legacy.parent.mkdir()
                legacy.write_bytes(b"legacy")
                with patch.object(signing, "PROFILE_DIRECTORIES", (xcode, legacy.parent)):
                    installed = signing.install_for_xcode(signing.Profile(legacy, "LEGACY-UUID", signing.DEVELOPMENT))
                self.assertEqual(installed, xcode / "LEGACY-UUID.provisionprofile")

    def test_missing_profile_names_the_restore_and_regenerate_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            directories, decode, environment = self.installed(directory, {})
            with directories, decode, environment:
                with self.assertRaisesRegex(ValueError, "make signing-setup.*signing_profiles force:true"):
                    signing.profile(signing.DEVELOPMENT, FINGERPRINT)
                with self.assertRaisesRegex(ValueError, "make release-signing-setup"):
                    signing.profile(signing.DEVELOPER_ID, FINGERPRINT)


class SigningTests(unittest.TestCase):
    def test_selects_valid_development_identity_for_configured_team(self):
        wanted, foreign = "A" * 40, "B" * 40
        listing = f'1) {wanted} "Apple Development: Local"\n2) {foreign} "Apple Development: Other"'
        certificates = "-----BEGIN CERTIFICATE-----local-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----foreign-----END CERTIFICATE-----"
        def result(output):
            return subprocess.CompletedProcess([], 0, stdout=output)
        results = [result(listing), result(certificates)]
        for fingerprint, team in [(wanted, "TEAM123456"), (foreign, "OTHER12345")]:
            results.append(result(f"sha1 Fingerprint={fingerprint}\n    OU = {team}\nnotAfter=Oct 28 12:00:00 2027 GMT\n"))
        with patch.dict("os.environ", {"DEVELOPMENT_TEAM": "TEAM123456", "ARX_SIGNING_IDENTITY": ""}), patch.object(signing.subprocess, "run", side_effect=results):
            self.assertEqual(signing.identity(), wanted)

    def test_missing_identity_does_not_fall_back_to_adhoc(self):
        empty = subprocess.CompletedProcess([], 0, stdout="")
        with patch.dict("os.environ", {"DEVELOPMENT_TEAM": "TEAM123456"}), patch.object(signing.subprocess, "run", return_value=empty):
            with self.assertRaisesRegex(ValueError, "No valid Apple Development"):
                signing.identity()

    def test_unsigned_build_does_not_access_keychain_and_isolates_actual_outputs(self):
        with (
            patch.object(build_app, "prepare"),
            patch.object(build_app, "require_mcp_helper"),
            patch.object(build_app.signing, "identity") as identity,
            patch.object(build_app.signing, "profile") as profile,
            patch.object(build_app, "application_path", return_value="/tmp/Arx.app"),
            patch.object(build_app, "run") as run,
        ):
            build_app.main()
        identity.assert_not_called()
        profile.assert_not_called()
        arguments = run.call_args_list[0].args[0]
        self.assertIn("CODE_SIGNING_ALLOWED=NO", arguments)
        self.assertFalse(any(value.startswith("ARX_PROVISIONING_PROFILE=") for value in arguments))
        self.assertIn(str(build_app.ROOT / "build/UnsignedDerivedData"), arguments)
        self.assertIn(f"SYMROOT={build_app.ROOT / 'build/UnsignedDerivedData/Build/Products'}", arguments)
        self.assertIn(f"OBJROOT={build_app.ROOT / 'build/UnsignedDerivedData/Build/Intermediates.noindex'}", arguments)
        self.assertIn("CONFIGURATION_BUILD_DIR=$(SYMROOT)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)", arguments)

    def test_signed_build_uses_validated_identity(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.dict("os.environ", {"DEVELOPMENT_TEAM": "TEAM123456"}),
            patch.object(build_app, "prepare"),
            patch.object(build_app, "require_mcp_helper"),
            patch.object(build_app.signing, "identity", return_value="A" * 40),
            patch.object(build_app.signing, "profile", return_value=development_profile()),
            patch.object(build_app.signing, "install_for_xcode") as install,
            patch.object(build_app, "application_path", return_value=signed_app(directory)),
            patch.object(build_app, "run") as run,
        ):
            build_app.signed()
        arguments = run.call_args_list[0].args[0]
        self.assertIn("CODE_SIGNING_ALLOWED=YES", arguments)
        self.assertIn("CODE_SIGN_IDENTITY=" + "A" * 40, arguments)
        self.assertIn("ARX_PROVISIONING_PROFILE=DEV-UUID", arguments)
        self.assertIn("ARX_ICLOUD_ENVIRONMENT=Development", arguments)
        self.assertIn("ARX_APS_ENVIRONMENT=development", arguments)
        install.assert_called_once_with(development_profile())
        self.assertIn(str(build_app.ROOT / "build/DerivedData"), arguments)
        self.assertFalse(any(value.startswith(("SYMROOT=", "OBJROOT=", "CONFIGURATION_BUILD_DIR=")) for value in arguments))

    def test_signed_build_without_an_embedded_profile_fails(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.dict("os.environ", {"DEVELOPMENT_TEAM": "TEAM123456"}),
            patch.object(build_app, "prepare"),
            patch.object(build_app, "require_mcp_helper"),
            patch.object(build_app.signing, "identity", return_value="A" * 40),
            patch.object(build_app.signing, "profile", return_value=development_profile()),
            patch.object(build_app.signing, "install_for_xcode") as install,
            patch.object(build_app, "application_path", return_value=Path(directory) / "Arx.app"),
            patch.object(build_app, "run"),
        ):
            with self.assertRaisesRegex(ValueError, "no embedded provisioning profile"):
                build_app.signed()

    def test_missing_profile_stops_a_signed_build_before_xcode(self):
        with (
            patch.dict("os.environ", {"DEVELOPMENT_TEAM": "TEAM123456", "CONFIGURATION": "Release"}),
            patch.object(build_app, "prepare") as prepare,
            patch.object(build_app.signing, "identity", return_value="A" * 40),
            patch.object(build_app.signing, "profile", side_effect=ValueError("No usable development provisioning profile")),
            patch.object(build_app, "run") as run,
        ):
            with self.assertRaisesRegex(ValueError, "provisioning profile"):
                build_app.signed()
        prepare.assert_not_called()
        run.assert_not_called()

    def test_debug_build_signs_arx_dev_with_its_own_profile(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.dict("os.environ", {"DEVELOPMENT_TEAM": "TEAM123456", "CONFIGURATION": "Debug"}),
            patch.object(build_app, "prepare"),
            patch.object(build_app, "require_mcp_helper"),
            patch.object(build_app.signing, "identity", return_value="A" * 40),
            patch.object(build_app.signing, "profile", return_value=development_profile()) as profile,
            patch.object(build_app.signing, "install_for_xcode"),
            patch.object(build_app, "drop_provisioned_entitlements") as unprovisioned,
            patch.object(build_app, "application_path", return_value=signed_app(directory)),
            patch.object(build_app, "run") as run,
        ):
            build_app.signed()
        profile.assert_called_once_with(signing.DEVELOPMENT, "A" * 40, signing.DEV_BUNDLE_ID)
        unprovisioned.assert_not_called()
        arguments = run.call_args_list[0].args[0]
        self.assertIn("ARX_PROVISIONING_PROFILE=DEV-UUID", arguments)

    def test_make_run_signs_debug_with_arxs_own_profile(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.dict("os.environ", {"DEVELOPMENT_TEAM": "TEAM123456"}),
            patch.object(build_app, "prepare"),
            patch.object(build_app, "require_mcp_helper"),
            patch.object(build_app.signing, "identity", return_value="A" * 40),
            patch.object(build_app.signing, "profile", return_value=development_profile()) as profile,
            patch.object(build_app.signing, "dev_profile") as dev_profile,
            patch.object(build_app.signing, "install_for_xcode"),
            patch.object(build_app, "drop_provisioned_entitlements") as unprovisioned,
            patch.object(build_app, "application_path", return_value=signed_app(directory)),
            patch.object(build_app, "run") as run,
        ):
            build_app.signed(configuration="Debug", bundle_id=signing.BUNDLE_ID, build_settings=build_app.ARX_SETTINGS)
        profile.assert_called_once_with(signing.DEVELOPMENT, "A" * 40, signing.BUNDLE_ID)
        dev_profile.assert_not_called()
        unprovisioned.assert_not_called()
        arguments = run.call_args_list[0].args[0]
        self.assertIn("ARX_PROVISIONING_PROFILE=DEV-UUID", arguments)
        self.assertEqual(arguments[arguments.index("-configuration") + 1], "Debug")
        self.assertIn("ARX_BUNDLE_ID=dev.capturecontext.arx", arguments)

    def test_arx_dev_without_its_profile_is_signed_without_icloud(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.dict("os.environ", {"DEVELOPMENT_TEAM": "TEAM123456", "CONFIGURATION": "Debug"}),
            patch.object(build_app, "prepare"),
            patch.object(build_app, "require_mcp_helper"),
            patch.object(build_app.signing, "identity", return_value="A" * 40),
            patch.object(build_app.signing, "profile", side_effect=ValueError("No usable development provisioning profile")),
            patch.object(build_app.signing, "install_for_xcode") as install,
            patch.object(build_app, "drop_provisioned_entitlements") as unprovisioned,
            patch.object(build_app, "application_path", return_value=Path(directory) / "Arx.app"),
            patch.object(build_app, "run") as run,
        ):
            build_app.signed()
        install.assert_not_called()
        unprovisioned.assert_called_once_with()
        arguments = run.call_args_list[0].args[0]
        self.assertIn("CODE_SIGN_IDENTITY=" + "A" * 40, arguments)
        self.assertIn("ARX_PROVISIONING_PROFILE=", arguments)
        self.assertFalse(any(value.startswith(("ARX_ICLOUD_ENVIRONMENT=", "ARX_APS_ENVIRONMENT=")) for value in arguments))

    def test_a_build_that_needs_icloud_requires_arx_devs_profile(self):
        with (
            patch.dict("os.environ", {"DEVELOPMENT_TEAM": "TEAM123456"}),
            patch.object(build_app, "prepare") as prepare,
            patch.object(build_app.signing, "identity", return_value="A" * 40),
            patch.object(build_app.signing, "profile", side_effect=ValueError("No usable development provisioning profile")),
            patch.object(build_app, "run") as run,
        ):
            with self.assertRaisesRegex(ValueError, "provisioning profile"):
                build_app.main(signed=True, require_profile=True, configuration="Debug")
        prepare.assert_not_called()
        run.assert_not_called()

    def test_unprovisioned_entitlements_drop_only_what_needs_a_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Arx.entitlements"
            kept = {"com.apple.security.network.client": True, "com.apple.security.device.camera": True}
            path.write_bytes(plistlib.dumps({
                **kept,
                **{key: "value" for key in build_app.PROVISIONED_ENTITLEMENTS},
            }))
            build_app.drop_provisioned_entitlements(path)
            self.assertEqual(plistlib.loads(path.read_bytes()), kept)

    def test_explicit_build_concurrency_reaches_xcode_without_signing_access(self):
        with (
            patch.dict("os.environ", {"BUILD_JOBS": "3"}),
            patch.object(build_app, "prepare"),
            patch.object(build_app, "require_mcp_helper"),
            patch.object(build_app.signing, "identity") as identity,
            patch.object(build_app, "application_path", return_value="/tmp/Arx.app"),
            patch.object(build_app, "run") as run,
        ):
            build_app.main()
        identity.assert_not_called()
        for call in run.call_args_list:
            arguments = call.args[0]
            self.assertEqual(arguments[arguments.index("-jobs") + 1], "3")

    def test_invalid_build_concurrency_fails_before_preparing_or_signing(self):
        for value in ["0", "-1", "three", "3.5"]:
            with (
                self.subTest(value=value),
                patch.dict("os.environ", {"BUILD_JOBS": value}),
                patch.object(build_app, "prepare") as prepare,
                patch.object(build_app.signing, "identity") as identity,
                patch.object(build_app, "run") as run,
            ):
                with self.assertRaisesRegex(ValueError, "positive integer"):
                    build_app.main(signed=True)
                prepare.assert_not_called()
                identity.assert_not_called()
                run.assert_not_called()


class FastlaneToolTests(unittest.TestCase):
    def test_mise_puts_its_fastlane_ahead_of_one_installed_into_ruby(self):
        # A fastlane gem left in the Ruby's own gem directory would otherwise run instead of the pinned one.
        tools = (Path(__file__).resolve().parents[2] / "mise.toml").read_text().split("[env]")[0]
        self.assertRegex(tools, r'"gem:fastlane" = \{ version = "[0-9.]+", depends = \["ruby"\] \}')
        self.assertLess(tools.index('"gem:fastlane"'), tools.index("\nruby = "))
        self.assertNotIn("bundler", tools)

    def test_lanes_run_the_mise_installed_fastlane(self):
        with patch.object(signing, "run") as run, patch.object(signing, "check"):
            signing.setup()
        run.assert_called_once_with(["fastlane", "mac", "development_signing"])
