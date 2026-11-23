import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-926: how a live folder's items and badge change with each refresh.
internal struct LiveFolderContentsTests {
	private static func item(_ id: String) -> LiveFolderItem {
		.init(id: id, title: id, url: URL(string: "https://github.com/arx/pull/\(id)")!)
	}

	private static let now: Date = .init(timeIntervalSince1970: 1_800_000_000)

	@Test
	internal func theFirstRefreshFillsTheFolderWithoutABadge() async throws {
		let contents = LiveFolderContents().refreshed(with: [Self.item("a"), Self.item("b"), Self.item("a")], at: Self.now)
		expectNoDifference(contents.items.map(\.id), ["a", "b"])
		#expect(contents.badgeCount == 0)
		#expect(contents.refreshedAt == Self.now)
	}

	@Test
	internal func newItemsBadgeUntilSeenAndGoneOnesTakeTheirBadge() async throws {
		var contents = LiveFolderContents().refreshed(with: [Self.item("a")], at: Self.now)
		contents = contents.refreshed(with: [Self.item("c"), Self.item("b"), Self.item("a")], at: Self.now + 60)
		#expect(contents.unseen == ["b", "c"])
		#expect(contents.badgeCount == 2)

		// "c" was merged: it leaves the folder and the badge.
		contents = contents.refreshed(with: [Self.item("b"), Self.item("a")], at: Self.now + 120)
		#expect(contents.badgeCount == 1)

		contents = contents.markingSeen()
		#expect(contents.badgeCount == 0)
		// Seen stays seen.
		contents = contents.refreshed(with: [Self.item("b"), Self.item("a")], at: Self.now + 180)
		#expect(contents.badgeCount == 0)
	}

	@Test
	internal func aFailedRefreshKeepsTheItems() async throws {
		let contents = LiveFolderContents().refreshed(with: [Self.item("a")], at: Self.now).failed(.unauthorized)
		expectNoDifference(contents.items.map(\.id), ["a"])
		#expect(contents.failure == .unauthorized)
		#expect(contents.refreshed(with: [Self.item("a")], at: Self.now + 60).failure == nil)
	}

	@Test
	internal func configurationsRoundTrip() async throws {
		let configuration = LiveFolderConfiguration(folderID: .init(rawValue: UUID()), source: .gitHubPullRequests(.reviewRequested))
		let decoded = try JSONDecoder().decode(LiveFolderConfiguration.self, from: JSONEncoder().encode(configuration))
		expectNoDifference(decoded, configuration)
		#expect(configuration.source.service == .gitHub)
	}
}
