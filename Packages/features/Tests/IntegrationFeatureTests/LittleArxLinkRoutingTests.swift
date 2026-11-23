import AppKit
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import LittleArxFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-855: links from Little Arx never reach the main window unless the person asks.
@Suite(.dependencies)
@MainActor
internal struct LittleArxLinkRoutingTests {
	private static let sourceID = UUID(70)
	private static let link = URL(string: "https://accounts.example/sign-in")!

	@Test
	internal func aSameTabNavigationStaysInItsLittleArx() throws {
		var state = fixture()
		let page = state.littleWindows[id: Self.sourceID]!.tab
		let before = state

		// A redirect or form submit lands in the same page: its Little Arx follows it.
		let navigation = BrowserNavigation(url: Self.link, title: "Sign in")
		_ = LittleArxFeature()._reduce(
			into: &state.littleWindows[id: Self.sourceID]!,
			action: .viewer(.delegate(.navigation(page.id, navigation)))
		)
		expectNoDifference(state.littleWindows[id: Self.sourceID]?.tab.restoration.url, Self.link)
		expectNoDifference(state.littleWindows.ids, before.littleWindows.ids)
		expectNoDifference(state.workspace, before.workspace)
		expectNoDifference(state.windows, before.windows)
		expectNoDifference(state.main.viewer, before.main.viewer)

		// A plain click on a link to another site goes on in the page: Little Arx's page is in
		// no space, so neither Peek setting applies to it.
		let crossSite = BrowserCrossSiteLink(
			sourceTabID: page.id,
			profileID: page.profileID,
			sourceSessionRevision: 3,
			sourceDocumentRevision: 7,
			url: Self.link
		)
		#expect(state.crossSiteLinkAction(for: crossSite, pointer: nil, engine: engine(source: page.id)) == nil)
	}

	/// `target=_blank` (foreground tab), a ⌘-click (background tab), and `window.open`
	/// as a popup or a window.
	@Test(arguments: [
		BrowserNewContents.Disposition.foregroundTab,
		.backgroundTab,
		.popup,
		.window,
	])
	internal func aNewTabOrPopupOpensInANewLittleArxWithItsOpener(
		disposition: BrowserNewContents.Disposition
	) throws {
		var state = fixture()
		let source = state.littleWindows[id: Self.sourceID]!
		state.focusedWindowID = source.id
		let offer = offer(from: source, disposition: disposition)
		let before = state

		// A ⌘-click reaches Arx as Chromium's own tab, not as Little Arx's binding. (A
		// Shift-click asks for a window, which Peek may take, as it does today.)
		#expect(disposition == .window || state.linkClickAction(
			for: offer,
			modifiers: [.command],
			pointer: nil,
			engine: engine(source: source.tab.id, child: offer.tab.id)
		) == nil)

		apply(offer, to: &state)

		let added = state.littleWindows.filter { $0.id != source.id }
		#expect(added.count == 1)
		let little = try #require(added.first)

		// The engine's own page, adopted as is: never recreated from its URL, so its
		// `window.opener` and `postMessage` still reach the source page.
		expectNoDifference(little.tab, offer.tab)
		expectNoDifference(little.openerWindowID, source.id)
		expectNoDifference(little.spaceID, source.spaceID)
		#expect(!little.isCommandOnly)
		expectNoDifference(
			state.focusedWindowID,
			disposition == .backgroundTab ? source.id : little.id
		)

		// Nothing reaches the main window, another window or a space's tabs.
		expectNoDifference(state.workspace, before.workspace)
		#expect(state.unsavedOrganization == nil)
		expectNoDifference(state.main, before.main)
		expectNoDifference(state.windows, before.windows)
		expectNoDifference(state.littleWindows[id: source.id], source)
	}

	@Test
	internal func aPopupThatClosesItselfClosesItsLittleArxAndFocusReturnsToItsOpener() async throws {
		var state = fixture()
		let source = state.littleWindows[id: Self.sourceID]!
		let popupOffer = offer(from: source, disposition: .popup)
		apply(popupOffer, to: &state)
		let popup = try #require(state.littleWindows.first { $0.id != source.id })
		state.littleWindows[id: popup.id]?.viewer.tab = popup.tab
		#expect(state.focusedWindowID == popup.id)

		let closed = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_000)

			// Blink ran the page's before-unload before it asked: Arx doesn't ask again.
			$0.browserEngine.permitsClosing = { _ in
				Issue.record("Asked the page's before-unload again")
				return false
			}
			$0.browserEngine.close = { id in closed.withValue { $0.append(id) } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// Another tab's request, or the source's own, closes nothing.
		await store.send(.event(.pageCloseRequested(state.workspace.tabs[0].id)))
		await store.send(.event(.pageCloseRequested(.init(rawValue: UUID(404)))))
		await store.finish()
		#expect(store.state.littleWindows.count == 2)

		await store.send(.event(.pageCloseRequested(popup.tab.id)))
		await store.skipReceivedActions()
		await store.finish()

		expectNoDifference(store.state.littleWindows.ids, [source.id])
		expectNoDifference(store.state.focusedWindowID, source.id)
		expectNoDifference(closed.value, [popup.tab.id])
		expectNoDifference(store.state.main.viewer, state.main.viewer)
		#expect(store.state.windows.isEmpty)
	}

	@Test
	internal func aPopupThatClosesInTheBackgroundLeavesFocusWhereItIs() async throws {
		var state = fixture()
		let source = state.littleWindows[id: Self.sourceID]!
		apply(offer(from: source, disposition: .popup), to: &state)
		let popup = try #require(state.littleWindows.first { $0.id != source.id })
		state.littleWindows[id: popup.id]?.viewer.tab = popup.tab
		state.focusedWindowID = state.main.id

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_000)
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.event(.pageCloseRequested(popup.tab.id)))
		await store.skipReceivedActions()
		await store.finish()

		expectNoDifference(store.state.littleWindows.ids, [source.id])
		expectNoDifference(store.state.focusedWindowID, state.main.id)
	}

	@Test
	internal func openInMainWindowIsTheLinkMenusOneWayOut() async throws {
		let state = fixture(space: 1)
		let little = state.littleWindows[id: Self.sourceID]!
		let placement = LinkContextPlacement(windowID: little.id, paneID: little.id, generation: 0)
		let action = try #require(state.linkOpenAction(Self.link, route: .mainWindow, placement: placement, origin: nil))
		guard case let .openInMainWindow(url, spaceID) = action else {
			Issue.record("Expected Open in Main Window, got \(action)")
			return
		}
		expectNoDifference(url, Self.link)
		expectNoDifference(spaceID, little.spaceID)

		// Only Little Arx offers it: not the main window, nor Peek over a Little Arx.
		let main = LinkContextPlacement(windowID: state.main.id, paneID: state.main.viewer.activePaneID, generation: 0)
		#expect(state.linkOpenAction(Self.link, route: .mainWindow, placement: main, origin: nil) == nil)
		let peek = LinkContextPlacement(windowID: little.id, paneID: little.id, peekID: UUID(77), generation: 0)
		#expect(state.linkOpenAction(Self.link, route: .mainWindow, placement: peek, origin: nil) == nil)
		#expect(state.linkOpenAction(URL(string: "mailto:a@b.c")!, route: .mainWindow, placement: placement, origin: nil) == nil)

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(action)
		await store.skipReceivedActions()
		await store.finish()

		// The main window switches to the Little Arx's space, so the link keeps its profile.
		expectNoDifference(store.state.main.sidebar.spaceID, little.spaceID)
		expectNoDifference(store.state.main.sidebar.selectedTab?.restoration.url, Self.link)
		expectNoDifference(store.state.main.sidebar.selectedTab?.profileID, little.tab.profileID)
		expectNoDifference(store.state.focusedWindowID, state.main.id)
		#expect(store.state.windowIsOpen)
		expectNoDifference(store.state.littleWindows, state.littleWindows)
	}

	/// Little Arx never shows a private page, so a private offer can't come from one: a
	/// private window's new tabs and popups stay private (NativeContentsPresentationTests),
	/// and nothing private ever opens a Little Arx or a space's tab.
	@Test(arguments: [
		BrowserNewContents.Disposition.foregroundTab,
		.backgroundTab,
		.popup,
		.window,
	])
	internal func privateOffersNeverReachLittleArx(disposition: BrowserNewContents.Disposition) throws {
		var state = fixture()
		let source = state.littleWindows[id: Self.sourceID]!
		let ordinary = offer(from: source, disposition: disposition)
		let offer = BrowserNewContents(
			sourceTabID: ordinary.sourceTabID,
			sourceSessionRevision: ordinary.sourceSessionRevision,
			sourceDocumentRevision: ordinary.sourceDocumentRevision,
			tab: ordinary.tab,
			disposition: disposition,
			isPrivate: true
		)
		let before = state
		apply(offer, to: &state)
		expectNoDifference(state, before)
		#expect(state.linkClickAction(
			for: offer,
			modifiers: [.option, .command],
			pointer: nil,
			engine: engine(source: source.tab.id, child: offer.tab.id)
		) == nil)
	}

	// MARK: - Fixture

	/// A main window and a Little Arx on space `space` showing its own page, in no space's tabs.
	private func fixture(space: Int = 0) -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		state.main.viewer.item.tab = organization.tabs[0]
		let page = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: organization.profiles[0].id,
			restoration: .init(title: "Figma", url: URL(string: "https://figma.example/file")!)
		)
		var little = LittleArxFeature.State(
			id: Self.sourceID,
			spaceID: organization.spaces[space].id,
			tab: page
		)
		little.viewer.tab = page
		state.littleWindows.append(little)
		return state
	}

	private func offer(
		from source: LittleArxFeature.State,
		disposition: BrowserNewContents.Disposition
	) -> BrowserNewContents {
		BrowserNewContents(
			sourceTabID: source.tab.id,
			sourceSessionRevision: 3,
			sourceDocumentRevision: 7,
			tab: .init(
				id: .init(rawValue: UUID(90)),
				profileID: source.tab.profileID,
				restoration: .init(title: "", url: Self.link)
			),
			disposition: disposition
		)
	}

	private func engine(
		source: BrowserCore.Tab.ID,
		child: BrowserCore.Tab.ID? = nil
	) -> BrowserEngineClient {
		var engine = BrowserEngineClient(status: { .ready })
		engine.snapshot = { id in
			if id == source { return .init(navigation: .init(), revision: 3, documentRevision: 7) }
			return id == child ? .init(navigation: .init(), revision: 1) : nil
		}
		return engine
	}

	/// The new Little Arx gets UUID(100), apart from the main window's UUID(0).
	private func apply(_ offer: BrowserNewContents, to state: inout AppFeature.State) {
		withDependencies {
			$0.uuid = .constant(UUID(100))
			$0.browserEngine.snapshot = { id in
				if id == offer.sourceTabID { return .init(navigation: .init(), revision: 3, documentRevision: 7) }
				return id == offer.tab.id ? .init(navigation: .init(), revision: 1) : nil
			}
		} operation: {
			_ = NativeContentsPresentation()._reduce(into: &state, action: .event(.browserNewContents(offer)))
		}
	}
}
