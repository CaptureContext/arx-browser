"""Build and open the AppUI preview without requiring the Chromium runtime."""

import os

from . import build_app
from .core.paths import ROOT
from .core.process import execute, run
from .tools.xcodebuild import build_job_arguments


def build():
    return build_app.main(scheme="AppUIPreview", log="build-preview.log")


def main():
    app = build()
    run(["open", str(app)])


TOUR_VIDEOS = ROOT / "build/tour-videos"


def _test_command(jobs, *arguments):
    return [
        "xcodebuild", "-workspace", "Project.xcworkspace", "-scheme", "AppUIPreview",
        "-destination", "platform=macOS", "-derivedDataPath", str(ROOT / "build/DerivedData"),
        "-clonedSourcePackagesDirPath", str(ROOT / ".build"),
        "-onlyUsePackageVersionsFromResolvedFile", *jobs, "CODE_SIGNING_ALLOWED=NO",
        *arguments, "test",
    ]


def test():
    jobs = build_job_arguments()
    build_app.prepare()
    run(_test_command(jobs), log="test-preview.log")


def tour_videos():
    """Export each onboarding tour demo as light and dark MP4s into build/tour-videos."""
    jobs = build_job_arguments()
    build_app.prepare()
    TOUR_VIDEOS.mkdir(parents=True, exist_ok=True)
    # xcodebuild hands TEST_RUNNER_-prefixed variables to the test process without the prefix.
    environment = {**os.environ, "TEST_RUNNER_ARX_TOUR_VIDEOS": str(TOUR_VIDEOS)}
    run(
        _test_command(jobs, "-only-testing:AppUIPreviewInteractionTests/TourVideoExportTests"),
        log="tour-videos.log",
        env=environment,
    )
    videos = sorted(TOUR_VIDEOS.glob("*.mp4"))
    if not videos:
        raise FileNotFoundError(f"No videos were written to {TOUR_VIDEOS}")
    for video in videos:
        print(video.relative_to(ROOT))


if __name__ == "__main__":
    raise SystemExit(execute(main))
