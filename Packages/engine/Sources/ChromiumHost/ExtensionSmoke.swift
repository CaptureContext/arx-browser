import AppKit
import ChromiumEngine

/// Developer-only acceptance fixture. Native startup owns fresh storage and
/// only its compiled-in MV3 extension can be loaded by these APIs.
@MainActor
internal final class ExtensionSmoke: NSObject, NSWindowDelegate {
	internal static let argument: String = "--extension-fixture"
	private let runtime: ChromiumRuntime
	private let url: URL
	private var pages: [ChromiumPage] = []
	private var windows: [NSWindow] = []
	private var task: Task<Void, Never>?
	internal private(set) var verified: Bool = false

	internal init(
		runtime: ChromiumRuntime,
		url: URL
	) {
		self.runtime = runtime
		self.url = url

		super.init()
	}

	internal func open() {
		NSApplication.shared.setActivationPolicy(.regular)
		NSApplication.shared.activate(ignoringOtherApps: true)

		task = Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_EXTENSION_SMOKE_VERIFIED")
			} catch {
				diagnostic("ARX_EXTENSION_SMOKE_FAILED: \(error)")
			}

			finish()
		}
	}

	internal func windowWillClose(_ notification: Notification) {
		task?.cancel()
		finish()
	}

	private func verify() async throws {
		let firstProfile = UUID()
		let secondProfile = UUID()
		phase("first-install")
		let installed = try await runtime.loadExtensionFixtureForTesting(profileID: firstProfile)
		let extensionID = try fixtureID(installed)
		let first = try await makePage(profile: firstProfile)
		let second = try await makePage(profile: secondProfile)

		try first.navigate(to: url)
		try await wait(first, title: "ARX_EXTENSION_READY:worker=true:dnr=true:count=1")
		diagnostic("ARX_EXTENSION_SMOKE_WORKER_DNR")

		phase("ungranted-profile-inspect")
		let empty = try await runtime.extensions(profileID: secondProfile)

		guard !empty.extensions.contains(where: { $0.id == extensionID })
		else { throw Failure.isolation }

		try second.navigate(to: url)
		try await waitForPlainPage(second)

		try await ExtensionSmokeDisableEnable.run(
			extensionID: extensionID,
			inspect: { try await self.runtime.extensions(profileID: firstProfile) },
			manage: { action, inventory in
				try await self.runtime.manageExtension(
					action,
					extensionID: extensionID,
					in: inventory
				)
			},
			waitUntilUnloaded: {
				try first.reload()
				try await self.waitForPlainPage(first)
			},
			phase: phase
		)

		phase("enabled-page-reload")
		try first.reload()
		try await wait(first, title: "ARX_EXTENSION_READY:worker=true:dnr=true:count=2")
		diagnostic("ARX_EXTENSION_SMOKE_DISABLE_ENABLE_STALE")

		phase("second-install")
		let secondInstalled = try await runtime.loadExtensionFixtureForTesting(profileID: secondProfile)
		guard try fixtureID(secondInstalled) == extensionID else { throw Failure.isolation }

		try second.reload()
		try await wait(second, title: "ARX_EXTENSION_READY:worker=true:dnr=true:count=1")
		diagnostic("ARX_EXTENSION_SMOKE_PROFILE_ISOLATION")

		phase("first-options")
		try await verifyOptions(profile: firstProfile, extensionID: extensionID, count: 2)
		phase("second-options")
		try await verifyOptions(profile: secondProfile, extensionID: extensionID, count: 1)
		diagnostic("ARX_EXTENSION_SMOKE_OPTIONS_IDENTITY")

		// A private page stays open through the tabs API phases; it must never
		// be reachable or counted by the ordinary profiles' extension.
		phase("private-bystander")
		let privateBystanderID = UUID()
		try runtime.preparePrivateProfile(privateBystanderID)
		let privateBystander = try await makePage(profile: privateBystanderID)
		try privateBystander.navigate(to: url)
		try await waitForPlainPage(privateBystander)

		phase("first-shortcut")
		let secondBeforeShortcut = second.navigation
		try await ExtensionShortcutSmoke.run(
			runtime: runtime,
			page: first,
			extensionID: extensionID,
			count: 2
		)
		guard second.navigation == secondBeforeShortcut
		else { throw Failure.isolation }

		phase("second-shortcut")
		let firstBeforeShortcut = first.navigation
		try await ExtensionShortcutSmoke.run(
			runtime: runtime,
			page: second,
			extensionID: extensionID,
			count: 1
		)
		guard first.navigation == firstBeforeShortcut
		else { throw Failure.isolation }

		diagnostic("ARX_EXTENSION_SMOKE_SHORTCUT_SCOPE")
		diagnostic("ARX_EXTENSION_SMOKE_SHORTCUT_REPLAY")

		// DEV-974: pressed right after switching windows, then right after a reload, before the
		// renderer reports focus. The first profile's command count is at 2 from first-shortcut,
		// and the reload loads the fixture's content script a third time.
		phase("shortcut-after-window-switch")
		let secondBeforeQuickShortcut = second.navigation
		try await ExtensionShortcutSmoke.pressWithoutRendererFocus(
			runtime: runtime,
			page: first,
			extensionID: extensionID,
			invocations: 3
		)
		phase("shortcut-after-reload")
		try first.reload()
		try await wait(first, title: "ARX_EXTENSION_READY:worker=true:dnr=true:count=3")
		try await ExtensionShortcutSmoke.pressWithoutRendererFocus(
			runtime: runtime,
			page: first,
			extensionID: extensionID,
			invocations: 4
		)
		guard second.navigation == secondBeforeQuickShortcut
		else { throw Failure.isolation }

		diagnostic("ARX_EXTENSION_SMOKE_SHORTCUT_WITHOUT_FOCUS_WAIT")

		phase("first-action")
		try await ExtensionActionSmoke.run(
			runtime: runtime,
			page: first,
			extensionID: extensionID,
			count: 3,
			verifyNavigationInvalidation: true,
			verifyOutgoingLink: true,
			invokeWithShortcut: true
		)
		phase("second-action")
		try await ExtensionActionSmoke.run(
			runtime: runtime,
			page: second,
			extensionID: extensionID,
			count: 1,
			verifyNavigationInvalidation: false,
			invokeWithShortcut: true,
			verifyRuntimeOptionsIn: secondProfile
		)
		phase("app-action")
		try await ExtensionActionSmoke.runFromApp(
			runtime: runtime,
			page: second,
			privatePage: privateBystander,
			extensionID: extensionID
		)
		diagnostic("ARX_EXTENSION_SMOKE_APP_ACTION")
		phase("popup-window")
		try await ExtensionPopupWindowSmoke.run(
			runtime: runtime,
			page: second,
			extensionID: extensionID,
			count: 1
		)
		diagnostic("ARX_EXTENSION_SMOKE_POPUP_WINDOW")

		// Every action phase above checked the native button draws nothing (DEV-849).
		diagnostic("ARX_EXTENSION_SMOKE_BUTTON_INVISIBLE")
		diagnostic("ARX_EXTENSION_SMOKE_ACTION_IDENTITY")
		diagnostic("ARX_EXTENSION_SMOKE_ACTION_STALE")
		diagnostic("ARX_EXTENSION_SMOKE_POPUP_LINK")
		diagnostic("ARX_EXTENSION_SMOKE_RUNTIME_OPTIONS")

		phase("tabs-action")
		let tabsSource = try await makePage(profile: firstProfile)
		try await ExtensionTabsSmoke.run(
			runtime: runtime,
			page: tabsSource,
			windowmate: first,
			others: [second, privateBystander],
			url: url,
			extensionID: extensionID,
			profileTabs: 2
		)
		dismiss(tabsSource)
		dismiss(privateBystander)
		runtime.releasePrivateProfile(privateBystanderID)
		diagnostic("ARX_EXTENSION_SMOKE_TABS_SCOPE")
		diagnostic("ARX_EXTENSION_SMOKE_WINDOW_SCOPE")

		phase("native-messaging-first")
		let firstNative = try await makePage(profile: firstProfile)
		try await NativeMessagingSmoke.run(page: firstNative, extensionID: extensionID)
		phase("native-messaging-second")
		let secondNative = try await makePage(profile: secondProfile)
		try await NativeMessagingSmoke.run(page: secondNative, extensionID: extensionID)
		diagnostic("ARX_EXTENSION_SMOKE_NATIVE_MESSAGING_SCOPE")
		diagnostic("ARX_EXTENSION_SMOKE_NATIVE_MESSAGING_LIFECYCLE")

		// DEV-956: a private window the first profile opened. Allowing the fixture there
		// reloads it, so this runs after every phase that messages an earlier page.
		phase("private-allow")
		let allowed = try await runtime.manageExtension(
			.allowInPrivate,
			extensionID: extensionID,
			in: try await runtime.extensions(profileID: firstProfile)
		)
		guard allowed.extensions.first(where: { $0.id == extensionID })?.allowedInPrivate == true
		else { throw Failure.privateProfile }

		phase("private-window")
		let privateWindowID = UUID()
		try runtime.preparePrivateProfile(privateWindowID, followingDownloadsOf: firstProfile)
		let privateWindow = try await makePage(profile: privateWindowID)
		try privateWindow.navigate(to: url)
		try await wait(privateWindow, titlePrefix: "ARX_EXTENSION_READY:worker=true:dnr=true:count=")
		try await ExtensionPrivateSmoke.runAllowed(
			runtime: runtime,
			page: privateWindow,
			url: url,
			extensionID: extensionID
		)
		diagnostic("ARX_EXTENSION_SMOKE_PRIVATE_ACTION")
		diagnostic("ARX_EXTENSION_SMOKE_PRIVATE_MENU")

		phase("private-disallow")
		_ = try await runtime.manageExtension(
			.disallowInPrivate,
			extensionID: extensionID,
			in: try await runtime.extensions(profileID: firstProfile)
		)
		try await ExtensionPrivateSmoke.runDisallowed(runtime: runtime, page: privateWindow, extensionID: extensionID)
		dismiss(privateWindow)
		runtime.releasePrivateProfile(privateWindowID)
		diagnostic("ARX_EXTENSION_SMOKE_PRIVATE_GATE")

		phase("permissions-inspect")
		let current = try await runtime.extensions(profileID: firstProfile)
		phase("permissions-disable")
		_ = try await runtime.manageExtension(
			.disable,
			extensionID: extensionID,
			in: current
		)
		phase("options-stale-refusal")
		do {
			_ = try await runtime.openExtensionOptions(extensionID: extensionID, in: current)
			throw Failure.options
		} catch ChromiumExtensionFailure.staleInventory {}

		diagnostic("ARX_EXTENSION_SMOKE_OPTIONS_STALE")
		phase("permissions-refresh")
		let userDisabled = try await runtime.extensions(profileID: firstProfile)
		phase("permissions-require")
		_ = try await runtime.requireExtensionFixturePermissionsForTesting(
			extensionID: extensionID,
			in: userDisabled
		)
		phase("permissions-required-refresh")
		let pending = try await runtime.extensions(profileID: firstProfile)

		guard
			let blocked = pending.extensions.first(where: { $0.id == extensionID }),
			Set(blocked.disableReasons) == [.userAction, .permissionsIncrease],
			!blocked.canEnable
		else { throw Failure.permissions }

		phase("permissions-blocked-enable")
		do {
			_ = try await runtime.attemptExtensionFixtureEnableForTesting(
				extensionID: extensionID,
				in: pending
			)
			throw Failure.permissions
		} catch ChromiumExtensionFailure.reviewRequired {}

		phase("permissions-preserved-inspect")
		let preserved = try await runtime.extensions(profileID: firstProfile)

		let preservedReasons = preserved.extensions.first(where: { $0.id == extensionID })?.disableReasons
		guard preservedReasons == blocked.disableReasons
		else { throw Failure.permissions }

		diagnostic("ARX_EXTENSION_SMOKE_PERMISSION_GUARD")

		phase("remove-apply")
		let removed = try await runtime.manageExtension(
			.remove,
			extensionID: extensionID,
			in: preserved
		)

		guard !removed.extensions.contains(where: { $0.id == extensionID })
		else { throw Failure.remove }

		try first.reload()
		try await waitForPlainPage(first)
		phase("remove-survivor-inspect")
		let survivor = try await runtime.extensions(profileID: secondProfile)

		guard survivor.extensions.first(where: { $0.id == extensionID })?.state == .enabled
		else { throw Failure.isolation }

		try second.reload()
		try await wait(second, title: "ARX_EXTENSION_READY:worker=true:dnr=true:count=2")
		diagnostic("ARX_EXTENSION_SMOKE_REMOVE_ISOLATION")

		// ⇧⌘H's element picker on an ordinary page whose profile has had uBlock running a while.
		try await ExtensionSmokeElementPicker.run(runtime: runtime, page: second, phase: phase)
		diagnostic("ARX_EXTENSION_SMOKE_ELEMENT_PICKER")
		try await ExtensionSmokeSiteFilters.run(
			runtime: runtime,
			page: second,
			url: url,
			phase: phase,
			diagnostic: diagnostic
		)

		// Arx's own picker (DEV-1201), saving through the same My filters.
		try await ExtensionSmokeOwnElementPicker.run(runtime: runtime, page: second, url: url, phase: phase)
		diagnostic("ARX_EXTENSION_SMOKE_OWN_ELEMENT_PICKER")

		// Hide Element's mode (DEV-1298): picks stay open, Undo, a list entry named, Done.
		try await ExtensionSmokeOwnElementPicker.runMode(runtime: runtime, page: second, url: url, phase: phase)
		diagnostic("ARX_EXTENSION_SMOKE_HIDE_ELEMENT_MODE")

		phase("private-denial")
		let privateID = UUID()
		try runtime.preparePrivateProfile(privateID)
		defer { runtime.releasePrivateProfile(privateID) }

		do {
			_ = try await runtime.extensions(profileID: privateID)
			throw Failure.privateProfile
		} catch ChromiumExtensionFailure.unavailable {}

		diagnostic("ARX_EXTENSION_SMOKE_PRIVATE_DENIED")
	}

	private func fixtureID(_ inventory: ChromiumExtensionInventory) throws -> String {
		let matches = inventory.extensions.filter(\.isFixture)

		guard
			matches.count == 1,
			let extension_ = matches.first
		else {
			// The inventory belongs only to this native-owned disposable profile.
			// Report classifications, never names, IDs, paths or host permissions.
			let states = inventory.extensions.map { $0.state.rawValue }
			throw Failure.install(
				"fixtureMatches=\(matches.count) total=\(inventory.extensions.count) states=\(states)"
			)
		}

		guard
			extension_.manifestVersion == 3,
			extension_.state == .enabled
		else {
			let reasons = extension_.disableReasons.map(\.rawValue)
			throw Failure.install(
				"manifest=\(extension_.manifestVersion) state=\(extension_.state.rawValue) reasons=\(reasons)"
			)
		}

		return extension_.id
	}

	private func makePage(profile: UUID) async throws -> ChromiumPage {
		let page = try await runtime.makePage(profile: profile)
		pages.append(page)

		show(page)
		return page
	}

	private func verifyOptions(
		profile: UUID,
		extensionID: String,
		count: Int
	) async throws {
		let inventory = try await runtime.extensions(profileID: profile)
		var offered: ChromiumPage?
		runtime.onExtensionView = { [weak self] page, offeredProfile, offeredExtension in
			guard
				let self,
				offered == nil,
				offeredProfile == profile,
				offeredExtension == extensionID,
				!page.isPrivate
			else { return false }

			offered = page
			self.pages.append(page)
			self.show(page)
			return true
		}
		defer { runtime.onExtensionView = nil }

		_ = try await runtime.openExtensionOptions(extensionID: extensionID, in: inventory)

		guard let page = offered
		else { throw Failure.options }

		try await wait(page, title: "ARX_EXTENSION_OPTIONS:\(extensionID):count=\(count)")

		guard
			page.navigation.url?.scheme == "chrome-extension",
			page.navigation.url?.host == extensionID,
			page.navigation.url?.path == "/options.html"
		else { throw Failure.options }

		dismiss(page)
	}

	private func dismiss(_ page: ChromiumPage) {
		if let window = windows.first(where: { $0.contentView === page.view }) {
			window.orderOut(nil)
			window.contentView = nil
		}

		page.close()
	}

	private func show(_ page: ChromiumPage) {
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 720, height: 480),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.delegate = self
		window.contentView = page.view
		window.title = "Arx disposable extension fixture"
		window.center()
		window.makeKeyAndOrderFront(nil)
		windows.append(window)
	}

	private func wait(
		_ page: ChromiumPage,
		title: String
	) async throws {
		for _ in 0..<300 {
			try Task.checkCancellation()

			let isReady = page.navigation.title == title
			&& !page.navigation.isLoading
			&& page.view.window != nil

			if isReady { return }
			try await Task.sleep(for: .milliseconds(50))
		}

		throw Failure.navigation(page.navigation.title)
	}

	private func wait(
		_ page: ChromiumPage,
		titlePrefix: String
	) async throws {
		for _ in 0..<300 {
			try Task.checkCancellation()

			let isReady = page.navigation.title.hasPrefix(titlePrefix)
			&& !page.navigation.isLoading
			&& page.view.window != nil

			if isReady { return }
			try await Task.sleep(for: .milliseconds(50))
		}

		throw Failure.navigation(page.navigation.title)
	}

	private func waitForPlainPage(_ page: ChromiumPage) async throws {
		try await wait(page, title: "Arx engine smoke")
		try await Task.sleep(for: .milliseconds(500))

		guard page.navigation.title == "Arx engine smoke"
		else { throw Failure.unexpectedInjection }
	}

	private func finish() {
		for page in pages { page.close() }
		pages.removeAll()

		for window in windows { window.orderOut(nil) }
		runtime.requestQuit()
	}

	private func phase(_ name: String) {
		diagnostic("ARX_EXTENSION_SMOKE_PHASE \(name)")
	}

	private func diagnostic(_ message: String) {
		FileHandle.standardError.write(Data("\(message)\n".utf8))
	}

	private enum Failure: Error {
		case isolation
		case remove
		case permissions
		case privateProfile
		case unexpectedInjection
		case options
		case install(String)
		case navigation(String)
	}
}
