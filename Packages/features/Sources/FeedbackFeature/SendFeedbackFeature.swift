import BrowserCore
import DiagnosticsClient
import Foundation
import _ComposableArchitecture

/// Help › Send Feedback (DEV-1284): a kind, what happened, files, an optional email and Include
/// diagnostics, sent privately to Arx's maintainer through Arx's backend, which files it in Linear.
///
/// The draft is kept until it's sent: closing and opening again finds it as it was, files
/// included. Sent, the sheet closes at once and only the email is kept; not sent, it stays and
/// says why.
@Reducer
public struct SendFeedbackFeature {
	@ObservableState
	public struct State: Equatable, Sendable {
		public var draft: FeedbackDraft

		/// The versions the footnote names; `nil` until read.
		public var environment: DiagnosticsEnvironment?

		/// The draft was read from disk; edits before then would be lost under it.
		public var isLoaded: Bool
		public var isSending: Bool

		/// Why the report didn't go, or a file couldn't be attached. Cleared by the next edit.
		public var failure: FeedbackFailure?

		/// Files being read or made smaller, which count toward the limit already.
		public var pendingAttachments: Int

		public init(
			draft: FeedbackDraft = .init(),
			environment: DiagnosticsEnvironment? = nil,
			isLoaded: Bool = false,
			isSending: Bool = false,
			failure: FeedbackFailure? = nil,
			pendingAttachments: Int = 0
		) {
			self.draft = draft
			self.environment = environment
			self.isLoaded = isLoaded
			self.isSending = isSending
			self.failure = failure
			self.pendingAttachments = pendingAttachments
		}

		public var isEditable: Bool { isLoaded && !isSending }

		/// Not while a report is on its way or a file is being read, which closing would lose.
		public var canClose: Bool { !isSending && pendingAttachments == 0 }

		public var canAttach: Bool {
			isEditable && draft.attachments.count + pendingAttachments < SendFeedback.Limits.attachments
		}

		/// The email as it's sent: trimmed, `nil` when empty.
		public var email: String? {
			let trimmed: String = draft.email.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : trimmed
		}

		/// Whether `email` looks like an address: something, an @, and a domain with a dot.
		public static func isValid(email: String) -> Bool {
			guard email.count <= SendFeedback.Limits.emailCharacters, !email.contains(where: \.isWhitespace)
			else { return false }

			let parts: [Substring] = email.split(separator: "@", omittingEmptySubsequences: false)
			guard parts.count == 2, !parts[0].isEmpty
			else { return false }

			let domain: [Substring] = parts[1].split(separator: ".", omittingEmptySubsequences: false)
			return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			/// The sheet appeared: reads the draft and the versions.
			case task
			case kindSelected(SendFeedback.Kind)
			case messageChanged(String)
			case emailChanged(String)
			case includesDiagnostics(Bool)

			/// Files from the attach button or a drop.
			case attachFiles([URL])

			/// A picture or file from the clipboard (⌘V) or a drop, with a name for it.
			case attachData(name: String, data: Data)
			case removeAttachment(FeedbackAttachment.ID)
			case send

			/// Cancel or Escape: the draft stays for next time.
			case close
			case openPublicIssueForms
			case openPrivacyPolicy
		}

		@CasePathable
		public enum Event: Sendable {
			case loaded(FeedbackDraft, DiagnosticsEnvironment)
			case attached(Result<FeedbackAttachment, FeedbackFailure>)

			/// More files were chosen than there was room for; the rest were left out.
			case overflowed
			case sent
			case sendFailed(FeedbackFailure)
		}

		@CasePathable
		public enum Delegate: Sendable {
			case close

			/// The report went: close the sheet.
			case sent
			case open(URL)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.sendFeedback)
	private var client

	@Dependency(\.diagnostics)
	private var diagnostics

	@Dependency(\.uuid)
	private var uuid

	@Dependency(\.continuousClock)
	private var clock

	private enum CancelID: Hashable {
		case saveDraft
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.task) { state in
			guard !state.isLoaded
			else { return .none }

			return .run { [client, diagnostics] send in
				let draft: FeedbackDraft = await client.loadDraft()
				await send(.event(.loaded(draft, diagnostics.environment())))
			}
		}

		Pullback(\.event.loaded) { state, loaded in
			let (draft, environment) = loaded
			state.draft = draft
			state.environment = environment
			state.isLoaded = true
			return .none
		}

		Pullback(\.ui.kindSelected) { state, kind in
			edit(&state) { $0.kind = kind }
		}

		Pullback(\.ui.messageChanged) { state, message in
			edit(&state) { $0.message = SendFeedback.capped(message, to: SendFeedback.Limits.messageCharacters) }
		}

		Pullback(\.ui.emailChanged) { state, email in
			edit(&state) { $0.email = SendFeedback.capped(email, to: SendFeedback.Limits.emailCharacters) }
		}

		Pullback(\.ui.includesDiagnostics) { state, isOn in
			edit(&state) { $0.includesDiagnostics = isOn }
		}

		Pullback(\.ui.attachFiles) { state, urls in
			attach(&state, files: urls.map { url in .file(url) })
		}

		Pullback(\.ui.attachData) { state, file in
			attach(&state, files: [.data(name: file.name, data: file.data)])
		}

		Pullback(\.event.attached) { state, result in
			state.pendingAttachments = max(0, state.pendingAttachments - 1)
			switch result {
			case let .success(attachment):
				// Another file may have filled the room while this one was read.
				guard
					state.draft.attachments.count < SendFeedback.Limits.attachments,
					state.draft.attachmentBytes + attachment.data.count <= SendFeedback.Limits.attachmentBytes
				else {
					state.failure = state.draft.attachments.count < SendFeedback.Limits.attachments
					? .fileTooLarge(name: attachment.name, total: state.draft.attachmentBytes + attachment.data.count)
					: .tooManyFiles
					return .none
				}

				state.draft.attachments.append(attachment)
				return saveDraft(state)

			case let .failure(failure):
				state.failure = failure
				return .none
			}
		}

		Pullback(\.event.overflowed) { state in
			state.failure = .tooManyFiles
			return .none
		}

		Pullback(\.ui.removeAttachment) { state, id in
			edit(&state) { $0.attachments.removeAll { $0.id == id } }
		}

		Pullback(\.ui.send) { state in
			guard state.isEditable, state.pendingAttachments == 0
			else { return .none }

			let message: String = state.draft.message.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !message.isEmpty else {
				state.failure = .emptyMessage
				return .none
			}

			if let email = state.email, !State.isValid(email: email) {
				state.failure = .invalidEmail
				return .none
			}

			state.failure = nil
			state.isSending = true
			let draft: FeedbackDraft = state.draft
			let email: String? = state.email

			// A save still waiting would write the draft back after it was sent.
			return .merge(.cancel(id: CancelID.saveDraft), .run { [client, diagnostics] send in
				let environment: DiagnosticsEnvironment = await diagnostics.environment()
				let file: Data? = draft.includesDiagnostics
				? FeedbackForm.diagnostics(await diagnostics.diagnostics(), environment: environment)
				: nil
				do throws(FeedbackFailure) {
					try await client.send(.init(
						kind: draft.kind,
						message: message,
						email: email,
						environment: environment,
						diagnostics: file,
						attachments: draft.attachments
					))
					await client.saveDraft(draft.afterSending)
					await send(.event(.sent))
				} catch {
					await send(.event(.sendFailed(error)))
				}
			})
		}

		Pullback(\.event.sent) { state in
			state.isSending = false
			state.draft = state.draft.afterSending
			return .send(.delegate(.sent))
		}

		Pullback(\.event.sendFailed) { state, failure in
			state.isSending = false
			state.failure = failure

			// Sending cancelled any save still waiting; the draft stays for next time.
			let draft: FeedbackDraft = state.draft
			return .run { [client] _ in await client.saveDraft(draft) }
		}

		Pullback(\.ui.close) { state in

			// A report on its way, or a file being read, finishes first: closing would lose it.
			guard state.canClose
			else { return .none }

			guard state.isLoaded
			else { return .send(.delegate(.close)) }

			let draft: FeedbackDraft = state.draft
			return .concatenate(
				.cancel(id: CancelID.saveDraft),
				.run { [client] _ in await client.saveDraft(draft) },
				.send(.delegate(.close))
			)
		}

		// The page opens in a tab, so the card closes first; the draft is kept for when it opens again.
		Pullback(\.ui.openPublicIssueForms) { state in
			leave(state, to: ArxService.publicIssueForms)
		}

		Pullback(\.ui.openPrivacyPolicy) { state in
			leave(state, to: ArxService.privacyPolicy)
		}
	}

	private func leave(
		_ state: State,
		to url: URL
	) -> Effect<Action> {
		guard state.canClose
		else { return .none }

		let draft: FeedbackDraft = state.draft
		let isLoaded: Bool = state.isLoaded
		return .concatenate(
			.cancel(id: CancelID.saveDraft),
			.run { [client] _ in if isLoaded { await client.saveDraft(draft) } },
			.send(.delegate(.open(url)))
		)
	}

	// MARK: - Editing

	/// Changes the draft, clears the last failure and keeps the draft a moment later.
	private func edit(
		_ state: inout State,
		_ change: (inout FeedbackDraft) -> Void
	) -> Effect<Action> {
		guard state.isEditable
		else { return .none }

		change(&state.draft)
		state.failure = nil
		return saveDraft(state)
	}

	private func saveDraft(_ state: State) -> Effect<Action> {
		let draft: FeedbackDraft = state.draft
		return .run { [client, clock] _ in
			try await clock.sleep(for: .milliseconds(500))
			await client.saveDraft(draft)
		}
		.cancellable(id: CancelID.saveDraft, cancelInFlight: true)
	}

	private enum Incoming: Sendable {
		case file(URL)
		case data(name: String, data: Data)
	}

	/// Reads each file and makes it fit, one after another, so each knows the room left.
	private func attach(
		_ state: inout State,
		files: [Incoming]
	) -> Effect<Action> {
		guard state.isEditable, !files.isEmpty
		else { return .none }

		state.failure = nil
		let room: Int = SendFeedback.Limits.attachments - state.draft.attachments.count - state.pendingAttachments
		guard room > 0 else {
			state.failure = .tooManyFiles
			return .none
		}

		let taken: [Incoming] = Array(files.prefix(room))
		state.pendingAttachments += taken.count
		let overflow: Bool = files.count > room
		let used: Int = state.draft.attachmentBytes
		let ids: [UUID] = taken.map { _ in uuid() }
		return .run { send in
			var used: Int = used
			for (file, id) in zip(taken, ids) {
				let result: Result<FeedbackAttachment, FeedbackFailure> = Self.read(file, id: id, room: SendFeedback.Limits.attachmentBytes - used)
				if case let .success(attachment) = result { used += attachment.data.count }
				await send(.event(.attached(result)))
			}
			if overflow { await send(.event(.overflowed)) }
		}
	}

	private static func read(
		_ file: Incoming,
		id: UUID,
		room: Int
	) -> Result<FeedbackAttachment, FeedbackFailure> {
		switch file {
		case let .file(url):
			let name: String = url.lastPathComponent

			// The size first, so a film far too large isn't read into memory.
			if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 64 * 1_024 * 1_024 {
				return .failure(.fileTooLarge(name: name, total: SendFeedback.Limits.attachmentBytes - room + size))
			}
			guard let data = try? Data(contentsOf: url)
			else { return .failure(.unreadableFile(name: name)) }

			return FeedbackAttachments.attachment(id: id, name: name, data: data, room: room)

		case let .data(name, data):
			return FeedbackAttachments.attachment(id: id, name: name, data: data, room: room)
		}
	}
}
