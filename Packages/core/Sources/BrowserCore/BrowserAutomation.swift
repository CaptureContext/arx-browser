import Foundation

public struct AutomationPreferences: Codable, Equatable, Sendable {
	public var isEnabled: Bool
	public var clients: [AutomationClient]
	public var authenticationLockID: UUID?
	public var authenticationTransitionID: UUID?

	/// Sites where the user let agents sign in with a saved password without
	/// asking (DEV-708), per profile. Off for every site until the user allows it.
	public var agentSignInSites: [AgentSignInSite]

	/// The automation client each profile's built-in assistant uses (DEV-720). It's an
	/// ordinary client in `clients`, scoped to that profile, so the assistant gets the same
	/// checks as any outside agent. Its credential lives only in memory for one run.
	public var assistantClients: [AssistantAutomationClient]

	/// How long an agent's tab may sit unused before it's tidied (DEV-1022).
	public var agentTabCleanup: AgentTabCleanup

	public init(
		isEnabled: Bool = false,
		clients: [AutomationClient] = [],
		authenticationLockID: UUID? = nil,
		authenticationTransitionID: UUID? = nil,
		agentSignInSites: [AgentSignInSite] = [],
		assistantClients: [AssistantAutomationClient] = [],
		agentTabCleanup: AgentTabCleanup = .default
	) {
		self.isEnabled = isEnabled
		self.clients = clients
		self.authenticationLockID = authenticationLockID
		self.authenticationTransitionID = authenticationTransitionID
		self.agentSignInSites = agentSignInSites
		self.assistantClients = assistantClients
		self.agentTabCleanup = agentTabCleanup
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			isEnabled: try values.decode(Bool.self, forKey: .isEnabled),
			clients: try values.decode([AutomationClient].self, forKey: .clients),
			authenticationLockID: try values.decodeIfPresent(UUID.self, forKey: .authenticationLockID),
			authenticationTransitionID: try values.decodeIfPresent(UUID.self, forKey: .authenticationTransitionID),
			agentSignInSites: try values.decodeIfPresent([AgentSignInSite].self, forKey: .agentSignInSites) ?? [],
			assistantClients: try values.decodeIfPresent([AssistantAutomationClient].self, forKey: .assistantClients) ?? [],
			// An unknown value, from a later version, falls back to the default.
			agentTabCleanup: (try? values.decodeIfPresent(AgentTabCleanup.self, forKey: .agentTabCleanup)) ?? .default
		)
	}

	private enum CodingKeys: String, CodingKey {
		case isEnabled, clients, authenticationLockID, authenticationTransitionID, agentSignInSites, assistantClients
		case agentTabCleanup
	}

	/// The client of the profile's built-in assistant, while it's still registered.
	public func assistantClient(for profileID: Profile.ID) -> AutomationClient? {
		guard let entry = assistantClients.first(where: { $0.profileID == profileID })
		else { return nil }

		return clients.first { $0.id == entry.clientID }
	}

	public func allowsAgentSignIn(
		profileID: Profile.ID,
		origin: String
	) -> Bool {
		agentSignInSites.contains(.init(profileID: profileID, origin: origin))
	}

	/// Recovery cannot revive capabilities from an older security snapshot.
	public func revokingGrants(makeID: () -> UUID = UUID.init) -> Self {
		var preferences = self
		for index in preferences.clients.indices {
			preferences.clients[index].scopes.removeAll()
			preferences.clients[index].capabilities.removeAll()
			preferences.clients[index].approvalPolicy = .alwaysAsk
			preferences.clients[index].allowsFocusedTab = false
			preferences.clients[index].mutationGrantUntil = nil
			preferences.clients[index].grantRevision = makeID()
		}
		return preferences
	}

	/// Clears every mutation grant that lasts past `latest`, leaving the client's other
	/// capabilities alone. Only a headless run's own client can hold such a grant, for
	/// its run; an attended session drops one that a crashed run left behind.
	public func revokingMutationGrants(
		endingAfter latest: Date,
		makeID: () -> UUID = UUID.init
	) -> Self {
		var preferences = self
		for index in preferences.clients.indices {
			guard let until = preferences.clients[index].mutationGrantUntil, until > latest
			else { continue }
			preferences.clients[index].mutationGrantUntil = nil
			preferences.clients[index].grantRevision = makeID()
		}
		return preferences
	}

	public func validate() throws {
		guard
			clients.count <= 32,
			Set(clients.map(\.id)).count == clients.count
		else { throw AutomationFailure.invalidRequest }

		guard
			assistantClients.count <= 32,
			Set(assistantClients.map(\.profileID)).count == assistantClients.count
		else { throw AutomationFailure.invalidRequest }

		guard
			agentSignInSites.count <= 512,
			agentSignInSites.allSatisfy({ AutomationSignInRequest.canonicalOrigin($0.origin) == $0.origin })
		else { throw AutomationFailure.invalidRequest }

		for client in clients {
			guard
				!client.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
				client.name.count <= 80,
				client.credentialDigest.count == 64,
				client.credentialDigest.allSatisfy({ $0.isHexDigit }),
				client.scopes.count <= 128
			else { throw AutomationFailure.invalidRequest }
		}
	}
}

public struct AutomationClient: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var name: String
	public var credentialDigest: String
	public var scopes: [AutomationScope]
	public var capabilities: Set<AutomationCapability>
	public var approvalPolicy: AutomationApprovalPolicy

	/// Lets the client pass `focused` instead of a tab, resolved by Arx when the tool runs.
	public var allowsFocusedTab: Bool
	public var mutationGrantUntil: Date?
	public var grantRevision: UUID

	/// Set by Stop on the page's agent indicator (DEV-899): every request fails with `paused`
	/// until the user resumes the client in Settings. The grant itself is kept.
	public var isPaused: Bool

	public init(
		id: UUID,
		name: String,
		credentialDigest: String,
		scopes: [AutomationScope] = [],
		capabilities: Set<AutomationCapability>,
		approvalPolicy: AutomationApprovalPolicy = .alwaysAsk,
		allowsFocusedTab: Bool = false,
		mutationGrantUntil: Date? = nil,
		grantRevision: UUID,
		isPaused: Bool = false
	) {
		self.id = id
		self.name = name
		self.credentialDigest = credentialDigest
		self.scopes = scopes
		self.capabilities = capabilities
		self.approvalPolicy = approvalPolicy
		self.allowsFocusedTab = allowsFocusedTab
		self.mutationGrantUntil = mutationGrantUntil
		self.grantRevision = grantRevision
		self.isPaused = isPaused
	}

	public init(
		id: UUID,
		name: String,
		credentialDigest: String,
		scopes: [AutomationScope] = [],
		allowsRead: Bool = false,
		allowsScreenshots: Bool = false,
		allowsPageContent: Bool = false,
		allowsPageInteraction: Bool = false,
		allowsSignIn: Bool = false,
		allowsManagement: Bool = false,
		mutationGrantUntil: Date? = nil,
		grantRevision: UUID
	) {
		self.init(
			id: id,
			name: name,
			credentialDigest: credentialDigest,
			scopes: scopes,
			capabilities: Self.capabilities(
				read: allowsRead,
				screenshots: allowsScreenshots,
				pageContent: allowsPageContent,
				interact: allowsPageInteraction,
				signIn: allowsSignIn,
				organize: allowsManagement
			),
			mutationGrantUntil: mutationGrantUntil,
			grantRevision: grantRevision
		)
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		let capabilities: Set<AutomationCapability>
		if let stored = try values.decodeIfPresent(Set<AutomationCapability>.self, forKey: .capabilities) {
			capabilities = stored

		} else {
			// Grants saved before capability classes. Page interaction used to need the
			// management toggle too, so it migrates only when both were on.
			let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
			let allowsManagement = try legacy.decode(Bool.self, forKey: .allowsManagement)
			let allowsPageInteraction = try legacy.decodeIfPresent(Bool.self, forKey: .allowsPageInteraction) ?? false
			capabilities = Self.capabilities(
				read: try legacy.decode(Bool.self, forKey: .allowsRead),
				screenshots: try legacy.decodeIfPresent(Bool.self, forKey: .allowsScreenshots) ?? false,
				pageContent: try legacy.decodeIfPresent(Bool.self, forKey: .allowsPageContent) ?? false,
				interact: allowsPageInteraction && allowsManagement,
				signIn: try legacy.decodeIfPresent(Bool.self, forKey: .allowsSignIn) ?? false,
				organize: allowsManagement
			)
		}

		self.init(
			id: try values.decode(UUID.self, forKey: .id),
			name: try values.decode(String.self, forKey: .name),
			credentialDigest: try values.decode(String.self, forKey: .credentialDigest),
			scopes: try values.decode([AutomationScope].self, forKey: .scopes),
			capabilities: capabilities,
			approvalPolicy: try values.decodeIfPresent(AutomationApprovalPolicy.self, forKey: .approvalPolicy) ?? .alwaysAsk,
			allowsFocusedTab: try values.decodeIfPresent(Bool.self, forKey: .allowsFocusedTab) ?? false,
			mutationGrantUntil: try values.decodeIfPresent(Date.self, forKey: .mutationGrantUntil),
			grantRevision: try values.decode(UUID.self, forKey: .grantRevision),
			isPaused: try values.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
		)
	}

	public func encode(to encoder: any Encoder) throws {
		var values = encoder.container(keyedBy: CodingKeys.self)
		try values.encode(id, forKey: .id)
		try values.encode(name, forKey: .name)
		try values.encode(credentialDigest, forKey: .credentialDigest)
		try values.encode(scopes, forKey: .scopes)
		try values.encode(capabilities.sorted(), forKey: .capabilities)
		try values.encode(approvalPolicy, forKey: .approvalPolicy)
		try values.encode(allowsFocusedTab, forKey: .allowsFocusedTab)
		try values.encodeIfPresent(mutationGrantUntil, forKey: .mutationGrantUntil)
		try values.encode(grantRevision, forKey: .grantRevision)

		// Written only while paused, so saved grants of running clients stay as they were.
		if isPaused { try values.encode(isPaused, forKey: .isPaused) }
	}

	public var allowsRead: Bool {
		get { capabilities.contains(.read) }
		set { set(.read, newValue) }
	}

	public var allowsScreenshots: Bool {
		get { capabilities.contains(.screenshots) }
		set { set(.screenshots, newValue) }
	}

	public var allowsPageContent: Bool {
		get { capabilities.contains(.pageContent) }
		set { set(.pageContent, newValue) }
	}

	public var allowsPageInteraction: Bool {
		get { capabilities.contains(.interact) }
		set { set(.interact, newValue) }
	}

	public var allowsSignIn: Bool {
		get { capabilities.contains(.signIn) }
		set { set(.signIn, newValue) }
	}

	/// The organize class: opening, moving, pinning, closing and renaming.
	public var allowsManagement: Bool {
		get { capabilities.contains(.organize) }
		set { set(.organize, newValue) }
	}

	public func allows(_ required: Set<AutomationCapability>) -> Bool {
		required.isSubset(of: capabilities)
	}

	/// Whether `operation` may run without asking, from the standing policy alone. A press
	/// with a `consequence` is consequential and always asks (DEV-1008).
	public func skipsApproval(
		for operation: AutomationOperation,
		consequence: AutomationConsequence? = nil
	) -> Bool {
		approvalPolicy.skipsApproval(for: consequence == nil ? operation.riskTier : .consequential)
	}

	private mutating func set(
		_ capability: AutomationCapability,
		_ isGranted: Bool
	) {
		if isGranted {
			capabilities.insert(capability)
		} else {
			capabilities.remove(capability)
		}
	}

	private static func capabilities(
		read: Bool,
		screenshots: Bool,
		pageContent: Bool,
		interact: Bool,
		signIn: Bool,
		organize: Bool
	) -> Set<AutomationCapability> {
		let pairs: [(Bool, AutomationCapability)] = [
			(read, .read),
			(screenshots, .screenshots),
			(pageContent, .pageContent),
			(interact, .interact),
			(signIn, .signIn),
			(organize, .organize),
		]
		return Set(pairs.filter(\.0).map(\.1))
	}

	private enum CodingKeys: String, CodingKey {
		case id, name, credentialDigest, scopes, capabilities, approvalPolicy, allowsFocusedTab
		case mutationGrantUntil, grantRevision, isPaused
	}

	private enum LegacyCodingKeys: String, CodingKey {
		case allowsRead, allowsScreenshots, allowsPageContent, allowsPageInteraction, allowsSignIn, allowsManagement
	}
}

public enum AutomationScope: Codable, Equatable, Hashable, Sendable {
	/// Every space, folder, tab and Favorite in the profile, including ones created later.
	case profile(Profile.ID)
	case space(Space.ID, profileID: Profile.ID)
	case tab(Tab.ID, profileID: Profile.ID, location: AutomationTabLocation)
}

public enum AutomationTabLocation: Codable, Equatable, Hashable, Sendable {
	case space(Space.ID)
	case favorites

	/// The grant-facing location of a tab: its space, pinned or not, or the profile's Favorites.
	public init(_ location: BrowserOrganization.TabLocation) {
		switch location {
		case let .unpinned(id), let .pinned(id, _): self = .space(id)
		case .favorite: self = .favorites
		}
	}
}

public struct AutomationCommand: Codable, Equatable, Sendable {
	public var operationID: UUID
	public var action: Action
	public var targetID: UUID
	public var expectedRevision: String
	public var destinationID: UUID?
	public var destinationRevision: String?
	public var url: URL?
	public var name: String?
	public var focus: Bool

	/// Opt-in for `openTab`: apply the user's Air Traffic Control rules instead of
	/// opening in `targetID`, which then only names the source space for
	/// current-space rules and the fallback.
	public var route: Bool
	public var sourceTabID: UUID?
	public var sourceRevision: String?
	public var presentationID: UUID?
	public var presentationRevision: String?

	/// `createSpace` and `renameSpace`: a symbol name or a single emoji.
	public var icon: String?

	/// `setSpaceTheme`: `light`, `dark` or `system` to follow the profile.
	public var theme: String?

	/// `setSpaceAppearance` and `setProfileAppearance`: the override fields to choose or inherit.
	public var appearance: AutomationAppearanceChange?

	/// `openSplit`: one to three more tabs, shown with the target as a Split View of two to four
	/// panes, in this order after it. A pinned one, or an open tab of another space of the
	/// profile, becomes an open tab of the target's space (DEV-992); a Favorite is refused.
	public var splitTabs: [AutomationSplitTab]?

	/// `openSplit` with `splitTabs`: side by side (`horizontal`, the default) or stacked.
	public var orientation: BrowserSpacePresentation.Orientation?

	/// `openTab`: the window that keeps the new tab, an ordinary window from
	/// `AutomationInventory.windows`; the main window when absent (DEV-1157).
	public var windowID: UUID?

	public init(
		operationID: UUID,
		action: Action,
		targetID: UUID,
		expectedRevision: String,
		destinationID: UUID? = nil,
		destinationRevision: String? = nil,
		url: URL? = nil,
		name: String? = nil,
		focus: Bool = false,
		route: Bool = false,
		sourceTabID: UUID? = nil,
		sourceRevision: String? = nil,
		presentationID: UUID? = nil,
		presentationRevision: String? = nil,
		icon: String? = nil,
		theme: String? = nil,
		appearance: AutomationAppearanceChange? = nil,
		splitTabs: [AutomationSplitTab]? = nil,
		orientation: BrowserSpacePresentation.Orientation? = nil,
		windowID: UUID? = nil
	) {
		self.operationID = operationID
		self.action = action
		self.targetID = targetID
		self.expectedRevision = expectedRevision
		self.destinationID = destinationID
		self.destinationRevision = destinationRevision
		self.url = url
		self.name = name
		self.focus = focus
		self.route = route
		self.sourceTabID = sourceTabID
		self.sourceRevision = sourceRevision
		self.presentationID = presentationID
		self.presentationRevision = presentationRevision
		self.icon = icon
		self.theme = theme
		self.appearance = appearance
		self.splitTabs = splitTabs
		self.orientation = orientation
		self.windowID = windowID
	}

	public func validate() throws {
		guard
			expectedRevision.count == 64,
			expectedRevision.allSatisfy(\.isHexDigit)
		else { throw AutomationFailure.invalidRequest }

		if let url {
			guard
				url.absoluteString.utf8.count <= 4096,
				let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
				["http", "https"].contains(components.scheme?.lowercased() ?? ""),
				components.host != nil,
				components.user == nil,
				components.password == nil
			else { throw AutomationFailure.invalidRequest }
		}

		if let name, name.utf8.count > 256 {
			throw AutomationFailure.invalidRequest
		}

		let isMissingURL = [.openTab, .navigate, .openLittleArx, .startDownload].contains(action) && url == nil
		if isMissingURL { throw AutomationFailure.invalidRequest }

		if let icon {
			guard action == .createSpace || action == .renameSpace, (1...64).contains(icon.utf8.count)
			else { throw AutomationFailure.invalidRequest }
		}
		if let theme {
			guard action == .setSpaceTheme, ["light", "dark", "system"].contains(theme)
			else { throw AutomationFailure.invalidRequest }
		} else if action == .setSpaceTheme {
			throw AutomationFailure.invalidRequest
		}
		if action == .renameSpace, name == nil, icon == nil { throw AutomationFailure.invalidRequest }
		if let splitTabs {
			let ids = splitTabs.map(\.id)
			guard
				action == .openSplit,
				(1 ... SplitLayout.maximumPanes - 1).contains(splitTabs.count),
				splitTabs.allSatisfy({ $0.revision.count == 64 && $0.revision.allSatisfy(\.isHexDigit) }),
				Set(ids).count == ids.count,
				!ids.contains(targetID)
			else { throw AutomationFailure.invalidRequest }
		}
		if orientation != nil, action != .openSplit || splitTabs == nil { throw AutomationFailure.invalidRequest }
		let setsAppearance = action == .setSpaceAppearance || action == .setProfileAppearance
		if let appearance {
			guard setsAppearance else { throw AutomationFailure.invalidRequest }
			try appearance.validate()
		} else if setsAppearance {
			throw AutomationFailure.invalidRequest
		}

		let namesRequired: Set<Action> = [.createFolder, .renameFolder, .createProfile, .renameProfile, .createSpace]
		let isMissingFolderName = namesRequired.contains(action)
		&& name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false

		if isMissingFolderName { throw AutomationFailure.invalidRequest }

		let isMissingDestination = [.moveTab, .moveFolder, .pinTab, .unpinTab, .removeFavorite].contains(action)
		&& (destinationID == nil || destinationRevision?.count != 64)

		if isMissingDestination { throw AutomationFailure.invalidRequest }

		// Optional destinations still come with their revision.
		if destinationID != nil, destinationRevision?.count != 64 { throw AutomationFailure.invalidRequest }

		// A window keeps only a tab openTab opens where it says, so never a routed one.
		if windowID != nil, action != .openTab || route { throw AutomationFailure.invalidRequest }

		// Routing chooses the destination itself, so it never combines with an explicit one.
		if route {
			guard action == .openTab, destinationID == nil, destinationRevision == nil
			else { throw AutomationFailure.invalidRequest }
		}

		let hasHostFields = sourceTabID != nil
		|| sourceRevision != nil
		|| presentationID != nil
		|| presentationRevision != nil

		if action.isHostOperation {
			guard focus else { throw AutomationFailure.unsupported }
			guard name == nil, destinationID == nil, destinationRevision == nil
			else { throw AutomationFailure.invalidRequest }

			if action == .openPeek {
				guard
					sourceTabID != nil,
					sourceRevision?.count == 64,
					presentationID == nil,
					presentationRevision == nil
				else { throw AutomationFailure.invalidRequest }

			} else if action == .openLittleArx {
				guard
					sourceTabID == nil,
					sourceRevision == nil,
					presentationID == nil,
					presentationRevision == nil
				else { throw AutomationFailure.invalidRequest }

			} else {
				guard
					presentationID != nil,
					presentationRevision?.count == 64,
					sourceTabID == nil,
					sourceRevision == nil,
					url == nil
				else { throw AutomationFailure.invalidRequest }
			}

		} else if hasHostFields {
			throw AutomationFailure.invalidRequest
		}
	}

	public enum Action: String, Codable, CaseIterable, Sendable {
		case openTab
		case selectTab
		case navigate
		case reload
		case back
		case forward
		case stop
		case closeTab
		case pinTab
		case unpinTab
		case moveTab
		case createFolder
		case renameFolder
		case moveFolder
		case openPeek
		case openLittleArx
		case promotePeekToTab
		case promotePeekToLittleArx
		case promoteLittleArx
		case createProfile
		case renameProfile
		case deleteProfile
		case createSpace
		case renameSpace
		case setSpaceTheme

		/// Chooses or clears the space's tint, grain and theme override fields.
		case setSpaceAppearance

		/// Chooses or clears the profile's tint, grain and theme override fields.
		case setProfileAppearance
		case moveSpace
		case deleteSpace
		case selectSpace
		case addFavorite
		case removeFavorite
		case updateSavedURL
		case removeSavedEntry
		case ungroupFolder
		case deleteFolder
		case openSplit
		case swapSplit
		case closeSplit
		case focusWindow
		case restoreArchived
		case cancelDownload
		case revealDownload

		/// Downloads `url` into the target profile. Arx asks every time unless the
		/// client's standing approval policy skips mutations; temporary grants don't cover it.
		case startDownload

		public var isHostOperation: Bool {
			switch self {
			case .openPeek, .openLittleArx, .promotePeekToTab, .promotePeekToLittleArx, .promoteLittleArx: true
			default: false
			}
		}

		public static var supported: [Self] { allCases }
	}
}

/// Another tab for `openSplit`, with the revision its inventory item listed.
public struct AutomationSplitTab: Codable, Equatable, Sendable {
	public var id: UUID
	public var revision: String

	public init(
		id: UUID,
		revision: String
	) {
		self.id = id
		self.revision = revision
	}
}

public enum AutomationOperation: Codable, Equatable, Sendable {
	case inventory(cursor: String?, limit: Int)
	case command(AutomationCommand)
	case capture(AutomationCaptureRequest)
	case inspect(AutomationInspectionRequest)
	case click(AutomationClickRequest)
	case wait(AutomationWaitRequest)
	case form(AutomationFormRequest)
	case scroll(AutomationScrollRequest)
	case signIn(AutomationSignInRequest)

	/// Asks once for every step of a batch; the steps follow as their own requests.
	case batch(AutomationBatchPlan)
	case data(AutomationDataRequest)
	case link(AutomationLinkRequest)
	case load(AutomationLoadRequest)
	case pdf(AutomationPDFRequest)
	case findInPage(AutomationFindInPageRequest)

	/// A tab's JavaScript dialog or permission prompt.
	case dialog(AutomationDialogRequest)

	/// Lists or controls media sessions and ArxPiP.
	case media(AutomationMediaRequest)

	/// Reads, tests or changes allowlisted Settings.
	case settings(AutomationSettingsRequest)

	/// Runs a script in a tab's developer world (DEV-668).
	case script(AutomationScriptRequest)

	/// Starts, stops or reads a tab's console or network log (DEV-668).
	case logs(AutomationLogRequest)

	/// Signs in with a password saved in the tab's profile, without revealing it (DEV-708).
	case passwordSignIn(AutomationPasswordSignInRequest)
}

public struct AutomationRequest: Equatable, Sendable {
	public var id: UUID
	public var clientID: UUID
	public var sessionID: UUID
	public var operation: AutomationOperation

	public init(
		id: UUID,
		clientID: UUID,
		sessionID: UUID,
		operation: AutomationOperation
	) {
		self.id = id
		self.clientID = clientID
		self.sessionID = sessionID
		self.operation = operation
	}
}

public struct AutomationInventoryItem: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var kind: Kind
	public var title: String
	public var profileID: UUID
	public var spaceID: UUID?
	public var parentID: UUID?
	public var url: String?
	public var host: String?
	public var urlSanitized: Bool
	public var isPinned: Bool
	public var sessionState: SessionState?

	/// DEV-1016: a `failed` tab whose renderer ended: `crashed`, `outOfMemory`, `killed`,
	/// `endedByArx`, `launchFailed` or `other`, or `keepsCrashing` and `keepsRunningOutOfMemory`
	/// for a page that ended three times within a minute.
	public var failureReason: String?
	public var revision: String
	public var automationClientID: UUID?

	/// Profiles and spaces: their own appearance override, when they have one.
	public var appearance: AppearanceOverride?

	/// Tabs: the file this tab's navigation became instead of a page, while it shows no page of
	/// its own (DEV-1116). Its progress is in the downloads data.
	public var downloadedFile: String?

	/// Open tabs, with independent windows: the window that keeps the tab, an `id` of
	/// `AutomationInventory.windows` (DEV-1157). The main window's ID stays the same while it's
	/// closed. Absent for pinned tabs and Favorites, which every window shares, and when windows
	/// share their open tabs.
	public var windowID: UUID?

	public init(
		id: UUID,
		kind: Kind,
		title: String,
		profileID: UUID,
		spaceID: UUID? = nil,
		parentID: UUID? = nil,
		url: String? = nil,
		host: String? = nil,
		isPinned: Bool = false,
		downloadedFile: String? = nil,
		sessionState: SessionState? = nil,
		revision: String,
		automationClientID: UUID? = nil,
		appearance: AppearanceOverride? = nil
	) {
		self.id = id
		self.kind = kind
		self.title = title
		self.profileID = profileID
		self.spaceID = spaceID
		self.parentID = parentID
		self.url = url
		self.host = host
		self.urlSanitized = true
		self.isPinned = isPinned
		self.sessionState = sessionState
		self.revision = revision
		self.automationClientID = automationClientID
		self.appearance = appearance
		self.downloadedFile = downloadedFile
	}

	public enum Kind: String, Codable, Sendable {
		case space
		case folder
		case tab

		/// Listed only for profile-scoped grants.
		case profile

		/// Never an inventory item; window targets come from `AutomationInventory.windows`.
		case window

		/// A Tab Archive entry, from a data read.
		case archived

		/// A download, from a data read.
		case download
	}

	public enum SessionState: String, Codable, Sendable {
		case unloaded
		case loading
		case ready
		case failed

		/// DEV-1009: the page's renderer stopped answering.
		case notAnswering
	}
}

public struct AutomationInventory: Codable, Equatable, Sendable {
	public var items: [AutomationInventoryItem]
	public var nextCursor: String?
	public var presentations: [AutomationPresentation]

	/// Granted profiles with their names. Item `profileID`s refer to these.
	public var profiles: [AutomationProfileItem]

	/// Ordinary windows showing a granted space.
	public var windows: [AutomationWindowItem]

	/// The app-wide chrome appearance that profile and space overrides apply to.
	public var chromeAppearance: ChromeAppearance?

	public init(
		items: [AutomationInventoryItem],
		nextCursor: String? = nil,
		presentations: [AutomationPresentation] = [],
		profiles: [AutomationProfileItem] = [],
		windows: [AutomationWindowItem] = [],
		chromeAppearance: ChromeAppearance? = nil
	) {
		self.items = items
		self.nextCursor = nextCursor
		self.presentations = presentations
		self.profiles = profiles
		self.windows = windows
		self.chromeAppearance = chromeAppearance
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.items = try values.decode([AutomationInventoryItem].self, forKey: .items)
		self.nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
		self.presentations = try values.decodeIfPresent([AutomationPresentation].self, forKey: .presentations) ?? []
		self.profiles = try values.decodeIfPresent([AutomationProfileItem].self, forKey: .profiles) ?? []
		self.windows = try values.decodeIfPresent([AutomationWindowItem].self, forKey: .windows) ?? []
		self.chromeAppearance = try values.decodeIfPresent(ChromeAppearance.self, forKey: .chromeAppearance)
	}

	private enum CodingKeys: String, CodingKey {
		case items, nextCursor, presentations, profiles, windows, chromeAppearance
	}
}

public struct AutomationCommandResult: Codable, Equatable, Sendable {
	public var operationID: UUID
	public var status: Status
	public var targetID: UUID?
	public var item: AutomationInventoryItem?
	public var presentation: AutomationPresentation?
	public var route: AutomationRoute?

	public init(
		operationID: UUID,
		status: Status,
		targetID: UUID? = nil,
		item: AutomationInventoryItem? = nil,
		presentation: AutomationPresentation? = nil,
		route: AutomationRoute? = nil
	) {
		self.operationID = operationID
		self.status = status
		self.targetID = targetID
		self.item = item
		self.presentation = presentation
		self.route = route
	}

	public enum Status: String, Codable, Sendable {
		case committed
		case acceptedLoading
		case cancelled
		case alreadyCommitted
	}
}

/// Where an opted-in `openTab` was routed by the user's Air Traffic Control rules.
public struct AutomationRoute: Codable, Equatable, Sendable {
	public var profileID: UUID
	public var spaceID: UUID
	public var mode: RoutingWindowMode
	public var source: Source
	public var ruleID: UUID?
	public var ruleName: String?

	public init(
		profileID: UUID,
		spaceID: UUID,
		mode: RoutingWindowMode,
		source: Source,
		ruleID: UUID? = nil,
		ruleName: String? = nil
	) {
		self.profileID = profileID
		self.spaceID = spaceID
		self.mode = mode
		self.source = source
		self.ruleID = ruleID
		self.ruleName = ruleName
	}

	public enum Source: String, Codable, Sendable {
		/// The first enabled rule matching the URL chose the destination.
		case rule

		/// No rule matched, so the fallback destination applied.
		case fallback
	}
}

public enum AutomationResult: Codable, Equatable, Sendable {
	case inventory(AutomationInventory)
	case command(AutomationCommandResult)
	case capture(AutomationCaptureResult)
	case inspection(AutomationInspectionResult)
	case click(AutomationClickResult)
	case wait(AutomationWaitResult)
	case form(AutomationFormResult)
	case scroll(AutomationScrollResult)
	case signIn(AutomationSignInResult)
	case batch(AutomationBatchApproval)
	case data(AutomationDataPage)
	case link(AutomationLinkResult)
	case load(AutomationLoadResult)
	case pdf(AutomationPDFResult)
	case findInPage(AutomationFindInPageResult)
	case dialog(AutomationDialogResult)
	case media(AutomationMediaResult)
	case settings(AutomationSettingsResult)
	case script(AutomationScriptResult)
	case logs(AutomationLogResult)
	case passwordSignIn(AutomationPasswordSignInResult)
	case failure(AutomationFailure)
}

public enum AutomationFailure: String, Error, Codable, Equatable, Sendable {
	case authenticationProtected
	case disabled
	case denied
	case invalidRequest
	case invalidCredential
	case staleSession
	case staleReference
	case notInteractable
	case noScrollableContainer
	case invalidDelta
	case unsupportedControl
	case invalidValue
	case optionNotFound
	case ambiguousOption

	/// A pointer action's point hit something other than its reference.
	case obscured

	/// browser_upload found no file chooser held for the page.
	case noFileChooser

	/// An upload path isn't a readable regular file.
	case fileUnavailable
	case staleTarget
	case staleCursor
	case appUnavailable
	case disconnected
	case busy
	case timedOut

	/// DEV-1009: the page stopped answering during the request. Arx ended its renderer and
	/// loaded it again; what the request did there is unknown.
	case pageNotAnswering
	case cancelled
	case unsupported
	case notLoaded
	case notReady
	case engineFailed
	case approvalDeclined

	/// The operation needs a person (for example mutation approval) and the run is unattended.
	case userActionRequired

	/// The user hasn't answered Arx yet. The request stays open: calling again with the same
	/// operation collects its result, and nothing runs twice (DEV-1024).
	case waitingForUser
	case duplicateOperation
	case limitExceeded

	/// Moving a tab, folder or Little Arx into another profile is not available to automation.
	case crossProfileTransferUnsupported

	/// Air Traffic Control could not resolve a destination: no rule or fallback applied,
	/// or the chosen profile or space no longer exists.
	case routeUnresolved

	/// The setting exists but automation can never read or change it.
	case protectedSetting

	/// Another command already uses the keyboard shortcut.
	case shortcutConflict

	/// macOS keeps the keyboard shortcut for editing or window commands.
	case shortcutReserved

	/// The developer tier needs Arx's developer mode, which only the user can turn on.
	case developerModeRequired

	/// The user pressed Stop on the page's agent indicator; the client's grant is paused
	/// until they resume it (DEV-899).
	case paused

	/// This Arx can't install extensions from the Chrome Web Store (DEV-951).
	case installationUnavailable

	/// Guidance for failures a person can resolve in Arx itself.
	public var message: String? {
		switch self {
		case .crossProfileTransferUnsupported:
			"Only moveTab crosses profiles, by reopening the tab there. Pins, folders and Little Arx can't; "
			+ "the user can move it to another profile in Arx."

		case .routeUnresolved:
			"Air Traffic Control has no usable destination for this URL. "
			+ "Check the routing rules and fallback in Arx Settings, or open the tab in an explicit space."

		case .noFileChooser:
			"No file chooser is waiting on this page. Click the file input with browser_click (x/y, clickCount "
			+ "or modifiers) first; a chooser opened right after that is held for about a minute."

		case .fileUnavailable:
			"Each upload path must be an existing, readable regular file, not a folder or a symbolic link."

		case .protectedSetting:
			"Security settings, developer mode and automation access can only be changed by the user in Arx Settings."

		case .shortcutConflict:
			"Another command or search shortcut already uses this. Read the section to see which; for keyboard "
			+ "shortcuts pass replace:true to take it from the other command, as Settings' Replace does."

		case .shortcutReserved:
			"⌘A, ⌘C, ⌘X, ⌘V, ⌘Z, ⇧⌘Z, ⌘H, ⌥⌘H and ⌘M stay with macOS editing and window commands."

		case .waitingForUser:
			"Arx is still asking the user, and the request stays open for 15 minutes. Tell the user what Arx "
			+ "asks, then call this tool again with exactly the same arguments, the same operationID included, "
			+ "to get its result. A new operationID would be a second request."

		case .developerModeRequired:
			"Scripts and console and network logs need developer mode, which the user turns on in Arx Settings."

		case .paused:
			"The user stopped this assistant in Arx. Don't retry; ask them to resume it in Settings › "
			+ "Local assistants (MCP) when they want you to continue."

		case .installationUnavailable:
			"This Arx can't install extensions from the Chrome Web Store, so installExtension isn't offered "
			+ "(the extensions section's canInstall is false). Installed extensions can still be enabled or disabled."

		default:
			nil
		}
	}
}

public struct AutomationActivity: Equatable, Identifiable, Sendable {
	public var id: UUID
	public var clientID: UUID
	public var operation: String
	public var outcome: String
	public var date: Date

	public init(
		id: UUID,
		clientID: UUID,
		operation: String,
		outcome: String,
		date: Date
	) {
		self.id = id
		self.clientID = clientID
		self.operation = operation
		self.outcome = outcome
		self.date = date
	}
}

public enum AutomationAccess {
	public static func permitsProfile(
		_ id: Profile.ID,
		client: AutomationClient
	) -> Bool {
		client.scopes.contains(.profile(id))
	}

	public static func permitsSpace(
		_ id: Space.ID,
		client: AutomationClient,
		organization: BrowserOrganization
	) -> Bool {
		guard let space = organization.spaces[id: id]
		else { return false }

		return permitsProfile(space.profileID, client: client)
		|| client.scopes.contains(.space(id, profileID: space.profileID))
	}

	public static func permitsTab(
		_ id: Tab.ID,
		client: AutomationClient,
		organization: BrowserOrganization
	) -> Bool {
		guard let tab = organization.tabs[id: id] else { return false }

		return permitsTab(
			tab,
			at: location(of: id, in: organization),
			client: client,
			organization: organization
		)
	}

	/// The same check for a tab whose location the caller already resolved, for example
	/// from `BrowserOrganization.tabLocations`, so a pass over many tabs walks them once.
	public static func permitsTab(
		_ tab: Tab,
		at location: AutomationTabLocation?,
		client: AutomationClient,
		organization: BrowserOrganization
	) -> Bool {
		guard let location else { return false }

		if
			permitsProfile(tab.profileID, client: client)
			|| client.scopes.contains(.tab(tab.id, profileID: tab.profileID, location: location))
		{
			return true
		}

		guard case let .space(spaceID) = location
		else { return false }

		return permitsSpace(spaceID, client: client, organization: organization)
	}

	public static func location(
		of id: Tab.ID,
		in organization: BrowserOrganization
	) -> AutomationTabLocation? {
		organization.location(of: id).map(AutomationTabLocation.init)
	}

	public static func sanitizedURL(_ url: URL) -> String? {
		guard
			var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
			let scheme = parts.scheme?.lowercased(),
			["http", "https"].contains(scheme)
		else { return nil }

		parts.user = nil
		parts.password = nil
		parts.query = nil
		parts.fragment = nil

		return parts.url?.absoluteString
	}
}

/// Which automation client a profile's built-in assistant uses.
public struct AssistantAutomationClient: Codable, Equatable, Hashable, Sendable {
	public var profileID: Profile.ID
	public var clientID: UUID

	public init(
		profileID: Profile.ID,
		clientID: UUID
	) {
		self.profileID = profileID
		self.clientID = clientID
	}
}

extension AutomationResult {
	/// The failure a result reports, whether a plain failure or a change's receipt.
	public var failure: AutomationFailure? {
		switch self {
		case let .failure(failure): failure
		case let .click(receipt): receipt.failure
		case let .form(receipt): receipt.failure
		case let .scroll(receipt): receipt.failure
		case let .media(result): result.failure
		case let .passwordSignIn(result): result.outcome == .failed && result.reason == .timedOut ? .timedOut : nil
		default: nil
		}
	}
}
