import BrowserCore
import BrowserSiteIconClient
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

/// DEV-880. The engine adds its own uses to the app's before it releases a profile.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumProfileReleaseAdapterTests {
	@Test
	internal func onlyProfilesNothingUsesForTheGracePeriodAreReleased() async throws {
		let fixture = ReleaseAdapterFixture()
		defer { fixture.runtime.finish() }

		for profile in [fixture.legacy, fixture.shown, fixture.paged, fixture.idle] {
			try await fixture.prepare(profile)
		}
		fixture.engine.pageProfiles[.init(rawValue: UUID())] = fixture.paged
		let start = try #require(fixture.runtime.preparedOrdinaryProfiles[fixture.idle.rawValue]).lastUse

		// Within the grace period, nothing goes.
		let early = fixture.engine.releaseIdleProfiles(
			usedByApp: [fixture.shown],
			gracePeriod: .seconds(60),
			now: start.advanced(by: .seconds(30))
		)
		#expect(early.isEmpty)
		#expect(ReleaseAdapterFixture.released.isEmpty)

		let released = fixture.engine.releaseIdleProfiles(
			usedByApp: [fixture.shown],
			gracePeriod: .seconds(60),
			now: start.advanced(by: .seconds(61))
		)
		#expect(released == [fixture.legacy, fixture.idle])
		// Default is the nil key.
		#expect(Set(ReleaseAdapterFixture.released) == ["", fixture.idle.rawValue.uuidString.lowercased()])
		#expect(!fixture.runtime.isPreparedOrdinaryProfile(fixture.idle.rawValue))
		#expect(fixture.runtime.isPreparedOrdinaryProfile(fixture.shown.rawValue))
		#expect(fixture.runtime.isPreparedOrdinaryProfile(fixture.paged.rawValue))
	}

	/// Until Chromium lists a loaded profile's downloads, startup reconciliation is running.
	@Test
	internal func aProfileWhoseDownloadsAreUnlistedStaysLoaded() async throws {
		let fixture = ReleaseAdapterFixture()
		defer { fixture.runtime.finish() }

		try await fixture.prepare(fixture.idle, listsDownloads: false)
		let start = try #require(fixture.runtime.preparedOrdinaryProfiles[fixture.idle.rawValue]).lastUse
		#expect(fixture.engine.releaseIdleProfiles(usedByApp: [], gracePeriod: .seconds(1), now: start.advanced(by: .seconds(60))).isEmpty)
		#expect(ReleaseAdapterFixture.released.isEmpty)

		fixture.runtime.receiveDownload(.initialized(profileKey: fixture.idle.rawValue.uuidString.lowercased()))
		#expect(
			fixture.engine.releaseIdleProfiles(usedByApp: [], gracePeriod: .seconds(1), now: start.advanced(by: .seconds(61)))
				== [fixture.idle]
		)
	}

	@Test
	internal func theGracePeriodStartsWhenAProfileStopsBeingUsed() async throws {
		let fixture = ReleaseAdapterFixture()
		defer { fixture.runtime.finish() }

		try await fixture.prepare(fixture.shown)
		let start = try #require(fixture.runtime.preparedOrdinaryProfiles[fixture.shown.rawValue]).lastUse

		// Shown until minute five, then the window moves elsewhere.
		let shownLate = start.advanced(by: .seconds(300))
		#expect(fixture.engine.releaseIdleProfiles(usedByApp: [fixture.shown], gracePeriod: .seconds(60), now: shownLate).isEmpty)
		#expect(fixture.engine.releaseIdleProfiles(usedByApp: [], gracePeriod: .seconds(60), now: shownLate.advanced(by: .seconds(59))).isEmpty)
		#expect(
			fixture.engine.releaseIdleProfiles(
				usedByApp: [],
				gracePeriod: .seconds(60),
				now: shownLate.advanced(by: .seconds(60))
			)
				== [fixture.shown]
		)
	}

	@Test
	internal func aProfileNativeRefusesIsTriedAgainLater() async throws {
		let fixture = ReleaseAdapterFixture()
		defer { fixture.runtime.finish() }

		try await fixture.prepare(fixture.idle)
		let start = try #require(fixture.runtime.preparedOrdinaryProfiles[fixture.idle.rawValue]).lastUse
		ReleaseAdapterFixture.refuses = true
		#expect(fixture.engine.releaseIdleProfiles(usedByApp: [], gracePeriod: .seconds(1), now: start.advanced(by: .seconds(2))).isEmpty)
		ReleaseAdapterFixture.refuses = false
		#expect(
			fixture.engine.releaseIdleProfiles(usedByApp: [], gracePeriod: .seconds(1), now: start.advanced(by: .seconds(3)))
				== [fixture.idle]
		)
		#expect(ReleaseAdapterFixture.released.count == 2)
	}

	/// A sidebar keeps other spaces' tabs mounted; their icons mustn't load an idle profile.
	@Test
	internal func siteIconsOfAProfileThatIsNotLoadedNeverLoadIt() async throws {
		let fixture = ReleaseAdapterFixture()
		defer { fixture.runtime.finish() }

		let directory = FileManager.default.temporaryDirectory.appending(path: "arx-release-icons-\(UUID())")
		defer { try? FileManager.default.removeItem(at: directory) }
		let organization = BrowserOrganization(
			profiles: [.init(id: fixture.legacy, name: "Shown"), .init(id: fixture.idle, name: "Idle")],
			legacyProfileID: fixture.legacy
		)
		let icons = fixture.engine.siteIcons(organization: organization, storeDirectory: directory)
		let key = BrowserSiteIconKey(profileID: fixture.idle, pageURL: URL(string: "https://capturecontext.dev/")!)
		let stream = icons.icons(key)
		var answers = stream.makeAsyncIterator()
		#expect(await answers.next() == .some(nil))
		// The cache's lookup runs on later turns; it would have asked native to prepare by now.
		for _ in 0..<500 { await Task.yield() }
		#expect(ReleaseAdapterFixture.preparing.isEmpty)
		#expect(ReleaseAdapterFixture.iconLookups.isEmpty)
		#expect(!fixture.runtime.isPreparedOrdinaryProfile(fixture.idle.rawValue))

		// Once something loads the profile, the icon answered from storage is read from Chromium.
		try await fixture.prepare(fixture.idle)
		for _ in 0..<500 where ReleaseAdapterFixture.iconLookups.isEmpty { await Task.yield() }
		#expect(ReleaseAdapterFixture.iconLookups == [fixture.idle.rawValue.uuidString.lowercased()])
		_ = stream
	}
}

@MainActor
private struct ReleaseAdapterFixture {
	fileprivate static var preparing: [UInt64] = []
	fileprivate static var released: [String] = []
	fileprivate static var refuses: Bool = false
	fileprivate static var iconLookups: [String] = []
	fileprivate let runtime: ChromiumRuntime
	fileprivate let engine: ChromiumBrowserEngine
	fileprivate static let legacyProfile: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
	fileprivate var legacy: Profile.ID { Self.legacyProfile }
	fileprivate let shown: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
	fileprivate let paged: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!)
	fileprivate let idle: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!)

	fileprivate init() {
		Self.preparing = []
		Self.released = []
		Self.refuses = false
		Self.iconLookups = []
		var api = ArxEngineAPI()
		api.lookup_site_icon = { key, _, _ in
			MainActor.assumeIsolated { ReleaseAdapterFixture.iconLookups.append(key.map { String(cString: $0) } ?? "?") }
		}
		api.cancel_site_icon = { _ in }
		api.prepare_profile = { _, request in
			MainActor.assumeIsolated { ReleaseAdapterFixture.preparing.append(request) }
		}
		let release: ChromiumReleaseProfileFunction = { key in
			MainActor.assumeIsolated {
				ReleaseAdapterFixture.released.append(key.map { String(cString: $0) } ?? "?")
				return !ReleaseAdapterFixture.refuses
			}
		}
		let runtime = ChromiumRuntime(api: api, releaseProfile: release)
		runtime.didBecomeReady()
		self.runtime = runtime
		self.engine = .init(runtime: runtime, profileID: Self.legacyProfile)
	}

	fileprivate func prepare(
		_ profile: Profile.ID,
		listsDownloads: Bool = true
	) async throws {
		let task = Task { try await engine.client.prepareProfile(profile) }
		while Self.preparing.isEmpty { await Task.yield() }
		runtime.complete(Self.preparing.removeFirst(), true)
		try await task.value
		guard listsDownloads else { return }
		let key = profile == legacy ? "" : profile.rawValue.uuidString.lowercased()
		runtime.receiveDownload(.initialized(profileKey: key))
	}
}
