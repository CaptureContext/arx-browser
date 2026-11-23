import AppKit
import ChromiumBridge
import IssueReporting

@MainActor
public final class ChromiumRuntime {
	public enum State: Equatable, Sendable {
		case idle
		case starting
		case running
		case stopped
	}

	public private(set) var state: State = .idle
	internal let api: ArxEngineAPI

	/// DEV-800, nil on engines built before per-tab volume.
	internal let audioVolume: ChromiumAudioVolumeFunction?

	/// DEV-880, nil on engines built before idle profile release.
	internal let releaseProfileFunction: ChromiumReleaseProfileFunction?
	internal let profileIsLoadedFunction: ChromiumProfileIsLoadedFunction?

	/// DEV-873, nil on engines built before tab unloading.
	internal let pageUnloading: ChromiumPageUnloadFunctions?

	/// DEV-898, nil on engines built before the Task Manager.
	internal let processFunctions: ChromiumProcessFunctions?

	/// DEV-892, nil on engines built before download pause and resume.
	internal let downloadControls: ChromiumDownloadControlFunctions?

	/// DEV-924, nil on engines built before request details.
	internal let networkCapture: ChromiumNetworkCaptureFunctions?

	/// DEV-884, DEV-890. Set once, right after loading the framework.
	internal var optionalExports: ChromiumOptionalExports = .init()

	/// DEV-878, nil on engines built before tabs kept their back/forward history.
	internal let navigationStateFunctions: ChromiumNavigationStateFunctions?

	/// DEV-907, nil on engines built before pages reported Badging API badges.
	internal let pageBadgeFunction: ChromiumPageBadgeFunction?

	/// DEV-907: a page's Badging API report: nil clears it, `.some(nil)` is a badge without a
	/// number, else the count.
	public var onPageBadge: (@MainActor (ChromiumPage, UInt64??) -> Void)?
	internal let extensionBridge: ChromiumExtensions
	internal let closeRequests: ChromiumCloseRequests
	internal let siteIcons: ChromiumSiteIcons
	internal let inspections: ChromiumInspections
	internal let pdfs: ChromiumPDFs
	internal let developers: ChromiumDevelopers
	internal let passwords: ChromiumPasswords
	internal let autofill: ChromiumAutofill
	internal let autofillData: ChromiumAutofillData
	internal let savedPasswords: ChromiumSavedPasswords
	internal let credentialImport: ChromiumCredentialImport
	internal let focusedLinks: ChromiumFocusedLinks
	internal let siteSettings: ChromiumSiteSettingsRequests
	internal let profileData: ChromiumProfileDataRequests
	internal let referenceClicks: ChromiumReferenceClicks
	internal let linkContexts: ChromiumLinkContexts
	internal let profileRetirement: ChromiumProfileRetirement
	private var pageSiteIconScopes: [UInt64: ChromiumSiteIcons.Scope] = [:]

	/// DEV-851. Each ordinary page's profile key, so engine work it starts can hold the profile.
	private var pageProfileKeys: [UInt64: String] = [:]

	/// The web addresses each ordinary page went through since its current load started,
	/// so an icon change names only the pages whose icons it touched (DEV-940).
	private var pageSiteIconURLs: [UInt64: [URL]] = [:]

	/// Pages whose current load redirected through more addresses than native sends:
	/// their changes refresh the whole profile until a new load starts.
	private var pageSiteIconTruncated: Set<UInt64> = []

	/// Pages Chromium reported an icon for since their current load started. Before
	/// that, Chromium maps the coming icon to every same-document address too.
	private var pageSiteIconReported: Set<UInt64> = []
	private var siteIconObservers: [UUID: AsyncStream<ChromiumSiteIconChange>.Continuation] = [:]
	private var requests: [UInt64: CheckedContinuation<Bool, Never>] = [:]
	private var closingRequests: [UInt64: UInt64] = [:]

	/// Callers waiting for a close request already asked of the same page, by that request.
	private var closingWaiters: [UInt64: [CheckedContinuation<Bool, Never>]] = [:]
	private let media: ChromiumMediaObservation = .init()
	private var captures: [UInt64: CaptureRequest] = [:]

	/// DEV-1172. Whole-page captures in flight (ChromiumWholePageCapture.swift).
	internal var wholePageCaptures: [UInt64: WholePageCaptureRequest] = [:]
	internal var nextRequest: UInt64 = 1
	private var preparedProfiles: Set<String> = []

	/// DEV-880. When something last prepared or worked in each prepared ordinary profile.
	private var profileUses: [String: ContinuousClock.Instant] = [:]

	/// DEV-880. Engine work in flight per ordinary profile; a held profile isn't released.
	private var profileHolds: [String: Int] = [:]
	private var lastRuntimeExtensionOptionsChild: UInt64 = 0
	private var runtimeOptionsOffers: [UInt64: RuntimeOptionsOffer] = [:]
	private var pendingOptionsSettlements: Set<UInt64> = []
	private var privateProfileKeys: Set<String> = []
	internal private(set) var pages: [UInt64: ChromiumPage] = [:]

	/// Synchronous host acceptance; consumers defer any close until after the native ACK.
	public var onUnhandledEscape: (@MainActor @Sendable (ChromiumPage, UInt64) -> Bool)?

	/// ABI62 (DEV-1264, DEV-1073). A ⌘ key a focused page received, and whether the page used it.
	/// A key the page used is reported after the renderer answers, and the return is ignored; a key
	/// it left is reported while Chromium still holds it: return true when the app ran its command.
	public var onCommandKey: (@MainActor @Sendable (ChromiumPage, ChromiumCommandKey, Bool) -> Bool)?

	/// ABI42: a page's DevTools opened, closed, docked, undocked or moved its divider.
	public var onDeveloperToolsLayout: (@MainActor @Sendable (ChromiumPage) -> Void)?

	/// ABI45 (DEV-795): an item the person chose in a page's page menu.
	public var onPageMenuChoice: (@MainActor @Sendable (ChromiumPage, ChromiumPageMenuItem) -> Void)?

	/// ABI45 (DEV-795): the page menu items the page's host can carry out now; none leaves
	/// them out of the menu. Read synchronously when the menu opens: never close a page here.
	public var onPageMenuItems: (@MainActor @Sendable (ChromiumPage) -> Set<ChromiumPageMenuItem>)?

	/// ABI48 (DEV-814): an app item the person chose in a context menu.
	public var onContextMenuChoice: (@MainActor @Sendable (ChromiumPage, ChromiumContextMenuChoice) -> Void)?

	/// ABI48 (DEV-814): the app items a page's host can carry out now, asked as a
	/// context menu opens. Items the engine carries out itself are always offered.
	public var onContextMenuItems: (@MainActor @Sendable (ChromiumPage) -> Set<ChromiumContextMenuItem>)?

	/// ABI49 (DEV-855): the page called `window.close()` and Blink allowed it (a window a
	/// script opened), for its current document. Blink has run its before-unload. Close the
	/// page's host without asking again, or ignore it: nothing has closed.
	public var onPageCloseRequest: (@MainActor @Sendable (ChromiumPage) -> Void)?

	/// ABI54 (DEV-949): a page entered (true) or left (false) HTML full screen. Entering, show
	/// only that page, filling the screen, until it leaves; ``exitFullScreen(_:)`` takes it out.
	public var onPageFullScreen: (@MainActor @Sendable (ChromiumPage, Bool) -> Void)?

	/// ABI60 (DEV-1111): the link under the pointer in the page's current document, as
	/// Chrome's status bubble shows it, or nil once the pointer leaves it. Without its user
	/// name or password; private pages report too.
	public var onLinkHover: (@MainActor @Sendable (ChromiumPage, ChromiumHoveredLink?) -> Void)?

	/// ABI60 (DEV-1111): whether pages report hovered links, as ``setLinkHoverReports(_:)`` last
	/// asked. The app asks before the engine runs, so ``didBecomeReady()`` applies it then.
	internal var linkHoverReports: Bool = false

	/// ABI56 (DEV-963): with ``setPagePromptsHosted(_:)`` on, a page's site permission prompt
	/// for the app to draw became current (its token), or went away (0), also when the app
	/// closes the page. Read it with
	/// ``ChromiumPage/permissionPrompt(token:)``.
	public var onPagePermissionPrompt: (@MainActor @Sendable (ChromiumPage, UInt64) -> Void)?

	/// DEV-880: an ordinary profile, nil being Default, became prepared: loaded for the first
	/// time, or again after a release.
	public var onOrdinaryProfilePrepared: (@MainActor @Sendable (UUID?) -> Void)?

	/// ABI24. A Force Click on an http(s) link in the page's current document.
	/// True takes it: native skips Look Up and the press never clicks the link.
	public var onLinkForceClick: (@MainActor @Sendable (ChromiumPage, UInt64, URL) -> Bool)?

	/// ABI43. A plain click on a link to another site in the page's current document.
	/// True takes it: native cancels the navigation and the page stays where it was.
	public var onCrossSiteLink: (@MainActor @Sendable (ChromiumPage, UInt64, URL) -> Bool)?

	/// ABI50 (DEV-857): a page asked to open a link for another app, before Chrome's lookup,
	/// "Open app?" dialog or launch. True takes it: Chrome shows and launches nothing, and the
	/// app asks and opens it itself. False leaves it to Chrome, unchanged.
	public var onExternalLink: (@MainActor @Sendable (ChromiumPage, ChromiumExternalLink) -> Bool)?

	/// ABI44. The Chrome Web Store in an ordinary page asked to install an item
	/// (Add to Chrome). True takes the request: prepare it with
	/// ``prepareWebstoreInstallation(_:in:)`` or decline it. False answers the
	/// store that the user cancelled.
	public var onWebstoreInstall: (@MainActor @Sendable (ChromiumPage, ChromiumWebstoreInstallRequest) -> Bool)?

	/// The child is already native-owned. Refusal removes only its wrapper; native
	/// ownership returns to the offer and is destroyed without touching its opener.
	public var onNewContents: (@MainActor @Sendable (
		ChromiumPage, UInt64, ChromiumPage, URL, ChromiumNewContentsDisposition
	) -> Bool)?

	/// A manifest-derived options page admitted by a pending Settings request or
	/// an actual native RuntimeAPI call in the exact ordinary extension profile.
	public var onExtensionView: (@MainActor @Sendable (ChromiumPage, UUID?, String) -> Bool)?

	/// Only the failed synchronous post-publication check may revoke this initial offer.
	public var onExtensionOptionsRevoked: (@MainActor @Sendable (ChromiumPage, UUID?, String) -> Void)?

	/// Releases initial rollback bookkeeping while preserving the published page.
	public var onExtensionOptionsSettled: (@MainActor @Sendable (ChromiumPage) -> Void)?

	/// ABI55 (DEV-885). While a click on a notification from the page's site ran, the page
	/// asked to come forward (window.focus() from its onclick, a service worker's
	/// client.focus(), or a page its openWindow() opened). Show its tab and bring Arx forward.
	public var onPageActivationRequest: (@MainActor @Sendable (ChromiumPage) -> Void)?

	/// ABI55 (DEV-885). A service worker opened a window during a click on its
	/// notification. The page is native-owned and loading; the profile is nil for the
	/// legacy Default profile. True adopts it as a foreground tab; false closes it.
	public var onNotificationWindow: (@MainActor @Sendable (ChromiumPage, UUID?) -> Bool)?

	/// ABI55 (DEV-885). A click on a site's notification finished.
	public var onNotificationClick: (@MainActor @Sendable (ChromiumNotificationClick) -> Void)?
	private var lastNotificationWindowChild: UInt64 = 0
	private var downloads: [String: [String: ChromiumDownload]] = [:]
	private var initializedDownloads: Set<String> = []
	private var downloadObservers: [UUID: AsyncStream<ChromiumDownloadEvent>.Continuation] = [:]
	private var downloadStarts: [UInt64: CheckedContinuation<Result<String, ChromiumDownloadStartFailure>, Never>] = [:]

	/// DEV-851: link downloads started and not yet waited on, and replies that came first.
	private var pendingLinkDownloads: Set<UInt64> = []
	private var finishedLinkDownloads: [UInt64: Result<String, ChromiumDownloadStartFailure>] = [:]

	/// The ordinary profile each link download holds until Chromium answers its start.
	private var linkDownloadHolds: [UInt64: String] = [:]

	/// DEV-963. Pages with a hosted permission prompt the app was told about, so closing one
	/// withdraws it: the engine's own withdrawal arrives after the page is gone.
	private var hostedPromptPages: Set<UInt64> = []
	private var onReady: (@MainActor (ChromiumRuntime) -> Void)?
	private var gestureFixtureEnabled: Bool = false

	/// Loads an Arx-built Helium framework executable, never an Ardia or stock Helium binary.
	public convenience init(frameworkExecutable: URL) throws {
		let framework = try ChromiumFramework.load(at: frameworkExecutable)
		self.init(
			api: framework.api,
			audioVolume: framework.audioVolume,
			releaseProfile: framework.releaseProfile,
			profileIsLoaded: framework.profileIsLoaded,
			pageUnloading: framework.pageUnloading,
			processFunctions: framework.processes,
			downloadControls: framework.downloadControls,
			networkCapture: framework.networkCapture,
			navigationState: framework.navigationState,
			pageBadges: framework.pageBadges
		)
		optionalExports = ChromiumFramework.optionalExports(at: frameworkExecutable)
	}

	internal init(
		api: ArxEngineAPI,
		audioVolume: ChromiumAudioVolumeFunction? = nil,
		releaseProfile: ChromiumReleaseProfileFunction? = nil,
		profileIsLoaded: ChromiumProfileIsLoadedFunction? = nil,
		pageUnloading: ChromiumPageUnloadFunctions? = nil,
		processFunctions: ChromiumProcessFunctions? = nil,
		downloadControls: ChromiumDownloadControlFunctions? = nil,
		networkCapture: ChromiumNetworkCaptureFunctions? = nil,
		navigationState: ChromiumNavigationStateFunctions? = nil,
		pageBadges: ChromiumPageBadgeFunction? = nil
	) {
		self.api = api
		self.audioVolume = audioVolume
		self.releaseProfileFunction = releaseProfile
		self.profileIsLoadedFunction = profileIsLoaded
		self.pageUnloading = pageUnloading
		self.processFunctions = processFunctions
		self.downloadControls = downloadControls
		self.networkCapture = networkCapture
		self.navigationStateFunctions = navigationState
		self.pageBadgeFunction = pageBadges
		self.extensionBridge = .init(api: api)
		self.closeRequests = .init(api: api)
		self.siteIcons = .init(api: api)
		self.inspections = .init(api: api)
		self.pdfs = .init(api: api)
		self.developers = .init(api: api)
		self.passwords = .init(api: api)
		self.autofill = .init(api: api)
		self.autofillData = .init(api: api)
		self.savedPasswords = .init(api: api)
		self.credentialImport = .init(api: api)
		self.focusedLinks = .init(api: api)
		self.siteSettings = .init(api: api)
		self.profileData = .init(api: api)
		self.referenceClicks = .init(api: api)
		self.linkContexts = .init(api: api)
		self.profileRetirement = .init(api: api)
	}

	/// Owns the main thread until Chromium exits. Call before NSApplication.shared or SwiftUI.App.main.
	/// Use a dedicated Arx profile directory. Helium and other browsers must not share it.
	/// The mock Keychain option is only for a disposable test profile. It does not
	/// validate production Keychain persistence or security; normal callers leave it false.
	public func run(
		executable: URL,
		profileDirectory: URL,
		mockKeychainForTesting: Bool = false,
		enableExtensions: Bool = false,
		extensionFixtureForTesting: Bool = false,
		profileRetirement: ChromiumProfileRetirementConfiguration? = nil,
		documentCaptureFixtureForTesting: Bool = false,
		gestureFixtureForTesting: Bool = false,
		extensionInstallFixtureForTesting: Bool = false,
		webstoreFixtureOriginForTesting: URL? = nil,
		onReady: @escaping @MainActor (ChromiumRuntime) -> Void
	) throws -> Int32 {
		guard state == .idle else { throw ChromiumError.alreadyStarted }
		guard
			executable.isFileURL,
			profileDirectory.isFileURL
		else { throw ChromiumError.invalidFileURL }
		let requiresMockKeychain = extensionFixtureForTesting
		|| documentCaptureFixtureForTesting
		|| extensionInstallFixtureForTesting

		guard !requiresMockKeychain || mockKeychainForTesting
		else { throw ChromiumExtensionFailure.invalidRequest }
		guard !gestureFixtureForTesting || mockKeychainForTesting
		else { throw ChromiumError.invalidFixture }

		let fixtureCount = [
			extensionFixtureForTesting,
			documentCaptureFixtureForTesting,
			gestureFixtureForTesting,
			extensionInstallFixtureForTesting
		].filter { $0 }.count

		guard
			fixtureCount <= 1,
			!(enableExtensions && (documentCaptureFixtureForTesting || gestureFixtureForTesting))
		else { throw ChromiumError.invalidFixture }
		guard fixtureCount == 0 || profileRetirement == nil
		else { throw ChromiumProfileRetirementFailure.invalid }
		let webstoreFixtureOrigin = try webstoreFixtureOriginForTesting.map { origin in
			guard
				extensionInstallFixtureForTesting,
				origin.scheme == "http",
				origin.host == "127.0.0.1",
				let port = origin.port,
				(1...65_535).contains(port),
				origin.path.isEmpty || origin.path == "/",
				origin.query == nil,
				origin.fragment == nil
			else { throw ChromiumError.invalidFixture }
			return "http://127.0.0.1:\(port)"
		}

		state = .starting
		self.onReady = onReady
		self.gestureFixtureEnabled = gestureFixtureForTesting
		extensionBridge.configure(
			enabled: enableExtensions,
			fixture: extensionFixtureForTesting,
			signedFixture: extensionInstallFixtureForTesting
		)
		defer { finish() }

		var callbacks = ArxEngineCallbacks(
			context: Unmanaged.passUnretained(self).toOpaque(),
			ready: { context in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.didBecomeReady()
				}
			},
			stopping: { context in
				MainActor.assumeIsolated {
					guard let context else { return }
					Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue().finish()
				}
			},
			profile_ready: { context, request, success in
				MainActor.assumeIsolated {
					guard let context else { return }
					Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue().complete(
						request,
						success
					)
				}
			},
			close_decided: { context, request, proceed in
				MainActor.assumeIsolated {
					guard let context else { return }
					Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue().complete(
						request,
						proceed
					)
				}
			},
			page_changed: { context, id, url, title, loading, back, forward, error in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.settleRuntimeOptionsOffer(page: id)
					runtime.pages[id]?.receive(.init(
						url: url.flatMap { URL(string: String(cString: $0)) },
						title: title.map { String(cString: $0) } ?? "",
						isLoading: loading,
						canGoBack: back,
						canGoForward: forward,
						errorCode: error == 0 ? nil : Int(error)
					))
				}
			},
			download_changed: { context, profile, snapshot in
				MainActor.assumeIsolated {
					guard let context, let profile, let snapshot
					else { return }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.receiveDownload(
						.changed(
							.init(
								profileKey: String(cString: profile),
								native: snapshot.pointee
							)
						)
					)
				}
			},
			downloads_initialized: { context, profile in
				MainActor.assumeIsolated {
					guard let context, let profile else { return }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.receiveDownload(.initialized(profileKey: String(cString: profile)))
				}
			},
			capture_completed: { context, request, page, status, snapshot in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.completeCapture(
						request,
						page: page,
						status: status,
						snapshot: snapshot?.pointee
					)
				}
			},
			media_changed: { context, page, snapshot in
				MainActor.assumeIsolated {
					guard let context, let snapshot else { return }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.media.receive(page: page, native: snapshot.pointee)
				}
			},
			media_completed: { context, request, page, status in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.media.complete(request: request, page: page, status: status)
				}
			},
			media_activated: { context, page, generation in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.media.activate(page: page, generation: generation)
				}
			},
			extensions_completed: { context, request, key, status, revision, bytes, count in
				MainActor.assumeIsolated {
					guard let context, let key else { return }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.extensionBridge.complete(
						request,
						profileKey: String(cString: key),
						status: status,
						revision: revision,
						bytes: bytes,
						count: count
					)
				}
			},
			authorized_close_decided: { context, request, page, status, token in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.closeRequests.complete(
						request: request,
						page: page,
						status: status,
						token: token
					)
				}
			},
			site_icon_changed: { context, page, url, iconURL in
				MainActor.assumeIsolated {
					guard let context, let url else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.receiveSiteIconChange(
						page: page,
						url: String(cString: url),
						iconURL: iconURL.map { String(cString: $0) }
					)
				}
			},
			site_icon_completed: { context, request, status, bytes, count, width, height, iconURL in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.siteIcons.complete(
						request,
						status: status,
						bytes: bytes,
						count: count,
						width: width,
						height: height,
						iconURL: iconURL.map { String(cString: $0) }
					)
				}
			},
			inspection_completed: { context, request, page, status, bytes, count in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.inspections.complete(
						request,
						page: page,
						status: status,
						bytes: bytes,
						count: count
					)
				}
			},
			reference_click_completed: { context, request, page, disposition, status in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.referenceClicks.complete(
						request,
						page: page,
						disposition: disposition,
						status: status
					)
				}
			},
			form_action_completed: { context, request, page, disposition, status in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.referenceClicks.completeFormAction(
						request,
						page: page,
						disposition: disposition,
						status: status
					)
				}
			},
			reference_scroll_completed: { context, request, page, disposition, status in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.referenceClicks.completeScroll(
						request,
						page: page,
						disposition: disposition,
						status: status
					)
				}
			},
			link_context_requested: { context, page, menu in
				MainActor.assumeIsolated {
					guard let context, let menu else { return false }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					return runtime.receiveLinkContext(page: page, native: menu.pointee)
				}
			},
			profile_retirement_completed: { context, request, status, snapshot in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.profileRetirement.complete(request, status: status, native: snapshot?.pointee)
				}
			},
			document_capture_completed: { context, request, page, status, snapshot in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.completeDocumentCapture(
						request,
						page: page,
						status: status,
						snapshot: snapshot?.pointee
					)
				}
			},
			document_capture_fixture_completed: { context, request, success in
				MainActor.assumeIsolated {
					guard let context else { return }
					Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue().complete(request, success)
				}
			},
			gesture_fixture_completed: { context, request, success in
				MainActor.assumeIsolated {
					guard let context else { return }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.complete(request, success)
				}
			},
			unhandled_escape: { context, page, generation in
				MainActor.assumeIsolated {
					guard let context else { return false }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					return runtime.receiveUnhandledEscape(page: page, generation: generation)
				}
			},
			new_contents_requested: { context, source, generation, child, target, targetSize, disposition in
				MainActor.assumeIsolated {
					guard
						let context,
						let target,
						(1...32_768).contains(targetSize),
						let copiedTarget = String(
							bytes: UnsafeRawBufferPointer(start: target, count: targetSize),
							encoding: .utf8
						),
						!copiedTarget.contains("\0")
					else { return false }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					return runtime.receiveNewContents(
						source: source,
						generation: generation,
						child: child,
						target: copiedTarget,
						disposition: Int(disposition.rawValue)
					)
				}
			},
			extension_install_prompt: { context, request, key, token, bytes, count in
				MainActor.assumeIsolated {
					guard let context, let key else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.extensionBridge.installs.prompt(
						request,
						profileKey: String(cString: key),
						token: token,
						bytes: bytes,
						count: count
					)
				}
			},
			extension_view_created: { context, request, key, extensionID, child, target, size, kind in
				MainActor.assumeIsolated {
					guard
						let context,
						let key,
						let extensionID,
						let target,
						(1...32_768).contains(size),
						let copied = String(
							bytes: UnsafeRawBufferPointer(start: target, count: size),
							encoding: .utf8
						),
						!copied.contains("\0")
					else { return false }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					return runtime.receiveExtensionOptions(
						request: request,
						profileKey: String(cString: key),
						extensionID: String(cString: extensionID),
						child: child,
						target: copied,
						kind: kind
					)
				}
			},
			extension_options_requested: { context, key, extensionID, child, target, size in
				MainActor.assumeIsolated {
					guard
						let context,
						let key,
						let extensionID,
						let target,
						(1...32_768).contains(size),
						let copied = String(
							bytes: UnsafeRawBufferPointer(start: target, count: size),
							encoding: .utf8
						),
						!copied.contains("\0")
					else { return false }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					return runtime.receiveRuntimeExtensionOptions(
						profileKey: String(cString: key),
						extensionID: String(cString: extensionID),
						child: child,
						target: copied
					)
				}
			},
			extension_options_revoked: { context, key, extensionID, child, generation in
				MainActor.assumeIsolated {
					guard
						let context,
						let key,
						let extensionID
					else { return }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.receiveRuntimeExtensionOptionsRevoked(
						profileKey: String(cString: key),
						extensionID: String(cString: extensionID),
						child: child,
						generation: generation
					)
				}
			},
			link_force_clicked: { context, page, generation, url, size in
				MainActor.assumeIsolated {
					guard
						let context,
						let url,
						(1...8_192).contains(size),
						let copied = String(
							bytes: UnsafeRawBufferPointer(start: url, count: size),
							encoding: .utf8
						),
						!copied.contains("\0")
					else { return false }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					return runtime.receiveLinkForceClick(page: page, generation: generation, target: copied)
				}
			},
			pdf_completed: { context, request, page, status, document, bytes, count in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.pdfs.complete(
						request,
						page: page,
						status: status,
						documentID: document,
						bytes: bytes,
						count: count
					)
				}
			},
			download_started: { context, request, status, guid, reason in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.completeDownloadStart(
						request,
						status: status,
						guid: guid.map { String(cString: $0) },
						interruptReason: reason
					)
				}
			},
			developer_completed: { context, request, page, status, json, count in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.developers.complete(
						request,
						page: page,
						status: status,
						json: json,
						count: count
					)
				}
			},
			password_save_offered: { context, page, token, origin, username, update in
				MainActor.assumeIsolated {
					guard let context, let origin else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.passwords.offered(.init(
						page: page,
						token: token,
						origin: String(cString: origin),
						username: username.map { String(cString: $0) } ?? "",
						isUpdate: update
					))
				}
			},
			sign_in_completed: { context, request, page, status, json, count in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.passwords.complete(
						request,
						page: page,
						status: status,
						json: json,
						count: count
					)
				}
			},
			saved_passwords_completed: { context, request, status, json, count in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.savedPasswords.complete(request, status: status, json: json, count: count)
				}
			},
			focused_link_completed: { context, request, page, generation, url, count in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.focusedLinks.complete(
						request,
						page: page,
						documentRevision: generation,
						url: url,
						count: count
					)
				}
			},
			site_settings_completed: { context, request, status, json, count in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.siteSettings.complete(request, status: status, json: json, count: count)
				}
			},
			site_settings_changed: { context, key in
				MainActor.assumeIsolated {
					guard let context, let key else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.siteSettings.changed(profileKey: String(cString: key))
				}
			},
			profile_data_completed: { context, request, status, json, count in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.profileData.complete(request, status: status, json: json, count: count)
				}
			},
			devtools_layout_changed: { context, id in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					guard let page = runtime.pages[id] else { return }
					runtime.onDeveloperToolsLayout?(page)
				}
			},
			cross_site_link_requested: { context, page, generation, url, size in
				MainActor.assumeIsolated {
					guard
						let context,
						let url,
						(1...8_192).contains(size),
						let copied = String(
							bytes: UnsafeRawBufferPointer(start: url, count: size),
							encoding: .utf8
						),
						!copied.contains("\0")
					else { return false }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					return runtime.receiveCrossSiteLink(page: page, generation: generation, target: copied)
				}
			},
			webstore_install_requested: { context, page, key, extensionID, token in
				MainActor.assumeIsolated {
					guard
						let context,
						let key,
						let extensionID,
						token > 0
					else { return false }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					return runtime.receiveWebstoreInstall(
						page: page,
						profileKey: String(cString: key),
						extensionID: String(cString: extensionID),
						token: token
					)
				}
			},
			page_menu_chosen: { context, id, generation, item in
				MainActor.assumeIsolated {
					guard
						let context,
						let item = ChromiumPageMenuItem(native: item)
					else { return }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					guard
						let page = runtime.pages[id],
						runtime.api.page_close_generation?(id) == generation
					else { return }
					runtime.onPageMenuChoice?(page, item)
				}
			},
			page_menu_items: { context, id in
				MainActor.assumeIsolated {
					guard let context else { return 0 }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					guard let page = runtime.pages[id], let items = runtime.onPageMenuItems?(page)
					else { return 0 }

					return items.reduce(0) { $0 | $1.mask }
				}
			},
			credential_import_completed: { context, request, status, json, count in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.credentialImport.complete(request, status: status, json: json, count: count)
				}
			},
			// ABI48 (DEV-814): context menus.
			context_menu_chosen: { context, id, generation, choice in
				MainActor.assumeIsolated {
					guard
						let context,
						let choice,
						let decoded = ChromiumContextMenuChoice(native: choice.pointee)
					else { return }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					guard
						let page = runtime.pages[id],
						runtime.api.page_close_generation?(id) == generation
					else { return }
					runtime.onContextMenuChoice?(page, decoded)
				}
			},
			context_menu_items: { context, id in
				MainActor.assumeIsolated {
					guard let context else { return 0 }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					guard let page = runtime.pages[id], let items = runtime.onContextMenuItems?(page)
					else { return 0 }

					return items.filter(\.isCarriedOutByApp).reduce(0) { $0 | $1.mask }
				}
			},
			page_close_requested: { context, id, generation in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.receivePageCloseRequest(page: id, generation: generation)
				}
			},
			external_link_requested: { context, page, generation, token, key, url, size, origin, originSize, flags in
				MainActor.assumeIsolated {
					guard
						let context,
						let url,
						(1...ChromiumExternalLink.maximumSize).contains(size),
						let link = String(
							bytes: UnsafeRawBufferPointer(start: url, count: size),
							encoding: .utf8
						),
						!link.contains("\0")
					else { return false }

					let source: String? = if let origin, (1...2_048).contains(originSize) {
						String(bytes: UnsafeRawBufferPointer(start: origin, count: originSize), encoding: .utf8)
					} else {
						nil
					}
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					return runtime.receiveExternalLink(
						page: page,
						generation: generation,
						link: .init(
							link: link,
							profileKey: key.map { String(cString: $0) },
							sourceOrigin: source,
							flags: flags,
							documentRevision: generation,
							token: token
						)
					)
				}
			},
			site_icon_redirects: { context, page, urls, count, truncated in
				MainActor.assumeIsolated {
					guard let context, count <= 16, urls != nil || count == 0 else { return }
					let addresses = (0..<count).compactMap { urls?[$0].map { String(cString: $0) } }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.receiveSiteIconRedirects(page: page, urls: addresses, truncated: truncated)
				}
			},
			autofill_suggestions_changed: { context, page, session, json, count in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.autofill.changed(page: page, session: session, json: json, count: count)
				}
			},
			autofill_data_completed: { context, request, status, json, count in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.autofillData.complete(request, status: status, json: json, count: count)
				}
			},
			// ABI54 (DEV-949).
			page_fullscreen_changed: { context, page, _, isFullScreen in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.receivePageFullScreen(page: page, isFullScreen: isFullScreen)
				}
			},
			page_activation_requested: { context, page, generation in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.receivePageActivationRequest(page: page, generation: generation)
				}
			},
			notification_window_requested: { context, key, child, target, size in
				MainActor.assumeIsolated {
					guard
						let context,
						let key,
						let target,
						(1...32_768).contains(size),
						let copied = String(
							bytes: UnsafeRawBufferPointer(start: target, count: size),
							encoding: .utf8
						),
						!copied.contains("\0")
					else { return false }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					return runtime.receiveNotificationWindow(
						profileKey: String(cString: key),
						child: child,
						target: copied
					)
				}
			},
			notification_clicked: { context, key, origin, size, flags in
				MainActor.assumeIsolated {
					guard
						let context,
						let key,
						let origin,
						(1...2_048).contains(size),
						let copied = String(
							bytes: UnsafeRawBufferPointer(start: origin, count: size),
							encoding: .utf8
						),
						let click = ChromiumNotificationClick(
							profileKey: String(cString: key),
							origin: copied,
							flags: flags
						)
					else { return }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.receiveNotificationClick(click)
				}
			},
			// ABI56 (DEV-963).
			page_permission_prompt_changed: { context, page, token in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.receivePagePermissionPrompt(page: page, token: token)
				}
			},
			// ABI60 (DEV-1111).
			page_link_hovered: { context, page, generation, link, size, flags in
				MainActor.assumeIsolated {
					guard let context else { return }

					let address: String? = if let link, (1...8192).contains(size) {
						String(
							decoding: UnsafeRawBufferPointer(start: link, count: size),
							as: UTF8.self
						)
					} else {
						nil
					}
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					runtime.receiveLinkHover(page: page, generation: generation, address: address, flags: flags)
				}
			},
			page_command_key: { context, page, generation, keyCode, flags, timestamp, consumed in
				MainActor.assumeIsolated {
					guard let context else { return false }

					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					return runtime.receiveCommandKey(
						page: page,
						generation: generation,
						key: .init(keyCode: keyCode, modifierFlags: flags, timestamp: timestamp),
						consumed: consumed
					)
				}
			}
		)
		if let profileRetirement {
			guard let run = api.run_with_profile_retirement
			else { throw ChromiumError.incompatibleBridge }
			var options = ArxEngineRunOptions(
				use_mock_keychain_for_testing: mockKeychainForTesting,
				enable_extensions: enableExtensions,
				extension_fixture_for_testing: false,
				document_capture_fixture_for_testing: false,
				gesture_fixture_for_testing: false,
				extension_install_fixture_for_testing: false,
				webstore_fixture_origin_for_testing: nil
			)
			return run(
				executable.path,
				profileDirectory.path,
				&callbacks,
				&options,
				profileRetirement.installationID.uuidString.lowercased(),
				profileRetirement.legacyProfileID.uuidString.lowercased()
			)
		}

		let requiresRunOptions = mockKeychainForTesting
		|| enableExtensions
		|| extensionFixtureForTesting
		|| documentCaptureFixtureForTesting
		|| gestureFixtureForTesting
		|| extensionInstallFixtureForTesting

		if requiresRunOptions {
			guard let run = api.run_with_options
			else { throw ChromiumError.incompatibleBridge }

			// Native copies the fixture origin before ChromeMain starts.
			let origin = webstoreFixtureOrigin.map { strdup($0) } ?? nil
			defer { free(origin) }
			var options = ArxEngineRunOptions(
				use_mock_keychain_for_testing: mockKeychainForTesting,
				enable_extensions: enableExtensions,
				extension_fixture_for_testing: extensionFixtureForTesting,
				document_capture_fixture_for_testing: documentCaptureFixtureForTesting,
				gesture_fixture_for_testing: gestureFixtureForTesting,
				extension_install_fixture_for_testing: extensionInstallFixtureForTesting,
				webstore_fixture_origin_for_testing: UnsafePointer(origin)
			)
			return run(executable.path, profileDirectory.path, &callbacks, &options)
		}

		return api.run(executable.path, profileDirectory.path, &callbacks)
	}

	internal func didBecomeReady() {
		state = .running

		// Settings asked for before the engine ran.
		if linkHoverReports { api.set_link_hover_reports?(true) }
		onReady?(self)
	}

	/// The runtime retains each page until close() or shutdown.
	public func makePage() throws -> ChromiumPage {
		try makePreparedPage(key: "")
	}

	private func makePreparedPage(key: String) throws -> ChromiumPage {
		guard state == .running else { throw ChromiumError.notRunning }
		return try makePage(id: api.create_page("about:blank", key), key: key)
	}

	private func makePage(
		id: UInt64,
		key: String
	) throws -> ChromiumPage {
		guard id != 0 else { throw ChromiumError.pageCreationFailed }
		guard let pointer = api.page_view(id) else {
			api.destroy_page(id)
			throw ChromiumError.pageCreationFailed
		}
		let view = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
		let page = ChromiumPage(
			id: id,
			view: view,
			runtime: self,
			isPrivate: privateProfileKeys.contains(key)
		)
		pages[id] = page
		if !page.isPrivate {
			pageSiteIconScopes[id] = siteIcons.currentScope(profileID: UUID(uuidString: key))
			pageProfileKeys[id] = key
		}
		return page
	}

	/// DEV-907: starts handing pages' Badging API reports to `onPageBadge`. The runtime lives as
	/// long as the process, so the handler never outlives it.
	public func observePageBadges() {
		guard let pageBadgeFunction else { return }

		pageBadgeFunction({ context, page, kind, count in
			guard let context else { return }

			MainActor.assumeIsolated {
				let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
				runtime.pageBadgeChanged(page, kind: kind, count: count)
			}
		}, Unmanaged.passUnretained(self).toOpaque())
	}

	internal func pageBadgeChanged(
		_ id: UInt64,
		kind: Int32,
		count: UInt64
	) {
		guard let page = pages[id] else { return }

		let badge: UInt64?? = switch kind {
		case 1: .some(nil)
		case 2: .some(count)
		default: nil
		}
		onPageBadge?(page, badge)
	}

	/// Whether this engine keeps a tab's back/forward history across pages (DEV-878).
	public var supportsNavigationState: Bool { navigationStateFunctions != nil }

	/// DEV-878: an ordinary page's back/forward entries around the current one, to save or to give
	/// another page. Nil for a private or empty page, or an engine without them.
	public func navigationState(_ page: ChromiumPage) -> Data? {
		guard
			state == .running,
			let functions = navigationStateFunctions,
			pages[page.id] === page,
			!page.isPrivate
		else { return nil }

		var bytes: UnsafePointer<UInt8>?
		let count = functions.copy(page.id, &bytes)
		guard count > 0, let bytes else { return nil }

		return Data(bytes: bytes, count: count)
	}

	/// DEV-878: a new ordinary page that takes saved back/forward entries before its first load.
	/// Nothing loads until ``loadRestoredPage(_:)``. Nil when the engine can't, the entries are
	/// unreadable, or their current page isn't `url`; the caller then opens `url` afresh.
	public func makePage(
		profile: UUID?,
		restoring navigationState: Data,
		at url: URL
	) async throws -> ChromiumPage? {
		guard let functions = navigationStateFunctions else { return nil }

		try await prepareProfile(profile)
		try Task.checkCancellation()
		let key = profile?.uuidString.lowercased() ?? ""
		guard
			state == .running,
			!privateProfileKeys.contains(key)
		else { return nil }

		let id = navigationState.withUnsafeBytes { buffer in
			functions.createRestoredPage(
				key,
				url.absoluteString,
				buffer.bindMemory(to: UInt8.self).baseAddress,
				buffer.count
			)
		}
		guard id != 0 else { return nil }

		return try makePage(id: id, key: key)
	}

	/// DEV-878: loads the current entry of a page made by ``makePage(profile:restoring:at:)``.
	public func loadRestoredPage(_ page: ChromiumPage) throws {
		guard
			state == .running,
			let functions = navigationStateFunctions,
			pages[page.id] === page
		else { throw ChromiumError.notRunning }

		guard functions.loadRestoredPage(page.id)
		else { throw ChromiumError.pageCreationFailed }
	}

	/// Nil maps only to the original Default directory. Other identities use dedicated profiles.
	public func makePage(profile: UUID?) async throws -> ChromiumPage {
		try await prepareProfile(profile)
		try Task.checkCancellation()
		return try makePreparedPage(key: profile?.uuidString.lowercased() ?? "")
	}

	/// Prepare isolated storage without creating or navigating a page. Every call counts as a
	/// use of the profile, which keeps an idle release away for its grace period (DEV-880).
	public func prepareProfile(_ profile: UUID?) async throws {
		guard state == .running else { throw ChromiumError.notRunning }
		let key = profile?.uuidString.lowercased() ?? ""
		if !preparedProfiles.contains(key) {
			guard !privateProfileKeys.contains(key) else { throw ChromiumError.pageCreationFailed }
			let success = await request { api.prepare_profile(key, $0) }
			guard success, state == .running else { throw ChromiumError.pageCreationFailed }
			let isNew = preparedProfiles.insert(key).inserted
			if isNew, !privateProfileKeys.contains(key) { onOrdinaryProfilePrepared?(profile) }
		}
		if !privateProfileKeys.contains(key) { profileUses[key] = .now }
		try Task.checkCancellation()
	}

	/// DEV-880. Whether this engine can release an idle ordinary profile before quit.
	public var supportsProfileRelease: Bool {
		state == .running && releaseProfileFunction != nil
	}

	/// DEV-880. Whether the ordinary profile, nil being Default, is prepared now.
	public func isPreparedOrdinaryProfile(_ profile: UUID?) -> Bool {
		let key = profile?.uuidString.lowercased() ?? ""
		return state == .running && preparedProfiles.contains(key) && !privateProfileKeys.contains(key)
	}

	/// DEV-880. The ordinary profiles the engine has prepared, nil being Default, with when
	/// something last used each and what holds it now.
	public var preparedOrdinaryProfiles: [UUID?: ChromiumProfileUse] {
		guard state == .running else { return [:] }

		var result: [UUID?: ChromiumProfileUse] = [:]
		for key in preparedProfiles where !privateProfileKeys.contains(key) {
			let id: UUID? = key.isEmpty ? nil : UUID(uuidString: key)
			guard key.isEmpty || id != nil else { continue }

			result[id] = .init(
				lastUse: profileUses[key] ?? .now,
				isHeld: profileHolds[key, default: 0] > 0,
				// Until Chromium has listed the profile's downloads, startup reconciliation is
				// still running: an observer detached now would leave restored transfers unseen.
				hasDownloads: !initializedDownloads.contains(key)
					|| downloads[key, default: [:]].values.contains { $0.state == .inProgress }
			)
		}
		return result
	}

	/// DEV-880. Releases an ordinary profile nothing uses, so Chromium unloads it; the next
	/// `prepareProfile` loads it again. False, changing nothing, while engine work holds it,
	/// for a profile that isn't prepared, and when native refuses: a page, a download,
	/// extension work or a consent prompt still uses it, or it's the parent of private ones.
	@discardableResult
	public func releaseProfile(_ profile: UUID?) -> Bool {
		let key = profile?.uuidString.lowercased() ?? ""
		guard
			state == .running,
			let release = releaseProfileFunction,
			preparedProfiles.contains(key),
			!privateProfileKeys.contains(key),
			profileHolds[key, default: 0] == 0,
			key.withCString({ release($0) })
		else { return false }

		preparedProfiles.remove(key)
		profileUses[key] = nil

		// The next load observes its downloads afresh and lists them again.
		initializedDownloads.remove(key)
		return true
	}

	/// DEV-880. Whether Chromium itself still has a live profile for the ordinary profile, nil
	/// being Default: prepared, or released and not destroyed yet. Nil when the engine can't say.
	public func isLoadedInChromium(_ profile: UUID?) -> Bool? {
		guard state == .running, let loaded = profileIsLoadedFunction else { return nil }

		return (profile?.uuidString.lowercased() ?? "").withCString { loaded($0) }
	}

	/// DEV-880. Runs engine work on the ordinary profile `key` with it held, so an idle release
	/// can't let it go before the engine answers. Finishing counts as a use.
	private func holding<Value, Failure: Error>(
		_ key: String,
		_ operation: () async throws(Failure) -> Value
	) async throws(Failure) -> Value {
		profileHolds[key, default: 0] += 1
		defer { releaseProfileHold(key) }
		return try await operation()
	}

	private func releaseProfileHold(_ key: String) {
		profileHolds[key, default: 1] -= 1
		if profileHolds[key] == 0 { profileHolds[key] = nil }
		if preparedProfiles.contains(key) { profileUses[key] = .now }
	}

	public var supportsProfileRetirement: Bool {
		state == .running && profileRetirement.isAvailable
	}

	public func profileRetirementSnapshot() async throws -> ChromiumProfileRetirementSnapshot {
		guard state == .running
		else { throw ChromiumProfileRetirementFailure.unavailable }
		return try await profileRetirement.snapshot()
	}

	/// Nil addresses only the permanently configured Default owner.
	public func retireProfile(
		_ profileID: UUID?,
		requestID: UUID,
		expectedRevision: UInt64,
		authorize: @escaping @MainActor @Sendable () -> Bool
	) async throws -> ChromiumProfileRetirementSnapshot {
		guard supportsProfileRetirement
		else { throw ChromiumProfileRetirementFailure.unavailable }
		return try await profileRetirement.retire(
			profileID: profileID,
			requestID: requestID,
			expectedRevision: expectedRevision,
			authorize: authorize
		)
	}

	public func preparePrivateProfile(_ id: UUID) throws {
		guard state == .running else { throw ChromiumError.notRunning }
		let key = id.uuidString.lowercased()
		guard api.prepare_private_profile(key) else { throw ChromiumError.pageCreationFailed }
		privateProfileKeys.insert(key)
		preparedProfiles.insert(key)
	}

	/// ABI45 (DEV-729). As `preparePrivateProfile(_:)`, and the private context's downloads
	/// folder and "Ask where to save" follow `opener`'s, the ordinary profile that opened the
	/// window (nil is Default), while both live. An opener that isn't prepared follows nothing.
	/// DEV-889: the context is the opener's own off-the-record child, so the opener's extensions
	/// allowed in private windows run there, and the opener stays loaded while it lives.
	public func preparePrivateProfile(
		_ id: UUID,
		followingDownloadsOf opener: UUID?
	) throws {
		guard state == .running else { throw ChromiumError.notRunning }
		let key = id.uuidString.lowercased()
		let openerKey = opener?.uuidString.lowercased() ?? ""
		let prepared = if let prepare = api.prepare_private_profile_for {
			!privateProfileKeys.contains(openerKey) && prepare(key, openerKey)
		} else {
			api.prepare_private_profile(key)
		}
		guard prepared else { throw ChromiumError.pageCreationFailed }

		privateProfileKeys.insert(key)
		preparedProfiles.insert(key)
	}

	/// Only current ordinary application profiles may query their own favicon database.
	public func configureSiteIconProfiles(_ profiles: Set<UUID?>) {
		siteIcons.configure(profiles: profiles.filter {
			!privateProfileKeys.contains($0?.uuidString.lowercased() ?? "")
		})
	}

	/// Whether a site icon lookup that misses the profile's favicon database fetches the
	/// site's icon (Settings: fetch icons for tabs that haven't loaded). Safe before start.
	public func setSiteIconFetch(enabled: Bool) {
		siteIcons.setFetch(enabled)
	}

	/// `mayFetch` false reads the favicon database only (ABI51): a miss never fetches.
	public func siteIcon(
		pageURL: URL,
		profileID: UUID?,
		mayFetch: Bool = true
	) async throws -> ChromiumSiteIcon? {
		guard state == .running
		else { throw ChromiumSiteIconFailure.unavailable }
		guard !privateProfileKeys.contains(profileID?.uuidString.lowercased() ?? "")
		else { throw ChromiumSiteIconFailure.unavailable }

		let scope = try siteIcons.scope(profileID: profileID)
		try await prepareProfile(profileID)
		return try await siteIcons.lookup(pageURL: pageURL, scope: scope, mayFetch: mayFetch)
	}

	public func siteIconChanges() -> AsyncStream<ChromiumSiteIconChange> {
		guard state == .running else { return .init { $0.finish() } }
		let id = UUID()
		return .init(bufferingPolicy: .bufferingNewest(256)) { continuation in
			siteIconObservers[id] = continuation
			continuation.onTermination = { [weak self] _ in
				Task { @MainActor in self?.siteIconObservers.removeValue(forKey: id) }
			}
		}
	}

	/// A queued notification remains useful after page closure, but never after profile replacement.
	public func isCurrentSiteIconChange(_ change: ChromiumSiteIconChange) -> Bool {
		state == .running && siteIcons.isCurrent(change.scope)
	}

	internal func receiveSiteIconChange(
		page: UInt64,
		url: String,
		iconURL: String? = nil
	) {
		guard
			let pageURL = URL(string: url),
			Self.isSiteIconURL(pageURL)
		else { return }
		recordSiteIconURL(pageURL, page: page, restarting: false)
		if pageSiteIconScopes[page] != nil { pageSiteIconReported.insert(page) }
		emitSiteIconChange(page: page, iconURL: iconURL.flatMap(ChromiumSiteIcon.iconURL))
	}

	/// ABI51 (DEV-940). A server redirect's middle addresses may never reach a page
	/// snapshot, yet Chromium's favicon database maps the page's icon to them too.
	/// Addresses new to the page's trail refresh, since its load may already have ended.
	internal func receiveSiteIconRedirects(
		page: UInt64,
		urls: [String],
		truncated: Bool = false
	) {
		let known = pageSiteIconURLs[page] ?? []
		for url in urls.compactMap(URL.init(string:)) where Self.isSiteIconURL(url) {
			recordSiteIconURL(url, page: page, restarting: false)
		}
		if truncated, pageSiteIconScopes[page] != nil {
			// Native left out some of the chain (older than the last eight, or too
			// long): they are unknown, so this load's changes, now and after its
			// favicon is stored, read every icon in the profile.
			pageSiteIconTruncated.insert(page)
			return emitSiteIconChange(page: page)
		}
		guard pageSiteIconURLs[page].map({ !Set($0).isSubset(of: known) }) == true
		else { return }
		emitSiteIconChange(page: page)
	}

	internal func receiveSiteIconNavigation(
		page: ChromiumPage,
		previous: ChromiumPage.Navigation,
		current: ChromiumPage.Navigation
	) {
		guard pages[page.id] === page else { return }
		let restarting = current.isLoading && !previous.isLoading
		if restarting {
			// The outgoing document may have written its icon just before it was
			// replaced, and its weak native notification dies with it. Name its
			// addresses now, before the new load starts a new trail.
			emitSiteIconChange(page: page.id)
		}
		recordSiteIconURL(current.url, page: page.id, restarting: restarting)
		let terminalTransition = !current.isLoading && (
			previous.isLoading
			|| previous.url != current.url
			|| previous.errorCode != current.errorCode
		)
		guard terminalTransition else { return }

		// Closing or replacing a document can cancel Chromium's weak posted icon
		// notification after its database write. Terminal lifecycle events recover
		// that refresh without querying for progress, title or history-only updates.
		// They name only this page's addresses, never every icon in the profile (DEV-940).
		emitSiteIconChange(page: page.id)
	}

	/// Remembers an address the page showed. A new load starts a new trail; a long run of
	/// same-document changes keeps only the latest few.
	private func recordSiteIconURL(
		_ url: URL?,
		page: UInt64,
		restarting: Bool
	) {
		guard pageSiteIconScopes[page] != nil else { return }
		if restarting {
			pageSiteIconTruncated.remove(page)
			pageSiteIconReported.remove(page)
		}
		var urls = restarting ? [] : pageSiteIconURLs[page, default: []]
		if let url, Self.isSiteIconURL(url), !urls.contains(url) {
			urls.append(url)
			if urls.count > Self.maximumSiteIconURLs {
				urls.removeFirst()

				// Before Chromium reports an icon, the dropped address may still get it:
				// this load's changes read the whole profile instead.
				if !pageSiteIconReported.contains(page) { pageSiteIconTruncated.insert(page) }
			}
		}
		pageSiteIconURLs[page] = urls
	}

	private func emitSiteIconChange(
		page: UInt64,
		iconURL: URL? = nil
	) {
		guard
			state == .running,
			let owner = pages[page],
			!owner.isPrivate,
			let scope = pageSiteIconScopes[page],
			siteIcons.isCurrent(scope),
			let pageURLs = pageSiteIconURLs[page],
			!pageURLs.isEmpty
		else { return }

		if pageSiteIconTruncated.contains(page) {
			emitSiteIconChange(.init(pageID: nil, pageURLs: [], iconURL: nil, scope: scope))

		} else {
			emitSiteIconChange(.init(
				pageID: page,
				pageURLs: pageURLs,
				iconURL: iconURL,
				scope: scope
			))
		}
	}

	/// Every icon in the profile may have changed, as after its history is cleared.
	private func emitProfileSiteIconChange(profile: UUID?) {
		guard
			state == .running,
			!privateProfileKeys.contains(profile?.uuidString.lowercased() ?? ""),
			let scope = siteIcons.currentScope(profileID: profile)
		else { return }

		emitSiteIconChange(.init(pageID: nil, pageURLs: [], iconURL: nil, scope: scope))
	}

	private func emitSiteIconChange(_ change: ChromiumSiteIconChange) {
		for observer in siteIconObservers.values {
			observer.yieldKeepingRefreshes(change)
		}
	}

	private static let maximumSiteIconURLs: Int = 8

	private static func isSiteIconURL(_ url: URL) -> Bool {
		["http", "https"].contains(url.scheme?.lowercased() ?? "")
		&& url.absoluteString.utf8.count <= 8192
	}

	/// Reads the current loaded ordinary HTTP(S) document without navigation or focus.
	/// Scope must be a trusted identifier unique to one client's current content grant.
	/// `frameID` names a child frame from a snapshot node's `frame`; nil reads the main frame.
	public func inspect(
		_ page: ChromiumPage,
		scope: UUID,
		frameID: String? = nil,
		limits: ChromiumInspectionLimits = .init()
	) async throws -> ChromiumInspectionSnapshot {
		try validateInspectionPage(page)
		inspections.register(page: page.id)
		let snapshot = try await inspections.inspect(
			page: page.id,
			scope: scope,
			frameID: frameID,
			limits: limits
		)

		try validateInspectionPage(page)
		guard inspectionDocumentIsCurrent(snapshot, on: page, scope: scope)
		else { throw ChromiumInspectionFailure.staleReference }

		return snapshot
	}

	/// Validates the retained node and exact DOM version in one renderer task.
	/// This read-only result never authorizes a separately scheduled page action.
	public func validateInspectionReference(
		_ reference: String,
		in snapshot: ChromiumInspectionSnapshot,
		on page: ChromiumPage,
		scope: UUID
	) async throws {
		try validateInspectionPage(page)
		try await inspections.validate(
			reference,
			in: snapshot,
			page: page.id,
			scope: scope
		)

		try validateInspectionPage(page)
		guard inspectionDocumentIsCurrent(snapshot, on: page, scope: scope)
		else { throw ChromiumInspectionFailure.staleReference }
	}

	/// Checks native document/page/scope liveness synchronously, not the renderer's
	/// current DOM version. A semantic snapshot remains historical at its version.
	public func inspectionDocumentIsCurrent(
		_ snapshot: ChromiumInspectionSnapshot,
		on page: ChromiumPage,
		scope: UUID
	) -> Bool {
		guard
			state == .running,
			pages[page.id] === page,
			!page.isPrivate,
			!page.isClosed
		else { return false }

		return inspections.documentIsCurrent(snapshot, page: page.id, scope: scope)
	}

	public func revokeInspectionScope(_ scope: UUID) {
		referenceClicks.revoke(scope: scope)
		inspections.revoke(scope: scope)
	}

	/// Sends one atomic renderer validation/activation operation. Cancellation
	/// returns a receipt; it never throws away possible website effects. The
	/// authorization callback runs synchronously immediately before C submission.
	public func clickInspectionReference(
		_ request: ChromiumReferenceClickRequest,
		on page: ChromiumPage,
		scope: UUID,
		authorize: @escaping @MainActor @Sendable () -> Bool
	) async -> ChromiumReferenceClickResult {
		releaseReplacedReferenceSubmissions()
		return await referenceClicks.click(
			request,
			page: page.id,
			scope: scope,
			documentRevision: { [weak self, weak page] in
				guard let self, let page
				else { return 0 }
				return self.closeGeneration(for: page)
			},
			validateSource: { [weak self, weak page] in
				guard let self, let page
				else { return .unavailable }
				guard self.state == .running, self.supportsReferenceClick
				else { return .unavailable }
				guard !page.isPrivate
				else { return .unsupportedDocument }
				guard self.inspectionDocumentIsCurrent(request.snapshot, on: page, scope: scope)
				else { return .staleReference }
				return nil
			},
			authorize: authorize
		)
	}

	/// Immutable function-table capability, separate from live readiness/grants.
	public var supportsReferenceClick: Bool {
		supportsInspection
		&& api.click_inspection_reference != nil
		&& api.cancel_reference_click != nil
	}

	/// Direct native replacement/selection on one inspected control. The same
	/// receipt registry and physical lane also own reference clicks.
	public func performInspectionFormAction(
		_ request: ChromiumReferenceFormRequest,
		on page: ChromiumPage,
		scope: UUID,
		authorize: @escaping @MainActor @Sendable () -> Bool
	) async -> ChromiumReferenceFormResult {
		releaseReplacedReferenceSubmissions()
		return await referenceClicks.formAction(
			request,
			page: page.id,
			scope: scope,
			documentRevision: { [weak self, weak page] in
				guard let self, let page
				else { return 0 }
				return self.closeGeneration(for: page)
			},
			validateSource: { [weak self, weak page] in
				guard let self, let page
				else { return .unavailable }
				guard self.state == .running, self.supportsReferenceFormActions
				else { return .unavailable }
				if case .keyPress = request.action, !self.supportsReferenceKeypress { return .unavailable }
				guard !page.isPrivate
				else { return .unsupportedDocument }
				guard self.inspectionDocumentIsCurrent(request.snapshot, on: page, scope: scope)
				else { return .staleReference }
				return nil
			},
			authorize: authorize
		)
	}

	public var supportsReferenceKeypress: Bool {
		supportsReferenceFormActions && api.reference_keypress_available?() == true
	}

	/// ABI27 pointer input shares the form entry point; the ABI version is exact.
	public var supportsReferencePointer: Bool {
		supportsReferenceFormActions
	}

	public var supportsReferenceFormActions: Bool {
		supportsInspection
		&& api.perform_inspection_form_action != nil
		&& api.cancel_reference_form_action != nil
	}

	/// Issues one instant request on the nearest scroll container of an explicit
	/// reference. No focused target, wheel input, or website completion is implied.
	public func scrollInspectionReference(
		_ request: ChromiumReferenceScrollRequest,
		on page: ChromiumPage,
		scope: UUID,
		authorize: @escaping @MainActor @Sendable () -> Bool
	) async -> ChromiumReferenceScrollResult {
		releaseReplacedReferenceSubmissions()
		return await referenceClicks.scroll(
			request,
			page: page.id,
			scope: scope,
			documentRevision: { [weak self, weak page] in
				guard let self, let page
				else { return 0 }
				return self.closeGeneration(for: page)
			},
			validateSource: { [weak self, weak page] in
				guard let self, let page
				else { return .unavailable }
				guard self.state == .running, self.supportsReferenceScroll
				else { return .unavailable }
				guard !page.isPrivate
				else { return .unsupportedDocument }
				guard self.inspectionDocumentIsCurrent(request.snapshot, on: page, scope: scope)
				else { return .staleReference }
				return nil
			},
			authorize: authorize
		)
	}

	public var supportsReferenceScroll: Bool {
		supportsInspection
		&& api.scroll_inspection_reference != nil
		&& api.cancel_reference_click != nil
	}

	private func validateInspectionPage(_ page: ChromiumPage) throws {
		guard state == .running, supportsInspection, !page.isPrivate
		else { throw ChromiumInspectionFailure.unavailable }
		guard pages[page.id] === page, !page.isClosed
		else { throw ChromiumInspectionFailure.staleReference }
	}

	/// Immutable table capability; operation readiness and ownership are checked separately.
	public var supportsInspection: Bool {
		api.inspect_page != nil
		&& api.validate_inspection_reference != nil
		&& api.cancel_inspection != nil
		&& api.revoke_inspection_scope != nil
		&& api.inspection_document_is_current != nil
	}

	/// Capability remains opt-in until the packaged native acceptance gate passes.
	public var supportsExtensions: Bool { state == .running && extensionBridge.isEnabled }

	public func extensions(profileID: UUID?) async throws -> ChromiumExtensionInventory {
		try await prepareExtensionProfile(profileID)
		return try await extensionBridge.inspect(profileID: profileID)
	}

	public func manageExtension(
		_ action: ChromiumExtensionAction,
		extensionID: String,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInventory {
		guard supportsExtensions
		else { throw ChromiumExtensionFailure.unavailable }
		guard extensionBridge.owns(inventory)
		else { throw ChromiumExtensionFailure.staleInventory }

		return try await extensionBridge.manage(action, extensionID: extensionID, in: inventory)
	}

	/// ABI20 developer folder loading, independent of signed-package installation.
	public var supportsUnpackedExtensions: Bool { supportsExtensions && extensionBridge.isUnpackedAvailable }

	/// Loads a developer-selected folder into the inventory's exact ordinary
	/// profile. Reload uses `manageExtension(.reload, …)` for an installed folder.
	public func loadUnpackedExtension(
		directory: URL,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInventory {
		guard supportsUnpackedExtensions, extensionBridge.owns(inventory)
		else { throw ChromiumExtensionFailure.unavailable }

		try await prepareExtensionProfile(inventory.profileID)
		return try await extensionBridge.loadUnpacked(directory: directory, in: inventory)
	}

	public var supportsExtensionInstallation: Bool {
		supportsExtensions && extensionBridge.installs.isAvailable
	}

	public func prepareExtensionInstallation(
		data: Data,
		sourceBasename: String,
		expectedExtensionID: String? = nil,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt {
		guard supportsExtensionInstallation, extensionBridge.owns(inventory)
		else { throw ChromiumExtensionFailure.unavailable }
		try await prepareExtensionProfile(inventory.profileID)
		return try await extensionBridge.installs.prepare(
			data: data,
			basename: sourceBasename,
			expectedID: expectedExtensionID,
			inventory: inventory
		)
	}

	public func resolveExtensionInstallation(
		_ prompt: ChromiumExtensionInstallPrompt,
		accept: Bool
	) async throws -> ChromiumExtensionInventory {
		guard
			supportsExtensions,
			!privateProfileKeys.contains(prompt.profileID?.uuidString.lowercased() ?? "")
		else { throw ChromiumExtensionFailure.unavailable }
		return try await extensionBridge.installs.resolve(prompt, accept: accept)
	}

	public func cancelExtensionInstallation(_ prompt: ChromiumExtensionInstallPrompt) {
		extensionBridge.installs.cancel(prompt)
	}

	/// ABI44 Chrome Web Store installs.
	public var supportsWebstoreInstallation: Bool {
		supportsExtensionInstallation && extensionBridge.installs.isWebstoreAvailable
	}

	/// Downloads the store's package for `request` and verifies it: the store's
	/// publisher signature, the requested ID, a new install. The prompt carries
	/// the package's SHA-256 and permissions; resolve it like any other.
	public func prepareWebstoreInstallation(
		_ request: ChromiumWebstoreInstallRequest,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt {
		guard
			supportsWebstoreInstallation,
			extensionBridge.owns(inventory),
			request.runtimeID == extensionBridge.runtimeID,
			request.profileID == inventory.profileID
		else { throw ChromiumExtensionFailure.unavailable }
		try await prepareExtensionProfile(inventory.profileID)
		return try await extensionBridge.installs.prepareWebstore(request, inventory: inventory)
	}

	/// ABI45 Chrome Web Store updates (DEV-776).
	public var supportsWebstoreUpdates: Bool {
		supportsExtensionInstallation && extensionBridge.installs.isWebstoreUpdateAvailable
	}

	/// Downloads the store's current package for an installed store extension and verifies
	/// it as an update: the store's publisher signature, the same ID, a newer version. The
	/// prompt says whether it asks for more permissions; resolve it like any other. Throws
	/// `ChromiumExtensionFailure.upToDate` when the store has nothing newer.
	public func prepareWebstoreUpdate(
		of extensionID: String,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt {
		guard supportsWebstoreUpdates, extensionBridge.owns(inventory)
		else { throw ChromiumExtensionFailure.unavailable }
		try await prepareExtensionProfile(inventory.profileID)
		return try await extensionBridge.installs.prepareWebstoreUpdate(of: extensionID, inventory: inventory)
	}

	/// ABI47 store installs by ID (DEV-845), for extensions brought over from another browser.
	public var supportsWebstoreImports: Bool {
		supportsExtensionInstallation && extensionBridge.installs.isWebstoreImportAvailable
	}

	/// Downloads the store's package for an extension that isn't installed in the inventory's
	/// profile and verifies it as a new install: the store's publisher signature, the same ID,
	/// MV3. Resolve the prompt like any other; the user approves every install.
	public func prepareWebstoreImport(
		of extensionID: String,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt {
		guard supportsWebstoreImports, extensionBridge.owns(inventory)
		else { throw ChromiumExtensionFailure.unavailable }
		try await prepareExtensionProfile(inventory.profileID)
		return try await extensionBridge.installs.prepareWebstoreImport(of: extensionID, inventory: inventory)
	}

	/// Answers the store that the user cancelled.
	public func declineWebstoreInstallation(_ request: ChromiumWebstoreInstallRequest) {
		guard request.runtimeID == extensionBridge.runtimeID else { return }
		api.decline_webstore_install?(request.token)
	}

	/// Only compiled signed packages in native-owned developer fixture storage.
	public func prepareSignedExtensionFixtureForTesting(
		variant: UInt32,
		expectedExtensionID: String? = nil,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInstallPrompt {
		guard supportsExtensions, extensionBridge.isSignedFixture, extensionBridge.owns(inventory)
		else { throw ChromiumExtensionFailure.unavailable }
		try await prepareExtensionProfile(inventory.profileID)
		return try await extensionBridge.installs.prepareFixture(
			variant: variant,
			expectedID: expectedExtensionID,
			inventory: inventory
		)
	}

	public var supportsExtensionOptions: Bool {
		supportsExtensions && api.extension_views_available?() == true && api.open_extension_view != nil
	}

	public func openExtensionOptions(
		extensionID: String,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInventory {
		guard supportsExtensionOptions else { throw ChromiumExtensionFailure.unavailable }

		return try await extensionBridge.openOptions(extensionID: extensionID, in: inventory)
	}

	/// Only the native-owned, fresh temporary profile runner permits this exact fixture.
	public func loadExtensionFixtureForTesting(profileID: UUID?) async throws -> ChromiumExtensionInventory {
		guard extensionBridge.isFixture
		else { throw ChromiumExtensionFailure.unavailable }

		try await prepareExtensionProfile(profileID)
		return try await extensionBridge.loadFixture(profileID: profileID)
	}

	/// Exercises the real native disable-reason guard; this does not simulate a verified CRX update.
	public func requireExtensionFixturePermissionsForTesting(
		extensionID: String,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInventory {
		guard supportsExtensions
		else { throw ChromiumExtensionFailure.unavailable }

		return try await extensionBridge.requireFixturePermissions(
			extensionID: extensionID,
			in: inventory
		)
	}

	/// Allows the disposable fixture to verify Chromium's refusal independently
	/// of Swift's canEnable guard. Never available for ordinary profiles/runs.
	public func attemptExtensionFixtureEnableForTesting(
		extensionID: String,
		in inventory: ChromiumExtensionInventory
	) async throws -> ChromiumExtensionInventory {
		guard supportsExtensions
		else { throw ChromiumExtensionFailure.unavailable }

		return try await extensionBridge.attemptFixtureEnable(extensionID: extensionID, in: inventory)
	}

	private func prepareExtensionProfile(_ profileID: UUID?) async throws {
		guard
			supportsExtensions,
			!privateProfileKeys.contains(profileID?.uuidString.lowercased() ?? "")
		else { throw ChromiumExtensionFailure.unavailable }

		try await prepareProfile(profileID)
		try Task.checkCancellation()
		guard supportsExtensions
		else { throw ChromiumExtensionFailure.unavailable }
	}

	public func releasePrivateProfile(_ id: UUID) {
		guard state == .running else { return }
		let key = id.uuidString.lowercased()
		api.release_private_profile(key)
		preparedProfiles.remove(key)
	}

	/// Whether the page lets itself close, after its beforeunload handler. The page answers one
	/// question at a time, and Chromium refuses another while it does, so a second caller hears
	/// the first one's answer (DEV-1188): Open in WebKit and the page router following the site
	/// it had just listed both asked, and the refused one could keep the page in Chromium.
	public func permitsClosing(_ page: ChromiumPage) async -> Bool {
		guard pages[page.id] === page else { return true }
		if let asked = closingRequests.first(where: { $0.value == page.id })?.key {
			return await withCheckedContinuation { closingWaiters[asked, default: []].append($0) }
		}
		return await request { requestID in
			closingRequests[requestID] = page.id
			api.request_close(page.id, requestID)
		}
	}

	public var supportsAuthorizedClosing: Bool {
		api.page_close_generation != nil
		&& api.request_authorized_close != nil
		&& api.consume_authorized_close != nil
		&& api.cancel_authorized_close != nil
	}

	/// Missing capability and callbacks trailing shutdown/page disposal intentionally
	/// return zero: neither state supplies authority for a later close request.
	internal func closeGeneration(for page: ChromiumPage) -> UInt64 {
		guard
			state == .running,
			pages[page.id] === page,
			let generation = api.page_close_generation
		else { return 0 }

		return generation(page.id)
	}

	/// Conservative readiness for a trusted authentication handoff on this page's
	/// current document. Logical cancellation alone never proves physical
	/// drainage; only a normal reply, a replaced document, page closure or
	/// runtime teardown releases an uncertain submission.
	public func referenceSubmissionsAreSettled(on page: ChromiumPage) -> Bool {
		guard
			state == .running,
			pages[page.id] === page,
			let revision = documentRevision(for: page)
		else { return false }

		releaseReplacedReferenceSubmissions()
		return referenceClicks.submissionsAreSettled(page: page.id, documentRevision: revision)
	}

	/// The native epoch advances when a primary main-frame navigation starts, so an
	/// entry from an earlier epoch cannot target the page's current document.
	private func releaseReplacedReferenceSubmissions() {
		guard state == .running
		else { return }

		referenceClicks.releaseSubmissions { [self] page, revision in
			guard let owner = pages[page]
			else { return true }
			guard revision != 0
			else { return false }
			return closeGeneration(for: owner) != revision
		}
	}

	/// The native epoch changes before deferred navigation callbacks reach Swift.
	/// This is a navigation/lifetime stamp, not a DOM mutation revision.
	public func documentRevision(for page: ChromiumPage) -> UInt64? {
		let generation = closeGeneration(for: page)
		return generation == 0 ? nil : generation
	}

	/// Epoch attached synchronously to the last navigation publication. Compare this
	/// with documentRevision before interpreting cached loading state for a live page.
	public func publishedDocumentRevision(for page: ChromiumPage) -> UInt64? {
		guard
			state == .running,
			pages[page.id] === page,
			page.closeGeneration > 0
		else { return nil }
		return page.closeGeneration
	}

	/// Uses the native epoch cached with the last published navigation snapshot.
	/// Approval itself never destroys the page; callers must recheck their live authority.
	public func approveClose(_ page: ChromiumPage) async throws -> ChromiumCloseApproval? {
		guard state == .running, supportsAuthorizedClosing
		else { throw ChromiumCloseFailure.unavailable }
		guard pages[page.id] === page
		else { throw ChromiumCloseFailure.staleDocument }

		return try await closeRequests.request(page: page.id, generation: page.closeGeneration)
	}

	/// Synchronous native validation/destruction followed by Swift ownership removal.
	/// There is no actor suspension between these steps.
	public func consumeClose(
		_ approval: ChromiumCloseApproval,
		for page: ChromiumPage
	) throws {
		guard state == .running
		else { throw ChromiumCloseFailure.unavailable }
		guard pages[page.id] === page
		else { throw ChromiumCloseFailure.staleDocument }

		try closeRequests.consume(approval, page: page.id)
		close(page, destroyNative: false)
	}

	public func cancelClose(_ approval: ChromiumCloseApproval) {
		guard state == .running else { return }
		closeRequests.cancel(approval)
	}

	private func request(_ start: (UInt64) -> Void) async -> Bool {
		let id = nextRequest
		nextRequest += 1
		return await withCheckedContinuation { continuation in
			requests[id] = continuation
			start(id)
		}
	}

	internal func complete(
		_ id: UInt64,
		_ result: Bool
	) {
		closingRequests.removeValue(forKey: id)
		requests.removeValue(forKey: id)?.resume(returning: result)
		for waiter in closingWaiters.removeValue(forKey: id) ?? [] {
			waiter.resume(returning: result)
		}
	}

	/// Replays the latest known transfers before subsequent events. The stream is independent of pages.
	public func downloadEvents() -> AsyncStream<ChromiumDownloadEvent> {
		let token = UUID()
		let (stream, continuation) = AsyncStream<ChromiumDownloadEvent>.makeStream()
		for records in downloads.values {
			for record in records.values { continuation.yield(.changed(record)) }
		}
		for key in initializedDownloads { continuation.yield(.initialized(profileKey: key)) }

		if state == .stopped {
			continuation.finish()

		} else {
			downloadObservers[token] = continuation
			continuation.onTermination = { [weak self] _ in
				Task { @MainActor [weak self] in
					self?.downloadObservers[token] = nil
				}
			}
		}

		return stream
	}

	/// Reads native work synchronously, including transfers whose queued events have not arrived yet.
	public func activeDownloadCount() -> Int {
		guard state == .running else { return 0 }
		return Int(clamping: api.active_download_count())
	}

	/// Whether the engine reports whether a page used every key combination Arx can bind (DEV-1332),
	/// so a shortcut without ⌘ can reach a page first. False with an engine built before it.
	public var followsAllShortcutKeys: Bool {
		optionalExports.followsAllShortcutKeys?() ?? false
	}

	/// How many transfers in progress, paused ones included, a quit would lose (DEV-1130): private
	/// ones, and ordinary ones Chromium couldn't continue where they stopped. Read synchronously,
	/// like `activeDownloadCount()`. Nil with an engine built before it.
	public func lostOnQuitDownloadCount() -> Int? {
		guard let count = optionalExports.lostOnQuitDownloadCount else { return nil }
		guard state == .running else { return 0 }
		return Int(clamping: count())
	}

	public func cancelAllDownloads() throws {
		guard state == .running
		else { throw ChromiumError.notRunning }

		api.cancel_all_downloads()
	}

	public func cancelDownload(
		profileKey: String,
		guid: String
	) throws {
		guard state == .running
		else { throw ChromiumError.notRunning }
		guard api.cancel_download(profileKey, guid)
		else { throw ChromiumError.downloadNotActive }
	}

	/// DEV-892: whether this engine pauses, resumes and removes downloads.
	public var supportsDownloadControls: Bool { downloadControls != nil }

	/// DEV-892: what a transfer can do now, or nil with an engine built before pause and resume.
	public func downloadControl(
		profileKey: String,
		guid: String
	) -> ChromiumDownloadControl? {
		guard state == .running, let downloadControls else { return nil }
		return .init(rawValue: downloadControls.control(profileKey, guid))
	}

	/// DEV-892: pauses an in-progress transfer, or resumes a paused or resumable interrupted one.
	public func setDownloadPaused(
		profileKey: String,
		guid: String,
		paused: Bool
	) throws {
		guard state == .running, let downloadControls
		else { throw ChromiumError.notRunning }
		guard downloadControls.setPaused(profileKey, guid, paused)
		else { throw ChromiumError.downloadNotActive }
	}

	/// DEV-892: removes a finished transfer from Chromium's history. False with an older engine,
	/// for a transfer in progress, or for one the engine doesn't know.
	@discardableResult
	public func removeDownload(
		profileKey: String,
		guid: String
	) -> Bool {
		guard state == .running, let downloadControls else { return false }
		return downloadControls.remove(profileKey, guid)
	}

	/// ABI33. Whether the bridge can start downloads.
	public var supportsStartingDownloads: Bool {
		state == .running && api.start_download != nil
	}

	/// Downloads an http(s) URL in an ordinary profile through Chromium's download
	/// manager, with no page. Chromium's prompt, safe-browsing and dangerous-file
	/// checks apply. Returns the new item's GUID once it exists; its first
	/// `downloadEvents()` change arrives before this returns. Private profiles are refused.
	public func startDownload(
		profileKey: String,
		url: URL
	) async throws -> String {
		guard
			state == .running,
			let start = api.start_download,
			!privateProfileKeys.contains(profileKey)
		else { throw ChromiumDownloadStartFailure.unavailable }
		guard
			let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			["http", "https"].contains(components.scheme?.lowercased() ?? ""),
			components.host?.isEmpty == false,
			components.user == nil,
			components.password == nil
		else { throw ChromiumError.invalidURL }

		let request = nextRequest
		nextRequest += 1

		// Not cancellable: once Chromium has the request, the agent learns its item or failure.
		// Held until then; the item it starts holds the profile natively after (DEV-880).
		let result = await holding(profileKey) { () async -> Result<String, ChromiumDownloadStartFailure> in
			await withCheckedContinuation { continuation in
				downloadStarts[request] = continuation
				let accepted = profileKey.withCString { key in
					url.absoluteString.withCString { start(request, key, $0) }
				}
				if !accepted {
					downloadStarts.removeValue(forKey: request)?.resume(returning: .failure(.unavailable))
				}
			}
		}
		return try result.get()
	}

	/// ABI56 (DEV-851). Whether the engine downloads a link menu's link itself.
	public var supportsLinkContextDownloads: Bool {
		state == .running && api.download_link_context != nil
	}

	/// ABI56 (DEV-851). The link menu's Download Linked File, started at once, while `context`
	/// is current (the menu ends right after the choice): the engine downloads its link from the
	/// link's own frame with that frame's sanitized referrer, as Chrome's Save Link As, in the
	/// page's ordinary profile, so a site that checks the referring page answers as in Chrome.
	/// Returns the request `linkContextDownload` waits on, or nil when refused (a stale menu, a
	/// private page). Chromium's prompt, safe-browsing and dangerous-file checks apply.
	public func startLinkContextDownload(
		_ context: ChromiumLinkContext,
		on page: ChromiumPage
	) -> UInt64? {
		guard
			supportsLinkContextDownloads,
			!page.isPrivate,
			let key = pageProfileKeys[page.id],
			linkContextIsCurrent(context, on: page)
		else { return nil }

		let request = nextRequest
		nextRequest += 1

		// Held until Chromium answers, as `startDownload` holds it; the item it starts holds the
		// profile natively after (DEV-880). The answer may come before anyone waits.
		profileHolds[key, default: 0] += 1
		linkDownloadHolds[request] = key
		pendingLinkDownloads.insert(request)
		let accepted = performIfOpen(on: page) { api, id in
			api.download_link_context?(id, context.token, request) ?? false
		} ?? false
		guard accepted else {
			pendingLinkDownloads.remove(request)
			if let key = linkDownloadHolds.removeValue(forKey: request) { releaseProfileHold(key) }
			return nil
		}

		return request
	}

	/// ABI56 (DEV-851). The GUID of the item `startLinkContextDownload` started, once it
	/// exists, as `startDownload` returns it. Each request is waited on once.
	public func linkContextDownload(_ request: UInt64) async throws -> String {
		guard pendingLinkDownloads.contains(request)
		else { throw ChromiumDownloadStartFailure.unavailable }

		defer { pendingLinkDownloads.remove(request) }
		if let finished = finishedLinkDownloads.removeValue(forKey: request) {
			return try finished.get()
		}
		let result = await withCheckedContinuation {
			(continuation: CheckedContinuation<Result<String, ChromiumDownloadStartFailure>, Never>) in
			downloadStarts[request] = continuation
		}
		return try result.get()
	}

	internal func completeDownloadStart(
		_ request: UInt64,
		status: ArxDownloadStartStatus,
		guid: String?,
		interruptReason: Int32
	) {
		let result: Result<String, ChromiumDownloadStartFailure>
		if status == ARX_DOWNLOAD_START_STARTED, let guid, !guid.isEmpty {
			result = .success(guid)
		} else {
			result = .failure(.init(status: status, interruptReason: interruptReason))
		}
		if let key = linkDownloadHolds.removeValue(forKey: request) { releaseProfileHold(key) }
		if let continuation = downloadStarts.removeValue(forKey: request) {
			continuation.resume(returning: result)
		} else if pendingLinkDownloads.contains(request) {
			// A link download's item can exist before the app waits for it (DEV-851).
			finishedLinkDownloads[request] = result
		}
	}

	internal func receiveDownload(_ event: ChromiumDownloadEvent) {
		switch event {
		case let .changed(value): downloads[value.profileKey, default: [:]][value.guid] = value
		case let .initialized(key): initializedDownloads.insert(key)
		}

		for continuation in downloadObservers.values { continuation.yield(event) }
	}

	/// Captures the existing compositor viewport without resizing, scrolling, or navigating it.
	/// `offscreen` keeps a page that isn't on screen rendering while hidden and
	/// copies its viewport; it never shows, focuses or selects the page.
	public func capture(
		_ page: ChromiumPage,
		limits: ChromiumCaptureLimits = .init(),
		fullDocument: Bool = false,
		offscreen: Bool = false
	) async throws -> ChromiumCapture {
		try Task.checkCancellation()
		guard state == .running
		else { throw ChromiumCaptureFailure.unavailable }
		guard pages[page.id] === page
		else { throw ChromiumCaptureFailure.staleDocument }

		guard !fullDocument || supportsDocumentCapture
		else { throw ChromiumCaptureFailure.unavailable }
		guard !offscreen || (!fullDocument && supportsOffscreenCapture)
		else { throw ChromiumCaptureFailure.unavailable }

		let nativeLimits = try limits.native()
		let request = nextRequest
		nextRequest += 1

		let capture: ChromiumCapture = try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				guard !Task.isCancelled else {
					continuation.resume(throwing: CancellationError())
					return
				}

				captures[request] = .init(
					page: page.id,
					limits: limits,
					fullDocument: fullDocument,
					continuation: continuation
				)
				if fullDocument {
					api.capture_document(page.id, request, nativeLimits)
				} else if offscreen, let capture = api.capture_offscreen {
					capture(page.id, request, nativeLimits)
				} else {
					api.capture_viewport(page.id, request, nativeLimits)
				}
			}
		} onCancel: { [weak self] in
			Task { @MainActor [weak self] in
				self?.cancelCapture(request)
			}
		}

		try Task.checkCancellation()
		return capture
	}

	/// ABI26 hidden-page capture.
	public var supportsOffscreenCapture: Bool {
		state == .running && api.capture_offscreen != nil
	}

	/// ABI26 PDF export and PDF document bytes.
	public var supportsPDF: Bool {
		state == .running && pdfs.isAvailable
	}

	/// Prints the page to PDF, or reads the PDF document it shows. Ordinary pages only, unless
	/// `allowsPrivate`, which only the app's own Print and Save as PDF pass (ABI56, DEV-971).
	public func pdf(
		_ page: ChromiumPage,
		kind: ChromiumPDFKind,
		maximumBytes: Int = 4_194_304,
		timeoutMilliseconds: Int = 15_000,
		allowsPrivate: Bool = false
	) async throws -> ChromiumPDF {
		guard state == .running, !page.isPrivate || allowsPrivate
		else { throw ChromiumPDFFailure.unavailable }
		guard pages[page.id] === page, !page.isClosed
		else { throw ChromiumPDFFailure.staleDocument }

		let result = try await pdfs.request(
			page: page.id,
			kind: kind,
			maximumBytes: maximumBytes,
			timeoutMilliseconds: timeoutMilliseconds,
			allowsPrivate: allowsPrivate
		)
		guard pages[page.id] === page, !page.isClosed
		else { throw ChromiumPDFFailure.staleDocument }

		return result
	}

	/// ABI37: whether the engine can read a page's keyboard-focused link.
	public var supportsFocusedLink: Bool {
		state == .running && focusedLinks.isAvailable
	}

	/// ABI37. The http(s) link with keyboard focus in the page's current document, in
	/// any frame. Nil when nothing focused is a link Arx can open, for a private or
	/// hidden page, or when the page navigated before native answered. Nothing on
	/// the page is clicked or focused.
	public func focusedLink(on page: ChromiumPage) async -> ChromiumFocusedLink? {
		guard
			state == .running,
			pages[page.id] === page,
			let revision = documentRevision(for: page)
		else { return nil }

		guard
			let link = await focusedLinks.read(page: page.id),
			link.documentRevision == revision,
			state == .running,
			pages[page.id] === page,
			documentRevision(for: page) == revision
		else { return nil }

		return link
	}

	/// ABI34 developer tier: scripts in a page's developer world and its console and network logs.
	public var supportsDeveloperTier: Bool {
		state == .running && developers.isAvailable
	}

	/// Runs `source` as the body of an async function in the page's developer
	/// world, an isolated world of its main frame where cookies, password, card
	/// and one-time-code values and stored credentials read as nothing, and
	/// awaits its JSON-serializable value. Ordinary pages only.
	public func evaluateScript(
		_ page: ChromiumPage,
		source: String,
		maximumBytes: Int = 65_536,
		timeoutMilliseconds: Int = 10_000
	) async throws -> ChromiumScriptValue {
		guard state == .running, !page.isPrivate
		else { throw ChromiumDeveloperFailure.unavailable }
		guard pages[page.id] === page, !page.isClosed
		else { throw ChromiumDeveloperFailure.staleDocument }

		let value = try await developers.evaluate(
			page: page.id,
			source: source,
			maximumBytes: maximumBytes,
			timeoutMilliseconds: timeoutMilliseconds
		)
		guard pages[page.id] === page, !page.isClosed
		else { throw ChromiumDeveloperFailure.staleDocument }

		return value
	}

	/// ABI57 (DEV-996): whether the engine runs the app's page translation scripts.
	public var supportsTranslationScripts: Bool {
		state == .running && developers.translationIsAvailable
	}

	/// ABI57 (DEV-996). Runs one of the app's page translation scripts as
	/// ``evaluateScript(_:source:maximumBytes:timeoutMilliseconds:)`` does, but in the
	/// page's translation world, apart from agents' developer world and with the same
	/// credential hooks. Private pages are accepted.
	public func evaluateTranslationScript(
		_ page: ChromiumPage,
		source: String,
		maximumBytes: Int = 65_536,
		timeoutMilliseconds: Int = 10_000
	) async throws -> ChromiumScriptValue {
		guard supportsTranslationScripts
		else { throw ChromiumDeveloperFailure.unavailable }
		guard pages[page.id] === page, !page.isClosed
		else { throw ChromiumDeveloperFailure.staleDocument }

		let value = try await developers.evaluate(
			page: page.id,
			source: source,
			maximumBytes: maximumBytes,
			timeoutMilliseconds: timeoutMilliseconds,
			translation: true
		)
		guard pages[page.id] === page, !page.isClosed
		else { throw ChromiumDeveloperFailure.staleDocument }

		return value
	}

	/// ABI58 (DEV-1009). Wait on a page that stopped answering: the engine checks again,
	/// and a hang still there comes back with a new number. False when it answers.
	@discardableResult
	public func waitForPage(_ page: ChromiumPage) -> Bool {
		performIfOpen(on: page) { api, id in api.wait_for_page?(id) ?? false } ?? false
	}

	/// ABI58 (DEV-1009). Whether the page's renderer answers within the timeout, apart from
	/// the developer scripts' queue; nil when the engine can't ask.
	public func pingPage(
		_ page: ChromiumPage,
		timeoutMilliseconds: Int
	) async -> Bool? {
		guard state == .running, pages[page.id] === page, !page.isClosed else { return nil }
		return await developers.ping(page: page.id, timeoutMilliseconds: timeoutMilliseconds)
	}

	/// ABI58 (DEV-1009). Ends the page's renderer process, and every page sharing it, so a
	/// reload, navigation or close doesn't wait on a page that doesn't answer.
	@discardableResult
	public func endRenderer(_ page: ChromiumPage) -> Bool {
		performIfOpen(on: page) { api, id in api.end_page_renderer?(id) ?? false } ?? false
	}

	/// Starts or stops keeping the page's console and network logs natively.
	/// Stopping drops them. Private pages are refused.
	public func setDeveloperLog(
		_ page: ChromiumPage,
		enabled: Bool
	) -> Bool {
		guard
			state == .running,
			!page.isPrivate,
			pages[page.id] === page,
			!page.isClosed,
			let set = api.set_developer_log
		else { return !enabled }

		return set(page.id, enabled)
	}

	/// Reads up to `limit` console or network entries after `after`.
	public func developerLog(
		_ page: ChromiumPage,
		kind: ChromiumDeveloperLogKind,
		after: UInt64,
		limit: Int
	) async throws -> ChromiumDeveloperLog {
		guard state == .running, !page.isPrivate
		else { throw ChromiumDeveloperFailure.unavailable }
		guard pages[page.id] === page, !page.isClosed
		else { throw ChromiumDeveloperFailure.staleDocument }

		return try await developers.read(page: page.id, kind: kind, after: after, limit: limit)
	}

	/// ABI35 saved passwords (DEV-708): Chromium's password manager, per ordinary profile.
	public var supportsPasswords: Bool {
		state == .running && passwords.isAvailable
	}

	/// Save and update offers for submitted sign-in forms on ordinary pages.
	public func passwordSaveOffers() -> AsyncStream<ChromiumPasswordSaveOffer> {
		passwords.offers()
	}

	/// Answers the page's current offer. False when it was replaced or the page closed.
	public func answerPasswordSave(
		_ page: ChromiumPage,
		token: UInt64,
		answer: ChromiumPasswordSaveAnswer
	) -> Bool {
		guard
			state == .running,
			!page.isPrivate,
			pages[page.id] === page,
			!page.isClosed
		else { return false }

		return passwords.answer(page: page.id, token: token, answer: answer)
	}

	/// ABI52 autofill (DEV-875, DEV-893): saved passwords, addresses and cards offered
	/// for an ordinary page's focused field, drawn by the app.
	public var supportsAutofill: Bool {
		state == .running && autofill.isAvailable
	}

	/// Shown and hidden suggestions of every ordinary page.
	public func autofillEvents() -> AsyncStream<ChromiumAutofillEvent> {
		autofill.events()
	}

	/// Fills a shown item, as a click on it; asks the device owner first where
	/// `setAutofillAuthentication` says so. False when the session or item isn't current.
	public func acceptAutofillSuggestion(
		_ page: ChromiumPage,
		session: UInt64,
		index: UInt32
	) -> Bool {
		guard
			state == .running,
			!page.isPrivate,
			pages[page.id] === page,
			!page.isClosed
		else { return false }

		return autofill.accept(page: page.id, session: session, index: index)
	}

	/// The item the pointer is over, so Return fills it.
	public func selectAutofillSuggestion(
		_ page: ChromiumPage,
		session: UInt64,
		index: UInt32?
	) {
		guard state == .running, pages[page.id] === page, !page.isClosed
		else { return }

		autofill.select(page: page.id, session: session, index: index)
	}

	public func dismissAutofillSuggestions(
		_ page: ChromiumPage,
		session: UInt64
	) {
		guard state == .running, pages[page.id] === page, !page.isClosed
		else { return }

		autofill.dismiss(page: page.id, session: session)
	}

	/// App-wide; may be set before the runtime runs. The reasons are LocalAuthentication's
	/// prompts, such as "fill a saved password"; an empty one refuses fills that need it.
	public func setAutofillAuthentication(
		_ mode: ChromiumAutofillAuthentication,
		passwordReason: String,
		cardReason: String
	) {
		autofill.configure(mode, passwordReason: passwordReason, cardReason: cardReason)
	}

	/// ABI52 (DEV-893): whether ordinary profiles fill addresses and payment cards. App-wide;
	/// both on until set, and may be set before the runtime runs.
	public func setAutofillProducts(
		addresses: Bool,
		cards: Bool
	) {
		api.set_autofill_products?(addresses, cards)
	}

	/// ABI52 Settings › Autofill (DEV-893), per ordinary profile.
	public var supportsAutofillData: Bool {
		state == .running && autofillData.isAvailable
	}

	public func autofillListing(profile: UUID?) async throws(ChromiumAutofillDataFailure) -> ChromiumAutofillListing {
		try await autofillData.list(profileKey: autofillProfileKey(profile))
	}

	/// Adds an address (no `id`) or edits one. Replies with the profile's listing.
	public func saveAutofillAddress(
		profile: UUID?,
		_ address: ChromiumAutofillAddress
	) async throws(ChromiumAutofillDataFailure) -> ChromiumAutofillListing {
		try await autofillData.save(profileKey: autofillProfileKey(profile), address: address)
	}

	/// Adds a card (no `id`) or edits one. Native reads the number from `numberField` during
	/// the call; nil or an empty field keeps an edited card's number.
	public func saveAutofillCard(
		profile: UUID?,
		_ card: ChromiumAutofillCardDetails,
		numberField: NSTextField?
	) async throws(ChromiumAutofillDataFailure) -> ChromiumAutofillListing {
		try await autofillData.save(profileKey: autofillProfileKey(profile), card: card, numberField: numberField)
	}

	public func removeAutofillData(
		profile: UUID?,
		id: String
	) async throws(ChromiumAutofillDataFailure) -> ChromiumAutofillListing {
		try await autofillData.remove(profileKey: autofillProfileKey(profile), id: id)
	}

	private func autofillProfileKey(_ profile: UUID?) throws(ChromiumAutofillDataFailure) -> String {
		let key = profile?.uuidString.lowercased() ?? ""
		guard
			supportsAutofillData,
			preparedProfiles.contains(key),
			!privateProfileKeys.contains(key)
		else { throw .unavailable }

		return key
	}

	/// The accounts saved in the page's own profile for exactly its main frame's
	/// origin. Private pages have none.
	public func signInCredentials(_ page: ChromiumPage) async throws -> ChromiumSignInCredentials {
		guard state == .running, !page.isPrivate
		else { throw ChromiumSignInFailure.unavailable }
		guard pages[page.id] === page, !page.isClosed
		else { throw ChromiumSignInFailure.staleDocument(filled: false) }

		return try await passwords.credentials(page: page.id)
	}

	/// ABI36 saved passwords in Settings (DEV-721), per ordinary profile.
	public var supportsSavedPasswords: Bool {
		state == .running && savedPasswords.isAvailable
	}

	/// The profile's saved passwords (site and username) and "never saved"
	/// sites. `profile` is nil for the default profile, as in `prepareProfile`.
	public func savedPasswordList(profile: UUID?) async throws(ChromiumSavedPasswordFailure) -> ChromiumSavedPasswordList {
		let key = try savedPasswordProfileKey(profile)
		return try await holding(key) { () async throws(ChromiumSavedPasswordFailure) in
			try await savedPasswords.list(profileKey: key)
		}
	}

	/// Adds (`credential` 0, with `url`) or edits a saved password. Native reads
	/// `passwordField` once and clears it; nil, or an empty field on an edit,
	/// keeps the saved password. Replies with a fresh listing.
	public func savePassword(
		profile: UUID?,
		listing: String?,
		credential: UInt32,
		url: String?,
		username: String,
		passwordField: NSTextField?
	) async throws(ChromiumSavedPasswordFailure) -> ChromiumSavedPasswordList {
		let key = try savedPasswordProfileKey(profile)
		return try await holding(key) { () async throws(ChromiumSavedPasswordFailure) in
			try await savedPasswords.save(
				profileKey: key,
				listing: listing,
				credential: credential,
				url: url,
				username: username,
				passwordField: passwordField
			)
		}
	}

	/// Removes a saved password or a "never saved" site. Replies with a fresh listing.
	public func removeSavedPassword(
		profile: UUID?,
		listing: String,
		credential: UInt32
	) async throws(ChromiumSavedPasswordFailure) -> ChromiumSavedPasswordList {
		let key = try savedPasswordProfileKey(profile)
		return try await holding(key) { () async throws(ChromiumSavedPasswordFailure) in
			try await savedPasswords.remove(profileKey: key, listing: listing, credential: credential)
		}
	}

	/// After the device owner authenticates (LocalAuthentication shows `reason`),
	/// copies the password or writes it into a field. Swift never receives it.
	public func revealSavedPassword(
		profile: UUID?,
		listing: String,
		credential: UInt32,
		reason: String,
		mode: ChromiumPasswordReveal
	) async throws(ChromiumSavedPasswordFailure) {
		let key = try savedPasswordProfileKey(profile)
		try await holding(key) { () async throws(ChromiumSavedPasswordFailure) in
			try await savedPasswords.reveal(
				profileKey: key,
				listing: listing,
				credential: credential,
				reason: reason,
				mode: mode
			)
		}
	}

	/// Imports a Chrome or Apple Passwords CSV export into the profile. Chromium
	/// reads and parses the file; existing site and username pairs are kept.
	public func importPasswords(
		profile: UUID?,
		file: URL
	) async throws(ChromiumSavedPasswordFailure) -> ChromiumPasswordImport {
		let key = try savedPasswordProfileKey(profile)
		return try await holding(key) { () async throws(ChromiumSavedPasswordFailure) in
			try await savedPasswords.importPasswords(profileKey: key, file: file)
		}
	}

	/// ABI46 credential migration (DEV-830): decrypted passwords and cookies from
	/// another Chromium browser go straight into an ordinary profile.
	public var supportsCredentialImport: Bool {
		state == .running && credentialImport.isAvailable
	}

	/// Adds passwords to the profile's own store, keeping stored site and
	/// username pairs. The records' strings are copied for the call and zeroed.
	public func importPasswordRecords(
		profile: UUID?,
		records: [ChromiumImportedPassword]
	) async throws(ChromiumCredentialImportFailure) -> ChromiumPasswordRecordImport {
		let key = try credentialImportProfileKey(profile)
		return try await holding(key) { () async throws(ChromiumCredentialImportFailure) in
			try await credentialImport.importPasswords(profileKey: key, records: records)
		}
	}

	/// Sets cookies with their full identity, keeping cookies the profile has.
	public func importCookies(
		profile: UUID?,
		cookies: [ChromiumImportedCookie]
	) async throws(ChromiumCredentialImportFailure) -> ChromiumCookieImport {
		let key = try credentialImportProfileKey(profile)
		return try await holding(key) { () async throws(ChromiumCredentialImportFailure) in
			try await credentialImport.importCookies(profileKey: key, cookies: cookies)
		}
	}

	/// The keys among `keys` that name an unexpired cookie in the profile now.
	public func checkCookies(
		profile: UUID?,
		keys: [ChromiumCookieKey]
	) async throws(ChromiumCredentialImportFailure) -> Set<ChromiumCookieKey> {
		let key = try credentialImportProfileKey(profile)
		return try await holding(key) { () async throws(ChromiumCredentialImportFailure) in
			try await credentialImport.checkCookies(profileKey: key, keys: keys)
		}
	}

	/// Removes exactly what an import added; returns how many entries went.
	public func undoCredentialImport(
		profile: UUID?,
		passwords: [ChromiumPasswordKey],
		cookies: [ChromiumCookieKey]
	) async throws(ChromiumCredentialImportFailure) -> Int {
		let key = try credentialImportProfileKey(profile)
		return try await holding(key) { () async throws(ChromiumCredentialImportFailure) in
			try await credentialImport.undo(profileKey: key, passwords: passwords, cookies: cookies)
		}
	}

	/// ABI38 site permissions and page zoom in Settings (DEV-716), per ordinary profile.
	public var supportsSiteSettings: Bool {
		state == .running && siteSettings.isAvailable
	}

	/// The profile's permission defaults and site exceptions, and its default and
	/// per-host zoom. `profile` is nil for the default profile, as in `prepareProfile`.
	/// Listing a profile makes `siteSettingsChanges` report it.
	public func siteSettingsList(profile: UUID?) async throws(ChromiumSiteSettingsFailure) -> ChromiumSiteSettings {
		let key = try siteSettingsProfileKey(profile)
		return try await holding(key) { () async throws(ChromiumSiteSettingsFailure) in
			try await siteSettings.list(profileKey: key)
		}
	}

	/// Sets a site's permission (`setting` nil removes the site's own), or the profile's
	/// default when `origin` is nil. Replies with a fresh listing.
	public func setSitePermission(
		profile: UUID?,
		origin: String?,
		permission: ChromiumSitePermission,
		setting: ChromiumSitePermissionSetting?
	) async throws(ChromiumSiteSettingsFailure) -> ChromiumSiteSettings {
		let key = try siteSettingsProfileKey(profile)
		return try await holding(key) { () async throws(ChromiumSiteSettingsFailure) in
			try await siteSettings.setPermission(
				profileKey: key,
				origin: origin,
				permission: permission,
				setting: setting
			)
		}
	}

	/// Sets a host's page zoom (`factor` nil removes it), or the profile's default
	/// when `host` is nil. Open pages on that host follow at once.
	public func setSiteZoom(
		profile: UUID?,
		host: String?,
		factor: Double?
	) async throws(ChromiumSiteSettingsFailure) -> ChromiumSiteSettings {
		let key = try siteSettingsProfileKey(profile)
		return try await holding(key) { () async throws(ChromiumSiteSettingsFailure) in
			try await siteSettings.setZoom(profileKey: key, host: host, factor: factor)
		}
	}

	/// Profiles whose site settings changed, from anywhere, once they have been listed.
	/// Nil is the default profile.
	public func siteSettingsChanges() -> AsyncStream<UUID?> {
		let keys = siteSettings.changes()
		return .init(bufferingPolicy: .bufferingNewest(64)) { continuation in
			let task = Task {
				for await key in keys {
					if key.isEmpty {
						continuation.yield(nil)
					} else if let id = UUID(uuidString: key) {
						continuation.yield(id)
					}
				}
				continuation.finish()
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	/// ABI39 Clear Browsing Data and the downloads location (DEV-647), per ordinary profile.
	public var supportsProfileData: Bool {
		state == .running && profileData.isAvailable
	}

	/// What clearing `kinds` since `since` (nil for all time) would remove from what
	/// Chromium stores. `profile` is nil for the default profile.
	public func countBrowsingData(
		profile: UUID?,
		kinds: Set<ChromiumBrowsingDataKind>,
		since: Date?
	) async throws(ChromiumProfileDataFailure) -> ChromiumBrowsingDataCounts {
		let key = try profileDataKey(profile)
		return try await holding(key) { () async throws(ChromiumProfileDataFailure) in
			try await profileData.count(profileKey: key, kinds: kinds, since: since)
		}
	}

	/// Clears `kinds` from `since` (nil for all time) until now, as Chrome's Clear
	/// Browsing Data does. Returns the kinds Chromium couldn't fully clear.
	@discardableResult
	public func clearBrowsingData(
		profile: UUID?,
		kinds: Set<ChromiumBrowsingDataKind>,
		since: Date?
	) async throws(ChromiumProfileDataFailure) -> Set<ChromiumBrowsingDataKind> {
		let key = try profileDataKey(profile)

		// Clearing history drops its pages' icons from the favicon database, even when
		// the clear fails part way, so every icon shown for the profile is read again.
		defer { if kinds.contains(.history) { emitProfileSiteIconChange(profile: profile) } }
		return try await holding(key) { () async throws(ChromiumProfileDataFailure) in
			try await profileData.clear(profileKey: key, kinds: kinds, since: since)
		}
	}

	/// ABI40 the site menu's Clear Cache and Clear Cookies (DEV-633).
	public var supportsSiteData: Bool {
		state == .running && profileData.isSiteDataAvailable
	}

	/// The site whose data `clearSiteData` removes for that page's address: its
	/// registrable domain, all subdomains included, or its host when it has none.
	public func siteDataScope(
		profile: UUID?,
		url: URL
	) async throws(ChromiumProfileDataFailure) -> String {
		let key = try siteDataKey(profile)
		return try await holding(key) { () async throws(ChromiumProfileDataFailure) in
			try await profileData.siteScope(profileKey: key, url: url)
		}
	}

	/// Clears that site's cookies (with its site storage) and/or cache, all time.
	/// Only `.cookies` and `.cache` are accepted.
	@discardableResult
	public func clearSiteData(
		profile: UUID?,
		url: URL,
		kinds: Set<ChromiumBrowsingDataKind>
	) async throws(ChromiumProfileDataFailure) -> (domain: String, failed: Set<ChromiumBrowsingDataKind>) {
		let key = try siteDataKey(profile)
		return try await holding(key) { () async throws(ChromiumProfileDataFailure) in
			try await profileData.clearSite(profileKey: key, url: url, kinds: kinds)
		}
	}

	/// Where the profile saves downloads and whether it asks first.
	public func downloadSettings(profile: UUID?) async throws(ChromiumProfileDataFailure) -> ChromiumDownloadSettings {
		let key = try profileDataKey(profile)
		return try await holding(key) { () async throws(ChromiumProfileDataFailure) in
			try await profileData.downloadSettings(profileKey: key)
		}
	}

	/// `directory` nil keeps the current folder. Private profiles prepared with
	/// `preparePrivateProfile(_:followingDownloadsOf:)` this profile follow it at once.
	public func setDownloadSettings(
		profile: UUID?,
		directory: String?,
		ask: Bool
	) async throws(ChromiumProfileDataFailure) -> ChromiumDownloadSettings {
		let key = try profileDataKey(profile)
		return try await holding(key) { () async throws(ChromiumProfileDataFailure) in
			try await profileData.setDownloadSettings(
				profileKey: key,
				directory: directory,
				ask: ask
			)
		}
	}

	private func siteDataKey(_ profile: UUID?) throws(ChromiumProfileDataFailure) -> String {
		let key = profile?.uuidString.lowercased() ?? ""
		guard
			supportsSiteData,
			preparedProfiles.contains(key),
			!privateProfileKeys.contains(key)
		else { throw .unavailable }

		return key
	}

	private func profileDataKey(_ profile: UUID?) throws(ChromiumProfileDataFailure) -> String {
		let key = profile?.uuidString.lowercased() ?? ""
		guard
			supportsProfileData,
			preparedProfiles.contains(key),
			!privateProfileKeys.contains(key)
		else { throw .unavailable }

		return key
	}

	private func siteSettingsProfileKey(_ profile: UUID?) throws(ChromiumSiteSettingsFailure) -> String {
		let key = profile?.uuidString.lowercased() ?? ""
		guard
			supportsSiteSettings,
			preparedProfiles.contains(key),
			!privateProfileKeys.contains(key)
		else { throw .unavailable }

		return key
	}

	private func credentialImportProfileKey(_ profile: UUID?) throws(ChromiumCredentialImportFailure) -> String {
		let key = profile?.uuidString.lowercased() ?? ""
		guard
			supportsCredentialImport,
			preparedProfiles.contains(key),
			!privateProfileKeys.contains(key)
		else { throw .unavailable }

		return key
	}

	private func savedPasswordProfileKey(_ profile: UUID?) throws(ChromiumSavedPasswordFailure) -> String {
		let key = profile?.uuidString.lowercased() ?? ""
		guard
			supportsSavedPasswords,
			preparedProfiles.contains(key),
			!privateProfileKeys.contains(key)
		else { throw .unavailable }

		return key
	}

	/// Fills a listed account into `frame` (nil for the main frame) of the
	/// listed document, submits it and reads what the page shows next. The
	/// password stays in Chromium; the result carries only an outcome.
	public func signIn(
		_ page: ChromiumPage,
		document: String,
		frame: String? = nil,
		credential: UInt32,
		timeoutMilliseconds: Int = 30_000
	) async throws -> ChromiumSignInResult {
		guard state == .running, !page.isPrivate
		else { throw ChromiumSignInFailure.unavailable }
		guard pages[page.id] === page, !page.isClosed
		else { throw ChromiumSignInFailure.staleDocument(filled: false) }

		return try await passwords.attempt(
			page: page.id,
			document: document,
			frame: frame,
			credential: credential,
			timeoutMilliseconds: timeoutMilliseconds
		)
	}

	/// False until the matching rebuilt native engine has passed acceptance.
	public var supportsDocumentCapture: Bool {
		state == .running && api.document_capture_available?() == true
	}

	/// Explicit developer fixture; native also requires its run option, mock
	/// Keychain and a fresh native-owned root. Does not enable production capture.
	public func runDocumentCaptureFixture(
		on page: ChromiumPage,
		origin: URL
	) async throws -> Bool {
		guard
			state == .running,
			pages[page.id] === page,
			let run = api.run_document_capture_fixture
		else { throw ChromiumCaptureFailure.unavailable }

		let request = nextRequest
		nextRequest += 1
		return await withCheckedContinuation { continuation in
			requests[request] = continuation
			run(page.id, request, origin.absoluteString)
		}
	}

	private func cancelCapture(_ request: UInt64) {
		guard let pending = captures.removeValue(forKey: request)
		else { return }

		pending.continuation.resume(throwing: CancellationError())
		guard state == .running else { return }

		if pending.fullDocument {
			api.cancel_document_capture(request)
		} else {
			api.cancel_capture(request)
		}
	}

	internal func completeCapture(
		_ request: UInt64,
		page: UInt64,
		status: ArxCaptureStatus,
		snapshot: ArxCaptureSnapshot?
	) {
		guard let pending = captures.removeValue(forKey: request)
		else { return }

		do {
			guard !pending.fullDocument, pending.page == page, pages[page] != nil
			else { throw ChromiumCaptureFailure.staleDocument }
			if status == ARX_CAPTURE_CANCELLED { throw CancellationError() }
			guard status == ARX_CAPTURE_SUCCESS
			else { throw ChromiumCaptureFailure(status: status) }
			guard let snapshot
			else { throw ChromiumCaptureFailure.invalidImage }

			pending.continuation.resume(
				returning: try .init(native: snapshot, limits: pending.limits)
			)
		} catch {
			pending.continuation.resume(throwing: error)
		}
	}

	internal func completeDocumentCapture(
		_ request: UInt64,
		page: UInt64,
		status: ArxCaptureStatus,
		snapshot: ArxDocumentCaptureSnapshot?
	) {
		guard let pending = captures.removeValue(forKey: request)
		else { return }

		do {
			guard pending.fullDocument, pending.page == page, pages[page] != nil
			else { throw ChromiumCaptureFailure.staleDocument }
			if status == ARX_CAPTURE_CANCELLED { throw CancellationError() }
			guard status == ARX_CAPTURE_SUCCESS
			else { throw ChromiumCaptureFailure(status: status) }
			guard let snapshot
			else { throw ChromiumCaptureFailure.invalidImage }

			pending.continuation.resume(
				returning: try .init(native: snapshot, limits: pending.limits)
			)
		} catch {
			pending.continuation.resume(throwing: error)
		}
	}

	/// Observation and PiP are opt-in per ordinary page; private pages are denied natively.
	public func observeMedia(_ page: ChromiumPage) throws {
		guard state == .running
		else { throw ChromiumMediaFailure.unavailable }
		guard pages[page.id] === page
		else { throw ChromiumMediaFailure.staleSource }
		guard !page.isPrivate
		else { throw ChromiumMediaFailure.unavailable }

		media.register(page.id)
		guard api.observe_media(page.id) else {
			media.remove(page: page.id, cancel: { _ in })
			throw ChromiumMediaFailure.unavailable
		}
	}

	/// Revalidates the live native observer before taking focus, without awaiting queued events.
	public func isMediaSourceCurrent(
		_ page: ChromiumPage,
		generation: UInt64
	) -> Bool {
		guard
			state == .running,
			pages[page.id] === page,
			!page.isPrivate,
			generation != 0
		else { return false }

		return api.media_source_is_current(page.id, generation)
	}

	public func mediaEvents() -> AsyncStream<[ChromiumMediaSource]> {
		media.events()
	}

	public func mediaActivations() -> AsyncStream<ChromiumMediaActivation> {
		media.activations()
	}

	public func performMedia(
		_ page: ChromiumPage,
		generation: UInt64,
		revision: UInt64,
		action: ChromiumMediaSource.Action
	) async throws {
		guard state == .running
		else { throw ChromiumMediaFailure.unavailable }
		guard
			pages[page.id] === page,
			let source = media.source(page: page.id),
			source.generation == generation,
			source.revision == revision
		else { throw ChromiumMediaFailure.staleSource }

		try await media.perform(
			source,
			action: action,
			start: { [self] request in
				api.perform_media(
					page.id,
					request,
					generation,
					revision,
					ArxMediaAction(rawValue: UInt32(action.rawValue))
				)
			},
			cancel: { [weak self] request in self?.api.cancel_media(request) }
		)
	}

	/// Seeks the exact source to an absolute time in seconds; completes once the
	/// engine sees the position reach it.
	public func seekMedia(
		_ page: ChromiumPage,
		generation: UInt64,
		revision: UInt64,
		to seconds: Double
	) async throws {
		guard state == .running
		else { throw ChromiumMediaFailure.unavailable }
		guard seconds.isFinite, seconds >= 0
		else { throw ChromiumMediaFailure.unsupportedAction }
		guard
			pages[page.id] === page,
			let source = media.source(page: page.id),
			source.generation == generation,
			source.revision == revision
		else { throw ChromiumMediaFailure.staleSource }

		try await media.perform(
			source,
			action: .seek,
			start: { [self] request in
				api.seek_media(page.id, request, generation, revision, seconds)
			},
			cancel: { [weak self] request in self?.api.cancel_media(request) }
		)
	}

	/// Reads an observed ordinary page's media position and audio mute once.
	public func mediaPosition(_ page: ChromiumPage) -> ChromiumMediaPosition? {
		guard state == .running, pages[page.id] === page, !page.isPrivate
		else { return nil }

		var native = ArxMediaPosition()
		guard api.media_position(page.id, &native)
		else { return nil }

		return ChromiumMediaPosition(native: native)
	}

	/// Mutes or unmutes an observed ordinary page's audio.
	public func setAudioMuted(
		_ page: ChromiumPage,
		_ isMuted: Bool
	) throws {
		guard state == .running
		else { throw ChromiumMediaFailure.unavailable }
		guard pages[page.id] === page, !page.isPrivate
		else { throw ChromiumMediaFailure.staleSource }
		guard api.set_page_audio_muted(page.id, isMuted)
		else { throw ChromiumMediaFailure.unavailable }
	}

	/// Whether this engine can scale a page's audio output (DEV-800).
	public var supportsAudioVolume: Bool { audioVolume != nil }

	/// DEV-800: scales an observed ordinary page's audio output, 0 to 1, on top of the page's own volume.
	public func setAudioVolume(
		_ page: ChromiumPage,
		_ volume: Double
	) throws {
		guard state == .running, let audioVolume
		else { throw ChromiumMediaFailure.unavailable }
		guard volume.isFinite, (0...1).contains(volume)
		else { throw ChromiumMediaFailure.unsupportedAction }
		guard pages[page.id] === page, !page.isPrivate
		else { throw ChromiumMediaFailure.staleSource }
		guard audioVolume(page.id, volume)
		else { throw ChromiumMediaFailure.unavailable }
	}

	/// ABI41: the page's zoom factor (1 is 100%), ordinary or private, or nil when
	/// the engine isn't running or doesn't know the page (DEV-726).
	public func pageZoom(_ page: ChromiumPage) -> Double? {
		pageZoomLevels(page)?.factor
	}

	/// ABI41: the page's zoom factor and its profile's default zoom.
	public func pageZoomLevels(_ page: ChromiumPage) -> (factor: Double, defaultFactor: Double)? {
		guard state == .running, pages[page.id] === page
		else { return nil }

		var defaultFactor: Double = 1
		let factor = api.page_zoom(page.id, &defaultFactor)
		return factor > 0 ? (factor, defaultFactor > 0 ? defaultFactor : 1) : nil
	}

	/// ABI41: sets the page's zoom factor, for its host as Chrome does (a private
	/// page's host only while its profile lives), or returns it to the default
	/// with 0. Returns the factor now in effect, or nil when nothing changed.
	public func setPageZoom(_ page: ChromiumPage, _ factor: Double) -> Double? {
		guard state == .running, pages[page.id] === page, api.set_page_zoom(page.id, factor)
		else { return nil }

		return pageZoom(page)
	}

	/// Boolean-only native policy evidence for disposable private-media fixtures.
	/// This does not inspect or prove the macOS Now Playing surface.
	public func privateMediaMetadataIsHidden(_ page: ChromiumPage) -> Bool? {
		guard state == .running, pages[page.id] === page
		else { return nil }

		switch api.private_media_metadata_status(page.id) {
		case 0: return false
		case 1: return true
		default: return nil
		}
	}

	public func requestQuit() {
		guard state == .running else { return }
		api.request_quit()
	}

	internal func perform<T>(
		on page: ChromiumPage,
		_ action: (ArxEngineAPI, UInt64) throws -> T
	) throws -> T {
		guard state == .running else { throw ChromiumError.notRunning }
		guard pages[page.id] === page else { throw ChromiumError.pageClosed }
		return try action(api, page.id)
	}

	/// `perform` for reads and best-effort actions on a page that may have closed meanwhile: a
	/// stopped runtime or a closed page answers nil, as the callers expect. Any other error breaks
	/// the bridge's contract, such as a missing export, and is reported.
	internal func performIfOpen<T>(
		on page: ChromiumPage,
		_ action: (ArxEngineAPI, UInt64) throws -> T
	) -> T? {
		do {
			return try perform(on: page, action)
		} catch ChromiumError.notRunning, ChromiumError.pageClosed {
			return nil
		} catch {
			reportIssue(error)
			return nil
		}
	}

	/// Whether `page` is this runtime's open page.
	internal func isCurrent(_ page: ChromiumPage) -> Bool {
		pages[page.id] === page && !page.isClosed
	}

	internal func close(
		_ page: ChromiumPage,
		destroyNative: Bool = true
	) {
		guard pages[page.id] === page else { return }

		if hostedPromptPages.remove(page.id) != nil { onPagePermissionPrompt?(page, 0) }
		runtimeOptionsOffers[page.id] = nil
		if pendingOptionsSettlements.remove(page.id) != nil { onExtensionOptionsSettled?(page) }
		emitSiteIconChange(page: page.id)
		pages.removeValue(forKey: page.id)
		pageSiteIconScopes.removeValue(forKey: page.id)
		pageProfileKeys.removeValue(forKey: page.id)
		pageSiteIconURLs.removeValue(forKey: page.id)
		pageSiteIconTruncated.remove(page.id)
		pageSiteIconReported.remove(page.id)
		closeRequests.remove(page: page.id)
		referenceClicks.remove(page: page.id)
		inspections.remove(page: page.id)
		pdfs.remove(page: page.id)
		developers.remove(page: page.id)
		passwords.remove(page: page.id)
		media.remove(page: page.id, cancel: { [self] request in api.cancel_media(request) })

		for requestID in captures.filter({ $0.value.page == page.id }).keys {
			guard let pending = captures.removeValue(forKey: requestID) else { continue }
			pending.continuation.resume(throwing: ChromiumCaptureFailure.staleDocument)
			if pending.fullDocument {
				api.cancel_document_capture(requestID)
			} else {
				api.cancel_capture(requestID)
			}
		}
		staleWholePageCaptures(of: page.id)

		for requestID in closingRequests.filter({ $0.value == page.id }).keys {
			complete(requestID, false)
		}

		linkContexts.remove(page: page.identifier)
		page.invalidate()
		if destroyNative { api.destroy_page(page.id) }
	}

	public func configureContentHosting(
		on page: ChromiumPage,
		enabled: Bool
	) throws {
		guard
			state == .running,
			pages[page.id] === page,
			let configure = api.configure_content_hosting,
			configure(page.id, enabled)
		else { throw ChromiumError.incompatibleBridge }
	}

	internal func receiveNewContents(
		source: UInt64,
		generation: UInt64,
		child: UInt64,
		target: String,
		disposition: Int
	) -> Bool {
		guard
			state == .running,
			let sourcePage = pages[source],
			child != 0,
			pages[child] == nil,
			documentRevision(for: sourcePage) == generation,
			target.utf8.count <= 32_768,
			let url = URL(string: target),
			["http", "https"].contains(url.scheme?.lowercased()) || target == "about:blank",
			let intent = ChromiumNewContentsDisposition(rawValue: disposition),
			let pointer = api.page_view(child)
		else { return false }

		let view = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
		let page = ChromiumPage(
			id: child,
			view: view,
			runtime: self,
			isPrivate: sourcePage.isPrivate
		)
		pages[child] = page
		pageSiteIconScopes[child] = pageSiteIconScopes[source]
		pageProfileKeys[child] = pageProfileKeys[source]
		page.receive(.init(
			url: url,
			title: "",
			isLoading: true,
			canGoBack: false,
			canGoForward: false,
			errorCode: nil
		))
		guard onNewContents?(sourcePage, generation, page, url, intent) == true else {
			close(page, destroyNative: false)
			return false
		}

		return pages[child] === page && !page.isClosed
	}

	internal func receiveExtensionOptions(
		request: UInt64,
		profileKey: String,
		extensionID: String,
		child: UInt64,
		target: String,
		kind: ArxExtensionViewKind
	) -> Bool {
		adoptExtensionOptions(
			request: request,
			profileKey: profileKey,
			extensionID: extensionID,
			child: child,
			target: target,
			kind: kind
		)
	}

	internal func receiveRuntimeExtensionOptions(
		profileKey: String,
		extensionID: String,
		child: UInt64,
		target: String
	) -> Bool {
		guard
			supportsExtensionOptions,
			profileKey.isEmpty || preparedProfiles.contains(profileKey),
			!privateProfileKeys.contains(profileKey),
			child > lastRuntimeExtensionOptionsChild
		else { return false }

		// Native allocates never-recycled page IDs and offers synchronously. A
		// refused/closed native API offer cannot be replayed as fresh authority.
		lastRuntimeExtensionOptionsChild = child
		return adoptExtensionOptions(
			request: nil,
			profileKey: profileKey,
			extensionID: extensionID,
			child: child,
			target: target,
			kind: ARX_EXTENSION_VIEW_OPTIONS
		)
	}

	private func adoptExtensionOptions(
		request: UInt64?,
		profileKey: String,
		extensionID: String,
		child: UInt64,
		target: String,
		kind: ArxExtensionViewKind
	) -> Bool {
		guard
			state == .running,
			kind == ARX_EXTENSION_VIEW_OPTIONS,
			profileKey.isEmpty || UUID(uuidString: profileKey)?.uuidString.lowercased() == profileKey,
			!privateProfileKeys.contains(profileKey),
			child != 0,
			pages[child] == nil,
			target.utf8.count <= 32_768,
			let url = URL(string: target, encodingInvalidCharacters: false),
			let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
			parts.scheme == "chrome-extension",
			parts.host == extensionID,
			parts.user == nil,
			parts.password == nil,
			parts.port == nil,
			ChromiumExtension.validID(extensionID),
			request.map({
				extensionBridge.consumeOptionsOffer(request: $0, profileKey: profileKey, extensionID: extensionID)
			}) ?? true,
			let pointer = api.page_view(child)
		else { return false }

		let view = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
		let page = ChromiumPage(
			id: child,
			view: view,
			runtime: self,
			isPrivate: false
		)
		pages[child] = page
		page.receive(.init(
			url: url,
			title: "",
			isLoading: true,
			canGoBack: false,
			canGoForward: false,
			errorCode: nil
		))

		pendingOptionsSettlements.insert(child)
		if request == nil {
			runtimeOptionsOffers[child] = .init(
				page: page,
				profileKey: profileKey,
				extensionID: extensionID,
				generation: page.closeGeneration,
				isPublishing: true
			)
		}

		guard onExtensionView?(page, UUID(uuidString: profileKey), extensionID) == true else {
			close(page, destroyNative: false)
			return false
		}

		runtimeOptionsOffers[child]?.isPublishing = false

		// The native post-publication check runs synchronously before the next
		// actor turn. No rollback authority survives a successful publication.
		Task { @MainActor [weak self, weak page] in
			guard let self, let page else { return }

			guard self.pages[child] === page else { return }

			self.settleRuntimeOptionsOffer(page: child)
		}

		return pages[child] === page && !page.isClosed
	}

	private struct RuntimeOptionsOffer {
		internal let page: ChromiumPage
		internal let profileKey: String
		internal let extensionID: String
		internal let generation: UInt64
		internal var isPublishing: Bool

		internal init(
			page: ChromiumPage,
			profileKey: String,
			extensionID: String,
			generation: UInt64,
			isPublishing: Bool
		) {
			self.page = page
			self.profileKey = profileKey
			self.extensionID = extensionID
			self.generation = generation
			self.isPublishing = isPublishing
		}
	}

	private func settleRuntimeOptionsOffer(page: UInt64) {
		guard
			runtimeOptionsOffers[page]?.isPublishing != true,
			pendingOptionsSettlements.remove(page) != nil,
			let owner = runtimeOptionsOffers[page]?.page ?? pages[page]
		else { return }

		runtimeOptionsOffers[page] = nil
		onExtensionOptionsSettled?(owner)
	}

	internal func receiveRuntimeExtensionOptionsRevoked(
		profileKey: String,
		extensionID: String,
		child: UInt64,
		generation: UInt64
	) {
		guard
			state == .running,
			let offer = runtimeOptionsOffers[child],
			offer.profileKey == profileKey,
			offer.extensionID == extensionID,
			generation > 0,
			offer.generation == generation
		else { return }

		runtimeOptionsOffers[child] = nil
		pendingOptionsSettlements.remove(child)

		guard
			pages[child] === offer.page,
			!offer.page.isClosed,
			documentRevision(for: offer.page) == generation
		else {
			onExtensionOptionsSettled?(offer.page)
			return
		}

		onExtensionOptionsRevoked?(offer.page, UUID(uuidString: profileKey), extensionID)
		close(offer.page, destroyNative: false)
	}

	internal func receiveUnhandledEscape(
		page: UInt64,
		generation: UInt64
	) -> Bool {
		guard
			state == .running,
			let owner = pages[page],
			documentRevision(for: owner) == generation
		else { return false }

		return onUnhandledEscape?(owner, generation) ?? false
	}

	// MARK: - ABI62 (DEV-1264, DEV-1073) command keys

	/// The open page whose view holds `view`: a page's own view or one inside it, such as the
	/// view that has keyboard focus. DevTools, extension popups and other web contents aren't pages.
	public func page(containing view: NSView) -> ChromiumPage? {
		var current: NSView? = view
		while let candidate = current {
			if let page = pages.values.first(where: { $0.view === candidate && !$0.isClosed }) { return page }
			current = candidate.superview
		}
		return nil
	}

	internal func receiveCommandKey(
		page: UInt64,
		generation: UInt64,
		key: ChromiumCommandKey,
		consumed: Bool
	) -> Bool {
		guard
			state == .running,
			let owner = pages[page],
			documentRevision(for: owner) == generation
		else { return false }

		return onCommandKey?(owner, key, consumed) ?? false
	}

	// MARK: - ABI55 (DEV-885) web notifications

	internal func receivePageActivationRequest(
		page: UInt64,
		generation: UInt64
	) {
		guard
			state == .running,
			let owner = pages[page],
			documentRevision(for: owner) == generation
		else { return }

		onPageActivationRequest?(owner)
	}

	internal func receiveNotificationWindow(
		profileKey: String,
		child: UInt64,
		target: String
	) -> Bool {
		guard
			state == .running,
			profileKey.isEmpty || preparedProfiles.contains(profileKey),
			!privateProfileKeys.contains(profileKey),
			child != 0,
			child > lastNotificationWindowChild,
			pages[child] == nil,
			let url = URL(string: target, encodingInvalidCharacters: false),
			let scheme = url.scheme,
			["http", "https"].contains(scheme) || target == "about:blank"
		else { return false }

		// Native allocates never-recycled page IDs and offers synchronously, so a refused
		// offer can't be replayed.
		lastNotificationWindowChild = child
		guard let pointer = api.page_view(child)
		else { return false }

		let view = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
		let page = ChromiumPage(
			id: child,
			view: view,
			runtime: self,
			isPrivate: false
		)
		pages[child] = page

		// Its icons count like any other page's.
		pageSiteIconScopes[child] = siteIcons.currentScope(profileID: UUID(uuidString: profileKey))
		pageProfileKeys[child] = profileKey
		page.receive(.init(
			url: url,
			title: "",
			isLoading: true,
			canGoBack: false,
			canGoForward: false,
			errorCode: nil
		))

		guard onNotificationWindow?(page, UUID(uuidString: profileKey)) == true else {
			close(page, destroyNative: false)
			return false
		}

		return pages[child] === page && !page.isClosed
	}

	internal func receiveNotificationClick(_ click: ChromiumNotificationClick) {
		guard
			state == .running,
			// Any ordinary profile: one not shown yet this session, or released while idle,
			// still has its notifications. The app checks the profile exists.
			!privateProfileKeys.contains(click.profileKey)
		else { return }

		onNotificationClick?(click)
	}

	internal func receivePageCloseRequest(
		page: UInt64,
		generation: UInt64
	) {
		guard
			state == .running,
			let owner = pages[page],
			documentRevision(for: owner) == generation
		else { return }

		onPageCloseRequest?(owner)
	}

	internal func receivePagePermissionPrompt(
		page: UInt64,
		token: UInt64
	) {
		guard
			state == .running,
			let owner = pages[page]
		else { return }

		if token == 0 {
			hostedPromptPages.remove(page)
		} else {
			hostedPromptPages.insert(page)
		}
		onPagePermissionPrompt?(owner, token)
	}

	/// ABI56 (DEV-963). Whether the engine can hand site permission prompts to the app.
	public var supportsHostedPagePrompts: Bool {
		state == .running && api.set_page_prompts_hosted != nil
	}

	/// ABI56 (DEV-963). The app draws ordinary site permission prompts (set once at launch).
	/// Off, the default, keeps the engine's own sheet exactly as before.
	public func setPagePromptsHosted(_ hosted: Bool) {
		guard state == .running else { return }

		api.set_page_prompts_hosted?(hosted)
	}

	/// Same-document navigations keep full screen, so a report is never dropped for its
	/// document generation: only for a page the app no longer has.
	internal func receivePageFullScreen(
		page: UInt64,
		isFullScreen: Bool
	) {
		guard
			state == .running,
			let owner = pages[page]
		else { return }

		onPageFullScreen?(owner, isFullScreen)
	}

	internal func receiveExternalLink(
		page: UInt64,
		generation: UInt64,
		link: ChromiumExternalLink
	) -> Bool {
		guard
			state == .running,
			let owner = pages[page],
			owner.isPrivate == link.isPrivate,
			documentRevision(for: owner) == generation
		else { return false }

		return onExternalLink?(owner, link) ?? false
	}

	internal func receiveLinkForceClick(
		page: UInt64,
		generation: UInt64,
		target: String
	) -> Bool {
		guard
			state == .running,
			let owner = pages[page],
			documentRevision(for: owner) == generation,
			let url = URL(string: target),
			["http", "https"].contains(url.scheme?.lowercased())
		else { return false }

		return onLinkForceClick?(owner, generation, url) ?? false
	}

	internal func receiveWebstoreInstall(
		page: UInt64,
		profileKey: String,
		extensionID: String,
		token: UInt64
	) -> Bool {
		let profileID: UUID? = profileKey.isEmpty ? nil : UUID(uuidString: profileKey)
		guard
			state == .running,
			supportsWebstoreInstallation,
			let owner = pages[page],
			!owner.isPrivate,
			profileKey.isEmpty || profileID?.uuidString.lowercased() == profileKey,
			ChromiumExtension.validID(extensionID),
			let onWebstoreInstall
		else { return false }

		return onWebstoreInstall(
			owner,
			.init(
				runtimeID: extensionBridge.runtimeID,
				token: token,
				profileID: profileID,
				extensionID: extensionID
			)
		)
	}

	internal func receiveCrossSiteLink(
		page: UInt64,
		generation: UInt64,
		target: String
	) -> Bool {
		guard
			state == .running,
			let owner = pages[page],
			!owner.isPrivate,
			documentRevision(for: owner) == generation,
			let url = URL(string: target),
			["http", "https"].contains(url.scheme?.lowercased())
		else { return false }

		return onCrossSiteLink?(owner, generation, url) ?? false
	}

	internal func receiveLinkContext(
		page: UInt64,
		native: ArxLinkContext
	) -> Bool {
		guard state == .running, let owner = pages[page] else { return false }
		return linkContexts.receive(
			page: owner,
			native: native,
			generation: documentRevision(for: owner) ?? 0
		)
	}

	public func linkContextEvents() -> AsyncStream<ChromiumLinkContext> {
		guard state == .running else { return .init { $0.finish() } }
		return linkContexts.events()
	}

	public func linkContextIsCurrent(
		_ context: ChromiumLinkContext,
		on page: ChromiumPage
	) -> Bool {
		state == .running
		&& pages[page.id] === page
		&& !page.isClosed
		&& context.pageID == page.identifier
		&& documentRevision(for: page) == context.documentGeneration
		&& linkContexts.isCurrent(context)
	}

	public func dismissLinkContext(
		page: UInt64,
		token: UInt64
	) {
		linkContexts.dismiss(page: page, token: token)
	}

	/// Runs only in the native-owned fresh-profile fixture mode. Browser points
	/// are injected; renderer ACK/CSS and native navigation remain real. This
	/// does not establish physical trackpad, Magic Mouse or threshold quality.
	public func runGestureFixture(
		on page: ChromiumPage,
		loopbackOrigin: URL
	) async -> Bool {
		guard
			state == .running,
			gestureFixtureEnabled,
			pages[page.id] === page,
			!page.isClosed,
			!page.isPrivate,
			let run = api.run_gesture_fixture,
			let origin = URLComponents(url: loopbackOrigin, resolvingAgainstBaseURL: false),
			origin.scheme == "http",
			origin.host == "127.0.0.1",
			(1...65_535).contains(origin.port ?? 0),
			origin.path == "/",
			origin.user == nil,
			origin.password == nil,
			origin.query == nil,
			origin.fragment == nil
		else { return false }

		return await request { request in
			run(page.id, request, loopbackOrigin.absoluteString)
		}
	}

	internal func finish() {
		profileRetirement.stop()
		gestureFixtureEnabled = false
		onUnhandledEscape = nil
		onCommandKey = nil
		onPageCloseRequest = nil
		onPageFullScreen = nil
		onLinkHover = nil
		onPageActivationRequest = nil
		onNotificationWindow = nil
		onNotificationClick = nil
		onLinkForceClick = nil
		onCrossSiteLink = nil
		onExternalLink = nil
		onWebstoreInstall = nil
		onNewContents = nil
		runtimeOptionsOffers.removeAll()
		pendingOptionsSettlements.removeAll()
		onExtensionView = nil
		onExtensionOptionsRevoked = nil
		onExtensionOptionsSettled = nil
		linkContexts.stop()
		closeRequests.finish()
		siteIcons.stop()
		referenceClicks.stop()
		inspections.stop()
		pdfs.stop()
		developers.stop()
		passwords.stop()
		autofill.stop()
		autofillData.stop()
		savedPasswords.stop()
		credentialImport.stop()
		focusedLinks.stop()
		siteSettings.stop()
		profileData.stop()
		for observer in siteIconObservers.values {
			observer.finish()
		}
		siteIconObservers.removeAll()
		pageSiteIconScopes.removeAll()
		pageProfileKeys.removeAll()
		pageSiteIconURLs.removeAll()
		pageSiteIconTruncated.removeAll()
		pageSiteIconReported.removeAll()
		extensionBridge.stop()
		media.finish()

		for capture in captures.values {
			capture.continuation.resume(throwing: ChromiumCaptureFailure.unavailable)
		}
		captures.removeAll()
		for capture in wholePageCaptures.values {
			capture.continuation.resume(throwing: ChromiumCaptureFailure.unavailable)
		}
		wholePageCaptures.removeAll()
		for continuation in requests.values {
			continuation.resume(returning: false)
		}
		for continuation in closingWaiters.values.joined() {
			continuation.resume(returning: false)
		}
		requests.removeAll()
		closingRequests.removeAll()
		closingWaiters.removeAll()
		preparedProfiles.removeAll()
		profileUses.removeAll()
		profileHolds.removeAll()
		for page in pages.values {
			page.invalidate()
		}
		pages.removeAll()
		hostedPromptPages.removeAll()
		for continuation in downloadObservers.values { continuation.finish() }
		downloadObservers.removeAll()
		downloads.removeAll()
		initializedDownloads.removeAll()
		for continuation in downloadStarts.values { continuation.resume(returning: .failure(.unavailable)) }
		downloadStarts.removeAll()
		pendingLinkDownloads.removeAll()
		finishedLinkDownloads.removeAll()
		linkDownloadHolds.removeAll()
		onReady = nil
		state = .stopped
	}

	private struct CaptureRequest {
		internal var page: UInt64
		internal var limits: ChromiumCaptureLimits
		internal var fullDocument: Bool
		internal var continuation: CheckedContinuation<ChromiumCapture, any Error>

		internal init(
			page: UInt64,
			limits: ChromiumCaptureLimits,
			fullDocument: Bool,
			continuation: CheckedContinuation<ChromiumCapture, any Error>
		) {
			self.page = page
			self.limits = limits
			self.fullDocument = fullDocument
			self.continuation = continuation
		}
	}
}
