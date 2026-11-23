#if DEBUG
import AppKit
import BrowserCore
import BrowserEngineClient
import ChromiumBrowserEngine
import Foundation
import UserNotifications
import _ComposableArchitecture

/// The web-notifications ticket (DEV-885). Runs only with `ARX_NOTIFICATION_SMOKE` and a
/// disposable `ARX_ENGINE_PROFILE`, in a windowed (never headless) run: unattended runs drop
/// sites' notifications before they post.
///
/// 1. Arx Dev must be allowed to post notifications. macOS asks a person the first time, and
///    nothing here can answer for them; otherwise the smoke prints
///    `ARX_NOTIFICATION_SMOKE_NOT_RUN` and quits without failing.
/// 2. The loopback page (`ARX_ENGINE_URL`) is given the notification permission through the
///    site-settings path Settings uses (`changeSiteSettings`), never a prompt, and fires
///    `new Notification(…)` (no `requireInteraction`, so Chromium posts it as a banner from the
///    app's own process rather than its Alerts helper).
/// 3. Notification Center has it: `deliveredNotifications()` lists one with the expected title,
///    and its title, subtitle (the site), body and attachments (the icon) are printed as JSON
///    for the runner to check.
/// 4. Clicks. A real click on a banner can't be automated (it needs Accessibility control of
///    Notification Center), so the smoke sends what the engine reports for one, from another
///    space: the page's `window.focus()` in its `onclick` (`pageActivationRequested`), a click
///    the site didn't answer (`notificationClicked`), and one whose page is gone after the tab
///    closed. Each must show the site's tab in the main window, in its own space, and bring Arx
///    forward; the last opens the site again.
/// 5. A private window's page asks for the permission and must be denied.
internal enum NotificationSmoke {
	internal enum Failure: String, Error {
		case missingConfiguration
		case missingPage
		case siteSettingsUnavailable
		case permissionNotSaved
		case permissionNotGranted
		case notificationNotShown
		case notDelivered
		case spaceNotCreated
		case activationNotShown
		case clickNotShown

		/// Arx didn't come forward with its window key after a click.
		case notBroughtForward

		/// Arx couldn't be put in the background before a click.
		case notInBackground
		case tabNotClosed
		case closedTabNotReopened
		case privateWindow
		case privateNotDenied
	}

	/// What Notification Center lists for the smoke's notification, printed as
	/// `ARX_NOTIFICATION_SMOKE_DELIVERED <json>`.
	internal struct Delivery: Codable, Equatable, Sendable {
		internal var title: String
		internal var subtitle: String
		internal var body: String

		/// Chromium attaches the notification's icon as an image file.
		internal var attachments: Int

		/// The `userInfo` values naming the notification's origin, as Chromium stores it.
		internal var origins: [String]

		internal init(
			title: String,
			subtitle: String,
			body: String,
			attachments: Int,
			origins: [String]
		) {
			self.title = title
			self.subtitle = subtitle
			self.body = body
			self.attachments = attachments
			self.origins = origins
		}

		internal var resultLine: String {
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
			let json = (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
			return "ARX_NOTIFICATION_SMOKE_DELIVERED \(json)"
		}
	}

	/// The fixture page's titles (`scripts/notification_smoke.py` writes the page).
	internal enum PageTitle {
		internal static let permissionPrefix = "Arx notification fixture "
		internal static let shown = "Arx notification shown"
		internal static let failed = "Arx notification error"
		internal static let home = "Arx notification fixture home"

		/// Followed by `asking`, then by what `Notification.requestPermission()` answered.
		internal static let privatePrefix = "Arx notification private "
	}

	internal static func isRequested(environment: [String: String]) -> Bool {
		environment["ARX_NOTIFICATION_SMOKE"] == "1" && environment["ARX_ENGINE_PROFILE"] != nil
	}

	/// The name the runner reads for an authorization status.
	internal static func authorizationName(_ status: UNAuthorizationStatus) -> String {
		switch status {
		case .notDetermined: "notDetermined"
		case .denied: "denied"
		case .authorized: "authorized"
		case .provisional: "provisional"
		case .ephemeral: "ephemeral"
		@unknown default: "unknown(\(status.rawValue))"
		}
	}

	/// `scheme://host[:port]` equality, with the scheme's default port.
	internal static func isSameOrigin(
		_ url: URL?,
		_ origin: URL
	) -> Bool {
		guard
			let url,
			let scheme = url.scheme?.lowercased(),
			scheme == origin.scheme?.lowercased(),
			url.host()?.lowercased() == origin.host()?.lowercased()
		else { return false }

		let defaultPort = scheme == "https" ? 443 : 80
		return (url.port ?? defaultPort) == (origin.port ?? defaultPort)
	}

	// MARK: - Run

	/// False when it didn't run because Arx Dev may not post notifications.
	@MainActor
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		window: @escaping @MainActor () -> NSWindow?,
		environment: [String: String]
	) async throws -> Bool {
		guard
			let pageURL = environment["ARX_ENGINE_URL"].flatMap(URL.init(string:)),
			let origin = environment["ARX_NOTIFICATION_SMOKE_ORIGIN"].flatMap(URL.init(string:)),
			let privateURL = environment["ARX_NOTIFICATION_SMOKE_PRIVATE_URL"].flatMap(URL.init(string:)),
			let title = environment["ARX_NOTIFICATION_SMOKE_TITLE"],
			var fireComponents = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
		else { throw Failure.missingConfiguration }

		fireComponents.queryItems = (fireComponents.queryItems ?? []) + [.init(name: "fire", value: "1")]
		guard let fireURL = fireComponents.url else { throw Failure.missingConfiguration }

		let client = engine.client
		try await wait(or: .missingPage) { shows(store, titlePrefix: PageTitle.permissionPrefix) }
		guard let tab = store.main.viewer.item.tab else { throw Failure.missingPage }

		// macOS asks a person once whether Arx Dev may post notifications. A status other than
		// authorized means this Mac can't show the notification, which is not Arx failing.
		let status = await authorizationStatus()
		guard status == .authorized else {
			print(
				"ARX_NOTIFICATION_SMOKE_NOT_RUN authorization=\(authorizationName(status)) "
				+ "Arx Dev is not allowed to post notifications; allow it once in System Settings › Notifications"
			)
			return false
		}
		print("ARX_NOTIFICATION_SMOKE_PHASE_AUTHORIZED")

		// Settings' own path for a site's permission, rather than the page's prompt.
		guard client.siteSettingsAreAvailable() else { throw Failure.siteSettingsUnavailable }
		guard let originText = SiteSettings.origin(origin.absoluteString) else { throw Failure.missingConfiguration }

		let edit = SiteSettingsEdit.setPermission(origin: originText, .notifications, .allow)
		let settings: SiteSettings
		do {
			settings = try await client.changeSiteSettings(tab.profileID, edit)
		} catch {
			throw Failure.permissionNotSaved
		}
		guard settings.holds(edit) else { throw Failure.permissionNotSaved }

		try await client.command(tab.id, .navigate(fireURL))
		try await wait(or: .permissionNotGranted) {
			shows(store, titlePrefix: PageTitle.permissionPrefix + "granted")
			|| shows(store, titlePrefix: PageTitle.shown)
			|| shows(store, titlePrefix: PageTitle.failed)
		}
		print("ARX_NOTIFICATION_SMOKE_PHASE_PERMISSION")

		try await wait(or: .notificationNotShown) { shows(store, titlePrefix: PageTitle.shown) }
		print("ARX_NOTIFICATION_SMOKE_PHASE_SHOWN")

		let delivery = try await delivered(title: title, origin: originText)
		print(delivery.resultLine)

		try await clickFromAnotherSpace(store: store, tab: tab, origin: origin, window: window)
		try await reopenClosedTab(store: store, tab: tab, origin: origin, window: window)
		try await denyInPrivateWindow(store: store, url: privateURL)

		removeDelivered(title: title)
		print("ARX_NOTIFICATION_SMOKE_SUCCESS")
		return true
	}

	// MARK: - Notification Center

	private static func authorizationStatus() async -> UNAuthorizationStatus {
		await withCheckedContinuation { continuation in
			UNUserNotificationCenter.current().getNotificationSettings { settings in
				continuation.resume(returning: settings.authorizationStatus)
			}
		}
	}

	private static func deliveredNotifications(origin: String) async -> [Delivery] {
		await withCheckedContinuation { continuation in
			UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
				let deliveries = notifications.map { notification in
					let content = notification.request.content
					return Delivery(
						title: content.title,
						subtitle: content.subtitle,
						body: content.body,
						attachments: content.attachments.count,
						origins: content.userInfo.values
							.compactMap { $0 as? String }
							.filter { $0.hasPrefix(origin) }
					)
				}
				continuation.resume(returning: deliveries)
			}
		}
	}

	/// The smoke's notification, once Notification Center lists it.
	@MainActor
	private static func delivered(
		title: String,
		origin: String
	) async throws -> Delivery {
		let end = ContinuousClock.now.advanced(by: .seconds(20))
		while ContinuousClock.now < end {
			let deliveries = await deliveredNotifications(origin: origin)
			if let delivery = deliveries.first(where: { $0.title == title }) { return delivery }
			try await Task.sleep(for: .milliseconds(250))
		}
		print("ARX_NOTIFICATION_SMOKE_DELIVERED_TITLES \(await deliveredNotifications(origin: origin).map(\.title))")
		await probeDelivery()
		throw Failure.notDelivered
	}

	/// Whether Notification Center lists a notification Arx Dev posts itself: if not, this Mac
	/// doesn't keep Arx Dev's notifications (its Notifications setting or a Focus), and the page's
	/// missing one says nothing about Chromium. Printed as `ARX_NOTIFICATION_SMOKE_PROBE`.
	@MainActor
	private static func probeDelivery() async {
		let center = UNUserNotificationCenter.current()
		let settings = await center.notificationSettings()
		let content = UNMutableNotificationContent()
		content.title = "Arx notification smoke probe"
		let request = UNNotificationRequest(identifier: "arx-notification-smoke-probe-\(UUID())", content: content, trigger: nil)
		var posted = "yes"
		do { try await center.add(request) } catch { posted = "no (\(error.localizedDescription))" }
		var listed = false
		let end = ContinuousClock.now.advanced(by: .seconds(5))
		while !listed, ContinuousClock.now < end {
			listed = await center.deliveredNotifications().contains { $0.request.identifier == request.identifier }
			if !listed { try? await Task.sleep(for: .milliseconds(250)) }
		}
		center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
		print(
			"ARX_NOTIFICATION_SMOKE_PROBE posted=\(posted) listed=\(listed)"
			+ " alerts=\(settings.alertSetting.rawValue) center=\(settings.notificationCenterSetting.rawValue)"
			+ " style=\(settings.alertStyle.rawValue)"
		)
	}

	/// Leaves no fixture banner in Notification Center.
	private static func removeDelivered(title: String) {
		UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
			let identifiers = notifications
				.filter { $0.request.content.title == title }
				.map(\.request.identifier)
			UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
		}
	}

	// MARK: - Clicks

	/// What a click does from another space of the same profile: the page's `window.focus()` in
	/// its `onclick`, then a click the site didn't answer. Both show the tab in its own space.
	@MainActor
	private static func clickFromAnotherSpace(
		store: StoreOf<AppFeature>,
		tab: BrowserCore.Tab,
		origin: URL,
		window: @MainActor () -> NSWindow?
	) async throws {
		let home = store.main.sidebar.spaceID
		let other = Space.ID(rawValue: UUID())
		store.send(.settings(.delegate(.changeOrganization(.createSpace(
			other,
			profileID: tab.profileID,
			name: "Notification smoke",
			icon: .stack
		)))))
		try await wait(or: .spaceNotCreated) { store.main.sidebar.organization.spaces.ids.contains(other) }

		try await leave(to: other, store: store)
		try await moveToBackground()
		var focusRequests = store.mediaSourceFocusRequest
		store.send(.event(.pageActivationRequested(tab.id)))
		try await wait(or: .activationNotShown) {
			shows(store, tab: tab.id, in: home) && store.mediaSourceFocusRequest > focusRequests
		}
		try await expectForward(window)
		print("ARX_NOTIFICATION_SMOKE_PHASE_ACTIVATION")

		try await leave(to: other, store: store)
		try await moveToBackground()
		focusRequests = store.mediaSourceFocusRequest
		store.send(.event(.notificationClicked(.init(
			profileID: tab.profileID,
			origin: origin,
			isPersistent: false,
			isHandled: false,
			pageIsGone: false
		))))
		try await wait(or: .clickNotShown) {
			shows(store, tab: tab.id, in: home) && store.mediaSourceFocusRequest > focusRequests
		}
		try await expectForward(window)
		print("ARX_NOTIFICATION_SMOKE_PHASE_CLICK")
	}

	/// The tab closes; a click on its notification, whose page is gone, opens the site again in
	/// the notification's profile.
	@MainActor
	private static func reopenClosedTab(
		store: StoreOf<AppFeature>,
		tab: BrowserCore.Tab,
		origin: URL,
		window: @MainActor () -> NSWindow?
	) async throws {
		guard store.main.viewer.item.tab?.id == tab.id else { throw Failure.clickNotShown }

		store.send(.main(.ui(.closeTab)))
		try await wait(or: .tabNotClosed) { !store.workspace.tabs.ids.contains(tab.id) }

		try await moveToBackground()
		let focusRequests = store.mediaSourceFocusRequest
		store.send(.event(.notificationClicked(.init(
			profileID: tab.profileID,
			origin: origin,
			isPersistent: false,
			isHandled: false,
			pageIsGone: true
		))))
		try await wait(or: .closedTabNotReopened) {
			guard let reopened = store.main.viewer.item.tab else { return false }

			return reopened.id != tab.id
			&& reopened.profileID == tab.profileID
			&& store.main.sidebar.selectedTab?.id == reopened.id
			&& isSameOrigin(store.main.viewer.item.navigation.url, origin)
			&& shows(store, titlePrefix: PageTitle.home)
			&& store.mediaSourceFocusRequest > focusRequests
		}
		try await expectForward(window)
		print("ARX_NOTIFICATION_SMOKE_PHASE_REOPENED")
	}

	/// Hides Arx, as when a person works in another app and a notification arrives, so a click
	/// has to bring it forward itself.
	@MainActor
	private static func moveToBackground() async throws {
		NSApp.hide(nil)
		try await wait(or: .notInBackground) { NSApp.isHidden && !NSApp.isActive }
	}

	/// The request to come forward was carried out: Arx is active and shown, and its main window
	/// is on screen, not minimized, and key.
	@MainActor
	private static func expectForward(_ window: @MainActor () -> NSWindow?) async throws {
		try await wait(or: .notBroughtForward) {
			guard let window = window() else { return false }
			return NSApp.isActive && !NSApp.isHidden && window.isVisible && !window.isMiniaturized && window.isKeyWindow
		}
	}

	/// Shows the other space in the main window, as a person working elsewhere would.
	@MainActor
	private static func leave(
		to space: Space.ID,
		store: StoreOf<AppFeature>
	) async throws {
		store.send(.main(.sidebar(.ui(.spaceSelected(space)))))
		try await wait(or: .spaceNotCreated) {
			store.main.sidebar.spaceID == space && store.main.viewer.spaceID == space
		}
	}

	// MARK: - Private window

	/// Chromium denies a private profile the notification permission, as Chrome does in Incognito.
	@MainActor
	private static func denyInPrivateWindow(
		store: StoreOf<AppFeature>,
		url: URL
	) async throws {
		let preparation = store.send(.ui(.newPrivateWindow))
		defer { preparation.cancel() }
		try await wait(or: .privateWindow) { store.windows.contains(where: \.isPrivate) }
		guard let window = store.windows.first(where: \.isPrivate)?.id else { throw Failure.privateWindow }

		try await wait(or: .privateWindow) { store.windows[id: window]?.commandBar.isPresented == true }
		store.send(.windows(.element(id: window, action: .commandBar(.ui(.queryChanged(url.absoluteString))))))
		store.send(.windows(.element(id: window, action: .commandBar(.ui(.selected("destination"))))))

		// Chromium answers a private profile's request after a short random delay.
		try await wait(or: .privateNotDenied, seconds: 30) {
			guard let navigation = store.windows[id: window]?.viewer.item.navigation else { return false }

			return !navigation.isLoading && navigation.title.hasPrefix(PageTitle.privatePrefix)
			&& navigation.title != PageTitle.privatePrefix + "asking"
		}
		let answer = store.windows[id: window]?.viewer.item.navigation.title ?? ""
		print("ARX_NOTIFICATION_SMOKE_PRIVATE \(answer.dropFirst(PageTitle.privatePrefix.count))")
		guard answer == PageTitle.privatePrefix + "denied" else { throw Failure.privateNotDenied }
		print("ARX_NOTIFICATION_SMOKE_PHASE_PRIVATE")

		store.send(.ui(.requestClosePrivateWindow(window)))
		try await wait(or: .privateWindow) { store.windows[id: window] == nil }
	}

	// MARK: - Waiting

	@MainActor
	private static func shows(
		_ store: StoreOf<AppFeature>,
		titlePrefix: String
	) -> Bool {
		let navigation = store.main.viewer.item.navigation
		return !navigation.isLoading && navigation.errorCode == nil && navigation.title.hasPrefix(titlePrefix)
	}

	@MainActor
	private static func shows(
		_ store: StoreOf<AppFeature>,
		tab: BrowserCore.Tab.ID,
		in space: Space.ID
	) -> Bool {
		store.main.sidebar.spaceID == space
		&& store.main.sidebar.selectedTab?.id == tab
		&& store.main.viewer.item.tab?.id == tab
	}

	@MainActor
	private static func wait(
		or failure: Failure,
		seconds: Int = 20,
		_ condition: @MainActor () -> Bool
	) async throws {
		let end = ContinuousClock.now.advanced(by: .seconds(seconds))
		while !condition() {
			guard ContinuousClock.now < end else { throw failure }
			try await Task.sleep(for: .milliseconds(100))
		}
	}
}

extension BrowserWindow {
	/// `make notification-smoke` (DEV-885); see `NotificationSmoke`.
	internal func startNotificationSmoke() {
		guard headless == nil, NotificationSmoke.isRequested(environment: environment) else { return }

		Task { @MainActor [self] in
			do {
				_ = try await NotificationSmoke.run(
					store: store,
					engine: engine,
					window: { [weak self] in self?.window },
					environment: environment
				)
			} catch {
				failed = true
				let failure = (error as? NotificationSmoke.Failure)?.rawValue ?? "\(error)"
				FileHandle.standardError.write(Data("ARX_NOTIFICATION_SMOKE_FAILED: \(failure)\n".utf8))
			}
			store.send(.ui(.quit))
		}
	}
}
#endif
