import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-1234: Open to an empty page at launch.
internal struct LaunchEmptyPageTests {
	@Test
	internal func isOnByDefaultAndForOlderSaves() throws {
		#expect(BrowserPreferences().opensEmptyPageAtLaunch)
		#expect(BrowserPreferences().general.opensEmptyPageAtLaunch)

		var preferences = BrowserPreferences()
		preferences.general.opensEmptyPageAtLaunch = false
		let data = try JSONEncoder().encode(preferences)
		#expect(try !JSONDecoder().decode(BrowserPreferences.self, from: data).opensEmptyPageAtLaunch)

		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		#expect(values.removeValue(forKey: "opensEmptyPageAtLaunch") != nil)
		let older = try JSONSerialization.data(withJSONObject: values)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: older).opensEmptyPageAtLaunch)
	}

	@Test
	internal func onClearsEverySelectionAndCollapsesEveryFolder() throws {
		var organization = Self.organization()
		var preferences = BrowserPreferences(windowPresentations: Self.windows())
		try organization.validate()

		LaunchEmptyPage.apply(to: &organization, preferences: &preferences, mainWindowID: UUID(30), mainSpaceID: Self.work)

		#expect(organization.spaces.allSatisfy { $0.selectedTabID == nil })
		#expect(organization.folders.allSatisfy { !$0.isExpanded })
		// What a save checks still holds.
		try organization.validate()
		try preferences.validate()

		// Nothing else moved.
		var expected = Self.organization()
		for index in expected.spaces.indices {
			expected.spaces[index].selectedTabID = nil
		}
		for index in expected.folders.indices {
			expected.folders[index].isExpanded = false
		}
		expectNoDifference(organization, expected)

		// No saved window shows a tab, and each keeps its place and the open tabs it keeps.
		for window in preferences.windowPresentations {
			for space in window.spaces {
				expectNoDifference(space.panes.map(\.tabID), [nil])
				expectNoDifference(space.panes.map(\.id), [space.activePaneID])
				expectNoDifference(space.sanitized(in: organization), space)
			}
		}
		expectNoDifference(preferences.windowPresentations.map(\.id), Self.windows().map(\.id))
		expectNoDifference(preferences.windowPresentations.map(\.activeSpaceID), Self.windows().map(\.activeSpaceID))
		expectNoDifference(preferences.windowPresentations.map(\.openTabs), Self.windows().map(\.openTabs))
		expectNoDifference(preferences.windowPresentations.map(\.sidebarWidth), Self.windows().map(\.sidebarWidth))
	}

	@Test
	internal func offLeavesTheSavedStateAlone() {
		var organization = Self.organization()
		var preferences = BrowserPreferences(windowPresentations: Self.windows())
		preferences.opensEmptyPageAtLaunch = false

		LaunchEmptyPage.apply(to: &organization, preferences: &preferences, mainWindowID: UUID(30), mainSpaceID: Self.work)

		expectNoDifference(organization, Self.organization())
		expectNoDifference(preferences.windowPresentations, Self.windows())
	}

	// MARK: - Fixture

	private static let profile = Profile.ID(rawValue: UUID(1))
	private static let work = Space.ID(rawValue: UUID(2))
	private static let home = Space.ID(rawValue: UUID(3))
	private static let outer = Folder.ID(rawValue: UUID(4))
	private static let inner = Folder.ID(rawValue: UUID(5))
	private static let favorite = Tab.ID(rawValue: UUID(10))
	private static let pinned = Tab.ID(rawValue: UUID(11))
	private static let nested = Tab.ID(rawValue: UUID(12))
	private static let open = Tab.ID(rawValue: UUID(13))
	private static let other = Tab.ID(rawValue: UUID(14))
	private static let homeOpen = Tab.ID(rawValue: UUID(15))

	private static func tab(
		_ id: Tab.ID,
		saved: Bool
	) -> Tab {
		let url = URL(string: "https://capturecontext.dev/\(id.rawValue.uuidString)")!
		return .init(
			id: id,
			profileID: profile,
			savedDestination: saved ? .init(title: "Saved", url: url) : nil,
			restoration: .init(title: "Page", url: url)
		)
	}

	/// Two spaces of one profile: Work selects a tab in a folder, Home selects a Favorite. One
	/// folder is expanded, the one inside it collapsed, and two open tabs are a split.
	private static func organization() -> BrowserOrganization {
		.init(
			profiles: [.init(id: profile, name: "Default", favorites: [favorite])],
			spaces: [
				.init(
					id: work,
					profileID: profile,
					name: "Work",
					savedItems: [.folder(outer), .tab(pinned)],
					unpinnedTabs: [open, other],
					selectedTabID: nested
				),
				.init(
					id: home,
					profileID: profile,
					name: "Home",
					unpinnedTabs: [homeOpen],
					selectedTabID: favorite
				),
			],
			folders: [
				.init(id: outer, spaceID: work, name: "Outer", children: [.folder(inner)], isExpanded: true),
				.init(id: inner, spaceID: work, name: "Inner", children: [.tab(nested)], isExpanded: false),
			],
			tabs: [
				tab(favorite, saved: true),
				tab(pinned, saved: true),
				tab(nested, saved: true),
				tab(open, saved: false),
				tab(other, saved: false),
				tab(homeOpen, saved: false),
			],
			splits: [.init(id: .init(rawValue: UUID(20)), spaceID: work, tabIDs: [open, other])]
		)
	}

	/// The main window shows Work's split, a second window Home's open tab.
	private static func windows() -> [BrowserWindowPresentation] {
		[
			.init(
				id: UUID(30),
				activeSpaceID: work,
				spaces: [
					.init(
						id: work,
						panes: [.init(id: UUID(31), tabID: open), .init(id: UUID(32), tabID: other)],
						activePaneID: UUID(32),
						orientation: .vertical
					),
				],
				sidebarWidth: 300
			),
			.init(
				id: UUID(40),
				activeSpaceID: home,
				spaces: [.init(id: home, panes: [.init(id: UUID(41), tabID: homeOpen)], activePaneID: UUID(41))],
				openTabs: [homeOpen]
			),
		]
	}
}

extension UUID {
	fileprivate init(_ value: UInt8) {
		self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
	}
}
