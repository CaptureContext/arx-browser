import AppUI
import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-907: unread badges on tabs and Favorites. DEV-1258: shown or hidden by the tab, its site,
/// its profile or the browser default, the most specific choice winning.
@Suite(.dependencies)
@MainActor
internal struct UnreadBadgeFeatureTests {
	@Test
	internal func aTabShowsItsSavedTitlesCountUntilItsPageReports() async throws {
		var organization = IntegrationFeatureTests().fixture()
		organization.tabs[0].restoration.title = "(2) Home / X"
		var sidebar = SidebarFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let tab = organization.tabs[0].id

		expectNoDifference(sidebar.tabItem(tab)?.unread, .init(badge: .count(2), host: "capturecontext.dev"))
		sidebar.unreadBadges[tab] = UnreadBadge.none
		#expect(sidebar.tabItem(tab)?.unread == nil)
		sidebar.unreadBadges[tab] = .dot
		expectNoDifference(sidebar.tabItem(tab)?.unread?.badge, .dot)
	}

	@Test
	internal func theTabTheSiteTheProfileAndTheBrowserDefaultChooseInThatOrder() async throws {
		var organization = IntegrationFeatureTests().fixture()
		organization.tabs[0].restoration.title = "(2) Home / X"
		let tab = organization.tabs[0].id
		let profileID = organization.tabs[0].profileID
		var sidebar = SidebarFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		expectNoDifference(sidebar.tabItem(tab)?.unreadBadges, .init(tab: nil, inherited: .show))

		// The browser default hides them.
		sidebar.showsUnreadBadges = false
		#expect(sidebar.tabItem(tab)?.unread == nil)
		expectNoDifference(sidebar.tabItem(tab)?.unreadBadges, .init(tab: nil, inherited: .hide))

		// The profile shows them over it.
		sidebar.organization.profiles[id: profileID]?.unreadBadges = .show
		expectNoDifference(sidebar.tabItem(tab)?.unread?.badge, .count(2))

		// The site hides them over the profile.
		sidebar.unreadBadgeOverrides.sites["capturecontext.dev"] = .hide
		#expect(sidebar.tabItem(tab)?.unread == nil)
		expectNoDifference(sidebar.tabItem(tab)?.unreadBadges, .init(tab: nil, inherited: .hide))

		// The tab shows them over its site.
		sidebar.unreadBadgeOverrides.tabs[tab] = .show
		expectNoDifference(sidebar.tabItem(tab)?.unread?.badge, .count(2))
		expectNoDifference(sidebar.tabItem(tab)?.unreadBadges, .init(tab: .show, inherited: .hide))

		// And hides them whatever the rest choose.
		sidebar.showsUnreadBadges = true
		sidebar.organization.profiles[id: profileID]?.unreadBadges = nil
		sidebar.unreadBadgeOverrides.sites = [:]
		sidebar.unreadBadgeOverrides.tabs[tab] = .hide
		#expect(sidebar.tabItem(tab)?.unread == nil)
	}

	@Test
	internal func everyLevelIsSavedAndReachesEveryWindow() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let tab = organization.tabs[1].id
		let profileID = organization.tabs[1].profileID
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.unreadBadgeChanged(tab, .count(4))))
		expectNoDifference(store.state.main.sidebar.tabItem(tab)?.unread?.badge, .count(4))

		// The tab's menu: hidden on this tab only, saved on this Mac.
		await store.send(.main(.sidebar(.ui(.sidebar(.setTabUnreadBadges(.tab(tab.rawValue), .hide))))))
		await store.receive(\.main.delegate.setTabUnreadBadges)
		expectNoDifference(document.preferences.unreadBadgeTabs, [tab: .hide])
		#expect(store.state.main.sidebar.tabItem(tab)?.unread == nil)
		await store.send(.main(.sidebar(.ui(.sidebar(.setTabUnreadBadges(.tab(tab.rawValue), nil))))))
		await store.receive(\.main.delegate.setTabUnreadBadges)
		expectNoDifference(document.preferences.unreadBadgeTabs, [:])
		expectNoDifference(store.state.main.sidebar.tabItem(tab)?.unread?.badge, .count(4))

		// The browser default, from Settings.
		await store.send(.settings(.ui(.showsUnreadBadges(false))))
		#expect(!document.preferences.showsUnreadBadges)
		#expect(store.state.main.sidebar.tabItem(tab)?.unread == nil)

		// The profile, from its settings, wins over it.
		await store.send(.settings(.ui(.changeOrganization(.setProfileUnreadBadges(profileID, .show)))))
		await store.receive(\.delegate.save)
		expectNoDifference(store.state.workspace.profiles[id: profileID]?.unreadBadges, .show)
		expectNoDifference(store.state.main.sidebar.organization.profiles[id: profileID]?.unreadBadges, .show)
		expectNoDifference(store.state.main.sidebar.tabItem(tab)?.unread?.badge, .count(4))

		// A site listed in Settings goes back to the default with Use Default.
		store.state.settings.$unreadBadgeOverrides.withLock { $0.sites["capturecontext.dev"] = .hide }
		await store.send(.event(.unreadBadgeChanged(tab, .count(5))))
		#expect(store.state.main.sidebar.tabItem(tab)?.unread == nil)
		await store.send(.settings(.ui(.resetUnreadBadgeSite("capturecontext.dev"))))
		expectNoDifference(document.preferences.unreadBadgeSites, [:])
		expectNoDifference(store.state.main.sidebar.tabItem(tab)?.unread?.badge, .count(5))

		// A tab that's gone keeps no report and takes no choice.
		await store.send(.event(.unreadBadgeChanged(.init(rawValue: UUID(99)), .dot)))
		#expect(store.state.unreadBadges[.init(rawValue: UUID(99))] == nil)
		await store.send(.main(.sidebar(.ui(.sidebar(.setTabUnreadBadges(.tab(UUID(99)), .hide))))))
		expectNoDifference(document.preferences.unreadBadgeTabs, [:])
	}

	@Test
	internal func theSiteMenuChoosesForTheSite() async throws {
		let document = WorkspaceDocument.unsaved()
		let profileID = Profile.ID(rawValue: UUID(1))
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			SiteMenuFeature.State()
		}
		let store = TestStore(initialState: state) { SiteMenuFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.open(.init(
			url: URL(string: "https://www.example.com/inbox")!,
			profileID: profileID,
			profileUnreadBadges: .hide
		))))
		expectNoDifference(store.state.menu?.unreadBadges, .init(site: nil, inherited: .hide))

		await store.send(.ui(.menu(.setUnreadBadges(.show))))
		expectNoDifference(document.preferences.unreadBadgeSites, ["example.com": .show])
		expectNoDifference(store.state.menu?.unreadBadges, .init(site: .show, inherited: .hide))

		await store.send(.ui(.menu(.setUnreadBadges(nil))))
		expectNoDifference(document.preferences.unreadBadgeSites, [:])

		// A private window's menu has no row and changes nothing.
		await store.send(.ui(.open(.init(
			url: URL(string: "https://example.com")!,
			profileID: profileID,
			isPrivate: true
		))))
		#expect(store.state.menu?.unreadBadges == nil)
		await store.send(.ui(.menu(.setUnreadBadges(.hide))))
		expectNoDifference(document.preferences.unreadBadgeSites, [:])
	}
}
