import AppKit
import ChromiumBridge
import CustomDump
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumInspectionTests {
	@Test
	internal func copiesBoundedSemanticDataAndPreservesTrustedScope() async throws {
		let fixture = InspectionFixture()
		let task = Task { try await fixture.inspect() }
		let request = try await fixture.nextRequest()
		expectNoDifference(request.scope, fixture.scope.uuidString.lowercased())
		expectNoDifference(request.page, 1)
		fixture.deliver(request.id)
		let snapshot = try await task.value
		expectNoDifference(snapshot.nodes.first?.name, "Explicit label")
		expectNoDifference(snapshot.nodes.last?.text, "Semantic text")
		expectNoDifference(snapshot.omissions, ChromiumInspectionOmission.allCases)
		#expect(fixture.bridge.documentIsCurrent(snapshot, page: 1, scope: fixture.scope))
	}

	@Test
	internal func framesAndWindowsUseTheFrameEntryPoint() async throws {
		let fixture = InspectionFixture(frames: true)
		let frame = InspectionFixture.token(200)
		let limits = ChromiumInspectionLimits(maximumNodes: 2, windowStart: 512, includesFormValues: true, includesBounds: true)
		let task = Task { try await fixture.bridge.inspect(page: 1, scope: fixture.scope, frameID: frame, limits: limits) }
		let request = try await fixture.nextRequest()
		expectNoDifference(InspectionFixture.windows.last?.frame, frame)
		expectNoDifference(InspectionFixture.windows.last?.start, 512)
		expectNoDifference(InspectionFixture.windows.last?.flags, UInt32(ARX_INSPECTION_FORM_VALUES | ARX_INSPECTION_BOUNDS))

		var json = InspectionFixture.json(request.id)
		json["windowStart"] = 512
		json["totalNodes"] = 2000
		json["omissions"] = ChromiumInspectionOmission.allCases.filter { $0 != .formValues }.map(\.rawValue)
		json["nodes"] = [
			[
				"index": 512,
				"parent": 3,
				"role": "textField",
				"value": "Draft",
				"bounds": ["x": 4, "y": 8, "width": 120, "height": 24],
			],
			["index": 513, "parent": 512, "role": "iframe", "frame": InspectionFixture.token(201)],
		]
		fixture.deliver(request.id, data: try JSONSerialization.data(withJSONObject: json))
		let snapshot = try await task.value
		expectNoDifference(snapshot.windowStart, 512)
		expectNoDifference(snapshot.totalNodes, 2000)
		expectNoDifference(snapshot.nodes.first?.value, "Draft")
		expectNoDifference(snapshot.nodes.first?.bounds, .init(x: 4, y: 8, width: 120, height: 24))
		expectNoDifference(snapshot.nodes.last?.frame, InspectionFixture.token(201))
	}

	@Test(arguments: ["unrequestedValue", "unrequestedBounds", "wrongFrame", "gap", "omissions"])
	internal func windowedResultsMustMatchTheirRequest(_ change: String) async throws {
		let fixture = InspectionFixture(frames: true)
		let limits = ChromiumInspectionLimits(maximumNodes: 2, windowStart: 2)
		let task = Task {
			try await fixture.bridge.inspect(page: 1, scope: fixture.scope, frameID: InspectionFixture.token(200), limits: limits)
		}
		let request = try await fixture.nextRequest()
		var json = InspectionFixture.json(request.id)
		json["windowStart"] = 2
		json["totalNodes"] = 10
		var nodes: [[String: Any]] = [["index": 2, "role": "button"], ["index": 3, "parent": 2, "role": "staticText", "text": "x"]]
		switch change {
		case "unrequestedValue": nodes[0]["value"] = "secret"
		case "unrequestedBounds": nodes[0]["bounds"] = ["x": 0, "y": 0, "width": 1, "height": 1]
		case "wrongFrame": json["frameID"] = InspectionFixture.token(999)
		case "gap": nodes[1]["index"] = 5
		default: json["omissions"] = ChromiumInspectionOmission.allCases.filter { $0 != .formValues }.map(\.rawValue)
		}
		json["nodes"] = nodes
		fixture.deliver(request.id, data: try JSONSerialization.data(withJSONObject: json))
		await #expect(throws: ChromiumInspectionFailure.invalidResponse) { try await task.value }
	}

	@Test
	internal func plainReadsKeepTheOriginalEntryPointWhenFramesAreUnavailable() async throws {
		let fixture = InspectionFixture()
		await #expect(throws: ChromiumInspectionFailure.unavailable) {
			try await fixture.bridge.inspect(page: 1, scope: fixture.scope, limits: .init(windowStart: 1))
		}
		#expect(InspectionFixture.calls.isEmpty)
	}

	@Test
	internal func cancellationBeforeDispatchAndLateCallbackNeverReuseRequest() async throws {
		let fixture = InspectionFixture()
		let preCancelled = Task { try await fixture.inspect() }
		preCancelled.cancel()
		await #expect(throws: CancellationError.self) { try await preCancelled.value }
		#expect(InspectionFixture.calls.isEmpty)

		let first = Task { try await fixture.inspect() }
		let original = try await fixture.nextRequest()
		first.cancel()
		await #expect(throws: CancellationError.self) { try await first.value }
		let second = Task { try await fixture.inspect() }
		let replacement = try await fixture.nextRequest()
		#expect(replacement.id > original.id)
		fixture.deliver(original.id)
		fixture.deliver(replacement.id)
		let result = try await second.value
		expectNoDifference(result.snapshotID, InspectionFixture.token(replacement.id))
		expectNoDifference(InspectionFixture.cancelled, [original.id])
	}

	@Test(arguments: ["revoke", "close", "native-document", "cancel"])
	internal func completedButNotResumedResultRejectsInvalidatedOwnership(_ operation: String) async throws {
		let fixture = InspectionFixture()
		let task = Task { try await fixture.inspect() }
		fixture.deliver(try await fixture.nextRequest().id)

		switch operation {
		case "revoke": fixture.bridge.revoke(scope: fixture.scope)
		case "close": fixture.bridge.remove(page: 1)
		case "native-document": InspectionFixture.nativeCurrent = false
		default: task.cancel()
		}
		if operation == "cancel" {
			await #expect(throws: CancellationError.self) { try await task.value }

		} else {
			await #expect(throws: ChromiumInspectionFailure.staleReference) { try await task.value }
		}
	}

	@Test
	internal func revokedScopeOrRecreatedPageCannotAcceptOldCallback() async throws {
		let fixture = InspectionFixture()
		let old = Task { try await fixture.inspect() }
		let original = try await fixture.nextRequest()
		fixture.bridge.revoke(scope: fixture.scope)
		fixture.bridge.remove(page: 1)
		fixture.bridge.register(page: 1)
		await #expect(throws: ChromiumInspectionFailure.staleReference) { try await old.value }

		let next = Task { try await fixture.inspect() }
		let replacement = try await fixture.nextRequest()
		fixture.deliver(original.id)
		fixture.deliver(replacement.id)
		let result = try await next.value
		expectNoDifference(result.snapshotID, InspectionFixture.token(replacement.id))
		expectNoDifference(InspectionFixture.revoked, [fixture.scope.uuidString.lowercased()])
	}

	@Test
	internal func referenceRequiresExactSnapshotPageScopeAndRendererRevalidation() async throws {
		let fixture = InspectionFixture()
		let task = Task { try await fixture.inspect() }
		fixture.deliver(try await fixture.nextRequest().id)
		let snapshot = try await task.value
		let reference = try #require(snapshot.nodes.first?.reference)
		fixture.bridge.register(page: 2)

		let mismatches: [(UInt64, UUID, String)] = [
			(2, fixture.scope, reference),
			(1, UUID(), reference),
			(1, fixture.scope, InspectionFixture.token(999)),
		]
		for (page, scope, token) in mismatches {
			await #expect(throws: ChromiumInspectionFailure.staleReference) {
				try await fixture.bridge.validate(token, in: snapshot, page: page, scope: scope)
			}
		}
		#expect(InspectionFixture.calls.isEmpty)

		let validation = Task {
			try await fixture.bridge.validate(reference, in: snapshot, page: 1, scope: fixture.scope)
		}
		let request = try await fixture.nextRequest()
		fixture.deliver(request.id, status: ARX_INSPECTION_STALE, data: Data())
		await #expect(throws: ChromiumInspectionFailure.staleReference) { try await validation.value }
	}

	@Test
	internal func nativeSuccessCannotValidateDifferentPageOrPayload() async throws {
		let fixture = InspectionFixture()
		let task = Task { try await fixture.inspect() }
		fixture.deliver(try await fixture.nextRequest().id, page: 9)
		await #expect(throws: ChromiumInspectionFailure.staleReference) { try await task.value }
	}

	@Test
	internal func rejectsOversizeBeforeDereferencingBytes() async throws {
		let fixture = InspectionFixture()
		let task = Task { try await fixture.inspect(limits: .init(maximumOutputBytes: 1_024)) }
		let request = try await fixture.nextRequest()
		fixture.bridge.complete(
			request.id,
			page: 1,
			status: ARX_INSPECTION_SUCCESS,
			bytes: nil,
			count: 1_025
		)
		await #expect(throws: ChromiumInspectionFailure.limitExceeded) { try await task.value }
	}

	@Test(arguments: ["parent", "duplicate-reference", "omissions", "role", "version", "identity", "large-text"])
	internal func malformedNativeProjectionFailsClosed(_ mutation: String) async throws {
		let fixture = InspectionFixture()
		let task = Task { try await fixture.inspect() }
		let request = try await fixture.nextRequest()
		var value = InspectionFixture.json(request.id)
		var nodes = value["nodes"] as! [[String: Any]]

		switch mutation {
		case "parent": nodes[0]["parent"] = 0
		case "duplicate-reference": nodes[1]["reference"] = nodes[0]["reference"]
		case "omissions": value["omissions"] = []
		case "role": nodes[0]["role"] = "button\npage instruction"
		case "version": value["domVersion"] = "01"
		case "identity": value["frameID"] = "foreign"
		default: nodes[1]["text"] = String(repeating: "x", count: 4_097)
		}
		value["nodes"] = nodes
		fixture.deliver(request.id, data: try JSONSerialization.data(withJSONObject: value))
		let failure: ChromiumInspectionFailure = mutation == "large-text" ? .limitExceeded : .invalidResponse
		await #expect(throws: failure) { try await task.value }
	}

	@Test
	internal func pendingAdmissionIsBoundedAndShutdownDrainsEverything() async throws {
		let fixture = InspectionFixture()
		var pending: [Task<ChromiumInspectionSnapshot, any Error>] = []
		for _ in 0..<16 {
			pending.append(Task { try await fixture.inspect() })
			_ = try await fixture.nextRequest()
		}
		await #expect(throws: ChromiumInspectionFailure.busy) { try await fixture.inspect() }
		fixture.bridge.stop()
		for task in pending {
			await #expect(throws: ChromiumInspectionFailure.staleReference) { try await task.value }
		}
		expectNoDifference(InspectionFixture.cancelled.count, 16)
	}

	@Test
	internal func runtimeRejectsPrivateAndForeignPageWithoutNativeAccess() async throws {
		var api = ArxEngineAPI()
		api.inspect_page = { _, _, _, _ in Issue.record("Unowned page reached native inspection") }
		api.validate_inspection_reference = { _, _, _, _, _ in }
		api.cancel_inspection = { _ in }
		api.revoke_inspection_scope = { _ in }
		api.inspection_document_is_current = { _, _, _ in false }
		let runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
		defer { runtime.finish() }
		let privatePage = ChromiumPage(id: 1, view: NSView(), runtime: runtime, isPrivate: true)
		let foreignPage = ChromiumPage(id: 2, view: NSView(), runtime: runtime)
		await #expect(throws: ChromiumInspectionFailure.unavailable) {
			try await runtime.inspect(privatePage, scope: UUID())
		}
		await #expect(throws: ChromiumInspectionFailure.staleReference) {
			try await runtime.inspect(foreignPage, scope: UUID())
		}
	}
}

@MainActor
private final class InspectionFixture {
	internal static var calls: [Call] = []
	internal static var cancelled: [UInt64] = []
	internal static var revoked: [String] = []
	internal static var nativeCurrent: Bool = true
	internal static var windows: [(frame: String, start: UInt32, flags: UInt32)] = []
	internal let bridge: ChromiumInspections
	internal let scope: UUID

	internal init(frames: Bool = false) {
		Self.calls = []
		Self.windows = []
		Self.cancelled = []
		Self.revoked = []
		Self.nativeCurrent = true
		self.scope = UUID()
		var api = ArxEngineAPI()
		api.inspect_page = { page, request, scope, _ in
			MainActor.assumeIsolated {
				InspectionFixture.calls.append(.init(id: request, page: page, scope: String(cString: scope!)))
			}
		}
		if frames {
			api.inspect_frame = { page, request, scope, frame, window in
				MainActor.assumeIsolated {
					InspectionFixture.windows.append((String(cString: frame!), window.window_start, window.flags))
					InspectionFixture.calls.append(.init(id: request, page: page, scope: String(cString: scope!)))
				}
			}
		}
		api.validate_inspection_reference = { page, request, scope, _, _ in
			MainActor.assumeIsolated {
				InspectionFixture.calls.append(.init(id: request, page: page, scope: String(cString: scope!)))
			}
		}
		api.inspection_document_is_current = { _, _, _ in
			MainActor.assumeIsolated { InspectionFixture.nativeCurrent }
		}
		api.cancel_inspection = { request in
			MainActor.assumeIsolated { InspectionFixture.cancelled.append(request) }
		}
		api.revoke_inspection_scope = { scope in
			MainActor.assumeIsolated { InspectionFixture.revoked.append(String(cString: scope!)) }
		}
		self.bridge = .init(api: api)
		bridge.register(page: 1)
	}

	internal func inspect(
		limits: ChromiumInspectionLimits = .init()
	) async throws -> ChromiumInspectionSnapshot {
		try await bridge.inspect(page: 1, scope: scope, limits: limits)
	}

	internal func nextRequest() async throws -> Call {
		for _ in 0..<1_000 {
			if !Self.calls.isEmpty { return Self.calls.removeFirst() }
			await Task.yield()
		}
		throw ChromiumInspectionFailure.timedOut
	}

	internal func deliver(
		_ request: UInt64,
		page: UInt64 = 1,
		status: ArxInspectionStatus = ARX_INSPECTION_SUCCESS,
		data: Data? = nil
	) {
		let payload = data ?? (try! JSONSerialization.data(withJSONObject: Self.json(request)))
		payload.withUnsafeBytes { bytes in
			bridge.complete(
				request,
				page: page,
				status: status,
				bytes: bytes.bindMemory(to: UInt8.self).baseAddress,
				count: payload.count
			)
		}
	}

	internal static func token(_ value: UInt64) -> String {
		String(format: "%032llx", value)
	}

	internal static func json(_ request: UInt64) -> [String: Any] {
		[
			"snapshotID": token(request),
			"documentID": token(100),
			"frameID": token(200),
			"domVersion": "7",
			"omissions": ChromiumInspectionOmission.allCases.map(\.rawValue),
			"nodes": [
				[
					"index": 0,
					"role": "button",
					"name": "Explicit label",
					"reference": token(300),
				],
				[
					"index": 1,
					"parent": 0,
					"role": "staticText",
					"text": "Semantic text",
				],
			],
		]
	}

	internal struct Call {
		internal let id: UInt64
		internal let page: UInt64
		internal let scope: String

		internal init(
			id: UInt64,
			page: UInt64,
			scope: String
		) {
			self.id = id
			self.page = page
			self.scope = scope
		}
	}
}
