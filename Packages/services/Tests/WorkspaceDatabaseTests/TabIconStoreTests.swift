import BrowserCore
import Foundation
import Testing
import WorkspaceDatabase
import _SQLiteData
import _TestSupport

/// A tab's chosen icon is part of its stored record (DEV-1251).
internal struct TabIconStoreTests {
	@Test
	internal func iconsOfPinsFavoritesAndOpenTabsSurviveAReopenedStore() async throws {
		let directory: TemporaryDirectory = try .init()
		var organization: BrowserOrganization = Fixture.organization
		let pin: Tab.ID = try #require(organization.spaces[0].savedItems.firstTab)
		let favorite: Tab.ID = try #require(organization.profiles.first { !$0.favorites.isEmpty }?.favorites.first)
		let open: Tab.ID = try #require(organization.spaces[0].unpinnedTabs.first)
		organization.tabs[id: pin]?.icon = .star
		organization.tabs[id: favorite]?.icon = .init(emoji: "🍲")
		organization.tabs[id: open]?.icon = .init(symbol: "flame.fill")
		try directory.open().save(Fixture.organization, preferences: Fixture.preferences)
		try directory.open().save(organization, preferences: Fixture.preferences)

		let loaded: BrowserOrganization? = try directory.open().load()?.organization

		expectNoDifference(loaded, organization)
		expectNoDifference(loaded?.tabs[id: pin]?.icon, .star)
		expectNoDifference(loaded?.tabs[id: favorite]?.icon, .init(emoji: "🍲"))
		expectNoDifference(loaded?.tabs[id: open]?.icon, .init(symbol: "flame.fill"))
	}

	@Test
	internal func aResetIconIsGoneFromTheStore() async throws {
		let directory: TemporaryDirectory = try .init()
		var organization: BrowserOrganization = Fixture.organization
		let pin: Tab.ID = try #require(organization.spaces[0].savedItems.firstTab)
		organization.tabs[id: pin]?.icon = .star
		let database: WorkspaceDatabase = try directory.open()
		try database.save(organization, preferences: Fixture.preferences)

		organization.tabs[id: pin]?.icon = nil
		try database.save(organization, preferences: Fixture.preferences)

		expectNoDifference(try directory.open().load()?.organization.tabs[id: pin]?.icon, nil)
	}

	/// An icon this build can't read, as a newer Mac could sync, leaves the site's icon rather
	/// than failing the workspace.
	@Test
	internal func anUnreadableIconLeavesTheSitesIcon() async throws {
		let directory: TemporaryDirectory = try .init()
		let organization: BrowserOrganization = Fixture.organization
		let pin: Tab.ID = try #require(organization.spaces[0].savedItems.firstTab)
		let database: WorkspaceDatabase = try directory.open()
		try database.save(organization, preferences: Fixture.preferences)
		try await database.database.write { db in
			try db.execute(
				sql: #"UPDATE "pinnedTab" SET "icon" = ? WHERE lower("id") = ?"#,
				arguments: ["{not json", pin.rawValue.uuidString.lowercased()]
			)
		}

		let loaded: BrowserOrganization? = try directory.open().load()?.organization

		#expect(loaded?.tabs[id: pin] != nil)
		expectNoDifference(loaded?.tabs[id: pin]?.icon, nil)
	}
}

extension [SavedItem] {
	fileprivate var firstTab: Tab.ID? {
		lazy.compactMap { item -> Tab.ID? in
			guard case let .tab(id) = item else { return nil }
			return id
		}
		.first
	}
}
