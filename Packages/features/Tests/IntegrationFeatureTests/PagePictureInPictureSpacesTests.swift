import AppKit
import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import SidebarFeature
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-1184: Page PiP's header picks the floating tab's space. The space picker and ⌘1–9 move
/// the tab to a space through its window, so the sidebar shows the move. A space of another
/// profile asks first, and once the page reopens there, its new tab floats instead.
@Suite(.dependencies)
@MainActor
internal struct PagePictureInPictureSpacesTests {
	private static let address: URL = .init(string: "https://capturecontext.dev")!

	// MARK: - The picker

	/// The picker shows each space as its Switch to Space shortcut, in the switcher's order, the
	/// tab's own selected, and names the profile of a space of another profile.
	@Test
	internal func thePickerShowsTheSpacesAsTheirShortcuts() async throws {
		let fixture = Fixture()
		let spaces = try #require(fixture.state.pagePictureInPictureSpaces())
		expectNoDifference(spaces.options.map(\.shortcut), ["⌃1", "⌃2", "⌃3"])
		expectNoDifference(spaces.options.map(\.name), ["Work", "Personal", "Side"])
		expectNoDifference(spaces.options.map(\.otherProfileName), [nil, nil, "Other"])
		expectNoDifference(spaces.current, fixture.work)
	}

	/// A rebound Switch to Space shortcut shows as it's bound; past the ninth, a space shows its
	/// number.
	@Test
	internal func thePickerFollowsTheSpaceShortcuts() async throws {
		let fixture = Fixture()
		let options = PagePictureInPictureSpacePicker.Option.options(
			spaces: fixture.state.workspace.spaces,
			profiles: fixture.state.workspace.profiles,
			profileID: fixture.profile,
			shortcuts: [.init(command: .space2, shortcut: .init(key: "2", modifiers: [.control, .option]))]
		)
		expectNoDifference(options.map(\.shortcut), ["⌃1", "⌃⌥2", "⌃3"])

		let many = (0..<10).map { Space(id: .init(rawValue: UUID(300 + $0)), profileID: fixture.profile, name: "\($0)") }
		let numbered = PagePictureInPictureSpacePicker.Option.options(
			spaces: many,
			profiles: fixture.state.workspace.profiles,
			profileID: fixture.profile,
			shortcuts: []
		)
		expectNoDifference(numbered.last?.shortcut, "10")
	}

	/// Little Arx's page, a Peek's and a private window's have no space to move between: they keep
	/// the profile picker.
	@Test
	internal func aPageWithoutASpaceKeepsTheProfilePicker() async throws {
		var fixture = Fixture()
		let tab = fixture.tab
		fixture.state.workspace.tabs.remove(id: tab)
		fixture.state.main.sidebar.organization.tabs.remove(id: tab)
		#expect(fixture.state.pagePictureInPictureSpaces() == nil)
		#expect(fixture.state.pagePictureInPictureSpaceMove(to: fixture.personal) == nil)
	}

	// MARK: - The same profile

	/// Choosing a space of the tab's own profile moves the tab there through its window: the
	/// window's sidebar shows it in the new space, and its page keeps floating.
	@Test
	internal func aSpaceOfTheSameProfileTakesTheTabAndItKeepsFloating() async throws {
		let fixture = Fixture()
		let store = fixture.makeStore()

		await store.send(.ui(.pagePictureInPictureMoveToSpace(fixture.personal)))
		await store.receive(\.main.transferConfirmedTabs)
		await store.receive(\.main.performTabMove)
		await store.skipReceivedActions(strict: false)
		await store.finish()

		fixture.expectMoved(in: store, to: fixture.personal)
		expectNoDifference(store.state.pagePictureInPicture?.tabID, fixture.tab)
		expectNoDifference(store.state.pagePictureInPicture?.phase, .open)
		#expect(store.state.main.pendingTabMove == nil)
		// The picker follows.
		expectNoDifference(store.state.pagePictureInPictureSpaceID(), fixture.personal)

		// Undo Organization Change takes the move back, as a drag's.
		#expect(!store.state.main.sidebar.undo.isEmpty)
	}

	/// ⌘2 while Page PiP is key, which is when commands target the application, moves the tab to
	/// the second space.
	@Test
	internal func commandNumberMovesTheTabToThatSpace() async throws {
		let fixture = Fixture()
		let store = fixture.makeStore()

		await store.send(.ui(.command(.tab2, .application)))
		await store.receive(\.ui.pagePictureInPictureMoveToSpace)
		await store.receive(\.main.transferConfirmedTabs)
		await store.skipReceivedActions(strict: false)
		await store.finish()

		fixture.expectMoved(in: store, to: fixture.personal)
		expectNoDifference(store.state.pagePictureInPicture?.phase, .open)
	}

	/// ⌘9 is the ninth space, which three spaces don't have, and ⌘1 is the tab's own space:
	/// neither moves anything.
	@Test(arguments: [BrowserCommand.lastTab, .tab1])
	internal func commandNumberWithoutAnotherSpaceDoesNothing(_ command: BrowserCommand) async throws {
		let fixture = Fixture()
		let store = fixture.makeStore()

		await store.send(.ui(.command(command, .application)))
		await store.skipReceivedActions(strict: false)
		await store.finish()

		fixture.expectMoved(in: store, to: fixture.work)
	}

	/// While Page PiP's address is being edited, or no page floats, ⌘1–9 aren't Page PiP's; nor
	/// are they in a browser window, where they select tabs.
	@Test
	internal func commandNumberIsPagePictureInPicturesOnlyWhileItsKey() async throws {
		var fixture = Fixture()
		#expect(fixture.state.pagePictureInPictureSpaceShortcut(for: .tab2, target: .window(fixture.state.main.id)) == nil)
		#expect(fixture.state.pagePictureInPictureSpaceShortcut(for: .copyURL, target: .application) == nil)
		fixture.state.pagePictureInPicture?.commandBar.isPresented = true
		#expect(fixture.state.pagePictureInPictureSpaceShortcut(for: .tab2, target: .application) == nil)
		fixture.state.pagePictureInPicture = nil
		#expect(fixture.state.pagePictureInPictureSpaceShortcut(for: .tab2, target: .application) == nil)
	}

	// MARK: - Another profile

	/// A space of another profile asks first, saying where the tab goes and that it reloads in
	/// the other profile without its sign-ins. Nothing moves until the answer.
	@Test
	internal func aSpaceOfAnotherProfileAsksFirst() async throws {
		let fixture = Fixture()
		let store = fixture.makeStore()

		await store.send(.ui(.command(.tab3, .application)))
		await store.receive(\.ui.pagePictureInPictureMoveToSpace)
		await store.finish()

		expectNoDifference(store.state.pagePictureInPicture?.spaceMove, fixture.side)
		let question = try #require(store.state.pagePictureInPictureProfileMoveConfirmation())
		expectNoDifference(question, .init(subject: .tab, spaceName: "Side", profileName: "Other"))
		expectNoDifference(question.title, "Move this tab to “Side”?")
		#expect(question.detail.contains("reloads in the Other profile"))
		#expect(question.detail.contains("sign-ins don’t carry over"))
		fixture.expectMoved(in: store, to: fixture.work)

		// While it asks, ⌘1–9 are the question's.
		#expect(store.state.pagePictureInPictureSpaceShortcut(for: .tab2, target: .application) == nil)
	}

	/// Escape, or Cancel, closes the question: nothing moves, and the page has the keyboard again.
	@Test
	internal func escapeCancelsTheMove() async throws {
		let fixture = Fixture()
		let store = fixture.makeStore()

		await store.send(.ui(.pagePictureInPictureMoveToSpace(fixture.side)))
		await store.send(.ui(.cancelPagePictureInPictureSpaceMove))
		await store.finish()

		#expect(store.state.pagePictureInPicture?.spaceMove == nil)
		#expect(store.state.pagePictureInPictureProfileMoveConfirmation() == nil)
		fixture.expectMoved(in: store, to: fixture.work)
		expectNoDifference(fixture.focused.value, [fixture.tab])
		expectNoDifference(fixture.opened.value, [])
	}

	/// A question whose space is deleted meanwhile ends, so the picker and ⌘1–9 work again.
	@Test
	internal func aQuestionWhoseSpaceWentEnds() async throws {
		var fixture = Fixture()
		let side = fixture.side

		// Asked about Side, which was deleted since, as Settings or another Mac can.
		fixture.state.pagePictureInPicture?.spaceMove = side
		fixture.state.workspace.spaces.remove(id: side)
		fixture.state.main.sidebar.organization = fixture.state.workspace
		#expect(fixture.state.pagePictureInPictureProfileMoveConfirmation() == nil)
		let store = fixture.makeStore()

		await store.send(.ui(.pagePictureInPictureBack))
		await store.finish()

		#expect(store.state.pagePictureInPicture?.spaceMove == nil)
		#expect(store.state.pagePictureInPictureSpaceShortcut(for: .tab2, target: .application) != nil)
	}

	/// A floating Favorite shows a space of its own profile, even while its window shows another
	/// profile's space.
	@Test
	internal func aFloatingFavoriteKeepsToItsProfile() async throws {
		var fixture = Fixture()
		let (tab, work, profile, side) = (fixture.tab, fixture.work, fixture.profile, fixture.side)
		fixture.state.workspace.spaces[id: work]?.unpinnedTabs.removeAll { $0 == tab }
		fixture.state.workspace.profiles[id: profile]?.favorites = [tab]
		fixture.state.main.sidebar.organization = fixture.state.workspace
		fixture.state.main.sidebar.selectSpace(side)
		expectNoDifference(fixture.state.pagePictureInPictureSpaceID(), fixture.work)
	}

	/// Move reopens the page in the other profile's space, as the window moves any tab there, and
	/// once the old tab is gone, its new tab floats in its place.
	@Test
	internal func movingReopensThePageThereAndItsNewTabFloats() async throws {
		let fixture = Fixture()
		let store = fixture.makeStore()

		await store.send(.ui(.pagePictureInPictureMoveToSpace(fixture.side)))
		await store.send(.ui(.confirmPagePictureInPictureSpaceMove))
		await store.receive(\.main.transferConfirmedTabs)
		await store.receive(\.main.event.movedAcrossProfiles)
		await store.receive(\.ui.presentTabInPictureInPicture)
		await store.skipReceivedActions(strict: false)
		await store.finish()

		let organization = store.state.main.sidebar.organization
		#expect(organization.tabs[id: fixture.tab] == nil)
		let replacement = try #require(organization.spaces[id: fixture.side]?.unpinnedTabs.first)
		expectNoDifference(organization.tabs[id: replacement]?.profileID, fixture.other)
		expectNoDifference(organization.tabs[id: replacement]?.restoration.url, Self.address)
		expectNoDifference(store.state.workspace.tabs[id: replacement]?.profileID, fixture.other)

		// The page opened in the other profile, and the new tab floats.
		#expect(fixture.opened.value.contains(replacement))
		expectNoDifference(store.state.pagePictureInPicture?.tabID, replacement)
		expectNoDifference(store.state.pagePictureInPicture?.windowID, store.state.main.id)
	}

	/// Return to Tab while the move to another profile is under way wins: once the move is done,
	/// nothing floats.
	@Test
	internal func returnToTabDuringTheMoveWins() async throws {
		var fixture = Fixture()
		let (tab, side) = (fixture.tab, fixture.side)
		let request = UUID(94)

		// Move was chosen, then Return to Tab, before the window finished the move.
		fixture.state.pagePictureInPicture?.profileMove = request
		fixture.state.pagePictureInPicture?.phase = .returning(focusesTab: true)
		let store = fixture.makeStore()

		await store.send(.main(.transferConfirmedTabs(request, [.tab(tab.rawValue)], nil, side)))
		await store.receive(\.main.event.movedAcrossProfiles)
		await store.skipReceivedActions(strict: false)
		await store.finish()

		let organization = store.state.main.sidebar.organization
		#expect(organization.tabs[id: tab] == nil)
		#expect(organization.spaces[id: side]?.unpinnedTabs.isEmpty == false)
		// Nothing floats again: the page went back, as asked.
		#expect(store.state.pagePictureInPicture == nil)
	}

	/// A floating page no pane shows navigated after it floated: its tab still names the old
	/// address, and the move records the new one first, so the window's check that the page is
	/// where its tab says passes, and the page reopens at the new address.
	@Test
	internal func aPageThatNavigatedWhileFloatingMovesAtItsNewAddress() async throws {
		var fixture = Fixture()
		let navigated = URL(string: "https://capturecontext.dev/later")!
		fixture.state.pagePictureInPicture?.navigation.url = navigated
		fixture.state.pagePictureInPicture?.navigation.title = "Later"
		let store = fixture.makeStore(pageURL: navigated)

		await store.send(.ui(.pagePictureInPictureMoveToSpace(fixture.side)))
		await store.send(.ui(.confirmPagePictureInPictureSpaceMove))
		await store.receive(\.main.event.movedAcrossProfiles)
		await store.skipReceivedActions(strict: false)
		await store.finish()

		let organization = store.state.main.sidebar.organization
		let replacement = try #require(organization.spaces[id: fixture.side]?.unpinnedTabs.first)
		expectNoDifference(organization.tabs[id: replacement]?.restoration, .init(title: "Later", url: navigated))
		expectNoDifference(store.state.pagePictureInPicture?.tabID, replacement)
	}

	/// Little Arx's question before Open in ends when its space is deleted, as Page PiP's does.
	@Test
	internal func littleArxsQuestionWhoseSpaceWentEnds() async throws {
		var fixture = Fixture()
		let side = fixture.side
		let little = UUID(92)
		var window = LittleArxFeature.State(
			id: little,
			spaceID: fixture.work,
			tab: .init(id: .init(rawValue: UUID(93)), profileID: fixture.profile, restoration: .init(title: "Little", url: Self.address))
		)
		window.isPictureInPicture = true
		window.pendingDestination = side
		fixture.state.littleWindows.append(window)
		fixture.state.workspace.spaces.remove(id: side)
		fixture.state.main.sidebar.organization = fixture.state.workspace
		let store = fixture.makeStore()

		await store.send(.ui(.pagePictureInPictureBack))
		await store.receive(\.littleWindows)
		await store.finish()
		#expect(store.state.littleWindows[id: little]?.pendingDestination == nil)
	}

	/// A page that refuses to close keeps its tab where it is, and it keeps floating.
	@Test
	internal func aPageThatWontCloseStaysAndKeepsFloating() async throws {
		let fixture = Fixture()
		let store = fixture.makeStore(permitsClosing: false)

		await store.send(.ui(.pagePictureInPictureMoveToSpace(fixture.side)))
		await store.send(.ui(.confirmPagePictureInPictureSpaceMove))
		await store.receive(\.main.event.moveFailed)
		await store.skipReceivedActions(strict: false)
		await store.finish()

		fixture.expectMoved(in: store, to: fixture.work)
		expectNoDifference(store.state.pagePictureInPicture?.tabID, fixture.tab)
		expectNoDifference(store.state.pagePictureInPicture?.phase, .open)
		#expect(store.state.pagePictureInPicture?.profileMove == nil)
		#expect(store.state.pagePictureInPicture?.replacement == nil)
	}

	// MARK: - Little Arx as Page PiP

	/// Little Arx as Page PiP (DEV-1112): ⌘2 opens its page in the second space, as "Open in"
	/// does, and a space of another profile asks first.
	@Test
	internal func littleArxAsPagePictureInPictureOpensInTheSpace() async throws {
		var fixture = Fixture()
		fixture.state.pagePictureInPicture = nil
		let little = UUID(90)
		var window = LittleArxFeature.State(
			id: little,
			spaceID: fixture.work,
			tab: .init(
				id: .init(rawValue: UUID(91)),
				profileID: fixture.profile,
				restoration: .init(title: "Little", url: Self.address)
			)
		)
		window.isPictureInPicture = true
		fixture.state.littleWindows.append(window)

		let action = fixture.state.pagePictureInPictureSpaceShortcut(for: .tab2, target: .window(little))
		guard case let .littleWindows(.element(id, .ui(.promote(space, profile)))) = action else {
			Issue.record("⌘2 didn't open the page in the second space: \(String(describing: action))")
			return
		}
		expectNoDifference(id, little)
		expectNoDifference(space, fixture.personal)
		expectNoDifference(profile, fixture.profile)
		let store = fixture.makeStore()
		await store.send(.ui(.command(.tab3, .window(little))))
		await store.receive(\.littleWindows)
		await store.skipReceivedActions(strict: false)
		await store.finish()
		expectNoDifference(store.state.littleWindows[id: little]?.pendingDestination, fixture.side)

		await store.send(.littleWindows(.element(id: little, action: .ui(.cancelPromotion))))
		#expect(store.state.littleWindows[id: little]?.pendingDestination == nil)

		// Not as Page PiP, ⌘2 is Little Arx's own.
		var plain = fixture.state
		plain.littleWindows[id: little]?.isPictureInPicture = false
		#expect(plain.pagePictureInPictureSpaceShortcut(for: .tab2, target: .window(little)) == nil)
	}

	// MARK: - Fixture

	/// The main window with Work and Personal in the Default profile and Side in Other, the first
	/// tab of Work floating in Page PiP.
	private struct Fixture {
		var state: AppFeature.State
		let profile: Profile.ID
		let work: Space.ID
		let personal: Space.ID
		let tab: BrowserCore.Tab.ID
		var other: Profile.ID { .init(rawValue: UUID(200)) }
		var side: Space.ID { .init(rawValue: UUID(201)) }
		let opened: LockIsolated<[BrowserCore.Tab.ID]> = .init([])
		let focused: LockIsolated<[BrowserCore.Tab.ID]> = .init([])

		@MainActor
		init() {
			var organization = IntegrationFeatureTests().fixture()
			let other = Profile.ID(rawValue: UUID(200))
			organization.profiles.append(.init(id: other, name: "Other"))
			organization.spaces.append(.init(id: .init(rawValue: UUID(201)), profileID: other, name: "Side"))
			profile = organization.profiles[0].id
			work = organization.spaces[0].id
			personal = organization.spaces[1].id
			tab = organization.tabs[0].id
			state = AppFeature.State(main: .init(organization: organization, spaceID: work))
			state.main.viewer.item.tab = organization.tabs[0]
			var navigation = BrowserNavigation()
			navigation.url = PagePictureInPictureSpacesTests.address
			state.pagePictureInPicture = .init(tabID: tab, windowID: state.main.id, phase: .open, navigation: navigation)
		}

		@MainActor
		/// `pageURL` is where the floating page is now, as the engine reports it.
		func makeStore(
			permitsClosing: Bool = true,
			pageURL: URL? = nil
		) -> TestStoreOf<AppFeature> {
			let organization = state.workspace
			let floating = tab
			let store = TestStore(initialState: state) { AppFeature() } withDependencies: { [opened, focused] in
				$0.uuid = .incrementing
				$0.date.now = Date(timeIntervalSince1970: 1_000)
				$0.browserSurface = .init(
					attach: { _, _ in },
					detach: { _ in },
					focus: { id in focused.withValue { $0.append(id) } }
				)
				$0.browserEngine.snapshot = { id in
					organization.tabs[id: id].map { tab in
						.init(navigation: .init(url: id == floating ? pageURL ?? tab.restoration.url : tab.restoration.url), revision: 1)
					}
				}
				$0.browserEngine.prepareProfile = { _ in }
				$0.browserEngine.open = { tab in opened.withValue { $0.append(tab.id) } }
				$0.browserEngine.close = { _ in }
				$0.browserEngine.permitsClosing = { _ in permitsClosing }
				$0.browserEngine.events = { _ in AsyncStream { $0.finish() } }
				$0.browserHistory = .init()
			}
			store.exhaustivity = .off(showSkippedAssertions: false)
			return store
		}

		/// The floating tab is in `space`, in the window's sidebar and the workspace.
		@MainActor
		func expectMoved(
			in store: TestStoreOf<AppFeature>,
			to space: Space.ID,
			sourceLocation: SourceLocation = #_sourceLocation
		) {
			let organization = store.state.main.sidebar.organization
			#expect(organization.location(of: tab) == .unpinned(space), sourceLocation: sourceLocation)
			#expect(store.state.workspace.location(of: tab) == .unpinned(space), sourceLocation: sourceLocation)
		}
	}
}

/// Page PiP's window with the space picker, and with its question before a move to another
/// profile laid over the page (DEV-1184), light and dark, when `ARX_DESIGN_SNAPSHOTS` names a
/// directory.
@MainActor
@Suite(.renderTurn, .dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct PagePictureInPictureSpacesSnapshotTests {
	@Test(arguments: [false, true])
	internal func pickerAndQuestion(dark: Bool) throws {
		var organization = IntegrationFeatureTests().fixture()
		let other = Profile.ID(rawValue: UUID(200))
		let side = Space.ID(rawValue: UUID(201))
		organization.profiles.append(.init(id: other, name: "Work"))
		organization.spaces.append(.init(id: side, profileID: other, name: "Office"))
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
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
		try write(view, size: PagePictureInPicturePanel.defaultSize, name: "page-pip-spaces-\(appearance).png", dark: dark)
		try write(view, size: PagePictureInPicturePanel.minimumSize, name: "page-pip-spaces-question-narrowest-\(appearance).png", dark: dark) {
			store.send(.ui(.pagePictureInPictureMoveToSpace(side)))
		}
		try write(view, size: PagePictureInPicturePanel.defaultSize, name: "page-pip-spaces-question-\(appearance).png", dark: dark)
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
