#if DEBUG
import AppKit
import BrowserCore
import BrowserExtensionsClient
import ChromiumBrowserEngine
import ExtensionsFeature
import Foundation
import _ComposableArchitecture

/// Drives the real AppFeature/Settings picker-result and consent actions. The
/// external runner owns all selected files and the whole signed app process.
/// System file-picker interaction itself remains a manual verification case.
@MainActor
internal enum ExtensionSettingsSmoke {
	internal static func run(
		fixture: ExtensionSettingsSmokeFixture,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		consentIsVisible: @escaping @MainActor () -> Bool
	) async throws {
		let run = Run(fixture: fixture, store: store, engine: engine, consentIsVisible: consentIsVisible)
		do {
			switch fixture.phase {
			case .initial:
				try await run.exercise()
				await store.send(.ui(.closeSettings)).finish()
				print("ARX_EXTENSION_SETTINGS_APP_VERIFIED")

			case .relaunch:
				try await run.exerciseRelaunch()
				await store.send(.ui(.closeSettings)).finish()
				print("ARX_EXTENSION_SETTINGS_APP_RELAUNCH_VERIFIED")
			}
		} catch {
			run.reportFailure()
			await store.send(.settings(.extensions(.ui(.dismiss)))).finish()
			throw error
		}
	}

	@MainActor
	private final class Run {
		private let fixture: ExtensionSettingsSmokeFixture
		private let store: StoreOf<AppFeature>
		private let engine: ChromiumBrowserEngine
		private let consentIsVisible: @MainActor () -> Bool
		private typealias Failure = ExtensionSettingsSmokeFixture.Failure

		private var phase: String = "startup"
		private var initialExtensions: [Profile.ID: [BrowserExtension]] = [:]

		internal init(
			fixture: ExtensionSettingsSmokeFixture,
			store: StoreOf<AppFeature>,
			engine: ChromiumBrowserEngine,
			consentIsVisible: @escaping @MainActor () -> Bool
		) {
			self.fixture = fixture
			self.store = store
			self.engine = engine
			self.consentIsVisible = consentIsVisible
		}

		internal func reportFailure() {
			let state = store.settings.extensions
			let error = state.error.map { String(describing: $0) } ?? "none"
			let evidence = "ARX_EXTENSION_SETTINGS_APP_PHASE_FAILED: \(phase) error=\(error) "
			+ "working=\(state.isWorking) prompt=\(state.pendingInstallation != nil) visible=\(consentIsVisible()) "
			+ "available=\(state.isAvailable) install=\(state.isInstallationAvailable) "
			+ "inventoryCount=\(state.inventory?.extensions.count ?? -1) presented=\(state.isPresented)\n"
			FileHandle.standardError.write(Data(evidence.utf8))
		}

		internal func exercise() async throws {
			let originalPreferences = store.persistedPreferences
			store.send(.ui(.openSettings))
			store.send(.settings(.ui(.profileSelected(ExtensionSettingsSmokeFixture.profileA))))
			store.send(.settings(.extensions(.ui(.present))))
			try await waitInventory(profile: ExtensionSettingsSmokeFixture.profileA)
			guard store.settings.extensions.isInstallationAvailable, hasNoFixtureExtension
			else { throw Failure.unavailable }

			phase = "initial-decline"
			let declined = try await prepare("v1.crx")
			try await resolve(declined, accept: false)
			guard hasNoFixtureExtension else { throw Failure.unexpectedConsent }
			store.send(.settings(.extensions(.ui(.respondToInstallation(declined, true)))))
			guard store.settings.extensions.pendingInstallation == nil, hasNoFixtureExtension
			else { throw Failure.unexpectedConsent }
			print("ARX_EXTENSION_SETTINGS_APP_DECLINED_REPLAY")

			phase = "install-v1"
			try await accept("v1.crx")
			try requireInstalled(version: "1.0")
			let firstCount = try await worker(
				profile: ExtensionSettingsSmokeFixture.profileA,
				space: ExtensionSettingsSmokeFixture.spaceA,
				version: "1.0"
			)
			print("ARX_EXTENSION_SETTINGS_APP_INSTALLED_WORKER")

			phase = "decline-escalation"
			let update = try await prepare("v2.crx", expectedID: fixture.configuration.extensionID)
			guard
				update.candidate.requiredPermissions.apis.contains("tabs"),
				update.candidate.requiredPermissions.apis.contains("nativeMessaging"),
				!update.candidate.warnings.isEmpty
			else { throw Failure.invalidPrompt }

			try await resolve(update, accept: false)
			try requireInstalled(version: "1.0")
			let declinedCount = try await worker(
				profile: ExtensionSettingsSmokeFixture.profileA,
				space: ExtensionSettingsSmokeFixture.spaceA,
				version: "1.0"
			)
			guard declinedCount > firstCount else { throw Failure.worker }
			print("ARX_EXTENSION_SETTINGS_APP_ESCALATION_DECLINED")

			phase = "invalid-packages"
			try await invalid("other-key.crx", expectedID: fixture.configuration.extensionID)
			try requireInstalled(version: "1.0")
			try await selectProfile(ExtensionSettingsSmokeFixture.profileB)
			try await invalid("corrupt.crx")
			guard hasNoFixtureExtension else { throw Failure.unexpectedProfile }
			print("ARX_EXTENSION_SETTINGS_APP_INVALID_PACKAGES")

			phase = "profile-isolation"
			try await accept("v1.crx")
			try requireInstalled(version: "1.0")
			let isolatedCount = try await worker(
				profile: ExtensionSettingsSmokeFixture.profileB,
				space: ExtensionSettingsSmokeFixture.spaceB,
				version: "1.0"
			)
			guard isolatedCount == 1 else { throw Failure.unexpectedProfile }
			let cancelled = try await prepare("v2.crx", expectedID: fixture.configuration.extensionID)
			try await selectProfile(ExtensionSettingsSmokeFixture.profileA)
			store.send(.settings(.extensions(.ui(.respondToInstallation(cancelled, true)))))
			try requireInstalled(version: "1.0")
			print("ARX_EXTENSION_SETTINGS_APP_PROFILE_CANCELLED")

			phase = "accept-escalation"
			try await accept("v2.crx", expectedID: fixture.configuration.extensionID)
			try requireInstalled(version: "2.0")
			guard
				let updated = fixtureExtension,
				updated.activePermissions.apis.contains("nativeMessaging"),
				updated.activePermissions.apis.contains("tabs")
			else { throw Failure.invalidInventory }

			let updatedCount = try await worker(
				profile: ExtensionSettingsSmokeFixture.profileA,
				space: ExtensionSettingsSmokeFixture.spaceA,
				version: "2.0"
			)
			guard updatedCount > declinedCount else { throw Failure.worker }

			try await exerciseSiteMenuPopup()
			try await exerciseExtensionWindow(
				probe: "extension-window-probe.html",
				marker: "ARX_EXTENSION_SETTINGS_APP_EXTENSION_WINDOW"
			)

			// DEV-1314: the same page opened with `chrome.tabs.create`, as 1Password opens its
			// welcome and sign-in page while its toolbar button has no popup.
			try await exerciseExtensionWindow(
				probe: "extension-tab-probe.html",
				marker: "ARX_EXTENSION_SETTINGS_APP_EXTENSION_TAB"
			)

			phase = "cleanup"
			try await removeInstalled()
			try await selectProfile(ExtensionSettingsSmokeFixture.profileB)
			try requireInstalled(version: "1.0")
			try await removeInstalled()
			guard preferencesUnchanged(from: originalPreferences)
			else { throw Failure.unexpectedConsent }

			print("ARX_EXTENSION_SETTINGS_APP_UPDATED_ISOLATED_CLEANED")

			try await exerciseUnpacked()
			guard preferencesUnchanged(from: originalPreferences)
			else { throw Failure.developerControls }
		}

		/// DEV-828: the site menu's extension tile runs the extension's action for the page the
		/// menu opened over, so its popup opens at the tile, not the Extensions sheet.
		private func exerciseSiteMenuPopup() async throws {
			phase = "site-menu-popup"
			let extensionID = fixture.configuration.extensionID
			guard
				let tab = store.main.viewer.item.tab,
				tab.profileID == ExtensionSettingsSmokeFixture.profileA,
				let window = LinkSharingClient.presentationWindow(for: store.main.id)
			else { throw Failure.siteMenu }

			window.makeKeyAndOrderFront(nil)
			NSApplication.shared.activate()
			try requireNoExtensionsPill(in: window)
			print("ARX_EXTENSION_SETTINGS_APP_NO_EXTENSIONS_PILL")
			store.send(.main(.ui(.siteMenu(.opened))))
			try await wait {
				self.store.main.siteMenu.context?.tabID == tab.id
				&& self.store.main.siteMenu.extensions?.contains(where: { $0.id == extensionID }) == true
			}

			// Where a tile would be, near the window's top left, in AppKit screen coordinates.
			let point = CGPoint(x: window.frame.minX + 80, y: window.frame.maxY - 60)
			let before = Set(NSApplication.shared.windows.filter(\.isVisible).map(ObjectIdentifier.init))
			store.send(.main(.ui(.siteMenu(.runExtension(extensionID, screenPoint: point)))))
			func popup() -> NSWindow? {
				NSApplication.shared.windows.first { candidate in
					candidate.isVisible
					&& !before.contains(ObjectIdentifier(candidate))
					&& candidate.frame.insetBy(dx: -48, dy: -48).contains(point)
				}
			}
			try await wait { popup() != nil }

			// The action opens a popup; it doesn't navigate or reload the page.
			guard engine.client.snapshot(tab.id)?.navigation.isLoading == false
			else { throw Failure.siteMenu }

			popup()?.close()
			try await wait { popup() == nil }
			store.send(.main(.ui(.siteMenu(.closed))))
			print("ARX_EXTENSION_SETTINGS_APP_SITE_MENU_POPUP")
		}

		/// DEV-1240: an extension's own window (`chrome.windows.create`, as 1Password's pop-out and
		/// unlock window) opens in a new Little Arx that takes the keyboard, answers with the ID its
		/// page then reports, and closes when the extension closes it. A probe page asks the worker
		/// to open it; a key typed into the window makes the worker call `chrome.windows.remove`.
		/// DEV-1314: the tab probe page has the worker call `chrome.tabs.create` for the page
		/// instead, which answers with the tab and the window it's in.
		private func exerciseExtensionWindow(probe: String, marker: String) async throws {
			phase = probe
			let extensionID = fixture.configuration.extensionID
			let windows = store.windows.ids
			let littleWindows = Set(store.littleWindows.ids)
			let url = fixture.configuration.baseURL.deletingLastPathComponent()
				.appendingPathComponent(probe)
				.appending(queryItems: [.init(name: "run", value: UUID().uuidString.lowercased())])
			store.send(.ui(.openURLInSpace(url, ExtensionSettingsSmokeFixture.spaceA, .mainBrowser)))

			func probeTitle() -> String? {
				guard
					let tab = store.main.viewer.item.tab,
					tab.profileID == ExtensionSettingsSmokeFixture.profileA,
					let snapshot = engine.client.snapshot(tab.id),
					snapshot.navigation.url == url
				else { return nil }

				return snapshot.navigation.title
			}

			let created = "ARX_EXTENSION_WINDOW_CREATED:"
			try await wait { probeTitle()?.hasPrefix(created) == true }
			let answer = probeTitle()?.dropFirst(created.count).split(separator: ":") ?? []
			guard
				answer.count == 2,
				let extensionWindow = Int(answer[0]),
				extensionWindow >= 0,
				answer[1] == "1"
			else { throw Failure.extensionWindow }

			let tabs = store.workspace.tabs.ids

			// A new Little Arx shows the extension's page, has the keyboard, and its page sees the
			// window the call answered with.
			var windowID: UUID?
			try await wait {
				guard let little = self.store.littleWindows.first(where: { !littleWindows.contains($0.id) })
				else { return false }

				windowID = little.id
				let address = little.tab.reopeningURL
				return address.scheme == "chrome-extension"
				&& address.host == extensionID
				&& address.path == "/window.html"
				&& little.tab.profileID == ExtensionSettingsSmokeFixture.profileA
				&& self.store.focusedWindowID == little.id
				&& self.engine.contentHostFixtureView(little.tab.id)?.window?.isKeyWindow == true
				&& self.engine.client.snapshot(little.tab.id)?.navigation.title
					== "ARX_EXTENSION_WINDOW_READY:\(extensionWindow)"
			}
			guard
				let windowID,
				let little = store.littleWindows[id: windowID],
				let window = engine.contentHostFixtureView(little.tab.id)?.window
			else { throw Failure.extensionWindow }

			// A key typed into the window reaches its focused field; no click gives it focus first.
			try typeKey("x", in: window)
			try await wait {
				self.store.littleWindows[id: windowID] == nil
				&& probeTitle() == "ARX_EXTENSION_WINDOW_CLOSED:x"
			}
			guard
				store.windows.ids == windows,
				store.workspace.tabs.ids == tabs,
				Set(store.littleWindows.ids) == littleWindows
			else { throw Failure.extensionWindow }

			print(marker)
		}

		private func typeKey(_ characters: String, in window: NSWindow) throws {
			for type in [NSEvent.EventType.keyDown, .keyUp] {
				guard let event = NSEvent.keyEvent(
					with: type,
					location: .zero,
					modifierFlags: [],
					timestamp: ProcessInfo.processInfo.systemUptime,
					windowNumber: window.windowNumber,
					context: nil,
					characters: characters,
					charactersIgnoringModifiers: characters,
					isARepeat: false,
					keyCode: 7
				) else { throw Failure.extensionWindow }

				window.sendEvent(event)
			}
		}

		/// DEV-849: with an extension that has an action, nothing over the page draws an
		/// "Extensions" pill. The engine's own button stays, as an untitled transparent 1x1 anchor.
		private func requireNoExtensionsPill(in window: NSWindow) throws {
			guard let root = window.contentView else { throw Failure.extensionsPill }
			var anchors = 0
			var stack: [NSView] = [root]
			while let view = stack.popLast() {
				stack.append(contentsOf: view.subviews)
				guard
					let button = view as? NSButton,
					!button.isHiddenOrHasHiddenAncestor
				else { continue }
				if button.identifier?.rawValue == "ArxExtensionActions" {
					anchors += 1
					guard
						button.title.isEmpty,
						button.isTransparent,
						button.frame.width <= 1, button.frame.height <= 1
					else { throw Failure.extensionsPill }
				} else if button.title == "Extensions" {
					throw Failure.extensionsPill
				}
			}
			guard anchors > 0 else { throw Failure.extensionsPill }
		}

		/// Developer-mode folder controls through the same Settings actions the
		/// folder picker and buttons send. Profile B stays untouched throughout.
		/// The folder stays loaded for the relaunch run, which removes it.
		private func exerciseUnpacked() async throws {
			phase = "unpacked-hidden"
			try await selectProfile(ExtensionSettingsSmokeFixture.profileA)
			guard
				!store.settings.general.developerModeEnabled,
				store.settings.extensions.isUnpackedAvailable,
				!store.settings.extensions.canLoadUnpacked
			else { throw Failure.developerControls }

			store.send(.settings(.extensions(.ui(.chooseUnpackedDirectory))))
			guard store.settings.extensions.directorySelection == nil
			else { throw Failure.developerControls }

			print("ARX_EXTENSION_SETTINGS_APP_UNPACKED_HIDDEN")

			phase = "unpacked-errors"
			try await setDeveloperMode(true)
			try await unpackedFailure(ExtensionSettingsSmokeFixture.missingFolder) { $0 == .directoryMissing }
			try await unpackedFailure(ExtensionSettingsSmokeFixture.unreadableFolder) { $0 == .directoryUnreadable }
			try await unpackedFailure(ExtensionSettingsSmokeFixture.invalidFolder) { failure in
				guard case let .invalidManifest(detail) = failure else { return false }

				return detail.localizedCaseInsensitiveContains("manifest")
			}
			guard unpackedItem == nil else { throw Failure.unpackedError }

			print("ARX_EXTENSION_SETTINGS_APP_UNPACKED_ERRORS")

			phase = "unpacked-load"
			try await loadUnpacked(ExtensionSettingsSmokeFixture.unpackedFolder)
			guard
				let loaded = unpackedItem,
				loaded.version == "1.0",
				loaded.state == .enabled,
				loaded.canReload
			else { throw Failure.unpackedLoad }

			let firstCount = try await worker(
				profile: ExtensionSettingsSmokeFixture.profileA,
				space: ExtensionSettingsSmokeFixture.spaceA,
				version: "1.0"
			)
			try await selectProfile(ExtensionSettingsSmokeFixture.profileB)
			guard unpackedItem == nil else { throw Failure.unexpectedProfile }

			try await selectProfile(ExtensionSettingsSmokeFixture.profileA)
			print("ARX_EXTENSION_SETTINGS_APP_UNPACKED_LOADED_ISOLATED")

			phase = "unpacked-reload"
			try writeUnpackedManifest(from: "1.0", to: "1.1")
			try await reloadUnpacked()
			guard let reloaded = unpackedItem, reloaded.version == "1.1", reloaded.state == .enabled
			else { throw Failure.unpackedReload }

			let reloadedCount = try await worker(
				profile: ExtensionSettingsSmokeFixture.profileA,
				space: ExtensionSettingsSmokeFixture.spaceA,
				version: "1.1"
			)
			guard reloadedCount > firstCount else { throw Failure.worker }

			print("ARX_EXTENSION_SETTINGS_APP_UNPACKED_RELOADED")

			phase = "unpacked-developer-off"
			try await setDeveloperMode(false)
			guard !store.settings.extensions.canLoadUnpacked
			else { throw Failure.developerControls }

			store.send(.settings(.extensions(.ui(.refresh))))
			try await waitInventory(profile: ExtensionSettingsSmokeFixture.profileA)
			guard let kept = unpackedItem, kept.version == "1.1", kept.state == .enabled
			else { throw Failure.developerControls }

			if let inventory = store.settings.extensions.inventory {
				let request = BrowserExtensionRequest(inventory: inventory, extensionID: kept.id, action: .reload)
				store.send(.settings(.extensions(.ui(.reload(request)))))
			}
			guard
				!store.settings.extensions.isWorking,
				store.settings.extensions.inventory?.extensions.contains(kept) == true
			else { throw Failure.developerControls }

			_ = try await worker(
				profile: ExtensionSettingsSmokeFixture.profileA,
				space: ExtensionSettingsSmokeFixture.spaceA,
				version: "1.1"
			)
			try await selectProfile(ExtensionSettingsSmokeFixture.profileB)
			guard unpackedItem == nil else { throw Failure.unexpectedProfile }

			print("ARX_EXTENSION_SETTINGS_APP_UNPACKED_DEVELOPER_OFF_KEPT")
		}

		/// Second process on the profile the initial run left behind. Arx's
		/// developer mode is off and Chromium's per-profile developer mode is
		/// still on, so Chromium must restore the folder from its path.
		internal func exerciseRelaunch() async throws {
			let originalPreferences = store.persistedPreferences
			phase = "relaunch-restored"
			store.send(.ui(.openSettings))
			store.send(.settings(.ui(.profileSelected(ExtensionSettingsSmokeFixture.profileA))))
			store.send(.settings(.extensions(.ui(.present))))
			try await waitInventory(profile: ExtensionSettingsSmokeFixture.profileA)
			guard
				!store.settings.general.developerModeEnabled,
				!store.settings.extensions.canLoadUnpacked,
				hasNoFixtureExtension
			else { throw Failure.developerControls }

			guard
				let restored = unpackedItem,
				restored.version == "1.1",
				restored.state == .enabled,
				restored.canReload
			else { throw Failure.unpackedRelaunch }

			// The worker's profile-local count was already 3 before the relaunch.
			let restoredCount = try await worker(
				profile: ExtensionSettingsSmokeFixture.profileA,
				space: ExtensionSettingsSmokeFixture.spaceA,
				version: "1.1"
			)
			guard restoredCount > 3 else { throw Failure.unpackedRelaunch }

			try await selectProfile(ExtensionSettingsSmokeFixture.profileB)
			guard unpackedItem == nil else { throw Failure.unexpectedProfile }

			try await selectProfile(ExtensionSettingsSmokeFixture.profileA)
			print("ARX_EXTENSION_SETTINGS_APP_UNPACKED_RELAUNCH_RESTORED")

			phase = "relaunch-reload"
			try await setDeveloperMode(true)
			try writeUnpackedManifest(from: "1.1", to: "1.2")
			try await reloadUnpacked()
			guard
				let reloaded = unpackedItem,
				reloaded.id == restored.id,
				reloaded.version == "1.2",
				reloaded.state == .enabled
			else { throw Failure.unpackedReload }

			let reloadedCount = try await worker(
				profile: ExtensionSettingsSmokeFixture.profileA,
				space: ExtensionSettingsSmokeFixture.spaceA,
				version: "1.2"
			)
			guard reloadedCount > restoredCount else { throw Failure.worker }

			try await setDeveloperMode(false)
			print("ARX_EXTENSION_SETTINGS_APP_UNPACKED_RELAUNCH_RELOADED")

			phase = "unpacked-cleanup"
			try await remove(reloaded.id)
			try await selectProfile(ExtensionSettingsSmokeFixture.profileB)
			guard unpackedItem == nil else { throw Failure.unexpectedProfile }

			guard preferencesUnchanged(from: originalPreferences)
			else { throw Failure.developerControls }

			print("ARX_EXTENSION_SETTINGS_APP_UNPACKED_REMOVED")
		}

		private var unpackedPath: String {
			fixture.root.appendingPathComponent(ExtensionSettingsSmokeFixture.unpackedFolder).path
		}

		private var unpackedItem: BrowserExtension? {
			store.settings.extensions.inventory?.extensions.first { $0.sourcePath == unpackedPath }
		}

		private func setDeveloperMode(_ enabled: Bool) async throws {
			store.send(.settings(.ui(.developerModeEnabled(enabled))))
			try await wait { self.store.settings.extensions.developerModeEnabled == enabled }
		}

		private func chooseFolder(_ name: String) throws {
			store.send(.settings(.extensions(.ui(.chooseUnpackedDirectory))))
			guard let selection = store.settings.extensions.directorySelection
			else { throw Failure.developerControls }

			// The same immutable context the production folder panel returns.
			let folder = fixture.root.appendingPathComponent(name, isDirectory: true)
			store.send(.settings(.extensions(.ui(.selectDirectory(selection, folder)))))
		}

		private func unpackedFailure(
			_ name: String,
			matches: (BrowserExtensionsClient.Failure) -> Bool
		) async throws {
			try chooseFolder(name)
			try await wait { !self.store.settings.extensions.isWorking }
			guard let error = store.settings.extensions.error, matches(error) else {
				let evidence = "ARX_EXTENSION_SETTINGS_UNPACKED_ERROR phase=\(phase) folder=\(name) "
				+ "error=\(String(describing: store.settings.extensions.error))\n"
				FileHandle.standardError.write(Data(evidence.utf8))
				throw Failure.unpackedError
			}

			store.send(.settings(.extensions(.ui(.refresh))))
			try await waitInventory(profile: ExtensionSettingsSmokeFixture.profileA)
		}

		/// A running worker may invalidate the read inventory first. Refresh and
		/// choose the folder again, as a user would.
		private func loadUnpacked(_ name: String) async throws {
			for attempt in 1...3 {
				try chooseFolder(name)
				try await wait { !self.store.settings.extensions.isWorking }
				if store.settings.extensions.error == .staleInventory, attempt < 3 {
					store.send(.settings(.extensions(.ui(.refresh))))
					try await waitInventory(profile: ExtensionSettingsSmokeFixture.profileA)
					continue
				}

				try await waitInventory(profile: ExtensionSettingsSmokeFixture.profileA)
				return
			}
		}

		private func reloadUnpacked() async throws {
			for attempt in 1...3 {
				guard
					let inventory = store.settings.extensions.inventory,
					let item = unpackedItem
				else { throw Failure.unpackedReload }

				let request = BrowserExtensionRequest(inventory: inventory, extensionID: item.id, action: .reload)
				store.send(.settings(.extensions(.ui(.reload(request)))))
				try await wait { !self.store.settings.extensions.isWorking }
				if store.settings.extensions.error == .staleInventory, attempt < 3 {
					store.send(.settings(.extensions(.ui(.refresh))))
					try await waitInventory(profile: inventory.profileID)
					continue
				}

				try await waitInventory(profile: inventory.profileID)
				return
			}
		}

		private func writeUnpackedManifest(
			from current: String,
			to version: String
		) throws {
			let manifest = fixture.root
				.appendingPathComponent(ExtensionSettingsSmokeFixture.unpackedFolder)
				.appendingPathComponent("manifest.json")
			let data = try Data(contentsOf: manifest)
			guard
				var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
				object["version"] as? String == current
			else { throw Failure.invalidFixture }

			object["version"] = version
			try JSONSerialization.data(withJSONObject: object).write(to: manifest)
		}

		/// Chrome may disable and re-enable its bundled component extension soon
		/// after a profile starts, which correctly invalidates the read inventory.
		/// Like a user, refresh and choose the package again, up to twice.
		private func prepare(
			_ name: String,
			expectedID: String? = nil
		) async throws -> BrowserExtensionInstallPrompt {
			for attempt in 1..<3 {
				do {
					return try await prepareOnce(name, expectedID: expectedID)
				} catch Failure.staleInventory {
					let evidence = "ARX_EXTENSION_SETTINGS_REFRESHED phase=\(phase) attempt=\(attempt)\n"
					FileHandle.standardError.write(Data(evidence.utf8))
				}
			}
			return try await prepareOnce(name, expectedID: expectedID)
		}

		private func prepareOnce(
			_ name: String,
			expectedID: String? = nil
		) async throws -> BrowserExtensionInstallPrompt {
			guard ExtensionSettingsSmokeFixture.packageNames.contains(name)
			else { throw Failure.invalidFixture }

			let profile = store.settings.extensions.profile?.id
			store.send(.settings(.extensions(.ui(.choosePackage(expectedID)))))
			guard let selection = store.settings.extensions.packageSelection
			else { throw Failure.unavailable }

			// Same immutable context returned by the production file-picker callback;
			// no fake client, verifier bypass or signed-fixture API is injected.
			let package = fixture.root.appendingPathComponent(name)
			store.send(.settings(.extensions(.ui(.selectPackage(selection, package)))))
			try await wait {
				self.store.settings.extensions.pendingInstallation != nil
				|| !self.store.settings.extensions.isWorking
			}
			if store.settings.extensions.error == .staleInventory {
				store.send(.settings(.extensions(.ui(.refresh))))
				try await waitInventory(profile: selection.inventory.profileID)
				let refreshed = store.settings.extensions.inventory
				let evidence = "ARX_EXTENSION_SETTINGS_STALE_EVIDENCE phase=\(phase) "
				+ "revisionUnchanged=\(refreshed?.revision == selection.inventory.revision) "
				+ "metadataUnchanged=\(refreshed?.extensions == selection.inventory.extensions)\n"
				FileHandle.standardError.write(Data(evidence.utf8))
				throw Failure.staleInventory
			}
			guard
				let prompt = store.settings.extensions.pendingInstallation,
				prompt.profileID == profile,
				prompt.inventoryID == selection.inventory.id,
				prompt.revision == selection.inventory.revision,
				prompt.candidate.packageSHA256 == fixture.configuration.packages[name],
				prompt.candidate.extensionID == fixture.configuration.extensionID,
				prompt.candidate.sourceBasename == name,
				prompt.candidate.isUpdate == (expectedID != nil)
			else { throw Failure.invalidPrompt }

			try await wait { self.consentIsVisible() }
			return prompt
		}

		/// Chooses the package and accepts its prompt. The bundled component extension Chrome
		/// disables and enables again soon after a profile starts can move the inventory's
		/// revision between the prompt and the answer, so the engine refuses the answer as
		/// stale: like a user, refresh and accept again, up to twice.
		@discardableResult
		private func accept(
			_ name: String,
			expectedID: String? = nil
		) async throws -> BrowserExtensionInstallPrompt {
			for attempt in 1...3 {
				let prompt = try await prepare(name, expectedID: expectedID)
				store.send(.settings(.extensions(.ui(.respondToInstallation(prompt, true)))))
				try await wait { !self.store.settings.extensions.isWorking }
				if store.settings.extensions.error == .staleInventory, attempt < 3 {
					let evidence = "ARX_EXTENSION_SETTINGS_REFRESHED phase=\(phase) accept=\(attempt)\n"
					FileHandle.standardError.write(Data(evidence.utf8))
					store.send(.settings(.extensions(.ui(.refresh))))
					try await waitInventory(profile: prompt.profileID)
					continue
				}
				try await waitInventory(profile: prompt.profileID)
				return prompt
			}
			throw Failure.staleInventory
		}

		private func resolve(
			_ prompt: BrowserExtensionInstallPrompt,
			accept: Bool
		) async throws {
			store.send(.settings(.extensions(.ui(.respondToInstallation(prompt, accept)))))
			try await waitInventory(profile: prompt.profileID)
		}

		private func invalid(
			_ name: String,
			expectedID: String? = nil
		) async throws {
			store.send(.settings(.extensions(.ui(.choosePackage(expectedID)))))
			guard let selection = store.settings.extensions.packageSelection
			else { throw Failure.unavailable }

			let package = fixture.root.appendingPathComponent(name)
			store.send(.settings(.extensions(.ui(.selectPackage(selection, package)))))
			try await wait { !self.store.settings.extensions.isWorking }
			guard
				store.settings.extensions.pendingInstallation == nil,
				store.settings.extensions.error == .invalidPackage
			else { throw Failure.invalidPackageAccepted }

			store.send(.settings(.extensions(.ui(.refresh))))
			try await waitInventory(profile: selection.inventory.profileID)
		}

		private func selectProfile(_ profile: Profile.ID) async throws {
			store.send(.settings(.ui(.profileSelected(profile))))
			try await waitInventory(profile: profile)
		}

		private func waitInventory(profile: Profile.ID) async throws {
			try await wait {
				guard !self.store.settings.extensions.isWorking else { return false }
				if self.store.settings.extensions.error == .busy {
					self.store.send(.settings(.extensions(.ui(.refresh))))
					return false
				}
				return true
			}
			guard
				store.settings.extensions.error == nil,
				let inventory = store.settings.extensions.inventory,
				inventory.profileID == profile
			else { throw Failure.invalidInventory }

			let unrelated = inventory.extensions
				.filter { $0.id != fixture.configuration.extensionID && $0.sourcePath != unpackedPath }
				.sorted { $0.id < $1.id }

			if let initial = initialExtensions[profile] {
				guard unrelated == initial else { throw Failure.unexpectedProfile }
			} else {
				// A fresh ordinary Chromium profile can contain bundled extensions.
				// Keep their exact metadata unchanged through every fixture operation.
				guard hasNoFixtureExtension else { throw Failure.unexpectedProfile }
				initialExtensions[profile] = unrelated
			}
		}

		/// Whether the preferences are as they were, apart from when tabs were last viewed. Tabs
		/// are archived when idle by default (DEV-1326), so each tab the smoke opens or leaves is
		/// stamped there; that's the browser's bookkeeping, not something an extension changed.
		private func preferencesUnchanged(from original: BrowserPreferences) -> Bool {
			var current = store.persistedPreferences
			current.tabsLastViewed = original.tabsLastViewed
			return current == original
		}

		private var hasNoFixtureExtension: Bool {
			store.settings.extensions.inventory?.extensions.contains {
				$0.id == fixture.configuration.extensionID
			} == false
		}

		private var fixtureExtension: BrowserExtension? {
			store.settings.extensions.inventory?.extensions.first { $0.id == fixture.configuration.extensionID }
		}

		private func requireInstalled(version: String) throws {
			guard
				let item = fixtureExtension,
				item.state == .enabled,
				item.version == version
			else { throw Failure.invalidInventory }
		}

		private func worker(
			profile: Profile.ID,
			space: Space.ID,
			version: String
		) async throws -> Int {
			let url = fixture.configuration.baseURL.deletingLastPathComponent()
				.appendingPathComponent("extension-settings-probe.html")
				.appending(queryItems: [.init(name: "run", value: UUID().uuidString.lowercased())])
			store.send(.ui(.openURLInSpace(url, space, .mainBrowser)))
			let prefix = "ARX_EXTENSION_SETTINGS_WORKER:v=\(version):count="
			try await wait {
				guard
					let tab = self.store.main.viewer.item.tab,
					tab.profileID == profile,
					let snapshot = self.engine.client.snapshot(tab.id),
					snapshot.navigation.url == url
				else { return false }

				return snapshot.navigation.title.hasPrefix(prefix) && !snapshot.navigation.isLoading
			}
			guard
				let tab = store.main.viewer.item.tab,
				let title = engine.client.snapshot(tab.id)?.navigation.title,
				let count = Int(title.dropFirst(prefix.count)),
				(1...100).contains(count)
			else { throw Failure.worker }

			return count
		}

		private func removeInstalled() async throws {
			try await remove(fixture.configuration.extensionID)
		}

		private func remove(_ extensionID: String) async throws {
			for attempt in 1...3 {
				guard let inventory = store.settings.extensions.inventory
				else { throw Failure.invalidInventory }

				let request = BrowserExtensionRequest(inventory: inventory, extensionID: extensionID, action: .remove)
				store.send(.settings(.extensions(.ui(.requestRemoval(request)))))
				store.send(.settings(.extensions(.ui(.confirmRemoval(request)))))
				try await wait { !self.store.settings.extensions.isWorking }

				// A running worker may invalidate the read inventory first. Refresh
				// and confirm again with the new revision, as a user would.
				if store.settings.extensions.error == .staleInventory, attempt < 3 {
					let evidence = "ARX_EXTENSION_SETTINGS_REFRESHED phase=\(phase) attempt=\(attempt)\n"
					FileHandle.standardError.write(Data(evidence.utf8))
					store.send(.settings(.extensions(.ui(.refresh))))
					try await waitInventory(profile: inventory.profileID)
					continue
				}
				try await waitInventory(profile: inventory.profileID)
				guard store.settings.extensions.inventory?.extensions.contains(where: { $0.id == extensionID }) == false
				else { throw Failure.cleanup }
				return
			}
		}

		private func wait(line: UInt = #line, _ condition: @MainActor () -> Bool) async throws {
			let deadline = ContinuousClock.now + .seconds(15)
			while !condition() {
				guard ContinuousClock.now < deadline else {
					let evidence = "ARX_EXTENSION_SETTINGS_TIMED_OUT phase=\(phase) line=\(line)\n"
					FileHandle.standardError.write(Data(evidence.utf8))
					throw Failure.timedOut
				}
				try await Task.sleep(for: .milliseconds(50))
			}
		}
	}
}
#endif
