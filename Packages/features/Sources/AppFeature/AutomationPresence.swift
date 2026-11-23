import AppUI
import BrowserCore
import Foundation
import SidebarFeature
import _ComposableArchitecture

/// An MCP client changing a page right now, or a moment ago (DEV-899). The page shows a pill
/// naming the client, with Stop, and its sidebar row shows a small badge.
///
/// Only operations that change what the page or the user sees count: clicks, typing, scrolling,
/// find highlights, dialog answers, media controls, scripts, password sign-ins and tab
/// commands. Reads (inventory, inspection, captures, waits, logs) show nothing, so an agent
/// that only looks never draws over the page.
public struct AgentPresence: Equatable, Sendable {
	/// How long the indicator stays after the last operation ends, so a run of quick actions
	/// reads as one and the user has time to press Stop.
	public static let linger: TimeInterval = 4

	/// The client the indicator names: the latest to act, or one still acting.
	public var clientID: UUID

	/// The requests acting on the tab now, with their clients. Two clients can act at once.
	public var activeRequests: [UUID: UUID]

	/// When the last operation started or ended.
	public var lastActed: Date

	/// Set by Stop: the pill offers Resume instead until it fades.
	public var isStopped: Bool

	public init(
		clientID: UUID,
		activeRequests: [UUID: UUID] = [:],
		lastActed: Date,
		isStopped: Bool = false
	) {
		self.clientID = clientID
		self.activeRequests = activeRequests
		self.lastActed = lastActed
		self.isStopped = isStopped
	}

	public var isActive: Bool { !activeRequests.isEmpty }

	/// When the indicator hides, or nil while an operation is still running.
	public var fadesAt: Date? {
		isActive ? nil : lastActed.addingTimeInterval(Self.linger)
	}

	public func isVisible(at date: Date) -> Bool {
		fadesAt.map { date < $0 } ?? true
	}
}

extension AutomationOperation {
	/// The tab an operation changes, or nil for reads and for operations that don't act on one
	/// page. A batch's steps arrive as their own requests and are counted there.
	internal var presenceTabID: BrowserCore.Tab.ID? {
		// Dismissing a dialog never asks, but it changes the page as accepting does.
		if case let .dialog(request) = self, request.action != .read {
			return .init(rawValue: request.targetID)
		}
		guard riskTier != .read else { return nil }

		let id: UUID? = switch self {
		case let .click(request): request.targetID
		case let .form(request): request.target.targetID
		case let .scroll(request): request.target.targetID
		case let .findInPage(request): request.targetID
		case let .dialog(request): request.targetID
		case let .media(request): request.targetID
		case let .script(request): request.targetID
		case let .passwordSignIn(request): request.targetID
		case let .command(command): command.action.targetKind == .tab ? command.targetID : nil
		case .inventory, .capture, .inspect, .wait, .signIn, .batch, .data, .link, .load, .pdf, .settings, .logs: nil
		}
		return id.map(BrowserCore.Tab.ID.init(rawValue:))
	}
}

extension AutomationOperation {
	/// DEV-1009: the page an operation works in, reads included, whose renderer may have
	/// stopped answering when the operation timed out.
	internal var pageTabID: BrowserCore.Tab.ID? {
		switch self {
		case let .capture(request): .init(rawValue: request.targetID)
		case let .inspect(request): .init(rawValue: request.targetID)
		case let .wait(request): .init(rawValue: request.targetID)
		case let .dialog(request): .init(rawValue: request.targetID)
		default: presenceTabID
		}
	}
}

extension AppFeature.State {
	/// Marks the request's tab as acted on, once the request is approved and about to run.
	internal mutating func beginAgentPresence(
		_ requestID: UUID,
		now: Date
	) {
		guard
			let pending = automation.pending[requestID],
			let tabID = pending.request.operation.presenceTabID,
			workspace.tabs[id: tabID] != nil
		else { return }

		// Entries that faded long ago go, so the map holds only recent tabs.
		automation.presence = automation.presence.filter { _, presence in
			presence.isActive || now.timeIntervalSince(presence.lastActed) < 60
		}
		var presence = automation.presence[tabID] ?? .init(clientID: pending.request.clientID, lastActed: now)
		presence.clientID = pending.request.clientID
		presence.activeRequests[requestID] = pending.request.clientID
		presence.lastActed = now
		presence.isStopped = false
		automation.presence[tabID] = presence
		agentUsedTab(tabID)
	}

	/// Ends the request's part in its tab's indicator, which then lingers for `AgentPresence.linger`.
	internal mutating func endAgentPresence(
		_ requestID: UUID,
		now: Date?
	) {
		for (tabID, presence) in automation.presence where presence.activeRequests[requestID] != nil {
			var presence = presence
			presence.activeRequests[requestID] = nil
			if let now { presence.lastActed = now }

			// Another client still acting keeps the indicator, under its name.
			if let other = presence.activeRequests.values.first, !presence.activeRequests.values.contains(presence.clientID) {
				presence.clientID = other
			}
			automation.presence[tabID] = presence
		}
	}

	/// Stop for one client: its requests leave every indicator. A tab another client still acts on
	/// keeps that client's indicator; the rest offer Resume until they fade.
	internal mutating func stopAgentPresence(
		of clientID: UUID,
		now: Date
	) {
		for (tabID, presence) in automation.presence
		where presence.clientID == clientID || presence.activeRequests.values.contains(clientID) {
			var presence = presence
			presence.activeRequests = presence.activeRequests.filter { $0.value != clientID }
			presence.lastActed = now
			if let other = presence.activeRequests.values.first {
				presence.clientID = other
			} else {
				presence.clientID = clientID
				presence.isStopped = true
			}
			automation.presence[tabID] = presence
		}
	}

	/// The indicator a page shows, with the client's name, or nil when none acts on it.
	public func agentPresence(
		on tabID: BrowserCore.Tab.ID
	) -> (presence: AgentPresence, clientName: String)? {
		guard
			let presence = automation.presence[tabID],
			let client = automationPreferences.clients.first(where: { $0.id == presence.clientID })
		else { return nil }

		return (presence, client.name)
	}

	/// What each sidebar row shows of an agent acting on its tab.
	internal var agentPresenceBadges: [BrowserCore.Tab.ID: SidebarItem.Agent] {
		var badges: [BrowserCore.Tab.ID: SidebarItem.Agent] = [:]
		for (tabID, presence) in automation.presence where !presence.isStopped {
			guard let client = automationPreferences.clients.first(where: { $0.id == presence.clientID })
			else { continue }

			// A tab an agent opened says so again once the acting badge fades (DEV-1022).
			badges[tabID] = .init(name: client.name, fadesAt: presence.fadesAt, openedBy: openerName(of: tabID))
		}

		// The rest of the tabs agents opened say which, quietly.
		for tabID in automation.agentTabs.keys where badges[tabID] == nil {
			guard let name = openerName(of: tabID) else { continue }
			badges[tabID] = .opener(name)
		}
		return badges
	}

	/// The name of the client that opened the tab, while it's still the client's (DEV-1022).
	private func openerName(of tabID: BrowserCore.Tab.ID) -> String? {
		guard let agentTab = automation.agentTabs[tabID] else { return nil }
		return automationPreferences.clients.first { $0.id == agentTab.clientID }?.name
	}

	/// Private windows never show automation; every other sidebar shows the same badges.
	internal mutating func publish(agentBadges badges: [BrowserCore.Tab.ID: SidebarItem.Agent]) {
		let mainBadges = main.isPrivate ? [:] : badges
		if main.sidebar.tabAgents != mainBadges { main.sidebar.tabAgents = mainBadges }
		for window in windows {
			let windowBadges = window.isPrivate ? [:] : badges
			if window.sidebar.tabAgents != windowBadges { windows[id: window.id]?.sidebar.tabAgents = windowBadges }
		}
	}
}

extension Reducer where State == AppFeature.State, Action == AppFeature.Action {
	/// Keeps every window's tab rows in step with the agents acting on them, new windows
	/// included. Only a difference reaches a sidebar.
	internal func publishingAgentPresence() -> some Reducer<State, Action> {
		CombineReducers {
			self
			Reduce { state, _ in
				state.publish(agentBadges: state.agentPresenceBadges)
				return .none
			}
		}
	}
}
