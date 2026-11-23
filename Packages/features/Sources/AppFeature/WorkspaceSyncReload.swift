import BrowserCore
import BrowserWorkspaceClient
import MainFeature
import ViewerFeature
import WorkspaceSync
import _ComposableArchitecture

/// Shows what iCloud sync wrote to the workspace database (DEV-977): after each batch an engine
/// commits, and the repair pass after it, the workspace is read again and every window reconciles
/// with it, as after a change in Settings.
///
/// The read happens only when no edit here is waiting to be saved, and in the same step that
/// publishes it. The database's diff writer saves against the rows it last read, so reading in
/// between an edit and its save would make that save delete what sync just added. Otherwise the
/// read waits for the next successful save, as it does while a profile is retired, Arx is cleared
/// for an import, or a profile moves between windows.
///
/// Composed inside AppFeature after the reducer that clears a saved edit, so its changes reach
/// AppFeature's observers, such as the global shortcut's.
@Reducer
internal struct WorkspaceSyncReload {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	private enum Cancellation: Hashable { case remoteChanges }

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.workspaceDocument)
	private var document

	@Dependency(\.workspaceSync)
	private var sync

	@Dependency(\.uuid)
	private var uuid

	internal var body: some ReducerOf<Self> {
		Pullback(\.main.ui.task) { _ in
			guard sync.isAvailable() else { return .none }

			return .run { [sync] send in
				for await category in await sync.remoteChanges() {
					// History has its own database; ProfileHistory takes it in. Tab Archive's file is read
					// with the workspace (DEV-983).
					if category == .history {
						await send(.event(.historySyncChanged))
					} else {
						await send(.event(.workspaceSyncChanged))
					}
				}
			}
			.cancellable(id: Cancellation.remoteChanges, cancelInFlight: true)
		}

		Pullback(\.event.workspaceSyncChanged) { state in
			reload(&state)
		}

		Pullback(\.event.workspaceSyncTabClosesDecided) { state, value in
			let (pages, approved) = value
			state.syncReloadAwaitingApproval = false

			// A page that stays keeps the change unread until the next one asks every page again.
			guard approved else {
				state.syncReloadPending = false
				return .none
			}

			state.syncApprovedTabCloses = pages
			return reload(&state)
		}

		// Panes showing them open them again in place, in the profile they have now: a later reload
		// may have moved them again meanwhile, and only what's current opens. A pane already showing
		// that profile opens it only when its page is gone, as after a move there and back (DEV-1071).
		Pullback(\.event.workspaceSyncPagesClosed) { state, ids in
			var panes: [(tabID: BrowserCore.Tab.ID, window: UUID, pane: UUID)] = []

			// A closed window's suspended panes open it when shown again.
			for window in [state.main] + state.windows.filter({ !$0.isPrivate }) {
				for pane in window.viewer.panes where pane.item.isObserving {
					guard let id = pane.item.tab?.id, ids.contains(id) else { continue }

					panes.append((id, window.id, pane.id))
				}
			}
			guard !panes.isEmpty else { return .none }

			return .run { @MainActor [engine, panes] send in
				for pane in panes {
					let page: SyncCheckedPage = engine.snapshot(pane.tabID).map { .live($0.nativeProfileID) } ?? .none
					send(.event(.workspaceSyncPaneChecked(pane.tabID, window: pane.window, pane: pane.pane, page: page)))
				}
			}
		}

		// Checked against the tab as it is when the answer arrives, so a later reload's profile wins.
		Pullback(\.event.workspaceSyncPaneChecked) { state, value in
			let (id, windowID, paneID, page) = value
			guard
				let tab = state.workspace.tabs[id: id],
				let window = windowID == state.main.id ? state.main : state.windows[id: windowID],
				!window.isPrivate,
				let pane = window.viewer.panes[id: paneID],
				pane.item.tab?.id == id,
				pane.item.isObserving
			else { return .none }

			// A page that doesn't say which profile it's in counts as in the current one.
			let isLive: Bool = switch page {
			case .none: false
			case let .live(profileID): profileID.map { $0 == tab.profileID } ?? true
			}
			guard pane.item.tab?.profileID != tab.profileID || !isLive else { return .none }

			let reopen: MainFeature.Action = .viewer(.reopen(tab, in: paneID))
			return windowID == state.main.id
			? .send(.main(reopen))
			: .send(.windows(.element(id: windowID, action: reopen)))
		}

		// A reload that waited runs after whichever action ends the wait: a save landing, or a
		// retirement, clear or profile transfer finishing, failing or cancelled.
		Reduce { state, action in
			guard state.syncReloadPending, !action.is(\.event.workspaceSyncChanged) else { return .none }

			return reload(&state)
		}
	}

	private func reload(_ state: inout State) -> Effect<Action> {
		// The answer reloads, reading whatever is newest then.
		guard !state.syncReloadAwaitingApproval else { return .none }

		guard
			state.unsavedOrganization == nil,
			!state.requiresImmediateSave,
			!state.discardUnsavedChangesOnQuit,
			// These finish with a save, which reads the change then.
			!state.profileRetirement.isBusy,
			!state.isChangingPreferenceGroup,
			state.migrationClearing == nil,
			!state.hasPendingProfileTransfers
		else {
			state.syncReloadPending = true

			// An answer holds for the read it was given for, not one that waits.
			state.syncApprovedTabCloses = [:]
			return .none
		}

		// A shared-preference edit reaches the document at once but asks for its save a step later:
		// save it now, and read once that save lands.
		if state.persistedPreferences != document.savedPreferences {
			state.syncReloadPending = true
			state.syncApprovedTabCloses = [:]
			return state.saveWorkspace()
		}

		state.syncReloadPending = false
		let reloaded: BrowserWorkspaceClient.Recovery?
		let previous: BrowserOrganization = state.workspace

		// An answer holds for this read only: a page's contents can change before the next one.
		let approved: [BrowserCore.Tab.ID: SyncClosingPage] = state.syncApprovedTabCloses
		state.syncApprovedTabCloses = [:]
		var closing: Set<BrowserCore.Tab.ID> = []
		do {
			// A page the change would close agrees first, as for a change made here: a tab another Mac
			// deleted, and one whose space it moved to another profile, which can't keep its page.
			// Asked before the rows are accepted, so a page that stays leaves the saved base, and so
			// the change, unread.
			reloaded = try document.reloadDatabase { organization in
				closing = organization.tabsChangingProfile(from: previous)
					.union(Set(previous.tabs.map(\.id)).subtracting(organization.tabs.map(\.id)))

				// An answer holds only for the page that gave it, not another document the tab shows since.
				let agreed: Bool = MainActor.assumeIsolated { [engine] in
					closing.allSatisfy { id in approved[id] == SyncClosingPage(engine.snapshot(id)) }
				}
				guard agreed else { throw ClosingNeedsApproval() }
			}
		} catch is ClosingNeedsApproval {
			state.syncReloadAwaitingApproval = true
			return .run { @MainActor [engine, closing] send in
				var pages: [BrowserCore.Tab.ID: SyncClosingPage] = [:]
				for id in closing {
					guard await engine.permitsClosing(id) else {
						send(.event(.workspaceSyncTabClosesDecided([:], approved: false)))
						return
					}
					pages[id] = SyncClosingPage(engine.snapshot(id))
				}
				send(.event(.workspaceSyncTabClosesDecided(pages, approved: true)))
			}
		} catch {
			// The rows stay as they are in memory; the next batch tries again, and an iCloud adoption
			// waiting for this read sooner (DEV-1221).
			return .send(.event(.workspaceSyncReadFailed))
		}

		// The store was read: an iCloud adoption waiting for it can decide now (DEV-1221).
		state.iCloudAdoption?.hasReadStore = true
		guard
			let reloaded,
			var organization = reloaded.organization
		else { return .none }

		// Profiles this Mac retired stay out, as at launch.
		let retired: Set<Profile.ID> = Set(
			state.profileRetirement.intents.filter(\.acknowledged).map(\.profileID)
		)
		if !retired.isEmpty {
			do {
				organization = try organization.excludingRetiredProfiles(retired)
			} catch {
				// Nothing would be left but retired profiles: keep what's shown, as a launch does.
				return .none
			}
		}

		// A pinned tab or Favorite another Mac moved to another profile comes back with a new ID, but
		// a fetch can bring its space's new profile first: until then it keeps its ID, and its page
		// in the old profile closes so it opens again in the new one.
		let reprofiled: Set<BrowserCore.Tab.ID> = organization.tabsChangingProfile(from: state.workspace)
			.subtracting(organization.openTabsChangingProfile(from: state.workspace))

		// This Mac's open tabs don't sync, but their space does. Ones whose space another Mac moved to
		// another profile get new identities, as a move here gives them, so their pages close in the
		// old profile and open again in the new one (DEV-1004).
		let replacements: [BrowserCore.Tab.ID: BrowserCore.Tab.ID] = organization.reidentifyOpenTabs(
			movedFrom: state.workspace
		) {
			.init(rawValue: uuid())
		}
		var preferences: BrowserPreferences = reloaded.preferences

		// Assistant grants and clients never sync; the reducer's own are current.
		preferences.automation = state.automationPreferences
		guard organization != state.workspace || preferences != state.persistedPreferences else { return .none }

		let removed: Set<BrowserCore.Tab.ID> = Set(state.workspace.tabs.map(\.id))
			.subtracting(organization.tabs.map(\.id))

		// So does which window each one is in (DEV-822).
		state.replaceOwnedTabs(replacements)
		state.workspace = organization

		// Layouts windows keep for spaces they aren't showing follow the new IDs.
		if !replacements.isEmpty {
			state.main.replacePresentedTabs(replacements)
			for id in state.windows.ids {
				state.windows[id: id]?.replacePresentedTabs(replacements)
			}
		}
		state.commit(organization: organization, preferences: preferences)

		// What was just read is what's saved.
		state.unsavedOrganization = nil

		// Each window keeps its selection where it still can and moves off a space that's gone, as
		// after a change in Settings, which isn't told: an editor open there stays open. Panes showing
		// a reidentified tab show it under its new ID first, so a split keeps its panes (DEV-1071).
		let mainPanes: [Effect<Action>] = state.main
			.panesShowing(replacements, in: organization)
			.map { .send(.main(.viewer($0))) }
		var effects: [Effect<Action>] = [
			.concatenate(mainPanes + [.send(.main(.reconcile(organization)))]),
			.send(.event(.workspaceSyncApplied)),
		]
		for window in state.windows where !window.isPrivate {
			let panes: [Effect<Action>] = window
				.panesShowing(replacements, in: organization)
				.map { .send(.windows(.element(id: window.id, action: .viewer($0)))) }
			effects.append(.concatenate(panes + [.send(.windows(.element(id: window.id, action: .reconcile(organization))))]))
		}
		if !removed.isEmpty {
			effects.append(.run { [engine] _ in
				for id in removed { await engine.close(id) }
			})
		}
		if !reprofiled.isEmpty {
			// A pane showing one opens it again in place, in the new profile, once its old page closed
			// (DEV-1071). A layout a window keeps for later opens it in the new profile when shown.
			effects.append(.run { [engine] send in
				for id in reprofiled { await engine.close(id) }
				await send(.event(.workspaceSyncPagesClosed(reprofiled)))
			})
		}

		// The new identities exist only here until saved.
		if !replacements.isEmpty {
			effects.append(state.saveWorkspace())
		}
		return .merge(effects)
	}
}

private struct ClosingNeedsApproval: Error {}

/// A tab's page when a pane showing it was checked after a sync reload closed its old one (DEV-1071).
public enum SyncCheckedPage: Equatable, Sendable {
	/// No page.
	case none

	/// A page, in this profile when the engine says.
	case live(Profile.ID?)
}

/// A page as it agreed to close for a sync reload (DEV-1071): an answer holds for that page and
/// document only. A tab without a page is `nil` throughout.
public struct SyncClosingPage: Equatable, Sendable {
	public var nativePageID: UInt64?
	public var documentRevision: UInt64?

	public init(_ snapshot: BrowserSessionSnapshot?) {
		self.nativePageID = snapshot?.nativePageID
		self.documentRevision = snapshot?.documentRevision
	}
}

extension BrowserOrganization {
	/// Tabs in both whose profile differs from `previous`'s, as when another Mac moved their space
	/// to another profile: a page can't move between profiles.
	internal func tabsChangingProfile(from previous: BrowserOrganization) -> Set<BrowserCore.Tab.ID> {
		Set(tabs.filter { tab in
			previous.tabs[id: tab.id].map { $0.profileID != tab.profileID } ?? false
		}.map(\.id))
	}

	/// Open tabs whose profile differs from `previous`'s: a space moved to another profile on
	/// another Mac changes its open tabs' profile here, and a page can't move between profiles.
	internal func openTabsChangingProfile(from previous: BrowserOrganization) -> Set<BrowserCore.Tab.ID> {
		Set(spaces.flatMap(\.unpinnedTabs).filter { id in
			guard let tab = tabs[id: id], let old = previous.tabs[id: id] else { return false }

			return old.profileID != tab.profileID
		})
	}

	/// Gives each of ``openTabsChangingProfile(from:)`` a new ID, keeping its place, page and title.
	///
	/// - Returns: each replaced ID's new one.
	internal mutating func reidentifyOpenTabs(
		movedFrom previous: BrowserOrganization,
		newTabID: () -> BrowserCore.Tab.ID
	) -> [BrowserCore.Tab.ID: BrowserCore.Tab.ID] {
		var identities: Set<BrowserCore.Tab.ID> = Set(tabs.map(\.id))
		var mapped: [BrowserCore.Tab.ID: BrowserCore.Tab.ID] = [:]
		let changing: Set<BrowserCore.Tab.ID> = openTabsChangingProfile(from: previous)
		for id in spaces.flatMap(\.unpinnedTabs) where changing.contains(id) {
			var replacement: BrowserCore.Tab.ID = newTabID()
			while !identities.insert(replacement).inserted { replacement = newTabID() }
			mapped[id] = replacement
		}
		guard !mapped.isEmpty else { return [:] }

		tabs = .init(uniqueElements: tabs.map { tab in
			guard let id = mapped[tab.id] else { return tab }

			return .init(
				id: id,
				profileID: tab.profileID,
				savedDestination: tab.savedDestination,
				restoration: tab.restoration,
				customTitle: tab.customTitle,
				icon: tab.icon,
				automationClientID: tab.automationClientID
			)
		})
		for index in spaces.indices {
			spaces[index].unpinnedTabs = spaces[index].unpinnedTabs.map { mapped[$0] ?? $0 }
			spaces[index].selectedTabID = spaces[index].selectedTabID.map { mapped[$0] ?? $0 }
		}
		for index in splits.indices {
			splits[index].tabIDs = splits[index].tabIDs.map { mapped[$0] ?? $0 }
		}
		for index in tabGroups.indices {
			tabGroups[index].tabIDs = tabGroups[index].tabIDs.map { mapped[$0] ?? $0 }
		}
		return mapped
	}
}

extension MainFeature.State {
	/// Shows each pane's tab that `replacements` reidentified under its new ID, in place. A suspended
	/// pane, as a closed window keeps, is left to show it when the window opens again.
	internal func panesShowing(
		_ replacements: [BrowserCore.Tab.ID: BrowserCore.Tab.ID],
		in organization: BrowserOrganization
	) -> [ViewerFeature.Action] {
		guard !replacements.isEmpty else { return [] }

		return viewer.panes.compactMap { pane in
			guard
				pane.item.isObserving,
				let id = pane.item.tab?.id,
				let replacement = replacements[id],
				let tab = organization.tabs[id: replacement]
			else { return nil }

			return .panes(.element(id: pane.id, action: .item(.show(tab))))
		}
	}

	/// Points the layouts this window keeps for spaces it isn't showing at `replacements`' new IDs.
	internal mutating func replacePresentedTabs(_ replacements: [BrowserCore.Tab.ID: BrowserCore.Tab.ID]) {
		for index in viewer.presentations.indices {
			for pane in viewer.presentations[index].panes.indices {
				guard
					let id = viewer.presentations[index].panes[pane].tabID,
					let replacement = replacements[id]
				else { continue }

				viewer.presentations[index].panes[pane].tabID = replacement
			}
		}
	}
}
