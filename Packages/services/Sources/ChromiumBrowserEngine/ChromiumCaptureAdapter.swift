import BrowserCaptureClient
import BrowserCore
import ChromiumEngine
import Foundation

internal enum ChromiumCaptureAdapter {
	@MainActor
	internal static func client(
		fullDocumentIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		captureDocument: @escaping @MainActor @Sendable (
			Tab.ID,
			ChromiumCaptureLimits
		) async throws -> ChromiumCapture = { _, _ in
			throw ChromiumCaptureFailure.unavailable
		},
		wholePageIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		captureWholePage: @escaping @MainActor @Sendable (
			Tab.ID,
			ChromiumWholePageLimits
		) async throws -> ChromiumCapture = { _, _ in
			throw ChromiumCaptureFailure.unavailable
		},
		isAvailable: @escaping @MainActor @Sendable () -> Bool,
		revision: @escaping @MainActor @Sendable (Tab.ID) -> UInt64?,
		documentRevision: @escaping @MainActor @Sendable (Tab.ID) -> UInt64? = { _ in nil },
		isVisible: @escaping @MainActor @Sendable (Tab.ID) -> Bool = { _ in false },
		ordinaryProfileID: @escaping @MainActor @Sendable (Tab.ID) -> Profile.ID? = { _ in nil },
		offscreenIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		captureOffscreen: @escaping @MainActor @Sendable (
			Tab.ID,
			ChromiumCaptureLimits
		) async throws -> ChromiumCapture = { _, _ in
			throw ChromiumCaptureFailure.unavailable
		},
		pdfIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		pdf: @escaping @MainActor @Sendable (
			Tab.ID,
			ChromiumPDFKind,
			Int,
			Bool
		) async throws -> ChromiumPDF = { _, _, _, _ in
			throw ChromiumPDFFailure.unavailable
		},
		scrollIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		pageZoom: @escaping @MainActor @Sendable (Tab.ID) -> Double? = { _ in nil },
		evaluateScroll: @escaping @MainActor @Sendable (
			Tab.ID,
			String
		) async throws -> ChromiumScriptValue = { _, _ in
			throw ChromiumDeveloperFailure.unavailable
		},
		surfaceRetryDelays: [Duration] = ChromiumCaptureAdapter.surfaceRetryDelays,
		capture: @escaping @MainActor @Sendable (
			Tab.ID,
			ChromiumCaptureLimits
		) async throws -> ChromiumCapture
	) -> BrowserCaptureClient {
		.init(
			fullDocumentIsAvailable: fullDocumentIsAvailable,
			wholePageIsAvailable: wholePageIsAvailable,
			isAvailable: isAvailable,
			offscreenIsAvailable: offscreenIsAvailable,
			pdfIsAvailable: pdfIsAvailable,
			pdfAuthorized: { request, authorize in
				try Task.checkCancellation()
				guard isAvailable(), pdfIsAvailable()
				else { throw PageCaptureFailure.unavailable }

				@MainActor
				func isCurrent() -> Bool {
					authorize()
					&& revision(request.tabID) == request.revision
					&& documentRevision(request.tabID) == request.documentRevision
					&& (ordinaryProfileID(request.tabID) != nil || request.allowsPrivate)
				}

				guard isCurrent() else { throw PageCaptureFailure.staleDocument }

				let kind: ChromiumPDFKind = switch request.kind {
				case let .export(landscape, printsBackground, scale, paperWidth, paperHeight):
					.export(.init(
						landscape: landscape,
						printsBackground: printsBackground,
						scale: scale,
						paperWidth: paperWidth,
						paperHeight: paperHeight
					))

				case .source:
					.source
				}
				let result: ChromiumPDF
				do {
					result = try await pdf(request.tabID, kind, request.maximumBytes, request.allowsPrivate)
				} catch let error as ChromiumPDFFailure {
					throw pdfFailure(error)
				}

				try Task.checkCancellation()
				guard isCurrent() else { throw PageCaptureFailure.staleDocument }
				return .init(request: request, documentID: result.documentID, data: result.data)
			},
			captureAuthorized: { request, authorize in
				var retryDelays = surfaceRetryDelays[...]

				// Waiting for a compositor frame spends the request's own timeout, never more.
				let clock = ContinuousClock()
				let deadline = clock.now + .milliseconds(request.limits.timeoutMilliseconds)
				var timeoutMilliseconds = request.limits.timeoutMilliseconds

				// A whole page rendered beyond the viewport (DEV-1172) or ABI16's recorded document.
				let isWholePage = request.mode == .fullDocument && request.beyondViewport

				@MainActor
				func modeIsAvailable() -> Bool {
					switch request.mode {
					case .viewport: true
					case .fullDocument: isWholePage ? wholePageIsAvailable() : fullDocumentIsAvailable()
					}
				}

				while true {
					try Task.checkCancellation()
					guard isAvailable(), modeIsAvailable()
					else { throw PageCaptureFailure.unavailable }

					// The whole page renders only on screen.
					guard !isWholePage || !request.offscreen
					else { throw PageCaptureFailure.unavailable }

					// An offscreen request may read a page that isn't visible; it stays hidden.
					let isOffscreen = request.offscreen && !isVisible(request.tabID)
					guard !isOffscreen || offscreenIsAvailable()
					else { throw PageCaptureFailure.unavailable }
					guard request.ordinaryProfileID == nil || isVisible(request.tabID) || isOffscreen
					else { throw PageCaptureFailure.unavailable }
					guard
						authorize(),
						revision(request.tabID) == request.revision,
						request.documentRevision.map({ $0 > 0 && documentRevision(request.tabID) == $0 }) ?? true,
						request.ordinaryProfileID.map({ ordinaryProfileID(request.tabID) == $0 }) ?? true
					else { throw PageCaptureFailure.staleDocument }

					let limits = request.limits
					let result: ChromiumCapture
					do {
						if isWholePage {
							result = try await captureWholePage(
								request.tabID,
								.init(
									maximumDimension: limits.maximumDimension,
									maximumPixels: limits.maximumPixels,
									maximumEncodedBytes: limits.maximumEncodedBytes,
									timeoutMilliseconds: timeoutMilliseconds
								)
							)
						} else {
							let perform = request.mode == .fullDocument ? captureDocument : isOffscreen ? captureOffscreen : capture
							result = try await perform(
								request.tabID,
								.init(
									maximumDimension: limits.maximumDimension,
									maximumPixels: limits.maximumPixels,
									maximumEncodedBytes: limits.maximumEncodedBytes,
									timeoutMilliseconds: timeoutMilliseconds
								)
							)
						}
					} catch ChromiumCaptureFailure.unavailable
						where !isOffscreen && isVisible(request.tabID)
						&& retryDelays.first.map({ clock.now + $0 < deadline - .milliseconds(1) }) == true
					{
						// The view is on screen, but the compositor hasn't shown or produced a
						// frame for it yet, as right after a page loads or a window comes forward
						// (DEV-711). Wait a moment and check everything again.
						try await Task.sleep(for: retryDelays.removeFirst())

						// A late wake-up, or a Mac that slept, can pass the deadline.
						let remaining = (deadline - clock.now).components
						let milliseconds = Int(remaining.seconds) * 1_000
							+ Int(remaining.attoseconds / 1_000_000_000_000_000)
						guard milliseconds > 0 else { throw PageCaptureFailure.unavailable }
						timeoutMilliseconds = milliseconds
						continue
					} catch let error as ChromiumCaptureFailure {
						throw failure(error)
					}

					try Task.checkCancellation()
					guard isAvailable(), modeIsAvailable()
					else { throw PageCaptureFailure.unavailable }
					guard request.ordinaryProfileID == nil || isVisible(request.tabID) || isOffscreen
					else { throw PageCaptureFailure.unavailable }
					guard
						authorize(),
						revision(request.tabID) == request.revision,
						request.documentRevision.map({ $0 > 0 && documentRevision(request.tabID) == $0 }) ?? true,
						request.ordinaryProfileID.map({ ordinaryProfileID(request.tabID) == $0 }) ?? true
					else { throw PageCaptureFailure.staleDocument }

					let frame = PageCaptureFrame(
						request: request,
						documentID: result.documentID,
						image: .init(
							png: result.png,
							width: result.width,
							height: result.height
						),
						viewportWidth: result.viewportWidth,
						viewportHeight: result.viewportHeight,
						deviceScale: result.deviceScale,
						wasLoading: result.wasLoading,
						warnings: [.protectedMediaMayBeMissing],
						documentGeometry: result.documentGeometry.map { geometry in
							.init(
								documentRect: .init(
									x: geometry.documentX,
									y: geometry.documentY,
									width: geometry.documentWidth,
									height: geometry.documentHeight
								),
								visibleRect: .init(
									x: geometry.visibleX,
									y: geometry.visibleY,
									width: geometry.visibleWidth,
									height: geometry.visibleHeight
								),
								scrollX: geometry.scrollX,
								scrollY: geometry.scrollY,
								zoomLevel: geometry.zoomLevel,
								pageScale: geometry.pageScale,
								rasterScale: geometry.rasterScale
							)
						},
						isCut: result.isCut
					)
					try frame.validate()
					return frame
				}
			},
			scrollIsAvailable: { isAvailable() && scrollIsAvailable() },
			scrollAuthorized: { request, offset, authorize in
				try Task.checkCancellation()
				guard
					isAvailable(),
					scrollIsAvailable(),
					!request.offscreen,
					isVisible(request.tabID)
				else { throw PageCaptureFailure.unavailable }

				@MainActor
				func isCurrent() -> Bool {
					authorize()
					&& revision(request.tabID) == request.revision
					&& request.documentRevision.map({ $0 > 0 && documentRevision(request.tabID) == $0 }) ?? true
					&& request.ordinaryProfileID.map({ ordinaryProfileID(request.tabID) == $0 }) ?? true
				}

				guard isCurrent() else { throw PageCaptureFailure.staleDocument }
				guard
					let zoom = pageZoom(request.tabID),
					let script = scrollScript(offset, zoom: zoom)
				else { throw PageCaptureFailure.unavailable }

				let value: ChromiumScriptValue
				do {
					value = try await evaluateScroll(request.tabID, script)
				} catch let error as ChromiumDeveloperFailure {
					throw scrollFailure(error)
				}

				try Task.checkCancellation()
				guard isCurrent() else { throw PageCaptureFailure.staleDocument }
				return try scrolled(value, zoom: zoom)
			}
		)
	}

	/// How long a capture of a page on screen waits, in turn, for its compositor frame
	/// before it reports the page as not ready: about half a second in all.
	internal static let surfaceRetryDelays: [Duration] = Array(repeating: .milliseconds(50), count: 10)

	/// The most a single scroll moves, in points: a few screens.
	internal static let maximumScroll: Double = 4_096

	/// What `scrollScript` replies, without scrolling, for a page magnified with a pinch.
	internal static let pinchedReply: String = #""pinched""#

	/// Scrolls the page's own scroller by `offset` points, at once whatever the page's
	/// `scroll-behavior`, and replies how far it moved, in CSS pixels (DEV-1208). It runs in Arx's
	/// isolated world, so the page's scripts can't see or replace it. Zoom turns points into CSS
	/// pixels.
	///
	/// A page magnified with a trackpad pinch isn't scrolled: its visual viewport moves the content
	/// by more points than the browser zoom says, and the drawn area and the crop would miss what
	/// was selected. The script replies `pinchedReply` before it scrolls.
	internal static func scrollScript(
		_ offset: PageCaptureOffset,
		zoom: Double
	) -> String? {
		guard
			zoom.isFinite,
			zoom > 0,
			offset.x.isFinite,
			offset.y.isFinite
		else { return nil }

		let x = min(max(offset.x, -maximumScroll), maximumScroll) / zoom
		let y = min(max(offset.y, -maximumScroll), maximumScroll) / zoom
		return """
		if (visualViewport && Math.abs(visualViewport.scale - 1) > 0.001) return "pinched";
		const x = scrollX, y = scrollY;
		scrollBy({ left: \(String(format: "%.4f", x)), top: \(String(format: "%.4f", y)), behavior: "instant" });
		return [scrollX - x, scrollY - y];
		"""
	}

	/// How far the page moved, in points, from `scrollScript`'s reply. A pinched page wasn't
	/// scrolled (`.unavailable`); any other reply that isn't two numbers came after the scroll may
	/// have run (`.invalidImage`).
	internal static func scrolled(
		_ value: ChromiumScriptValue,
		zoom: Double
	) throws -> PageCaptureOffset {
		if case let .json(text) = value, text == pinchedReply {
			throw PageCaptureFailure.unavailable
		}
		guard
			case let .json(text) = value,
			let moved = try? JSONDecoder().decode([Double].self, from: Data(text.utf8)),
			moved.count == 2,
			moved.allSatisfy(\.isFinite)
		else { throw PageCaptureFailure.invalidImage }

		return .init(x: moved[0] * zoom, y: moved[1] * zoom)
	}

	/// `.busy` and `.unavailable` say the script never ran, so the page didn't move: the engine
	/// refused it up front, as for a `file:` page or another document that isn't HTTP(S). Every other
	/// failure may have come after the scroll ran.
	private static func scrollFailure(_ error: ChromiumDeveloperFailure) -> PageCaptureFailure {
		switch error {
		case .busy: .busy
		case .unavailable, .unsupportedDocument, .invalidRequest, .syntax: .unavailable
		case .staleDocument: .staleDocument
		case .timedOut: .timedOut
		case .limitExceeded, .failed, .exception: .invalidImage
		}
	}

	private static func pdfFailure(_ error: ChromiumPDFFailure) -> PageCaptureFailure {
		switch error {
		case .unavailable: .unavailable
		case .unsupportedDocument: .unsupportedRendering
		case .staleDocument: .staleDocument
		case .limitExceeded: .limitExceeded
		case .busy: .busy
		case .timedOut: .timedOut
		case .invalidRequest: .invalidFormat
		case .failed: .encodingFailed
		}
	}

	private static func failure(_ error: ChromiumCaptureFailure) -> PageCaptureFailure {
		switch error {
		case .unavailable: .unavailable
		case .busy: .busy
		case .staleDocument: .staleDocument
		case .limitExceeded: .limitExceeded
		case .timedOut: .timedOut
		case .unsupportedRendering: .unsupportedRendering
		case .encodingFailed: .encodingFailed
		case .invalidImage: .invalidImage
		}
	}
}
