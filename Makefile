.DEFAULT_GOAL := help
MISE ?= mise
TASKS = $(MISE) exec -- python3 -m Scripts.tasks

.PHONY: help bootstrap project workspace check bangs test build-package build-app build-app-runtime build-app-signed run run-preview run-dev signing-check signing-setup release-signing-check release-signing-setup release-signing-cleanup test-all test-runtime test-mcp open submodules resolve check-toolchain engine-tools engine-checkout engine-prepare engine-overlay-report engine-upstream engine-bump engine-anchor-check engine-check engine-build engine-cache engine-restore engine-fetch engine-validate engine-hosts engine-host engine-smoke extension-install-smoke webstore-install-smoke extensions-smoke close-smoke inspection-smoke reference-click-smoke reference-form-smoke reference-keypress-smoke reference-scroll-smoke link-context-smoke focused-link-smoke back-forward-cache-smoke cross-site-link-smoke site-settings-smoke browsing-data-smoke document-capture-smoke gesture-smoke background-visibility-smoke external-consent-smoke extension-settings-smoke app-smoke password-smoke routing-smoke profile-retirement-smoke migration-clear-smoke developer-tools-smoke local-failure-smoke profile-release-smoke tab-unload-smoke headless-smoke little-arx-space-smoke notification-smoke component-updates-smoke sign-in-smoke sign-in-interface-smoke build-preview preview test-preview tour-videos dmg dmg-verify appcast install update cloudkit-probe cloudkit-schema benchmark sidebar-scroll hand-check-smoke load-ladder perf-gate agent-evals version credits hang-smoke
help:
	@$(TASKS) help
bootstrap:
	$(MISE) install
	@$(TASKS) resolve
	@$(TASKS) project
project workspace check bangs test build-package build-app build-app-runtime build-app-signed run run-preview run-dev signing-check signing-setup release-signing-check release-signing-setup release-signing-cleanup test-all test-runtime test-mcp open submodules resolve check-toolchain engine-tools engine-checkout engine-prepare engine-overlay-report engine-check engine-build engine-cache engine-restore engine-fetch engine-validate engine-host engine-smoke extension-install-smoke webstore-install-smoke extensions-smoke close-smoke hang-smoke inspection-smoke reference-click-smoke reference-form-smoke reference-keypress-smoke reference-scroll-smoke link-context-smoke focused-link-smoke back-forward-cache-smoke cross-site-link-smoke site-settings-smoke browsing-data-smoke document-capture-smoke gesture-smoke background-visibility-smoke external-consent-smoke extension-settings-smoke app-smoke password-smoke routing-smoke profile-retirement-smoke migration-clear-smoke developer-tools-smoke local-failure-smoke profile-release-smoke tab-unload-smoke headless-smoke little-arx-space-smoke notification-smoke component-updates-smoke sign-in-smoke sign-in-interface-smoke build-preview preview test-preview tour-videos credits:
	@$(TASKS) $@
# make dmg ARGS='--skip-notarize'; make dmg-verify [path/to/Arx-<version>-<build>-arm64.dmg] [ARGS='--allow-unnotarized']
dmg:
	@$(TASKS) $@ $(ARGS)
dmg-verify:
	@$(TASKS) $@ $(filter %.dmg,$(MAKECMDGOALS)) $(ARGS)
# make engine-upstream [ARGS='--json PATH']: a helium-macos release newer than engine.lock.json, its kind and due date.
# make engine-bump ARGS='--version 0.21.3.1' (or '--json PATH' from engine-upstream): move the lock and the files naming it.
# make engine-anchor-check [ARGS='--report PATH --json PATH']: every overlay anchor on the locked release, without the
# Chromium tree (DEV-955). See DEVELOPMENT.md › Engine updates.
engine-upstream engine-bump engine-anchor-check:
	@$(TASKS) $@ $(ARGS)
# make engine-hosts [ARGS=path/to/Arx Framework.framework]: every hard-coded host in the engine;
# fails on a Helium host or a Google URL host not in Scripts/engine/allowed-hosts.json (DEV-930).
engine-hosts:
	@$(TASKS) $@ $(ARGS)
# make appcast ARGS='--previous path/to/releases [path/to/Arx-<version>-<build>-arm64.dmg]': signs the
# disk image's appcast entry and makes deltas and the Arx.dmg copy into build/release/appcast. Publishes nothing.
appcast:
	@$(TASKS) $@ $(ARGS)
# make install / make update [ARGS=--open]: a Release build signed as make dmg signs it, swapped into
# /Applications/Arx.app. No notarization, disk image or build number bump; update needs an installed Arx.
install update:
	@$(TASKS) $@ $(ARGS)
# make cloudkit-probe [ARGS='--app path/to/Arx.app']
cloudkit-probe:
	@$(TASKS) $@ $(ARGS)
# make cloudkit-schema [ARGS='--compare development|production']: writes CloudKit/arx.ckdb from the synced tables,
# or lists what that environment's schema lacks (needs a token from `xcrun cktool save-token`; DEV-1209).
cloudkit-schema:
	@$(TASKS) $@ $(ARGS)
# make benchmark [ARGS='--app path/to/Arx.app --launches 5 --tabs 10,50,100']; see Scripts/README.md
benchmark:
	@$(TASKS) $@ $(ARGS)
# make sidebar-scroll [ARGS='--app path/to/Arx.app | --ref COMMIT, --tabs 30,150,400 --runs 3']: frame drops while the
# sidebar scrolls in the real window (DEV-1238). Needs the screen and nobody at the Mac; see Scripts/README.md.
sidebar-scroll:
	@$(TASKS) $@ $(ARGS)
# make hand-check-smoke [ARGS='--phase find --phase full-screen --phase address --phase private-save --phase hide-element-toast']: the hand checks
# for find refocus, window full screen, long addresses, private Save Page As and Hide Element's toast clicks in Arx Dev; needs the screen.
hand-check-smoke:
	@$(TASKS) $@ $(ARGS)
# make load-ladder [ARGS='--app path/to/Arx.app --record --quick']: how many tabs Arx holds, awake and unloaded,
# before idle CPU, wakeups, main-thread lag, slow switches, memory pressure or swap break a limit (DEV-1027).
load-ladder:
	@$(TASKS) $@ $(ARGS)
# make agent-evals [ARGS='--app path/to/Arx.app --task NAME --record --model claude']: scripted agents do small tasks
# through MCP in Arx --headless; prints calls, tokens and pass/fail against Scripts/agent_evals/baseline.json (DEV-1026).
agent-evals:
	@$(TASKS) $@ $(ARGS)
# make perf-gate ARGS='--current build/release/Arx.app [--record] [--previous path/to/Previous/Arx.app] [--override "reason"]'
# or ARGS='--compare previous.json current.json': fails on a regression past Scripts/perf-gate.json (DEV-902).
perf-gate:
	@$(TASKS) $@ $(ARGS)
# make version shows the version; make version ARGS=0.2.0 sets the marketing version.
version:
	@$(TASKS) $@ $(ARGS)
# make localization-export ARGS='--lang de [--chunk-size 120 --out DIR]', make localization-import ARGS='--lang de --from DIR
# [--validate-only]', make localization-check [ARGS='--lang de --github --mark-stale']: see .agents/LOCALIZATION.md (DEV-1291).
.PHONY: localization-export localization-import localization-check
localization-export localization-import localization-check:
	@$(TASKS) $@ $(ARGS)
# make style: advisory SwiftFormat, SwiftLint and StyleCheck warnings (DEV-1280); exits 0 unless a tool crashes.
.PHONY: style
style:
	@$(TASKS) $@
# A disk image path given as a goal is an argument for dmg-verify, not something to build.
DMG_PATHS := $(filter %.dmg,$(MAKECMDGOALS))
ifneq ($(DMG_PATHS),)
.PHONY: $(DMG_PATHS)
$(DMG_PATHS):
	@:
endif
