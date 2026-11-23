import BrowserCore
import Foundation
import _Dependencies

@MainActor
public final class BrowserAutomationHost {
	public let epoch: UUID
	public let directory: URL
	public private(set) var socketPath: String?

	private let socket: LocalAutomationSocket = .init()
	private let requestTimeout: Duration
	private let clock: AnyClock<Duration>
	private var preferences: @MainActor () -> AutomationPreferences = { .init() }
	private var receive: @MainActor (AutomationHostEvent) -> Void = { _ in }
	private var authorizeResponse: @MainActor (
		AutomationRequest,
		AutomationResult
	) -> AutomationFailure? = { _, _ in .denied }
	private var focusedTab: @MainActor (AutomationClient) -> AutomationFocusedTab? = { _ in nil }
	private var changes: @MainActor (AutomationClient) -> AutomationChangeDigest? = { _ in nil }
	private var sessions: [UUID: UUID] = [:]
	private var pending: [UUID: Pending] = [:]

	/// Replies of requests that ended while no call waited for them, kept for `wait` (DEV-1024).
	private var settled: [UUID: Settled] = [:]
	private var cancelledRequests: [UUID: Set<UUID>] = [:]
	private var generation: UUID = .init()
	private var isEnabled: Bool = false
	private var sessionActivity: [UUID: AnyClock<Duration>.Instant] = [:]
	private var expiry: Task<Void, Never>?

	public init(
		directory: URL,
		epoch: UUID = UUID(),
		requestTimeout: Duration = .seconds(30),
		clock: AnyClock<Duration> = AnyClock(ContinuousClock())
	) {
		self.requestTimeout = requestTimeout
		self.clock = clock
		self.directory = directory
		self.epoch = epoch
	}

	public func configure(
		preferences: @escaping @MainActor () -> AutomationPreferences,
		receive: @escaping @MainActor (AutomationHostEvent) -> Void,
		authorizeResponse: @escaping @MainActor (AutomationRequest, AutomationResult) -> AutomationFailure? = { _, _ in .denied },
		focusedTab: @escaping @MainActor (AutomationClient) -> AutomationFocusedTab? = { _ in nil },
		changes: @escaping @MainActor (AutomationClient) -> AutomationChangeDigest? = { _ in nil }
	) {
		self.preferences = preferences
		self.receive = receive
		self.authorizeResponse = authorizeResponse
		self.focusedTab = focusedTab
		self.changes = changes
	}

	public func enable() async throws -> String {
		guard preferences().isEnabled else { throw AutomationFailure.disabled }
		if let socketPath, isEnabled { return socketPath }
		let generation = self.generation
		let path = try await socket.start(directory: directory) { [weak self] envelope in
			guard let self else { return .failure(.appUnavailable) }
			return await self.handle(envelope)
		}
		guard
			generation == self.generation,
			preferences().isEnabled,
			!Task.isCancelled
		else {
			await socket.stop()
			throw AutomationFailure.disabled
		}
		self.socketPath = path
		self.isEnabled = true
		self.expiry = Task { [weak self, clock] in
			while !Task.isCancelled {
				do { try await clock.sleep(for: .seconds(15)) } catch { return }
				guard let self else { return }
				for (id, activity) in self.sessionActivity where activity.duration(to: clock.now) > .seconds(45) {
					self.disconnect(id)
				}
				self.settled = self.settled.filter { clock.now < $0.value.expiresAt }
			}
		}
		return path
	}

	public func stop() async {
		isEnabled = false
		generation = UUID()
		expiry?.cancel()
		expiry = nil
		sessionActivity.removeAll()
		socketPath = nil
		for id in Array(pending.keys) { cancel(id, failure: .disabled) }
		settled.removeAll()
		for id in sessions.keys { receive(.disconnected(sessionID: id)) }
		sessions.removeAll()
		cancelledRequests.removeAll()
		await socket.stop()
	}

	public func revoke(_ clientID: UUID) {
		let revoked = sessions.filter { $0.value == clientID }.map(\.key)
		for sessionID in revoked { disconnect(sessionID) }
	}

	/// Called only from the app's final live authorization callback, directly before native submission.
	/// Records conservative uncertainty before any cancellation or revocation can release a reply.
	public func beginClick(_ id: UUID) -> Bool {
		guard case .click = pending[id]?.request.operation else { return false }
		return beginInteraction(id, event: .clickSubmitted(id))
	}

	public func beginForm(_ id: UUID) -> Bool {
		guard case .form = pending[id]?.request.operation else { return false }
		return beginInteraction(id, event: .formSubmitted(id))
	}

	public func beginScroll(_ id: UUID) -> Bool {
		guard case .scroll = pending[id]?.request.operation else { return false }
		return beginInteraction(id, event: .scrollSubmitted(id))
	}

	private func beginInteraction(
		_ id: UUID,
		event: AutomationHostEvent
	) -> Bool {
		guard
			var request = pending[id],
			!request.interactionSubmitted,
			isEnabled,
			preferences().isEnabled,
			preferences().authenticationLockID == nil,
			clock.now < request.deadline,
			sessions[request.sessionID] == request.client.id,
			preferences().clients.first(where: { $0.id == request.client.id }) == request.client
		else { return false }

		request.interactionSubmitted = true
		pending[id] = request
		receive(event)
		return true
	}

	public func respond(
		_ id: UUID,
		result: AutomationResult
	) {
		guard let request = pending.removeValue(forKey: id) else { return }
		request.timeout.cancel()
		let settings = preferences()

		// Preference edits precede their asynchronous revoke effect. Never release old data in that gap.
		let isClientCurrent = settings.clients.first(where: { $0.id == request.client.id }) == request.client
		&& request.client.allowsRead

		let failure: AutomationFailure?
		if !isEnabled || !settings.isEnabled {
			failure = .disabled
		} else if clock.now >= request.deadline {
			failure = .timedOut
		} else if sessions[request.sessionID] != request.client.id {
			failure = .staleSession
		} else if settings.clients.first(where: { $0.id == request.client.id })?.isPaused == true {
			// Stop on the page's agent indicator; the reply says so instead of a bare denial.
			failure = .paused
		} else if !isClientCurrent {
			failure = .denied
		} else {
			failure = authorizeResponse(request.request, result)
		}
		if settings.authenticationLockID != nil, !request.request.operation.isSignInStatusOrCancel {
			deliver(request, .failure(.authenticationProtected))
			return
		}
		if let failure {
			deliver(request, failureReply(request, failure: failure, result: result))
			return
		}

		// Bound the exact frame before releasing content. No suspension may separate
		// this check from the live authorization above.
		do {
			switch result {
			case let .wait(wait): try wait.validate()

			case let .capture(capture): try capture.validate()

			// The helper pages inspections to fit its own client; the frame bound below still applies.
			case let .inspection(inspection): try inspection.validate()

			case let .pdf(pdf): try pdf.validate()

			case let .media(media): try media.validate()

			case let .findInPage(find): try find.validate()

			case let .dialog(dialog): try dialog.validate()

			case let .script(script): try script.validate()

			case let .logs(logs): try logs.validate()

			case .inventory, .command, .click, .form, .scroll, .signIn, .batch, .data, .link, .load, .settings, .passwordSignIn, .failure:
				break
			}
			let replySize = try JSONEncoder().encode(AutomationIPC.Reply.result(result)).count
			guard replySize <= AutomationIPC.maximumResponseBytes(for: result)
			else { throw AutomationFailure.limitExceeded }

		} catch {
			deliver(
				request,
				failureReply(
					request,
					failure: error as? AutomationFailure ?? .invalidRequest,
					result: result
				)
			)
			return
		}
		if case let .inspection(inspection) = result {
			receive(
				.inspectionReleased(
					request.request,
					inspection,
					grantRevision: request.client.grantRevision
				)
			)
		}
		deliver(request, .result(result), result: result)
	}

	/// Called when Arx asks the user about a request (DEV-1024). Its call returns
	/// `waitingForUser` at once, so the helper can tell its client; the request stays
	/// open for `AutomationUserWait.limit`, and `wait` collects its result.
	public func waitForUser(
		_ id: UUID,
		_ wait: AutomationUserWait
	) {
		guard var request = pending[id], request.waitingForUser == nil else { return }
		request.timeout.cancel()
		request.timeout = expiry(id, after: AutomationUserWait.limit)
		request.deadline = clock.now.advanced(by: AutomationUserWait.limit)
		request.waitingForUser = wait
		let continuation = request.continuation
		request.continuation = nil
		pending[id] = request
		continuation?.resume(returning: .waitingForUser(wait))
	}

	/// Resumes the call waiting for the request, or keeps the reply until one asks.
	private func deliver(
		_ request: Pending,
		_ reply: AutomationIPC.Reply,
		result: AutomationResult? = nil
	) {
		// Every call listening for it hears the same reply: the same call made twice at once too.
		for listener in request.listeners.values {
			listener.poll.cancel()
			listener.continuation.resume(returning: reply)
		}
		if let continuation = request.continuation {
			continuation.resume(returning: reply)
			return
		}
		guard request.listeners.isEmpty else { return }

		// Bounded: the oldest kept reply goes first.
		if settled.count >= 64, let oldest = settled.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
			settled[oldest] = nil
		}
		settled[request.request.id] = .init(
			pending: request,
			result: result,
			reply: reply,
			expiresAt: clock.now.advanced(by: AutomationUserWait.limit)
		)
	}

	/// Ends a `wait` that heard nothing in its time: the request still waits for the user.
	private func release(
		_ id: UUID,
		listener: UUID
	) {
		guard
			var request = pending[id],
			let ended = request.listeners.removeValue(forKey: listener)
		else { return }
		pending[id] = request
		ended.continuation.resume(returning: .waitingForUser(request.waitingForUser ?? .init(kind: .approval, question: "")))
	}

	private func expiry(
		_ id: UUID,
		after duration: Duration
	) -> Task<Void, Never> {
		Task { [weak self, clock] in
			do {
				try await clock.sleep(for: duration)
			} catch {
				return
			}
			self?.cancel(id, failure: .timedOut)
		}
	}

	private func handle(_ envelope: AutomationIPC.Envelope) async -> AutomationIPC.Reply {
		let settings = preferences()
		guard isEnabled, settings.isEnabled else { return .failure(.disabled) }
		guard
			envelope.version == AutomationIPC.protocolVersion,
			let client = settings.clients.first(where: { $0.id == envelope.clientID }),
			AutomationSecurity.matches(token: envelope.credential, digest: client.credentialDigest)
		else { return .failure(.invalidCredential) }
		if case .hello = envelope.payload {
			guard
				envelope.epoch == nil,
				sessions[envelope.sessionID] == nil,
				sessions.count < 32,
				sessions.values.filter({ $0 == client.id }).count < 4
			else { return .failure(.invalidRequest) }

			sessions[envelope.sessionID] = client.id
			sessionActivity[envelope.sessionID] = clock.now
			receive(.connected(clientID: client.id, sessionID: envelope.sessionID))
			return .hello(epoch)
		}
		guard envelope.epoch == epoch, sessions[envelope.sessionID] == client.id
		else { return .failure(.staleSession) }

		sessionActivity[envelope.sessionID] = clock.now
		switch envelope.payload {
		case .hello:
			return .failure(.invalidRequest)

		case .ping:
			return .acknowledged

		case .grants:
			return .grants(.init(client))

		case .focusedTab:
			if client.isPaused { return .failure(.paused) }
			guard client.allowsRead, client.allowsFocusedTab else { return .failure(.denied) }
			if settings.authenticationLockID != nil { return .failure(.authenticationProtected) }
			guard let tab = focusedTab(client) else { return .failure(.notReady) }
			return .focusedTab(tab)

		case .changes:
			if client.isPaused { return .failure(.paused) }
			guard client.allowsRead else { return .failure(.denied) }
			if settings.authenticationLockID != nil { return .failure(.authenticationProtected) }
			guard
				let digest = changes(client),
				digest.tabs.count <= AutomationChangeDigest.maximumTabs
			else { return .failure(.notReady) }
			return .changes(digest)

		case .disconnect:
			disconnect(envelope.sessionID)
			return .acknowledged

		case let .cancel(id):
			guard pending[id] == nil || pending[id]?.sessionID == envelope.sessionID
			else { return .failure(.denied) }

			guard cancelledRequests[envelope.sessionID, default: []].count < 256 else {
				disconnect(envelope.sessionID)
				return .failure(.limitExceeded)
			}

			// Cancellation may arrive before the request on a different local connection.
			cancelledRequests[envelope.sessionID, default: []].insert(id)
			cancel(id, failure: .cancelled)
			return .acknowledged

		case let .request(id, operation):
			if settings.authenticationLockID != nil, !operation.isSignInStatusOrCancel {
				return .failure(.authenticationProtected)
			}
			if client.isPaused { return .failure(.paused) }
			guard !cancelledRequests[envelope.sessionID, default: []].contains(id)
			else { return .failure(.cancelled) }

			guard
				pending[id] == nil,
				pending.count < 16,
				pending.values.filter({ $0.sessionID == envelope.sessionID }).count < 4
			else { return .failure(.busy) }

			return await withCheckedContinuation { continuation in
				let timeout = expiry(id, after: requestTimeout)
				let request = AutomationRequest(
					id: id,
					clientID: client.id,
					sessionID: envelope.sessionID,
					operation: operation
				)
				pending[id] = .init(
					request: request,
					client: client,
					deadline: clock.now.advanced(by: requestTimeout),
					continuation: continuation,
					timeout: timeout,
					interactionSubmitted: false
				)
				receive(.request(request))
			}

		case let .wait(id, seconds):
			guard (1...20).contains(seconds) else { return .failure(.invalidRequest) }
			if settings.authenticationLockID != nil { return .failure(.authenticationProtected) }
			if let kept = settled[id] {
				guard kept.sessionID == envelope.sessionID else { return .failure(.denied) }
				settled[id] = nil
				guard clock.now < kept.expiresAt else { return .failure(.timedOut) }

				// Released only under the grant it was answered for, and what it shows of a page
				// only as Arx would release it now.
				if client.isPaused { return .failure(.paused) }
				guard client == kept.pending.client else { return .failure(.denied) }
				if case let .command(command)? = kept.result {
					// A command's outcome, without what it shows of the tab it opened or moved.
					return .result(.command(command.receipt))
				}
				if let result = kept.result, !result.isReceipt, let failure = authorizeResponse(kept.pending.request, result) {
					return failureReply(kept.pending, failure: failure, result: result)
				}
				return kept.reply
			}
			guard let request = pending[id] else { return .failure(.timedOut) }
			guard request.sessionID == envelope.sessionID else { return .failure(.denied) }
			guard
				request.waitingForUser != nil,
				request.listeners.count < 4
			else { return .failure(request.waitingForUser == nil ? .invalidRequest : .busy) }

			return await withCheckedContinuation { continuation in
				guard var request = pending[id] else {
					continuation.resume(returning: settled.removeValue(forKey: id)?.reply ?? .failure(.timedOut))
					return
				}
				let listener = UUID()
				let poll = Task { [weak self, clock] in
					do {
						try await clock.sleep(for: .seconds(seconds))
					} catch {
						return
					}
					self?.release(id, listener: listener)
				}
				request.listeners[listener] = .init(continuation: continuation, poll: poll)
				pending[id] = request
			}
		}
	}

	private func disconnect(_ sessionID: UUID) {
		sessions[sessionID] = nil
		cancelledRequests[sessionID] = nil
		sessionActivity[sessionID] = nil
		let sessionRequests = pending.filter { $0.value.sessionID == sessionID }.map(\.key)
		for id in sessionRequests { cancel(id, failure: .disconnected) }
		settled = settled.filter { $0.value.sessionID != sessionID }
		receive(.disconnected(sessionID: sessionID))
	}

	private func cancel(
		_ id: UUID,
		failure: AutomationFailure
	) {
		guard let request = pending.removeValue(forKey: id) else { return }
		request.timeout.cancel()
		receive(.cancel(id))
		deliver(request, failureReply(request, failure: failure))
	}

	private func failureReply(
		_ pending: Pending,
		failure: AutomationFailure,
		result: AutomationResult? = nil
	) -> AutomationIPC.Reply {
		if case let .scroll(request) = pending.request.operation {
			var disposition: AutomationScrollDisposition = pending.interactionSubmitted ? .possiblyDispatched : .notDispatched
			if case let .scroll(receipt) = result, receipt.operationID == request.operationID {
				disposition = receipt.disposition
			}
			return .result(.scroll(.init(
				operationID: request.operationID,
				disposition: disposition,
				failure: failure
			)))
		}
		if case let .form(request) = pending.request.operation {
			var disposition: AutomationFormDisposition = pending.interactionSubmitted ? .possiblyDispatched : .notDispatched
			if case let .form(receipt) = result, receipt.operationID == request.operationID {
				disposition = receipt.disposition
			}
			return .result(.form(.init(
				operationID: request.operationID,
				disposition: disposition,
				failure: failure
			)))
		}
		guard case let .click(request) = pending.request.operation
		else { return .failure(failure) }

		var disposition: AutomationClickDisposition = pending.interactionSubmitted ? .possiblyDispatched : .notDispatched
		if case let .click(receipt) = result, receipt.operationID == request.operationID {
			// No page data crosses this revocation/cancellation boundary. Only the
			// authenticated request's own operation acknowledgment is retained.
			disposition = receipt.disposition
		}
		return .result(.click(.init(
			operationID: request.operationID,
			disposition: disposition,
			failure: failure
		)))
	}

	private struct Pending {
		internal let request: AutomationRequest
		internal let client: AutomationClient
		internal var deadline: AnyClock<Duration>.Instant

		/// The call waiting for the reply; nil while the request waits for the user unwatched.
		internal var continuation: CheckedContinuation<AutomationIPC.Reply, Never>?
		internal var timeout: Task<Void, Never>
		internal var interactionSubmitted: Bool

		/// Set once Arx asks the user; the request then outlives its call.
		internal var waitingForUser: AutomationUserWait?

		/// The `wait` calls listening for the reply, each ended by its own poll if nothing comes.
		internal var listeners: [UUID: Listener]

		internal init(
			request: AutomationRequest,
			client: AutomationClient,
			deadline: AnyClock<Duration>.Instant,
			continuation: CheckedContinuation<AutomationIPC.Reply, Never>?,
			timeout: Task<Void, Never>,
			interactionSubmitted: Bool,
			waitingForUser: AutomationUserWait? = nil,
			listeners: [UUID: Listener] = [:]
		) {
			self.request = request
			self.client = client
			self.deadline = deadline
			self.continuation = continuation
			self.timeout = timeout
			self.interactionSubmitted = interactionSubmitted
			self.waitingForUser = waitingForUser
			self.listeners = listeners
		}

		internal var sessionID: UUID { request.sessionID }
	}

	private struct Listener {
		internal let continuation: CheckedContinuation<AutomationIPC.Reply, Never>
		internal let poll: Task<Void, Never>

		internal init(
			continuation: CheckedContinuation<AutomationIPC.Reply, Never>,
			poll: Task<Void, Never>
		) {
			self.continuation = continuation
			self.poll = poll
		}
	}

	private struct Settled {
		internal var pending: Pending

		/// The app's answer, for the live check at collection; nil for a failure reply.
		internal var result: AutomationResult?
		internal var reply: AutomationIPC.Reply
		internal var expiresAt: AnyClock<Duration>.Instant

		internal init(
			pending: Pending,
			result: AutomationResult?,
			reply: AutomationIPC.Reply,
			expiresAt: AnyClock<Duration>.Instant
		) {
			self.pending = pending
			self.result = result
			self.reply = reply
			self.expiresAt = expiresAt
		}

		internal var sessionID: UUID { pending.sessionID }
	}
}

extension AutomationCommandResult {
	/// The outcome alone: the operation, its status and its target's ID.
	fileprivate var receipt: Self {
		var receipt = self
		receipt.item = nil
		receipt.presentation = nil
		receipt.route = nil
		return receipt
	}
}

extension AutomationResult {
	/// An outcome that names only the request's own operation, which the app no longer
	/// checks once it answered (a click's receipt is released with it). Anything else carries
	/// what a page or the browser holds, or authority that lapses (a batch approval), and is
	/// checked again before a late release.
	fileprivate var isReceipt: Bool {
		switch self {
		case .click, .form, .scroll, .signIn, .passwordSignIn, .failure: true
		default: false
		}
	}
}
