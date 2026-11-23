import Foundation

/// The one button the sidebar URL bar keeps for its page, before Copy Link and the site menu
/// (DEV-1254). The URL bar keeps one slot and fills it
/// by this rule:
///
/// 1. Reading mode while the page is read: it's the way back.
/// 2. Else an extension the person pinned to the URL bar. A pin is the person's own choice, and
///    it belongs to the profile, not the page, so it never comes and goes while a page loads.
/// 3. Else reading mode on a page with an article.
/// 4. Else nothing, and the address takes the room.
///
/// The slot changes only once a page has settled: loaded, and checked for an article. From the
/// moment another page commits until then, a slot that had a button keeps its room, empty, so
/// the address and the buttons beside it don't move twice for one navigation. Reading mode
/// stays in the site menu and the command bar when a pin takes its place.
public enum URLBarPageButton: Equatable, Sendable {
	/// Reading mode, lit while the page is read.
	case readingMode(isReading: Bool)

	/// The extension the person pinned to the URL bar, by its ID.
	case pinnedExtension(String)

	/// The room of the button that was there, held while the next page settles.
	case reserved

	/// What the rule reads about the page, each from state that changes once per page rather
	/// than on every loading tick.
	public struct Signals: Equatable, Sendable {
		/// Reading mode is open over the page.
		public var isReading: Bool

		/// The page's article check said it has one.
		public var isReadable: Bool

		/// The page has loaded and its article check has answered, or it gets none.
		public var isSettled: Bool

		/// The first extension pinned to the URL bar that can run on this page.
		public var pinnedExtensionID: String?

		public init(
			isReading: Bool = false,
			isReadable: Bool = false,
			isSettled: Bool = true,
			pinnedExtensionID: String? = nil
		) {
			self.isReading = isReading
			self.isReadable = isReadable
			self.isSettled = isSettled
			self.pinnedExtensionID = pinnedExtensionID
		}
	}

	/// The slot's button for `signals`, after `previous` was shown; nil leaves no slot.
	public static func next(
		after previous: Self?,
		_ signals: Signals
	) -> Self? {
		if signals.isReading { return .readingMode(isReading: true) }
		if let id = signals.pinnedExtensionID { return .pinnedExtension(id) }
		if signals.isReadable { return .readingMode(isReading: false) }
		guard !signals.isSettled, previous != nil else { return nil }
		return .reserved
	}
}
