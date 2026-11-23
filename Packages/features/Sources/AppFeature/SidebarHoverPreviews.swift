import AppUI
import BrowserCaptureClient
import BrowserCore
import BrowserPagePreviewClient
import CoreGraphics
import Foundation
import ImageIO
import MainFeature
import UniformTypeIdentifiers
import _ComposableArchitecture

extension AppFeature.State {
	/// What a window's hover previews show for these tabs: live title and address, and when each was last used.
	///
	/// Last use is the later of when the tab was last on screen (kept while a profile archives tabs) and
	/// the latest history visit to its current address. Private windows keep no history, so theirs is nil.
	public func sidebarTabPreviews(
		in windowID: UUID,
		tabIDs: [UUID],
		isLoaded: (BrowserCore.Tab.ID) -> Bool = { _ in false }
	) -> [UUID: SidebarTabPreview] {
		let window = windowID == main.id ? (windowIsOpen ? main : nil) : windows[id: windowID]
		guard let window, !window.isClosing else { return [:] }
		let organization = window.isPrivate ? window.sidebar.organization : workspace

		var visits: [Profile.ID: [URL: Date]] = [:]
		var previews: [UUID: SidebarTabPreview] = [:]
		for id in tabIDs where previews[id] == nil {
			guard let tab = organization.tabs[id: .init(rawValue: id)] else { continue }
			let url = tab.restoration.url
			var lastUsed: Date? = window.isPrivate ? nil : tabsLastViewed[tab.id]
			if !window.isPrivate {
				if visits[tab.profileID] == nil {
					visits[tab.profileID] = Self.latestVisits(history.snapshots[tab.profileID])
				}
				if let visited = visits[tab.profileID]?[url] {
					lastUsed = max(lastUsed ?? visited, visited)
				}
			}
			previews[id] = .init(
				title: tab.displayTitle,
				url: url,
				lastUsed: lastUsed,
				isLoaded: isLoaded(tab.id)
			)
		}
		return previews
	}

	private static func latestVisits(_ snapshot: BrowsingHistorySnapshot?) -> [URL: Date] {
		guard let snapshot else { return [:] }
		return snapshot.entries.reduce(into: [:]) { visits, entry in
			visits[entry.url] = max(visits[entry.url] ?? entry.lastVisited, entry.lastVisited)
		}
	}
}

/// The window's own engine and capture clients. Views run outside the store's dependency
/// scope, so the window passes them in rather than reading `@Dependency`.
internal struct SidebarPreviewClients: Sendable {
	/// The live session of a tab, or nil when it isn't loaded.
	internal var snapshot: @MainActor @Sendable (BrowserCore.Tab.ID) -> BrowserSessionSnapshot?
	internal var capture: BrowserCaptureClient

	/// Runs a fixed read-only script in a loaded tab's developer world and returns its JSON
	/// value, or nil when the engine can't (DEV-802).
	internal var readScript: @MainActor @Sendable (BrowserCore.Tab.ID, String) async -> String?

	/// Saved pictures and site details for pages that aren't loaded (DEV-730).
	internal var pagePreviews: BrowserPagePreviewClient

	/// The cookies a profile would send to an address, which site details send to the page's
	/// own host (DEV-1142). Nil while `ARX_SITE_PREVIEW_IMAGES` is off: no cookies at all.
	internal var siteCookies: (@MainActor @Sendable (Profile.ID, URL) async -> [HTTPCookie])?

	/// Full previews (DEV-730): opens a page no window shows, silences it
	/// and closes it again.
	internal var openPage: @MainActor @Sendable (BrowserCore.Tab) async throws -> Void
	internal var mutePage: @MainActor @Sendable (BrowserCore.Tab.ID) -> Void
	internal var closePage: @MainActor @Sendable (BrowserCore.Tab.ID) -> Void

	/// Where a tab's media is, for the sidebar player's bar (DEV-906).
	internal var mediaPosition: @MainActor @Sendable (BrowserCore.Tab.ID) -> BrowserMediaPosition?

	internal init(
		snapshot: @escaping @MainActor @Sendable (BrowserCore.Tab.ID) -> BrowserSessionSnapshot? = { _ in nil },
		capture: BrowserCaptureClient = .init(),
		readScript: @escaping @MainActor @Sendable (BrowserCore.Tab.ID, String) async -> String? = { _, _ in nil },
		pagePreviews: BrowserPagePreviewClient = .init(),
		siteCookies: (@MainActor @Sendable (Profile.ID, URL) async -> [HTTPCookie])? = nil,
		openPage: @escaping @MainActor @Sendable (BrowserCore.Tab) async throws -> Void = { _ in
			throw CancellationError()
		},
		mutePage: @escaping @MainActor @Sendable (BrowserCore.Tab.ID) -> Void = { _ in },
		closePage: @escaping @MainActor @Sendable (BrowserCore.Tab.ID) -> Void = { _ in },
		mediaPosition: @escaping @MainActor @Sendable (BrowserCore.Tab.ID) -> BrowserMediaPosition? = { _ in nil }
	) {
		self.snapshot = snapshot
		self.capture = capture
		self.readScript = readScript
		self.pagePreviews = pagePreviews
		self.siteCookies = siteCookies
		self.openPage = openPage
		self.mutePage = mutePage
		self.closePage = closePage
		self.mediaPosition = mediaPosition
	}
}

@MainActor
internal func sidebarHoverPreviews(
	store: StoreOf<AppFeature>,
	windowID: UUID,
	clients: SidebarPreviewClients
) -> SidebarHoverPreviews? {
	let general = store.settings.general
	guard general.hoverPreviewsEnabled else { return nil }
	let sources = general.hoverPreviewSources
	let liveCalendar = LiveCalendar.isEnabled()

	// Shift + hover loads the page instantly (DEV-1029), only while it's on.
	var livePage: (@MainActor @Sendable (UUID) async -> CGImage?)?
	if sources.shiftLoadsPages {
		livePage = { @MainActor @Sendable id in
			guard let page = store.state.sidebarPreviewPage(in: windowID, tabID: id)
			else { return nil }
			return await SidebarPagePictures.shared.livePicture(of: page, clients: clients)
		}
	}
	return .init(
		tabs: { ids in
			store.state.sidebarTabPreviews(in: windowID, tabIDs: ids) { clients.snapshot($0) != nil }
		},
		thumbnail: { id in
			guard let page = store.state.sidebarPreviewPage(in: windowID, tabID: id)
			else { return nil }
			return await SidebarPagePictures.shared.picture(of: page, sources: sources, clients: clients)
		},
		livePage: livePage,
		summary: { id in
			guard
				sources.pageDetails,
				let page = store.state.sidebarPreviewPage(in: windowID, tabID: id),
				let key = page.key,
				clients.snapshot(page.tab.id) == nil
			else { return nil }
			return await SidebarPageDetails.shared.details(for: key, clients: clients)?.description
		},
		showsFolders: sources.folders,
		site: { id in
			switch store.state.sidebarSiteSource(in: windowID, tabID: id, sources: sources, liveCalendar: liveCalendar) {
			case let .ready(preview):
				return preview

			case let .mail(account):
				return await SidebarMailPreviews.shared.preview(
					for: .init(rawValue: id),
					account: account,
					clients: clients
				)

			case .calendar, nil:
				return nil
			}
		},
		calendar: { id in
			guard
				case let .calendar(account)? = store.state.sidebarSiteSource(
					in: windowID,
					tabID: id,
					sources: sources,
					liveCalendar: liveCalendar
				),
				let tab = store.state.workspace.tabs[id: .init(rawValue: id)]
			else { return nil }

			return sidebarLiveCalendar(
				tab: tab,
				account: account,
				store: store,
				windowID: windowID,
				clients: clients
			)
		}
	)
}

/// Live Calendar's card actions for one favorite (DEV-804).
@MainActor
private func sidebarLiveCalendar(
	tab: BrowserCore.Tab,
	account: Int,
	store: StoreOf<AppFeature>,
	windowID: UUID,
	clients: SidebarPreviewClients
) -> SidebarLiveCalendar {
	.init(
		day: { refresh in
			await SidebarCalendarPreviews.shared.day(for: tab, account: account, refresh: refresh, clients: clients)
		},
		newEvent: {
			// The window's space shows the favorite, so the new tab opens in the favorite's profile.
			let action: MainFeature.Action = .ui(.openInNewTab(GoogleCalendarReader.newEventURL(account: account)))
			store.send(windowID == store.main.id ? .main(action) : .windows(.element(id: windowID, action: action)))
		},
		disable: {
			var sources = store.settings.general.hoverPreviewSources
			sources.disabledCalendars.insert(tab.id.rawValue)
			store.send(.settings(.ui(.hoverPreviewSources(sources))))
		},
		checkPage: {
			await SidebarCalendarPreviews.shared.probe(for: tab, account: account, clients: clients)
		}
	)
}

/// Pictures of loaded pages for hover cards. They stay in memory only, and a page's picture is
/// reused while its document is unchanged and the picture is recent.
@MainActor
internal final class SidebarThumbnails {
	internal static let shared: SidebarThumbnails = .init()

	/// Twice the card's image width, for Retina displays.
	internal static let maximumWidth: Int = 528
	internal static let lifetime: Duration = .seconds(30)
	internal static let capacity: Int = 24

	private struct Entry {
		internal var revision: UInt64
		internal var documentRevision: UInt64?
		internal var capturedAt: ContinuousClock.Instant
		internal var image: CGImage
	}

	/// The session and document a picture belongs to.
	private struct Key: Equatable {
		internal var revision: UInt64
		internal var documentRevision: UInt64?
	}

	private struct Pending {
		internal var key: Key
		internal var task: Task<CGImage?, Never>
	}

	private var entries: [BrowserCore.Tab.ID: Entry]
	private var inFlight: [BrowserCore.Tab.ID: Pending]

	/// Chromium captures one page at a time, so preview captures queue behind each other.
	private var lastCapture: Task<CGImage?, Never>?

	private init() {
		self.entries = [:]
		self.inFlight = [:]
		self.lastCapture = nil
	}

	/// A picture of a loaded page. A new one is also saved under `saving`'s profile for its
	/// current address, so the card keeps it after the tab unloads (DEV-730).
	internal func thumbnail(
		for tabID: BrowserCore.Tab.ID,
		clients: SidebarPreviewClients,
		saving profileID: Profile.ID? = nil
	) async -> CGImage? {
		let started = Date()
		let capture = clients.capture
		guard let snapshot = clients.snapshot(tabID), capture.isAvailable() else {
			entries[tabID] = nil
			return nil
		}
		let key = Key(
			revision: snapshot.revision,
			documentRevision: snapshot.documentRevision.flatMap { $0 > 0 ? $0 : nil }
		)
		if
			let entry = entries[tabID],
			entry.revision == key.revision,
			entry.documentRevision == key.documentRevision,
			entry.capturedAt.duration(to: .now) < Self.lifetime
		{ return entry.image }

		let task: Task<CGImage?, Never>
		if let pending = inFlight[tabID], pending.key == key {
			task = pending.task
		} else {
			let request = PageCaptureRequest(
				tabID: tabID,
				revision: key.revision,
				limits: .init(maximumEncodedBytes: 16 * 1024 * 1024, timeoutMilliseconds: 2_000),
				documentRevision: key.documentRevision,
				// A page that isn't on screen is captured without showing it.
				offscreen: true
			)
			let previous = lastCapture
			task = Task { @MainActor in
				_ = await previous?.value
				if !snapshot.isVisibleForCapture, !capture.offscreenIsAvailable() { return nil }
				guard let frame = await Self.capture(request, with: capture) else { return nil }

				// Decoding and scaling a full Retina viewport would stall the pointer on the main actor.
				let image = frame.image
				let limits = request.limits
				let maximumWidth = Self.maximumWidth
				return await Task.detached(priority: .userInitiated) {
					SidebarThumbnails.thumbnail(from: image, limits: limits, maximumWidth: maximumWidth)
				}.value
			}
			lastCapture = task
			inFlight[tabID] = .init(key: key, task: task)
		}

		let image = await task.value
		if inFlight[tabID]?.key == key { inFlight[tabID] = nil }

		// The page may have moved on while the picture was taken or scaled.
		guard
			let image,
			let current = clients.snapshot(tabID),
			current.revision == key.revision,
			current.documentRevision.flatMap({ $0 > 0 ? $0 : nil }) == key.documentRevision
		else { return nil }

		store(.init(
			revision: key.revision,
			documentRevision: key.documentRevision,
			capturedAt: .now,
			image: image
		), for: tabID)
		if let profileID, let url = current.navigation.url {
			SidebarPagePictures.save(
				image,
				for: .init(profileID: profileID, pageURL: url),
				takenAt: started,
				clients: clients
			)
		}
		return image
	}

	/// Another capture (an assistant's, say) may hold Chromium's capture slot; wait briefly and retry.
	private static func capture(
		_ request: PageCaptureRequest,
		with capture: BrowserCaptureClient
	) async -> PageCaptureFrame? {
		for attempt in 0..<3 {
			do {
				let frame = try await capture.capture(request)
				return frame.request == request ? frame : nil
			} catch PageCaptureFailure.busy where attempt < 2 {
				try? await Task.sleep(for: .milliseconds(150))
			} catch {
				return nil
			}
		}
		return nil
	}

	/// Drops a page's picture, for pages opened only to take one.
	internal func forget(_ tabID: BrowserCore.Tab.ID) {
		entries[tabID] = nil
		inFlight[tabID] = nil
	}

	private func store(
		_ entry: Entry,
		for tabID: BrowserCore.Tab.ID
	) {
		entries[tabID] = entry
		guard entries.count > Self.capacity else { return }
		let oldest = entries.min { $0.value.capturedAt < $1.value.capturedAt }
		if let oldest { entries[oldest.key] = nil }
	}

	/// Validates the capture's PNG like `PageCaptureCodec`, then lets ImageIO decode it straight to card size.
	nonisolated internal static func thumbnail(
		from image: PageCaptureImage,
		limits: PageCaptureLimits,
		maximumWidth: Int
	) -> CGImage? {
		guard
			(try? limits.validate(width: image.width, height: image.height, encodedBytes: image.png.count)) != nil,
			let source = CGImageSourceCreateWithData(image.png as CFData, nil),
			CGImageSourceGetType(source) as String? == UTType.png.identifier,
			CGImageSourceGetCount(source) == 1
		else { return nil }

		let width = Double(min(image.width, maximumWidth))
		let height = Double(image.height) * width / Double(image.width)
		let options: CFDictionary = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceShouldCacheImmediately: true,
			kCGImageSourceThumbnailMaxPixelSize: max(1, Int(max(width, height).rounded())),
		] as CFDictionary
		return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
	}
}
