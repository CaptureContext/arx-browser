import ChromiumBridge
import Foundation

/// ABI26. What a PDF read produces.
public enum ChromiumPDFKind: Sendable {
	/// The page printed to PDF. The page receives beforeprint and afterprint.
	case export(ChromiumPDFOptions)

	/// The bytes of a page that shows a PDF document, from the cache when present.
	case source
}

public struct ChromiumPDFOptions: Equatable, Sendable {
	public var landscape: Bool
	public var printsBackground: Bool

	/// 0.1 to 2; nil keeps 1.
	public var scale: Double?

	/// Inches; nil keeps US Letter.
	public var paperWidth: Double?
	public var paperHeight: Double?

	public init(
		landscape: Bool = false,
		printsBackground: Bool = false,
		scale: Double? = nil,
		paperWidth: Double? = nil,
		paperHeight: Double? = nil
	) {
		self.landscape = landscape
		self.printsBackground = printsBackground
		self.scale = scale
		self.paperWidth = paperWidth
		self.paperHeight = paperHeight
	}

	internal func native() throws -> ArxPdfOptions {
		let isValid = (scale.map { $0.isFinite && (0.1...2).contains($0) } ?? true)
		&& (paperWidth.map { $0.isFinite && (1...100).contains($0) } ?? true)
		&& (paperHeight.map { $0.isFinite && (1...100).contains($0) } ?? true)
		guard isValid else { throw ChromiumPDFFailure.invalidRequest }

		return .init(
			landscape: landscape,
			print_background: printsBackground,
			allows_private: false,
			scale: scale ?? 0,
			paper_width: paperWidth ?? 0,
			paper_height: paperHeight ?? 0
		)
	}
}

public struct ChromiumPDF: Equatable, Sendable {
	public var documentID: String
	public var data: Data

	public init(
		documentID: String,
		data: Data
	) {
		self.documentID = documentID
		self.data = data
	}
}

public enum ChromiumPDFFailure: Error, Equatable, Sendable {
	case unavailable
	case unsupportedDocument
	case staleDocument
	case limitExceeded
	case failed
	case busy
	case invalidRequest
	case timedOut

	internal init(status: ArxPdfStatus) {
		self = switch status {
		case ARX_PDF_UNAVAILABLE: .unavailable
		case ARX_PDF_UNSUPPORTED: .unsupportedDocument
		case ARX_PDF_STALE: .staleDocument
		case ARX_PDF_LIMIT: .limitExceeded
		case ARX_PDF_BUSY: .busy
		case ARX_PDF_INVALID: .invalidRequest
		case ARX_PDF_TIMEOUT: .timedOut
		default: .failed
		}
	}
}

/// Pending PDF requests. Each native request replies once.
@MainActor
internal final class ChromiumPDFs {
	private let api: ArxEngineAPI
	private var nextRequest: UInt64 = 1
	private var requests: [UInt64: Request] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal var isAvailable: Bool { api.request_pdf != nil && api.cancel_pdf != nil }

	internal func request(
		page: UInt64,
		kind: ChromiumPDFKind,
		maximumBytes: Int,
		timeoutMilliseconds: Int,
		allowsPrivate: Bool = false
	) async throws -> ChromiumPDF {
		try Task.checkCancellation()
		guard let start = api.request_pdf
		else { throw ChromiumPDFFailure.unavailable }
		guard
			(1...33_554_432).contains(maximumBytes),
			(1...30_000).contains(timeoutMilliseconds),
			requests.count < 4,
			nextRequest < UInt64.max
		else { throw ChromiumPDFFailure.invalidRequest }

		var options: ArxPdfOptions
		let nativeKind: ArxPdfKind
		switch kind {
		case let .export(value):
			options = try value.native()
			nativeKind = ARX_PDF_EXPORT

		case .source:
			options = try ChromiumPDFOptions().native()
			nativeKind = ARX_PDF_SOURCE
		}

		// ABI56 (DEV-971): only the app's own Print and Save as PDF read a private page.
		options.allows_private = allowsPrivate

		let id = nextRequest
		nextRequest += 1
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				guard !Task.isCancelled else {
					continuation.resume(throwing: CancellationError())
					return
				}

				requests[id] = .init(page: page, maximumBytes: maximumBytes, continuation: continuation)
				start(page, id, nativeKind, options, UInt32(maximumBytes), UInt32(timeoutMilliseconds))
			}
		} onCancel: {
			Task { @MainActor [weak self] in self?.cancel(id) }
		}
	}

	internal func complete(
		_ id: UInt64,
		page: UInt64,
		status: ArxPdfStatus,
		documentID: UnsafePointer<CChar>?,
		bytes: UnsafePointer<UInt8>?,
		count: Int
	) {
		guard let request = requests.removeValue(forKey: id)
		else { return }

		do {
			guard request.page == page
			else { throw ChromiumPDFFailure.staleDocument }
			if status == ARX_PDF_CANCELLED { throw CancellationError() }
			guard status == ARX_PDF_SUCCESS
			else { throw ChromiumPDFFailure(status: status) }
			guard
				let documentID,
				let bytes,
				count > 0
			else { throw ChromiumPDFFailure.failed }
			guard count <= request.maximumBytes
			else { throw ChromiumPDFFailure.limitExceeded }

			let document = String(cString: documentID)
			guard !document.isEmpty
			else { throw ChromiumPDFFailure.failed }

			request.continuation.resume(returning: .init(documentID: document, data: Data(bytes: bytes, count: count)))
		} catch {
			request.continuation.resume(throwing: error)
		}
	}

	internal func remove(page: UInt64) {
		for id in requests.keys.filter({ requests[$0]?.page == page }) {
			cancel(id, failure: ChromiumPDFFailure.staleDocument)
		}
	}

	internal func stop() {
		for id in Array(requests.keys) {
			cancel(id, failure: ChromiumPDFFailure.unavailable)
		}
	}

	private func cancel(
		_ id: UInt64,
		failure: any Error = CancellationError()
	) {
		guard let request = requests.removeValue(forKey: id)
		else { return }

		api.cancel_pdf?(id)
		request.continuation.resume(throwing: failure)
	}

	private struct Request {
		internal let page: UInt64
		internal let maximumBytes: Int
		internal let continuation: CheckedContinuation<ChromiumPDF, any Error>

		internal init(
			page: UInt64,
			maximumBytes: Int,
			continuation: CheckedContinuation<ChromiumPDF, any Error>
		) {
			self.page = page
			self.maximumBytes = maximumBytes
			self.continuation = continuation
		}
	}
}
