import AppKit
import BrowserCore
import Foundation

/// What Hide Element's mode tells the app as it goes on a tab (DEV-1298): the picker stays open
/// over the page, each pick hidden and saved to My filters, until Done.
public enum BrowserElementHidingEvent: Equatable, Sendable {
	/// The engine can't run the mode on the tab's page; nothing opened.
	case unavailable

	/// The mode is open over the page and takes commands.
	case opened

	/// A pick went from the page and `filter`, `site##selector`, into My filters.
	case hidden(filter: String, element: BrowserHiddenElementDescription)

	/// A pick went from the page, but the engine wouldn't save `filter`.
	case refused(filter: String)

	/// The outline's box in the page's points from its top-left corner; nil while there's none.
	case target(CGRect?)

	/// What each line hides on the page, nil where nothing on it matches.
	case described([String: BrowserHiddenElementDescription?])

	/// An element shown again: whether it shows now, or waits for the page to load again.
	case shown(filter: String, isVisible: Bool)

	/// A key the app answers.
	case key(BrowserElementHidingKey)
}

/// A hidden element as a list shows it (DEV-1298): the name the outline's label gave it and its
/// kind.
public struct BrowserHiddenElementDescription: Equatable, Sendable {
	public var label: String
	public var kind: Kind

	public init(
		label: String,
		kind: Kind
	) {
		self.label = label
		self.kind = kind
	}

	/// What kind of thing it is, from its role or tag.
	public enum Kind: String, CaseIterable, Equatable, Sendable {
		case link
		case button
		case image
		case video
		case audio
		case frame
		case list
		case listItem = "listitem"
		case navigation
		case banner
		case footer = "contentinfo"
		case sidebar = "complementary"
		case form
		case dialog
		case section = "region"
		case article
		case textField = "textbox"
		case heading
		case paragraph
		case table
		case element

		/// The script's name for it; anything it doesn't know is an element.
		public init(script name: String) {
			self = Self(rawValue: name) ?? .element
		}
	}
}

/// The keys Hide Element's mode leaves to the app (DEV-1298).
public enum BrowserElementHidingKey: Equatable, Sendable {
	/// Done, or closing the open list.
	case escape

	/// Opens or closes the list of hidden elements.
	case `return`

	/// ⌘Z or Edit › Undo.
	case undo

	/// ↑ and ↓ while the list is open.
	case up
	case down

	/// Delete while the list is open.
	case delete
}

/// What the app asks of Hide Element's mode on a tab (DEV-1298).
public enum BrowserElementHidingCommand: Equatable, Sendable {
	/// Shows the element of a line this session hid again. Taking the line out of My filters is
	/// `showHiddenElement`'s.
	case unhide(String)

	/// Names what each line hides on the page.
	case describe([String])

	/// The toast's list opened or closed: while it's open, ↑, ↓ and Delete are the list's.
	case listOpen(Bool)

	/// Done: the picker closes and the event stream ends.
	case close
}
