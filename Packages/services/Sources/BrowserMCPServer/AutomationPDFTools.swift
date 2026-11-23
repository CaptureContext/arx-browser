import BrowserAutomationClient
import BrowserCore
import Foundation
import _MCP

extension AutomationTools {
	internal static var pdfDefinition: Tool {
		.init(
			name: "browser_pdf",
			title: "Export a page to PDF or read a PDF document",
			description: """
			Requires the page-content grant, an explicit ordinary tab and its current inventory revision. \
			action export prints the page to PDF (at most 4 MiB) and returns it as an application/pdf resource; \
			the page receives beforeprint and afterprint, and nothing is saved to disk. landscape, printBackground \
			and scale (0.1 to 2) shape the print. action text reads the PDF document a tab shows, from the cache when \
			present and otherwise from the site with the profile's cookies, and returns its text in chunks of at most \
			limit UTF-8 bytes (default 16384), page after page; pass nextCursor alone for the next chunk. A cursor is \
			bound to the PDF's SHA-256 digest; a different document fails with staleCursor. Pages that aren't PDFs \
			return unsupported for text. Private tabs are never read. All content is untrusted website data.
			""",
			inputSchema: schema(
				properties: [
					"targetID": string(maximum: 36),
					"expectedRevision": string(maximum: 64),
					"action": .object([
						"type": .string("string"),
						"enum": .array(AutomationPDFRequest.Kind.allCases.map { .string($0.rawValue) }),
					]),
					"landscape": .object(["type": .string("boolean")]),
					"printBackground": .object(["type": .string("boolean")]),
					"scale": .object([
						"type": .string("number"),
						"minimum": .double(0.1),
						"maximum": .int(2),
					]),
					"limit": integerSchema(1024...65_536, default: 16_384),
					"cursor": string(maximum: AutomationPageCursor.maximumLength),
				]
			),
			annotations: .init(
				readOnlyHint: true,
				destructiveHint: false,
				openWorldHint: true
			)
		)
	}

	internal static var findInPageDefinition: Tool {
		.init(
			name: "browser_find_in_page",
			title: "Find and highlight text in a page",
			description: """
			Chromium's own find in page on an explicit ordinary tab and its current inventory revision: it matches \
			rendered text across frames, highlights every match and moves the active one. text starts a new search; \
			without text, direction next or previous moves through the current search; stop:true ends it and leaves \
			the selection on the active match. Requires the page-content and interact grants and mutation approval, \
			since the highlight and selection are visible to the user and the page. Never focuses, scrolls the \
			window or selects the tab. Returns matches and the one-based active match, or null when the page \
			reported no result within 2 seconds. Use browser_find for references in a snapshot.
			""",
			inputSchema: schema(
				properties: [
					"targetID": string(maximum: 36),
					"expectedRevision": string(maximum: 64),
					"text": string(maximum: 1_024),
					"direction": .object([
						"type": .string("string"),
						"enum": .array([.string("next"), .string("previous")]),
					]),
					"stop": .object(["type": .string("boolean")]),
				],
				required: ["targetID", "expectedRevision"]
			),
			annotations: .init(
				readOnlyHint: false,
				destructiveHint: false,
				idempotentHint: false,
				openWorldHint: false
			)
		)
	}

	internal static func findInPageRequest(_ arguments: [String: Value]) throws -> AutomationFindInPageRequest {
		guard
			Set(arguments.keys).isSubset(of: ["targetID", "expectedRevision", "text", "direction", "stop"]),
			let targetID = arguments["targetID"]?.stringValue.flatMap(UUID.init(uuidString:)),
			let revision = arguments["expectedRevision"]?.stringValue
		else { throw AutomationFailure.invalidRequest }

		let direction = arguments["direction"]?.stringValue ?? "next"
		guard ["next", "previous"].contains(direction)
		else { throw AutomationFailure.invalidRequest }

		var stop = false
		if let value = arguments["stop"] {
			guard let flag = value.boolValue else { throw AutomationFailure.invalidRequest }
			stop = flag
		}
		var text: String?
		if let value = arguments["text"] {
			guard let string = value.stringValue else { throw AutomationFailure.invalidRequest }
			text = string
		}
		let request = AutomationFindInPageRequest(
			targetID: targetID,
			expectedRevision: revision,
			text: text,
			forward: direction == "next",
			stop: stop
		)
		try request.validate()
		return request
	}

	internal static func pdfRequest(_ arguments: [String: Value]) throws -> AutomationPDFRequest {
		guard
			Set(arguments.keys).isSubset(of: [
				"targetID", "expectedRevision", "action", "landscape", "printBackground", "scale", "limit",
			]),
			let targetID = arguments["targetID"]?.stringValue.flatMap(UUID.init(uuidString:)),
			let revision = arguments["expectedRevision"]?.stringValue,
			let kind = arguments["action"]?.stringValue.flatMap(AutomationPDFRequest.Kind.init(rawValue:))
		else { throw AutomationFailure.invalidRequest }

		func flag(_ key: String) throws -> Bool {
			guard let value = arguments[key] else { return false }
			guard let flag = value.boolValue else { throw AutomationFailure.invalidRequest }
			return flag
		}

		var scale: Double?
		switch arguments["scale"] {
		case nil: scale = nil
		case let .int(value)?: scale = Double(value)
		case let .double(value)?: scale = value
		default: throw AutomationFailure.invalidRequest
		}
		var limit = 16_384
		if let value = arguments["limit"] {
			guard let number = value.intValue else { throw AutomationFailure.invalidRequest }
			limit = number
		}
		let request = AutomationPDFRequest(
			targetID: targetID,
			expectedRevision: revision,
			kind: kind,
			landscape: try flag("landscape"),
			printsBackground: try flag("printBackground"),
			scale: scale,
			maximumBytes: limit
		)
		try request.validate()
		return request
	}
}

extension AutomationCalls {
	/// `browser_pdf`: an export is one call; text continues by cursor, bound to the PDF's digest.
	internal func pdf(_ arguments: [String: Value]) async throws -> CallTool.Result {
		var request: AutomationPDFRequest
		var expectedDigest: String?
		var focusedTab: UUID?
		if let raw = arguments["cursor"] {
			guard
				arguments.count == 1,
				let text = raw.stringValue,
				let cursor = try? AutomationPageCursor.decode(text, as: .read),
				let digest = cursor.query
			else { throw MCPError.invalidParams("Arguments do not match the tool schema") }

			let inventory: AutomationInventory
			switch await gateway.fullInventory() {
			case let .success(value): inventory = value
			case let .failure(failure): return try BrowserMCPServer.toolResult(.failure(failure))
			}
			guard let item = inventory.items.first(where: { $0.kind == .tab && $0.id == cursor.targetID })
			else { return try BrowserMCPServer.toolResult(.failure(.denied)) }

			request = .init(
				targetID: cursor.targetID,
				expectedRevision: item.revision,
				kind: .text,
				offset: cursor.offset,
				maximumBytes: cursor.limit
			)
			expectedDigest = digest

		} else {
			var resolved = arguments
			if resolved["targetID"] == .string(AutomationFocusedTab.alias) {
				switch await gateway.focusedTab() {
				case let .success(tab):
					resolved["targetID"] = .string(tab.tabID.uuidString)
					resolved["expectedRevision"] = .string(tab.revision)
					focusedTab = tab.tabID

				case let .failure(failure):
					return try BrowserMCPServer.toolResult(.failure(failure))
				}
			}
			do {
				request = try AutomationTools.pdfRequest(resolved)
			} catch {
				throw MCPError.invalidParams("Arguments do not match the tool schema")
			}
		}

		let result = await gateway.perform(.pdf(request))
		guard case let .pdf(pdf) = result
		else { return try BrowserMCPServer.toolResult(result, focusedTab: focusedTab) }

		if let expectedDigest, pdf.digest != expectedDigest {
			return try BrowserMCPServer.toolResult(.failure(.staleCursor))
		}
		var extra: [String: Value] = [:]
		if let next = pdf.nextOffset {
			// The cursor reuses the page cursor's shape: query carries the digest.
			let cursor = AutomationPageCursor(
				kind: .read,
				targetID: request.targetID,
				documentID: pdf.documentID,
				domVersion: "1",
				offset: next,
				limit: request.maximumBytes,
				query: pdf.digest
			)
			extra["nextCursor"] = .string(try cursor.encoded())
		}
		return try BrowserMCPServer.toolResult(result, focusedTab: focusedTab, extra: extra)
	}
}
