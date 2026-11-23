import BrowserCore
import CryptoKit
import Foundation
import WebKit

/// Every tab's WebKit page and every profile's WebKit data store (DEV-877).
///
/// Each ordinary profile has one persistent `WKWebsiteDataStore`, named by an identifier
/// derived from the profile's, and each private profile one non-persistent store that lasts
/// until the private window's profile is released. Nothing crosses between profiles.
@MainActor
public final class WebKitPages {
	private var pages: [Tab.ID: WebKitPage] = [:]
	private var persistentStores: [Profile.ID: WKWebsiteDataStore] = [:]
	private var privateStores: [Profile.ID: WKWebsiteDataStore] = [:]
	private let stores: WebKitDataStores

	/// Applies the content blocker's rules to pages, when there is one.
	public var contentRules: WebKitContentRules?

	/// Arx's page menu on every page's context menus (DEV-1199); nil keeps WebKit's own menu.
	public var pageMenu: WebKitPageMenu?

	/// The buttons of a page's JavaScript alert and confirm dialogs, in the interface's language:
	/// the app sets them from its catalog (DEV-1291), which this package can't read.
	public var dialogButtons: WebKitDialogButtons = .untranslated

	/// Whether Safari's Web Inspector can inspect pages, which puts WebKit's Inspect Element in
	/// their context menus (DEV-1199). Arx turns it on with developer mode.
	public var isInspectable: Bool = false {
		didSet {
			guard isInspectable != oldValue else { return }
			for page in pages.values { page.webView.isInspectable = isInspectable }
		}
	}

	public init(
		contentRules: WebKitContentRules? = nil,
		stores: WebKitDataStores = .live
	) {
		self.contentRules = contentRules
		self.stores = stores
	}

	public func page(_ id: Tab.ID) -> WebKitPage? { pages[id] }

	public var tabIDs: Set<Tab.ID> { Set(pages.keys) }

	/// The tab's page, made in its profile's store when it has none.
	internal func make(
		_ tab: Tab,
		isPrivate: Bool,
		returnsToChromium: Bool
	) -> WebKitPage {
		if let page = pages[tab.id] {
			page.returnsToChromium = returnsToChromium
			return page
		}
		let page = WebKitPage(
			tabID: tab.id,
			profileID: tab.profileID,
			isPrivate: isPrivate,
			dataStore: dataStore(for: tab.profileID, isPrivate: isPrivate),
			returnsToChromium: returnsToChromium
		)
		page.willNavigate = { [weak self] page, url in
			self?.contentRules?.apply(
				to: page.webView.configuration.userContentController,
				profile: page.profileID,
				for: url
			)
		}
		page.pageMenu = { [weak self] in self?.pageMenu }
		page.dialogButtons = { [weak self] in self?.dialogButtons ?? .untranslated }
		page.webView.isInspectable = isInspectable
		pages[tab.id] = page
		return page
	}

	internal func close(_ id: Tab.ID) {
		pages.removeValue(forKey: id)?.close()
	}

	/// Lets a private profile's store go once its last page has closed: its cookies and site
	/// data go with it.
	public func releasePrivateProfile(_ id: Profile.ID) {
		guard !pages.values.contains(where: { $0.profileID == id }) else { return }
		privateStores[id] = nil
	}

	/// Removes an ordinary profile's WebKit data, for a profile that's being deleted.
	public func removeData(of id: Profile.ID) async {
		for page in pages.values where page.profileID == id {
			close(page.tabID)
		}
		persistentStores[id] = nil
		try? await stores.remove(Self.dataStoreIdentifier(for: id))
	}

	/// Clears a profile's WebKit data with the same choices as its Chromium data: cookies and
	/// site storage, the cache, or both, since a moment (nil for all time), for one site
	/// (its registrable domain and subdomains) or every site. History, downloads, autofill and
	/// site settings have no WebKit store of their own.
	public func clearData(
		of id: Profile.ID,
		isPrivate: Bool,
		kinds: Set<BrowsingDataKind>,
		since: Date? = nil,
		site: String? = nil
	) async {
		let types = Self.dataTypes(kinds)
		guard !types.isEmpty, let store = await existingDataStore(for: id, isPrivate: isPrivate)
		else { return }
		guard let site, !site.isEmpty else {
			await store.removeData(ofTypes: types, modifiedSince: since ?? .distantPast)
			return
		}
		let domain = site.lowercased()
		let records = await store.dataRecords(ofTypes: types).filter { record in
			let name = record.displayName.lowercased()
			return name == domain || name.hasSuffix("." + domain)
		}
		guard !records.isEmpty else { return }
		await store.removeData(ofTypes: types, for: records)
	}

	internal static func dataTypes(_ kinds: Set<BrowsingDataKind>) -> Set<String> {
		let caches: Set<String> = [
			WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
		]
		var types: Set<String> = []
		if kinds.contains(.cookies) { types.formUnion(WKWebsiteDataStore.allWebsiteDataTypes().subtracting(caches)) }
		if kinds.contains(.cache) { types.formUnion(caches) }
		return types
	}

	/// Copies cookies into the profile's store before a page moves there. A cookie WebKit
	/// already has (the same name, domain and path) stays: a sign-in or refresh in WebKit is
	/// newer than Chromium's copy.
	internal func importCookies(
		_ cookies: [HTTPCookie],
		profileID: Profile.ID,
		isPrivate: Bool
	) async {
		guard !cookies.isEmpty else { return }
		let store = dataStore(for: profileID, isPrivate: isPrivate).httpCookieStore
		let existing = Set(await store.allCookies().map(Self.cookieKey))
		for cookie in cookies where !existing.contains(Self.cookieKey(cookie)) {
			await store.setCookie(cookie)
		}
	}

	internal static func cookieKey(_ cookie: HTTPCookie) -> String {
		"\(cookie.name)\u{0}\(cookie.domain.lowercased())\u{0}\(cookie.path)"
	}

	/// The profile's store when WebKit has one, without making one: a private profile's lives
	/// only while its pages do, and making an ordinary profile's would write it to disk.
	private func existingDataStore(
		for id: Profile.ID,
		isPrivate: Bool
	) async -> WKWebsiteDataStore? {
		if isPrivate { return privateStores[id] }
		if let store = persistentStores[id] { return store }
		guard await stores.identifiers().contains(Self.dataStoreIdentifier(for: id))
		else { return nil }

		return dataStore(for: id, isPrivate: false)
	}

	internal func dataStore(
		for id: Profile.ID,
		isPrivate: Bool
	) -> WKWebsiteDataStore {
		if isPrivate {
			if let store = privateStores[id] { return store }
			let store = WKWebsiteDataStore.nonPersistent()
			privateStores[id] = store
			return store
		}
		if let store = persistentStores[id] { return store }
		let store = stores.make(Self.dataStoreIdentifier(for: id))
		persistentStores[id] = store
		return store
	}

	/// The WebKit store's identifier for a profile: a name-based UUID, so it never equals an
	/// identifier anything else uses for the profile.
	///
	/// A profile merged into iCloud's uses this Mac's alias for it (DEV-1216), so its pages keep the
	/// merged profile's website data.
	public static func dataStoreIdentifier(for id: Profile.ID) -> UUID {
		let storage: UUID = ProfileStorageAliases.shared.storageID(for: id.rawValue)
		let digest = SHA256.hash(data: Data("dev.capturecontext.arx.webkit|\(storage.uuidString)".utf8))
		var bytes = Array(digest.prefix(16))
		bytes[6] = (bytes[6] & 0x0F) | 0x50
		bytes[8] = (bytes[8] & 0x3F) | 0x80
		return UUID(uuid: (
			bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
			bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
		))
	}
}

/// How ``WebKitPages`` reaches WebKit's per-profile data stores. Tests replace it, so they never
/// write a store to disk.
public struct WebKitDataStores {
	/// The persistent store for an identifier, made on disk when it isn't there.
	public var make: @MainActor (UUID) -> WKWebsiteDataStore

	/// The identifiers of the stores on disk.
	public var identifiers: @MainActor () async -> [UUID]

	/// Deletes a store and its data. It must have no pages.
	public var remove: @MainActor (UUID) async throws -> Void

	public init(
		make: @escaping @MainActor (UUID) -> WKWebsiteDataStore,
		identifiers: @escaping @MainActor () async -> [UUID],
		remove: @escaping @MainActor (UUID) async throws -> Void
	) {
		self.make = make
		self.identifiers = identifiers
		self.remove = remove
	}

	public static var live: Self {
		.init(
			make: { WKWebsiteDataStore(forIdentifier: $0) },
			identifiers: {
				prepareWebKit()
				return await withCheckedContinuation { continuation in
					WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0) }
				}
			},
			remove: { identifier in
				prepareWebKit()
				try await WKWebsiteDataStore.remove(forIdentifier: identifier)
			}
		)
	}

	/// WebKit's class methods for identified stores (`remove(forIdentifier:)`,
	/// `fetchAllDataStoreIdentifiers`) don't set WebKit up. Called before anything else WebKit in
	/// the process, as profile retirement or Clear History does when no page has used WebKit,
	/// their work finishes on WebKit's I/O queue by dispatching to a main run loop WebKit never
	/// made, and the app crashes (SIGSEGV in `WTF::RunLoop::dispatch`). Making a store object
	/// first sets WebKit up; a non-persistent one writes nothing to disk.
	@MainActor
	private static var webKitIsReady: Bool = false

	@MainActor
	private static func prepareWebKit() {
		guard !webKitIsReady else { return }
		_ = WKWebsiteDataStore.nonPersistent()
		webKitIsReady = true
	}
}
