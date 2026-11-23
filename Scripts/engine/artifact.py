"""Identify a complete framework built from the current lock and bridge sources."""

import hashlib
import json
import os
import platform
from pathlib import Path

from .config import LOCK, PACKAGE, SOURCE, WORK, fingerprint

FRAMEWORK = SOURCE / "out/Default" / LOCK["framework"]
STAMP = WORK / "artifact.json"


def identity():
    digest = hashlib.sha256(fingerprint().encode())
    inputs = sorted((PACKAGE / "Native").rglob("*"))
    inputs += sorted((PACKAGE / "Sources/ChromiumBridge").rglob("*"))
    inputs += sorted((PACKAGE / "Prototypes/DocumentCapture").rglob("*"))
    # DEV-1100: Arx's engine branding and the overlay that puts it in place.
    inputs += sorted((PACKAGE / "Branding").rglob("*"))
    inputs.append(PACKAGE.parents[1] / "Scripts/engine/branding_overlay.py")
    inputs += [__file__, PACKAGE.parents[1] / "Scripts/engine/overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/build.py",
               PACKAGE.parents[1] / "Scripts/engine/close_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/inspection_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/page_consent_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/form_actions_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/scroll_actions_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/link_context_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/keypress_actions_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/pointer_actions_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/keyboard_actions_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/form_state_actions_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/extension_install_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/extension_navigation_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/extension_tabs_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/http_auth_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/extension_windows_overlay.py",
               # DEV-1240, DEV-1314: an extension's own window and tab in Little Arx.
               PACKAGE.parents[1] / "Scripts/engine/extension_window_create_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/extension_tab_create_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/unattended_prompts_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/bangs_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/services_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/developer_world_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/password_manager_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/autofill_suggestions_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/extension_inventory_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/background_pages_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/content_host_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/media_freeze_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/live_connection_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/erasure_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/document_capture_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/document_capture_prototype.py",
               PACKAGE.parents[1] / "Scripts/engine/document_capture_budget_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/gesture_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/force_click_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/pip_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/link_navigation_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/external_link_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/session_cookies_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/document_recording_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/document_raster_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/webstore_install_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/audio_volume_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/startup_metrics_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/component_updates_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/safe_storage_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/native_messaging_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/extension_uninstall_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/content_blocking_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/private_extension_routing_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/badge_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/notification_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/protected_media_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/widevine_answer_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/page_media_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/browser_scheme_link_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/device_chooser_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/cast_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/bfcache_media_session_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/dark_pages_overlay.py",
               PACKAGE.parents[1] / "Scripts/engine/file_stream_guard_overlay.py"]
    # DEV-1094: the dark pages overlay's record of DEV-1077's first insertions.
    inputs.append(PACKAGE.parents[1] / "Scripts/engine/dark_pages_dev1077.py")
    for path in map(Path, inputs):
        if path.is_file():
            digest.update(path.name.encode())
            digest.update(path.read_bytes())
    return {"sources": digest.hexdigest(), "architecture": os.environ.get("ENGINE_ARCH", platform.machine())}


def complete():
    if not (FRAMEWORK / "Versions" / LOCK["chromium"] / "Arx Framework").is_file():
        raise ValueError("The completed engine framework is missing")
    STAMP.write_text(json.dumps(identity(), sort_keys=True))


def available():
    return (STAMP.is_file() and json.loads(STAMP.read_text()) == identity()
            and (FRAMEWORK / "Versions" / LOCK["chromium"] / "Arx Framework").is_file())


def require():
    if not available():
        raise ValueError("Run make engine-build to finish the framework for the current engine sources")
    return FRAMEWORK
