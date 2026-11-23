@testable import AppFeature
import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import SettingsFeature
import Testing
import _ComposableArchitecture

@Suite(.dependencies)
@MainActor
internal struct SettingsNavigationTests {
	@Test
	internal func browsingSettingsPreservesDraftAndDoesNotWritePreferences() async {
		let draft = SearchShortcut(name: "Draft", keyword: "draft", template: "https://capturecontext.dev/{query}")
		var state = SettingsFeature.State(draft: draft)
		state.page = .searchShortcuts
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}

		await store.send(.ui(.categorySelected(.profiles))) {
			$0.category = .profiles
			$0.page = nil
		}
		await store.send(.ui(.panelPresented(.previews))) { $0.panel = .previews }
		await store.send(.ui(.panelPresented(nil))) { $0.panel = nil }
		await store.send(.ui(.shortcutQueryChanged("cmd shift n"))) { $0.shortcutQuery = "cmd shift n" }

		@Dependency(\.workspaceDocument)
		var document

		expectNoDifference(document.preferences, BrowserPreferences())
		expectNoDifference(store.state.draft, draft)
		await store.finish()
	}

	@Test
	internal func shortcutSearchUsesTheCommandRegistryAndExactKeyTokens() {
		let shortcuts = BrowserCommand.allCases.map { $0.settingsShortcut(bindings: []) }
		expectNoDifference(shortcuts.map(\.id), BrowserCommand.allCases.map(\.rawValue))
		expectNoDifference(shortcuts.filter { $0.matches("CMD+SHIFT+N") }.map(\.id), ["newPrivateWindow"])
		expectNoDifference(shortcuts.filter { $0.matches("cmd+s") }.map(\.id), ["toggleSidebar"])
		expectNoDifference(shortcuts.filter { $0.matches("⌥⌘A") }.map(\.id), ["littleArx"])
		#expect(shortcuts.first { $0.id == "settings" }?.matches("Settings") == true)
		#expect(shortcuts.allSatisfy { $0.matches("  ") })
		#expect(shortcuts.filter { $0.matches("nonexistent") }.isEmpty)
	}
}
