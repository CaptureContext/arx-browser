import BrowserCore
import Foundation
import _Dependencies

public struct BrowserCaptureClient: Sendable {
	public var fullDocumentIsAvailable: @MainActor @Sendable () -> Bool

	/// Whether the engine renders whole pages beyond the viewport, for requests with
	/// `beyondViewport` (DEV-1172).
	public var wholePageIsAvailable: @MainActor @Sendable () -> Bool
	public var isAvailable: @MainActor @Sendable () -> Bool
	public var captureAuthorized: @MainActor @Sendable (
		PageCaptureRequest,
		@escaping @MainActor @Sendable () -> Bool
	) async throws -> PageCaptureFrame
	public var crop: @Sendable (PageCaptureFrame, PageCaptureRegion) throws -> PageCaptureImage

	/// Whether Capture Area can scroll the page while an area is drawn (DEV-1208).
	public var scrollIsAvailable: @MainActor @Sendable () -> Bool

	/// Scrolls the request's page by an offset in viewport points and says how far it moved, which
	/// is less at the page's ends (DEV-1208). Only the page's own scroll moves, not a box inside it.
	/// `.busy` and `.unavailable` mean the page didn't move, as for a pinched page or one the engine
	/// can't run scripts in; any other failure may have come after it moved.
	public var scrollAuthorized: @MainActor @Sendable (
		PageCaptureRequest,
		PageCaptureOffset,
		@escaping @MainActor @Sendable () -> Bool
	) async throws -> PageCaptureOffset

	/// Puts a captured image in a device on a gradient (DEV-757).
	public var frame: @Sendable (PageCaptureImage, DeviceCaptureStyle) throws -> PageCaptureImage
	public var offscreenIsAvailable: @MainActor @Sendable () -> Bool
	public var pdfIsAvailable: @MainActor @Sendable () -> Bool

	/// Prints a page to PDF or reads the PDF document it shows.
	public var pdfAuthorized: @MainActor @Sendable (
		PagePDFRequest,
		@escaping @MainActor @Sendable () -> Bool
	) async throws -> PagePDF

	public init(
		fullDocumentIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		wholePageIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		isAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		offscreenIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		pdfIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		pdfAuthorized: @escaping @MainActor @Sendable (
			PagePDFRequest,
			@escaping @MainActor @Sendable () -> Bool
		) async throws -> PagePDF = { _, _ in throw PageCaptureFailure.unavailable },
		captureAuthorized: @escaping @MainActor @Sendable (
			PageCaptureRequest,
			@escaping @MainActor @Sendable () -> Bool
		) async throws -> PageCaptureFrame = { _, _ in throw PageCaptureFailure.unavailable },
		crop: @escaping @Sendable (PageCaptureFrame, PageCaptureRegion) throws -> PageCaptureImage = {
			try PageCaptureCodec.crop($0, to: $1)
		},
		scrollIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		scrollAuthorized: @escaping @MainActor @Sendable (
			PageCaptureRequest,
			PageCaptureOffset,
			@escaping @MainActor @Sendable () -> Bool
		) async throws -> PageCaptureOffset = { _, _, _ in throw PageCaptureFailure.unavailable },
		frame: @escaping @Sendable (PageCaptureImage, DeviceCaptureStyle) throws -> PageCaptureImage = {
			try PageCaptureCodec.frame($0, in: $1)
		}
	) {
		self.fullDocumentIsAvailable = fullDocumentIsAvailable
		self.wholePageIsAvailable = wholePageIsAvailable
		self.isAvailable = isAvailable
		self.captureAuthorized = captureAuthorized
		self.crop = crop
		self.scrollIsAvailable = scrollIsAvailable
		self.scrollAuthorized = scrollAuthorized
		self.frame = frame
		self.offscreenIsAvailable = offscreenIsAvailable
		self.pdfIsAvailable = pdfIsAvailable
		self.pdfAuthorized = pdfAuthorized
	}

	@MainActor
	public func capture(_ request: PageCaptureRequest) async throws -> PageCaptureFrame {
		try await captureAuthorized(request, { true })
	}
}

extension BrowserCaptureClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init() }
	public static var previewValue: Self { .init() }
}

extension DependencyValues {
	public var browserCapture: BrowserCaptureClient {
		get { self[BrowserCaptureClient.self] }
		set { self[BrowserCaptureClient.self] = newValue }
	}
}
