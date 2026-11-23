import AppUI
import BrowserCore
import BrowserEngineClient
import SidebarFeature
import _ComposableArchitecture

/// Stages every new session before committing a complete tree edit. Originals close only after commit.
@Reducer
internal struct ProfileTabTransfer {
	internal typealias State = MainFeature.State
	internal typealias Action = MainFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.tabMoveAuthorization)
	private var authorization

	@Dependency(\.uuid)
	private var uuid

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.sidebar.delegate.transferTabs) { _, request in
			.send(.transferTabs(request.0, request.1, request.2))
		}

		Pullback(\.sidebar.delegate.takeOpenTabsFromOtherWindows) { state, tabs in
			guard !state.isPrivate else { return .none }
			return .send(.delegate(.takeOpenTabsFromOtherWindows(tabs)))
		}

		Pullback(\.sidebar.delegate.chooseMoveDestination) { state, roots in
			guard !state.transferInProgress, !state.isClosing else { return .none }
			state.movePicker = .init(
				roots: roots,
				organization: state.sidebar.organization,
				selection: state.sidebar.moveSelection
			)
			return .none
		}

		Pullback(\.ui.dismissMovePicker) { state in
			state.movePicker = nil
			return .none
		}

		Pullback(\.ui.chooseMoveDestination) { state, target in
			guard let picker = state.movePicker else { return .none }
			state.movePicker = nil
			guard
				picker.organization == state.sidebar.organization,
				picker.selection == state.sidebar.moveSelection
			else {
				state.sidebar.message = String.localized(.appUI.management.workspaceChanged)
				return .none
			}
			return .send(.transferTabs(
				picker.roots,
				target.1.map { .inside(.folder($0.rawValue)) },
				target.0
			))
		}

		Pullback(\.ui.moveSelectedTab) { state, destination in
			guard let tab = state.sidebar.selectedTab else { return .none }
			return .send(.transferTabs([.tab(tab.id.rawValue)], nil, destination))
		}

		// A whole space reuses the tree move: one confirmation, staged sessions, the same rollback and undo.
		Pullback(\.ui.moveSpaceToProfile) { state, value in
			guard !state.transferInProgress, !state.isClosing, !state.isPrivate else { return .none }
			do {
				let plan = try state.sidebar.organization.movingSpace(
					value.0,
					toProfile: value.1,
					newTabID: { .init(rawValue: uuid()) }
				)
				let request = TabMoveRequest(
					id: uuid(),
					plan: plan,
					selection: state.sidebar.moveSelection,
					sourceSpace: state.sidebar.spaceID,
					selectedTab: state.sidebar.selectedTab?.id,
					sourcePresentations: state.movePresentations(for: plan)
				)
				if plan.replacements.isEmpty { return .send(.performTabMove(request)) }
				state.pendingTabMove = request
			} catch {
				state.sidebar.message = String.localized(.appUI.preview.invalidMove)
			}
			return .none
		}

		Pullback(\.ui.cancelProfileMove) { state in
			state.pendingTabMove = nil
			return .none
		}

		Pullback(\.ui.confirmProfileMove) { state in
			guard let request = state.pendingTabMove else { return .none }
			state.pendingTabMove = nil
			return .send(.performTabMove(request))
		}

		Pullback(\.sidebar.delegate.reverseTransfer) { state, completed in
			guard !state.transferInProgress, !state.isClosing else { return .none }
			guard state.sidebar.organization.hasSameMoveStructure(as: completed.updated) else {
				state.sidebar.message = String.localized(.appUI.management.workspaceChanged)

				// With one ⌘Z per window, the move can't go back any more, so it's no longer a step,
				// and ⌘Z reaches the ones before it (DEV-1030).
				if state.sidebar.windowUndo { state.sidebar.dropTransferStep(completed) }
				return .none
			}
			var completed = completed
			completed.updated = state.sidebar.organization
			guard let reverse = try? completed.reversed(newTabID: { .init(rawValue: uuid()) }) else {
				state.sidebar.message = String.localized(.appUI.preview.invalidMove)
				return .none
			}
			let request = TabMoveRequest(
				id: uuid(),
				plan: reverse,
				selection: state.sidebar.moveSelection,
				sourceSpace: state.sidebar.spaceID,
				selectedTab: state.sidebar.selectedTab?.id,
				sourcePresentations: state.movePresentations(for: reverse),
				isUndo: true
			)
			if reverse.replacements.isEmpty { return .send(.performTabMove(request)) }
			state.pendingTabMove = request
			return .none
		}

		Pullback(\.transferTabs) { state, value in
			guard !state.transferInProgress, !state.isClosing else { return .none }
			do {
				// Dropping a pinned tab among regular tabs is the person asking to unpin it.
				let plan = try state.sidebar.organization.moving(
					value.0.map(\.savedItem),
					to: value.1?.moveDestination ?? .spaceRoot,
					in: value.2,
					unpinning: true,
					newTabID: { .init(rawValue: uuid()) }
				)
				let request = TabMoveRequest(
					id: uuid(),
					plan: plan,
					selection: state.sidebar.moveSelection,
					sourceSpace: state.sidebar.spaceID,
					selectedTab: state.sidebar.selectedTab?.id,
					sourcePresentations: state.movePresentations(for: plan)
				)
				if !plan.replacements.isEmpty {
					guard !state.isPrivate else { throw TransferError.stale }
					state.pendingTabMove = request
					return .none
				}
				return .send(.performTabMove(request))
			} catch {
				state.sidebar.message = String.localized(.appUI.preview.invalidMove)
				return .none
			}
		}

		Pullback(\.transferConfirmedTabs) { state, value in
			let (id, items, target, space) = value
			guard !state.transferInProgress, !state.isClosing, !state.isPrivate else {
				return .send(.event(.moveFailed(id, String.localized(.appUI.management.busy))))
			}
			do {
				let plan = try state.sidebar.organization.moving(
					items.map(\.savedItem),
					to: target?.moveDestination ?? .spaceRoot,
					in: space,
					unpinning: true,
					newTabID: { .init(rawValue: uuid()) }
				)
				return .send(.performTabMove(.init(
					id: id,
					plan: plan,
					selection: state.sidebar.moveSelection,
					sourceSpace: state.sidebar.spaceID,
					selectedTab: state.sidebar.selectedTab?.id,
					sourcePresentations: state.movePresentations(for: plan)
				)))
			} catch {
				return .send(.event(.moveFailed(id, String.localized(.appUI.preview.invalidMove))))
			}
		}

				Pullback(\.performTabMove) { state, request in
			guard !state.transferInProgress, !state.isClosing, state.matches(request) else {
				state.sidebar.message = String.localized(.appUI.management.workspaceChanged)
				return .none
			}
			if request.plan.replacements.isEmpty {
				let taken = state.openTabsTakenFromOtherWindows(by: request)
				let followed = commit(request, into: &state)
				let synchronize: Effect<Action> = .send(followed.map { .synchronizeSelecting($0) } ?? .synchronize)
				guard !taken.isEmpty else { return synchronize }

				return .concatenate(synchronize, .send(.delegate(.takeOpenTabsFromOtherWindows(taken))))
			}
			guard !state.isPrivate else { return .none }
			state.activeTabMove = request
			state.transferInProgress = true
			state.sidebar.message = nil
			let windowID = state.id
			return .run { @MainActor [engine, authorization] send in
				let sources = request.plan.replacements.map(\.source.id)
				let snapshots = sources.map { engine.snapshot($0) }
				let identities = snapshots.map { $0?.moveIdentity }
				let live = request.plan.replacements
					.enumerated()
					.filter { snapshots[$0.offset] != nil }
					.map(\.element)
				var attempted: [BrowserCore.Tab.ID] = []

				@MainActor
				func validate() throws {
					try Task.checkCancellation()
					guard
						authorization.check(windowID, sources),
						sources.map({ engine.snapshot($0)?.moveIdentity }) == identities
					else {
						throw TransferError.stale
					}
				}

				do {
					try validate()
					for (replacement, snapshot) in zip(request.plan.replacements, snapshots) {
						let isPresented = request.sourcePresentations.values
							.contains(where: { $0.tabID == replacement.source.id })

						if snapshot == nil, isPresented { throw TransferError.stale }
						if let url = snapshot?.navigation.url, url != replacement.source.restoration.url {
							throw TransferError.stale
						}
					}
					for profile in Set(live.map(\.destination.profileID)) {
						try validate()
						try await engine.prepareProfile(profile)
					}
					for replacement in live {
						try validate()
						var session = replacement.destination
						session.savedDestination = nil
						attempted.append(session.id)
						try await engine.open(session)
					}
					for id in live.map(\.source.id) {
						try validate()
						guard await engine.permitsClosing(id) else { throw TransferError.cancelled }
					}
					try validate()
					send(.event(.movedAcrossProfiles(request)))
				} catch {
					for id in attempted { engine.close(id) }
					let message: String
					switch error {
					case TransferError.cancelled: message = ""
					case TransferError.stale: message = String.localized(.appUI.management.workspaceChanged)
					default: message = error.localizedDescription
					}
					send(.event(.moveFailed(request.id, message)))
				}
			}
		}

		Pullback(\.event.movedAcrossProfiles) { state, request in
			guard state.activeTabMove == request, state.matches(request), !state.isClosing else {
				if state.activeTabMove?.id == request.id {
					state.activeTabMove = nil
					state.transferInProgress = false
				}
				state.sidebar.message = String.localized(.appUI.management.workspaceChanged)
				let retained = Set(state.sidebar.organization.tabs.map(\.id))
				return .run { [engine] _ in
					for replacement in request.plan.replacements where !retained.contains(replacement.destination.id) {
						await engine.close(replacement.destination.id)
					}
				}
			}
			let followed = commit(request, into: &state)
			state.activeTabMove = nil
			state.transferInProgress = false
			return .send(followed.map { .synchronizeSelecting($0) } ?? .synchronize)
		}

		Pullback(\.event.moveFailed) { state, value in
			guard state.activeTabMove?.id == value.0 else { return .none }
			state.activeTabMove = nil
			state.transferInProgress = false
			state.sidebar.message = value.1.isEmpty ? nil : value.1
			return .none
		}
	}

	private func commit(
		_ request: TabMoveRequest,
		into state: inout State
	) -> BrowserCore.Tab.ID? {
		let followed = request.selectedTab.flatMap { selected -> BrowserCore.Tab.ID? in
			guard state.viewer.panes.contains(where: { $0.item.tab?.id == selected })
			else { return nil }
			if let replacement = request.plan.replacements.first(where: { $0.source.id == selected }) {
				return replacement.destination.id
			}
			return request.plan.movedTabIDs.contains(selected) ? selected : nil
		}
		state.sidebar.organization = request.plan.updated
		state.sidebar.moveSelection = []
		state.sidebar.selectSpace(request.plan.destination)
		if let followed { state.sidebar.select(followed) }
		if request.isUndo {
			if let step = state.sidebar.undo.popLast() {
				state.sidebar.transferUndos.removeAll { $0.previous == step.before }
			}

		} else if request.plan.previous != state.sidebar.organization {
			var completed = request.plan
			completed.updated = state.sidebar.organization
			state.sidebar.transferUndos.append(completed)

			// Made from the space the tabs left, which ⌘Z shows again.
			state.sidebar.pushUndo(request.plan.previous, in: request.sourceSpace)
		}
		return followed
	}

	private enum TransferError: Error {
		case stale
		case cancelled
	}
}

extension MainFeature.State {
	/// Open tabs another window keeps that a sidebar drop here moves among the open tabs, such as
	/// a row dragged from that window's sidebar (DEV-822). Undo leaves them where they are.
	fileprivate func openTabsTakenFromOtherWindows(by request: TabMoveRequest) -> [BrowserCore.Tab.ID] {
		guard !request.isUndo, !isPrivate, sidebar.openTabFilter != .all else { return [] }

		let wasOpen = Set(request.plan.previous.spaces.flatMap(\.unpinnedTabs))
		let open = Set(request.plan.updated.spaces.flatMap(\.unpinnedTabs))
		return request.plan.movedTabIDs.filter { id in
			wasOpen.contains(id) && open.contains(id) && !sidebar.openTabFilter.shows(id)
		}
	}
}

extension BrowserSessionSnapshot {
	/// What a page mustn't change while a move of its tab runs, or the move would close or copy
	/// the wrong page: the page itself, its profile, its document and where it is in its history.
	/// A color the page reports late, a new title, the window showing it and the revisions they
	/// bump don't make the move unsafe (TabMoveSmoke, DEV-1030). A page with no document stamp,
	/// a WebKit page or an unloaded one, keeps its revision instead, so a reload of the same
	/// address still counts.
	fileprivate var moveIdentity: MoveIdentity {
		.init(
			nativePageID: nativePageID,
			nativeProfileID: nativeProfileID,
			documentRevision: documentRevision,
			revision: documentRevision == nil ? revision : nil,
			url: navigation.url,
			history: navigation.history.map { .init(id: $0.id, url: $0.url, isCurrent: $0.isCurrent) }
		)
	}
}

private struct MoveIdentity: Equatable {
	struct Entry: Equatable {
		var id: Int
		var url: URL
		var isCurrent: Bool
	}

	internal var nativePageID: UInt64?
	internal var nativeProfileID: Profile.ID?
	internal var documentRevision: UInt64?

	/// Only for a page without `documentRevision`.
	internal var revision: UInt64?
	internal var url: URL?
	internal var history: [Entry]
}
