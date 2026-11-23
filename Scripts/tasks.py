"""Thin command dispatcher shared by Make and CI."""

import sys
from functools import partial

from . import external_consent_smoke, extension_settings_smoke
from . import appcast, credits, cloudkit_probe, cloudkit_schema, install, routing_smoke, versioning, app_smoke, build_app, build_package, check, preview, project, release, resolve, test, test_all, test_runtime, test_mcp, signing
from . import benchmark, load_ladder, perf_gate, sidebar_scroll
from .agent_evals import runner as agent_evals
from . import profile_retirement_smoke, developer_tools_smoke, local_failure_smoke, headless_smoke, sign_in_smoke, component_updates_smoke
from . import profile_release_smoke
from . import tab_unload_smoke
from . import little_arx_space_smoke
from . import notification_smoke
from . import hand_check_smoke
from .core import bangs
from . import style
from . import localization
from .core.process import execute
from .tools import git, swift
from .engine import document_capture_smoke, build as engine_build, checkout as engine_checkout, tools as engine_tools
from .engine import host as engine_host, smoke as engine_smoke
from .engine import back_forward_cache_smoke, background_visibility_smoke, password_smoke, extension_install_smoke, webstore_install_smoke, reference_keypress_smoke, gesture_smoke, link_context_smoke, focused_link_smoke, cross_site_link_smoke, site_settings_smoke, browsing_data_smoke, close_smoke, hang_smoke, extensions_smoke, inspection_smoke, reference_click_smoke, reference_form_smoke, reference_scroll_smoke
from .engine import archive as engine_archive, cache as engine_cache, overlay as engine_overlay
from .engine import bundle as engine_bundle, fetch as engine_fetch, hosts as engine_hosts
from .engine import anchors as engine_anchors, upstream as engine_upstream


COMMANDS = {
    "check-toolchain": swift.check_toolchain,
    "submodules": git.submodules,
    "resolve": resolve.main,
    "project": project.main,
    "workspace": project.main,
    "check": check.main,
    "bangs": bangs.main,
    "style": style.main,
    "localization-export": localization.export_main,
    "localization-import": localization.import_main,
    "localization-check": localization.check_main,
    "credits": credits.main,
    "test": test.main,
    "build-package": build_package.main,
    "build-app": build_app.main,
    "build-app-runtime": build_app.runtime,
    "build-app-signed": build_app.signed,
    "run": build_app.launch,
    "run-preview": build_app.launch_preview,
    "run-dev": build_app.launch_dev,
    "signing-check": signing.check,
    "signing-setup": signing.setup,
    "release-signing-check": signing.release_check,
    "release-signing-setup": signing.release_setup,
    "release-signing-cleanup": signing.release_cleanup,
    "dmg": release.main,
    "dmg-verify": release.verify,
    "appcast": appcast.main,
    "install": install.install,
    "update": install.update,
    "version": versioning.main,
    "cloudkit-probe": cloudkit_probe.main,
    "cloudkit-schema": cloudkit_schema.main,
    "benchmark": benchmark.main,
    "sidebar-scroll": sidebar_scroll.main,
    "load-ladder": load_ladder.main,
    "perf-gate": perf_gate.main,
    "agent-evals": agent_evals.main,
    "app-smoke": app_smoke.main,
    "password-smoke": password_smoke.main,
    "external-consent-smoke": external_consent_smoke.main,
    "extension-settings-smoke": extension_settings_smoke.main,
    "routing-smoke": routing_smoke.main,
    "profile-retirement-smoke": profile_retirement_smoke.main,
    "migration-clear-smoke": partial(profile_retirement_smoke.main, clearing=True),
    "developer-tools-smoke": developer_tools_smoke.main,
    "local-failure-smoke": local_failure_smoke.main,
    "profile-release-smoke": profile_release_smoke.main,
    "tab-unload-smoke": tab_unload_smoke.main,
    "headless-smoke": headless_smoke.main,
    "little-arx-space-smoke": little_arx_space_smoke.main,
    "notification-smoke": notification_smoke.main,
    "hand-check-smoke": hand_check_smoke.main,
    "component-updates-smoke": component_updates_smoke.main,
    "sign-in-smoke": sign_in_smoke.main,
    "sign-in-interface-smoke": sign_in_smoke.interface,
    "build-preview": preview.build,
    "test-preview": preview.test,
    "preview": preview.main,
    "tour-videos": preview.tour_videos,
    "test-all": test_all.main,
    "test-runtime": test_runtime.main,
    "test-mcp": test_mcp.main,
    "open": project.open_project,
    "engine-tools": engine_tools.main,
    "engine-checkout": engine_checkout.main,
    "engine-prepare": engine_build.prepare,
    "engine-overlay-report": engine_overlay.report,
    "engine-upstream": engine_upstream.main,
    "engine-bump": engine_upstream.bump_main,
    "engine-anchor-check": engine_anchors.main,
    "engine-check": engine_build.check,
    "engine-build": engine_build.main,
    "engine-cache": engine_archive.main,
    "engine-restore": engine_cache.restore,
    "engine-fetch": engine_fetch.main,
    "engine-validate": engine_bundle.require,
    "engine-hosts": engine_hosts.main,
    "engine-host": engine_host.main,
    "engine-smoke": engine_smoke.main,
    "extensions-smoke": extensions_smoke.main,
    "extension-install-smoke": extension_install_smoke.main,
    "webstore-install-smoke": webstore_install_smoke.main,
    "close-smoke": close_smoke.main,
    "hang-smoke": hang_smoke.main,
    "inspection-smoke": inspection_smoke.main,
    "reference-click-smoke": reference_click_smoke.main,
    "reference-form-smoke": reference_form_smoke.main,
    "reference-keypress-smoke": reference_keypress_smoke.main,
    "reference-scroll-smoke": reference_scroll_smoke.main,
    "link-context-smoke": link_context_smoke.main,
    "focused-link-smoke": focused_link_smoke.main,
    "back-forward-cache-smoke": back_forward_cache_smoke.main,
    "cross-site-link-smoke": cross_site_link_smoke.main,
    "site-settings-smoke": site_settings_smoke.main,
    "browsing-data-smoke": browsing_data_smoke.main,
    "document-capture-smoke": document_capture_smoke.main,
    "gesture-smoke": gesture_smoke.main,
    "background-visibility-smoke": background_visibility_smoke.main,
}
# Commands that take their own options, passed through from Make's ARGS.
ARGUMENT_COMMANDS = {"localization-export", "localization-import", "localization-check", "dmg", "dmg-verify", "appcast", "install", "update", "cloudkit-probe", "cloudkit-schema", "version", "benchmark", "sidebar-scroll", "load-ladder", "engine-hosts", "perf-gate", "engine-upstream", "engine-bump", "engine-anchor-check", "agent-evals", "hand-check-smoke"}
SUMMARIES = {
    "localization-export": "Strings a language still needs, as JSON chunks with its glossary (ARGS='--lang de [--chunk-size N --out DIR]')",
    "localization-import": "Validate translated chunks and merge them into the catalogs (ARGS='--lang de --from DIR [--validate-only]')",
    "localization-check": "Missing, stale and suspicious translations per language; fails only for shipped ones [ARGS='--lang de']",
    "style": "Advisory swift-style warnings from SwiftFormat, SwiftLint and StyleCheck; fails only if a tool crashes",
    "run": "Build Debug as Arx on the installed Arx's data and open it; the installed Arx quits first",
    "run-preview": "Build Debug as Arx Preview, with its own data folder and Keychain item, and open it",
    "run-dev": "Build Arx Dev (its own bundle ID and data) and open it",
    "notification-smoke": "A site's notification in Notification Center, its click routes and private denial, in Arx Dev; needs the screen. Exits 77 (NOT RUN) until Arx Dev may post notifications",
    "hand-check-smoke": "Find refocus, window full screen, long addresses and private Save Page As in Arx Dev; needs the screen [ARGS='--phase NAME']",
    "agent-evals": "Scripted agents do tasks through MCP in Arx --headless; calls and tokens against the baseline [ARGS='--app APP --record --model claude']",
    "sidebar-scroll": "Frame drops while the sidebar scrolls in the real window; needs the screen [ARGS='--app APP | --ref COMMIT']",
    "load-ladder": "Tabs Arx holds before a limit breaks, awake and unloaded, in Arx --headless [ARGS='--app APP --record --quick']",
    "perf-gate": "Benchmark a release against the previous one; fail on a regression (ARGS='--current APP [--record]')",
    "dmg": "Build, sign, notarize and package a release disk image",
    "appcast": "Sparkle appcast and deltas for a release disk image; publishes nothing (ARGS='--previous DIR')",
    "engine-overlay-report": "Apply every overlay to the prepared engine tree; list each missing anchor",
    "engine-upstream": "Report a helium-macos release newer than engine.lock.json [ARGS='--json PATH']",
    "engine-bump": "Move engine.lock.json and the files naming its pins to a release (ARGS='--version TAG' or '--json PATH')",
    "engine-anchor-check": "Check every overlay anchor on the locked release without the Chromium tree [ARGS='--report PATH']",
    "engine-hosts": "List the engine framework's hard-coded hosts; fail on Helium or unlisted Google ones [ARGS=path]",
    "install": "Build Release, sign it as make dmg does and install it as /Applications/Arx.app [ARGS=--open]",
    "update": "Like make install, but only replaces an Arx already in /Applications [ARGS=--open]",
}


def main(arguments):
    command = arguments[0] if arguments else "help"
    if len(arguments) > 1 and command not in ARGUMENT_COMMANDS:
        command = "help"
    if command == "help":
        print("make bootstrap      Install pinned tools and generate Xcode workspace")
        for name in COMMANDS:
            summary = SUMMARIES.get(name)
            print(f"make {name:<14} {summary}" if summary else f"make {name}")
        return 0
    if command not in COMMANDS:
        print(f"Unknown task: {command}", file=sys.stderr)
        return 2
    action = COMMANDS[command]
    if command in ARGUMENT_COMMANDS:
        action = partial(action, arguments[1:])
    return execute(action)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
