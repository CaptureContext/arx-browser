import ChromiumBridge
import CryptoKit
import Foundation

@MainActor
internal final class ChromiumReferenceClicks {
	private let api: ArxEngineAPI

	// One ledger and physical admission queue covers every reference mutation.
	private var nextRequest: UInt64 = 1
	private var receipts: [UUID: Receipt] = [:]
	private var scopeCounts: [UUID: Int] = [:]
	private var pending: [UInt64: Pending] = [:]

	// Early cancellation replies do not prove renderer drainage. Entries are
	// bound to the page and the document epoch they were submitted into.
	private var unresolvedSubmissions: [UInt64: Submission] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	/// True when no submission into this exact page document has an uncertain
	/// native outcome. A zero epoch means the document was unknown at
	/// submission, so such an entry blocks every document of its page.
	internal func submissionsAreSettled(
		page: UInt64,
		documentRevision: UInt64
	) -> Bool {
		!unresolvedSubmissions.values.contains { submission in
			submission.page == page
			&& (submission.documentRevision == 0 || submission.documentRevision == documentRevision)
		}
	}

	/// Drops uncertainty for documents that were replaced or pages that closed.
	/// The predicate receives the page and the document epoch of one submission.
	internal func releaseSubmissions(where isReplaced: (UInt64, UInt64) -> Bool) {
		unresolvedSubmissions = unresolvedSubmissions.filter { _, submission in
			!isReplaced(submission.page, submission.documentRevision)
		}
	}

	internal func click(
		_ request: ChromiumReferenceClickRequest,
		page: UInt64,
		scope: UUID,
		documentRevision: @escaping @MainActor () -> UInt64,
		validateSource: @escaping @MainActor () -> ChromiumReferenceClickFailure?,
		authorize: @escaping @MainActor @Sendable () -> Bool
	) async -> ChromiumReferenceClickResult {
		let result = await perform(
			.init(click: request),
			page: page,
			scope: scope,
			documentRevision: documentRevision,
			validateSource: { validateSource().map(ChromiumReferenceFormFailure.init) },
			authorize: authorize
		)
		return result.clickResult
	}

	internal func formAction(
		_ request: ChromiumReferenceFormRequest,
		page: UInt64,
		scope: UUID,
		documentRevision: @escaping @MainActor () -> UInt64,
		validateSource: @escaping @MainActor () -> ChromiumReferenceFormFailure?,
		authorize: @escaping @MainActor @Sendable () -> Bool
	) async -> ChromiumReferenceFormResult {
		await perform(
			.init(form: request),
			page: page,
			scope: scope,
			documentRevision: documentRevision,
			validateSource: validateSource,
			authorize: authorize
		)
	}

	internal func scroll(
		_ request: ChromiumReferenceScrollRequest,
		page: UInt64,
		scope: UUID,
		documentRevision: @escaping @MainActor () -> UInt64,
		validateSource: @escaping @MainActor () -> ChromiumReferenceScrollFailure?,
		authorize: @escaping @MainActor @Sendable () -> Bool
	) async -> ChromiumReferenceScrollResult {
		let result = await perform(
			.init(scroll: request),
			page: page,
			scope: scope,
			documentRevision: documentRevision,
			validateSource: { validateSource().map(ChromiumReferenceFormFailure.init) },
			authorize: authorize
		)
		return result.scrollResult
	}

	private func perform(
		_ request: Request,
		page: UInt64,
		scope: UUID,
		documentRevision: @escaping @MainActor () -> UInt64,
		validateSource: @escaping @MainActor () -> ChromiumReferenceFormFailure?,
		authorize: @escaping @MainActor @Sendable () -> Bool
	) async -> ChromiumReferenceFormResult {
		let binding = Binding(request: request, page: page, scope: scope)
		if let previous = receipts[request.operationID] {
			return .init(
				operationID: request.operationID,
				disposition: previous.binding == binding ? previous.disposition : .possiblyDispatched,
				failure: .duplicateOperation
			)
		}

		guard request.isValid else {
			return .init(
				operationID: request.operationID,
				disposition: .notDispatched,
				failure: .invalidResponse
			)
		}
		if let failure = request.payloadFailure {
			return reject(request.operationID, failure: failure)
		}

		guard
			receipts.count < 4_096,
			scopeCounts[scope, default: 0] < 256
		else {
			return .init(
				operationID: request.operationID,
				disposition: .notDispatched,
				failure: .limitExceeded
			)
		}
		receipts[request.operationID] = .init(binding: binding, disposition: .notDispatched)
		scopeCounts[scope, default: 0] += 1

		let available: Bool = switch request.kind {
		case 0:
			api.click_inspection_reference != nil && api.cancel_reference_click != nil

		case 3:
			api.scroll_inspection_reference != nil && api.cancel_reference_click != nil

		case 4:
			api.reference_keypress_available?() == true
			&& api.perform_inspection_form_action != nil
			&& api.cancel_reference_form_action != nil

		default:
			api.perform_inspection_form_action != nil && api.cancel_reference_form_action != nil
		}

		guard available
		else { return reject(request.operationID, failure: .unavailable) }
		guard !Task.isCancelled
		else { return reject(request.operationID, failure: .cancelled) }
		if let failure = validateSource() {
			return reject(request.operationID, failure: failure)
		}
		guard
			pending.count < 16,
			unresolvedSubmissions.count < 16,
			!pending.values.contains(where: { $0.binding.page == page }),
			nextRequest < UInt64.max
		else { return reject(request.operationID, failure: .busy) }

		let id = nextRequest
		nextRequest += 1
		return await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				guard !Task.isCancelled else {
					continuation.resume(returning: reject(request.operationID, failure: .cancelled))
					return
				}
				if let failure = validateSource() {
					continuation.resume(returning: reject(request.operationID, failure: failure))
					return
				}
				guard authorize() else {
					continuation.resume(returning: reject(request.operationID, failure: .notAuthorized))
					return
				}

				// No suspension between this final live authorization and C submission.
				// Cancellation may race it from another thread; the receipt is marked
				// uncertain before C can synchronously reenter through a native callback.
				guard !Task.isCancelled else {
					continuation.resume(returning: reject(request.operationID, failure: .cancelled))
					return
				}
				if let failure = validateSource() {
					continuation.resume(returning: reject(request.operationID, failure: failure))
					return
				}
				pending[id] = .init(
					operationID: request.operationID,
					binding: binding,
					continuation: continuation
				)
				receipts[request.operationID]?.disposition = .possiblyDispatched
				unresolvedSubmissions[id] = .init(page: page, documentRevision: documentRevision())
				submit(request, id: id, page: page, scope: scope)
			}
		} onCancel: {
			Task { @MainActor [weak self] in
				self?.cancel(id, failure: .cancelled)
			}
		}
	}

	internal func complete(
		_ id: UInt64,
		page: UInt64,
		disposition: ArxClickDisposition,
		status: ArxClickStatus
	) {
		completeAction(
			id,
			page: page,
			disposition: disposition.rawValue,
			status: status.rawValue,
			family: 0
		)
	}

	internal func completeFormAction(
		_ id: UInt64,
		page: UInt64,
		disposition: ArxFormDisposition,
		status: ArxFormStatus
	) {
		completeAction(
			id,
			page: page,
			disposition: disposition.rawValue,
			status: status.rawValue,
			family: 1
		)
	}

	internal func completeScroll(
		_ id: UInt64,
		page: UInt64,
		disposition: ArxScrollDisposition,
		status: ArxScrollStatus
	) {
		completeAction(
			id,
			page: page,
			disposition: disposition.rawValue,
			status: status.rawValue,
			family: 3
		)
	}

	private func completeAction(
		_ id: UInt64,
		page: UInt64,
		disposition: UInt32,
		status: UInt32,
		family: UInt32
	) {
		guard let request = pending.removeValue(forKey: id)
		else { return }

		let result = response(
			for: request,
			page: page,
			disposition: disposition,
			status: status,
			family: family
		)

		// A validated successful reply comes from native DeliverClick after its
		// physical slot is erased. Cancel/timeout/failure may be an earlier reply;
		// retain uncertainty until document replacement, page closure or
		// runtime teardown in that case.
		if result.failure == nil { unresolvedSubmissions[id] = nil }
		receipts[request.operationID]?.disposition = result.disposition
		request.continuation?.resume(returning: result)
	}

	private func submit(
		_ request: Request,
		id: UInt64,
		page: UInt64,
		scope: UUID
	) {
		if request.kind == 0 {
			api.click_inspection_reference?(
				page,
				id,
				scope.uuidString.lowercased(),
				request.snapshot.snapshotID,
				request.reference,
				request.operationID.uuidString.lowercased(),
				UInt32(request.timeoutMilliseconds)
			)

		} else if request.kind == 3 {
			api.scroll_inspection_reference?(
				page,
				id,
				scope.uuidString.lowercased(),
				request.snapshot.snapshotID,
				request.reference,
				request.operationID.uuidString.lowercased(),
				ArxScrollAxis(rawValue: request.scrollAxis),
				request.scrollDelta,
				UInt32(request.timeoutMilliseconds)
			)

		} else {
			request.payload.withUnsafeBytes { bytes in
				api.perform_inspection_form_action?(
					page,
					id,
					scope.uuidString.lowercased(),
					request.snapshot.snapshotID,
					request.reference,
					request.operationID.uuidString.lowercased(),
					ArxFormActionKind(rawValue: request.kind),
					bytes.bindMemory(to: UInt8.self).baseAddress,
					bytes.count,
					UInt32(request.timeoutMilliseconds)
				)
			}
		}
	}

	internal func revoke(scope: UUID) {
		for id in pending.keys.filter({ pending[$0]?.binding.scope == scope }) {
			cancel(id, failure: .notAuthorized)
		}
	}

	/// Native page identifiers are never reused, so a closed page's uncertain
	/// submissions cannot reach any later page.
	internal func remove(page: UInt64) {
		for id in pending.keys.filter({ pending[$0]?.binding.page == page }) {
			cancel(id, failure: .staleReference)
		}
		releaseSubmissions { submissionPage, _ in submissionPage == page }
	}

	internal func stop() {
		for id in Array(pending.keys) {
			cancel(id, failure: .unavailable)
		}
		pending.removeAll()
		unresolvedSubmissions.removeAll()

		// Keep receipts even after shutdown: a stopped runtime cannot replay them.
	}

	private func response(
		for request: Pending,
		page: UInt64,
		disposition: UInt32,
		status: UInt32,
		family: UInt32
	) -> ChromiumReferenceFormResult {
		guard
			page == request.binding.page,
			family == request.binding.callbackFamily,
			let disposition = ChromiumReferenceFormDisposition(raw: disposition),
			family != 0 || disposition != .unchanged,
			let status = ChromiumReferenceFormStatus(raw: status),
			family != 0 || status.raw <= 12,
			family != 3 || status.raw <= 14,
			status.failure != nil || disposition == .dispatched || disposition == .unchanged
		else {
			return .init(
				operationID: request.operationID,
				disposition: .possiblyDispatched,
				failure: .invalidResponse
			)
		}
		return .init(
			operationID: request.operationID,
			disposition: disposition,
			failure: status.failure
		)
	}

	private func reject(
		_ operationID: UUID,
		failure: ChromiumReferenceFormFailure
	) -> ChromiumReferenceFormResult {
		.init(operationID: operationID, disposition: .notDispatched, failure: failure)
	}

	private func cancel(
		_ id: UInt64,
		failure: ChromiumReferenceFormFailure
	) {
		guard
			var request = pending[id],
			let continuation = request.continuation
		else { return }

		request.continuation = nil
		pending[id] = request
		if request.binding.kind == 0 || request.binding.kind == 3 {
			api.cancel_reference_click?(id)
		} else {
			api.cancel_reference_form_action?(id)
		}
		continuation.resume(returning: .init(
			operationID: request.operationID,
			disposition: receipts[request.operationID]?.disposition ?? .possiblyDispatched,
			failure: failure
		))
	}
}

extension ChromiumReferenceClicks {
	private struct Binding: Equatable {
		internal let page: UInt64
		internal let scope: UUID
		internal let snapshot: String
		internal let reference: String
		internal let document: String
		internal let frame: String
		internal let version: String
		internal let kind: UInt32
		internal let payloadDigest: [UInt8]

		internal init(
			request: Request,
			page: UInt64,
			scope: UUID
		) {
			self.page = page
			self.scope = scope
			self.snapshot = request.snapshot.snapshotID
			self.reference = request.reference
			self.document = request.snapshot.documentID
			self.frame = request.snapshot.frameID
			self.version = request.snapshot.domVersion
			self.kind = request.kind
			self.payloadDigest = request.payloadDigest
		}

		internal var callbackFamily: UInt32 {
			switch kind {
			case 0, 3: kind
			default: 1
			}
		}
	}

	private struct Submission {
		internal let page: UInt64
		internal let documentRevision: UInt64

		internal init(
			page: UInt64,
			documentRevision: UInt64
		) {
			self.page = page
			self.documentRevision = documentRevision
		}
	}

	private struct Receipt {
		internal let binding: Binding
		internal var disposition: ChromiumReferenceFormDisposition

		internal init(
			binding: Binding,
			disposition: ChromiumReferenceFormDisposition
		) {
			self.binding = binding
			self.disposition = disposition
		}
	}

	private struct Pending {
		internal let operationID: UUID
		internal let binding: Binding
		internal var continuation: CheckedContinuation<ChromiumReferenceFormResult, Never>?

		internal init(
			operationID: UUID,
			binding: Binding,
			continuation: CheckedContinuation<ChromiumReferenceFormResult, Never>?
		) {
			self.operationID = operationID
			self.binding = binding
			self.continuation = continuation
		}
	}
}

extension ChromiumReferenceClicks {
	private struct Request {
		internal let operationID: UUID
		internal let snapshot: ChromiumInspectionSnapshot
		internal let reference: String
		internal let timeoutMilliseconds: Int
		internal let kind: UInt32
		internal let payload: Data
		internal let payloadDigest: [UInt8]
		internal let payloadFailure: ChromiumReferenceFormFailure?
		internal let scrollAxis: UInt32
		internal let scrollDelta: Double

		internal init(click: ChromiumReferenceClickRequest) {
			self.operationID = click.operationID
			self.snapshot = click.snapshot
			self.reference = click.reference
			self.timeoutMilliseconds = click.timeoutMilliseconds
			self.kind = 0
			self.scrollAxis = 0
			self.scrollDelta = 0
			self.payload = .init()
			self.payloadDigest = []
			self.payloadFailure = nil
		}

		internal init(form: ChromiumReferenceFormRequest) {
			self.operationID = form.operationID
			self.snapshot = form.snapshot
			self.reference = form.reference
			self.timeoutMilliseconds = form.timeoutMilliseconds

			self.scrollAxis = 0
			self.scrollDelta = 0

			let value: String
			let maximum: Int
			switch form.action {
			case let .replaceText(text):
				self.kind = 1
				value = text
				maximum = 32_768

			case let .selectValue(option):
				self.kind = 2
				value = option
				maximum = 4_096

			case let .keyPress(key):
				self.kind = 4
				value = key
				maximum = 32

			case let .pointer(action):
				self.kind = action.kind
				value = action.payload ?? ""
				maximum = 512

			case let .typeText(text):
				self.kind = 64
				value = text
				maximum = 1_024

			case let .keyChord(key, modifiers):
				self.kind = 128
				value = "\(modifiers.rawValue):\(key)"
				maximum = 40

			case let .selectValues(values):
				self.kind = 256
				value = Self.selectValuesPayload(values) ?? ""
				maximum = 4_096

			case let .setChecked(checked):
				self.kind = 512
				value = checked ? "1" : "0"
				maximum = 1
			}

			// Prefix before copying/hashing: a malformed caller cannot cause an
			// unbounded temporary conversion or a full scan for a rejected value.
			let bytes = Data(value.utf8.prefix(maximum + 1))
			self.payload = bytes
			if bytes.count > maximum {
				self.payloadFailure = .limitExceeded
			} else if
				bytes.contains(0)
				|| (kind == 4 && !Self.isSupportedKeypress(value))
				|| (kind == 64 && !Self.isTypeable(value))
				|| (kind == 256 && value.isEmpty)
				|| (Self.chord(form.action).map { !Self.isSupportedChord($0.0, $0.1) } ?? false)
				|| (Self.pointer(form.action).map { !Self.isValid($0, form) } ?? false)
			{
				self.payloadFailure = .invalidValue
			} else {
				self.payloadFailure = nil
			}

			var hash = SHA256()
			hash.update(data: Data("Arx.FormActionPayload.v1".utf8))
			for number in [UInt64(kind), UInt64(bytes.count)] {
				var number = number.littleEndian
				withUnsafeBytes(of: &number) { hash.update(bufferPointer: $0) }
			}
			hash.update(data: bytes)
			self.payloadDigest = Array(hash.finalize())
		}

		internal init(scroll: ChromiumReferenceScrollRequest) {
			self.operationID = scroll.operationID
			self.snapshot = scroll.snapshot
			self.reference = scroll.reference
			self.timeoutMilliseconds = scroll.timeoutMilliseconds
			self.kind = 3
			self.payload = .init()
			self.scrollAxis = scroll.axis == .horizontal ? 0 : 1
			self.scrollDelta = scroll.deltaCSSPixels == 0 ? 0 : scroll.deltaCSSPixels

			guard scroll.deltaCSSPixels.isFinite, abs(scroll.deltaCSSPixels) <= 8_192 else {
				self.payloadFailure = .invalidValue
				self.payloadDigest = []
				return
			}
			self.payloadFailure = nil

			var hash = SHA256()
			hash.update(data: Data("Arx.ScrollActionPayload.v1".utf8))
			for number in [UInt64(scrollAxis), scrollDelta.bitPattern] {
				var number = number.littleEndian
				withUnsafeBytes(of: &number) { hash.update(bufferPointer: $0) }
			}
			self.payloadDigest = Array(hash.finalize())
		}

		internal var isValid: Bool {
			let tokens = [snapshot.snapshotID, snapshot.documentID, snapshot.frameID, reference]
			let tokensAreValid = tokens.allSatisfy { token in
				token.utf8.count == 32 && token.utf8.allSatisfy { byte in
					(48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
				}
			}
			return tokensAreValid
			&& (1...2_000).contains(timeoutMilliseconds)
			&& snapshot.domVersion.utf8.count <= 20
			&& UInt64(snapshot.domVersion).map { $0 > 0 && String($0) == snapshot.domVersion } == true
			&& (
				snapshot.nodes.contains(where: { $0.reference == reference })
				|| (isPointer && reference == snapshot.snapshotID)
			)
		}

		private var isPointer: Bool {
			[8, 16, 32].contains(kind)
		}

		/// A JSON array of distinct option values, or nil when it can't be one.
		private static func selectValuesPayload(_ values: [String]) -> String? {
			guard
				values.count <= 64,
				Set(values).count == values.count,
				!values.contains(where: { $0.utf8.contains(0) || $0.utf16.count > 4_096 }),
				let data = ChromiumReply.encode(values)
			else { return nil }
			return String(decoding: data, as: UTF8.self)
		}

		private static func chord(_ action: ChromiumReferenceFormAction) -> (String, ChromiumKeyModifiers)? {
			guard case let .keyChord(key, modifiers) = action else { return nil }
			return (key, modifiers)
		}

		private static func isSupportedChord(_ key: String, _ modifiers: ChromiumKeyModifiers) -> Bool {
			modifiers.isSubset(of: [.shift, .control, .option, .command])
			&& (ChromiumKeyModifiers.namedKeys.contains(key) || isPrintable(key))
		}

		/// Every character must be printable; LF stands for Enter.
		private static func isTypeable(_ text: String) -> Bool {
			!text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
				scalar == "\n" || isPrintable(String(scalar))
			}
		}

		private static func isPrintable(_ value: String) -> Bool {
			guard
				value.unicodeScalars.count == 1,
				let scalar = value.unicodeScalars.first?.value
			else { return false }
			return scalar >= 0x20
			&& !(0x7F...0x9F).contains(scalar)
			&& scalar != 0x2028
			&& scalar != 0x2029
			&& scalar & 0xFFFF < 0xFFFE
		}

		private static func pointer(_ action: ChromiumReferenceFormAction) -> ChromiumPointerAction? {
			guard case let .pointer(pointer) = action else { return nil }
			return pointer
		}

		/// A point addresses the viewport through the snapshot's own ID; a real
		/// reference never takes one. Destinations belong to the same snapshot.
		private static func isValid(
			_ action: ChromiumPointerAction,
			_ form: ChromiumReferenceFormRequest
		) -> Bool {
			guard
				action.payload != nil,
				(action.point != nil) == (form.reference == form.snapshot.snapshotID)
			else { return false }
			if case let .drag(_, .reference(destination), _, _) = action {
				return form.snapshot.nodes.contains(where: { $0.reference == destination })
			}
			return true
		}

		private static func isSupportedKeypress(_ value: String) -> Bool {
			guard value.utf8.prefix(33).count <= 32 else { return false }
			let named: Set<String> = [
				"Backspace",
				"Delete",
				"ArrowLeft",
				"ArrowRight",
				"ArrowUp",
				"ArrowDown",
				"Home",
				"End",
				"Enter",
			]
			if named.contains(value) { return true }
			guard
				value.unicodeScalars.count == 1,
				let scalar = value.unicodeScalars.first?.value
			else { return false }
			return scalar >= 0x20
			&& !(0x7F...0x9F).contains(scalar)
			&& scalar != 0x2028
			&& scalar != 0x2029
			&& scalar & 0xFFFF < 0xFFFE
		}
	}
}

extension ChromiumReferenceFormDisposition {
	fileprivate init?(raw: UInt32) {
		switch raw {
		case 0: self = .notDispatched
		case 1: self = .dispatched
		case 2: self = .possiblyDispatched
		case 3: self = .unchanged
		default: return nil
		}
	}
}

private struct ChromiumReferenceFormStatus {
	internal let raw: UInt32
	internal let failure: ChromiumReferenceFormFailure?

	internal init?(raw: UInt32) {
		self.raw = raw
		switch raw {
		case 0: self.failure = nil
		case 1: self.failure = .unavailable
		case 2: self.failure = .notReady
		case 3: self.failure = .unsupportedDocument
		case 4: self.failure = .staleReference
		case 5: self.failure = .notInteractable
		case 6: self.failure = .notAuthorized
		case 7: self.failure = .busy
		case 8: self.failure = .limitExceeded
		case 9: self.failure = .duplicateOperation
		case 10: self.failure = .cancelled
		case 11: self.failure = .timedOut
		case 12: self.failure = .invalidResponse
		case 13: self.failure = .unsupportedControl
		case 14: self.failure = .invalidValue
		case 15: self.failure = .optionNotFound
		case 16: self.failure = .ambiguousOption
		case 17: self.failure = .obscured
		default: return nil
		}
	}
}

extension ChromiumReferenceFormFailure {
	fileprivate init(_ click: ChromiumReferenceClickFailure) {
		switch click {
		case .unavailable: self = .unavailable
		case .notReady: self = .notReady
		case .unsupportedDocument: self = .unsupportedDocument
		case .staleReference: self = .staleReference
		case .notInteractable: self = .notInteractable
		case .notAuthorized: self = .notAuthorized
		case .busy: self = .busy
		case .limitExceeded: self = .limitExceeded
		case .duplicateOperation: self = .duplicateOperation
		case .cancelled: self = .cancelled
		case .timedOut: self = .timedOut
		case .invalidResponse: self = .invalidResponse
		}
	}

	fileprivate var clickFailure: ChromiumReferenceClickFailure {
		switch self {
		case .unavailable: .unavailable
		case .notReady: .notReady
		case .unsupportedDocument: .unsupportedDocument
		case .staleReference: .staleReference
		case .notInteractable: .notInteractable
		case .notAuthorized: .notAuthorized
		case .busy: .busy
		case .limitExceeded: .limitExceeded
		case .duplicateOperation: .duplicateOperation
		case .cancelled: .cancelled
		case .timedOut: .timedOut
		case .invalidResponse: .invalidResponse
		case .unsupportedControl, .invalidValue, .optionNotFound, .ambiguousOption, .obscured: .invalidResponse
		}
	}
}

extension ChromiumReferenceFormResult {
	fileprivate var clickResult: ChromiumReferenceClickResult {
		let disposition: ChromiumReferenceClickDisposition = switch self.disposition {
		case .notDispatched: .notDispatched
		case .dispatched: .dispatched
		case .possiblyDispatched, .unchanged: .possiblyDispatched
		}
		return .init(
			operationID: operationID,
			disposition: disposition,
			failure: self.disposition == .unchanged ? .invalidResponse : failure?.clickFailure
		)
	}
}

// The internal shared queue uses the form result's common numeric prefix. A
// scroll reply must pass its distinct callback-family check before conversion.
extension ChromiumReferenceFormFailure {
	fileprivate init(_ scroll: ChromiumReferenceScrollFailure) {
		switch scroll {
		case .unavailable: self = .unavailable
		case .notReady: self = .notReady
		case .unsupportedDocument: self = .unsupportedDocument
		case .staleReference: self = .staleReference
		case .notInteractable: self = .notInteractable
		case .notAuthorized: self = .notAuthorized
		case .busy: self = .busy
		case .limitExceeded: self = .limitExceeded
		case .duplicateOperation: self = .duplicateOperation
		case .cancelled: self = .cancelled
		case .timedOut: self = .timedOut
		case .invalidResponse: self = .invalidResponse
		case .noScrollableContainer: self = .unsupportedControl
		case .invalidDelta: self = .invalidValue
		}
	}

	fileprivate var scrollFailure: ChromiumReferenceScrollFailure {
		switch self {
		case .unavailable: .unavailable
		case .notReady: .notReady
		case .unsupportedDocument: .unsupportedDocument
		case .staleReference: .staleReference
		case .notInteractable: .notInteractable
		case .notAuthorized: .notAuthorized
		case .busy: .busy
		case .limitExceeded: .limitExceeded
		case .duplicateOperation: .duplicateOperation
		case .cancelled: .cancelled
		case .timedOut: .timedOut
		case .invalidResponse: .invalidResponse
		case .unsupportedControl: .noScrollableContainer
		case .invalidValue: .invalidDelta
		case .optionNotFound, .ambiguousOption, .obscured: .invalidResponse
		}
	}
}

extension ChromiumReferenceFormResult {
	fileprivate var scrollResult: ChromiumReferenceScrollResult {
		let disposition: ChromiumReferenceScrollDisposition = switch self.disposition {
		case .notDispatched: .notDispatched
		case .dispatched: .dispatched
		case .possiblyDispatched: .possiblyDispatched
		case .unchanged: .unchanged
		}
		return .init(
			operationID: operationID,
			disposition: disposition,
			failure: failure?.scrollFailure
		)
	}
}
