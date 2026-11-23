import ChromiumBridge
import Foundation

public struct ChromiumCaptureLimits: Equatable, Sendable {
	public var maximumDimension: Int
	public var maximumPixels: Int
	public var maximumEncodedBytes: Int
	public var timeoutMilliseconds: Int

	public init(
		maximumDimension: Int = 8_192,
		maximumPixels: Int = 16_777_216,
		maximumEncodedBytes: Int = 67_108_864,
		timeoutMilliseconds: Int = 3_000
	) {
		self.maximumDimension = maximumDimension
		self.maximumPixels = maximumPixels
		self.maximumEncodedBytes = maximumEncodedBytes
		self.timeoutMilliseconds = timeoutMilliseconds
	}

	internal func native() throws -> ArxCaptureLimits {
		guard
			(1...8_192).contains(maximumDimension),
			(1...16_777_216).contains(maximumPixels),
			(1...67_108_864).contains(maximumEncodedBytes),
			(1...10_000).contains(timeoutMilliseconds)
		else { throw ChromiumCaptureFailure.invalidImage }

		return .init(
			maximum_dimension: UInt32(maximumDimension),
			maximum_pixels: UInt32(maximumPixels),
			maximum_encoded_bytes: UInt32(maximumEncodedBytes),
			timeout_ms: UInt32(timeoutMilliseconds)
		)
	}
}

public struct ChromiumCapture: Equatable, Sendable {
	public var documentID: String
	public var png: Data
	public var width: Int
	public var height: Int
	public var viewportWidth: Double
	public var viewportHeight: Double
	public var deviceScale: Double
	public var wasLoading: Bool
	public var documentGeometry: ChromiumDocumentCaptureGeometry?

	/// DEV-1172: a whole-page capture cut at its limits, so the image holds only the top of the page.
	public var isCut: Bool = false

	internal init(
		native: ArxCaptureSnapshot,
		limits: ChromiumCaptureLimits
	) throws {
		guard
			let document = native.document_id,
			let bytes = native.png,
			native.png_size > 0,
			native.width > 0,
			native.height > 0,
			native.viewport_width.isFinite,
			native.viewport_width > 0,
			native.viewport_height.isFinite,
			native.viewport_height > 0,
			native.device_scale.isFinite,
			native.device_scale > 0
		else { throw ChromiumCaptureFailure.invalidImage }
		guard
			native.png_size <= limits.maximumEncodedBytes,
			native.width <= limits.maximumDimension,
			native.height <= limits.maximumDimension,
			Int(native.width) <= limits.maximumPixels / Int(native.height)
		else { throw ChromiumCaptureFailure.limitExceeded }

		let documentID = String(cString: document)
		guard !documentID.isEmpty
		else { throw ChromiumCaptureFailure.invalidImage }

		self.documentID = documentID
		self.png = Data(bytes: bytes, count: native.png_size)
		self.width = Int(native.width)
		self.height = Int(native.height)
		self.viewportWidth = native.viewport_width
		self.viewportHeight = native.viewport_height
		self.deviceScale = native.device_scale
		self.wasLoading = native.was_loading
		self.documentGeometry = nil
	}
}

public struct ChromiumDocumentCaptureGeometry: Equatable, Sendable {
	public var documentX: Double
	public var documentY: Double
	public var documentWidth: Double
	public var documentHeight: Double
	public var visibleX: Double
	public var visibleY: Double
	public var visibleWidth: Double
	public var visibleHeight: Double
	public var scrollX: Double
	public var scrollY: Double
	public var zoomLevel: Double
	public var pageScale: Double
	public var rasterScale: Double

	internal init(
		documentX: Double,
		documentY: Double,
		documentWidth: Double,
		documentHeight: Double,
		visibleX: Double,
		visibleY: Double,
		visibleWidth: Double,
		visibleHeight: Double,
		scrollX: Double,
		scrollY: Double,
		zoomLevel: Double,
		pageScale: Double,
		rasterScale: Double
	) {
		self.documentX = documentX
		self.documentY = documentY
		self.documentWidth = documentWidth
		self.documentHeight = documentHeight
		self.visibleX = visibleX
		self.visibleY = visibleY
		self.visibleWidth = visibleWidth
		self.visibleHeight = visibleHeight
		self.scrollX = scrollX
		self.scrollY = scrollY
		self.zoomLevel = zoomLevel
		self.pageScale = pageScale
		self.rasterScale = rasterScale
	}

	internal init(native: ArxDocumentCaptureSnapshot) throws {
		let values: [Double] = [
			native.document_x,
			native.document_y,
			native.document_width,
			native.document_height,
			native.visible_x,
			native.visible_y,
			native.visible_width,
			native.visible_height,
			native.scroll_x,
			native.scroll_y,
			native.zoom_level,
			native.page_scale,
			native.raster_scale
		]
		guard
			values.allSatisfy(\.isFinite),
			native.document_width == Double(native.width),
			native.document_height == Double(native.height),
			native.visible_width > 0,
			native.visible_height > 0,
			native.page_scale == 1,
			native.raster_scale == 1
		else { throw ChromiumCaptureFailure.invalidImage }

		self.documentX = native.document_x
		self.documentY = native.document_y
		self.documentWidth = native.document_width
		self.documentHeight = native.document_height
		self.visibleX = native.visible_x
		self.visibleY = native.visible_y
		self.visibleWidth = native.visible_width
		self.visibleHeight = native.visible_height
		self.scrollX = native.scroll_x
		self.scrollY = native.scroll_y
		self.zoomLevel = native.zoom_level
		self.pageScale = native.page_scale
		self.rasterScale = native.raster_scale
	}
}

extension ChromiumCapture {
	internal init(
		native: ArxDocumentCaptureSnapshot,
		limits: ChromiumCaptureLimits
	) throws {
		// Validate untrusted geometry before copying borrowed image bytes.
		let geometry = try ChromiumDocumentCaptureGeometry(native: native)
		let snapshot = ArxCaptureSnapshot(
			document_id: native.document_id,
			png: native.png,
			png_size: native.png_size,
			width: native.width,
			height: native.height,
			viewport_width: native.viewport_width,
			viewport_height: native.viewport_height,
			device_scale: native.device_scale,
			was_loading: native.was_loading
		)
		try self.init(native: snapshot, limits: limits)
		self.documentGeometry = geometry
	}
}

public enum ChromiumCaptureFailure: Error, Equatable, Sendable {
	case unavailable
	case busy
	case staleDocument
	case limitExceeded
	case timedOut
	case unsupportedRendering
	case encodingFailed
	case invalidImage

	internal init(status: ArxCaptureStatus) {
		self = switch status {
		case ARX_CAPTURE_STALE: .staleDocument
		case ARX_CAPTURE_LIMIT: .limitExceeded
		case ARX_CAPTURE_UNAVAILABLE: .unavailable
		case ARX_CAPTURE_TIMEOUT: .timedOut
		case ARX_CAPTURE_UNSUPPORTED: .unsupportedRendering
		case ARX_CAPTURE_ENCODING_FAILED: .encodingFailed
		case ARX_CAPTURE_BUSY: .busy
		default: .invalidImage
		}
	}
}
