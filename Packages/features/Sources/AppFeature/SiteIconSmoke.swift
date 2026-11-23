#if DEBUG
import AppKit
import BrowserCore
import BrowserSiteIconClient
import ChromiumBrowserEngine
import ChromiumEngine
import Darwin
import Foundation
import ImageIO

@MainActor
internal enum SiteIconSmoke {
	internal static func run(
		engine: ChromiumBrowserEngine,
		runtime: ChromiumRuntime,
		client: BrowserSiteIconClient,
		organization: BrowserOrganization,
		baseURL: URL,
		profileDirectory: URL,
		environment: [String: String]
	) async throws {
		guard let root = environment["ARX_SITE_ICONS_SMOKE_ROOT"]
		else { throw Failure.invalidFixture }
		try SiteIconSmokeFixture.validate(
			root: URL(filePath: root),
			profile: profileDirectory,
			baseURL: baseURL
		)
		try await Runner(
			engine: engine,
			runtime: runtime,
			client: client,
			organization: organization,
			baseURL: baseURL,
			fixtureRoot: URL(filePath: root),
			iconOrigin: try IconOrigin(environment: environment)
		).run()
	}

	/// The fixture's second loopback port, with hosts no other stage uses, so no cookie
	/// an earlier stage stored reaches these pages (cookies are kept per host, not per
	/// port): `declared.localhost` declares an icon on its root page; `bare.localhost`
	/// has only `/favicon.ico`; `redirect.localhost` sends its root to
	/// `sign-in.localhost`'s sign-in page, which declares its own icon; and
	/// `app.localhost` shows its app page, with its own icon, only to a profile its
	/// sign-in page set a cookie in (DEV-1108). The saved pages themselves are never
	/// served, so fetching them would fail the fixture.
	internal struct IconOrigin: Equatable {
		internal let declaredPage: URL
		internal let barePage: URL
		internal let redirectingPage: URL
		internal let appSignIn: URL
		internal let appPage: URL

		internal init(environment: [String: String]) throws {
			guard
				let raw = environment["ARX_SITE_ICONS_ORIGIN_PORT"],
				let port = Int(raw),
				(1...65535).contains(port),
				let declaredPage = URL(string: "http://declared.localhost:\(port)/saved/deep.html?token=one-time"),
				let barePage = URL(string: "http://bare.localhost:\(port)/saved/page.html"),
				let redirectingPage = URL(string: "http://redirect.localhost:\(port)/saved/app.html"),
				let appSignIn = URL(string: "http://app.localhost:\(port)/sign-in-here"),
				let appPage = URL(string: "http://app.localhost:\(port)/mail/u/0/?token=one-time")
			else { throw Failure.invalidFixture }

			self.declaredPage = declaredPage
			self.barePage = barePage
			self.redirectingPage = redirectingPage
			self.appSignIn = appSignIn
			self.appPage = appPage
		}
	}

	internal enum Failure: Error {
		case invalidFixture
		case missingProfile
		case timedOut(String)
		case invalidPixels
		case missingDatabaseIcon
		case hostFallback
		case privateLookup
		case missingFetchedIcon
	}
}

extension SiteIconSmoke {
	@MainActor
	private final class Runner {
		private let engine: ChromiumBrowserEngine
		private let runtime: ChromiumRuntime
		private let client: BrowserSiteIconClient
		private let organization: BrowserOrganization
		private let baseURL: URL
		private let fixtureRoot: URL
		private let iconOrigin: IconOrigin
		private let otherProfile: Profile.ID = .init(rawValue: UUID())
		private let privateProfile: UUID = .init()
		private let host: NSView
		private let window: NSWindow
		private var tabs: Set<Tab.ID> = []

		internal init(
			engine: ChromiumBrowserEngine,
			runtime: ChromiumRuntime,
			client: BrowserSiteIconClient,
			organization: BrowserOrganization,
			baseURL: URL,
			fixtureRoot: URL,
			iconOrigin: IconOrigin
		) {
			self.engine = engine
			self.runtime = runtime
			self.client = client
			self.organization = organization
			self.baseURL = baseURL
			self.fixtureRoot = fixtureRoot
			self.iconOrigin = iconOrigin
			let bounds = NSRect(x: 0, y: 0, width: 480, height: 320)
			self.host = .init(frame: bounds)
			self.window = .init(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
			window.isReleasedWhenClosed = false
			window.title = "Arx controlled site icon fixture"
			window.contentView = host
		}

		internal func run() async throws {
			guard let profileID = organization.profiles.first?.id
			else { throw Failure.missingProfile }
			let profiles = Set(organization.profiles.map(\.id))
			client.configureProfiles(profiles.union([otherProfile]))
			let previousWindow = NSApp.keyWindow
			defer {
				for id in tabs {
					engine.client.close(id)
				}
				runtime.releasePrivateProfile(privateProfile)
				client.configureProfiles(profiles)
				engine.surface.detach(host)
				window.close()
				previousWindow?.makeKeyAndOrderFront(nil)
			}
			window.makeKeyAndOrderFront(nil)

			let savedURL = url("page.html")
			let first = try await open("red", profileID: profileID)
			let firstIcons = Observation(client.icons(.init(profileID: profileID, pageURL: savedURL)))
			defer { firstIcons.stop() }
			try await wait("authenticated ordinary icon") { SiteIconSmoke.matches(firstIcons.data, color: [255, 0, 0]) }
			engine.client.close(first)
			tabs.remove(first)
			let legacyProfile = organization.legacyProfileID ?? organization.profiles.first?.id
			let nativeProfile = profileID == legacyProfile ? nil : profileID.rawValue
			guard let persisted = try await runtime.siteIcon(pageURL: savedURL, profileID: nativeProfile)
			else { throw Failure.missingDatabaseIcon }
			guard SiteIconSmoke.matches(persisted.png, color: [255, 0, 0])
			else { throw Failure.invalidPixels }

			let absent = try await runtime.siteIcon(pageURL: url("never-visited.html"), profileID: nativeProfile)
			guard absent == nil else { throw Failure.hostFallback }
			print("ARX_SITE_ICONS_DATABASE_SUCCESS")

			// Saved pages that never loaded: the icon comes from the site's root page
			// or /favicon.ico, is stored in this profile and is read back without a
			// fetch. Another profile has its own database, so it fetches for itself;
			// the fixture counts each request.
			try await expectFetched(iconOrigin.declaredPage, profileID: nativeProfile, color: [255, 255, 0])
			try await expectFetched(iconOrigin.declaredPage, profileID: nativeProfile, color: [255, 255, 0])
			try await expectFetched(iconOrigin.declaredPage, profileID: otherProfile.rawValue, color: [255, 255, 0])
			try await expectFetched(iconOrigin.barePage, profileID: nativeProfile, color: [255, 0, 255])

			// A root that redirects to another host's sign-in page: the site's own
			// /favicon.ico, never the sign-in page's icon (DEV-1108).
			try await expectFetched(iconOrigin.redirectingPage, profileID: nativeProfile, color: [0, 255, 255])

			// A signed-in app: the fetch carries the profile's cookie, so the app's directory
			// answers with its own icon. Another profile isn't signed in and gets the app
			// host's /favicon.ico (DEV-1108).
			let signIn = try await openPage(iconOrigin.appSignIn, title: "Arx signed in", profileID: profileID)
			engine.client.close(signIn)
			tabs.remove(signIn)
			try await expectFetched(iconOrigin.appPage, profileID: nativeProfile, color: [0, 0, 128])
			try await expectFetched(iconOrigin.appPage, profileID: otherProfile.rawValue, color: [128, 128, 0])
			print("ARX_SITE_ICONS_FETCH_SUCCESS")

			_ = try await open("green", profileID: otherProfile)
			let otherIcons = Observation(client.icons(.init(profileID: otherProfile, pageURL: savedURL)))
			defer { otherIcons.stop() }
			try await wait("separate profile icon") { SiteIconSmoke.matches(otherIcons.data, color: [0, 255, 0]) }
			guard SiteIconSmoke.matches(firstIcons.data, color: [255, 0, 0])
			else { throw Failure.invalidPixels }

			_ = try await open("blue", profileID: profileID)
			try await wait("same-page icon refresh") { SiteIconSmoke.matches(firstIcons.data, color: [0, 0, 255]) }
			guard SiteIconSmoke.matches(otherIcons.data, color: [0, 255, 0])
			else { throw Failure.invalidPixels }

			// An icon the page replaces from script while open replaces the shown and the
			// stored one (DEV-1108).
			let scriptedURL = url("scripted.html")
			let scriptedIcons = Observation(client.icons(.init(profileID: profileID, pageURL: scriptedURL)))
			defer { scriptedIcons.stop() }
			_ = try await openPage(scriptedURL, title: "Arx scripted site icon replaced", profileID: profileID)
			try await wait("scripted icon replaced") { SiteIconSmoke.matches(scriptedIcons.data, color: [0, 128, 0]) }
			let storedScripted = try await runtime.siteIcon(pageURL: scriptedURL, profileID: nativeProfile)
			guard SiteIconSmoke.matches(storedScripted?.png, color: [0, 128, 0])
			else { throw Failure.invalidPixels }
			print("ARX_SITE_ICONS_PROFILE_SUCCESS")

			try runtime.preparePrivateProfile(privateProfile)
			do {
				_ = try await runtime.siteIcon(pageURL: savedURL, profileID: privateProfile)
				throw Failure.privateLookup
			} catch ChromiumSiteIconFailure.unavailable {
				// Private identities cannot query the ordinary parent's favicon database.
			}
			guard let legacyProfile else { throw Failure.missingProfile }
			try SiteIconRestartManifest(
				primaryProfile: profileID.rawValue,
				secondaryProfile: otherProfile.rawValue,
				legacyProfile: legacyProfile.rawValue,
				savedURL: savedURL
			).write(to: fixtureRoot)
			print("ARX_SITE_ICONS_SMOKE_SUCCESS")
		}

		private func expectFetched(
			_ pageURL: URL,
			profileID: UUID?,
			color: [UInt8]
		) async throws {
			let icon = try await runtime.siteIcon(pageURL: pageURL, profileID: profileID)
			guard SiteIconSmoke.matches(icon?.png, color: color)
			else { throw Failure.missingFetchedIcon }
		}

		private func open(
			_ color: String,
			profileID: Profile.ID
		) async throws -> Tab.ID {
			let tab = Tab(
				id: .init(rawValue: UUID()),
				profileID: profileID,
				restoration: .init(title: "Site icon fixture", url: url("set-\(color).html"))
			)
			tabs.insert(tab.id)
			try await engine.client.open(tab)
			engine.surface.attach(tab.id, host)
			try await wait("owned page \(color)") {
				guard let snapshot = self.engine.client.snapshot(tab.id)
				else { return false }
				return snapshot.navigation.title == "Arx site icon \(color)"
				&& snapshot.navigation.url == self.url("page.html")
				&& !snapshot.navigation.isLoading
				&& snapshot.navigation.errorCode == nil
			}
			return tab.id
		}

		/// Opens a fixture page and waits until it shows `title`.
		private func openPage(
			_ pageURL: URL,
			title: String,
			profileID: Profile.ID
		) async throws -> Tab.ID {
			let tab = Tab(
				id: .init(rawValue: UUID()),
				profileID: profileID,
				restoration: .init(title: "Site icon fixture", url: pageURL)
			)
			tabs.insert(tab.id)
			try await engine.client.open(tab)
			engine.surface.attach(tab.id, host)
			try await wait("page \(title)") {
				guard let snapshot = self.engine.client.snapshot(tab.id)
				else { return false }
				return snapshot.navigation.title == title
				&& snapshot.navigation.url == pageURL
				&& snapshot.navigation.errorCode == nil
			}
			return tab.id
		}

		private func url(_ name: String) -> URL {
			baseURL.deletingLastPathComponent().appendingPathComponent("site-icons/\(name)")
		}

		private func wait(
			_ phase: String,
			until ready: () -> Bool
		) async throws {
			let deadline = ContinuousClock.now.advanced(by: .seconds(10))
			while ContinuousClock.now < deadline {
				try Task.checkCancellation()
				if ready() {
					return
				}

				try await Task.sleep(for: .milliseconds(25))
			}
			throw Failure.timedOut(phase)
		}
	}

	internal static func matches(
		_ png: Data?,
		color: [UInt8]
	) -> Bool {
		guard
			let png,
			let source = CGImageSourceCreateWithData(png as CFData, nil),
			let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
			image.width == 32,
			image.height == 32,
			let space = CGColorSpace(name: CGColorSpace.sRGB)
		else { return false }
		var pixel: [UInt8] = [0, 0, 0, 0]
		let decoded = pixel.withUnsafeMutableBytes { bytes in
			guard let context = CGContext(
				data: bytes.baseAddress,
				width: 1,
				height: 1,
				bitsPerComponent: 8,
				bytesPerRow: 4,
				space: space,
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			) else { return false }
			context.draw(image, in: .init(x: 0, y: 0, width: 1, height: 1))
			return true
		}
		return decoded && pixel[3] == 255
		&& zip(pixel.prefix(3), color).allSatisfy { abs(Int($0) - Int($1)) <= 3 }
	}

	@MainActor
	private final class Observation {
		internal private(set) var data: Data?
		private var task: Task<Void, Never>?

		internal init(_ stream: AsyncStream<Data?>) {
			self.task = Task { [weak self] in
				for await data in stream {
					guard !Task.isCancelled else { return }
					self?.data = data
				}
			}
		}

		internal func stop() {
			task?.cancel()
		}
	}
}

internal enum SiteIconSmokeFixture {
	internal static let sentinel: String = "Arx site icons disposable fixture v1\n"

	internal static func validate(
		root: URL,
		profile: URL,
		baseURL: URL
	) throws {
		guard
			root.isFileURL,
			profile.isFileURL,
			root.lastPathComponent.hasPrefix("app-smoke-"),
			profile.standardizedFileURL.path == root.appendingPathComponent("profile").standardizedFileURL.path,
			valid(root, kind: S_IFDIR, mode: 0o700),
			valid(profile, kind: S_IFDIR, mode: 0o700),
			profile.resolvingSymlinksInPath().deletingLastPathComponent().path == root.resolvingSymlinksInPath().path,
			let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			(1...65535).contains(parts.port ?? 0),
			parts.user == nil,
			parts.password == nil,
			parts.query == nil,
			parts.fragment == nil,
			parts.path == "/index.html"
		else { throw SiteIconSmoke.Failure.invalidFixture }
		let marker = root.appendingPathComponent(".arx-site-icons-smoke")
		guard
			valid(marker, kind: S_IFREG, mode: 0o600, size: sentinel.utf8.count),
			(try? Data(contentsOf: marker)) == Data(sentinel.utf8)
		else { throw SiteIconSmoke.Failure.invalidFixture }
	}

	private static func valid(
		_ url: URL,
		kind: mode_t,
		mode: mode_t,
		size: Int? = nil
	) -> Bool {
		var info = stat()
		guard
			lstat(url.path, &info) == 0,
			info.st_uid == getuid(),
			info.st_mode & S_IFMT == kind,
			info.st_mode & 0o777 == mode
		else { return false }
		return size.map { info.st_size == $0 } ?? true
	}
}
#endif
