"""Launch the product Xcode built, including custom locations and configurations."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from Scripts import build_app, preview, signing
from Scripts.tools.xcodebuild import application_path, require_mcp_helper


class BuildProductTests(unittest.TestCase):
    def settings(self, directory, product="Arx.app", target="Arx"):
        return json.dumps([
            {"target": "Application", "buildSettings": {}},
            {"target": target, "buildSettings": {
                "TARGET_BUILD_DIR": str(directory), "FULL_PRODUCT_NAME": product,
            }},
        ])

    def test_resolves_custom_product_location(self):
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory) / "Custom Products" / "Release"
            app = products / "Arx.app"
            app.mkdir(parents=True)
            self.assertEqual(application_path(self.settings(products), "Arx"), app)

    def test_missing_application_reports_actual_xcode_path(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "application product is missing") as error:
                application_path(self.settings(directory), "Arx")
            self.assertIn(str(Path(directory) / "Arx.app"), str(error.exception))

    def test_wrong_target_cannot_launch_an_unrelated_app(self):
        with self.assertRaisesRegex(ValueError, "Expected one Arx application target"):
            application_path(self.settings("/tmp", target="AppUIPreview"), "Arx")

    def test_build_settings_use_the_same_configuration_and_overrides_as_build(self):
        with patch.dict("os.environ", {"CONFIGURATION": "Release"}), \
                patch.object(build_app, "prepare"), \
                patch.object(build_app, "require_mcp_helper"), \
                patch.object(build_app, "application_path", return_value=Path("/tmp/Custom/Arx.app")), \
                patch.object(build_app, "run", return_value="[]") as run:
            app = build_app.main()
        build, query = [call.args[0] for call in run.call_args_list]
        self.assertEqual(build[:-1], query[:-2])
        self.assertEqual(query[-2:], ["-showBuildSettings", "-json"])
        self.assertEqual(build[build.index("-configuration") + 1], "Release")
        self.assertEqual(app, Path("/tmp/Custom/Arx.app"))

    def test_unsigned_products_stay_separate_from_custom_signed_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "Project With Spaces"
            custom_signed = root / "Build/Products/Custom Release"
            commands = []

            def xcode(arguments, **_):
                commands.append(arguments)
                values = dict(argument.split("=", 1) for argument in arguments if "=" in argument)
                configuration = arguments[arguments.index("-configuration") + 1]
                if "SYMROOT" in values:
                    resolved = values["CONFIGURATION_BUILD_DIR"].replace("$(SYMROOT)", values["SYMROOT"])
                    resolved = resolved.replace("$(CONFIGURATION)", configuration).replace("$(EFFECTIVE_PLATFORM_NAME)", "")
                    products = Path(resolved)
                else:
                    products = custom_signed
                app = products / "Arx.app"
                if arguments[-1] == "build":
                    helper = app / "Contents/Helpers/ArxMCP"
                    helper.parent.mkdir(parents=True, exist_ok=True)
                    helper.write_text("unsigned" if values["CODE_SIGNING_ALLOWED"] == "NO" else "signed")
                    helper.chmod(0o700)
                    if values["CODE_SIGNING_ALLOWED"] == "YES":
                        (app / "Contents/embedded.provisionprofile").write_bytes(b"profile")
                    return ""
                self.assertEqual(arguments[-2:], ["-showBuildSettings", "-json"])
                return self.settings(products)

            with (
                patch.dict("os.environ", {"CONFIGURATION": "Custom Release", "DESTINATION": "platform=macOS,arch=arm64",
                                          "DEVELOPMENT_TEAM": "TEAM123456", "BUILD_JOBS": "2", "ARX_REQUIRE_ENGINE": "0"}),
                patch.object(build_app, "ROOT", root), patch.object(build_app, "prepare"),
                patch.object(build_app.signing, "identity", return_value="A" * 40),
                patch.object(build_app.signing, "profile", return_value=signing.Profile(Path("/p"), "UUID", signing.DEVELOPMENT)),
                patch.object(build_app.signing, "install_for_xcode"),
                patch.object(build_app, "run", side_effect=xcode),
            ):
                signed = build_app.main(signed=True)
                unsigned = build_app.main()

            self.assertEqual(signed, custom_signed / "Arx.app")
            self.assertEqual(unsigned, root / "build/UnsignedDerivedData/Build/Products/Custom Release/Arx.app")
            self.assertNotEqual(unsigned, signed)
            self.assertEqual((signed / "Contents/Helpers/ArxMCP").read_text(), "signed")
            self.assertEqual((unsigned / "Contents/Helpers/ArxMCP").read_text(), "unsigned")
            self.assertFalse((unsigned / "Contents/embedded.provisionprofile").exists())
            for build, query in [commands[:2], commands[2:]]:
                self.assertEqual(build[:-1], query[:-2])
                self.assertEqual(build[build.index("-configuration") + 1], "Custom Release")
                self.assertEqual(build[build.index("-destination") + 1], "platform=macOS,arch=arm64")

    def test_preview_build_does_not_inherit_arx_output_overrides(self):
        with (
            patch.object(build_app, "prepare"), patch.object(build_app, "application_path", return_value=Path("/tmp/Preview.app")),
            patch.object(build_app, "run", return_value="[]") as run,
        ):
            build_app.main(scheme="AppUIPreview")
        for call in run.call_args_list:
            self.assertFalse(any(value.startswith(("SYMROOT=", "OBJROOT=", "CONFIGURATION_BUILD_DIR=")) for value in call.args[0]))

    def test_app_requires_an_embedded_executable_helper(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Arx.app"
            with self.assertRaisesRegex(ValueError, "MCP helper"):
                require_mcp_helper(app)
            helper = app / "Contents/Helpers/ArxMCP"
            helper.parent.mkdir(parents=True)
            helper.write_text("fixture")
            helper.chmod(0o600)
            with self.assertRaisesRegex(ValueError, "MCP helper"):
                require_mcp_helper(app)
            helper.chmod(0o700)
            self.assertEqual(require_mcp_helper(app), helper)

    def test_launch_uses_returned_product(self):
        app = Path("/tmp/Custom Products/Release/Arx.app")
        with patch.object(build_app, "close_running_arx"), \
                patch.object(build_app, "signed", return_value=app), patch.object(build_app, "run") as run:
            build_app.launch()
        run.assert_called_once_with(["open", str(app)])

    def test_launch_closes_running_arx_before_building(self):
        calls = []
        with patch.object(build_app, "close_running_arx", side_effect=lambda **_: calls.append("close")), \
                patch.object(build_app, "signed", side_effect=lambda **_: calls.append("build") or Path("/tmp/Arx.app")), \
                patch.object(build_app, "run"):
            build_app.launch()
        self.assertEqual(calls, ["close", "build"])

    def test_make_run_builds_debug_as_arx_on_its_data(self):
        with patch.object(build_app, "close_running_arx") as close, \
                patch.object(build_app, "signed", return_value=Path("/tmp/Arx.app")) as signed, \
                patch.object(build_app, "run"):
            build_app.launch()
        variant = close.call_args.kwargs["variant"]
        self.assertEqual(variant.name, "live")
        options = signed.call_args.kwargs
        self.assertEqual(options["configuration"], "Debug")
        self.assertEqual(options["bundle_id"], "dev.capturecontext.arx")
        self.assertIn("ARX_BUNDLE_ID=dev.capturecontext.arx", options["build_settings"])
        self.assertIn("ARX_STORAGE_KEY_SERVICE=Arx Storage Key", options["build_settings"])
        # The installed Arx's own data folder: no folder of its own.
        self.assertFalse(any(value.startswith("ARX_DATA_FOLDER=") for value in options["build_settings"]))

    def test_make_run_preview_has_its_own_data_folder_and_keychain_item(self):
        with patch.object(build_app, "close_running_arx"), \
                patch.object(build_app, "signed", return_value=Path("/tmp/Arx.app")) as signed, \
                patch.object(build_app, "run"):
            build_app.launch_preview()
        options = signed.call_args.kwargs
        self.assertEqual(options["bundle_id"], "dev.capturecontext.arx")
        settings = options["build_settings"]
        self.assertIn("ARX_DATA_FOLDER=dev.capturecontext.arx.preview", settings)
        self.assertIn("ARX_SUPPORT_NAME=Arx Preview", settings)
        self.assertIn("ARX_STORAGE_KEY_SERVICE=Arx Preview Storage Key", settings)
        self.assertIn("ARX_STORAGE_KEY_ACCOUNT=Arx Preview", settings)

    def test_make_run_dev_builds_arx_dev_as_before(self):
        with patch.object(build_app, "close_running_arx") as close, \
                patch.object(build_app, "signed", return_value=Path("/tmp/Arx.app")) as signed, \
                patch.object(build_app, "run"):
            build_app.launch_dev()
        self.assertEqual(close.call_args.kwargs["variant"].bundle_id, "dev.capturecontext.arx.dev")
        signed.assert_called_once_with()

    def test_each_variant_quits_what_it_replaces_or_shares_data_with(self):
        builds = str(build_app.SIGNED_DERIVED_DATA) + "/"
        arx, dev = "dev.capturecontext.arx", "dev.capturecontext.arx.dev"
        # make run shares the installed Arx's data, so every Arx quits; Arx Dev only from the build folder.
        self.assertEqual(build_app.RUN_VARIANTS["live"].quitting(), [(arx, None), (dev, builds)])
        # make run-preview leaves the installed Arx and any Arx Dev elsewhere open.
        self.assertEqual(build_app.RUN_VARIANTS["preview"].quitting(), [(arx, builds), (dev, builds)])
        # make run-dev, as before, quits every Arx Dev, and Debug-as-Arx copies in the build folder.
        self.assertEqual(build_app.RUN_VARIANTS["dev"].quitting(), [(arx, builds), (dev, None)])

    def test_close_for_a_variant_asks_each_target_and_waits(self):
        variant = build_app.RUN_VARIANTS["preview"]
        with patch.dict("os.environ", {"ARX_KEEP_RUNNING": ""}), \
                patch.object(build_app, "running_arx", side_effect=[1, 0, 1, 0, 0, 0]) as running, \
                patch.object(build_app.time, "sleep"):
            build_app.close_running_arx(variant=variant)
        builds = str(build_app.SIGNED_DERIVED_DATA) + "/"
        self.assertEqual(running.call_args_list[0].kwargs, {"quitting": True, "bundle_id": "dev.capturecontext.arx", "under": builds})
        self.assertEqual(running.call_args_list[1].kwargs, {"quitting": True, "bundle_id": "dev.capturecontext.arx.dev", "under": builds})
        self.assertEqual(running.call_count, 6)

    def test_close_waits_until_arx_has_quit(self):
        with patch.dict("os.environ", {"ARX_KEEP_RUNNING": "", "CONFIGURATION": "Debug"}), \
                patch.object(build_app, "running_arx", side_effect=[1, 1, 0]) as running, \
                patch.object(build_app.time, "sleep"):
            build_app.close_running_arx()
        self.assertEqual(running.call_count, 3)
        self.assertEqual(running.call_args_list[0].kwargs, {"quitting": True, "bundle_id": "dev.capturecontext.arx.dev"})

    def test_close_quits_only_the_edition_being_built(self):
        # make run builds Arx Dev and leaves an installed Arx open (DEV-1013).
        for configuration, bundle_id in (("Debug", "dev.capturecontext.arx.dev"), ("Release", "dev.capturecontext.arx")):
            with self.subTest(configuration=configuration), \
                    patch.dict("os.environ", {"ARX_KEEP_RUNNING": "", "CONFIGURATION": configuration}), \
                    patch.object(build_app, "running_arx", return_value=0) as running:
                build_app.close_running_arx()
            running.assert_called_once_with(quitting=True, bundle_id=bundle_id)

    def test_close_reports_an_arx_that_stays_open(self):
        with patch.dict("os.environ", {"ARX_KEEP_RUNNING": ""}), \
                patch.object(build_app, "running_arx", return_value=1), \
                patch.object(build_app, "QUIT_TIMEOUT", 0), \
                patch.object(build_app.time, "sleep"):
            with self.assertRaisesRegex(ValueError, "ARX_KEEP_RUNNING"):
                build_app.close_running_arx()

    def test_close_can_be_turned_off(self):
        with patch.dict("os.environ", {"ARX_KEEP_RUNNING": "1"}), \
                patch.object(build_app, "running_arx") as running:
            build_app.close_running_arx()
        running.assert_not_called()

    def test_failed_build_never_queries_or_launches_a_stale_product(self):
        with patch.object(build_app, "prepare"), \
                patch.object(build_app, "run", side_effect=subprocess.CalledProcessError(65, "xcodebuild")) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                build_app.main()
        run.assert_called_once()

    def test_preview_uses_returned_product(self):
        app = Path("/tmp/Custom Products/Release/AppUIPreview.app")
        with patch.object(preview, "build", return_value=app), patch.object(preview, "run") as run:
            preview.main()
        run.assert_called_once_with(["open", str(app)])
