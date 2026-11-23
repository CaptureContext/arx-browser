import BrowserAutomationClient
import BrowserCore
import Foundation
import _MCP

/// Paged page reads composed from one semantic snapshot: `browser_inspect` node
/// pages, `browser_read` text chunks and `browser_find` matches. Each page is cut
/// from a fresh snapshot of the exact version its cursor names.
extension AutomationCalls {
	internal static let pageReadingTools: Set<String> = ["browser_inspect", "browser_read", "browser_find"]

	internal func read(
		_ name: String,
		arguments: [String: Value]
	) async throws -> CallTool.Result {
		let kind: AutomationPageCursor.Kind = switch name {
		case "browser_read": .read
		case "browser_find": .find
		default: .inspect
		}

		let request: PageReadRequest
		do {
			request = try PageReadRequest(kind: kind, arguments: arguments)
		} catch {
			throw MCPError.invalidParams("Arguments do not match the tool schema")
		}

		let source: PageReadSource
		switch try await snapshot(for: request) {
		case let .success(value): source = value
		case let .failure(failure): return try BrowserMCPServer.toolResult(.failure(failure))
		}

		do {
			return try page(request, source: source)
		} catch let failure as AutomationFailure {
			return try BrowserMCPServer.toolResult(.failure(failure))
		}
	}

	// MARK: - Snapshot

	private struct PageReadSource: Sendable {
		internal var inspection: AutomationInspectionResult
		internal var focusedTab: UUID?
		internal var loaded: Bool
	}

	private func snapshot(for request: PageReadRequest) async throws -> Result<PageReadSource, AutomationFailure> {
		var base: AutomationInspectionRequest
		var focusedTab: UUID?
		var loaded = false
		if let cursor = request.cursor {
			let inventory: AutomationInventory
			switch await gateway.fullInventory() {
			case let .success(value): inventory = value
			case let .failure(failure): return .failure(failure)
			}
			guard let item = inventory.items.first(where: { $0.kind == .tab && $0.id == cursor.targetID })
			else { return .failure(.denied) }

			base = .init(targetID: cursor.targetID, expectedRevision: item.revision)

		} else {
			var arguments: [String: Value] = [:]
			arguments["targetID"] = request.targetID
			arguments["expectedRevision"] = request.expectedRevision
			let prepared: Prepared
			switch try await prepare("browser_inspect", arguments: arguments) {
			case let .operation(value): prepared = value
			case let .result(.failure(failure)): return .failure(failure)
			case .result: return .failure(.invalidRequest)
			}
			guard case let .inspect(inspection) = prepared.operation
			else { return .failure(.invalidRequest) }

			base = inspection
			focusedTab = prepared.focusedTab
			if request.load {
				switch await ensureLoaded(base.targetID, expectedRevision: base.expectedRevision) {
				case let .success(outcome):
					base.expectedRevision = outcome.revision
					loaded = outcome.loaded

				case let .failure(failure):
					return .failure(failure)
				}
			}
		}
		base.frameID = request.frameID
		base.includesFormValues = request.formValues
		base.includesBounds = request.bounds
		base.maximumTextBytes = request.maximumTextBytes

		switch request.kind {
		case .inspect:
			// One native window: pages of a large document never mix versions.
			base.windowStart = request.cursor?.offset ?? 0
			base.maximumNodes = request.limit
			switch await window(base) {
			case let .success(inspection):
				if let cursor = request.cursor, !cursor.matches(inspection.snapshot) { return .failure(.staleCursor) }
				return .success(.init(inspection: inspection, focusedTab: focusedTab, loaded: loaded))

			case let .failure(failure):
				return .failure(failure)
			}

		case .read, .find:
			switch await wholeDocument(base) {
			case let .success(inspection):
				if let cursor = request.cursor, !cursor.matches(inspection.snapshot) { return .failure(.staleCursor) }
				return .success(.init(inspection: inspection, focusedTab: focusedTab, loaded: loaded))

			case let .failure(failure):
				return .failure(failure)
			}
		}
	}

	private func window(_ request: AutomationInspectionRequest) async -> Result<AutomationInspectionResult, AutomationFailure> {
		switch await gateway.perform(.inspect(request)) {
		case let .inspection(result):
			do {
				try result.validate()
				return .success(result)
			} catch {
				return .failure(error as? AutomationFailure ?? .invalidRequest)
			}

		case let .failure(failure): return .failure(failure)

		default: return .failure(.invalidRequest)
		}
	}

	/// Every window of one DOM version, joined. A page that changes while it is
	/// read is read again once from the start; references stay only in the last
	/// window, the connection's latest snapshot.
	private func wholeDocument(_ base: AutomationInspectionRequest) async -> Result<AutomationInspectionResult, AutomationFailure> {
		for _ in 0..<2 {
			var request = base
			request.windowStart = 0
			request.maximumNodes = 512
			var joined: AutomationInspectionResult?
			var isStale = false
			while true {
				let result: AutomationInspectionResult
				switch await window(request) {
				case let .success(value): result = value
				case let .failure(failure): return .failure(failure)
				}

				if var current = joined {
					guard
						current.snapshot.documentID == result.snapshot.documentID,
						current.snapshot.domVersion == result.snapshot.domVersion
					else {
						isStale = true
						break
					}

					for index in current.snapshot.nodes.indices { current.snapshot.nodes[index].reference = nil }
					current.snapshot.nodes += result.snapshot.nodes
					current.snapshot.snapshotID = result.snapshot.snapshotID
					current.snapshot.totalNodes = result.snapshot.totalNodes
					current.request = result.request
					joined = current

				} else {
					joined = result
				}

				let end = result.snapshot.windowStart + result.snapshot.nodes.count
				guard end < result.snapshot.totalNodes, !result.snapshot.nodes.isEmpty else { break }

				request.windowStart = end
			}
			guard !isStale, var joined else { continue }

			// The joined snapshot reads as one whole-document request.
			joined.request.windowStart = 0
			joined.request.maximumNodes = joined.snapshot.nodes.count
			joined.snapshot.windowStart = 0
			return .success(joined)
		}
		return .failure(.staleTarget)
	}

	// MARK: - Background load

	private struct LoadOutcome: Sendable {
		internal var revision: String
		internal var loaded: Bool
	}

	/// Loads an unloaded tab in the background and waits, at most 10 seconds, until
	/// its page stops loading. Arx never focuses or selects the tab.
	private func ensureLoaded(
		_ targetID: UUID,
		expectedRevision: String
	) async -> Result<LoadOutcome, AutomationFailure> {
		switch await gateway.perform(.load(.init(targetID: targetID, expectedRevision: expectedRevision))) {
		case .load(.init(targetID: targetID, status: .loading)): break

		// A page that already exists is read as it is, like a call without load.
		case .load(.init(targetID: targetID, status: .alreadyLoaded)): return .success(.init(revision: expectedRevision, loaded: false))

		case let .failure(failure): return .failure(failure)

		default: return .failure(.invalidRequest)
		}

		let deadline = ContinuousClock.now + .seconds(10)
		while ContinuousClock.now < deadline {
			let inventory: AutomationInventory
			switch await gateway.fullInventory() {
			case let .success(value): inventory = value
			case let .failure(failure): return .failure(failure)
			}
			guard let item = inventory.items.first(where: { $0.kind == .tab && $0.id == targetID })
			else { return .failure(.denied) }

			switch item.sessionState {
			case .ready:
				return .success(.init(revision: item.revision, loaded: true))

			case .failed:
				return .failure(.engineFailed)

			// DEV-1009: reading would wait on a renderer that doesn't answer.
			case .notAnswering:
				return .failure(.pageNotAnswering)

			case .loading, .unloaded, .none:
				let remaining = deadline - ContinuousClock.now
				let milliseconds = Int(remaining.components.seconds * 1000)
				+ Int(remaining.components.attoseconds / 1_000_000_000_000_000)
				guard milliseconds > 0 else { return .failure(.timedOut) }

				// A commit while waiting returns staleTarget; the next pass reads the new revision.
				let result = await gateway.perform(.wait(.init(
					targetID: targetID,
					expectedRevision: item.revision,
					condition: .loadingStopped,
					timeoutMilliseconds: min(milliseconds, 10_000)
				)))
				switch result {
				case .wait, .failure(.staleTarget), .failure(.notLoaded), .failure(.notReady):
					// A page that has not published its first navigation yet reports
					// notLoaded; give it a moment instead of spinning.
					if case .failure = result { try? await Task.sleep(for: .milliseconds(200)) }

				case let .failure(failure):
					return .failure(failure)

				default:
					return .failure(.invalidRequest)
				}
			}
		}
		return .failure(.timedOut)
	}

	// MARK: - Pages

	private func page(
		_ request: PageReadRequest,
		source: PageReadSource
	) throws -> CallTool.Result {
		let inspection = source.inspection
		let snapshot = inspection.snapshot
		let offset = request.cursor?.offset ?? 0

		var fields: [String: Value] = [
			"targetID": .string(inspection.request.targetID.uuidString),
			"profileID": .string(inspection.source.profileID.rawValue.uuidString),
			"sessionRevision": .string(String(inspection.source.sessionRevision)),
			"documentRevision": .string(String(inspection.source.documentRevision)),
			"snapshotID": .string(snapshot.snapshotID),
			"documentID": .string(snapshot.documentID),
			"frameID": .string(snapshot.frameID),
			"domVersion": .string(snapshot.domVersion),
			"historical": .bool(true),
			"referencesAuthorizeActions": .bool(false),
			"omissions": try Value(encoding: snapshot.omissions),
		]
		if source.loaded { fields["loadedInBackground"] = .bool(true) }

		func cursor(at next: Int?) throws -> Value {
			guard let next else { return .null }
			return .string(try AutomationPageCursor(
				kind: request.kind,
				targetID: inspection.request.targetID,
				documentID: snapshot.documentID,
				domVersion: snapshot.domVersion,
				offset: next,
				limit: request.limit,
				format: request.format,
				scope: request.scope,
				query: request.query,
				frameID: request.frameID,
				formValues: request.formValues,
				bounds: request.bounds
			).encoded())
		}

		func response(_ result: [String: Value]) throws -> CallTool.Result {
			var extra: [String: Value] = ["untrustedData": .bool(true), "result": .object(fields.merging(result) { $1 })]
			if let focused = source.focusedTab { extra["focusedTab"] = .string(focused.uuidString) }
			return try BrowserMCPServer.envelope(extra, isError: false)
		}

		switch request.kind {
		case .inspect:
			// The snapshot is one native window starting at the cursor's offset.
			guard snapshot.windowStart == offset else { throw AutomationFailure.staleCursor }

			// Shrink the page until it fits; the cursor then resumes after what was sent.
			var count = snapshot.nodes.count
			while true {
				let end = offset + count
				let candidate = try response([
					"kind": .string("inspection"),
					"expectedRevision": .string(inspection.request.expectedRevision),
					"offset": .int(offset),
					"totalNodes": .int(snapshot.totalNodes),
					"nodes": try Value(encoding: Array(snapshot.nodes.prefix(count))),
					"nextCursor": try cursor(at: end < snapshot.totalNodes ? end : nil),
				])
				if BrowserMCPServer.fits(candidate) { return candidate }
				guard count > 1 else { throw AutomationFailure.limitExceeded }

				count /= 2
			}

		case .read:
			let format = request.format ?? .markdown
			let scope = request.scope ?? .main
			let text = AutomationReadableText.render(snapshot.nodes, format: format, scope: scope)
			let totalBytes = text.utf8.count
			var maximumBytes = request.limit
			while true {
				let (chunk, next) = try AutomationReadableText.chunk(text, offset: offset, maximumBytes: maximumBytes)
				let candidate = try response([
					"kind": .string("read"),
					"format": .string(format.rawValue),
					"scope": .string(scope.rawValue),
					"offset": .int(offset),
					"totalBytes": .int(totalBytes),
					"text": .string(chunk),
					"nextCursor": try cursor(at: next),
				])
				if BrowserMCPServer.fits(candidate) { return candidate }
				guard maximumBytes > 1024 else { throw AutomationFailure.limitExceeded }

				maximumBytes /= 2
			}

		case .find:
			let matches = AutomationReadableText.find(request.query ?? "", in: snapshot.nodes)
			guard offset <= matches.count else { throw AutomationFailure.staleCursor }

			let end = min(matches.count, offset + request.limit)
			let candidate = try response([
				"kind": .string("find"),
				"query": .string(request.query ?? ""),
				"offset": .int(offset),
				"totalMatches": .int(matches.count),
				"matches": try Value(encoding: Array(matches[offset..<end])),
				"nextCursor": try cursor(at: end < matches.count ? end : nil),
			])
			guard BrowserMCPServer.fits(candidate) else { throw AutomationFailure.limitExceeded }
			return candidate
		}
	}
}

/// Parsed arguments of a page-reading tool. A cursor carries every option, so it
/// stands alone.
private struct PageReadRequest: Sendable {
	internal var kind: AutomationPageCursor.Kind
	internal var cursor: AutomationPageCursor?
	internal var targetID: Value?
	internal var expectedRevision: Value?
	internal var maximumTextBytes: Int = 65_536
	internal var limit: Int
	internal var format: AutomationReadableText.Format?
	internal var scope: AutomationReadableText.Scope?
	internal var query: String?
	internal var load: Bool = false
	internal var frameID: String?
	internal var formValues: Bool = false
	internal var bounds: Bool = false

	internal init(
		kind: AutomationPageCursor.Kind,
		arguments: [String: Value]
	) throws {
		self.kind = kind
		if let raw = arguments["cursor"] {
			guard
				arguments.count == 1,
				let text = raw.stringValue
			else { throw AutomationFailure.invalidRequest }

			let cursor = try AutomationPageCursor.decode(text, as: kind)
			self.cursor = cursor
			self.limit = cursor.limit
			self.format = cursor.format
			self.scope = cursor.scope
			self.query = cursor.query
			self.frameID = cursor.frameID
			self.formValues = cursor.formValues ?? false
			self.bounds = cursor.bounds ?? false
			try validateLimit()
			return
		}

		var allowed: Set<String> = ["targetID", "expectedRevision", "limit", "load", "frameID", "formValues", "bounds"]
		switch kind {
		case .inspect: allowed.formUnion(["maximumNodes", "maximumTextBytes"])
		case .read: allowed.formUnion(["format", "scope"])
		case .find: allowed.insert("query")
		}
		guard
			Set(arguments.keys).isSubset(of: allowed),
			arguments["targetID"] != nil,
			arguments["expectedRevision"] != nil
		else { throw AutomationFailure.invalidRequest }

		self.targetID = arguments["targetID"]
		self.expectedRevision = arguments["expectedRevision"]

		func integer(
			_ key: String,
			default fallback: Int
		) throws -> Int {
			guard let value = arguments[key] else { return fallback }
			guard let number = value.intValue else { throw AutomationFailure.invalidRequest }
			return number
		}

		// maximumNodes is the window size the original tool called a budget.
		self.maximumTextBytes = try integer("maximumTextBytes", default: 65_536)
		self.limit = try integer("limit", default: try integer("maximumNodes", default: Self.defaultLimit(kind)))
		func flag(_ key: String) throws -> Bool {
			guard let value = arguments[key] else { return false }
			guard let flag = value.boolValue else { throw AutomationFailure.invalidRequest }
			return flag
		}
		self.load = try flag("load")
		self.formValues = try flag("formValues")
		self.bounds = try flag("bounds")
		if let value = arguments["frameID"] {
			guard
				let frame = value.stringValue,
				frame.utf8.count == 32,
				frame.allSatisfy(\.isHexDigit)
			else { throw AutomationFailure.invalidRequest }
			self.frameID = frame
		}

		switch kind {
		case .inspect:
			break

		case .read:
			if let value = arguments["format"] {
				guard let format = value.stringValue.flatMap(AutomationReadableText.Format.init(rawValue:))
				else { throw AutomationFailure.invalidRequest }
				self.format = format
			}
			if let value = arguments["scope"] {
				guard let scope = value.stringValue.flatMap(AutomationReadableText.Scope.init(rawValue:))
				else { throw AutomationFailure.invalidRequest }
				self.scope = scope
			}
			self.format = self.format ?? .markdown
			self.scope = self.scope ?? .main

		case .find:
			guard
				let query = arguments["query"]?.stringValue,
				!query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
				query.utf8.count <= 256
			else { throw AutomationFailure.invalidRequest }
			self.query = query
		}
		try validateLimit()
	}

	internal static func defaultLimit(_ kind: AutomationPageCursor.Kind) -> Int {
		switch kind {
		case .inspect: 100
		case .read: 16_384
		case .find: 20
		}
	}

	internal static func limitRange(_ kind: AutomationPageCursor.Kind) -> ClosedRange<Int> {
		switch kind {
		case .inspect: 1...512
		case .read: 1024...65_536
		case .find: 1...100
		}
	}

	private func validateLimit() throws {
		guard
			Self.limitRange(kind).contains(limit),
			(1...65_536).contains(maximumTextBytes)
		else { throw AutomationFailure.invalidRequest }
	}
}
