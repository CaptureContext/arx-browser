import BrowserCore
import CommandBarFeature
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1319: ⌘K's actions list Open as is with ⌘↩ while the typed text can be an address, which is
/// what ⌘↩ already opens (DEV-1189), and ⌘-click on a result does what ⌘↩ does with it
/// highlighted. No two actions ever claim ⌘↩.
@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct OpenAsIsTests {
	internal enum Kind: String, CaseIterable, Sendable {
		case site
		case tab
		case search
		case command
	}

	/// Text that can be an address, and text that can't (it has a space). The tests' arguments
	/// spell them out, since a main-actor static can't be read there.
	private static let address = "docs.example"
	private static let words = "docs example"

	// MARK: - The panel

	@Test(arguments: Kind.allCases)
	internal func thePanelListsOpenAsIsWhileTheTextCanBeAnAddress(_ kind: Kind) throws {
		let state = Self.state(query: Self.address)
		let actions = state.actions(for: try Self.entry(kind, in: state))
		let openAsIs = try #require(actions.first { $0.id == CommandBarFeature.State.openURLID })

		expectNoDifference(openAsIs.title, "Open as is")
		expectNoDifference(openAsIs.shortcut, "⌘↩")
		expectNoDifference(openAsIs.kind, .run(.openInNewTab(URL(string: "https://docs.example")!), nil))

		// Right after the result's own action.
		expectNoDifference(actions.dropFirst().first?.id, CommandBarFeature.State.openURLID)
		expectNoDifference(actions.filter { $0.shortcut == "⌘↩" }.map(\.id), [CommandBarFeature.State.openURLID])
	}

	@Test(arguments: Kind.allCases)
	internal func withoutAnAddressThePanelKeepsTheResultsNewTabOnCommandReturn(_ kind: Kind) throws {
		let state = Self.state(query: Self.words)
		let actions = state.actions(for: try Self.entry(kind, in: state))

		#expect(!actions.contains { $0.id == CommandBarFeature.State.openURLID })
		expectNoDifference(
			actions.filter { $0.shortcut == "⌘↩" }.map(\.id),
			kind == .command ? [] : ["open-new-tab"]
		)
	}

	/// With the panel open, ⌘↩ is the action it shows with ⌘↩.
	@Test(arguments: ["docs.example", "docs example"])
	internal func inTheOpenPanelCommandReturnIsTheActionShowingIt(_ query: String) throws {
		var state = Self.state(query: query)
		state.selectedID = "history"
		state.actionPanel = .init(entryID: "history")
		let shown = state.actionPanelActions.first { $0.shortcut == "⌘↩" }?.id

		expectNoDifference(state.actionID(forShortcut: "⌘↩"), shown)
		expectNoDifference(shown, query == Self.address ? CommandBarFeature.State.openURLID : "open-new-tab")
	}

	// MARK: - ⌘-click

	@Test(arguments: Kind.allCases, ["docs.example", "docs example"])
	internal func commandClickDoesWhatCommandReturnDoes(_ kind: Kind, query: String) async throws {
		let initial = Self.state(query: query)
		let id = try Self.entry(kind, in: initial).presentation.id

		let byKey = try await Self.executions(initial) { store in
			await store.send(.ui(.highlighted(id))).finish()
			if let action = store.state.actionID(forShortcut: "⌘↩") {
				await store.send(.ui(.actionRequested(action))).finish()
			}
		}
		let byClick = try await Self.executions(initial) { store in
			await store.send(.ui(.commandClicked(id))).finish()
		}

		expectNoDifference(byClick.map(\.entry.intent), byKey.map(\.entry.intent))
		expectNoDifference(byClick.map(\.isTypedAddress), byKey.map(\.isTypedAddress))

		// Only a command with no address to open does nothing.
		expectNoDifference(byClick.isEmpty, kind == .command && query == Self.words)
	}

	/// A ⌘-click while another result's actions are open acts on the clicked result.
	@Test
	internal func commandClickActsOnTheClickedResultNotThePanels() async throws {
		var initial = Self.state(query: Self.words)
		initial.selectedID = "tab"
		initial.actionPanel = .init(entryID: "tab")
		let executed = try await Self.executions(initial) { store in
			await store.send(.ui(.commandClicked("history"))).finish()
		}
		expectNoDifference(executed.map(\.entry.intent), [.openInNewTab(URL(string: "https://docs.example/page")!)])
	}

	// MARK: - Fixture

	private static func state(query: String) -> CommandBarFeature.State {
		var state = CommandBarFeature.State(mode: .commands, candidates: candidates)
		state.isPresented = true
		state.query = query
		state.opensSchemeAddresses = true
		state.selectedID = state.entries.first?.presentation.id
		return state
	}

	private static func entry(
		_ kind: Kind,
		in state: CommandBarFeature.State
	) throws -> CommandBarFeature.Entry {
		let id = switch kind {
		case .site: "history"

		case .tab: "tab"

		// A link's own search row; text that's no link has only its search.
		case .search: state.query == address ? "search-typed" : "destination"

		case .command: "command"
		}
		return try #require(state.entries.first { $0.presentation.id == id }, "\(id) in \(state.entries.map(\.presentation.id))")
	}

	/// Runs `body` on a store from `initial` and returns what it asked the host to run.
	private static func executions(
		_ initial: CommandBarFeature.State,
		_ body: (StoreOf<CommandBarFeature>) async throws -> Void
	) async throws -> [CommandBarFeature.Execution] {
		let executed = LockIsolated<[CommandBarFeature.Execution]>([])
		let store = Store(initialState: initial) {
			Reduce<CommandBarFeature.State, CommandBarFeature.Action> { state, action in
				if case let .delegate(.execute(execution)) = action {
					executed.withValue { $0.append(execution) }
				}
				return CommandBarFeature()._reduce(into: &state, action: action)
			}
		}
		try await body(store)
		return executed.value
	}

	private static let profile: Profile.ID = .init(rawValue: UUID(1))
	private static let space: Space.ID = .init(rawValue: UUID(2))

	private static let candidates: [CommandBarFeature.Entry] = [
		.init(
			presentation: .init(
				id: "history",
				title: "Docs example page",
				subtitle: "https://docs.example/page",
				actionTitle: "Open URL",
				symbol: "clock.arrow.circlepath"
			),
			intent: .openHistory(.init(
				id: UUID(10),
				profileID: profile,
				spaceID: space,
				url: URL(string: "https://docs.example/page")!
			))
		),
		.init(
			presentation: .init(
				id: "tab",
				title: "Docs example tab",
				subtitle: "https://docs.example/tab",
				actionTitle: "Switch to Tab",
				symbol: "globe",
				siteIcon: .init(profileID: profile.rawValue, pageURL: URL(string: "https://docs.example/tab")!)
			),
			intent: .selectTab(.init(rawValue: UUID(3))),
			destination: .tab(profile, .unpinned(space))
		),
		.init(
			presentation: .init(id: "command", title: "Reload Docs", actionTitle: "Command", symbol: "arrow.clockwise"),
			intent: .command(.reload),
			keywords: [address, words]
		),
	]
}
