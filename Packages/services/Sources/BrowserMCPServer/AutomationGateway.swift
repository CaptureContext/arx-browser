import AgentToolsClient
import BrowserAutomationClient
import BrowserCore
import Foundation
import Synchronization

internal actor AutomationGateway {
	private let path: String
	private let clientID: UUID
	private let credential: String
	private let sessionID: UUID = .init()
	private let grantInterval: Duration
	private var epoch: UUID?
	private var heartbeat: Task<Void, Never>?
	private var grantsChanged: @Sendable (AutomationGrantSummary) async -> Void = { _ in }
	private var heartbeatTick: @Sendable () async -> Void = {}

	/// Documents of snapshots this connection delivered, so an act-and-observe
	/// result can tell whether its fresh snapshot is still the same document.
	private var deliveredDocuments: [String: DeliveredSnapshot] = [:]

	/// The last address seen for each tab, from inventory pages and from `openTab` and `navigate`,
	/// so an answer about a page can name its site skill.
	private var tabAddresses: [UUID: TabAddress] = [:]

	/// Site skills this connection already named; each is named once.
	private var namedSiteSkills: Set<String> = []

	/// Requests that went on waiting for the user, by their operation, so the same call again
	/// collects the open request instead of sending a new one (DEV-1024).
	private var waiting: [String: Waiting] = [:]
	internal private(set) var grants: AutomationGrantSummary = .init()

	internal init(
		path: String,
		clientID: UUID,
		credential: String,
		grantInterval: Duration = .seconds(2)
	) {
		self.path = path
		self.clientID = clientID
		self.credential = credential
		self.grantInterval = grantInterval
	}

	/// Called after the grant the helper last saw changes, so the server can tell its client.
	internal func onGrantsChanged(_ handler: @escaping @Sendable (AutomationGrantSummary) async -> Void) {
		self.grantsChanged = handler
	}

	/// Called after every successful grant poll, for work that follows the same cadence.
	internal func onHeartbeat(_ handler: @escaping @Sendable () async -> Void) {
		self.heartbeatTick = handler
	}

	/// The document a delivered snapshot belongs to, if this connection delivered it recently.
	internal func deliveredDocument(snapshotID: String) -> DeliveredSnapshot? {
		deliveredDocuments[snapshotID]
	}

	/// Every granted item, page by page, bounded so a huge workspace cannot stall the helper.
	internal func fullInventory(maximumPages: Int = 20) async -> Result<AutomationInventory, AutomationFailure> {
		var cursor: String?
		var inventory = AutomationInventory(items: [])
		for _ in 0..<maximumPages {
			switch await perform(.inventory(cursor: cursor, limit: 100)) {
			case let .inventory(page):
				inventory.items += page.items
				inventory.presentations = page.presentations
				inventory.profiles = page.profiles
				inventory.windows = page.windows
				inventory.chromeAppearance = page.chromeAppearance
				guard let next = page.nextCursor else { return .success(inventory) }
				cursor = next

			case let .failure(failure):
				return .failure(failure)

			default:
				return .failure(.invalidRequest)
			}
		}
		return .failure(.limitExceeded)
	}

	/// The granted tabs' current revisions.
	internal func changes() async -> Result<AutomationChangeDigest, AutomationFailure> {
		guard epoch != nil else { return .failure(.staleSession) }
		do {
			switch try await exchange(.changes) {
			case let .changes(digest): return .success(digest)
			case let .failure(error): return .failure(error)
			default: return .failure(.invalidRequest)
			}
		} catch {
			return .failure(error as? AutomationFailure ?? .disconnected)
		}
	}

	internal func initialize() async throws {
		guard epoch == nil else { throw AutomationFailure.staleSession }
		switch try await exchange(.hello) {
		case let .hello(epoch):
			self.epoch = epoch
			if case let .grants(grants) = try await exchange(.grants) { self.grants = grants }
			let interval = grantInterval

			// Polling the grant doubles as the keep-alive. A grant change updates the
			// session in place; only revocation or app shutdown ends it.
			self.heartbeat = Task { [weak self] in
				while !Task.isCancelled {
					do { try await Task.sleep(for: interval) } catch { return }
					guard let self, await self.refreshGrants() else { return }
				}
			}

		case let .failure(error):
			throw error

		default:
			throw AutomationFailure.invalidRequest
		}
	}

	internal func perform(_ operation: AutomationOperation) async -> AutomationResult {
		guard epoch != nil else { return .failure(.staleSession) }
		if Task.isCancelled { return interrupted(operation, failure: .cancelled, submitted: false) }

		// The same call again, after it returned waitingForUser: collect the open request.
		let key = Self.waitingKey(operation)
		let open = key.flatMap { waiting[$0] }.flatMap { $0.matches(operation) ? $0 : nil }
		let id = open?.requestID ?? UUID()
		return await withTaskCancellationHandler {
			do {
				let reply: AutomationIPC.Reply = if let open {
					.waitingForUser(open.wait)
				} else {
					try await exchange(.request(id, operation))
				}
				switch reply {
				case let .result(result):
					remember(result)
					rememberAddresses(operation, result: result)
					return result

				case let .failure(error):
					return .failure(error)

				case let .waitingForUser(wait):
					return try await waitForUser(id, operation: operation, key: key, wait: wait)

				default:
					return interrupted(operation, failure: .invalidRequest, submitted: true)
				}
			} catch is CancellationError {
				return interrupted(operation, failure: .cancelled, submitted: true)
			} catch {
				return interrupted(
					operation,
					failure: error as? AutomationFailure ?? .disconnected,
					submitted: true
				)
			}
		} onCancel: {
			Task { await self.cancel(id) }
		}
	}

	/// Waits for the user's answer in short polls, telling the client what Arx asks, until the
	/// call's limit. Past it, the request stays open in Arx and the call says so.
	private func waitForUser(
		_ id: UUID,
		operation: AutomationOperation,
		key: String?,
		wait: AutomationUserWait
	) async throws -> AutomationResult {
		let policy = Self.userWait ?? .init()
		if let key {
			// Arx keeps at most four requests a connection open, so the oldest entries are spent.
			if waiting.count >= 16, waiting[key] == nil, let oldest = waiting.min(by: { $0.value.since < $1.value.since }) {
				waiting[oldest.key] = nil
			}
			waiting[key] = .init(
				requestID: id,
				operation: operation,
				wait: wait,
				byCall: policy.call != nil,
				since: .now
			)
		}
		let deadline = ContinuousClock.now.advanced(by: policy.limit)
		var wait = wait
		while true {
			await policy.progress("Waiting for the user to " + wait.question + ".")
			let remaining = ContinuousClock.now.duration(to: deadline)
			guard remaining > .zero else { break }

			let seconds = max(1, min(Self.pollSeconds, Int(remaining.components.seconds)))
			switch try await exchange(.wait(id, seconds: seconds)) {
			case let .result(result):
				if let key { waiting[key] = nil }
				remember(result)
				rememberAddresses(operation, result: result)
				return result

			case let .failure(error):
				if let key { waiting[key] = nil }
				return interrupted(operation, failure: error, submitted: true)

			case let .waitingForUser(next):
				if !next.question.isEmpty { wait = next }
				if let key { waiting[key]?.wait = wait }

			default:
				if let key { waiting[key] = nil }
				return interrupted(operation, failure: .invalidRequest, submitted: true)
			}
		}
		policy.note.wait.withLock { $0 = wait }
		return .failure(.waitingForUser)
	}

	/// What the same call again finds an open request by. Inside a tool call: the call's tool
	/// and arguments, and which of its requests this is, since parsing may generate fields (a
	/// batch's ID, a new rule's ID) and some requests carry no operation ID. Otherwise the
	/// operation's own ID.
	private static func waitingKey(_ operation: AutomationOperation) -> String? {
		if let call = userWait?.call { return call.nextRequest() }
		if case let .batch(plan) = operation { return plan.batchID.uuidString }
		return operation.mutationID?.uuidString
	}

	private static let pollSeconds: Int = 10

	/// How long one tool call waits for the user, and how it says it waits (DEV-1024).
	internal struct UserWait: Sendable {
		internal var limit: Duration
		internal var progress: @Sendable (String) async -> Void

		/// What the call still waits for when it gives up, for its result to name.
		internal let note: Note

		/// The tool call, when the server knows it: its tool and canonical arguments.
		internal let call: Call?

		internal init(
			limit: Duration = .seconds(15),
			call: String? = nil,
			progress: @escaping @Sendable (String) async -> Void = { _ in }
		) {
			self.limit = limit
			self.progress = progress
			self.note = .init()
			self.call = call.map(Call.init)
		}

		/// Numbers the requests one tool call makes, in order.
		internal final class Call: Sendable {
			internal let identity: String
			private let count: Mutex<Int> = .init(0)

			internal init(_ identity: String) {
				self.identity = identity
			}

			internal func nextRequest() -> String {
				let index = count.withLock { value in
					defer { value += 1 }
					return value
				}
				return identity + "#" + String(index)
			}

			/// The number the next request gets.
			internal var position: Int {
				count.withLock { $0 }
			}

			/// Numbers the next request `position`, for the same call again to reach a request it
			/// made after others it no longer repeats (DEV-1072).
			internal func resume(at position: Int) {
				count.withLock { $0 = position }
			}
		}

		internal final class Note: Sendable {
			internal let wait: Mutex<AutomationUserWait?> = .init(nil)

			internal init() {}
		}
	}

	/// The current tool call's wait, set by the server around each call.
	@TaskLocal
	internal static var userWait: UserWait?

	private struct Waiting: Sendable {
		internal var requestID: UUID
		internal var operation: AutomationOperation
		internal var wait: AutomationUserWait

		/// Keyed by the call's own arguments, which already match.
		internal var byCall: Bool
		internal var since: ContinuousClock.Instant

		internal func matches(_ other: AutomationOperation) -> Bool {
			byCall || operation == other
		}
	}

	private func interrupted(
		_ operation: AutomationOperation,
		failure: AutomationFailure,
		submitted: Bool
	) -> AutomationResult {
		if case let .scroll(request) = operation {
			return .scroll(.init(
				operationID: request.operationID,
				disposition: submitted ? .possiblyDispatched : .notDispatched,
				failure: failure
			))
		}
		if case let .form(request) = operation {
			return .form(.init(
				operationID: request.operationID,
				disposition: submitted ? .possiblyDispatched : .notDispatched,
				failure: failure
			))
		}
		guard case let .click(request) = operation else { return .failure(failure) }

		// Once a local exchange starts, a lost connection cannot establish whether
		// native dispatch occurred. Never turn that ambiguity into a safe retry.
		return .click(.init(
			operationID: request.operationID,
			disposition: submitted ? .possiblyDispatched : .notDispatched,
			failure: failure
		))
	}

	internal func disconnect() async {
		heartbeat?.cancel()
		heartbeat = nil
		guard epoch != nil else { return }
		_ = try? await exchange(.disconnect)
		epoch = nil
	}

	/// Resolves the focused-tab alias in Arx at the moment of the call.
	internal func focusedTab() async -> Result<AutomationFocusedTab, AutomationFailure> {
		guard epoch != nil else { return .failure(.staleSession) }
		do {
			switch try await exchange(.focusedTab) {
			case let .focusedTab(tab): return .success(tab)
			case let .failure(error): return .failure(error)
			default: return .failure(.invalidRequest)
			}
		} catch {
			return .failure(error as? AutomationFailure ?? .disconnected)
		}
	}

	private func refreshGrants() async -> Bool {
		guard
			let reply = try? await exchange(.grants),
			case let .grants(current) = reply
		else { return false }

		if current != grants {
			grants = current

			// Snapshots read under the old grant are not evidence for the new one.
			deliveredDocuments.removeAll()
			await grantsChanged(current)
		}
		await heartbeatTick()
		return true
	}

	private func remember(_ result: AutomationResult) {
		guard case let .inspection(inspection) = result else { return }
		if deliveredDocuments.count >= 64 { deliveredDocuments.removeAll() }
		deliveredDocuments[inspection.snapshot.snapshotID] = .init(
			targetID: inspection.request.targetID,
			documentID: inspection.snapshot.documentID
		)
	}

	private func rememberAddresses(
		_ operation: AutomationOperation,
		result: AutomationResult
	) {
		switch (operation, result) {
		case let (_, .inventory(page)):
			// A tab without an http(s) address drops the one remembered for it.
			for item in page.items where item.kind == .tab {
				remember(
					item.url.flatMap(URL.init(string:)).map { TabAddress(url: $0, revision: item.revision) },
					forTab: item.id
				)
			}

		case let (.command(command), .command(receipt)) where receipt.status != .cancelled && command.action == .selectTab:
			// Arx accepts a selection only at the tab's current revision, with any alias resolved.
			tabAddresses[command.targetID]?.confirmedRevision = command.expectedRevision

		case let (.command(command), .command(receipt)) where receipt.status != .cancelled:
			guard [.openTab, .navigate].contains(command.action), let url = command.url
			else { return }

			// openTab answers with the new tab; navigate acts on its target. The new page's
			// revision isn't known until the inventory lists it.
			let tab: UUID? = command.action == .openTab ? receipt.targetID : receipt.targetID ?? command.targetID
			if let tab { remember(TabAddress(url: url, revision: nil), forTab: tab) }

		case let (.inspect(request), .inspection):
			tabAddresses[request.targetID]?.confirmedRevision = request.expectedRevision

		default:
			break
		}
	}

	/// Keeps at most 1,024 addresses: a new tab past that pushes out an older one.
	private func remember(
		_ address: TabAddress?,
		forTab id: UUID
	) {
		if address != nil, tabAddresses[id] == nil, tabAddresses.count >= 1024 {
			tabAddresses.remove(at: tabAddresses.startIndex)
		}
		tabAddresses[id] = address
	}

	/// The site skill for a tab's page that this connection hasn't named yet.
	///
	/// A page can change without the server seeing it (a link, back, the user), so the address
	/// counts only for the page it was read with. ``Page/openedNow``: `openTab` or `navigate` just
	/// set it. ``Page/confirmed``: the page this connection last read or selected, when Arx
	/// accepted that at the revision the inventory listed.
	internal func unnamedSiteSkill(
		forTab id: UUID,
		page: Page
	) -> AgentSiteSkill? {
		guard let address = tabAddresses[id]
		else { return nil }

		let isCurrent: Bool = switch page {
		case .openedNow: address.revision == nil
		case .confirmed: address.revision != nil && address.confirmedRevision == address.revision
		}
		guard isCurrent
		else { return nil }

		return AgentSiteSkill.matching(address.url).first { !namedSiteSkills.contains($0.name) }
	}

	internal func markNamed(_ skill: AgentSiteSkill) {
		namedSiteSkills.insert(skill.name)
	}

	internal enum Page: Equatable, Sendable {
		case openedNow
		case confirmed
	}

	private struct TabAddress: Sendable {
		var url: URL

		/// The tab's revision when the inventory listed this address; `nil` from `openTab` or `navigate`.
		var revision: String?

		/// The revision this connection's last successful page read or `selectTab` asked for.
		var confirmedRevision: String?
	}

	internal struct DeliveredSnapshot: Equatable, Sendable {
		internal var targetID: UUID
		internal var documentID: String

		internal init(
			targetID: UUID,
			documentID: String
		) {
			self.targetID = targetID
			self.documentID = documentID
		}
	}

	private func cancel(_ id: UUID) async { _ = try? await exchange(.cancel(id)) }

	private func exchange(_ payload: AutomationIPC.Payload) async throws -> AutomationIPC.Reply {
		try await LocalAutomationSocket.exchange(
			path: path,
			envelope: .init(
				clientID: clientID,
				credential: credential,
				sessionID: sessionID,
				epoch: epoch,
				payload: payload
			)
		)
	}
}
