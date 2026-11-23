import Foundation

/// Whether a page holds form input a person typed and hasn't sent, in any of its frames
/// (DEV-1084). The engine reads only this answer, never the input.
public enum BrowserFormEdits: Equatable, Sendable {
	/// Nothing typed, or nothing to lose: an unloaded, crashed or closing page, or one that isn't
	/// on the web.
	case clean

	/// A frame holds typed input: a changed or filled field, a changed choice, or an editable area
	/// with text.
	case typed

	/// The engine couldn't tell: a frame didn't answer in time, the page has more frames than it
	/// reads, or the page changed meanwhile.
	case unknown
}
