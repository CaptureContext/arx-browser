import Foundation

public struct BrowserNavigation: Equatable, Sendable {
	public var url: URL?
	public var title: String
	public var isLoading: Bool
	public var errorCode: Int?

	/// The download this tab's navigation became while the tab has no page of its own, such as
	/// a new tab opened for a file (DEV-1116). A tab showing a page keeps it and has none.
	public var download: Download?

	/// The engine says nothing has committed in this tab: a new tab, or one whose only
	/// navigation became a download (DEV-1116). Its address is only what it tried to open, so
	/// it's no page visit. False when the engine can't tell.
	public var hasNoPage: Bool

	/// The engine cancelled an HTTP authentication challenge in the current
	/// document because nobody could answer it (an unattended run).
	public var authenticationCancelled: Bool

	/// Sign-in prompts the engine refused in the current document because
	/// nobody could answer them (an unattended run).
	public var cancelledSignInPrompts: SignInPrompts

	/// The current find in page's matches, and which one is active.
	public var findResult: FindResult?
	public var canGoBack: Bool
	public var canGoForward: Bool
	public var history: [Entry]

	/// The engine unloaded the page to free memory (DEV-873). It keeps its address, title and
	/// history, and loads again when it's shown; until then it has no document to read.
	public var isUnloaded: Bool

	/// The engine showing the page (DEV-877): WebKit for sites Settings › Advanced › WebKit lists.
	public var engine: PageEngine

	/// DEV-1009: 0 while the page answers, else the number of its current hang. The page's
	/// renderer left an input unanswered; Wait checks again, and a hang still there comes back
	/// with a new number.
	public var unresponsive: UInt32

	/// DEV-1016: why the page's renderer last ended, and whether it keeps ending; nil before
	/// its first end.
	public var rendererEnd: RendererEnd?

	/// DEV-1065: the page's main-frame documents so far. A new one, a reload included (Arx's,
	/// the page's own or AppleScript's), adds one; a fragment or a frame in the page doesn't.
	/// 0 when the engine doesn't say.
	public var document: UInt64

	/// The colors the current document declares for the browser around it (DEV-1101).
	public var colors: PageColors

	public init(
		url: URL? = nil,
		title: String = "",
		isLoading: Bool = false,
		errorCode: Int? = nil,
		download: Download? = nil,
		hasNoPage: Bool = false,
		authenticationCancelled: Bool = false,
		cancelledSignInPrompts: SignInPrompts = [],
		findResult: FindResult? = nil,
		canGoBack: Bool = false,
		canGoForward: Bool = false,
		history: [Entry] = [],
		isUnloaded: Bool = false,
		engine: PageEngine = .chromium,
		unresponsive: UInt32 = 0,
		rendererEnd: RendererEnd? = nil,
		document: UInt64 = 0,
		colors: PageColors = .none
	) {
		self.url = url
		self.title = title
		self.isLoading = isLoading
		self.errorCode = errorCode
		self.download = download
		self.hasNoPage = hasNoPage
		self.authenticationCancelled = authenticationCancelled
		self.cancelledSignInPrompts = cancelledSignInPrompts
		self.findResult = findResult
		self.canGoBack = canGoBack
		self.canGoForward = canGoForward
		self.history = history
		self.isUnloaded = isUnloaded
		self.engine = engine
		self.unresponsive = unresponsive
		self.rendererEnd = rendererEnd
		self.document = document
		self.colors = colors
	}

	/// DEV-1009: the page's renderer stopped answering.
	public var isUnresponsive: Bool { unresponsive != 0 }
}

extension BrowserNavigation {
	/// A transfer a navigation became instead of a page (DEV-1116).
	public struct Download: Equatable, Sendable {
		public var id: BrowserDownload.ID
		public var filename: String

		public init(
			id: BrowserDownload.ID,
			filename: String
		) {
			self.id = id
			self.filename = filename
		}
	}

	/// Sign-in prompts that need a person.
	public struct SignInPrompts: OptionSet, Hashable, Sendable {
		public let rawValue: UInt8

		public init(rawValue: UInt8) {
			self.rawValue = rawValue
		}

		/// A WebAuthn (passkey or security key) request.
		public static let webAuthentication: Self = .init(rawValue: 1 << 0)

		/// A FedCM (browser-mediated federated sign-in) request.
		public static let federatedSignIn: Self = .init(rawValue: 1 << 1)
	}

	/// The current document needs a person: an HTTP authentication challenge or a
	/// sign-in prompt was refused because nobody could answer it.
	public var requiresUserAction: Bool {
		authenticationCancelled || !cancelledSignInPrompts.isEmpty
	}

	public struct Entry: Identifiable, Equatable, Sendable {
		public let id: Int
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
}

extension BrowserNavigation {
	public enum HistoryDirection: Equatable, Sendable {
		case back
		case forward
	}

	/// The native controller supplies chronological entries, including exactly one current entry.
	public func entries(in direction: HistoryDirection) -> [Entry] {
		guard
			history.filter(\.isCurrent).count == 1,
			Set(history.map(\.id)).count == history.count,
			let index = history.firstIndex(where: \.isCurrent)
		else { return [] }
		switch direction {
		case .back: return history[..<index].reversed()
		case .forward: return Array(history[(index + 1)...])
		}
	}
}

extension BrowserNavigation {
	public struct FindResult: Equatable, Sendable {
		public var matches: Int
		public var active: Int

		public init(
			matches: Int,
			active: Int
		) {
			self.matches = matches
			self.active = active
		}
	}
}

extension BrowserNavigation {
	/// Whether the page shows an ordinary web address, http or https with a host: what Print,
	/// Save Page As and View Page Source take (DEV-795).
	public var showsWebPage: Bool {
		guard let url, url.host() != nil else { return false }
		return url.hasWebScheme
	}
}
