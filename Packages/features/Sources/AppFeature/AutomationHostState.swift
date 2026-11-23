import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import Foundation
import PeekFeature
import _ComposableArchitecture

/// An expiring Peek or Little Arx handle owned by one MCP client session.
internal struct AutomationHostHandle: Equatable, Sendable {
	internal let id: UUID
	internal let clientID: UUID
	internal let sessionID: UUID
	internal let grantRevision: UUID
	internal let expiresAt: Date
	internal let kind: AutomationPresentation.Kind
	internal let hostID: UUID
	internal let tabID: BrowserCore.Tab.ID
	internal let profileID: Profile.ID
	internal let targetID: UUID
	internal let source: PeekFeature.Source?

	internal init(
		id: UUID,
		clientID: UUID,
		sessionID: UUID,
		grantRevision: UUID,
		expiresAt: Date,
		kind: AutomationPresentation.Kind,
		hostID: UUID,
		tabID: BrowserCore.Tab.ID,
		profileID: Profile.ID,
		targetID: UUID,
		source: PeekFeature.Source?
	) {
		self.id = id
		self.clientID = clientID
		self.sessionID = sessionID
		self.grantRevision = grantRevision
		self.expiresAt = expiresAt
		self.kind = kind
		self.hostID = hostID
		self.tabID = tabID
		self.profileID = profileID
		self.targetID = targetID
		self.source = source
	}
}

/// Host state captured before approval and rechecked when the handoff commits.
internal struct AutomationHostContext: Equatable, Sendable {
	internal let source: PeekFeature.Source?
	internal let sourceSession: AutomationSessionIdentity?
	internal let handle: AutomationHostHandle?
	internal let presentationSession: AutomationSessionIdentity?

	internal init(
		source: PeekFeature.Source?,
		sourceSession: AutomationSessionIdentity?,
		handle: AutomationHostHandle?,
		presentationSession: AutomationSessionIdentity?
	) {
		self.source = source
		self.sourceSession = sourceSession
		self.handle = handle
		self.presentationSession = presentationSession
	}
}

/// The document and navigation a handoff is bound to. Host visibility is deliberately
/// excluded: releasing a Peek or Little Arx surface changes it without changing the session.
internal struct AutomationSessionIdentity: Equatable, Sendable {
	internal let navigation: BrowserNavigation
	internal let revision: UInt64
	internal let documentRevision: UInt64?

	internal init?(_ snapshot: BrowserSessionSnapshot?) {
		guard let snapshot else { return nil }

		self.navigation = snapshot.navigation
		self.revision = snapshot.revision
		self.documentRevision = snapshot.documentRevision
	}
}

internal struct AutomationHostReceipt: Equatable, Sendable {
	internal let request: AutomationRequest
	internal let grantRevision: UUID
	internal let response: AutomationCommandResult

	internal init(
		request: AutomationRequest,
		grantRevision: UUID,
		response: AutomationCommandResult
	) {
		self.request = request
		self.grantRevision = grantRevision
		self.response = response
	}
}

// MARK: - Presentations

extension AppFeature.State {
	internal static let automationHostLifetime: TimeInterval = 300
	internal static let automationHostLimitPerClient: Int = 8
	internal static let automationHostLimit: Int = 32

	internal var automationSnapshotTabIDs: Set<BrowserCore.Tab.ID> {
		WorkProbe.record(.everyAutomationSnapshot)
		return Set(workspace.tabs.map(\.id)).union(automation.hostHandles.values.map(\.tabID))
	}

	/// The tabs whose sessions `request`'s checks read, and `result`'s when it's being released
	/// (DEV-934). A command that names its tabs reads those and the hosted ones, so opening or
	/// selecting a tab costs the same at 100 tabs as at 10. Everything else, inventory included,
	/// reads every tab.
	internal func automationSnapshotTabIDs(
		for request: AutomationRequest,
		result: AutomationResult? = nil
	) -> Set<BrowserCore.Tab.ID> {
		guard
			case let .command(command) = request.operation,
			!command.route,
			AutomationCommand.Action.readsNamedSessions.contains(command.action)
		else { return automationSnapshotTabIDs }

		var ids: Set<UUID> = [command.targetID]
		if let destinationID = command.destinationID { ids.insert(destinationID) }
		ids.formUnion(command.splitTabs?.map(\.id) ?? [])
		ids.formUnion(request.operation.pageTargets)
		if case let .command(response) = result {
			if let targetID = response.targetID { ids.insert(targetID) }
			if let item = response.item { ids.insert(item.id) }
		}
		return Set(ids.map(BrowserCore.Tab.ID.init(rawValue:)))
			.union(automation.hostHandles.values.map(\.tabID))
	}

	/// `ids`' current sessions, read from the engine.
	@MainActor
	internal static func automationSnapshots(
		of ids: Set<BrowserCore.Tab.ID>,
		reading snapshot: (BrowserCore.Tab.ID) -> BrowserSessionSnapshot?
	) -> [BrowserCore.Tab.ID: BrowserSessionSnapshot] {
		var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot] = [:]
		snapshots.reserveCapacity(ids.count)
		for id in ids {
			if let value = snapshot(id) { snapshots[id] = value }
		}
		return snapshots
	}

	internal func automationPresentations(
		for request: AutomationRequest,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		now: Date
	) -> [AutomationPresentation] {
		let clients = automationPreferences.clients
		guard
			let client = clients.first(where: { $0.id == request.clientID }),
			client.allowsRead,
			client.allowsManagement,
			automation.sessions[request.sessionID] == client.id
		else { return [] }

		return automation.hostHandles.values.compactMap { handle in
			guard
				handle.clientID == client.id,
				handle.sessionID == request.sessionID,
				handle.grantRevision == client.grantRevision,
				handle.expiresAt > now,
				automationHostScopeIsPermitted(handle, client: client),
				automationHostIsCurrent(handle)
			else { return nil }

			// The revision moves with the hosted document, so promotion needs fresh inventory.
			let snapshot = snapshots[handle.tabID]
			let identity = [
				handle.id.uuidString,
				handle.hostID.uuidString,
				handle.tabID.rawValue.uuidString,
				handle.profileID.rawValue.uuidString,
				handle.grantRevision.uuidString,
				String(snapshot?.revision ?? 0),
				String(snapshot?.documentRevision ?? 0),
			]
			let bytes = withErrorReporting { try JSONEncoder().encode(identity) }
			guard let bytes else { return nil }

			return .init(
				id: handle.id,
				kind: handle.kind,
				tabID: handle.tabID.rawValue,
				profileID: handle.profileID.rawValue,
				sourceTargetID: handle.targetID,
				revision: AutomationSecurity.digest(bytes)
			)
		}
		.sorted { $0.id.uuidString < $1.id.uuidString }
	}

	internal func automationHostScopeIsPermitted(
		_ handle: AutomationHostHandle,
		client: AutomationClient
	) -> Bool {
		guard workspace.profiles.ids.contains(handle.profileID) else { return false }

		if let tab = workspace.tabs.first(where: { $0.id.rawValue == handle.targetID }) {
			guard
				tab.profileID == handle.profileID,
				AutomationAccess.permitsTab(tab.id, client: client, organization: workspace)
			else { return false }

		} else {
			guard
				let space = workspace.spaces.first(where: { $0.id.rawValue == handle.targetID }),
				space.profileID == handle.profileID,
				AutomationAccess.permitsSpace(space.id, client: client, organization: workspace)
			else { return false }
		}

		guard let sourceTabID = handle.source?.tabID else { return true }
		return AutomationAccess.permitsTab(sourceTabID, client: client, organization: workspace)
	}

	internal func automationHostIsCurrent(_ handle: AutomationHostHandle) -> Bool {
		switch handle.kind {
		case .peek:
			guard let peek = peeks[id: handle.hostID] else { return false }
			return peek.tab.id == handle.tabID
			&& peek.tab.profileID == handle.profileID
			&& peek.source == handle.source
			&& peek.phase == .idle
			&& peekSourceIsAvailable(peek.source)

		case .littleArx:
			guard let little = littleWindows[id: handle.hostID] else { return false }
			return little.tab.id == handle.tabID
			&& little.tab.profileID == handle.profileID
			&& !little.isCommandOnly
			&& !little.isClosing
			&& !little.isPromoting
			&& !little.isSwitchingProfile
			&& little.peekID == nil
		}
	}

	private func automationPresentationIsCurrent(
		_ command: AutomationCommand,
		request: AutomationRequest,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		now: Date
	) -> Bool {
		automationPresentations(for: request, snapshots: snapshots, now: now).contains {
			$0.id == command.presentationID && $0.revision == command.presentationRevision
		}
	}
}

// MARK: - Context

extension AppFeature.State {
	internal func automationHostContext(
		for pending: AutomationState.Pending,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		now: Date
	) -> AutomationHostContext? {
		guard
			case let .command(command) = pending.request.operation,
			command.action.isHostOperation,
			!profileRetirement.isBusy
		else { return nil }

		switch command.action {
		case .openPeek:
			return automationPeekContext(command, snapshots: snapshots)

		case .openLittleArx:
			return .init(source: nil, sourceSession: nil, handle: nil, presentationSession: nil)

		default:
			guard
				let id = command.presentationID,
				let handle = automation.hostHandles[id],
				let snapshot = snapshots[handle.tabID],
				snapshot.documentRevision != nil,
				automationPresentationIsCurrent(
					command,
					request: pending.request,
					snapshots: snapshots,
					now: now
				)
			else { return nil }

			return .init(
				source: handle.source,
				sourceSession: .init(handle.source?.tabID.flatMap { snapshots[$0] }),
				handle: handle,
				presentationSession: .init(snapshot)
			)
		}
	}

	/// Resolves the unique ordinary pane showing the explicit source tab; there is no focused-window fallback.
	private func automationPeekContext(
		_ command: AutomationCommand,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationHostContext? {
		guard
			let sourceID = command.sourceTabID.map(BrowserCore.Tab.ID.init(rawValue:)),
			let sourceSnapshot = snapshots[sourceID],
			sourceSnapshot.documentRevision != nil
		else { return nil }

		let hosts = (windowIsOpen ? [main] : []) + windows.filter { !$0.isPrivate }
		let owners = hosts.flatMap { host in
			host.viewer.panes.compactMap { pane -> PeekFeature.Source? in
				guard pane.item.tab?.id == sourceID else { return nil }
				return peekSource(windowID: host.id, paneID: pane.id)
			}
		}
		guard
			owners.count == 1,
			let source = owners.first,
			!peeks.contains(where: { $0.source.windowID == source.windowID })
		else { return nil }

		// Borrowing an existing tab must not steal it from another visible pane or Peek.
		if command.url == nil {
			let borrowedID = BrowserCore.Tab.ID(rawValue: command.targetID)
			let isShownElsewhere = hosts.contains { host in
				host.viewer.panes.contains { pane in
					pane.item.tab?.id == borrowedID
					&& (host.id != source.windowID || pane.id != source.paneID)
				}
			}
			guard
				!isShownElsewhere,
				!peeks.contains(where: { $0.tab.id == borrowedID })
			else { return nil }
		}

		return .init(
			source: source,
			sourceSession: .init(sourceSnapshot),
			handle: nil,
			presentationSession: nil
		)
	}
}

// MARK: - Validation

extension AppFeature.State {
	internal func automationHostValidation(
		_ pending: AutomationState.Pending,
		command: AutomationCommand,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		now: Date
	) -> AutomationFailure? {
		// Unattended runs have no visible window to host Peek or Little Arx.
		guard !automation.isUnattended else { return .unsupported }
		guard !profileRetirement.isBusy else { return .busy }

		if command.action == .openPeek {
			let source = command.sourceTabID.flatMap { sourceID in
				AutomationInventoryBuilder
					.items(client: client, organization: workspace, snapshots: snapshots)
					.first { $0.id == sourceID && $0.kind == .tab }
			}
			guard
				let source,
				source.revision == command.sourceRevision,
				let target = workspace.tabs.first(where: { $0.id.rawValue == command.targetID }),
				target.profileID.rawValue == source.profileID
			else { return .staleTarget }
		}

		// An outdated or foreign presentation handle is stale, not merely unready.
		if command.presentationID != nil, pending.hostContext == nil {
			let isCurrent = automationPresentationIsCurrent(
				command,
				request: pending.request,
				snapshots: snapshots,
				now: now
			)
			guard isCurrent else { return .staleTarget }
		}

		let resolved = pending.hostContext
		?? automationHostContext(for: pending, snapshots: snapshots, now: now)
		guard let context = resolved else { return .notReady }

		if let captured = pending.hostContext {
			if let source = captured.source {
				guard
					peekSourceIsValid(source),
					AutomationSessionIdentity(source.tabID.flatMap { snapshots[$0] }) == captured.sourceSession
				else { return .staleTarget }
			}
			if let handle = captured.handle {
				guard AutomationSessionIdentity(snapshots[handle.tabID]) == captured.presentationSession
				else { return .staleTarget }
			}
		}

		guard let handle = context.handle else {
			if pending.executing { return nil }
			return automationHostCapacityValidation(client: client, now: now)
		}

		guard
			handle.clientID == client.id,
			handle.sessionID == pending.request.sessionID,
			handle.grantRevision == client.grantRevision,
			handle.expiresAt > now,
			automationHostScopeIsPermitted(handle, client: client)
		else { return .denied }

		if let failure = automationPromotionValidation(command, handle: handle, client: client) {
			return failure
		}

		if pending.executing {
			guard handle.kind == .littleArx else { return nil }
			guard
				let little = littleWindows[id: handle.hostID],
				little.tab.id == handle.tabID,
				little.tab.profileID == handle.profileID,
				!little.isClosing,
				!little.isSwitchingProfile,
				little.peekID == nil
			else { return .staleTarget }

			return nil
		}

		guard
			automationHostIsCurrent(handle),
			automationPresentationIsCurrent(
				command,
				request: pending.request,
				snapshots: snapshots,
				now: now
			)
		else { return .staleTarget }

		return nil
	}

	private func automationHostCapacityValidation(
		client: AutomationClient,
		now: Date
	) -> AutomationFailure? {
		let live = automation.hostHandles.values.filter { handle in
			handle.expiresAt > now && automationHostIsCurrent(handle)
		}
		let owned = live.filter { $0.clientID == client.id }.count
		let isWithinLimits = owned < Self.automationHostLimitPerClient
		&& live.count < Self.automationHostLimit
		return isWithinLimits ? nil : .limitExceeded
	}

	private func automationPromotionValidation(
		_ command: AutomationCommand,
		handle: AutomationHostHandle,
		client: AutomationClient
	) -> AutomationFailure? {
		if command.action == .promoteLittleArx {
			guard
				handle.kind == .littleArx,
				let space = workspace.spaces.first(where: { $0.id.rawValue == command.targetID })
			else { return .unsupported }
			guard space.profileID == handle.profileID
			else { return .crossProfileTransferUnsupported }

			return nil
		}

		guard
			handle.kind == .peek,
			command.targetID == handle.targetID,
			let peek = peeks[id: handle.hostID],
			peek.tab.id == handle.tabID,
			peek.tab.profileID == handle.profileID,
			peek.source == handle.source
		else { return .staleTarget }

		// Only a temporary preview can become a Little Arx; a borrowed tab already has a home.
		if command.action == .promotePeekToLittleArx, !peek.isTemporary { return .unsupported }

		let entersUngrantedSpace = command.action == .promotePeekToTab
		&& peek.isTemporary
		&& !AutomationAccess.permitsSpace(peek.source.spaceID, client: client, organization: workspace)
		return entersUngrantedSpace ? .denied : nil
	}

	internal func automationHostResponseValidation(
		_ request: AutomationRequest,
		response: AutomationCommandResult,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		now: Date
	) -> AutomationFailure? {
		guard
			let receipt = automation.hostReceipts[request.id],
			receipt.request == request,
			receipt.response == response,
			receipt.grantRevision == client.grantRevision
		else { return .denied }

		if let presentation = response.presentation {
			let isCurrent = automationPresentations(for: request, snapshots: snapshots, now: now)
				.contains(presentation)
			return isCurrent ? nil : .staleTarget
		}

		guard
			let id = response.targetID,
			let tab = workspace.tabs.first(where: { $0.id.rawValue == id }),
			AutomationAccess.permitsTab(tab.id, client: client, organization: workspace)
		else { return .denied }

		return nil
	}
}

// MARK: - Handoff fences

extension AppFeature.State {
	internal mutating func completeAutomationHostTransition(
		_ hostID: UUID,
		requestID: UUID?
	) {
		guard let requestID, automation.hostTransitions[hostID] == requestID else { return }

		automation.hostTransitions[hostID] = nil
		if automation.pending[requestID] != nil { automation.hostCompletions.insert(requestID) }
	}

	internal mutating func failAutomationHostTransition(
		_ hostID: UUID,
		requestID: UUID?,
		failure: AutomationFailure
	) {
		guard let requestID, automation.hostTransitions[hostID] == requestID else { return }

		automation.hostTransitions[hostID] = nil
		if automation.pending[requestID] != nil { automation.hostFailures[requestID] = failure }
	}

	internal func automationHostCallbackIsCurrent(
		_ hostID: UUID,
		requestID: UUID?
	) -> Bool {
		// A retired MCP callback cannot fall through into ordinary UI authority.
		automation.hostTransitions[hostID] == requestID
	}

	/// Used at the existing asynchronous host-transfer commit boundaries.
	/// A canceled request loses authority; it never takes content away from its UI owner.
	internal mutating func automationAllowsHostTransition(
		_ hostID: UUID,
		requestID: UUID? = nil,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		now: Date
	) -> Bool {
		guard automationHostCallbackIsCurrent(hostID, requestID: requestID) else { return false }
		guard let requestID else { return true }

		guard
			let pending = automation.pending[requestID],
			pending.executing,
			automationValidation(pending, snapshots: snapshots, now: now) == nil
		else {
			failAutomationHostTransition(hostID, requestID: requestID, failure: .staleTarget)
			return false
		}

		return true
	}
}

extension WorkProbe.Work {
	/// A read of every tab's session for an automation check (`automationSnapshotTabIDs`).
	internal static let everyAutomationSnapshot: Self = .init("AppFeature.automationSnapshotTabIDs")
}

extension AutomationCommand.Action {
	/// Commands whose checks, execution and result read only the sessions of the tabs they
	/// name, and of hosted presentations (DEV-934). Routed, host, closing, transfer and
	/// management commands read every tab.
	internal static let readsNamedSessions: Set<Self> = [
		.openTab, .selectTab, .navigate, .reload, .back, .forward, .stop,
		.pinTab, .unpinTab, .createFolder, .renameFolder,
	]
}
