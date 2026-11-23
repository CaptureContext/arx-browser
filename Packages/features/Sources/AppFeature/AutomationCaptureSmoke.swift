#if DEBUG
import BrowserCaptureClient
import BrowserCore
import Foundation
import _MCP

/// Parses the public MCP image envelope without relying on private IPC result fields.
internal enum AutomationCaptureSmoke {
	internal enum Reply {
		case image(Snapshot)
		case failure(AutomationFailure)
	}

	internal struct Snapshot: Equatable {
		internal var metadata: Metadata
		internal var image: PageCaptureImage

		internal init(
			metadata: Metadata,
			image: PageCaptureImage
		) {
			self.metadata = metadata
			self.image = image
		}
	}

	internal struct Metadata: Decodable, Equatable {
		internal let kind: String
		internal let targetID: UUID
		internal let expectedRevision: String
		internal let sessionRevision: String
		internal let documentRevision: String
		internal let profileID: UUID
		internal let documentID: String
		internal let snapshotID: UUID
		internal let mode: AutomationCaptureRequest.Mode
		internal let region: PageCaptureRegion?
		internal let width: Int
		internal let height: Int
		internal let viewportWidth: Double
		internal let viewportHeight: Double
		internal let deviceScale: Double
		internal let wasLoading: Bool
		internal let warnings: [String]
		internal let documentGeometry: PageCaptureDocumentGeometry?

		internal init(
			kind: String,
			targetID: UUID,
			expectedRevision: String,
			sessionRevision: String,
			documentRevision: String,
			profileID: UUID,
			documentID: String,
			snapshotID: UUID,
			mode: AutomationCaptureRequest.Mode,
			region: PageCaptureRegion?,
			width: Int,
			height: Int,
			viewportWidth: Double,
			viewportHeight: Double,
			deviceScale: Double,
			wasLoading: Bool,
			warnings: [String],
			documentGeometry: PageCaptureDocumentGeometry? = nil
		) {
			self.kind = kind
			self.targetID = targetID
			self.expectedRevision = expectedRevision
			self.sessionRevision = sessionRevision
			self.documentRevision = documentRevision
			self.profileID = profileID
			self.documentID = documentID
			self.snapshotID = snapshotID
			self.mode = mode
			self.region = region
			self.width = width
			self.height = height
			self.viewportWidth = viewportWidth
			self.viewportHeight = viewportHeight
			self.deviceScale = deviceScale
			self.wasLoading = wasLoading
			self.warnings = warnings
			self.documentGeometry = documentGeometry
		}
	}

	internal static func decode(_ result: CallTool.Result) throws -> Reply {
		guard try JSONEncoder().encode(result).count <= 262_144
		else { throw AutomationSmokeFailure.invalidResponse }

		if result.isError == true {
			guard case let .failure(failure) = try AutomationSmokeResponse.decode(result)
			else { throw AutomationSmokeFailure.invalidResponse }
			return .failure(failure)
		}
		guard
			result.isError == false,
			result.content.count == 2,
			case let .text(text, _, _) = result.content[0],
			case let .image(encoded, type, _, _) = result.content[1],
			type == "image/png",
			let png = Data(base64Encoded: encoded),
			png.count <= AutomationCaptureResult.maximumImageBytes,
			let structured = result.structuredContent,
			try JSONDecoder().decode(Value.self, from: Data(text.utf8)) == structured
		else { throw AutomationSmokeFailure.invalidResponse }

		let envelope = try JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
		let metadata = envelope.result
		guard
			envelope.untrustedData,
			metadata.kind == "capture",
			metadata.expectedRevision.utf8.count == 64,
			metadata.expectedRevision.allSatisfy(\.isHexDigit),
			UInt64(metadata.sessionRevision) != nil,
			(UInt64(metadata.documentRevision) ?? 0) > 0,
			!metadata.documentID.isEmpty,
			metadata.documentID.utf8.count <= 128,
			metadata.viewportWidth.isFinite,
			metadata.viewportHeight.isFinite,
			metadata.deviceScale.isFinite,
			metadata.viewportWidth > 0,
			metadata.viewportHeight > 0,
			metadata.deviceScale > 0,
			metadata.warnings == ["protectedMediaMayBeMissing"]
		else { throw AutomationSmokeFailure.invalidResponse }

		let image = PageCaptureImage(png: png, width: metadata.width, height: metadata.height)
		_ = try PageCaptureCodec.decode(image)
		return .image(.init(metadata: metadata, image: image))
	}

	internal static func verify(
		_ reply: Reply,
		request: AutomationCaptureRequest,
		profileID: Profile.ID
	) throws -> Snapshot {
		guard case let .image(snapshot) = reply else {
			throw AutomationSmokeMismatch(
				.captureMismatch,
				check: "mcpCapture.reply",
				expected: "image",
				actual: "\(reply)"
			)
		}

		let metadata = snapshot.metadata
		try AutomationSmokeMismatch.require("mcpCapture.targetID", metadata.targetID, equals: request.targetID)
		try AutomationSmokeMismatch.require(
			"mcpCapture.expectedRevision",
			metadata.expectedRevision,
			equals: request.expectedRevision
		)
		try AutomationSmokeMismatch.require("mcpCapture.profileID", metadata.profileID, equals: profileID.rawValue)
		try AutomationSmokeMismatch.require("mcpCapture.mode", metadata.mode, equals: request.mode)
		try AutomationSmokeMismatch.require("mcpCapture.region", metadata.region, equals: request.region)
		try AutomationSmokeMismatch.require("mcpCapture.wasLoading", metadata.wasLoading, equals: false)
		return snapshot
	}

	internal static func verifyDocument(_ snapshot: Snapshot) throws {
		try AutomationSmokeMismatch.require("mcpDocument.mode", snapshot.metadata.mode, equals: .fullDocument)
		guard let geometry = snapshot.metadata.documentGeometry else {
			throw AutomationSmokeMismatch(
				.captureMismatch,
				check: "mcpDocument.geometry",
				expected: "present",
				actual: "nil"
			)
		}

		try AutomationSmokeMismatch.require(
			"mcpDocument.viewportHeight",
			snapshot.metadata.viewportHeight < 1800,
			expected: "<1800",
			actual: "\(snapshot.metadata.viewportHeight)"
		)

		try verifyDocument(
			image: snapshot.image,
			geometry: geometry,
			deviceScale: snapshot.metadata.deviceScale
		)
	}

	internal static func verifyDocument(
		image: PageCaptureImage,
		geometry: PageCaptureDocumentGeometry,
		deviceScale: Double
	) throws {
		try verifyDocumentGeometry(
			width: image.width,
			height: image.height,
			geometry: geometry,
			deviceScale: deviceScale
		)
		let image = try PageCaptureCodec.decode(image)
		let patches: [CaptureSmokePixels.Patch] = [
			.init(x: 900 * deviceScale, y: 300 * deviceScale, red: 255, green: 0, blue: 0),
			.init(x: 900 * deviceScale, y: 900 * deviceScale, red: 0, green: 255, blue: 0),
			.init(x: 900 * deviceScale, y: 1500 * deviceScale, red: 0, green: 0, blue: 255),
		]
		for patch in patches {
			try CaptureSmokePixels.expect(image, x: Int(patch.x), y: Int(patch.y), patch: patch)
		}
	}

	/// This owned page has 1800 CSS pixels in each dimension, three 600-CSS-
	/// pixel bands, no page zoom, and CSS scroll (125,300). Native layout pixels
	/// include the current backing scale; rasterScale remains independently 1.
	internal static func verifyDocumentGeometry(
		width: Int,
		height: Int,
		geometry: PageCaptureDocumentGeometry,
		deviceScale: Double
	) throws {
		let expectedDocumentRect: PageCaptureRegion = .init(
			x: 0,
			y: 0,
			width: 1800 * deviceScale,
			height: 1800 * deviceScale
		)
		try AutomationSmokeMismatch.require(
			"documentGeometry.deviceScale",
			deviceScale.isFinite && deviceScale > 0 && deviceScale <= 2,
			expected: "(0,2]",
			actual: "\(deviceScale)"
		)
		try AutomationSmokeMismatch.require(
			"documentGeometry.documentRect",
			geometry.documentRect,
			equals: expectedDocumentRect
		)
		try AutomationSmokeMismatch.require("documentGeometry.scrollX", geometry.scrollX, equals: 125 * deviceScale)
		try AutomationSmokeMismatch.require("documentGeometry.scrollY", geometry.scrollY, equals: 300 * deviceScale)
		try AutomationSmokeMismatch.require("documentGeometry.zoomLevel", geometry.zoomLevel, equals: 0)
		try AutomationSmokeMismatch.require("documentGeometry.pageScale", geometry.pageScale, equals: 1)
		try AutomationSmokeMismatch.require("documentGeometry.rasterScale", geometry.rasterScale, equals: 1)
		try AutomationSmokeMismatch.require("documentGeometry.width", width, equals: Int(1800 * deviceScale))
		try AutomationSmokeMismatch.require("documentGeometry.height", height, equals: Int(1800 * deviceScale))
	}

	internal static func verifyPixels(
		_ snapshot: Snapshot,
		region: Bool
	) throws {
		let image = try PageCaptureCodec.decode(snapshot.image)
		let patches: [CaptureSmokePixels.Patch] = region
		? [.init(x: 10, y: 10, red: 0, green: 0, blue: 255)]
		: [
			.init(x: 50, y: 50, red: 255, green: 0, blue: 0),
			.init(x: 150, y: 50, red: 0, green: 255, blue: 0),
			.init(x: 50, y: 150, red: 0, green: 0, blue: 255),
			.init(x: 260, y: 40, red: 255, green: 0, blue: 255),
			.init(x: 50, y: 260, red: 0, green: 255, blue: 255),
		]
		let width = region ? 20 : snapshot.metadata.viewportWidth
		let height = region ? 20 : snapshot.metadata.viewportHeight
		for patch in patches {
			try CaptureSmokePixels.expect(
				image,
				x: Int(floor(patch.x * Double(image.width) / width)),
				y: Int(floor(patch.y * Double(image.height) / height)),
				patch: patch
			)
		}
	}

	private struct Envelope: Decodable {
		internal let untrustedData: Bool
		internal let result: Metadata

		internal init(
			untrustedData: Bool,
			result: Metadata
		) {
			self.untrustedData = untrustedData
			self.result = result
		}
	}
}
#endif
