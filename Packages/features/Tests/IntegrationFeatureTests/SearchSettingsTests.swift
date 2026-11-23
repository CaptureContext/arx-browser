import AppFeature
import BrowserCore
import BrowserWorkspaceClient
import CommandBarFeature
import CustomDump
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

extension IntegrationFeatureTests {
	@Test
	internal func shortcutEncodesOneURLComponentWithoutLeakingDelimiters() async throws {
		let query = "a & b/東京+100% #?"
		let queryShortcut = SearchShortcut(
			name: "Query",
			keyword: "query",
			template: "https://capturecontext.dev/search?q={query}&fixed=1"
		)
		let pathShortcut = SearchShortcut(
			name: "Path",
			keyword: "path",
			template: "https://capturecontext.dev/find/{query}"
		)
		let url = try queryShortcut.destination(for: query)
		expectNoDifference(
			URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
			[
				.init(name: "q", value: query),
				.init(name: "fixed", value: "1"),
			]
		)
		#expect(try pathShortcut.destination(for: query).absoluteString.contains("%2F"))
		#expect(url.absoluteString.contains("%2B"))
	}

	@Test
	internal func shortcutRejectsUnsupportedPositionsSchemesAndCollisions() async throws {
		for template in [
			"javascript:{query}",
			"https://{query}.capturecontext.dev",
			"https://capturecontext.dev/?{query}=x",
			"https://capturecontext.dev/#x{query}",
			"https://capturecontext.dev/search?q=prefix{query}",
			"https://capturecontext.dev/{query}?q={query}"
		] {
			#expect(throws: (any Error).self) {
				try SearchShortcut(
					name: "Invalid",
					keyword: "x",
					template: template
				).validate()
			}
		}
		var preferences = BrowserPreferences(searchShortcuts: SearchShortcut.fixtures)
		preferences.searchShortcuts.append(.init(
			name: "Duplicate",
			keyword: "GH",
			template: "https://capturecontext.dev/{query}"
		))
		#expect(throws: (any Error).self) { try preferences.validate() }
	}

	@Test
	internal func bangsAndTabModeResolveLocallyAndUnknownRequiresExplicitSearch() async throws {
		SearchShortcut.useFixtures()
		var state = CommandBarFeature.State()
		state.query = "!gh swift & concurrency"
		guard case let .open(url) = try #require(state.entries.first).intent else {
			Issue.record("Expected direct URL")
			return
		}
		expectNoDifference(url.host(), "github.com")
		expectNoDifference(
			URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
			"swift & concurrency"
		)
		state.query = "!unknown hello"
		expectNoDifference(state.entries.map(\.presentation.id), ["search-original"])
		state.isPresented = true
		state.query = "gh"
		let store = TestStore(initialState: state) { CommandBarFeature() }
		await store.send(.ui(.tabPressed)) {
			$0.siteSearchKeyword = "gh"
			$0.query = ""

			// Before a query, the site's front page (DEV-1321).
			$0.selectedID = "front-gh"
		}
		await store.send(.ui(.dismissed)) {
			$0.siteSearchKeyword = nil
			$0.selectedID = nil
		}
		#expect(store.state.isPresented)
	}

	@Test
	internal func preferencesRoundTripThroughTheWorkspaceRecoveryContract() async throws {
		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent("workspace.json")
		var preferences = BrowserPreferences()
		preferences.grainIntensity = 0.7
		preferences.searchShortcuts.append(.init(
			name: "Custom",
			keyword: "custom",
			template: "https://capturecontext.dev/{query}"
		))
		try BrowserWorkspaceClient(file: file).save(fixture(), preferences: preferences)
		expectNoDifference(
			try BrowserWorkspaceClient(file: file).loadWithRecovery().preferences,
			preferences
		)
	}

	@Test
	internal func editingShortcutCannotSilentlyReplaceAConflictingKeyword() async throws {
		let store = Self.storeWithShortcuts()
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.draftChanged(.init(
			name: "Conflict",
			keyword: "GH",
			template: "https://capturecontext.dev/{query}"
		))))
		await store.send(.ui(.saveShortcut))
		expectNoDifference(store.state.searchShortcuts, SearchShortcut.fixtures)
		#expect(store.state.error != nil)
	}

	/// Settings with a person's own shortcuts, since Arx starts with none (DEV-1321).
	fileprivate static func storeWithShortcuts() -> TestStoreOf<SettingsFeature> {
		let document = WorkspaceDocument.unsaved(BrowserPreferences(searchShortcuts: SearchShortcut.fixtures))
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			SettingsFeature.State()
		}
		return TestStore(initialState: state) { SettingsFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
	}
}

extension IntegrationFeatureTests {
	@Test
	internal func failedPreferenceSaveStaysPendingAndAnOldAcknowledgementCannotClearIt() async throws {
		let organization = fixture()
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) { AppFeature() }
		let observation = await store.send(.observeWorkspaceDocument)
		await store.send(.settings(.ui(.grainIntensity(0.8)))) {
			$0.settings.$chromeAppearance.withLock { $0.grain.intensity = 0.8 }
		}
		await store.receive(\.event.workspaceDocumentChanged) { $0.unsavedOrganization = organization }
		await store.receive(\.delegate.save)
		await store.send(.event(.saveFailed("Disk full"))) { $0.persistenceError = "Disk full" }
		await store.send(.event(.saveSucceeded(organization, .init())))
		expectNoDifference(store.state.settings.chromeAppearance.grain.intensity, 0.8)
		expectNoDifference(store.state.unsavedOrganization, organization)
		await observation.cancel()
	}
}

extension IntegrationFeatureTests {
	private static let bundledFixture: BangCatalog = .init(parsing: """
	g goog google\tGoogle\t1\thttps://www.google.com/search?q={query}
	gh\tBundled GitHub\t1\thttps://bundled.example/gh?q={query}
	gmail\tGmail\t0\thttps://mail.google.com/mail/#search/{query}
	price\tPrice\t1\thttps://price.example/?q={query}
	""")

	@Test
	internal func bundledSuggestionsFollowTheUsersShortcutsAndTabModeStaysWithThem() async throws {
		SearchShortcut.useFixtures()
		var state = CommandBarFeature.State(bangs: Self.bundledFixture)
		state.query = "!"
		expectNoDifference(
			state.entries.map(\.presentation.title),
			[
				"!gh · GitHub", "!yt · YouTube", "!w · Wikipedia",
				"!g · Google", "!gmail · Gmail", "!price · Price",
				String.localized(.appUI.search.original),
			]
		)
		state.query = "!go"
		expectNoDifference(
			state.entries.map(\.presentation.title),
			["!goog · Google", "!google · Google", String.localized(.appUI.search.original)]
		)

		// The person's !gh wins over the bundled one; an exact bundled keyword with a query
		// searches at once, and without one enters its scoped search, homepage or not (DEV-1321).
		state.query = "!gh swift"
		expectNoDifference(state.entries.map(\.presentation.subtitle), ["https://github.com/search?q=swift"])
		state.query = "!g"
		expectNoDifference(state.entries.map(\.presentation.id), ["use-g"])
		state.query = "!gmail"
		expectNoDifference(state.entries.map(\.presentation.id), ["use-gmail"])
		expectNoDifference(state.entries.first?.presentation.subtitle, String.localized(.appUI.search.queryRequired))
		state.query = "!google"
		expectNoDifference(state.entries.first?.intent, .useShortcut("google"))

		let store = TestStore(initialState: state) { CommandBarFeature() }
		store.exhaustivity = .off
		await store.send(.present(.newTab, "", []))

		// A bundled keyword without `!` stays ordinary text, even on Tab.
		await store.send(.ui(.queryChanged("price")))
		await store.send(.ui(.tabPressed))
		#expect(store.state.siteSearchKeyword == nil)
		// Choosing a bundled suggestion enters its site-search mode.
		await store.send(.ui(.queryChanged("!goo")))
		await store.send(.ui(.selected("use-goog")))
		#expect(store.state.siteSearchKeyword == "goog")
		await store.send(.ui(.queryChanged("swift")))
		expectNoDifference(store.state.entries.first?.presentation.subtitle, "https://www.google.com/search?q=swift")
	}

	@Test
	internal func settingsListBundledBangsReadOnlyAndSearchable() async throws {
		let store = TestStore(initialState: SettingsFeature.State(bangs: Self.bundledFixture)) { SettingsFeature() }
		expectNoDifference(store.state.bundledBangResults.map(\.name), ["Google", "Bundled GitHub", "Gmail", "Price"])
		await store.send(.ui(.bangQueryChanged("!gm"))) { $0.bangQuery = "!gm" }
		expectNoDifference(store.state.bundledBangResults.map(\.name), ["Gmail"])
		await store.send(.ui(.bangQueryChanged("google"))) { $0.bangQuery = "google" }
		expectNoDifference(store.state.bundledBangResults.map(\.name), ["Google"])

		// Searching never edits the user's shortcuts, of which Arx starts with none (DEV-1321).
		expectNoDifference(store.state.searchShortcuts, [])
	}
}

extension IntegrationFeatureTests {
	@Test
	internal func addShortcutOpensAnEditorThatSaveAndCancelClose() async throws {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.addShortcut)) {
			$0.isEditingShortcut = true
			$0.editingKeyword = nil
		}
		await store.send(.ui(.cancelShortcutEdit)) {
			$0.isEditingShortcut = false
		}
		await store.send(.ui(.addShortcut))
		let shortcut = SearchShortcut(
			name: "Docs",
			keyword: "docs",
			template: "https://capturecontext.dev/docs?q={query}"
		)
		await store.send(.ui(.draftChanged(shortcut)))
		await store.send(.ui(.saveShortcut)) {
			$0.isEditingShortcut = false
		}
		#expect(store.state.searchShortcuts.contains(shortcut))
	}

	@Test
	internal func deletingTheShortcutBeingEditedClosesItsEditor() async throws {
		let keyword = try #require(SearchShortcut.fixtures.first).id
		let store = Self.storeWithShortcuts()
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.editShortcut(keyword))) {
			$0.isEditingShortcut = true
			$0.editingKeyword = keyword
		}
		await store.send(.ui(.deleteShortcut(keyword))) {
			$0.isEditingShortcut = false
			$0.editingKeyword = nil
		}
	}
}
