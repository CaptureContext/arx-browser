import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-880. Idle ordinary profiles go back to native, and load again on the next use.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumProfileReleaseTests {
	@Test
	internal func aReleasedProfileIsPreparedAgainOnItsNextUse() async throws {
		let fixture = ReleaseFixture()
		defer { fixture.runtime.finish() }

		#expect(fixture.runtime.supportsProfileRelease)
		try await fixture.prepare(ReleaseFixture.work)
		#expect(fixture.runtime.isPreparedOrdinaryProfile(ReleaseFixture.work))
		// Chromium hasn't listed its downloads yet: startup reconciliation holds it.
		#expect(try #require(fixture.runtime.preparedOrdinaryProfiles[ReleaseFixture.work]).hasDownloads)
		fixture.runtime.receiveDownload(.initialized(profileKey: ReleaseFixture.workKey))
		let use = try #require(fixture.runtime.preparedOrdinaryProfiles[ReleaseFixture.work])
		#expect(!use.isHeld && !use.hasDownloads)

		#expect(fixture.runtime.releaseProfile(ReleaseFixture.work))
		#expect(ReleaseFixture.released == [ReleaseFixture.workKey])
		#expect(!fixture.runtime.isPreparedOrdinaryProfile(ReleaseFixture.work))
		#expect(fixture.runtime.preparedOrdinaryProfiles.isEmpty)
		// Not prepared any more: nothing for native to release.
		#expect(!fixture.runtime.releaseProfile(ReleaseFixture.work))
		#expect(ReleaseFixture.released == [ReleaseFixture.workKey])

		try await fixture.prepare(ReleaseFixture.work)
		#expect(ReleaseFixture.prepared == [ReleaseFixture.workKey, ReleaseFixture.workKey])
		// Loaded again, its downloads are listed again before it counts as idle.
		#expect(try #require(fixture.runtime.preparedOrdinaryProfiles[ReleaseFixture.work]).hasDownloads)
	}

	@Test
	internal func aProfileNativeStillUsesStaysPrepared() async throws {
		let fixture = ReleaseFixture()
		defer { fixture.runtime.finish() }

		try await fixture.prepare(nil)
		ReleaseFixture.refuses = true
		#expect(!fixture.runtime.releaseProfile(nil))
		#expect(ReleaseFixture.released == [""])
		#expect(fixture.runtime.isPreparedOrdinaryProfile(nil))
		#expect(fixture.runtime.preparedOrdinaryProfiles.keys.map { $0 } == [nil])
	}

	@Test
	internal func engineWorkHoldsItsProfileUntilNativeAnswers() async throws {
		let fixture = ReleaseFixture()
		defer { fixture.runtime.finish() }

		try await fixture.prepare(ReleaseFixture.work)
		let before = try #require(fixture.runtime.preparedOrdinaryProfiles[ReleaseFixture.work]).lastUse
		let start = Task {
			try await fixture.runtime.startDownload(profileKey: ReleaseFixture.workKey, url: ReleaseFixture.url)
		}
		let request = await fixture.nextDownloadStart()
		#expect(try #require(fixture.runtime.preparedOrdinaryProfiles[ReleaseFixture.work]).isHeld)
		#expect(!fixture.runtime.releaseProfile(ReleaseFixture.work))
		#expect(ReleaseFixture.released.isEmpty)

		fixture.runtime.completeDownloadStart(request, status: ARX_DOWNLOAD_START_STARTED, guid: "guid", interruptReason: 0)
		#expect(try await start.value == "guid")
		let after = try #require(fixture.runtime.preparedOrdinaryProfiles[ReleaseFixture.work])
		#expect(!after.isHeld)
		// Finishing the work counts as a use.
		#expect(after.lastUse >= before)
		#expect(fixture.runtime.releaseProfile(ReleaseFixture.work))
	}

	@Test
	internal func chromiumsOwnRecordAnswersWhetherAProfileIsLoaded() async throws {
		let fixture = ReleaseFixture()
		defer { fixture.runtime.finish() }

		ReleaseFixture.chromiumLoaded = [ReleaseFixture.workKey]
		#expect(fixture.runtime.isLoadedInChromium(ReleaseFixture.work) == true)
		#expect(fixture.runtime.isLoadedInChromium(nil) == false)
		#expect(ReleaseFixture.asked == [ReleaseFixture.workKey, ""])

		let older = ReleaseFixture(releases: false)
		defer { older.runtime.finish() }
		#expect(older.runtime.isLoadedInChromium(ReleaseFixture.work) == nil)
	}

	@Test
	internal func privateProfilesAndOlderEnginesReleaseNothing() async throws {
		let fixture = ReleaseFixture()
		defer { fixture.runtime.finish() }

		let privateProfile = UUID()
		try fixture.runtime.preparePrivateProfile(privateProfile)
		#expect(fixture.runtime.preparedOrdinaryProfiles.isEmpty)
		#expect(!fixture.runtime.isPreparedOrdinaryProfile(privateProfile))
		#expect(!fixture.runtime.releaseProfile(privateProfile))

		let older = ReleaseFixture(releases: false)
		defer { older.runtime.finish() }
		try await older.prepare(ReleaseFixture.work)
		#expect(!older.runtime.supportsProfileRelease)
		#expect(!older.runtime.releaseProfile(ReleaseFixture.work))
		#expect(older.runtime.isPreparedOrdinaryProfile(ReleaseFixture.work))
		#expect(ReleaseFixture.released.isEmpty)
	}
}

@MainActor
private struct ReleaseFixture {
	fileprivate static let work: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
	fileprivate static let workKey: String = "00000000-0000-4000-8000-000000000002"
	fileprivate static let url: URL = URL(string: "https://capturecontext.dev/file.zip")!
	fileprivate static var prepared: [String] = []
	fileprivate static var preparing: [UInt64] = []
	fileprivate static var released: [String] = []
	fileprivate static var refuses: Bool = false
	fileprivate static var downloadStarts: [UInt64] = []
	fileprivate static var chromiumLoaded: Set<String> = []
	fileprivate static var asked: [String] = []
	fileprivate let runtime: ChromiumRuntime

	fileprivate init(releases: Bool = true) {
		Self.prepared = []
		Self.preparing = []
		Self.released = []
		Self.refuses = false
		Self.downloadStarts = []
		Self.chromiumLoaded = []
		Self.asked = []
		var api = ArxEngineAPI()
		api.prepare_profile = { key, request in
			MainActor.assumeIsolated {
				ReleaseFixture.prepared.append(key.map { String(cString: $0) } ?? "?")
				ReleaseFixture.preparing.append(request)
			}
		}
		api.prepare_private_profile = { _ in true }
		api.start_download = { request, _, _ in
			MainActor.assumeIsolated {
				ReleaseFixture.downloadStarts.append(request)
				return true
			}
		}
		let release: ChromiumReleaseProfileFunction = { key in
			MainActor.assumeIsolated {
				ReleaseFixture.released.append(key.map { String(cString: $0) } ?? "?")
				return !ReleaseFixture.refuses
			}
		}
		let loaded: ChromiumProfileIsLoadedFunction = { key in
			MainActor.assumeIsolated {
				let key = key.map { String(cString: $0) } ?? "?"
				ReleaseFixture.asked.append(key)
				return ReleaseFixture.chromiumLoaded.contains(key)
			}
		}
		self.runtime = .init(
			api: api,
			releaseProfile: releases ? release : nil,
			profileIsLoaded: releases ? loaded : nil
		)
		runtime.didBecomeReady()
	}

	fileprivate func prepare(_ profile: UUID?) async throws {
		let task = Task { try await runtime.prepareProfile(profile) }
		while Self.preparing.isEmpty { await Task.yield() }
		runtime.complete(Self.preparing.removeFirst(), true)
		try await task.value
	}

	fileprivate func nextDownloadStart() async -> UInt64 {
		while Self.downloadStarts.isEmpty { await Task.yield() }
		return Self.downloadStarts.removeFirst()
	}
}
