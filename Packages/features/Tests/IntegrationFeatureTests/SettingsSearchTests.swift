import AppKit
import BrowserCore
import CustomDump
import DefaultBrowserClient
import DiagnosticsClient
import Foundation
import MemberNumberClient
@testable import SettingsFeature
import SwiftUI
import Testing
import _ComposableArchitecture

/// Settings' sidebar search: its index, matching, and what choosing a result does.
@MainActor
@Suite(.renderTurn, .dependencies)
internal struct SettingsSearchTests {
	@Test
	func everyEntryResolvesToARowItsPanePlaces() throws {
		let index = SettingsCategory.searchIndex
		for category in SettingsCategory.available {
			let expected = Set(index.filter { $0.destination.category == category }.compactMap(\.destination.anchor))
			guard !expected.isEmpty else { continue }

			// General › Tabs places one placement row without `ARX_NEW_TABS_AT_TOP`, two with it
			// (DEV-1174).
			let placed = try Self.anchors(in: category)
				.union(category == .general ? Self.anchors(in: category, newTabsAtTop: true) : [])
			let missing = expected.subtracting(placed)
			#expect(missing.isEmpty, "\(category) doesn't place \(missing.map(\.rawValue).sorted())")
		}
	}

	@Test
	func entriesAreUniqueAndEveryAnchorIsFound() {
		let index = SettingsCategory.searchIndex
		expectNoDifference(Set(index.map(\.id)).count, index.count)
		let anchors = Set(index.compactMap(\.destination.anchor))
		expectNoDifference(Set(SettingsAnchor.allCases).subtracting(anchors).subtracting(SettingsAnchor.hiddenByFeatureFlags), [])
		for category in SettingsCategory.available {
			#expect(index.contains { $0.destination == .pane(category) })
		}
		for page in SettingsPage.available where page.isSearchable {
			#expect(index.contains { $0.destination == .page(page) })
		}
	}

	@Test
	func everyEntryHasItsPaneFirstInItsPath() {
		for entry in SettingsCategory.searchIndex {
			guard let path = entry.path else {
				#expect(entry.destination == .pane(entry.category))
				continue
			}
			#expect(path.hasPrefix(entry.category.title + " › "))
			#expect(path.hasSuffix(entry.title))
			expectNoDifference(entry.destination.category, entry.category)
		}
	}

	@Test(arguments: [
		("MCP", SettingsDestination.automation),
		("air", .page(.routing)),
		("Air Traffic", .page(.routing)),
		("App Links", .page(.appLinks)),
		("Proxy Links", .page(.proxyLinks)),
		("WebKit sites", .page(.webKitSites)),
		("alias", .row(.shortcuts, .commands)),
		("providers", .row(.assistant, .assistantProviders)),
		("bangs", .page(.searchShortcuts)),
		("haptic", .row(.advanced, .haptics)),
		("appearance", .pane(.appearance)),
		("middle-click", .row(.general, .linkTabSwitching)),
		("Open to an empty page", .row(.general, .emptyPageAtLaunch)),
		("collapse folders", .row(.general, .emptyPageAtLaunch)),
		("When memory runs low", .row(.advanced, .memoryPressureGrace)),
		("Sites kept loaded", .page(.keptLoadedSites)),
		("Keep pinned tabs loaded", .row(.advanced, .memoryPinnedTabs)),
		("bfcache", .row(.advanced, .backForwardCache)),
		("Pages kept", .row(.advanced, .backForwardCache)),
		("Dark pages", .row(.appearance, .darkPages)),
		("night", .row(.appearance, .darkPages)),
		("darken", .row(.appearance, .darkPages)),
		("Match site", .row(.appearance, .matchSite)),
		("website color", .row(.appearance, .matchSite)),
	])
	func queriesFindTheirSetting(_ query: String, _ destination: SettingsDestination) {
		let results = SettingsCategory.searchIndex.matching(query)
		expectNoDifference(results.first?.destination, destination)
	}

	/// Rows behind a feature flag are found only while it shows them: Link Status (DEV-1111),
	/// Dark pages (DEV-1141), Match site (DEV-1170) and General › Tabs' two placement rows, which
	/// replace the one (DEV-1174). Dark mode still finds the theme first.
	@Test
	func flaggedRowsAreFoundOnlyWithTheirFeatureFlag() {
		let index = SettingsCategory.searchIndex
		expectNoDifference(
			Set(index.filter { !$0.isAvailable(.init()) }.map(\.destination)),
			[
				.row(.links, .linkStatus),
				.row(.appearance, .darkPages),
				.row(.appearance, .matchSite),
				.row(.general, .openedTabPlacement),
			]
		)
		expectNoDifference(index.filter { !$0.isAvailable(.all) }.map(\.destination), [.row(.general, .newTabPlacement)])

		let shown = index.filter { $0.isAvailable(.init(darkPages: true)) }
		expectNoDifference(shown.matching("night").first?.destination, .row(.appearance, .darkPages))
		#expect(shown.matching("dark mode").contains { $0.destination == .row(.appearance, .darkPages) })
		expectNoDifference(shown.matching("dark mode").first?.destination, .row(.appearance, .theme))
		let hidden = index.filter { $0.isAvailable(.init()) }
		#expect(!hidden.matching("night").contains { $0.destination == .row(.appearance, .darkPages) })
	}

	/// DEV-871: search finds AI Commands only in a build that lists it.
	@Test
	func aiCommandsIsFoundOnlyWhileListed() async throws {
		let results = SettingsCategory.searchIndex.matching("AI Commands")
		if SettingsPage.available.contains(.aiCommands) {
			expectNoDifference(results.first?.destination, .page(.aiCommands))
		} else {
			#expect(!results.contains { $0.destination == .page(.aiCommands) })
		}
	}

	@Test
	func matchingIgnoresCaseAccentsAndSurroundingSpace() {
		let index = SettingsCategory.searchIndex
		expectNoDifference(index.matching("  mcp ").first?.destination, .automation)
		expectNoDifference(index.matching("HÁPTIC").first?.destination, .row(.advanced, .haptics))
		#expect(index.matching("   ").isEmpty)
		#expect(index.matching("zzzzqqq").isEmpty)
	}

	@Test
	func pathsNameThePaneAndTheSetting() throws {
		let automation = try #require(SettingsCategory.searchIndex.first { $0.destination == .automation })
		expectNoDifference(
			automation.path,
			SettingsCategory.advanced.title + " › " + String.localized(.appUI.automation.title)
		)
	}

	// MARK: - Choosing a result

	@Test
	func choosingARowOpensItsPaneAndHighlightsItForAMoment() async {
		let clock = TestClock()
		let store = TestStore(initialState: SettingsFeature.State()) {
			SettingsFeature()
		} withDependencies: {
			$0.continuousClock = clock
		}
		await store.send(.ui(.searchResultChosen(.row(.advanced, .haptics)))) {
			$0.category = .advanced
			$0.highlightedAnchor = .haptics
		}
		await clock.advance(by: SettingsFeature.highlightDuration)
		await store.receive(\.event.highlightEnded) {
			$0.highlightedAnchor = nil
		}
	}

	@Test
	func choosingASheetOpensItOverItsPane() async {
		let clock = TestClock()
		let store = TestStore(initialState: SettingsFeature.State()) {
			SettingsFeature()
		} withDependencies: {
			$0.continuousClock = clock
		}
		await store.send(.ui(.searchResultChosen(.panel(.previews, .previews)))) {
			$0.category = .general
			$0.panel = .previews
			$0.highlightedAnchor = .previews
		}
		await store.send(.ui(.categorySelected(.links))) {
			$0.category = .links
			$0.panel = nil
			$0.highlightedAnchor = nil
		}
	}

	/// DEV-1114: a list found from any pane opens on its own page in its pane, and choosing
	/// another pane leaves the page.
	@Test
	func choosingAListOpensItsPage() async {
		let store = TestStore(initialState: SettingsFeature.State()) {
			SettingsFeature()
		}
		await store.send(.ui(.searchResultChosen(.page(.proxyLinks)))) {
			$0.category = .links
			$0.page = .proxyLinks
		}
		await store.send(.ui(.searchResultChosen(.page(.keptLoadedSites)))) {
			$0.category = .advanced
			$0.page = .keptLoadedSites
		}
		await store.send(.ui(.pagePresented(nil))) {
			$0.page = nil
		}
		await store.send(.ui(.pagePresented(.webKitSites))) {
			$0.page = .webKitSites
		}
		await store.send(.ui(.categorySelected(.general))) {
			$0.category = .general
			$0.page = nil
		}
	}

	@Test
	func choosingAPageShowsItAndLocalAssistantsAsksTheApp() async {
		let clock = TestClock()
		let store = TestStore(initialState: SettingsFeature.State()) {
			SettingsFeature()
		} withDependencies: {
			$0.continuousClock = clock
		}

		// A build that doesn't list AI Commands opens its pane instead (DEV-871).
		let isListed = SettingsPage.available.contains(.aiCommands)
		await store.send(.ui(.searchResultChosen(.page(.aiCommands)))) {
			$0.category = .assistant
			$0.page = isListed ? .aiCommands : nil
		}
		await store.send(.ui(.searchResultChosen(.automation))) {
			$0.category = .advanced
			$0.page = nil
			$0.highlightedAnchor = .automation
		}
		await store.receive(\.delegate.openAutomation)
		await clock.advance(by: SettingsFeature.highlightDuration)
		await store.receive(\.event.highlightEnded) {
			$0.highlightedAnchor = nil
		}
	}

	// MARK: - Helpers

	/// The anchors a pane places, read from a real layout of Settings showing it.
	private static func anchors(
		in category: SettingsCategory,
		newTabsAtTop: Bool = false
	) throws -> Set<SettingsAnchor> {
		var state = SettingsFeature.State()
		state.category = category
		state.newTabsAtTopAvailable = newTabsAtTop

		// Content blocking's section shows only with an engine that has it (DEV-884).
		state.contentBlockingAvailable = true

		// Link Status shows only with its feature flag (DEV-1111).
		state.linkStatusAvailable = true

		// Dark pages shows only with its feature flag and an engine that has them (DEV-1020).
		state.darkPagesAvailable = true

		// Match site shows only with its feature flag (DEV-1170).
		state.matchSiteAvailable = true
		let store = Store(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = .unavailable

			// Privacy reads the crash report status when it appears (DEV-887).
			$0.diagnostics = .previewValue

			// The Arx pane reads the member number and its sign-ins when it appears (DEV-701).
			$0.memberNumber = .previewValue
		}
		let sink = AnchorSink()
		let size = CGSize(width: SettingsWindowSize.width, height: SettingsWindowSize.height)
		let host = NSHostingView(
			rootView: SettingsView(
				store: store,
				shortcuts: BrowserCommand.allCases.map { .init(id: $0.rawValue, title: $0.rawValue, keys: "", searchTerms: "") },
				// The app's chat settings, which Assistant shows.
				assistant: AnyView(Text(verbatim: "Providers"))
			)
			.onPreferenceChange(SettingsAnchorsKey.self) { anchors in
				MainActor.assumeIsolated { sink.anchors.formUnion(anchors) }
			}
		)
		host.frame = .init(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		window.close()
		return sink.anchors
	}
}

@MainActor
private final class AnchorSink {
	var anchors: Set<SettingsAnchor> = []
}
