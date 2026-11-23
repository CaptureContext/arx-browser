import AppKit
import ChromiumEngine

/// ABI38 site permissions and page zoom (DEV-716) against real Chromium storage:
/// site exceptions and defaults, refused values, a live zoom change on an open
/// page, change notifications, profile isolation and a private profile. ABI56 (DEV-963):
/// site permission prompts handed to the app, and the engine's own sheet while they aren't.
@MainActor
internal final class SiteSettingsSmoke {
	internal static let argument: String = "--site-settings-fixture"

	private enum Failure: Error, CustomStringConvertible {
		case unavailable
		case timedOut
		case unexpected(String)

		internal var description: String {
			switch self {
			case .unavailable: "unavailable"
			case .timedOut: "timed-out"
			case let .unexpected(detail): "unexpected \(detail)"
			}
		}
	}

	private let runtime: ChromiumRuntime
	private let url: URL
	private var pages: [ChromiumPage] = []
	private var windows: [NSWindow] = []
	private var privateProfiles: [UUID] = []
	private var changes: [UUID?] = []
	private var promptTokens: [UInt64] = []
	private var phase: String = "startup"
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
				diagnostic("ARX_SITE_SETTINGS_SMOKE_VERIFIED")
			} catch {
				diagnostic("ARX_SITE_SETTINGS_SMOKE_FAILED phase=\(phase) reason=\(error)")
			}

			for page in pages {
				page.close()
			}
			for profile in privateProfiles {
				runtime.releasePrivateProfile(profile)
			}
			for window in windows {
				window.orderOut(nil)
				window.close()
			}
			runtime.requestQuit()
		}
	}

	private func verify() async throws {
		guard runtime.supportsSiteSettings
		else { throw Failure.unavailable }

		let watcher = Task { [runtime] in
			for await profile in runtime.siteSettingsChanges() {
				self.changes.append(profile)
			}
		}
		defer { watcher.cancel() }

		phase = "list"
		try await runtime.prepareProfile(nil)
		let initial = try await runtime.siteSettingsList(profile: nil)
		let names = Set(ChromiumSitePermission.allCases.map(\.rawValue))
		guard
			Set(initial.permissions.defaults.keys) == names,
			initial.permissions.sites.isEmpty,
			initial.zoom.default == 1,
			initial.zoom.sites.isEmpty
		else { throw Failure.unexpected("initial \(initial)") }
		diagnostic("ARX_SITE_SETTINGS_SMOKE_LIST")

		phase = "permission"
		let origin = "https://camera.example"
		var listing = try await runtime.setSitePermission(
			profile: nil,
			origin: origin + "/path?q=1",
			permission: .camera,
			setting: .allow
		)
		try require(listing, origin, "camera", "allow")
		listing = try await runtime.setSitePermission(
			profile: nil,
			origin: origin,
			permission: .camera,
			setting: .block
		)
		try require(listing, origin, "camera", "block")
		listing = try await runtime.setSitePermission(
			profile: nil,
			origin: "http://popups.example:8080",
			permission: .popups,
			setting: .allow
		)
		try require(listing, "http://popups.example:8080", "popups", "allow")
		for permission in [ChromiumSitePermission.microphone, .location, .notifications, .clipboard] {
			listing = try await runtime.setSitePermission(
				profile: nil,
				origin: origin,
				permission: permission,
				setting: .allow
			)
			try require(listing, origin, permission.rawValue, "allow")
		}
		listing = try await runtime.setSitePermission(
			profile: nil,
			origin: origin,
			permission: .camera,
			setting: nil
		)
		guard !listing.permissions.sites.contains(where: { $0.origin == origin && $0.permission == "camera" })
		else { throw Failure.unexpected("removed camera still listed") }

		// DEV-884: content blocking off for one site, then back on.
		guard initial.permissions.defaults["ads"] == "block"
		else { throw Failure.unexpected("ads default \(initial.permissions.defaults)") }
		listing = try await runtime.setSitePermission(
			profile: nil,
			origin: origin,
			permission: .ads,
			setting: .allow
		)
		try require(listing, origin, "ads", "allow")
		listing = try await runtime.setSitePermission(
			profile: nil,
			origin: origin,
			permission: .ads,
			setting: nil
		)
		guard !listing.permissions.sites.contains(where: { $0.origin == origin && $0.permission == "ads" })
		else { throw Failure.unexpected("removed ads still listed") }
		diagnostic("ARX_SITE_SETTINGS_SMOKE_PERMISSION")

		phase = "invalid"
		try await refuses("popups-ask") {
			_ = try await self.runtime.setSitePermission(
				profile: nil,
				origin: origin,
				permission: .popups,
				setting: .ask
			)
		}
		try await refuses("javascript-origin") {
			_ = try await self.runtime.setSitePermission(
				profile: nil,
				origin: "javascript:alert(1)",
				permission: .camera,
				setting: .allow
			)
		}
		try await refuses("credentials-origin") {
			_ = try await self.runtime.setSitePermission(
				profile: nil,
				origin: "https://user:pass@x.example",
				permission: .camera,
				setting: .allow
			)
		}
		try await refuses("default-allow-camera") {
			_ = try await self.runtime.setSitePermission(
				profile: nil,
				origin: nil,
				permission: .camera,
				setting: .allow
			)
		}
		try await refuses("zoom-range") {
			_ = try await self.runtime.setSiteZoom(profile: nil, host: "127.0.0.1", factor: 9)
		}
		try await refuses("zoom-host") {
			_ = try await self.runtime.setSiteZoom(profile: nil, host: "a/b", factor: 1.5)
		}
		diagnostic("ARX_SITE_SETTINGS_SMOKE_INVALID")

		phase = "default"
		listing = try await runtime.setSitePermission(
			profile: nil,
			origin: nil,
			permission: .notifications,
			setting: .block
		)
		guard listing.permissions.defaults["notifications"] == "block"
		else { throw Failure.unexpected("default notifications \(listing.permissions.defaults)") }
		listing = try await runtime.setSitePermission(
			profile: nil,
			origin: nil,
			permission: .notifications,
			setting: .ask
		)
		guard listing.permissions.defaults["notifications"] == "ask"
		else { throw Failure.unexpected("default notifications restore") }
		diagnostic("ARX_SITE_SETTINGS_SMOKE_DEFAULT")

		phase = "zoom"
		let page = try await makePage()
		let before = try await pixelRatio(page)
		guard let host = url.host() else { throw Failure.unexpected("no host") }
		changes.removeAll()
		listing = try await runtime.setSiteZoom(profile: nil, host: host, factor: 1.5)
		guard listing.zoom.sites.contains(.init(host: host, factor: 1.5))
		else { throw Failure.unexpected("zoom \(listing.zoom)") }

		// The open page follows without reloading.
		try await wait { await self.pixelRatio(page, before: before, isNear: 1.5) }
		try await wait { self.changes.contains(where: { $0 == nil }) }
		diagnostic("ARX_SITE_SETTINGS_SMOKE_CHANGED")
		listing = try await runtime.setSiteZoom(profile: nil, host: host, factor: nil)
		guard listing.zoom.sites.isEmpty
		else { throw Failure.unexpected("zoom removal \(listing.zoom)") }
		try await wait { await self.pixelRatio(page, before: before, isNear: 1) }
		listing = try await runtime.setSiteZoom(profile: nil, host: nil, factor: 1.25)
		guard listing.zoom.default == 1.25
		else { throw Failure.unexpected("default zoom \(listing.zoom)") }
		try await wait { await self.pixelRatio(page, before: before, isNear: 1.25) }
		listing = try await runtime.setSiteZoom(profile: nil, host: nil, factor: 1)
		guard listing.zoom.default == 1
		else { throw Failure.unexpected("default zoom restore") }
		diagnostic("ARX_SITE_SETTINGS_SMOKE_ZOOM")

		phase = "isolation"
		let other = UUID()
		try await runtime.prepareProfile(other)
		let otherListing = try await runtime.siteSettingsList(profile: other)
		guard otherListing.permissions.sites.isEmpty, otherListing.zoom.sites.isEmpty
		else { throw Failure.unexpected("other profile \(otherListing)") }
		changes.removeAll()
		_ = try await runtime.setSitePermission(
			profile: other,
			origin: origin,
			permission: .camera,
			setting: .block
		)
		try await wait { self.changes.contains(other) }
		guard try await runtime.siteSettingsList(profile: nil).permissions.sites.allSatisfy({ $0.permission != "camera" })
		else { throw Failure.unexpected("other profile's camera reached the default profile") }
		diagnostic("ARX_SITE_SETTINGS_SMOKE_ISOLATION")

		phase = "private"
		let privateProfile = UUID()
		try runtime.preparePrivateProfile(privateProfile)
		privateProfiles.append(privateProfile)
		try await refuses("private-list", expected: .unavailable) {
			_ = try await self.runtime.siteSettingsList(profile: privateProfile)
		}
		try await refuses("private-set", expected: .unavailable) {
			_ = try await self.runtime.setSiteZoom(profile: privateProfile, host: "a.example", factor: 1.5)
		}
		try await refuses("unknown", expected: .unavailable) {
			_ = try await self.runtime.siteSettingsList(profile: UUID())
		}
		diagnostic("ARX_SITE_SETTINGS_SMOKE_PRIVATE")

		phase = "hosted-prompts"
		try await verifyHostedPrompts()
		diagnostic("ARX_SITE_SETTINGS_SMOKE_HOSTED_PROMPTS")
	}

	/// DEV-963. Off, a notification request shows the engine's sheet and the app hears
	/// nothing. On, the app gets it instead: an answer inside the input delay only dismisses,
	/// a navigation withdraws it, answers it can't take are refused, Block blocks the site,
	/// and a page closing under it decides nothing.
	private func verifyHostedPrompts() async throws {
		guard runtime.supportsHostedPagePrompts
		else { throw Failure.unavailable }

		runtime.onPagePermissionPrompt = { [weak self] _, token in
			self?.promptTokens.append(token)
		}
		defer {
			runtime.setPagePromptsHosted(false)
			runtime.onPagePermissionPrompt = nil
		}
		NSApplication.shared.activate(ignoringOtherApps: true)
		let page = try await makePage()
		windows.last?.makeKeyAndOrderFront(nil)

		// Permission prompts belong to a page hosting content, as in the app.
		try runtime.configureContentHosting(on: page, enabled: true)
		defer { try? runtime.configureContentHosting(on: page, enabled: false) }
		guard let scheme = url.scheme, let host = url.host()
		else { throw Failure.unexpected("fixture url \(url)") }

		let origin = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")

		// Off: the engine's own sheet, answered here through automation.
		phase = "hosted-prompts-off"
		try await requestNotifications(page)
		try await wait { page.dialog()?.kind == .permission }
		guard promptTokens.isEmpty, let sheet = page.dialog()
		else { throw Failure.unexpected("hosted off reported \(promptTokens)") }

		try page.answerDialog(sheet, accept: false)
		try await wait { try await self.notificationResult(page) == "default" }

		// On: too soon to count, so Allow only dismisses.
		phase = "hosted-prompts-early"
		runtime.setPagePromptsHosted(true)
		var prompt = try await hostedPrompt(page)
		guard
			prompt.permissions == ["notifications"],
			prompt.variant == .ask,
			prompt.requestingOrigin == origin,
			prompt.embeddingOrigin == nil,
			prompt.geolocation == nil,
			!prompt.allowOnce,
			page.dialog()?.kind == .permission
		else { throw Failure.unexpected("prompt \(prompt) origin=\(origin)") }

		try page.answerPermissionPrompt(prompt, decision: .allow)
		try await wait { self.promptTokens.last == 0 }
		try await wait { try await self.notificationResult(page) == "default" }
		guard page.permissionPrompt(token: prompt.token) == nil
		else { throw Failure.unexpected("answered prompt still readable") }

		// A navigation withdraws it, and its answer is stale.
		phase = "hosted-prompts-navigation"
		prompt = try await hostedPrompt(page)
		try page.navigate(to: url)
		try await wait { self.promptTokens.last == 0 }
		do {
			try page.answerPermissionPrompt(prompt, decision: .block)
			throw Failure.unexpected("withdrawn prompt answered")
		} catch let failure as ChromiumPageDialogFailure where failure == .stale {}
		try await wait { !page.navigation.isLoading }

		// Answers the prompt can't take, then Block once the input delay has passed.
		phase = "hosted-prompts-block"
		prompt = try await hostedPrompt(page)
		for (decision, accuracy) in [
			(ChromiumPagePermissionDecision.allowOnce, ChromiumPagePermissionAccuracy?.none),
			(.allow, .precise),
		] {
			do {
				try page.answerPermissionPrompt(prompt, decision: decision, accuracy: accuracy)
				throw Failure.unexpected("\(decision) \(String(describing: accuracy)) accepted")
			} catch let failure as ChromiumPageDialogFailure where failure == .invalid {}
		}
		try await wait { NSApplication.shared.isActive && self.windows.last?.isKeyWindow == true }
		try await Task.sleep(for: .milliseconds(600))
		try page.answerPermissionPrompt(prompt, decision: .block)
		try await wait { self.promptTokens.last == 0 }
		try await wait { try await self.notificationResult(page) == "denied" }
		let listing = try await runtime.siteSettingsList(profile: nil)
		try require(listing, origin, "notifications", "block")
		_ = try await runtime.setSitePermission(profile: nil, origin: origin, permission: .notifications, setting: nil)

		// A page closing under its prompt decides nothing.
		phase = "hosted-prompts-close"
		let closing = try await makePage()
		windows.last?.makeKeyAndOrderFront(nil)
		try runtime.configureContentHosting(on: closing, enabled: true)
		prompt = try await hostedPrompt(closing)
		closing.close()
		guard promptTokens.last == 0
		else { throw Failure.unexpected("closing the page didn't withdraw its prompt") }

		try await Task.sleep(for: .seconds(1))
		guard closing.permissionPrompt(token: prompt.token) == nil
		else { throw Failure.unexpected("closed page's prompt still readable") }

		let afterClose = try await runtime.siteSettingsList(profile: nil)
		guard !afterClose.permissions.sites.contains(where: { $0.origin == origin && $0.permission == "notifications" })
		else { throw Failure.unexpected("closing the page decided \(afterClose.permissions.sites)") }
	}

	private func requestNotifications(_ page: ChromiumPage) async throws {
		_ = try await runtime.evaluateScript(page, source: """
			globalThis.arxNotificationResult = "pending";
			Notification.requestPermission().then(result => { globalThis.arxNotificationResult = result; });
			return true;
			""")
	}

	private func notificationResult(_ page: ChromiumPage) async throws -> String? {
		guard case let .json(text) = try await runtime.evaluateScript(
			page,
			source: "return globalThis.arxNotificationResult ?? null;"
		)
		else { return nil }

		return try JSONDecoder().decode(String?.self, from: Data(text.utf8))
	}

	/// Requests notifications, and the hosted prompt the app is told about.
	private func hostedPrompt(_ page: ChromiumPage) async throws -> ChromiumPagePermissionPrompt {
		let count = promptTokens.count
		try await requestNotifications(page)
		try await wait { self.promptTokens.count > count && self.promptTokens.last != 0 }
		guard let token = promptTokens.last, let prompt = page.permissionPrompt(token: token)
		else { throw Failure.unexpected("hosted prompt unreadable") }

		return prompt
	}

	private func require(
		_ listing: ChromiumSiteSettings,
		_ origin: String,
		_ permission: String,
		_ setting: String
	) throws {
		guard listing.permissions.sites.contains(.init(origin: origin, permission: permission, setting: setting))
		else { throw Failure.unexpected("\(origin) \(permission) \(setting) not in \(listing.permissions.sites)") }
	}

	private func refuses(
		_ name: String,
		expected: ChromiumSiteSettingsFailure? = nil,
		_ body: () async throws -> Void
	) async throws {
		do {
			try await body()
		} catch let failure as ChromiumSiteSettingsFailure {
			switch (expected, failure) {
			case (nil, .invalid): return
			case let (expected?, failure) where failure == expected: return
			default: throw Failure.unexpected("\(name) \(failure)")
			}
		}
		throw Failure.unexpected("\(name) accepted")
	}

	/// Whether the page's pixel ratio over `before` is within 0.05 of `factor`, for polling while
	/// zoom applies. A read that fails is printed and polled again, so a timeout shows why.
	private func pixelRatio(
		_ page: ChromiumPage,
		before: Double,
		isNear factor: Double
	) async -> Bool {
		do {
			return abs(try await pixelRatio(page) / before - factor) < 0.05
		} catch {
			diagnostic("ARX_SITE_SETTINGS_SMOKE_PIXEL_RATIO_UNREAD \(error)")
			return false
		}
	}

	private func pixelRatio(_ page: ChromiumPage) async throws -> Double {
		guard
			case let .json(text) = try await runtime.evaluateScript(page, source: "return window.devicePixelRatio;"),
			let ratio = Double(text)
		else { throw Failure.unexpected("devicePixelRatio") }

		return ratio
	}

	private func makePage() async throws -> ChromiumPage {
		let page = try await runtime.makePage(profile: nil)
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 640, height: 480),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = page.view
		window.orderFront(nil)
		pages.append(page)
		windows.append(window)
		try page.navigate(to: url)
		try await wait { page.navigation.url == self.url && !page.navigation.isLoading && page.navigation.errorCode == nil }
		return page
	}

	private func wait(_ condition: @escaping @MainActor () async throws -> Bool) async throws {
		let deadline = Date().addingTimeInterval(15)
		while !(try await condition()) {
			guard Date() < deadline else { throw Failure.timedOut }
			try await Task.sleep(for: .milliseconds(50))
		}
	}
}

private func diagnostic(_ message: String) {
	FileHandle.standardError.write(Data("\(message)\n".utf8))
}
