import AppKit
import BrowserCore
import BrowserDownloadsClient
import ChromiumBridge
import CustomDump
import Foundation
import Testing
import _TestSupport

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

/// DEV-1116: a tab the engine opened straight to a file shows the transfer its navigation
/// became, even when its current history entry carries the file's address. Only a committed
/// document, which the engine reports itself, is a page to keep, and the `about:blank` the
/// engine opens every fresh page at isn't the tab's own.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumDownloadingTabTests {
	@Test
	internal func aTabOpenedToAFileShowsItsTransferWhateverItsCurrentEntrySays() async throws {
		let fixture = DownloadingTabFixture(document: ARX_PAGE_DOCUMENT_NONE)
		try fixture.start()
		defer { fixture.stop() }
		try await fixture.open()

		// Chromium ended the navigation that became the download without committing it, and
		// the tab's current entry has the file's address.
		fixture.publish(error: Int32(ChromiumPage.abortedErrorCode))
		#expect(fixture.page?.navigation.history.first(where: \.isCurrent)?.url == DownloadingTabFixture.address)

		fixture.download(state: 0)
		let shown = try await fixture.shownDownload()
		expectNoDifference(shown, .init(id: fixture.downloadID, filename: "report.bin"))

		fixture.download(state: 1)
		try await fixture.settle()
		let navigation = try #require(fixture.engine.client.snapshot(fixture.tab.id)?.navigation)
		expectNoDifference(navigation.download, .init(id: fixture.downloadID, filename: "report.bin"))
		expectNoDifference(navigation.errorCode, nil)

		// Nothing committed: the file's address is no page visit.
		#expect(navigation.hasNoPage)
	}

	/// The app smoke's case: the engine opens every fresh page at `about:blank`, which commits
	/// as an ordinary entry, so the document type is a web page. While that's still the tab's
	/// only entry, the tab has nothing of its own and shows its transfer.
	@Test
	internal func aTabStillAtTheBlankPageItOpenedWithShowsItsTransfer() async throws {
		let fixture = DownloadingTabFixture(document: ARX_PAGE_DOCUMENT_WEB, history: [DownloadingTabFixture.blank])
		try fixture.start()
		defer { fixture.stop() }
		try await fixture.open()
		fixture.publish(error: Int32(ChromiumPage.abortedErrorCode))

		fixture.download(state: 0)
		let shown = try await fixture.shownDownload()
		expectNoDifference(shown, .init(id: fixture.downloadID, filename: "report.bin"))

		fixture.download(state: 1)
		try await fixture.settle()
		let navigation = try #require(fixture.engine.client.snapshot(fixture.tab.id)?.navigation)
		expectNoDifference(navigation.download, .init(id: fixture.downloadID, filename: "report.bin"))
		expectNoDifference(navigation.errorCode, nil)
		#expect(navigation.hasNoPage)

		// Once a page of its own commits after it, the tab keeps that page.
		DownloadingTabFixture.entries = [DownloadingTabFixture.blank, DownloadingTabFixture.address]
		fixture.publish(error: 0, title: "Report")
		let committed = try #require(fixture.engine.client.snapshot(fixture.tab.id)?.navigation)
		expectNoDifference(committed.download, nil)
		#expect(!committed.hasNoPage)
	}

	/// A page's colors can change alone while its tab shows the transfer: observers still hear
	/// the transfer, since the app replaces its navigation with every snapshot it hears.
	@Test
	internal func aColorOnlyUpdateKeepsTheTransfer() async throws {
		let fixture = DownloadingTabFixture(document: ARX_PAGE_DOCUMENT_NONE)
		try fixture.start()
		defer { fixture.stop() }
		try await fixture.open()
		var events = fixture.engine.client.events(fixture.tab.id).makeAsyncIterator()
		fixture.publish(error: Int32(ChromiumPage.abortedErrorCode))
		fixture.download(state: 1)
		try await fixture.settle()
		_ = try await fixture.shownDownload()

		DownloadingTabFixture.colors = .init(
			theme_color: 0xFF20_4060,
			background_color: 0xFFFF_FFFF,
			has_theme_color: true,
			has_background_color: true
		)
		fixture.publish(error: Int32(ChromiumPage.abortedErrorCode))
		let colors = PageColors(themeARGB: 0xFF20_4060, backgroundARGB: 0xFFFF_FFFF)
		var recolored: BrowserNavigation?
		while let navigation = await events.next() {
			if navigation.colors == colors {
				recolored = navigation
				break
			}
		}
		let navigation = try #require(recolored)
		expectNoDifference(navigation.download, .init(id: fixture.downloadID, filename: "report.bin"))
		#expect(navigation.hasNoPage)
	}

	@Test
	internal func aTabWithACommittedPageKeepsIt() async throws {
		let fixture = DownloadingTabFixture(document: ARX_PAGE_DOCUMENT_WEB)
		try fixture.start()
		defer { fixture.stop() }
		try await fixture.open()
		fixture.publish(error: 0)

		fixture.download(state: 1)
		try await fixture.settle()
		let navigation = try #require(fixture.engine.client.snapshot(fixture.tab.id)?.navigation)
		expectNoDifference(navigation.download, nil)
		#expect(!navigation.hasNoPage)
	}

	@Test
	internal func aPageThatCommitsLaterForgetsTheTransfer() async throws {
		let fixture = DownloadingTabFixture(document: ARX_PAGE_DOCUMENT_NONE)
		try fixture.start()
		defer { fixture.stop() }
		try await fixture.open()
		fixture.publish(error: Int32(ChromiumPage.abortedErrorCode))
		fixture.download(state: 1)
		_ = try await fixture.shownDownload()

		DownloadingTabFixture.document = ARX_PAGE_DOCUMENT_WEB
		fixture.publish(error: 0, title: "Report")
		let navigation = try #require(fixture.engine.client.snapshot(fixture.tab.id)?.navigation)
		expectNoDifference(navigation.download, nil)
	}

	@Test
	internal func nothingCommittedIsNoPageUnlessASiteWroteABlankDocument() {
		#expect(ChromiumBrowserEngine.hasNoPage(committed: false, current: nil))
		#expect(ChromiumBrowserEngine.hasNoPage(committed: false, current: DownloadingTabFixture.address))
		// Chromium keeps a written popup's about:blank document on its initial entry.
		#expect(!ChromiumBrowserEngine.hasNoPage(committed: false, current: URL(string: "about:blank")!))
		#expect(!ChromiumBrowserEngine.hasNoPage(committed: true, current: DownloadingTabFixture.address))
		#expect(!ChromiumBrowserEngine.hasNoPage(committed: true, current: nil))
	}

	/// Only the one `about:blank` a fresh page starts at; a site's own `about:blank` after a
	/// page, or a page alone, is history of its own.
	@Test
	internal func onlyTheOpeningBlankPageIsStillTheStart() {
		let blank = DownloadingTabFixture.blank
		let page = DownloadingTabFixture.address
		#expect(ChromiumBrowserEngine.isStillAtItsStart([blank]))
		#expect(!ChromiumBrowserEngine.isStillAtItsStart([]))
		#expect(!ChromiumBrowserEngine.isStillAtItsStart([page]))
		#expect(!ChromiumBrowserEngine.isStillAtItsStart([blank, page]))
		#expect(!ChromiumBrowserEngine.isStillAtItsStart([page, blank]))
	}
}

@MainActor
private final class DownloadingTabFixture {
	fileprivate static let address: URL = URL(string: "https://files.test/report.bin")!
	fileprivate static var callbacks: ArxEngineCallbacks?
	fileprivate static var document: ArxPageDocumentType = ARX_PAGE_DOCUMENT_NONE
	fileprivate static var colors: ArxPageColors = .init()
	fileprivate static let blank: URL = URL(string: "about:blank")!
	private static let page: UInt64 = 31
	private static let view: NSView = .init()

	/// The tab's history, its last entry current. Borrowed by `history_entry` until its next
	/// call, as the engine's own strings are.
	fileprivate static var entries: [URL] = [address] {
		didSet { entryURLs = entries.map { strdup($0.absoluteString)! } }
	}
	private static var entryURLs: [UnsafeMutablePointer<CChar>] = [strdup(address.absoluteString)!]
	private static let entryTitle: UnsafeMutablePointer<CChar> = strdup("")!

	fileprivate let runtime: ChromiumRuntime
	fileprivate let engine: ChromiumBrowserEngine
	fileprivate let downloadID: BrowserDownload.ID
	fileprivate let tab: Tab = .init(
		id: .init(rawValue: UUID(41)),
		profileID: .init(rawValue: UUID(42)),
		restoration: .init(title: "Report", url: DownloadingTabFixture.address)
	)
	private let directory: URL
	private var downloads: BrowserDownloadsClient?

	fileprivate init(document: ArxPageDocumentType, history: [URL] = [address]) {
		Self.callbacks = nil
		Self.document = document
		Self.entries = history
		Self.colors = .init()
		directory = FileManager.default.temporaryDirectory.appending(path: "arx-downloading-tab-\(UUID())")
		downloadID = .init(profileID: tab.profileID, guid: "tab-download")
		var api = ArxEngineAPI()
		api.run = { _, _, callbacks in
			MainActor.assumeIsolated { DownloadingTabFixture.callbacks = callbacks?.pointee }
			return 0
		}
		api.create_page = { _, _ in DownloadingTabFixture.page }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { DownloadingTabFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.prepare_profile = { _, request in
			MainActor.assumeIsolated {
				guard let callbacks = DownloadingTabFixture.callbacks else { return }
				callbacks.profile_ready(callbacks.context, request, true)
			}
		}
		api.navigate = { _, _ in true }
		api.destroy_page = { _ in }
		api.history_count = { _ in MainActor.assumeIsolated { Int32(DownloadingTabFixture.entries.count) } }
		api.history_entry = { _, index, url, title, current in
			MainActor.assumeIsolated {
				let urls = DownloadingTabFixture.entryURLs
				guard index >= 0, Int(index) < urls.count else { return -1 }
				url?.pointee = UnsafePointer(urls[Int(index)])
				title?.pointee = UnsafePointer(DownloadingTabFixture.entryTitle)
				current?.pointee = Int(index) == urls.count - 1
				return Int32(index) + 1
			}
		}
		api.page_document_type = { _ in MainActor.assumeIsolated { DownloadingTabFixture.document } }
		api.page_colors = { _, colors in
			MainActor.assumeIsolated {
				colors?.pointee = DownloadingTabFixture.colors
				return true
			}
		}
		api.page_close_generation = { _ in 1 }
		api.request_authorized_close = { _, _, _ in }
		api.consume_authorized_close = { _, _, _ in ARX_CLOSE_STALE }
		api.cancel_authorized_close = { _, _ in }
		runtime = ChromiumRuntime(api: api)
		engine = ChromiumBrowserEngine(runtime: runtime, profileID: tab.profileID)
	}

	fileprivate var page: ChromiumPage? { runtime.pages[Self.page] }

	fileprivate func start() throws {
		// The injected C table starts no process and reads or writes neither URL.
		_ = try runtime.run(
			executable: URL(fileURLWithPath: "/tmp/arx-unit-test-no-executable"),
			profileDirectory: URL(fileURLWithPath: "/tmp/arx-unit-test-no-profile")
		) { _ in }
		runtime.didBecomeReady()
		downloads = engine.downloads(
			metadataFile: directory.appending(path: "downloads.json"),
			organization: .init(tabs: [tab])
		)
	}

	fileprivate func open() async throws { try await engine.client.open(tab) }

	fileprivate func publish(error: Int32, title: String = "") {
		guard let callbacks = Self.callbacks else { return }
		Self.address.absoluteString.withCString { url in
			title.withCString { title in
				callbacks.page_changed(callbacks.context, Self.page, url, title, false, false, false, error)
			}
		}
	}

	/// `state` is Chromium's: 0 in progress, 1 complete.
	fileprivate func download(state: Int32) {
		guard let callbacks = Self.callbacks else { return }
		"".withCString { profile in
			downloadID.guid.withCString { guid in
				Self.address.absoluteString.withCString { url in
					"report.bin".withCString { filename in
						var snapshot = ArxDownloadSnapshot(
							guid: guid,
							url: url,
							target_path: nil,
							filename: filename,
							source_page: Self.page,
							state: state,
							interrupt_reason: 0,
							received_bytes: state == 1 ? 24 : 12,
							total_bytes: 24,
							started_at: 100,
							dangerous: false,
							missing: false,
							private_context: false
						)
						callbacks.download_changed(callbacks.context, profile, &snapshot)
					}
				}
			}
		}
	}

	/// The transfer the tab shows, once the queue has passed it on.
	fileprivate func shownDownload() async throws -> BrowserNavigation.Download {
		for _ in 0..<1000 {
			if let shown = engine.client.snapshot(tab.id)?.navigation.download { return shown }
			await Task.yield()
		}
		throw AutomationFailure.timedOut
	}

	/// Lets the queue pass on what the engine reported.
	fileprivate func settle() async throws {
		for _ in 0..<1000 {
			if downloads?.snapshot().downloads.first?.status == .complete { break }
			await Task.yield()
		}
		guard downloads?.snapshot().downloads.first?.status == .complete else { throw AutomationFailure.timedOut }
		for _ in 0..<10 { await Task.yield() }
	}

	fileprivate func stop() {
		engine.closeAll()
		runtime.finish()
		Self.callbacks = nil
		try? FileManager.default.removeItem(at: directory)
	}
}
