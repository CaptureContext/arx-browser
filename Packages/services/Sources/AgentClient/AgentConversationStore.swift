import BrowserCore
import Foundation
import _Dependencies

/// Keeps each profile's agent settings and kept chats on this Mac, inside that profile's folder.
///
/// Every call names the profile it works on, and nothing saved under one profile is listed
/// or loaded from another. Only persistent chats are written. Ephemeral chats live in memory;
/// the store only remembers their provider transcripts, so they can be discarded even after
/// a crash.
public struct AgentConversationStore: Sendable {
	/// The profile's kept chats, most recently updated first.
	public var list: @Sendable (Profile.ID) async throws -> [AgentConversation]

	/// Writes a persistent chat. An ephemeral chat is never written.
	public var save: @Sendable (AgentConversation) async throws -> Void

	public var delete: @Sendable (AgentConversation.ID, Profile.ID) async throws -> Void

	/// Deletes every chat and setting of a profile, such as when the profile is removed.
	public var deleteProfile: @Sendable (Profile.ID) async throws -> Void

	public var settings: @Sendable (Profile.ID) async throws -> AgentProfileSettings?

	public var setSettings: @Sendable (AgentProfileSettings?, Profile.ID) async throws -> Void

	/// Notes an ephemeral chat's provider transcript, as soon as its first turn starts.
	public var rememberTranscript: @Sendable (_ resumeToken: String, Profile.ID) async throws -> Void

	public var forgetTranscript: @Sendable (_ resumeToken: String, Profile.ID) async throws -> Void

	/// Transcripts noted and not yet discarded.
	public var rememberedTranscripts: @Sendable (Profile.ID) async throws -> [String]

	/// Removes the turn files and folders a profile has on disk that were made before `launch`.
	/// A turn removes its own when it ends, so only a crash or a forced quit leaves one, with the
	/// profile's automation credential in it. Anything made since belongs to a turn of this run
	/// and stays, so cleanup can run while chats start.
	public var clearTurns: @Sendable (Profile.ID, _ launch: Date) async throws -> Void

	public init(
		list: @escaping @Sendable (Profile.ID) async throws -> [AgentConversation],
		save: @escaping @Sendable (AgentConversation) async throws -> Void,
		delete: @escaping @Sendable (AgentConversation.ID, Profile.ID) async throws -> Void,
		deleteProfile: @escaping @Sendable (Profile.ID) async throws -> Void,
		settings: @escaping @Sendable (Profile.ID) async throws -> AgentProfileSettings?,
		setSettings: @escaping @Sendable (AgentProfileSettings?, Profile.ID) async throws -> Void,
		rememberTranscript: @escaping @Sendable (_ resumeToken: String, Profile.ID) async throws -> Void,
		forgetTranscript: @escaping @Sendable (_ resumeToken: String, Profile.ID) async throws -> Void,
		rememberedTranscripts: @escaping @Sendable (Profile.ID) async throws -> [String],
		clearTurns: @escaping @Sendable (Profile.ID, _ launch: Date) async throws -> Void
	) {
		self.list = list
		self.save = save
		self.delete = delete
		self.deleteProfile = deleteProfile
		self.settings = settings
		self.setSettings = setSettings
		self.rememberTranscript = rememberTranscript
		self.forgetTranscript = forgetTranscript
		self.rememberedTranscripts = rememberedTranscripts
		self.clearTurns = clearTurns
	}
}

// MARK: - Lifecycle

extension AgentConversationStore {
	/// Call when a turn reports ``AgentEvent/started(resumeToken:modelID:)``. An ephemeral chat's
	/// transcript is remembered so it's discarded later, even if Arx doesn't quit cleanly.
	public func started(
		_ conversation: AgentConversation,
		resumeToken: String
	) async throws {
		guard conversation.retention == .ephemeral
		else { return }

		try await rememberTranscript(resumeToken, conversation.profileID)
	}

	/// Ends a chat: when an ephemeral one expires or the browser quits, or when a person
	/// deletes one. Removes the chat and everything its provider kept on this Mac for it.
	public func delete(
		_ conversation: AgentConversation,
		provider: AgentProviderClient
	) async throws {
		if let resumeToken = conversation.resumeToken {
			try await provider.discard(resumeToken)
			try await forgetTranscript(resumeToken, conversation.profileID)
		}
		try await delete(conversation.id, conversation.profileID)
	}

	/// Discards every remembered ephemeral transcript of a profile. Call at launch, to clean up
	/// after a crash, and when the browser quits.
	public func sweep(
		_ profileID: Profile.ID,
		provider: AgentProviderClient
	) async throws {
		for resumeToken in try await rememberedTranscripts(profileID) {
			try await provider.discard(resumeToken)
			try await forgetTranscript(resumeToken, profileID)
		}
	}
}

// MARK: - Files

extension AgentConversationStore {
	/// JSON files under `folders`.
	public static func files(_ folders: AgentProfileFolders) -> Self {
		let transcripts: TranscriptLedger = .init(folders: folders)
		return .init(
			list: { profileID in
				let directory: URL = folders.conversations(profileID)
				guard FileManager.default.fileExists(atPath: directory.path)
				else { return [] }

				let files: [URL] = try FileManager.default.contentsOfDirectory(
					at: directory,
					includingPropertiesForKeys: nil,
					options: [.skipsHiddenFiles]
				)
				return files
					.filter { $0.pathExtension == "json" }
					.compactMap { file in
						withErrorReporting {
							try decoder.decode(AgentConversation.self, from: Data(contentsOf: file))
						}
					}

					// A file copied in from another profile's folder is ignored.
					.filter { $0.profileID == profileID && $0.retention == .persistent }
					.sorted { $0.updatedAt > $1.updatedAt }
			},
			save: { conversation in
				guard conversation.retention == .persistent
				else { return }

				try folders.write(
					try encoder.encode(conversation),
					to: folders.conversation(conversation.id, in: conversation.profileID)
				)
			},
			delete: { conversationID, profileID in
				try folders.remove(folders.conversation(conversationID, in: profileID))
			},
			deleteProfile: { profileID in
				try folders.remove(folders.profile(profileID))
			},
			settings: { profileID in
				let file: URL = folders.settings(profileID)
				guard FileManager.default.fileExists(atPath: file.path)
				else { return nil }

				return try decoder.decode(AgentProfileSettings.self, from: Data(contentsOf: file))
			},
			setSettings: { settings, profileID in
				let file: URL = folders.settings(profileID)
				guard let settings
				else { return try folders.remove(file) }

				try folders.write(try encoder.encode(settings), to: file)
			},
			rememberTranscript: { resumeToken, profileID in
				try transcripts.update(profileID) { $0.insert(resumeToken) }
			},
			forgetTranscript: { resumeToken, profileID in
				try transcripts.update(profileID) { $0.remove(resumeToken) }
			},
			rememberedTranscripts: { profileID in
				try transcripts.read(profileID).sorted()
			},
			clearTurns: { profileID, launch in
				let directory: URL = folders.turns(profileID)
				guard FileManager.default.fileExists(atPath: directory.path)
				else { return }

				let items: [URL] = try FileManager.default.contentsOfDirectory(
					at: directory,
					includingPropertiesForKeys: [.creationDateKey]
				)
				for item in items {
					// Without a creation date it can't be from this run's turns either way;
					// leaving a credential behind is worse than failing a turn.
					let created: Date = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
					guard created < launch else { continue }

					try folders.remove(item)
				}
			}
		)
	}

	fileprivate static var encoder: JSONEncoder {
		let encoder: JSONEncoder = .init()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.sortedKeys]
		return encoder
	}

	fileprivate static var decoder: JSONDecoder {
		let decoder: JSONDecoder = .init()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}
}

/// The `Transcripts.json` file of each profile. A lock keeps concurrent updates from losing entries.
private final class TranscriptLedger: Sendable {
	private let folders: AgentProfileFolders
	private let lock: NSLock = .init()

	internal init(folders: AgentProfileFolders) {
		self.folders = folders
	}

	internal func read(_ profileID: Profile.ID) throws -> Set<String> {
		lock.lock()
		defer { lock.unlock() }
		return try load(profileID)
	}

	internal func update(
		_ profileID: Profile.ID,
		_ change: (inout Set<String>) -> Void
	) throws {
		lock.lock()
		defer { lock.unlock() }

		var tokens: Set<String> = try load(profileID)
		change(&tokens)
		let file: URL = folders.transcripts(profileID)
		guard !tokens.isEmpty
		else { return try folders.remove(file) }

		try folders.write(try AgentConversationStore.encoder.encode(tokens.sorted()), to: file)
	}

	private func load(_ profileID: Profile.ID) throws -> Set<String> {
		let file: URL = folders.transcripts(profileID)
		guard FileManager.default.fileExists(atPath: file.path)
		else { return [] }

		return Set(try AgentConversationStore.decoder.decode([String].self, from: Data(contentsOf: file)))
	}
}

// MARK: - Dependency

extension AgentConversationStore: DependencyKey {
	public static var liveValue: Self {
		.files(.live(home: FileManager.default.homeDirectoryForCurrentUser))
	}

	public static var testValue: Self {
		.init(
			list: unimplemented("AgentConversationStore.list", placeholder: []),
			save: unimplemented("AgentConversationStore.save"),
			delete: unimplemented("AgentConversationStore.delete"),
			deleteProfile: unimplemented("AgentConversationStore.deleteProfile"),
			settings: unimplemented("AgentConversationStore.settings", placeholder: nil),
			setSettings: unimplemented("AgentConversationStore.setSettings"),
			rememberTranscript: unimplemented("AgentConversationStore.rememberTranscript"),
			forgetTranscript: unimplemented("AgentConversationStore.forgetTranscript"),
			rememberedTranscripts: unimplemented("AgentConversationStore.rememberedTranscripts", placeholder: []),
			clearTurns: unimplemented("AgentConversationStore.clearTurns")
		)
	}
}

extension DependencyValues {
	public var agentConversations: AgentConversationStore {
		get { self[AgentConversationStore.self] }
		set { self[AgentConversationStore.self] = newValue }
	}
}
