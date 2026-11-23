import AppKit
import ChromiumEngine

/// Native startup signs only compiled fixture sources with fresh disposable
/// keys. Every package enters the ordinary CRX3 verifier and consent boundary.
@MainActor
internal final class ExtensionInstallSmoke {
	internal static let argument: String = "--extension-install-fixture"
	private let runtime: ChromiumRuntime
	private let url: URL
	private var pages: [ChromiumPage] = []
	private var windows: [NSWindow] = []
	internal private(set) var verified: Bool = false

	internal init(
		runtime: ChromiumRuntime,
		url: URL
	) {
		self.runtime = runtime
		self.url = url
	}

	internal func open() {
		NSApplication.shared.setActivationPolicy(.regular)
		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_EXTENSION_INSTALL_SMOKE_VERIFIED")
			} catch {
				diagnostic("ARX_EXTENSION_INSTALL_SMOKE_FAILED: \(error)")
			}
			for page in pages { page.close() }
			for window in windows { window.orderOut(nil) }
			runtime.requestQuit()
		}
	}

	private func verify() async throws {
		let profile = UUID()
		let otherProfile = UUID()
		let original = try await runtime.extensions(profileID: profile)
		let otherOriginal = try await runtime.extensions(profileID: otherProfile)
		phase("verified-new-candidate")
		let declined = try await prepare(variant: 0, inventory: original)
		let extensionID = declined.candidate.id
		guard
			!declined.candidate.isUpdate,
			declined.candidate.permissionIncrease == nil,
			declined.candidate.version == "1.0",
			// DEV-968: the fixture's manifest names its author.
			declined.candidate.publisher == "CaptureContext fixtures",
			declined.candidate.requiredPermissions.apis.contains("storage"),
			!declined.candidate.requiredPermissions.apis.contains("nativeMessaging"),
			!original.extensions.contains(where: { $0.id == extensionID })
		else { throw Failure.candidate }

		// Verification and prompt publication retain the physical profile slot.
		// Inspecting another profile remains independent; no install is inferred.
		do {
			_ = try await runtime.extensions(profileID: profile)
			throw Failure.physicalSlot
		} catch ChromiumExtensionFailure.busy {}
		let otherDuringPrompt = try await runtime.extensions(profileID: otherProfile)
		guard otherDuringPrompt.extensions == otherOriginal.extensions
		else { throw Failure.isolation }
		try await decline(declined)
		let afterDecline = try await runtime.extensions(profileID: profile)
		guard afterDecline == original else { throw Failure.denialChangedInventory }
		do {
			_ = try await runtime.resolveExtensionInstallation(declined, accept: true)
			throw Failure.replay
		} catch ChromiumExtensionFailure.staleInventory {}
		diagnostic("ARX_EXTENSION_INSTALL_SMOKE_VERIFIED_DECLINED")

		phase("new-consent")
		let accepted = try await prepareRefreshing(variant: 0, inventory: afterDecline)
		guard accepted.candidate.id == extensionID else { throw Failure.candidate }
		phase("new-consent-resolve")
		let installed = try await runtime.resolveExtensionInstallation(accepted, accept: true)
		let firstInstalled = try extension_(extensionID, in: installed, version: "1.0")
		guard firstInstalled.state == .enabled else { throw Failure.install }
		let page = try await makePage(profile: profile)
		try page.navigate(to: url)
		try await wait(page, title: "ARX_EXTENSION_READY:worker=true:dnr=true:count=1")
		diagnostic("ARX_EXTENSION_INSTALL_SMOKE_CRX_WORKER_DNR")

		phase("escalation-decline")
		let beforeUpdate = try await runtime.extensions(profileID: profile)
		let upgrade = try await prepare(variant: 1, expectedID: extensionID, inventory: beforeUpdate)
		guard
			upgrade.candidate.id == extensionID,
			upgrade.candidate.version == "2.0",
			upgrade.candidate.isUpdate,
			// ABI45 (DEV-776): v2 adds tabs and nativeMessaging, both with warnings.
			upgrade.candidate.permissionIncrease == true,
			upgrade.candidate.requiredPermissions.apis.contains("nativeMessaging"),
			upgrade.candidate.requiredPermissions.apis.contains("tabs"),
			!upgrade.candidate.warnings.isEmpty
		else { throw Failure.candidate }
		try await decline(upgrade)
		let afterUpdateDecline = try await runtime.extensions(profileID: profile)
		guard afterUpdateDecline == beforeUpdate else { throw Failure.denialChangedInventory }
		try page.reload()
		try await wait(page, title: "ARX_EXTENSION_READY:worker=true:dnr=true:count=2")
		diagnostic("ARX_EXTENSION_INSTALL_SMOKE_ESCALATION_DECLINED")

		phase("invalid-signed-inputs")

		// Version 2 would be eligible for this version-1 installation, but its
		// different signing identity must fail before any consent is published.
		try await invalid(variant: 2, expectedID: extensionID, inventory: afterUpdateDecline)

		// Corrupt v1 enters a fresh profile with no version/installed-ID conflict:
		// a refusal cannot be explained by downgrade or duplicate admission.
		let freshOther = try await runtime.extensions(profileID: otherProfile)
		try await invalid(variant: 3, inventory: freshOther)
		diagnostic("ARX_EXTENSION_INSTALL_SMOKE_SIGNATURE_ID_GUARDS")

		phase("escalation-consent")
		let updatePrompt = try await prepare(
			variant: 1,
			expectedID: extensionID,
			inventory: afterUpdateDecline
		)
		let updated = try await runtime.resolveExtensionInstallation(updatePrompt, accept: true)
		let secondInstalled = try extension_(extensionID, in: updated, version: "2.0")
		guard
			secondInstalled.state == .enabled,
			secondInstalled.activePermissions.apis.contains("nativeMessaging"),
			secondInstalled.activePermissions.apis.contains("tabs")
		else { throw Failure.install }
		try page.reload()
		try await wait(page, title: "ARX_EXTENSION_READY:worker=true:dnr=true:count=3")
		diagnostic("ARX_EXTENSION_INSTALL_SMOKE_UPDATE_STORAGE_PRESERVED")

		phase("cancel-prompt")

		// A different fresh profile permits installing version 1 again, without
		// weakening version checks on an already updated installation.
		let other = try await runtime.extensions(profileID: otherProfile)
		let cancelled = try await prepare(variant: 0, inventory: other)
		runtime.cancelExtensionInstallation(cancelled)
		let afterCancel = try await waitForPhysicalDrain(profile: otherProfile)
		guard afterCancel == other else { throw Failure.denialChangedInventory }
		diagnostic("ARX_EXTENSION_INSTALL_SMOKE_CANCEL_DRAINED")

		phase("profile-isolation")
		let independent = try await prepare(variant: 0, inventory: afterCancel)
		let otherInstalled = try await runtime.resolveExtensionInstallation(independent, accept: true)
		_ = try extension_(extensionID, in: otherInstalled, version: "1.0")
		let otherPage = try await makePage(profile: otherProfile)
		try otherPage.navigate(to: url)
		try await wait(otherPage, title: "ARX_EXTENSION_READY:worker=true:dnr=true:count=1")
		let current = try await runtime.extensions(profileID: profile)
		_ = try extension_(extensionID, in: current, version: "2.0")
		let removed = try await runtime.manageExtension(.remove, extensionID: extensionID, in: current)
		guard !removed.extensions.contains(where: { $0.id == extensionID })
		else { throw Failure.install }
		let survivor = try await runtime.extensions(profileID: otherProfile)
		_ = try extension_(extensionID, in: survivor, version: "1.0")
		diagnostic("ARX_EXTENSION_INSTALL_SMOKE_PROFILE_ISOLATION")

		let privateID = UUID()
		try runtime.preparePrivateProfile(privateID)
		defer { runtime.releasePrivateProfile(privateID) }
		do {
			_ = try await runtime.extensions(profileID: privateID)
			throw Failure.privateProfile
		} catch ChromiumExtensionFailure.unavailable {}
		diagnostic("ARX_EXTENSION_INSTALL_SMOKE_PRIVATE_DENIED")
	}

	private func prepare(
		variant: UInt32,
		expectedID: String? = nil,
		inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt {
		try await runtime.prepareSignedExtensionFixtureForTesting(
			variant: variant,
			expectedExtensionID: expectedID,
			in: inventory
		)
	}

	/// Chromium may disable and re-enable its bundled component extension soon
	/// after a profile starts. That correctly invalidates the read inventory.
	/// Like the app, read again and prepare anew; a stale token is never reused.
	private func prepareRefreshing(
		variant: UInt32,
		inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt {
		var inventory = inventory
		for attempt in 1..<3 {
			do {
				return try await prepare(variant: variant, inventory: inventory)
			} catch ChromiumExtensionFailure.staleInventory {
				diagnostic("ARX_EXTENSION_INSTALL_SMOKE_REFRESHED attempt=\(attempt)")
				inventory = try await runtime.extensions(profileID: inventory.profileID)
			}
		}
		return try await prepare(variant: variant, inventory: inventory)
	}

	private func invalid(
		variant: UInt32,
		expectedID: String? = nil,
		inventory: ChromiumExtensionInventory
	) async throws {
		do {
			let unexpected = try await prepare(
				variant: variant,
				expectedID: expectedID,
				inventory: inventory
			)
			runtime.cancelExtensionInstallation(unexpected)
			throw Failure.verifierAccepted
		} catch ChromiumExtensionFailure.invalidPackage {}
		let after = try await runtime.extensions(profileID: inventory.profileID)
		guard after == inventory else { throw Failure.invalidChangedInventory }
	}

	private func decline(_ prompt: ChromiumExtensionInstallPrompt) async throws {
		do {
			_ = try await runtime.resolveExtensionInstallation(prompt, accept: false)
			throw Failure.denialChangedInventory
		} catch ChromiumExtensionFailure.cancelled {}
	}

	private func extension_(
		_ id: String,
		in inventory: ChromiumExtensionInventory,
		version: String
	) throws -> ChromiumExtension {
		guard
			let extension_ = inventory.extensions.first(where: { $0.id == id }),
			extension_.version == version,
			extension_.manifestVersion == 3
		else { throw Failure.install }
		return extension_
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

	private func waitForPhysicalDrain(profile: UUID) async throws -> ChromiumExtensionInventory {
		for _ in 0..<300 {
			do {
				return try await runtime.extensions(profileID: profile)
			} catch ChromiumExtensionFailure.busy {
				try await Task.sleep(for: .milliseconds(50))
			}
		}
		throw Failure.physicalSlot
	}

	private func phase(_ phase: String) {
		diagnostic("ARX_EXTENSION_INSTALL_SMOKE_PHASE \(phase)")
	}

	private func diagnostic(_ message: String) {
		FileHandle.standardError.write(Data("\(message)\n".utf8))
	}

	private enum Failure: Error {
		case candidate
		case physicalSlot
		case isolation
		case denialChangedInventory
		case replay
		case install
		case verifierAccepted
		case invalidChangedInventory
		case privateProfile
		case navigation(String)
	}
}
