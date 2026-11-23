@testable import AppFeature
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1298: Hide Element's mode. Clicks hide elements and stay in the mode; Undo shows the last
/// again; the toast's list, the site menu's entries, deletes one; Done closes the picker and
/// reloads the page only when an element hidden before needs it to come back.
@Suite(.dependencies)
@MainActor
internal struct HideElementFeatureTests {
	nonisolated private static let site = "capturecontext.dev"
	nonisolated private static let earlier = "capturecontext.dev##nav.promo"
	nonisolated private static let banner = "capturecontext.dev##aside.banner"
	nonisolated private static let footer = "capturecontext.dev##footer"
	nonisolated private static let tab = BrowserCore.Tab.ID(rawValue: UUID())

	/// The engine as the mode sees it: My filters' lines for the site, and what the app asked.
	private final class Engine: Sendable {
		let lines = LockIsolated<[String]>([HideElementFeatureTests.earlier])
		let commands = LockIsolated<[BrowserElementHidingCommand]>([])
		let shown = LockIsolated<[String]>([])
		let reloads = LockIsolated<Int>(0)
		let accents = LockIsolated<[ChromePalette.RGB]>([])

		/// The page's document; browsing on changes it.
		let document = LockIsolated<UInt64>(8)
		let events = AsyncStream<BrowserElementHidingEvent>.makeStream()

		var client: BrowserEngineClient {
			var client = BrowserEngineClient(status: { .ready })
			client.hiddenElements = { [lines] _ in
				BrowserHiddenElements(sites: [HideElementFeatureTests.site: lines.value])
			}
			client.showHiddenElement = { [lines, shown] _, filter in
				shown.withValue { $0.append(filter) }
				lines.withValue { $0.removeAll { $0 == filter } }
				return true
			}
			client.elementHidingCommand = { [commands] _, command in
				commands.withValue { $0.append(command) }
				return true
			}
			client.hideElements = { [events, accents] _, accent, _ in
				accents.withValue { $0.append(accent) }
				return events.stream
			}
			client.snapshot = { [document] _ in
				BrowserSessionSnapshot(navigation: .init(), revision: 1, documentRevision: document.value)
			}
			client.command = { [reloads] _, command in
				if command == .reload { reloads.withValue { $0 += 1 } }
			}
			return client
		}
	}

	private func store(_ engine: Engine) -> TestStoreOf<HideElementFeature> {
		let store = TestStore(initialState: HideElementFeature.State(id: Self.tab, site: Self.site)) {
			HideElementFeature()
		} withDependencies: {
			$0.browserEngine = engine.client
			$0.continuousClock = ImmediateClock()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}

	@Test
	internal func openingListsTheSitesHiddenElementsAndNamesThem() async {
		let engine = Engine()
		let store = store(engine)

		await store.send(.event(.engine(.opened)))
		await store.receive(\.event.entriesLoaded) {
			$0.entries = [.init(id: Self.earlier)]
		}
		expectNoDifference(engine.commands.value, [.describe([Self.earlier])])

		let named = BrowserHiddenElementDescription(label: "Deals", kind: .navigation)
		await store.send(.event(.engine(.described([Self.earlier: named])))) {
			$0.entries[id: Self.earlier]?.element = named
		}
		expectNoDifference(store.state.entries[id: Self.earlier]?.presentation.title, "Deals")
	}

	@Test
	internal func aClickHidesAndUndoShowsTheLastAgain() async {
		let engine = Engine()
		let store = store(engine)

		let banner = BrowserHiddenElementDescription(label: "Sale", kind: .sidebar)
		await store.send(.event(.engine(.hidden(filter: Self.banner, element: banner)))) {
			$0.entries = [.init(id: Self.banner, element: banner)]
			$0.undoable = [Self.banner]
		}
		await store.send(.event(.engine(.hidden(filter: Self.footer, element: .init(label: "Footer", kind: .footer)))))
		expectNoDifference(store.state.undoable, [Self.banner, Self.footer])
		#expect(store.state.canUndo)

		// ⌘Z, from the page's view.
		await store.send(.event(.engine(.key(.undo))))
		await store.receive(\.ui.undo) {
			$0.undoable = [Self.banner]
			$0.entries = [.init(id: Self.banner, element: banner)]
		}
		expectNoDifference(engine.shown.value, [Self.footer])
		expectNoDifference(engine.commands.value, [.unhide(Self.footer)])

		await store.send(.ui(.undo))
		expectNoDifference(engine.shown.value, [Self.footer, Self.banner])
		#expect(!store.state.canUndo)
		#expect(store.state.entries.isEmpty)
	}

	@Test
	internal func aRefusedPickSaysSoAndUndoStillShowsIt() async {
		let engine = Engine()
		let store = store(engine)

		await store.send(.event(.engine(.refused(filter: Self.banner)))) {
			$0.note = .refused
			$0.undoable = [Self.banner]
		}
		await store.send(.ui(.undo)) {
			$0.note = nil
			$0.undoable = []
		}

		// Nothing to take out of My filters; only the element to show.
		expectNoDifference(engine.shown.value, [])
		expectNoDifference(engine.commands.value, [.unhide(Self.banner)])
	}

	@Test
	internal func returnOpensTheListWhereTheKeysChooseAndDeleteAnEntry() async {
		let engine = Engine()
		let store = store(engine)
		await store.send(.event(.engine(.hidden(filter: Self.banner, element: .init(label: "Sale", kind: .sidebar)))))

		await store.send(.event(.engine(.key(.return))))
		await store.receive(\.ui.toggleList) {
			$0.isExpanded = true
			$0.selection = Self.banner
		}
		await store.receive(\.event.entriesLoaded)

		// My filters' order first, then this session's pick.
		expectNoDifference(store.state.entries.ids.elements, [Self.earlier, Self.banner])
		#expect(engine.commands.value.contains(.listOpen(true)))

		await store.send(.event(.engine(.key(.up)))) {
			$0.selection = Self.earlier
		}
		await store.send(.event(.engine(.key(.up))))
		expectNoDifference(store.state.selection, Self.earlier)

		// Delete shows the chosen element again; the next entry is chosen.
		await store.send(.event(.engine(.key(.delete))))
		await store.receive(\.ui.show) {
			$0.entries = [.init(id: Self.banner, element: .init(label: "Sale", kind: .sidebar))]
			$0.selection = Self.banner
		}
		expectNoDifference(engine.shown.value, [Self.earlier])
		#expect(engine.commands.value.contains(.unhide(Self.earlier)))
		expectNoDifference(engine.lines.value, [])

		// Escape closes the list before it's Done.
		await store.send(.event(.engine(.key(.escape))))
		await store.receive(\.ui.toggleList) {
			$0.isExpanded = false
		}
		#expect(!store.state.isFinishing)
	}

	/// A list read before uBlock drops a line shown again doesn't bring it back (Codex, round 4).
	@Test
	internal func anEntryShownAgainStaysOffAStaleList() async {
		let engine = Engine()
		let store = store(engine)
		await store.send(.event(.engine(.opened)))
		await store.receive(\.event.entriesLoaded)
		await store.send(.ui(.show(Self.earlier))) {
			$0.entries = []
			$0.removing = [Self.earlier]
		}

		// uBlock hasn't dropped it yet.
		await store.send(.event(.entriesLoaded([Self.earlier]))) {
			$0.entries = []
		}

		// Now it has.
		await store.send(.event(.entriesLoaded([]))) {
			$0.removing = []
		}
	}

	/// A line the page can't show at once comes back when Done reloads the page (Codex, round 5).
	@Test
	internal func aLineThePageCantShowAtOnceWaitsForTheReload() async {
		let engine = Engine()
		var client = engine.client
		client.elementHidingCommand = { _, command in
			if case .unhide = command { return false }
			return true
		}
		let store = TestStore(initialState: HideElementFeature.State(id: Self.tab, site: Self.site)) {
			HideElementFeature()
		} withDependencies: {
			$0.browserEngine = client
			$0.continuousClock = ImmediateClock()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.event(.entriesLoaded([Self.earlier])))
		await store.send(.ui(.show(Self.earlier))) {
			$0.waitingForReload = [Self.earlier]
		}
	}

	@Test
	internal func doneClosesThePickerAndEndsWithoutAReload() async {
		let engine = Engine()
		let store = store(engine)
		await store.send(.event(.engine(.hidden(filter: Self.banner, element: .init(label: "Sale", kind: .sidebar)))))

		await store.send(.event(.engine(.key(.escape))))
		await store.receive(\.ui.done) {
			$0.isFinishing = true
		}
		#expect(engine.commands.value.contains(.close))
		#expect(!store.state.canUndo)

		// The picker closed: the engine's stream ended.
		await store.send(.event(.ended))
		await store.receive(\.delegate.ended)
		expectNoDifference(engine.reloads.value, 0)
	}

	/// An element hidden before this time comes back only once the page loads again.
	@Test
	internal func doneReloadsThePageWhenAnElementShownWaitsForIt() async {
		let engine = Engine()
		let store = store(engine)
		await store.send(.event(.engine(.opened)))
		await store.receive(\.event.entriesLoaded)

		await store.send(.ui(.show(Self.earlier)))
		await store.send(.event(.engine(.shown(filter: Self.earlier, isVisible: false)))) {
			$0.waitingForReload = [Self.earlier]
		}
		await store.send(.ui(.done))
		await store.send(.event(.ended))
		await store.receive(\.delegate.ended)
		expectNoDifference(engine.reloads.value, 1)
	}

	/// Browsing on ends the mode; the page it went to isn't reloaded (Codex, round 2).
	@Test
	internal func aPageBrowsedAwayFromIsntReloaded() async {
		let engine = Engine()
		let store = store(engine)
		await store.send(.event(.engine(.opened)))
		await store.receive(\.event.entriesLoaded)
		await store.send(.ui(.show(Self.earlier)))
		await store.send(.event(.engine(.shown(filter: Self.earlier, isVisible: false))))

		engine.document.setValue(9)
		await store.send(.event(.ended))
		await store.receive(\.delegate.ended)
		expectNoDifference(engine.reloads.value, 0)
	}

	// MARK: - From the command

	private func appState() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let shown = organization.tabs[0]
		state.main.sidebar.organization.spaces[0].selectedTabID = shown.id
		state.main.viewer.item.tab = shown
		state.main.viewer.item.navigation = .init(url: URL(string: "https://CaptureContext.dev/arx")!)
		state.hideElementEnabled = true
		state.elementPickerEnabled = true
		return state
	}

	@Test
	internal func hideElementOpensTheModeInRedAndAgainIsDone() async throws {
		let state = appState()
		let tab = try #require(state.main.viewer.item.tab)
		let engine = Engine()
		var client = engine.client
		client.elementPickerIsAvailable = { true }
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = client
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.command(.hideElement, .window(state.main.id))))
		await store.receive(\.hideElementSessions)
		#expect(store.state.hideElementSessions[id: tab.id]?.site == "capturecontext.dev")
		// The mode's red, the design system's red accent, not the window's accent.
		try await Task.sleep(for: .milliseconds(50))
		expectNoDifference(engine.accents.value, [ChromeAccent.Preset.red.accent.rgb])

		// ⇧⌘H again is Done.
		await store.send(.ui(.command(.hideElement, .window(state.main.id))))
		await store.receive(\.hideElementSessions)
		#expect(store.state.hideElementSessions[id: tab.id]?.isFinishing == true)
		#expect(engine.commands.value.contains(.close))

		engine.events.continuation.finish()
		await store.receive(\.hideElementSessions)
		try await Task.sleep(for: .milliseconds(50))
		await store.skipReceivedActions()
		#expect(store.state.hideElementSessions.isEmpty)
	}

	/// A page the mode can't run on, such as a site with blocking off, gets uBlock's picker.
	@Test
	internal func aPageTheModeCantRunOnFallsBackToUBlocksPicker() async throws {
		let state = appState()
		let tab = try #require(state.main.viewer.item.tab)
		let uBlockPicks = LockIsolated<[BrowserCore.Tab.ID]>([])
		var client = BrowserEngineClient(status: { .ready })
		client.elementPickerIsAvailable = { true }
		client.startElementPicker = { id in
			uBlockPicks.withValue { $0.append(id) }
			return true
		}
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = client
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.command(.hideElement, .window(state.main.id))))
		await store.finish()
		await store.skipReceivedActions()
		expectNoDifference(uBlockPicks.value, [tab.id])
		#expect(store.state.hideElementSessions.isEmpty)
	}
}
