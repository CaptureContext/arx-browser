import Foundation

/// A class of browser access an automation client can hold. Each tool declares the
/// classes it needs, and a client sees and may call only the tools its classes cover.
public enum AutomationCapability: String, Codable, CaseIterable, Comparable, Hashable, Sendable {
	/// Inventory of granted spaces, folders and tabs, and waiting on page loads.
	case read

	/// Viewport, region and full-document screenshots.
	case screenshots

	/// Semantic page snapshots.
	case pageContent

	/// Clicks, text replacement, selection, key presses and scrolling.
	case interact

	/// Opening, moving, pinning, closing and renaming tabs and folders.
	case organize

	/// Profiles, spaces and settings.
	case browserAdmin

	/// Browsing history.
	case history

	/// Downloads.
	case downloads

	/// Uploading local files to pages. Every upload also asks the user.
	case files

	/// Console and network logs of granted tabs. Needs developer mode.
	case devtools

	/// Request and response headers and bodies, and HAR export, on top of devtools (DEV-924).
	/// Credential and cookie headers never leave the engine. Needs developer mode.
	case networkDetails

	/// Script evaluation in granted tabs' developer world. Needs developer mode.
	case script

	/// The trusted sign-in handoff.
	case signIn

	public static func < (lhs: Self, rhs: Self) -> Bool {
		let order: [Self] = allCases
		return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
	}
}

/// How much an action can change. The app enforces each client's approval policy
/// against the tier, so a client can never lower the tier of its own request.
public enum AutomationRiskTier: Int, Codable, Comparable, Hashable, Sendable {
	/// Reads granted data and never changes the browser or a website.
	case read

	/// Changes the browser or a website in a way the user can usually undo.
	case mutate

	/// Removes or closes something.
	case destructive

	/// Pays, sends, posts or deletes on a website, read from what the press does
	/// (``AutomationConsequence``). Every policy asks, and a temporary grant never covers it.
	case consequential

	public static func < (lhs: Self, rhs: Self) -> Bool {
		lhs.rawValue < rhs.rawValue
	}
}

/// When a client's mutations need the user's approval in Arx.
public enum AutomationApprovalPolicy: String, Codable, CaseIterable, Hashable, Sendable {
	/// Every mutation asks, unless a temporary grant is active.
	case alwaysAsk

	/// Only destructive and consequential actions ask.
	case destructiveOnly

	/// Only consequential actions ask. The grant stands until the user changes it.
	case never

	/// Whether an action of `tier` runs without asking.
	public func skipsApproval(for tier: AutomationRiskTier) -> Bool {
		switch (self, tier) {
		case (_, .read): true
		case (_, .consequential): false
		case (.never, _): true
		case (.destructiveOnly, .mutate): true
		case (.destructiveOnly, .destructive), (.alwaysAsk, _): false
		}
	}
}

/// What a connected client may currently do, as the MCP helper sees it. The helper
/// lists tools from this and reports a change to its client without reconnecting.
public struct AutomationGrantSummary: Codable, Equatable, Hashable, Sendable {
	public var capabilities: [AutomationCapability]
	public var approvalPolicy: AutomationApprovalPolicy
	public var allowsFocusedTab: Bool

	public init(
		capabilities: [AutomationCapability] = [],
		approvalPolicy: AutomationApprovalPolicy = .alwaysAsk,
		allowsFocusedTab: Bool = false
	) {
		self.capabilities = capabilities.sorted()
		self.approvalPolicy = approvalPolicy
		self.allowsFocusedTab = allowsFocusedTab
	}

	public init(_ client: AutomationClient) {
		self.init(
			capabilities: Array(client.capabilities),
			approvalPolicy: client.approvalPolicy,
			allowsFocusedTab: client.allowsFocusedTab && client.allowsRead
		)
	}

	public func contains(_ capabilities: Set<AutomationCapability>) -> Bool {
		capabilities.isSubset(of: Set(self.capabilities))
	}
}

/// The tab the focused-tab alias resolved to when the MCP helper asked.
public struct AutomationFocusedTab: Codable, Equatable, Sendable {
	/// The argument value agents pass instead of a tab ID and revision.
	public static let alias: String = "focused"

	public var tabID: UUID
	public var revision: String

	public init(
		tabID: UUID,
		revision: String
	) {
		self.tabID = tabID
		self.revision = revision
	}
}

extension AutomationCommand.Action {
	public var riskTier: AutomationRiskTier {
		switch self {
		case .closeTab, .deleteProfile, .deleteSpace, .removeSavedEntry, .deleteFolder: .destructive
		default: .mutate
		}
	}

	/// Whether a committed action leaves its target gone: destructive actions, and ungrouping,
	/// which keeps a folder's children and removes the folder. Its result names no target,
	/// because the response check only lets through targets the client can still see.
	public var removesTarget: Bool {
		riskTier == .destructive || self == .ungroupFolder
	}

	/// The class that covers the action, besides read.
	public var capability: AutomationCapability {
		switch self {
		case .createProfile, .renameProfile, .deleteProfile, .createSpace, .renameSpace, .setSpaceTheme,
			.setSpaceAppearance, .setProfileAppearance, .moveSpace, .deleteSpace:
			.browserAdmin
		case .cancelDownload, .revealDownload, .startDownload:
			.downloads
		default:
			.organize
		}
	}

	/// What the action targets.
	public var targetKind: AutomationInventoryItem.Kind {
		switch self {
		case .openTab, .createFolder, .openLittleArx, .promoteLittleArx, .renameSpace, .setSpaceTheme,
			.setSpaceAppearance, .moveSpace, .deleteSpace, .selectSpace:
			.space
		case .renameFolder, .moveFolder, .ungroupFolder, .deleteFolder:
			.folder
		case .createProfile, .renameProfile, .deleteProfile, .createSpace, .startDownload, .setProfileAppearance:
			.profile
		case .swapSplit, .closeSplit, .focusWindow:
			.window
		case .restoreArchived:
			.archived
		case .cancelDownload, .revealDownload:
			.download
		default:
			.tab
		}
	}
}

extension AutomationOperation {
	/// The classes a client needs before Arx accepts this operation.
	public var requiredCapabilities: Set<AutomationCapability> {
		switch self {
		case .inventory, .wait: [.read]
		case let .command(command): [.read, command.action.capability]
		case .capture: [.read, .screenshots]
		case .inspect: [.read, .pageContent]
		case let .form(request) where request.kind == .upload: [.read, .pageContent, .interact, .files]
		case .click, .form, .scroll: [.read, .pageContent, .interact]
		case .signIn: [.read, .signIn]
		case let .batch(plan): plan.requiredCapabilities
		case let .data(request):
			switch request.kind {
			case .history: [.read, .history]
			case .archive: [.read]
			case .downloads: [.read, .downloads]
			}
		case .link: [.read]
		case .load, .pdf: [.read, .pageContent]
		case .findInPage, .dialog: [.read, .pageContent, .interact]
		case .media: [.read, .interact]
		case .settings: [.read, .browserAdmin]
		case .script: [.read, .script]
		case let .logs(request): request.needsNetworkDetails ? [.read, .devtools, .networkDetails] : [.read, .devtools]
		case .passwordSignIn: [.read, .signIn]
		}
	}

	/// How much the operation can change, which the client's approval policy is checked against.
	public var riskTier: AutomationRiskTier {
		switch self {
		// Loading a saved page is what selecting it would do, without any presentation change.
		case .inventory, .wait, .capture, .inspect, .signIn, .data, .link, .load, .pdf: .read

		// Highlights and the final selection are visible to the page and the user.
		case .findInPage: .mutate

		// Dismissing never needs approval; accepting always asks (alwaysAsks).
		case let .dialog(request): request.action == .accept ? .mutate : .read

		// Playback and ArxPiP are visible and audible to the user.
		case let .media(request): request.isControl ? .mutate : .read

		case let .settings(request): request.change?.edit.riskTier ?? .read

		case let .command(command): command.action.riskTier

		case .click, .form, .scroll: .mutate

		case let .batch(plan): plan.riskTier

		// A script can do anything the signed-in user can on that site.
		case .script: .mutate

		// Keeping or reading a log changes nothing a website or the user sees.
		case .logs: .read

		// Submits a form as the user, on a site the user saved a password for.
		case .passwordSignIn: .mutate
		}
	}

	/// Asks the user every time, whatever the client's standing or temporary
	/// approval: each uploaded file, and each site allowed a permission that
	/// prompts, is shown and approved in Arx.
	public var alwaysAsks: Bool {
		switch self {
		case let .form(request): request.kind == .upload
		case let .dialog(request): request.action == .accept
		case let .settings(request):
			request.change.map { $0.edit.grantsSitePermission || $0.edit.installsExtension } == true
		default: false
		}
	}

	/// Asks in the Extensions sheet's review rather than in Arx's approval prompt: an
	/// extension install, whose review shows what the prompt couldn't (DEV-951). It
	/// always asks, so it is never batched and never covered by a grant.
	public var asksInExtensionReview: Bool {
		guard case let .settings(request) = self else { return false }
		return request.change?.edit.installsExtension == true
	}

	/// Asks the user every time unless the client's standing approval policy skips
	/// its tier. A temporary grant or a batch approval never covers it: each download
	/// is shown and approved on its own.
	public var ignoresTemporaryGrant: Bool {
		switch self {
		case let .command(command): command.action == .startDownload

		// Each script is shown and approved on its own.
		case .script: true

		// Arx's own per-site setting decides, never a client grant.
		case .passwordSignIn: true

		default: false
		}
	}
}
