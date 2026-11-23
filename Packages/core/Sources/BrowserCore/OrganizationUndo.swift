import Foundation

/// One thing ⌘Z takes back in a window (DEV-1030): the workspace before it, and after it.
///
/// Taking a step back reverts only what it changed, on top of the workspace as it is now
/// (`BrowserOrganization.reverting(_:to:)`), so what was done since, in this window or another,
/// by hand or by an agent, stays.
public struct OrganizationUndo: Equatable, Sendable {
	/// Who made the change.
	public enum Author: Equatable, Sendable {
		case person

		/// An MCP client, by the name it registered with. Taking its change back says so.
		case agent(String)
	}

	/// Tabs Move to Window sent from `source` to `target`. Taking the step back shows them in
	/// `source` again.
	public struct WindowMove: Equatable, Sendable {
		public var tabs: [Tab.ID]
		public var source: UUID
		public var target: UUID

		public init(
			tabs: [Tab.ID],
			source: UUID,
			target: UUID
		) {
			self.tabs = tabs
			self.source = source
			self.target = target
		}
	}

	/// Which change it is. Copies other windows hold keep it, so taking the step back drops exactly
	/// its copies, even where another step has the same workspaces. Not part of equality: a step
	/// is the same value however it was made.
	public let id: UUID
	public var before: BrowserOrganization

	/// Nil while the step is still being made: whatever the window does next without a step of
	/// its own, such as the group a split drop records once its pane opens, belongs to it. It's
	/// sealed as the window's next step starts, or as another window or an agent changes the
	/// workspace.
	public var after: BrowserOrganization?

	/// The space the window showed, which it shows again when the step is taken back.
	public var spaceID: Space.ID?
	public var author: Author

	/// When the step can no longer be taken back: a deleted space's grace period.
	public var expiresAt: Date?
	public var windowMove: WindowMove?

	/// The window each open tab the step removed was in, while windows keep their own open tabs
	/// (DEV-822): taking the step back gives each window its tabs again (DEV-1030).
	public var openTabOwners: [Tab.ID: UUID]

	/// Whether taking the step back selects again the tab its space had selected before. Only a
	/// window's own steps do; a step another window or an agent made leaves the selection alone.
	public var restoresSelection: Bool

	public init(
		id: UUID = UUID(),
		before: BrowserOrganization,
		after: BrowserOrganization? = nil,
		spaceID: Space.ID? = nil,
		author: Author = .person,
		expiresAt: Date? = nil,
		windowMove: WindowMove? = nil,
		openTabOwners: [Tab.ID: UUID] = [:],
		restoresSelection: Bool = true
	) {
		self.id = id
		self.before = before
		self.after = after
		self.spaceID = spaceID
		self.author = author
		self.expiresAt = expiresAt
		self.windowMove = windowMove
		self.openTabOwners = openTabOwners
		self.restoresSelection = restoresSelection
	}

	/// The step as it is now: an open one ends with `current`.
	public func sealed(with current: BrowserOrganization) -> Self {
		var sealed = self
		if sealed.after == nil { sealed.after = current }
		return sealed
	}

	/// Whether `other` is the same change, as another window holds it.
	public func isSameChange(as other: Self) -> Bool {
		id == other.id
	}

	public static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.before == rhs.before
		&& lhs.after == rhs.after
		&& lhs.spaceID == rhs.spaceID
		&& lhs.author == rhs.author
		&& lhs.expiresAt == rhs.expiresAt
		&& lhs.windowMove == rhs.windowMove
		&& lhs.openTabOwners == rhs.openTabOwners
		&& lhs.restoresSelection == rhs.restoresSelection
	}

	/// Whether the step can still be taken back at `date`.
	public func isAvailable(at date: Date) -> Bool {
		expiresAt.map { date < $0 } ?? true
	}

	/// How long ⌘Z can bring a deleted space back, its tabs and folders with it.
	public static let deletedSpaceGracePeriod: TimeInterval = 60
}
