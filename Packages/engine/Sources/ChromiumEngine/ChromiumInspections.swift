import ChromiumBridge
import Foundation

@MainActor
internal final class ChromiumInspections {
	private let api: ArxEngineAPI
	private var nextRequest: UInt64 = 1
	private var nextGeneration: UInt64 = 1
	private var pages: [UInt64: UInt64] = [:]
	private var scopes: [UUID: UInt64] = [:]
	private var requests: [UInt64: Request] = [:]
	private var snapshots: [String: OwnedSnapshot] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal func register(page: UInt64) {
		guard pages[page] == nil, nextGeneration < UInt64.max
		else { return }

		pages[page] = nextGeneration
		nextGeneration += 1
	}

	internal func inspect(
		page: UInt64,
		scope: UUID,
		frameID: String? = nil,
		limits: ChromiumInspectionLimits
	) async throws -> ChromiumInspectionSnapshot {
		try Task.checkCancellation()
		let window = try limits.nativeWindow()
		if let frameID {
			guard ChromiumInspectionSnapshot.isToken(frameID)
			else { throw ChromiumInspectionFailure.invalidResponse }
		}

		let context = try context(page: page, scope: scope)
		let isPlain = frameID == nil && window.window_start == 0 && window.flags == 0
		let result: ChromiumInspectionSnapshot?
		if let inspect = api.inspect_frame {
			result = try await perform(context: context, limits: limits, frameID: frameID) { request in
				inspect(page, request, scope.uuidString.lowercased(), frameID ?? "", window)
			}
		} else if isPlain, let inspect = api.inspect_page {
			result = try await perform(context: context, limits: limits, frameID: nil) { request in
				inspect(page, request, scope.uuidString.lowercased(), window.limits)
			}
		} else {
			throw ChromiumInspectionFailure.unavailable
		}

		guard
			let result,
			documentIsCurrent(result, page: page, scope: scope)
		else { throw ChromiumInspectionFailure.staleReference }

		return result
	}

	internal func validate(
		_ reference: String,
		in snapshot: ChromiumInspectionSnapshot,
		page: UInt64,
		scope: UUID
	) async throws {
		try Task.checkCancellation()
		guard
			documentIsCurrent(snapshot, page: page, scope: scope),
			snapshot.nodes.contains(where: { $0.reference == reference }),
			let validate = api.validate_inspection_reference
		else { throw ChromiumInspectionFailure.staleReference }

		let context = try context(page: page, scope: scope)
		_ = try await perform(context: context, limits: nil, frameID: nil) { request in
			validate(
				page,
				request,
				scope.uuidString.lowercased(),
				snapshot.snapshotID,
				reference
			)
		}

		guard documentIsCurrent(snapshot, page: page, scope: scope)
		else { throw ChromiumInspectionFailure.staleReference }
	}

	internal func documentIsCurrent(
		_ snapshot: ChromiumInspectionSnapshot,
		page: UInt64,
		scope: UUID
	) -> Bool {
		guard
			let owned = snapshots[snapshot.snapshotID],
			owned.snapshot == snapshot,
			owned.context.page == page,
			owned.context.scope == scope,
			isCurrent(owned.context),
			let current = api.inspection_document_is_current
		else { return false }

		return current(page, scope.uuidString.lowercased(), snapshot.snapshotID)
	}

	internal func revoke(scope: UUID) {
		scopes.removeValue(forKey: scope)
		for request in requests.keys.filter({ requests[$0]?.context.scope == scope }) {
			cancel(request, failure: ChromiumInspectionFailure.staleReference)
		}
		snapshots = snapshots.filter { $0.value.context.scope != scope }
		api.revoke_inspection_scope?(scope.uuidString.lowercased())
	}

	internal func remove(page: UInt64) {
		pages.removeValue(forKey: page)
		for request in requests.keys.filter({ requests[$0]?.context.page == page }) {
			cancel(request, failure: ChromiumInspectionFailure.staleReference)
		}
		snapshots = snapshots.filter { $0.value.context.page != page }
	}

	internal func stop() {
		for scope in Array(scopes.keys) {
			revoke(scope: scope)
		}
		pages.removeAll()
		snapshots.removeAll()
	}

	internal func complete(
		_ id: UInt64,
		page: UInt64,
		status: ArxInspectionStatus,
		bytes: UnsafePointer<UInt8>?,
		count: Int
	) {
		guard let request = requests.removeValue(forKey: id)
		else { return }

		do {
			guard page == request.context.page, isCurrent(request.context)
			else { throw ChromiumInspectionFailure.staleReference }
			if status == ARX_INSPECTION_CANCELLED { throw CancellationError() }
			guard status == ARX_INSPECTION_SUCCESS
			else { throw ChromiumInspectionFailure(status: status) }

			guard let limits = request.limits else {
				guard count == 0
				else { throw ChromiumInspectionFailure.invalidResponse }

				request.continuation.resume(returning: nil)
				return
			}
			guard count > 0, count <= limits.maximumOutputBytes
			else { throw ChromiumInspectionFailure.limitExceeded }
			guard let bytes
			else { throw ChromiumInspectionFailure.invalidResponse }

			let snapshot: ChromiumInspectionSnapshot
			do {
				snapshot = try JSONDecoder().decode(
					ChromiumInspectionSnapshot.self,
					from: Data(bytes: bytes, count: count)
				)
			} catch {
				throw ChromiumInspectionFailure.invalidResponse
			}

			try snapshot.validate(limits: limits)
			if let frameID = request.frameID, snapshot.frameID != frameID {
				throw ChromiumInspectionFailure.invalidResponse
			}
			prune()
			guard snapshots.count < 16, snapshots[snapshot.snapshotID] == nil
			else { throw ChromiumInspectionFailure.busy }

			snapshots[snapshot.snapshotID] = .init(
				snapshot: snapshot,
				context: request.context
			)
			guard documentIsCurrent(snapshot, page: page, scope: request.context.scope) else {
				snapshots.removeValue(forKey: snapshot.snapshotID)
				throw ChromiumInspectionFailure.staleReference
			}
			request.continuation.resume(returning: snapshot)
		} catch {
			request.continuation.resume(throwing: error)
		}
	}

	private func context(
		page: UInt64,
		scope: UUID
	) throws -> Context {
		guard let pageGeneration = pages[page]
		else { throw ChromiumInspectionFailure.unavailable }

		if scopes[scope] == nil {
			guard scopes.count < 32, nextGeneration < UInt64.max
			else { throw ChromiumInspectionFailure.busy }

			scopes[scope] = nextGeneration
			nextGeneration += 1
		}

		return .init(
			page: page,
			pageGeneration: pageGeneration,
			scope: scope,
			scopeGeneration: scopes[scope]!
		)
	}

	private func isCurrent(_ context: Context) -> Bool {
		pages[context.page] == context.pageGeneration
		&& scopes[context.scope] == context.scopeGeneration
	}

	private func prune() {
		for id in Array(snapshots.keys) {
			guard let owned = snapshots[id]
			else { continue }

			let current = documentIsCurrent(
				owned.snapshot,
				page: owned.context.page,
				scope: owned.context.scope
			)
			if !current {
				snapshots.removeValue(forKey: id)
			}
		}
	}

	private func perform(
		context: Context,
		limits: ChromiumInspectionLimits?,
		frameID: String?,
		start: (UInt64) -> Void
	) async throws -> ChromiumInspectionSnapshot? {
		try Task.checkCancellation()
		guard requests.count < 16, nextRequest < UInt64.max
		else { throw ChromiumInspectionFailure.busy }

		let id = nextRequest
		nextRequest += 1
		let snapshot: ChromiumInspectionSnapshot? = try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await withCheckedThrowingContinuation { continuation in
				requests[id] = .init(
					context: context,
					limits: limits,
					frameID: frameID,
					continuation: continuation
				)
				start(id)
			}
		} onCancel: {
			Task { @MainActor [weak self] in
				self?.cancel(id, failure: CancellationError())
			}
		}

		try Task.checkCancellation()
		guard isCurrent(context)
		else { throw ChromiumInspectionFailure.staleReference }

		return snapshot
	}

	private func cancel(
		_ id: UInt64,
		failure: any Error
	) {
		guard let request = requests.removeValue(forKey: id)
		else { return }

		api.cancel_inspection?(id)
		request.continuation.resume(throwing: failure)
	}

	private struct Context {
		internal let page: UInt64
		internal let pageGeneration: UInt64
		internal let scope: UUID
		internal let scopeGeneration: UInt64

		internal init(
			page: UInt64,
			pageGeneration: UInt64,
			scope: UUID,
			scopeGeneration: UInt64
		) {
			self.page = page
			self.pageGeneration = pageGeneration
			self.scope = scope
			self.scopeGeneration = scopeGeneration
		}
	}

	private struct OwnedSnapshot {
		internal let snapshot: ChromiumInspectionSnapshot
		internal let context: Context

		internal init(
			snapshot: ChromiumInspectionSnapshot,
			context: Context
		) {
			self.snapshot = snapshot
			self.context = context
		}
	}

	private struct Request {
		internal let context: Context
		internal let limits: ChromiumInspectionLimits?
		internal let frameID: String?
		internal let continuation: CheckedContinuation<ChromiumInspectionSnapshot?, any Error>

		internal init(
			context: Context,
			limits: ChromiumInspectionLimits?,
			frameID: String?,
			continuation: CheckedContinuation<ChromiumInspectionSnapshot?, any Error>
		) {
			self.context = context
			self.limits = limits
			self.frameID = frameID
			self.continuation = continuation
		}
	}
}

extension ChromiumInspectionLimits {
	internal func native() throws -> ArxInspectionLimits {
		guard
			(1...512).contains(maximumNodes),
			(1...65_536).contains(maximumTextBytes),
			(1...256).contains(maximumReferences),
			(1_024...262_144).contains(maximumOutputBytes),
			(1...2_000).contains(timeoutMilliseconds)
		else { throw ChromiumInspectionFailure.limitExceeded }

		return .init(
			maximum_nodes: UInt32(maximumNodes),
			maximum_text_bytes: UInt32(maximumTextBytes),
			maximum_references: UInt32(maximumReferences),
			maximum_output_bytes: UInt32(maximumOutputBytes),
			timeout_ms: UInt32(timeoutMilliseconds)
		)
	}

	internal func nativeWindow() throws -> ArxInspectionWindow {
		guard (0..<Self.maximumTreeNodes).contains(windowStart)
		else { throw ChromiumInspectionFailure.limitExceeded }

		var flags: UInt32 = 0
		if includesFormValues { flags |= UInt32(ARX_INSPECTION_FORM_VALUES) }
		if includesBounds { flags |= UInt32(ARX_INSPECTION_BOUNDS) }
		return .init(limits: try native(), window_start: UInt32(windowStart), flags: flags)
	}
}

extension ChromiumInspectionSnapshot {
	internal func validate(limits: ChromiumInspectionLimits) throws {
		guard nodes.count <= limits.maximumNodes
		else { throw ChromiumInspectionFailure.limitExceeded }

		// Form values are the only coverage a request can add.
		var coverage = Set(ChromiumInspectionOmission.allCases)
		if limits.includesFormValues { coverage.remove(.formValues) }
		guard
			Self.isToken(snapshotID),
			Self.isToken(documentID),
			Self.isToken(frameID),
			let version = UInt64(domVersion),
			version > 0,
			String(version) == domVersion,
			omissions.count == coverage.count,
			Set(omissions) == coverage,
			windowStart == limits.windowStart,
			totalNodes >= windowStart + nodes.count,
			totalNodes <= ChromiumInspectionLimits.maximumTreeNodes
		else { throw ChromiumInspectionFailure.invalidResponse }

		var references: Set<String> = []
		var textBytes = 0
		for (offset, node) in nodes.enumerated() {
			let index = windowStart + offset
			guard
				node.index == index,
				node.parent.map({ (0..<index).contains($0) }) ?? true,
				node.frame.map(Self.isToken) ?? true,
				limits.includesFormValues || (node.value == nil && node.checked == nil),
				node.value == nil || node.checked == nil,
				limits.includesBounds || node.bounds == nil,
				node.bounds.map({ $0.width > 0 && $0.height > 0 }) ?? true,
				!node.role.isEmpty,
				node.role.utf8.count <= 64,
				node.role.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) })
			else { throw ChromiumInspectionFailure.invalidResponse }

			for text in [node.name, node.text, node.value].compactMap({ $0 }) {
				guard text.utf8.count <= 4_096
				else { throw ChromiumInspectionFailure.limitExceeded }

				textBytes += text.utf8.count
			}
			if let reference = node.reference {
				guard Self.isToken(reference), references.insert(reference).inserted
				else { throw ChromiumInspectionFailure.invalidResponse }
			}
		}
		guard
			textBytes <= limits.maximumTextBytes,
			references.count <= limits.maximumReferences
		else { throw ChromiumInspectionFailure.limitExceeded }
	}

	internal static func isToken(_ token: String) -> Bool {
		token.utf8.count == 32
		&& token.utf8.allSatisfy {
			(48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
		}
	}
}

extension ChromiumInspectionFailure {
	internal init(status: ArxInspectionStatus) {
		self = switch status {
		case ARX_INSPECTION_UNAVAILABLE: .unavailable
		case ARX_INSPECTION_NOT_READY: .notReady
		case ARX_INSPECTION_UNSUPPORTED: .unsupportedDocument
		case ARX_INSPECTION_STALE: .staleReference
		case ARX_INSPECTION_LIMIT: .limitExceeded
		case ARX_INSPECTION_TIMEOUT: .timedOut
		case ARX_INSPECTION_BUSY: .busy
		default: .invalidResponse
		}
	}
}
