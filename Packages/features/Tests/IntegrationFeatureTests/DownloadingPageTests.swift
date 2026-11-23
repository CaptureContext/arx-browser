import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import CustomDump
import Foundation
import Testing
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

/// DEV-1116: a navigation that becomes a download is no page error. A tab with a page keeps it;
/// one with nothing to keep shows the transfer.
@Suite(.dependencies)
@MainActor
internal struct DownloadingPageTests {
	private static let fileURL: URL = URL(string: "https://files.capturecontext.dev/report.pdf")!

	private static func record(
		_ tab: BrowserCore.Tab,
		guid: String = "transfer",
		status: BrowserDownload.Status = .inProgress
	) -> BrowserDownload {
		.init(
			id: .init(profileID: tab.profileID, guid: guid),
			profileName: "Personal",
			url: fileURL,
			filename: "report.pdf",
			status: status,
			receivedBytes: 512,
			totalBytes: 2048,
			startedAt: Date(timeIntervalSince1970: 1_000),
			sourceTabID: tab.id
		)
	}

	private static func became(_ record: BrowserDownload) -> BrowserNavigation {
		.init(download: .init(id: record.id, filename: record.filename))
	}

	@Test
	internal func aTabWithNoPageShowsTheTransferItsNavigationBecame() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let record = Self.record(tab)
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab, generation: 3)) {
			ViewerItemFeature()
		} withDependencies: {
			// The engine names a transfer only once the queue has it.
			$0.browserDownloads.snapshot = { .init(downloads: [record]) }
		}
		store.exhaustivity = .off

		await store.send(.event(.navigation(tab.id, 3, Self.became(record))))
		#expect(store.state.failure == nil)
		await store.receive(\.event.downloadsRead)
		#expect(store.state.removedDownloadID == nil)
		#expect(store.state.download == nil)

		await store.send(.event(.downloads(tab.id, 3, [record])))
		expectNoDifference(store.state.download, record)

		var finished = record
		finished.status = .complete
		finished.receivedBytes = 2048
		await store.send(.event(.downloads(tab.id, 3, [finished])))
		expectNoDifference(store.state.download, finished)
	}

	/// A queue read that arrives after a newer queue update never undoes it.
	@Test
	internal func aLateQueueReadLeavesNewerUpdatesAlone() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		var record = Self.record(tab)
		record.status = .complete
		var initial = ViewerItemFeature.State(tab: tab, navigation: Self.became(record), generation: 3)
		initial.tabDownloads = [record]
		let store = TestStore(initialState: initial) { ViewerItemFeature() }

		await store.send(.event(.downloadsRead(tab.id, 3, [])))
		await store.send(.event(.downloadsRead(tab.id, 3, [Self.record(tab)])))
	}

	@Test
	internal func aTabShowingAPageKeepsItAndShowsNoTransfer() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let record = Self.record(tab)
		let page = BrowserNavigation(url: URL(string: "https://capturecontext.dev/files"), title: "Files")
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab, generation: 3)) {
			ViewerItemFeature()
		}
		store.exhaustivity = .off

		await store.send(.event(.navigation(tab.id, 3, page)))
		await store.send(.event(.downloads(tab.id, 3, [record])))

		expectNoDifference(store.state.navigation, page)
		#expect(store.state.download == nil)
		#expect(store.state.failure == nil)
	}

	@Test
	internal func anOlderObservationsTransfersAreIgnored() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let record = Self.record(tab)
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab, generation: 3)) {
			ViewerItemFeature()
		}

		await store.send(.event(.downloads(tab.id, 2, [record])))
		await store.send(.event(.downloads(BrowserCore.Tab.ID(rawValue: UUID()), 3, [record])))
	}

	@Test
	internal func showingATabFollowsOnlyItsOwnTransfers() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let mine = Self.record(tab)
		var other = Self.record(tab, guid: "other")
		other.sourceTabID = BrowserCore.Tab.ID(rawValue: UUID())
		let store = TestStore(initialState: ViewerItemFeature.State()) { ViewerItemFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in AsyncStream { $0.finish() } }
			$0.browserDownloads.events = {
				AsyncStream { continuation in
					continuation.yield(.init())
					continuation.yield(.init(downloads: [other]))
					continuation.yield(.init(downloads: [mine, other]))
					continuation.finish()
				}
			}
		}
		store.exhaustivity = .off

		await store.send(.show(tab))

		// The first queue always arrives, so a stale observation stops itself.
		await store.receive(\.event.downloads)
		await store.receive(\.event.downloads) {
			$0.tabDownloads = [mine]
		}
		await store.finish()
	}

	@Test
	internal func theDownloadingPagesButtonsActOnTheShownTransfer() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let record = Self.record(tab)
		var initial = ViewerItemFeature.State(tab: tab, navigation: Self.became(record), generation: 3)
		initial.tabDownloads = [record]
		let calls = LockIsolated<[String]>([])
		let store = TestStore(initialState: initial) { ViewerItemFeature() } withDependencies: {
			$0.browserDownloads.cancel = { id in calls.withValue { $0.append("cancel \(id.guid)") } }
			$0.browserDownloads.open = { id in calls.withValue { $0.append("open \(id.guid)") } }
			$0.browserDownloads.reveal = { id in calls.withValue { $0.append("reveal \(id.guid)") } }
			$0.browserDownloads.setPaused = { id, paused in
				calls.withValue { $0.append("paused \(paused) \(id.guid)") }
			}
			$0.browserEngine.command = { id, command in
				calls.withValue { $0.append("command \(id == tab.id) \(command)") }
			}
		}
		store.exhaustivity = .off

		await store.send(.ui(.download(.cancel)))
		await store.send(.ui(.download(.reveal)))
		await store.send(.ui(.download(.open)))
		await store.send(.ui(.download(.resume)))
		await store.send(.ui(.download(.retry)))
		await store.receive(\.ui.command)
		await store.finish()

		expectNoDifference(calls.value, [
			"cancel transfer",
			"reveal transfer",
			"open transfer",
			"paused false transfer",
			"command true \(BrowserEngineClient.Command.navigate(Self.fileURL))",
		])
	}

	@Test
	internal func aRemovedTransferKeepsItsLastRecordForRetry() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		var record = Self.record(tab)
		record.status = .complete
		var initial = ViewerItemFeature.State(tab: tab, navigation: Self.became(record), generation: 3)
		initial.tabDownloads = [record]
		let store = TestStore(initialState: initial) { ViewerItemFeature() }

		await store.send(.event(.downloads(tab.id, 3, []))) {
			$0.tabDownloads = []
			$0.removedDownloadID = record.id
			$0.removedDownload = record
		}
		#expect(store.state.download == nil)
	}

	/// Removed while the tab wasn't shown: the queue read after the navigation names it says so.
	@Test
	internal func aTransferRemovedWhileHiddenIsRecognizedWhenShownAgain() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let record = Self.record(tab)
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab, generation: 3)) {
			ViewerItemFeature()
		} withDependencies: {
			$0.browserDownloads.snapshot = { .init() }
		}

		await store.send(.event(.navigation(tab.id, 3, Self.became(record)))) {
			$0.navigation = Self.became(record)
		}
		await store.receive(\.delegate.navigation)
		await store.receive(\.event.downloadsRead) {
			$0.removedDownloadID = record.id
		}
	}

	@Test
	internal func aFailedActionSaysWhy() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		var record = Self.record(tab)
		record.status = .complete
		var initial = ViewerItemFeature.State(tab: tab, navigation: Self.became(record), generation: 3)
		initial.tabDownloads = [record]
		let store = TestStore(initialState: initial) { ViewerItemFeature() } withDependencies: {
			$0.browserDownloads.open = { _ in throw BrowserDownloadsClient.Failure.couldNotOpen }
			$0.browserEngine.command = { _, _ in }
		}

		await store.send(.ui(.download(.open)))
		await store.receive(\.event.downloadActionFailed) {
			$0.downloadMessage = BrowserDownloadsClient.Failure.couldNotOpen.localizedDescription
		}
		await store.send(.ui(.download(.retry))) {
			$0.downloadMessage = nil
		}
		await store.receive(\.ui.command)
	}
}
