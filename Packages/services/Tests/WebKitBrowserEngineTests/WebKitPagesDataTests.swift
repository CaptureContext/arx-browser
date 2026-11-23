import BrowserCore
import Foundation
import Testing
import WebKit

@testable import WebKitBrowserEngine

/// A profile's WebKit data is removed or cleared without making a store it never had, and
/// WebKit's store-wide calls never run before WebKit is set up (the retirement crash).
@MainActor
@Suite(.serialized)
internal struct WebKitPagesDataTests {
	private let profile: Profile.ID = .init(rawValue: UUID())

	@Test
	internal func removingAProfileClosesItsPagesBeforeItsStoreGoes() async throws {
		let log = StoreLog()
		let pages = WebKitPages(stores: log.stores)
		log.pages = pages
		let tab = Tab(
			id: .init(rawValue: UUID()),
			profileID: profile,
			restoration: .init(title: "News", url: URL(string: "https://news.example")!)
		)
		_ = pages.make(tab, isPrivate: false, returnsToChromium: false)

		await pages.removeData(of: profile)

		#expect(pages.page(tab.id) == nil)
		#expect(log.removed == [WebKitPages.dataStoreIdentifier(for: profile)])
		#expect(log.pagesWhenRemoved == [0])
	}

	@Test
	internal func clearingAProfileWebKitNeverStoredMakesNoStore() async throws {
		let log = StoreLog()
		let pages = WebKitPages(stores: log.stores)

		await pages.clearData(of: profile, isPrivate: false, kinds: [.cookies, .cache])
		await pages.clearData(of: profile, isPrivate: true, kinds: [.cookies, .cache])

		#expect(log.made.isEmpty)
	}

	@Test
	internal func clearingAProfileWithAStoreOnDiskUsesIt() async throws {
		let log = StoreLog()
		log.onDisk = [WebKitPages.dataStoreIdentifier(for: profile)]
		let pages = WebKitPages(stores: log.stores)

		await pages.clearData(of: profile, isPrivate: false, kinds: [.cache])

		#expect(log.made == [WebKitPages.dataStoreIdentifier(for: profile)])
	}

	/// The live calls set WebKit up first. Without that, the first of them in a process crashed
	/// in `WTF::RunLoop::dispatch` once WebKit's I/O queue finished.
	@Test
	internal func liveStoreCallsCompleteForAStoreNobodyMade() async throws {
		let identifier = UUID()
		let stores = WebKitDataStores.live

		let identifiers = await stores.identifiers()
		try await stores.remove(identifier)

		#expect(!identifiers.contains(identifier))
	}
}

@MainActor
private final class StoreLog {
	internal var made: [UUID] = []
	internal var removed: [UUID] = []
	internal var pagesWhenRemoved: [Int] = []
	internal var onDisk: [UUID] = []
	internal weak var pages: WebKitPages?

	internal var stores: WebKitDataStores {
		.init(
			make: { [self] identifier in
				made.append(identifier)
				return .nonPersistent()
			},
			identifiers: { [self] in onDisk },
			remove: { [self] identifier in
				removed.append(identifier)
				pagesWhenRemoved.append(pages?.tabIDs.count ?? -1)
			}
		)
	}
}

extension WebKitDataStores {
	/// Non-persistent stores in place of the profile's, so tests write nothing to disk.
	internal static var inMemory: Self {
		.init(make: { _ in .nonPersistent() }, identifiers: { [] }, remove: { _ in })
	}
}
