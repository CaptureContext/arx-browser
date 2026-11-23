import Foundation

/// An explicit read of one existing permitted page; it never changes presentation.
public struct AutomationCaptureRequest: Codable, Equatable, Sendable {
	public var targetID: UUID
	public var expectedRevision: String
	public var mode: Mode
	public var region: PageCaptureRegion?

	/// Downscales the captured pixels; 1 keeps them as they are.
	public var scale: Double
	public var format: Format

	/// JPEG quality from 0 to 1. Only JPEG accepts it.
	public var quality: Double?

	/// For `.element`: a reference from this connection's latest snapshot read with bounds.
	public var element: Element?

	/// Captures a page that isn't on screen without showing, focusing or selecting it.
	public var offscreen: Bool

	/// After capturing, asks the person in Arx where to save the image.
	/// The agent can't name the destination and learns only the file name.
	public var save: Bool

	public init(
		targetID: UUID,
		expectedRevision: String,
		mode: Mode,
		region: PageCaptureRegion? = nil,
		scale: Double = 1,
		format: Format = .png,
		quality: Double? = nil,
		element: Element? = nil,
		offscreen: Bool = false,
		save: Bool = false
	) {
		self.targetID = targetID
		self.expectedRevision = expectedRevision
		self.mode = mode
		self.region = region
		self.scale = scale
		self.format = format
		self.quality = quality
		self.element = element
		self.offscreen = offscreen
		self.save = save
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.targetID = try container.decode(UUID.self, forKey: .targetID)
		self.expectedRevision = try container.decode(String.self, forKey: .expectedRevision)
		self.mode = try container.decode(Mode.self, forKey: .mode)
		self.region = try container.decodeIfPresent(PageCaptureRegion.self, forKey: .region)
		self.scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
		self.format = try container.decodeIfPresent(Format.self, forKey: .format) ?? .png
		self.quality = try container.decodeIfPresent(Double.self, forKey: .quality)
		self.element = try container.decodeIfPresent(Element.self, forKey: .element)
		self.offscreen = try container.decodeIfPresent(Bool.self, forKey: .offscreen) ?? false
		self.save = try container.decodeIfPresent(Bool.self, forKey: .save) ?? false
	}

	/// Whether the native frame is delivered unchanged.
	public var keepsNativeEncoding: Bool { scale == 1 && format == .png }

	public func validate() throws {
		let hasValidQuality = quality.map { $0.isFinite && (0...1).contains($0) } ?? true
		guard
			expectedRevision.utf8.count == 64,
			expectedRevision.allSatisfy(\.isHexDigit),
			(mode == .region) == (region != nil),
			(mode == .element) == (element != nil),
			element.map({ !$0.snapshotID.isEmpty && $0.snapshotID.utf8.count <= 128 }) ?? true,
			element.map({ !$0.reference.isEmpty && $0.reference.utf8.count <= 128 }) ?? true,
			// An offscreen page has no full-document recording.
			!offscreen || mode != .fullDocument,
			scale.isFinite,
			(0.1...1).contains(scale),
			quality == nil || format == .jpeg,
			hasValidQuality
		else { throw AutomationFailure.invalidRequest }

		if let region {
			guard
				region.x.isFinite,
				region.y.isFinite,
				region.width.isFinite,
				region.height.isFinite,
				region.x >= 0,
				region.y >= 0,
				region.width > 0,
				region.height > 0,
				region.x + region.width > region.x,
				region.y + region.height > region.y,
				region.x + region.width <= 8_192,
				region.y + region.height <= 8_192
			else { throw AutomationFailure.invalidRequest }
		}
	}

	public enum Mode: String, Codable, Sendable {
		case viewport
		case region
		case fullDocument

		/// The bounds a snapshot reported for one reference, clamped to the viewport.
		case element
	}

	public struct Element: Codable, Equatable, Sendable {
		public var snapshotID: String
		public var reference: String

		public init(
			snapshotID: String,
			reference: String
		) {
			self.snapshotID = snapshotID
			self.reference = reference
		}
	}

	public enum Format: String, Codable, CaseIterable, Sendable {
		case png
		case jpeg

		public var mimeType: String {
			switch self {
			case .png: "image/png"
			case .jpeg: "image/jpeg"
			}
		}
	}
}

/// The delivered image, encoded as the request asked.
public struct AutomationCaptureImage: Codable, Equatable, Sendable {
	public var data: Data
	public var format: AutomationCaptureRequest.Format
	public var width: Int
	public var height: Int

	public init(
		data: Data,
		format: AutomationCaptureRequest.Format,
		width: Int,
		height: Int
	) {
		self.data = data
		self.format = format
		self.width = width
		self.height = height
	}

	public init(_ image: PageCaptureImage) {
		self.init(
			data: image.png,
			format: .png,
			width: image.width,
			height: image.height
		)
	}
}

public struct AutomationCaptureResult: Codable, Equatable, Sendable {
	/// Leaves room for base64 and metadata within the image transport frame.
	public static let maximumImageBytes: Int = 4_194_304

	public var request: AutomationCaptureRequest
	public var profileID: Profile.ID
	public var sessionRevision: UInt64
	public var documentRevision: UInt64
	public var documentID: String
	public var snapshotID: UUID
	public var image: AutomationCaptureImage
	public var viewportWidth: Double
	public var viewportHeight: Double
	public var deviceScale: Double
	public var wasLoading: Bool
	public var documentGeometry: PageCaptureDocumentGeometry?

	/// The viewport region an element capture used.
	public var elementRegion: PageCaptureRegion?

	/// What the person did with the save panel when the request asked to save.
	public var save: SaveOutcome?

	public init(
		request: AutomationCaptureRequest,
		profileID: Profile.ID,
		sessionRevision: UInt64,
		documentRevision: UInt64,
		documentID: String,
		snapshotID: UUID,
		image: AutomationCaptureImage,
		viewportWidth: Double,
		viewportHeight: Double,
		deviceScale: Double,
		wasLoading: Bool,
		documentGeometry: PageCaptureDocumentGeometry? = nil,
		elementRegion: PageCaptureRegion? = nil,
		save: SaveOutcome? = nil
	) {
		self.request = request
		self.profileID = profileID
		self.sessionRevision = sessionRevision
		self.documentRevision = documentRevision
		self.documentID = documentID
		self.snapshotID = snapshotID
		self.image = image
		self.viewportWidth = viewportWidth
		self.viewportHeight = viewportHeight
		self.deviceScale = deviceScale
		self.wasLoading = wasLoading
		self.documentGeometry = documentGeometry
		self.elementRegion = elementRegion
		self.save = save
	}

	public func validate() throws {
		try request.validate()
		guard image.data.count <= Self.maximumImageBytes
		else { throw AutomationFailure.limitExceeded }
		guard
			image.format == request.format,
			(request.mode == .element) == (elementRegion != nil),
			request.save == (save != nil),
			save?.isValid ?? true,
			documentRevision > 0,
			!documentID.isEmpty,
			documentID.utf8.count <= 128,
			!image.data.isEmpty,
			(1...8_192).contains(image.width),
			(1...8_192).contains(image.height),
			image.width <= 16_777_216 / image.height,
			viewportWidth.isFinite,
			viewportHeight.isFinite,
			deviceScale.isFinite,
			viewportWidth > 0,
			viewportHeight > 0,
			deviceScale > 0
		else { throw AutomationFailure.invalidRequest }

		if request.mode == .fullDocument, !request.keepsNativeEncoding {
			// The pixels were scaled or re-encoded, so only their size is checked
			// against the native document extent.
			guard let rect = documentGeometry?.documentRect
			else { throw AutomationFailure.invalidRequest }

			let isScaledExtent = abs(Double(image.width) - (rect.width * request.scale).rounded()) <= 1
			&& abs(Double(image.height) - (rect.height * request.scale).rounded()) <= 1

			guard isScaledExtent else { throw AutomationFailure.invalidRequest }

		} else if request.mode == .fullDocument {
			do {
				try PageCaptureFrame(
					request: .init(
						tabID: .init(rawValue: request.targetID),
						revision: sessionRevision,
						mode: .fullDocument
					),
					documentID: documentID,
					image: .init(png: image.data, width: image.width, height: image.height),
					viewportWidth: viewportWidth,
					viewportHeight: viewportHeight,
					deviceScale: deviceScale,
					wasLoading: wasLoading,
					documentGeometry: documentGeometry
				).validate()
			} catch {
				throw AutomationFailure.invalidRequest
			}

		} else if documentGeometry != nil {
			throw AutomationFailure.invalidRequest
		}
	}
}

extension AutomationCaptureResult {
	/// The person's answer to the save panel. A saved capture reports only the
	/// file name it was written under, never its folder.
	public enum SaveOutcome: Codable, Equatable, Sendable {
		case saved(fileName: String)

		/// The person cancelled the panel; nothing was written.
		case declined

		public var fileName: String? {
			guard case let .saved(fileName) = self else { return nil }
			return fileName
		}

		internal var isValid: Bool {
			guard let fileName else { return true }
			return !fileName.isEmpty
			&& fileName.utf8.count <= 255
			&& !fileName.contains("/")
			&& !fileName.contains(":")
			&& fileName != "."
			&& fileName != ".."
		}
	}
}
