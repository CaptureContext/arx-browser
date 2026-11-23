import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

@testable import BrowserMCPServer

internal struct AutomationCaptureTests {
	@Test
	internal func oldClientGrantsNeverEnableScreenshots() async throws {
		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		var values = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(client)) as? [String: Any])
		values.removeValue(forKey: "allowsScreenshots")
		let restored = try JSONDecoder().decode(AutomationClient.self, from: JSONSerialization.data(withJSONObject: values))
		expectNoDifference(restored, client)
		expectNoDifference(restored.allowsScreenshots, false)
	}

	@Test
	internal func regionParserAcceptsIntegerAndFractionalPointsAndRejectsExtraAuthority() async throws {
		let request = Self.result().request
		var arguments: [String: Value] = [
			"targetID": .string(request.targetID.uuidString),
			"expectedRevision": .string(request.expectedRevision),
			"mode": .string("region"),
			"region": .object(["x": .int(0), "y": .double(0.5), "width": .int(1), "height": .int(1)]),
		]
		expectNoDifference(
			try AutomationTools.operation(name: "browser_capture", arguments: arguments),
			.capture(.init(
				targetID: request.targetID,
				expectedRevision: request.expectedRevision,
				mode: .region,
				region: .init(x: 0, y: 0.5, width: 1, height: 1)
			))
		)
		for (key, value): (String, Value) in [
			("mode", .string("fullDocument")),
			("region", .object(["x": .int(0), "y": .int(0), "width": .int(0), "height": .int(1)])),
			("region", .object(["x": .int(0), "y": .int(0), "width": .double(.infinity), "height": .int(1)])),
			("region", .object(["x": .int(0), "y": .int(0), "width": .int(1), "height": .int(1), "frameID": .int(1)])),
			("region", .object(["x": .double(.nan), "y": .int(0), "width": .int(1), "height": .int(1)])),
			("region", .object(["x": .int(-1), "y": .int(0), "width": .int(1), "height": .int(1)])),
			("focus", .bool(true)),
		] {
			var invalid = arguments
			invalid[key] = value
			#expect(throws: AutomationFailure.invalidRequest) {
				try AutomationTools.operation(name: "browser_capture", arguments: invalid)
			}
		}
		arguments["mode"] = .string("viewport")
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_capture", arguments: arguments)
		}
	}

	@Test(arguments: [false, true])
	internal func nativeEpochInvalidatesOnlyScreenshotInventory(allowsScreenshots: Bool) async throws {
		let organization = BrowserAutomationTests.organization()
		var client = BrowserAutomationTests.client(organization)
		client.allowsScreenshots = allowsScreenshots
		let tab = organization.tabs[0]
		let before = BrowserSessionSnapshot(navigation: .init(url: tab.restoration.url), revision: 3, documentRevision: 8)
		var after = before
		after.documentRevision = 9
		let old = AutomationInventoryBuilder.items(client: client, organization: organization, snapshots: [tab.id: before])
		let current = AutomationInventoryBuilder.items(
			client: client,
			organization: organization,
			snapshots: [tab.id: after]
		)
		expectNoDifference(old.last?.revision != current.last?.revision, allowsScreenshots)
		expectNoDifference(old.last?.url, current.last?.url)
	}

	@Test
	internal func fullDocumentIsAdvertisedAndPreservesGeometryWithoutViewportSubstitution() async throws {
		let definition = try #require(AutomationTools.definitions.first { $0.name == "browser_capture" })
		let schema = try JSONEncoder().encode(definition.inputSchema)
		#expect(String(decoding: schema, as: UTF8.self).contains("fullDocument"))
		var capture = Self.result()
		capture.request.mode = .fullDocument
		capture.viewportWidth = 900
		capture.viewportHeight = 700
		let geometry = PageCaptureDocumentGeometry(
			documentRect: .init(x: -2, y: 0, width: 1, height: 1),
			visibleRect: .init(x: 0, y: 0, width: 900, height: 700),
			scrollX: 0.5,
			scrollY: 1100.25,
			zoomLevel: 1.25,
			pageScale: 1,
			rasterScale: 1
		)
		capture.documentGeometry = geometry
		var arguments: [String: Value] = [
			"targetID": .string(capture.request.targetID.uuidString),
			"expectedRevision": .string(capture.request.expectedRevision),
			"mode": .string("fullDocument"),
		]
		expectNoDifference(try AutomationTools.operation(name: "browser_capture", arguments: arguments), .capture(capture.request))
		let response = try BrowserMCPServer.toolResult(.capture(capture))
		expectNoDifference(response.isError, false)
		guard
			case let .object(envelope) = response.structuredContent,
			case let .object(metadata) = envelope["result"]
		else { throw AutomationFailure.invalidRequest }
		expectNoDifference(metadata["documentGeometry"], try Value(geometry))
		expectNoDifference(metadata["viewportWidth"], .double(900))
		expectNoDifference(metadata["height"], .int(1))
		arguments["region"] = .object(["x": .int(0), "y": .int(0), "width": .int(1), "height": .int(1)])
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_capture", arguments: arguments)
		}
		capture.documentGeometry = nil
		expectNoDifference(try BrowserMCPServer.toolResult(.capture(capture)).isError, true)
	}

	@Test
	internal func imageAppearsOnceAndOversizedResultBecomesBoundedError() async throws {
		let capture = Self.result()
		let response = try BrowserMCPServer.toolResult(.capture(capture))
		expectNoDifference(response.isError, false)
		expectNoDifference(response.content.count, 2)
		guard case let .image(data, mimeType, _, _) = response.content[1] else {
			Issue.record("Missing MCP image content")
			return
		}
		expectNoDifference(Data(base64Encoded: data), capture.image.data)
		expectNoDifference(mimeType, "image/png")
		let encoded = try JSONEncoder().encode(response)
		#expect(encoded.count < AutomationIPC.maximumResponseBytes)
		let metadata = try JSONEncoder().encode(response.structuredContent)
		#expect(!String(decoding: metadata, as: UTF8.self).contains(data))

		for extraBytes in [0, 1] {
			var oversized = capture
			oversized.image.data = Data(repeating: 255, count: AutomationCaptureResult.maximumImageBytes + extraBytes)
			let denied = try BrowserMCPServer.toolResult(.capture(oversized))
			expectNoDifference(denied.isError, true)
			expectNoDifference(denied.content.count, 1)
			#expect(try JSONEncoder().encode(denied).count < 1024)
		}
	}

	@Test
	internal func saveIsAFlagAndTheAgentCanNeverNameAPath() async throws {
		let request = Self.result().request
		let arguments: [String: Value] = [
			"targetID": .string(request.targetID.uuidString),
			"expectedRevision": .string(request.expectedRevision),
			"mode": .string("viewport"),
			"save": .bool(true),
		]
		var saving = request
		saving.save = true
		expectNoDifference(
			try AutomationTools.operation(name: "browser_capture", arguments: arguments),
			.capture(saving)
		)
		for (key, value): (String, Value) in [
			("save", .string("/Users/someone/Desktop/capture.png")),
			("save", .object(["path": .string("/tmp")])),
			("path", .string("/tmp/capture.png")),
			("destination", .string("~/Desktop")),
			("fileName", .string("capture.png")),
		] {
			var invalid = arguments
			invalid[key] = value
			#expect(throws: AutomationFailure.invalidRequest) {
				try AutomationTools.operation(name: "browser_capture", arguments: invalid)
			}
		}
	}

	@Test
	internal func savedCapturesReportOnlyTheFileName() async throws {
		var request = Self.result().request
		request.save = true
		var saved = Self.result(request: request)
		saved.save = .saved(fileName: "Fixture Page.png")
		let response = try BrowserMCPServer.toolResult(.capture(saved))
		expectNoDifference(response.isError, false)
		let metadata = String(decoding: try JSONEncoder().encode(response.structuredContent), as: UTF8.self)
		#expect(metadata.contains("Fixture Page.png"))
		#expect(metadata.contains("\"saved\""))

		var declined = saved
		declined.save = .declined
		let declinedResponse = try BrowserMCPServer.toolResult(.capture(declined))
		expectNoDifference(declinedResponse.isError, false)
		let declinedMetadata = String(decoding: try JSONEncoder().encode(declinedResponse.structuredContent), as: UTF8.self)
		#expect(declinedMetadata.contains("\"declined\""))

		// A result must answer a save request, and only with a bare file name.
		for outcome: AutomationCaptureResult.SaveOutcome? in [
			nil, .saved(fileName: ""), .saved(fileName: "Folder/capture.png"), .saved(fileName: ".."),
		] {
			var invalid = saved
			invalid.save = outcome
			#expect(throws: AutomationFailure.invalidRequest) { try invalid.validate() }
		}
		var unrequested = Self.result()
		unrequested.save = .declined
		#expect(throws: AutomationFailure.invalidRequest) { try unrequested.validate() }
	}

	/// A region capture stands in for a large image, above the old 256 KiB frame.
	internal static let largeImageBytes: Int = 1_048_576

	internal static func result(request: AutomationCaptureRequest? = nil) -> AutomationCaptureResult {
		let request = request ?? .init(
			targetID: UUID(3),
			expectedRevision: String(repeating: "a", count: 64),
			mode: .viewport
		)
		var result = Self.pngResult(request: request)
		if request.format == .jpeg {
			result.image = .init(data: Data([0xFF, 0xD8, 0xFF, 0xD9]), format: .jpeg, width: 1, height: 1)
		} else if request.mode == .region {
			result.image.data = Data(repeating: 0x41, count: largeImageBytes)
		}
		return result
	}

	private static func pngResult(request: AutomationCaptureRequest) -> AutomationCaptureResult {
		.init(
			request: request,
			profileID: .init(rawValue: UUID(0)),
			sessionRevision: 3,
			documentRevision: 8,
			documentID: "fixture-document",
			snapshotID: UUID(9),
			image: .init(
				data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!,
				format: .png,
				width: 1,
				height: 1
			),
			viewportWidth: 1,
			viewportHeight: 1,
			deviceScale: 1,
			wasLoading: false
		)
	}
}
