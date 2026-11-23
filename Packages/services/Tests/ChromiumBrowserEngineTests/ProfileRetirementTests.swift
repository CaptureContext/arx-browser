import BrowserCore
import BrowserEngineClient
import ChromiumBridge
import CustomDump
import Foundation
import Testing

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ProfileRetirementTests {
	@Test
	internal func defaultClientAndMissingNativeCapabilityStayUnavailable() async throws {
		expectNoDifference(BrowserEngineClient.liveValue.retirementIsAvailable(), false)
		await #expect(throws: ProfileRetirementFailure.unavailable) {
			try await BrowserEngineClient.liveValue.profileRetirementSnapshot()
		}
		let runtime = ChromiumRuntime(api: .init())
		let engine = ChromiumBrowserEngine(runtime: runtime, profileID: .init(rawValue: Self.legacy))
		runtime.didBecomeReady()
		defer { runtime.finish() }
		expectNoDifference(engine.client.retirementIsAvailable(), false)
	}

	@Test
	internal func activeOrPendingSessionCannotRetireAndLostReceiptKeepsAdmissionClosed() async throws {
		let fixture = RetirementAdapterFixture()
		defer { fixture.runtime.finish() }
		fixture.engine.pageProfiles[.init(rawValue: Self.tab)] = fixture.profile
		await #expect(throws: ProfileRetirementFailure.busy) {
			try await fixture.engine.client.retireProfile(fixture.request, { true })
		}
		expectNoDifference(RetirementAdapterFixture.queueCount, 0)
		fixture.engine.pageProfiles.removeAll()
		RetirementAdapterFixture.status = ARX_RETIREMENT_IO
		await #expect(throws: ProfileRetirementFailure.io) {
			try await fixture.engine.client.retireProfile(fixture.request, { true })
		}
		expectNoDifference(RetirementAdapterFixture.queueCount, 1)
		expectNoDifference(fixture.engine.retiringProfiles, [fixture.profile])
		await #expect(throws: ProfileRetirementFailure.busy) {
			try await fixture.engine.client.prepareProfile(fixture.profile)
		}
	}

	@Test
	internal func exactDurableAcknowledgmentRetiresWithoutClaimingErasure() async throws {
		let fixture = RetirementAdapterFixture()
		defer { fixture.runtime.finish() }
		let snapshot = try await fixture.engine.client.retireProfile(fixture.request, { true })
		expectNoDifference(snapshot.acknowledges(fixture.request), true)
		expectNoDifference(snapshot.records.first?.state, .awaitingStartup)
		expectNoDifference(snapshot.records.first?.profileID, fixture.profile)
		expectNoDifference(fixture.engine.retiringProfiles, [fixture.profile])
	}

	@Test
	internal func staleUndurableAndActiveSnapshotsDoNotAcknowledgeConsent() async throws {
		let request = ProfileRetirementRequest(
			profileID: .init(rawValue: Self.profile),
			requestID: Self.request,
			expectedRevision: 12
		)
		for (revision, durable, state) in [
			(UInt64(12), true, ProfileRetirementRecord.State.awaitingStartup),
			(13, false, .awaitingStartup), (13, true, .active),
		] {
			let snapshot = ProfileRetirementSnapshot(
				revision: revision,
				isDurable: durable,
				records: [.init(profileID: request.profileID, requestID: request.requestID, state: state)]
			)
			expectNoDifference(snapshot.acknowledges(request), false)
		}
	}

	@Test
	internal func blockedCleanupStillAcknowledgesOnlyExactDurableRetirement() async throws {
		let request = ProfileRetirementRequest(
			profileID: .init(rawValue: Self.profile),
			requestID: Self.request,
			expectedRevision: 12
		)
		let record = ProfileRetirementRecord(profileID: request.profileID, requestID: request.requestID, state: .blocked)
		expectNoDifference(ProfileRetirementSnapshot(revision: 13, isDurable: true, records: [record]).acknowledges(request), true)
		expectNoDifference(ProfileRetirementSnapshot(revision: 13, isDurable: false, records: [record]).acknowledges(request), false)
		let other = ProfileRetirementRequest(profileID: request.profileID, requestID: Self.legacy, expectedRevision: 12)
		expectNoDifference(ProfileRetirementSnapshot(revision: 13, isDurable: true, records: [record]).acknowledges(other), false)
	}

	fileprivate static let legacy: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
	fileprivate static let profile: UUID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
	fileprivate static let request: UUID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
	fileprivate static let tab: UUID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
}

@MainActor
private final class RetirementAdapterFixture {
	internal static weak var current: RetirementAdapterFixture?
	internal static var status: ArxProfileRetirementStatus = ARX_RETIREMENT_OK
	internal static var queueCount: Int = 0
	internal let runtime: ChromiumRuntime
	internal let engine: ChromiumBrowserEngine
	internal let profile: Profile.ID
	internal let request: ProfileRetirementRequest

	internal init() {
		Self.status = ARX_RETIREMENT_OK
		Self.queueCount = 0
		var api = ArxEngineAPI()
		api.profile_retirement_available = { true }
		api.queue_profile_retirement = { _, _, _, _, id in
			MainActor.assumeIsolated {
				RetirementAdapterFixture.queueCount += 1
				RetirementAdapterFixture.current?.deliver(id)
			}
		}
		self.runtime = .init(api: api)
		self.engine = .init(runtime: runtime, profileID: .init(rawValue: ProfileRetirementTests.legacy))
		self.profile = .init(rawValue: ProfileRetirementTests.profile)
		self.request = .init(profileID: profile, requestID: ProfileRetirementTests.request, expectedRevision: 12)
		Self.current = self
		runtime.didBecomeReady()
	}

	internal func deliver(_ id: UInt64) {
		profile.rawValue.uuidString.lowercased().withCString { profileBytes in
			request.requestID.uuidString.lowercased().withCString { requestBytes in
				var record = ArxProfileRetirementRecord(
					profile_id: profileBytes,
					request_id: requestBytes,
					legacy_storage: false,
					progress: ARX_RETIREMENT_AWAITING_STARTUP
				)
				withUnsafePointer(to: &record) { records in
					runtime.profileRetirement.complete(
						id, status: Self.status,
						native: .init(revision: 13, durable: true, records: records, record_count: 1)
					)
				}
			}
		}
	}
}
