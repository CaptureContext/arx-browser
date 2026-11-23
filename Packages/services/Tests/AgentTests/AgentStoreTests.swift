import AgentClient
import BrowserCore
import Foundation
import Testing
import _TestSupport

internal struct AgentStoreTests {
	@Test
	internal func savesListsAndDeletesPerProfile() async throws {
		let folders: AgentProfileFolders = try .temporary()
		let store: AgentConversationStore = .files(folders)
		let work: Profile.ID = .make(1)
		let personal: Profile.ID = .make(2)

		let older: AgentConversation = .make(1, in: work, updatedAt: 10)
		let newer: AgentConversation = .make(2, in: work, updatedAt: 20)
		let other: AgentConversation = .make(3, in: personal, updatedAt: 30)
		for conversation in [older, newer, other] {
			try await store.save(conversation)
		}

		#expect(try await store.list(work) == [newer, older])
		#expect(try await store.list(personal) == [other])

		try await store.delete(older.id, work)
		#expect(try await store.list(work) == [newer])
		#expect(try await store.list(personal) == [other])
	}

	@Test
	internal func neverWritesEphemeralChats() async throws {
		let folders: AgentProfileFolders = try .temporary()
		let store: AgentConversationStore = .files(folders)
		let conversation: AgentConversation = .make(1, in: .make(1), updatedAt: 1, retention: .ephemeral)

		try await store.save(conversation)

		#expect(!FileManager.default.fileExists(atPath: folders.conversation(conversation.id, in: .make(1)).path))
		#expect(try await store.list(.make(1)) == [])
	}

	@Test
	internal func ephemeralChatsExpireTwentyMinutesAfterTheirLastActivity() async throws {
		let ephemeral: AgentConversation = .make(1, in: .make(1), updatedAt: 1000, retention: .ephemeral)
		let kept: AgentConversation = .make(2, in: .make(1), updatedAt: 1000)

		#expect(ephemeral.expiresAt == Date(timeIntervalSince1970: 1000 + 20 * 60))
		#expect(!ephemeral.isExpired(at: Date(timeIntervalSince1970: 1000 + 20 * 60 - 1)))
		#expect(ephemeral.isExpired(at: Date(timeIntervalSince1970: 1000 + 20 * 60)))
		#expect(kept.expiresAt == nil)
		#expect(!kept.isExpired(at: .distantFuture))
	}

	@Test
	internal func remembersEphemeralTranscriptsUntilSwept() async throws {
		let folders: AgentProfileFolders = try .temporary()
		let store: AgentConversationStore = .files(folders)
		let ephemeral: AgentConversation = .make(1, in: .make(1), updatedAt: 1, retention: .ephemeral)
		let kept: AgentConversation = .make(2, in: .make(1), updatedAt: 1)

		try await store.started(ephemeral, resumeToken: "a")
		try await store.started(kept, resumeToken: "kept")
		try await store.rememberTranscript("b", .make(1))
		try await store.rememberTranscript("other", .make(2))
		#expect(try await store.rememberedTranscripts(.make(1)) == ["a", "b"])

		// Arx relaunches after a crash: the leftovers are discarded.
		let discarded: LockIsolated<[String]> = .init([])
		var provider: AgentProviderClient = .unavailable(.claude)
		provider.discard = { token in discarded.withValue { $0.append(token) } }
		try await store.sweep(.make(1), provider: provider)

		#expect(discarded.value == ["a", "b"])
		#expect(try await store.rememberedTranscripts(.make(1)) == [])
		#expect(try await store.rememberedTranscripts(.make(2)) == ["other"])
		#expect(!FileManager.default.fileExists(atPath: folders.transcripts(.make(1)).path))
	}

	@Test
	internal func clearsTurnsLeftBehindByACrash() async throws {
		let folders: AgentProfileFolders = try .temporary()
		let store: AgentConversationStore = .files(folders)

		// Claude's turn file and Codex's turn folder, both holding the automation credential.
		let claudeTurn: URL = folders.turns(.make(1)).appending(path: UUID().uuidString + ".json")
		let codexTurn: URL = folders.turns(.make(1)).appending(path: UUID().uuidString, directoryHint: .isDirectory)
		try folders.write(Data("{}".utf8), to: claudeTurn)
		try folders.write(Data("token".utf8), to: codexTurn.appending(path: ".codex/config.toml"))
		let otherTurn: URL = folders.turns(.make(2)).appending(path: UUID().uuidString + ".json")
		try folders.write(Data("{}".utf8), to: otherTurn)
		try await store.setSettings(.init(provider: .claude, retention: .persistent), .make(1))
		let launch: Date = Date()
		for leftover in [claudeTurn, codexTurn, otherTurn] {
			try FileManager.default.setAttributes([.creationDate: launch.addingTimeInterval(-3_600)], ofItemAtPath: leftover.path)
		}

		// A turn this run started while cleanup was still going.
		let currentTurn: URL = folders.turns(.make(1)).appending(path: UUID().uuidString + ".json")
		try folders.write(Data("{}".utf8), to: currentTurn)
		try FileManager.default.setAttributes([.creationDate: launch.addingTimeInterval(1)], ofItemAtPath: currentTurn.path)

		try await store.clearTurns(.make(1), launch)

		#expect(!FileManager.default.fileExists(atPath: claudeTurn.path))
		#expect(!FileManager.default.fileExists(atPath: codexTurn.path))
		#expect(FileManager.default.fileExists(atPath: currentTurn.path))
		#expect(FileManager.default.fileExists(atPath: otherTurn.path))
		#expect(try await store.settings(.make(1)) != nil)

		// A profile without leftovers is fine too.
		try await store.clearTurns(.make(3), launch)
	}

	@Test
	internal func endingAnEphemeralChatDiscardsAndForgetsItsTranscript() async throws {
		let folders: AgentProfileFolders = try .temporary()
		let store: AgentConversationStore = .files(folders)
		var conversation: AgentConversation = .make(1, in: .make(1), updatedAt: 1, retention: .ephemeral)
		conversation.resumeToken = "a"
		try await store.started(conversation, resumeToken: "a")

		let discarded: LockIsolated<[String]> = .init([])
		var provider: AgentProviderClient = .unavailable(.claude)
		provider.discard = { token in discarded.withValue { $0.append(token) } }
		try await store.delete(conversation, provider: provider)

		#expect(discarded.value == ["a"])
		#expect(try await store.rememberedTranscripts(.make(1)) == [])
	}

	@Test
	internal func ignoresAConversationCopiedFromAnotherProfile() async throws {
		let folders: AgentProfileFolders = try .temporary()
		let store: AgentConversationStore = .files(folders)
		let conversation: AgentConversation = .make(1, in: .make(1), updatedAt: 1)
		try await store.save(conversation)

		let copy: URL = folders.conversation(conversation.id, in: .make(2))
		try folders.prepare(copy.deletingLastPathComponent())
		try FileManager.default.copyItem(at: folders.conversation(conversation.id, in: .make(1)), to: copy)

		#expect(try await store.list(.make(2)) == [])
	}

	@Test
	internal func keepsFilesPrivate() async throws {
		let folders: AgentProfileFolders = try .temporary()
		let store: AgentConversationStore = .files(folders)
		let conversation: AgentConversation = .make(1, in: .make(1), updatedAt: 1)
		try await store.save(conversation)

		let file: URL = folders.conversation(conversation.id, in: .make(1))
		#expect(try permissions(file) == 0o600)
		#expect(try permissions(file.deletingLastPathComponent()) == 0o700)
		#expect(try permissions(folders.profile(.make(1))) == 0o700)
	}

	@Test
	internal func storesSettingsPerProfile() async throws {
		let folders: AgentProfileFolders = try .temporary()
		let store: AgentConversationStore = .files(folders)
		let settings: AgentProfileSettings = .init(
			provider: .claude,
			accountID: "default",
			modelID: "sonnet",
			retention: .persistent
		)

		try await store.setSettings(settings, .make(1))
		#expect(try await store.settings(.make(1)) == settings)
		#expect(try await store.settings(.make(2)) == nil)

		try await store.setSettings(nil, .make(1))
		#expect(try await store.settings(.make(1)) == nil)
	}

	@Test
	internal func chatsAreEphemeralUnlessChosen() async throws {
		let decoded: AgentProfileSettings = try JSONDecoder().decode(
			AgentProfileSettings.self,
			from: Data(#"{"provider":"claude"}"#.utf8)
		)

		#expect(decoded.retention == .ephemeral)
		#expect(AgentProfileSettings(provider: .claude).retention == .ephemeral)
	}

	@Test
	internal func deletingAProfileRemovesEverything() async throws {
		let folders: AgentProfileFolders = try .temporary()
		let store: AgentConversationStore = .files(folders)
		try await store.save(.make(1, in: .make(1), updatedAt: 1))
		try await store.setSettings(.init(provider: .claude), .make(1))
		try await store.save(.make(2, in: .make(2), updatedAt: 1))

		try await store.deleteProfile(.make(1))

		#expect(!FileManager.default.fileExists(atPath: folders.profile(.make(1)).path))
		#expect(try await store.list(.make(2)).count == 1)
	}

	@Test
	internal func deletingAConversationDiscardsTheProviderCopy() async throws {
		let folders: AgentProfileFolders = try .temporary()
		let store: AgentConversationStore = .files(folders)
		var conversation: AgentConversation = .make(1, in: .make(1), updatedAt: 1)
		conversation.resumeToken = "session"
		try await store.save(conversation)

		let discarded: LockIsolated<[String]> = .init([])
		var provider: AgentProviderClient = .unavailable(.claude)
		provider.discard = { token in discarded.withValue { $0.append(token) } }

		try await store.delete(conversation, provider: provider)

		#expect(discarded.value == ["session"])
		#expect(try await store.list(.make(1)) == [])
	}

	private func permissions(_ url: URL) throws -> Int {
		let attributes: [FileAttributeKey: Any] = try FileManager.default.attributesOfItem(atPath: url.path)
		return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
	}
}

// MARK: - Fixtures

extension AgentProfileFolders {
	/// A new folder outside the home folder, as every test must use.
	internal static func temporary() throws -> Self {
		let root: URL = FileManager.default.temporaryDirectory
			.appending(path: "AgentTests-" + UUID().uuidString, directoryHint: .isDirectory)
			.appending(path: "Profiles", directoryHint: .isDirectory)
		return .init(root: root)
	}
}

extension Profile.ID {
	internal static func make(_ value: UInt8) -> Self {
		.init(rawValue: .make(value))
	}
}

extension UUID {
	internal static func make(_ value: UInt8) -> Self {
		UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
	}
}

extension AgentConversation {
	internal static func make(
		_ value: UInt8,
		in profileID: Profile.ID,
		updatedAt: TimeInterval,
		retention: AgentRetention = .persistent
	) -> Self {
		.init(
			id: .init(rawValue: .make(value)),
			profileID: profileID,
			provider: .claude,
			title: "Chat \(value)",
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: updatedAt),
			retention: retention,
			messages: [
				.init(
					id: .make(value),
					role: .user,
					text: "Summarize the page",
					attachments: [.selection(text: "Hello", url: "https://example.com")],
					createdAt: Date(timeIntervalSince1970: 0)
				),
			]
		)
	}
}
