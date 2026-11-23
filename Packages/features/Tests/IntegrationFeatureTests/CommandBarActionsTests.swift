import AppFeature
import BrowserCore
import CommandBarFeature
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// ⌘K's contextual actions in the command bar, and open tabs and history listed apart (DEV-810).
@Suite(.dependencies)
@MainActor
internal struct CommandBarActionsTests {
	private let profile: Profile.ID = .init(rawValue: UUID(1))
	private let space: Space.ID = .init(rawValue: UUID(2))
	private let tabID: BrowserCore.Tab.ID = .init(rawValue: UUID(3))
	private let otherTabID: BrowserCore.Tab.ID = .init(rawValue: UUID(4))
	private let openURL: URL = URL(string: "https://capturecontext.dev/open")!
	private let otherTabURL: URL = URL(string: "https://capturecontext.dev/other")!
	private let siteURL: URL = URL(string: "https://www.example.com/a")!
	private let siblingURL: URL = URL(string: "https://Example.com/b")!

	// MARK: - Listing

	@Test
	internal func aHistoryResultFollowsTheTabShowingItsPage() {
		let state = CommandBarFeature.State(mode: .newTab, candidates: candidates())
		expectNoDifference(
			state.entries.map(\.presentation.id),
			["tab", "history-10", "tab-other", "history-11", "history-12"]
		)
	}

	@Test
	internal func aTabsHistoryResultSurvivesTheVisibleLimit() {
		let tabs: [CommandBarFeature.Entry] = (0..<8).map { index in
			tab("tab-\(index)", id: .init(rawValue: UUID(100 + index)), url: URL(string: "https://tab.example/\(index)")!)
		}
		let state = CommandBarFeature.State(
			mode: .newTab,
			candidates: tabs + [history(10, url: URL(string: "https://tab.example/0")!)]
		)
		expectNoDifference(
			state.entries.map(\.presentation.id),
			["tab-0", "history-10", "tab-1", "tab-2", "tab-3", "tab-4", "tab-5", "tab-6"]
		)
	}

	@Test
	internal func showHistoryListsOnlyHistoryButStillSwitchesToAnOpenTab() {
		let state = CommandBarFeature.State(mode: .history, candidates: candidates())
		expectNoDifference(state.entries.map(\.presentation.id), ["history-10", "history-11", "history-12"])
		expectNoDifference(
			state.actions(for: entry("history-10", in: state)).prefix(3).map(\.id),
			["primary", "open-new-tab", "switch-to-tab"]
		)
	}

	/// A proxy link command on a page no proxy link rule matches is listed disabled; choosing it
	/// does nothing, and the bar stays open (DEV-1262).
	@Test
	internal func aDisabledCommandIsListedButDoesNothing() async throws {
		let context = BrowserCommandContext(host: .main, hasTab: true, canSavePage: true)
		let candidates = CommandBarFeature.Entry.commands(in: context, bindings: [])
		let disabled = try #require(candidates.first { $0.intent == .disabledCommand(.copyProxyLink) })
		#expect(!disabled.presentation.isEnabled)
		expectNoDifference(
			candidates.filter { !$0.presentation.isEnabled }.map(\.intent),
			[.disabledCommand(.copyProxyLink), .disabledCommand(.copyMarkdownProxy), .disabledCommand(.shareProxyLink)]
		)

		let store = TestStore(initialState: CommandBarFeature.State(
			isPresented: true,
			query: disabled.presentation.title,
			mode: .commands,
			candidates: candidates
		)) { CommandBarFeature() }
		#expect(store.state.entries.contains { $0.presentation.id == disabled.presentation.id })
		await store.send(.ui(.selected(disabled.presentation.id)))
		#expect(store.state.isPresented)
		await store.finish()
	}

	// MARK: - Actions per result

	@Test
	internal func anOpenTabSwitchesByDefaultAndOffersEveryWayToOpenItsPage() {
		let state = CommandBarFeature.State(mode: .newTab, candidates: candidates())
		let actions = state.actions(for: entry("tab", in: state))
		expectNoDifference(
			actions.map(\.id),
			["primary", "open-new-tab", "open-peek", "open-little-arx", "copy-url"]
		)
		expectNoDifference(actions[0].kind, .run(.selectTab(tabID), .tab(profile, .unpinned(space))))
		expectNoDifference(actions[0].shortcut, "↩")
		expectNoDifference(actions[1].kind, .run(.openInNewTab(openURL), nil))
	}

	@Test
	internal func aHistoryResultOpensByDefaultAndCanSwitchToItsTabOrBeDeleted() {
		let state = CommandBarFeature.State(mode: .newTab, candidates: candidates())
		let actions = state.actions(for: entry("history-10", in: state))
		expectNoDifference(
			actions.map(\.id),
			[
				"primary", "switch-to-tab", "open-peek", "open-little-arx", "copy-url",
				"delete-history", "delete-history-site",
			]
		)
		expectNoDifference(actions[1].kind, .run(.selectTab(tabID), .tab(profile, .unpinned(space))))
		expectNoDifference(actions[5].kind, .removeHistory(profile, .entries([UUID(10)])))
		expectNoDifference(actions[6].kind, .removeHistory(profile, .site("capturecontext.dev")))
		expectNoDifference(actions[6].isDestructive, true)

		// Without an open tab there's nothing to switch to; a site's removal drops `www.`.
		let lone = state.actions(for: entry("history-11", in: state))
		expectNoDifference(
			lone.map(\.id),
			["primary", "open-peek", "open-little-arx", "copy-url", "delete-history", "delete-history-site"]
		)
		expectNoDifference(lone.last?.kind, .removeHistory(profile, .site("example.com")))
	}

	@Test
	internal func inTheAddressFieldReturnReplacesThePageSoNewTabIsOffered() {
		let state = CommandBarFeature.State(mode: .currentTab, candidates: candidates())
		let actions = state.actions(for: entry("history-11", in: state))
		expectNoDifference(actions.prefix(2).map(\.id), ["primary", "open-new-tab"])
	}

	@Test
	internal func aTypedAddressOrSearchOpensInPeekOrLittleArx() {
		let state = CommandBarFeature.State(query: "example.org", mode: .newTab, candidates: candidates())
		let typed = state.actions(for: entry("destination", in: state))

		// What ⌘↩ opens as is comes second while the text can be an address (DEV-1319).
		expectNoDifference(typed.map(\.id), ["primary", "open-url", "open-peek", "open-little-arx", "copy-url"])
		expectNoDifference(typed[2].kind, .run(.openInPeek(URL(string: "https://example.org")!), nil))

		let search = CommandBarFeature.State(query: "arx browser", mode: .newTab, candidates: candidates())
		expectNoDifference(
			search.actions(for: entry("destination", in: search)).map(\.id),
			["primary", "open-peek", "open-little-arx", "copy-url"]
		)
	}

	@Test
	internal func commandsSpacesAndFoldersOfferOnlyTheirOwnAction() {
		let state = CommandBarFeature.State(query: "Side", mode: .commands, candidates: candidates())
		let actions = state.actions(for: entry("command", in: state))

		// Besides opening as is what ⌘↩ opens while the text can be an address (DEV-1319).
		expectNoDifference(actions.map(\.id), ["primary", "open-url"])
		expectNoDifference(actions[0].kind, .run(.toggleSidebar, nil))
	}

	@Test
	internal func aHostThatCannotOpenOrDeleteOffersOnlySwitchingAndCopying() {
		var state = CommandBarFeature.State(mode: .newTab, candidates: candidates())
		state.actionAvailability = .none
		expectNoDifference(
			state.actions(for: entry("history-10", in: state)).map(\.id),
			["primary", "switch-to-tab", "copy-url"]
		)
	}

	@Test
	internal func peekAndLittleArxAreOfferedOnlyForWebPages() {
		var candidates = candidates()
		candidates.append(tab("chat", id: .init(rawValue: UUID(5)), url: URL(string: "arx://chat/1")!))
		let state = CommandBarFeature.State(mode: .newTab, candidates: candidates)
		expectNoDifference(
			state.actions(for: entry("chat", in: state)).map(\.id),
			["primary", "open-new-tab", "copy-url"]
		)
	}

	// MARK: - Panel and keys

	@Test
	internal func commandKTogglesThePanelAndEscClosesItBeforeTheBar() async {
		let store = TestStore(initialState: CommandBarFeature.State()) { CommandBarFeature() }
		let candidates = candidates()
		await store.send(.present(.newTab, "", candidates)) {
			$0.isPresented = true
			$0.candidates = candidates
			$0.selectedID = "tab"
			$0.focusRequest = 1
		}
		await store.send(.ui(.highlighted("history-11"))) {
			$0.selectedID = "history-11"
		}
		await store.send(.ui(.actionsToggled)) {
			$0.actionPanel = .init(entryID: "history-11", selectedID: "primary")
		}

		// The pointer crossing the list behind the panel moves nothing.
		await store.send(.ui(.highlighted("tab")))
		await store.send(.ui(.actionsToggled)) {
			$0.actionPanel = nil
			$0.inputRefocusRequest = 1
		}

		await store.send(.ui(.actionsToggled)) {
			$0.actionPanel = .init(entryID: "history-11", selectedID: "primary")
		}
		await store.send(.ui(.dismissed)) {
			$0.actionPanel = nil
			$0.inputRefocusRequest = 2
		}
		await store.send(.ui(.dismissed)) {
			$0.isPresented = false
		}
		await store.receive(\.delegate.dismissed)
	}

	@Test
	internal func typingFiltersTheActionsAndKeepsAVisibleHighlight() async {
		var initial = CommandBarFeature.State(mode: .newTab, candidates: candidates())
		initial.isPresented = true
		initial.selectedID = "history-11"
		let store = TestStore(initialState: initial) { CommandBarFeature() }

		await store.send(.ui(.actionsToggled)) {
			$0.actionPanel = .init(entryID: "history-11", selectedID: "primary")
		}
		await store.send(.ui(.actionHighlighted("copy-url"))) {
			$0.actionPanel?.selectedID = "copy-url"
		}
		await store.send(.ui(.actionQueryChanged("delete"))) {
			$0.actionPanel?.query = "delete"
			$0.actionPanel?.selectedID = "delete-history"
		}
		expectNoDifference(store.state.actionPanelActions.map(\.id), ["delete-history", "delete-history-site"])
		await store.send(.ui(.actionQueryChanged("del"))) {
			$0.actionPanel?.query = "del"
		}
		await store.send(.ui(.actionsDismissed)) {
			$0.actionPanel = nil
			$0.inputRefocusRequest = 1
		}
	}

	@Test
	internal func editingTheFieldClosesTheActions() async {
		var initial = CommandBarFeature.State(mode: .newTab, candidates: candidates())
		initial.isPresented = true
		initial.selectedID = "history-11"
		let store = TestStore(initialState: initial) { CommandBarFeature() }

		await store.send(.ui(.actionsToggled)) {
			$0.actionPanel = .init(entryID: "history-11", selectedID: "primary")
		}
		await store.send(.ui(.queryChanged("manual"))) {
			$0.actionPanel = nil
			$0.query = "manual"
			$0.selectedID = "destination"
		}
	}

	// MARK: - Running actions

	@Test(arguments: [
		("tab", "primary"),
		("tab", "open-new-tab"),
		("tab", "open-peek"),
		("tab", "open-little-arx"),
		("tab", "copy-url"),
		("history-10", "primary"),
		("history-10", "switch-to-tab"),
	])
	internal func anActionRunsThroughTheHostWithTheResultsIdentity(
		_ entryID: String,
		_ actionID: String
	) async throws {
		var initial = CommandBarFeature.State(mode: .newTab, candidates: candidates())
		initial.isPresented = true
		initial.selectedID = entryID
		initial.focusRequest = 7
		let entry = entry(entryID, in: initial)
		let action = try #require(initial.actions(for: entry).first { $0.id == actionID })
		guard case let .run(intent, destination) = action.kind else {
			Issue.record("\(actionID) doesn't run through the host")
			return
		}
		let store = TestStore(initialState: initial) { CommandBarFeature() }

		await store.send(.ui(.actionsToggled)) {
			$0.actionPanel = .init(entryID: entryID, selectedID: "primary")
		}
		await store.send(.ui(.actionSelected(actionID))) {
			$0.actionPanel = nil
			$0.inputRefocusRequest = 1
			$0.isPresented = false
		}
		var expected = entry
		expected.intent = intent
		expected.destination = destination

		// An action other than the result's own carries the result, for the host to check.
		await store.receive(
			\.delegate.execute,
			.init(
				entry: expected,
				mode: .newTab,
				presentationID: 7,
				origin: actionID == "primary" ? nil : entry,
				// DEV-1015: opening a history result is a visit asked for; switching to its tab isn't one.
				isTypedAddress: entryID == "history-10" && actionID == "primary"
			)
		)

		let expectedIntent: CommandBarFeature.Intent = switch (entryID, actionID) {
		case ("tab", "primary"), ("history-10", "switch-to-tab"): .selectTab(tabID)
		case ("tab", "open-new-tab"): .openInNewTab(openURL)
		case ("tab", "open-peek"): .openInPeek(openURL)
		case ("tab", "open-little-arx"): .openInLittleArx(openURL)
		case ("tab", "copy-url"): .copyURL(openURL)
		default: .openHistory(.init(id: UUID(10), profileID: profile, spaceID: space, url: openURL))
		}
		expectNoDifference(intent, expectedIntent)
	}

	@Test
	internal func eachActionHasItsOwnKeyThatRunsItFromTheBar() async {
		var initial = CommandBarFeature.State(mode: .newTab, candidates: candidates())
		initial.isPresented = true
		initial.selectedID = "history-10"
		initial.focusRequest = 3
		expectNoDifference(
			initial.actions(for: entry("history-10", in: initial)).map(\.shortcut),
			["↩", "⌃↩", "⇧↩", "⌥⌘↩", "⇧⌘C", "⌃X", "⌃⇧X"]
		)
		expectNoDifference(initial.actionID(forShortcut: "⇧↩"), "open-peek")
		expectNoDifference(initial.actionID(forShortcut: "⌘↩"), nil)
		expectNoDifference(initial.primaryActionTitle, "Open")
		#expect(initial.offersCopyURL)

		let store = TestStore(initialState: initial) { CommandBarFeature() }

		// ⇧↩ straight from the bar, without the panel.
		await store.send(.ui(.actionRequested("open-peek"))) {
			$0.isPresented = false
		}
		var expected = entry("history-10", in: initial)
		expected.intent = .openInPeek(openURL)
		await store.receive(
			\.delegate.execute,
			.init(entry: expected, mode: .newTab, presentationID: 3, origin: entry("history-10", in: initial))
		)
	}

	@Test
	internal func theAppsOwnBindingsWinOverAnActionsKey() {
		var state = CommandBarFeature.State(mode: .newTab, candidates: candidates())
		state.isPresented = true
		state.selectedID = "history-11"

		// Command Bar rebound to ⌃X.
		state.reservedShortcuts = ["⌃X"]
		let delete = state.actions(for: entry("history-11", in: state)).first { $0.id == "delete-history" }
		expectNoDifference(delete?.shortcut, nil)
		expectNoDifference(state.actionID(forShortcut: "⌃X"), nil)
		expectNoDifference(state.actionID(forShortcut: "⌃⇧X"), "delete-history-site")

		// Copy URL rebound to ⌃⇧X takes the key from Delete All from the site.
		state.copyURLShortcut = "⌃⇧X"
		let actions = state.actions(for: entry("history-11", in: state))
		expectNoDifference(actions.first { $0.id == "delete-history-site" }?.shortcut, nil)
		expectNoDifference(actions.first { $0.id == "copy-url" }?.shortcut, "⌃⇧X")
		expectNoDifference(state.actionID(forShortcut: "⌃⇧X"), "copy-url")
	}

	@Test
	internal func thePrimaryActionDoesWhatReturnDoes() async {
		var initial = CommandBarFeature.State(mode: .newTab, candidates: candidates())
		initial.isPresented = true
		initial.selectedID = "tab"
		let store = TestStore(initialState: initial) { CommandBarFeature() }
		await store.send(.ui(.actionRequested("primary"))) {
			$0.isPresented = false
		}
		await store.receive(
			\.delegate.execute,
			.init(entry: entry("tab", in: initial), mode: .newTab, presentationID: 0)
		)
	}

	@Test
	internal func aKeyFromTheBarRemovesHistoryAndKeepsItOpen() async {
		var initial = CommandBarFeature.State(mode: .newTab, candidates: candidates())
		initial.isPresented = true
		initial.selectedID = "history-11"
		let store = TestStore(initialState: initial) { CommandBarFeature() }
		await store.send(.ui(.actionRequested("delete-history"))) {
			$0.candidates.removeAll { $0.presentation.id == "history-11" }
			$0.selectedID = "history-12"
		}
		await store.receive(\.delegate.removeHistory)
	}

	@Test
	internal func deleteFromHistoryDropsTheResultKeepsTheBarOpenAndAsksTheHost() async {
		var initial = CommandBarFeature.State(mode: .newTab, candidates: candidates())
		initial.isPresented = true
		initial.selectedID = "history-11"
		let store = TestStore(initialState: initial) { CommandBarFeature() }

		await store.send(.ui(.actionsToggled)) {
			$0.actionPanel = .init(entryID: "history-11", selectedID: "primary")
		}
		await store.send(.ui(.actionSelected("delete-history"))) {
			$0.actionPanel = nil
			$0.inputRefocusRequest = 1
			$0.candidates.removeAll { $0.presentation.id == "history-11" }

			// The highlight moves to the next result.
			$0.selectedID = "history-12"
		}
		await store.receive(\.delegate.removeHistory)
		expectNoDifference(store.state.entries.map(\.presentation.id), ["tab", "history-10", "tab-other", "history-12"])
	}

	@Test
	internal func deleteAllFromASiteDropsEveryResultFromIt() async {
		var initial = CommandBarFeature.State(mode: .newTab, candidates: candidates())
		initial.isPresented = true
		initial.selectedID = "history-12"
		let store = TestStore(initialState: initial) { CommandBarFeature() }

		await store.send(.ui(.actionsToggled)) {
			$0.actionPanel = .init(entryID: "history-12", selectedID: "primary")
		}
		await store.send(.ui(.actionSelected("delete-history-site"))) {
			$0.actionPanel = nil
			$0.inputRefocusRequest = 1
			$0.candidates.removeAll { ["history-11", "history-12"].contains($0.presentation.id) }

			// Nothing follows it, so the highlight moves back.
			$0.selectedID = "tab-other"
		}
		await store.receive(\.delegate.removeHistory)
		#expect(store.state.isPresented)
	}

	// MARK: - Fixtures

	private func entry(
		_ id: String,
		in state: CommandBarFeature.State
	) -> CommandBarFeature.Entry {
		state.entries.first { $0.presentation.id == id }!
	}

	private func candidates() -> [CommandBarFeature.Entry] {
		[
			tab("tab", id: tabID, url: openURL),
			tab("tab-other", id: otherTabID, url: otherTabURL),
			history(10, url: openURL),
			history(11, url: siteURL),
			history(12, url: siblingURL),
			.init(
				presentation: .init(id: "command", title: "Sidebar", actionTitle: "Command", symbol: "sidebar.left"),
				intent: .toggleSidebar
			),
		]
	}

	private func tab(
		_ entryID: String,
		id: BrowserCore.Tab.ID,
		url: URL
	) -> CommandBarFeature.Entry {
		.init(
			presentation: .init(
				id: entryID,
				title: entryID,
				subtitle: url.absoluteString,
				actionTitle: "Switch to Tab",
				symbol: "globe",
				siteIcon: .init(profileID: profile.rawValue, pageURL: url)
			),
			intent: .selectTab(id),
			destination: .tab(profile, .unpinned(space))
		)
	}

	private func history(
		_ id: Int,
		url: URL
	) -> CommandBarFeature.Entry {
		.init(
			presentation: .init(
				id: "history-\(id)",
				title: "History \(id)",
				subtitle: url.absoluteString,
				actionTitle: "Open URL",
				symbol: "clock.arrow.circlepath"
			),
			intent: .openHistory(.init(id: UUID(id), profileID: profile, spaceID: space, url: url))
		)
	}
}
