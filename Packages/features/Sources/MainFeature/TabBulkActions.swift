import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation
import SidebarFeature
import _ComposableArchitecture

/// The tabs one bulk close takes, checked again once their pages allow it (DEV-883).
public struct BulkTabClose: Equatable, Sendable {
	/// The open tabs, archived as one group so Reopen Last Closed Tab brings them back together.
	public var entries: [ArchivedTab]

	/// The open tabs of a private window, which keeps no archive.
	public var removals: [BrowserCore.Tab.ID]

	/// Pinned tabs and Favorites, which unload back to their saved page as ⌘W does.
	public var resets: [BrowserCore.Tab.ID]

	/// Where every tab was, so a move meanwhile cancels the close.
	public var locations: [BrowserCore.Tab.ID: BrowserOrganization.TabLocation]

	public init(
		entries: [ArchivedTab],
		removals: [BrowserCore.Tab.ID],
		resets: [BrowserCore.Tab.ID],
		locations: [BrowserCore.Tab.ID: BrowserOrganization.TabLocation]
	) {
		self.entries = entries
		self.removals = removals
		self.resets = resets
		self.locations = locations
	}

	/// Every tab it closes, archived and removed ones first.
	public var tabIDs: [BrowserCore.Tab.ID] { entries.map(\.tab.id) + removals + resets }

	/// The tabs that leave the sidebar.
	public var departingTabIDs: [BrowserCore.Tab.ID] { entries.map(\.tab.id) + removals }
}

/// The tab menu's bulk actions: Close Other Tabs, Close Tabs Below, and Close, Archive, Duplicate,
/// Pin and Unpin a selection. Each is one organization change, so one Undo Organization Change
/// takes it back. Move to Window goes to the app, which knows the other windows (DEV-883).
@Reducer
internal struct TabBulkActions {
	internal typealias State = MainFeature.State
	internal typealias Action = MainFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.date.now)
	private var now

	@Dependency(\.uuid)
	private var uuid

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.sidebar.ui.sidebar.closeTabs) { state, ids in
			close(state.sidebarOrderedTabs(ids), resettingSaved: true, state: &state)
		}

		Pullback(\.sidebar.ui.sidebar.archiveTabs) { state, ids in
			close(state.sidebarOrderedTabs(ids), resettingSaved: false, state: &state)
		}

		Pullback(\.sidebar.ui.sidebar.closeOtherTabs) { state, id in
			close(state.openTabs(otherThan: id), resettingSaved: false, state: &state)
		}

		Pullback(\.sidebar.ui.sidebar.closeTabsBelow) { state, id in
			close(state.openTabs(below: id), resettingSaved: false, state: &state)
		}

		Pullback(\.event.bulkCloseApproved) { state, request in
			let isCurrent = request.locations.allSatisfy { id, location in
				state.sidebar.organization.location(of: id) == location
			}
			guard !state.isClosing, isCurrent else {
				return .send(.event(.bulkCloseFailed(request, String.localized(.appUI.archive.tabsMoved))))
			}

			// Saved pages unload after the commit, through the usual reset, which also clears
			// them from other windows and Peek.
			return .run { [engine] send in
				for id in request.departingTabIDs { await engine.close(id) }
				await send(.event(.bulkCloseFinished(request)))
			}
		}

		Pullback(\.event.bulkCloseFailed) { state, value in
			let (request, message) = value
			state.pendingTabCloses.subtract(request.resets)
			return .send(.event(.archiveFailed(message)))
		}

		Pullback(\.event.bulkCloseFinished) { state, request in
			state.archive.isWorking = false
			let previous = state.sidebar.organization
			var organization = previous
			var resets: [BrowserCore.Tab.ID] = []
			do {
				try organization.archiveClosedTabs(request.entries)
				try organization.update { organization in
					for id in request.removals where organization.location(of: id) == request.locations[id] {
						organization.removeTab(id)
					}
					for id in request.resets where organization.location(of: id) == request.locations[id] {
						organization.resetPinnedTab(id)
						resets.append(id)
					}
				}
			} catch {
				state.archive.message = error.localizedDescription
			}
			if organization != previous {
				state.sidebar.organization = organization

				// Done as it's made: a tab selected afterwards isn't part of it (DEV-1198).
				state.sidebar.pushSealedUndo(previous)
				state.sidebar.message = nil
			}
			state.pendingTabCloses.subtract(Set(request.resets).subtracting(resets))

			let departed = Set(request.departingTabIDs).subtracting(organization.tabs.ids)
			state.knownTabIDs.subtract(departed)
			state.sidebar.moveSelection.removeAll { item in
				guard case let .tab(id) = item else { return false }
				return departed.contains(.init(rawValue: id))
			}

			// A move that finished while the pages closed keeps its tabs; their pages open again.
			let retained = request.departingTabIDs.compactMap { organization.tabs[id: $0] }
			for id in resets {
				state.sidebar.noteReset(id)
			}
			let unloads: [Effect<Action>] = resets.map { .send(.sidebar(.delegate(.resetTab($0)))) }
			return .merge([.send(.synchronize), state.reopeningRetainedTabs(retained, engine: engine)] + unloads)
		}

		Pullback(\.sidebar.ui.sidebar.duplicateTabs) { state, ids in
			let sources = state.sidebarOrderedTabs(ids).compactMap { state.sidebar.organization.tabs[id: $0] }
			guard !sources.isEmpty else { return .none }

			let copies: [BrowserCore.Tab] = sources.map { source in

				// The page a pane shows may be ahead of the tab's last saved address.
				let navigation = state.viewer.panes.first { $0.item.tab?.id == source.id }?.item.navigation
				let title = navigation.flatMap { $0.title.isEmpty ? nil : $0.title } ?? source.restoration.title
				return .init(
					id: .init(rawValue: uuid()),
					profileID: source.profileID,
					restoration: .init(
						title: title,
						url: navigation?.url ?? source.restoration.url
					),
					customTitle: source.customTitle,
					icon: source.icon
				)
			}
			let spaceID = state.sidebar.spaceID
			state.sidebar.edit { organization in
				guard let index = organization.spaces.index(id: spaceID)
				else { return }

				organization.tabs.append(contentsOf: copies)

				// Each directly below the tab it copies; bookmarks' copies first, in their own
				// order, which listing them last to first keeps (DEV-1310, DEV-1325).
				let open: Set<BrowserCore.Tab.ID> = Set(organization.spaces[index].unpinnedTabs)
				let pairs = Array(zip(sources, copies))
				for (source, copy) in pairs where open.contains(source.id) {
					organization.placeOpenedTab(copy.id, inSpaceAt: index, opener: source.id)
				}
				for (source, copy) in pairs.reversed() where !open.contains(source.id) {
					organization.placeOpenedTab(copy.id, inSpaceAt: index, opener: source.id)
				}
			}

			// Each copy's first page takes its tab's back/forward history (DEV-878).
			return .run { @MainActor [engine] _ in
				for (source, copy) in zip(sources, copies) { engine.cloneNavigation(source, copy.id) }
			}
		}

		Pullback(\.sidebar.ui.sidebar.setPinned) { state, value in
			let (ids, isPinned) = value
			let tabs = state.sidebarOrderedTabs(ids)
			let spaceID = state.sidebar.spaceID
			state.sidebar.edit { organization in

				// A whole Split View pinned or unpinned stays one (DEV-1006).
				try organization.keepingSplits { organization in
					for id in tabs {
						guard let tab = organization.tabs[id: id] else { continue }
						let isSaved = tab.savedDestination != nil
						guard isSaved != isPinned else { continue }

						try organization.move(.tab(id.rawValue), to: isPinned ? .savedRoot : .unpinnedRoot, in: spaceID)
					}
				}
			}
			return .none
		}

		Pullback(\.completeWindowMove) { state, value in
			let (tabs, destination, previous, handedOver, target) = value
			guard !state.isPrivate, !state.isClosing else { return .none }

			let before = state.sidebar.organization
			if let destination, let space = state.sidebar.organization.spaces[id: destination] {
				state.sidebar.edit { organization in

					// A whole Split View moved to the space stays one there (DEV-1006).
					try organization.keepingSplits { organization in
						for id in tabs {
							guard
								let tab = organization.tabs[id: id],
								tab.profileID == space.profileID
							else { continue }

							switch organization.location(of: id) {
							case .unpinned:
								try organization.move(.tab(id.rawValue), to: .unpinnedRoot, in: destination)

							case .pinned:
								try organization.move(.tab(id.rawValue), to: .savedRoot, in: destination)

							case .favorite, nil:
								continue
							}
						}
					}
				}
			}

			// A move that only brought the other window forward has nothing to undo there.
			guard let previous, !handedOver.isEmpty else {
				return state.sidebar.organization == before ? .none : .send(.synchronize)
			}

			// One undo step, from before this window let the tabs go, so it selects them again: the
			// move to the other window's space is part of it.
			if state.sidebar.organization != before, state.sidebar.undo.last?.before == before {
				state.sidebar.undo.removeLast()
			}
			let step = OrganizationUndo(
				before: previous,
				after: state.sidebar.organization,
				spaceID: state.sidebar.spaceID,
				windowMove: .init(tabs: handedOver, source: state.id, target: target)
			)
			state.sidebar.appendUndo(step)
			guard state.sidebar.windowUndo else { return .send(.synchronize) }

			// The window the tabs went to can take the step back too (DEV-1030).
			return .merge(.send(.synchronize), .send(.delegate(.shareUndo(step, windowID: target))))
		}

		Pullback(\.sidebar.ui.sidebar.moveToWindow) { state, value in
			let (ids, windowID) = value
			let tabs = state.sidebarOrderedTabs(ids)
			guard
				!state.isPrivate,
				!state.isClosing,
				!tabs.isEmpty
			else { return .none }

			// The app checks the move first; this window lets the tabs go only once it may.
			return .send(.delegate(.moveTabsToWindow(tabs, window: windowID, spaceID: state.sidebar.spaceID)))
		}

		Pullback(\.releaseTabsForWindowMove) { state, tabs in

			// A tab shows in one window at a time, so this one lets the tabs go: their split panes
			// close, and the selection moves to a neighbour.
			let leaving = Set(tabs)
			let leavingPanes = state.viewer.panes
				.filter { $0.item.tab.map { leaving.contains($0.id) } == true }
				.map(\.id)

			// A split keeps at least one pane, which the neighbour then fills.
			let closing = leavingPanes.count < state.viewer.panes.count
			? leavingPanes
			: leavingPanes.filter { $0 != state.viewer.activePaneID }
			let panes: [Effect<Action>] = state.viewer.isSplit
			? closing.map { .send(.viewer(.ui(.closePane($0)))) }
			: []
			var selection: Effect<Action> = .none
			if let selected = state.sidebar.selectedTab, leaving.contains(selected.id) {
				state.sidebar.selectNeighbour(leaving: leaving)
				selection = state.viewerSynchronization(selected: state.sidebar.selectedTab)
			}
			return .concatenate(.merge(panes), selection)
		}
	}

	private func close(
		_ ids: [BrowserCore.Tab.ID],
		resettingSaved: Bool,
		state: inout State
	) -> Effect<Action> {
		guard
			!ids.isEmpty,
			!state.isClosing,
			!state.archive.isWorking
		else { return .none }

		let locations = state.sidebar.organization.tabLocations
		var open: [BrowserCore.Tab.ID] = []
		var saved: [BrowserCore.Tab.ID] = []
		for id in ids {
			switch locations[id] {
			case .unpinned:
				open.append(id)

			case .pinned, .favorite:
				if resettingSaved { saved.append(id) }

			case nil:
				continue
			}
		}
		let entries = state.isPrivate ? [] : state.sidebar.organization.archiveEntries(
			for: open,
			closedAt: now,
			groupID: uuid(),
			uuid: { uuid() }
		)
		let request = BulkTabClose(
			entries: entries,
			removals: state.isPrivate ? open : [],
			resets: saved,
			locations: locations.filter { open.contains($0.key) || saved.contains($0.key) }
		)
		guard !request.tabIDs.isEmpty else { return .none }

		state.archive.isWorking = true
		state.archive.message = nil

		// As a single close does, so the app's saved-page reset knows these are closing.
		state.pendingTabCloses.formUnion(request.resets)
		return .run { [engine] send in
			for id in request.tabIDs {
				guard await engine.permitsClosing(id), !Task.isCancelled else {
					await send(.event(.bulkCloseFailed(request, "")))
					return
				}
			}
			await send(.event(.bulkCloseApproved(request)))
		}
	}
}

extension MainFeature.State {
	/// The current space's tabs among `ids`, once each, in sidebar order: Favorites, pinned tabs
	/// and folders, then open tabs (DEV-883).
	internal func sidebarOrderedTabs(_ ids: [SidebarItem.ID]) -> [BrowserCore.Tab.ID] {
		let requested: Set<BrowserCore.Tab.ID> = Set(ids.compactMap { id in
			guard case let .tab(uuid) = id else { return nil }
			return .init(rawValue: uuid)
		})
		var seen: Set<BrowserCore.Tab.ID> = []
		return sidebar.windowTabOrder.filter { id in
			requested.contains(id) && seen.insert(id).inserted
		}
	}

	/// Close Other Tabs: the open tabs outside the selection the row is in, or other than the row.
	internal func openTabs(otherThan id: SidebarItem.ID) -> [BrowserCore.Tab.ID] {
		let kept: Set<BrowserCore.Tab.ID> = Set(sidebarOrderedTabs(
			sidebar.moveSelection.contains(id) ? sidebar.moveSelection : [id]
		))
		guard !kept.isEmpty else { return [] }

		return sidebar.windowOpenTabs.filter { !kept.contains($0) }
	}

	/// Close Tabs Below: the open tabs after this one, or after its Split View group.
	internal func openTabs(below id: SidebarItem.ID) -> [BrowserCore.Tab.ID] {
		guard case let .tab(uuid) = id else { return [] }

		let tabID: BrowserCore.Tab.ID = .init(rawValue: uuid)
		let tabs = sidebar.windowOpenTabs
		let group = sidebar.organization.splits.first { $0.spaceID == sidebar.spaceID && $0.tabIDs.contains(tabID) }
		let members = group?.tabIDs ?? [tabID]
		guard let last = tabs.indices.last(where: { members.contains(tabs[$0]) })
		else { return [] }

		return Array(tabs[(last + 1)...])
	}
}

extension SidebarFeature.State {
	/// Selects the open tab after the leaving ones, or before them, or nothing.
	internal mutating func selectNeighbour(leaving tabs: Set<BrowserCore.Tab.ID>) {
		// The leaving tabs keep their places, even those already handed to another window.
		let open = space.unpinnedTabs.filter { openTabFilter.shows($0) || tabs.contains($0) }
		let staying = open.filter { !tabs.contains($0) }
		let firstLeaving = open.firstIndex(where: tabs.contains)
		let neighbour = firstLeaving.flatMap { start in
			open[start...].first { !tabs.contains($0) } ?? open[..<start].last { !tabs.contains($0) }
		} ?? staying.first
		if let neighbour {
			select(neighbour)
		} else if let index = organization.spaces.index(id: spaceID) {
			organization.spaces[index].selectedTabID = nil
		}
	}
}
