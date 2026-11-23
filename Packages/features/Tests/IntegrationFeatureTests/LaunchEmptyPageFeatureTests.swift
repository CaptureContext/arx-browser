import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-1234: with Open to an empty page at launch on, a launch shows no tab in any window and
/// every folder collapsed; off, it comes back to what was shown.
@Suite(.dependencies)
@MainActor
internal struct LaunchEmptyPageFeatureTests {
	private static let profile = Profile.ID(rawValue: UUID(0))
	private static let work = Space.ID(rawValue: UUID(1))
	private static let home = Space.ID(rawValue: UUID(2))
	private static let folder = Folder.ID(rawValue: UUID(3))
	private static let pinned = BrowserCore.Tab.ID(rawValue: UUID(4))
	private static let open = BrowserCore.Tab.ID(rawValue: UUID(5))
	private static let homeOpen = BrowserCore.Tab.ID(rawValue: UUID(6))
	private static let mainID = UUID(10)
	private static let secondID = UUID(20)

	@Test
	internal func launchOpensToTheEmptyPageWithEveryFolderCollapsed() throws {
		let state = Self.launch(opensEmptyPage: true)

		#expect(state.workspace.spaces.allSatisfy { $0.selectedTabID == nil })
		#expect(state.workspace.folders.allSatisfy { !$0.isExpanded })
		try state.workspace.validate()

		let windows = [state.main] + Array(state.windows)
		expectNoDifference(windows.map(\.id), [Self.mainID, Self.secondID])
		for window in windows {
			#expect(window.viewer.item.tab == nil)
			#expect(window.sidebar.selectedTab == nil)
			#expect(window.viewer.panes.allSatisfy { $0.item.tab == nil })
			#expect(window.sidebar.organization.spaces.allSatisfy { $0.selectedTabID == nil })
			try window.sidebar.organization.validate()
		}
	}

	@Test
	internal func turnedOffALaunchComesBackToWhatWasShown() {
		let state = Self.launch(opensEmptyPage: false)

		expectNoDifference(state.workspace.folders[id: Self.folder]?.isExpanded, true)
		expectNoDifference(state.main.viewer.item.tab?.id, Self.pinned)
		expectNoDifference(state.main.sidebar.selectedTab?.id, Self.pinned)
		expectNoDifference(state.windows[id: Self.secondID]?.viewer.item.tab?.id, Self.homeOpen)
	}

	@Test
	internal func theSettingsSwitchChangesTheAppWidePreference() async {
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: Self.organization(), spaceID: Self.work))
		}
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		#expect(store.state.settings.general.opensEmptyPageAtLaunch)

		await store.send(.settings(.ui(.opensEmptyPageAtLaunch(false))))
		#expect(!store.state.settings.general.opensEmptyPageAtLaunch)
		#expect(!document.preferences.opensEmptyPageAtLaunch)

		await store.send(.settings(.ui(.opensEmptyPageAtLaunch(true))))
		#expect(document.preferences.opensEmptyPageAtLaunch)
	}

	/// Window records from before DEV-822 keep no open tabs: launch infers them from their panes.
	/// Emptying the panes first must leave every window the open tabs it would have had.
	@Test(arguments: LegacyScenario.allCases)
	internal func legacyWindowsKeepTheOpenTabsTheirPanesGaveThem(_ scenario: LegacyScenario) {
		let off = Self.relaunch(scenario.records, opensEmptyPage: false)
		let on = Self.relaunch(scenario.records, opensEmptyPage: true)

		expectNoDifference(on.windowTabOwners, scenario.owners)
		expectNoDifference(on.windowTabOwners, off.windowTabOwners)
		expectNoDifference(on.windows.map(\.id), off.windows.map(\.id))
		for window in on.windows {
			expectNoDifference(window.sidebar.windowOpenTabs, off.windows[id: window.id]?.sidebar.windowOpenTabs)
		}
		expectNoDifference(on.main.sidebar.windowOpenTabs, off.main.sidebar.windowOpenTabs)
		#expect(([on.main] + Array(on.windows)).allSatisfy { $0.viewer.item.tab == nil && $0.sidebar.selectedTab == nil })
	}

	internal enum LegacyScenario: CaseIterable, Sendable {
		/// As `IndependentWindowsTests.aRecordFromBeforeKeepsTheOpenTabsItsPanesShow`.
		case aRecordKeepsTheTabItsPaneShows

		/// As `IndependentWindowsTests.olderRecordsGiveATabToTheWindowThatShowsItBeforeOneThatCachedIt`.
		case theWindowThatShowsATabGetsItBeforeOneThatCachedIt

		/// A tab another layout caches goes to the window that cached it when no window shows it.
		case aCachedTabNoWindowShowsGoesToItsWindow

		/// The main window's record shows the tab, so the older window gets nothing.
		case theMainWindowsTabStaysTheMainWindows

		fileprivate var records: [BrowserWindowPresentation] {
			// `IntegrationFeatureTests().fixture()`'s Work and Personal.
			let first = Space.ID(rawValue: UUID(1))
			let second = Space.ID(rawValue: UUID(2))
			let tab = BrowserCore.Tab.ID(rawValue: UUID(4))
			let favorite = BrowserCore.Tab.ID(rawValue: UUID(5))
			switch self {
			case .aRecordKeepsTheTabItsPaneShows:
				return [.init(
					id: UUID(50),
					activeSpaceID: first,
					spaces: [.init(id: first, panes: [.init(id: UUID(60), tabID: tab)], activePaneID: UUID(60))]
				)]

			case .theWindowThatShowsATabGetsItBeforeOneThatCachedIt:
				return [
					.init(
						id: UUID(50),
						activeSpaceID: second,
						spaces: [
							.init(id: second, panes: [.init(id: UUID(62), tabID: favorite)], activePaneID: UUID(62)),
							.init(id: first, panes: [.init(id: UUID(60), tabID: tab)], activePaneID: UUID(60)),
						]
					),
					.init(
						id: UUID(51),
						activeSpaceID: first,
						spaces: [.init(id: first, panes: [.init(id: UUID(61), tabID: tab)], activePaneID: UUID(61))]
					),
				]

			case .aCachedTabNoWindowShowsGoesToItsWindow:
				return [.init(
					id: UUID(50),
					activeSpaceID: second,
					spaces: [
						.init(id: second, panes: [.init(id: UUID(62), tabID: favorite)], activePaneID: UUID(62)),
						.init(id: first, panes: [.init(id: UUID(60), tabID: tab)], activePaneID: UUID(60)),
					]
				)]

			case .theMainWindowsTabStaysTheMainWindows:
				return [
					.init(
						id: MainFeature.State.mainWindowID,
						activeSpaceID: first,
						spaces: [.init(id: first, panes: [.init(id: UUID(70), tabID: tab)], activePaneID: UUID(70))]
					),
					.init(
						id: UUID(50),
						activeSpaceID: first,
						spaces: [.init(id: first, panes: [.init(id: UUID(60), tabID: tab)], activePaneID: UUID(60))]
					),
				]
			}
		}

		fileprivate var owners: [BrowserCore.Tab.ID: UUID] {
			let tab = BrowserCore.Tab.ID(rawValue: UUID(4))
			switch self {
			case .aRecordKeepsTheTabItsPaneShows: return [tab: UUID(50)]
			case .theWindowThatShowsATabGetsItBeforeOneThatCachedIt: return [tab: UUID(51)]
			case .aCachedTabNoWindowShowsGoesToItsWindow: return [tab: UUID(50)]
			case .theMainWindowsTabStaysTheMainWindows: return [:]
			}
		}
	}

	/// `IntegrationFeatureTests`' organization with a Favorite, relaunched with `records` and
	/// independent windows, as launch builds it.
	private static func relaunch(
		_ records: [BrowserWindowPresentation],
		opensEmptyPage: Bool
	) -> AppFeature.State {
		var organization = IntegrationFeatureTests().fixture()
		let favorite = BrowserCore.Tab(
			id: .init(rawValue: UUID(5)),
			profileID: organization.profiles[0].id,
			savedDestination: .init(title: "Mail", url: URL(string: "https://mail.example")!),
			restoration: .init(title: "Mail", url: URL(string: "https://mail.example")!)
		)
		organization.tabs.append(favorite)
		organization.profiles[0].favorites = [favorite.id]
		let space = organization.spaces[0].id
		var preferences = BrowserPreferences(windowPresentations: records)
		preferences.opensEmptyPageAtLaunch = opensEmptyPage
		LaunchEmptyPage.apply(
			to: &organization,
			preferences: &preferences,
			mainWindowID: MainFeature.State.mainWindowID,
			mainSpaceID: space
		)

		return withDependencies {
			$0.workspaceDocument = .unsaved(preferences)
		} operation: {
			var state = AppFeature.State(main: .init(organization: organization, spaceID: space))
			state.setIndependentWindows(true)
			return state
		}
	}

	/// State built as launch builds it: the saved organization and windows go through
	/// ``LaunchEmptyPage`` first, then the document and the windows are made from them.
	private static func launch(opensEmptyPage: Bool) -> AppFeature.State {
		var organization = organization()
		var preferences = BrowserPreferences(
			windowPresentations: [
				.init(
					id: mainID,
					activeSpaceID: work,
					spaces: [.init(id: work, panes: [.init(id: UUID(11), tabID: pinned)], activePaneID: UUID(11))]
				),
				.init(
					id: secondID,
					activeSpaceID: home,
					spaces: [.init(id: home, panes: [.init(id: UUID(21), tabID: homeOpen)], activePaneID: UUID(21))]
				),
			]
		)
		preferences.opensEmptyPageAtLaunch = opensEmptyPage
		LaunchEmptyPage.apply(to: &organization, preferences: &preferences, mainWindowID: mainID, mainSpaceID: work)

		return withDependencies {
			$0.workspaceDocument = .unsaved(preferences)
		} operation: {
			AppFeature.State(
				main: .init(organization: organization, spaceID: work, id: mainID),
				automation: preferences.automation
			)
		}
	}

	/// Work selects a pinned tab in an expanded folder; Home selects its open tab.
	private static func organization() -> BrowserOrganization {
		let url = URL(string: "https://capturecontext.dev")!
		return .init(
			profiles: [.init(id: profile, name: "Default")],
			spaces: [
				.init(
					id: work,
					profileID: profile,
					name: "Work",
					savedItems: [.folder(folder)],
					unpinnedTabs: [open],
					selectedTabID: pinned
				),
				.init(
					id: home,
					profileID: profile,
					name: "Home",
					unpinnedTabs: [homeOpen],
					selectedTabID: homeOpen
				),
			],
			folders: [.init(id: folder, spaceID: work, name: "Reading", children: [.tab(pinned)], isExpanded: true)],
			tabs: [
				.init(id: pinned, profileID: profile, savedDestination: .init(title: "Pin", url: url), restoration: .init(title: "Pin", url: url)),
				.init(id: open, profileID: profile, restoration: .init(title: "Open", url: url)),
				.init(id: homeOpen, profileID: profile, restoration: .init(title: "Home", url: url)),
			]
		)
	}
}
