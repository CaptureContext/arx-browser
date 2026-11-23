import AppKit

/// Which hover preview a window shows (DEV-1288): at most one, whatever its kind (a tab's,
/// a Favorite's or a folder's card, or the Library's recent downloads).
///
/// A preview asks before it opens. With nothing shown, or with its own preview shown, it opens.
/// Over another preview it opens too, and that one closes first, unless the other is held:
/// its folder search has the keyboard or text, it has the keyboard, or the pointer is on it.
/// A held preview gives way only to a preview that has settled, opened after the pointer rested
/// on its row for the whole hover delay or with Shift, never to one a passing pointer opened
/// at once right after another preview closed.
internal struct SidebarHoverPreviewExclusivity<ID: Hashable>: Equatable {
	internal enum Decision: Equatable {
		/// Show the preview, once `replacing`, the one shown until now, has gone.
		case open(replacing: ID?)

		/// Leave it closed: the preview shown is held.
		case refuse
	}

	/// The preview the window shows, or nil.
	internal private(set) var current: ID?

	/// Whether the current preview is held, so only a settled one replaces it.
	internal private(set) var isHeld: Bool

	internal init() {
		self.current = nil
		self.isHeld = false
	}

	internal mutating func request(
		_ id: ID,
		isSettled: Bool
	) -> Decision {
		guard let shown = current, shown != id else {
			if current == nil { isHeld = false }
			current = id
			return .open(replacing: nil)
		}
		guard !isHeld || isSettled else { return .refuse }

		current = id
		isHeld = false
		return .open(replacing: shown)
	}

	/// The preview is held or let go. Only the current preview's word counts.
	internal mutating func hold(
		_ id: ID,
		_ isHeld: Bool
	) {
		guard current == id else { return }
		self.isHeld = isHeld
	}

	/// The preview closed. A preview that was already replaced changes nothing.
	internal mutating func release(_ id: ID) {
		guard current == id else { return }
		current = nil
		isHeld = false
	}
}

/// A shown hover preview, as its window's owner sees it.
@MainActor
internal protocol SidebarHoverPreviewPresentation: AnyObject {
	/// Another preview replaces this one: it goes at once, before the other is shown.
	func evict()
}

/// The one owner of a window's hover preview (DEV-1288). Every hover panel in the window asks it
/// before showing, so a second preview can't appear beside the first: the first is ordered out
/// before the second is ordered in, in the same turn of the main thread.
@MainActor
internal final class SidebarHoverPreviewOwner {
	private var state: SidebarHoverPreviewExclusivity<ObjectIdentifier>
	private weak var current: (any SidebarHoverPreviewPresentation)?

	internal init() {
		self.state = .init()
		self.current = nil
	}

	/// The preview the window shows, if it's still alive.
	internal var shown: (any SidebarHoverPreviewPresentation)? {
		current
	}

	/// Whether `preview` may show. If it replaces another, that one has been evicted on return.
	internal func request(
		_ preview: any SidebarHoverPreviewPresentation,
		isSettled: Bool
	) -> Bool {
		// A preview whose view went away without closing no longer holds the window.
		if current == nil, let stale = state.current { state.release(stale) }

		switch state.request(ObjectIdentifier(preview), isSettled: isSettled) {
		case .refuse:
			return false

		case let .open(replacing):
			let previous = replacing == nil ? nil : current
			current = preview
			previous?.evict()
			return true
		}
	}

	internal func hold(
		_ preview: any SidebarHoverPreviewPresentation,
		_ isHeld: Bool
	) {
		state.hold(ObjectIdentifier(preview), isHeld)
	}

	internal func release(_ preview: any SidebarHoverPreviewPresentation) {
		guard current === preview else { return }
		state.release(ObjectIdentifier(preview))
		current = nil
	}

	// MARK: - One per window

	private static var owners: [ObjectIdentifier: Entry] = [:]

	private struct Entry {
		internal weak var window: NSWindow?
		internal var owner: SidebarHoverPreviewOwner
	}

	/// The owner of `window`'s hover preview, made the first time the window asks.
	internal static func owner(for window: NSWindow) -> SidebarHoverPreviewOwner {
		owners = owners.filter { $0.value.window != nil }
		let key = ObjectIdentifier(window)
		if let entry = owners[key], entry.window === window { return entry.owner }

		let owner = SidebarHoverPreviewOwner()
		owners[key] = .init(window: window, owner: owner)
		return owner
	}
}
