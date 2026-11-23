import BrowserCore
import Foundation
import _Dependencies

/// A page that asked for protected media (DEV-877): its frame requested Encrypted Media
/// Extensions key systems, which Chromium can't play in Arx.
public struct ProtectedMediaRequest: Equatable, Sendable {
	public var tabID: Tab.ID
	public var profileID: Profile.ID

	/// The page's main-frame address when it asked.
	public var url: URL

	/// Why the engine reported the page (DEV-1211).
	public var reason: Reason

	public init(
		tabID: Tab.ID,
		profileID: Profile.ID,
		url: URL,
		reason: Reason = .playbackFailed
	) {
		self.tabID = tabID
		self.profileID = profileID
		self.url = url
		self.reason = reason
	}

	/// Why the engine reported a page's protected media (DEV-1211).
	public enum Reason: Equatable, Sendable {
		/// The page can't play its protected media in Chromium. An engine that gives no reason
		/// reports this, as every request was before.
		case playbackFailed

		/// Keys couldn't be created, or access was refused, before any media on the page wanted
		/// keys. A bot check does this, and so does a streaming player that stops early.
		case keysWithoutMedia
	}
}

/// A tab's page moved to the other engine (DEV-877).
public struct PageEngineChange: Equatable, Sendable {
	public var tabID: Tab.ID
	public var engine: PageEngine

	public init(
		tabID: Tab.ID,
		engine: PageEngine
	) {
		self.tabID = tabID
		self.engine = engine
	}
}

/// How Save As writes a WebKit page (DEV-1199).
public enum WebKitPageSaveFormat: CaseIterable, Equatable, Sendable {
	/// Safari's web archive: the document and every resource it loaded, in one file.
	case webArchive

	/// The document's HTML as the server sent it.
	case html

	/// The page printed to PDF on Page Setup's paper.
	case pdf
}

/// Which engine shows each tab's page, and moving a page between Chromium and WebKit
/// (DEV-877). The default has no WebKit pages: every tab is Chromium's and nothing moves.
public struct PageEngineClient: Sendable {
	/// The engine showing the tab's page now.
	public var engine: @MainActor @Sendable (Tab.ID) -> PageEngine

	/// Moves a tab's page to `engine`, loading `url` there (the page's own address when nil).
	/// A move to WebKit copies the site's cookies first. False when it didn't move: the page
	/// refused to leave (unsaved input), the tab has no page, or WebKit pages are off.
	public var move: @MainActor @Sendable (Tab.ID, PageEngine, URL?) async -> Bool

	/// Pages that asked for protected media, as Chromium reports them.
	public var protectedMediaRequests: @MainActor @Sendable () -> AsyncStream<ProtectedMediaRequest>

	/// Each move between engines, for the sidebar's engine mark.
	public var changes: @MainActor @Sendable () -> AsyncStream<PageEngineChange>

	/// Prints a WebKit page with WebKit's print panel on its window, titled with the second
	/// argument (DEV-1199). Throws for a tab WebKit doesn't show, or one no window shows.
	public var printWebKitPage: @MainActor @Sendable (Tab.ID, String) async throws -> Void

	/// Saves a WebKit page's document at the first address to the file URL in the format
	/// (DEV-1199). Throws when the page shows another address by then, rather than saving
	/// another document under this one's name, and for a tab WebKit doesn't show.
	public var saveWebKitPage: @MainActor @Sendable (Tab.ID, URL, URL, WebKitPageSaveFormat) async throws -> Void

	public init(
		engine: @escaping @MainActor @Sendable (Tab.ID) -> PageEngine = { _ in .chromium },
		move: @escaping @MainActor @Sendable (Tab.ID, PageEngine, URL?) async -> Bool = { _, _, _ in false },
		protectedMediaRequests: @escaping @MainActor @Sendable () -> AsyncStream<ProtectedMediaRequest> = {
			.finished
		},
		changes: @escaping @MainActor @Sendable () -> AsyncStream<PageEngineChange> = { .finished },
		printWebKitPage: @escaping @MainActor @Sendable (Tab.ID, String) async throws -> Void = { _, _ in
			throw BrowserEngineClient.Failure.unavailable
		},
		saveWebKitPage: @escaping @MainActor @Sendable (Tab.ID, URL, URL, WebKitPageSaveFormat) async throws -> Void = { _, _, _, _ in
			throw BrowserEngineClient.Failure.unavailable
		}
	) {
		self.engine = engine
		self.move = move
		self.protectedMediaRequests = protectedMediaRequests
		self.changes = changes
		self.printWebKitPage = printWebKitPage
		self.saveWebKitPage = saveWebKitPage
	}
}

extension PageEngineClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init() }
}

extension DependencyValues {
	public var pageEngines: PageEngineClient {
		get { self[PageEngineClient.self] }
		set { self[PageEngineClient.self] = newValue }
	}
}
