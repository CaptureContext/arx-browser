import BrowserCore
import CustomDump
import Foundation
import Testing
import _TestSupport
@testable import MigrationAssistant

/// Version 2 adds opt-in history and Tab Archive sections and an extension list.
internal struct ArxTransferVersion2Tests {
	private static func id(_ value: Int) -> UUID {
		UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
	}

	private static let profileID: Profile.ID = .init(rawValue: id(1))
	private static let spaceID: Space.ID = .init(rawValue: id(2))
	private static let goneSpaceID: Space.ID = .init(rawValue: id(3))
	private static let group: UUID = id(40)

	/// One space with a regular tab, two tabs closed together from it, and one
	/// closed from a space that no longer exists.
	private static func source() -> BrowserOrganization {
		func archived(
			_ number: Int,
			_ url: String,
			space: Space.ID,
			name: String,
			index: Int,
			group: UUID = group
		) -> ArchivedTab {
			.init(
				id: .init(rawValue: id(number)),
				groupID: group,
				closedAt: Date(timeIntervalSince1970: TimeInterval(number * 100)),
				originalSpaceID: space,
				originalSpaceName: name,
				originalIndex: index,
				tab: .init(
					id: .init(rawValue: id(number + 1)),
					profileID: profileID,
					restoration: .init(title: "Closed \(number) 🗂", url: URL(string: url)!),
					customTitle: number == 30 ? "Named" : nil
				)
			)
		}

		let open: BrowserCore.Tab = .init(
			id: .init(rawValue: id(10)),
			profileID: profileID,
			restoration: .init(title: "Open", url: URL(string: "https://open.example.org")!)
		)
		return .init(
			profiles: [.init(id: profileID, name: "Personal")],
			spaces: [.init(id: spaceID, profileID: profileID, name: "Work", unpinnedTabs: [open.id])],
			tabs: [open],
			archive: [
				archived(30, "https://closed.example.org/a", space: spaceID, name: "Work", index: 1),
				archived(32, "https://closed.example.org/a", space: spaceID, name: "Work", index: 0),
				archived(34, "https://gone.example.org", space: goneSpaceID, name: "Old", index: 4, group: id(41)),
			]
		)
	}

	private static func history() -> BrowsingHistorySnapshot {
		.init(
			profileID: profileID,
			entries: [
				.init(id: id(50), url: URL(string: "https://newest.example.org")!, title: "Newest ✨", lastVisited: Date(timeIntervalSince1970: 2_000)),
				.init(id: id(51), url: URL(string: "https://older.example.org")!, title: "Older", lastVisited: Date(timeIntervalSince1970: 1_000)),
			]
		)
	}

	private static let extensions: [Profile.ID: [BrowserExtension]] = [
		profileID: [
			.init(id: "aaaabbbbccccddddeeeeffffgggghhhh", name: "Store Extension", version: "1", fromWebStore: true, state: .enabled),
			.init(id: "iiiijjjjkkkkllllmmmmnnnnoooopppp", name: "Unpacked", version: "1", state: .disabled),
		],
	]

	private static func clean() -> BrowserOrganization {
		let profile = Profile.ID(rawValue: id(90))
		return .init(
			profiles: [.init(id: profile, name: "Fresh")],
			spaces: [.init(id: .init(rawValue: id(91)), profileID: profile, name: "Start")]
		)
	}

	private static let destination: MigrationDestination = .init(
		profileID: .init(rawValue: id(90)),
		spaceID: .init(rawValue: id(91)),
		defaultRoute: .newProfile
	)

	private func archive(
		history: Bool,
		archivedTabs: Bool
	) -> ArxTransferArchive {
		ArxTransferArchive(
			organization: Self.source(),
			preferences: .init(),
			createdAt: Date(timeIntervalSince1970: 1_000),
			appVersion: "2.0",
			history: history ? [Self.history()] : nil,
			includesArchivedTabs: archivedTabs,
			extensions: Self.extensions
		)
	}

	private func file(_ data: Data) throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = directory.appending(path: "Archive.json")
		try data.write(to: url)
		return url
	}

	private func run(
		_ url: URL,
		into destination: FixtureDestination
	) async throws -> (MigrationSource, MigrationReport) {
		let client = MigrationAssistantClient.running(adapters: [], writer: destination.writer)
		let source = try await client.addFile(url)
		let preview = try await client.inspect(source.id, source.categories, Self.destination)
		var report: MigrationReport?
		for try await event in client.execute(.init(id: .init(rawValue: UUID()), preview: preview)) {
			if case let .finished(value) = event { report = value }
		}
		return (source, try #require(report))
	}

	@Test
	internal func historyAndTheTabArchiveStayOutUnlessIncluded() throws {
		let archive = archive(history: false, archivedTabs: false)
		let text = String(decoding: try archive.encoded(), as: UTF8.self)

		expectNoDifference(archive.version, 2)
		expectNoDifference(archive.categories, ["organization", "preferences", "extensions"])
		#expect(archive.history == nil)
		#expect(archive.archivedTabs == nil)
		#expect(!text.contains("newest.example.org"))
		#expect(!text.contains("closed.example.org"))
		expectNoDifference(archive.extensions?.map(\.name), ["Store Extension", "Unpacked"])
		expectNoDifference(archive.importableCategories, [.favorites, .bookmarks, .openTabs, .extensions, .preferences])
	}

	@Test
	internal func theSummarySaysWhatWasIncluded() {
		let summary = archive(history: true, archivedTabs: true).summary

		expectNoDifference(summary.historyEntries, 2)
		expectNoDifference(summary.archivedTabs, 3)
		expectNoDifference(summary.extensions, 2)
	}

	@Test
	internal func includedHistoryAndArchivedTabsRoundTrip() async throws {
		let destination = FixtureDestination(Self.clean())
		let url = try file(try archive(history: true, archivedTabs: true).encoded())

		let (source, report) = try await run(url, into: destination)

		expectNoDifference(
			source.categories,
			[.favorites, .bookmarks, .openTabs, .archivedTabs, .history, .extensions, .preferences]
		)
		expectNoDifference(report.outcome, .completed)
		let organization = destination.organization.value
		try organization.validate()

		let profile = try #require(organization.profiles.first { $0.name == "Personal" })
		let work = try #require(organization.spaces.first { $0.name == "Work" })
		expectNoDifference(work.profileID, profile.id)
		expectNoDifference(
			organization.archive.map { [$0.tab.restoration.title, $0.tab.restoration.url.absoluteString, $0.tab.customTitle ?? "-", $0.originalSpaceName, "\($0.originalIndex)"] },
			[
				["Closed 30 🗂", "https://closed.example.org/a", "Named", "Work", "1"],
				["Closed 32 🗂", "https://closed.example.org/a", "-", "Work", "0"],
				["Closed 34 🗂", "https://gone.example.org", "-", "Start", "4"],
			]
		)
		expectNoDifference(organization.archive.map(\.closedAt.timeIntervalSince1970), [3_000, 3_200, 3_400])
		expectNoDifference(organization.archive.map(\.groupID), [Self.group, Self.group, Self.id(41)])
		expectNoDifference(organization.archive.map(\.originalSpaceID.rawValue)[0], work.id.rawValue)
		#expect(organization.archive.allSatisfy { !organization.tabs.ids.contains($0.tab.id) })
		// A space that wasn't exported falls back to the destination space and its profile.
		expectNoDifference(organization.archive[2].tab.profileID.rawValue, Self.id(90))

		let history = destination.history.value
		expectNoDifference(Array(history.keys), [profile.id])
		expectNoDifference(
			history[profile.id]?.map { [$0.url.absoluteString, $0.title, "\($0.lastVisited.timeIntervalSince1970)"] },
			[["https://newest.example.org", "Newest ✨", "2000.0"], ["https://older.example.org", "Older", "1000.0"]]
		)

		let extensions = try #require(report.categories.first { $0.category == .extensions })
		expectNoDifference(extensions.status, .committed)
		expectNoDifference(extensions.imported, [])
		expectNoDifference(
			extensions.issues.map(\.reason),
			[
				.reinstallManually(.init(id: "aaaabbbbccccddddeeeeffffgggghhhh", name: "Store Extension", fromWebStore: true)),
				.reinstallManually(.init(id: "iiiijjjjkkkkllllmmmmnnnnoooopppp", name: "Unpacked", fromWebStore: false)),
			]
		)
	}

	@Test
	internal func importingTheSameArchiveAgainAddsNothing() async throws {
		let destination = FixtureDestination(Self.clean())
		let url = try file(try archive(history: true, archivedTabs: true).encoded())
		_ = try await run(url, into: destination)
		let before = destination.organization.value
		let historyCommits = destination.commits.value.filter { $0.category == .history }.count

		let (_, again) = try await run(url, into: destination)

		expectNoDifference(again.importedCount, 0)
		expectNoDifference(destination.organization.value, before)
		expectNoDifference(destination.commits.value.filter { $0.category == .history }.count, historyCommits)

		// Nothing left to commit, so the category isn't run at all.
		#expect(!again.categories.contains { $0.category == .history })
	}

	@Test
	internal func aVersion1ArchiveStillImports() async throws {
		let version1 = """
		{
		  "format": "dev.capturecontext.arx.transfer",
		  "version": 1,
		  "createdAt": "2026-11-04T12:00:00Z",
		  "categories": ["organization", "preferences"],
		  "profiles": [{ "id": "00000000-0000-0000-0000-000000000001", "name": "Old", "favorites": [] }],
		  "spaces": [{
		    "id": "00000000-0000-0000-0000-000000000002",
		    "profileID": "00000000-0000-0000-0000-000000000001",
		    "name": "Space",
		    "pinned": [],
		    "regular": [{
		      "id": "00000000-0000-0000-0000-000000000003",
		      "title": "Tab",
		      "currentURL": "https://old.example.org",
		      "currentTitle": "Tab"
		    }]
		  }]
		}
		"""
		let destination = FixtureDestination(Self.clean())

		let (source, report) = try await run(try file(Data(version1.utf8)), into: destination)

		expectNoDifference(source.categories, [.favorites, .bookmarks, .openTabs, .preferences])
		expectNoDifference(report.outcome, .completed)
		expectNoDifference(
			destination.organization.value.tabs.map(\.restoration.url.absoluteString),
			["https://old.example.org"]
		)
	}

	@Test
	internal func entriesWithoutAUsableDateAreReportedNotImported() {
		let record = MigrationRecord(
			sourceItemID: "h",
			category: .history,
			title: "No date",
			url: "https://example.org"
		)
		let archived = MigrationRecord(
			sourceItemID: "a",
			category: .archivedTabs,
			title: "Bad",
			url: "https://example.org",
			archived: .init(groupID: "g", closedAt: .now, index: -1)
		)

		for record in [record, archived] {
			guard case let .failure(issue) = record.validated(from: .init(rawValue: "x")) else {
				Issue.record("\(record.sourceItemID) must not import.")
				continue
			}
			expectNoDifference(issue.reason, .invalidDate)
		}
	}
}
