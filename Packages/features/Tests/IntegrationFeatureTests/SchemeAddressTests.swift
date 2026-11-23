import AppFeature
import AppLinkClient
@testable import AppUI
import BrowserCore
@testable import CommandBarFeature
import CustomDump
import Foundation
@testable import MainFeature
@testable import SettingsFeature
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1189: the URL bar and the command bar open typed addresses with any scheme, and
/// `arx://settings/…` and `chrome://settings/…` open Arx Settings at their place.
@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct SchemeAddressTests {
	// MARK: - The bar's rows

	@Test(arguments: [CommandBarFeature.Mode.newTab, .currentTab, .commands])
	internal func aSettingsAddressOpensFirstThenSearches(mode: CommandBarFeature.Mode) {
		let text = "arx://settings/content/protectedContent"
		let state = Self.state(mode, query: text, candidates: Self.commands)
		let entries = state.entries

		expectNoDifference(Array(entries.map(\.presentation.id).prefix(2)), ["destination", "search-typed"])
		expectNoDifference(entries.first?.intent, .open(URL(string: text)!))
		expectNoDifference(entries.first?.presentation.subtitle, String.localized(.appUI.command.settingsAddress))
		expectNoDifference(entries.first?.presentation.actionTitle, String.localized(.appUI.command.open))
		expectNoDifference(entries.dropFirst().first?.intent, .open(SearchEngine.google.url(for: text)!))
	}

	@Test
	internal func plainWordsWithAColonStillSearch() {
		for text in ["note:milk", "re:invent", "javascript:alert(1)", "arx://chat", "chrome://flags"] {
			let state = Self.state(.newTab, query: text, candidates: [])
			expectNoDifference(state.entries.map(\.presentation.id), ["destination"], "\(text)")
			expectNoDifference(state.entries.first?.intent, .open(SearchEngine.google.url(for: text)!), "\(text)")
		}
	}

	@Test
	internal func aPageAddressOpensInTheEngine() {
		for text in ["about:blank", "file:///Users/max/Notes.md"] {
			let state = Self.state(.newTab, query: text, candidates: [])
			expectNoDifference(state.entries.first?.intent, .open(URL(string: text)!), "\(text)")
			expectNoDifference(state.entries.first?.presentation.symbol, "globe")
		}
	}

	@Test
	internal func anAppsLinkNamesTheAppAndIsAskedOnce() async {
		let asked = LockIsolated<[String]>([])
		var state = CommandBarFeature.State(mode: .newTab)
		state.isPresented = true
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.commandBarSchemeApps.appName = { scheme in
				asked.withValue { $0.append(scheme) }
				return scheme == "spotify" ? "Spotify" : nil
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.queryChanged("spotify:track:4uLU")))
		await store.send(.ui(.queryChanged("spotify:track:4uLU6")))
		expectNoDifference(asked.value, ["spotify"])
		expectNoDifference(store.state.selectedID, "destination")
		let open = store.state.entries.first
		expectNoDifference(open?.intent, .open(URL(string: "spotify:track:4uLU6")!))
		expectNoDifference(open?.presentation.subtitle, String.localized(.appUI.command.opensInApp("Spotify")))

		// Without an app, `scheme:rest` is plain text.
		await store.send(.ui(.queryChanged("note:milk")))
		expectNoDifference(asked.value, ["spotify", "note"])
		expectNoDifference(store.state.entries.map(\.presentation.id), ["destination"])
	}

	@Test
	internal func anAppsLinkNothingOpensSearches() {
		var state = Self.state(.newTab, query: "anything://at-all", candidates: [])
		state.schemeApps = ["anything": String?.none]
		expectNoDifference(state.entries.map(\.presentation.id), ["destination"])
		expectNoDifference(state.entries.first?.intent, .open(SearchEngine.google.url(for: "anything://at-all")!))

		state.schemeApps = ["anything": "Anything"]
		expectNoDifference(state.entries.first?.intent, .open(URL(string: "anything://at-all")!))
	}

	@Test
	internal func chromePagesWithArxCommandsListTheCommand() {
		let state = Self.state(.newTab, query: "chrome://downloads", candidates: Self.commands)
		expectNoDifference(state.entries.map(\.intent), [.command(.downloads)])
	}

	@Test
	internal func withTheFeatureFlagOffAddressesSearchAsBefore() {
		var state = Self.state(.newTab, query: "arx://settings", candidates: [])
		state.opensSchemeAddresses = false
		expectNoDifference(state.entries.map(\.presentation.id), ["destination"])
		expectNoDifference(state.entries.first?.intent, .open(SearchEngine.google.url(for: "arx://settings")!))
	}

	// MARK: - Opening them

	@Test
	internal func protectedContentOpensSettingsAtProtectedMedia() async throws {
		let fixture = CollectionFixture()
		let clock = TestClock()
		var opened: [BrowserCore.Tab] = []
		let store = Store(initialState: fixture.app) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing

			// The row's highlight ends on a timer, which this clock holds until the test looks.
			$0.continuousClock = clock
			$0.browserEngine.open = { opened.append($0) }
			$0.browserEngine.events = { _ in .finished }
		}

		let opening = try await Self.open("arx://settings/content/protectedContent", in: store, waits: false)
		try await pollUntil("the row's highlight") { store.settings.highlightedAnchor != nil }
		#expect(store.settingsIsOpen)
		expectNoDifference(store.settings.category, .advanced)
		expectNoDifference(store.settings.highlightedAnchor, .protectedMedia)
		expectNoDifference(opened, [])
		expectNoDifference(store.workspace.tabs, fixture.organization.tabs)

		await clock.advance(by: SettingsFeature.highlightDuration)
		await opening.finish()
		expectNoDifference(store.settings.highlightedAnchor, nil)
	}

	@Test(arguments: [
		("chrome://settings/content/camera", "site"),
		("chrome://settings/passwords", "passwords"),
		("arx://settings/clearBrowserData", "clear"),
	])
	internal func aProfilesSheetOpensForTheWindowsProfile(address: String, sheet: String) async throws {
		let fixture = CollectionFixture()
		var shown: [String] = []
		let store = Store(initialState: fixture.app) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in

				// The sheets load the profile's data from the engine; only which one opens matters.
				switch action {
				case let .settings(.ui(.showSiteSettings(id))) where id == fixture.work.id: shown.append("site")
				case let .settings(.ui(.showSavedPasswords(id))) where id == fixture.work.id: shown.append("passwords")
				case let .settings(.ui(.showClearBrowsingData(id))) where id == fixture.work.id: shown.append("clear")
				default: return AppFeature()._reduce(into: &state, action: action)
				}
				return .none
			}
		} withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in Issue.record("Opened a tab") }
			$0.browserEngine.events = { _ in .finished }
		}

		try await Self.open(address, in: store)
		expectNoDifference(shown, [sheet])
		expectNoDifference(store.settings.selectedProfileID, fixture.work.id)
		#expect(store.settingsIsOpen)
	}

	@Test(arguments: ["chrome://settings/searchEngines", "chrome://settings/downloads"])
	internal func aProfilesPageOpensForTheWindowsProfile(address: String) async throws {
		let fixture = CollectionFixture()
		let store = Store(initialState: fixture.app) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in Issue.record("Opened a tab") }
			$0.browserEngine.events = { _ in .finished }
		}

		try await Self.open(address, in: store)
		#expect(store.settingsIsOpen)
		expectNoDifference(store.settings.category, .profiles)
		expectNoDifference(store.settings.selectedProfileID, fixture.work.id)
		expectNoDifference(store.settings.page, .profile)
	}

	@Test
	internal func anUnknownPathOpensSettingsAtItsTop() async throws {
		let store = Store(initialState: CollectionFixture().app) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in Issue.record("Opened a tab") }
			$0.browserEngine.events = { _ in .finished }
		}

		try await Self.open("chrome://settings/somethingNew", in: store)
		#expect(store.settingsIsOpen)
		expectNoDifference(store.settings.category, SettingsCategory.available.first)
	}

	@Test
	internal func anAppsLinkOpensInItsAppAndLeavesThePage() async throws {
		let fixture = CollectionFixture()
		let opened = LockIsolated<[URL]>([])
		let store = Store(initialState: fixture.app) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in Issue.record("Opened a tab") }
			$0.browserEngine.events = { _ in .finished }

			// The engine refuses other apps' schemes, so it's never asked to navigate to one.
			$0.browserEngine.command = { _, command in
				guard case .navigate = command else { return }
				Issue.record("Navigated")
			}
			$0.commandBarSchemeApps.appName = { $0 == "slack" ? "Slack" : nil }
			$0.appLinks.openApp = { url, application in
				#expect(application == nil)
				opened.withValue { $0.append(url) }
				return .opened
			}
		}

		try await Self.open("slack://open?team=T123", in: store)
		expectNoDifference(opened.value, [URL(string: "slack://open?team=T123")!])
		expectNoDifference(store.workspace.tabs, fixture.organization.tabs)
		#expect(!store.main.commandBar.isPresented)
	}

	// MARK: - ⌘↩ opens what's typed

	@Test
	internal func commandReturnReadsWhatsTypedAsAnAddress() {
		let expected: [(String, String?)] = [
			("example.com", "https://example.com"),
			("example.com:8080/path", "https://example.com:8080/path"),
			("intranet", "https://intranet"),
			("intranet:3000", "https://intranet:3000"),
			("intranet/wiki/Help:Contents", "https://intranet/wiki/Help:Contents"),
			("intranet/go?to=https://example.com", "https://intranet/go?to=https://example.com"),
			("localhost:3000", "http://localhost:3000"),
			("http://example.com", "http://example.com"),
			("arx://settings/privacy", "arx://settings/privacy"),
			("about:blank", "about:blank"),
			("slack://open", "slack://open"),
			// No app opens it, so it's no address.
			("anything://at-all", nil),
			// No address: ⌘↩ keeps its result action.
			("swift tips", nil),
			("note:milk", nil),
			("javascript:alert(1)", nil),
			("!gh arx", nil),
			("user:secret@example.com", nil),
		]
		for (text, url) in expected {
			var state = Self.state(.newTab, query: text, candidates: [])
			state.schemeApps = ["slack": "Slack", "anything": String?.none]
			expectNoDifference(state.typedURL, url.flatMap(URL.init(string:)), "\(text)")
		}
	}

	@Test(arguments: [
		(CommandBarFeature.Mode.newTab, "open"),
		(.commands, "newTab"),
		(.currentTab, "open"),
	])
	internal func commandReturnOpensTheTypedAddressWhereTheBarSays(mode: CommandBarFeature.Mode, opens: String) async {
		var executed: [CommandBarFeature.Execution] = []
		var state = Self.state(mode, query: "", candidates: Self.pages)
		state.selectedID = nil
		let store = Store(initialState: state) {
			Reduce<CommandBarFeature.State, CommandBarFeature.Action> { state, action in
				if case let .delegate(.execute(execution)) = action { executed.append(execution) }
				return CommandBarFeature()._reduce(into: &state, action: action)
			}
		}

		// A single word is an address for ⌘↩ too, with `https://`, as typed.
		await store.send(.ui(.queryChanged("example"))).finish()
		expectNoDifference(store.state.typedURL, URL(string: "https://example"))
		await store.send(.ui(.queryChanged("example.com/docs"))).finish()
		expectNoDifference(store.state.actionID(forShortcut: "⌘↩"), CommandBarFeature.State.openURLID)

		await store.send(.ui(.actionRequested(CommandBarFeature.State.openURLID))).finish()
		let url = URL(string: "https://example.com/docs")!
		expectNoDifference(executed.map(\.entry.intent), [opens == "newTab" ? .openInNewTab(url) : .open(url)])
		expectNoDifference(executed.map(\.isTypedAddress), [true])
		#expect(!store.state.isPresented)
	}

	@Test
	internal func openInNewTabStaysInTheActionsWithoutItsKey() throws {
		var state = Self.state(.commands, query: "docs.example", candidates: Self.pages)
		state.selectedID = "docs"
		let page = try #require(state.entries.first { $0.presentation.id == "docs" })
		let newTab = state.actions(for: page).first { $0.id == "open-new-tab" }
		#expect(newTab != nil)
		expectNoDifference(newTab?.shortcut, nil)

		// In its actions panel too, ⌘↩ stays with the typed address, which the panel lists as
		// Open as is with ⌘↩ (DEV-1319), so Open in New Tab still shows no key.
		state.actionPanel = .init(entryID: "docs")
		#expect(state.openURLTakesCommandReturn)
		expectNoDifference(state.actions(for: page).first { $0.id == "open-new-tab" }?.shortcut, nil)
		expectNoDifference(state.actionPanelActions.first { $0.shortcut == "⌘↩" }?.id, CommandBarFeature.State.openURLID)
		expectNoDifference(state.actionID(forShortcut: "⌘↩"), CommandBarFeature.State.openURLID)

		// Text that's no address leaves ⌘↩ to the highlighted result.
		var words = Self.state(.commands, query: "docs example", candidates: Self.pages)
		words.selectedID = "docs"
		expectNoDifference(words.actionID(forShortcut: "⌘↩"), "open-new-tab")
	}

	@Test(arguments: ["command", "copyURL"])
	internal func aCommandReturnTheAppBindsKeepsItsAction(binding: String) throws {
		var state = Self.state(.commands, query: "docs.example", candidates: Self.pages)
		state.selectedID = "docs"
		if binding == "command" {
			state.reservedShortcuts = [CommandBarFeature.State.Shortcut.newTab]
		} else {
			state.copyURLShortcut = CommandBarFeature.State.Shortcut.newTab
		}
		#expect(state.openURLEntry != nil)
		#expect(!state.openURLTakesCommandReturn)
		#expect(state.actionID(forShortcut: "⌘↩") != CommandBarFeature.State.openURLID)
	}

	@Test
	internal func commandReturnInTheAddressFieldReplacesThePage() async throws {
		let fixture = CollectionFixture()
		var navigated: [(BrowserCore.Tab.ID, URL)] = []
		let store = Store(initialState: fixture.app) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in Issue.record("Opened a tab") }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.command = { id, command in
				guard case let .navigate(url) = command else { return }
				navigated.append((id, url))
			}
		}

		await store.send(.main(.ui(.openCommand(.currentTab)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged("intranet/wiki"))))).finish()
		await store.send(.main(.commandBar(.ui(.actionRequested(CommandBarFeature.State.openURLID))))).finish()
		expectNoDifference(navigated.map(\.0), [fixture.source.id])
		expectNoDifference(navigated.map(\.1), [URL(string: "https://intranet/wiki")!])
	}

	@Test
	internal func commandReturnInCommandKOpensANewTab() async throws {
		let fixture = CollectionFixture()
		var opened: [BrowserCore.Tab] = []
		let store = Store(initialState: fixture.app) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { opened.append($0) }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.command = { _, command in
				if case .navigate = command { Issue.record("Replaced the page") }
			}
		}

		await store.send(.main(.ui(.openCommand(.commands)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged("intranet/wiki"))))).finish()
		await store.send(.main(.commandBar(.ui(.actionRequested(CommandBarFeature.State.openURLID))))).finish()
		expectNoDifference(opened.map(\.restoration.url), [URL(string: "https://intranet/wiki")!])
	}

	// MARK: - The shared table and Settings

	@Test
	internal func everyMappedPlaceIsOneSettingsHas() {
		let addresses = Array(SettingsAddress.chromePaths.values) + Array(SettingsAddress.chromePages.values)
		for case let .destination(id) in addresses {
			#expect(SettingsDestination(id: id) != nil, "\(id)")
		}
		expectNoDifference(
			SettingsAddress.panes,
			Set(SettingsCategory.available.map { $0.rawValue.lowercased() })
		)
	}

	@Test
	internal func arxPathsFindTheRowOrPageInThePane() {
		expectNoDifference(SettingsDestination(pane: "Advanced", item: "protectedMEDIA"), .row(.advanced, .protectedMedia))
		expectNoDifference(SettingsDestination(pane: "links", item: "appLinks"), .page(.appLinks))
		expectNoDifference(SettingsDestination(pane: "general", item: "nothing"), .pane(.general))

		// A row of another pane isn't this pane's.
		expectNoDifference(SettingsDestination(pane: "general", item: "protectedMedia"), .pane(.general))
		#expect(SettingsDestination(pane: "nowhere", item: "x") == nil)
	}

	@Test
	internal func theFeatureFlagIsOnByDefault() {
		let defaults = UserDefaults(suiteName: "SchemeAddressTests")!
		defaults.removePersistentDomain(forName: "SchemeAddressTests")
		#expect(FeatureFlag.schemeAddresses.name == "ARX_SCHEME_ADDRESSES")
		#expect(FeatureFlag.schemeAddresses.isOn(environment: [:], defaults: defaults))
		#expect(!FeatureFlag.schemeAddresses.isOn(environment: ["ARX_SCHEME_ADDRESSES": "0"], defaults: defaults))
	}

	// MARK: - Snapshot

	/// Writes the bar with each kind of address when `ARX_DESIGN_SNAPSHOTS` names a directory.
	@Test(
		.renderTurn,
		.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil),
		arguments: [false, true]
	)
	internal func snapshot(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		var slack = Self.state(.newTab, query: "slack://open", candidates: [])
		slack.schemeApps = ["slack": "Slack"]
		let states = [
			Self.state(.newTab, query: "arx://settings/content/protectedContent", candidates: []),
			slack,
			Self.state(.currentTab, query: "about:blank", candidates: []),
		]
		let view = VStack(alignment: .leading, spacing: 18) {
			ForEach(Array(states.enumerated()), id: \.offset) { _, state in
				CommandBar(
					query: .constant(state.query),
					selectedID: .constant(state.entries.first?.presentation.id),
					results: state.entries.map(\.presentation),
					style: state.mode == .currentTab ? .urlField : .palette,
					onAskAgent: {},
					onSelect: { _ in },
					onDismiss: {}
				)
				.frame(width: 640)
			}
		}
		.environment(\.commandBarIsStatic, true)
		.padding(24)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()

		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = host.appearance
		window.contentView = host
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "command-bar-scheme-addresses-\(dark ? "dark" : "light").png"))
		window.close()
	}

	// MARK: - Fixtures

	private static func state(
		_ mode: CommandBarFeature.Mode,
		query: String,
		candidates: [CommandBarFeature.Entry]
	) -> CommandBarFeature.State {
		var state = CommandBarFeature.State(mode: mode, candidates: candidates)
		state.isPresented = true
		state.query = query
		state.opensSchemeAddresses = true
		return state
	}

	private static let commands: [CommandBarFeature.Entry] = [
		.init(
			presentation: .init(id: "command-downloads", title: "Downloads", actionTitle: "Command", symbol: "arrow.down.circle"),
			intent: .command(.downloads)
		),
		.init(
			presentation: .init(id: "command-settings", title: "Settings", actionTitle: "Command", symbol: "gearshape"),
			intent: .command(.settings)
		),
	]

	private static let pages: [CommandBarFeature.Entry] = [
		.init(
			presentation: .init(id: "docs", title: "Docs example page", subtitle: "https://docs.example/", actionTitle: "Open", symbol: "globe"),
			intent: .open(URL(string: "https://docs.example/")!)
		),
	]

	/// Types `address` in the main window's ⌘T bar and takes its first row. Unless it `waits`,
	/// it leaves the row's effects running and returns them, for a test whose clock holds one.
	@discardableResult
	private static func open(
		_ address: String,
		in store: StoreOf<AppFeature>,
		waits: Bool = true
	) async throws -> StoreTask {
		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged(address))))).finish()
		let selected = try #require(store.main.commandBar.selectedID)
		expectNoDifference(selected, "destination")
		let task = store.send(.main(.commandBar(.ui(.selected(selected)))))
		if waits { await task.finish() }
		return task
	}
}
