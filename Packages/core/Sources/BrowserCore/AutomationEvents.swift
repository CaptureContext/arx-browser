import Foundation

/// What a granted tab shows the events feed (DEV-924): a short hash of its address, how its page
/// loaded, a load error, and the dialog or permission prompt it's showing. Never the address,
/// title or dialog text themselves; an agent reads those from the tab's resource with its grant.
public struct AutomationTabSignal: Codable, Equatable, Hashable, Sendable {
	public var address: String?
	public var state: AutomationInventoryItem.SessionState?

	/// Chromium's network error for a failed load, such as -105 for a name that didn't resolve.
	public var errorCode: Int?
	public var dialog: BrowserPageDialog.Kind?

	public init(
		address: String? = nil,
		state: AutomationInventoryItem.SessionState? = nil,
		errorCode: Int? = nil,
		dialog: BrowserPageDialog.Kind? = nil
	) {
		self.address = address
		self.state = state
		self.errorCode = errorCode
		self.dialog = dialog
	}
}

/// One entry of `arx://events`, the browser events an MCP client can follow for its granted tabs
/// (DEV-924). The helper derives them from successive change digests while the client subscribes.
public struct AutomationEvent: Codable, Equatable, Sendable {
	public enum Kind: String, Codable, CaseIterable, Sendable {
		/// A granted tab appeared: opened, or newly granted.
		case tabOpened

		/// A granted tab went away: closed, or no longer granted.
		case tabClosed

		/// The tab went to another address.
		case navigated
		case loadStarted
		case loadFinished

		/// The page failed to load (`errorCode`).
		case pageError

		/// The page opened a JavaScript dialog (`dialog`).
		case dialogOpened

		/// The page asked for a permission.
		case permissionPrompt

		/// Something in the granted downloads changed. Read `arx://downloads`.
		case downloadsChanged

		/// The tab changed in a way the others don't name: a reload, or a load that started and
		/// finished between two looks. Read the tab's resource.
		case tabChanged
	}

	public static let maximumKept: Int = 200

	public var sequence: UInt64
	public var kind: Kind
	public var tabID: UUID?

	/// The tab's inventory revision after the change, to pass as `expectedRevision`.
	public var revision: String?
	public var errorCode: Int?
	public var dialog: BrowserPageDialog.Kind?
	public var time: Date

	public init(
		sequence: UInt64,
		kind: Kind,
		tabID: UUID? = nil,
		revision: String? = nil,
		errorCode: Int? = nil,
		dialog: BrowserPageDialog.Kind? = nil,
		time: Date
	) {
		self.sequence = sequence
		self.kind = kind
		self.tabID = tabID
		self.revision = revision
		self.errorCode = errorCode
		self.dialog = dialog
		self.time = time
	}

	/// The events between two digests, in tab order, numbered from `firstSequence`.
	public static func changes(
		from previous: AutomationChangeDigest,
		to current: AutomationChangeDigest,
		firstSequence: UInt64,
		time: Date
	) -> [Self] {
		var events: [Self] = []
		func add(
			_ kind: Kind,
			tab: UUID? = nil,
			errorCode: Int? = nil,
			dialog: BrowserPageDialog.Kind? = nil
		) {
			events.append(.init(
				sequence: firstSequence + UInt64(events.count),
				kind: kind,
				tabID: tab,
				revision: tab.flatMap { current.tabs[$0] },
				errorCode: errorCode,
				dialog: dialog,
				time: time
			))
		}

		let ids = Set(previous.tabs.keys).union(current.tabs.keys).sorted { $0.uuidString < $1.uuidString }
		for id in ids {
			guard previous.tabs[id] != nil else {
				add(.tabOpened, tab: id)
				continue
			}
			guard current.tabs[id] != nil else {
				add(.tabClosed, tab: id)
				continue
			}

			let before = previous.signals[id] ?? .init()
			let after = current.signals[id] ?? .init()
			let count = events.count
			if before.address != after.address, after.address != nil { add(.navigated, tab: id) }
			if before.state != .loading, after.state == .loading { add(.loadStarted, tab: id) }
			if before.state == .loading, after.state == .ready { add(.loadFinished, tab: id) }
			if let code = after.errorCode, before.errorCode != code || before.address != after.address {
				add(.pageError, tab: id, errorCode: code)
			}
			if let dialog = after.dialog, before.dialog != dialog {
				add(dialog == .permission ? .permissionPrompt : .dialogOpened, tab: id, dialog: dialog)
			}

			// The digest is sampled, so a short load can begin and end between two looks.
			if events.count == count, previous.tabs[id] != current.tabs[id] { add(.tabChanged, tab: id) }
		}
		if previous.downloads != current.downloads, current.downloads != nil {
			add(.downloadsChanged)
		}
		return events
	}
}
