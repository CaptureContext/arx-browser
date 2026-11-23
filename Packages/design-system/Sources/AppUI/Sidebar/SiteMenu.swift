import BrowserCore
import Foundation
import SwiftUI

/// What the URL bar's site menu shows for the current page (DEV-633):
/// share and capture, the profile's extensions, the site's permissions and zoom, and its
/// connection with a "…" menu for clearing its data and opening Settings.
public struct SiteMenu: Equatable, Sendable {
	public enum Connection: Equatable, Sendable {
		/// An https page.
		case secure

		/// An http page.
		case notSecure

		/// Anything else, such as a file or the PDF viewer.
		case local
	}

	public struct Extension: Equatable, Identifiable, Sendable {
		public var id: String
		public var name: String

		/// The manifest icon's bytes (DEV-824); nil shows the letter tile.
		public var icon: Data?

		/// It has an options page Arx can open (DEV-801).
		public var canOpenOptions: Bool

		/// The person may turn it off, or remove it, from its tile's menu (DEV-891).
		public var canTurnOff: Bool
		public var canRemove: Bool

		/// It runs in private windows opened from this profile, and the person may change that
		/// from its tile's menu (DEV-889).
		public var allowedInPrivate: Bool
		public var canAllowInPrivate: Bool

		/// It can run in private windows at all (DEV-956); a private window's menu names the
		/// ones that can't.
		public var canRunInPrivate: Bool

		/// Arx can run its action for a page: a Manifest V3 extension the person installed
		/// (DEV-956). A private window shows only these, as it has no Extensions sheet to fall
		/// back to.
		public var canRunAction: Bool

		/// A store update the automatic check turned down for asking more permissions waits for
		/// the person's review (DEV-1210).
		public var needsUpdateReview: Bool

		public init(
			id: String,
			name: String,
			icon: Data? = nil,
			canOpenOptions: Bool = false,
			canTurnOff: Bool = false,
			canRemove: Bool = false,
			allowedInPrivate: Bool = false,
			canAllowInPrivate: Bool = false,
			canRunInPrivate: Bool = true,
			canRunAction: Bool = true,
			needsUpdateReview: Bool = false
		) {
			self.id = id
			self.name = name
			self.icon = icon
			self.canOpenOptions = canOpenOptions
			self.canTurnOff = canTurnOff
			self.canRemove = canRemove
			self.allowedInPrivate = allowedInPrivate
			self.canAllowInPrivate = canAllowInPrivate
			self.canRunInPrivate = canRunInPrivate
			self.canRunAction = canRunAction
			self.needsUpdateReview = needsUpdateReview
		}

		/// The tile's letter when the extension has no icon to show.
		public var initial: String {
			ExtensionIconImage.initial(name)
		}
	}

	/// One permission row: the site's own setting, or nil when the profile's default applies.
	public struct Permission: Equatable, Identifiable, Sendable {
		public var permission: SitePermission
		public var setting: SitePermissionSetting?
		public var defaultSetting: SitePermissionSetting
		public var isManaged: Bool

		public var id: SitePermission { permission }

		public init(
			permission: SitePermission,
			setting: SitePermissionSetting?,
			defaultSetting: SitePermissionSetting,
			isManaged: Bool = false
		) {
			self.permission = permission
			self.setting = setting
			self.defaultSetting = defaultSetting
			self.isManaged = isManaged
		}

		/// What the site gets now.
		public var effective: SitePermissionSetting { setting ?? defaultSetting }
	}

	public enum ClearKind: String, Equatable, Sendable {
		case cache
		case cookies
	}

	/// A Clear Cache or Clear Cookies in progress: the site is read from the engine and
	/// shown before anything is cleared.
	public enum Clearing: Equatable, Sendable {
		case scoping(ClearKind)
		case confirming(ClearKind, domain: String)
		case clearing(ClearKind, domain: String)
		case cleared(ClearKind, domain: String, isComplete: Bool)
		case failed(ClearKind)

		public var kind: ClearKind {
			switch self {
			case let .scoping(kind), let .confirming(kind, _), let .clearing(kind, _),
				let .cleared(kind, _, _), let .failed(kind):
				kind
			}
		}
	}

	/// The site's engine (DEV-877): whether it opens in WebKit, where protected video plays.
	public struct WebKit: Equatable, Sendable {
		/// The site is on Settings › Advanced › WebKit's list.
		public var isListed: Bool

		/// The page shows in WebKit now.
		public var isShown: Bool

		/// The site's protected video plays only in WebKit (DEV-1188), such as Netflix's: in a
		/// Chromium tab, Arx offers WebKit when its video starts.
		public var playsVideoOnlyInWebKit: Bool

		/// Whether Open in WebKit's switch is on: the site is listed, or the page shows in WebKit
		/// now. A page that moved from the fallback prompt, such as Netflix's off the list
		/// (DEV-1188), is in WebKit, so the switch says so; turning it off moves the page back to
		/// Chromium.
		public var isOn: Bool {
			isListed || isShown
		}

		public init(
			isListed: Bool,
			isShown: Bool,
			playsVideoOnlyInWebKit: Bool = false
		) {
			self.isListed = isListed
			self.isShown = isShown
			self.playsVideoOnlyInWebKit = playsVideoOnlyInWebKit
		}
	}

	/// Translate from the page's language, and the profile's choices for it (DEV-904).
	public struct Translation: Equatable, Sendable {
		/// The page's language, by name, such as "French".
		public var languageName: String
		public var isTranslated: Bool
		public var neverTranslatesSite: Bool
		public var alwaysTranslatesLanguage: Bool

		public init(
			languageName: String,
			isTranslated: Bool,
			neverTranslatesSite: Bool = false,
			alwaysTranslatesLanguage: Bool = false
		) {
			self.languageName = languageName
			self.isTranslated = isTranslated
			self.neverTranslatesSite = neverTranslatesSite
			self.alwaysTranslatesLanguage = alwaysTranslatesLanguage
		}
	}

	/// An element hidden on the site with Hide Element (DEV-1019): a line of uBlock Origin's
	/// My filters and the selector it hides.
	public struct HiddenElement: Equatable, Identifiable, Sendable {
		/// The filter line, which Show takes out of My filters.
		public var id: String
		public var selector: String

		public init(
			id: String,
			selector: String
		) {
			self.id = id
			self.selector = selector
		}
	}

	/// A device the site may use (DEV-905).
	public struct Device: Equatable, Identifiable, Sendable {
		public var id: String
		public var name: String

		/// An SF Symbol for its kind.
		public var symbol: String

		public init(
			id: String,
			name: String,
			symbol: String
		) {
			self.id = id
			self.name = name
			self.symbol = symbol
		}
	}

	/// The window the menu opens in (DEV-1257), which decides the items it shows.
	public var hostWindow: Host
	public var host: String
	public var connection: Connection
	public var profileName: String?
	public var canShare: Bool
	public var canCapture: Bool

	/// Nil hides the Reading Mode tile, behind its feature flag; false shows it dimmed, for a
	/// page reading mode can't read (DEV-1028).
	public var canRead: Bool?

	/// Nil hides the extensions row (no extension runtime, or a private window with no
	/// opener). In a private window, the opener's extensions allowed there (DEV-956).
	public var extensions: [Extension]?

	/// A private window's extensions row: its own empty text, and the names of the opener's
	/// extensions that can't run in private windows, which the row says (DEV-956).
	public var extensionsArePrivate: Bool
	public var unavailableInPrivate: [String]

	/// The extension whose Remove… waits for the person's yes (DEV-891).
	public var removingExtension: Extension?

	/// Nil hides the permission rows (private windows, pages that aren't http(s)).
	public var permissions: [Permission]?

	/// Whether Arx blocks ads and trackers on this site (DEV-884). Nil hides the row: content
	/// blocking is off in Settings, the engine can't do it per site, or a private window.
	public var blocksContent: Bool?

	/// Policy, an extension or supervision keeps content blocking on for this site.
	public var contentBlockingIsManaged: Bool

	/// The Open in WebKit row; nil hides it (WebKit pages off, or a page that isn't https).
	public var webKit: WebKit?

	/// The Dark page row (DEV-1020): whether dark pages darken this site. Nil hides it (dark
	/// pages off, a private window, or a page that isn't a web page).
	public var darkPage: Bool?

	/// The Unread badges row (DEV-1258): the site's own choice and what its tabs get without one.
	/// Nil hides it (a private window, or a page that is not on the web).
	public var unreadBadges: UnreadBadges?

	/// The devices the site may use, each with Forget (DEV-905). Empty or nil hides them.
	public var devices: [Device]?

	/// The elements hidden on the site, each with Show, and Hide Element… (DEV-1019). Nil hides
	/// the section: content blocking off, an engine without it, a private window or a page that
	/// isn't http(s).
	public var hiddenElements: [HiddenElement]?

	/// Hide Element… under them: not on a site with blocking off, where a picked filter
	/// wouldn't apply (DEV-1019).
	public var canHideElement: Bool

	/// The Translate row: shown for a page in another language than the person's, or a
	/// translated one (DEV-904).
	public var translation: Translation?

	/// The site's own zoom when it has one, as a factor.
	public var zoom: Double?
	public var isLoading: Bool
	public var isApplying: Bool

	/// The "…" menu's Clear Cache and Clear Cookies.
	public var canClearSiteData: Bool

	/// Manage Extensions, Add Extension and All Site Settings, for profiles Settings lists.
	public var canOpenSettings: Bool
	public var clearing: Clearing?
	public var notice: String?

	public init(
		hostWindow: Host = .mainWindow,
		host: String,
		connection: Connection,
		profileName: String? = nil,
		canShare: Bool = true,
		canCapture: Bool = true,
		canRead: Bool? = nil,
		extensions: [Extension]? = nil,
		extensionsArePrivate: Bool = false,
		unavailableInPrivate: [String] = [],
		removingExtension: Extension? = nil,
		permissions: [Permission]? = nil,
		blocksContent: Bool? = nil,
		contentBlockingIsManaged: Bool = false,
		webKit: WebKit? = nil,
		darkPage: Bool? = nil,
		unreadBadges: UnreadBadges? = nil,
		devices: [Device]? = nil,
		hiddenElements: [HiddenElement]? = nil,
		canHideElement: Bool = true,
		translation: Translation? = nil,
		zoom: Double? = nil,
		isLoading: Bool = false,
		isApplying: Bool = false,
		canClearSiteData: Bool = false,
		canOpenSettings: Bool = false,
		clearing: Clearing? = nil,
		notice: String? = nil
	) {
		self.hostWindow = hostWindow
		self.host = host
		self.connection = connection
		self.profileName = profileName
		self.canShare = canShare
		self.canCapture = canCapture
		self.canRead = canRead
		self.extensions = extensions
		self.extensionsArePrivate = extensionsArePrivate
		self.unavailableInPrivate = unavailableInPrivate
		self.removingExtension = removingExtension
		self.permissions = permissions
		self.blocksContent = blocksContent
		self.contentBlockingIsManaged = contentBlockingIsManaged
		self.webKit = webKit
		self.darkPage = darkPage
		self.unreadBadges = unreadBadges
		self.devices = devices
		self.hiddenElements = hiddenElements
		self.canHideElement = canHideElement
		self.translation = translation
		self.zoom = zoom
		self.isLoading = isLoading
		self.isApplying = isApplying
		self.canClearSiteData = canClearSiteData
		self.canOpenSettings = canOpenSettings
		self.clearing = clearing
		self.notice = notice
	}

	/// Whether the menu shows `item` in its window (DEV-1257).
	public func shows(_ item: Item) -> Bool {
		hostWindow.shows(item)
	}

	public static func connection(for url: URL?) -> Connection {
		switch url?.scheme?.lowercased() {
		case "https": .secure
		case "http": .notSecure
		default: .local
		}
	}
}

extension SiteMenu {
	/// The windows whose URL bar opens the site menu (DEV-1257). They share one panel; a floating
	/// window leaves out what makes no sense there rather than dimming it.
	public enum Host: CaseIterable, Equatable, Sendable {
		/// A main window's tab, or another browser window's.
		case mainWindow

		/// Little Arx's window.
		case littleArx

		/// Page PiP's floating window, and Little Arx while it floats as Page PiP (DEV-1112).
		case pagePictureInPicture

		/// Whether the menu shows `item` in this window.
		public func shows(_ item: Item) -> Bool {
			switch self {
			case .mainWindow:
				true

			case .littleArx:
				!Item.mainWindowOnly.contains(item)

			case .pagePictureInPicture:
				!Item.mainWindowOnly.contains(item) && !Item.notFloating.contains(item)
			}
		}

		/// Every item the menu shows in this window, in the panel's order.
		public var items: [Item] {
			Item.allCases.filter(shows)
		}
	}

	/// What the site menu can show (DEV-1257): its top row's tiles, then its sections and rows, and
	/// the "…" menu's items. Each shows only where its data does too, such as permissions for an
	/// http(s) page; this is where the window allows it at all.
	public enum Item: CaseIterable, Hashable, Sendable {
		case share
		case captureViewport
		case captureRegion

		/// The Page PiP tile: floats the page (DEV-950), or Little Arx's window (DEV-1112).
		case pagePictureInPicture
		case readingMode

		/// The extensions' tiles and their menus.
		case extensions

		/// `+` and the "…" menu's Add Extension: the Chrome Web Store in a new Little Arx of the
		/// page's profile (DEV-1317).
		case addExtension

		/// The "…" menu's Manage Extensions, and the row's Manage.
		case manageExtensions
		case permissions
		case contentBlocking
		case zoom
		case translation
		case devices

		/// The elements hidden on the site, each with Show (DEV-1019).
		case hiddenElements

		/// Hide Element…, uBlock's picker over the page (DEV-1019).
		case hideElement

		/// Open in WebKit (DEV-877).
		case webKit

		/// The Dark page switch (DEV-1020).
		case darkPage

		/// The Unread badges choice for the site (DEV-1258).
		case unreadBadges

		/// The "…" menu's Clear Cache and Clear Cookies.
		case clearSiteData

		/// The "…" menu's All Site Settings.
		case allSiteSettings

		/// Items whose action belongs to a main window: Translate, Hide Element and Dark page are
		/// commands only a main window's page takes.
		/// Unread badges show only in a main window's sidebar.
		fileprivate static let mainWindowOnly: Set<Item> = [
			.translation, .hideElement, .darkPage, .unreadBadges,
		]

		/// Items a floating page can't take: capture has nowhere in the window to draw its controls,
		/// the page already floats, the window shows the page without its reader, and moving the
		/// page to WebKit would take it from the window that holds it.
		fileprivate static let notFloating: Set<Item> = [
			.captureViewport, .captureRegion, .pagePictureInPicture, .readingMode, .webKit,
		]

		/// The item an action comes from; nil for opening, closing and answers to a question the
		/// panel asked, which any window may send.
		public init?(_ action: SiteMenuAction) {
			switch action {
			case .share: self = .share
			case .captureViewport: self = .captureViewport
			case .captureRegion: self = .captureRegion
			case .pagePictureInPicture: self = .pagePictureInPicture
			case .readingMode: self = .readingMode
			case .runExtension, .openExtensionOptions, .turnOffExtension, .setExtensionAllowedInPrivate,
				.requestExtensionRemoval, .reviewExtensionUpdate:
				self = .extensions
			case .addExtension: self = .addExtension
			case .manageExtensions, .showExtension: self = .manageExtensions
			case .setPermission: self = .permissions
			case .setContentBlocking: self = .contentBlocking
			case .resetZoom: self = .zoom
			case .translate, .setNeverTranslate, .setAlwaysTranslate: self = .translation
			case .forgetDevice: self = .devices
			case .showHiddenElement: self = .hiddenElements
			case .hideElement: self = .hideElement
			case .setWebKit: self = .webKit
			case .setDarkPage: self = .darkPage
			case .setUnreadBadges: self = .unreadBadges
			case .requestClear: self = .clearSiteData
			case .allSiteSettings: self = .allSiteSettings
			case .opened, .closed, .confirmExtensionRemoval, .cancelExtensionRemoval, .confirmClear,
				.cancelClear, .dismissNotice:
				return nil
			}
		}
	}
}

extension SiteMenu {
	/// One of the buttons at the top of the menu (DEV-1333): two rows of four, the one-shot actions
	/// first and the page's modes under them.
	public struct Key: Equatable, Identifiable, Sendable {
		public enum ID: CaseIterable, Hashable, Sendable {
			case share
			case captureRegion
			case capturePage
			case hideElement
			case pagePictureInPicture
			case readingMode
			case webKit
			case darkPage

			/// The menu item the key belongs to, which decides the windows that show it.
			public var item: Item {
				switch self {
				case .share: .share
				case .captureRegion: .captureRegion
				case .capturePage: .captureViewport
				case .hideElement: .hideElement
				case .pagePictureInPicture: .pagePictureInPicture
				case .readingMode: .readingMode
				case .webKit: .webKit
				case .darkPage: .darkPage
				}
			}
		}

		public var id: ID

		/// False dims the key: the page can't take it, such as Reader on a page without an article.
		public var isEnabled: Bool

		/// A switch's state, which the key shows and VoiceOver reads; nil for an action.
		public var isOn: Bool?

		public init(
			_ id: ID,
			isEnabled: Bool = true,
			isOn: Bool? = nil
		) {
			self.id = id
			self.isEnabled = isEnabled
			self.isOn = isOn
		}
	}

	/// How many keys a row holds.
	public static let keysPerRow: Int = 4

	/// The keys the menu shows in its window, in order: Share, Capture Area, Capture Page and Hide
	/// Element, then Picture in Picture, Reader, Open in WebKit and Dark page (DEV-1333). A key the
	/// window allows but the page can't take is dimmed, so the rows keep their places; Reader stays
	/// hidden behind its feature flag.
	public var keys: [Key] {
		Key.ID.allCases.compactMap { id -> Key? in
			guard shows(id.item) else { return nil }

			switch id {
			case .share:
				return .init(id, isEnabled: canShare)

			case .captureRegion, .capturePage:
				return .init(id, isEnabled: canCapture)

			case .hideElement:
				return .init(id, isEnabled: hiddenElements != nil && canHideElement)

			case .pagePictureInPicture:
				return .init(id)

			case .readingMode:
				guard let canRead else { return nil }
				return .init(id, isEnabled: canRead)

			case .webKit:
				return .init(id, isEnabled: webKit != nil && !isApplying, isOn: webKit?.isOn ?? false)

			case .darkPage:
				return .init(id, isEnabled: darkPage != nil && !isApplying, isOn: darkPage ?? false)
			}
		}
	}

	/// The keys in rows of ``keysPerRow``.
	public var keyRows: [[Key]] {
		let keys = self.keys
		return stride(from: 0, to: keys.count, by: Self.keysPerRow).map {
			Array(keys[$0..<min($0 + Self.keysPerRow, keys.count)])
		}
	}
}

extension SiteMenu {
	/// A site's choice in a menu pop-up (DEV-1333): what the site stores, nil to follow the default,
	/// and what the default gives. Closed, the pop-up shows only the value the site gets, such as
	/// "Ask"; open, it lists "Default (Ask)" and then each option, checking what's stored.
	public struct Choice<Value: Hashable & Sendable>: Equatable, Sendable {
		public struct Entry: Equatable, Hashable, Sendable {
			/// Nil is the default entry.
			public var value: Value?
			public var isChecked: Bool

			public init(
				value: Value?,
				isChecked: Bool
			) {
				self.value = value
				self.isChecked = isChecked
			}
		}

		public var stored: Value?
		public var inherited: Value
		public var options: [Value]

		public init(
			stored: Value?,
			inherited: Value,
			options: [Value]
		) {
			self.stored = stored
			self.inherited = inherited
			self.options = options
		}

		/// What the closed pop-up shows: the value the site gets.
		public var effective: Value {
			stored ?? inherited
		}

		public var isDefault: Bool {
			stored == nil
		}

		/// The open menu: the default entry, then each option; the stored one is checked.
		public var entries: [Entry] {
			[.init(value: nil, isChecked: stored == nil)]
			+ options.map { .init(value: $0, isChecked: stored == $0) }
		}
	}
}

extension SiteMenu.Permission {
	/// The row's pop-up (DEV-1333).
	public var choice: SiteMenu.Choice<SitePermissionSetting> {
		.init(stored: setting, inherited: defaultSetting, options: permission.siteSettings)
	}
}

extension SiteMenu.UnreadBadges {
	/// The row's pop-up (DEV-1333).
	public var choice: SiteMenu.Choice<UnreadBadgeVisibility> {
		.init(stored: site, inherited: inherited, options: UnreadBadgeVisibility.allCases)
	}
}

extension SiteMenu {
	/// The site's unread badges choice (DEV-1258), or nil while it inherits, and what it inherits
	/// from the profile or the browser default.
	public struct UnreadBadges: Equatable, Sendable {
		public var site: UnreadBadgeVisibility?
		public var inherited: UnreadBadgeVisibility

		public init(
			site: UnreadBadgeVisibility?,
			inherited: UnreadBadgeVisibility
		) {
			self.site = site
			self.inherited = inherited
		}
	}
}

public enum SiteMenuAction: Equatable, Sendable {
	/// The panel opened or closed.
	case opened
	case closed
	case share
	case captureViewport
	case captureRegion

	/// Floats the page in Page PiP (DEV-950).
	case pagePictureInPicture

	/// Reading Mode for the page (DEV-1028).
	case readingMode
	case manageExtensions

	/// The profile's Extensions sheet, on that extension (DEV-801): its tile's Manage Extensions.
	case showExtension(String)

	/// The profile's Extensions sheet, with the review of this extension's update that waits for
	/// it (DEV-1210).
	case reviewExtensionUpdate(String)

	/// An extension's tile: runs its action for the page, so its popup opens at the
	/// point, the tile's in AppKit screen coordinates (DEV-828).
	case runExtension(String, screenPoint: CGPoint)

	/// The extension's options page, from its tile's menu (DEV-801).
	case openExtensionOptions(String)

	/// Turns the extension off in this profile, from its tile's menu (DEV-891).
	case turnOffExtension(String)

	/// Allow in Private Windows, from its tile's menu (DEV-889).
	case setExtensionAllowedInPrivate(String, Bool)

	/// Remove… from its tile's menu asks first; the answer removes it or not (DEV-891).
	case requestExtensionRemoval(String)
	case confirmExtensionRemoval
	case cancelExtensionRemoval

	/// `+`: the Chrome Web Store in a new Little Arx of the page's profile (DEV-1317).
	case addExtension

	/// Nil goes back to the profile's default.
	case setPermission(SitePermission, SitePermissionSetting?)

	/// Turns content blocking off for the site, or back on (DEV-884).
	case setContentBlocking(Bool)

	/// Lists the site for WebKit and moves the page there, or takes it off the list and moves
	/// the page back to Chromium (DEV-877).
	case setWebKit(Bool)

	/// Dark pages for this site: on, or off so it keeps its own look (DEV-1020).
	case setDarkPage(Bool)

	/// The site's unread badges (DEV-1258): shown or hidden on its tabs and Favorites, or nil to
	/// follow the profile and the browser default.
	case setUnreadBadges(UnreadBadgeVisibility?)

	/// Forget: the site may no longer use this device without asking (DEV-905).
	case forgetDevice(String)

	/// Hide Element… on the page (DEV-1019).
	case hideElement

	/// Shows a hidden element again: its filter line (DEV-1019).
	case showHiddenElement(String)

	/// Translates the page, or shows the original (DEV-904).
	case translate(Bool)
	case setNeverTranslate(Bool)
	case setAlwaysTranslate(Bool)
	case resetZoom
	case requestClear(SiteMenu.ClearKind)
	case confirmClear
	case cancelClear
	case allSiteSettings
	case dismissNotice
}

/// The menu for the URL bar's page, with where its actions go. Without one the URL bar
/// shows the page's address only, as the tour does.
public struct SiteMenuSource: Sendable {
	public var menu: SiteMenu?
	public var send: @MainActor @Sendable (SiteMenuAction) -> Void

	public init(
		menu: SiteMenu?,
		send: @escaping @MainActor @Sendable (SiteMenuAction) -> Void
	) {
		self.menu = menu
		self.send = send
	}
}

extension EnvironmentValues {
	@Entry
	public var siteMenu: SiteMenuSource? = nil
}
