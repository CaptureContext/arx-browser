/// Which modifier keys open a clicked link in Little Arx.
///
/// Both choices include Command, because pages can't tell these apart from Chromium's
/// own new-tab clicks and a choice without it would take over Option's download click.
public enum LittleArxLinkBinding: String, CaseIterable, Codable, Equatable, Sendable {
	case optionCommand
	case shiftOptionCommand
	case off
}

/// Where a Shift-click on a page link opens it (DEV-1239).
public enum ShiftClickLinkAction: String, CaseIterable, Codable, Equatable, Sendable {
	case peek
	case littleArx
	case newTab

	/// Chromium's own Shift-click, which Arx leaves alone.
	case newWindow
}

/// Where a Force Click on a page link opens it.
public enum ForceClickLinkAction: String, CaseIterable, Codable, Equatable, Sendable {
	case peek
	case littleArx
	case newTab

	/// Chromium's own Force Click, which Arx leaves alone: the system Look Up. Settings call it
	/// Look Up; the stored name is older than the other choices (DEV-1239).
	case off
}

/// How the Runway looks: the panel at the pointer that asks which profile a link from another
/// app opens in, when its route asks for a destination.
public enum RunwayAppearance: String, CaseIterable, Codable, Equatable, Sendable {
	/// A panel with the link, a search field and Close, the profiles in a glass tile, and the
	/// keys that open and drop the link.
	case regular

	/// Only the search field, Close and the profiles, each on its own glass, with no panel
	/// behind them.
	case compact
}

/// Where a plain click on a link to another site opens it, from a tab whose kind Settings
/// give a choice: a Favorite, or a pinned tab in a space or its folders (DEV-727, DEV-1239).
public enum CrossSiteLinkAction: String, CaseIterable, Codable, Equatable, Sendable {
	case peek
	case littleArx
	case newTab

	/// The link is followed in its tab, as in any other.
	case currentTab
}

/// Where the Little Arx bar opens on the screen.
public enum LittleArxLauncherPosition: String, CaseIterable, Codable, Equatable, Sendable {
	case topRight
	case topCenter
	case topLeft
	case center
}
