import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-1243, DEV-1325: a tab a link opens goes where its opener says. From a Favorite or a pinned
/// tab, which have no place among the space's open tabs, it goes first among them; from an open
/// tab, directly below it, every time. Foreground and background alike, and whatever Settings ›
/// General › New tabs open says, which places the New Tab button's tabs.
@Suite(.dependencies)
@MainActor
internal struct OpenerTabPlacementTests {
	private enum Opener: CaseIterable {
		case favorite
		case pinned
		case regular
	}

	/// A Favorite's page-opened tab goes where Settings send its links (DEV-1312), Peek by default;
	/// New Tab keeps the tab whose place these tests check.
	private let document: WorkspaceDocument = .unsaved(.init(crossSiteLinkFromFavorites: .newTab))
	private let profile: Profile.ID = .init(rawValue: UUID(0))
	private let opener: BrowserCore.Tab.ID = .init(rawValue: UUID(3))
	private let first: BrowserCore.Tab.ID = .init(rawValue: UUID(4))
	private let second: BrowserCore.Tab.ID = .init(rawValue: UUID(5))
	private let child: BrowserCore.Tab.ID = .init(rawValue: UUID(90))
	private let nextChild: BrowserCore.Tab.ID = .init(rawValue: UUID(91))

	@Test(arguments: [BrowserNewContents.Disposition.foregroundTab, .backgroundTab])
	internal func aTabFromAFavoriteGoesToTheTop(disposition: BrowserNewContents.Disposition) async throws {
		let store = store(.favorite)

		await store.send(.event(.browserNewContents(offer(disposition), shiftHeld: false)))
		await store.skipReceivedActions()

		expectNoDifference(store.state.workspace.spaces[0].unpinnedTabs, [child, first, second])
	}

	@Test(arguments: [BrowserNewContents.Disposition.foregroundTab, .backgroundTab])
	internal func aTabFromAPinnedTabGoesToTheTop(disposition: BrowserNewContents.Disposition) async throws {
		let store = store(.pinned)

		await store.send(.event(.browserNewContents(offer(disposition), shiftHeld: false)))
		await store.skipReceivedActions()

		expectNoDifference(store.state.workspace.spaces[0].unpinnedTabs, [child, first, second])
	}

	@Test(arguments: [BrowserNewContents.Disposition.foregroundTab, .backgroundTab])
	internal func aTabFromAnOpenTabGoesRightBelowIt(disposition: BrowserNewContents.Disposition) async throws {
		let store = store(.regular)

		await store.send(.event(.browserNewContents(offer(disposition), shiftHeld: false)))
		await store.skipReceivedActions()

		expectNoDifference(store.state.workspace.spaces[0].unpinnedTabs, [first, opener, child, second])
	}

	/// Each of several tabs one tab opens goes where the first did, so the newest is nearest its
	/// opener, or first (Max's rules, DEV-1325).
	@Test(arguments: Opener.allCases)
	private func eachTabOpenedInARowGoesWhereTheFirstDid(from kind: Opener) async throws {
		let store = store(kind)

		await store.send(.event(.browserNewContents(offer(.backgroundTab), shiftHeld: false)))
		await store.send(.event(.browserNewContents(offer(.backgroundTab, id: nextChild), shiftHeld: false)))
		await store.skipReceivedActions()

		let expected: [BrowserCore.Tab.ID] = switch kind {
		case .favorite, .pinned: [nextChild, child, first, second]
		case .regular: [first, opener, nextChild, child, second]
		}
		expectNoDifference(store.state.workspace.spaces[0].unpinnedTabs, expected)
	}

	/// Settings › General › New tabs open doesn't move a tab a link opens.
	@Test(arguments: NewTabPlacement.allCases)
	internal func theNewTabSettingLeavesLinkTabsAlone(placement: NewTabPlacement) async throws {
		var state = state(.regular)
		state.settings.$general.withLock {
			$0.newTabPlacement = placement
			$0.openedTabPlacement = placement
		}
		let store = store(state)

		await store.send(.event(.browserNewContents(offer(.foregroundTab), shiftHeld: false)))
		await store.skipReceivedActions()

		expectNoDifference(store.state.workspace.spaces[0].unpinnedTabs, [first, opener, child, second])
	}

	@Test(arguments: Opener.allCases)
	private func openInNewTabFromTheLinkMenuFollowsTheOpener(_ kind: Opener) async throws {
		let store = store(kind) { $0.uuid = .constant(UUID(80)) }
		let id = BrowserCore.Tab.ID(rawValue: UUID(80))

		await store.send(.openLinkInBackgroundTab(URL(string: "https://x.com/linked")!, opener: opener, windowID: store.state.main.id))
		await store.skipReceivedActions()
		await store.finish()

		let expected: [BrowserCore.Tab.ID] = switch kind {
		case .favorite, .pinned: [id, first, second]
		case .regular: [first, opener, id, second]
		}
		expectNoDifference(store.state.workspace.spaces[0].unpinnedTabs, expected)
	}

	/// A link behind the page, then Open in New Tab from the same tab: both go by the same rule,
	/// so the second sits between the opener and the first, or first.
	@Test(arguments: Opener.allCases)
	private func backgroundAndForegroundTabsFollowOneRule(from kind: Opener) async throws {
		let store = store(kind) { $0.uuid = .constant(UUID(80)) }
		let id = BrowserCore.Tab.ID(rawValue: UUID(80))

		await store.send(.event(.browserNewContents(offer(.backgroundTab), shiftHeld: false)))
		await store.send(.main(.ui(.openInNewTab(URL(string: "https://x.com/linked")!))))
		await store.skipReceivedActions()

		let expected: [BrowserCore.Tab.ID] = switch kind {
		case .favorite, .pinned: [id, child, first, second]
		case .regular: [first, opener, id, child, second]
		}
		expectNoDifference(store.state.workspace.spaces[0].unpinnedTabs, expected)
	}

	// MARK: - Fixture

	/// A space whose open tabs are `first` and `second`, with `opener` a Favorite, a pinned tab
	/// or an open tab between them, selected and shown.
	private func state(_ kind: Opener) -> AppFeature.State {
		let space = Space.ID(rawValue: UUID(1))
		let url = URL(string: "https://capturecontext.dev")!
		let tabs: [BrowserCore.Tab] = [opener, first, second].map {
			.init(
				id: $0,
				profileID: profile,
				// A Favorite and a pinned tab keep where they were saved.
				savedDestination: $0 == opener && kind != .regular ? .init(title: "Saved", url: url) : nil,
				restoration: .init(title: "Example", url: url)
			)
		}
		let organization = BrowserOrganization(
			profiles: [.init(
				id: profile,
				name: "Default",
				favorites: kind == .favorite ? [opener] : []
			)],
			spaces: [.init(
				id: space,
				profileID: profile,
				name: "Work",
				savedItems: kind == .pinned ? [.tab(opener)] : [],
				unpinnedTabs: kind == .regular ? [first, opener, second] : [first, second],
				selectedTabID: opener
			)],
			tabs: tabs
		)
		var state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: space))
		}
		state.main.viewer.item = .init(tab: tabs[0], generation: 4)
		return state
	}

	private func offer(
		_ disposition: BrowserNewContents.Disposition,
		id: BrowserCore.Tab.ID? = nil
	) -> BrowserNewContents {
		.init(
			sourceTabID: opener,
			sourceSessionRevision: 3,
			sourceDocumentRevision: 7,
			tab: .init(
				id: id ?? child,
				profileID: profile,
				restoration: .init(title: "Linked", url: URL(string: "https://child.example/")!)
			),
			disposition: disposition
		)
	}

	private func store(
		_ kind: Opener,
		dependencies: (inout DependencyValues) -> Void = { _ in }
	) -> TestStoreOf<AppFeature> {
		store(state(kind), dependencies: dependencies)
	}

	private func store(
		_ state: AppFeature.State,
		dependencies: (inout DependencyValues) -> Void = { _ in }
	) -> TestStoreOf<AppFeature> {
		let opener = opener
		let children: Set<BrowserCore.Tab.ID> = [child, nextChild]
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { id in
				if id == opener { return .init(navigation: .init(), revision: 3, documentRevision: 7) }
				return children.contains(id) ? .init(navigation: .init(), revision: 1) : nil
			}
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			dependencies(&$0)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}
