import AppKit
import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import CommandBarFeature
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-1124: Page PiP's address edits as the main window's does. A click opens the command bar
/// over it with the address, what's chosen opens in the floating page, Esc closes it, and either
/// way the page has the keyboard again.
@Suite(.dependencies)
@MainActor
internal struct PagePictureInPictureAddressTests {
	private static let address: URL = .init(string: "https://floating.example/watch")!
	private static let typed: URL = .init(string: "https://typed.example/page")!

	@Test
	internal func returnOpensWhatsChosenInTheFloatingPage() async throws {
		let (state, tab) = floating()
		let commands = LockIsolated<[BrowserEngineClient.Command]>([])
		let focused = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, commands: commands, focused: focused)

		await store.send(.ui(.editPagePictureInPictureAddress))
		await store.receive(\.pagePictureInPictureCommandBar.present)
		let bar = try #require(store.state.pagePictureInPicture?.commandBar)
		#expect(bar.isPresented)
		#expect(bar.mode == .currentTab)
		expectNoDifference(bar.query, Self.address.absoluteString)
		expectNoDifference(store.state.pagePictureInPicture?.addressPresentation, bar.focusRequest)

		// The typed text's own link, as Return takes it.
		await store.send(.pagePictureInPictureCommandBar(.ui(.queryChanged(Self.typed.absoluteString))))
		await store.send(.pagePictureInPictureCommandBar(.ui(.selected("destination"))))
		await store.receive(\.pagePictureInPictureCommandBar.delegate.execute) {
			#expect($0.pagePictureInPicture?.commandBar.isPresented == false)
		}
		await store.receive(\.event.pagePictureInPictureTypedAddressOpened)
		await store.finish()

		#expect(store.state.pagePictureInPicture?.commandBar.isPresented == false)
		#expect(store.state.pagePictureInPicture?.addressPresentation == nil)
		expectNoDifference(commands.value, [.navigate(Self.typed)])
		expectNoDifference(focused.value, [tab])

		// Its visit counts as typed, as from a window's address (DEV-1015).
		let profile = try #require(store.state.workspace.tabs[id: tab]?.profileID)
		let waiting = store.state.history.typedAddresses[profile] ?? []
		expectNoDifference(waiting.map(\.tabID), [tab])
		expectNoDifference(waiting.map(\.site), ["typed.example"])
	}

	/// It searches with the floating page's profile's engine, as the main window does.
	@Test
	internal func itSearchesWithThePagesProfilesEngine() async throws {
		var (state, tab) = floating()
		let profile = try #require(state.workspace.tabs[id: tab]?.profileID)
		state.workspace.profiles[id: profile]?.searchEngine = .duckDuckGo
		let store = makeStore(state, commands: .init([]), focused: .init([]))

		await store.send(.ui(.editPagePictureInPictureAddress))
		await store.receive(\.pagePictureInPictureCommandBar.present)
		await store.finish()
		expectNoDifference(store.state.pagePictureInPicture?.commandBar.searchEngine, .duckDuckGo)
	}

	/// With its bar open the panel is the key window, whose commands target the application: ⌘K
	/// shows the highlighted result's actions in that bar, not the main window's.
	@Test
	internal func commandKShowsTheBarsActions() async throws {
		let (state, _) = floating()
		let store = makeStore(state, commands: .init([]), focused: .init([]))

		await store.send(.ui(.editPagePictureInPictureAddress))
		await store.receive(\.pagePictureInPictureCommandBar.present)
		await store.send(.ui(.command(.commandBar, .application)))
		await store.receive(\.pagePictureInPictureCommandBar.ui.actionsToggled)
		await store.finish()
		#expect(store.state.pagePictureInPicture?.commandBar.actionPanel != nil)
		#expect(!store.state.main.commandBar.isPresented)
	}

	@Test
	internal func escapeClosesItAndGivesThePageTheKeyboard() async throws {
		let (state, tab) = floating()
		let commands = LockIsolated<[BrowserEngineClient.Command]>([])
		let focused = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, commands: commands, focused: focused)

		await store.send(.ui(.editPagePictureInPictureAddress))
		await store.receive(\.pagePictureInPictureCommandBar.present)
		await store.send(.pagePictureInPictureCommandBar(.ui(.dismissed)))
		await store.receive(\.pagePictureInPictureCommandBar.delegate.dismissed)
		await store.finish()

		#expect(store.state.pagePictureInPicture?.commandBar.isPresented == false)
		#expect(store.state.pagePictureInPicture?.addressPresentation == nil)
		expectNoDifference(commands.value, [])
		expectNoDifference(focused.value, [tab])
	}

	/// A choice made once the page started back to its tab opens nothing: the floating window is
	/// letting go of it.
	@Test
	internal func aChoiceAfterThePageWentBackOpensNothing() async throws {
		let (state, _) = floating()
		let commands = LockIsolated<[BrowserEngineClient.Command]>([])
		let store = makeStore(state, commands: commands, focused: .init([]))

		await store.send(.ui(.editPagePictureInPictureAddress))
		await store.receive(\.pagePictureInPictureCommandBar.present)
		await store.send(.pagePictureInPictureCommandBar(.ui(.queryChanged(Self.typed.absoluteString))))
		await store.send(.ui(.closePagePictureInPicture(focusesTab: false)))
		let entry = try #require(store.state.pagePictureInPicture?.commandBar.entries.first { entry in
			if case .open = entry.intent { return true }
			return false
		})
		await store.send(.pagePictureInPictureCommandBar(.ui(.selected(entry.presentation.id))))
		await store.finish()

		expectNoDifference(commands.value, [])
	}

	/// The address edits only once the page floats.
	@Test
	internal func itEditsOnlyOnceThePageFloats() async throws {
		var (state, _) = floating()
		state.pagePictureInPicture?.phase = .opening
		let store = makeStore(state, commands: .init([]), focused: .init([]))

		await store.send(.ui(.editPagePictureInPictureAddress))
		await store.finish()
		#expect(store.state.pagePictureInPicture?.commandBar.isPresented == false)
		#expect(store.state.pagePictureInPicture?.addressPresentation == nil)
	}

	/// A second click while the bar is open doesn't present it again over itself.
	@Test
	internal func aSecondClickKeepsTheBarAsItIs() async throws {
		let (state, _) = floating()
		let store = makeStore(state, commands: .init([]), focused: .init([]))

		await store.send(.ui(.editPagePictureInPictureAddress))
		await store.receive(\.pagePictureInPictureCommandBar.present)
		let presented = try #require(store.state.pagePictureInPicture?.commandBar.focusRequest)
		await store.send(.ui(.editPagePictureInPictureAddress))
		await store.finish()
		expectNoDifference(store.state.pagePictureInPicture?.commandBar.focusRequest, presented)
		expectNoDifference(store.state.pagePictureInPicture?.addressPresentation, presented)
	}

	/// Little Arx turned into Page PiP (DEV-1112) edits its address the same way, with its own bar.
	@Test
	internal func littleArxAsPagePictureInPictureEditsItsAddress() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let space = organization.spaces[0]
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: space.profileID,
			restoration: .init(title: "Floating", url: Self.address)
		)
		var state = LittleArxFeature.State(id: UUID(81), spaceID: space.id, tab: tab)
		state.viewer.navigation.url = Self.address
		state.isPictureInPicture = true
		let store = TestStore(initialState: state) { LittleArxFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.openCommand(.currentTab)))
		await store.receive(\.commandBar.present)
		#expect(store.state.commandBar.isPresented)
		#expect(store.state.commandBar.mode == .currentTab)
		expectNoDifference(store.state.commandBar.query, Self.address.absoluteString)
		await store.send(.commandBar(.ui(.dismissed)))
		await store.finish()
		#expect(!store.state.commandBar.isPresented)
	}

	/// The main window with a tab whose page floats in Page PiP.
	private func floating() -> (AppFeature.State, BrowserCore.Tab.ID) {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		let tab = organization.tabs[0].id
		var navigation = BrowserNavigation()
		navigation.url = Self.address
		state.pagePictureInPicture = .init(tabID: tab, windowID: state.main.id, phase: .open, navigation: navigation)
		return (state, tab)
	}

	private func makeStore(
		_ state: AppFeature.State,
		commands: LockIsolated<[BrowserEngineClient.Command]>,
		focused: LockIsolated<[BrowserCore.Tab.ID]>
	) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_000)
			$0.browserSurface = .init(
				attach: { _, _ in },
				detach: { _ in },
				focus: { id in focused.withValue { $0.append(id) } }
			)
			$0.browserEngine.command = { _, command in commands.withValue { $0.append(command) } }
			$0.browserEngine.snapshot = { _ in nil }
			$0.browserHistory = .init()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}

/// Page PiP's window with its address idle and being edited, light and dark (DEV-1124), when
/// `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(.renderTurn, .dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct PagePictureInPictureAddressSnapshotTests {
	@Test(arguments: [false, true])
	internal func idleAndEditing(dark: Bool) throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		let tab = organization.tabs[0].id
		var navigation = BrowserNavigation()
		navigation.url = URL(string: "https://www.example.com/watch/live")!
		navigation.canGoBack = true
		state.pagePictureInPicture = .init(tabID: tab, windowID: state.main.id, phase: .open, navigation: navigation)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in nil }
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
		}
		let view = PagePictureInPictureContent(
			store: store,
			tabID: tab,
			windowID: state.main.id,
			surface: .init(attach: { _, _ in }, detach: { _ in })
		)
		let appearance = dark ? "dark" : "light"
		let size: CGSize = PagePictureInPicturePanel.defaultSize
		try write(view, size: size, name: "page-pip-address-idle-\(appearance).png", dark: dark)
		try write(view, size: size, name: "page-pip-address-editing-\(appearance).png", dark: dark) {
			store.send(.ui(.editPagePictureInPictureAddress))
		}
	}

	private func write(
		_ view: some View,
		size: CGSize,
		name: String,
		dark: Bool,
		afterAppearing: () -> Void = {}
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.isOpaque = false
		window.backgroundColor = .clear
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let host = NSHostingView(rootView: view)
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for step in 0..<8 {
			if step == 2 { afterAppearing() }
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: name))
		window.close()
	}
}
