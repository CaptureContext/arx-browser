import BrowserCore
import BrowserWorkspaceClient
import CommandBarFeature
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture

/// DEV-750: ⌫ in an already-empty command bar or address field closes it like Esc, after
/// removing a search scope, unless the setting is off. Composition never reaches the
/// reducer: `AppUIInputTests` covers the field.
@Suite(.dependencies)
@MainActor
internal struct CommandBarEmptyDeleteTests {
	private func store(
		closesOnEmptyDelete: Bool = true,
		shortcuts: [SearchShortcut] = SearchShortcut.fixtures
	) -> TestStoreOf<CommandBarFeature> {
		let document = WorkspaceDocument.unsaved(BrowserPreferences(
			searchShortcuts: shortcuts,
			closesCommandBarOnEmptyDelete: closesOnEmptyDelete
		))
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			CommandBarFeature.State()
		}
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off
		return store
	}

	@Test
	internal func deleteInAnEmptyCommandBarClosesIt() async throws {
		let store = store()
		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.deletedWhenEmpty))
		await store.receive(\.ui.dismissed) {
			$0.isPresented = false
		}
		await store.receive(\.delegate.dismissed)
	}

	@Test
	internal func theDeleteThatEmptiesTheFieldKeepsItOpen() async throws {
		let store = store()
		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.queryChanged("a")))
		await store.send(.ui(.queryChanged("")))
		#expect(store.state.isPresented)
		await store.send(.ui(.deletedWhenEmpty))
		await store.receive(\.ui.dismissed) {
			$0.isPresented = false
		}
		await store.receive(\.delegate.dismissed)
	}

	@Test
	internal func aClearedAddressFieldCollapsesOnTheNextDelete() async throws {
		let store = store()
		await store.send(.present(.currentTab, "https://capturecontext.dev/", []))
		await store.send(.ui(.queryChanged("")))
		#expect(store.state.isPresented)
		await store.send(.ui(.deletedWhenEmpty))
		await store.receive(\.ui.dismissed) {
			$0.isPresented = false
		}
		await store.receive(\.delegate.dismissed)
	}

	@Test
	internal func aFieldWithTextIgnoresAStaleEmptyDelete() async throws {
		let store = store()
		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.queryChanged("swift")))
		await store.send(.ui(.deletedWhenEmpty))
		#expect(store.state.isPresented)
		expectNoDifference(store.state.query, "swift")
	}

	@Test
	internal func aSearchScopeGoesBeforeTheBarCloses() async throws {
		let shortcut = SearchShortcut(name: "Fixture", keyword: "fixture", template: "https://search.example/?q={query}")
		let store = store(shortcuts: [shortcut])
		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.queryChanged("fixture")))
		await store.send(.ui(.tabPressed)) {
			$0.siteSearchKeyword = "fixture"
			$0.query = ""
		}
		await store.send(.ui(.deletedWhenEmpty))
		await store.receive(\.ui.dismissed) {
			$0.siteSearchKeyword = nil
		}
		#expect(store.state.isPresented)
		await store.send(.ui(.deletedWhenEmpty))
		await store.receive(\.ui.dismissed) {
			$0.isPresented = false
		}
		await store.receive(\.delegate.dismissed)
	}

	@Test
	internal func withTheSettingOffDeleteOnlyRemovesTheScope() async throws {
		let shortcut = SearchShortcut(name: "Fixture", keyword: "fixture", template: "https://search.example/?q={query}")
		let store = store(closesOnEmptyDelete: false, shortcuts: [shortcut])
		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.deletedWhenEmpty))
		#expect(store.state.isPresented)

		await store.send(.ui(.queryChanged("fixture")))
		await store.send(.ui(.tabPressed))
		await store.send(.ui(.deletedWhenEmpty))
		await store.receive(\.ui.dismissed) {
			$0.siteSearchKeyword = nil
		}
		await store.send(.ui(.deletedWhenEmpty))
		#expect(store.state.isPresented)
	}

	@Test
	internal func theSettingIsOnByDefaultAndOlderSavesKeepIt() throws {
		#expect(BrowserPreferences().closesCommandBarOnEmptyDelete)
		let data = try JSONEncoder().encode(BrowserPreferences())
		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		#expect(values.removeValue(forKey: "closesCommandBarOnEmptyDelete") != nil)
		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: values)
		)
		#expect(decoded.closesCommandBarOnEmptyDelete)
	}
}
