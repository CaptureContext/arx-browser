import Foundation

/// How long a hidden tab keeps its page loaded before Arx unloads it to free memory (DEV-873).
///
/// An unloaded tab keeps its address, title, icon and back/forward list, and loads again when
/// it's shown. Settings › General › Tabs and Settings › Advanced › Memory choose it; critical
/// memory pressure unloads hidden tabs sooner, whatever it says (``TabUnloadPressureGrace``).
public enum TabUnloadDelay: String, CaseIterable, Codable, Sendable {
	case oneHour
	case twoHours
	case threeHours
	case sixHours
	case twelveHours
	case never

	/// PROVISIONAL: three hours is Max's decision of 22 November 2026 (the idle tab defaults
	/// ticket, DEV-1326), half the six hours a regular tab waits before it's archived
	/// (``TabArchiveInterval/default``), so a tab unloads before it leaves the sidebar. It is
	/// still unmeasured, as the six hours before it were (DEV-873). Replace it with the value a
	/// memory measurement supports: 50 tabs, resident memory of Arx and its helpers after one,
	/// two, three and six hours hidden, against unloading off.
	public static let provisionalDefault: Self = .threeHours

	/// How long a tab stays hidden before it unloads, or nil when only memory pressure unloads it.
	public var duration: TimeInterval? {
		switch self {
		case .oneHour: 60 * 60
		case .twoHours: 2 * 60 * 60
		case .threeHours: 3 * 60 * 60
		case .sixHours: 6 * 60 * 60
		case .twelveHours: 12 * 60 * 60
		case .never: nil
		}
	}
}

/// How long a tab stays hidden before critical memory pressure may unload it (DEV-873), from
/// Settings › Advanced › Memory.
///
/// Even under critical pressure a tab unloads only after being hidden this long, so switching
/// away and straight back never loses its state. A ``TabUnloadDelay`` shorter than this wins.
public enum TabUnloadPressureGrace: String, CaseIterable, Codable, Sendable {
	case thirtySeconds
	case oneMinute
	case twoMinutes
	case fiveMinutes
	case tenMinutes

	/// PROVISIONAL (DEV-873): Chrome waits ten minutes; critical pressure is closer to the system
	/// ending processes.
	public static let provisionalDefault: Self = .oneMinute

	/// How long a tab stays hidden before memory pressure may unload it.
	public var duration: TimeInterval {
		switch self {
		case .thirtySeconds: 30
		case .oneMinute: 60
		case .twoMinutes: 2 * 60
		case .fiveMinutes: 5 * 60
		case .tenMinutes: 10 * 60
		}
	}
}

/// Why Arx unloads a tab's page (DEV-873). The engine applies Chrome's rules for each:
/// Chrome's proactive rules for `inactive` also keep pages with notifications or with
/// title and icon changes in the background.
public enum TabUnloadReason: Equatable, Sendable {
	/// Hidden longer than ``TabUnloadDelay`` allows.
	case inactive

	/// The system is under critical memory pressure, and the tab has been hidden longer than
	/// ``TabUnloadPressureGrace`` allows.
	case memoryPressure

	/// No open window holds the tab since a window closed (DEV-1104). The engine ends its picture
	/// in picture and unloads it even while it plays sound, captures or holds a live connection,
	/// and keeps it for unsaved input and DevTools.
	case windowClosed

	/// As ``windowClosed``, for a tab whose page held unsaved input when its window asked before
	/// closing (DEV-1107): the person chose Leave in its before-unload question, or it had nothing
	/// to ask. Unsaved input doesn't keep it.
	case windowClosedAnswered
}

/// What asking the engine to unload a tab's page did (DEV-873).
public enum TabUnloadOutcome: Equatable, Sendable {
	case unloaded
	case alreadyUnloaded

	/// The engine kept it loaded: it plays sound, shows picture in picture, holds form
	/// input or a WebSocket or WebTransport connection (DEV-879), captures, has DevTools
	/// attached, or another of Chrome's reasons.
	case kept

	/// It's loading; the next sweep asks again.
	case busy

	/// The engine has no page for the tab, or can't unload pages.
	case unavailable
}

/// The app's half of deciding whether a tab may unload (DEV-873): what only the app knows.
///
/// The engine's half is `PageUnloadBlockers` in the engine package's
/// `Native/page_unload_bridge.h`, which applies Chrome's discard rules (sound, picture in
/// picture, form input, notifications, capture and the like), DevTools, visibility and open
/// WebSocket or WebTransport connections (DEV-879), and refuses on its own. Add facts the app
/// knows here, and facts about the page itself there.
public enum TabUnloadEligibility {
	/// What the app knows about one tab.
	public struct Facts: Equatable, Sendable {
		/// The engine has a page for the tab and it isn't unloaded already.
		public var isLoaded: Bool

		/// Shown in a pane of an open window, in Peek or in Little Arx.
		public var isOnScreen: Bool

		/// Its space's selected tab: what the space shows when it's opened next.
		public var isSelectedInSpace: Bool

		/// An agent is acting on it, or did a moment ago.
		public var isInAgentUse: Bool

		/// A chat tab (DEV-761): no page to unload.
		public var isChat: Bool

		/// On a site its profile keeps loaded, or a pinned tab or Favorite while Settings keeps
		/// those loaded (DEV-932).
		public var isKeptLoaded: Bool

		public init(
			isLoaded: Bool,
			isOnScreen: Bool,
			isSelectedInSpace: Bool,
			isInAgentUse: Bool,
			isChat: Bool,
			isKeptLoaded: Bool = false
		) {
			self.isLoaded = isLoaded
			self.isOnScreen = isOnScreen
			self.isSelectedInSpace = isSelectedInSpace
			self.isInAgentUse = isInAgentUse
			self.isChat = isChat
			self.isKeptLoaded = isKeptLoaded
		}
	}

	/// Why the app keeps a tab loaded.
	public enum Exemption: Equatable, Sendable, CaseIterable {
		case notLoaded
		case chat
		case onScreen
		case selectedInSpace
		case agentUse
		case keptLoaded
	}

	/// Why the tab must stay loaded, or nil when the app lets the engine decide.
	public static func exemption(_ facts: Facts) -> Exemption? {
		if !facts.isLoaded { return .notLoaded }
		if facts.isChat { return .chat }
		if facts.isOnScreen { return .onScreen }
		if facts.isSelectedInSpace { return .selectedInSpace }
		if facts.isInAgentUse { return .agentUse }
		if facts.isKeptLoaded { return .keptLoaded }
		return nil
	}
}

/// When hidden tabs unload (DEV-873).
public enum TabUnloadPolicy {
	/// One tab the policy weighs.
	public struct Candidate: Equatable, Sendable {
		public let id: Tab.ID
		public var facts: TabUnloadEligibility.Facts

		/// When it left the screen, or when Arx first found it hidden. Nil: its clock hasn't
		/// started, so it isn't due.
		public var hiddenSince: Date?

		public init(
			id: Tab.ID,
			facts: TabUnloadEligibility.Facts,
			hiddenSince: Date?
		) {
			self.id = id
			self.facts = facts
			self.hiddenSince = hiddenSince
		}
	}

	/// PROVISIONAL (DEV-873): how long a tab an agent acted on stays loaded afterwards, so a
	/// session's next step finds it where it left it.
	public static let agentGrace: TimeInterval = 15 * 60

	/// How often Arx looks for tabs to unload.
	public static let sweepInterval: Duration = .seconds(60)

	/// The tabs to unload now, longest hidden first.
	public static func dueTabs(
		_ candidates: [Candidate],
		delay: TabUnloadDelay,
		pressureGrace: TabUnloadPressureGrace,
		reason: TabUnloadReason,
		now: Date
	) -> [Tab.ID] {
		let grace = pressureGrace.duration
		let threshold: TimeInterval? = switch reason {
		case .inactive: delay.duration

		case .memoryPressure: min(grace, delay.duration ?? grace)

		// Not a sweep's reason: a closed window's tabs are due at once.
		case .windowClosed, .windowClosedAnswered: 0
		}
		guard let threshold else { return [] }

		return candidates
			.compactMap { candidate -> (id: Tab.ID, hiddenSince: Date)? in
				guard
					TabUnloadEligibility.exemption(candidate.facts) == nil,
					let hiddenSince = candidate.hiddenSince,
					now.timeIntervalSince(hiddenSince) >= threshold
				else { return nil }

				return (candidate.id, hiddenSince)
			}
			.sorted { $0.hiddenSince < $1.hiddenSince }
			.map(\.id)
	}
}
