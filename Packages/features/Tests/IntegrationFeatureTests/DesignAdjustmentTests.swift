import AppKit
import AppFeature
import AppUI
import BrowserCore
import CommandBarFeature
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct DesignAdjustmentTests {
	@Test
	internal func emptyQueryOffersOpenTabsThenFavoritesThenHistory() {
		let profile = Profile.ID(rawValue: UUID(1))
		let space = Space.ID(rawValue: UUID(2))
		let entry: (String, CommandBarFeature.Intent, CommandBarFeature.Destination?) -> CommandBarFeature.Entry = { id, intent, destination in
			.init(
				presentation: .init(id: id, title: id, actionTitle: "", symbol: "globe"),
				intent: intent,
				destination: destination
			)
		}
		let state = CommandBarFeature.State(mode: .newTab, candidates: [
			entry("history", .open(URL(string: "https://older.example")!), nil),
			entry("favorite", .selectTab(.init(rawValue: UUID(3))), .tab(profile, .favorite(profile))),
			entry("space", .selectSpace(space), .space(profile)),
			entry("command", .command(.settings), nil),
			entry("tab", .selectTab(.init(rawValue: UUID(4))), .tab(profile, .unpinned(space)))
		])

		expectNoDifference(state.entries.map(\.presentation.id), ["tab", "favorite", "history"])
	}

	@Test
	internal func commandEntriesCarryTheirOwnSymbolAndCurrentBinding() {
		let standard = CommandBarFeature.Entry.command(.settings, bindings: [])
		let rebound = CommandBarFeature.Entry.command(.settings, bindings: [
			.init(command: .settings, shortcut: .init(key: "j"))
		])
		let unbound = CommandBarFeature.Entry.command(.settings, bindings: [
			.init(command: .settings, shortcut: nil)
		])

		#expect(standard.presentation.symbol != "command")
		expectNoDifference(standard.presentation.shortcut, "⌘,")
		expectNoDifference(rebound.presentation.shortcut, "⌘J")
		expectNoDifference(unbound.presentation.shortcut, nil)
	}

	@Test(arguments: ["escape", "delete"])
	internal func newPanePresentsTheCommandBarAndEscapeClosesIt(_ key: String) async {
		let organization = IntegrationFeatureTests().fixture()
		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		initial.viewer.item.tab = organization.tabs[0]
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			// An incrementing generator would start at the initial pane's all-zero ID.
			$0.uuid = .constant(UUID(20))
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.splitTab(nil))).finish()
		await store.skipReceivedActions()
		let paneID = store.state.viewer.activePaneID
		#expect(store.state.viewer.isSplit)
		#expect(store.state.viewer.item.tab == nil)
		#expect(store.state.commandBar.isPresented)
		expectNoDifference(store.state.commandBar.mode, .newTab)
		expectNoDifference(store.state.commandBarEmptyPaneID, paneID)

		// DEV-750: ⌫ in the empty field closes it exactly as Esc does, empty pane included.
		let close: CommandBarFeature.Action.UI = key == "escape" ? .dismissed : .deletedWhenEmpty
		await store.send(.commandBar(.ui(close))).finish()
		await store.skipReceivedActions()
		#expect(!store.state.viewer.isSplit)
		#expect(!store.state.commandBar.isPresented)
		expectNoDifference(store.state.commandBarEmptyPaneID, nil)
		expectNoDifference(store.state.viewer.item.tab?.id, organization.tabs[0].id)
	}

	@Test
	internal func dismissingTheCommandBarLeavesAnOccupiedSplitAlone() async {
		let organization = IntegrationFeatureTests().fixture()
		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		initial.viewer.item.tab = organization.tabs[0]
		initial.viewer.panes.append(.init(id: UUID(20), item: .init(tab: organization.tabs[1])))
		let store = TestStore(initialState: initial) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.openCommand(.newTab))).finish()
		await store.skipReceivedActions()
		expectNoDifference(store.state.commandBarEmptyPaneID, nil)
		await store.send(.commandBar(.ui(.dismissed))).finish()
		await store.skipReceivedActions()
		#expect(store.state.viewer.isSplit)
	}

	@Test
	internal func splitProjectsBothMembersForTheSidebar() {
		let organization = IntegrationFeatureTests().fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.viewer.item.tab = organization.tabs[0]
		expectNoDifference(state.splitTabIDs, [])

		state.viewer.panes.append(.init(id: UUID(20)))
		expectNoDifference(state.splitTabIDs, [.tab(organization.tabs[0].id.rawValue)])

		state.viewer.panes[id: UUID(20)]?.item.tab = organization.tabs[1]
		expectNoDifference(state.splitTabIDs, [
			.tab(organization.tabs[0].id.rawValue),
			.tab(organization.tabs[1].id.rawValue)
		])
	}

	@Test
	internal func littleArxLauncherLeadsWithPagesAndNeverOffersItself() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let history = BrowsingHistoryEntry(
			id: UUID(30),
			url: URL(string: "https://history.example/path")!,
			title: "History page",
			lastVisited: .init(timeIntervalSince1970: 1)
		)
		let profile = organization.spaces[0].profileID
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		initial.main.browsingHistory[profile] = .init(profileID: profile, entries: [history], revision: 1)
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.openLittleArx(nil, nil)))
		let window = try #require(store.state.littleWindows.first)
		let first = try #require(window.launcherSuggestions.first)
		expectNoDifference(first.intent, .open(history.url))
		expectNoDifference(first.presentation.subtitle, "history.example/path")

		await store.send(.littleWindows(.element(id: window.id, action: .ui(.task))))
		await store.skipReceivedActions()
		let bar = try #require(store.state.littleWindows.first).commandBar
		#expect(bar.entries.allSatisfy { if case .open = $0.intent { true } else { false } })
		#expect(!bar.candidates.contains { $0.intent == .command(.littleArx) })
		#expect(bar.candidates.contains { $0.intent == .command(.settings) })
	}

	@Test
	internal func grainDefaultIsHalvedWithoutChangingSavedPreferences() throws {
		expectNoDifference(BrowserPreferences().grainIntensity, 0.18)
		let saved = Data(#"{"grainEnabled":true,"grainIntensity":0.35,"grainSize":1,"searchShortcuts":[]}"#.utf8)
		expectNoDifference(try JSONDecoder().decode(BrowserPreferences.self, from: saved).grainIntensity, 0.35)
	}

	@Test
	internal func libraryClosesWhenASpaceIsSelected() async {
		let organization = IntegrationFeatureTests().fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.isLibraryOpen = true
		let store = TestStore(initialState: state) {
			MainFeature()
		}
		store.exhaustivity = .off

		await store.send(.sidebar(.ui(.spaceSelected(organization.spaces[0].id)))) {
			$0.isLibraryOpen = false
		}
		await store.send(.ui(.libraryOpenChanged(true))) {
			$0.isLibraryOpen = true
		}
	}

	@Test
	internal func libraryOffersOnlyWhatThisWindowCanOpen() {
		let organization = IntegrationFeatureTests().fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		expectNoDifference(state.librarySections, [.history, .spaces, .archive])

		state.downloadsAvailable = true
		state.mediaAvailable = true
		expectNoDifference(state.librarySections, [.media, .downloads, .history, .spaces, .archive])

		var privateState = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id, isPrivate: true)
		privateState.downloadsAvailable = true
		privateState.mediaAvailable = true
		expectNoDifference(privateState.librarySections, [.downloads, .spaces])
		expectNoDifference(privateState.libraryPanel, .downloads)
	}

	@Test
	internal func libraryShowsMediaBesideTheRail() async {
		let organization = IntegrationFeatureTests().fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.downloadsAvailable = true
		state.mediaAvailable = true
		let store = TestStore(initialState: state) {
			MainFeature()
		}
		store.exhaustivity = .off

		await store.send(.ui(.librarySectionSelected(.media))) {
			$0.librarySelection = .media
		}
		expectNoDifference(store.state.libraryPanel, .media)

		await store.send(.ui(.librarySectionSelected(.archive))) {
			$0.librarySelection = .archive
			$0.archive.profileID = organization.spaces[0].profileID
		}
		#expect(!store.state.archive.isPresented)
	}

	@Test
	internal func openingTheLibraryAtMediaShowsAHiddenSidebar() async {
		let organization = IntegrationFeatureTests().fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.sidebar.sidebarIsVisible = false
		let unavailable = TestStore(initialState: state) {
			MainFeature()
		}

		// Media isn't offered until the engine reports it.
		await unavailable.send(.ui(.openLibrary(.media)))

		state.mediaAvailable = true
		let store = TestStore(initialState: state) {
			MainFeature()
		}
		await store.send(.ui(.openLibrary(.media))) {
			$0.librarySelection = .media
			$0.isLibraryOpen = true
			$0.sidebar.sidebarIsVisible = true
		}
		expectNoDifference(store.state.libraryPanel, .media)
	}

	private func track(
		spaceIndex: Int = 0,
		libraryProgress: CGFloat = 0,
		pageCount: Int = 3
	) -> SidebarTrack {
		.init(
			spaceIndex: spaceIndex,
			libraryProgress: libraryProgress,
			pageCount: pageCount,
			pageWidth: 300,
			libraryWidth: 400
		)
	}

	@Test
	internal func trackRevealsTheSpaceItMovesToward() {
		var forward = track(spaceIndex: 1)
		#expect(forward.revealedSpace(from: 1) == nil)
		_ = forward.begin(deltaX: -4, deltaY: 0)
		forward.move(by: -30, at: 1)
		#expect(forward.revealedSpace(from: 1) == 2)

		var back = track(spaceIndex: 1)
		_ = back.begin(deltaX: 4, deltaY: 0)
		back.move(by: 30, at: 1)
		#expect(back.revealedSpace(from: 1) == 0)

		var last = track(spaceIndex: 2)
		_ = last.begin(deltaX: -4, deltaY: 0)
		last.move(by: -30, at: 1)
		#expect(last.revealedSpace(from: 2) == nil)

		var library = track(spaceIndex: 0)
		_ = library.begin(deltaX: 4, deltaY: 0)
		library.move(by: 30, at: 1)
		#expect(library.revealedSpace(from: 0) == nil)
	}

	@Test
	internal func trackClaimsOnlySwipesWithSomewhereToGo() {
		var closed = track()
		let claimed1 = closed.begin(deltaX: 1, deltaY: 4)
		#expect(!claimed1)
		let claimed2 = closed.begin(deltaX: 4, deltaY: 1)
		#expect(claimed2)

		var open = track(libraryProgress: 1)
		let claimed3 = open.begin(deltaX: 4, deltaY: 1)
		#expect(!claimed3)
		let claimed4 = open.begin(deltaX: -4, deltaY: 1)
		#expect(claimed4)

		var lone = track(pageCount: 1)
		let claimed5 = lone.begin(deltaX: -4, deltaY: 1)
		#expect(!claimed5)
		let claimed6 = lone.begin(deltaX: 4, deltaY: 1)
		#expect(claimed6)
	}

	/// DEV-1310: one swipe goes one stop. A long dismissal of the Library shuts it, gives a little
	/// into the space after the one under it and lands on the one under it.
	@Test
	internal func longDismissStopsAtTheSpaceUnderTheLibrary() {
		var track = track(libraryProgress: 1)
		let claimed7 = track.begin(deltaX: -10, deltaY: 0)
		#expect(claimed7)
		// The track goes half as far as the fingers: 200 points shut a quarter of the Library.
		track.move(by: -200, at: 0)
		expectNoDifference(track.libraryProgress, 0.75)
		expectNoDifference(track.spacesPosition, 0)

		// The rest of the Library's width.
		track.move(by: -600, at: 1)
		expectNoDifference(track.libraryProgress, 0)
		expectNoDifference(track.spacesPosition, 0)

		// A page's worth more gives 0.13 of a page toward the next space, and no further stop.
		track.move(by: -600, at: 2)
		#expect(abs(track.spacesPosition - 0.1304) < 0.001)
		expectNoDifference(track.release(at: 3), .space(0))
	}

	/// DEV-1310: a long swipe back from a later space goes to the space before it, not on
	/// through the spaces to the Library.
	@Test
	internal func longSwipeFromALaterSpaceGoesBackOneSpace() {
		var track = track(spaceIndex: 2)
		let claimed8 = track.begin(deltaX: 10, deltaY: 0)
		#expect(claimed8)
		track.move(by: 600, at: 0)
		expectNoDifference(track.spacesPosition, 1)
		expectNoDifference(track.libraryProgress, 0)

		// Far past it, the track gives toward the first space and never reaches it.
		track.move(by: 1300, at: 1)
		#expect(track.spacesPosition < 1 && track.spacesPosition > 0.7)
		expectNoDifference(track.libraryProgress, 0)
		expectNoDifference(track.release(at: 3), .space(1))
	}

	@Test
	internal func trackReversesWithoutADeadZone() {
		var track = track(libraryProgress: 1)
		let claimed9 = track.begin(deltaX: -10, deltaY: 0)
		#expect(claimed9)
		track.move(by: 5000, at: 0)
		expectNoDifference(track.libraryProgress, 1)

		// Half as far as the fingers, from the first point they come back.
		track.move(by: -40, at: 1)
		expectNoDifference(track.libraryProgress, 0.95)
	}

	/// The Library opened from a later space sits before that space, and a swipe out of it stops
	/// there (DEV-1310), giving a little toward the next.
	@Test
	internal func libraryOpenedFromALaterSpaceLeadsBackToThatSpace() {
		var track = track(spaceIndex: 1, libraryProgress: 1)
		let claimed10 = track.begin(deltaX: -10, deltaY: 0)
		#expect(claimed10)
		expectNoDifference(track.spacesPosition, 1)
		track.move(by: -800, at: 0)
		expectNoDifference(track.spacesPosition, 1)
		expectNoDifference(track.libraryProgress, 0)
		track.move(by: -600, at: 1)
		#expect(abs(track.spacesPosition - 1.1304) < 0.001)
		expectNoDifference(track.release(at: 3), .space(1))
	}

	@Test
	internal func releaseSettlesByWhichShowsMoreOrTheWayTheFingersWent() {
		var slow = track()
		_ = slow.begin(deltaX: 1, deltaY: 0)
		slow.move(by: 100, at: 0)
		slow.move(by: 1, at: 1)
		expectNoDifference(slow.release(at: 1.01), .space(0))

		var past = track()
		_ = past.begin(deltaX: 1, deltaY: 0)
		past.move(by: 450, at: 0)
		past.move(by: 1, at: 1)
		expectNoDifference(past.release(at: 1.01), .library)

		var flick = track()
		_ = flick.begin(deltaX: 1, deltaY: 0)
		flick.move(by: 20, at: 0)
		flick.move(by: 40, at: 0.016)
		flick.move(by: 40, at: 0.032)
		expectNoDifference(flick.release(at: 0.04), .library)

		// Fingers that stopped before lifting carry no flick.
		var rested = track()
		_ = rested.begin(deltaX: 1, deltaY: 0)
		rested.move(by: 20, at: 0)
		rested.move(by: 40, at: 0.016)
		rested.move(by: 40, at: 0.032)
		expectNoDifference(rested.release(at: 0.5), .space(0))
	}

	@Test
	internal func releaseContinuesAtTheFingersSpeedWithoutOvershoot() {
		var track = track()
		_ = track.begin(deltaX: 1, deltaY: 0)
		var time: TimeInterval = 0
		for _ in 0..<30 {
			track.move(by: 8, at: time)
			time += 1.0 / 120
		}

		// The track goes half as far as the fingers, so half as fast.
		let fingerSpeed = CGFloat(8) * SidebarTrack.follow / 400 * 120
		track.release(at: time)

		// A tenth of a millisecond after lifting, before the spring has pulled on it, the track
		// still moves as fast as it did under the fingers.
		var early = track
		let lifted = early.position
		_ = early.advance(to: time + 0.0001)
		#expect(abs((lifted - early.position) / 0.0001 - fingerSpeed) < fingerSpeed * 0.1)

		var previous = track.position
		var isSettling = true
		var frames = 0
		while isSettling {
			time += 1.0 / 120
			frames += 1
			isSettling = track.advance(to: time)
			#expect(track.position <= previous)
			#expect(track.position >= -1)
			previous = track.position
		}
		expectNoDifference(track.position, -1)
		#expect(frames < 90)
	}

	@Test
	internal func aSwipeCatchesTheSpringWhereItIs() {
		var track = track()
		track.present(spaceIndex: 0, isLibraryOpen: true, at: 0)
		_ = track.advance(to: 0.05)
		let caught = track.position
		#expect(caught > -1 && caught < 0)
		let claimed11 = track.begin(deltaX: -4, deltaY: 0)
		#expect(claimed11)
		expectNoDifference(track.position, caught)
		#expect(!track.isSettling)
		track.move(by: -4, at: 0.06)
		#expect(abs(track.position - (caught + 0.005)) < 0.000_001)
	}

	@Test
	internal func presentingTheStopATrackIsHeadingForChangesNothing() {
		var track = track(libraryProgress: 1)
		_ = track.begin(deltaX: -1, deltaY: 0)
		track.move(by: -500, at: 0)
		track.move(by: -1, at: 1)
		expectNoDifference(track.release(at: 1.01), .space(0))
		let settling = track
		track.present(spaceIndex: 0, isLibraryOpen: false, at: 1.02)
		expectNoDifference(track, settling)
	}

	@Test
	internal func selectingAnEarlierSpaceSlidesPastNoLibrary() {
		var track = track(spaceIndex: 2)
		track.present(spaceIndex: 0, isLibraryOpen: false, at: 0)
		var time: TimeInterval = 0
		while track.isSettling {
			time += 1.0 / 120
			_ = track.advance(to: time)
			expectNoDifference(track.libraryProgress, 0)
		}
		expectNoDifference(track.spacesPosition, 0)
	}

	@Test
	internal func nestedScrollSpendsTheSwipeOnlyWhileTheLibraryIsOpen() {
		var open = track(libraryProgress: 1)
		open.nestedScroll = .init(canMoveBack: true, canMoveForward: true)
		#expect(open.nestedConsumes(deltaX: -4, deltaY: 0))
		#expect(open.nestedConsumes(deltaX: 4, deltaY: 0))
		#expect(!open.nestedConsumes(deltaX: 1, deltaY: 4))

		// At its far edge, the same swipe moves on to dismissing the Library.
		open.nestedScroll = .init(canMoveBack: true, canMoveForward: false)
		#expect(!open.nestedConsumes(deltaX: -4, deltaY: 0))

		var closed = track()
		closed.nestedScroll = .init(canMoveBack: true, canMoveForward: true)
		#expect(!closed.nestedConsumes(deltaX: -4, deltaY: 0))
	}

	@Test
	internal func mouseWheelStepsOneStopAtATime() {
		var track = track(spaceIndex: 1)
		#expect(track.wheel(by: -10, at: 0) == nil)
		expectNoDifference(track.wheel(by: -25, at: 0.1), .space(2))
		_ = track.advance(to: 10)

		// Still turning, too soon after the last step.
		expectNoDifference(track.spacesPosition, 2)
		#expect(track.wheel(by: 40, at: 0.2) == nil)
		#expect(track.wheel(by: 1, at: 0.4) == nil)
		expectNoDifference(track.wheel(by: 1, at: 0.6), .space(1))

		var paused = self.track()
		#expect(paused.wheel(by: -20, at: 0) == nil)
		#expect(paused.wheel(by: -20, at: 1) == nil)
	}

	private func pinnedSpace(profile: UUID?) -> SidebarSpace {
		.init(id: UUID(), name: "", profileID: profile, favorites: [], savedItems: [], unpinnedTabs: [], selectedID: nil, url: nil)
	}

	@Test
	internal func pinnedHeaderMovesOnlyWhenTheProfileChanges() {
		let work = UUID()
		let home = UUID()
		let groups = SidebarPinnedGroup.groups(of: [
			pinnedSpace(profile: work),
			pinnedSpace(profile: work),
			pinnedSpace(profile: home),
			pinnedSpace(profile: work),
		])
		expectNoDifference(groups.map(\.spaces), [0...1, 2...2, 3...3])

		// Within the profile's own spaces, it stays perfectly still.
		expectNoDifference(groups[0].offset(at: 0), 0)
		expectNoDifference(groups[0].offset(at: 0.5), 0)
		expectNoDifference(groups[0].offset(at: 1), 0)

		// Between profiles, both follow the swipe, and meet where the pages meet.
		expectNoDifference(groups[0].offset(at: 1.25), -0.25)
		expectNoDifference(groups[1].offset(at: 1.25), 0.75)
		expectNoDifference(groups[1].offset(at: 2), 0)
		expectNoDifference(groups[1].offset(at: 2.5), -0.5)
		expectNoDifference(groups[2].offset(at: 2.5), 0.5)
	}

	@Test
	internal func spacesWithoutAProfileShareNoHeader() {
		let groups = SidebarPinnedGroup.groups(of: [pinnedSpace(profile: nil), pinnedSpace(profile: nil)])
		expectNoDifference(groups.map(\.spaces), [0...0, 1...1])
	}

	@Test
	internal func emptyAddressBarOffersPageActions() {
		let actions: [BrowserCommand] = [.closeTab, .reload, .settings]
		var state = CommandBarFeature.State(
			mode: .currentTab,
			candidates: actions.map { .command($0, bindings: .init()) }
		)
		expectNoDifference(state.entries.map(\.intent), [.command(.reload), .command(.closeTab)])

		state.query = "https://capturecontext.dev"
		state.prefilledQuery = state.query
		#expect(state.pageActionEntries.isEmpty)
		#expect(state.isAddress)

		state.prefilledQuery = nil
		state.query = "settings"
		#expect(!state.isAddress)
		#expect(state.pageActionEntries.isEmpty)
		#expect(state.entries.contains { $0.intent == .command(.settings) })
	}

	@Test
	internal func profilesChooseWhereFreeTextSearches() throws {
		let organization = IntegrationFeatureTests().fixture()
		let updated = try organization.applying(.setSearchEngine(organization.profiles[0].id, .duckDuckGo), uuid: { UUID() })
		expectNoDifference(updated.profiles[0].searchEngine, .duckDuckGo)

		var state = MainFeature.State(organization: updated, spaceID: updated.spaces[0].id)
		state.commandBar.searchEngine = .duckDuckGo
		state.commandBar.query = "swift tips"
		let open = state.commandBar.entries.compactMap { entry -> URL? in
			if case let .open(url) = entry.intent { url } else { nil }
		}
		#expect(open.first?.host() == "duckduckgo.com")
		expectNoDifference(CommandBarFeature.State.destination("swift tips")?.host(), "www.google.com")
	}

	@Test
	internal func spaceAppearanceWinsOverItsProfiles() throws {
		var organization = IntegrationFeatureTests().fixture()
		let space = organization.spaces[0].id
		organization = try organization.applying(
			.setProfileAppearance(organization.spaces[0].profileID, .init(theme: .dark, grainEnabled: false)),
			uuid: { UUID() }
		)
		expectNoDifference(organization.appearance(ofSpace: space), .init(theme: .dark, grainEnabled: false))

		// A space only replaces what it chooses, and inherits the rest.
		organization = try organization.applying(.setSpaceAppearance(space, .init(theme: .light)), uuid: { UUID() })
		expectNoDifference(organization.appearance(ofSpace: space), .init(theme: .light, grainEnabled: false))
	}

	@Test
	internal func templateSyntaxFindsPlaceholders() {
		expectNoDifference(
			TemplateSyntax.tokens(in: "https://kk{host}/{path").map { [$0.name, $0.isClosed ? "closed" : "open"] },
			[["host", "closed"], ["path", "open"]]
		)
		expectNoDifference(TemplateSyntax.tokens(in: "{host}").first?.range, NSRange(location: 0, length: 6))
		expectNoDifference(TemplateSyntax.tokens(in: "plain"), [])

		// A second opening brace starts afresh instead of swallowing the first.
		expectNoDifference(TemplateSyntax.tokens(in: "{a{b}").map(\.name), ["a", "b"])
	}

	@Test
	internal func templateCompletionFollowsTheCaret() throws {
		let placeholders: [TemplatePlaceholder] = [.host, .path, .query]
		expectNoDifference(TemplateSyntax.completion(in: "a{pa", caret: 4), .init(start: 1, prefix: "pa"))
		expectNoDifference(TemplateSyntax.completion(in: "a{", caret: 2), .init(start: 1, prefix: ""))
		expectNoDifference(TemplateSyntax.completion(in: "a{path}", caret: 7), nil)
		expectNoDifference(TemplateSyntax.completion(in: "a/b", caret: 3), nil)

		let typing = try #require(TemplateSyntax.completion(in: "{host}/{", caret: 8))
		expectNoDifference(TemplateSyntax.options(for: typing, from: placeholders, in: "{host}/{").map(\.name), ["path", "query"])
		let filtered = try #require(TemplateSyntax.completion(in: "{qu", caret: 3))
		expectNoDifference(TemplateSyntax.options(for: filtered, from: placeholders, in: "{qu").map(\.name), ["query"])

		let accepted = TemplateSyntax.accepting(.path, for: .init(start: 1, prefix: "p"), in: "a{p}b", caret: 3)
		expectNoDifference(accepted.text, "a{path}b")
		expectNoDifference(accepted.caret, 7)
	}

	@Test
	internal func everyCatalogSymbolExistsOnThisSystem() {
		let missing = SpaceIconCatalog.symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
		expectNoDifference(missing, [])
		expectNoDifference(Set(SpaceIconCatalog.symbols).count, SpaceIconCatalog.symbols.count)
		#expect(SpaceIconCatalog.emoji.count > 500)
	}

	@Test
	internal func iconSearchFindsByNameAndSynonym() {
		#expect(SpaceIconCatalog.symbols(matching: "").count == SpaceIconCatalog.symbols.count)
		#expect(SpaceIconCatalog.symbols(matching: "home").contains("house.fill"))
		#expect(SpaceIconCatalog.symbols(matching: "plane").contains("airplane"))
		#expect(SpaceIconCatalog.symbols(matching: "zzz").isEmpty)
		#expect(SpaceIconCatalog.emoji(matching: "grinning face").contains("😀"))
	}

	@Test
	internal func spaceIconReadsTheSameStringsTheClosedSetSaved() throws {
		let decoded = try JSONDecoder().decode(SpaceIcon.self, from: Data(#""square.stack""#.utf8))
		expectNoDifference(decoded, .stack)
		#expect(!decoded.isEmoji)

		let emoji = SpaceIcon(emoji: "🚀")
		#expect(emoji.isEmoji)
		expectNoDifference(emoji.symbolName, SpaceIcon.stack.rawValue)
		let encoded = try JSONEncoder().encode(emoji)
		expectNoDifference(try JSONDecoder().decode(SpaceIcon.self, from: encoded), emoji)
	}

	@Test
	internal func dragEdgesAreTheSidebarsOuterStrips() {
		expectNoDifference(SidebarDragEdge(x: 0, width: 300), .leading)
		expectNoDifference(SidebarDragEdge(x: 16, width: 300), .leading)
		expectNoDifference(SidebarDragEdge(x: 150, width: 300), nil)
		expectNoDifference(SidebarDragEdge(x: 284, width: 300), .trailing)
	}

	@Test
	internal func siteIconKeepsAcrossPagesOfOneSiteOnly() {
		let profile = UUID()
		let page = SidebarItem.SiteIcon(profileID: profile, pageURL: URL(string: "https://capturecontext.dev/a")!)
		#expect(page.isSameSite(as: .init(profileID: profile, pageURL: URL(string: "https://capturecontext.dev/b")!)))
		#expect(!page.isSameSite(as: .init(profileID: profile, pageURL: URL(string: "https://github.com/a")!)))
		#expect(!page.isSameSite(as: .init(profileID: UUID(), pageURL: page.pageURL)))
	}

	@Test
	internal func manageSpacesOpensTheLibrarysSpacesSection() async {
		let organization = IntegrationFeatureTests().fixture()
		let store = TestStore(initialState: MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)) {
			MainFeature()
		}
		await store.send(.ui(.manageSpaces)) {
			$0.librarySelection = .spaces
			$0.isLibraryOpen = true
		}
	}

	@Test
	internal func shiftingSpacesKeepsTheSelectedOneInPlace() {
		var track = track(spaceIndex: 2)
		track.shift(by: -1)
		expectNoDifference(track.spacesPosition, 1)
		expectNoDifference(track.libraryProgress, 0)
	}

	@Test
	internal func commandBarOffersOrganizationCommands() {
		let organization = IntegrationFeatureTests().fixture()
		let state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let offered = state.commandCandidates.compactMap { entry -> BrowserCommand? in
			guard case let .command(command) = entry.intent else { return nil }
			return command
		}
		for command in [BrowserCommand.newSpace, .nextSpace, .previousSpace, .toggleLibrary] {
			#expect(offered.contains(command))
			#expect(state.organizationAction(for: command) != nil)
		}
	}

	@Test
	internal func spaceCommandsWrapAroundAndNewSpaceSelectsIt() async {
		let organization = IntegrationFeatureTests().fixture()
		let last = organization.spaces[organization.spaces.count - 1]
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.isLibraryOpen = true
		guard case let .sidebar(.ui(.spaceSelected(previous))) = state.organizationAction(for: .previousSpace) else {
			Issue.record("Expected a space selection")
			return
		}
		expectNoDifference(previous, last.id)

		let store = TestStore(initialState: state) {
			MainFeature()
		} withDependencies: {
			$0.uuid = .constant(UUID(90))
		}
		store.exhaustivity = .off

		await store.send(.sidebar(.ui(.newSpace)))
		#expect(store.state.sidebar.spaceID.rawValue == UUID(90))
		#expect(store.state.sidebar.organization.spaces.count == organization.spaces.count + 1)
		#expect(!store.state.isLibraryOpen)
	}

	@Test
	internal func libraryGroupsEntriesByRelativeAge() {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = .gmt
		let now = Date(timeIntervalSince1970: 1_800_000_000)
		let ages = [3, 8, 9, 15, 70]
		let dates = ages.map { now.addingTimeInterval(-Double($0) * 86_400) }
		let groups = SidebarLibraryGroup<Date>.grouping(
			dates,
			date: { $0 },
			now: now,
			calendar: calendar,
			locale: .init(identifier: "en_US")
		)
		expectNoDifference(groups.map(\.title), ["3 days ago", "1 week ago", "2 weeks ago", "2 months ago"])
		expectNoDifference(groups.map(\.items.count), [1, 2, 1, 1])
	}
}
