import BrowserCore
import BrowserWorkspaceClient
import CommandBarFeature
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture

/// DEV-895: the calculator's result row and the quick-create rows. The pure functions
/// behind them are tested in `BrowserCoreTests`; this covers where the rows go and what
/// Return does.
@Suite(.dependencies)
@MainActor
internal struct CommandBarInstantRowsTests {
	private final class Copies: @unchecked Sendable {
		private let lock: NSLock = .init()
		private var _texts: [String] = []

		var texts: [String] { lock.withLock { _texts } }

		func copy(_ text: String) { lock.withLock { _texts.append(text) } }
	}

	private func store(copies: Copies = .init()) -> TestStoreOf<CommandBarFeature> {
		let document = WorkspaceDocument.unsaved(BrowserPreferences())
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			CommandBarFeature.State()
		}
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.commandBarClipboard = .init { copies.copy($0) }
		}
		store.exhaustivity = .off
		return store
	}

	private let newTab: CommandBarFeature.Entry = .command(.newTab, bindings: [])

	@Test
	internal func anExpressionLeadsWithItsResultAndReturnCopiesIt() async throws {
		let copies: Copies = .init()
		let store = store(copies: copies)
		await store.send(.present(.newTab, "", [newTab]))
		await store.send(.ui(.queryChanged("12*7.5")))

		let first = try #require(store.state.entries.first)
		#expect(first.presentation.title == "= 90")
		#expect(first.intent == .copyText("90"))
		#expect(store.state.selectedID == first.presentation.id)

		await store.send(.ui(.selected(first.presentation.id)))
		await store.receive(\.delegate.dismissed)
		#expect(!store.state.isPresented)
		#expect(copies.texts == ["90"])
	}

	@Test
	internal func typingAnExpressionKeyByKeyHighlightsItsResult() async throws {
		let store = store()
		await store.send(.present(.newTab, "", [newTab]))
		for text in ["1", "1+", "1+1"] {
			await store.send(.ui(.queryChanged(text)))
		}
		#expect(store.state.selectedID == "calculator")
		await store.send(.ui(.queryChanged("new")))
		await store.send(.ui(.queryChanged("new d")))
		#expect(store.state.selectedID == "create-docs.new")
	}

	@Test
	internal func instantRowsLeadTheProvidersSuggestions() async throws {
		let store = store()
		await store.send(.present(.newTab, "", []))
		var state = store.state
		state.query = "1+1"
		state.suggestionsQuery = "1+1"
		state.suggestions = ["one plus one", "1+1 meaning"]

		// The plain search for what's typed comes right after the instant row (DEV-978).
		expectNoDifference(
			state.entries.prefix(3).map(\.presentation.id),
			["calculator", "destination", "suggestion-one plus one"]
		)
		state.query = "new doc"
		state.suggestionsQuery = "new doc"
		state.suggestions = ["new doctor who"]
		#expect(state.entries.first?.presentation.id == "create-docs.new")
	}

	@Test
	internal func ordinaryTextHasNoResultRow() async throws {
		let store = store()
		await store.send(.present(.newTab, "", [newTab]))
		for text in ["swift", "2024", "e"] {
			await store.send(.ui(.queryChanged(text)))
			#expect(!store.state.entries.contains { $0.intent == .copyText(text) })
			#expect(!store.state.entries.contains { $0.presentation.id == "calculator" })
		}
	}

	@Test
	internal func newDocListsItsCreateTargetsFirst() async throws {
		let store = store()
		await store.send(.present(.newTab, "", [newTab]))
		await store.send(.ui(.queryChanged("new doc")))
		expectNoDifference(
			store.state.entries.prefix(2).map(\.intent),
			[.open(URL(string: "https://docs.new")!), .open(URL(string: "https://word.new")!)]
		)
	}

	@Test
	internal func newAloneKeepsNewTabFirstAndListsTargetsAfter() async throws {
		let store = store()
		await store.send(.present(.commands, "", [newTab]))
		await store.send(.ui(.queryChanged("new")))
		let entries = store.state.entries
		#expect(entries.first?.intent == .command(.newTab))
		#expect(entries.contains { $0.intent == .open(URL(string: "https://meet.new")!) })
	}

	@Test
	internal func aBareNewDomainIsAnAddressToCreateWith() async throws {
		let store = store()
		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.queryChanged("excalidraw.new")))
		#expect(store.state.entries.first?.intent == .open(URL(string: "https://excalidraw.new")!))
	}

	@Test
	internal func showHistoryHasNeither() async throws {
		let store = store()
		await store.send(.present(.history, "", []))
		await store.send(.ui(.queryChanged("1+1")))
		#expect(store.state.entries.isEmpty)
	}
}
