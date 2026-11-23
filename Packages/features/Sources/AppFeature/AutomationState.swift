import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import SidebarFeature
import _ComposableArchitecture

public struct AutomationState: Equatable, Sendable {
	public var signIn: AutomationSignInState
	public var isPresented: Bool
	public var socketPath: String?
	public var error: AutomationFailure?
	public var sessions: [UUID: UUID]
	public var pending: [UUID: Pending]
	internal var inspectionScopes: [UUID: InspectionScope]
	internal var releasedInspections: [ReleasedInspection]

	/// The last native find text per tab, for next/previous without text.
	internal var findInPageTexts: [BrowserCore.Tab.ID: String]
	internal var operationBindings: [OperationKey: String]
	internal var scrollOutcomes: [OperationKey: AutomationScrollResult]
	internal var scrollReceipts: [UUID: InteractionReceipt]
	internal var formOutcomes: [OperationKey: AutomationFormResult]
	internal var formReceipts: [UUID: InteractionReceipt]
	internal var clickOutcomes: [OperationKey: AutomationClickResult]
	internal var clickReceipts: [UUID: ClickReceipt]
	public var activity: [AutomationActivity]

	/// Tabs an MCP client is changing or just changed, for the page's indicator (DEV-899).
	public var presence: [BrowserCore.Tab.ID: AgentPresence]

	/// The `ARX_AGENT_TABS` feature flag, read at launch (DEV-1022).
	public var agentTabsEnabled: Bool

	/// The tabs agents opened that are still theirs, with the flag on (DEV-1022). None of it is
	/// saved: the tab keeps its client, and a relaunch starts each one's clock again.
	public var agentTabs: [BrowserCore.Tab.ID: AgentTab]

	/// Agent tabs sent to the archive, with their uses then: the app lets through as due those
	/// still tidyable and unused since, when their pages agree.
	internal var agentTabsArchiving: [BrowserCore.Tab.ID: Int]

	/// Counts changes to Settings' delay: a tidying decision taken under another one is dropped.
	internal var agentTabsPolicy: Int

	/// The tabs a client ran scripts in. Their timers and promises outlive the request, and no
	/// revision Arx sees tells a same-document navigation apart, so Stop reloads them (DEV-899).
	internal var scriptDocuments: [ScriptDocument]
	internal var hostCompletions: Set<UUID>
	internal var hostFailures: [UUID: AutomationFailure]
	internal var hostTransitions: [UUID: UUID]
	internal var hostHandles: [UUID: AutomationHostHandle]
	internal var hostReceipts: [UUID: AutomationHostReceipt]
	internal var closeReceipts: [UUID: AutomationCloseReceipt]

	/// Approved batches by connection, waiting for their steps.
	internal var batchApprovals: [UUID: BatchApproval]

	/// Tabs whose console and network logs a client started, by client. The logs
	/// themselves stay in the engine.
	internal var developerLogs: [BrowserCore.Tab.ID: UUID]

	/// Saved accounts listed for pending password sign-ins, by request (DEV-708).
	public var passwordSignIns: [UUID: PasswordSignInListing]

	/// Tabs whose document holds a filled password that didn't sign in, with that
	/// document's revision. Page reads and captures of it are refused.
	internal var passwordQuarantine: [BrowserCore.Tab.ID: UInt64]

	/// A submitted password the user can save to its tab's profile.
	public var passwordSave: BrowserPasswordSaveOffer?

	/// Cross-profile moves started by automation that committed, by request ID.
	internal var completedTransfers: Set<UUID>

	/// Agents' settled preference changes, oldest first, that `undo` can put back (DEV-1023).
	public var preferenceChanges: [PreferenceChange]
	public var usedOperations: Set<OperationKey>

	/// DEV-1009: requests that timed out on a tab whose page was then asked if it answers.
	internal var hangChecks: Set<UUID>
	public var newClientName: String

	/// Add Client's form is open (DEV-1001).
	public var isAddingClient: Bool
	public var configuration: String?

	/// An `arx setup` waiting for a person's answer.
	public var pendingAgentSetup: AgentSetup.Request?

	/// An approved setup waiting for the server to start.
	public var approvedAgentSetup: AgentSetup.Request?
	public var generation: UUID

	/// Headless runs have nobody to approve a mutation; approval fails instead of waiting.
	public var isUnattended: Bool

	/// A headless run's own client. Only it may hold a mutation grant longer than
	/// `temporaryGrantWindow`, and only while the app session is unattended.
	public var unattendedClientID: UUID?

	/// The longest temporary mutation grant, in seconds. Never above `temporaryGrantLimit`.
	public var temporaryGrantWindow: TimeInterval

	public static let temporaryGrantLimit: TimeInterval = 900

	public init() {
		self.signIn = .init()
		self.isPresented = false
		self.socketPath = nil
		self.pendingAgentSetup = nil
		self.approvedAgentSetup = nil
		self.error = nil
		self.sessions = [:]
		self.pending = [:]
		self.inspectionScopes = [:]
		self.releasedInspections = []
		self.findInPageTexts = [:]
		self.operationBindings = [:]
		self.scrollOutcomes = [:]
		self.scrollReceipts = [:]
		self.formOutcomes = [:]
		self.formReceipts = [:]
		self.clickOutcomes = [:]
		self.clickReceipts = [:]
		self.activity = []
		self.presence = [:]
		self.agentTabsEnabled = AgentTabs.isOn
		self.agentTabs = [:]
		self.agentTabsArchiving = [:]
		self.agentTabsPolicy = 0
		self.scriptDocuments = []
		self.hostCompletions = []
		self.hostFailures = [:]
		self.hostTransitions = [:]
		self.hostHandles = [:]
		self.hostReceipts = [:]
		self.closeReceipts = [:]
		self.batchApprovals = [:]
		self.developerLogs = [:]
		self.passwordSignIns = [:]
		self.passwordQuarantine = [:]
		self.passwordSave = nil
		self.completedTransfers = []
		self.preferenceChanges = []
		self.usedOperations = []
		self.hangChecks = []
		self.newClientName = ""
		self.isAddingClient = false
		self.configuration = nil
		self.generation = UUID()
		self.isUnattended = false
		self.unattendedClientID = nil
		self.temporaryGrantWindow = Self.temporaryGrantLimit
	}

	/// The expiry an updated client may keep. A headless run's own client keeps the
	/// expiry its command line chose, including `.distantFuture` for a run without
	/// `--timeout`; every other grant is capped at `temporaryGrantWindow`.
	public func mutationGrantExpiry(
		for client: AutomationClient,
		requested: Date?,
		now: Date
	) -> Date? {
		guard let requested else { return nil }
		if ownsUnattendedGrant(client.id) { return requested }
		return min(requested, now.addingTimeInterval(temporaryGrantWindow))
	}

	/// Whether `client` may mutate without asking. A grant longer than the window can
	/// only come from a headless run, so it is void outside that run, e.g. when a
	/// crashed run's persistent profile is opened interactively.
	public func mutationGrantIsActive(
		for client: AutomationClient,
		now: Date
	) -> Bool {
		guard let until = client.mutationGrantUntil, until > now else { return false }
		return ownsUnattendedGrant(client.id)
		|| until <= now.addingTimeInterval(temporaryGrantWindow)
	}

	private func ownsUnattendedGrant(_ clientID: UUID) -> Bool {
		isUnattended && unattendedClientID == clientID
	}

	/// How Settings describes a client's mutation grant.
	public enum MutationGrant: Equatable, Sendable {
		case none

		/// An interactive grant, within `temporaryGrantWindow`.
		case temporary(until: Date)

		/// A grant past the window, which only a headless run sets. `until` is its
		/// `--timeout` deadline, or nil for a run that lasts until it is stopped.
		case headlessRun(until: Date?)
	}

	public func mutationGrant(
		for client: AutomationClient,
		now: Date
	) -> MutationGrant {
		guard let until = client.mutationGrantUntil, until > now else { return .none }
		if until <= now.addingTimeInterval(temporaryGrantWindow) { return .temporary(until: until) }
		return .headlessRun(until: until >= .distantFuture ? nil : until)
	}

	/// Preferences an attended session starts with: a crashed headless run's grant
	/// past the temporary window is revoked, not just ignored, so it never looks live.
	public static func attendedPreferences(
		_ preferences: AutomationPreferences,
		now: Date,
		makeID: () -> UUID = UUID.init
	) -> AutomationPreferences {
		preferences.revokingMutationGrants(
			endingAfter: now.addingTimeInterval(temporaryGrantLimit),
			makeID: makeID
		)
	}

	internal struct InspectionScope: Equatable, Sendable {
		internal var id: UUID
		internal var clientID: UUID
		internal var grantRevision: UUID

		internal init(
			id: UUID,
			clientID: UUID,
			grantRevision: UUID
		) {
			self.id = id
			self.clientID = clientID
			self.grantRevision = grantRevision
		}
	}

	public struct Pending: Equatable, Sendable {
		public var request: AutomationRequest
		public var grantRevision: UUID
		public var approved: Bool
		public var awaitingApproval: Bool
		public var executing: Bool
		public var approvalExpiresAt: Date?
		public var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
		internal var hostContext: AutomationHostContext?
		internal var hostResultTab: BrowserCore.Tab.ID?
		internal var hostStartedAt: Date?
		internal var focusContext: TabPresentationContext?
		internal var closeRequest: AutomationCloseRequest?
		internal var interactionSource: PageInspectionSource?
		internal var waitTarget: PageWaitTarget?

		/// Set when an opted-in `openTab` was resolved by Air Traffic Control.
		internal var route: AutomationRoute?

		/// What a management command waits to observe before it reports success.
		internal var settlement: AutomationState.Settlement?
		internal var settleAttempts: Int

		/// What the press pays, sends, posts or deletes, read from the released snapshot when the
		/// request reached its approval check. It asks every time (DEV-1008).
		internal var consequence: AutomationConsequence?

		/// A batch's consequential steps, by position, for its approval prompt.
		internal var stepConsequences: [Int: AutomationConsequence]

		/// Set when an approved batch covers this step: whether the user saw that batch's prompt.
		/// A consequential step runs on a batch approval only when they did.
		internal var batchAskedUser: Bool?

		/// A preference change's keys as they were before it, recorded for `undo` once it settles
		/// (DEV-1023).
		internal var preferencesBefore: [AutomationPreferenceSetting]?

		public init(
			request: AutomationRequest,
			grantRevision: UUID,
			approved: Bool = false,
			executing: Bool = false
		) {
			self.request = request
			self.grantRevision = grantRevision
			self.approved = approved
			self.awaitingApproval = false
			self.executing = executing
			self.approvalExpiresAt = nil
			self.snapshots = [:]
			self.hostContext = nil
			self.hostResultTab = nil
			self.hostStartedAt = nil
			self.focusContext = nil
			self.closeRequest = nil
			self.interactionSource = nil
			self.waitTarget = nil
			self.route = nil
			self.settlement = nil
			self.settleAttempts = 0
			self.consequence = nil
			self.stepConsequences = [:]
			self.batchAskedUser = nil
			self.preferencesBefore = nil
		}
	}

	internal struct ScriptDocument: Equatable, Sendable {
		internal var tabID: BrowserCore.Tab.ID
		internal var clientID: UUID
	}

	public struct OperationKey: Equatable, Hashable, Sendable {
		public var clientID: UUID
		public var operationID: UUID

		public init(
			clientID: UUID,
			operationID: UUID
		) {
			self.clientID = clientID
			self.operationID = operationID
		}
	}
}

/// A tab an agent opened, while it's still the agent's (DEV-1022).
public struct AgentTab: Equatable, Sendable {
	public var clientID: UUID

	/// The connection that opened it, or last took it over. Nil for a tab from an earlier launch.
	public var sessionID: UUID?

	/// How long nothing has used it while the Mac was awake.
	public var idle: Duration

	/// Counts uses of it, the agent's and its coming on screen or leaving it (DEV-1093), so a
	/// tidying decision taken before one is dropped.
	public var uses: Int

	/// The pin and name the agent's own change left on it, through MCP, or nil when it made none.
	/// A tab the agent pinned or renamed itself stays the agent's; one the person pins or renames
	/// otherwise becomes theirs. Kept for this launch only.
	public var agentOrganization: AgentOrganization?

	public init(
		clientID: UUID,
		sessionID: UUID? = nil,
		idle: Duration = .zero,
		uses: Int = 0,
		agentOrganization: AgentOrganization? = nil
	) {
		self.clientID = clientID
		self.sessionID = sessionID
		self.idle = idle
		self.uses = uses
		self.agentOrganization = agentOrganization
	}

	/// A tab's pin and name as a change left them.
	public struct AgentOrganization: Equatable, Sendable {
		/// Neither pinned nor renamed, as an agent's new tab is.
		public static let untouched: Self = .init(savedDestination: nil, customTitle: nil)

		public var savedDestination: BrowserCore.Tab.SavedDestination?
		public var customTitle: String?

		public init(
			savedDestination: BrowserCore.Tab.SavedDestination?,
			customTitle: String?
		) {
			self.savedDestination = savedDestination
			self.customTitle = customTitle
		}

		public init(_ tab: BrowserCore.Tab) {
			self.init(savedDestination: tab.savedDestination, customTitle: tab.customTitle)
		}
	}
}

@CasePathable
public enum AutomationAction: Sendable {
	case signIn(AutomationSignInAction)
	case ui(UI)
	case event(Event)
	case delegate(Delegate)
	case observation(ObservationAction<Observation>)

	@CasePathable
	public enum UI: Sendable {
		case present(Bool)
		case enabled(Bool)
		case clientName(String)

		/// Opens Add Client's form (DEV-1001).
		case newClient

		/// Closes Add Client's form without adding.
		case cancelNewClient
		case addClient
		case approveAgentSetup
		case declineAgentSetup

		/// Issues a credential for an agent app that Arx was just added to from the app itself,
		/// where the person's click is the approval.
		case connectAgent(AgentSetup.Agent)
		case copyConfiguration
		case dismissConfiguration
		case updateClient(AutomationClient)
		case revokeClient(UUID)

		/// Stop on a page's agent indicator: ends the client's operations and pauses its grant
		/// until `resumeClient` (DEV-899).
		case stopClient(UUID)
		case resumeClient(UUID)
		case approve(UUID)
		case decline(UUID)

		/// One-way for the app session: there is no person to approve mutations.
		case unattended

		/// Marks a headless run's own client; ignored unless the session is unattended.
		case unattendedClient(UUID)

		/// Shortens `temporaryGrantWindow` for smoke tests; it can never lengthen it.
		case temporaryGrantWindow(TimeInterval)

		/// Starts listening for save offers of submitted passwords.
		case observePasswordSaves
		case answerPasswordSave(BrowserPasswordSaveAnswer)
		case passwordAccount(UUID, UInt32)
		case passwordAllowsWithoutAsking(UUID, Bool)
		case removeAgentSignInSite(AgentSignInSite)

		/// How long an agent's tab may sit unused before it's tidied (DEV-1022).
		case agentTabCleanup(AgentTabCleanup)
	}

	@CasePathable
	public enum Event: Sendable {
		case serverRequested(UUID)
		case started(UUID, Result<String, AutomationFailure>)
		case clientCreated(AutomationClient, String)
		case agentSetupRequested(AgentSetup.Request)
		case agentSetupClientCreated(AutomationClient, String, AgentSetup.Request)
		case host(AutomationHostEvent)
		case inspected(UUID, [BrowserCore.Tab.ID: BrowserSessionSnapshot])
		case finished(UUID, AutomationResult)

		/// DEV-1009: a request timed out on a tab whose page then didn't answer a ping.
		/// The document is the one the ping found frozen.
		case pageNotAnswering(UUID, BrowserCore.Tab.ID, document: UInt64?, AutomationResult)
		case waited(UUID, PageWaitObservation)
		case opened(UUID, BrowserCore.Tab)
		case closed(UUID, UUID)
		case hostProgress(UUID)
		case hostReceiptReleased(UUID)
		case closeReceiptReleased(UUID)
		case clickReceiptReleased(UUID)
		case formReceiptReleased(UUID)
		case scrollReceiptReleased(UUID)
		case managementApproved(UUID, BrowserOrganization, BrowserOrganization, [BrowserCore.Tab.ID])
		case folderDeletionApproved(UUID, BrowserOrganization, BrowserOrganization, [BrowserCore.Tab.ID])
		case managementSettled(UUID)
		case managementFailed(UUID, AutomationFailure)
		case archiveRestored(UUID, BrowserOrganization, BrowserOrganization, [BrowserCore.Tab])

		/// The ledger's queue, read once for a request that needs the downloads class.
		case downloadsRead(DownloadQueue)

		/// The download queue as the start left it, then the result.
		case downloadStarted(UUID, DownloadQueue, AutomationResult)

		/// A profile's extensions were read or changed for a request.
		case extensionsChanged(UUID, Profile.ID, AutomationResult)

		/// A profile's site permissions or zoom were read or changed for a request.
		case siteSettingsChanged(UUID, Profile.ID, AutomationResult)
		case passwordAccountsListed(UUID, Result<BrowserSavedAccounts, BrowserPasswordFailure>)
		case passwordSignInFinished(UUID, BrowserCore.Tab.ID, Result<BrowserPasswordSignInResult, BrowserPasswordFailure>)
		case passwordSaveOffered(BrowserPasswordSaveOffer)

		/// The agent tabs due for tidying, and those with something typed into a form (DEV-1022).
		case agentTabsChecked([BrowserCore.Tab.ID: Int], drafted: Set<BrowserCore.Tab.ID>, policy: Int)

		/// The person picked or kept an agent's tab: it's theirs now (DEV-1022).
		case agentTabKept(BrowserCore.Tab.ID)

		/// `openTab`'s request may take over this tab of the client's, once its profile is ready.
		case agentTabReuseReady(UUID, BrowserCore.Tab.ID)
	}

	@CasePathable
	public enum Delegate: Sendable {}

	@CasePathable
	public enum Observation: Equatable, Sendable {}
}

extension AppFeature.State {
	/// Whether a data page read moments ago may still go to the client: the request is the one it
	/// answers, and every item in it is one the client may read now, from the same profile.
	///
	/// The page itself may be behind by then. A download's progress moves its bytes and revision,
	/// a visit moves history, and engine batch 8's app smoke had a just-started download's list
	/// refused with `staleTarget` because the queue moved between the read and this check. That
	/// isn't a reason to withhold it, as any read is a moment's view; a grant that no longer
	/// covers an item, or an item that's gone, is.
	internal func automationDataPageValidation(
		_ request: AutomationDataRequest,
		page: AutomationDataPage,
		client: AutomationClient
	) -> AutomationFailure? {
		guard page.request == request else { return .staleTarget }

		let granted = Dictionary(
			automationDataItems(request.kind, client: client).map { ($0.id, $0) },
			uniquingKeysWith: { first, _ in first }
		)
		let stillGranted = page.items.allSatisfy { item in
			granted[item.id].map { $0.kind == item.kind && $0.profileID == item.profileID } == true
		}
		return stillGranted ? nil : .staleTarget
	}

	/// Rechecks a completed result at the last MainActor boundary before releasing it to IPC.
	/// The host separately checks the request's captured grant and credential revision.
	public func automationResponseValidation(
		_ request: AutomationRequest,
		result: AutomationResult,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		now: Date = Date(),
		inspectionDocumentIsCurrent: (AutomationInspectionResult) -> Bool = { _ in false },
		waitSourceIsCurrent: (PageWaitSource) -> Bool = { _ in false }
	) -> AutomationFailure? {
		guard
			automationPreferences.isEnabled,
			!shouldQuit,
			!checkingQuit
		else { return .disabled }
		let clients = automationPreferences.clients
		guard
			automation.sessions[request.sessionID] == request.clientID,
			let client = clients.first(where: { $0.id == request.clientID }),
			client.allows(request.operation.requiredCapabilities)
		else { return .denied }

		if client.isPaused { return .paused }
		if automationPrivacyIsLocked, !request.operation.isSignInStatusOrCancel {
			return .authenticationProtected
		}
		if let failure = automationPasswordQuarantine(request.operation, snapshots: snapshots) { return failure }
		if case .failure = result { return nil }
		guard automationWorkspaceIsSynchronized else { return .busy }

		switch (request.operation, result) {
		case let (.signIn(signIn), .signIn(response)):
			guard
				client.allowsSignIn,
				signIn.operationID == response.operationID,
				let record = automation.signIn.records[response.operationID],
				record.clientID == request.clientID,
				record.sessionID == request.sessionID,
				record.grantRevision == client.grantRevision,
				record.status == response.status
			else { return .denied }

			return nil

		case let (.scroll(scroll), .scroll(response)):
			return automationScrollResponseValidation(
				request,
				scroll: scroll,
				response: response,
				client: client
			)

		case let (.form(form), .form(response)):
			return automationFormResponseValidation(
				request,
				form: form,
				response: response,
				client: client
			)

		case let (.click(click), .click(response)):
			guard click.operationID == response.operationID else { return .invalidRequest }
			guard
				client.allowsPageContent,
				client.allowsPageInteraction
			else { return .denied }

			let key = AutomationState.OperationKey(
				clientID: client.id,
				operationID: click.operationID
			)
			let isRejectedBeforeAdmission = response.disposition == .notDispatched
			&& response.failure == .limitExceeded
			&& !automation.usedOperations.contains(key)
			if isRejectedBeforeAdmission {
				return nil
			}
			if response.failure == .duplicateOperation {
				let matchesRecordedOutcome = response.disposition == .possiblyDispatched
				|| (
					automation.operationBindings[key] == AutomationSecurity.mutationBinding(request.operation)
					&& automation.clickOutcomes[key]?.disposition == response.disposition
				)
				guard
					automation.usedOperations.contains(key),
					matchesRecordedOutcome
				else { return .denied }

				return nil
			}
			guard automation.clickOutcomes[key]?.disposition == response.disposition
			else { return .denied }
			if response.disposition == .notDispatched { return nil }

			guard
				let receipt = automation.clickReceipts[request.id],
				receipt.request == request,
				receipt.grantRevision == client.grantRevision,
				workspace.profiles.ids.contains(receipt.source.profileID),
				workspace.tabs[id: receipt.source.tabID]?.profileID == receipt.source.profileID,
				AutomationAccess.permitsTab(receipt.source.tabID, client: client, organization: workspace)
			else { return .denied }

			// Click-induced navigation is allowed here. This reply contains only
			// operation outcome metadata, never stale or newly navigated page content.
			return nil

		case let (.wait(wait), .wait(response)):
			let failure = automationWaitValidation(
				wait,
				client: client,
				snapshots: snapshots,
				target: response.source.target
			)
			if let failure { return failure }

			guard response.request == wait else { return .invalidRequest }
			do {
				try response.validate()
				return waitSourceIsCurrent(response.source) ? nil : .staleTarget
			} catch {
				return error as? AutomationFailure ?? .invalidRequest
			}

		case let (.inspect(inspection), .inspection(response)):
			let failure = automationInspectionValidation(
				inspection,
				client: client,
				snapshots: snapshots
			)
			if let failure { return failure }

			guard
				response.request == inspection,
				let scope = automation.inspectionScopes[request.sessionID],
				scope.clientID == client.id,
				scope.grantRevision == client.grantRevision,
				response.source.scopeID == scope.id,
				let tab = workspace.tabs.first(where: { $0.id.rawValue == inspection.targetID }),
				response.source.profileID == tab.profileID,
				let snapshot = snapshots[tab.id],
				response.source.sessionRevision == snapshot.revision,
				response.source.documentRevision == snapshot.documentRevision
			else { return .staleTarget }

			do {
				try response.validate()
				return inspectionDocumentIsCurrent(response) ? nil : .staleTarget
			} catch {
				return error as? AutomationFailure ?? .invalidRequest
			}

		case let (.capture(capture), .capture(response)):
			let failure = automationCaptureValidation(
				capture,
				client: client,
				snapshots: snapshots
			)
			if let failure { return failure }

			guard
				response.request == capture,
				let tab = workspace.tabs.first(where: { $0.id.rawValue == capture.targetID }),
				response.profileID == tab.profileID,
				let snapshot = snapshots[tab.id],
				response.sessionRevision == snapshot.revision,
				response.documentRevision == snapshot.documentRevision
			else { return .staleTarget }

			do {
				try response.validate()
				return nil
			} catch {
				return error as? AutomationFailure ?? .invalidRequest
			}

		case let (.inventory(cursor, limit), .inventory(inventory)):
			let items = automationTabWindows(AutomationInventoryBuilder.items(
				client: client,
				organization: workspace,
				snapshots: snapshots
			))
			do {
				var current = try AutomationInventoryBuilder.page(items, cursor: cursor, limit: limit)
				current.presentations = automationPresentations(for: request, snapshots: snapshots, now: now)
				current.profiles = AutomationInventoryBuilder.profiles(client: client, organization: workspace, items: items)
				current.windows = automationWindows(for: client)
				current.chromeAppearance = settings.chromeAppearance
				return current == inventory ? nil : .staleTarget
			} catch {
				return error as? AutomationFailure ?? .invalidRequest
			}

		case let (.data(data), .data(page)):
			return automationDataPageValidation(data, page: page, client: client)

		case let (.link(link), .link(response)):
			guard case let .success(current) = automationLink(link) else { return .invalidRequest }
			return current == response ? nil : .staleTarget

		case let (.load(load), .load(response)):
			return automationLoadResponseValidation(load, response: response, client: client)

		case let (.pdf(pdf), .pdf(response)):
			return automationPDFResponseValidation(
				pdf,
				response: response,
				client: client,
				snapshots: snapshots
			)

		case let (.findInPage(find), .findInPage(response)):
			return automationFindInPageResponseValidation(
				find,
				response: response,
				client: client,
				snapshots: snapshots
			)

		case let (.dialog(dialog), .dialog(response)):
			return automationDialogResponseValidation(
				dialog,
				response: response,
				client: client,
				snapshots: snapshots
			)

		case let (.settings(settingsRequest), .settings(response)):
			return automationSettingsResponseValidation(settingsRequest, response: response, client: client)

		case let (.script(script), .script(response)):
			return automationScriptResponseValidation(script, response: response, client: client)

		case let (.logs(logs), .logs(response)):
			return automationLogResponseValidation(logs, response: response, client: client, snapshots: snapshots)

		case let (.passwordSignIn(passwordSignIn), .passwordSignIn(response)):
			// An outcome only; the page itself is past the request's revision.
			guard passwordSignIn.operationID == response.operationID else { return .invalidRequest }
			return client.allowsSignIn ? nil : .denied

		case let (.media(media), .media(response)):
			return automationMediaResponseValidation(
				media,
				response: response,
				client: client,
				snapshots: snapshots
			)

		case let (.batch(plan), .batch(approval)):
			guard
				approval.batchID == plan.batchID,
				let recorded = automation.batchApprovals[request.sessionID],
				recorded.batchID == plan.batchID,
				recorded.grantRevision == client.grantRevision,
				recorded.bindings.count == approval.approvedSteps,
				// Collected late (DEV-1024), an approval that already lapsed reports none.
				recorded.expiresAt > now
			else { return approval.approvedSteps == 0 && approval.batchID == plan.batchID ? nil : .denied }

			return nil

		case let (.command(command), .command(response)):
			guard
				client.allowsManagement || command.action.capability == .downloads,
				command.operationID == response.operationID
			else { return .denied }

			if command.action == .startDownload {
				// The new transfer, in the granted profile the request named.
				guard
					response.item == nil,
					let targetID = response.targetID,
					automationDataItems(.downloads, client: client)
						.contains(where: { $0.id == targetID && $0.profileID == command.targetID })
				else { return .denied }

				return nil
			}

			if command.action.isHostOperation {
				return automationHostResponseValidation(
					request,
					response: response,
					client: client,
					snapshots: snapshots,
					now: now
				)
			}

			if command.action == .closeTab || command.action == .removeSavedEntry {
				guard let receipt = automation.closeReceipts[request.id] else { return .denied }
				return receipt.validation(
					request: request,
					response: response,
					client: client,
					snapshots: snapshots,
					state: self
				)
			}

			func item(
				_ id: UUID,
				kind: AutomationInventoryItem.Kind? = nil
			) -> AutomationInventoryItem? {
				AutomationInventoryBuilder.item(id, kind: kind, client: client, organization: workspace, snapshots: snapshots)
			}
			if let targetID = response.targetID, item(targetID) == nil {
				return .denied
			}
			if let listed = response.item, item(listed.id, kind: listed.kind) != listed { return .staleTarget }
			return nil

		default:
			return .invalidRequest
		}
	}

	/// DEV-1009: whether a request that timed out may still have its tab's frozen renderer
	/// ended. Its client, session, grant and access to the tab, as now; not the revision, which
	/// the hang report itself moved on.
	internal func automationMayRecover(
		_ requestID: UUID,
		tabID: BrowserCore.Tab.ID
	) -> Bool {
		guard
			let pending = automation.pending[requestID],
			automationPreferences.isEnabled,
			!shouldQuit,
			!checkingQuit,
			!automationPrivacyIsLocked,
			automation.sessions[pending.request.sessionID] == pending.request.clientID,
			let client = automationPreferences.clients.first(where: { $0.id == pending.request.clientID }),
			client.grantRevision == pending.grantRevision,
			!client.isPaused
		else { return false }

		return AutomationAccess.permitsTab(tabID, client: client, organization: workspace)
	}

	public func automationCanExecute(
		_ requestID: UUID,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		now: Date
	) -> Bool {
		guard
			let pending = automation.pending[requestID],
			pending.executing
		else { return false }
		if pending.request.operation.mutationID != nil, !pending.approved { return false }

		return automationValidation(pending, snapshots: snapshots, now: now) == nil
	}

	internal func automationValidation(
		_ pending: AutomationState.Pending,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		now: Date
	) -> AutomationFailure? {
		if let expiration = pending.approvalExpiresAt, expiration <= now { return .denied }
		guard
			automationPreferences.isEnabled,
			!shouldQuit,
			!checkingQuit
		else { return .disabled }
		let clients = automationPreferences.clients
		guard
			automation.sessions[pending.request.sessionID] == pending.request.clientID,
			let client = clients.first(where: { $0.id == pending.request.clientID }),
			client.grantRevision == pending.grantRevision,
			client.allows(pending.request.operation.requiredCapabilities)
		else { return .denied }

		if client.isPaused { return .paused }
		if automationPrivacyIsLocked, !pending.request.operation.isSignInStatusOrCancel {
			return .authenticationProtected
		}
		if let failure = automationPasswordQuarantine(pending.request.operation, snapshots: snapshots) {
			return failure
		}
		if case let .signIn(request) = pending.request.operation {
			return automationSignInValidation(request, client: client, snapshots: snapshots)
		}

		// Window edits publish asynchronously. Do not authorize against a stale canonical copy.
		guard automationWorkspaceIsSynchronized else { return .busy }
		if case let .scroll(request) = pending.request.operation {
			do {
				try request.validate()
			} catch {
				return error as? AutomationFailure ?? .invalidRequest
			}

			return automationClickValidation(
				request.target,
				pending: pending,
				client: client,
				snapshots: snapshots,
				now: now
			)
		}
		if case let .form(request) = pending.request.operation {
			do {
				try request.validate()
			} catch {
				return error as? AutomationFailure ?? .invalidRequest
			}

			return automationClickValidation(
				request.target,
				pending: pending,
				client: client,
				snapshots: snapshots,
				now: now,
				targetsViewport: request.targetsViewport,
				destinationReference: request.pointer?.destinationReference
			)
		}
		if case let .click(request) = pending.request.operation {
			return automationClickValidation(
				request,
				pending: pending,
				client: client,
				snapshots: snapshots,
				now: now
			)
		}
		if case let .wait(request) = pending.request.operation {
			return automationWaitValidation(
				request,
				client: client,
				snapshots: snapshots,
				target: pending.waitTarget
			)
		}
		if case let .inspect(request) = pending.request.operation {
			return automationInspectionValidation(request, client: client, snapshots: snapshots)
		}
		if case let .capture(request) = pending.request.operation {
			return automationCaptureValidation(request, client: client, snapshots: snapshots)
		}
		if case let .load(request) = pending.request.operation {
			return automationLoadValidation(request, client: client, snapshots: snapshots)
		}
		if case let .pdf(request) = pending.request.operation {
			return automationPDFValidation(request, client: client, snapshots: snapshots)
		}
		if case let .findInPage(request) = pending.request.operation {
			return automationFindInPageValidation(request, client: client, snapshots: snapshots)
		}
		if case let .dialog(request) = pending.request.operation {
			return automationDialogValidation(request, client: client, snapshots: snapshots)
		}
		if case let .media(request) = pending.request.operation {
			return automationMediaValidation(request, client: client, snapshots: snapshots)
		}
		if case let .script(request) = pending.request.operation {
			return automationScriptValidation(request, client: client, snapshots: snapshots)
		}
		if case let .logs(request) = pending.request.operation {
			return automationLogValidation(request, client: client, snapshots: snapshots)
		}
		if case let .passwordSignIn(request) = pending.request.operation {
			// Once filling started, the page may navigate; the engine binds the document.
			if pending.executing { return nil }
			return automationPasswordSignInValidation(request, client: client, snapshots: snapshots)
		}
		if case let .batch(plan) = pending.request.operation {
			return automationBatchValidation(plan, client: client, snapshots: snapshots)
		}
		if case let .settings(request) = pending.request.operation {
			// A change already running is judged by its settlement; Settings has begun to change.
			if pending.settlement != nil { return nil }
			return automationSettingsValidation(request, client: client)
		}
		guard case let .command(command) = pending.request.operation
		else { return nil }

		// Download actions need only their own class; requiredCapabilities already checked it.
		guard client.allowsManagement || command.action.capability == .downloads
		else { return .denied }

		func isBusy(_ host: MainFeature.State) -> Bool {
			var closes = host.pendingTabCloses
			let ownedClose = pending.closeRequest.flatMap { source in
				host.automationCloseRequests[source.tab.id] == source.token ? source.tab.id : nil
			}
			if let ownedClose {
				closes.remove(ownedClose)
			}

			return host.transferInProgress
			|| host.isClosing
			|| host.archive.isWorking
			|| host.pendingFolderDeletion != nil
			|| !closes.isEmpty
		}
		let littleWindowIsBusy = littleWindows.contains { little in
			little.isSwitchingProfile
			|| (little.isPromoting && little.id != pending.hostContext?.handle?.hostID)
		}
		guard
			peeks.isEmpty || command.action.isHostOperation,
			!settings.isManagingOrganization,
			!isBusy(main),
			!windows.contains(where: isBusy),
			!littleWindowIsBusy
		else { return .busy }

		if let source = pending.closeRequest, !source.matches(self) { return .staleTarget }

		guard AutomationCommand.Action.supported.contains(command.action)
		else { return .unsupported }

		do {
			try command.validate()
		} catch {
			return .invalidRequest
		}

		if command.action.targetKind == .window {
			return automationWindowValidation(command, client: client)
		}
		if command.action.targetKind == .archived || command.action.targetKind == .download {
			return automationDataTargetValidation(command, client: client)
		}

		// Only the items the command names are derived and checked, not the whole inventory.
		func item(_ id: UUID) -> AutomationInventoryItem? {
			AutomationInventoryBuilder.item(id, client: client, organization: workspace, snapshots: snapshots)
		}
		guard let target = item(command.targetID)
		else { return .denied }
		guard target.revision == command.expectedRevision
		else { return .staleTarget }

		if let destinationID = command.destinationID {
			guard let destination = item(destinationID)
			else { return .denied }
			guard destination.revision == command.destinationRevision
			else { return .staleTarget }

			// Tabs reopen in another profile and spaces reorder across profiles; nothing else crosses.
			let crossesProfiles = destination.profileID != target.profileID
			guard !crossesProfiles || [.moveTab, .moveSpace].contains(command.action)
			else { return .crossProfileTransferUnsupported }
		}

		guard target.kind == command.action.targetKind else { return .invalidRequest }

		// openTab's window: the main window, or another ordinary window the client sees (DEV-1157).
		if let windowID = command.windowID, windowID != main.id {
			guard automationWindows(for: client).contains(where: { $0.id == windowID }) else { return .denied }
		}
		if let splitTabs = command.splitTabs {
			// Every member is a granted tab at its listed revision that can share a split in the
			// target's space: any tab of the profile, which moves into the target's list beside it,
			// or a Favorite of the profile, which joins from the grid (DEV-1006). The target names
			// the split's space and list, so it can't be a Favorite.
			let spaceID: Space.ID
			switch workspace.location(of: .init(rawValue: command.targetID)) {
			case let .unpinned(id), let .pinned(id, _): spaceID = id
			case .favorite, nil: return .invalidRequest
			}
			for tab in splitTabs {
				guard let item = item(tab.id) else { return .denied }
				guard item.revision == tab.revision else { return .staleTarget }
				guard item.kind == .tab, workspace.canJoinSplit(.init(rawValue: tab.id), in: spaceID)
				else { return .invalidRequest }
			}
		}
		if command.action.isHostOperation {
			return automationHostValidation(
				pending,
				command: command,
				client: client,
				snapshots: snapshots,
				now: now
			)
		}
		if command.action == .moveFolder {
			return automationFolderMoveValidation(command, client: client)
		}
		return nil
	}

	internal var automationWorkspaceIsSynchronized: Bool {
		workspace.matchesIgnoringSelection(main.sidebar.organization)
		&& windows
			.filter { !$0.isPrivate }
			.allSatisfy { workspace.matchesIgnoringSelection($0.sidebar.organization) }
	}
}

extension BrowserOrganization {
	/// Whether two copies differ only in each space's selected tab. Selection belongs to each
	/// window and is not an ownership or permission change. Compares in place instead of
	/// copying both organizations; `automationSynchronizationComparesEveryOrganizationField`
	/// fails when a new stored property needs a line here.
	internal func matchesIgnoringSelection(_ other: Self) -> Bool {
		guard
			legacyProfileID == other.legacyProfileID,
			retiredProfileIDs == other.retiredProfileIDs,
			profiles == other.profiles,
			folders == other.folders,
			tabs == other.tabs,
			archive == other.archive,
			splits == other.splits,
			tabGroups == other.tabGroups,
			spaces.count == other.spaces.count
		else { return false }

		return zip(spaces, other.spaces).allSatisfy { space, otherSpace in
			guard space.selectedTabID != otherSpace.selectedTabID else { return space == otherSpace }

			var unselected = otherSpace
			unselected.selectedTabID = space.selectedTabID
			return space == unselected
		}
	}
}

extension AutomationState {
	/// What an agent's `setPreferences` changed, so `undo` can put it back while nothing has
	/// changed those preferences since (DEV-1023).
	public struct PreferenceChange: Equatable, Sendable {
		public var operationID: UUID
		public var clientID: UUID

		/// Each changed preference as it was before.
		public var before: [AutomationPreferenceSetting]

		/// Each changed preference as the change left it.
		public var after: [AutomationPreferenceSetting]

		public init(
			operationID: UUID,
			clientID: UUID,
			before: [AutomationPreferenceSetting],
			after: [AutomationPreferenceSetting]
		) {
			self.operationID = operationID
			self.clientID = clientID
			self.before = before
			self.after = after
		}
	}

	/// How many changes `undo` can reach.
	public static let preferenceChangeLimit: Int = 32

	/// The client's own change with this operation ID: operation IDs are unique per client only.
	public func preferenceChange(
		_ operationID: String,
		clientID: UUID
	) -> PreferenceChange? {
		guard let id = UUID(uuidString: operationID) else { return nil }
		return preferenceChanges.last { $0.operationID == id && $0.clientID == clientID }
	}
}
