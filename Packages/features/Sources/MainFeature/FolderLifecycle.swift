import AppUI
import BrowserCore
import BrowserEngineClient
import SidebarFeature
import _ComposableArchitecture

/// Folder edits commit only after every page agrees; opening keeps existing session identities.
@Reducer
internal struct FolderLifecycle {
	internal typealias State = MainFeature.State
	internal typealias Action = MainFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.sidebar.delegate.deleteFolder) { state, id in
			guard state.pendingFolderDeletion == nil, !state.isClosing else { return .none }
			let subtree = state.sidebar.organization.folderSubtree(id)
			guard !subtree.isEmpty else { return .none }
			let tabs = state.sidebar.organization.tabs(in: id, includingDescendants: true)
			state.pendingFolderDeletion = id
			state.sidebar.message = nil
			return .run { [engine] send in
				for tab in tabs {
					guard await engine.permitsClosing(tab), !Task.isCancelled else {
						await send(.event(.folderDeletionCancelled(id)))
						return
					}
				}
				await send(.event(.folderDeletionApproved(id, subtree)))
			}
		}

		Pullback(\.event.folderDeletionCancelled) { state, id in
			guard state.pendingFolderDeletion == id else { return .none }
			state.pendingFolderDeletion = nil
			return .none
		}

		Pullback(\.event.folderDeletionApproved) { state, value in
			let (id, subtree) = value
			guard state.pendingFolderDeletion == id else { return .none }
			state.pendingFolderDeletion = nil
			guard !state.isClosing, state.sidebar.organization.folderSubtree(id) == subtree else {
				state.sidebar.message = String.localized(.appUI.management.workspaceChanged)
				return .none
			}
			state.sidebar.edit { try $0.deleteFolder(id) }
			return .send(.synchronize)
		}

		Pullback(\.sidebar.delegate.openFolder) { state, value in
			let (id, includingDescendants) = value
			guard !state.isClosing else { return .none }
			let tabs = state.sidebar.organization.tabs(in: id, includingDescendants: includingDescendants)
			guard !tabs.isEmpty else { return .none }
			state.sidebar.reveal(id)
			state.sidebar.message = nil
			return .send(.openFolderTabs(tabs))
		}

		Pullback(\.openFolderTabs) { state, ids in
			guard !state.isClosing, let id = ids.first else { return .none }
			let remaining = Array(ids.dropFirst())
			guard let tab = state.sidebar.organization.tabs[id: id] else {
				return .send(.openFolderTabs(remaining))
			}
			return .run { [engine] send in
				do {
					try Task.checkCancellation()
					try await engine.open(tab)
					await send(.event(.folderTabOpened(id, remaining: remaining)))
				} catch {
					await send(.event(.folderTabFailed(error.localizedDescription, remaining: remaining)))
				}
			}
		}

		Pullback(\.event.folderTabOpened) { state, value in
			let (id, remaining) = value
			guard state.sidebar.organization.tabs.ids.contains(id) else {
				return .concatenate(
					.run { [engine] _ in await engine.close(id) },
					.send(.openFolderTabs(remaining))
				)
			}
			guard !state.isClosing else { return .none }
			if state.sidebar.selectedTab == nil {
				let message = state.sidebar.message
				state.sidebar.select(id)
				state.sidebar.message = message
			}
			return .merge(.send(.synchronize), .send(.openFolderTabs(remaining)))
		}

		Pullback(\.event.folderTabFailed) { state, value in
			let (message, remaining) = value
			state.sidebar.message = message
			return .send(.openFolderTabs(remaining))
		}
	}
}
