import AppKit
import ChromiumEngine

/// DEV-765. A loopback page stands in for the Chrome Web Store through
/// Chromium's own `--apps-gallery-url` switch, and serves a recorded, unmodified
/// store package (JSON Formatter 0.10.2, signed with Google's publisher key).
/// Every install goes through the real webstorePrivate API, the publisher-proof
/// CRX3 verifier and the consent prompt, in native-owned storage.
///
/// DEV-951 installs the item by ID with no store page, as `browser_settings`
/// `installExtension` does: a declined review installs nothing, an approved one installs it.
///
/// DEV-776 adds store updates of the installed item: nothing newer, a package
/// that fails verification, an item that isn't installed in the profile, and,
/// when the runner has a second recorded store version of the same item
/// (`ARX_WEBSTORE_NEXT_VERSION`), the update itself through review.
@MainActor
internal final class WebstoreInstallSmoke {
	internal static let argument: String = "--webstore-install-fixture"
	private static let extensionID: String = "bcjindcccaagfpapjjmafapmmgkkhgoa"
	private static let packageSHA256: String = "5e0ebde71ee60f997a9f5fc0850e6ae4a9f67006dbf662f00507f99e957c2b21"

	/// A valid ID the fixture server doesn't have a package for: it answers with
	/// the JSON Formatter package, whose ID doesn't match.
	private static let otherID: String = "aaaabbbbccccddddeeeeffffgggghhhh"

	private let runtime: ChromiumRuntime
	private let origin: URL
	private var pages: [ChromiumPage] = []
	private var windows: [NSWindow] = []
	private var requests: [ChromiumWebstoreInstallRequest] = []
	internal private(set) var verified: Bool = false

	internal init(
		runtime: ChromiumRuntime,
		origin: URL
	) {
		self.runtime = runtime
		self.origin = origin
	}

	internal func open() {
		NSApplication.shared.setActivationPolicy(.regular)
		runtime.onWebstoreInstall = { [weak self] _, request in
			guard let self else { return false }
			requests.append(request)
			return true
		}
		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_WEBSTORE_INSTALL_SMOKE_VERIFIED")
			} catch {
				diagnostic("ARX_WEBSTORE_INSTALL_SMOKE_FAILED: \(error)")
			}
			for page in pages { page.close() }
			for window in windows { window.orderOut(nil) }
			runtime.requestQuit()
		}
	}

	private func verify() async throws {
		guard runtime.supportsWebstoreInstallation else { throw Failure.unavailable }
		let profile = UUID()
		let otherProfile = UUID()

		// The install phase below runs on this new profile: let it settle first.
		let original = try await settledInventory(profile)
		let otherOriginal = try await runtime.extensions(profileID: otherProfile)
		let store = try await makePage(profile: profile)

		phase("decline")
		let request = try await ask(store, id: Self.extensionID, profile: profile)
		runtime.declineWebstoreInstallation(request)
		try await wait(store, title: "ARX_WEBSTORE:begin=user_cancelled")
		guard try await runtime.extensions(profileID: profile) == original
		else { throw Failure.inventoryChanged }
		diagnostic("ARX_WEBSTORE_INSTALL_SMOKE_DECLINED")

		phase("review-cancel")
		var prompt = try await prepare(store, id: Self.extensionID, profile: profile)
		let candidate = prompt.candidate
		guard
			candidate.id == Self.extensionID,
			candidate.version == "0.10.2",
			candidate.packageSHA256 == Self.packageSHA256,
			// DEV-968: this store package's manifest names no author, so no publisher.
			candidate.publisher == nil,
			candidate.sourceBasename == ChromiumWebstoreInstallRequest.sourceName,
			!candidate.isUpdate,
			candidate.requiredPermissions.apis.contains("storage"),
			!candidate.requiredPermissions.hosts.isEmpty,
			!candidate.warnings.isEmpty
		else { throw Failure.candidate }
		do {
			_ = try await runtime.resolveExtensionInstallation(prompt, accept: false)
			throw Failure.inventoryChanged
		} catch ChromiumExtensionFailure.cancelled {}
		try await wait(store, title: "ARX_WEBSTORE:begin=user_cancelled")
		let afterCancel = try await runtime.extensions(profileID: profile)
		guard !afterCancel.extensions.contains(where: { $0.id == Self.extensionID })
		else { throw Failure.inventoryChanged }
		diagnostic("ARX_WEBSTORE_INSTALL_SMOKE_REVIEW_HASH_PERMISSIONS")

		phase("install")
		prompt = try await prepare(store, id: Self.extensionID, profile: profile)
		let installed = try await runtime.resolveExtensionInstallation(prompt, accept: true)
		guard
			let item = installed.extensions.first(where: { $0.id == Self.extensionID }),
			item.version == "0.10.2",
			item.fromWebStore,
			item.state == .enabled
		else { throw Failure.install }
		try await wait(store, title: "ARX_WEBSTORE:installed")
		diagnostic("ARX_WEBSTORE_INSTALL_SMOKE_INSTALLED")

		phase("already-installed")
		try store.navigate(to: storeURL(id: Self.extensionID, attempt: "again"))
		try await wait(store, title: "ARX_WEBSTORE:begin=already_installed")

		phase("runs")

		// Chromium never runs extensions on the store's own origin, so the JSON
		// comes from the same server under another host name.
		let data = try await makePage(profile: profile)
		try data.navigate(to: jsonURL)
		try await waitForFormatter(data, present: true)
		diagnostic("ARX_WEBSTORE_INSTALL_SMOKE_RUNS")

		phase("profile-isolation")
		let otherData = try await makePage(profile: otherProfile)
		try otherData.navigate(to: jsonURL)
		try await waitForFormatter(otherData, present: false)
		let otherAfter = try await runtime.extensions(profileID: otherProfile)
		guard otherAfter.extensions == otherOriginal.extensions else { throw Failure.isolation }
		try store.navigate(to: statusURL(id: Self.extensionID))
		try await wait(store, title: "ARX_WEBSTORE_STATUS:enabled")
		let otherStore = try await makePage(profile: otherProfile)
		try otherStore.navigate(to: statusURL(id: Self.extensionID))
		try await wait(otherStore, title: "ARX_WEBSTORE_STATUS:installable")
		diagnostic("ARX_WEBSTORE_INSTALL_SMOKE_PROFILE_ISOLATION")

		phase("guards")

		// A package whose signature no longer verifies, then a package whose ID
		// isn't the one the store asked for: neither reaches a prompt.
		try await refused(otherStore, id: Self.extensionID, variant: "corrupt", profile: otherProfile)
		try await refused(otherStore, id: Self.otherID, variant: "valid", profile: otherProfile)
		guard try await runtime.extensions(profileID: otherProfile).extensions == otherOriginal.extensions
		else { throw Failure.isolation }
		diagnostic("ARX_WEBSTORE_INSTALL_SMOKE_SIGNATURE_ID_GUARDS")

		try await verifyInstallByID()
		try await verifyUpdates(store: store, profile: profile, otherProfile: otherProfile)
	}

	/// DEV-951. An MCP client's `installExtension` prepares the store's package by ID, the
	/// path DEV-845 imports use, and the person answers the same review. In a throwaway
	/// profile of its own: a declined review installs nothing, an approved one installs it.
	private func verifyInstallByID() async throws {
		guard runtime.supportsWebstoreImports else { throw Failure.unavailable }

		phase("install-by-id")
		let profile = UUID()
		_ = try await settledInventory(profile)
		var prompt = try await prepareByID(in: profile)
		let candidate = prompt.candidate
		guard
			candidate.id == Self.extensionID,
			candidate.version == "0.10.2",
			candidate.packageSHA256 == Self.packageSHA256,
			!candidate.isUpdate,
			candidate.requiredPermissions.apis.contains("storage"),
			!candidate.warnings.isEmpty
		else { throw Failure.candidate }
		do {
			_ = try await runtime.resolveExtensionInstallation(prompt, accept: false)
			throw Failure.inventoryChanged
		} catch ChromiumExtensionFailure.cancelled {}
		let declined = try await runtime.extensions(profileID: profile)
		guard !declined.extensions.contains(where: { $0.id == Self.extensionID })
		else { throw Failure.inventoryChanged }

		prompt = try await prepareByID(in: profile)
		let installed = try await runtime.resolveExtensionInstallation(prompt, accept: true)
		guard
			let item = installed.extensions.first(where: { $0.id == Self.extensionID }),
			item.version == "0.10.2",
			item.fromWebStore,
			item.state == .enabled
		else { throw Failure.install }
		diagnostic("ARX_WEBSTORE_INSTALL_SMOKE_BY_ID")
	}

	/// ABI45 store updates of the item installed above.
	private func verifyUpdates(
		store: ChromiumPage,
		profile: UUID,
		otherProfile: UUID
	) async throws {
		guard runtime.supportsWebstoreUpdates else { throw Failure.unavailable }

		phase("update-current")

		// The store serves the installed version: nothing to ask, nothing changes.
		try await serve("valid", on: store)
		let current = try await runtime.extensions(profileID: profile)
		do {
			let prompt = try await runtime.prepareWebstoreUpdate(of: Self.extensionID, in: current)
			runtime.cancelExtensionInstallation(prompt)
			throw Failure.update
		} catch ChromiumExtensionFailure.upToDate {}
		guard try await installedVersion(profile) == "0.10.2" else { throw Failure.update }
		diagnostic("ARX_WEBSTORE_UPDATE_SMOKE_UP_TO_DATE")

		phase("update-guards")

		// A store package whose signature fails never reaches a prompt, and the
		// installed version stays enabled.
		try await serve("corrupt", on: store)
		do {
			let prompt = try await runtime.prepareWebstoreUpdate(
				of: Self.extensionID,
				in: runtime.extensions(profileID: profile)
			)
			runtime.cancelExtensionInstallation(prompt)
			throw Failure.verifierAccepted
		} catch ChromiumExtensionFailure.invalidPackage {}
		try await serve("valid", on: store)
		guard try await installedVersion(profile) == "0.10.2" else { throw Failure.update }

		// Another profile doesn't have the item: its update is refused before any download.
		do {
			_ = try await runtime.prepareWebstoreUpdate(
				of: Self.extensionID,
				in: runtime.extensions(profileID: otherProfile)
			)
			throw Failure.isolation
		} catch ChromiumExtensionFailure.invalidRequest {}
		diagnostic("ARX_WEBSTORE_UPDATE_SMOKE_GUARDS")

		guard let next = ProcessInfo.processInfo.environment["ARX_WEBSTORE_NEXT_VERSION"], !next.isEmpty else {
			diagnostic("ARX_WEBSTORE_UPDATE_SMOKE_NEWER_SKIPPED")
			return
		}

		phase("update-newer")
		try await serve("next", on: store)
		var prompt = try await runtime.prepareWebstoreUpdate(
			of: Self.extensionID,
			in: runtime.extensions(profileID: profile)
		)
		guard
			prompt.candidate.id == Self.extensionID,
			prompt.candidate.isUpdate,
			prompt.candidate.version == next,
			prompt.candidate.permissionIncrease != nil
		else { throw Failure.candidate }

		// Declining keeps the installed version.
		do {
			_ = try await runtime.resolveExtensionInstallation(prompt, accept: false)
			throw Failure.update
		} catch ChromiumExtensionFailure.cancelled {}
		guard try await installedVersion(profile) == "0.10.2" else { throw Failure.update }
		prompt = try await runtime.prepareWebstoreUpdate(
			of: Self.extensionID,
			in: runtime.extensions(profileID: profile)
		)
		let updated = try await runtime.resolveExtensionInstallation(prompt, accept: true)
		guard
			let item = updated.extensions.first(where: { $0.id == Self.extensionID }),
			item.version == next,
			item.fromWebStore
		else { throw Failure.update }
		guard try await runtime.extensions(profileID: otherProfile).extensions
			.allSatisfy({ $0.id != Self.extensionID })
		else { throw Failure.isolation }
		diagnostic("ARX_WEBSTORE_UPDATE_SMOKE_NEWER")
	}

	/// Which package the fixture store serves next: `valid`, `corrupt` or `next`.
	private func serve(
		_ variant: String,
		on page: ChromiumPage
	) async throws {
		var components = URLComponents(url: origin.appending(path: "variant"), resolvingAgainstBaseURL: false)!
		components.query = variant
		try page.navigate(to: components.url!)
		try await wait(page, title: "ARX_WEBSTORE_VARIANT:\(variant)")
	}

	/// Reads a profile's extensions until two reads half a second apart have the same revision:
	/// a profile that has only just started keeps moving it for several seconds. Gives up after
	/// ten seconds with the latest read, and says so.
	private func settledInventory(_ profile: UUID) async throws -> ChromiumExtensionInventory {
		var previous = try await runtime.extensions(profileID: profile)
		let deadline = ContinuousClock.now + .seconds(10)
		while ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(500))
			let current = try await runtime.extensions(profileID: profile)
			if current.revision == previous.revision { return current }
			previous = current
		}
		diagnostic("ARX_WEBSTORE_INSTALL_SMOKE_UNSETTLED revision=\(previous.revision)")
		return previous
	}

	/// Prepares the store item by ID the way the Extensions sheet does for an MCP install
	/// (DEV-951): each `staleInventory` reads the profile again and checks the item still isn't
	/// installed, and the third in a row fails.
	private func prepareByID(in profile: UUID) async throws -> ChromiumExtensionInstallPrompt {
		var inventory = try await runtime.extensions(profileID: profile)
		for attempt in 1...3 {
			guard !inventory.extensions.contains(where: { $0.id == Self.extensionID })
			else { throw Failure.inventoryChanged }
			do {
				return try await runtime.prepareWebstoreImport(of: Self.extensionID, in: inventory)
			} catch ChromiumExtensionFailure.staleInventory where attempt < 3 {
				phase("install-by-id-stale-retry")
				inventory = try await runtime.extensions(profileID: profile)
			}
		}
		throw Failure.stale
	}

	private func installedVersion(_ profile: UUID) async throws -> String? {
		try await runtime.extensions(profileID: profile).extensions
			.first(where: { $0.id == Self.extensionID })?.version
	}

	private func ask(
		_ page: ChromiumPage,
		id: String,
		profile: UUID,
		variant: String = "valid"
	) async throws -> ChromiumWebstoreInstallRequest {
		requests.removeAll()
		try page.navigate(to: storeURL(id: id, attempt: UUID().uuidString, variant: variant))
		for _ in 0..<300 {
			if let request = requests.first {
				requests.removeAll()
				guard request.extensionID == id, request.profileID == profile
				else { throw Failure.request }
				return request
			}
			try await Task.sleep(for: .milliseconds(50))
		}
		throw Failure.navigation(page.navigation.title)
	}

	private func refused(
		_ page: ChromiumPage,
		id: String,
		variant: String,
		profile: UUID
	) async throws {
		do {
			let prompt = try await prepare(page, id: id, profile: profile, variant: variant)
			runtime.cancelExtensionInstallation(prompt)
			throw Failure.verifierAccepted
		} catch ChromiumExtensionFailure.invalidPackage {}
		try await wait(page, title: "ARX_WEBSTORE:begin=install_error")
	}

	/// Asks the store page for an install and prepares it. Chromium may disable
	/// and re-enable its component extensions soon after a profile starts, which
	/// correctly invalidates an inventory and uses up the store's request; like
	/// a user clicking Add to Chrome again, the page asks anew.
	private func prepare(
		_ page: ChromiumPage,
		id: String,
		profile: UUID,
		variant: String = "valid"
	) async throws -> ChromiumExtensionInstallPrompt {
		for attempt in 1..<3 {
			let request = try await ask(page, id: id, profile: profile, variant: variant)
			let inventory = try await runtime.extensions(profileID: profile)
			do {
				return try await runtime.prepareWebstoreInstallation(request, in: inventory)
			} catch ChromiumExtensionFailure.staleInventory {
				diagnostic("ARX_WEBSTORE_INSTALL_SMOKE_REFRESHED attempt=\(attempt)")
			}
		}
		throw Failure.stale
	}

	private var jsonURL: URL {
		var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
		components.host = "localhost"
		components.path = "/data.json"
		return components.url!
	}

	private func storeURL(
		id: String,
		attempt: String,
		variant: String = "valid"
	) -> URL {
		var components = URLComponents(url: origin.appending(path: "store.html"), resolvingAgainstBaseURL: false)!
		components.queryItems = [.init(name: "attempt", value: attempt)]
		components.fragment = "\(id):\(variant)"
		return components.url!
	}

	private func statusURL(id: String) -> URL {
		var components = URLComponents(url: origin.appending(path: "status.html"), resolvingAgainstBaseURL: false)!
		components.queryItems = [.init(name: "attempt", value: UUID().uuidString)]
		components.fragment = id
		return components.url!
	}

	private func waitForFormatter(
		_ page: ChromiumPage,
		present: Bool
	) async throws {
		// Absence is checked after the content script would long have run.
		let attempts = present ? 100 : 20
		var last: ChromiumScriptValue = .undefined
		for _ in 0..<attempts {
			if !page.navigation.isLoading {
				do {
					last = try await runtime.evaluateScript(
						page,
						source: "return !!document.getElementById('jsonFormatterParsed');"
					)
				} catch ChromiumDeveloperFailure.unsupportedDocument {
					// The page is still on about:blank until the navigation commits.
					last = .undefined
				}
				if present, last == .json("true") { return }
			}
			try await Task.sleep(for: .milliseconds(100))
		}
		guard !present, last == .json("false") else { throw Failure.formatter(present) }
	}

	private func makePage(profile: UUID) async throws -> ChromiumPage {
		let page = try await runtime.makePage(profile: profile)
		pages.append(page)
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 720, height: 480),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = page.view
		window.makeKeyAndOrderFront(nil)
		windows.append(window)
		NSApplication.shared.activate(ignoringOtherApps: true)
		return page
	}

	private func wait(
		_ page: ChromiumPage,
		title: String
	) async throws {
		for _ in 0..<300 {
			try Task.checkCancellation()
			if page.navigation.title == title, !page.navigation.isLoading { return }
			try await Task.sleep(for: .milliseconds(50))
		}
		throw Failure.navigation(page.navigation.title)
	}

	private func phase(_ phase: String) {
		diagnostic("ARX_WEBSTORE_INSTALL_SMOKE_PHASE \(phase)")
	}

	private func diagnostic(_ message: String) {
		FileHandle.standardError.write(Data("\(message)\n".utf8))
	}

	private enum Failure: Error {
		case unavailable
		case request
		case candidate
		case inventoryChanged
		case install
		case isolation
		case verifierAccepted
		case update
		case stale
		case formatter(Bool)
		case navigation(String)
	}
}
