import AppUI
import BrowserCore
import CommandBarFeature
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1311: the field shows the highlighted result's icon. A bang's row shows its site's stored
/// icon; only its scoped search lets the field fetch it, never in a private window.
@Suite(.dependencies)
@MainActor
internal struct CommandBarIconTests {
	// MARK: - The field's icon

	@Test
	internal func theFieldShowsAHighlightedSitesIcon() {
		let state = iconState(query: "ca", selectedID: "history-capturecontext")
		let icon = CommandBarFieldIcon(selected: state.selectedEntry?.presentation)
		expectNoDifference(icon.siteIcon, iconKey("https://capturecontext.dev/"))
		expectNoDifference(icon.symbol, "clock.arrow.circlepath")
		expectNoDifference(icon.siteIconFetch, .onScreen)
	}

	@Test
	internal func theFieldShowsAHighlightedTabsIcon() {
		let state = iconState(query: "ca", selectedID: "tab-calendar")
		let icon = CommandBarFieldIcon(selected: state.selectedEntry?.presentation)
		expectNoDifference(icon.siteIcon, iconKey("https://calendar.google.com/calendar"))
		expectNoDifference(icon.symbol, "globe")
	}

	@Test
	internal func theFieldShowsTheMagnifyingGlassForASearch() {
		let state = iconState(query: "ca", selectedID: "destination")
		let icon = CommandBarFieldIcon(selected: state.selectedEntry?.presentation)
		expectNoDifference(icon.siteIcon, nil)
		expectNoDifference(icon.symbol, "magnifyingglass")
	}

	@Test
	internal func theFieldShowsAHighlightedCommandsSymbol() {
		let state = iconState(query: "reload", selectedID: "command-reload")
		let icon = CommandBarFieldIcon(selected: state.selectedEntry?.presentation)
		expectNoDifference(icon.siteIcon, nil)
		expectNoDifference(icon.symbol, BrowserCommand.reload.symbol)
	}

	@Test
	internal func theFieldFallsBackToTheMagnifyingGlass() {
		// Nothing highlighted.
		expectNoDifference(CommandBarFieldIcon(selected: nil), .init(siteIcon: nil, symbol: "magnifyingglass"))

		// A result with no icon of its own.
		let blank = CommandBarResult(id: "blank", title: "Blank", actionTitle: "Open", symbol: "")
		expectNoDifference(CommandBarFieldIcon(selected: blank), .init(siteIcon: nil, symbol: "magnifyingglass"))

		// The host's own fallback, such as the globe over an address, while nothing is highlighted.
		expectNoDifference(
			CommandBarFieldIcon(selected: nil, fallbackSymbol: "globe"),
			.init(siteIcon: nil, symbol: "globe")
		)
	}

	@Test
	internal func theFieldFollowsTheHighlight() async throws {
		let store = TestStore(initialState: iconState(query: "ca", selectedID: "history-capturecontext")) {
			CommandBarFeature()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.highlighted("tab-calendar")))
		expectNoDifference(
			CommandBarFieldIcon(selected: store.state.selectedEntry?.presentation).siteIcon,
			iconKey("https://calendar.google.com/calendar")
		)
		await store.send(.ui(.highlighted("destination")))
		expectNoDifference(
			CommandBarFieldIcon(selected: store.state.selectedEntry?.presentation),
			.init(siteIcon: nil, symbol: "magnifyingglass")
		)
	}

	// MARK: - Bangs

	/// Typing "!" lists bangs with their sites' front pages as icons, only ever read from what's
	/// stored, highlighted or not.
	@Test
	internal func bangRowsShowTheirSitesIcon() {
		let state = iconState(query: "!", selectedID: nil)
		let rows = state.entries.filter { $0.presentation.id.hasPrefix("use-") }
		#expect(!rows.isEmpty)
		for row in rows {
			#expect(row.presentation.siteIcon?.profileID == Self.iconProfile.rawValue, "\(row.presentation.id)")
			#expect(row.presentation.siteIconFetch == .storedOnly, "\(row.presentation.id)")
			#expect(row.presentation.symbol == "magnifyingglass")
		}
		let github = state.entries.first { $0.presentation.id == "use-gh" }
		expectNoDifference(github?.presentation.siteIcon, iconKey("https://github.com/"))

		// Searching for the typed text isn't a site.
		#expect(state.entries.first { $0.presentation.id == "search-original" }?.presentation.siteIcon == nil)
	}

	/// A bang in use, typed with its query, keeps its site's icon in its one row.
	@Test
	internal func aBangInUseShowsItsSitesIcon() {
		let state = iconState(query: "!yt cats", selectedID: nil)
		let row = state.entries.first
		expectNoDifference(row?.presentation.id, "bang-yt")
		expectNoDifference(row?.presentation.siteIcon, iconKey("https://www.youtube.com/"))
		expectNoDifference(row?.presentation.siteIconFetch, .storedOnly)
	}

	/// Choosing YouTube from the "!y" list scopes the search to it, as "yt" then Tab does: the
	/// field shows YouTube's icon, which it may fetch, whatever is highlighted; leaving the scope
	/// takes it away. ("!yt" then Return opens YouTube's front page instead.)
	@Test
	internal func aScopedSearchShowsItsSitesIconInTheField() async throws {
		let store = TestStore(initialState: iconState(query: "!y", selectedID: nil)) {
			CommandBarFeature()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		#expect(store.state.scopeSiteIcon == nil)
		await store.send(.ui(.selected("use-yt")))
		expectNoDifference(store.state.siteSearchKeyword, "yt")
		expectNoDifference(store.state.scopeSiteIcon, iconKey("https://www.youtube.com/"))
		let field = CommandBarFieldIcon(
			selected: store.state.selectedEntry?.presentation,
			scope: store.state.scopeSiteIcon
		)
		expectNoDifference(field, .init(siteIcon: iconKey("https://www.youtube.com/"), symbol: "magnifyingglass"))
		expectNoDifference(field.siteIconFetch, .onScreen)

		await store.send(.ui(.queryChanged("cats")))
		expectNoDifference(store.state.scopeSiteIcon, iconKey("https://www.youtube.com/"))

		await store.send(.ui(.queryChanged("")))
		await store.send(.ui(.deletedWhenEmpty))
		await store.receive(\.ui.dismissed)
		expectNoDifference(store.state.siteSearchKeyword, nil)
		expectNoDifference(store.state.scopeSiteIcon, nil)
	}

	/// A private window has no profile to read icons from, so its bangs keep the magnifying glass.
	@Test
	internal func aPrivateWindowsBangsHaveNoIcon() async throws {
		var state = iconState(query: "!", selectedID: nil)
		state.bangIconProfileID = nil
		#expect(state.entries.allSatisfy { $0.presentation.siteIcon == nil })
		state.siteSearchKeyword = "yt"
		#expect(state.scopeSiteIcon == nil)

		let organization = IntegrationFeatureTests().fixture()
		var window = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id, isPrivate: true)
		window.viewer.item.tab = organization.tabs[0]
		let store = TestStore(initialState: window) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.openCommand(.newTab)))
		await store.receive(\.commandBar.present)
		expectNoDifference(store.state.commandBar.bangIconProfileID, nil)
	}

	/// A regular window's bangs read its profile's icons.
	@Test
	internal func aWindowsBangsReadItsProfilesIcons() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var window = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		window.viewer.item.tab = organization.tabs[0]
		let store = TestStore(initialState: window) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.openCommand(.newTab)))
		await store.receive(\.commandBar.present)
		expectNoDifference(store.state.commandBar.bangIconProfileID, organization.spaces[0].profileID)
	}

	// MARK: - Fixtures

	private static let iconProfile: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000001311")!)

	private func iconKey(_ address: String) -> SidebarItem.SiteIcon {
		.init(profileID: Self.iconProfile.rawValue, pageURL: URL(string: address)!)
	}

	private func iconState(
		query: String,
		selectedID: String?
	) -> CommandBarFeature.State {
		var state = CommandBarFeature.State(
			isPresented: true,
			mode: .newTab,
			candidates: [
				.init(
					presentation: .init(
						id: "history-capturecontext",
						title: "CaptureContext",
						subtitle: "https://capturecontext.dev/",
						actionTitle: "Open",
						symbol: "clock.arrow.circlepath",
						siteIcon: iconKey("https://capturecontext.dev/")
					),
					intent: .open(URL(string: "https://capturecontext.dev/")!)
				),
				.init(
					presentation: .init(
						id: "tab-calendar",
						title: "Google Calendar",
						subtitle: "https://calendar.google.com/calendar",
						actionTitle: "Switch to Tab",
						symbol: "globe",
						siteIcon: iconKey("https://calendar.google.com/calendar")
					),
					intent: .selectTab(.init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000ca1e")!))
				),
				.command(.reload, bindings: []),
			],
			bangs: .init(parsing: """
			gh github	GitHub	1	https://github.com/search?q={query}
			yt youtube	YouTube	1	https://www.youtube.com/results?search_query={query}
			w wiki	Wikipedia	1	https://en.wikipedia.org/wiki/Special:Search?search={query}
			""")
		)
		state.bangIconProfileID = Self.iconProfile
		state.query = query
		state.selectedID = selectedID
		return state
	}
}
