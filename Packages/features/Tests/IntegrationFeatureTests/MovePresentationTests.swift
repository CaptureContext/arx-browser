import AppFeature
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import Testing
import ViewerFeature
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func folderMoveUndoPresentsFreshIdentityInItsStoredSourceSplit() async throws {
		let organization = presentationMoveFixture(crossProfile: true)
		let source = organization.spaces[0].id
		let destination = organization.spaces[1].id
		var main = MainFeature.State(organization: organization, spaceID: source)
		main.viewer.item.tab = organization.tabs[0]
		main.viewer.panes.append(.init(id: UUID(42), item: .init(tab: organization.tabs[2])))
		main.viewer.preservesPresentation = true
		main.viewer.orientation = .vertical
		main.viewer.fractions = [0.65, 0.35]
		let originalLayout = try #require(main.viewer.currentPresentation)
		let store = presentationMoveStore(main)
		await store.send(.main(.transferTabs([.folder(organization.folders[0].id.rawValue)], nil, destination))).finish()
		await store.send(.main(.ui(.confirmProfileMove))).finish()
		let moved = try #require(store.main.sidebar.selectedTab?.id)
		expectNoDifference(store.main.viewer.item.tab?.id, moved)
		#expect(moved != organization.tabs[0].id)
		#expect(store.main.viewer.presentations.contains(originalLayout))

		await store.send(.main(.sidebar(.ui(.undo)))).finish()
		await store.send(.main(.ui(.confirmProfileMove))).finish()
		let restored = try #require(
			store.main.sidebar.organization.tabs.first { $0.restoration.url == organization.tabs[0].restoration.url }
		)
		#expect(restored.id != moved && restored.id != organization.tabs[0].id)
		expectNoDifference(store.main.sidebar.spaceID, source)
		expectNoDifference(store.main.sidebar.selectedTab?.id, restored.id)
		expectNoDifference(store.main.viewer.item.tab?.id, restored.id)
		var restoredLayout = originalLayout
		restoredLayout.panes[0].tabID = restored.id
		expectNoDifference(store.main.viewer.currentPresentation, restoredLayout)
	}

	@Test(arguments: [false, true])
	internal func folderMoveFollowsSelectionIntoVisitedDestinationWithoutReplacingOtherPane(crossProfile: Bool) async throws {
		let organization = presentationMoveFixture(crossProfile: crossProfile)
		let destination = organization.spaces[1].id
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = organization.tabs[0]
		main.viewer.preservesPresentation = true
		let layout = BrowserSpacePresentation(
			id: destination,
			panes: [
				.init(id: UUID(43), tabID: organization.tabs[3].id),
				.init(id: UUID(44), tabID: organization.tabs[4].id),
			],
			activePaneID: UUID(43),
			orientation: .vertical,
			fractions: [0.35, 0.65]
		)
		main.viewer.presentations = [layout]
		let store = presentationMoveStore(main)
		await store.send(.main(.transferTabs([.folder(organization.folders[0].id.rawValue)], nil, destination))).finish()
		if crossProfile { await store.send(.main(.ui(.confirmProfileMove))).finish() }
		let moved = try #require(
			store.main.sidebar.organization.tabs.first { $0.restoration.url == organization.tabs[0].restoration.url }
		)
		var expected = layout
		expected.panes[0].tabID = moved.id
		expectNoDifference(store.main.sidebar.selectedTab?.id, moved.id)
		expectNoDifference(store.main.viewer.currentPresentation, expected)
		#expect(store.main.sidebar.organization.tabs.ids.contains(organization.tabs[3].id))
	}

	@Test
	internal func delayedMoveSynchronizationDoesNotExplicitlySelectAfterSelectionChanges() async {
		let organization = presentationMoveFixture(crossProfile: true)
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = organization.tabs[0]
		main.sidebar.select(organization.tabs[3].id)
		let store = TestStore(initialState: main) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.synchronizeSelecting(organization.tabs[0].id))
		await store.receive { action in
			guard case let .delegate(.requestSpacePresentation(space, selected, selectRequested)) = action
			else { return false }
			return space == organization.spaces[1].id && selected == organization.tabs[3].id && !selectRequested
		}
		await store.finish()
		expectNoDifference(store.state.sidebar.selectedTab?.id, organization.tabs[3].id)
	}

	@Test(arguments: [false, true])
	internal func explicitSpaceSelectionCannotInsertForeignOrClaimedTab(claimed: Bool) async {
		let organization = presentationMoveFixture(crossProfile: true)
		let destination = organization.spaces[1].id
		var viewer = ViewerFeature.State(item: .init(tab: organization.tabs[0]))
		viewer.spaceID = organization.spaces[0].id
		viewer.requestedSpaceID = destination
		let layout = BrowserSpacePresentation(
			id: destination,
			panes: [
				.init(id: UUID(43), tabID: organization.tabs[3].id),
				.init(id: UUID(44), tabID: organization.tabs[4].id),
			],
			activePaneID: UUID(43),
			orientation: .vertical,
			fractions: [0.35, 0.65]
		)
		viewer.presentations = [layout]
		let store = Store(initialState: viewer) { ViewerFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		let selected = claimed ? organization.tabs[3] : organization.tabs[0]
		await store.send(
			.selectSpace(
				destination,
				organization,
				selected: selected,
				selectRequested: true,
				excluding: claimed ? [selected.id] : []
			)
		).finish()
		var expected = layout
		if claimed {
			expected.panes.removeFirst()
			expected.activePaneID = UUID(44)
			expected.fractions = [1]
		}
		expectNoDifference(store.currentPresentation, expected)
	}

	private func presentationMoveStore(_ main: MainFeature.State) -> StoreOf<AppFeature> {
		let next = LockIsolated(100)

		// Parameterized cases run in parallel and save window layouts, so each gets its own document.
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: main)
		}
		return Store(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.uuid = .init {
				next.withValue { value in
					defer { value += 1 }
					return UUID(value)
				}
			}
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1) }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { _ in }
		}
	}

	private func presentationMoveFixture(crossProfile: Bool) -> BrowserOrganization {
		let source = Space.ID(rawValue: UUID(1))
		let destination = Space.ID(rawValue: UUID(2))
		let profile = Profile.ID(rawValue: UUID(10))
		let other = crossProfile ? Profile.ID(rawValue: UUID(11)) : profile
		let folder = Folder.ID(rawValue: UUID(20))
		let tabs: [BrowserCore.Tab] = (30...34).map { value in
			var tab = BrowserCore.Tab(
				id: .init(rawValue: UUID(value)),
				profileID: value < 33 ? profile : other,
				restoration: .init(
					title: "Page \(value)",
					url: URL(string: "https://capturecontext.dev/\(value)")!
				)
			)
			if value < 32 { tab.savedDestination = .init(title: tab.restoration.title, url: tab.restoration.url) }
			return tab
		}
		return .init(
			profiles: [.init(id: profile, name: "Source")] + (crossProfile ? [.init(id: other, name: "Destination")] : []),
			spaces: [
				.init(
					id: source,
					profileID: profile,
					name: "Source",
					savedItems: [.folder(folder)],
					unpinnedTabs: [tabs[2].id],
					selectedTabID: tabs[0].id
				),
				.init(
					id: destination,
					profileID: other,
					name: "Destination",
					unpinnedTabs: [tabs[3].id, tabs[4].id],
					selectedTabID: tabs[3].id
				),
			],
			folders: [
				.init(
					id: folder,
					spaceID: source,
					name: "Moved folder",
					children: [.tab(tabs[0].id), .tab(tabs[1].id)]
				),
			],
			tabs: tabs
		)
	}
}
