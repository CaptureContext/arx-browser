import AppKit
import BrowserCore
import ChromiumBridge
import BrowserPageInspectionClient
import ChromiumEngine
import CustomDump
import Foundation
import Testing
import _TestSupport

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumInspectionAdapterTests {
	@Test
	internal func retainedEngineClientTracksReadinessAndRejectsMissingOrPrivateSessions() async throws {
		NativeInspectionFixture.calls = 0
		var api = ArxEngineAPI()
		api.inspect_page = { _, _, _, _ in
			MainActor.assumeIsolated { NativeInspectionFixture.calls += 1 }
		}
		api.validate_inspection_reference = { _, _, _, _, _ in }
		api.inspection_document_is_current = { _, _, _ in true }
		api.cancel_inspection = { _ in }
		api.revoke_inspection_scope = { _ in }
		api.page_close_generation = { _ in 8 }
		api.prepare_private_profile = { _ in true }
		api.create_page = { _, _ in 1 }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { NativeInspectionFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.navigate = { _, _ in true }
		api.destroy_page = { _ in }

		let runtime = ChromiumRuntime(api: api)
		let engine = ChromiumBrowserEngine(runtime: runtime, profileID: .init(rawValue: UUID(0)))
		let client = engine.inspection
		let source = PageInspectionSource(
			tabID: .init(rawValue: UUID(3)),
			profileID: .init(rawValue: UUID(4)),
			sessionRevision: 1,
			documentRevision: 8,
			scopeID: UUID(99)
		)
		let request = AutomationInspectionRequest(
			targetID: source.tabID.rawValue,
			expectedRevision: String(repeating: "a", count: 64)
		)
		#expect(!client.isAvailable())
		await #expect(throws: AutomationFailure.notReady) {
			try await client.inspectAuthorized(request, source, { true })
		}

		runtime.didBecomeReady()
		#expect(client.isAvailable())
		await #expect(throws: AutomationFailure.staleTarget) {
			try await client.inspectAuthorized(request, source, { true })
		}

		try runtime.preparePrivateProfile(source.profileID.rawValue)
		try await engine.client.open(.init(
			id: source.tabID,
			profileID: source.profileID,
			restoration: .init(title: "Private fixture", url: URL(string: "https://fixture.invalid")!)
		))
		expectNoDifference(engine.client.snapshot(source.tabID)?.revision, source.sessionRevision)
		expectNoDifference(engine.client.snapshot(source.tabID)?.documentRevision, source.documentRevision)
		await #expect(throws: AutomationFailure.staleTarget) {
			try await client.inspectAuthorized(request, source, { true })
		}
		expectNoDifference(NativeInspectionFixture.calls, 0)

		engine.closeAll()
		runtime.finish()
		#expect(!client.isAvailable())
		await #expect(throws: AutomationFailure.notReady) {
			try await client.inspectAuthorized(request, source, { true })
		}
	}

	@Test
	internal func absentNativeFunctionTableNeverAdvertisesAvailability() async throws {
		let runtime = ChromiumRuntime(api: ArxEngineAPI())
		let engine = ChromiumBrowserEngine(runtime: runtime, profileID: .init(rawValue: UUID(0)))
		let client = engine.inspection
		runtime.didBecomeReady()
		defer { runtime.finish() }
		#expect(!client.isAvailable())
	}

	@Test(arguments: ["scope", "document", "session", "private", "profile", "grant"])
	internal func staleAuthorityIsRejectedBeforeAndAfterNativeAwait(change: String) async throws {
		let fixture = InspectionFixture()
		let client = fixture.client
		let task = Task { try await client.inspectAuthorized(fixture.request, fixture.source, { fixture.authorized }) }
		try await fixture.waitForRead()

		if change == "grant" {
			fixture.authorized = false

		} else if change == "scope" || change == "document" {
			fixture.documentCurrent = false

		} else {
			fixture.sourceCurrent = false
		}
		fixture.complete()
		await #expect(throws: AutomationFailure.staleTarget) { try await task.value }
		#expect(change == "grant" || !client.documentIsCurrent(fixture.result))

		fixture.sourceCurrent = false
		await #expect(throws: AutomationFailure.staleTarget) {
			try await client.inspectAuthorized(fixture.request, fixture.source, { fixture.authorized })
		}
		expectNoDifference(fixture.calls, 1)
	}

	@Test
	internal func cancellationAndShutdownNeverReleaseCompletedSnapshot() async throws {
		for cancel in [true, false] {
			let fixture = InspectionFixture()
			let task = Task { try await fixture.client.inspectAuthorized(fixture.request, fixture.source, { true }) }
			try await fixture.waitForRead()
			if cancel {
			task.cancel()
		} else {
			fixture.available = false
		}
			fixture.complete()
			do {
				_ = try await task.value
				Issue.record("Completed snapshot escaped cancellation/shutdown")
			} catch is CancellationError {
				#expect(cancel)
			} catch {
				expectNoDifference(error as? AutomationFailure, .notReady)
			}
		}
	}

	@Test
	internal func snapshotKeepsHistoricalVersionAndBudgetsWithoutClaimingCurrentDOM() async throws {
		let fixture = InspectionFixture()
		let task = Task { try await fixture.client.inspectAuthorized(fixture.request, fixture.source, { true }) }
		try await fixture.waitForRead()
		fixture.complete()
		let snapshot = try await task.value
		expectNoDifference(snapshot, fixture.result.snapshot)
		expectNoDifference(fixture.limits, .init(
			maximumNodes: 256,
			maximumTextBytes: 32_768,
			maximumOutputBytes: 114_688
		))
		#expect(fixture.client.documentIsCurrent(fixture.result))
	}

	@Test
	internal func framesWindowsAndOptInFieldsSurviveBothConversions() async throws {
		let fixture = InspectionFixture()
		let frame = String(repeating: "a", count: 32)
		fixture.request.frameID = frame
		fixture.request.windowStart = 600
		fixture.request.includesFormValues = true
		fixture.request.includesBounds = true
		let request = fixture.request
		let task = Task { try await fixture.client.inspectAuthorized(request, fixture.source, { true }) }
		try await fixture.waitForRead()
		expectNoDifference(fixture.frameID, frame)
		expectNoDifference(fixture.limits?.windowStart, 600)
		expectNoDifference(fixture.limits?.includesFormValues, true)
		expectNoDifference(fixture.limits?.includesBounds, true)
		fixture.continuation?.resume(returning: .init(
			snapshotID: "snapshot",
			documentID: "document",
			frameID: frame,
			domVersion: "7",
			nodes: [
				.init(
					index: 600,
					parent: 2,
					role: "textField",
					name: nil,
					text: nil,
					reference: nil,
					value: "Draft",
					bounds: .init(x: 1, y: 2, width: 30, height: 40)
				),
				.init(
					index: 601,
					parent: 600,
					role: "iframe",
					name: nil,
					text: nil,
					reference: nil,
					frame: String(repeating: "b", count: 32)
				),
			],
			omissions: ChromiumInspectionOmission.allCases.filter { $0 != .formValues },
			windowStart: 600,
			totalNodes: 900
		))
		let snapshot = try await task.value
		expectNoDifference(snapshot.totalNodes, 900)
		expectNoDifference(snapshot.nodes[0].value, "Draft")
		expectNoDifference(snapshot.nodes[0].bounds, .init(x: 1, y: 2, width: 30, height: 40))
		expectNoDifference(snapshot.nodes[1].frame, String(repeating: "b", count: 32))

		// The reverse conversion feeds documentIsCurrent; it must be exact.
		expectNoDifference(ChromiumInspectionSnapshot(snapshot).nodes[0].bounds, .init(x: 1, y: 2, width: 30, height: 40))
		expectNoDifference(ChromiumInspectionSnapshot(snapshot).totalNodes, 900)
	}

	@Test
	internal func unavailableAndNativeFailureStayActionable() async throws {
		let fixture = InspectionFixture()
		fixture.available = false
		await #expect(throws: AutomationFailure.notReady) {
			try await fixture.client.inspectAuthorized(fixture.request, fixture.source, { true })
		}
		expectNoDifference(fixture.calls, 0)
		fixture.available = true
		let task = Task { try await fixture.client.inspectAuthorized(fixture.request, fixture.source, { true }) }
		try await fixture.waitForRead()
		fixture.continuation?.resume(throwing: ChromiumInspectionFailure.limitExceeded)
		fixture.continuation = nil
		await #expect(throws: AutomationFailure.limitExceeded) { try await task.value }
	}
}

@MainActor
private final class InspectionFixture {
	fileprivate var available: Bool = true
	fileprivate var authorized: Bool = true
	fileprivate var sourceCurrent: Bool = true
	fileprivate var documentCurrent: Bool = true
	fileprivate var calls: Int = 0
	fileprivate var limits: ChromiumInspectionLimits?
	fileprivate var frameID: String?
	fileprivate var continuation: CheckedContinuation<ChromiumInspectionSnapshot, any Error>?
	fileprivate let source: PageInspectionSource = .init(
		tabID: .init(rawValue: UUID(3)),
		profileID: .init(rawValue: UUID(0)),
		sessionRevision: 3,
		documentRevision: 8,
		scopeID: UUID(99)
	)
	fileprivate var request: AutomationInspectionRequest = .init(
		targetID: UUID(3),
		expectedRevision: String(repeating: "a", count: 64)
	)

	fileprivate var result: AutomationInspectionResult {
		.init(request: request, source: source, snapshot: .init(
			snapshotID: "snapshot",
			documentID: "document",
			frameID: "frame",
			domVersion: "7",
			nodes: [.init(index: 0, role: "staticText", text: "Historical text")],
			omissions: PageInspectionOmission.allCases
		))
	}

	fileprivate var client: BrowserPageInspectionClient {
		ChromiumInspectionAdapter.client(
			isAvailable: { [self] in available },
			sourceIsCurrent: { [self] in sourceCurrent && $0 == source },
			inspect: { [self] requested, frameID, limits in
				expectNoDifference(requested, source)
				calls += 1
				self.frameID = frameID
				self.limits = limits
				return try await withCheckedThrowingContinuation { continuation = $0 }
			},
			documentIsCurrent: { [self] snapshot, requested in
				documentCurrent && requested == source && snapshot.snapshotID == result.snapshot.snapshotID
			},
			revokeScope: { _ in }
		)
	}

	fileprivate func waitForRead() async throws {
		for _ in 0..<1000 {
			if continuation != nil { return }
			await Task.yield()
		}
		throw AutomationFailure.timedOut
	}

	fileprivate func complete() {
		continuation?.resume(returning: .init(
			snapshotID: "snapshot",
			documentID: "document",
			frameID: "frame",
			domVersion: "7",
			nodes: [.init(index: 0, parent: nil, role: "staticText", name: nil, text: "Historical text", reference: nil)],
			omissions: ChromiumInspectionOmission.allCases
		))
		continuation = nil
	}
}

@MainActor
private enum NativeInspectionFixture {
	fileprivate static var calls: Int = 0
	fileprivate static let view: NSView = .init()
}
