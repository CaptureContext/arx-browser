import AppKit
import ChromiumBridge

@MainActor
public final class ChromiumPage {
	public struct Navigation: Equatable, Sendable {
		public var url: URL?
		public var title: String
		public var isLoading: Bool
		public var canGoBack: Bool
		public var canGoForward: Bool
		public var errorCode: Int?

		/// ABI21. HTTP authentication challenges an unattended run cancelled for
		/// the current document instead of prompting. Always 0 in interactive runs.
		public var authenticationCancellations: UInt64

		/// ABI22. Sign-in prompts an unattended run refused for the current
		/// document. Always empty in interactive runs.
		public var userActionRequests: UserActionRequests

		/// ABI23. Matches of the current find, and which is active, or nil with none.
		public var findResult: FindResult?
		public var history: [HistoryEntry]

		/// DEV-873. The engine unloaded the page to free memory: it keeps its address, title
		/// and history, and loads again when it's shown.
		public var isUnloaded: Bool

		/// ABI58 (DEV-1009). 0 while the page answers, else the number of its current hang.
		public var unresponsive: UInt32

		/// ABI58 (DEV-1016). Why the page's renderer last ended, or nil before its first end.
		public var rendererEnd: RendererEnd?

		/// ABI59 (DEV-1065). The page's main-frame documents so far: a new one, a reload included,
		/// adds one; a fragment or a frame in the page doesn't. 0 before the first.
		public var document: UInt64

		/// ABI61 (DEV-1101). The colors the current document declares; none for a PDF.
		public var colors: Colors = .none

		internal init(
			url: URL?,
			title: String,
			isLoading: Bool,
			canGoBack: Bool,
			canGoForward: Bool,
			errorCode: Int?,
			authenticationCancellations: UInt64 = 0,
			userActionRequests: UserActionRequests = [],
			history: [HistoryEntry] = [],
			isUnloaded: Bool = false,
			unresponsive: UInt32 = 0,
			rendererEnd: RendererEnd? = nil,
			document: UInt64 = 0
		) {
			self.url = url
			self.title = title
			self.isLoading = isLoading
			self.canGoBack = canGoBack
			self.canGoForward = canGoForward
			self.errorCode = errorCode
			self.authenticationCancellations = authenticationCancellations
			self.userActionRequests = userActionRequests
			self.history = history
			self.isUnloaded = isUnloaded
			self.unresponsive = unresponsive
			self.rendererEnd = rendererEnd
			self.document = document
		}
	}

	/// ABI58 (DEV-1016). A renderer end: its number for the page (growing with each),
	/// Chromium's termination status, the process's exit code, and whether the engine ended
	/// it itself (``ChromiumRuntime/endRenderer(_:)``).
	public struct RendererEnd: Equatable, Sendable {
		public enum Status: Equatable, Sendable {
			case normal
			case abnormal
			case killed
			case crashed
			case launchFailed
			case outOfMemory
			case other(Int32)

			internal init(_ value: Int32) {
				self = switch value {
				case Int32(ARX_RENDERER_END_NORMAL): .normal
				case Int32(ARX_RENDERER_END_ABNORMAL): .abnormal
				case Int32(ARX_RENDERER_END_KILLED): .killed
				case Int32(ARX_RENDERER_END_CRASHED): .crashed
				case Int32(ARX_RENDERER_END_LAUNCH_FAILED): .launchFailed
				case Int32(ARX_RENDERER_END_OUT_OF_MEMORY): .outOfMemory
				default: .other(value)
				}
			}
		}

		public var number: UInt32
		public var status: Status
		public var exitCode: Int32
		public var endedByEngine: Bool

		public init(
			number: UInt32,
			status: Status,
			exitCode: Int32,
			endedByEngine: Bool
		) {
			self.number = number
			self.status = status
			self.exitCode = exitCode
			self.endedByEngine = endedByEngine
		}
	}

	/// ABI61 (DEV-1101). A page's theme color (`<meta name="theme-color">`, for its light or dark
	/// scheme) and the background its CSS gives the document, as `0xAARRGGBB`.
	public struct Colors: Equatable, Sendable {
		public var theme: UInt32?
		public var background: UInt32?

		public init(
			theme: UInt32? = nil,
			background: UInt32? = nil
		) {
			self.theme = theme
			self.background = background
		}

		public static let none: Self = .init()
	}

	/// ABI23. Matches of the current find, and which is active.
	public struct FindResult: Equatable, Sendable {
		public var matches: Int
		public var active: Int

		internal init(
			matches: Int,
			active: Int
		) {
			self.matches = matches
			self.active = active
		}
	}

	/// ABI22. Sign-in prompts that needed a person in an unattended run.
	public struct UserActionRequests: OptionSet, Equatable, Hashable, Sendable {
		public let rawValue: UInt32

		public init(rawValue: UInt32) {
			self.rawValue = rawValue
		}

		/// A modal WebAuthn request, cancelled before its dialog.
		public static let webAuthentication: Self = .init(rawValue: ARX_USER_ACTION_WEB_AUTHENTICATION.rawValue)

		/// A FedCM request that needed a dialog.
		public static let federatedSignIn: Self = .init(rawValue: ARX_USER_ACTION_FEDERATED_SIGN_IN.rawValue)
	}

	public struct HistoryEntry: Equatable, Sendable {
		public var id: Int
		public var url: URL
		public var title: String
		public var isCurrent: Bool

		public init(
			id: Int,
			url: URL,
			title: String,
			isCurrent: Bool
		) {
			self.id = id
			self.url = url
			self.title = title
			self.isCurrent = isCurrent
		}
	}

	/// Valid for hosting until close() or runtime shutdown.
	public let view: NSView
	public let isPrivate: Bool
	public private(set) var isClosed: Bool = false
	public private(set) var navigation: Navigation = .init(
		url: URL(string: "about:blank"),
		title: "",
		isLoading: false,
		canGoBack: false,
		canGoForward: false,
		errorCode: nil
	)
	public var onNavigation: (@MainActor (Navigation) -> Void)?

	/// ABI61 (DEV-1101). A change of the page's colors alone, which `onNavigation` doesn't hear:
	/// the document, its history and everything its session holds stay as they were.
	public var onColors: (@MainActor (Navigation) -> Void)?
	public var identifier: UInt64 { id }
	internal let id: UInt64
	internal private(set) var closeGeneration: UInt64 = 0
	private weak var runtime: ChromiumRuntime?

	internal init(
		id: UInt64,
		view: NSView,
		runtime: ChromiumRuntime,
		isPrivate: Bool = false
	) {
		self.id = id
		self.view = view
		self.runtime = runtime
		self.isPrivate = isPrivate
	}

	public func navigate(to url: URL) throws {
		try owner().perform(on: self) { api, id in
			guard api.navigate(id, url.absoluteString)
			else { throw ChromiumError.invalidURL }
		}
	}

	public func goBack() throws {
		try owner().perform(on: self) { $0.go_back($1) }
	}

	public func goForward() throws {
		try owner().perform(on: self) { $0.go_forward($1) }
	}

	public func clearCacheAndReload() throws {
		try owner().perform(on: self) { $0.clear_cache_and_reload($1) }
	}

	/// Revalidates the page's resources without clearing the profile's HTTP cache.
	public func reloadBypassingCache() throws {
		try owner().perform(on: self) { api, id in
			guard let reload = api.reload_bypassing_cache else { throw ChromiumError.incompatibleBridge }
			reload(id)
		}
	}

	public func reload() throws {
		try owner().perform(on: self) { $0.reload($1) }
	}

	/// ABI23. Starts a search with `newSession`, or moves through the current one.
	public func find(
		_ text: String,
		forward: Bool,
		newSession: Bool
	) throws {
		try owner().perform(on: self) { api, id in
			guard let find = api.page_find else { throw ChromiumError.incompatibleBridge }
			text.withCString { find(id, $0, forward, newSession) }
		}
	}

	public func stopFind() throws {
		try owner().perform(on: self) { api, id in
			guard let stop = api.page_stop_find else { throw ChromiumError.incompatibleBridge }
			stop(id)
		}
	}

	public func stop() throws {
		try owner().perform(on: self) { $0.stop($1) }
	}

	public func goToEntry(_ entryID: Int) throws {
		try owner().perform(on: self) { api, pageID in
			api.go_to_entry(pageID, Int32(entryID))
		}
	}

	public func close() {
		runtime?.close(self)
	}

	/// Gives keyboard focus to the page's render widget view, as Chrome's
	/// WebContents focus does. The contents view never forwards key events,
	/// so making it first responder alone leaves Escape and extension
	/// shortcuts undelivered until the user clicks into the page.
	@discardableResult
	public func focusContent() -> Bool {
		guard let window = view.window
		else { return false }

		// While the element picker is open, its view over the page has the keys (DEV-1206).
		if let picker = view.subviews.last(where: { $0 is ChromiumElementPickerInput }) {
			return window.makeFirstResponder(picker)
		}
		let render = view.subviews.first(where: { !($0 is NSControl) && $0.acceptsFirstResponder })
		return window.makeFirstResponder(render ?? view)
	}

	/// Chromium's `ERR_ABORTED`: a navigation ended without committing, and without an error page.
	internal static let abortedErrorCode: Int = -3

	internal func receive(_ navigation: Navigation) {
		var snapshot = navigation
		snapshot.history = self.navigation.history

		// DEV-1116: Chromium ends a navigation it didn't commit, such as one that became a
		// download, or a stop, with ERR_ABORTED and shows no error page. The page that was
		// showing stays, and so does its own error, if it had one.
		if navigation.errorCode == Self.abortedErrorCode { snapshot.errorCode = self.navigation.errorCode }
		if let runtime {
			closeGeneration = runtime.closeGeneration(for: self)

			// `page_changed` also reports find steps and prompt counters; the back/forward
			// list only changes with the document, its title, or its loading state.
			let historyMayHaveChanged = navigation.url != self.navigation.url
			|| navigation.title != self.navigation.title
			|| navigation.isLoading != self.navigation.isLoading
			|| navigation.canGoBack != self.navigation.canGoBack
			|| navigation.canGoForward != self.navigation.canGoForward
			|| self.navigation.history.isEmpty
			if historyMayHaveChanged { snapshot.history = history(in: runtime) }
			snapshot.authenticationCancellations = runtime.performIfOpen(on: self) { api, id in
				api.page_authentication_cancellations.map { $0(id) } ?? 0
			} ?? 0
			let userActionRequests = runtime.performIfOpen(on: self) { api, id in
				api.page_user_action_requests.map { $0(id) } ?? 0
			} ?? 0
			snapshot.userActionRequests = UserActionRequests(rawValue: userActionRequests)
			let findResult = runtime.performIfOpen(on: self) { api, id -> FindResult? in
				var matches: Int32 = -1
				var active: Int32 = -1
				api.page_find_status?(id, &matches, &active)

				// -1: no search in this page, or an engine without find.
				guard matches >= 0 else { return nil }
				return FindResult(matches: Int(matches), active: max(Int(active), 0))
			}
			snapshot.findResult = findResult ?? nil
			snapshot.colors = runtime.performIfOpen(on: self, Self.colors) ?? .none
			snapshot.isUnloaded = runtime.isUnloaded(self)
			snapshot.unresponsive = runtime.performIfOpen(on: self) { api, id in
				api.page_unresponsive.map { $0(id) } ?? 0
			} ?? 0
			snapshot.rendererEnd = runtime.performIfOpen(on: self) { api, id -> RendererEnd? in
				var end = ArxRendererEnd()
				guard api.page_renderer_end?(id, &end) == true else { return nil }
				return .init(
					number: end.number,
					status: .init(end.status),
					exitCode: end.exit_code,
					endedByEngine: end.ended_by_engine
				)
			} ?? nil
			snapshot.document = runtime.performIfOpen(on: self) { api, id in
				api.page_main_document.map { $0(id) } ?? 0
			} ?? 0
		}
		runtime?.receiveSiteIconNavigation(
			page: self,
			previous: self.navigation,
			current: snapshot
		)
		guard snapshot != self.navigation else { return }

		var recolored = self.navigation
		recolored.colors = snapshot.colors
		self.navigation = snapshot
		if recolored == snapshot {
			onColors?(snapshot)
		} else {
			onNavigation?(snapshot)
		}
	}

	/// The PDF viewer's own grey isn't a site's color, so a PDF reports none.
	nonisolated private static func colors(
		api: ArxEngineAPI,
		id: UInt64
	) -> Colors {
		var colors: ArxPageColors = .init()
		guard
			let read = api.page_colors,
			read(id, &colors),
			api.page_document_type?(id) != ARX_PAGE_DOCUMENT_PDF
		else { return .none }

		return .init(
			theme: colors.has_theme_color ? colors.theme_color : nil,
			background: colors.has_background_color ? colors.background_color : nil
		)
	}

	private func history(in runtime: ChromiumRuntime) -> [HistoryEntry] {
		let entries = runtime.performIfOpen(on: self) { api, id in
			(0 ..< api.history_count(id)).compactMap { index -> HistoryEntry? in
				var url: UnsafePointer<CChar>?
				var title: UnsafePointer<CChar>?
				var current = false
				let entryID = api.history_entry(id, index, &url, &title, &current)
				guard
					entryID >= 0,
					let url,
					let value = URL(string: String(cString: url))
				else { return nil }

				return HistoryEntry(
					id: Int(entryID),
					url: value,
					title: title.map(String.init(cString:)) ?? "",
					isCurrent: current
				)
			}
		}
		return entries ?? []
	}

	internal func invalidate() {
		isClosed = true
		closeGeneration = 0
		view.removeFromSuperview()
		onNavigation = nil
		onColors = nil
		runtime = nil
	}

	internal func owner() throws -> ChromiumRuntime {
		guard let openOwner else { throw ChromiumError.pageClosed }
		return openOwner
	}

	/// The runtime while this page is open; nil once it closed.
	internal var openOwner: ChromiumRuntime? {
		isClosed ? nil : runtime
	}
}
