import BrowserCore
import BrowserEngineClient
import CommandBarFeature
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct CommandBarAddressMatchTests {
	// MARK: - Index

	@Test
	internal func matchesTheShortestAddressTypedToward() async throws {
		let index = AddressMatchIndex(candidates())

		expectNoDifference(index.entryID(matching: "Cap"), "tab")
		expectNoDifference(index.entryID(matching: "capturecontext.dev/d"), "history")
		expectNoDifference(index.entryID(matching: "capturecontext.dev"), "tab")
		expectNoDifference(index.entryID(matching: "www.ex"), "news")
		expectNoDifference(index.entryID(matching: "ex"), "news")
		expectNoDifference(index.entryID(matching: "https://cap"), "tab")
	}

	@Test
	internal func neverMatchesAnAddressThatWasNotTypedToward() async throws {
		let index = AddressMatchIndex(candidates())

		for typed in ["", "turecontext", "cap ture", "!cap", "Sidebar", "about", "file"] {
			#expect(index.entryID(matching: typed) == nil, "\(typed)")
		}
	}

	@Test
	internal func anEarlierCandidateWinsATie() async throws {
		let first = page("first", "https://same.example/")
		let second = page("second", "https://same.example/")

		expectNoDifference(AddressMatchIndex([first, second]).entryID(matching: "sa"), "first")
		expectNoDifference(AddressMatchIndex([second, first]).entryID(matching: "sa"), "second")
	}

	// MARK: - Keys

	/// DEV-1223: the field keeps exactly what was typed, however much longer the matched address
	/// is, and Return still opens the highlighted page.
	@Test(arguments: [CommandBarFeature.Mode.newTab, .commands, .currentTab])
	internal func aLongTypedTextKeepsNoSuffixAndReturnFollowsTheSelection(mode: CommandBarFeature.Mode) async throws {
		let long = page("long", "https://capturecontext.dev/docs/arx/settings/general/tabs/where-new-tabs-open")
		let entries = candidates() + [long]
		var state = CommandBarFeature.State(mode: mode, candidates: entries)
		state.isPresented = true
		let store = TestStore(initialState: state) { CommandBarFeature() }
		let typed = "capturecontext.dev/docs/arx/settings/general/tabs/where"

		await store.send(.ui(.queryChanged(typed))) {
			$0.query = typed
			$0.selectedID = "long"
		}
		expectNoDifference(store.state.addressMatchID, "long")
		expectNoDifference(store.state.entries.first?.presentation.id, "long")

		await store.send(.ui(.selected("long"))) {
			$0.isPresented = false
		}
		await store.receive(\.delegate.execute, .init(entry: long, mode: mode, presentationID: 0, isTypedAddress: true))
	}

	@Test(arguments: [CommandBarFeature.Mode.newTab, .commands, .currentTab])
	internal func returnOpensTheMatchedPageAndDeletingKeepsIt(mode: CommandBarFeature.Mode) async throws {
		let entries = candidates()
		let prefill = mode == .currentTab ? "https://capturecontext.dev/" : ""
		let store = TestStore(initialState: CommandBarFeature.State()) { CommandBarFeature() }

		await store.send(.present(mode, prefill, entries)) {
			$0.mode = mode
			$0.isPresented = true
			$0.query = prefill
			$0.prefilledQuery = mode == .currentTab ? prefill : nil
			$0.candidates = entries
			$0.selectedID = mode == .commands ? "command" : "tab"
			$0.focusRequest = 1
		}

		// A prefilled address is never matched before the first edit.
		#expect(store.state.addressMatchID == nil)

		await store.send(.ui(.queryChanged("capt"))) {
			$0.query = "capt"
			$0.prefilledQuery = nil
			$0.selectedID = "tab"
		}
		expectNoDifference(store.state.entries.first?.presentation.id, "tab")

		// Tab doesn't follow the highlighted result.
		await store.send(.ui(.tabPressed))

		// With nothing drawn after the caret, a deletion is an edit like any other: the page the
		// text still leads toward stays highlighted.
		await store.send(.ui(.queryChanged("cap"))) {
			$0.query = "cap"
		}
		expectNoDifference(store.state.addressMatchID, "tab")

		await store.send(.ui(.selected("tab"))) {
			$0.isPresented = false
		}

		// Switching to an open tab loads nothing, so it isn't a typed address (DEV-1015).
		await store.receive(\.delegate.execute, .init(entry: entries[0], mode: mode, presentationID: 1))
	}

	@Test(arguments: [CommandBarFeature.Mode.newTab, .commands, .currentTab])
	internal func aPathLeadsToTheLongerPage(mode: CommandBarFeature.Mode) async throws {
		var state = CommandBarFeature.State(mode: mode, candidates: candidates())
		state.isPresented = true
		let store = TestStore(initialState: state) { CommandBarFeature() }

		await store.send(.ui(.queryChanged("capturecontext.dev"))) {
			$0.query = "capturecontext.dev"
			$0.selectedID = "tab"
		}
		expectNoDifference(store.state.addressMatchID, "tab")

		await store.send(.ui(.queryChanged("capturecontext.dev/"))) {
			$0.query = "capturecontext.dev/"
			$0.selectedID = "history"
		}

		await store.send(.ui(.selected("history"))) {
			$0.isPresented = false
		}

		// DEV-1015: the matched page was typed toward.
		await store.receive(\.delegate.execute, .init(entry: candidates()[1], mode: mode, presentationID: 0, isTypedAddress: true))
	}

	@Test(arguments: [CommandBarFeature.Mode.newTab, .commands, .currentTab])
	internal func returnOpensAnotherHighlightedResult(mode: CommandBarFeature.Mode) async throws {
		var state = CommandBarFeature.State(mode: mode, candidates: candidates())
		state.isPresented = true
		let store = TestStore(initialState: state) { CommandBarFeature() }

		await store.send(.ui(.queryChanged("cap"))) {
			$0.query = "cap"
			$0.selectedID = "tab"
		}
		await store.send(.ui(.highlighted("destination"))) {
			$0.selectedID = "destination"
		}

		let destination = try #require(store.state.entries.first { $0.presentation.id == "destination" })
		await store.send(.ui(.selected("destination"))) {
			$0.isPresented = false
		}
		await store.receive(\.delegate.execute, .init(entry: destination, mode: mode, presentationID: 0))
		expectNoDifference(destination.intent, .open(SearchEngine.google.url(for: "cap")!))
	}

	@Test
	internal func deletingKeepsAHighlightThatWasNotTheMatch() async throws {
		var state = CommandBarFeature.State(mode: .newTab, candidates: candidates())
		state.isPresented = true
		let store = TestStore(initialState: state) { CommandBarFeature() }

		await store.send(.ui(.queryChanged("examples"))) {
			$0.query = "examples"
			$0.selectedID = "destination"
		}
		await store.send(.ui(.queryChanged("example"))) {
			$0.query = "example"
			$0.selectedID = "news"
		}
		await store.send(.ui(.highlighted("destination"))) {
			$0.selectedID = "destination"
		}

		// The text still leads toward the same page, which takes the highlight back, as typing
		// does.
		await store.send(.ui(.queryChanged("exampl"))) {
			$0.query = "exampl"
			$0.selectedID = "news"
		}
	}

	@Test(arguments: [CommandBarFeature.Mode.newTab, .commands, .currentTab])
	internal func returnFollowsATypedLink(mode: CommandBarFeature.Mode) async throws {
		var state = CommandBarFeature.State(mode: mode, candidates: candidates())
		state.isPresented = true
		let store = TestStore(initialState: state) { CommandBarFeature() }
		let url = URL(string: "https://elsewhere.example/page")!

		await store.send(.ui(.queryChanged(url.absoluteString))) {
			$0.query = url.absoluteString
			$0.selectedID = "destination"
		}
		#expect(store.state.addressMatchID == nil)

		let entry = try #require(store.state.entries.first)
		await store.send(.ui(.selected("destination"))) {
			$0.isPresented = false
		}

		// DEV-1015: a typed link is a typed address.
		await store.receive(\.delegate.execute, .init(entry: entry, mode: mode, presentationID: 0, isTypedAddress: true))
		expectNoDifference(entry.intent, .open(url))
	}

	@Test
	internal func bangsAndKeywordSearchesNeverMatch() async throws {
		let entries = candidates() + [page("bang-like", "https://yt.example/")]
		var state = CommandBarFeature.State(mode: .newTab, candidates: entries)
		state.isPresented = true
		state.siteSearchKeyword = "yt"
		state.query = "yt"
		#expect(state.addressMatchID == nil)

		state.siteSearchKeyword = nil
		state.query = "!yt"
		#expect(state.addressMatchID == nil)
	}

	// MARK: - Windows

	@Test(arguments: [CommandBarFeature.Mode.newTab, .commands, .currentTab])
	internal func mainWindowReturnSwitchesToTheMatchedTab(mode: CommandBarFeature.Mode) async throws {
		var organization = IntegrationFeatureTests().fixture()
		organization.tabs[1].restoration.url = URL(string: "https://docs.example/guide")!
		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		initial.viewer.item.tab = organization.tabs[0]
		var commands: [BrowserEngineClient.Command] = []
		let store = Store(initialState: initial) { MainFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.command = { _, command in commands.append(command) }
		}

		await store.send(.ui(.openCommand(mode))).finish()
		await store.send(.commandBar(.ui(.queryChanged("docs")))).finish()
		let selected = try #require(store.commandBar.selectedID)
		expectNoDifference(store.commandBar.addressMatchID, selected)
		expectNoDifference(store.commandBar.query, "docs")
		await store.send(.commandBar(.ui(.selected(selected)))).finish()

		expectNoDifference(store.sidebar.selectedTab?.id, organization.tabs[1].id)
		expectNoDifference(commands, [])
	}

	@Test(arguments: [CommandBarFeature.Mode.commands, .currentTab])
	internal func privateWindowMatchesThePagesOwnStackAndNavigatesIt(mode: CommandBarFeature.Mode) async throws {
		let organization = IntegrationFeatureTests().fixture()
		var initial = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: true
		)
		initial.viewer.item.tab = organization.tabs[0]
		let visited = URL(string: "https://private.example/visited")!
		initial.viewer.item.navigation.history = [
			.init(id: 1, url: visited, title: "Visited", isCurrent: false),
			.init(id: 2, url: organization.tabs[0].restoration.url, title: "Open", isCurrent: true),
		]
		var commands: [BrowserEngineClient.Command] = []
		let store = Store(initialState: initial) { MainFeature() } withDependencies: {
			$0.browserEngine.command = { _, command in commands.append(command) }
		}

		await store.send(.ui(.openCommand(mode))).finish()
		await store.send(.commandBar(.ui(.queryChanged("pri")))).finish()
		let selected = try #require(store.commandBar.selectedID)
		expectNoDifference(store.commandBar.addressMatchID, selected)
		await store.send(.commandBar(.ui(.selected(selected)))).finish()

		expectNoDifference(commands, [.navigate(visited)])
	}

	@Test
	internal func littleArxLauncherOpensTheMatchedSuggestion() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let suggestion = page("suggestion", "https://news.example/today")
		var opened: [BrowserCore.Tab] = []
		let store = TestStore(initialState: LittleArxFeature.State(
			id: UUID(20),
			spaceID: organization.spaces[0].id,
			tab: organization.tabs[0],
			isCommandOnly: true,
			launcherSuggestions: [suggestion]
		)) { LittleArxFeature() } withDependencies: {
			$0.browserEngine.open = { opened.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.task))
		await store.receive(\.commandBar.present)
		await store.finish()

		await store.send(.commandBar(.ui(.queryChanged("NEWS"))))
		expectNoDifference(store.state.commandBar.query, "NEWS")
		expectNoDifference(store.state.commandBar.selectedID, "suggestion")
		await store.send(.commandBar(.ui(.selected("suggestion"))))
		await store.receive(\.commandBar.delegate.execute)
		await store.receive(\.navigateFromCommandBar)
		await store.finish()
		expectNoDifference(opened.map(\.restoration.url), [URL(string: "https://news.example/today")!])
	}

	@Test
	internal func peekHasNoCommandBar() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = LittleArxFeature.State(
			id: UUID(20),
			spaceID: organization.spaces[0].id,
			tab: organization.tabs[0]
		)
		state.peekID = UUID(21)
		let store = TestStore(initialState: state) { LittleArxFeature() }

		await store.send(.ui(.openCommand(.currentTab)))
		#expect(!store.state.commandBar.isPresented)
	}

	// MARK: - Fixtures

	private func page(
		_ id: String,
		_ address: String
	) -> CommandBarFeature.Entry {
		.init(
			presentation: .init(id: id, title: id, actionTitle: "Open", symbol: "globe"),
			intent: .open(URL(string: address)!)
		)
	}

	private func candidates() -> [CommandBarFeature.Entry] {
		[
			.init(
				presentation: .init(
					id: "tab",
					title: "Current",
					actionTitle: "Switch",
					symbol: "globe",
					siteIcon: .init(
						profileID: UUID(0),
						pageURL: URL(string: "https://capturecontext.dev/")!
					)
				),
				intent: .selectTab(.init(rawValue: UUID(1)))
			),
			page("history", "https://capturecontext.dev/docs/arx"),
			page("news", "https://www.example.org/news"),
			page("blank", "about:blank"),
			page("file", "file:///tmp/notes.txt"),
			.init(
				presentation: .init(
					id: "command",
					title: "Sidebar",
					actionTitle: "Command",
					symbol: "sidebar.left"
				),
				intent: .toggleSidebar
			),
		]
	}
}
