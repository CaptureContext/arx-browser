import BrowserCore
import Foundation

/// What became of a page's request for new contents: a link opening a new tab or window, or a
/// popup. The engine keeps the last one in debug builds, so an app smoke that times out after a
/// click can say whether the engine ever heard of it and where it stopped (DEV-1191).
///
/// It carries identifiers, revisions and the step that refused, never the URL.
public struct NewContentsRecord: Equatable, Sendable, CustomStringConvertible {
	/// Counts requests from 1 since the engine started, so a smoke can tell a new one from an old one.
	public let sequence: Int
	public let sourceTabID: Tab.ID?

	/// The source's session revision when the request came, which the app's routing compares.
	public let sourceRevision: UInt64?
	public let disposition: Disposition
	public let outcome: Outcome

	public init(
		sequence: Int,
		sourceTabID: Tab.ID?,
		sourceRevision: UInt64?,
		disposition: Disposition,
		outcome: Outcome
	) {
		self.sequence = sequence
		self.sourceTabID = sourceTabID
		self.sourceRevision = sourceRevision
		self.disposition = disposition
		self.outcome = outcome
	}

	public var description: String {
		"#\(sequence) \(disposition.rawValue) \(outcome.rawValue) sourceRevision=\(sourceRevision.map(String.init) ?? "none")"
	}

	public enum Disposition: String, Equatable, Sendable {
		case foregroundTab
		case backgroundTab
		case window
		case popup
	}

	public enum Outcome: String, Equatable, Sendable {
		/// The request's page isn't a tab the engine knows.
		case unknownSource

		/// The source's profile is closing.
		case retiringProfile

		/// A private page asked for an ordinary one, or the other way round.
		case privacyMismatch

		/// The source's document changed since the click.
		case staleDocument

		/// The source page isn't in its host, or its host isn't in a window.
		case noHost

		/// The source's window isn't on screen.
		case windowHidden

		/// The source page is hidden, or none of it is visible.
		case pageHidden

		/// Media observation couldn't start for the new page.
		case mediaFailed

		/// The app declined it: it opened the link its own way, or dropped it.
		case declined

		/// The app took the new page as Chromium made it.
		case adopted
	}
}
