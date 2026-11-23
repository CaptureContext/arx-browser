import AppUI
import BrowserCore
import CommandBarFeature
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture

/// An alias typed in the command bar finds its command, first when it's typed exactly.
@Suite(.dependencies)
@MainActor
internal struct CommandAliasRankingTests {
	private static let aliases: [CommandAlias] = [.init(command: .pinTab, alias: "pin")]

	private static let candidates: [CommandBarFeature.Entry] = [
		.init(
			presentation: .init(id: "page", title: "Pinball rules", actionTitle: "Open", symbol: "globe"),
			intent: .open(URL(string: "https://example.com/pinball")!)
		),
		.command(.reload, bindings: []),
		.command(.pinTab, bindings: [], aliases: aliases),
	]

	@Test(arguments: [CommandBarFeature.Mode.commands, .newTab])
	internal func anExactAliasPutsItsCommandFirst(mode: CommandBarFeature.Mode) {
		var state = CommandBarFeature.State(mode: mode, candidates: Self.candidates)
		state.query = "Pin"
		#expect(state.entries.first?.intent == .command(.pinTab))
	}

	@Test
	internal func theStartOfAnAliasFindsItsCommand() {
		var state = CommandBarFeature.State(mode: .commands, candidates: Self.candidates)
		state.query = "pi"
		#expect(state.entries.contains { $0.intent == .command(.pinTab) })
		#expect(Self.candidates[2].presentation.alias == "pin")
	}

	/// Typed through the reducer, the alias is highlighted, so Return runs the command and not a
	/// page whose address starts with the same letters.
	@Test
	internal func anExactAliasIsHighlightedOverAPageItStarts() async {
		let page = CommandBarFeature.Entry(
			presentation: .init(id: "pinterest", title: "Pinterest", subtitle: "https://pinterest.com", actionTitle: "Open", symbol: "globe"),
			intent: .open(URL(string: "https://pinterest.com")!)
		)
		let store = Store(
			initialState: CommandBarFeature.State(isPresented: true, mode: .newTab, candidates: [page] + Self.candidates)
		) { CommandBarFeature() }
		store.send(.ui(.queryChanged("pin")))
		#expect(store.selectedID == "command-" + BrowserCommand.pinTab.rawValue)
	}
}
