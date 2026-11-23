import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-950: a tab's live page floats in Page PiP and comes back to its tab without reloading.
/// DEV-1105: a tab's menu presents it, its window's header follows the page, and it lasts as long
/// as the window it floats from.
@Suite(.dependencies)
@MainActor
internal struct PagePictureInPictureTests {
	@Test
	internal func thePageLeavesItsWindowBeforeItFloatsAndComesBack() async throws {
		let state = fixture()
		let tab = state.workspace.tabs[0].id
		let released = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, released: released)

		await store.send(.ui(.openPagePictureInPicture(tab))) {
			$0.pagePictureInPicture = .init(tabID: tab, windowID: state.main.id)
		}
		await store.receive(\.event.pagePictureInPictureReleased) {
			$0.pagePictureInPicture?.phase = .open
		}

		// The window's page view let go first, so the floating window can take the page.
		expectNoDifference(released.value, [tab])

		// It's on screen: automatic media PiP leaves it alone, and archiving counts it as viewed.
		expectNoDifference(store.state.media.tabsFloatingElsewhere, [tab])
		#expect(store.state.tabsOnScreen.contains(tab))

		await store.send(.ui(.closePagePictureInPicture(focusesTab: false))) {
			$0.pagePictureInPicture?.phase = .returning(focusesTab: false)
		}
		await store.send(.event(.pagePictureInPictureClosed(tab))) {
			$0.pagePictureInPicture = nil
		}
		await store.finish()
	}

	@Test
	internal func theCommandFloatsAndBringsBack() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		#expect(state.pagePictureInPictureTab(for: .window(state.main.id)) == tab)

		state.pagePictureInPicture = .init(tabID: tab, windowID: state.main.id, phase: .open)
		let store = makeStore(state, released: .init([]))
		await store.send(.ui(.command(.pagePictureInPicture, .window(state.main.id))))
		await store.receive(\.ui.closePagePictureInPicture) {
			$0.pagePictureInPicture?.phase = .returning(focusesTab: true)
		}
		await store.finish()
	}

	@Test
	internal func onePageFloatsAtATime() async throws {
		var state = fixture()
		let first = state.workspace.tabs[0].id
		let second = state.workspace.tabs[1].id
		var window = MainFeature.State(
			organization: state.workspace,
			spaceID: state.workspace.spaces[0].id,
			id: UUID(90)
		)
		window.viewer.item.tab = state.workspace.tabs[1]
		state.windows.append(window)
		state.pagePictureInPicture = .init(tabID: first, windowID: state.main.id, phase: .open)
		let released = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, released: released)

		// The floating page goes back first, then the other one floats.
		await store.send(.ui(.openPagePictureInPicture(second))) {
			$0.pagePictureInPicture?.phase = .returning(focusesTab: false)
			$0.pagePictureInPicture?.next = second
		}
		await store.send(.event(.pagePictureInPictureClosed(first))) {
			$0.pagePictureInPicture = nil
		}
		await store.receive(\.ui.openPagePictureInPicture) {
			$0.pagePictureInPicture = .init(tabID: second, windowID: window.id)
		}
		await store.receive(\.event.pagePictureInPictureReleased) {
			$0.pagePictureInPicture?.phase = .open
		}
		await store.finish()
		expectNoDifference(released.value, [second])
	}

	/// A private window's tab lives in that window's own organization: Return to Tab selects it
	/// there, after the person moved to another tab.
	@Test
	internal func backToTabSelectsAPrivateWindowsTab() async throws {
		var state = fixture()
		let profileID = state.workspace.profiles[0].id
		let shown = BrowserCore.Tab(
			id: .init(rawValue: UUID(91)),
			profileID: profileID,
			restoration: .init(title: "Shown", url: URL(string: "https://shown.example")!)
		)
		let floating = BrowserCore.Tab(
			id: .init(rawValue: UUID(92)),
			profileID: profileID,
			restoration: .init(title: "Floating", url: URL(string: "https://floating.example")!)
		)
		var organization = state.workspace
		organization.tabs = [shown, floating]
		organization.spaces[0].unpinnedTabs = [shown.id, floating.id]
		organization.spaces[0].selectedTabID = shown.id
		var window = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			id: UUID(93)
		)
		window.viewer.item.tab = shown
		state.windows.append(window)
		state.pagePictureInPicture = .init(
			tabID: floating.id,
			windowID: window.id,
			phase: .returning(focusesTab: true)
		)
		let store = makeStore(state, released: .init([]))

		await store.send(.event(.pagePictureInPictureClosed(floating.id)))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		#expect(store.state.pagePictureInPicture == nil)
		expectNoDifference(store.state.focusedWindowID, window.id)
		expectNoDifference(store.state.windows[id: window.id]?.sidebar.selectedTab?.id, floating.id)
	}

	@Test
	internal func aClosedTabEndsIt() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		state.pagePictureInPicture = .init(tabID: tab, windowID: state.main.id, phase: .open)
		#expect(state.hasPagePictureInPictureTab(tab))
		#expect(!state.hasPagePictureInPictureTab(.init(rawValue: UUID(404))))

		state.pagePictureInPicture = .init(tabID: .init(rawValue: UUID(404)), windowID: state.main.id, phase: .open)
		let store = makeStore(state, released: .init([]))
		await store.send(.ui(.closePagePictureInPicture(focusesTab: false))) {
			$0.pagePictureInPicture = nil
		}
		await store.finish()
	}

	@Test
	internal func aFloatingPageNeverFillsItsWindowNorTakesACapture() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		#expect(state.pageFullScreenWindow(showing: tab) == state.main.id)
		#expect(state.captureSource(for: .window(state.main.id)) != nil)
		state.pagePictureInPicture = .init(tabID: tab, windowID: state.main.id, phase: .open)
		#expect(state.pageFullScreenWindow(showing: tab) == nil)
		#expect(state.captureSource(for: .window(state.main.id)) == nil)
	}

	/// A headless run shows no windows, so nothing floats.
	@Test
	internal func aHeadlessRunNeverFloatsAPage() async throws {
		var state = fixture()
		state.automation.isUnattended = true
		let released = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, released: released)
		await store.send(.ui(.openPagePictureInPicture(state.workspace.tabs[0].id)))
		await store.finish()
		#expect(store.state.pagePictureInPicture == nil)
		#expect(released.value.isEmpty)
	}

	@Test
	internal func aHiddenTabCantFloat() async throws {
		let state = fixture()
		let hidden = state.workspace.tabs[1].id
		let store = makeStore(state, released: .init([]))
		await store.send(.ui(.openPagePictureInPicture(hidden)))
		await store.finish()
		#expect(store.state.pagePictureInPicture == nil)
	}

	// MARK: - Present Tab in Picture in Picture (DEV-1105)

	@Test
	internal func aTabsMenuFloatsATabNoWindowShows() async throws {
		let state = fixture()
		let hidden = state.workspace.tabs[1]
		#expect(state.pagePictureInPictureSource(of: hidden.id) == nil)
		#expect(state.canPresentTabInPictureInPicture(hidden.id, in: state.main.id, engine: Self.engine))
		let opened = LockIsolated<[BrowserCore.Tab.ID]>([])
		let released = LockIsolated<[BrowserCore.Tab.ID]>([])
		let navigation = BrowserNavigation(url: URL(string: "https://hidden.example/page")!, canGoBack: true)
		let store = makeStore(state, released: released, opened: opened, navigation: navigation)

		await store.send(.ui(.presentTabInPictureInPicture(hidden.id, windowID: state.main.id))) {
			$0.pagePictureInPicture = .init(tabID: hidden.id, windowID: state.main.id)
		}
		await store.receive(\.event.pagePictureInPictureReleased) {
			$0.pagePictureInPicture?.phase = .open
		}

		// The header follows the page itself, since no window shows it.
		await store.receive(\.event.pagePictureInPictureNavigation) {
			$0.pagePictureInPicture?.navigation = navigation
		}

		// It loaded for the floating window; the window that shows another tab let go of nothing.
		expectNoDifference(opened.value, [hidden.id])
		#expect(released.value.isEmpty)
		// The tab keeps its place, and the window keeps showing its own tab.
		expectNoDifference(store.state.main.viewer.item.tab?.id, state.workspace.tabs[0].id)

		// A floating tab isn't offered again.
		#expect(!store.state.canPresentTabInPictureInPicture(hidden.id, in: state.main.id, engine: Self.engine))
		await store.send(.ui(.closePagePictureInPicture(focusesTab: false)))
		await store.send(.event(.pagePictureInPictureClosed(hidden.id))) {
			$0.pagePictureInPicture = nil
		}
		await store.finish()
	}

	@Test
	internal func aTabsMenuFloatsAShownTabFromItsWindow() async throws {
		let state = fixture()
		let shown = state.workspace.tabs[0].id
		let opened = LockIsolated<[BrowserCore.Tab.ID]>([])
		let released = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, released: released, opened: opened)

		await store.send(.ui(.presentTabInPictureInPicture(shown, windowID: state.main.id)))
		await store.receive(\.ui.openPagePictureInPicture) {
			$0.pagePictureInPicture = .init(tabID: shown, windowID: state.main.id)
		}
		await store.receive(\.event.pagePictureInPictureReleased) {
			$0.pagePictureInPicture?.phase = .open
		}

		// The window showing it let go of it; it was already loaded.
		expectNoDifference(released.value, [shown])
		#expect(opened.value.isEmpty)
		await store.send(.ui(.closePagePictureInPicture(focusesTab: false)))
		await store.send(.event(.pagePictureInPictureClosed(shown)))
		await store.finish()
	}

	@Test
	internal func aTabThatCantLoadDoesntFloat() async throws {
		let state = fixture()
		let hidden = state.workspace.tabs[1].id
		let store = makeStore(state, released: .init([]), opens: false)

		await store.send(.ui(.presentTabInPictureInPicture(hidden, windowID: state.main.id))) {
			$0.pagePictureInPicture = .init(tabID: hidden, windowID: state.main.id)
		}
		await store.receive(\.event.pagePictureInPictureFailed) {
			$0.pagePictureInPicture = nil
		}
		await store.finish()
	}

	/// DEV-1116: a tab showing the Downloading page has no page of its own, and the floating
	/// window draws only the page, so neither its menu, the command nor a menu sent anyway floats it.
	@Test
	internal func aTabShowingItsTransferDoesntFloat() async throws {
		let state = fixture()
		let shown = state.workspace.tabs[0].id
		let hidden = state.workspace.tabs[1].id
		let transfer = Self.transfer(state.workspace.tabs[0].profileID)
		let snapshot: @MainActor @Sendable (BrowserCore.Tab.ID) -> BrowserSessionSnapshot? = { _ in
			.init(navigation: transfer, revision: 1)
		}
		#expect(state.canPresentTabInPictureInPicture(hidden, in: state.main.id, engine: Self.engine))
		var downloading = Self.engine
		downloading.snapshot = snapshot
		#expect(!state.canPresentTabInPictureInPicture(shown, in: state.main.id, engine: downloading))
		#expect(!state.canPresentTabInPictureInPicture(hidden, in: state.main.id, engine: downloading))

		let opened = LockIsolated<[BrowserCore.Tab.ID]>([])
		let released = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, released: released, opened: opened, snapshot: snapshot)
		await store.send(.ui(.openPagePictureInPicture(shown)))
		await store.send(.ui(.presentTabInPictureInPicture(shown, windowID: state.main.id)))
		await store.send(.ui(.presentTabInPictureInPicture(hidden, windowID: state.main.id)))
		await store.send(.ui(.command(.pagePictureInPicture, .window(state.main.id))))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		#expect(store.state.pagePictureInPicture == nil)
		#expect(released.value.isEmpty)
		#expect(opened.value.isEmpty)
	}

	/// A floating page whose navigation becomes a transfer has nothing left to float: it goes
	/// back to its tab, which shows the transfer.
	@Test
	internal func aFloatingPageThatBecomesATransferGoesBack() async throws {
		var state = fixture()
		let hidden = state.workspace.tabs[1]
		state.pagePictureInPicture = .init(tabID: hidden.id, windowID: state.main.id, phase: .open)
		let transfer = Self.transfer(hidden.profileID)
		let store = makeStore(state, released: .init([]))

		await store.send(.event(.pagePictureInPictureNavigation(hidden.id, transfer))) {
			$0.pagePictureInPicture?.navigation = transfer
			$0.pagePictureInPicture?.phase = .returning(focusesTab: false)
		}
		await store.send(.event(.pagePictureInPictureClosed(hidden.id))) {
			$0.pagePictureInPicture = nil
		}
		await store.finish()

		// The window keeps showing its own tab.
		expectNoDifference(store.state.main.viewer.item.tab?.id, state.workspace.tabs[0].id)
	}

	private static func transfer(_ profileID: Profile.ID) -> BrowserNavigation {
		var navigation = BrowserNavigation(url: URL(string: "https://files.example/report.bin")!)
		navigation.download = .init(id: .init(profileID: profileID, guid: "report"), filename: "report.bin")
		navigation.hasNoPage = true
		return navigation
	}

	@Test
	internal func aTabsMenuOffersNothingForAChatTabOrAHeadlessRun() async throws {
		var state = fixture()
		let hidden = state.workspace.tabs[1].id
		state.automation.isUnattended = true
		#expect(!state.canPresentTabInPictureInPicture(hidden, in: state.main.id, engine: Self.engine))
		#expect(!state.canPresentTabInPictureInPicture(state.workspace.tabs[0].id, in: state.main.id, engine: Self.engine))

		state.automation.isUnattended = false
		state.workspace.tabs[id: hidden]?.restoration.url = ChatTabAddress(conversationID: nil).url
		state.main.sidebar.organization.tabs[id: hidden]?.restoration.url = ChatTabAddress(conversationID: nil).url
		#expect(state.workspace.tabs[id: hidden]?.isChat == true)
		#expect(!state.canPresentTabInPictureInPicture(hidden, in: state.main.id, engine: Self.engine))
		// Nor for a window that's gone.
		#expect(!state.canPresentTabInPictureInPicture(state.workspace.tabs[0].id, in: UUID(404), engine: Self.engine))
	}

	/// Closing its window returns it without showing the tab, and it ends once the floating window
	/// lets the page go (DEV-1104's release unloads the page then).
	@Test
	internal func closingItsWindowEndsIt() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		state.pagePictureInPicture = .init(tabID: tab, windowID: state.main.id, phase: .open)
		let store = makeStore(state, released: .init([]))

		await store.send(.ui(.closeWindow)) {
			$0.windowIsOpen = false
			$0.pagePictureInPicture?.phase = .returning(focusesTab: false)
		}
		await store.skipReceivedActions(strict: false)
		await store.send(.event(.pagePictureInPictureClosed(tab)))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		#expect(store.state.pagePictureInPicture == nil)
	}

	/// A page still opening when its window closes never floated: its tab keeps it.
	@Test
	internal func closingItsWindowWhileItOpensDropsIt() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		state.pagePictureInPicture = .init(tabID: tab, windowID: state.main.id, phase: .opening)
		let store = makeStore(state, released: .init([]))

		await store.send(.ui(.closeWindow)) {
			$0.windowIsOpen = false
			$0.pagePictureInPicture = nil
		}
		await store.skipReceivedActions(strict: false)
		await store.finish()
	}

	@Test
	internal func closingAnotherWindowEndsOnlyItsOwn() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[1]
		var window = MainFeature.State(
			organization: state.workspace,
			spaceID: state.workspace.spaces[0].id,
			id: UUID(90)
		)
		window.viewer.item.tab = tab
		state.windows.append(window)
		let other = MainFeature.State(
			organization: state.workspace,
			spaceID: state.workspace.spaces[0].id,
			id: UUID(91)
		)
		state.windows.append(other)
		state.pagePictureInPicture = .init(tabID: tab.id, windowID: window.id, phase: .open)
		let store = makeStore(state, released: .init([]))

		await store.send(.ui(.closeAdditionalWindow(other.id)))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.pagePictureInPicture?.tabID == tab.id)

		await store.send(.ui(.closeAdditionalWindow(window.id)))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.pagePictureInPicture?.phase == .returning(focusesTab: false))
		await store.send(.event(.pagePictureInPictureClosed(tab.id)))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		#expect(store.state.pagePictureInPicture == nil)
	}

	/// A close the person can still cancel, as a private window's while its pages decide, keeps it.
	@Test
	internal func aCloseStillPendingKeepsIt() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[1]
		var window = MainFeature.State(
			organization: state.workspace,
			spaceID: state.workspace.spaces[0].id,
			id: UUID(90)
		)
		window.viewer.item.tab = tab
		window.isClosing = true
		state.windows.append(window)
		state.pagePictureInPicture = .init(tabID: tab.id, windowID: window.id, phase: .open)

		// Nothing new floats from a closing window.
		#expect(!state.canPresentTabInPictureInPicture(state.workspace.tabs[0].id, in: window.id, engine: Self.engine))
		let store = makeStore(state, released: .init([]))

		await store.send(.event(.pagePictureInPictureNavigation(tab.id, .init())))
		await store.finish()
		#expect(store.state.pagePictureInPicture?.tabID == tab.id)
	}

	@Test
	internal func itsHeaderGoesBackAndCopiesThePagesAddress() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		let url = URL(string: "https://floating.example/article")!
		state.pagePictureInPicture = .init(
			tabID: tab,
			windowID: state.main.id,
			phase: .open,
			navigation: .init(url: url, canGoBack: false)
		)
		let commands = LockIsolated<[BrowserEngineClient.Command]>([])
		let copied = LockIsolated<[String]>([])
		let store = makeStore(state, released: .init([]), commands: commands, copied: copied)

		// Nowhere to go back to.
		await store.send(.ui(.pagePictureInPictureBack))
		await store.send(.event(.pagePictureInPictureNavigation(tab, .init(url: url, canGoBack: true)))) {
			$0.pagePictureInPicture?.navigation.canGoBack = true
		}
		await store.send(.ui(.pagePictureInPictureBack))
		await store.send(.ui(.copyPagePictureInPictureURL))
		await store.receive(\.delegate.copyURL, url)

		// Another tab's navigation leaves the header alone.
		await store.send(.event(.pagePictureInPictureNavigation(state.workspace.tabs[1].id, .init())))
		await store.finish()
		expectNoDifference(commands.value, [.back])
		expectNoDifference(copied.value, [url.absoluteString])
	}

	/// A background tab asked for from another window while a page floats floats from the window
	/// whose menu asked, once the first is back.
	@Test
	internal func aQueuedBackgroundTabFloatsFromTheWindowThatAskedForIt() async throws {
		var state = fixture()
		let first = state.workspace.tabs[0].id
		let hidden = state.workspace.tabs[1].id
		let window = MainFeature.State(
			organization: state.workspace,
			spaceID: state.workspace.spaces[0].id,
			id: UUID(90)
		)
		state.windows.append(window)
		state.pagePictureInPicture = .init(tabID: first, windowID: state.main.id, phase: .open)
		let store = makeStore(state, released: .init([]))

		await store.send(.ui(.presentTabInPictureInPicture(hidden, windowID: window.id))) {
			$0.pagePictureInPicture?.phase = .returning(focusesTab: false)
			$0.pagePictureInPicture?.next = hidden
			$0.pagePictureInPicture?.nextWindowID = window.id
		}
		await store.send(.event(.pagePictureInPictureClosed(first))) {
			$0.pagePictureInPicture = nil
		}
		await store.receive(\.ui.presentTabInPictureInPicture) {
			$0.pagePictureInPicture = .init(tabID: hidden, windowID: window.id)
		}
		await store.receive(\.event.pagePictureInPictureReleased) {
			$0.pagePictureInPicture?.phase = .open
		}
		await store.finish()
	}

	/// No window may show a floating page, so its visits are recorded from its own navigation.
	@Test
	internal func aFloatingPageRecordsItsVisits() async throws {
		var state = fixture()
		let hidden = state.workspace.tabs[1].id
		state.pagePictureInPicture = .init(tabID: hidden, windowID: state.main.id, phase: .open)
		let recorded = LockIsolated<[URL]>([])
		let url = URL(string: "https://floating.example/next")!
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init(
				record: { id, visit in
					let url = visit.url
					recorded.withValue { $0.append(url) }
					return .init(snapshot: .init(profileID: id, entries: [], revision: 1))
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.pagePictureInPictureNavigation(hidden, .init(url: url, title: "Next"))))
		await store.skipReceivedActions(strict: false)

		// The same navigation again is the same visit.
		await store.send(.event(.pagePictureInPictureNavigation(hidden, .init(url: url, title: "Next"))))

		// Nor does a tab that isn't floating record here.
		await store.send(.event(.pagePictureInPictureNavigation(state.workspace.tabs[0].id, .init(url: url))))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		expectNoDifference(recorded.value, [url])
	}

	/// A saved tab opened in Peek and floated from there is still Peek's page: history records
	/// none of its visits, as for any Peek.
	@Test
	internal func aFloatingPeeksVisitsAreNotRecorded() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[1]
		state.peeks.append(.init(id: UUID(81), source: .init(
			windowID: state.main.id,
			paneID: state.main.viewer.activePaneID,
			tabID: state.workspace.tabs[0].id,
			spaceID: state.main.sidebar.spaceID,
			profileID: tab.profileID,
			identity: "Fixture"
		), tab: tab, isTemporary: false))
		state.pagePictureInPicture = .init(tabID: tab.id, windowID: state.main.id, phase: .open)
		let recorded = LockIsolated<[URL]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init(
				record: { id, visit in
					let url = visit.url
					recorded.withValue { $0.append(url) }
					return .init(snapshot: .init(profileID: id, entries: [], revision: 1))
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let url = URL(string: "https://peek.example/next")!
		await store.send(.event(.pagePictureInPictureNavigation(tab.id, .init(url: url, title: "Next"))))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		expectNoDifference(recorded.value, [])
	}

	/// A floating Favorite's visits stay in its own profile's spaces (DEV-1154): the window's
	/// while it shows that profile, else the profile's first, never another profile's space.
	@Test
	internal func aFloatingFavoritesVisitsKeepASpaceOfItsProfile() async throws {
		let (organization, favorite) = Self.twoProfilesWithAFavorite()
		let work = organization.spaces[0].id
		let reading = organization.spaces[1].id
		let other = organization.spaces[2].id

		// The window shows another profile's space: the Favorite's profile's first space.
		let fromOther = try await recordedSpaces(organization, favorite: favorite, windowSpace: other)
		expectNoDifference(fromOther, [work])

		// The window shows a space of the Favorite's profile: that one.
		let fromReading = try await recordedSpaces(organization, favorite: favorite, windowSpace: reading)
		expectNoDifference(fromReading, [reading])

		// Links follow the same rule.
		var state = AppFeature.State(main: .init(organization: organization, spaceID: other))
		state.pagePictureInPicture = .init(tabID: favorite, windowID: state.main.id, phase: .open)
		expectNoDifference(state.floatingSpace(of: Self.personal, windowID: state.main.id), work)
	}

	/// The spaces a floating Favorite's visit is recorded with, floating from a window on `windowSpace`.
	private func recordedSpaces(
		_ organization: BrowserOrganization,
		favorite: BrowserCore.Tab.ID,
		windowSpace: Space.ID
	) async throws -> [Space.ID?] {
		var state = AppFeature.State(main: .init(organization: organization, spaceID: windowSpace))
		state.pagePictureInPicture = .init(tabID: favorite, windowID: state.main.id, phase: .open)
		let recorded = LockIsolated<[Space.ID?]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init(
				record: { id, visit in
					let spaceID = visit.spaceID
					recorded.withValue { $0.append(spaceID) }
					return .init(snapshot: .init(profileID: id, entries: [], revision: 1))
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let url = URL(string: "https://floating.example/favorite")!
		await store.send(.event(.pagePictureInPictureNavigation(favorite, .init(url: url, title: "Favorite"))))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		return recorded.value
	}

	private static let personal = Profile.ID(rawValue: UUID(20))

	/// Personal has the spaces Work and Reading and a Favorite; Other has a space of its own.
	private static func twoProfilesWithAFavorite() -> (BrowserOrganization, BrowserCore.Tab.ID) {
		let other = Profile.ID(rawValue: UUID(21))
		let favorite = BrowserCore.Tab(
			id: .init(rawValue: UUID(30)),
			profileID: personal,
			restoration: .init(title: "Favorite", url: URL(string: "https://favorite.example")!)
		)
		let organization = BrowserOrganization(
			profiles: [
				.init(id: personal, name: "Personal", favorites: [favorite.id]),
				.init(id: other, name: "Other"),
			],
			spaces: [
				.init(id: .init(rawValue: UUID(22)), profileID: personal, name: "Work"),
				.init(id: .init(rawValue: UUID(23)), profileID: personal, name: "Reading"),
				.init(id: .init(rawValue: UUID(24)), profileID: other, name: "Other"),
			],
			tabs: [favorite]
		)
		return (organization, favorite.id)
	}

	/// A floating page no pane shows opens its links from the window it floats from, next to it.
	@Test
	internal func aFloatingPagesLinksOpenFromItsWindow() async throws {
		var state = fixture()
		let hidden = state.workspace.tabs[1]
		#expect(state.nativeContentPlacement(tabID: hidden.id, profileID: hidden.profileID, isPrivate: false) == nil)

		state.pagePictureInPicture = .init(tabID: hidden.id, windowID: state.main.id, phase: .open)
		let placement = try #require(
			state.nativeContentPlacement(tabID: hidden.id, profileID: hidden.profileID, isPrivate: false)
		)
		expectNoDifference(placement.windowID, state.main.id)
		expectNoDifference(placement.paneID, state.main.viewer.activePaneID)
		expectNoDifference(placement.floatingTabID, hidden.id)

		// Its links go to its own space, whatever the window shows.
		let space: Space.ID? = switch state.workspace.location(of: hidden.id) {
		case let .pinned(spaceID, _), let .unpinned(spaceID): spaceID
		case .favorite, nil: nil
		}
		expectNoDifference(state.nativeContentsSpace(placement), space)

		// Not while it's still opening, nor for a private page.
		state.pagePictureInPicture?.phase = .opening
		#expect(state.nativeContentPlacement(tabID: hidden.id, profileID: hidden.profileID, isPrivate: false) == nil)
		state.pagePictureInPicture?.phase = .open
		#expect(state.nativeContentPlacement(tabID: hidden.id, profileID: hidden.profileID, isPrivate: true) == nil)
		// A page a pane shows keeps that pane.
		let shown = state.workspace.tabs[0]
		state.pagePictureInPicture = .init(tabID: shown.id, windowID: state.main.id, phase: .open)
		#expect(state.nativeContentPlacement(tabID: shown.id, profileID: shown.profileID, isPrivate: false)?.floatingTabID == nil)
	}

	@Test
	internal func itsHeaderGoesForward() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		state.pagePictureInPicture = .init(
			tabID: tab,
			windowID: state.main.id,
			phase: .open,
			navigation: .init(canGoBack: true, canGoForward: false)
		)
		let commands = LockIsolated<[BrowserEngineClient.Command]>([])
		let store = makeStore(state, released: .init([]), commands: commands)

		// Nowhere to go forward to.
		await store.send(.ui(.pagePictureInPictureForward))
		await store.send(.event(.pagePictureInPictureNavigation(tab, .init(canGoBack: true, canGoForward: true)))) {
			$0.pagePictureInPicture?.navigation.canGoForward = true
		}
		await store.send(.ui(.pagePictureInPictureForward))
		await store.finish()
		expectNoDifference(commands.value, [.forward])
	}

	/// Little Arx's profile picker on a space's tab: the tab keeps its page and goes back to its
	/// tab, and a new tab at the same address in the chosen profile's space floats instead.
	@Test
	internal func choosingAnotherProfileFloatsTheAddressThereAndKeepsTheTab() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0]
		let work = Profile.ID(rawValue: UUID(200))
		let workSpace = Space.ID(rawValue: UUID(201))
		state.workspace.profiles.append(.init(id: work, name: "Work"))
		state.workspace.spaces.append(.init(id: workSpace, profileID: work, name: "Office"))
		state.main.sidebar.organization = state.workspace
		let url = URL(string: "https://floating.example/now")!
		state.pagePictureInPicture = .init(
			tabID: tab.id,
			windowID: state.main.id,
			phase: .open,
			navigation: .init(url: url, title: "Now")
		)
		let profiles = state.pagePictureInPictureProfiles()
		expectNoDifference(profiles.current, tab.profileID)
		expectNoDifference(profiles.options.map(\.isEnabled), [true, true])
		let opened = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, released: .init([]), opened: opened)

		// The same profile changes nothing.
		await store.send(.ui(.pagePictureInPictureSelectProfile(tab.profileID)))
		await store.send(.ui(.pagePictureInPictureSelectProfile(work)))
		let newTab = try #require(store.state.workspace.spaces[id: workSpace]?.unpinnedTabs.first)
		expectNoDifference(store.state.workspace.tabs[id: newTab]?.profileID, work)
		expectNoDifference(store.state.workspace.tabs[id: newTab]?.restoration.url, url)

		// The original tab is still there; its page goes back first.
		#expect(store.state.workspace.tabs[id: tab.id] != nil)
		expectNoDifference(store.state.pagePictureInPicture?.phase, .returning(focusesTab: false))
		expectNoDifference(store.state.pagePictureInPicture?.next, newTab)

		await store.send(.event(.pagePictureInPictureClosed(tab.id)))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		expectNoDifference(store.state.pagePictureInPicture?.tabID, newTab)
		expectNoDifference(store.state.pagePictureInPicture?.phase, .open)
		expectNoDifference(opened.value, [newTab])
	}

	/// A private window's floating tab stays in its profile.
	@Test
	internal func aPrivateTabKeepsItsProfile() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0]
		state.workspace.tabs.remove(id: tab.id)
		state.pagePictureInPicture = .init(tabID: tab.id, windowID: state.main.id, phase: .open)
		state.main.sidebar.organization.tabs[id: tab.id] = tab
		let profiles = state.pagePictureInPictureProfiles()
		expectNoDifference(profiles.options.map(\.id), [tab.profileID])
	}

	// MARK: - Fixture

	/// An engine with no pages, as the menus' check reads it.
	private static let engine: BrowserEngineClient = .init(status: { .notIntegrated })

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		state.main.viewer.item.tab = organization.tabs[0]
		return state
	}

	private func makeStore(
		_ state: AppFeature.State,
		released: LockIsolated<[BrowserCore.Tab.ID]>,
		opened: LockIsolated<[BrowserCore.Tab.ID]> = .init([]),
		opens: Bool = true,
		navigation: BrowserNavigation? = nil,
		commands: LockIsolated<[BrowserEngineClient.Command]> = .init([]),
		copied: LockIsolated<[String]> = .init([]),
		snapshot: @escaping @MainActor @Sendable (BrowserCore.Tab.ID) -> BrowserSessionSnapshot? = { _ in nil }
	) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_000)
			$0.browserSurface = .init(
				attach: { _, _ in },
				detach: { _ in },
				release: { id in released.withValue { $0.append(id) } }
			)
			$0.browserEngine.open = { tab in
				guard opens else { throw CancellationError() }

				opened.withValue { $0.append(tab.id) }
			}
			$0.browserEngine.events = { _ in
				AsyncStream { continuation in
					if let navigation { continuation.yield(navigation) }
					continuation.finish()
				}
			}
			$0.browserEngine.command = { _, command in commands.withValue { $0.append(command) } }
			$0.browserEngine.snapshot = snapshot
			$0.linkSharing.copy = { text in
				copied.withValue { $0.append(text) }
				return true
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}
