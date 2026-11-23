import AgentClient
import Foundation
import Synchronization
import _ComposableArchitecture

/// Writes kept chats in the order the reducer asked for them.
///
/// Each save runs in its own effect, and effects don't run in the order they start. Without
/// this, a chat saved as its turn started, with its reply still empty, could land after the
/// save of its finished or failed turn and replace it. A save numbered before one that already
/// came in for the same chat is dropped, and a newer one waits for the one being written.
public final class ChatSaves: Sendable {
	private struct Chat {
		/// The newest save asked for.
		var requested: Int

		/// The save being written, which the next one waits for.
		var writing: Task<Void, Never>?
	}

	private let serials: Mutex<Int> = .init(0)
	private let chats: Mutex<[AgentConversation.ID: Chat]> = .init([:])

	public init() {}

	/// The next save's number. The reducer takes it as it asks for the save, so the numbers
	/// follow the actions.
	internal func next() -> Int {
		serials.withLock { serial in
			serial += 1
			return serial
		}
	}

	/// Writes `conversation` unless a newer save of it came in first, after the save before it.
	/// It returns once the chat's newest save is written, its own or the one that replaced it,
	/// so whatever runs after a save, such as the provider after a turn's first one, finds the
	/// chat on disk.
	internal func save(
		_ conversation: AgentConversation,
		serial: Int,
		with write: @escaping @Sendable (AgentConversation) async throws -> Void
	) async {
		let id: AgentConversation.ID = conversation.id
		chats.withLock { chats in
			let previous: Chat? = chats[id]
			if let previous, previous.requested >= serial { return }

			let waited: Task<Void, Never>? = previous?.writing
			let task: Task<Void, Never> = .init { [self] in
				await waited?.value

				// A newer save came in while this one waited: it writes instead.
				guard self.chats.withLock({ $0[id]?.requested == serial })
				else { return }

				await withErrorReporting { try await write(conversation) }
			}
			chats[id] = .init(requested: serial, writing: task)
		}

		// Each write waits for the one before it, so the newest one ends last.
		var awaited: Task<Void, Never>?
		while let newest = chats.withLock({ $0[id]?.writing }), newest != awaited {
			await newest.value
			awaited = newest
		}
	}

	/// The newest save asked for `id`, for tests that wait for a save to come in.
	internal func requested(_ id: AgentConversation.ID) -> Int? {
		chats.withLock { $0[id]?.requested }
	}
}

extension ChatSaves: DependencyKey {
	public static let liveValue: ChatSaves = .init()

	/// A test's own, so chats with the same IDs in other tests don't order its saves.
	public static var testValue: ChatSaves { .init() }
}

extension DependencyValues {
	/// The order kept chats are written in.
	public var chatSaves: ChatSaves {
		get { self[ChatSaves.self] }
		set { self[ChatSaves.self] = newValue }
	}
}

extension AgentMessage {
	/// An answer with nothing in it yet: no text, no tools and no attachments, as a reply is
	/// while its turn starts.
	internal var isEmptyReply: Bool {
		role == .assistant && text.isEmpty && tools.isEmpty && attachments.isEmpty
	}
}
