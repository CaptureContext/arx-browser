"""Prepare Helium sources, apply the Arx bridge, and build its complete framework."""

import json
import os
import platform
import shutil
import shlex
import signal
import subprocess
from pathlib import Path

from ..core.process import run
from . import artifact, branding_overlay, checkout, hosts, overlay
from .config import LOCK, SOURCE, UPSTREAM, WORK, fingerprint


def environment():
    missing = [name for name in ["curl", "zstd", "xcodebuild"] if not shutil.which(name)]
    if missing:
        raise ValueError("Missing Helium build tools: " + ", ".join(missing))
    local_python = WORK / "python/bin/python3"
    python = os.environ.get("ENGINE_PYTHON") or (str(local_python) if local_python.exists() else shutil.which("python3.13"))
    if not python:
        raise ValueError("Run make engine-tools to install Helium’s Python dependencies, or set ENGINE_PYTHON to a Python 3.13 executable with requests and Pillow installed.")
    python = str(Path(shutil.which(python) or python).absolute())
    run([python, "-c", "import sys, requests, PIL; assert sys.version_info[:2] == (3, 13)"])
    # Upstream invokes python3 by name. Keep it in a project-local shim directory.
    shims = WORK / "bin"
    shims.mkdir(parents=True, exist_ok=True)
    shim = shims / "python3"
    if shim.is_symlink():
        shim.unlink()
    elif shim.exists() and not shim.read_text().startswith("#!/bin/sh\n# Arx engine Python shim\n"):
        raise ValueError(f"Refusing to replace an unknown file: {shim}")
    shim.write_text("#!/bin/sh\n# Arx engine Python shim\nexec " + shlex.quote(python) + ' "$@"\n')
    shim.chmod(0o755)
    return dict(os.environ, PATH=str(shims) + os.pathsep + os.environ["PATH"])


def prepare():
    env = environment()
    checkout.main()
    stamp = WORK / "prepared.json"
    if stamp.exists():
        if {k: v for k, v in json.loads(stamp.read_text()).items() if k != "abi"} != {k: v for k, v in LOCK.items() if k != "abi"} or not (SOURCE / "chrome/BUILD.gn").exists():
            raise ValueError("Engine source cache does not match its lock. Preserve any edits and move .build/engine aside before rebuilding.")
    else:
        if SOURCE.exists():
            raise ValueError("Engine preparation was interrupted. Preserve any edits and move .build/engine aside before retrying.")
        run(["bash", "-c", 'set -euo pipefail; _root_dir="$PWD"; source devutils/shared.sh; prepare_sources true'], cwd=UPSTREAM, env=env)
        stamp.write_text(fingerprint())
    overlay.apply(team=os.environ.get("DEVELOPMENT_TEAM", ""))
    return env


def configure():
    arch = os.environ.get("ENGINE_ARCH", platform.machine())
    if arch not in LOCK["architectures"]:
        raise ValueError(f"Unsupported ENGINE_ARCH: {arch}")
    env = prepare()
    env["SISO_PATH"] = str(SOURCE / "third_party/siso/cipd/siso")
    run(["bash", "-c", 'set -euo pipefail; _root_dir="$PWD"; source devutils/shared.sh; '
         'write_gn_args "$1" release; printf "\\nenable_sparkle=false\\n" >> "$_out_dir/args.gn"',
         "arx-engine", arch], cwd=UPSTREAM, env=env)
    enable_cast_discovery(SOURCE / "out/Default/args.gn")
    run(["bash", "-c", 'set -euo pipefail; _root_dir="$PWD"; source devutils/shared.sh; gn_gen',
         "arx-engine"], cwd=UPSTREAM, env=env)
    return env


# DEV-927: Cast finds devices with mDNS and SSDP (DIAL), which Helium's flags.gn turns off.
# Chromium's macOS defaults (net/features.gni, chrome/common/features.gni) have both on.
CAST_GN_ARGS = ("enable_mdns", "enable_service_discovery")


def enable_cast_discovery(path):
    """Turns Helium's `enable_mdns=false` and `enable_service_discovery=false` in `args.gn`
    back on. Each must be there once, so a changed upstream can't quietly drop Cast."""
    lines = Path(path).read_text().splitlines()
    for name in CAST_GN_ARGS:
        found = [index for index, line in enumerate(lines)
                 if line.replace(" ", "").startswith(name + "=")]
        if len(found) != 1 or lines[found[0]].replace(" ", "") != f"{name}=false":
            raise ValueError(f"Expected Helium's {name}=false once in {path}")
        lines[found[0]] = f"{name}=true"
    Path(path).write_text("\n".join(lines) + "\n")


def compile_targets(targets, env):
    run_guarded([str(WORK / "bin/python3"), str(SOURCE / "third_party/depot_tools/autoninja.py"),
                 "-C", str(SOURCE / "out/Default"), "-j", os.environ.get("ENGINE_JOBS", "8"), *targets], env)


def run_guarded(arguments, env):
    """Interrupt only this build's process group before exhausting disk space."""
    reserve = float(os.environ.get("ENGINE_MIN_FREE_GIB", "40")) * 1024 ** 3
    if reserve <= 0 or not reserve < float("inf"):
        raise ValueError("ENGINE_MIN_FREE_GIB must be a finite positive number")
    if shutil.disk_usage(SOURCE).free < reserve:
        raise ValueError("Not enough disk headroom for the engine build; at least "
                         f"{reserve / 1024 ** 3:g} GiB must remain free")
    print("+ " + " ".join(map(str, arguments)), flush=True)
    process = subprocess.Popen(arguments, cwd=SOURCE, env=env, start_new_session=True)
    try:
        while True:
            try:
                result = process.wait(timeout=15)
                if result:
                    raise subprocess.CalledProcessError(result, arguments)
                return
            except subprocess.TimeoutExpired:
                if shutil.disk_usage(SOURCE).free < reserve:
                    raise ValueError("Engine build stopped to preserve disk headroom. "
                                     "Free space before resuming the incremental build.")
    finally:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGINT)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()


def check_native(env):
    run([str(SOURCE / "buildtools/mac/gn"), "check", "out/Default", "//chrome/browser/arx:arx"], cwd=SOURCE)
    run([str(SOURCE / "buildtools/mac/gn"), "check", "out/Default", "//components/arx_inspection:renderer"], cwd=SOURCE)
    run([str(SOURCE / "buildtools/mac/gn"), "check", "out/Default", "//components/arx_page_media:renderer"], cwd=SOURCE)
    for target in ["browser", "renderer", "fixture"]:
        run([str(SOURCE / "buildtools/mac/gn"), "check", "out/Default",
             "//components/paint_preview/arx:" + target], cwd=SOURCE)
    outputs = []
    sources = ["//chrome/browser/arx/" + source for source in
               ["engine_bridge.mm", "popup_host.mm", "page_consent_host.mm", "downloads_bridge.mm", "capture_bridge.mm", "page_capture_bridge.mm", "media_bridge.mm",
                "extensions_bridge.mm", "extensions_install_bridge.mm", "site_icons_bridge.mm", "inspection_bridge.mm", "pdf_bridge.mm", "devtools_bridge.mm", "developer_bridge.mm", "network_capture_bridge.mm", "focused_link_bridge.mm", "page_zoom_bridge.mm", "page_unload_bridge.mm", "page_menu_bridge.mm", "context_menu_bridge.mm", "webstore_install_bridge.mm", "link_navigation_bridge.mm", "autofill_bridge.mm", "autofill_settings.mm", "password_bridge.mm", "password_settings.mm", "credential_import.mm", "site_settings_bridge.mm", "browsing_data_bridge.mm", "content_blocking_bridge.mm", "extension_menu_items.mm", "private_download_prefs.mm", "protected_media_bridge.mm", "page_media_bridge.mm", "battery_saver_bridge.mm", "dark_pages_bridge.mm", "device_chooser_bridge.mm", "cast_bridge.mm", "hovered_link_bridge.mm", "browser_scheme_link_bridge.mm",
                "profile_erasure/journal.cc", "profile_erasure/bridge.cc",
                "form_edits_bridge.mm",
                "page_command_key.mm",
                # DEV-1309: a person's file choosers get Chrome's file dialog.
                "file_chooser_bridge.mm",
                # DEV-1240.
                "extension_window_bridge.mm",
                "gestures/controller.mm", "gestures/panel.mm", "gestures/fixture.mm"]]
    sources += ["//content/browser/renderer_host/render_frame_host_impl.cc",
                "//content/browser/renderer_host/navigation_request.cc",
                "//components/arx_inspection/inspector.cc",
                "//components/arx_inspection/script_runner.cc",
                "//components/arx_page_media/page_media_agent.cc",
                # DEV-1193: Blink's refused chrome:// links and their browser binder.
                "//third_party/blink/renderer/core/loader/frame_loader.cc",
                "//third_party/blink/renderer/core/page/create_window.cc",
                "//third_party/blink/renderer/core/frame/remote_frame.cc",
                "//chrome/browser/chrome_browser_interface_binders.cc",
                "//third_party/blink/renderer/core/exported/web_document.cc",
                "//third_party/blink/renderer/core/exported/web_element.cc",
                "//third_party/blink/renderer/core/exported/web_form_control_element.cc",
                "//chrome/renderer/chrome_content_renderer_client.cc",
                "//extensions/browser/crx_installer.cc",
                "//extensions/browser/api/webstore_private/webstore_private_api.cc",
                "//chrome/browser/extensions/api/runtime/chrome_runtime_api_delegate.cc",
                "//chrome/browser/extensions/extension_keybinding_registry.cc",
                "//chrome/browser/extensions/extension_tab_util.cc",
                "//chrome/browser/extensions/api/tabs/tabs_api.cc",
                "//chrome/browser/extensions/api/tabs/windows_api.cc",
                "//chrome/browser/ui/login/http_auth_coordinator.cc",
                "//chrome/browser/password_manager/chrome_password_manager_client.cc",
                "//chrome/browser/ui/autofill/chrome_autofill_client.cc",
                "//chrome/browser/ui/autofill/payments/chrome_payments_autofill_client.cc",
                "//chrome/browser/policy/configuration_policy_handler_list_factory.cc",
                "//chrome/browser/webauthn/chrome_authenticator_request_delegate.cc",
                "//chrome/browser/ui/webid/identity_dialog_controller.cc",
                "//chrome/browser/shutdown_watchdog_mac.cc",
                "//extensions/browser/extension_prefs.cc",
                "//components/permissions/permission_request_manager.cc",
                "//components/web_modal/web_contents_modal_dialog_manager_delegate.cc",
                "//chrome/browser/external_protocol/external_protocol_handler.cc",
                "//chrome/browser/ui/views/external_protocol_dialog.cc",
                "//content/browser/child_process_launcher_helper.cc",
                "//chrome/browser/process_singleton_posix.cc",
                "//chrome/browser/chrome_process_singleton.cc",
                "//chrome/browser/profiles/profile_manager.cc",
                "//chrome/app/chrome_main_delegate.cc",
                "//chrome/browser/chrome_content_browser_client.cc",
                "//components/input/gesture_event_queue.cc",
                "//components/input/render_input_router.cc",
                "//components/input/input_router_impl.cc",
                "//content/browser/renderer_host/render_widget_host_impl.cc",
                "//chrome/browser/renderer_host/chrome_render_widget_host_view_mac_delegate.mm"]
    sources += ["//components/paint_preview/arx/" + source for source in
                ["document_capture.cc", "document_recorder.cc", "record_admission.cc",
                 "png_encoding.cc", "document_capture_fixture.cc"]]
    sources += ["//components/services/paint_preview_compositor/paint_preview_compositor_impl.cc",
                "//cc/paint/record_paint_canvas.cc",
                "//third_party/blink/renderer/platform/graphics/paint/paint_controller.cc",
                "//third_party/blink/renderer/platform/graphics/paint/paint_chunker.cc",
                "//components/paint_preview/renderer/paint_preview_recorder_utils.cc",
                "//third_party/blink/renderer/core/frame/web_local_frame_impl.cc"]
    # Per-tab volume (DEV-800).
    sources += ["//services/audio/arx_local_volume.cc",
                "//services/audio/output_controller.cc",
                "//services/audio/stream_factory.cc",
                "//content/browser/media/forwarding_audio_stream_factory.cc",
                "//content/browser/web_contents/web_contents_impl.cc"]
    # WebKit pages' protected media hook (DEV-877).
    sources += ["//content/browser/media/key_system_support_impl.cc"]
    # DEV-1144, DEV-1205: refused and granted protected media requests reach it.
    sources += ["//content/renderer/media/media_factory.cc",
                "//third_party/blink/renderer/platform/media/web_encrypted_media_client_impl.cc",
                "//third_party/blink/renderer/modules/encryptedmedia/navigator_request_media_key_system_access.cc"]
    # DEV-1211: a media element that wants keys reaches it too.
    sources += ["//third_party/blink/renderer/modules/encryptedmedia/html_media_element_encrypted_media.cc"]
    # DEV-1144: the Widevine answer and the page media bridge's binder.
    sources += ["//components/cdm/renderer/key_system_support_update.cc",
                "//content/browser/media/media_interface_proxy.cc",
                "//chrome/browser/chrome_content_browser_client_receiver_bindings.cc"]
    # Device choosers (DEV-905).
    sources += ["//chrome/browser/ui/views/permissions/chooser_bubble_ui.cc"]
    # Cast (DEV-927): discovery only builds with enable_mdns and enable_service_discovery.
    sources += ["//chrome/browser/media/router/discovery/mdns/dns_sd_device_lister.cc",
                "//chrome/browser/media/router/discovery/mdns/dns_sd_registry.cc",
                "//chrome/browser/media/router/discovery/dial/dial_registry.cc",
                "//chrome/browser/local_discovery/service_discovery_client_mac.mm",
                "//chrome/browser/ui/views/chrome_browser_main_extra_parts_views.cc"]
    # A page restored from the back/forward cache keeps its media session (DEV-960).
    sources += ["//content/browser/media/session/media_session_impl.cc",
                "//content/browser/media/session/media_session_service_impl.cc"]
    # A FileStream deleted at shutdown drops its descriptor's guard before closing it.
    sources += ["//net/base/file_stream_context_posix.cc"]
    # TtsAudioOutputStreamFactory is patched too, but builds only on ChromeOS.
    for source in sources:
        source_outputs = run([str(SOURCE / "buildtools/mac/gn"), "outputs", "out/Default",
                              source], cwd=SOURCE, capture=True).splitlines()
        if not source_outputs:
            raise ValueError(f"Native bridge source is missing from Chromium's build graph: {source}")
        outputs.extend(source_outputs)
    compile_targets(outputs, env)


def check():
    check_native(configure())


def main():
    artifact.STAMP.unlink(missing_ok=True)
    identity = artifact.identity()
    env = configure()
    check_native(env)
    compile_targets(["chrome:chrome_framework"], env)
    if identity != artifact.identity():
        raise ValueError("Engine sources changed during the build; rerun make engine-build")
    # DEV-930: a build that still names Helium's servers, or a Google host nobody reviewed, isn't complete.
    hosts.check(artifact.FRAMEWORK)
    # DEV-1100: nor one that bundles Helium's logo or names Helium in its English strings.
    branding_overlay.check_framework(artifact.FRAMEWORK / "Versions" / LOCK["chromium"] / "Resources")
    artifact.complete()
    print(f"Built framework: {SOURCE / 'out/Default' / LOCK['framework']}")
