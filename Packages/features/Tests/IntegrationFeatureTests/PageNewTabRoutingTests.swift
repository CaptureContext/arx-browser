import AppKit
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-1312: a tab a Favorite's or pinned tab's page asks for (`target="_blank"`, `window.open`
/// without window features, a form aimed at a new tab) goes where Settings › Links send that
/// tab's links to other sites. Gmail's account switch, from a mail Favorite, is one.
@Suite(.dependencies)
@MainActor
internal struct PageNewTabRoutingTests {
	/// Another account on the same site, as Gmail's account switch opens it.
	private static let otherAccount = URL(string: "https://mail.example/mail/u/1/")!
	private static let pointer = CGPoint(x: 640, y: 360)

	// MARK: - Chromium

	@Test
	internal func aFavoritesNewTabOpensInPeekWithTheEnginesOwnPage() async throws {
		let state = state(.favorite)
		let offer = offer(state)
		let opened = LockIsolated<[BrowserCore.Tab]>([])
		let store = store(state, offer: offer) { tab in opened.withValue { $0.append(tab) } }

		await store.send(.event(.browserNewContents(offer, origin: Self.pointer)))
		await store.receive(\.peekNewContents)
		await store.finish()

		let peek = try #require(store.state.peeks.first)

		// The engine's page, adopted as is: Peek shows it, so its `window.opener` and
		// `postMessage` still reach the Favorite.
		expectNoDifference(peek.tab, offer.tab)
		#expect(peek.isTemporary)
		expectNoDifference(peek.source.windowID, state.main.id)
		expectNoDifference(peek.source.tabID, offer.sourceTabID)
		expectNoDifference(peek.origin, Self.pointer)
		#expect(store.state.containsTab(offer.tab.id))
		// No tab joins the space, and the Favorite stays on screen behind the Peek.
		expectNoDifference(store.state.workspace, state.workspace)
		expectNoDifference(store.state.main.viewer.item.tab?.id, offer.sourceTabID)

		// Showing it reuses the engine's page; nothing loads it again from its URL.
		#expect(opened.value.allSatisfy { $0.id == offer.tab.id })
	}

	@Test
	internal func aFavoritesNewTabFollowsEachChoiceOfTheSetting() async throws {
		// Little Arx keeps the page and its opener too.
		let little = state(.favorite, preferences: .init(crossSiteLinkFromFavorites: .littleArx))
		let toLittle = offer(little)
		let littleStore = store(little, offer: toLittle)
		await littleStore.send(.event(.browserNewContents(toLittle)))
		await littleStore.finish()
		let window = try #require(littleStore.state.littleWindows.first)
		expectNoDifference(window.tab, toLittle.tab)
		expectNoDifference(window.openerWindowID, little.main.id)
		#expect(littleStore.state.peeks.isEmpty)
		expectNoDifference(littleStore.state.workspace.tabs.ids, little.workspace.tabs.ids)

		// New Tab and Current Tab keep the tab Chromium asked for.
		for choice in [CrossSiteLinkAction.newTab, .currentTab] {
			let tab = state(.favorite, preferences: .init(crossSiteLinkFromFavorites: choice))
			let toTab = offer(tab)
			let tabStore = store(tab, offer: toTab)
			await tabStore.send(.event(.browserNewContents(toTab)))
			await tabStore.finish()
			#expect(tabStore.state.workspace.tabs.ids.contains(toTab.tab.id), "\(choice)")
			#expect(tabStore.state.peeks.isEmpty, "\(choice)")
			#expect(tabStore.state.littleWindows.isEmpty, "\(choice)")
		}
	}

	@Test
	internal func pinnedTabsFollowTheirOwnSettingAndUnpinnedTabsKeepTheTab() async throws {
		// Pinned tabs keep their links unless the person chose otherwise.
		let pinned = state(.pinned)
		let fromPinned = offer(pinned)
		let pinnedStore = store(pinned, offer: fromPinned)
		await pinnedStore.send(.event(.browserNewContents(fromPinned)))
		await pinnedStore.finish()
		#expect(pinnedStore.state.workspace.tabs.ids.contains(fromPinned.tab.id))
		#expect(pinnedStore.state.peeks.isEmpty)

		let peeking = state(.pinned, preferences: .init(crossSiteLinkFromPinnedTabs: .peek))
		let fromPeeking = offer(peeking)
		let peekingStore = store(peeking, offer: fromPeeking)
		await peekingStore.send(.event(.browserNewContents(fromPeeking)))
		await peekingStore.receive(\.peekNewContents)
		await peekingStore.finish()
		expectNoDifference(peekingStore.state.peeks.first?.tab, fromPeeking.tab)

		let unpinned = state(
			.unpinned,
			preferences: .init(crossSiteLinkFromFavorites: .peek, crossSiteLinkFromPinnedTabs: .peek)
		)
		let fromUnpinned = offer(unpinned)
		let unpinnedStore = store(unpinned, offer: fromUnpinned)
		await unpinnedStore.send(.event(.browserNewContents(fromUnpinned)))
		await unpinnedStore.finish()
		#expect(unpinnedStore.state.workspace.tabs.ids.contains(fromUnpinned.tab.id))
		#expect(unpinnedStore.state.peeks.isEmpty)
	}

	/// The person's own tab: a ⌘-click or a middle click (a background tab), any click with a
	/// modifier key, and a Shift-click's window keep what they ask for. A popup a page sizes,
	/// as a sign-in opens, still goes to Little Arx with its opener (DEV-1186).
	@Test
	internal func explicitTabsWindowsAndPopupsFromAFavoriteNeverGoToPeek() async throws {
		let state = state(.favorite)

		let background = offer(state, disposition: .backgroundTab)
		let backgroundStore = store(state, offer: background)
		await backgroundStore.send(.event(.browserNewContents(background)))
		await backgroundStore.finish()
		#expect(backgroundStore.state.workspace.tabs.ids.contains(background.tab.id))
		#expect(backgroundStore.state.peeks.isEmpty)

		let modified = offer(state)
		let modifiedStore = store(state, offer: modified)
		await modifiedStore.send(.event(.browserNewContents(modified, shiftHeld: true, modified: true)))
		await modifiedStore.finish()
		#expect(modifiedStore.state.workspace.tabs.ids.contains(modified.tab.id))
		#expect(modifiedStore.state.peeks.isEmpty)

		let popup = offer(state, disposition: .popup)
		let popupStore = store(state, offer: popup)
		await popupStore.send(.event(.browserNewContents(popup)))
		await popupStore.finish()
		expectNoDifference(popupStore.state.littleWindows.first?.tab, popup.tab)
		expectNoDifference(popupStore.state.littleWindows.first?.openerWindowID, state.main.id)
		#expect(popupStore.state.peeks.isEmpty)

		let window = offer(state, disposition: .window)
		let windowStore = store(state, offer: window)
		await windowStore.send(.event(.browserNewContents(window)))
		await windowStore.finish()
		#expect(windowStore.state.workspace.tabs.ids.contains(window.tab.id))
		#expect(windowStore.state.windows.count == 1)
		#expect(windowStore.state.peeks.isEmpty)
	}

	/// A Peek already open in the window is never replaced by the new page: a page under a Peek
	/// has no placement, so its new tab never reaches Peek, where the open Peek would have to
	/// close first while Chromium drops the page nobody took.
	@Test
	internal func aNewTabNeverReplacesAnOpenPeek() async throws {
		var state = state(.favorite)
		let source = try #require(state.peekSource(windowID: state.main.id, paneID: state.main.viewer.activePaneID))
		let open = PeekFeature.State(
			id: UUID(200),
			source: source,
			tab: .init(
				id: .init(rawValue: UUID(201)),
				profileID: source.profileID,
				restoration: .init(title: "", url: URL(string: "https://elsewhere.example/")!)
			),
			isTemporary: true
		)
		state.peeks.append(open)
		let offer = offer(state)
		let store = store(state, offer: offer)

		await store.send(.event(.browserNewContents(offer)))
		await store.finish()
		expectNoDifference(store.state.peeks.map(\.id), [open.id])
		expectNoDifference(store.state.peeks.first?.tab, open.tab)
	}

	/// A page that isn't a web page, such as `window.open()`'s `about:blank` a script then
	/// writes, can't open in Peek, so it keeps its tab.
	@Test
	internal func aNewTabPeekCantShowKeepsItsTab() async throws {
		let state = state(.favorite)
		let blank = offer(state, url: URL(string: "about:blank")!)
		let store = store(state, offer: blank)
		await store.send(.event(.browserNewContents(blank)))
		await store.finish()
		#expect(store.state.workspace.tabs.ids.contains(blank.tab.id))
		#expect(store.state.peeks.isEmpty)
	}

	@Test
	internal func closingTheNewTabsPeekClosesItsPage() async throws {
		let state = state(.favorite)
		let offer = offer(state)
		let closed = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = store(state, offer: offer, close: { id in closed.withValue { $0.append(id) } })
		await store.send(.event(.browserNewContents(offer)))
		await store.receive(\.peekNewContents)
		await store.finish()
		#expect(store.state.peeks.count == 1)

		await store.send(.ui(.dismissPeek(windowID: state.main.id)))
		await store.receive(\.event.peekReleased)
		#expect(store.state.peeks.isEmpty)
		expectNoDifference(closed.value, [offer.tab.id])
		expectNoDifference(store.state.workspace, state.workspace)
	}

	// MARK: - WebKit

	@Test
	internal func aWebKitFavoritesNewTabFollowsTheSettingUnlessThePersonChoseATab() async throws {
		let favorite = state(.favorite)
		let source = try #require(favorite.main.viewer.item.tab?.id)
		let peekStore = webKitStore(favorite)
		await peekStore.send(.webKitPages(.openNewTab(source: source, Self.otherAccount, isPageRequest: true)))
		await peekStore.receive(\.ui.peekURLFromSource)

		// A modified click, a middle click or a sized popup keeps the tab.
		let tabStore = webKitStore(favorite)
		await tabStore.send(.webKitPages(.openNewTab(source: source, Self.otherAccount, isPageRequest: false)))
		await tabStore.receive(\.main.ui.openInNewTab)

		let little = state(.favorite, preferences: .init(crossSiteLinkFromFavorites: .littleArx))
		let littleStore = webKitStore(little)
		await littleStore.send(.webKitPages(.openNewTab(source: source, Self.otherAccount, isPageRequest: true)))
		await littleStore.receive(\.ui.openLittleArx)
	}

	// MARK: - Fixture

	private func webKitStore(_ state: AppFeature.State) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
		}
		store.exhaustivity = .off
		return store
	}

	private enum SourceKind { case favorite, pinned, unpinned }

	/// The main window showing a mail page, moved to a Favorite or a space's pinned tabs.
	private func state(
		_ kind: SourceKind,
		preferences: BrowserPreferences = .init()
	) -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = withDependencies {
			$0.workspaceDocument = .unsaved(preferences)
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		let tabID = organization.spaces[0].unpinnedTabs[0]
		state.main.sidebar.select(tabID)
		state.main.viewer.item.tab = organization.tabs[id: tabID]
		let spaceID = state.workspace.spaces[0].id

		// A bookmark keeps its saved URL, as the organization requires.
		if kind != .unpinned, let tab = state.workspace.tabs[id: tabID] {
			state.workspace.tabs[id: tabID]!.savedDestination = .init(title: tab.displayTitle, url: tab.restoration.url)
		}
		switch kind {
		case .favorite:
			state.workspace.spaces[id: spaceID]!.unpinnedTabs.removeAll { $0 == tabID }
			state.workspace.profiles[0].favorites.append(tabID)
		case .pinned:
			state.workspace.spaces[id: spaceID]!.unpinnedTabs.removeAll { $0 == tabID }
			state.workspace.spaces[id: spaceID]!.savedItems.append(.tab(tabID))
		case .unpinned:
			break
		}
		return state
	}

	private func offer(
		_ state: AppFeature.State,
		disposition: BrowserNewContents.Disposition = .foregroundTab,
		url: URL = otherAccount
	) -> BrowserNewContents {
		let source = state.main.viewer.item.tab!
		return .init(
			sourceTabID: source.id,
			sourceSessionRevision: 3,
			sourceDocumentRevision: 7,
			tab: .init(
				id: .init(rawValue: UUID(90)),
				profileID: source.profileID,
				restoration: .init(title: "", url: url)
			),
			disposition: disposition
		)
	}

	/// An engine holding the source page and the page it opened.
	private func store(
		_ state: AppFeature.State,
		offer: BrowserNewContents,
		open: @escaping @Sendable (BrowserCore.Tab) -> Void = { _ in },
		close: @escaping @Sendable (BrowserCore.Tab.ID) -> Void = { _ in }
	) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.browserEngine.snapshot = { id in
				if id == offer.sourceTabID {
					return .init(navigation: .init(), revision: 3, documentRevision: 7, nativeProfileID: offer.tab.profileID)
				}
				return id == offer.tab.id ? .init(navigation: .init(), revision: 1) : nil
			}
			$0.browserEngine.open = { open($0) }
			$0.browserEngine.close = { close($0) }

			// The new page has no before-unload to ask about.
			$0.browserEngine.permitsClosing = { _ in true }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}
