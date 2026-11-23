import AppKit
import ChromiumEngine

/// ABI39 Clear Browsing Data and the downloads location (DEV-647) against real
/// Chromium storage: counts, a time-ranged and an all-time clear, refused values,
/// one clear per profile, the downloads folder with a real download into it,
/// "Ask where to save", profile isolation and a private profile. ABI40 adds one
/// site's cookies and cache from the site menu (DEV-633). ABI45 adds a private
/// profile that follows the downloads folder of the profile that opened it (DEV-729).
@MainActor
internal final class BrowsingDataSmoke {
	internal static let argument: String = "--browsing-data-fixture"

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
	private let folder: URL
	private var pages: [ChromiumPage] = []
	private var windows: [NSWindow] = []
	private var privateProfiles: [UUID] = []
	private var phase: String = "startup"
	internal private(set) var verified: Bool = false

	internal init(
		runtime: ChromiumRuntime,
		url: URL,
		folder: URL
	) {
		self.runtime = runtime
		self.url = url
		self.folder = folder
	}

	internal func open() {
		NSApplication.shared.setActivationPolicy(.regular)
		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_BROWSING_DATA_SMOKE_VERIFIED")
			} catch {
				diagnostic("ARX_BROWSING_DATA_SMOKE_FAILED phase=\(phase) reason=\(error)")
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
		guard runtime.supportsProfileData, runtime.supportsSiteSettings, runtime.supportsSiteData
		else { throw Failure.unavailable }

		let all = Set(ChromiumBrowsingDataKind.allCases)

		phase = "count"
		try await runtime.prepareProfile(nil)
		let page = try await makePage()
		_ = try await runtime.evaluateScript(
			page,
			source: "document.cookie = 'arx=1; max-age=3600'; localStorage.setItem('arx', '1'); return 1;"
		)
		_ = try await runtime.setSitePermission(
			profile: nil,
			origin: "https://camera.example",
			permission: .camera,
			setting: .block
		)
		var counts = try await runtime.countBrowsingData(profile: nil, kinds: all, since: nil)
		guard
			let cookies = counts.cookies, cookies.sites >= 1,
			counts.cache != nil,
			counts.autofill != nil,
			let sites = counts.siteSettings, sites.sites >= 1
		else { throw Failure.unexpected("counts \(counts)") }

		// Only what was asked is counted.
		counts = try await runtime.countBrowsingData(profile: nil, kinds: [.cache], since: nil)
		guard counts.cookies == nil, counts.siteSettings == nil, counts.cache != nil
		else { throw Failure.unexpected("cache-only counts \(counts)") }
		diagnostic("ARX_BROWSING_DATA_SMOKE_COUNT")

		phase = "site"

		// The fixture page is on a loopback IP, which is its own site.
		guard
			let host = url.host(),
			try await runtime.siteDataScope(profile: nil, url: url) == host,
			try await runtime.siteDataScope(profile: nil, url: URL(string: "https://a.b.example.co.uk/x")!)
				== "example.co.uk"
		else { throw Failure.unexpected("site scope") }
		try await refuses("site-file") {
			_ = try await self.runtime.siteDataScope(profile: nil, url: URL(fileURLWithPath: "/tmp/a.html"))
		}
		try await refuses("site-kinds") {
			_ = try await self.runtime.clearSiteData(profile: nil, url: self.url, kinds: [.history])
		}

		// Another site's clear keeps this one's cookies; this site's own removes them.
		var site = try await runtime.clearSiteData(
			profile: nil,
			url: URL(string: "https://other.example")!,
			kinds: [.cookies]
		)
		guard site.domain == "other.example", site.failed.isEmpty
		else { throw Failure.unexpected("other site \(site)") }
		counts = try await runtime.countBrowsingData(profile: nil, kinds: [.cookies], since: nil)
		guard let kept = counts.cookies, kept.sites >= 1
		else { throw Failure.unexpected("another site's clear removed cookies \(counts)") }
		site = try await runtime.clearSiteData(profile: nil, url: url, kinds: [.cookies, .cache])
		guard site.domain == host, site.failed.isEmpty
		else { throw Failure.unexpected("site clear \(site)") }
		counts = try await runtime.countBrowsingData(profile: nil, kinds: [.cookies], since: nil)
		guard counts.cookies?.sites == 0
		else { throw Failure.unexpected("after site clear \(counts)") }

		// Site settings aren't site data.
		guard
			try await runtime.siteSettingsList(profile: nil).permissions.sites
				.contains(where: { $0.origin == "https://camera.example" })
		else { throw Failure.unexpected("a site clear removed site settings") }
		diagnostic("ARX_BROWSING_DATA_SMOKE_SITE")

		phase = "invalid"
		try await refuses("future") {
			_ = try await self.runtime.countBrowsingData(
				profile: nil,
				kinds: [.cookies],
				since: Date().addingTimeInterval(3 * 86_400)
			)
		}
		try await refuses("no-kinds") {
			_ = try await self.runtime.clearBrowsingData(profile: nil, kinds: [], since: nil)
		}
		try await refuses("relative-folder") {
			_ = try await self.runtime.setDownloadSettings(profile: nil, directory: "Downloads", ask: false)
		}
		try await refuses("missing-folder") {
			_ = try await self.runtime.setDownloadSettings(
				profile: nil,
				directory: self.folder.appending(path: "missing").path,
				ask: false
			)
		}
		diagnostic("ARX_BROWSING_DATA_SMOKE_INVALID")

		phase = "clear"

		// A range that started after the site setting was made keeps it.
		try await Task.sleep(for: .seconds(1.5))
		let later = Date()
		try await Task.sleep(for: .seconds(1.5))
		var failed = try await runtime.clearBrowsingData(profile: nil, kinds: [.siteSettings], since: later)
		guard failed.isEmpty else { throw Failure.unexpected("ranged failed \(failed)") }
		guard
			try await runtime.siteSettingsList(profile: nil).permissions.sites
				.contains(where: { $0.origin == "https://camera.example" })
		else { throw Failure.unexpected("a ranged clear removed an older site setting") }

		// Two clears of one profile at once: whichever reaches native second is refused,
		// the other clears.
		let racers = [Set(ChromiumBrowsingDataKind.allCases), [.cache]].map { kinds in
			Task { () -> Result<Set<ChromiumBrowsingDataKind>, ChromiumProfileDataFailure> in
				do throws(ChromiumProfileDataFailure) {
					return .success(try await self.runtime.clearBrowsingData(profile: nil, kinds: kinds, since: nil))
				} catch {
					return .failure(error)
				}
			}
		}
		var results: [Result<Set<ChromiumBrowsingDataKind>, ChromiumProfileDataFailure>] = []
		for racer in racers {
			results.append(await racer.value)
		}
		let busy = results.filter { $0 == .failure(.busy) }.count
		let cleared = results.filter { $0 == .success([]) }.count
		guard busy == 1, cleared == 1
		else { throw Failure.unexpected("concurrent clears \(results)") }

		// The busy one may have been the full clear; make sure everything is gone.
		failed = try await runtime.clearBrowsingData(profile: nil, kinds: all, since: nil)
		guard failed.isEmpty else { throw Failure.unexpected("failed \(failed)") }
		counts = try await runtime.countBrowsingData(profile: nil, kinds: [.cookies, .siteSettings], since: nil)
		guard counts.cookies?.sites == 0, counts.siteSettings?.sites == 0
		else { throw Failure.unexpected("after clear \(counts)") }
		guard try await runtime.siteSettingsList(profile: nil).permissions.sites.isEmpty
		else { throw Failure.unexpected("site settings survived") }
		diagnostic("ARX_BROWSING_DATA_SMOKE_CLEAR")

		phase = "downloads"
		let initial = try await runtime.downloadSettings(profile: nil)
		guard !initial.ask, !initial.managed, initial.directory.hasPrefix("/"), !initial.defaultDirectory.isEmpty
		else { throw Failure.unexpected("initial downloads \(initial)") }
		var settings = try await runtime.setDownloadSettings(profile: nil, directory: folder.path, ask: false)
		guard settings.directory == folder.path, !settings.ask
		else { throw Failure.unexpected("set downloads \(settings)") }
		let events = runtime.downloadEvents()
		let guid = try await runtime.startDownload(profileKey: "", url: url)
		var target: URL?
		for await event in events {
			guard case let .changed(download) = event, download.guid == guid else { continue }

			if download.state == .complete {
				target = download.target
				break
			}
			guard download.state == .inProgress
			else { throw Failure.unexpected("download \(download.state)") }
		}
		guard
			let target,
			target.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path
		else { throw Failure.unexpected("download target \(String(describing: target))") }

		// Nil keeps the folder and changes only the question.
		settings = try await runtime.setDownloadSettings(profile: nil, directory: nil, ask: true)
		guard settings.directory == folder.path, settings.ask
		else { throw Failure.unexpected("ask \(settings)") }
		settings = try await runtime.downloadSettings(profile: nil)
		guard settings.directory == folder.path, settings.ask
		else { throw Failure.unexpected("read back \(settings)") }
		settings = try await runtime.setDownloadSettings(profile: nil, directory: initial.directory, ask: false)
		guard settings.directory == initial.directory, !settings.ask
		else { throw Failure.unexpected("restore \(settings)") }
		diagnostic("ARX_BROWSING_DATA_SMOKE_DOWNLOADS")

		phase = "isolation"
		_ = try await runtime.setDownloadSettings(profile: nil, directory: folder.path, ask: true)
		let other = UUID()
		try await runtime.prepareProfile(other)
		let otherSettings = try await runtime.downloadSettings(profile: other)
		guard otherSettings.directory != folder.path, !otherSettings.ask
		else { throw Failure.unexpected("other profile \(otherSettings)") }
		_ = try await runtime.setDownloadSettings(profile: nil, directory: initial.directory, ask: false)
		diagnostic("ARX_BROWSING_DATA_SMOKE_ISOLATION")

		phase = "private"
		let privateProfile = UUID()
		try runtime.preparePrivateProfile(privateProfile)
		privateProfiles.append(privateProfile)
		try await refuses("private-count", expected: .unavailable) {
			_ = try await self.runtime.countBrowsingData(profile: privateProfile, kinds: all, since: nil)
		}
		try await refuses("private-clear", expected: .unavailable) {
			_ = try await self.runtime.clearBrowsingData(profile: privateProfile, kinds: all, since: nil)
		}
		try await refuses("private-downloads", expected: .unavailable) {
			_ = try await self.runtime.setDownloadSettings(profile: privateProfile, directory: nil, ask: true)
		}
		try await refuses("private-site", expected: .unavailable) {
			_ = try await self.runtime.clearSiteData(profile: privateProfile, url: self.url, kinds: [.cookies])
		}
		try await refuses("unknown", expected: .unavailable) {
			_ = try await self.runtime.downloadSettings(profile: UUID())
		}
		diagnostic("ARX_BROWSING_DATA_SMOKE_PRIVATE")

		try await verifyPrivateOpener(other: other)
	}

	/// DEV-729. A private profile opened from `other` saves into `other`'s downloads
	/// folder, and follows it when it changes. Default saves into the fixture folder
	/// meanwhile, so a wrong destination never reaches the user's Downloads.
	private func verifyPrivateOpener(other: UUID) async throws {
		phase = "private-opener"
		let openerFolder = folder.appending(path: "opener", directoryHint: .isDirectory)
		let changedFolder = folder.appending(path: "opener-changed", directoryHint: .isDirectory)
		for directory in [openerFolder, changedFolder] {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		}
		_ = try await runtime.setDownloadSettings(profile: nil, directory: folder.path, ask: false)
		_ = try await runtime.setDownloadSettings(profile: other, directory: openerFolder.path, ask: false)

		let follower = UUID()
		try runtime.preparePrivateProfile(follower, followingDownloadsOf: other)
		privateProfiles.append(follower)
		let page = try await makePage(profile: follower)
		guard page.isPrivate else { throw Failure.unexpected("private-opener page isn't private") }

		var target = try await privateDownload(in: page)
		guard Self.directory(of: target) == Self.path(openerFolder)
		else { throw Failure.unexpected("private-opener target \(target.path)") }

		// The opener's change reaches the open private profile.
		_ = try await runtime.setDownloadSettings(profile: other, directory: changedFolder.path, ask: false)
		target = try await privateDownload(in: page)
		guard Self.directory(of: target) == Self.path(changedFolder)
		else { throw Failure.unexpected("private-opener changed target \(target.path)") }

		// The opener only ever reads: its own settings are as set.
		let opener = try await runtime.downloadSettings(profile: other)
		guard opener.directory == changedFolder.path, !opener.ask
		else { throw Failure.unexpected("private-opener opener \(opener)") }

		// A private profile can't be an opener.
		do {
			try runtime.preparePrivateProfile(UUID(), followingDownloadsOf: follower)
			throw Failure.unexpected("private opener accepted")
		} catch ChromiumError.pageCreationFailed {}
		diagnostic("ARX_BROWSING_DATA_SMOKE_PRIVATE_OPENER")
	}

	/// Opens the fixture's binary file in a private page, which downloads it, and
	/// returns where it was saved.
	private func privateDownload(in page: ChromiumPage) async throws -> URL {
		let events = runtime.downloadEvents()
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
		components.path = "/arx-private-download.bin"
		components.queryItems = [.init(name: "attempt", value: UUID().uuidString)]
		let source = components.url!
		try page.navigate(to: source)
		for await event in events {
			guard
				case let .changed(download) = event,
				download.isPrivate,
				download.url?.path == source.path,
				download.url?.query == source.query
			else { continue }

			if download.state == .complete, let target = download.target { return target }
			guard download.state == .inProgress
			else { throw Failure.unexpected("private download \(download.state)") }
		}
		throw Failure.timedOut
	}

	private static func directory(of file: URL) -> String {
		path(file.deletingLastPathComponent())
	}

	private static func path(_ directory: URL) -> String {
		directory.resolvingSymlinksInPath().standardizedFileURL.path
	}

	private func refuses(
		_ name: String,
		expected: ChromiumProfileDataFailure? = nil,
		_ body: () async throws -> Void
	) async throws {
		do {
			try await body()
		} catch let failure as ChromiumProfileDataFailure {
			switch (expected, failure) {
			case (nil, .invalid): return
			case let (expected?, failure) where failure == expected: return
			default: throw Failure.unexpected("\(name) \(failure)")
			}
		}
		throw Failure.unexpected("\(name) accepted")
	}

	private func makePage(profile: UUID? = nil) async throws -> ChromiumPage {
		let page = try await runtime.makePage(profile: profile)
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

	private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
		let deadline = Date().addingTimeInterval(15)
		while !(await condition()) {
			guard Date() < deadline else { throw Failure.timedOut }
			try await Task.sleep(for: .milliseconds(50))
		}
	}
}

private func diagnostic(_ message: String) {
	FileHandle.standardError.write(Data("\(message)\n".utf8))
}
