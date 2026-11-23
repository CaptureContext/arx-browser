import ChromiumBridge
import CustomDump
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumProfileRetirementTests {
	@Test
	internal func durableRetirementIsNotErasureAndCancellationKeepsReceipt() async throws {
		let fixture = RetirementFixture()
		let task = Task { try await fixture.retire() }
		let call = try await fixture.nextCall()
		expectNoDifference(call.profile, fixture.profile.uuidString.lowercased())
		expectNoDifference(call.legacy, false)
		expectNoDifference(call.revision, 12)
		task.cancel()
		fixture.deliver(call.id, progress: ARX_RETIREMENT_AWAITING_STARTUP)
		let result = try await task.value
		expectNoDifference(result.records.first?.state, .awaitingStartup)
		expectNoDifference(result.records.first?.requestID, fixture.request)
		expectNoDifference(result.isDurable, true)
	}

	@Test
	internal func restartStatesRemainExplicitAndPayloadIsCopied() async throws {
		let fixture = RetirementFixture()
		for (native, expected) in [
			(ARX_RETIREMENT_QUARANTINE_PENDING, ChromiumProfileRetirementSnapshot.Record.State.quarantinePending),
			(ARX_RETIREMENT_RESTART_REQUIRED, .restartRequired),
			(ARX_RETIREMENT_VERIFICATION_PENDING, .verificationPending),
			(ARX_RETIREMENT_ERASED, .erased),
			(ARX_RETIREMENT_BLOCKED, .blocked),
		] {
			let task = Task { try await fixture.bridge.snapshot() }
			fixture.deliver(try await fixture.nextCall().id, progress: native)
			let result = try await task.value
			expectNoDifference(result.records.first?.state, expected)
			expectNoDifference(result.records.first?.profileID, fixture.profile)
		}
	}

	@Test
	internal func rejectedAndLostRepliesCannotInventDurability() async throws {
		let fixture = RetirementFixture()
		let task = Task { try await fixture.retire() }
		fixture.deliver(try await fixture.nextCall().id, status: ARX_RETIREMENT_IO)
		await #expect(throws: ChromiumProfileRetirementFailure.io) { try await task.value }

		let second = Task { try await fixture.retire() }
		let old = try await fixture.nextCall()
		fixture.bridge.stop()
		await #expect(throws: ChromiumProfileRetirementFailure.unavailable) { try await second.value }
		let third = Task { try await fixture.retire() }
		let current = try await fixture.nextCall()
		#expect(current.id > old.id)
		fixture.deliver(old.id, progress: ARX_RETIREMENT_ERASED)
		fixture.deliver(current.id, progress: ARX_RETIREMENT_RESTART_REQUIRED)
		let result = try await third.value
		expectNoDifference(result.records.first?.state, .restartRequired)
	}

	@Test
	internal func deniedConsentAndInvalidPayloadNeverQueueOrSucceed() async throws {
		let fixture = RetirementFixture()
		await #expect(throws: ChromiumProfileRetirementFailure.invalid) {
			try await fixture.bridge.retire(
				profileID: fixture.profile,
				requestID: fixture.request,
				expectedRevision: 12,
				authorize: { false }
			)
		}
		expectNoDifference(RetirementFixture.calls.count, 0)
		let task = Task { try await fixture.bridge.snapshot() }
		let call = try await fixture.nextCall()
		fixture.deliver(call.id, progress: ArxProfileRetirementProgress(rawValue: 999))
		await #expect(throws: ChromiumProfileRetirementFailure.invalid) { try await task.value }
	}
}

@MainActor
private final class RetirementFixture {
	internal struct Call {
		internal let id: UInt64
		internal let profile: String
		internal let legacy: Bool
		internal let revision: UInt64
	}

	internal static var calls: [Call] = []
	internal let profile: UUID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
	internal let request: UUID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
	internal let bridge: ChromiumProfileRetirement

	internal init() {
		Self.calls = []
		var api = ArxEngineAPI()
		api.profile_retirement_available = { true }
		api.inspect_profile_retirement = { id in
			MainActor.assumeIsolated { RetirementFixture.calls.append(.init(id: id, profile: "", legacy: false, revision: 0)) }
		}
		api.queue_profile_retirement = { key, legacy, _, revision, id in
			MainActor.assumeIsolated {
				RetirementFixture.calls.append(.init(id: id, profile: key.map(String.init(cString:)) ?? "", legacy: legacy, revision: revision))
			}
		}
		self.bridge = .init(api: api)
	}

	internal func retire() async throws -> ChromiumProfileRetirementSnapshot {
		try await bridge.retire(profileID: profile, requestID: request, expectedRevision: 12, authorize: { true })
	}

	internal func nextCall() async throws -> Call {
		for _ in 0..<1000 {
			if !Self.calls.isEmpty { return Self.calls.removeFirst() }
			await Task.yield()
		}
		throw ChromiumProfileRetirementFailure.unavailable
	}

	internal func deliver(
		_ id: UInt64,
		status: ArxProfileRetirementStatus = ARX_RETIREMENT_OK,
		progress: ArxProfileRetirementProgress = ARX_RETIREMENT_AWAITING_STARTUP
	) {
		profile.uuidString.lowercased().withCString { profileBytes in
			request.uuidString.lowercased().withCString { requestBytes in
				var record = ArxProfileRetirementRecord(
					profile_id: profileBytes,
					request_id: requestBytes,
					legacy_storage: false,
					progress: progress
				)
				withUnsafePointer(to: &record) { records in
					bridge.complete(id, status: status, native: .init(revision: 13, durable: true, records: records, record_count: 1))
				}
			}
		}
	}
}
