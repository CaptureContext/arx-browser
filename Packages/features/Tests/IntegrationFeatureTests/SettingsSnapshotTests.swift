import AgentClient
import AppKit
@testable import AppFeature
import BrowserCore
import ChatFeature
import DefaultBrowserClient
import DiagnosticsClient
import Foundation
import MemberNumberClient
@testable import SettingsFeature
import SwiftUI
import Testing
import AppUI
import _ComposableArchitecture

/// Writes offscreen PNGs of the Settings window for visual self-review, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(.renderTurn, .dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct SettingsSnapshotTests {
	@Test(arguments: SettingsCategory.available, [false, true])
	internal func settings(_ category: SettingsCategory, dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let organization = IntegrationFeatureTests().fixture()
		var state = SettingsFeature.State()
		state.category = category
		let store = Store(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = .unavailable

			// The Arx pane's member number, not claimed yet, with both sign-ins (DEV-701).
			$0.memberNumber = .previewValue
		}
		let size = CGSize(width: SettingsWindowSize.width, height: SettingsWindowSize.height)

		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		if category == .shortcuts {
			// The same shared storage the store reads.
			state.$commandAliases.withLock { $0 = [.init(command: .pinTab, alias: "pin")] }
		}
		let shortcuts = BrowserCommand.allCases.map { $0.settingsShortcut(bindings: []) }
		let host = NSHostingView(rootView: SettingsView(store: store, organization: organization, shortcuts: shortcuts))
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "settings-\(category.rawValue)-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// Profiles › a profile: its settings on a page of their own.
	@Test(arguments: [false, true])
	internal func profilePage(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let organization = IntegrationFeatureTests().fixture()
		var state = SettingsFeature.State()
		state.category = .profiles
		state.selectedProfileID = organization.profiles.first?.id
		state.page = .profile
		let store = Store(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = .unavailable
		}
		let size = CGSize(width: SettingsWindowSize.width, height: SettingsWindowSize.height)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let host = NSHostingView(rootView: SettingsView(store: store, organization: organization))
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<8 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}

		// The top of the page, then its lower sections.
		let scrollView = try #require(Self.scrollViews(in: host).max { $0.frame.width < $1.frame.width })
		for (name, offset) in [("top", 0.0), ("bottom", 900.0)] {
			// Offsets count from the top of the content, below the bar's inset.
			scrollView.contentView.scroll(to: .init(x: 0, y: offset - scrollView.contentInsets.top))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			for _ in 0..<6 {
				host.layoutSubtreeIfNeeded()
				RunLoop.main.run(until: .now.addingTimeInterval(0.05))
			}
			let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
			host.cacheDisplay(in: host.bounds, to: representation)
			let data = try #require(representation.representation(using: .png, properties: [:]))
			try data.write(to: directory.appending(path: "settings-profile-page-\(name)-\(dark ? "dark" : "light").png"))
		}
		window.close()
	}

	/// The sidebar's search: results with their paths, and a chosen row highlighted in its pane.
	@Test(arguments: ["air", "mcp", "alias"], [false, true])
	internal func search(_ query: String, dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let organization = IntegrationFeatureTests().fixture()
		let destination = try #require(SettingsCategory.searchIndex.matching(query).first).destination
		var state = SettingsFeature.State()
		state.category = destination.category
		if case .row = destination { state.highlightedAnchor = destination.anchor }
		let store = Store(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = .unavailable
		}
		let size = CGSize(width: SettingsWindowSize.width, height: SettingsWindowSize.height)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let shortcuts = BrowserCommand.allCases.map { $0.settingsShortcut(bindings: []) }
		let host = NSHostingView(
			rootView: SettingsView(store: store, organization: organization, shortcuts: shortcuts, searchQuery: query)
		)
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<10 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "settings-search-\(query)-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// A pane scrolled down: the header has collapsed into the navigation bar's inline title.
	@Test(arguments: SettingsCategory.available, [false, true])
	internal func scrolled(_ category: SettingsCategory, dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let organization = IntegrationFeatureTests().fixture()
		var state = SettingsFeature.State()
		state.category = category
		let store = Store(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = .unavailable

			// The Arx pane's member number, not claimed yet, with both sign-ins (DEV-701).
			$0.memberNumber = .previewValue
		}
		let size = CGSize(width: SettingsWindowSize.width, height: SettingsWindowSize.height)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let shortcuts = BrowserCommand.allCases.map { $0.settingsShortcut(bindings: []) }
		let host = NSHostingView(rootView: SettingsView(store: store, organization: organization, shortcuts: shortcuts))
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}

		// The pane's scroll view is the widest one; the sidebar's is narrower.
		let scrollView = try #require(Self.scrollViews(in: host).max { $0.frame.width < $1.frame.width })
		scrollView.contentView.scroll(to: .init(x: 0, y: 260))
		scrollView.reflectScrolledClipView(scrollView.contentView)
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "settings-\(category.rawValue)-scrolled-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// The top of the sidebar at rest and with the categories scrolled under its search
	/// (DEV-782): the bar's surface reaches the window's top edge under the window controls and
	/// both sides of the sidebar, so nothing shows beside the search or above it.
	@Test(arguments: [false, true], [false, true])
	internal func sidebarTop(scrolled: Bool, dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let organization = IntegrationFeatureTests().fixture()
		let store = Store(initialState: SettingsFeature.State()) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = .unavailable
		}

		// Short, so the categories scroll.
		let size = CGSize(width: SettingsWindowSize.width, height: 260)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let host = NSHostingView(rootView: SettingsView(store: store, organization: organization))
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		if scrolled {
			// The sidebar's scroll view is the narrowest one.
			let scrollView = try #require(Self.scrollViews(in: host).min { $0.frame.width < $1.frame.width })
			scrollView.contentView.scroll(to: .init(x: 0, y: 10))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			for _ in 0..<6 {
				host.layoutSubtreeIfNeeded()
				RunLoop.main.run(until: .now.addingTimeInterval(0.05))
			}
		}
		let rect = CGRect(x: 0, y: 0, width: SettingsWindowSize.sidebarWidth + 20, height: size.height)
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: rect))
		host.cacheDisplay(in: rect, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(
			to: directory.appending(path: "settings-sidebar-top\(scrolled ? "-scrolled" : "")-\(dark ? "dark" : "light").png")
		)
		window.close()
	}

	private static func scrollViews(in view: NSView) -> [NSScrollView] {
		(view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollViews(in: $0) }
	}

	/// Settings › Assistant with a signed-in, a signed-out and a missing provider.
	@Test(arguments: [false, true])
	internal func assistant(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let organization = IntegrationFeatureTests().fixture()
		var state = SettingsFeature.State()
		state.category = .assistant
		let store = Store(initialState: state) { SettingsFeature() }
		let profile = try #require(organization.profiles.first)
		let chat = Store(
			initialState: ChatFeature.State(
				id: profile.id,
				isLoaded: true,
				settings: .init(provider: .claude, retention: .persistent),
				accounts: [
					.claude: .init(
						provider: .claude,
						status: .signedIn(.init(id: "claude", label: "person@example.com", plan: "Max"))
					),
					.openAI: .init(provider: .openAI, status: .signedOut(instructions: "Run codex login.")),
				]
			)
		) { EmptyReducer<ChatFeature.State, ChatFeature.Action>() }
		let assistant = withDependencies {
			$0.agentProviders = AgentProviders(clients: [.unimplemented(.claude), .unimplemented(.openAI)], isEnabled: false)
		} operation: {
			ChatSettingsView(stores: [chat], profiles: [profile])
		}
		let size = CGSize(width: SettingsWindowSize.width, height: SettingsWindowSize.height)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let host = NSHostingView(
			rootView: SettingsView(store: store, organization: organization, assistant: AnyView(assistant))
		)
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "settings-assistant-chats-\(dark ? "dark" : "light").png"))

		// Assistant's pages: AI Commands and Assistant Features.
		for page in SettingsPage.available where page.category == .assistant {
			store.send(.ui(.pagePresented(page)))
			for _ in 0..<4 {
				host.layoutSubtreeIfNeeded()
				RunLoop.main.run(until: .now.addingTimeInterval(0.05))
			}
			let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
			host.cacheDisplay(in: host.bounds, to: image)
			let pageData = try #require(image.representation(using: .png, properties: [:]))
			try pageData.write(to: directory.appending(path: "settings-assistant-\(page.rawValue)-\(dark ? "dark" : "light").png"))
		}
		window.close()
	}

	/// Local assistants (MCP) with one client that can read and see page text.
	@Test(arguments: [false, true])
	internal func automation(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.automation.socketPath = "/tmp/ipc.sock"
		state.automationPreferences.isEnabled = true
		state.automationPreferences.clients = [
			.init(
				id: UUID(),
				name: "Assistant",
				credentialDigest: "",
				capabilities: [.read, .pageContent],
				grantRevision: UUID()
			),
		]
		let store = Store(initialState: state) { EmptyReducer<AppFeature.State, AppFeature.Action>() }
		let host = NSHostingView(
			rootView: AutomationSettingsView(store: store, height: 1600)
				.background(Color(nsColor: .windowBackgroundColor))
		)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let size = CGSize(width: 680, height: 1600)
		host.frame = .init(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "automation-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// Previews, the one sheet a pane's row still opens (DEV-1114).
	@Test(arguments: [false, true])
	internal func previewsPanel(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let store = Store(initialState: SettingsFeature.State()) { SettingsFeature() }
		try writePanel(.previews, store: store, name: "previews", dark: dark, to: directory)
	}

	/// DEV-1114: each long list on its own page, under the Back bar, in the Settings window.
	@Test(
		arguments: [
			SettingsPage.searchShortcuts,
			.proxyLinks,
			.routing,
			.appLinks,
			.keptLoadedSites,
			.webKitSites,
			.featureFlags,
		],
		[false, true]
	)
	internal func listPage(_ page: SettingsPage, dark: Bool) throws {
		let organization = Self.listFixture()
		var state = SettingsFeature.State()
		state.category = page.category
		state.page = page
		Self.fillLists(state, organization: organization)

		// Arx launched with reading mode off, so turning it on waits for Relaunch.
		state.launchFeatureFlags = [.readingMode: false]
		let store = Store(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			// App Links lists the Mac's apps when it opens.
			$0.appLinks = .previewValue

			// Feature Flags: one flag set by the environment, iCloud sync on with its warning, and
			// a change that waits for a relaunch.
			$0.featureFlags = .init(
				state: { flag in
					switch flag {
					case .agentTabs: .init(isOn: true, source: .environment)
					case .readingMode, .sqliteWorkspace, .iCloudSync: .init(isOn: true, source: .defaults)
					default: .init(isOn: flag.isOnByDefault, source: .default)
					}
				},
				set: { _, _ in },
				reopenAfterQuit: {}
			)
		}

		try writeSettings(store, organization: organization, name: "settings-page-\(page.rawValue)", dark: dark)
	}

	/// Every pane from top to bottom, one window's height at a time, for reviewing spacing and
	/// copy across Settings in one pass (DEV-1241).
	@Test(arguments: SettingsCategory.available, [false, true])
	internal func fullPane(_ category: SettingsCategory, dark: Bool) throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = SettingsFeature.State()
		state.category = category
		let store = Store(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = .unavailable

			// Privacy reads the crash reports' status.
			$0.diagnostics = .previewValue
		}
		try writeFrames(
			store,
			organization: organization,
			name: "settings-full-\(category.rawValue)",
			dark: dark
		)
	}

	/// Profiles › a profile at its full length (DEV-1241).
	@Test(arguments: [false, true])
	internal func fullProfilePage(dark: Bool) throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = SettingsFeature.State()
		state.category = .profiles
		state.selectedProfileID = organization.profiles.first?.id
		state.page = .profile
		let store = Store(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = .unavailable
		}
		try writeFrames(store, organization: organization, name: "settings-full-profile-page", dark: dark)
	}

	/// Max, 18 Nov: each list's add button over the list (`before`, the flag off) and as the "+"
	/// on the window's top bar (`after`).
	@Test(arguments: SettingsAddTarget.allCases, [false, true])
	internal func toolbarAdd(_ target: SettingsAddTarget, dark: Bool) throws {
		let page = SettingsPage.allCases.first { SettingsAddTarget(page: $0) == target }
		let category = page?.category ?? .profiles
		for addsFromToolbar in [false, true] {
			let organization = Self.listFixture()
			var state = SettingsFeature.State()
			state.category = category
			state.page = page
			Self.fillLists(state, organization: organization)
			let store = Store(initialState: state) {
				SettingsFeature()
			} withDependencies: {
				$0.appLinks = .previewValue
				$0.defaultBrowser = .unavailable
			}
			try writeSettings(
				store,
				organization: organization,
				name: "settings-add-\(page?.rawValue ?? category.rawValue)-\(addsFromToolbar ? "after" : "before")",
				dark: dark,
				addsFromToolbar: addsFromToolbar
			)
		}
	}

	/// DEV-1114: the panes whose lists became drill-down rows, each with its count.
	@Test(arguments: [SettingsCategory.general, .links, .advanced], [false, true])
	internal func drillDownRows(_ category: SettingsCategory, dark: Bool) throws {
		let organization = Self.listFixture()
		var state = SettingsFeature.State()
		state.category = category
		Self.fillLists(state, organization: organization)
		let store = Store(initialState: state) { SettingsFeature() }

		// General's Search section and Advanced's WebKit section sit low in their panes.
		let offset: CGFloat? = switch category {
		case .general: 900
		case .advanced: 700
		default: nil
		}
		try writeSettings(
			store,
			organization: organization,
			name: "settings-rows-\(category.rawValue)",
			dark: dark,
			scrollBy: offset
		)
	}

	/// DEV-1174: General › Tabs with `ARX_NEW_TABS_AT_TOP` on (New tabs open and Tabs from links
	/// open) and off (the one New tabs open), with links left at the bottom.
	@Test(arguments: [false, true], [false, true])
	internal func tabPlacementRows(newTabsAtTop: Bool, dark: Bool) throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = SettingsFeature.State()
		state.category = .general
		state.newTabsAtTopAvailable = newTabsAtTop
		state.$general.withLock { general in
			general.openedTabPlacement = .top
			general.newTabPlacement = .bottom
		}
		let store = Store(initialState: state) { SettingsFeature() } withDependencies: {
			$0.defaultBrowser = .unavailable
		}
		try writeSettings(
			store,
			organization: organization,
			name: "settings-tab-placement-\(newTabsAtTop ? "two-rows" : "one-row")",
			dark: dark,
			scrollBy: Self.tabsSectionOffset
		)
	}

	/// How far General scrolls to show its Tabs section.
	private static let tabsSectionOffset: CGFloat = 330

	/// The fixture, with two sites kept loaded in its first profile.
	private static func listFixture() -> BrowserOrganization {
		var organization = IntegrationFeatureTests().fixture()
		organization.profiles[0].keptLoadedSites = ["mail.google.com", "linear.app"]
		return organization
	}

	/// A few entries in each list, through the same shared storage the store reads.
	private static func fillLists(
		_ state: SettingsFeature.State,
		organization: BrowserOrganization
	) {
		state.$proxyLinkRules.withLock { $0 = proxyRules }
		state.$webKitPages.withLock { $0 = .init(sites: ["netflix.com", "max.com", "open.spotify.com"]) }
		state.$routingPreferences.withLock {
			$0.rules = [
				.init(
					id: UUID(),
					name: "meet.example.com",
					host: "meet.example.com",
					destination: .init(scope: .currentSpace, mode: .littleArx)
				),
				.init(
					id: UUID(),
					name: "github.com/capturecontext",
					host: "github.com",
					includesSubdomains: true,
					pathPrefix: "/capturecontext",
					destination: .init(scope: .space(organization.spaces[0].id), mode: .mainBrowser)
				),
				.init(
					id: UUID(),
					name: "accounts.google.com",
					host: "accounts.google.com",
					destination: .init(scope: .ask)
				),
			]
		}
	}

	/// The Settings window scrolled from the pane's top to its bottom, one PNG per screenful
	/// (`name-1`, `name-2`, …), each overlapping the one before it a little.
	private func writeFrames(
		_ store: StoreOf<SettingsFeature>,
		organization: BrowserOrganization,
		name: String,
		dark: Bool
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let size = CGSize(width: SettingsWindowSize.width, height: SettingsWindowSize.height)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let shortcuts = BrowserCommand.allCases.map { $0.settingsShortcut(bindings: []) }
		let host = NSHostingView(rootView: SettingsView(store: store, organization: organization, shortcuts: shortcuts))
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<8 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let scrollView = try #require(Self.scrollViews(in: host).max { $0.frame.width < $1.frame.width })
		var frame = 1
		var offset: CGFloat = 0
		while true {
			scrollView.contentView.scroll(to: .init(x: 0, y: offset - scrollView.contentInsets.top))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			for _ in 0..<6 {
				host.layoutSubtreeIfNeeded()
				RunLoop.main.run(until: .now.addingTimeInterval(0.05))
			}
			let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
			host.cacheDisplay(in: host.bounds, to: representation)
			let data = try #require(representation.representation(using: .png, properties: [:]))
			try data.write(to: directory.appending(path: "\(name)-\(frame)-\(dark ? "dark" : "light").png"))

			// Lazy panes grow as they scroll: measure again each time.
			let content = scrollView.documentView?.frame.height ?? 0
			let visible = scrollView.contentView.bounds.height - scrollView.contentInsets.top
			guard offset + visible < content, frame < 12 else { break }

			offset = min(offset + visible - 80, content - visible)
			frame += 1
		}
		window.close()
	}

	/// The whole Settings window, as it opens, optionally scrolled.
	private func writeSettings(
		_ store: StoreOf<SettingsFeature>,
		organization: BrowserOrganization,
		name: String,
		dark: Bool,
		isPaneSearchExpanded: Bool = false,
		scrollBy offset: CGFloat? = nil,
		addsFromToolbar: Bool = SettingsToolbarAdd.isEnabled
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let size = CGSize(width: SettingsWindowSize.width, height: SettingsWindowSize.height)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let host = NSHostingView(
			rootView: SettingsView(
				store: store,
				organization: organization,
				isPaneSearchExpanded: isPaneSearchExpanded
			)
			.environment(\.settingsToolbarAdd, addsFromToolbar)
		)
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		if let offset {
			let scrollView = try #require(Self.scrollViews(in: host).max { $0.frame.width < $1.frame.width })
			scrollView.contentView.scroll(to: .init(x: 0, y: offset))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			for _ in 0..<6 {
				host.layoutSubtreeIfNeeded()
				RunLoop.main.run(until: .now.addingTimeInterval(0.05))
			}
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// A profile's Site Settings and Passwords sheets, under the bar with Close and the trail.
	@Test(arguments: [false, true])
	internal func profileSheets(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let profile = try #require(IntegrationFeatureTests().fixture().profiles.first)
		let siteSettings = Store(
			initialState: SiteSettingsFeature.State(profileID: profile.id, profileName: profile.name, isLoading: false)
		) { EmptyReducer<SiteSettingsFeature.State, SiteSettingsFeature.Action>() }
		let passwords = Store(
			initialState: SavedPasswordsFeature.State(profileID: profile.id, profileName: profile.name, isLoading: false)
		) { EmptyReducer<SavedPasswordsFeature.State, SavedPasswordsFeature.Action>() }
		try writeSheet(SiteSettingsView(store: siteSettings), name: "site-settings", dark: dark, to: directory)
		try writeSheet(SavedPasswordsView(store: passwords), name: "passwords", dark: dark, to: directory)
	}

	private func writeSheet(
		_ sheet: some View,
		name: String,
		dark: Bool,
		to directory: URL
	) throws {
		let host = NSHostingView(rootView: sheet.background(Color(nsColor: .windowBackgroundColor)))
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let size = host.fittingSize
		host.frame = .init(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "settings-sheet-\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// Add Shortcut's form, in its own sheet (DEV-1001).
	@Test(arguments: [false, true])
	internal func searchShortcutEditor(dark: Bool) throws {
		let store = Store(initialState: SettingsFeature.State()) { SettingsFeature() }
		store.send(.ui(.addShortcut))
		try writeView(SearchShortcutEditor(store: store, isNew: true), name: "settings-form-search-new", dark: dark)
	}

	/// DEV-1001: Settings › Advanced's site form, new, edited with a message, and for a kept-loaded
	/// site with the profile picker.
	@Test(arguments: ["webkit-new", "webkit-edit-duplicate", "kept-loaded-new"], [false, true])
	internal func siteForm(_ name: String, dark: Bool) throws {
		let organization = IntegrationFeatureTests().fixture()
		let state = SettingsFeature.State()
		state.$webKitPages.withLock { $0 = .init(sites: ["netflix.com", "max.com"]) }
		let store = Store(initialState: state) { SettingsFeature() }
		switch name {
		case "webkit-new":
			store.send(.ui(.siteDraft(.new(.webKit, profileID: nil))))

		case "webkit-edit-duplicate":
			store.send(.ui(.siteDraft(.edit(.webKit, site: "max.com", profileID: nil))))
			if var draft = store.siteDraft {
				draft.site = "netflix.com"
				store.send(.ui(.siteDraft(.changed(draft))))
			}
			store.send(.ui(.siteDraft(.save)))

		default:
			store.send(.ui(.siteDraft(.new(.keptLoaded, profileID: organization.profiles.first?.id))))
		}

		// Two profiles, so the kept-loaded form shows its profile picker.
		var profiles = Array(organization.profiles)
		if profiles.count < 2 {
			profiles.append(Profile(id: .init(rawValue: UUID()), name: "Personal"))
		}
		try writeView(SettingsSiteForm(store: store, profiles: profiles), name: "settings-form-\(name)", dark: dark)
	}

	/// DEV-1001: Advanced's two site lists, on their pages (DEV-1114), with their Add Site… buttons.
	@Test(arguments: [false, true])
	internal func siteListButtons(dark: Bool) throws {
		var organization = IntegrationFeatureTests().fixture()
		organization.profiles[0].keptLoadedSites = ["music.example.com"]
		let state = SettingsFeature.State()
		state.$webKitPages.withLock { $0 = .init(sites: ["netflix.com", "max.com"]) }
		let store = Store(initialState: state) { SettingsFeature() }
		try writeView(
			VStack(spacing: 16) {
				SettingsWebKitSitesView(store: store)
				SettingsKeptLoadedSitesView(store: store, organization: organization)
			}
			.padding(20)
			.frame(width: 640)
			.settingsControls(),
			name: "settings-site-lists",
			dark: dark
		)
	}

	/// DEV-1001: Local assistants' Add Client form.
	@Test(arguments: [false, true])
	internal func addClientForm(dark: Bool) throws {
		try writeView(
			SettingsListForm(
				title: "Add Client",
				primaryTitle: "Add",
				isValid: false,
				onCancel: {},
				onSubmit: {}
			) {
				SettingsTextField("Client name", text: .constant(""), prompt: "My assistant")
			},
			name: "settings-form-mcp-client",
			dark: dark
		)
	}

	/// Search Shortcuts with the bar's bangs search expanded, empty and holding a query (DEV-782),
	/// on its own page (DEV-1114).
	@Test(arguments: ["", "you"], [false, true])
	internal func searchShortcutsBarSearch(_ query: String, dark: Bool) throws {
		var state = SettingsFeature.State()
		state.category = .general
		state.page = .searchShortcuts
		let store = Store(initialState: state) { SettingsFeature() }
		store.send(.ui(.bangQueryChanged(query)))
		try writeSettings(
			store,
			organization: IntegrationFeatureTests().fixture(),
			name: "settings-page-searchShortcuts-bar-search\(query.isEmpty ? "" : "-query")",
			dark: dark,
			isPaneSearchExpanded: true
		)
	}

	/// Search Shortcuts scrolled, so the list passes under the bar (DEV-782).
	@Test(arguments: [false, true])
	internal func searchShortcutsScrolled(dark: Bool) throws {
		var state = SettingsFeature.State()
		state.category = .general
		state.page = .searchShortcuts
		let store = Store(initialState: state) { SettingsFeature() }
		try writeSettings(
			store,
			organization: IntegrationFeatureTests().fixture(),
			name: "settings-page-searchShortcuts-scrolled",
			dark: dark,
			scrollBy: 90
		)
	}

	/// The Shortcuts pane's bar, scrolled so its icon and title show leading-aligned, with its
	/// search collapsed, expanded and holding a query (DEV-782, DEV-790).
	@Test(arguments: ["collapsed", "expanded", "query"], [false, true])
	internal func shortcutsBarSearch(_ search: String, dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let organization = IntegrationFeatureTests().fixture()
		var state = SettingsFeature.State()
		state.category = .shortcuts
		state.shortcutQuery = search == "query" ? "tab" : ""
		let store = Store(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = .unavailable
		}
		let size = CGSize(width: SettingsWindowSize.width, height: SettingsWindowSize.height)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let shortcuts = BrowserCommand.allCases.map { $0.settingsShortcut(bindings: []) }
		let host = NSHostingView(
			rootView: SettingsView(
				store: store,
				organization: organization,
				shortcuts: shortcuts,
				isPaneSearchExpanded: search == "expanded"
			)
		)
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let scrollView = try #require(Self.scrollViews(in: host).max { $0.frame.width < $1.frame.width })
		scrollView.contentView.scroll(to: .init(x: 0, y: 160))
		scrollView.reflectScrolledClipView(scrollView.contentView)
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "settings-shortcuts-bar-search-\(search)-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// Settings › Shortcuts' two sections (DEV-1332): with nothing customized, Default Shortcuts
	/// alone; with a recorded shortcut, an alias and a conflict choice, Customized Shortcuts above.
	@Test(arguments: [false, true], [false, true])
	internal func shortcutsSections(customized: Bool, dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let organization = IntegrationFeatureTests().fixture()
		var state = SettingsFeature.State()
		state.category = .shortcuts
		state.$keyboardShortcuts.withLock {
			$0 = customized ? [.init(command: .reload, shortcut: .init(key: "r", modifiers: [.command, .shift]))] : []
		}
		state.$commandAliases.withLock { $0 = customized ? [.init(command: .pinTab, alias: "pin")] : [] }
		state.$shortcutConflictChoices.withLock {
			$0 = customized ? [.init(command: .findInPage, resolution: .delayed)] : []
		}
		let store = Store(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = .unavailable
		}
		let size = CGSize(width: SettingsWindowSize.width, height: SettingsWindowSize.height)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let shortcuts = BrowserCommand.allCases.map { $0.settingsShortcut(bindings: state.keyboardShortcuts) }
		let host = NSHostingView(rootView: SettingsView(store: store, organization: organization, shortcuts: shortcuts))
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		let name = customized ? "customized" : "defaults"
		try data.write(to: directory.appending(path: "settings-shortcuts-sections-\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// Settings › Shortcuts' Conflict resolution pickers (DEV-1332), left of each alias: a Site
	/// default (Find), a command that keeps its keys (New Little Arx window, Quit), a key without ⌘
	/// (Switch to Space), and the footer that explains them.
	@Test(arguments: ["find", "little arx", "quit", "space 1"], [false, true])
	internal func shortcutsConflictResolution(_ query: String, dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let organization = IntegrationFeatureTests().fixture()
		var state = SettingsFeature.State()
		state.category = .shortcuts
		state.shortcutQuery = query
		state.$keyboardShortcuts.withLock { $0 = [] }
		state.$shortcutConflictChoices.withLock { $0 = [.init(command: .findNext, resolution: .delayed), .init(command: .findPrevious, resolution: .site)] }
		let store = Store(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = .unavailable
		}
		let size = CGSize(width: SettingsWindowSize.width, height: SettingsWindowSize.height)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let shortcuts = BrowserCommand.allCases.map { $0.settingsShortcut(bindings: []) }
		let host = NSHostingView(rootView: SettingsView(store: store, organization: organization, shortcuts: shortcuts))
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		let name = query.replacingOccurrences(of: " ", with: "-")
		try data.write(to: directory.appending(path: "settings-shortcuts-conflict-\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}

	private func writePanel(
		_ panel: SettingsPanel,
		store: StoreOf<SettingsFeature>,
		name: String,
		dark: Bool,
		scrollBy offset: CGFloat? = nil,
		to directory: URL
	) throws {
		let host = NSHostingView(
			rootView: SettingsDetailView(store: store, panel: panel)
				.background(Color(nsColor: .windowBackgroundColor))
		)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let size = host.fittingSize
		host.frame = .init(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		if let offset, let scrollView = Self.scrollViews(in: host).first {
			// Content scrolled under the bar: no hard clip line, a soft edge (DEV-782).
			scrollView.contentView.scroll(to: .init(x: 0, y: offset))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			for _ in 0..<6 {
				host.layoutSubtreeIfNeeded()
				RunLoop.main.run(until: .now.addingTimeInterval(0.05))
			}
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "settings-panel-\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// Site Settings › By Default: labels lead and every pop-up lines up on the trailing edge.
	@Test(arguments: [false, true])
	internal func siteSettings(dark: Bool) throws {
		let state = SiteSettingsFeature.State(
			profileID: .init(rawValue: UUID(0)),
			profileName: "Arx",
			settings: .init(
				defaults: SitePermission.allCases.map { .init(permission: $0, setting: $0 == .popups ? .block : .ask) },
				exceptions: [
					.init(origin: "https://meet.example", permission: .camera, setting: .allow),
					.init(origin: "https://meet.example", permission: .microphone, setting: .allow, isManaged: true),
				],
				zoom: [.init(host: "docs.example", factor: 1.5)]
			),
			isLoading: false
		)
		let store = Store(initialState: state) {
			EmptyReducer<SiteSettingsFeature.State, SiteSettingsFeature.Action>()
		}
		try writeView(
			SiteSettingsView(store: store)
				.settingsControls()
				.background(Color(nsColor: .windowBackgroundColor)),
			name: "site-settings",
			dark: dark
		)
	}

	/// Site Settings with more sites than fit, under an always-shown scroll bar (DEV-775): the
	/// cards and their trailing pop-ups stay clear of the scroller.
	@Test(arguments: [false, true])
	internal func siteSettingsScroller(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let origins = (1...8).map { "https://site\($0).example" }
		let state = SiteSettingsFeature.State(
			profileID: .init(rawValue: UUID(0)),
			profileName: "Arx",
			settings: .init(
				defaults: SitePermission.allCases.map { .init(permission: $0, setting: $0 == .popups ? .block : .ask) },
				exceptions: origins.map { .init(origin: $0, permission: .camera, setting: .allow) },
				zoom: [.init(host: "docs.example", factor: 1.5)]
			),
			isLoading: false
		)
		let store = Store(initialState: state) {
			EmptyReducer<SiteSettingsFeature.State, SiteSettingsFeature.Action>()
		}
		let view = SiteSettingsView(store: store)
			.settingsControls()
			.background(Color(nsColor: .windowBackgroundColor))
		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let size = host.fittingSize
		host.frame = .init(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		for pass in 0..<6 {
			host.layoutSubtreeIfNeeded()
			if pass == 1 {
				// As "Show scroll bars: Always" draws them.
				for scrollView in Self.scrollViews(in: host) {
					scrollView.scrollerStyle = .legacy
					scrollView.autohidesScrollers = false
				}
			}
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "site-settings-scroller-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// A profile's Clear Browsing Data (DEV-772), under the Close bar with Clear Data pinned
	/// below.
	@Test(arguments: [false, true])
	internal func clearBrowsingData(dark: Bool) throws {
		let store = Store(
			initialState: ClearBrowsingDataFeature.State(profileID: .init(rawValue: UUID(0)), profileName: "Arx")
		) {
			EmptyReducer<ClearBrowsingDataFeature.State, ClearBrowsingDataFeature.Action>()
		}
		try writeView(
			ClearBrowsingDataView(store: store)
				.settingsControls(),
			name: "clear-browsing-data",
			dark: dark
		)
	}

	/// The shared modal style (DEV-766): Create a new Profile, empty and named, and a confirm
	/// sheet, Remove Space.
	@Test(arguments: ["profile-empty", "profile-filled", "remove-space", "edit-space"], [false, true])
	internal func modal(_ name: String, dark: Bool) throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = SettingsFeature.State()
		state.organizationEditorIsPresented = true
		switch name {
		case "profile-filled": state.organizationEditor = .init(kind: .profile(nil), name: "Work")
		case "edit-space":
			let space = organization.spaces[0]
			state.organizationEditor = .init(kind: .space(space.id), name: space.name)
		case "remove-space": state.organizationEditor = .init(kind: .removeSpace(organization.spaces[0].id), name: organization.spaces[0].name)
		default: state.organizationEditor = .init(kind: .profile(nil))
		}
		let store = Store(initialState: state) { SettingsFeature() }
		try writeView(
			OrganizationEditorView(store: store, organization: organization)
				.settingsControls(),
			name: "modal-\(name)",
			dark: dark
		)
	}

	/// Settings › Links › Proxy Links (DEV-767, DEV-1114): the rules list, empty and with rules,
	/// each with its drag handle on the right and no move arrows (DEV-1113).
	@Test(arguments: [false, true], [false, true])
	internal func linksRules(withRules: Bool, dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		var state = SettingsFeature.State()
		state.category = .links
		state.page = .proxyLinks
		state.$proxyLinkRules.withLock { $0 = withRules ? Self.proxyRules : [] }
		let store = Store(initialState: state) { SettingsFeature() }
		let size = CGSize(width: SettingsWindowSize.width, height: SettingsWindowSize.height)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let host = NSHostingView(rootView: SettingsView(store: store, organization: IntegrationFeatureTests().fixture()))
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		let name = withRules ? "rules" : "empty"
		try data.write(to: directory.appending(path: "links-\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// The Links rule form (DEV-767): a new rule being typed, with a link tested, and a saved
	/// rule open for editing, with Delete.
	@Test(arguments: [false, true], [false, true])
	internal func linksRuleForm(editing: Bool, dark: Bool) throws {
		var state = SettingsFeature.State()
		state.$proxyLinkRules.withLock { $0 = Self.proxyRules }
		state.proxyLinkEditor = editing
		? .init(rule: Self.proxyRules[0])
		: .init(name: "Posts on a mirror", sourceHosts: "x.com", testURL: "https://x.com/arx/status/1?utm_source=share")
		let store = Store(initialState: state) { SettingsFeature() }
		try writeView(
			ProxyLinkEditorView(store: store),
			name: "links-form-\(editing ? "edit" : "new")",
			dark: dark
		)
	}

	private static let proxyRules: [ProxyLinkRule] = [
		.init(
			id: UUID(1),
			name: "Embeds for X",
			sourceHosts: ["x.com", "twitter.com"],
			destinationTemplate: "https://fxtwitter.com{path}{query}{fragment}"
		),
		.init(
			id: UUID(2),
			name: "Old Reddit",
			sourceHosts: ["www.reddit.com"],
			destinationTemplate: "https://old.reddit.com{path}{query}",
			isEnabled: false
		),
		// One of Arx's own: a row like any other, deletable too (DEV-1113).
		ProxyLinkRule.defaults[2],
	]

	/// Renders `view` at its fitting size into `ARX_DESIGN_SNAPSHOTS` as `<name>-<appearance>.png`.
	private func writeView(
		_ view: some View,
		name: String,
		dark: Bool
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let size = host.fittingSize
		host.frame = .init(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// The quit dialog as it is, with downloads that will stop, and with one quitting would lose
	/// (DEV-966).
	@Test(arguments: [false, true], [QuitConfirmation.Downloads(), .init(active: 2), .init(active: 2, unresumable: 1)])
	internal func quitConfirmation(dark: Bool, downloads: QuitConfirmation.Downloads) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let host = NSHostingView(
			rootView: QuitConfirmationView(
				icon: Image(nsImage: NSApplication.shared.applicationIconImage),
				downloads: downloads.active,
				unresumableDownloads: downloads.unresumable
			) { _ in }
				.padding(24)
				.background(Color.gray.opacity(0.4))
		)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.fittingSize),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		let variant = downloads.active == 0 ? "" : downloads.unresumable == 0 ? "-downloads" : "-downloads-lost"
		try data.write(to: directory.appending(path: "quit\(variant)-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
