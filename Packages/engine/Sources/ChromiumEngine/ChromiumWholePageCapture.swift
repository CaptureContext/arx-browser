import ChromiumBridge
import Darwin
import Foundation

/// `ArxEngineCaptureWholePage` and `ArxEngineCancelWholePageCapture` (DEV-1172): the whole page,
/// rendered beyond the viewport the way DevTools' "Capture full size screenshot" renders it, so
/// frames, video, canvas and WebGL come out as they show on screen. Outside the ABI table: engines
/// built before it lack them, and `supportsWholePageCapture` is false there.
internal struct ChromiumWholePageCaptureFunctions {
	internal var capture: ArxEngineCaptureWholePageFunction
	internal var cancel: ArxEngineCancelWholePageCaptureFunction

	internal init(
		capture: ArxEngineCaptureWholePageFunction,
		cancel: ArxEngineCancelWholePageCaptureFunction
	) {
		self.capture = capture
		self.cancel = cancel
	}

	internal static func load(_ handle: UnsafeMutableRawPointer) -> Self? {
		guard
			let capture = dlsym(handle, "ArxEngineCaptureWholePage"),
			let cancel = dlsym(handle, "ArxEngineCancelWholePageCapture")
		else { return nil }

		return .init(
			capture: unsafeBitCast(capture, to: ArxEngineCaptureWholePageFunction.self),
			cancel: unsafeBitCast(cancel, to: ArxEngineCancelWholePageCaptureFunction.self)
		)
	}
}

/// Physical pixels. A page taller or wider than `maximumDimension` is cut there, and one over
/// `maximumPixels` shorter still; the capture says so (`ChromiumCapture.isCut`).
public struct ChromiumWholePageLimits: Equatable, Sendable {
	/// The largest texture side Apple GPUs take.
	public static let largestDimension: Int = 16_384

	public var maximumDimension: Int
	public var maximumPixels: Int
	public var maximumEncodedBytes: Int
	public var timeoutMilliseconds: Int

	/// 3072 × 16384 pixels: a whole 16384-pixel height for pages up to 1536 points wide on a
	/// Retina display.
	public init(
		maximumDimension: Int = Self.largestDimension,
		maximumPixels: Int = 50_331_648,
		maximumEncodedBytes: Int = 67_108_864,
		timeoutMilliseconds: Int = 15_000
	) {
		self.maximumDimension = maximumDimension
		self.maximumPixels = maximumPixels
		self.maximumEncodedBytes = maximumEncodedBytes
		self.timeoutMilliseconds = timeoutMilliseconds
	}

	internal func native() throws -> ArxPageCaptureLimits {
		guard
			(1...Self.largestDimension).contains(maximumDimension),
			(1...67_108_864).contains(maximumPixels),
			(1...67_108_864).contains(maximumEncodedBytes),
			(1...30_000).contains(timeoutMilliseconds)
		else { throw ChromiumCaptureFailure.invalidImage }

		return .init(
			maximum_dimension: UInt32(maximumDimension),
			maximum_pixels: UInt64(maximumPixels),
			maximum_encoded_bytes: UInt64(maximumEncodedBytes),
			timeout_ms: UInt32(timeoutMilliseconds)
		)
	}
}

extension ChromiumCapture {
	/// The image starts at the document's top-left corner. Its geometry is in layout pixels, one
	/// image pixel each, like ABI16's document capture: the visible area and scroll are scaled from
	/// DIP by the device scale.
	internal init(
		native: ArxPageCaptureSnapshot,
		limits: ChromiumWholePageLimits
	) throws {
		let metrics: [Double] = [
			native.document_width,
			native.document_height,
			native.captured_width,
			native.captured_height,
			native.scroll_x,
			native.scroll_y,
			native.viewport_width,
			native.viewport_height,
			native.device_scale,
			native.zoom_level,
		]
		guard
			let document = native.document_id,
			let bytes = native.png,
			native.png_size > 0,
			native.width > 0,
			native.height > 0,
			metrics.allSatisfy(\.isFinite),
			native.device_scale > 0,
			native.viewport_width > 0,
			native.viewport_height > 0,
			native.captured_width > 0,
			native.captured_height > 0,
			native.captured_width <= native.document_width,
			native.captured_height <= native.document_height
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

		let scale = native.device_scale
		self.documentID = documentID
		self.png = Data(bytes: bytes, count: native.png_size)
		self.width = Int(native.width)
		self.height = Int(native.height)
		self.viewportWidth = native.viewport_width
		self.viewportHeight = native.viewport_height
		self.deviceScale = scale
		self.wasLoading = native.was_loading
		self.documentGeometry = .init(
			documentX: 0,
			documentY: 0,
			documentWidth: Double(native.width),
			documentHeight: Double(native.height),
			visibleX: native.scroll_x * scale,
			visibleY: native.scroll_y * scale,
			visibleWidth: native.viewport_width * scale,
			visibleHeight: native.viewport_height * scale,
			scrollX: native.scroll_x * scale,
			scrollY: native.scroll_y * scale,
			zoomLevel: native.zoom_level,
			pageScale: 1,
			rasterScale: 1
		)
		self.isCut = native.cut
	}
}

/// A whole-page capture in flight, resumed once.
internal struct WholePageCaptureRequest {
	internal var page: UInt64
	internal var limits: ChromiumWholePageLimits
	internal var continuation: CheckedContinuation<ChromiumCapture, any Error>

	internal init(
		page: UInt64,
		limits: ChromiumWholePageLimits,
		continuation: CheckedContinuation<ChromiumCapture, any Error>
	) {
		self.page = page
		self.limits = limits
		self.continuation = continuation
	}
}

extension ChromiumRuntime {
	/// Whether this engine renders whole pages beyond the viewport (DEV-1172).
	public var supportsWholePageCapture: Bool {
		state == .running && optionalExports.wholePageCapture != nil
	}

	/// The whole page of a shown page, cut at `limits`. The page lays out at its whole height for
	/// one frame and goes back to its own size; it sees the resize.
	public func captureWholePage(
		_ page: ChromiumPage,
		limits: ChromiumWholePageLimits = .init()
	) async throws -> ChromiumCapture {
		try Task.checkCancellation()
		guard
			state == .running,
			let functions = optionalExports.wholePageCapture
		else { throw ChromiumCaptureFailure.unavailable }
		guard pages[page.id] === page
		else { throw ChromiumCaptureFailure.staleDocument }

		let nativeLimits = try limits.native()
		let request = nextRequest
		nextRequest += 1
		let context = Unmanaged.passUnretained(self).toOpaque()

		let capture: ChromiumCapture = try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				guard !Task.isCancelled else {
					continuation.resume(throwing: CancellationError())
					return
				}

				wholePageCaptures[request] = .init(
					page: page.id,
					limits: limits,
					continuation: continuation
				)
				let started = withUnsafePointer(to: nativeLimits) { limits in
					functions.capture(
						page.id,
						request,
						limits,
						{ context, request, status, snapshot in
							guard let context else { return }

							MainActor.assumeIsolated {
								Unmanaged<ChromiumRuntime>.fromOpaque(context)
									.takeUnretainedValue()
									.completeWholePageCapture(request, status: status, snapshot: snapshot?.pointee)
							}
						},
						context
					)
				}

				// Refused outright: the engine never calls back.
				guard
					!started,
					let pending = wholePageCaptures.removeValue(forKey: request)
				else { return }

				pending.continuation.resume(throwing: ChromiumCaptureFailure.unavailable)
			}
		} onCancel: { [weak self] in
			Task { @MainActor [weak self] in
				self?.cancelWholePageCapture(request)
			}
		}

		try Task.checkCancellation()
		return capture
	}

	internal func completeWholePageCapture(
		_ request: UInt64,
		status: ArxCaptureStatus,
		snapshot: ArxPageCaptureSnapshot?
	) {
		guard let pending = wholePageCaptures.removeValue(forKey: request)
		else { return }

		do {
			guard pages[pending.page] != nil
			else { throw ChromiumCaptureFailure.staleDocument }
			if status == ARX_CAPTURE_CANCELLED { throw CancellationError() }
			guard status == ARX_CAPTURE_SUCCESS
			else { throw ChromiumCaptureFailure(status: status) }
			guard let snapshot
			else { throw ChromiumCaptureFailure.invalidImage }

			pending.continuation.resume(returning: try .init(native: snapshot, limits: pending.limits))
		} catch {
			pending.continuation.resume(throwing: error)
		}
	}

	internal func cancelWholePageCapture(_ request: UInt64) {
		guard let pending = wholePageCaptures.removeValue(forKey: request)
		else { return }

		pending.continuation.resume(throwing: CancellationError())
		guard state == .running else { return }

		optionalExports.wholePageCapture?.cancel(request)
	}

	/// A closed page's captures end as stale; the engine still drains its own work.
	internal func staleWholePageCaptures(of page: UInt64) {
		for request in wholePageCaptures.filter({ $0.value.page == page }).keys {
			guard let pending = wholePageCaptures.removeValue(forKey: request)
			else { continue }

			pending.continuation.resume(throwing: ChromiumCaptureFailure.staleDocument)
			optionalExports.wholePageCapture?.cancel(request)
		}
	}
}
