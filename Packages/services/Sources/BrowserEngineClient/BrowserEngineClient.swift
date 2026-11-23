import AppKit
import BrowserCore
import Foundation
import _Dependencies

/// Commands and observations use domain identities; native pages stay in the live service.
public struct BrowserEngineClient: Sendable {
	/// False means before-unload refusal. Success invokes didClose synchronously after
	/// native disposal, with no suspension between consuming authority and that callback.
	public typealias AuthorizedClose = @MainActor @Sendable (
		Tab.ID,
		UInt64?,
		@escaping @MainActor @Sendable () -> Bool,
		@escaping @MainActor @Sendable () -> Void
	) async throws -> Bool

	/// False while an earlier reference action on the tab's current document has an
	/// uncertain native outcome. Other tabs and replaced documents never block it.
	public var referenceSubmissionsAreSettled: @MainActor @Sendable (Tab.ID) -> Bool
	public var status: @Sendable () -> BrowserEngineStatus
	public var snapshot: @MainActor @Sendable (Tab.ID) -> BrowserSessionSnapshot?
	public var openAuthorized: @MainActor @Sendable (
		Tab,
		@escaping @MainActor @Sendable () -> Bool
	) async throws -> Void
	public var commandAuthorized: @MainActor @Sendable (
		Tab.ID,
		UInt64,
		Command,
		@escaping @MainActor @Sendable () -> Bool
	) async throws -> Void
	public var closeAuthorized: AuthorizedClose?
	public var open: @MainActor @Sendable (Tab) async throws -> Void
	public var command: @MainActor @Sendable (Tab.ID, Command) async throws -> Void
	public var permitsClosing: @MainActor @Sendable (Tab.ID) async -> Bool
	public var close: @MainActor @Sendable (Tab.ID) -> Void

	/// DEV-1009. Wait on a page that stopped answering: the engine checks again, and a hang
	/// still there comes back with a new number. False when the page answers.
	public var waitForPage: @MainActor @Sendable (Tab.ID) -> Bool = { _ in false }

	/// DEV-1009. Ends the page's renderer process, and every page sharing it; the page then
	/// shows its renderer gone until it reloads. Commands and closing do this themselves for
	/// a page that stopped answering.
	public var endRenderer: @MainActor @Sendable (Tab.ID) -> Bool = { _ in false }

	/// DEV-1009. Whether the page answers within the timeout (milliseconds), apart from the
	/// developer scripts' queue; nil when the engine can't ask.
	public var pingPage: @MainActor @Sendable (Tab.ID, Int) async -> Bool? = { _, _ in nil }
	public var prepareProfile: @MainActor @Sendable (Profile.ID) async throws -> Void

	/// The second profile, when known, is the ordinary profile that opened the private
	/// window: its downloads folder and "Ask where to save" apply there too (DEV-729).
	public var preparePrivateProfile: @MainActor @Sendable (Profile.ID, Profile.ID?) throws -> Void
	public var releasePrivateProfile: @MainActor @Sendable (Profile.ID) -> Void

	/// DEV-880. Lets go of the loaded ordinary profiles that nothing has used for the grace
	/// period. The app passes the profiles it shows or works in (``AppFeature``'s
	/// `profilesInUse`); the engine adds its pages, downloads and work in flight. Returns the
	/// profiles released; each loads again the next time something prepares it. Engines built
	/// before it release nothing.
	public var releaseIdleProfiles: @MainActor @Sendable (Set<Profile.ID>, Duration) -> Set<Profile.ID> = { _, _ in [] }
	public var events: @MainActor @Sendable (Tab.ID) -> AsyncStream<BrowserNavigation>

	/// The page's navigation each time its current history entry changes (another entry, or a
	/// new address for it) or starts or finishes loading. Unlike `events`, which keeps only the
	/// newest, none is dropped, so a page that leaves a site and comes straight back shows both
	/// (DEV-1063). It starts with the page's navigation now. Engines built before it report none.
	public var entryChanges: @MainActor @Sendable (Tab.ID) -> AsyncStream<BrowserNavigation> = { _ in .finished }

	/// DEV-1293. Whether the tab's page in the other engine is right behind or ahead of this one's
	/// current entry, so the page's own swipe offers that way. Engines built before it swipe only
	/// through the page's own history.
	public var setSharedHistory: @MainActor @Sendable (Tab.ID, _ back: Bool, _ forward: Bool) -> Void = { _, _, _ in }
	public var linkContexts: @MainActor @Sendable () -> AsyncStream<BrowserLinkContext>
	public var linkContextIsCurrent: @MainActor @Sendable (BrowserLinkContext) -> Bool
	public var dismissLinkContext: @MainActor @Sendable (BrowserLinkContext) -> Void

	/// Opens DevTools on the exact element under a still-current link menu.
	public var inspectLinkContext: @MainActor @Sendable (BrowserLinkContext) -> Bool

	/// DEV-890. Adds extensions' items for a still-current link menu to the app's `NSMenu`;
	/// a chosen one runs in the engine. False when there are none.
	public var appendLinkExtensionItems: @MainActor @Sendable (BrowserLinkContext, AnyObject) -> Bool = { _, _ in false }

	/// DEV-851. Download Linked File, started at once while the link menu is current: the engine
	/// downloads the link from its own frame with its page's referrer, as Chrome's Save Link As.
	/// Returns the request `linkContextDownload` waits on, or nil when the engine can't, and the
	/// app starts a plain download instead.
	public var startLinkContextDownload: @MainActor @Sendable (BrowserLinkContext) -> UInt64? = { _ in nil }

	/// The item a started link download made, once it exists.
	public var linkContextDownload: @MainActor @Sendable (
		BrowserLinkContext,
		UInt64
	) async throws -> BrowserDownload.ID = { _, _ in throw CancellationError() }
	public var retirementIsAvailable: @MainActor @Sendable () -> Bool
	public var blockProfileRetirement: @MainActor @Sendable (Profile.ID) -> Void
	public var profileRetirementSnapshot: @MainActor @Sendable () async throws -> ProfileRetirementSnapshot

	/// Authorization is checked immediately before irreversible durable retirement.
	/// A successful receipt must be reconciled even if the caller is then canceled.
	public var retireProfile: @MainActor @Sendable (
		ProfileRetirementRequest,
		@escaping @MainActor @Sendable () -> Bool
	) async throws -> ProfileRetirementSnapshot

	/// DEV-878: `copy`'s first page takes `source`'s back/forward history, for Duplicate Tab and a
	/// tab reopened from the archive. Call it before the copy opens. Does nothing for a private
	/// tab, or with an engine that keeps no history.
	public var cloneNavigation: @MainActor @Sendable (_ source: Tab, _ copy: Tab.ID) -> Void = { _, _ in }

	/// DEV-878: Reset Tab. The tab's saved back/forward history goes, so it reopens at its saved
	/// page alone. Call it after the tab's page closed.
	public var discardNavigation: @MainActor @Sendable (Tab.ID, Profile.ID) -> Void = { _, _ in }

	/// DEV-878: Clear History. The profile's tabs forget their saved back/forward history, and its
	/// open tabs save none until they close.
	public var forgetNavigation: @MainActor @Sendable (Profile.ID) -> Void = { _ in }

	/// ABI45 (DEV-795): whether Save Page As can save HTML and web archives.
	public var savePageIsAvailable: @MainActor @Sendable () -> Bool = { false }

	/// ABI45 (DEV-795): saves the tab's current web page to a file URL with Chromium's
	/// Save Page. The save runs as a download in the tab's profile.
	public var savePage: @MainActor @Sendable (Tab.ID, URL, BrowserSavePageFormat) throws -> Void = { _, _, _ in
		throw Failure.unavailable
	}

	/// ABI48 (DEV-819): the kind of the tab's committed document, known for a PDF while it's
	/// still loading. Nil with an older engine, or before anything has committed.
	public var documentType: @MainActor @Sendable (Tab.ID) -> BrowserDocumentType? = { _ in nil }

	/// ABI50 (DEV-857): whether the app link a tab offered with this token still comes from a
	/// current source (the same document, and the frame that asked). False when unknown.
	public var externalLinkIsCurrent: @MainActor @Sendable (Tab.ID, UInt64) -> Bool = { _, _ in false }

	/// DEV-873: whether the engine can unload a tab's page to free memory.
	public var tabUnloadingIsAvailable: @MainActor @Sendable () -> Bool = { false }

	/// DEV-873: unloads the tab's hidden page in place when the engine's rules allow it (no
	/// sound, picture in picture, form input, capture or DevTools, among Chrome's reasons). It
	/// keeps its address, title and history, reports `isUnloaded` in its snapshot, and loads
	/// again when it's shown or opened.
	public var unloadTab: @MainActor @Sendable (Tab.ID, TabUnloadReason) -> TabUnloadOutcome = { _, _ in
		.unavailable
	}

	/// DEV-1107: whether the tab's page holds form input or other edits it hasn't saved, which
	/// closing the window holding it would keep loaded. The window asks such pages before it
	/// closes, then unloads them with `TabUnloadReason.windowClosedAnswered`. False by default,
	/// and with an engine that can't.
	public var tabHoldsUnsavedInput: @MainActor @Sendable (Tab.ID) -> Bool = { _ in false }

	/// DEV-1128: ends the tab's video or document picture in picture without unloading its page,
	/// as closing the window that owns the tab does while an agent keeps the page loaded.
	public var endPictureInPicture: @MainActor @Sendable (Tab.ID) -> Void = { _ in }

	/// ABI48 (DEV-828): whether the engine runs extensions' actions for a tab.
	public var extensionActionsAreAvailable: @MainActor @Sendable () -> Bool = { false }

	/// Runs an extension's toolbar action for the tab, as a click on its toolbar button: its
	/// popup opens at the point, in AppKit screen coordinates, or the extension gets the click.
	/// Only for the person's own click.
	public var runExtensionAction: @MainActor @Sendable (
		Tab.ID,
		_ extensionID: String,
		_ screenPoint: CGPoint
	) throws(BrowserExtensionActionFailure) -> BrowserExtensionActionRun = { _, _, _ throws(BrowserExtensionActionFailure) in
		throw .unavailable
	}

	/// DEV-824 follow-up: the PNG of the icon an extension set for the tab with `setIcon` or a
	/// declarative rule, at scale 1 or 2. Nil when it set none, or the engine can't tell.
	public var extensionActionIcon: @MainActor @Sendable (
		Tab.ID,
		_ extensionID: String,
		_ scale: Float
	) -> Data? = { _, _, _ in nil }

	/// DEV-1316: extensions' action popups open in the app's windows, closing on losing focus as
	/// the windows' rule says; nil goes back to the engine's own window. False when the engine
	/// can't, as one built before it, which keeps its popover.
	public var setExtensionPopupWindows: @MainActor @Sendable (BrowserExtensionPopupWindows?) -> Bool = { _ in false }

	/// DEV-1019: whether the engine hides elements with uBlock Origin's element picker.
	public var elementHidingIsAvailable: @MainActor @Sendable () -> Bool = { false }

	/// DEV-1019: opens uBlock Origin's element picker on the tab's page, an ordinary http(s)
	/// page in a profile with content blocking on. False when it can't.
	public var startElementPicker: @MainActor @Sendable (Tab.ID) -> Bool = { _ in false }

	/// DEV-1019: the elements hidden on sites in the tab's profile, from uBlock's My filters.
	/// Nil when the engine can't read them.
	public var hiddenElements: @MainActor @Sendable (Tab.ID) async -> BrowserHiddenElements? = { _ in nil }

	/// DEV-1019: takes one of `hiddenElements`' filters out of My filters in the tab's profile.
	/// The element shows once the page reloads. False when it can't.
	public var showHiddenElement: @MainActor @Sendable (Tab.ID, _ filter: String) -> Bool = { _, _ in false }

	/// DEV-1201: whether the engine runs Arx's own element picker, which saves to My filters.
	public var elementPickerIsAvailable: @MainActor @Sendable () -> Bool = { false }

	/// DEV-1201: Arx's own element picker on the tab's page, drawn in `accent`, until it ends: a
	/// pick saves its line to My filters in the tab's profile. ⇧⌘H again closes it.
	public var pickElement: @MainActor @Sendable (
		Tab.ID,
		_ accent: ChromePalette.RGB
	) async -> BrowserElementPick = { _, _ in .unavailable }

	/// DEV-1298: Hide Element's mode on the tab's page, outlined in `accent`, with `cursor`'s
	/// pointer over the page: the picker stays open, each pick hidden and saved to My filters,
	/// until Done (`elementHidingCommand(.close)`), ⇧⌘H again or the page going away, when the
	/// stream ends. It starts with `unavailable` and ends where the engine can't run it.
	public var hideElements: @MainActor @Sendable (
		Tab.ID,
		_ accent: ChromePalette.RGB,
		_ cursor: @escaping @MainActor @Sendable () -> NSCursor?
	) -> AsyncStream<BrowserElementHidingEvent> = { _, _, _ in
		AsyncStream { continuation in
			continuation.yield(.unavailable)
			continuation.finish()
		}
	}

	/// DEV-1298: hands Hide Element's mode on the tab what the app asks of it. False when no
	/// mode is open there.
	public var elementHidingCommand: @MainActor @Sendable (Tab.ID, BrowserElementHidingCommand) -> Bool = { _, _ in false }

	/// ABI31: the JavaScript dialog or permission prompt the tab is showing.
	public var pageDialog: @MainActor @Sendable (Tab.ID) -> BrowserPageDialog? = { _ in nil }

	/// Accepts or dismisses that exact dialog after the final authorization.
	public var answerPageDialog: @MainActor @Sendable (
		Tab.ID,
		BrowserPageDialog,
		_ accept: Bool,
		_ text: String?,
		@escaping @MainActor @Sendable () -> Bool
	) -> BrowserPageDialogAnswer = { _, _, _, _, _ in .unavailable }

	/// ABI56 (DEV-963): the app draws ordinary site permission prompts instead of the engine's
	/// sheet. Set once at launch; false when the engine can't. Off keeps the engine's sheet.
	public var setPagePromptsHosted: @MainActor @Sendable (Bool) -> Bool = { _ in false }

	/// ABI56: the tab's current hosted permission prompt `token`, or nil once it's gone.
	public var pagePermissionPrompt: @MainActor @Sendable (Tab.ID, UInt64) -> BrowserPagePermissionPrompt? = { _, _ in
		nil
	}

	/// ABI56: answers that exact prompt with the person's decision and, for a location prompt
	/// that offered a choice, the accuracy picked (nil keeps the prompt's own). The engine
	/// rechecks the source and turns an answer given too soon, or away from the source window,
	/// into a dismissal.
	public var answerPagePermissionPrompt: @MainActor @Sendable (
		Tab.ID,
		_ token: UInt64,
		BrowserPagePermissionDecision,
		BrowserPagePermissionPrompt.Accuracy?
	) -> BrowserPageDialogAnswer = { _, _, _, _ in .unavailable }

	/// ABI37: the link with keyboard focus in the tab's current document, in any frame
	/// (DEV-713). Nil when the focused element isn't an http(s) link, for private tabs,
	/// hidden pages, or when the page navigated before the engine answered.
	public var focusedLink: @MainActor @Sendable (Tab.ID) async -> BrowserFocusedLink? = { _ in nil }

	/// DEV-1084: whether the tab's page holds form input a person typed and hasn't sent, in any
	/// frame, cross-origin ones too. Nil when the engine can't check (an engine built before it,
	/// a WebKit page, no live page).
	public var formEdits: @MainActor @Sendable (Tab.ID) async -> BrowserFormEdits? = { _ in nil }

	/// DEV-898: Arx's processes with their memory and CPU time, and what runs in each renderer,
	/// for the Task Manager. Nil with an engine built before it.
	public var processTable: @MainActor @Sendable () -> BrowserProcessTable? = { nil }

	/// Ends a renderer the last table listed, as Chrome's Task Manager does. False for any other
	/// process or with an older engine.
	public var endProcess: @MainActor @Sendable (Int32) -> Bool = { _ in false }

	/// ABI41: the tab's page zoom factor, 1 being 100% (DEV-726). Nil when the
	/// engine doesn't have the tab's page.
	public var pageZoom: @MainActor @Sendable (Tab.ID) -> Double? = { _ in nil }

	/// ABI41: sets the tab's page zoom factor (0.25-5) for its host, as Chrome's
	/// Zoom In does, or returns it to the profile's default with 0. A private
	/// tab's level lasts only as long as its private profile. Returns the factor
	/// now in effect, or nil when the engine couldn't change it.
	public var setPageZoom: @MainActor @Sendable (Tab.ID, Double) -> Double? = { _, _ in nil }

	/// DEV-1020: whether the engine can darken pages.
	public var darkPagesAreAvailable: @MainActor @Sendable () -> Bool = { false }

	/// DEV-1020: what every page darkens, now and as pages are created. A page's sites are its
	/// profile's in the configuration; a change restyles open pages without reloading them.
	public var setDarkPages: @MainActor @Sendable (DarkPagesConfiguration) -> Void = { _ in }

	/// ABI34: whether the engine has the developer tier (DEV-668).
	public var developerTierIsAvailable: @MainActor @Sendable () -> Bool = { false }

	/// Runs a script in the tab's developer world after the final authorization.
	public var evaluateScript: EvaluateScript = { _, _, _, _, _ throws(BrowserDeveloperFailure) in
		throw .unavailable
	}

	/// ABI57 (DEV-996): runs the app's page translation scripts in the tab's translation world,
	/// apart from agents' developer world, in ordinary and private tabs.
	public var evaluateTranslationScript: EvaluateTranslationScript = { _, _, _, _ throws(BrowserDeveloperFailure) in
		throw .unavailable
	}

	/// Starts or stops keeping the tab's console and network logs. Stopping drops them.
	public var setDeveloperLog: @MainActor @Sendable (Tab.ID, Bool) -> Bool = { _, enabled in !enabled }

	/// Reads the tab's console or network log after a sequence number.
	public var readDeveloperLog: ReadDeveloperLog = { _, _, _, _ throws(BrowserDeveloperFailure) in
		throw .unavailable
	}

	/// DEV-924: whether the engine keeps request headers and bodies for `browser_logs`.
	public var networkDetailsAreAvailable: @MainActor @Sendable () -> Bool = { false }

	/// Starts or stops keeping an ordinary tab's request details; stopping drops them.
	public var setNetworkCapture: @MainActor @Sendable (Tab.ID, Bool) -> Bool = { _, enabled in !enabled }

	/// The kept request details after a sequence number, at most a count, bodies cut at a byte
	/// count, as the engine's JSON. Nil when the tab isn't keeping them.
	public var readNetworkCapture: @MainActor @Sendable (Tab.ID, UInt64, Int, Int) -> Data? = { _, _, _, _ in nil }

	/// Chromium's password manager is in this engine (DEV-708).
	public var passwordsAreAvailable: @MainActor @Sendable () -> Bool = { false }

	/// The accounts saved in the tab's own profile for exactly its origin. Never a password.
	public var savedAccounts: SavedAccounts = { _ throws(BrowserPasswordFailure) in
		throw .unavailable
	}

	/// Fills a listed account into the tab after the final authorization, submits
	/// it and reports only how it ended.
	public var signInWithPassword: SignInWithPassword = { _, _, _, _, _ throws(BrowserPasswordFailure) in
		throw .unavailable
	}

	/// Offers to save or update a password the user submitted in an ordinary tab.
	public var passwordSaveOffers: @MainActor @Sendable () -> AsyncStream<BrowserPasswordSaveOffer> = {
		.finished
	}

	/// Answers the tab's current save offer; false when it's gone.
	public var answerPasswordSave: @MainActor @Sendable (
		Tab.ID,
		_ token: UInt64,
		BrowserPasswordSaveAnswer
	) -> Bool = { _, _, _ in false }

	/// Autofill suggestions for ordinary tabs' focused fields, drawn by the app (DEV-875).
	public var autofillEvents: @MainActor @Sendable () -> AsyncStream<BrowserAutofillEvent> = {
		.finished
	}

	/// Fills a shown suggestion, as a click on it; Touch ID or the login password first
	/// where the authentication setting says so. False when it's no longer shown.
	public var acceptAutofillSuggestion: @MainActor @Sendable (
		Tab.ID,
		_ session: UInt64,
		BrowserAutofillItem.ID
	) -> Bool = { _, _, _ in false }

	/// The suggestion under the pointer, so Return fills it.
	public var selectAutofillSuggestion: @MainActor @Sendable (
		Tab.ID,
		_ session: UInt64,
		BrowserAutofillItem.ID?
	) -> Void = { _, _, _ in }

	public var dismissAutofillSuggestions: @MainActor @Sendable (
		Tab.ID,
		_ session: UInt64
	) -> Void = { _, _ in }

	/// App-wide. The reasons finish LocalAuthentication's prompt, "Arx is trying to …".
	public var setAutofillAuthentication: @MainActor @Sendable (
		BrowserAutofillAuthentication,
		_ passwordReason: String,
		_ cardReason: String
	) -> Void = { _, _, _ in }

	/// Whether ordinary profiles fill addresses and payment cards (DEV-893). App-wide.
	public var setAutofillProducts: @MainActor @Sendable (_ addresses: Bool, _ cards: Bool) -> Void = { _, _ in }

	/// Settings can manage addresses and payment cards in this engine (DEV-893).
	public var autofillDataIsAvailable: @MainActor @Sendable () -> Bool = { false }

	/// An ordinary profile's addresses and payment cards.
	public var autofillListing: AutofillListingRequest = { _ throws(BrowserAutofillDataFailure) in
		throw .unavailable
	}

	/// Adds an address (empty `id`) or edits one.
	public var saveAutofillAddress: SaveAutofillAddress = { _, _ throws(BrowserAutofillDataFailure) in
		throw .unavailable
	}

	/// Adds a card or edits one; the engine reads the number from the lent field.
	public var saveAutofillCard: SaveAutofillCard = { _ throws(BrowserAutofillDataFailure) in
		throw .unavailable
	}

	/// Removes an address or a card.
	public var removeAutofillData: RemoveAutofillData = { _, _ throws(BrowserAutofillDataFailure) in
		throw .unavailable
	}

	/// Settings can manage saved passwords in this engine (DEV-721).
	public var savedPasswordsAreAvailable: @MainActor @Sendable () -> Bool = { false }

	/// An ordinary profile's saved passwords (site and username) and "never saved" sites.
	public var savedPasswords: SavedPasswords = { _ throws(BrowserSavedPasswordFailure) in
		throw .unavailable
	}

	/// Adds or edits a saved password; the engine reads the password from the lent field.
	public var savePassword: SavePassword = { _ throws(BrowserSavedPasswordFailure) in
		throw .unavailable
	}

	/// Removes a saved password or a "never saved" site.
	public var removeSavedPassword: RemoveSavedPassword = { _, _, _ throws(BrowserSavedPasswordFailure) in
		throw .unavailable
	}

	/// After the device owner authenticates, copies a saved password or shows it
	/// in a lent field. The value never reaches the caller.
	public var revealSavedPassword: RevealSavedPassword = { _, _, _, _, _ throws(BrowserSavedPasswordFailure) in
		throw .unavailable
	}

	/// Imports a Chrome or Apple Passwords CSV export into an ordinary profile.
	public var importPasswords: ImportPasswords = { _, _ throws(BrowserSavedPasswordFailure) in
		throw .unavailable
	}

	/// This engine takes decrypted passwords and cookies from another browser (ABI46, DEV-830).
	/// Without it the migration assistant offers the CSV import and never reads the Keychain.
	public var credentialImportIsAvailable: @MainActor @Sendable () -> Bool = { false }

	/// Adds decrypted passwords to an ordinary profile's own store, keeping saved pairs.
	public var importPasswordRecords: ImportPasswordRecords = { _, _ throws(BrowserCredentialImportFailure) in
		throw .unavailable
	}

	/// Sets decrypted cookies in an ordinary profile, keeping cookies it already has.
	public var importCookies: ImportCookies = { _, _ throws(BrowserCredentialImportFailure) in
		throw .unavailable
	}

	/// The keys that name an unexpired cookie in the profile now.
	public var checkCookies: CheckCookies = { _, _ throws(BrowserCredentialImportFailure) in
		throw .unavailable
	}

	/// Removes exactly what one import added; returns how many entries went.
	public var undoCredentialImport: UndoCredentialImport = { _, _, _ throws(BrowserCredentialImportFailure) in
		throw .unavailable
	}

	/// Settings can manage site permissions and page zoom in this engine (DEV-716).
	public var siteSettingsAreAvailable: @MainActor @Sendable () -> Bool = { false }

	/// An ordinary profile's permission defaults, site exceptions and page zoom.
	public var siteSettings: SiteSettingsRead = { _ throws(SiteSettingsFailure) in
		throw .unavailable
	}

	/// Applies one change to an ordinary profile's site settings and returns them fresh.
	public var changeSiteSettings: ChangeSiteSettings = { _, _ throws(SiteSettingsFailure) in
		throw .unavailable
	}

	/// Profiles whose site settings changed, from Settings, automation or a page's
	/// permission prompt, once each has been read.
	public var siteSettingsChanges: @MainActor @Sendable () -> AsyncStream<Profile.ID> = { .finished }

	/// Settings can clear browsing data and set the downloads folder in this engine (DEV-647).
	public var profileDataIsAvailable: @MainActor @Sendable () -> Bool = { false }

	public var countBrowsingData: CountBrowsingData = { _, _, _ throws(ProfileDataFailure) in
		throw .unavailable
	}

	public var clearBrowsingData: ClearBrowsingData = { _, _, _ throws(ProfileDataFailure) in
		throw .unavailable
	}

	/// The site menu can clear one site's cookies and cache in this engine (DEV-633).
	public var siteDataIsAvailable: @MainActor @Sendable () -> Bool = { false }

	public var siteDataScope: SiteDataScope = { _, _ throws(ProfileDataFailure) in
		throw .unavailable
	}

	public var clearSiteData: ClearSiteData = { _, _, _ throws(ProfileDataFailure) in
		throw .unavailable
	}

	/// An ordinary profile's downloads folder and whether it asks where to save.
	public var downloadSettings: DownloadSettingsRead = { _ throws(ProfileDataFailure) in
		throw .unavailable
	}

	public var changeDownloadSettings: ChangeDownloadSettings = { _, _, _ throws(ProfileDataFailure) in
		throw .unavailable
	}

	/// The security components the engine keeps updating and the versions it uses
	/// (DEV-874); empty where the engine has no user data directory to read.
	public var securityComponents: @Sendable () async -> [BrowserSecurityComponent] = { [] }

	public init(
		status: @escaping @Sendable () -> BrowserEngineStatus,
		referenceSubmissionsAreSettled: @escaping @MainActor @Sendable (Tab.ID) -> Bool = { _ in false },
		snapshot: @escaping @MainActor @Sendable (Tab.ID) -> BrowserSessionSnapshot? = { _ in nil },
		openAuthorized: @escaping @MainActor @Sendable (
			Tab,
			@escaping @MainActor @Sendable () -> Bool
		) async throws -> Void = { _, _ in throw Failure.unavailable },
		commandAuthorized: @escaping @MainActor @Sendable (
			Tab.ID,
			UInt64,
			Command,
			@escaping @MainActor @Sendable () -> Bool
		) async throws -> Void = { _, _, _, _ in throw Failure.unavailable },
		closeAuthorized: AuthorizedClose? = nil,
		open: @escaping @MainActor @Sendable (Tab) async throws -> Void = { _ in
			throw Failure.unavailable
		},
		command: @escaping @MainActor @Sendable (Tab.ID, Command) async throws -> Void = { _, _ in
			throw Failure.unavailable
		},
		permitsClosing: @escaping @MainActor @Sendable (Tab.ID) async -> Bool = { _ in true },
		close: @escaping @MainActor @Sendable (Tab.ID) -> Void = { _ in },
		prepareProfile: @escaping @MainActor @Sendable (Profile.ID) async throws -> Void = { _ in },
		preparePrivateProfile: @escaping @MainActor @Sendable (Profile.ID, Profile.ID?) throws -> Void = { _, _ in
			throw Failure.unavailable
		},
		releasePrivateProfile: @escaping @MainActor @Sendable (Profile.ID) -> Void = { _ in },
		events: @escaping @MainActor @Sendable (Tab.ID) -> AsyncStream<BrowserNavigation> = { _ in
			.finished
		},
		linkContexts: @escaping @MainActor @Sendable () -> AsyncStream<BrowserLinkContext> = { .finished },
		linkContextIsCurrent: @escaping @MainActor @Sendable (BrowserLinkContext) -> Bool = { _ in false },
		dismissLinkContext: @escaping @MainActor @Sendable (BrowserLinkContext) -> Void = { _ in },
		inspectLinkContext: @escaping @MainActor @Sendable (BrowserLinkContext) -> Bool = { _ in false },
		retirementIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		blockProfileRetirement: @escaping @MainActor @Sendable (Profile.ID) -> Void = { _ in },
		profileRetirementSnapshot: @escaping @MainActor @Sendable () async throws -> ProfileRetirementSnapshot = {
			throw ProfileRetirementFailure.unavailable
		},
		retireProfile: @escaping @MainActor @Sendable (
			ProfileRetirementRequest,
			@escaping @MainActor @Sendable () -> Bool
		) async throws -> ProfileRetirementSnapshot = { _, _ in throw ProfileRetirementFailure.unavailable }
	) {
		self.referenceSubmissionsAreSettled = referenceSubmissionsAreSettled
		self.status = status
		self.snapshot = snapshot
		self.openAuthorized = openAuthorized
		self.commandAuthorized = commandAuthorized
		self.closeAuthorized = closeAuthorized
		self.open = open
		self.command = command
		self.close = close
		self.permitsClosing = permitsClosing
		self.prepareProfile = prepareProfile
		self.preparePrivateProfile = preparePrivateProfile
		self.releasePrivateProfile = releasePrivateProfile
		self.events = events
		self.linkContexts = linkContexts
		self.linkContextIsCurrent = linkContextIsCurrent
		self.dismissLinkContext = dismissLinkContext
		self.inspectLinkContext = inspectLinkContext
		self.retirementIsAvailable = retirementIsAvailable
		self.blockProfileRetirement = blockProfileRetirement
		self.profileRetirementSnapshot = profileRetirementSnapshot
		self.retireProfile = retireProfile
	}

	public enum Command: Equatable, Sendable {
		case navigate(URL)
		case back
		case forward
		case clearCacheAndReload
		case reloadBypassingCache

		/// Opens or focuses Chromium DevTools for the exact session; no fallback target.
		/// Docked in the page since ABI42 (DEV-733), unless DevTools was undocked last.
		case openDeveloperTools

		/// Closes the session's DevTools when it's open, or opens it.
		case toggleDeveloperTools

		/// ABI42: opens DevTools if needed at one of its panels.
		case showDeveloperToolsPanel(DeveloperToolsPanel)

		/// ABI42: opens DevTools if needed and starts Inspect Element's picker.
		case inspectElementMode
		case reload
		case stop
		case historyEntry(Int)
		case find(String, forward: Bool, newSession: Bool)
		case stopFind

		/// ABI41: steps the page's zoom for its host, or the tab alone in a private window's
		/// profile until it closes (DEV-726).
		case zoom(PageZoom)

		/// ABI54 (DEV-949): takes the page out of HTML full screen, as Escape does. Nothing
		/// happens when it isn't in full screen or the engine can't.
		case exitFullScreen
	}

	/// DevTools panels Arx opens directly (DEV-733).
	public enum DeveloperToolsPanel: String, Equatable, Sendable {
		case console
		case network
		case elements
	}

	public enum Failure: Error {
		case unavailable
		case missingSession
		case unsupportedProfile
	}
}

extension BrowserEngineClient: DependencyKey {
	public static var liveValue: Self { .init(status: { .notIntegrated }) }

	public static var testValue: Self {
		.init(
			status: unimplemented(
				"BrowserEngineClient.status",
				placeholder: .notIntegrated
			)
		)
	}

	public static var previewValue: Self { liveValue }
}

extension DependencyValues {
	public var browserEngine: BrowserEngineClient {
		get { self[BrowserEngineClient.self] }
		set { self[BrowserEngineClient.self] = newValue }
	}
}

extension BrowserCommand {
	/// The page command a browser command performs on its exact target session.
	public var engineCommand: BrowserEngineClient.Command? {
		switch self {
		case .goBack: .back
		case .goForward: .forward
		case .reload: .reload
		case .clearCacheAndReload: .clearCacheAndReload
		case .reloadBypassingCache: .reloadBypassingCache
		case .stopLoading: .stop
		case .developerTools: .toggleDeveloperTools
		case .inspectElement: .inspectElementMode
		case .javaScriptConsole: .showDeveloperToolsPanel(.console)
		case .zoomIn, .zoomOut, .actualSize: pageZoom.map { BrowserEngineClient.Command.zoom($0) }
		default: nil
		}
	}
}

/// ABI45 (DEV-795). The formats Chromium's Save Page writes, as Chrome offers them.
public enum BrowserSavePageFormat: Equatable, Sendable {
	/// The HTML and its resources in a "<name>_files" folder beside it.
	case complete

	/// The page's HTML alone.
	case htmlOnly

	/// One MHTML web archive.
	case webArchive
}

extension BrowserEngineClient.Command {
	/// DEV-1009: the command leaves the document or stops it, so on a page that stopped
	/// answering its renderer ends first: reload, stop, back, forward, a history entry and a
	/// new address.
	public var leavesTheDocument: Bool {
		switch self {
		case .navigate, .back, .forward, .clearCacheAndReload, .reloadBypassingCache, .reload, .stop, .historyEntry:
			true
		default:
			false
		}
	}
}
