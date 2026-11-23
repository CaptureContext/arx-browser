import BrowserAutomationClient
import BrowserCore
import Foundation

/// Where agents keep each profile's files. Every profile has its own folder that only this
/// user can read, so nothing one profile's agent writes is visible to another profile.
///
/// ```text
/// <root>/<profile>/Conversations/<conversation>.json   persistent chats only
/// <root>/<profile>/Settings.json
/// <root>/<profile>/Transcripts.json   ephemeral chats' provider transcripts still to discard
/// <root>/<profile>/Workspace/        the provider's working directory, kept empty
/// <root>/<profile>/Turns/<turn>.json  a running turn's tool configuration, removed when it ends
/// ```
public struct AgentProfileFolders: Equatable, Sendable {
	public var root: URL

	public init(root: URL) {
		self.root = root
	}

	public static func live(home: URL) -> Self {
		.init(root: ArxEdition.current.namedSupport(home: home).appending(path: "Agents/Profiles", directoryHint: .isDirectory))
	}

	public func profile(_ id: Profile.ID) -> URL {
		root.appending(path: id.rawValue.uuidString, directoryHint: .isDirectory)
	}

	public func conversations(_ id: Profile.ID) -> URL {
		profile(id).appending(path: "Conversations", directoryHint: .isDirectory)
	}

	public func conversation(
		_ conversationID: AgentConversation.ID,
		in profileID: Profile.ID
	) -> URL {
		conversations(profileID).appending(path: conversationID.rawValue.uuidString + ".json")
	}

	public func settings(_ id: Profile.ID) -> URL {
		profile(id).appending(path: "Settings.json")
	}

	/// Provider transcripts of ephemeral chats that still have to be discarded.
	public func transcripts(_ id: Profile.ID) -> URL {
		profile(id).appending(path: "Transcripts.json")
	}

	public func workspace(_ id: Profile.ID) -> URL {
		profile(id).appending(path: "Workspace", directoryHint: .isDirectory)
	}

	public func turns(_ id: Profile.ID) -> URL {
		profile(id).appending(path: "Turns", directoryHint: .isDirectory)
	}

	/// Creates `directory` and its parents up to ``root``, readable only by this user.
	public func prepare(_ directory: URL) throws {
		try RealHomeGuard.check(directory)
		let manager: FileManager = .default
		try manager.createDirectory(
			at: directory,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)

		var folder: URL = directory.standardizedFileURL
		let top: String = root.standardizedFileURL.path
		while folder.path.hasPrefix(top), folder.path.count >= top.count {
			try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
			folder.deleteLastPathComponent()
		}
	}

	/// Writes `data` so only this user can read it, including while it's being written.
	public func write(
		_ data: Data,
		to file: URL
	) throws {
		try RealHomeGuard.check(file)
		try prepare(file.deletingLastPathComponent())

		let manager: FileManager = .default
		let temporary: URL = file.deletingLastPathComponent().appending(path: "." + UUID().uuidString)
		guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
		else { throw CocoaError(.fileWriteUnknown) }

		do {
			_ = try manager.replaceItemAt(file, withItemAt: temporary)
		} catch {
			try? manager.removeItem(at: temporary)
			throw error
		}
	}

	/// Removes `item` if it exists.
	public func remove(_ item: URL) throws {
		try RealHomeGuard.check(item)
		guard FileManager.default.fileExists(atPath: item.path)
		else { return }

		try FileManager.default.removeItem(at: item)
	}
}
