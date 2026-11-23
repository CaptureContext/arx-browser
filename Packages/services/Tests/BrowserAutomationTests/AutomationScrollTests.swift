import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP

@testable import BrowserMCPServer

internal struct AutomationScrollTests {
	@Test(arguments: AutomationScrollRequest.Axis.allCases)
	internal func schemaRequiresExplicitTargetAxisAndBoundedFiniteDelta(axis: AutomationScrollRequest.Axis) async throws {
		for delta in [-8192.0, -120.5, -0.0, 0, 120.5, 8192] {
			let request = Self.request(axis: axis, delta: delta)
			let arguments = Self.arguments(request)
			expectNoDifference(try AutomationTools.operation(name: "browser_scroll", arguments: arguments), .scroll(request))

			for key in arguments.keys {
				var missing = arguments
				missing[key] = nil
				#expect(throws: AutomationFailure.invalidRequest) {
					try AutomationTools.operation(name: "browser_scroll", arguments: missing)
				}
			}
			var implicit = arguments
			implicit["focus"] = .bool(true)
			#expect(throws: AutomationFailure.invalidRequest) {
				try AutomationTools.operation(name: "browser_scroll", arguments: implicit)
			}
		}
	}

	@Test(arguments: [Double.nan, .infinity, -.infinity, 8192.0001, -8192.0001])
	internal func invalidDeltasNeverReachAnOperation(delta: Double) async throws {
		let request = Self.request(delta: delta)
		#expect(throws: AutomationFailure.invalidDelta) { try request.validate() }
		#expect(throws: AutomationFailure.invalidDelta) {
			try AutomationTools.operation(name: "browser_scroll", arguments: Self.arguments(request))
		}
	}

	@Test
	internal func integersAreAcceptedButStringsBooleansAndUnknownAxesAreRejected() async throws {
		let request = Self.request(delta: 120)
		var arguments = Self.arguments(request)
		arguments["deltaCSSPixels"] = .int(120)
		expectNoDifference(
			try AutomationTools.operation(name: "browser_scroll", arguments: arguments),
			.scroll(request)
		)
		for value in [Value.string("120"), .bool(true), .null] {
			arguments["deltaCSSPixels"] = value
			#expect(throws: AutomationFailure.invalidRequest) {
				try AutomationTools.operation(name: "browser_scroll", arguments: arguments)
			}
		}
		arguments = Self.arguments(Self.request())
		arguments["axis"] = .string("nearest")
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_scroll", arguments: arguments)
		}
	}

	@Test
	internal func canonicalBindingNormalizesSignedZeroAndSeparatesEveryActionField() async throws {
		let original = Self.request(delta: 0)
		let digest = try #require(AutomationSecurity.mutationBinding(.scroll(original)))
		var changed = original
		changed.deltaCSSPixels = -0.0
		expectNoDifference(digest, AutomationSecurity.mutationBinding(.scroll(changed)))

		// Decoding bypasses the designated initializer; binding still canonicalizes zero.
		let bytes = try JSONEncoder().encode(changed)
		let decoded = try JSONDecoder().decode(AutomationScrollRequest.self, from: bytes)
		expectNoDifference(decoded.canonicalDelta.bitPattern, 0)
		expectNoDifference(digest, AutomationSecurity.mutationBinding(.scroll(decoded)))
		for change in ["axis", "delta", "reference", "snapshot", "target"] {
			changed = original
			switch change {
			case "axis": changed.axis = .horizontal
			case "delta": changed.deltaCSSPixels = 0.25
			case "reference": changed.target.reference += "other"
			case "snapshot": changed.target.snapshotID += "other"
			default: changed.target.targetID = UUID()
			}
			#expect(digest != AutomationSecurity.mutationBinding(.scroll(changed)))
		}
		#expect(digest != AutomationSecurity.mutationBinding(.click(original.target)))
		#expect(digest != AutomationSecurity.mutationBinding(.form(.init(
			target: original.target,
			kind: .selectValue,
			value: "0"
		))))
	}

	@Test(arguments: [AutomationScrollDisposition.notDispatched, .dispatched, .possiblyDispatched, .unchanged])
	internal func receiptsContainNoOffsetsOrReferenceContent(disposition: AutomationScrollDisposition) async throws {
		let result = AutomationScrollResult(operationID: UUID(), disposition: disposition)
		let payload = try BrowserMCPServer.payload(.scroll(result))
		guard case let .object(fields) = payload else {
			Issue.record("Missing scroll payload")
			return
		}
		expectNoDifference(Set(fields.keys), ["kind", "operationID", "disposition", "failure", "navigationCompleted"])
		expectNoDifference(fields["kind"], .string("scroll"))
		expectNoDifference(fields["disposition"], .string(disposition.rawValue))
		expectNoDifference(fields["navigationCompleted"], .bool(false))
	}

	@Test(.timeLimit(.minutes(1)))
	internal func unexpectedReplyAfterExchangePreservesUncertainty() async throws {
		let socket = LocalAutomationSocket()
		let directory = URL(fileURLWithPath: "/tmp/arx-scroll-gateway-" + UUID().uuidString.prefix(8))
		defer {
			do { try FileManager.default.removeItem(at: directory) }
			catch { Issue.record("Gateway fixture cleanup failed") }
		}
		let path = try await socket.start(directory: directory) { envelope in
			if case .hello = envelope.payload { return .hello(UUID()) }
			return .acknowledged
		}
		let gateway = AutomationGateway(path: path, clientID: UUID(), credential: String(repeating: "0", count: 64))
		try await gateway.initialize()
		let request = Self.request()
		let result = await gateway.perform(.scroll(request))
		expectNoDifference(result, .scroll(.init(
			operationID: request.operationID,
			disposition: .possiblyDispatched,
			failure: .invalidRequest
		)))
		await gateway.disconnect()
		await socket.stop()
	}

	internal static func request(
		axis: AutomationScrollRequest.Axis = .vertical,
		delta: Double = 120.5
	) -> AutomationScrollRequest {
		.init(target: AutomationClickTests.request(), axis: axis, deltaCSSPixels: delta)
	}

	private static func arguments(_ request: AutomationScrollRequest) -> [String: Value] {
		[
			"operationID": .string(request.operationID.uuidString),
			"targetID": .string(request.target.targetID.uuidString),
			"expectedRevision": .string(request.target.expectedRevision),
			"snapshotID": .string(request.target.snapshotID),
			"reference": .string(request.target.reference),
			"axis": .string(request.axis.rawValue),
			"deltaCSSPixels": .double(request.deltaCSSPixels),
		]
	}
}
