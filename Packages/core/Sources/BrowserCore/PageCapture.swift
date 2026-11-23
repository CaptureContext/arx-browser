import Foundation

/// Captures bind an existing session revision; focusing another host never retargets them.
public struct PageCaptureRequest: Equatable, Sendable {
	public var tabID: Tab.ID
	public var revision: UInt64
	public var limits: PageCaptureLimits
	public var mode: PageCaptureMode
	public var documentRevision: UInt64?
	public var ordinaryProfileID: Profile.ID?

	/// Captures a page that isn't on screen without showing it.
	public var offscreen: Bool

	/// With `.fullDocument`, renders the whole page beyond the viewport, as DevTools' full size
	/// screenshot does, instead of recording the document (DEV-1172).
	public var beyondViewport: Bool

	public init(
		tabID: Tab.ID,
		revision: UInt64,
		limits: PageCaptureLimits = .init(),
		mode: PageCaptureMode = .viewport,
		documentRevision: UInt64? = nil,
		ordinaryProfileID: Profile.ID? = nil,
		offscreen: Bool = false,
		beyondViewport: Bool = false
	) {
		self.tabID = tabID
		self.revision = revision
		self.limits = limits
		self.mode = mode
		self.documentRevision = documentRevision
		self.ordinaryProfileID = ordinaryProfileID
		self.offscreen = offscreen
		self.beyondViewport = beyondViewport
	}
}

public enum PageCaptureMode: Equatable, Sendable {
	case viewport
	case fullDocument
}

/// Exact laid-out document geometry. Image coordinates start at the document
/// rectangle's origin; the visible viewport and fractional scroll remain separate.
public struct PageCaptureDocumentGeometry: Codable, Equatable, Sendable {
	public var documentRect: PageCaptureRegion
	public var visibleRect: PageCaptureRegion
	public var scrollX: Double
	public var scrollY: Double
	public var zoomLevel: Double
	public var pageScale: Double
	public var rasterScale: Double

	public init(
		documentRect: PageCaptureRegion,
		visibleRect: PageCaptureRegion,
		scrollX: Double,
		scrollY: Double,
		zoomLevel: Double,
		pageScale: Double,
		rasterScale: Double
	) {
		self.documentRect = documentRect
		self.visibleRect = visibleRect
		self.scrollX = scrollX
		self.scrollY = scrollY
		self.zoomLevel = zoomLevel
		self.pageScale = pageScale
		self.rasterScale = rasterScale
	}
}

public struct PageCaptureLimits: Equatable, Sendable {
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

	/// A whole page rendered beyond the viewport (DEV-1172): up to 16384 pixels a side, the
	/// largest texture Apple GPUs take, and 3072 × 16384 pixels in all; a longer page is cut.
	public static let wholePage: Self = .init(
		maximumDimension: 16_384,
		maximumPixels: 50_331_648,
		maximumEncodedBytes: 67_108_864,
		timeoutMilliseconds: 15_000
	)

	public func validate(
		width: Int,
		height: Int,
		encodedBytes: Int = 0
	) throws {
		guard
			(1...16_384).contains(maximumDimension),
			(1...67_108_864).contains(maximumPixels),
			(1...67_108_864).contains(maximumEncodedBytes),
			timeoutMilliseconds > 0,
			timeoutMilliseconds <= 30_000,
			width > 0,
			height > 0,
			encodedBytes >= 0
		else { throw PageCaptureFailure.invalidImage }

		guard
			width <= maximumDimension,
			height <= maximumDimension,
			width <= maximumPixels / height,
			encodedBytes <= maximumEncodedBytes
		else { throw PageCaptureFailure.limitExceeded }
	}
}

public struct PageCaptureImage: Codable, Equatable, Sendable {
	/// Immutable PNG bytes. Saving and cropping never trigger another page capture.
	public var png: Data
	public var width: Int
	public var height: Int

	public init(
		png: Data,
		width: Int,
		height: Int
	) {
		self.png = png
		self.width = width
		self.height = height
	}
}

public struct PageCaptureFrame: Equatable, Sendable {
	public var request: PageCaptureRequest
	public var documentID: String
	public var image: PageCaptureImage
	public var viewportWidth: Double
	public var viewportHeight: Double
	public var deviceScale: Double
	public var wasLoading: Bool
	public var warnings: [PageCaptureWarning]
	public var documentGeometry: PageCaptureDocumentGeometry?

	/// A whole page cut at its limits: the image holds only the top of the page (DEV-1172).
	public var isCut: Bool

	public init(
		request: PageCaptureRequest,
		documentID: String,
		image: PageCaptureImage,
		viewportWidth: Double,
		viewportHeight: Double,
		deviceScale: Double,
		wasLoading: Bool,
		warnings: [PageCaptureWarning] = [],
		documentGeometry: PageCaptureDocumentGeometry? = nil,
		isCut: Bool = false
	) {
		self.request = request
		self.documentID = documentID
		self.image = image
		self.viewportWidth = viewportWidth
		self.viewportHeight = viewportHeight
		self.deviceScale = deviceScale
		self.wasLoading = wasLoading
		self.warnings = warnings
		self.documentGeometry = documentGeometry
		self.isCut = isCut
	}

	/// Point extent of the immutable image, independent of the live viewport.
	public var imagePointWidth: Double { documentGeometry?.documentRect.width ?? viewportWidth }
	public var imagePointHeight: Double { documentGeometry?.documentRect.height ?? viewportHeight }

	public func validate() throws {
		try request.limits.validate(
			width: image.width,
			height: image.height,
			encodedBytes: image.png.count
		)

		guard
			!documentID.isEmpty,
			!image.png.isEmpty,
			viewportWidth.isFinite,
			viewportHeight.isFinite,
			deviceScale.isFinite,
			viewportWidth > 0,
			viewportHeight > 0,
			deviceScale > 0,
			(Double(image.width) / viewportWidth).isFinite,
			(Double(image.height) / viewportHeight).isFinite,
			Double(image.width) / viewportWidth > 0,
			Double(image.height) / viewportHeight > 0
		else { throw PageCaptureFailure.invalidImage }

		switch (request.mode, documentGeometry) {
		case (.viewport, nil):
			break

		case let (.fullDocument, .some(geometry)):
			let rect = geometry.documentRect
			let visible = geometry.visibleRect
			let metrics: [Double] = [
				rect.x, rect.y, rect.width, rect.height,
				visible.x, visible.y, visible.width, visible.height,
				geometry.scrollX, geometry.scrollY,
				geometry.zoomLevel, geometry.pageScale, geometry.rasterScale,
			]

			guard
				metrics.allSatisfy(\.isFinite),
				rect.width > 0,
				rect.height > 0,
				visible.width > 0,
				visible.height > 0,
				geometry.pageScale == 1,
				geometry.rasterScale == 1,
				rect.width == Double(image.width),
				rect.height == Double(image.height)
			else { throw PageCaptureFailure.invalidImage }

		default:
			throw PageCaptureFailure.invalidImage
		}
	}

	/// Input uses top-left image points. A document image begins at its document
	/// rectangle origin, so negative overflow does not become a negative crop.
	/// Output rounds outward to include every selected pixel.
	/// Actual bitmap/viewport ratios handle fractional zoom and device-scale rounding independently.
	public func pixels(in region: PageCaptureRegion) throws -> PageCapturePixels {
		try validate()
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
			region.x + region.width <= imagePointWidth.nextUp,
			region.y + region.height <= imagePointHeight.nextUp
		else { throw PageCaptureFailure.invalidRegion }

		let scaleX = Double(image.width) / imagePointWidth
		let scaleY = Double(image.height) / imagePointHeight
		let x = Int(floor(region.x * scaleX))
		let y = Int(floor(region.y * scaleY))
		let right = min(image.width, Int(ceil((region.x + region.width) * scaleX)))
		let bottom = min(image.height, Int(ceil((region.y + region.height) * scaleY)))
		guard right > x, bottom > y else { throw PageCaptureFailure.invalidRegion }
		return .init(x: x, y: y, width: right - x, height: bottom - y)
	}
}

public struct PageCaptureRegion: Codable, Equatable, Sendable {
	public var x: Double
	public var y: Double
	public var width: Double
	public var height: Double

	public init(
		x: Double,
		y: Double,
		width: Double,
		height: Double
	) {
		self.x = x
		self.y = y
		self.width = width
		self.height = height
	}
}

/// A distance in viewport points: how far to scroll a page, or how far it moved (DEV-1208).
public struct PageCaptureOffset: Codable, Equatable, Sendable {
	public static let zero: Self = .init(x: 0, y: 0)

	public var x: Double
	public var y: Double

	public init(
		x: Double,
		y: Double
	) {
		self.x = x
		self.y = y
	}

	public static func + (lhs: Self, rhs: Self) -> Self {
		.init(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
	}
}

public struct PageCapturePixels: Equatable, Sendable {
	public var x: Int
	public var y: Int
	public var width: Int
	public var height: Int

	public init(
		x: Int,
		y: Int,
		width: Int,
		height: Int
	) {
		self.x = x
		self.y = y
		self.width = width
		self.height = height
	}
}

public enum PageCaptureFormat: Hashable, Sendable {
	case png
	case jpeg(quality: Double)

	public var fileExtension: String {
		switch self {
		case .png: "png"
		case .jpeg: "jpg"
		}
	}
}

public enum PageCaptureWarning: Hashable, Sendable {
	case protectedMediaMayBeMissing

	public var message: String {
		switch self {
		case .protectedMediaMayBeMissing:
			"Protected media may appear blank. Review the preview before saving."
		}
	}
}

public enum PageCaptureFailure: Error, Equatable, LocalizedError, Sendable {
	case unavailable
	case busy
	case staleDocument
	case limitExceeded
	case invalidRegion
	case invalidImage
	case timedOut
	case unsupportedRendering
	case encodingFailed
	case invalidFormat

	public var errorDescription: String? {
		switch self {
		case .unavailable: "Page capture is not available in this engine."
		case .busy: "Another page capture is still finishing. Try again shortly."
		case .staleDocument: "The page changed or closed. Start a new capture."
		case .limitExceeded: "This capture exceeds the image limit. Capture the viewport or a smaller area."
		case .invalidRegion: "Choose an area inside the captured image."
		case .invalidImage: "The engine returned an invalid capture. Try again."
		case .timedOut: "The page did not finish capturing. Try again."
		case .unsupportedRendering: "This page contains rendering that cannot be captured."
		case .encodingFailed: "The image could not be encoded. Try another format."
		case .invalidFormat: "Choose a matching PNG or JPEG file extension and a valid quality."
		}
	}
}
