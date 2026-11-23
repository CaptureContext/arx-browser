#if DEBUG
import AppUI
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// Exercises the production move reducer and live authorization with real Chromium sessions.
internal enum TabMoveSmoke {
	@MainActor
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine
	) async throws {
		guard
			let original = store.main.viewer.item.tab,
			let second = store.workspace.tabs.first(where: {
				$0.id != original.id && $0.profileID == original.profileID && engine.client.snapshot($0.id) != nil
			})
		else { throw Failure.missingSource }

		let sourceSpace = store.main.sidebar.spaceID
		let destination = Space.ID(rawValue: UUID())
		let profile = Profile.ID(rawValue: UUID())
		store.send(.settings(.delegate(.changeOrganization(.createProfile(profile, name: "Move smoke")))))
		try await wait("Destination profile was not reconciled") {
			store.main.sidebar.organization.profiles.ids.contains(profile)
		}
		store.send(.settings(.delegate(.changeOrganization(.createSpace(
			destination,
			profileID: profile,
			name: "Move smoke",
			icon: .stack
		)))))
		try await wait("Destination space was not reconciled") {
			store.main.sidebar.organization.spaces.ids.contains(destination)
		}

		let previousFolders = Set(store.workspace.folders.map(\.id))
		store.send(.main(.sidebar(.ui(.sidebar(.newFolder(nil))))))
		try await wait("Root folder was not created") { store.workspace.folders.contains { !previousFolders.contains($0.id) } }
		guard let root = store.workspace.folders.first(where: { !previousFolders.contains($0.id) })
		else { throw Failure.missingSource }
		store.send(.main(.sidebar(.ui(.sidebar(.newFolder(.folder(root.id.rawValue)))))))
		try await wait("Nested folder was not created") { store.workspace.folders.count == previousFolders.count + 2 }
		guard let nested = store.workspace.folders.first(where: { !previousFolders.contains($0.id) && $0.id != root.id })
		else { throw Failure.missingSource }
		store.send(.main(.transferTabs([.tab(original.id.rawValue)], .inside(.folder(root.id.rawValue)), sourceSpace)))
		try await wait("First page was not placed in root folder") {
			store.workspace.folders[id: root.id]?.children.contains(.tab(original.id)) == true
		}
		store.send(.main(.transferTabs([.tab(second.id.rawValue)], .inside(.folder(nested.id.rawValue)), sourceSpace)))
		try await wait("Second page was not placed in nested folder") {
			store.workspace.folders[id: nested.id]?.children.contains(.tab(second.id)) == true
		}
		let originals = [original.id, second.id]
		guard originals.allSatisfy({ engine.client.snapshot($0) != nil })
		else { throw Failure.missingSource }
		let urls = originals.compactMap { engine.client.snapshot($0)?.navigation.url }
		store.send(.main(.transferTabs([.folder(root.id.rawValue)], nil, destination)))
		try await wait("Cross-profile confirmation was not offered") { store.main.pendingTabMove != nil }
		guard
			let forward = store.main.pendingTabMove,
			forward.plan.replacements.count == 2,
			Set(forward.plan.replacements.map(\.source.id)) == Set(originals)
		else { throw Failure.invalidTransfer }
		store.send(.main(.ui(.confirmProfileMove)))
		let transferred = forward.plan.replacements.map(\.destination)
		try await wait("Cross-profile folder transfer did not settle") {
			!store.main.transferInProgress && originals.allSatisfy { engine.client.snapshot($0) == nil }
			&& transferred.allSatisfy { tab in loaded(engine, tab: tab) && store.workspace.tabs.ids.contains(tab.id) }
			&& store.main.viewer.item.tab.map { engine.isAttached($0.id) && transferred.map(\.id).contains($0.id) } == true
		}
		guard
			store.workspace.folders.filter({ $0.id == root.id || $0.id == nested.id }).allSatisfy({ $0.spaceID == destination }),
			transferred.allSatisfy({ $0.profileID == profile }),
			Set(transferred.map(\.restoration.url)) == Set(urls),
			let presented = store.main.viewer.item.tab,
			transferred.contains(where: { $0.id == presented.id }),
			engine.isAttached(presented.id)
		else { throw Failure.invalidTransfer }

		store.send(.main(.sidebar(.ui(.undo))))
		try await wait("Undo confirmation was not offered") { store.main.pendingTabMove?.isUndo == true }
		guard let reverse = store.main.pendingTabMove else { throw Failure.invalidTransfer }
		let restored = reverse.plan.replacements.map(\.destination)
		store.send(.main(.ui(.confirmProfileMove)))
		do {
			try await wait("Undo did not restore live source-profile pages") {
				!store.main.transferInProgress
				&& transferred.allSatisfy { engine.client.snapshot($0.id) == nil }
				&& restored.allSatisfy { tab in loaded(engine, tab: tab) && store.workspace.tabs.ids.contains(tab.id) }
				&& store.main.viewer.item.tab.map { engine.isAttached($0.id) && restored.map(\.id).contains($0.id) } == true
			}
		} catch {
			let sidebar = store.main.sidebar
			print(
				"ARX_TAB_MOVE_UNDO_DIAGNOSTIC active=\(store.main.transferInProgress) "
				+ "message=\(sidebar.message ?? "none") space=\(sidebar.spaceID) "
				+ "selected=\(String(describing: sidebar.selectedTab?.id)) "
				+ "presented=\(String(describing: store.main.viewer.item.tab?.id))"
			)
			for tab in transferred + restored {
				print(
					"ARX_TAB_MOVE_PAGE id=\(tab.id) retained=\(store.workspace.tabs.ids.contains(tab.id)) "
					+ "attached=\(engine.isAttached(tab.id)) "
					+ "snapshot=\(String(describing: engine.client.snapshot(tab.id)))"
				)
			}
			throw error
		}
		let previousIDs = Set(originals + transferred.map(\.id))
		guard
			restored.count == 2,
			restored.allSatisfy({ $0.profileID == original.profileID && !previousIDs.contains($0.id) }),
			store.workspace.folders.filter({ $0.id == root.id || $0.id == nested.id }).allSatisfy({ $0.spaceID == sourceSpace }),
			Set(restored.map(\.restoration.url)) == Set(urls),
			store.main.sidebar.spaceID == sourceSpace,
			let active = store.main.viewer.item.tab,
			restored.contains(where: { $0.id == active.id }),
			engine.isAttached(active.id)
		else { throw Failure.invalidTransfer }
		try store.workspace.validate()
		print("ARX_TAB_MOVE_SMOKE_SUCCESS")
	}

	@MainActor
	private static func loaded(
		_ engine: ChromiumBrowserEngine,
		tab: BrowserCore.Tab
	) -> Bool {
		guard let snapshot = engine.client.snapshot(tab.id) else { return false }
		return snapshot.navigation.url == tab.restoration.url && !snapshot.navigation.isLoading && snapshot.navigation.errorCode == nil
	}

	@MainActor
	private static func wait(
		_ message: String,
		until ready: () -> Bool
	) async throws {
		for _ in 0..<150 {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(100))
		}
		throw Failure.timedOut(message)
	}

	private enum Failure: Error {
		case missingSource
		case invalidTransfer
		case timedOut(String)
	}
}
#endif
