import Foundation

/// What hover previews show beyond a tab's card, from Settings › General › Previews (DEV-802,
/// DEV-730). Each needs Previews on hover as well.
///
/// Missing keys, from builds before a source existed, keep their default.
public struct HoverPreviewSources: Codable, Equatable, Sendable {
	/// A folder lists its tabs. Off, a folder shows only its title as a tooltip.
	public var folders: Bool

	/// A Gmail favorite that's open lists its unread mail, read from the page in its own profile.
	public var mail: Bool

	/// A Linear, Notion or Figma favorite lists the pages its profile visited there most recently.
	public var recentPages: Bool

	/// A tab whose page isn't loaded shows the picture and description the site publishes for
	/// it (Open Graph). Fetched without cookies, or with `ARX_SITE_PREVIEW_IMAGES` with the
	/// cookies the tab's profile sends the page's own host (DEV-1142).
	public var pageDetails: Bool

	/// Full previews: a tab whose page isn't loaded and has no saved picture loads off screen
	/// to take one. Off by default, because it runs the page.
	public var fullPages: Bool

	/// Shift + hover loads the page instantly (DEV-1029): Shift-hover over a tab whose page isn't
	/// loaded loads it off screen at once for a fresh picture, whatever `fullPages` says. Off by
	/// default, because it runs the page.
	public var shiftLoadsPages: Bool

	/// Live Calendar (DEV-804, behind `ARX_LIVE_CALENDAR`): a Google Calendar favorite shows
	/// today's day, read from the calendar's own page in the favorite's profile.
	public var calendars: Bool

	/// Calendar favorites whose card was set back to the ordinary one with Disable Live
	/// Calendar. Turning `calendars` on again in Settings clears it.
	public var disabledCalendars: Set<UUID>

	public init(
		folders: Bool = true,
		mail: Bool = true,
		recentPages: Bool = true,
		pageDetails: Bool = true,
		fullPages: Bool = false,
		shiftLoadsPages: Bool = false,
		calendars: Bool = true,
		disabledCalendars: Set<UUID> = []
	) {
		self.folders = folders
		self.mail = mail
		self.recentPages = recentPages
		self.pageDetails = pageDetails
		self.fullPages = fullPages
		self.shiftLoadsPages = shiftLoadsPages
		self.calendars = calendars
		self.disabledCalendars = disabledCalendars
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.folders = (try? values.decodeIfPresent(Bool.self, forKey: .folders)) ?? true
		self.mail = (try? values.decodeIfPresent(Bool.self, forKey: .mail)) ?? true
		self.recentPages = (try? values.decodeIfPresent(Bool.self, forKey: .recentPages)) ?? true
		self.pageDetails = (try? values.decodeIfPresent(Bool.self, forKey: .pageDetails)) ?? true
		self.fullPages = (try? values.decodeIfPresent(Bool.self, forKey: .fullPages)) ?? false
		self.shiftLoadsPages = (try? values.decodeIfPresent(Bool.self, forKey: .shiftLoadsPages)) ?? false
		self.calendars = (try? values.decodeIfPresent(Bool.self, forKey: .calendars)) ?? true
		self.disabledCalendars = (try? values.decodeIfPresent(Set<UUID>.self, forKey: .disabledCalendars)) ?? []
	}
}

/// What a hover card shows for a page that isn't loaded and has no saved picture: Settings ›
/// General › Previews' choice under `ARX_SITE_PREVIEW_IMAGES` (DEV-1142). It reads and writes
/// `pageDetails` and `fullPages`, so the saved preferences keep their shape and the flag can go
/// off again without losing anything.
public enum UnloadedPagePreview: String, CaseIterable, Hashable, Sendable {
	/// The picture and description the site publishes for the page, read from its HTML head
	/// without running it. The default.
	case sitePicture

	/// The page loads out of sight to take a picture (Full previews), with the site's picture
	/// when that fails.
	case loadPage

	/// Only the picture Arx took while the page was open; nothing is requested.
	case savedPicture
}

extension HoverPreviewSources {
	public var unloadedPages: UnloadedPagePreview {
		get {
			if fullPages { return .loadPage }
			return pageDetails ? .sitePicture : .savedPicture
		}
		set {
			switch newValue {
			case .sitePicture:
				pageDetails = true
				fullPages = false

			case .loadPage:
				pageDetails = true
				fullPages = true

			case .savedPicture:
				pageDetails = false
				fullPages = false
			}
		}
	}
}
