import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation
import TabArchiveFeature
import _ComposableArchitecture

/// Keeps archive commits and native session ownership at the main-window boundary.
@Reducer
internal struct TabArchiving {
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
		Pullback(\.event.closePermissionGranted) { state, value in
			let (id, reset, location) = value
			guard state.sidebar.organization.location(of: id) == location else {
				state.pendingTabCloses.remove(id)
				return .none
			}
			return .run { [engine] send in
				if !reset { await engine.close(id) }
				await send(.sidebar(.event(.closeApproved(id, reset: reset, expectedLocation: location))))
			}
		}

		// Runs before SidebarFeature removes the successfully closed tab.
		Pullback(\.sidebar.event.closeApproved) { state, value in
			let (id, reset, expectedLocation) = value
			let isAtExpectedLocation = expectedLocation == nil
			|| state.sidebar.organization.location(of: id) == expectedLocation

			if !reset || !isAtExpectedLocation {
				state.pendingTabCloses.remove(id)
			}
			guard !reset else { return .none }
			guard isAtExpectedLocation else {
				guard let retained = state.sidebar.organization.tabs[id: id] else { return .none }
				return state.reopeningRetainedTabs([retained], engine: engine)
			}
			state.knownTabIDs.remove(id)
			guard !state.isPrivate, case .unpinned = state.sidebar.organization.location(of: id)
			else { return .none }
			do {
				try state.archiveClosedTab(id, closedAt: now, groupID: uuid(), uuid: { uuid() })
			} catch {
				state.sidebar.message = error.localizedDescription
			}
			return state.archive.profileID == nil ? .none : .send(.refreshArchive)
		}

		Pullback(\.ui.openArchive) { state in
			guard !state.isPrivate, !state.archive.isWorking else { return .none }
			state.archive.profileID = state.sidebar.space.profileID
			state.archive.query = ""
			state.archive.spaceFilter = nil
			state.archive.selectedIDs = []
			state.archive.restorationConfirmation = nil
			state.archive.message = nil
			state.archive.isPresented = true
			state.refreshArchive()
			return .none
		}

		Pullback(\.refreshArchive) { state in
			state.refreshArchive()
			return .none
		}

		Pullback(\.reconcile) { state, _ in state.archive.profileID == nil ? .none : .send(.refreshArchive) }
		Pullback(\.synchronize) { state in state.archive.profileID == nil ? .none : .send(.refreshArchive) }
		Pullback(\.synchronizeSelecting) { state, _ in
			state.archive.profileID == nil ? .none : .send(.refreshArchive)
		}

		Pullback(\.ui.reopenLastClosedTab) { state in
			guard !state.isPrivate, !state.archive.isWorking else { return .none }
			state.archive.profileID = state.sidebar.space.profileID
			state.refreshArchive()
			guard let entry = state.archive.entries.last
			else { return .none }
			let ids = state.archive.entries.filter { $0.groupID == entry.groupID }.map(\.id)
			state.archive.selectedIDs = Set(ids)
			return .send(.archive(.delegate(.restore(ids, nil))))
		}

		// Restores one entry the way ⇧⌘T restores the last group (DEV-908).
		Pullback(\.ui.reopenArchivedTab) { state, id in
			guard !state.isPrivate, !state.archive.isWorking else { return .none }
			state.archive.profileID = state.sidebar.space.profileID
			state.refreshArchive()
			guard state.archive.entries.contains(where: { $0.id == id }) else { return .none }
			state.archive.selectedIDs = [id]
			return .send(.archive(.delegate(.restore([id], nil))))
		}

		Pullback(\.ui.archiveSelectedTabs) { state, requested in
			guard !state.isPrivate, !state.isClosing, !state.archive.isWorking else { return .none }
			let ids = requested.isEmpty ? state.archiveSelectedTabIDs : requested
			let eligible = ids.filter { id in
				guard case let .unpinned(spaceID) = state.sidebar.organization.location(of: id)
				else { return false }
				return state.sidebar.organization.spaces[id: spaceID]?.profileID == state.sidebar.space.profileID
			}
			guard !eligible.isEmpty else { return .none }
			let entries = state.sidebar.organization.archiveEntries(
				for: eligible,
				closedAt: now,
				groupID: uuid(),
				uuid: { uuid() }
			)
			guard !entries.isEmpty else { return .none }
			state.archive.isWorking = true
			state.archive.message = nil
			return .run { [engine] send in
				for entry in entries {
					guard await engine.permitsClosing(entry.tab.id), !Task.isCancelled else {
						await send(.event(.archiveFailed("")))
						return
					}
				}
				await send(.event(.archiveApproved(entries)))
			}
		}

		Pullback(\.archiveInactiveTabs) { state, ids in
			guard !state.isPrivate, !state.isClosing, !state.archive.isWorking else { return .none }

			// The app chose these knowing which windows are open and checks again before closing.
			let eligible = ids.filter { id in
				guard case .unpinned = state.sidebar.organization.location(of: id)
				else { return false }
				return true
			}
			guard !eligible.isEmpty else { return .none }
			let entries = state.sidebar.organization.archiveEntries(
				for: eligible,
				closedAt: now,
				groupID: uuid(),
				uuid: { uuid() }
			)
			guard !entries.isEmpty else { return .none }
			state.archive.isWorking = true
			return .run { [engine] send in
				var permitted: [ArchivedTab] = []
				var refused: [BrowserCore.Tab.ID] = []
				for entry in entries {
					guard !Task.isCancelled else { break }
					if await engine.permitsClosing(entry.tab.id) {
						permitted.append(entry)
					} else {
						refused.append(entry.tab.id)
					}
				}
				guard !Task.isCancelled else {
					await send(.event(.archiveFailed("")))
					return
				}
				await send(.event(.inactiveArchivePermitted(permitted, refused: refused)))
			}
		}

		Pullback(\.event.archiveApproved) { state, entries in
			let entriesAreCurrent = entries.allSatisfy {
				state.sidebar.organization.location(of: $0.tab.id) == .unpinned($0.originalSpaceID)
			}
			guard !state.isClosing, entriesAreCurrent else {
				return .send(.event(.archiveFailed(String.localized(.appUI.archive.tabsMoved))))
			}
			return .run { [engine] send in
				for entry in entries { await engine.close(entry.tab.id) }
				await send(.event(.archiveClosed(entries)))
			}
		}

		Pullback(\.event.archiveClosed) { state, entries in
			state.archive.isWorking = false
			do {
				// Archiving isn't a step of its own, nor part of the one being made (DEV-1030).
				state.sidebar.sealUndo()
				try state.sidebar.organization.archiveClosedTabs(entries)
				state.knownTabIDs.subtract(entries.map(\.tab.id))
				let retainedIDs = Set(state.sidebar.organization.tabs.map(\.id.rawValue))
				state.sidebar.moveSelection.removeAll { item in
					guard case let .tab(id) = item else { return false }
					return !retainedIDs.contains(id)
				}
			} catch { state.archive.message = error.localizedDescription }
			let entryTabIDs = Set(entries.map(\.tab.id))
			let retained = Array(state.sidebar.organization.tabs.filter { entryTabIDs.contains($0.id) })
			return .merge(.send(.synchronize), state.reopeningRetainedTabs(retained, engine: engine))
		}

		Pullback(\.archive.delegate.restore) { state, request in
			guard !state.isPrivate, !state.isClosing, !state.archive.isWorking else { return .none }
			let (ids, destination) = request
			let previous = state.sidebar.organization
			let entries = previous.archive.filter { ids.contains($0.id) }
			guard
				!entries.isEmpty,
				entries.allSatisfy({ $0.tab.profileID == state.archive.profileID })
			else { return .none }
			let updated: BrowserOrganization
			do { updated = try previous.restoringArchive(ids, to: destination, uuid: { uuid() }) }
			catch {
				state.archive.message = error.localizedDescription
				state.archive.isPresented = true
				return .none
			}
			let copies = Array(updated.tabs.filter { !previous.tabs.ids.contains($0.id) })

			// Each copy reopens with its closed tab's back/forward history (DEV-878). The copies
			// follow the entries' order.
			let reopened = zip(entries, copies).filter { entry, copy in
				entry.tab.profileID == copy.profileID && entry.tab.restoration == copy.restoration
			}
			state.archive.isWorking = true
			state.archive.message = nil
			return .run { [engine] send in
				for (entry, copy) in reopened { await engine.cloneNavigation(entry.tab, copy.id) }
				do {
					for profile in Set(copies.map(\.profileID)) {
						try await engine.prepareProfile(profile)
					}
					for tab in copies {
						try Task.checkCancellation()
						try await engine.open(tab)
					}
					try Task.checkCancellation()
					await send(.event(.archiveRestored(previous, updated, copies)))
				} catch {
					for tab in copies { await engine.close(tab.id) }
					await send(.event(.archiveFailed(error.localizedDescription)))
				}
			}
		}

		Pullback(\.event.archiveRestored) { state, result in
			let (previous, updated, opened) = result
			state.archive.isWorking = false
			guard state.sidebar.organization == previous, !state.isClosing else {
				state.archive.message = String.localized(.appUI.archive.workspaceChanged)
				state.archive.isPresented = true
				return .run { [engine] _ in
					for tab in opened { await engine.close(tab.id) }
				}
			}

			// Reopening isn't a step: ⌘Z passes over the close it reopened (DEV-1030).
			state.sidebar.sealUndo()
			state.sidebar.organization = updated
			if let tab = opened.first {
				state.sidebar.select(tab.id)
				return .send(.synchronizeSelecting(tab.id))
			}
			return .send(.synchronize)
		}

		Pullback(\.event.archiveFailed) { state, message in
			state.archive.isWorking = false
			state.archive.message = message.isEmpty ? nil : message
			if !message.isEmpty { state.archive.isPresented = true }
			return .none
		}

		Pullback(\.archive.delegate.delete) { state, ids in
			guard
				!state.isPrivate,
				!state.archive.isWorking,
				let profile = state.archive.profileID
			else { return .none }
			state.sidebar.sealUndo()
			state.sidebar.organization.archive.removeAll { ids.contains($0.id) && $0.tab.profileID == profile }
			return .send(.synchronize)
		}

		Pullback(\.archive.delegate.clear) { state, profile in
			guard !state.isPrivate, !state.archive.isWorking, profile == state.archive.profileID
			else { return .none }
			state.sidebar.sealUndo()
			state.sidebar.organization.archive.removeAll { $0.tab.profileID == profile }
			return .send(.synchronize)
		}
	}

}

extension MainFeature.State {
	/// A concurrent move or pin can finish while native close awaits; restore its retained session.
	internal func reopeningRetainedTabs(
		_ tabs: [BrowserCore.Tab],
		engine: BrowserEngineClient
	) -> Effect<MainFeature.Action> {
		let selected = tabs.first { $0.id == viewer.item.tab?.id }
		let background = tabs.filter { $0.id != selected?.id }
		return .merge(
			selected.map { .send(.viewer(.item(.show($0)))) } ?? .none,
			.run { send in
				for tab in background {
					do { try await engine.open(tab) }
					catch { await send(.event(.archiveFailed(error.localizedDescription))) }
				}
			}
		)
	}

	internal mutating func refreshArchive() {
		guard let profileID = archive.profileID else { return }
		archive.entries = sidebar.organization.archive.filter { $0.tab.profileID == profileID }
		archive.spaces = sidebar.organization.spaces
		archive.profiles = sidebar.organization.profiles
		archive.profileName = sidebar.organization.profiles[id: profileID]?.name
		?? String.localized(.appUI.archive.removedProfile)
		archive.selectedIDs.formIntersection(archive.entries.map(\.id))
		if let confirmation = archive.restorationConfirmation, !confirmation.matches(archive) {
			archive.restorationConfirmation = nil
		}
	}
}

extension MainFeature.State {
	/// Commits one ordinary unpinned close after its native session has been disposed. With
	/// `windowUndo`, a close made in this window is a step ⌘Z takes back while Recently Closed holds
	/// the tab; an agent's close is recorded by the app instead (DEV-1030). Without it, the close
	/// clears the window's history.
	public mutating func archiveClosedTab(
		_ id: BrowserCore.Tab.ID,
		closedAt: Date,
		groupID: UUID,
		recordsUndo: Bool = true,
		uuid: () -> UUID
	) throws {
		guard
			!isPrivate,
			case .unpinned = sidebar.organization.location(of: id)
		else { throw TabArchiveError.invalidEntry }

		let entries = sidebar.organization.archiveEntries(
			for: [id],
			closedAt: closedAt,
			groupID: groupID,
			uuid: uuid
		)
		guard entries.count == 1 else { throw TabArchiveError.invalidEntry }

		let previous = sidebar.organization
		let isStep = recordsUndo && sidebar.windowUndo
		if !isStep { sidebar.sealUndo() }
		try sidebar.organization.archiveClosedTabs(entries)
		if isStep { sidebar.pushSealedUndo(previous) }
		knownTabIDs.remove(id)
		if archive.profileID != nil { refreshArchive() }
	}
}
