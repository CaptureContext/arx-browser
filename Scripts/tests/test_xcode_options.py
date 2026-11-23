"""Apply the same explicit concurrency limit to app and preview commands."""

import unittest
from unittest.mock import patch

from Scripts import preview
from Scripts.tools.xcodebuild import build_job_arguments


class XcodeOptionTests(unittest.TestCase):
    def test_jobs_are_optional_and_trimmed(self):
        for raw, expected in [("", []), ("  ", []), (" 4 ", ["-jobs", "4"])]:
            with self.subTest(raw=raw), patch.dict("os.environ", {"BUILD_JOBS": raw}):
                self.assertEqual(build_job_arguments(), expected)

    def test_preview_test_honors_jobs_without_changing_default_outputs(self):
        with (
            patch.dict("os.environ", {"BUILD_JOBS": " 3 "}),
            patch.object(preview.build_app, "prepare"),
            patch.object(preview, "run") as run,
        ):
            preview.test()
        arguments = run.call_args.args[0]
        self.assertEqual(arguments[arguments.index("-jobs") + 1], "3")
        self.assertEqual(arguments[arguments.index("-derivedDataPath") + 1], str(preview.ROOT / "build/DerivedData"))
        self.assertEqual(arguments[-1], "test")
        self.assertIn("CODE_SIGNING_ALLOWED=NO", arguments)
        self.assertFalse(any(value.startswith(("SYMROOT=", "OBJROOT=")) for value in arguments))

    def test_preview_rejects_invalid_jobs_before_preparing(self):
        for value in ["0", "-1", "3.5", "three", "٣", "４"]:
            with (
                self.subTest(value=value), patch.dict("os.environ", {"BUILD_JOBS": value}),
                patch.object(preview.build_app, "prepare") as prepare,
                patch.object(preview, "run") as run,
            ):
                with self.assertRaisesRegex(ValueError, "positive integer"):
                    preview.test()
                prepare.assert_not_called()
                run.assert_not_called()

    def test_preview_absent_jobs_keeps_xcode_default(self):
        with (
            patch.dict("os.environ", {"BUILD_JOBS": ""}),
            patch.object(preview.build_app, "prepare"),
            patch.object(preview, "run") as run,
        ):
            preview.test()
        self.assertNotIn("-jobs", run.call_args.args[0])
