import BrowserCore
import BrowserPagePreviewClient
import CoreGraphics
import Foundation
import MainFeature

/// A tab a hover card describes, with what decides where its picture may come from.
internal struct SidebarPreviewPage: Equatable, Sendable {
	internal var tab: BrowserCore.Tab

	/// Private windows keep nothing and fetch nothing for unloaded pages.
	internal var isPrivate: Bool

	/// Where the tab's saved picture lives: its profile and last address. Nil in a private window.
	internal var key: BrowserPagePreviewKey? {
		isPrivate ? nil : .init(profileID: tab.profileID, pageURL: tab.restoration.url)
	}
}

extension AppFeature.State {
	/// The tab a window's hover card describes, or nil when the window or tab is gone.
	internal func sidebarPreviewPage(
		in windowID: UUID,
		tabID: UUID
	) -> SidebarPreviewPage? {
		let window = windowID == main.id ? (windowIsOpen ? main : nil) : windows[id: windowID]
		guard let window, !window.isClosing else { return nil }
		let organization = window.isPrivate ? window.sidebar.organization : workspace
		guard let tab = organization.tabs[id: .init(rawValue: tabID)] else { return nil }
		return .init(tab: tab, isPrivate: window.isPrivate)
	}
}

/// Where a hover card's picture comes from (DEV-730), in order:
///
/// 1. a loaded page: a live picture, which is also saved for later unless the window is private;
/// 2. the picture saved for the page in its profile;
/// 3. Full previews, when on: the page loads off screen to take one, which is saved;
/// 4. site details, when on: the picture the site publishes for the page.
///
/// Shift-hover with Shift + hover loads the page instantly on (DEV-1029) goes straight to a
/// fresh load (``livePicture(of:clients:)``) and falls back to this order.
///
/// Private windows only ever get the first, and keep nothing.
@MainActor
internal final class SidebarPagePictures {
	internal static let shared: SidebarPagePictures = .init()

	/// How long a page opened for a Full preview may take to load.
	internal static let loadTimeout: Duration = .seconds(10)

	/// Lets a page that just finished loading paint before its picture is taken.
	internal static let settleDelay: Duration = .milliseconds(500)

	/// One Full preview at a time: each runs a whole page. A load runs to its end even when the
	/// card that asked goes, so a card Shift replaced (DEV-1029), or the next card for the same
	/// tab, takes the same picture instead of finding the load busy.
	private var loading: (page: LoadedPage, picture: Task<Taken?, Never>)?

	/// What a load is for: a request shares it only for the same tab, profile and address.
	private struct LoadedPage: Equatable {
		internal var tab: BrowserCore.Tab.ID
		internal var profile: BrowserCore.Profile.ID
		internal var url: URL
	}

	/// A picture a load took, and when the load started: every request that shared it saves it
	/// with that time, so a profile's pictures deleted meanwhile stay deleted.
	private struct Taken {
		internal var image: CGImage
		internal var startedAt: Date
	}

	private init() {
		self.loading = nil
	}

	internal func picture(
		of page: SidebarPreviewPage,
		sources: HoverPreviewSources,
		clients: SidebarPreviewClients
	) async -> CGImage? {
		let tabID = page.tab.id
		if clients.snapshot(tabID) != nil {
			let saving = page.isPrivate ? nil : page.tab.profileID
			let image: CGImage? = await SidebarThumbnails.shared.thumbnail(
				for: tabID,
				clients: clients,
				saving: saving
			)
			if let image { return image }
		}
		guard let key = page.key, !Task.isCancelled else { return nil }

		if
			let saved = await clients.pagePreviews.picture(key),
			let image = await Self.decode(saved.jpeg)
		{
			return image
		}

		// A page that loaded meanwhile shows its live picture next time instead.
		guard !Task.isCancelled, clients.snapshot(tabID) == nil else { return nil }

		if sources.fullPages, let taken = await loadedPicture(of: page.tab, clients: clients) {
			Self.save(taken.image, for: key, takenAt: taken.startedAt, clients: clients)
			return taken.image
		}
		guard sources.pageDetails, !Task.isCancelled else { return nil }
		return await SidebarPageDetails.shared.image(for: key, clients: clients)
	}

	/// Shift + hover loads the page instantly (DEV-1029): a page that isn't loaded loads off screen
	/// now for a fresh picture, saved picture or not and whatever Full previews says, and the
	/// picture is saved. Nil for a loaded page (its card takes the live picture as usual), in a
	/// private window, which fetches nothing, or when the page can't load; the card then shows
	/// its usual picture.
	internal func livePicture(
		of page: SidebarPreviewPage,
		clients: SidebarPreviewClients
	) async -> CGImage? {
		guard
			clients.snapshot(page.tab.id) == nil,
			let key = page.key,
			!Task.isCancelled
		else { return nil }

		guard let taken = await loadedPicture(of: page.tab, clients: clients)
		else { return nil }

		Self.save(taken.image, for: key, takenAt: taken.startedAt, clients: clients)
		return taken.image
	}

	/// Saves a picture off the main actor. Callers never pass a private window's page.
	/// `takenAt` is when its capture started, so the store refuses it if the profile's pictures
	/// were deleted meanwhile.
	internal static func save(
		_ image: CGImage,
		for key: BrowserPagePreviewKey,
		takenAt: Date,
		clients: SidebarPreviewClients
	) {
		let store = clients.pagePreviews.store
		Task.detached(priority: .utility) {
			guard let jpeg = PagePictureCodec.jpeg(image) else { return }
			await store(.init(jpeg: jpeg, takenAt: takenAt), key)
		}
	}

	internal static func decode(_ data: Data) async -> CGImage? {
		let maximumWidth = SidebarThumbnails.maximumWidth
		return await Task.detached(priority: .userInitiated) {
			PagePictureCodec.thumbnail(from: data, maximumPixelSize: maximumWidth)
		}.value
	}

	// MARK: - Full previews

	/// Loads the tab's last page off screen as a page no window shows, in the tab's own profile,
	/// takes its picture and closes it. Nothing reaches the tab, its history or its window: the
	/// page has its own ID, which only this method knows.
	private func loadedPicture(
		of tab: BrowserCore.Tab,
		clients: SidebarPreviewClients
	) async -> Taken? {
		let requested: LoadedPage = .init(tab: tab.id, profile: tab.profileID, url: tab.restoration.url)
		if let loading {
			return loading.page == requested ? await loading.picture.value : nil
		}
		guard
			clients.capture.isAvailable(),
			clients.capture.offscreenIsAvailable()
		else { return nil }

		let startedAt = Date()
		let picture = Task { @MainActor () -> Taken? in
			guard let image = await Self.load(tab, clients: clients)
			else { return nil }

			return .init(image: image, startedAt: startedAt)
		}
		loading = (requested, picture)
		let taken: Taken? = await picture.value
		if loading?.page == requested { loading = nil }
		return taken
	}

	/// Opens the page, waits for it to load and settle, takes its picture and closes it.
	private static func load(
		_ tab: BrowserCore.Tab,
		clients: SidebarPreviewClients
	) async -> CGImage? {
		let page = BrowserCore.Tab(
			id: .init(rawValue: UUID()),
			profileID: tab.profileID,
			restoration: tab.restoration
		)
		do {
			try await clients.openPage(page)
		} catch {
			clients.closePage(page.id)
			return nil
		}
		defer {
			SidebarThumbnails.shared.forget(page.id)
			clients.closePage(page.id)
		}
		clients.mutePage(page.id)

		guard await waitUntilLoaded(page.id, clients: clients)
		else { return nil }
		try? await Task.sleep(for: settleDelay)
		return await SidebarThumbnails.shared.thumbnail(for: page.id, clients: clients)
	}

	/// Whether the page finished loading without an error before the timeout.
	private static func waitUntilLoaded(
		_ id: BrowserCore.Tab.ID,
		clients: SidebarPreviewClients
	) async -> Bool {
		let deadline = ContinuousClock.now.advanced(by: loadTimeout)
		while ContinuousClock.now < deadline, !Task.isCancelled {
			if
				let navigation = clients.snapshot(id)?.navigation,
				navigation.url != nil,
				!navigation.isLoading
			{
				return navigation.errorCode == nil
			}
			try? await Task.sleep(for: .milliseconds(100))
		}
		return false
	}
}

/// What sites publish about pages that aren't loaded (DEV-730), kept in memory for ten minutes,
/// per profile like everything else a profile looks at. Fetched without cookies, or, when the
/// clients carry the profile's (DEV-1142), with those its page's own host would get.
@MainActor
internal final class SidebarPageDetails {
	internal static let shared: SidebarPageDetails = .init()

	internal static let lifetime: Duration = .seconds(600)
	internal static let capacity: Int = 64

	private struct Entry {
		internal var fetchedAt: ContinuousClock.Instant
		internal var details: PageDetails?
		internal var image: CGImage??
	}

	private var entries: [BrowserPagePreviewKey: Entry]
	private var inFlight: [BrowserPagePreviewKey: Task<PageDetails?, Never>]
	private var imagesInFlight: [BrowserPagePreviewKey: Task<CGImage?, Never>]

	private init() {
		self.entries = [:]
		self.inFlight = [:]
		self.imagesInFlight = [:]
	}

	internal func details(
		for key: BrowserPagePreviewKey,
		clients: SidebarPreviewClients
	) async -> PageDetails? {
		if
			let entry = entries[key],
			entry.fetchedAt.duration(to: .now) < Self.lifetime
		{
			return entry.details
		}

		let task: Task<PageDetails?, Never>
		if let pending = inFlight[key] {
			task = pending
		} else {
			let fetch = clients.pagePreviews.details
			let credentials = Self.credentials(for: key, clients: clients)
			task = Task { await fetch(key.pageURL, credentials) }
			inFlight[key] = task
		}
		let details = await task.value
		if inFlight[key] == task {
			inFlight[key] = nil
			store(.init(fetchedAt: .now, details: details, image: nil), for: key)
		}
		return details
	}

	internal func image(
		for key: BrowserPagePreviewKey,
		clients: SidebarPreviewClients
	) async -> CGImage? {
		guard let imageURL = await details(for: key, clients: clients)?.imageURL
		else { return nil }
		if let image = entries[key]?.image { return image }

		let task: Task<CGImage?, Never>
		if let pending = imagesInFlight[key] {
			task = pending
		} else {
			let fetch = clients.pagePreviews.image
			let credentials = Self.credentials(for: key, clients: clients)
			task = Task {
				guard let data = await fetch(imageURL, credentials) else { return nil }
				return await SidebarPagePictures.decode(data)
			}
			imagesInFlight[key] = task
		}
		let image = await task.value
		if imagesInFlight[key] == task {
			imagesInFlight[key] = nil
			entries[key]?.image = .some(image)
		}
		return image
	}

	/// The page's profile behind a fetch, or nil to send no cookies.
	private static func credentials(
		for key: BrowserPagePreviewKey,
		clients: SidebarPreviewClients
	) -> PageFetchCredentials? {
		guard let siteCookies = clients.siteCookies else { return nil }
		let profileID = key.profileID
		return .init(pageURL: key.pageURL) { url in await siteCookies(profileID, url) }
	}

	/// Forgets a profile's details, when its history, cookies or cache are cleared or it's
	/// removed.
	internal func forget(_ profileIDs: Set<Profile.ID>) {
		for key in entries.keys where profileIDs.contains(key.profileID) {
			entries[key] = nil
		}
		for (key, task) in inFlight where profileIDs.contains(key.profileID) {
			task.cancel()
			inFlight[key] = nil
		}
		for (key, task) in imagesInFlight where profileIDs.contains(key.profileID) {
			task.cancel()
			imagesInFlight[key] = nil
		}
	}

	private func store(
		_ entry: Entry,
		for key: BrowserPagePreviewKey
	) {
		entries[key] = entry
		guard entries.count > Self.capacity else { return }
		let oldest = entries.min { $0.value.fetchedAt < $1.value.fetchedAt }
		if let oldest { entries[oldest.key] = nil }
	}
}
