import BrowserCore
import BrowserHistoryClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import MigrationAssistant
import Testing
import _ComposableArchitecture
import _TestSupport
@testable import AppFeature

/// Moves an Arx archive between two data directories the way two installs would:
/// export through AppFeature from real workspace and history stores, then import
/// through MigrationAssistant and AppFeature's commit and save path into a clean
/// directory, and read the result back from disk. Offline, with no account.
@Suite(.dependencies)
@MainActor
internal struct ArchiveRoundTripTests {
	private static func id(_ value: Int) -> UUID {
		UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
	}

	private static let profileID: Profile.ID = .init(rawValue: id(1))

	/// Nested and empty folders, Unicode, repeated URLs, a pinned tab away from its
	/// saved URL, a regular tab, a favorite and two archived tabs.
	private static func source() -> BrowserOrganization {
		let space = Space.ID(rawValue: id(3))
		func tab(
			_ number: Int,
			_ title: String,
			_ url: String,
			saved: Bool = true,
			current: String? = nil,
			custom: String? = nil
		) -> BrowserCore.Tab {
			let address = URL(string: url)!
			return .init(
				id: .init(rawValue: id(number)),
				profileID: profileID,
				savedDestination: saved ? .init(title: title, url: address) : nil,
				restoration: .init(
					title: current == nil ? title : "Moved",
					url: current.flatMap(URL.init(string:)) ?? address
				),
				customTitle: custom
			)
		}
		func archived(
			_ number: Int,
			_ url: String,
			index: Int
		) -> ArchivedTab {
			.init(
				id: .init(rawValue: id(number)),
				groupID: id(60),
				closedAt: Date(timeIntervalSince1970: TimeInterval(number * 1_000)),
				originalSpaceID: space,
				originalSpaceName: "家",
				originalIndex: index,
				tab: tab(number + 1, "Closed \(number) 🗂", url, saved: false)
			)
		}

		let inner = Folder.ID(rawValue: id(10))
		let outer = Folder.ID(rawValue: id(11))
		let empty = Folder.ID(rawValue: id(12))
		return .init(
			profiles: [.init(id: profileID, name: "Žluťoučký 🦊", favorites: [.init(rawValue: id(20))])],
			spaces: [
				.init(
					id: space,
					profileID: profileID,
					name: "家",
					icon: .house,
					savedItems: [.tab(.init(rawValue: id(21))), .folder(outer), .folder(empty), .tab(.init(rawValue: id(22)))],
					unpinnedTabs: [.init(rawValue: id(23)), .init(rawValue: id(24))]
				),
			],
			folders: [
				.init(id: outer, spaceID: space, name: "Outer", children: [.folder(inner)], isExpanded: false),
				.init(id: inner, spaceID: space, name: "Inner", children: [.tab(.init(rawValue: id(25)))]),
				.init(id: empty, spaceID: space, name: "Empty"),
			],
			tabs: [
				tab(20, "Mail", "https://mail.example.org"),
				tab(21, "Saved", "https://saved.example.org", current: "https://moved.example.org/page", custom: "My name"),
				tab(22, "Twice", "https://repeat.example.org"),
				tab(23, "Regular", "https://regular.example.org", saved: false),
				tab(24, "Regular twice", "https://repeat.example.org", saved: false),
				tab(25, "Deep ✨ & <odd>", "https://repeat.example.org"),
			],
			archive: [
				archived(40, "https://closed.example.org/a", index: 2),
				archived(42, "https://closed.example.org/b", index: 0),
			]
		)
	}

	private static func clean() -> BrowserOrganization {
		let profile = Profile.ID(rawValue: id(90))
		return .init(
			profiles: [.init(id: profile, name: "Fresh")],
			spaces: [.init(id: .init(rawValue: id(91)), profileID: profile, name: "Start")]
		)
	}

	private static let visits: [BrowsingHistoryEntry] = [
		.init(id: id(70), url: URL(string: "https://visited.example.org/ü")!, title: "Visited ✨", lastVisited: Date(timeIntervalSince1970: 3_000)),
		.init(id: id(71), url: URL(string: "https://older.example.org")!, title: "Older", lastVisited: Date(timeIntervalSince1970: 1_000)),
	]

	private func directory() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appending(path: "ArchiveRoundTrip-" + UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	private func store(
		_ organization: BrowserOrganization,
		preferences: BrowserPreferences,
		workspace: BrowserWorkspaceClient,
		history: BrowserHistoryClient,
		bridge: MigrationWorkspaceBridge = .init(finished: true),
		exportTo archive: URL? = nil
	) -> StoreOf<AppFeature> {
		// Each install has its own workspace document, as each app launch does.
		let document = WorkspaceDocument(client: workspace, organization: organization, preferences: preferences)
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(
				main: .init(organization: organization, spaceID: organization.spaces[0].id),
				automation: preferences.automation
			)
		}
		return Store(initialState: state) {
			AppFeature()
			WorkspacePersistence(workspace: workspace)
		} withDependencies: {
			$0.workspaceDocument = document
			$0.uuid = .init { UUID() }
			$0.date.now = Date(timeIntervalSince1970: 5_000)
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserHistory = history
			$0.migrationWorkspace = bridge
			$0.browserDataExportClient = .init(
				chooseDestination: { _ in archive },
				write: { data, url in try data.write(to: url, options: .atomic) }
			)
		}
	}

	/// Serves the bridge like the app's window task. Its stream ends with the task.
	private func serve(
		_ bridge: MigrationWorkspaceBridge,
		with store: StoreOf<AppFeature>
	) -> Task<Void, Never> {
		Task { @MainActor in
			for await request in bridge.requests {
				await store.send(.migrationWorkspace(.request(request))).finish()
			}
		}
	}

	private func importArchive(
		_ archive: URL,
		into store: StoreOf<AppFeature>,
		bridge: MigrationWorkspaceBridge
	) async throws -> MigrationReport {
		let client = MigrationAssistantClient.running(adapters: [], writer: bridge.writer)
		let source = try await client.addFile(archive)
		let organization = store.workspace
		let destination = MigrationDestination(
			profileID: organization.profiles[0].id,
			spaceID: organization.spaces[0].id,
			defaultRoute: .newProfile
		)
		let preview = try await client.inspect(source.id, source.categories, destination)
		var report: MigrationReport?
		for try await event in client.execute(.init(id: .init(rawValue: UUID()), preview: preview)) {
			if case let .finished(value) = event { report = value }
		}
		return try #require(report)
	}

	/// A comparable outline of one profile, since IDs differ between installs.
	private func outline(
		of organization: BrowserOrganization,
		profile: Profile.ID
	) -> [String] {
		func title(_ id: BrowserCore.Tab.ID) -> String {
			let tab = organization.tabs[id: id]!
			return [
				tab.customTitle ?? "-",
				tab.savedDestination?.title ?? "-",
				tab.savedDestination?.url.absoluteString ?? "-",
				tab.restoration.title,
				tab.restoration.url.absoluteString,
			].joined(separator: "|")
		}

		func lines(
			_ items: [SavedItem],
			_ prefix: String
		) -> [String] {
			items.flatMap { item -> [String] in
				switch item {
				case let .tab(id):
					return [prefix + title(id)]

				case let .folder(id):
					let folder = organization.folders[id: id]!
					return ["\(prefix)[\(folder.name) \(folder.isExpanded)]"] + lines(folder.children, prefix + "  ")
				}
			}
		}

		let owner = organization.profiles[id: profile]!
		return ["P \(owner.name)"]
		+ owner.favorites.map { "F " + title($0) }
		+ organization.spaces.filter { $0.profileID == profile }.flatMap { space -> [String] in
			["S \(space.name) \(space.icon?.rawValue ?? "-")"]
			+ lines(space.savedItems, "  ")
			+ space.unpinnedTabs.map { "R " + title($0) }
		}
		+ organization.archive.filter { $0.tab.profileID == profile }.map { entry in
			"A \(entry.originalSpaceName) \(entry.originalIndex) \(entry.closedAt.timeIntervalSince1970) "
			+ "\(entry.tab.restoration.title)|\(entry.tab.restoration.url.absoluteString)"
		}
	}

	@Test
	internal func anArchiveMovesBetweenTwoDataDirectories() async throws {
		let root = try directory()
		defer { try? FileManager.default.removeItem(at: root) }
		let archive = root.appending(path: "Arx Archive.json")

		// The first install: its workspace and history on disk.
		let first = root.appending(path: "First", directoryHint: .isDirectory)
		var preferences = BrowserPreferences()
		preferences.grainIntensity = 0.42
		let firstWorkspace = BrowserWorkspaceClient(file: first.appending(path: "workspace.json"))
		try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
		try firstWorkspace.save(Self.source(), preferences: preferences)
		let firstHistory = BrowserHistoryStore(directory: first.appending(path: "History"))
		_ = try await firstHistory.merge(Self.profileID, entries: Self.visits)

		let recovered = try BrowserWorkspaceClient(file: first.appending(path: "workspace.json")).loadWithRecovery()
		let exporter = store(
			try #require(recovered.organization),
			preferences: recovered.preferences,
			workspace: firstWorkspace,
			history: firstHistory.client,
			exportTo: archive
		)
		exporter.send(.browserDataExport(.includesHistoryChanged(true)))
		exporter.send(.browserDataExport(.includesArchivedTabsChanged(true)))
		await exporter.send(.ui(.exportBrowserData(.archive))).finish()
		#expect(FileManager.default.fileExists(atPath: archive.path))

		// The second install starts clean.
		let second = root.appending(path: "Second", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
		let secondFile = second.appending(path: "workspace.json")
		let secondWorkspace = BrowserWorkspaceClient(file: secondFile)
		try secondWorkspace.save(Self.clean(), preferences: .init())
		let secondHistory = BrowserHistoryStore(directory: second.appending(path: "History"))
		let bridge = MigrationWorkspaceBridge()
		let importer = store(
			Self.clean(),
			preferences: .init(),
			workspace: secondWorkspace,
			history: secondHistory.client,
			bridge: bridge
		)
		let serving = serve(bridge, with: importer)
		defer { serving.cancel() }

		let report = try await importArchive(archive, into: importer, bridge: bridge)
		expectNoDifference(report.outcome, .completed)

		// Read back from disk, as the second install would after a restart.
		let saved = try BrowserWorkspaceClient(file: secondFile).loadWithRecovery()
		let organization = try #require(saved.organization)
		try organization.validate()
		let created = try #require(organization.profiles.first { $0.name == "Žluťoučký 🦊" })
		expectNoDifference(
			outline(of: organization, profile: created.id),
			outline(of: Self.source(), profile: Self.profileID)
		)
		expectNoDifference(organization.profiles.map(\.name), ["Fresh", "Žluťoučký 🦊"])
		expectNoDifference(saved.preferences.grainIntensity, 0.42)

		let history = try await BrowserHistoryStore(directory: second.appending(path: "History")).load(created.id)
		expectNoDifference(
			history.snapshot.entries.map { [$0.url.absoluteString, $0.title, "\($0.lastVisited.timeIntervalSince1970)"] },
			[["https://visited.example.org/%C3%BC", "Visited ✨", "3000.0"], ["https://older.example.org", "Older", "1000.0"]]
		)

		let transferred = report.categories.map { ($0.category, $0.imported.count) }
		expectNoDifference(transferred.map(\.0), [.favorites, .bookmarks, .openTabs, .archivedTabs, .history, .preferences])

		// Importing the same file again adds nothing anywhere.
		let again = try await importArchive(archive, into: importer, bridge: bridge)
		expectNoDifference(again.importedCount, 0)
		expectNoDifference(try BrowserWorkspaceClient(file: secondFile).load(), organization)
		let reloaded = try await BrowserHistoryStore(directory: second.appending(path: "History")).load(created.id)
		expectNoDifference(reloaded.snapshot.entries, history.snapshot.entries)
	}
}
