import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserExtensionsClient
import BrowserWorkspaceClient
import Foundation
import PageTranslationClient
import _ComposableArchitecture

/// The URL bar's site menu (DEV-633): the page's profile's extensions, the site's
/// permissions and zoom from Chromium, and Clear Cache and Clear Cookies for the site
/// alone. Opening reads everything again; closing stops reading but lets a clear finish.
@Reducer
public struct SiteMenuFeature {
	/// The page and profile the menu opened over.
	public struct Context: Equatable, Sendable {
		public var url: URL

		/// The tab whose page the menu describes, when it has one (DEV-828).
		public var tabID: BrowserCore.Tab.ID?
		public var profileID: Profile.ID
		public var profileName: String?
		public var isPrivate: Bool

		/// The ordinary profile a private window belongs to (DEV-956): its extensions allowed
		/// in private windows run there. Nil for an ordinary page.
		public var openerProfileID: Profile.ID?
		public var canCapture: Bool

		/// Reading Mode, behind its feature flag: nil hides it, false dims it (DEV-1028).
		public var canRead: Bool?

		/// The page failed to load, such as a certificate or TLS error.
		public var loadFailed: Bool

		/// The page shows in WebKit (DEV-877).
		public var usesWebKit: Bool

		/// Whether dark pages darken this site (DEV-1020); nil while they aren't offered here.
		public var darkPage: Bool?

		/// The page's profile's unread badges choice (DEV-1258), which the site's inherits with the
		/// browser default; nil while the profile inherits.
		public var profileUnreadBadges: UnreadBadgeVisibility?

		public init(
			url: URL,
			tabID: BrowserCore.Tab.ID? = nil,
			profileID: Profile.ID,
			profileName: String? = nil,
			isPrivate: Bool = false,
			openerProfileID: Profile.ID? = nil,
			canCapture: Bool = false,
			canRead: Bool? = nil,
			loadFailed: Bool = false,
			usesWebKit: Bool = false,
			darkPage: Bool? = nil,
			profileUnreadBadges: UnreadBadgeVisibility? = nil
		) {
			self.url = url
			self.tabID = tabID
			self.profileID = profileID
			self.profileName = profileName
			self.isPrivate = isPrivate
			self.openerProfileID = openerProfileID
			self.canCapture = canCapture
			self.canRead = canRead
			self.loadFailed = loadFailed
			self.usesWebKit = usesWebKit
			self.darkPage = darkPage
			self.profileUnreadBadges = profileUnreadBadges
		}

		/// `scheme://host[:port]` for an http(s) page, as site settings list it. Built from
		/// the address's parts, so a long path or query doesn't matter.
		public var origin: String? {
			guard
				let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
				let scheme = components.scheme,
				let host = components.encodedHost
			else { return nil }

			let port = components.port.map { ":\($0)" } ?? ""
			return SiteSettings.origin("\(scheme)://\(host)\(port)")
		}

		public var zoomHost: String? {
			origin.flatMap(SiteSettings.zoomHost)
		}

		/// The profile whose extensions the menu shows: the page's, or a private window's opener.
		public var extensionsProfileID: Profile.ID? {
			isPrivate ? openerProfileID : profileID
		}

		/// Secure only for an https page that loaded.
		public var connection: SiteMenu.Connection {
			let connection = SiteMenu.connection(for: url)
			return connection == .secure && loadFailed ? .notSecure : connection
		}
	}

	@ObservableState
	public struct State: Equatable {
		/// The window the menu opens in (DEV-1257): a main window's, Little Arx's or Page PiP's.
		/// It decides which items the panel shows and which actions the menu takes.
		public var host: SiteMenu.Host
		public var context: Context?
		public var isOpen: Bool

		/// Enabled extensions; nil until read, or when the profile has none to show.
		public var extensions: [SiteMenu.Extension]?
		public var extensionsAvailable: Bool
		public var isLoadingExtensions: Bool
		public var settings: SiteSettings?
		public var settingsAvailable: Bool
		public var isLoadingSettings: Bool
		public var isApplying: Bool
		public var siteDataAvailable: Bool
		public var clearing: SiteMenu.Clearing?

		/// The page a clear in progress belongs to, and its request: a late reply for an
		/// earlier request, or another page, is ignored.
		public var clearContext: Context?
		public var clearRequest: Int
		public var settingsFailed: Bool

		/// The extension whose Remove… waits for an answer, and whether a Turn Off or
		/// Remove is running (DEV-891).
		public var removingExtensionID: String?
		public var isChangingExtension: Bool
		public var extensionChangeFailed: Bool

		/// Settings › General › Content blocking (DEV-884).
		@SharedReader
		public var general: GeneralPreferences

		/// The devices the site may use, read when the menu opens (DEV-905).
		public var devices: [BrowserDeviceGrant]

		/// The `ARX_HIDE_ELEMENT` feature flag, which the app sets (DEV-1019): Hide Element and
		/// the Hidden Elements section. Off by default.
		public var hideElementEnabled: Bool

		/// The filters that hide elements on the page's site, read when the menu opens (DEV-1019);
		/// nil while they're read or when Hide Element isn't available for the page.
		public var hiddenElements: [String]?

		/// The page's language, read when the menu opens, when it isn't the person's (DEV-904).
		public var pageLanguage: String?

		/// The language each translated tab was translated from; the app keeps it (DEV-904).
		public var translatedTabs: [BrowserCore.Tab.ID: String]

		/// Each profile's Never and Always translate choices (DEV-904).
		@Shared
		public var translation: TranslationPreferences

		/// Settings › Advanced › WebKit's list, which Open in WebKit edits (DEV-877).
		@Shared
		public var webKitPages: WebKitPagePreferences

		/// The sites' own unread badges choices, which the Unread badges row edits (DEV-1258).
		@Shared
		public var unreadBadgeOverrides: UnreadBadgeOverrides

		/// The FairPlay sites Arx's helper can play in Chromium tabs now, before Settings'
		/// Protected media; the app keeps it (DEV-1151). Empty without the bridge.
		public var fairPlayOrigins: Set<String>

		public init(host: SiteMenu.Host = .mainWindow) {
			self.host = host
			self.context = nil
			self.isOpen = false
			self.extensions = nil
			self.extensionsAvailable = false
			self.isLoadingExtensions = false
			self.settings = nil
			self.settingsAvailable = false
			self.isLoadingSettings = false
			self.isApplying = false
			self.siteDataAvailable = false
			self.clearing = nil
			self.clearContext = nil
			self.clearRequest = 0
			self.settingsFailed = false
			self.removingExtensionID = nil
			self.isChangingExtension = false
			self.extensionChangeFailed = false
			self._general = SharedReader(.general)
			self.devices = []
			self.hideElementEnabled = false
			self.hiddenElements = nil
			self.pageLanguage = nil
			self.translatedTabs = [:]
			self._translation = Shared(.translation)
			self._webKitPages = Shared(.webKitPages)
			self._unreadBadgeOverrides = Shared(.unreadBadgeOverrides)
			self.fairPlayOrigins = []
		}

		/// The Translate row (DEV-904): a translated tab, or a page in another language than the
		/// person's that isn't a Never translate site.
		fileprivate var translationRow: SiteMenu.Translation? {
			guard
				let context,
				!context.isPrivate,
				!context.usesWebKit,
				let tabID = context.tabID
			else { return nil }

			let preferences = translation[context.profileID]
			let translatedFrom = translatedTabs[tabID]
			guard let language = translatedFrom ?? pageLanguage else { return nil }
			if translatedFrom == nil, preferences.neverTranslates(context.url) { return nil }
			return .init(
				languageName: Locale.current.localizedString(forIdentifier: language) ?? language,
				isTranslated: translatedFrom != nil,
				neverTranslatesSite: preferences.neverTranslates(context.url),
				alwaysTranslatesLanguage: preferences.alwaysTranslates(language)
			)
		}

		/// The Unread badges row (DEV-1258): an ordinary web page's site's choice and what
		/// the site inherits from the profile and the browser default.
		fileprivate var unreadBadgesRow: SiteMenu.UnreadBadges? {
			guard
				let context,
				!context.isPrivate,
				SiteMenu.connection(for: context.url) != .local,
				let host = BrowserCore.Tab.unreadBadgeHost(of: context.url)
			else { return nil }

			return .init(
				site: unreadBadgeOverrides.sites[host],
				inherited: UnreadBadgeVisibility.resolve(
					tab: nil,
					site: nil,
					profile: context.profileUnreadBadges,
					browser: .init(shows: general.showsUnreadBadges)
				)
			)
		}

		/// What the panel shows; nil until the menu has a page.
		public var menu: SiteMenu? {
			guard let context else { return nil }

			let ordinary = !context.isPrivate
			let origin = context.origin
			let permissions: [SiteMenu.Permission]? = {
				guard ordinary, settingsAvailable, let origin else { return nil }
				guard let settings else { return [] }

				return SitePermission.allCases.map { settings.menuRow($0, origin: origin) }
			}()
			let zoom = context.zoomHost.flatMap { settings?.zoom(for: $0) }
			let blocksContent: Bool? = {
				guard
					ordinary,
					general.blocksContent,
					let origin,
					let settings,
					settings.contentBlockingIsAvailable
				else { return nil }

				return settings.blocksContent(on: origin)
			}()

			// DEV-956: a private window shows its opener's extensions allowed there, and names
			// the ones that can't run in private windows.
			let shownExtensions = extensionsAvailable ? extensions : nil
			let tiles = ordinary ? shownExtensions : shownExtensions?.filter { $0.allowedInPrivate && $0.canRunInPrivate && $0.canRunAction }
			let unavailableInPrivate = ordinary ? [] : (shownExtensions ?? []).filter { !$0.canRunInPrivate }.map(\.name)
			return .init(
				hostWindow: host,
				host: context.url.host() ?? context.url.absoluteString,
				connection: context.connection,
				profileName: context.profileName,
				canShare: true,
				canCapture: context.canCapture,
				canRead: context.canRead,
				extensions: context.extensionsProfileID != nil && extensionsAvailable ? (tiles ?? []) : nil,
				extensionsArePrivate: !ordinary,
				unavailableInPrivate: unavailableInPrivate,
				removingExtension: ordinary ? extensions?.first { $0.id == removingExtensionID } : nil,
				permissions: permissions,
				blocksContent: blocksContent,
				contentBlockingIsManaged: blocksContent != nil && context.origin.map {
					settings?.contentBlockingIsManaged(on: $0) == true
				} == true,
				webKit: webKitPages.isEnabled && WebKitPagePreferences.isSecure(context.url)
				? .init(
					isListed: SiteMenuFeature.opensInWebKit(context.url, webKitPages, fairPlayOrigins: fairPlayOrigins),
					isShown: context.usesWebKit,
					playsVideoOnlyInWebKit: SiteMenuFeature.playsVideoOnlyInWebKit(context.url, webKitPages, fairPlayOrigins: fairPlayOrigins)
				)
				: nil,
				darkPage: context.darkPage,
				unreadBadges: unreadBadgesRow,
				devices: ordinary ? devices.map { grant in
					.init(id: grant.id, name: grant.name, symbol: grant.kind.symbol)
				} : nil,
				hiddenElements: ordinary && hideElementEnabled && general.blocksContent ? hiddenElements.map { filters in
					filters.map { .init(id: $0, selector: BrowserHiddenElements.selector(of: $0)) }
				} : nil,
				canHideElement: blocksContent != false,
				translation: translationRow,
				zoom: zoom,
				isLoading: isLoadingExtensions || isLoadingSettings,
				isApplying: isApplying || isChangingExtension,
				canClearSiteData: ordinary && siteDataAvailable && origin != nil,
				canOpenSettings: ordinary,
				clearing: clearing,
				notice: extensionChangeFailed
				? String.localized(.appUI.siteMenu.extensionChangeFailed)
				: settingsFailed ? String.localized(.appUI.siteMenu.settingsFailed) : nil
			)
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			/// The panel opened over this page.
			case open(Context)
			case menu(SiteMenuAction)
		}

		@CasePathable
		public enum Event: Sendable {
			/// The profile's tiles, built for a tab: their icons can be ones its page set.
			case extensionsLoaded(Profile.ID, BrowserCore.Tab.ID?, [SiteMenu.Extension]?)
			case settingsLoaded(Profile.ID, Result<SiteSettings, SiteSettingsFailure>)
			case settingsApplied(Profile.ID, Result<SiteSettings, SiteSettingsFailure>)
			case settingsChanged(Profile.ID)
			case scoped(request: Int, SiteMenu.ClearKind, Result<String, ProfileDataFailure>)
			case cleared(request: Int, SiteMenu.ClearKind, String, Result<Set<BrowsingDataKind>, ProfileDataFailure>)

			/// A Turn Off or Remove finished (DEV-891).
			case extensionChanged(Profile.ID, succeeded: Bool)

			/// Open in WebKit moved the tab's page, or didn't (DEV-877).
			case engineChanged(BrowserCore.Tab.ID, PageEngine)

			/// The page's language, when it isn't the person's (DEV-904).
			case languageDetected(BrowserCore.Tab.ID, String?)

			/// The filters that hide elements on the tab's site, or nil when they can't be read
			/// (DEV-1019).
			case hiddenElementsLoaded(BrowserCore.Tab.ID, [String]?)
		}

		@CasePathable
		public enum Delegate: Sendable {
			case share(URL)
			case command(BrowserCommand)
			case manageExtensions(Profile.ID)

			/// The profile's Extensions sheet, on this extension.
			case showExtension(Profile.ID, extensionID: String)

			/// The profile's Extensions sheet, with the review of this extension's update (DEV-1210).
			case reviewExtensionUpdate(Profile.ID, extensionID: String)
			case openExtensionOptions(Profile.ID, extensionID: String)
			case openSiteSettings(Profile.ID)

			/// The site's cookies or cache were cleared: hover cards forget what they fetched
			/// with them (DEV-1142).
			case clearedSiteData(Profile.ID)

			/// Add Extension (DEV-1317): the Chrome Web Store in a new Little Arx of this profile.
			case openWebstore(Profile.ID)

			/// Translate Page or Show Original for the tab (DEV-904).
			case translatePage(BrowserCore.Tab.ID)

			/// The profile's extensions changed here; Settings › Extensions reads them again.
			case extensionsChanged(Profile.ID)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.browserExtensions)
	private var extensions

	@Dependency(\.pageEngines)
	private var pageEngines

	@Dependency(\.deviceChoosers)
	private var deviceChoosers

	@Dependency(\.pageTranslation)
	private var pageTranslation

	@Dependency(\.continuousClock)
	private var clock

	/// How often Show looks for uBlock to have reloaded its filters (DEV-1019), and how many
	/// times, about five seconds, before it reloads the tab's page anyway.
	internal static let showPollInterval: Duration = .milliseconds(150)
	internal static let showPolls: Int = 33

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.open) { state, context in
			state.context = context
			state.isOpen = true
			state.extensions = nil
			state.settings = nil
			state.clearing = nil
			state.clearContext = nil
			state.clearRequest += 1
			state.settingsFailed = false
			state.isApplying = false
			state.removingExtensionID = nil
			state.extensionChangeFailed = false
			state.devices = context.isPrivate ? [] : loadDevices(context)
			state.hiddenElements = nil
			state.pageLanguage = nil
			guard !context.isPrivate else {
				// DEV-956: the opener's extensions allowed in private windows; nothing else.
				state.extensionsAvailable = context.openerProfileID != nil
				&& MainActor.assumeIsolated { [extensions] in extensions.isAvailable }
				state.settingsAvailable = false
				state.siteDataAvailable = false
				return .merge(
					.cancel(id: Cancellation.observe),
					loadExtensions(&state)
				)
			}

			state.extensionsAvailable = MainActor.assumeIsolated { [extensions] in extensions.isAvailable }
			state.settingsAvailable = context.origin != nil
			state.siteDataAvailable = MainActor.assumeIsolated { [engine] in engine.siteDataIsAvailable() }

			// What the window leaves out isn't read (DEV-1257).
			let host = state.host
			return .merge(
				loadExtensions(&state),
				loadSettings(&state),
				observe(context.profileID),
				host.shows(.translation) ? detectLanguage(context) : .none,
				host.shows(.hiddenElements)
				? loadHiddenElements(context, blocksContent: state.hideElementEnabled && state.general.blocksContent)
				: .none
			)
		}

		Pullback(\.ui.menu) { state, action in
			menu(action, state: &state)
		}

		events
	}

	@ReducerBuilder<State, Action>
	private var events: some ReducerOf<Self> {
		Pullback(\.event.extensionsLoaded) { state, value in
			let (profileID, tabID, loaded) = value
			guard state.context?.extensionsProfileID == profileID else { return .none }

			// Tiles built for another tab, by a change that finished after the menu moved on,
			// carry that page's icons: read the profile again for this one (DEV-1179). Their
			// inventory read fine, so a read this tab's menu lost to that change runs again.
			guard state.context?.tabID == tabID else {
				if loaded != nil { state.extensionsAvailable = true }
				return loadExtensions(&state)
			}

			state.isLoadingExtensions = false
			state.extensions = loaded

			// A read that failed (such as one that met a Turn Off in flight) hides the row;
			// the next good one, such as that change's own, shows it again.
			state.extensionsAvailable = loaded != nil
			return .none
		}

		Pullback(\.event.hiddenElementsLoaded) { state, value in
			let (tabID, filters) = value
			guard state.context?.tabID == tabID else { return .none }
			state.hiddenElements = filters
			return .none
		}

		Pullback(\.event.languageDetected) { state, value in
			let (tabID, language) = value
			guard state.context?.tabID == tabID else { return .none }
			state.pageLanguage = language
			return .none
		}

		Pullback(\.event.engineChanged) { state, value in
			let (tabID, engine) = value
			guard state.context?.tabID == tabID else { return .none }

			state.context?.usesWebKit = engine == .webKit
			return .none
		}

		Pullback(\.event.extensionChanged) { state, value in
			let (profileID, succeeded) = value
			state.isChangingExtension = false
			guard state.context?.profileID == profileID else {
				return .send(.delegate(.extensionsChanged(profileID)))
			}

			state.extensionChangeFailed = !succeeded

			// The tiles came with the change's own inventory (`extensionsLoaded`), so only
			// Settings › Extensions reads again; two reads of one profile at once would collide.
			return .send(.delegate(.extensionsChanged(profileID)))
		}

		Pullback(\.event.settingsLoaded) { state, value in
			let (profileID, result) = value
			guard state.context?.profileID == profileID else { return .none }

			state.isLoadingSettings = false
			switch result {
			case let .success(settings):
				state.settings = settings

			case .failure(.unavailable):
				state.settingsAvailable = false

			case .failure:
				state.settingsFailed = true
			}
			return .none
		}

		Pullback(\.event.settingsApplied) { state, value in
			let (profileID, result) = value
			guard state.context?.profileID == profileID else { return .none }

			state.isApplying = false
			switch result {
			case let .success(settings):
				state.settings = settings
				return .none

			case .failure:
				state.settingsFailed = true
				return loadSettings(&state)
			}
		}

		Pullback(\.event.settingsChanged) { state, profileID in

			// A change of our own comes back with its listing.
			guard state.isOpen, !state.isApplying, state.context?.profileID == profileID
			else { return .none }

			return loadSettings(&state)
		}

		Pullback(\.event.scoped) { state, value in
			let (request, kind, result) = value
			guard request == state.clearRequest, state.clearing == .scoping(kind) else { return .none }

			switch result {
			case let .success(domain):
				state.clearing = .confirming(kind, domain: domain)

			case .failure:
				state.clearing = .failed(kind)
			}
			return .none
		}

		Pullback(\.event.cleared) { state, value in
			let (request, kind, domain, result) = value
			guard
				request == state.clearRequest,
				state.clearing == .clearing(kind, domain: domain)
			else { return .none }

			switch result {
			case let .success(failed):
				state.clearing = .cleared(kind, domain: domain, isComplete: failed.isEmpty)

			case .failure:
				state.clearing = .failed(kind)
			}
			return .none
		}
	}

	private func menu(
		_ action: SiteMenuAction,
		state: inout State
	) -> Effect<Action> {
		// An item the window leaves out takes no action there either (DEV-1257).
		if let item = SiteMenu.Item(action), !state.host.shows(item) { return .none }

		switch action {
		case .opened:
			// The parent answers with `open` and the page.
			return .none

		case .closed:
			state.isOpen = false

			// A clear in flight finishes; a question nobody answered is dropped.
			switch state.clearing {
			case .scoping, .confirming:
				state.clearing = nil
				state.clearContext = nil
				state.clearRequest += 1
			default:
				break
			}
			state.isLoadingExtensions = false
			state.isLoadingSettings = false

			// An unanswered Remove… is dropped; a Turn Off or Remove in flight finishes.
			state.removingExtensionID = nil
			return .merge(
				.cancel(id: Cancellation.observe),
				.cancel(id: Cancellation.load),
				.cancel(id: Cancellation.settings),
				.cancel(id: Cancellation.scope),
				.cancel(id: Cancellation.hiddenElements)
			)

		case .share:
			guard let url = state.context?.url else { return .none }
			return .send(.delegate(.share(url)))

		case .captureViewport:
			return state.context?.canCapture == true ? .send(.delegate(.command(.captureViewport))) : .none

		case .captureRegion:
			return state.context?.canCapture == true ? .send(.delegate(.command(.captureRegion))) : .none

		case .pagePictureInPicture:
			return state.context == nil ? .none : .send(.delegate(.command(.pagePictureInPicture)))

		case .readingMode:
			return state.context?.canRead == true ? .send(.delegate(.command(.readingMode))) : .none

		case .manageExtensions:
			guard let context = state.context, !context.isPrivate else { return .none }
			return .send(.delegate(.manageExtensions(context.profileID)))

		case let .showExtension(extensionID):
			guard let context = state.context, !context.isPrivate else { return .none }
			return .send(.delegate(.showExtension(context.profileID, extensionID: extensionID)))

		case let .reviewExtensionUpdate(extensionID):
			guard
				let context = state.context,
				!context.isPrivate,
				state.menu?.extensions?.contains(where: { $0.id == extensionID && $0.needsUpdateReview }) == true
			else { return .none }

			return .send(.delegate(.reviewExtensionUpdate(context.profileID, extensionID: extensionID)))

		case let .runExtension(extensionID, point):
			// Runs the extension's action for the page. When the engine can't (an
			// older engine, the page needs a reload, a side panel), the tile opens the profile's
			// Extensions sheet on it, as before (DEV-801).
			// DEV-956: in a private window, only a tile it shows: one allowed there.
			guard
				let context = state.context,
				state.menu?.extensions?.contains(where: { $0.id == extensionID }) == true
			else { return .none }

			// The context and point are the click's, so a menu that closes or moves on meanwhile
			// changes neither the tab nor where the popup opens. Not cancellable: closing the menu
			// is part of the click.
			return .run { @MainActor [engine] send in
				let ran = Self.runExtensionAction(
					extensionID,
					in: context.tabID,
					at: point,
					engine: engine
				)

				// A private window has no Extensions sheet of its own.
				guard !ran, !context.isPrivate else { return }
				send(.delegate(.showExtension(context.profileID, extensionID: extensionID)))
			}

		case let .openExtensionOptions(extensionID):
			guard
				let context = state.context,
				!context.isPrivate,
				state.extensions?.contains(where: { $0.id == extensionID && $0.canOpenOptions }) == true
			else { return .none }
			return .send(.delegate(.openExtensionOptions(context.profileID, extensionID: extensionID)))

		case .addExtension:
			guard let context = state.context, !context.isPrivate else { return .none }
			// DEV-1317: the Chrome Web Store opens in a new Little Arx of the menu's profile, in
			// front with the keyboard, wherever the menu was opened.
			return .send(.delegate(.openWebstore(context.profileID)))

		case .allSiteSettings:
			guard let context = state.context, !context.isPrivate else { return .none }
			return .send(.delegate(.openSiteSettings(context.profileID)))

		case let .setPermission(permission, setting):
			guard
				let context = state.context,
				!context.isPrivate,
				let origin = context.origin,
				let settings = state.settings,
				!settings.menuRow(permission, origin: origin).isManaged
			else { return .none }
			if let setting, !permission.siteSettings.contains(setting) { return .none }

			return apply(.setPermission(origin: origin, permission, setting), state: &state)

		case let .setContentBlocking(isOn):
			guard
				let context = state.context,
				!context.isPrivate,
				let origin = context.origin,
				let settings = state.settings,
				settings.contentBlockingIsAvailable,
				state.general.blocksContent,
				!settings.contentBlockingIsManaged(on: origin),
				settings.blocksContent(on: origin) != isOn
			else { return .none }

			return apply(.setContentBlocking(origin: origin, isOn: isOn), state: &state)

		case let .translate(isOn):
			guard let context = state.context, let tabID = context.tabID, !context.isPrivate else { return .none }
			let isTranslated = state.translatedTabs[tabID] != nil
			guard isOn != isTranslated else { return .none }
			return .send(.delegate(.translatePage(tabID)))

		case let .setNeverTranslate(isOn):
			guard let context = state.context, !context.isPrivate else { return .none }
			state.$translation.withLock { $0[context.profileID].setNeverTranslates(isOn, for: context.url) }
			return .none

		case let .setAlwaysTranslate(isOn):
			guard
				let context = state.context,
				!context.isPrivate,
				let tabID = context.tabID,
				let language = state.translatedTabs[tabID] ?? state.pageLanguage
			else { return .none }

			state.$translation.withLock { $0[context.profileID].setAlwaysTranslates(isOn, language: language) }
			return .none

		case .hideElement:
			guard let menu = state.menu, menu.hiddenElements != nil, menu.canHideElement else { return .none }
			return .send(.delegate(.command(.hideElement)))

		case let .showHiddenElement(filter):
			guard
				let context = state.context,
				let tabID = context.tabID,
				state.hiddenElements?.contains(filter) == true
			else { return .none }

			let (shown, document) = MainActor.assumeIsolated { [engine] in
				(engine.showHiddenElement(tabID, filter), engine.snapshot(tabID)?.documentRevision)
			}
			guard shown else { return .none }
			state.hiddenElements?.removeAll { $0 == filter }

			// The element comes back once the page loads again with uBlock's filters reloaded
			// without the line. uBlock says so by listing the site's elements again without it.
			return .run { [engine, clock] _ in
				for _ in 0..<Self.showPolls {
					let hidden = await engine.hiddenElements(tabID)
					guard hidden?.sites.values.contains(where: { $0.contains(filter) }) == true else { break }
					try await clock.sleep(for: Self.showPollInterval)
				}

				// That tab, wherever it is now, while it still shows the same page: the person may
				// have moved on, or browsed on in it, meanwhile.
				guard await engine.snapshot(tabID)?.documentRevision == document else { return }
				try? await engine.command(tabID, .reload)
			}

		case let .forgetDevice(id):
			guard
				let context = state.context,
				!context.isPrivate,
				let grant = state.devices.first(where: { $0.id == id })
			else { return .none }

			let profileID = context.profileID
			_ = MainActor.assumeIsolated { [deviceChoosers] in deviceChoosers.revoke(profileID, grant) }
			state.devices = loadDevices(context)
			return .none

		case let .setDarkPage(isOn):
			// The Dark Page command turns the page's site off or on; the switch moves at once.
			guard let darkPage = state.context?.darkPage, darkPage != isOn else { return .none }

			state.context?.darkPage = isOn
			return .send(.delegate(.command(.darkPage)))

		case let .setUnreadBadges(visibility):
			guard
				let context = state.context,
				!context.isPrivate,
				SiteMenu.connection(for: context.url) != .local,
				let host = BrowserCore.Tab.unreadBadgeHost(of: context.url)
			else { return .none }

			state.$unreadBadgeOverrides.withLock { $0.sites[host] = visibility }
			return .none

		case let .setWebKit(isOn):
			guard
				let context = state.context,
				state.webKitPages.isEnabled,
				WebKitPagePreferences.isSecure(context.url)
			else { return .none }

			let fairPlayOrigins = state.fairPlayOrigins
			state.$webKitPages.withLock { preferences in

				// A FairPlay site (DEV-1144): the choice is Settings' Protected media too, which
				// would otherwise keep it in Chromium whatever the list says.
				if FairPlayInChromium.origin(of: context.url) != nil {
					preferences.protectedMedia = isOn ? .webKitPage : .fairPlayInTab
				}
				if isOn {
					preferences.add(context.url)
				} else if SiteMenuFeature.opensInWebKit(context.url, preferences, fairPlayOrigins: fairPlayOrigins) {
					// Still WebKit's, as any listed site is, or a FairPlay site the helper can't
					// play now (DEV-1151): off takes it off the list.
					preferences.remove(context.url)
				}
			}
			let engine: PageEngine = isOn ? .webKit : .chromium
			guard let tabID = context.tabID, context.usesWebKit != isOn else { return .none }

			return .run { [pageEngines] send in
				let moved = await pageEngines.move(tabID, engine, nil)
				await send(.event(.engineChanged(tabID, moved ? engine : (isOn ? .chromium : .webKit))))
			}

		case .resetZoom:
			guard let context = state.context, !context.isPrivate, let host = context.zoomHost
			else { return .none }

			return apply(.setZoom(host: host, factor: nil), state: &state)

		case let .requestClear(kind):
			guard
				let context = state.context,
				!context.isPrivate,
				state.siteDataAvailable,
				context.origin != nil
			else { return .none }
			switch state.clearing {
			case .scoping, .confirming, .clearing: return .none
			default: break
			}

			state.clearing = .scoping(kind)
			state.clearContext = context
			state.clearRequest += 1
			let request = state.clearRequest
			let url = context.url
			let profileID = context.profileID
			let scope: Effect<Action> = .run { [engine] send in
				let result: Result<String, ProfileDataFailure>
				do throws(ProfileDataFailure) {
					result = .success(try await engine.siteDataScope(profileID, url))
				} catch {
					result = .failure(error)
				}
				await send(.event(.scoped(request: request, kind, result)))
			}
			.cancellable(id: Cancellation.scope)

			// Cancelled in reducer order, like every effect here that a newer one replaces:
			// `cancelInFlight` cancels only when the task registers, off the main actor, so an
			// older read could cancel this one and leave the menu scoping. An older read that
			// registers late carries an older request and is ignored.
			return .concatenate(.cancel(id: Cancellation.scope), scope)

		case .confirmClear:
			// The page whose site was shown, never one opened since.
			guard
				let context = state.clearContext,
				case let .confirming(kind, domain) = state.clearing
			else { return .none }

			state.clearing = .clearing(kind, domain: domain)
			let request = state.clearRequest
			let url = context.url
			let profileID = context.profileID
			let kinds: Set<BrowsingDataKind> = kind == .cache ? [.cache] : [.cookies]
			return .run { [engine] send in
				let result: Result<Set<BrowsingDataKind>, ProfileDataFailure>
				do throws(ProfileDataFailure) {
					result = .success(try await engine.clearSiteData(profileID, url, kinds))
				} catch {
					result = .failure(error)
				}
				if case let .success(failed) = result, !kinds.subtracting(failed).isEmpty {
					await send(.delegate(.clearedSiteData(profileID)))
				}
				await send(.event(.cleared(request: request, kind, domain, result)))
			}

		case .cancelClear:
			if case .confirming = state.clearing {
				state.clearing = nil
				state.clearContext = nil
			}
			return .none

		case .dismissNotice:
			switch state.clearing {
			case .cleared, .failed: state.clearing = nil
			default: break
			}
			state.settingsFailed = false
			state.extensionChangeFailed = false
			return .none

		case let .turnOffExtension(extensionID):
			guard
				let context = state.context,
				!context.isPrivate,
				!state.isChangingExtension,
				state.extensions?.contains(where: { $0.id == extensionID && $0.canTurnOff }) == true
			else { return .none }

			state.removingExtensionID = nil
			return change(extensionID, .disable, state: &state)

		case let .setExtensionAllowedInPrivate(extensionID, allowed):
			let action: BrowserExtensionAction = allowed ? .allowInPrivate : .disallowInPrivate
			guard
				let context = state.context,
				!context.isPrivate,
				!state.isChangingExtension,
				state.extensions?.contains(where: {
					$0.id == extensionID && $0.canAllowInPrivate && $0.allowedInPrivate != allowed
				}) == true
			else { return .none }

			state.removingExtensionID = nil
			return change(extensionID, action, state: &state)

		case let .requestExtensionRemoval(extensionID):
			guard
				let context = state.context,
				!context.isPrivate,
				!state.isChangingExtension,
				state.extensions?.contains(where: { $0.id == extensionID && $0.canRemove }) == true
			else { return .none }

			state.removingExtensionID = extensionID
			return .none

		case .cancelExtensionRemoval:
			state.removingExtensionID = nil
			return .none

		case .confirmExtensionRemoval:
			guard
				let context = state.context,
				!context.isPrivate,
				!state.isChangingExtension,
				let extensionID = state.removingExtensionID,
				state.extensions?.contains(where: { $0.id == extensionID && $0.canRemove }) == true
			else { return .none }

			state.removingExtensionID = nil
			return change(extensionID, .remove, state: &state)
		}
	}

	private func apply(
		_ edit: SiteSettingsEdit,
		state: inout State
	) -> Effect<Action> {
		guard
			let profileID = state.context?.profileID,
			!state.isApplying,
			state.settings?.holds(edit) != true
		else { return .none }
		do throws(SiteSettingsFailure) {
			try edit.validate()
		} catch {
			return .none
		}

		state.isApplying = true
		state.settingsFailed = false
		return .run { [engine] send in
			let result: Result<SiteSettings, SiteSettingsFailure>
			do throws(SiteSettingsFailure) {
				result = .success(try await engine.changeSiteSettings(profileID, edit))
			} catch {
				result = .failure(error)
			}
			await send(.event(.settingsApplied(profileID, result)))
		}
	}

	/// Runs the extension's action for the tab when the engine can. False when it can't, or
	/// the menu's page has no tab.
	@MainActor
	private static func runExtensionAction(
		_ extensionID: String,
		in tabID: BrowserCore.Tab.ID?,
		at point: CGPoint,
		engine: BrowserEngineClient
	) -> Bool {
		guard
			let tabID,
			engine.extensionActionsAreAvailable()
		else { return false }

		do {
			_ = try engine.runExtensionAction(tabID, extensionID, point)
			return true
		} catch {
			return false
		}
	}

	private func loadExtensions(_ state: inout State) -> Effect<Action> {
		guard let profileID = state.context?.extensionsProfileID, state.extensionsAvailable else { return .none }

		state.isLoadingExtensions = true
		let tabID = state.context?.tabID

		// DEV-1210: a private window has no Extensions sheet to review an update in.
		let marksUpdateReviews = state.context?.isPrivate == false && ExtensionUpdateReviewFeatureFlag.isOn()
		return .run { [engine, extensions] send in
			var loaded: [SiteMenu.Extension]?
			do {
				loaded = await Self.tiles(
					try await extensions.inspect(profileID),
					in: tabID,
					engine: engine,
					extensions: extensions,
					marksUpdateReviews: marksUpdateReviews
				)
			} catch {
				loaded = nil
			}
			await send(.event(.extensionsLoaded(profileID, tabID, loaded)))
		}
		.cancellable(id: Cancellation.load)
	}

	/// The tiles for an inventory: its enabled extensions by name, with their icons.
	private static func tiles(
		_ inventory: BrowserExtensionInventory,
		in tabID: BrowserCore.Tab.ID?,
		engine: BrowserEngineClient,
		extensions: BrowserExtensionsClient,
		marksUpdateReviews: Bool
	) async -> [SiteMenu.Extension] {
		let enabled = inventory.extensions
			.filter { $0.state == .enabled && hasTile($0) }
			.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

		// DEV-1210: store updates the automatic check left for the person's review, for this
		// installed version. This fresh inventory also drops the marks of extensions that went or
		// changed, such as one removed from this menu while the Extensions sheet is closed.
		@Shared(.extensionUpdateReviews)
		var reviews

		if marksUpdateReviews { $reviews.withLock { $0.reconcile(with: inventory) } }
		let reviewed: Set<String> = marksUpdateReviews
		? Set(reviews.pending(in: inventory.profileID).filter { review in
			inventory.extensions.contains { $0.id == review.extensionID && $0.version == review.installedVersion }
		}.map(\.extensionID))
		: []
		var items: [SiteMenu.Extension] = []
		for item in enabled {
			var icon = await actionIcon(item.id, in: tabID, engine: engine)
			if icon == nil, let path = item.iconPath(pixels: tileIconPixels) {
				icon = await extensions.icon(path)
			}

			// A component's files live in the engine's resources, not on disk.
			icon = icon ?? item.bundledIcon
			items.append(
				.init(
					id: item.id,
					name: item.name,
					icon: icon,
					canOpenOptions: item.canOpenOptions,
					canTurnOff: item.allows(.disable),
					canRemove: item.allows(.remove),
					allowedInPrivate: item.allowedInPrivate,
					canAllowInPrivate: item.canAllowInPrivate,
					canRunInPrivate: item.canRunInPrivate,
					// Components such as uBlock Origin and Manifest V2 extensions have no action
					// Arx runs (ExtensionActionHost).
					canRunAction: item.manifestVersion == 3 && ![5, 10].contains(item.location),
					needsUpdateReview: reviewed.contains(item.id)
				)
			)
		}
		return items
	}

	/// Whether an enabled extension gets a tile. A component with neither a toolbar action nor
	/// an options page, such as Chromium's PDF Viewer, has nothing a tile could open: it would
	/// only send the click to Settings (DEV-1314). uBlock Origin keeps its tile.
	private static func hasTile(_ item: BrowserExtension) -> Bool {
		guard [5, 10].contains(item.location) else { return true }

		return item.canOpenOptions || !item.actionIcons.isEmpty
	}

	/// The pixels a tile's icon covers on a 2x display: 20 points.
	private static let tileIconPixels: Int = 40

	/// The icon the extension set for the tab's page, as its toolbar button would show it.
	@MainActor
	private static func actionIcon(
		_ extensionID: String,
		in tabID: BrowserCore.Tab.ID?,
		engine: BrowserEngineClient
	) -> Data? {
		tabID.flatMap { engine.extensionActionIcon($0, extensionID, 2) }
	}

	/// Turns an extension off, removes it or changes whether it runs in private windows with a
	/// fresh inventory of its profile, which rechecks that the change is still allowed
	/// (DEV-891, DEV-889).
	private func change(
		_ extensionID: String,
		_ action: BrowserExtensionAction,
		state: inout State
	) -> Effect<Action> {
		guard let profileID = state.context?.profileID else { return .none }

		state.isChangingExtension = true
		let marksUpdateReviews = state.context?.isPrivate == false && ExtensionUpdateReviewFeatureFlag.isOn()
		state.extensionChangeFailed = false
		let tabID = state.context?.tabID
		return .run { [engine, extensions] send in
			var succeeded = false
			var latest: BrowserExtensionInventory?
			do {
				let inventory = try await extensions.inspect(profileID)
				latest = inventory
				if inventory.extensions.first(where: { $0.id == extensionID })?.allows(action) == true {
					let after = try await extensions.manage(.init(
						inventory: inventory,
						extensionID: extensionID,
						action: action
					))
					latest = after
					let item = after.extensions.first { $0.id == extensionID }
					succeeded = switch action {
					case .remove: item == nil
					case .allowInPrivate: item?.allowedInPrivate == true
					case .disallowInPrivate: item?.allowedInPrivate == false
					case .disable: item?.state == .disabled
					case .enable: item?.state == .enabled
					case .reload: item != nil
					}
				}
			} catch {
				succeeded = false
			}
			if let latest {
				let tiles = await Self.tiles(
					latest,
					in: tabID,
					engine: engine,
					extensions: extensions,
					marksUpdateReviews: marksUpdateReviews
				)
				await send(.event(.extensionsLoaded(profileID, tabID, tiles)))
			}
			await send(.event(.extensionChanged(profileID, succeeded: succeeded)))
		}
	}

	private func loadSettings(_ state: inout State) -> Effect<Action> {
		guard let profileID = state.context?.profileID, state.settingsAvailable else { return .none }

		state.isLoadingSettings = true
		let load: Effect<Action> = .run { [engine] send in
			let result: Result<SiteSettings, SiteSettingsFailure>
			do throws(SiteSettingsFailure) {
				result = .success(try await engine.siteSettings(profileID))
			} catch {
				result = .failure(error)
			}
			await send(.event(.settingsLoaded(profileID, result)))
		}
		.cancellable(id: Cancellation.settings)

		// A late older read for another profile is ignored; one for this profile reads the same.
		return .concatenate(.cancel(id: Cancellation.settings), load)
	}

	private func observe(_ profileID: Profile.ID) -> Effect<Action> {
		let observation: Effect<Action> = .run { [engine] send in
			for await changed in await engine.siteSettingsChanges() where changed == profileID {
				await send(.event(.settingsChanged(changed)))
			}
		}
		.cancellable(id: Cancellation.observe)

		// A late older observation of another profile sends changes `settingsChanged` ignores,
		// and stops with the next cancellation.
		return .concatenate(.cancel(id: Cancellation.observe), observation)
	}

	private enum Cancellation: Hashable {
		case scope
		case load
		case settings
		case observe
		case hiddenElements
	}
}

extension SiteMenuFeature {
	/// Reads the page's language with a sample of its text, for the Translate row (DEV-904).
	/// Only Chromium pages on the web; nothing for a private or WebKit page.
	fileprivate func detectLanguage(_ context: Context) -> Effect<Action> {
		guard let tabID = context.tabID, !context.isPrivate, !context.usesWebKit, context.url.hasWebScheme
		else { return .none }

		return .run { [engine, pageTranslation] send in
			let outcome = try? await engine.evaluateScript(tabID, PageTranslationScripts.sample, 16 * 1024, 2000, { true })
			guard
				case let .value(json) = outcome,
				let sample = try? JSONDecoder().decode(PageTranslationScripts.Sample.self, from: Data(json.utf8)),
				let detected = pageTranslation.detectLanguage(sample.text) ?? (sample.lang.isEmpty ? nil : sample.lang)
			else { return await send(.event(.languageDetected(tabID, nil))) }

			let language = PageTranslationClient.baseLanguage(detected)
			await send(.event(.languageDetected(tabID, language == pageTranslation.targetLanguage() ? nil : language)))
		}
	}
}

extension SiteMenuFeature {
	/// The filters that hide elements on the page's site (DEV-1019): an ordinary http(s) page
	/// with Hide Element's feature flag and content blocking on, on an engine that hides elements.
	fileprivate func loadHiddenElements(
		_ context: Context,
		blocksContent: Bool
	) -> Effect<Action> {
		guard
			blocksContent,
			!context.isPrivate,
			!context.usesWebKit,
			let tabID = context.tabID,
			let scheme = context.url.scheme?.lowercased(),
			scheme == "http" || scheme == "https",
			let host = context.url.host(),
			MainActor.assumeIsolated({ [engine] in engine.elementHidingIsAvailable() })
		else { return .none }

		// uBlock names an IPv6 site with its brackets, as the address writes it.
		let site = host.contains(":") ? "[\(host)]" : host
		return .run { [engine] send in
			let hidden = await engine.hiddenElements(tabID)
			await send(.event(.hiddenElementsLoaded(tabID, hidden?.filters(for: site))))
		}
		.cancellable(id: Cancellation.hiddenElements, cancelInFlight: true)
	}

	/// The devices the page's site may use in its profile, read from the engine (DEV-905).
	fileprivate func loadDevices(_ context: Context) -> [BrowserDeviceGrant] {
		guard let origin = context.origin else { return [] }
		let profileID = context.profileID
		let grants = MainActor.assumeIsolated { [deviceChoosers] in deviceChoosers.grants(profileID) } ?? []
		return grants.filter { SiteSettings.origin($0.origin) == origin }
	}
}

extension BrowserDeviceGrant.Kind {
	fileprivate var symbol: String {
		switch self {
		case .usb, .hid: "cable.connector"
		case .serial: "point.3.connected.trianglepath.dotted"
		case .bluetooth: "wave.3.right"
		}
	}
}

extension MainFeature.State {
	/// The page the site menu describes: the active pane's tab, in that tab's profile.
	internal var siteMenuContext: SiteMenuFeature.Context? {
		let shown = viewer.item.tab
		guard let tab = shown ?? (!viewer.isSplit ? sidebar.selectedTab : nil) else { return nil }

		let url = (shown == nil ? nil : viewer.item.navigation.url) ?? tab.restoration.url

		return .init(
			url: url,
			tabID: shown?.id,
			profileID: tab.profileID,
			profileName: sidebar.organization.profiles[id: tab.profileID]?.name,
			isPrivate: isPrivate,
			openerProfileID: isPrivate ? privateOpenerProfileID : nil,
			canCapture: BrowserCommand.captureViewport.isEnabled(in: commandContext),
			canRead: commandContext.readingModeEnabled
			? BrowserCommand.readingMode.isEnabled(in: commandContext)
			: nil,
			loadFailed: shown != nil && viewer.item.navigation.errorCode != nil,
			usesWebKit: shown != nil && viewer.item.navigation.engine == .webKit,
			darkPage: darkPagesOffered && !isPrivate && !(shown != nil && viewer.item.navigation.engine == .webKit)
				&& KeptLoadedSite.site(of: url) != nil
			? !(sidebar.organization.profiles[id: tab.profileID]?.darkPagesOffSites ?? []).contains {
				KeptLoadedSite.matches(url, site: $0)
			}
			: nil,
			profileUnreadBadges: sidebar.organization.profiles[id: tab.profileID]?.unreadBadges
		)
	}
}

extension SiteSettings {
	/// One site menu row: the page's own setting, and what applies without it (a wider
	/// site rule or the profile's default). A managed rule for the site, then a managed
	/// default, decide over anything the user set, as in Chromium; the row then shows
	/// that value and can't change.
	internal func menuRow(
		_ permission: SitePermission,
		origin: String
	) -> SiteMenu.Permission {
		let winner = rule(for: permission, origin: origin)
		let profileDefault = defaultSetting(for: permission)
		if let winner, winner.isManaged {
			return .init(permission: permission, setting: nil, defaultSetting: winner.setting, isManaged: true)
		}
		if let profileDefault, profileDefault.isManaged {
			return .init(permission: permission, setting: nil, defaultSetting: profileDefault.setting, isManaged: true)
		}

		let inherited = rule(for: permission, origin: origin, excluding: origin)
		return .init(
			permission: permission,
			setting: winner?.origin == origin ? winner?.setting : nil,
			defaultSetting: inherited?.setting
			?? profileDefault?.setting
			?? (permission == .popups ? .block : .ask)
		)
	}
}

extension SiteMenuFeature {
	/// Whether `url` opens in WebKit as the router decides it (DEV-1151): a FairPlay site the
	/// helper can play now stays in Chromium under "FairPlay in the tab" though the list covers
	/// it (DEV-1144); without the bridge, or after a failed track, the list decides.
	internal static func opensInWebKit(
		_ url: URL,
		_ preferences: WebKitPagePreferences,
		fairPlayOrigins: Set<String>
	) -> Bool {
		preferences
			.keepingInChromium(preferences.bridgedOrigins(fairPlayOrigins.sorted()))
			.opensInWebKit(url)
	}

	/// Whether `url`'s protected video plays only in WebKit as the router decides it (DEV-1188):
	/// a listed built-in streaming site, such as Netflix, that the FairPlay helper doesn't keep in
	/// Chromium now. In a Chromium tab Arx offers WebKit when its video starts.
	internal static func playsVideoOnlyInWebKit(
		_ url: URL,
		_ preferences: WebKitPagePreferences,
		fairPlayOrigins: Set<String>
	) -> Bool {
		preferences
			.keepingInChromium(preferences.bridgedOrigins(fairPlayOrigins.sorted()))
			.playsProtectedMediaOnlyInWebKit(url)
	}
}
