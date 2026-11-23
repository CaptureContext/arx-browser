@testable import AppFeature
import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserExtensionsClient
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// The site menu in Little Arx and Page PiP (DEV-1257): the main window's menu, opened over the
/// floating window's page, with the items that window leaves out taking no action.
@MainActor
@Suite(.dependencies, .serialized)
internal struct FloatingSiteMenuTests {
	@Test
	internal func aMainWindowsMenuShowsEveryItem() {
		let organization = IntegrationFeatureTests().fixture()
		let state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		expectNoDifference(state.siteMenu.host, .mainWindow)
	}

	@Test
	internal func littleArxOpensTheMenuOverItsOwnPage() async throws {
		let (state, little) = fixture()
		let store = makeStore(state)
		let id = FloatingSiteMenu.ID.littleArx(little.id)

		await store.send(.ui(.floatingSiteMenu(id, .opened)))
		await settle(store)

		let siteMenu = try #require(store.state.floatingSiteMenus[id: id]?.siteMenu)
		expectNoDifference(siteMenu.host, .littleArx)
		expectNoDifference(siteMenu.context?.tabID, little.tab.id)
		expectNoDifference(siteMenu.menu?.hostWindow, .littleArx)

		// The main window's own menu stays as it was.
		#expect(!store.state.main.siteMenu.isOpen)
	}

	@Test
	internal func littleArxFloatingAsPagePictureInPictureHasPagePictureInPicturesMenu() async throws {
		var (state, little) = fixture()
		state.littleWindows[id: little.id]?.isPictureInPicture = true
		let store = makeStore(state)
		let id = FloatingSiteMenu.ID.littleArx(little.id)

		await store.send(.ui(.floatingSiteMenu(id, .opened)))
		await settle(store)

		expectNoDifference(store.state.floatingSiteMenus[id: id]?.siteMenu.host, .pagePictureInPicture)
	}

	@Test
	internal func pagePictureInPictureOpensTheMenuOverTheFloatingPage() async throws {
		var (state, _) = fixture()
		let tab = state.workspace.tabs[0]
		state.pagePictureInPicture = .init(
			tabID: tab.id,
			windowID: state.main.id,
			phase: .open,
			navigation: .init(url: URL(string: "https://capturecontext.dev/page")!)
		)
		let store = makeStore(state)

		await store.send(.ui(.floatingSiteMenu(.pagePictureInPicture, .opened)))
		await settle(store)

		let siteMenu = try #require(store.state.floatingSiteMenus[id: .pagePictureInPicture]?.siteMenu)
		expectNoDifference(siteMenu.host, .pagePictureInPicture)
		expectNoDifference(siteMenu.context?.tabID, tab.id)
		expectNoDifference(siteMenu.context?.url, URL(string: "https://capturecontext.dev/page")!)
		#expect(siteMenu.context?.canCapture == false && siteMenu.context?.canRead == nil)
	}

	@Test
	internal func aClosedWindowOpensNoMenu() async {
		let (state, _) = fixture()
		let store = makeStore(state)

		await store.send(.ui(.floatingSiteMenu(.littleArx(UUID(99)), .opened)))
		await store.send(.ui(.floatingSiteMenu(.pagePictureInPicture, .opened)))
		await settle(store)

		#expect(store.state.floatingSiteMenus.isEmpty)
	}

	@Test
	internal func littleArxsShareAndCaptureLeaveForItsWindow() async {
		var (state, little) = fixture()
		state.captureAvailable = true
		let store = makeStore(state)
		let id = FloatingSiteMenu.ID.littleArx(little.id)
		await store.send(.ui(.floatingSiteMenu(id, .opened)))
		await settle(store)

		await store.send(.ui(.floatingSiteMenu(id, .share)))
		await store.receive(\.ui.shareLinks)
		await settle(store)
		expectNoDifference(sharedWindowIDs, [little.id])

		await store.send(.ui(.floatingSiteMenu(id, .captureViewport)))
		await store.receive(\.ui.command)
		await settle(store)
	}

	/// Add Extension in Little Arx's menu opens the Chrome Web Store in a new Little Arx of the
	/// page's profile, which takes focus, rather than a tab out of sight (DEV-1317).
	@Test
	internal func littleArxsAddExtensionOpensTheStoreInANewLittleArxOfItsProfile() async throws {
		let (state, little) = fixture()
		let store = makeStore(state)
		await store.send(.event(.routingReady))
		await settle(store)
		let id = FloatingSiteMenu.ID.littleArx(little.id)
		await store.send(.ui(.floatingSiteMenu(id, .opened)))
		await settle(store)

		await store.send(.ui(.floatingSiteMenu(id, .addExtension)))
		await store.receive(\.openWebstore, little.tab.profileID)
		await settle(store)

		let opened = try #require(store.state.littleWindows.last)
		#expect(opened.id != little.id)
		expectNoDifference(store.state.littleWindows.count, 2)
		expectNoDifference(opened.tab.restoration.url, BrowserWebstoreInstallRequest.storeURL)
		expectNoDifference(opened.tab.profileID, little.tab.profileID)
		expectNoDifference(store.state.focusedWindowID, opened.id)
		expectNoDifference(store.state.workspace.tabs.count, state.workspace.tabs.count)
	}

	@Test
	internal func pagePictureInPictureSharesFromItsFloatingWindow() async {
		var (state, _) = fixture()
		let tab = state.workspace.tabs[0]
		state.pagePictureInPicture = .init(tabID: tab.id, windowID: state.main.id, phase: .open)
		let store = makeStore(state)
		await store.send(.ui(.floatingSiteMenu(.pagePictureInPicture, .opened)))
		await settle(store)

		await store.send(.ui(.floatingSiteMenu(.pagePictureInPicture, .share)))
		await store.receive(\.ui.shareLinks)
		await settle(store)

		expectNoDifference(sharedWindowIDs, [LinkSharingClient.pagePictureInPictureWindowID])

		// What the share did shows on the floating window.
		expectNoDifference(store.state.linkActionFeedback?.windowID, LinkSharingClient.pagePictureInPictureWindowID)
	}

	/// Page PiP returning its page takes the popover away without closing it: the menu closes
	/// anyway, so it stops reading the site's settings (Codex review).
	@Test
	internal func aMenuClosesWithItsWindow() async throws {
		var (state, little) = fixture()
		let tab = state.workspace.tabs[0]
		state.pagePictureInPicture = .init(tabID: tab.id, windowID: state.main.id, phase: .open)
		let store = makeStore(state)
		await store.send(.ui(.floatingSiteMenu(.pagePictureInPicture, .opened)))
		await store.send(.ui(.floatingSiteMenu(.littleArx(little.id), .opened)))
		await settle(store)
		#expect(store.state.floatingSiteMenus[id: .pagePictureInPicture]?.siteMenu.isOpen == true)

		await store.send(.ui(.closePagePictureInPicture(focusesTab: false)))
		await settle(store)

		#expect(store.state.floatingSiteMenus[id: .pagePictureInPicture]?.siteMenu.isOpen == false)
		// Another window's menu stays open.
		#expect(store.state.floatingSiteMenus[id: .littleArx(little.id)]?.siteMenu.isOpen == true)
	}

	/// The reducer, not only the panel, keeps out what a window leaves out: an exhaustive store,
	/// so any action or change the item caused would fail the test.
	@Test(arguments: [SiteMenu.Host.littleArx, .pagePictureInPicture])
	internal func anItemTheWindowLeavesOutTakesNoAction(_ host: SiteMenu.Host) async {
		let actions: [SiteMenuAction] = [
			.captureViewport, .captureRegion, .pagePictureInPicture, .readingMode, .addExtension,
			.hideElement, .setDarkPage(false), .setWebKit(true), .translate(true), .setNeverTranslate(true),
		]
		for action in actions {
			guard let item = SiteMenu.Item(action), !host.shows(item) else { continue }

			var state = SiteMenuFeature.State(host: host)
			state.context = .init(
				url: URL(string: "https://capturecontext.dev")!,
				tabID: .init(rawValue: UUID(5)),
				profileID: .init(rawValue: UUID(6)),
				canCapture: true,
				canRead: true,
				darkPage: true
			)
			let store = TestStore(initialState: state) { SiteMenuFeature() }

			await store.send(.ui(.menu(action)))
			await store.finish()
		}
	}

	/// What a main window takes, the floating windows' menus send on (DEV-633).
	@Test
	internal func aMainWindowsMenuTakesThoseItems() async {
		var state = SiteMenuFeature.State(host: .mainWindow)
		state.context = .init(
			url: URL(string: "https://capturecontext.dev")!,
			tabID: .init(rawValue: UUID(5)),
			profileID: .init(rawValue: UUID(6)),
			canCapture: true
		)
		let store = TestStore(initialState: state) { SiteMenuFeature() }

		await store.send(.ui(.menu(.captureRegion)))
		await store.receive(\.delegate.command)
		await store.send(.ui(.menu(.addExtension)))
		await store.receive(\.delegate.openWebstore, .init(rawValue: UUID(6)))
	}

	// MARK: - Support

	private var sharedWindowIDs: [UUID] { shares.value }
	private let shares = LockIsolated<[UUID]>([])

	private func fixture() -> (AppFeature.State, LittleArxFeature.State) {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		let tab = organization.tabs[0]
		var little = LittleArxFeature.State(id: UUID(32), spaceID: organization.spaces[0].id, tab: tab)
		little.viewer = .init(tab: tab)
		state.littleWindows.append(little)
		return (state, little)
	}

	private func makeStore(_ state: AppFeature.State) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: { [shares] in
			$0.uuid = .incrementing
			$0.continuousClock = ImmediateClock()
			$0.browserEngine = BrowserEngineClient(status: { .ready })
			// A Little Arx the store opens in prepares its profile and opens its page (DEV-1317).
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserExtensions = .init(isAvailable: false)
			$0.linkSharing.share = { _, windowID in
				shares.withValue { $0.append(windowID ?? UUID()) }
				return .cancelled
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}

	private func settle(_ store: TestStoreOf<AppFeature>) async {
		await store.finish()
		await store.skipReceivedActions(strict: false)
	}
}
