import BrowserCore
import BrowserWorkspaceClient
import Foundation
import MainFeature
import WorkspaceSync
import _ComposableArchitecture

extension Reducer where State == AppFeature.State, Action == AppFeature.Action {
	/// Records the spaces, pinned tabs and Favorites that come on screen as used (DEV-980), so a
	/// deletion another Mac synced spares what this Mac still opens. Opening one doesn't always
	/// change a saved row: switching back to a space keeps its selected tab. The store records each
	/// at most once a day, and only with iCloud sync on.
	internal func recordingUse() -> some Reducer<State, Action> {
		CombineReducers {
			onChange(of: { $0.itemsInUse }, reduce: { _, previous, current in
				Self.recordUse(of: current.subtracting(previous))
			})

			// What a launch restores is on screen from the start, with no change to notice.
			Reduce { state, action in
				guard action.is(\.main.ui.task) else { return .none }

				return Self.recordUse(of: state.itemsInUse)
			}
		}
	}

	private static func recordUse(of opened: Set<UUID>) -> Effect<Action> {
		@Dependency(\.workspaceSync)
		var sync

		guard !opened.isEmpty, sync.isAvailable() else { return .none }

		@Dependency(\.workspaceDocument)
		var document

		return .run { [sync] _ in
			try? document.recordUse(of: opened)

			// Opening a space marked for deletion cancels it (DEV-1336): the mark goes at once.
			@SharedReader(.iCloudRemoval)
			var removal

			if opened.contains(where: { removal.marked[$0] != nil }) { await sync.refreshStatus() }
		}
	}
}

extension AppFeature.State {
	/// The tabs on screen and the spaces open windows show, by ID. Private windows don't count.
	internal var itemsInUse: Set<UUID> {
		let open: [MainFeature.State] = (windowIsOpen ? [main] : []) + windows.filter { !$0.isPrivate }
		var ids: Set<UUID> = Set(tabsOnScreen.map(\.rawValue))
		ids.formUnion(open.map(\.sidebar.spaceID.rawValue))
		return ids
	}
}
