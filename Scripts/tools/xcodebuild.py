"""Compose shared Xcode options and read resolved application product locations."""

import json
import os
from pathlib import Path


def build_job_arguments():
    jobs = os.environ.get("BUILD_JOBS", "").strip()
    if jobs and (not jobs.isascii() or not jobs.isdecimal() or int(jobs) < 1):
        raise ValueError("BUILD_JOBS must be a positive integer.")
    return ["-jobs", jobs] if jobs else []


def isolated_build_settings(derived_data):
    """Override custom Xcode output preferences: unsigned Arx builds and `make benchmark`'s own build."""
    root = derived_data / "Build"
    return [
        f"SYMROOT={root / 'Products'}",
        f"OBJROOT={root / 'Intermediates.noindex'}",
        "CONFIGURATION_BUILD_DIR=$(SYMROOT)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)",
    ]


def application_path(output, target):
    try:
        settings = json.loads(output)
    except json.JSONDecodeError as error:
        raise ValueError("Xcode returned invalid build-settings JSON.") from error

    matches = [entry.get("buildSettings", {}) for entry in settings if entry.get("target") == target]
    if len(matches) != 1:
        raise ValueError(f"Expected one {target} application target in Xcode build settings, found {len(matches)}.")

    directory = matches[0].get("TARGET_BUILD_DIR")
    product = matches[0].get("FULL_PRODUCT_NAME")
    if not directory or not product or not product.endswith(".app"):
        raise ValueError(f"Xcode did not report an application product location for {target}.")

    app = Path(directory) / product
    if not app.is_dir():
        raise ValueError(
            f"Xcode reported a successful build, but its application product is missing: {app}. "
            "Inspect the build log printed above for the target and output paths."
        )
    return app


def require_mcp_helper(app):
    helper = app / "Contents/Helpers/ArxMCP"
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise ValueError(f"The built Arx application is missing its executable MCP helper: {helper}")
    return helper
