import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct BrowserOrganizationTests {
	@Test
	internal func roundTripsOrderedOrganizationWithoutLoadingSessions() async throws {
		let organization = fixture()
		let data = try JSONEncoder().encode(organization)
		let restored = try JSONDecoder().decode(BrowserOrganization.self, from: data)
		try restored.validate(sessions: [])
		expectNoDifference(restored, organization)
		expectNoDifference(restored.location(of: id(4)), .pinned(id(10), folder: id(101)))
	}

	@Test
	internal func tabOrderFollowsTheSidebar() {
		let organization = fixture()

		// Favorites, saved tabs depth-first through nested folders, then open tabs.
		expectNoDifference(organization.tabOrder(in: id(10)), [id(1), id(4), id(2), id(3)])
		expectNoDifference(organization.tabOrder(in: id(20)), [id(1)])
		expectNoDifference(organization.tabOrder(in: id(30)), [])
		expectNoDifference(organization.tabOrder(in: id(99)), [])
	}

	@Test
	internal func legacyTabWithoutCustomTitleDecodesAndKeepsLiveTitleBehavior() async throws {
		let original = fixture().tabs[0]
		let encoded = try JSONEncoder().encode(original)
		var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		object.removeValue(forKey: "customTitle")
		let legacy = try JSONSerialization.data(withJSONObject: object)
		var tab = try JSONDecoder().decode(Tab.self, from: legacy)

		expectNoDifference(tab.customTitle, nil)
		expectNoDifference(tab.displayTitle, original.savedDestination?.title ?? original.restoration.title)
		tab.savedDestination = nil
		tab.restoration.title = "New page title"
		expectNoDifference(tab.displayTitle, "New page title")
	}

	@Test
	internal func favoriteCanBeSelectedAcrossSpacesInItsProfile() async throws {
		var organization = fixture()
		try organization.validate()
		expectNoDifference(organization.location(of: id(1)), .favorite(id(1)))
		organization.spaces[2].selectedTabID = id(1)
		#expect(throws: BrowserOrganization.ValidationError.invalidSelection(id(30), id(1))) {
			try organization.validate()
		}
	}

	/// A save clears a selection the space can't show instead of refusing the workspace (DEV-1261):
	/// another profile's Favorite, another space's tab, and a tab no longer held.
	@Test
	internal func repairingSelectionsClearsOnlyTheInvalidOnes() throws {
		var organization = fixture()
		organization.spaces[2].selectedTabID = id(1)
		organization.spaces[1].selectedTabID = id(3)
		let missing: Tab.ID = id(99)
		organization.spaces[0].selectedTabID = missing

		let repairs = organization.repairSelections()

		expectNoDifference(repairs, [
			.init(spaceID: id(10), tabID: missing),
			.init(spaceID: id(20), tabID: id(3)),
			.init(spaceID: id(30), tabID: id(1)),
		])
		expectNoDifference(organization.spaces.map(\.selectedTabID), [nil, nil, nil])
		try organization.validate()
		expectNoDifference(organization.repairSelections(), [])

		var valid = fixture()
		expectNoDifference(valid.repairSelections(), [])
		expectNoDifference(valid, fixture())
	}

	@Test
	internal func currentNavigationDoesNotReplaceSavedDestination() async throws {
		let saved = URL(string: "https://capturecontext.dev/start")!
		let current = URL(string: "https://capturecontext.dev/elsewhere")!
		var tab = Tab(
			id: id(1),
			profileID: id(1),
			savedDestination: .init(
				title: "Start",
				url: saved
			),
			restoration: .init(
				title: "Start",
				url: saved
			)
		)
		await expectDifference(tab) {
			tab.restoration = .init(
				title: "Elsewhere",
				url: current
			)
		} changes: {
			$0.restoration.title = "Elsewhere"
			$0.restoration.url = current
		}
		expectNoDifference(tab.reopeningURL, saved)
		tab.savedDestination = nil
		expectNoDifference(tab.reopeningURL, current)
	}

	@Test
	internal func equalURLsDoNotMergeDistinctTabs() async throws {
		let organization = fixture()
		try organization.validate()
		expectNoDifference(
			organization.tabs[0].savedDestination?.url,
			organization.tabs[1].savedDestination?.url
		)
		#expect(organization.tabs[0].id != organization.tabs[1].id)
	}

	@Test
	internal func invalidOwnershipEditRollsBack() async throws {
		var organization = fixture()
		let original = organization
		#expect(throws: BrowserOrganization.ValidationError.multipleTabLocations(id(1))) {
			try organization.update { $0.spaces[0].savedItems.append(.tab(id(1))) }
		}
		expectNoDifference(organization, original)
	}

	@Test
	internal func thrownEditRollsBack() async throws {
		enum Failure: Error, Equatable {
			case cancelled
		}
		var organization = fixture()
		let original = organization
		#expect(throws: Failure.cancelled) {
			try organization.update {
				$0.profiles[0].favorites.removeAll()
				throw Failure.cancelled
			}
		}
		expectNoDifference(organization, original)
	}

	@Test
	internal func rejectsFolderCycle() async throws {
		var organization = fixture()
		organization.folders[1].children.append(.folder(id(100)))
		#expect(throws: BrowserOrganization.ValidationError.folderCycle(id(100))) {
			try organization.validate()
		}
	}

	@Test
	internal func rejectsCrossSpaceFoldersAndCrossProfileTabs() async throws {
		var organization = fixture()
		organization.folders[1].spaceID = id(20)
		#expect(throws: BrowserOrganization.ValidationError.folderSpaceMismatch(id(101))) {
			try organization.validate()
		}
		organization = fixture()
		organization.profiles[1].favorites = [id(1)]
		#expect(throws: BrowserOrganization.ValidationError.tabProfileMismatch(id(1))) {
			try organization.validate()
		}
	}

	@Test
	internal func rejectsOrphanedEntriesAndMissingReferences() async throws {
		var organization = fixture()
		organization.profiles[0].favorites = []
		#expect(throws: BrowserOrganization.ValidationError.unplacedTab(id(1))) {
			try organization.validate()
		}
		organization = fixture()
		organization.spaces[1].savedItems = [.folder(id(199))]
		#expect(throws: BrowserOrganization.ValidationError.missingFolder(id(199))) {
			try organization.validate()
		}
	}

	@Test
	internal func requiresSavedMetadataOnlyForSavedLocations() async throws {
		var organization = fixture()
		organization.tabs[0].savedDestination = nil
		#expect(throws: BrowserOrganization.ValidationError.invalidSavedDestination(id(1))) {
			try organization.validate()
		}
		organization = fixture()
		organization.tabs[2].savedDestination = organization.tabs[0].savedDestination
		#expect(throws: BrowserOrganization.ValidationError.invalidSavedDestination(id(3))) {
			try organization.validate()
		}
	}

	@Test
	internal func preservesSessionIdentityWhenFavoritingAnUnpinnedTab() async throws {
		var organization = fixture()
		let session = BrowsingSession(id: id(1), tabID: id(3), profileID: id(1))
		try organization.update {
			$0.spaces[0].unpinnedTabs.removeAll()
			$0.tabs[2].savedDestination = .init(
				title: "Example",
				url: $0.tabs[2].restoration.url
			)
			$0.profiles[0].favorites.append(id(3))
		}
		try organization.validate(sessions: [session])
		expectNoDifference(organization.location(of: session.tabID), .favorite(id(1)))
	}

	@Test
	internal func rejectsDuplicateOrWrongProfileSessions() async throws {
		let organization = fixture()
		let session = BrowsingSession(id: id(1), tabID: id(1), profileID: id(1))
		let duplicate = BrowsingSession(id: id(2), tabID: id(1), profileID: id(1))
		#expect(throws: BrowserOrganization.ValidationError.multipleSessions(id(1))) {
			try organization.validate(sessions: [session, duplicate])
		}
		let wrongProfile = BrowsingSession(id: id(3), tabID: id(1), profileID: id(2))
		#expect(throws: BrowserOrganization.ValidationError.sessionProfileMismatch(id(3))) {
			try organization.validate(sessions: [wrongProfile])
		}
	}

	private func fixture() -> BrowserOrganization {
		let url = URL(string: "https://capturecontext.dev")!
		return .init(
			profiles: [
				.init(
					id: id(1),
					name: "Personal",
					favorites: [id(1)]
				),
				.init(
					id: id(2),
					name: "Work"
				),
			],
			spaces: [
				.init(
					id: id(10),
					profileID: id(1),
					name: "Research",
					savedItems: [.folder(id(100)), .tab(id(2))],
					unpinnedTabs: [id(3)],
					selectedTabID: id(1)
				),
				.init(
					id: id(20),
					profileID: id(1),
					name: "Reading",
					selectedTabID: id(1)
				),
				.init(
					id: id(30),
					profileID: id(2),
					name: "Work"
				),
			],
			folders: [
				.init(
					id: id(100),
					spaceID: id(10),
					name: "Projects",
					children: [.folder(id(101))]
				),
				.init(
					id: id(101),
					spaceID: id(10),
					name: "Arx",
					children: [.tab(id(4))]
				),
			],
			tabs: (1 ... 4).map { index in
				.init(
					id: id(UInt8(index)),
					profileID: id(1),
					savedDestination: index == 3
					? nil
					: .init(title: "Example", url: url),
					restoration: .init(
						title: "Example",
						url: url
					)
				)
			}
		)
	}

	private func id<Entity>(_ value: UInt8) -> BrowserID<Entity> {
		.init(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value)))
	}
}
