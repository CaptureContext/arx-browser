@testable import AppFeature
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// TabMoveSmoke's steps against a fake engine that keeps a snapshot per open page: two pages
/// put in nested folders, the folder moved to a space of a new profile, and ⌘Z taking it back
/// with fresh pages in the source profile.
@Suite(.dependencies)
@MainActor
internal struct CrossProfileUndoTests {
	@Test(arguments: [true, false])
	internal func undoOfAFolderMovedToAnotherProfileRestoresItsLivePages(windowUndo: Bool) async throws {
		try await undoAFolderMovedToAnotherProfile(windowUndo: windowUndo, meanwhile: nil, restores: true)
	}

	/// A page that reports its site's color, or is shown in another way, while ⌘Z moves it back
	/// doesn't stop the move: TabMoveSmoke's live pages report their color just after they load.
	@Test(arguments: [true, false])
	internal func undoKeepsGoingWhenAPageReportsItsColorMeanwhile(windowUndo: Bool) async throws {
		try await undoAFolderMovedToAnotherProfile(windowUndo: windowUndo, meanwhile: .recolor, restores: true)
	}

	/// A page that goes to another address while ⌘Z moves it back stops the move, as before.
	@Test
	internal func undoStopsWhenAPageNavigatesMeanwhile() async throws {
		try await undoAFolderMovedToAnotherProfile(windowUndo: true, meanwhile: .navigate, restores: false)
	}

	private func undoAFolderMovedToAnotherProfile(
		windowUndo: Bool,
		meanwhile change: FakePages.Change?,
		restores: Bool
	) async throws {
		let organization = IntegrationFeatureTests().fixture()
		let sourceSpace = organization.spaces[0].id
		let original = try #require(organization.tabs[id: organization.spaces[0].unpinnedTabs[0]])
		let second = try #require(organization.tabs[id: organization.spaces[0].unpinnedTabs[1]])
		let engine = FakePages([original, second])
		let store = makeStore(organization, windowUndo: windowUndo, engine: engine)

		let profile = Profile.ID(rawValue: UUID(800))
		let destination = Space.ID(rawValue: UUID(801))
		await store.send(.settings(.delegate(.changeOrganization(.createProfile(profile, name: "Move smoke"))))).finish()
		await store.send(.settings(.delegate(.changeOrganization(.createSpace(
			destination,
			profileID: profile,
			name: "Move smoke",
			icon: .stack
		))))).finish()
		#expect(store.main.sidebar.organization.spaces.ids.contains(destination))

		let before = Set(store.workspace.folders.ids)
		await store.send(.main(.sidebar(.ui(.sidebar(.newFolder(nil)))))).finish()
		let root = try #require(store.workspace.folders.first { !before.contains($0.id) })
		await store.send(.main(.sidebar(.ui(.sidebar(.newFolder(.folder(root.id.rawValue))))))).finish()
		let nested = try #require(store.workspace.folders.first { !before.contains($0.id) && $0.id != root.id })
		await store.send(.main(.transferTabs([.tab(original.id.rawValue)], .inside(.folder(root.id.rawValue)), sourceSpace))).finish()
		await store.send(.main(.transferTabs([.tab(second.id.rawValue)], .inside(.folder(nested.id.rawValue)), sourceSpace))).finish()
		#expect(store.workspace.folders[id: nested.id]?.children.contains(.tab(second.id)) == true)

		await store.send(.main(.transferTabs([.folder(root.id.rawValue)], nil, destination))).finish()
		let forward = try #require(store.main.pendingTabMove)
		await store.send(.main(.ui(.confirmProfileMove))).finish()
		let transferred = forward.plan.replacements.map(\.destination)
		#expect(!store.main.transferInProgress)
		#expect(transferred.allSatisfy { store.workspace.tabs.ids.contains($0.id) && engine.isOpen($0.id) })
		#expect(store.workspace.folders[id: root.id]?.spaceID == destination)

		await store.send(.main(.sidebar(.ui(.undo)))).finish()
		let reverse = try #require(store.main.pendingTabMove)
		#expect(reverse.isUndo)
		let restored = reverse.plan.replacements.map(\.destination)
		engine.change(transferred.map(\.id), onNextPreparation: change)
		await store.send(.main(.ui(.confirmProfileMove))).finish()

		guard restores else {
			#expect(restored.allSatisfy { !store.workspace.tabs.ids.contains($0.id) && !engine.isOpen($0.id) })
			#expect(transferred.allSatisfy { store.workspace.tabs.ids.contains($0.id) })
			return
		}
		expectNoDifference(store.main.sidebar.message, nil)
		#expect(!store.main.transferInProgress)
		#expect(transferred.allSatisfy { !engine.isOpen($0.id) && !store.workspace.tabs.ids.contains($0.id) })
		#expect(restored.count == 2)
		#expect(restored.allSatisfy { store.workspace.tabs.ids.contains($0.id) && engine.isOpen($0.id) })
		expectNoDifference(store.workspace.folders[id: root.id]?.spaceID, sourceSpace)
		expectNoDifference(store.main.sidebar.spaceID, sourceSpace)
		try store.workspace.validate()
	}

	private func makeStore(
		_ organization: BrowserOrganization,
		windowUndo: Bool,
		engine: FakePages
	) -> StoreOf<AppFeature> {
		let next = LockIsolated(1_000)
		let document = WorkspaceDocument.unsaved()

		// The live check, which reads the store while the move runs.
		let live = LockIsolated<StoreOf<AppFeature>?>(nil)
		var state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		state.main.viewer.item.tab = organization.tabs[id: organization.spaces[0].unpinnedTabs[0]]
		state.main.sidebar.windowUndo = windowUndo
		state.focusedWindowID = state.main.id
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.uuid = .init {
				next.withValue { value in
					defer { value += 1 }
					return UUID(value)
				}
			}
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.snapshot = { engine.snapshot($0) }
			$0.browserEngine.open = { engine.open($0) }
			$0.browserEngine.close = { engine.close($0) }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.prepareProfile = { _ in engine.prepared() }
			$0.tabMoveAuthorization.check = { windowID, sources in
				live.value?.state.canCommitTabMove(windowID: windowID, sourceIDs: sources) ?? false
			}
		}
		live.setValue(store)
		return store
	}
}

/// Open pages and their snapshots, as the engine keeps them.
private final class FakePages: @unchecked Sendable {
	/// What a page does while a move runs.
	enum Change {
		/// It reports its site's color, a new revision and another visibility, as a live page does
		/// just after it loads.
		case recolor

		/// It goes to another address.
		case navigate
	}

	private let pages: LockIsolated<[BrowserCore.Tab.ID: BrowserSessionSnapshot]>
	private let pending: LockIsolated<(tabs: [BrowserCore.Tab.ID], change: Change)?> = .init(nil)

	init(_ tabs: [BrowserCore.Tab]) {
		pages = .init(Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, Self.snapshot(of: $0)) }))
	}

	func snapshot(_ id: BrowserCore.Tab.ID) -> BrowserSessionSnapshot? {
		pages.value[id]
	}

	func isOpen(_ id: BrowserCore.Tab.ID) -> Bool {
		pages.value[id] != nil
	}

	func open(_ tab: BrowserCore.Tab) {
		pages.withValue { $0[tab.id] = Self.snapshot(of: tab) }
	}

	func close(_ id: BrowserCore.Tab.ID) {
		pages.withValue { $0[id] = nil }
	}

	/// Makes `tabs` change as the next move prepares its destination profile, after it read them.
	func change(
		_ tabs: [BrowserCore.Tab.ID],
		onNextPreparation change: Change?
	) {
		pending.setValue(change.map { (tabs, $0) })
	}

	func prepared() {
		guard let (tabs, change) = pending.value else { return }

		pending.setValue(nil)
		pages.withValue { pages in
			for id in tabs {
				guard var snapshot = pages[id] else { continue }

				switch change {
				case .recolor:
					snapshot.navigation.colors = .init(background: .init(red: 0.9, green: 0.95, blue: 1))
					snapshot.revision += 1
					snapshot.isVisibleForCapture.toggle()
				case .navigate:
					snapshot.navigation.url = URL(string: "https://elsewhere.example")!
					snapshot.revision += 1
				}
				pages[id] = snapshot
			}
		}
	}

	private static func snapshot(of tab: BrowserCore.Tab) -> BrowserSessionSnapshot {
		.init(
			navigation: .init(url: tab.restoration.url, title: tab.restoration.title),
			revision: 1,
			documentRevision: 1
		)
	}
}
