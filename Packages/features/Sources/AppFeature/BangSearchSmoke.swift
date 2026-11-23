#if DEBUG
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// Checks command-bar destinations against actual Chromium documents and profile storage.
@MainActor
internal enum BangSearchSmoke {
	private static let query: String = "swift & 東京/café+100% #?!"
	private static let encodedQuery: String = "swift%20%26%20%E6%9D%B1%E4%BA%AC%2Fcaf%C3%A9%2B100%25%20%23%3F%21"

	/// Also a bundled keyword (MDN Web Docs), so the leading-bang navigation proves the user's shortcut wins.
	private static let queryKeyword: String = "mdn"
	private static let pathKeyword: String = "arxsmokepath"
	private static let bundledKeyword: String = "arxsmokebundled"

	/// A real bundled bang, previewed only: the smoke never leaves loopback.
	private static let offlineKeyword: String = "ddg"
	private static let offlinePreview: String = "https://duckduckgo.com/?q=" + encodedQuery

	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		baseURL: URL,
		profileDirectory: URL,
		fixtureRoot: URL
	) async throws {
		// Reuse the signed runner's owner-only disposable-root check before any edits.
		try AutomationSmokeFixture.validate(
			root: fixtureRoot,
			profile: profileDirectory,
			baseURL: baseURL,
			preferences: store.automationPreferences
		)
		guard
			let original = store.main.viewer.item.tab,
			let originalURL = engine.client.snapshot(original.id)?.navigation.url,
			store.littleWindows.isEmpty,
			!store.main.isPrivate,
			!store.settings.searchShortcuts.contains(where: {
				[queryKeyword, pathKeyword].contains($0.id)
			})
		else { throw Failure.invalidSource }

		let originalSpace = store.main.sidebar.spaceID
		let originalPane = store.main.viewer.activePaneID
		let originalShortcuts = store.settings.searchShortcuts
		let root = baseURL.deletingLastPathComponent().absoluteString
		let readURL = try url(root + "bang-search/read")
		let ordinarySeed = try url(root + "bang-search/seed?identity=ordinary")
		let secondarySeed = try url(root + "bang-search/seed?identity=secondary")

		// Literal expected URLs are independent of SearchShortcut.destination's encoder.
		let queryURL = try url(root + "bang-search/query?q=" + encodedQuery)
		let pathURL = try url(root + "bang-search/path/" + encodedQuery)
		let bundledURL = try url(root + "bang-search/bundled?q=" + encodedQuery)
		let shortcuts: [SearchShortcut] = [
			.init(
				name: "Arx fixture query",
				keyword: queryKeyword,
				template: root + "bang-search/query?q={query}"
			),
			.init(
				name: "Arx fixture path",
				keyword: pathKeyword,
				template: root + "bang-search/path/{query}"
			),
		]
		for shortcut in shortcuts {
			store.send(.settings(.ui(.draftChanged(shortcut))))
			store.send(.settings(.ui(.saveShortcut)))
		}
		try await wait("Shortcut settings did not reach the command bar") {
			shortcuts.allSatisfy { store.main.commandBar.shortcuts.contains($0) }
			&& store.settings.error == nil
		}

		// The bundled list is read at launch from the app bundle, with no network.
		try await wait("The bundled bang list did not load") {
			store.settings.bangs.keywordCount > 13_000
			&& store.main.commandBar.bangs === store.settings.bangs
		}
		let bundled = store.settings.bangs
		guard bundled.bang(for: queryKeyword) != nil else { throw Failure.invalidSource }

		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		try await previewOffline(store: store)
		store.send(.main(.commandBar(.ui(.dismissed))))

		await store.send(.main(.ui(.openCommand(.currentTab)))).finish()
		try await mainQuery(ordinarySeed.absoluteString, resultID: "destination", store: store)
		try await wait("Ordinary profile identity was not seeded") {
			loaded(engine, tabID: original.id, url: ordinarySeed, mode: "seed", identity: "ordinary")
			&& store.main.viewer.item.navigation == engine.client.snapshot(original.id)?.navigation
		}

		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		try await mainQuery("!\(queryKeyword) \(query)", resultID: "bang-" + queryKeyword, store: store)
		try await wait("Leading bang did not open in the invoking ordinary profile", diagnostic: {
			let tab = store.main.viewer.item.tab
			let navigation = tab.flatMap { engine.client.snapshot($0.id)?.navigation }
			let historyURL = navigation?.history.first(where: \.isCurrent)?.url
			let expectedTitle = "Arx bang|query|\(query)|ordinary|ordinary"
			let checks: [(String, Bool)] = [
				("hasTab", tab != nil),
				("freshTab", tab?.id != original.id),
				("profile", tab?.profileID == original.profileID),
				("space", store.main.sidebar.spaceID == originalSpace),
				("attached", tab.map { engine.isAttached($0.id) } ?? false),
				("snapshot", navigation != nil),
				("url", navigation?.url == queryURL),
				("loaded", navigation?.isLoading == false),
				("noError", navigation?.errorCode == nil),
				("title", navigation?.title == expectedTitle),
				("history", historyURL == queryURL),
				("observation", store.main.viewer.item.navigation == navigation),
			]
			return checks.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
		}) {
			guard let tab = store.main.viewer.item.tab else { return false }

			return tab.id != original.id
			&& tab.profileID == original.profileID
			&& store.main.sidebar.spaceID == originalSpace
			&& engine.isAttached(tab.id)
			&& loaded(engine, tabID: tab.id, url: queryURL, mode: "query", identity: "ordinary")
			&& store.main.viewer.item.navigation == engine.client.snapshot(tab.id)?.navigation
		}
		print("ARX_BANG_MAIN_SMOKE_SUCCESS")

		let secondaryProfile = Profile.ID(rawValue: UUID())
		let secondarySpace = Space.ID(rawValue: UUID())
		store.send(.settings(.delegate(.changeOrganization(.createProfile(
			secondaryProfile,
			name: "Bang smoke"
		)))))
		try await wait("Secondary profile was not published") {
			store.main.sidebar.organization.profiles.ids.contains(secondaryProfile)
		}
		store.send(.settings(.delegate(.changeOrganization(.createSpace(
			secondarySpace,
			profileID: secondaryProfile,
			name: "Bang smoke",
			icon: .stack
		)))))
		try await wait("Secondary space was not published") {
			store.main.sidebar.organization.spaces.ids.contains(secondarySpace)
		}
		store.send(.main(.sidebar(.ui(.spaceSelected(secondarySpace)))))
		try await wait("Secondary space was not presented") {
			store.main.sidebar.spaceID == secondarySpace
			&& store.main.viewer.spaceID == secondarySpace
		}
		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		try await mainQuery(readURL.absoluteString, resultID: "destination", store: store)
		try await wait("Secondary profile inherited another profile's storage") {
			guard let tab = store.main.viewer.item.tab else { return false }

			return tab.profileID == secondaryProfile
			&& loaded(engine, tabID: tab.id, url: readURL, mode: "read", identity: "empty")
			&& store.main.viewer.item.navigation == engine.client.snapshot(tab.id)?.navigation
		}
		guard let secondary = store.main.viewer.item.tab else { throw Failure.invalidSource }

		await store.send(.main(.ui(.openCommand(.currentTab)))).finish()
		try await mainQuery(secondarySeed.absoluteString, resultID: "destination", store: store)
		try await wait("Secondary profile identity was not seeded") {
			loaded(engine, tabID: secondary.id, url: secondarySeed, mode: "seed", identity: "secondary")
			&& store.main.viewer.item.navigation == engine.client.snapshot(secondary.id)?.navigation
		}
		await store.send(.main(.ui(.openCommand(.currentTab)))).finish()
		try await wait("Site-search bar did not open") { store.main.commandBar.isPresented }
		store.send(.main(.commandBar(.ui(.queryChanged(pathKeyword)))))
		store.send(.main(.commandBar(.ui(.tabPressed))))
		guard store.main.commandBar.siteSearchKeyword == pathKeyword
		else { throw Failure.missingSiteSearchMode }

		try await mainQuery(query, resultID: "bang-" + pathKeyword, store: store)
		try await wait("Site search changed the invoking tab or profile") {
			store.main.viewer.item.tab?.id == secondary.id
			&& store.main.viewer.item.tab?.profileID == secondaryProfile
			&& store.main.sidebar.spaceID == secondarySpace
			&& engine.isAttached(secondary.id)
			&& loaded(engine, tabID: secondary.id, url: pathURL, mode: "path", identity: "secondary")
			&& store.main.viewer.item.navigation == engine.client.snapshot(secondary.id)?.navigation
		}
		print("ARX_SITE_SEARCH_MAIN_SMOKE_SUCCESS")

		// A bundled entry pointing at the fixture takes the same path as `!g` or `!mdn`.
		let fixtureCatalog = BangCatalog(
			parsing: "\(bundledKeyword)\tArx bundled fixture\t0\t\(root)bang-search/bundled?q={query}"
		)
		store.send(.event(.bangsLoaded(fixtureCatalog)))
		await store.send(.main(.ui(.openCommand(.currentTab)))).finish()
		try await mainQuery("!\(bundledKeyword) \(query)", resultID: "bang-" + bundledKeyword, store: store)
		try await wait("Bundled bang did not open in the invoking tab and profile") {
			store.main.viewer.item.tab?.id == secondary.id
			&& store.main.viewer.item.tab?.profileID == secondaryProfile
			&& loaded(engine, tabID: secondary.id, url: bundledURL, mode: "bundled", identity: "secondary")
			&& store.main.viewer.item.navigation == engine.client.snapshot(secondary.id)?.navigation
		}
		store.send(.event(.bangsLoaded(bundled)))
		guard store.main.commandBar.bangs === bundled, store.settings.bangs === bundled
		else { throw Failure.invalidSource }
		print("ARX_BANG_BUNDLED_SMOKE_SUCCESS")

		// Main remains in the other profile, so a focused-profile fallback is detectable.
		store.send(.ui(.openLittleArx(originalSpace, readURL)))
		guard let little = store.littleWindows.first else { throw Failure.invalidSource }
		try await wait("Little Arx did not inherit its explicit source profile") {
			store.littleWindows[id: little.id]?.tab.profileID == original.profileID
			&& loaded(engine, tabID: little.tab.id, url: readURL, mode: "read", identity: "ordinary")
			&& store.littleWindows[id: little.id]?.viewer.navigation == engine.client.snapshot(little.tab.id)?.navigation
		}
		await store.send(.littleWindows(.element(id: little.id, action: .ui(.openCommand(.currentTab))))).finish()
		try await wait("Little Arx did not receive the bundled list") {
			store.littleWindows[id: little.id]?.commandBar.bangs === bundled
		}
		try await previewOffline(store: store, little: little.id)
		store.send(.littleWindows(.element(id: little.id, action: .commandBar(.ui(.dismissed)))))
		for siteSearch in [false, true] {
			await store.send(.littleWindows(.element(
				id: little.id,
				action: .ui(.openCommand(.currentTab))
			))).finish()
			try await wait("Little Arx command bar did not open") {
				store.littleWindows[id: little.id]?.commandBar.isPresented == true
			}
			let keyword = siteSearch ? pathKeyword : queryKeyword
			if siteSearch {
				store.send(.littleWindows(.element(
					id: little.id,
					action: .commandBar(.ui(.queryChanged(keyword)))
				)))
				store.send(.littleWindows(.element(id: little.id, action: .commandBar(.ui(.tabPressed)))))
				guard store.littleWindows[id: little.id]?.commandBar.siteSearchKeyword == keyword
				else { throw Failure.missingSiteSearchMode }
			}
			store.send(.littleWindows(.element(
				id: little.id,
				action: .commandBar(.ui(.queryChanged(siteSearch ? query : "!\(keyword) \(query)")))
			)))
			let destination = siteSearch ? pathURL : queryURL
			guard store.littleWindows[id: little.id]?.commandBar.entries.first?.presentation.subtitle == destination.absoluteString
			else { throw Failure.wrongDestinationPreview }

			store.send(.littleWindows(.element(
				id: little.id,
				action: .commandBar(.ui(.selected("bang-" + keyword)))
			)))
			try await wait("Little Arx search lost its native profile or tab") {
				store.littleWindows[id: little.id]?.tab.id == little.tab.id
				&& store.littleWindows[id: little.id]?.tab.profileID == original.profileID
				&& store.littleWindows[id: little.id]?.spaceID == originalSpace
				&& store.main.sidebar.spaceID == secondarySpace
				&& engine.isAttached(little.tab.id)
				&& loaded(
					engine,
					tabID: little.tab.id,
					url: destination,
					mode: siteSearch ? "path" : "query",
					identity: "ordinary"
				)
				&& store.littleWindows[id: little.id]?.viewer.navigation == engine.client.snapshot(little.tab.id)?.navigation
			}
			print(siteSearch ? "ARX_SITE_SEARCH_LITTLE_SMOKE_SUCCESS" : "ARX_BANG_LITTLE_SMOKE_SUCCESS")
		}

		store.send(.littleWindows(.element(id: little.id, action: .ui(.close))))
		try await wait("Little Arx search session did not close") {
			store.littleWindows[id: little.id] == nil
			&& engine.client.snapshot(little.tab.id) == nil
		}
		for shortcut in shortcuts {
			store.send(.settings(.ui(.deleteShortcut(shortcut.id))))
		}

		store.send(.main(.sidebar(.ui(.spaceSelected(originalSpace)))))
		try await wait("Original space presentation was not restored") {
			store.main.viewer.spaceID == originalSpace
			&& store.main.viewer.panes[id: originalPane] != nil
		}
		store.send(.main(.present(original.id, in: originalPane)))
		try await wait("Original ordinary tab was not restored") {
			store.main.viewer.panes[id: originalPane]?.item.tab?.id == original.id
			&& store.main.sidebar.spaceID == originalSpace
			&& store.main.commandBar.shortcuts == originalShortcuts
			&& store.main.commandBar.bangs === bundled
			&& store.settings.searchShortcuts == originalShortcuts
		}
		store.send(.main(.viewer(.command(.navigate(originalURL), in: originalPane, tabID: original.id))))
		try await wait("Original ordinary document was not restored", diagnostic: {
			let navigation = engine.client.snapshot(original.id)?.navigation
			let observed = store.main.viewer.item.navigation
			let checks: [(String, Bool)] = [
				("snapshot", navigation != nil),
				("url", navigation?.url == originalURL),
				("loaded", navigation?.isLoading == false),
				("noError", navigation?.errorCode == nil),
				("activePane", store.main.viewer.activePaneID == originalPane),
				("capturedTab", store.main.viewer.panes[id: originalPane]?.item.tab?.id == original.id),
				("activeTab", store.main.viewer.item.tab?.id == original.id),
				("observation", store.main.viewer.item.navigation == navigation),
				("observedURL", observed.url == navigation?.url),
				("observedTitle", observed.title == navigation?.title),
				("observedLoading", observed.isLoading),
				("observedError", observed.errorCode != nil),
				("observedBack", observed.canGoBack == navigation?.canGoBack),
				("observedForward", observed.canGoForward == navigation?.canGoForward),
				("observedHistory", observed.history == navigation?.history),
				("attached", engine.isAttached(original.id)),
			]
			let identity = " generation=\(store.main.viewer.item.generation)"
			+ " observedEntries=\(observed.history.count) nativeEntries=\(navigation?.history.count ?? -1)"
			+ " failed=\(store.main.viewer.item.failure != nil) panes=\(store.main.viewer.panes.count)"

			return checks.map { "\($0.0)=\($0.1)" }.joined(separator: " ") + identity
		}) {
			guard let navigation = engine.client.snapshot(original.id)?.navigation
			else { return false }

			return navigation.url == originalURL
			&& !navigation.isLoading
			&& navigation.errorCode == nil
			&& store.main.viewer.item.tab?.id == original.id
			&& store.main.viewer.item.navigation == navigation
			&& engine.isAttached(original.id)
		}
	}

	private static func mainQuery(
		_ query: String,
		resultID: String,
		store: StoreOf<AppFeature>
	) async throws {
		try await wait("Main command bar did not open") { store.main.commandBar.isPresented }
		store.send(.main(.commandBar(.ui(.queryChanged(query)))))
		guard store.main.commandBar.entries.contains(where: { $0.presentation.id == resultID })
		else { throw Failure.missingDestination }

		store.send(.main(.commandBar(.ui(.selected(resultID)))))
	}

	/// A real bundled bang resolves to its site with no request made.
	private static func previewOffline(
		store: StoreOf<AppFeature>,
		little: UUID? = nil
	) async throws {
		let text = "!\(offlineKeyword) \(query)"
		if let little {
			store.send(.littleWindows(.element(id: little, action: .commandBar(.ui(.queryChanged(text))))))
		} else {
			store.send(.main(.commandBar(.ui(.queryChanged(text)))))
		}
		let entries = little.flatMap { store.littleWindows[id: $0]?.commandBar.entries } ?? store.main.commandBar.entries
		guard
			store.settings.bangs.bang(for: offlineKeyword) != nil,
			entries.first?.presentation.id == "bang-" + offlineKeyword,
			entries.first?.presentation.subtitle == offlinePreview
		else { throw Failure.wrongDestinationPreview }
	}

	private static func loaded(
		_ engine: ChromiumBrowserEngine,
		tabID: BrowserCore.Tab.ID,
		url: URL,
		mode: String,
		identity: String
	) -> Bool {
		guard let navigation = engine.client.snapshot(tabID)?.navigation else { return false }
		let text = ["query", "path", "bundled"].contains(mode) ? query : ""

		return navigation.url == url
		&& !navigation.isLoading
		&& navigation.errorCode == nil
		&& navigation.title == "Arx bang|\(mode)|\(text)|\(identity)|\(identity)"
		&& navigation.history.first(where: \.isCurrent)?.url == url
	}

	private static func url(_ value: String) throws -> URL {
		guard let result = URL(string: value) else { throw Failure.invalidSource }
		return result
	}

	private static func wait(
		_ message: String,
		diagnostic: () -> String = { "" },
		until ready: () -> Bool
	) async throws {
		for _ in 0..<100 {
			if ready() {
				return
			}

			try await Task.sleep(for: .milliseconds(100))
		}

		let details = diagnostic()
		if !details.isEmpty {
			print("ARX_BANG_DIAGNOSTIC \(details)")
		}

		throw Failure.timedOut(message)
	}

	private enum Failure: Error {
		case invalidSource
		case missingSiteSearchMode
		case missingDestination
		case wrongDestinationPreview
		case timedOut(String)
	}
}
#endif
