import BrowserAutomationClient
import BrowserCaptureClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

@testable import BrowserMCPServer

internal struct AutomationPDFTests {
	/// A fixture PDF's text: long enough for several 1 KiB chunks.
	internal static let text: String = (0..<200).map { "ARX_PDF_LINE_\($0)" }.joined(separator: "\n")
	internal static let digest: String = String(repeating: "c", count: 64)

	internal static func result(_ request: AutomationPDFRequest) -> AutomationPDFResult {
		switch request.kind {
		case .export:
			let data = Data("%PDF-1.4 fixture".utf8)
			return .init(
				request: request,
				profileID: .init(rawValue: UUID(0)),
				documentRevision: 8,
				documentID: "document",
				data: data,
				totalBytes: data.count,
				pageCount: 1,
				digest: digest
			)

		case .text:
			let (chunk, next) = PagePDFText.chunk(text, offset: request.offset, maximumBytes: request.maximumBytes)
				?? ("", nil)
			return .init(
				request: request,
				profileID: .init(rawValue: UUID(0)),
				documentRevision: 8,
				documentID: "document",
				text: chunk,
				totalBytes: text.utf8.count,
				nextOffset: next,
				pageCount: 2,
				digest: digest
			)
		}
	}

	@Test
	internal func pdfToolParsesExportAndTextAndRejectsMixedOptions() throws {
		let base: [String: Value] = [
			"targetID": .string(UUID(3).uuidString),
			"expectedRevision": .string(String(repeating: "a", count: 64)),
		]
		var export = base
		export["action"] = .string("export")
		export["landscape"] = .bool(true)
		export["scale"] = .double(0.5)
		let exportRequest = try AutomationTools.pdfRequest(export)
		expectNoDifference(exportRequest.kind, .export)
		expectNoDifference(exportRequest.landscape, true)
		expectNoDifference(exportRequest.scale, 0.5)

		var text = base
		text["action"] = .string("text")
		text["limit"] = .int(2048)
		expectNoDifference(try AutomationTools.pdfRequest(text).maximumBytes, 2048)

		for (key, value): (String, Value) in [
			("landscape", .bool(true)),
			("scale", .double(5)),
			("limit", .int(10)),
			("path", .string("/tmp/out.pdf")),
		] {
			var invalid = text
			invalid[key] = value
			#expect(throws: AutomationFailure.invalidRequest) { try AutomationTools.pdfRequest(invalid) }
		}
	}

	@Test
	internal func resultsBindTheirKindAndBounds() throws {
		let request = AutomationPDFRequest(
			targetID: UUID(3),
			expectedRevision: String(repeating: "a", count: 64),
			kind: .text,
			maximumBytes: 1024
		)
		let result = Self.result(request)
		try result.validate()
		#expect(result.nextOffset != nil)
		#expect(result.text?.hasSuffix("\n") == true)

		var foreign = result
		foreign.data = Data("%PDF".utf8)
		#expect(throws: AutomationFailure.invalidRequest) { try foreign.validate() }

		var oversized = Self.result(.init(targetID: UUID(3), expectedRevision: request.expectedRevision, kind: .export))
		oversized.data = Data(repeating: 1, count: AutomationPDFRequest.maximumExportBytes + 1)
		oversized.totalBytes = oversized.data?.count ?? 0
		#expect(throws: AutomationFailure.limitExceeded) { try oversized.validate() }

		// The export travels as an application/pdf resource in the image frame.
		let exported = Self.result(.init(targetID: UUID(3), expectedRevision: request.expectedRevision, kind: .export))
		let response = try BrowserMCPServer.toolResult(.pdf(exported))
		guard case let .resource(resource, _, _) = response.content.last
		else { throw AutomationFailure.invalidRequest }
		expectNoDifference(resource.mimeType, "application/pdf")
		expectNoDifference(resource.blob.flatMap { Data(base64Encoded: $0) }, exported.data)
		expectNoDifference(AutomationIPC.maximumResponseBytes(for: .pdf(exported)), AutomationIPC.maximumImageResponseBytes)
	}

	@Test
	internal func pdfTextChunksCoverTheDocument() throws {
		var offset = 0
		var rebuilt = ""
		while true {
			let (chunk, next) = try #require(PagePDFText.chunk(Self.text, offset: offset, maximumBytes: 1024))
			rebuilt += chunk
			guard let next else { break }
			offset = next
		}
		expectNoDifference(rebuilt, Self.text)
		#expect(PagePDFText.chunk(Self.text, offset: Self.text.utf8.count + 1, maximumBytes: 1024) == nil)
		#expect(PagePDFText.extract(Data("<html>".utf8)) == nil)
	}

	@Test
	internal func findInPageIsAnInteractionThatNeedsApproval() throws {
		let arguments: [String: Value] = [
			"targetID": .string(UUID(3).uuidString),
			"expectedRevision": .string(String(repeating: "a", count: 64)),
			"text": .string("needle"),
			"direction": .string("previous"),
		]
		guard case let .findInPage(request) = try AutomationTools.operation(name: "browser_find_in_page", arguments: arguments)
		else { throw AutomationFailure.invalidRequest }

		expectNoDifference(request.text, "needle")
		expectNoDifference(request.forward, false)
		let operation = AutomationOperation.findInPage(request)
		expectNoDifference(operation.riskTier, .mutate)
		expectNoDifference(operation.requiredCapabilities, [.read, .pageContent, .interact])
		expectNoDifference(AutomationTools.requiredCapabilities(forTool: "browser_find_in_page"), [.read, .pageContent, .interact])

		var stopWithText = arguments
		stopWithText["stop"] = .bool(true)
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_find_in_page", arguments: stopWithText)
		}
	}

	@Test
	internal func elementAndOffscreenCapturesParse() throws {
		let arguments: [String: Value] = [
			"targetID": .string(UUID(3).uuidString),
			"expectedRevision": .string(String(repeating: "a", count: 64)),
			"mode": .string("element"),
			"snapshotID": .string("snapshot"),
			"reference": .string("opaque"),
			"offscreen": .bool(true),
		]
		guard case let .capture(request) = try AutomationTools.operation(name: "browser_capture", arguments: arguments)
		else { throw AutomationFailure.invalidRequest }

		expectNoDifference(request.element, .init(snapshotID: "snapshot", reference: "opaque"))
		expectNoDifference(request.offscreen, true)

		var missingReference = arguments
		missingReference["reference"] = nil
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_capture", arguments: missingReference)
		}
		var offscreenDocument = arguments
		offscreenDocument["mode"] = .string("fullDocument")
		offscreenDocument["snapshotID"] = nil
		offscreenDocument["reference"] = nil
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(name: "browser_capture", arguments: offscreenDocument)
		}
	}
}
