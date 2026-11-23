#if DEBUG
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP

@testable import AppFeature

@Suite(.dependencies)
internal struct AutomationCaptureSmokeTests {
	@Test
	internal func publicImageEnvelopeChecksPixelsAndMetadataAgreement() throws {
		let result = try response()
		guard case let .image(snapshot) = try AutomationCaptureSmoke.decode(result) else {
			Issue.record("Fixture omitted its image")
			return
		}
		expectNoDifference(snapshot.image.width, 1)
		expectNoDifference(snapshot.image.height, 1)
		expectNoDifference(snapshot.metadata.documentID, "controlled-document")
		let request = AutomationCaptureRequest(
			targetID: snapshot.metadata.targetID,
			expectedRevision: String(repeating: "a", count: 64),
			mode: .viewport
		)
		expectNoDifference(
			try AutomationCaptureSmoke.verify(
				.image(snapshot),
				request: request,
				profileID: .init(rawValue: snapshot.metadata.profileID)
			),
			snapshot
		)
		#expect {
			try AutomationCaptureSmoke.verify(.image(snapshot), request: request, profileID: .init(rawValue: UUID()))
		} throws: { isMismatch($0, check: "mcpCapture.profileID") }
	}

	@Test
	internal func documentEnvelopeRetainsGeometryAndRejectsViewportPixelsAsFullDocument() async throws {
		let geometry = PageCaptureDocumentGeometry(
			documentRect: .init(x: -2, y: 0, width: 1, height: 1),
			visibleRect: .init(x: 0, y: 0, width: 900, height: 700),
			scrollX: 125.25,
			scrollY: 1100.5,
			zoomLevel: 1.25,
			pageScale: 1,
			rasterScale: 1
		)
		let decoded = try AutomationCaptureSmoke.decode(response(mode: .fullDocument, geometry: geometry))
		guard case let .image(snapshot) = decoded
		else { throw AutomationSmokeFailure.captureMismatch }
		expectNoDifference(snapshot.metadata.documentGeometry, geometry)
		expectNoDifference(snapshot.metadata.mode, .fullDocument)
		#expect {
			try AutomationCaptureSmoke.verifyDocument(snapshot)
		} throws: { isMismatch($0, check: "documentGeometry.documentRect") }
	}

	@Test(arguments: [1.0, 2.0])
	internal func documentGeometryUsesActualLayoutBackingScale(deviceScale: Double) throws {
		let extent = 1800 * deviceScale
		let geometry = PageCaptureDocumentGeometry(
			documentRect: .init(x: 0, y: 0, width: extent, height: extent),
			visibleRect: .init(x: 0, y: 300 * deviceScale, width: 900 * deviceScale, height: 700 * deviceScale),
			scrollX: 125 * deviceScale,
			scrollY: 300 * deviceScale,
			zoomLevel: 0,
			pageScale: 1,
			rasterScale: 1
		)
		try AutomationCaptureSmoke.verifyDocumentGeometry(
			width: Int(extent),
			height: Int(extent),
			geometry: geometry,
			deviceScale: deviceScale
		)
		var wrong = geometry
		wrong.scrollY = 300 / deviceScale
		wrong.documentRect.height = 1800 / deviceScale
		#expect {
			try AutomationCaptureSmoke.verifyDocumentGeometry(
				width: 1800,
				height: 1800,
				geometry: wrong,
				deviceScale: 2
			)
		} throws: { isMismatch($0, check: "documentGeometry.documentRect") }
		wrong = geometry
		wrong.documentRect.width *= 2
		wrong.documentRect.height *= 2
		#expect {
			try AutomationCaptureSmoke.verifyDocumentGeometry(
				width: Int(extent * 2),
				height: Int(extent * 2),
				geometry: wrong,
				deviceScale: deviceScale
			)
		} throws: { isMismatch($0, check: "documentGeometry.documentRect") }
		wrong = geometry
		wrong.rasterScale = deviceScale == 1 ? 2 : deviceScale
		#expect {
			try AutomationCaptureSmoke.verifyDocumentGeometry(
				width: Int(extent),
				height: Int(extent),
				geometry: wrong,
				deviceScale: deviceScale
			)
		} throws: { isMismatch($0, check: "documentGeometry.rasterScale") }
	}

	@Test(arguments: ["structure", "bytes", "dimensions", "mime", "duplicates", "oversize"])
	internal func malformedImageEnvelopeCannotSatisfyNativeGate(change: String) throws {
		let original = try response(width: change == "dimensions" ? 2 : 1)
		var content = original.content
		var structured = original.structuredContent
		switch change {
		case "structure":
			structured = .object([:])

		case "bytes":
			let data = Data([1, 2, 3]).base64EncodedString()
			content[1] = .image(data: data, mimeType: "image/png", annotations: nil, _meta: nil)

		case "mime":
			content[1] = .image(data: "", mimeType: "image/jpeg", annotations: nil, _meta: nil)

		case "duplicates":
			content.append(content[1])

		case "oversize":
			let data = Data(repeating: 255, count: 262_144).base64EncodedString()
			content[1] = .image(data: data, mimeType: "image/png", annotations: nil, _meta: nil)

		default:
			break
		}
		let result = CallTool.Result(content: content, structuredContent: structured, isError: false)
		#expect(throws: (any Error).self) { try AutomationCaptureSmoke.decode(result) }
	}

	private func isMismatch(
		_ error: any Error,
		check: String
	) -> Bool {
		guard let mismatch = error as? AutomationSmokeMismatch else { return false }

		return mismatch.failure == .captureMismatch && mismatch.check == check
	}

	private func response(
		width: Int = 1,
		mode: AutomationCaptureRequest.Mode = .viewport,
		geometry: PageCaptureDocumentGeometry? = nil
	) throws -> CallTool.Result {
		let value: Value = .object([
			"untrustedData": .bool(true),
			"result": .object([
				"kind": .string("capture"),
				"targetID": .string(UUID().uuidString),
				"expectedRevision": .string(String(repeating: "a", count: 64)),
				"sessionRevision": .string("3"),
				"documentRevision": .string("8"),
				"profileID": .string(UUID().uuidString),
				"documentID": .string("controlled-document"),
				"snapshotID": .string(UUID().uuidString),
				"mode": .string(mode.rawValue),
				"documentGeometry": try geometry.map { try Value($0) } ?? .null,
				"region": .null,
				"width": .int(width),
				"height": .int(1),
				"viewportWidth": .double(1),
				"viewportHeight": .double(1),
				"deviceScale": .double(1),
				"wasLoading": .bool(false),
				"warnings": .array([.string("protectedMediaMayBeMissing")]),
			]),
		])
		let encoded = try JSONEncoder().encode(value)
		let wireValue = try JSONDecoder().decode(Value.self, from: encoded)
		return .init(
			content: [
				.text(text: String(decoding: encoded, as: UTF8.self), annotations: nil, _meta: nil),
				.image(
					data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
					mimeType: "image/png",
					annotations: nil,
					_meta: nil
				),
			],
			structuredContent: Optional(wireValue),
			isError: false
		)
	}
}
#endif
