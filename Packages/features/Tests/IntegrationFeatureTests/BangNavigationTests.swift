import AppFeature
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test(arguments: ["newTab", "currentTab", "little"], [false, true])
	internal func searchShortcutPreservesInvokingHostAndProfile(
		host: String,
		siteSearch: Bool
	) async throws {
		var organization = fixture()
		let secondaryProfile = Profile.ID(rawValue: UUID(20))
		organization.profiles.append(.init(id: secondaryProfile, name: "Secondary"))
		organization.spaces[1] = .init(
			id: organization.spaces[1].id,
			profileID: secondaryProfile,
			name: "Secondary"
		)
		let source = organization.tabs[0]
		let temporary = BrowserCore.Tab(
			id: .init(rawValue: UUID(30)),
			profileID: secondaryProfile,
			restoration: source.restoration
		)
		let shortcut = SearchShortcut(
			name: "Fixture",
			keyword: "fixture",
			template: "https://search.example/?q={query}"
		)
		let document = WorkspaceDocument.unsaved(BrowserPreferences(searchShortcuts: [shortcut]))
		var (initial, little) = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
			main.viewer.item.tab = source
			return (
				AppFeature.State(main: main),
				LittleArxFeature.State(id: UUID(31), spaceID: organization.spaces[1].id, tab: temporary)
			)
		}
		little.viewer.tab = temporary
		initial.littleWindows.append(little)
		initial.focusedWindowID = little.id
		var opened: [BrowserCore.Tab] = []
		var navigated: [(id: BrowserCore.Tab.ID, url: URL)] = []
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.uuid = .constant(UUID(100))
			$0.browserEngine.open = { opened.append($0) }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.command = { id, command in
				guard case let .navigate(url) = command else {
					Issue.record("Expected search navigation")
					return
				}
				navigated.append((id, url))
			}
		}
		let query = "swift & 東京/50%+"
		let expected = try #require(URL(string: "https://search.example/?q=swift%20%26%20%E6%9D%B1%E4%BA%AC%2F50%25%2B"))

		if host == "little" {
			await store.send(.littleWindows(.element(id: little.id, action: .ui(.openCommand(.currentTab))))).finish()
			if siteSearch {
				await store.send(.littleWindows(.element(
					id: little.id,
					action: .commandBar(.ui(.queryChanged(shortcut.keyword)))
				))).finish()
				await store.send(.littleWindows(.element(id: little.id, action: .commandBar(.ui(.tabPressed))))).finish()
			}
			await store.send(.littleWindows(.element(
				id: little.id,
				action: .commandBar(.ui(.queryChanged(siteSearch ? query : "!fixture " + query)))
			))).finish()
			expectNoDifference(store.littleWindows[id: little.id]?.commandBar.entries.first?.presentation.subtitle, expected.absoluteString)
			await store.send(.littleWindows(.element(
				id: little.id,
				action: .commandBar(.ui(.selected("bang-fixture")))
			))).finish()

		} else {
			await store.send(.main(.ui(.openCommand(host == "newTab" ? .newTab : .currentTab)))).finish()
			if siteSearch {
				await store.send(.main(.commandBar(.ui(.queryChanged(shortcut.keyword))))).finish()
				await store.send(.main(.commandBar(.ui(.tabPressed)))).finish()
			}
			await store.send(.main(.commandBar(.ui(.queryChanged(siteSearch ? query : "!fixture " + query))))).finish()
			expectNoDifference(store.main.commandBar.entries.first?.presentation.subtitle, expected.absoluteString)
			await store.send(.main(.commandBar(.ui(.selected("bang-fixture"))))).finish()
		}

		if host == "newTab" {
			let created = try #require(opened.first)
			expectNoDifference(opened.count, 1)
			expectNoDifference(navigated.count, 0)
			expectNoDifference(created.profileID, source.profileID)
			expectNoDifference(created.restoration.url, expected)
			#expect(created.id != source.id)
			expectNoDifference(store.main.viewer.item.tab?.id, created.id)
			expectNoDifference(store.workspace.location(of: created.id), .unpinned(organization.spaces[0].id))

		} else {
			expectNoDifference(opened, [])
			expectNoDifference(navigated.map(\.id), [host == "little" ? temporary.id : source.id])
			expectNoDifference(navigated.map(\.url), [expected])
			expectNoDifference(store.workspace, initial.workspace)
		}
		expectNoDifference(store.main.sidebar.spaceID, organization.spaces[0].id)
		expectNoDifference(store.littleWindows[id: little.id]?.tab, temporary)
		expectNoDifference(store.littleWindows[id: little.id]?.spaceID, organization.spaces[1].id)
	}
}

extension IntegrationFeatureTests {
	/// The bundled list loads through the app's own client and resolves after the user's shortcuts.
	@Test(arguments: ["newTab", "currentTab", "little"])
	internal func bundledBangsNavigateAfterTheUsersShortcuts(host: String) async throws {
		let organization = fixture()
		let source = organization.tabs[0]

		// The user's !mdn clashes with the bundled MDN Web Docs bang.
		let mine = SearchShortcut(name: "Mine", keyword: "MDN", template: "https://mine.example/?q={query}")
		let document = WorkspaceDocument.unsaved(BrowserPreferences(searchShortcuts: [mine]))
		let (initialState, little) = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
			main.viewer.item.tab = source
			let little = LittleArxFeature.State(
				id: UUID(31),
				spaceID: organization.spaces[0].id,
				tab: BrowserCore.Tab(
					id: .init(rawValue: UUID(30)),
					profileID: source.profileID,
					restoration: source.restoration
				)
			)
			return (AppFeature.State(main: main), little)
		}
		var initial = initialState
		initial.littleWindows.append(little)
		initial.littleWindows[id: little.id]?.viewer.tab = little.tab
		initial.focusedWindowID = host == "little" ? little.id : initial.main.id
		let loads: LockIsolated<Int> = .init(0)
		var opened: [URL] = []
		var navigated: [URL] = []
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.uuid = .incrementing
			$0.bangCatalog.load = {
				loads.withValue { $0 += 1 }
				return try await BangCatalog.bundled()
			}
			$0.browserEngine.open = { opened.append($0.restoration.url) }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.command = { _, command in
				guard case let .navigate(url) = command else { return }
				navigated.append(url)
			}
		}

		await store.send(.loadBangs).finish()
		await store.send(.loadBangs).finish()
		expectNoDifference(loads.value, 1)
		#expect(store.settings.bangs.keywordCount > 13_000)
		#expect(store.main.commandBar.bangs === store.settings.bangs)
		#expect(store.littleWindows[id: little.id]?.commandBar.bangs === store.settings.bangs)

		let expected: [(query: String, id: String, url: String)] = [
			("!ddg swift actors", "bang-ddg", "https://duckduckgo.com/?q=swift%20actors"),
			("!G swift", "bang-g", "https://www.google.com/search?q=swift"),
			("!mdn fetch", "bang-mdn", "https://mine.example/?q=fetch"),
		]
		for (query, id, url) in expected {
			if host == "little" {
				await store.send(.littleWindows(.element(id: little.id, action: .ui(.openCommand(.currentTab))))).finish()
				await store.send(.littleWindows(.element(id: little.id, action: .commandBar(.ui(.queryChanged(query)))))).finish()
				let entry = try #require(store.littleWindows[id: little.id]?.commandBar.entries.first)
				expectNoDifference(entry.presentation.id, id)
				expectNoDifference(entry.presentation.subtitle, url)
				await store.send(.littleWindows(.element(id: little.id, action: .commandBar(.ui(.selected(id)))))).finish()
			} else {
				await store.send(.main(.ui(.openCommand(host == "newTab" ? .newTab : .currentTab)))).finish()
				await store.send(.main(.commandBar(.ui(.queryChanged(query))))).finish()
				let entry = try #require(store.main.commandBar.entries.first)
				expectNoDifference(entry.presentation.id, id)
				expectNoDifference(entry.presentation.subtitle, url)
				await store.send(.main(.commandBar(.ui(.selected(id))))).finish()
			}
		}

		let urls = expected.compactMap { URL(string: $0.url) }
		expectNoDifference(host == "newTab" ? opened : navigated, urls)
		expectNoDifference(host == "newTab" ? navigated : opened, [])
	}

	@Test
	internal func bangsResolveOnlyFromTheUsersShortcutsUntilTheBundledListLoads() async throws {
		SearchShortcut.useFixtures()
		var main = MainFeature.State(organization: fixture(), spaceID: fixture().spaces[0].id)
		main.viewer.item.tab = fixture().tabs[0]
		let store = Store(initialState: AppFeature.State(main: main)) { AppFeature() } withDependencies: {
			$0.browserEngine.events = { _ in .finished }
		}
		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged("!ddg swift"))))).finish()
		expectNoDifference(store.main.commandBar.entries.map(\.presentation.id), ["search-original"])
		await store.send(.main(.commandBar(.ui(.queryChanged("!gh swift"))))).finish()
		expectNoDifference(store.main.commandBar.entries.first?.presentation.subtitle, "https://github.com/search?q=swift")
	}
}
