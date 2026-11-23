import ChromiumBridge
import CustomDump
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumPDFTests {
	@Test
	internal func exportCopiesBytesAndCarriesOptions() async throws {
		let fixture = PDFFixture()
		let task = Task {
			try await fixture.pdfs.request(
				page: 1,
				kind: .export(.init(landscape: true, printsBackground: true, scale: 0.5)),
				maximumBytes: 1024,
				timeoutMilliseconds: 1000
			)
		}
		let call = try await fixture.nextCall()
		expectNoDifference(call.kind, ARX_PDF_EXPORT)
		expectNoDifference(call.options.landscape, true)
		expectNoDifference(call.options.print_background, true)
		expectNoDifference(call.options.scale, 0.5)
		expectNoDifference(call.options.paper_width, 0)
		fixture.complete(call.request, data: Data("%PDF-1.7".utf8))
		let pdf = try await task.value
		expectNoDifference(pdf.documentID, "document")
		expectNoDifference(pdf.data, Data("%PDF-1.7".utf8))
	}

	@Test(arguments: [ARX_PDF_UNSUPPORTED, ARX_PDF_LIMIT, ARX_PDF_STALE, ARX_PDF_BUSY])
	internal func nativeFailuresStayDistinct(_ status: ArxPdfStatus) async throws {
		let fixture = PDFFixture()
		let task = Task {
			try await fixture.pdfs.request(page: 1, kind: .source, maximumBytes: 1024, timeoutMilliseconds: 1000)
		}
		let call = try await fixture.nextCall()
		expectNoDifference(call.kind, ARX_PDF_SOURCE)
		fixture.complete(call.request, status: status)
		await #expect(throws: ChromiumPDFFailure(status: status)) { try await task.value }
	}

	@Test
	internal func oversizedOrForeignRepliesAreRejected() async throws {
		let fixture = PDFFixture()
		let oversized = Task {
			try await fixture.pdfs.request(page: 1, kind: .source, maximumBytes: 4, timeoutMilliseconds: 1000)
		}
		let first = try await fixture.nextCall()
		fixture.complete(first.request, data: Data(repeating: 1, count: 5))
		await #expect(throws: ChromiumPDFFailure.limitExceeded) { try await oversized.value }

		let foreign = Task {
			try await fixture.pdfs.request(page: 1, kind: .source, maximumBytes: 1024, timeoutMilliseconds: 1000)
		}
		let second = try await fixture.nextCall()
		fixture.complete(second.request, page: 2, data: Data("%PDF".utf8))
		await #expect(throws: ChromiumPDFFailure.staleDocument) { try await foreign.value }
	}

	@Test
	internal func cancellationAndPageRemovalCancelNatively() async throws {
		let fixture = PDFFixture()
		let cancelled = Task {
			try await fixture.pdfs.request(page: 1, kind: .source, maximumBytes: 1024, timeoutMilliseconds: 1000)
		}
		let first = try await fixture.nextCall()
		cancelled.cancel()
		await #expect(throws: CancellationError.self) { try await cancelled.value }
		expectNoDifference(PDFFixture.cancelled, [first.request])

		let removed = Task {
			try await fixture.pdfs.request(page: 1, kind: .source, maximumBytes: 1024, timeoutMilliseconds: 1000)
		}
		let second = try await fixture.nextCall()
		fixture.pdfs.remove(page: 1)
		await #expect(throws: ChromiumPDFFailure.staleDocument) { try await removed.value }
		expectNoDifference(PDFFixture.cancelled, [first.request, second.request])
	}

	@Test
	internal func invalidOptionsNeverReachNative() async throws {
		let fixture = PDFFixture()
		await #expect(throws: ChromiumPDFFailure.invalidRequest) {
			try await fixture.pdfs.request(
				page: 1,
				kind: .export(.init(scale: 5)),
				maximumBytes: 1024,
				timeoutMilliseconds: 1000
			)
		}
		#expect(PDFFixture.calls.isEmpty)
	}
}

@MainActor
private final class PDFFixture {
	internal static var calls: [Call] = []
	internal static var cancelled: [UInt64] = []
	internal let pdfs: ChromiumPDFs

	internal init() {
		Self.calls = []
		Self.cancelled = []
		var api = ArxEngineAPI()
		api.request_pdf = { page, request, kind, options, _, _ in
			MainActor.assumeIsolated {
				PDFFixture.calls.append(.init(page: page, request: request, kind: kind, options: options))
			}
		}
		api.cancel_pdf = { request in
			MainActor.assumeIsolated { PDFFixture.cancelled.append(request) }
		}
		self.pdfs = .init(api: api)
	}

	internal func nextCall() async throws -> Call {
		for _ in 0..<1_000 {
			if !Self.calls.isEmpty { return Self.calls.removeFirst() }
			await Task.yield()
		}
		throw ChromiumPDFFailure.timedOut
	}

	internal func complete(
		_ request: UInt64,
		page: UInt64 = 1,
		status: ArxPdfStatus = ARX_PDF_SUCCESS,
		data: Data = Data()
	) {
		data.withUnsafeBytes { bytes in
			"document".withCString { document in
				pdfs.complete(
					request,
					page: page,
					status: status,
					documentID: document,
					bytes: bytes.bindMemory(to: UInt8.self).baseAddress,
					count: data.count
				)
			}
		}
	}

	internal struct Call {
		internal let page: UInt64
		internal let request: UInt64
		internal let kind: ArxPdfKind
		internal let options: ArxPdfOptions
	}
}
