@testable import AppFeature
import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import BrowserHistoryClient
import Clocks
import CustomDump
import Foundation
import Testing
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

/// DEV-1116: a tab whose only navigation became a download has nothing committed. It's no
/// visit, and its Downloading page still learns when the transfer leaves the list.
@MainActor
internal struct DownloadNavigationTests {
	private static let fileURL: URL = URL(string: "https://files.capturecontext.dev/report.pdf")!

	private static func record(_ tab: BrowserCore.Tab) -> BrowserDownload {
		.init(
			id: .init(profileID: tab.profileID, guid: "transfer"),
			profileName: "Personal",
			url: fileURL,
			filename: "report.pdf",
			status: .complete,
			receivedBytes: 2048,
			totalBytes: 2048,
			startedAt: Date(timeIntervalSince1970: 1_000),
			sourceTabID: tab.id
		)
	}

	/// The file's address stays in a tab that committed nothing, with no error: history
	/// records no visit, and no page text is read.
	@Test
	internal func aTabWithNothingCommittedIsNoVisit() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let profile = organization.profiles[0].id
		let tab = organization.tabs[0]
		state.main.viewer.item.tab = tab
		state.history.snapshots[profile] = .init(profileID: profile)
		state.history.knownProfiles = Set(organization.profiles.map(\.id))
		let clock = TestClock()
		let visits = LockIsolated<[URL]>([])
		let reads = LockIsolated(0)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.continuousClock = clock
			$0.browserHistory = .init(record: { profile, visit in
				visits.withValue { $0.append(visit.url) }
				return .init(snapshot: .init(profileID: profile))
			})
			$0.browserEngine.evaluateScript = { _, _, _, _, _ in
				reads.withValue { $0 += 1 }
				return .value(#"{"url":"https://files.capturecontext.dev/report.pdf","text":"%PDF"}"#)
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let downloading = BrowserNavigation(url: Self.fileURL, title: "", hasNoPage: true)
		await store.send(.main(.viewer(.item(.delegate(.navigation(tab.id, downloading))))))
		await clock.advance(by: ProfileHistory.pageTextDelay)
		await store.finish()
		expectNoDifference(visits.value, [])
		#expect(reads.value == 0)

		// The same address once a page committed there is a visit.
		let page = BrowserNavigation(url: Self.fileURL, title: "Report")
		await store.send(.main(.viewer(.item(.delegate(.navigation(tab.id, page))))))
		await clock.advance(by: ProfileHistory.pageTextDelay)
		await store.finish()
		expectNoDifference(visits.value, [Self.fileURL])
	}

	/// The queue keeps only its newest update for an item, so it can skip every one that had
	/// the shown transfer. A queue without it then reads the list again before saying it's gone.
	@Test
	internal func aQueueThatSkippedTheTransferReadsTheListBeforeCallingItRemoved() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let record = Self.record(tab)
		let navigation = BrowserNavigation(download: .init(id: record.id, filename: record.filename))
		let listed = LockIsolated<[BrowserDownload]>([record])
		let store = TestStore(
			initialState: ViewerItemFeature.State(tab: tab, navigation: navigation, generation: 3)
		) {
			ViewerItemFeature()
		} withDependencies: {
			$0.browserDownloads.snapshot = { .init(downloads: listed.value) }
		}

		// An older update, from before the queue had it: the list still has it.
		await store.send(.event(.downloads(tab.id, 3, [])))
		await store.receive(\.event.downloadsRead)
		#expect(store.state.removedDownloadID == nil)

		// Removed from the list before this item saw it.
		listed.setValue([])
		await store.send(.event(.downloads(tab.id, 3, [])))
		await store.receive(\.event.downloadsRead) {
			$0.removedDownloadID = record.id
		}

		// Once it's known to be gone, an empty queue reads nothing more.
		await store.send(.event(.downloads(tab.id, 3, [])))
	}
}
