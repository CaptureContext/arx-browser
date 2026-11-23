import BrowserCore
import BrowserDownloadsClient
import CustomDump
import DownloadsFeature
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct DownloadsFeatureTests {
	@Test
	internal func privateTransfersRequireExplicitFilterAndNeverAppearInAllProfiles() async {
		let ordinary = record()
		var other = ordinary
		other.id.profileID = .init(rawValue: UUID())
		var privateRecord = ordinary
		privateRecord.id.guid = "private"
		privateRecord.isPrivate = true
		var initial = DownloadsFeature.State(profileID: ordinary.id.profileID)
		initial.queue = .init(
			downloads: [ordinary, other, privateRecord],
			privateDownloads: [privateRecord]
		)
		let store = TestStore(initialState: initial) { DownloadsFeature() }
		expectNoDifference(store.state.visibleDownloads, [ordinary])
		await store.send(.ui(.filterChanged(.allProfiles))) { $0.filter = .allProfiles }
		expectNoDifference(store.state.visibleDownloads, [ordinary, other])
		await store.send(.ui(.filterChanged(.privateTransfers))) { $0.filter = .privateTransfers }
		expectNoDifference(store.state.visibleDownloads, [privateRecord])
	}

	@Test
	internal func appliesProgressAndTerminalStatesFromServiceOnly() async {
		var value = record()
		let store = TestStore(initialState: DownloadsFeature.State(profileID: value.id.profileID)) {
			DownloadsFeature()
		}
		for status in [BrowserDownload.Status.inProgress, .complete, .interrupted, .cancelled] {
			value.status = status
			value.receivedBytes += 10
			let queue = DownloadQueue(downloads: [value])
			await store.send(.event(.queueChanged(queue))) { $0.queue = queue }
		}
	}

	@Test
	internal func cancelRequestsNativeActionWithoutInventingCompletion() async {
		let value = record()
		var cancelled: [BrowserDownload.ID] = []
		var initial = DownloadsFeature.State(profileID: value.id.profileID)
		initial.queue = .init(downloads: [value])
		let store = TestStore(initialState: initial) { DownloadsFeature() } withDependencies: {
			$0.browserDownloads.cancel = { cancelled.append($0) }
		}
		await store.send(.ui(.cancel(value.id)))
		await store.finish()
		expectNoDifference(cancelled, [value.id])
		expectNoDifference(store.state.queue.downloads, [value])
	}

	@Test
	internal func ignoresActionsForHiddenOrUnsafeRecords() async {
		var value = record()
		value.isPrivate = true
		var initial = DownloadsFeature.State(profileID: value.id.profileID)
		initial.queue = .init(privateDownloads: [value])
		let store = TestStore(initialState: initial) { DownloadsFeature() } withDependencies: {
			$0.browserDownloads.cancel = { _ in Issue.record("Hidden private transfer was cancelled") }
			$0.browserDownloads.open = { _ in Issue.record("Incomplete file was opened") }
		}
		await store.send(.ui(.cancel(value.id)))
		await store.send(.ui(.filterChanged(.privateTransfers))) { $0.filter = .privateTransfers }
		await store.send(.ui(.open(value.id)))
		await store.finish()
	}

	@Test
	internal func exposesFileOpenFailure() async {
		var value = record()
		value.status = .complete
		value.target = URL(filePath: "/tmp/moved.txt")
		var initial = DownloadsFeature.State(profileID: value.id.profileID)
		initial.queue = .init(downloads: [value])
		let store = TestStore(initialState: initial) { DownloadsFeature() } withDependencies: {
			$0.browserDownloads.open = { _ in throw BrowserDownloadsClient.Failure.fileMissing }
		}
		await store.send(.ui(.open(value.id)))
		await store.receive(\.event.operationFailed) {
			$0.message = BrowserDownloadsClient.Failure.fileMissing.localizedDescription
		}
		await store.finish()
	}

	@Test
	internal func dismissingObservationDoesNotCancelTransfers() async {
		let value = record()
		let (stream, continuation) = AsyncStream<DownloadQueue>.makeStream()
		var initial = DownloadsFeature.State(profileID: value.id.profileID)
		initial.isPresented = true
		let store = TestStore(initialState: initial) { DownloadsFeature() } withDependencies: {
			$0.browserDownloads.events = { stream }
			$0.browserDownloads.cancel = { _ in Issue.record("Dismissal cancelled a transfer") }
			$0.browserDownloads.cancelAll = { Issue.record("Dismissal cancelled all transfers") }
		}
		await store.send(.ui(.appeared))
		continuation.yield(.init(downloads: [value]))
		await store.receive(\.event.queueChanged) { $0.queue = .init(downloads: [value]) }
		await store.send(.ui(.dismissed)) { $0.isPresented = false }
		await store.finish()
		#expect(store.state.queue.activeCount == 1)
	}

	/// DEV-770: profiles picked in the filter pane show as header chips, and removing a chip there
	/// narrows the list back, to the current profile once none is left.
	@Test
	internal func profileFiltersAreAddedInThePaneAndRemovedFromTheHeader() async {
		let current = record()
		var work = current
		work.id = .init(profileID: .init(rawValue: UUID()), guid: "work")
		var home = current
		home.id = .init(profileID: .init(rawValue: UUID()), guid: "home")
		var initial = DownloadsFeature.State(profileID: current.id.profileID)
		initial.queue = .init(downloads: [current, work, home])
		let store = TestStore(initialState: initial) { DownloadsFeature() }

		await store.send(.ui(.filterPaneToggled)) { $0.isFilterPanePresented = true }
		await store.send(.ui(.profileFilterToggled(work.id.profileID))) {
			$0.profileFilter = [work.id.profileID]
			$0.filter = .allProfiles
		}
		await store.send(.ui(.profileFilterToggled(home.id.profileID))) {
			$0.profileFilter = [work.id.profileID, home.id.profileID]
		}
		await store.send(.ui(.filterPaneDismissed)) { $0.isFilterPanePresented = false }
		expectNoDifference(store.state.activeFilterCount, 2)
		expectNoDifference(Set(store.state.visibleDownloads.map(\.id)), [work.id, home.id])

		await store.send(.ui(.profileFilterRemoved(work.id.profileID))) {
			$0.profileFilter = [home.id.profileID]
		}
		expectNoDifference(store.state.visibleDownloads, [home])

		await store.send(.ui(.profileFilterRemoved(home.id.profileID))) {
			$0.profileFilter = []
			$0.filter = .currentProfile
		}
		expectNoDifference(store.state.activeFilterCount, 0)
		expectNoDifference(store.state.visibleDownloads, [current])
	}

	@Test
	internal func privateTransfersReplaceProfileFiltersAndToggleBack() async {
		let ordinary = record()
		var privateRecord = ordinary
		privateRecord.id.guid = "private"
		privateRecord.isPrivate = true
		var initial = DownloadsFeature.State(profileID: ordinary.id.profileID)
		initial.queue = .init(downloads: [ordinary], privateDownloads: [privateRecord])
		let store = TestStore(initialState: initial) { DownloadsFeature() }

		await store.send(.ui(.profileFilterToggled(ordinary.id.profileID))) {
			$0.profileFilter = [ordinary.id.profileID]
			$0.filter = .allProfiles
		}
		await store.send(.ui(.privateTransfersToggled)) {
			$0.profileFilter = []
			$0.filter = .privateTransfers
		}
		expectNoDifference(store.state.activeFilterCount, 1)
		expectNoDifference(store.state.visibleDownloads, [privateRecord])

		// Picking a profile leaves private transfers.
		await store.send(.ui(.profileFilterToggled(ordinary.id.profileID))) {
			$0.profileFilter = [ordinary.id.profileID]
			$0.filter = .allProfiles
		}
		await store.send(.ui(.filterChanged(.privateTransfers))) {
			$0.profileFilter = []
			$0.filter = .privateTransfers
		}

		// The header chip removes it.
		await store.send(.ui(.privateTransfersToggled)) { $0.filter = .currentProfile }
		expectNoDifference(store.state.visibleDownloads, [ordinary])
	}

	/// DEV-758: the Library button lists its window's profile, so its rows open whatever the panel filters.
	@Test
	internal func recentRowsOpenOutsideThePanelsFilter() async {
		var value = record()
		value.status = .complete
		value.target = URL(filePath: "/tmp/report.txt")
		var unsafe = value
		unsafe.id.guid = "unsafe"
		unsafe.isDangerous = true
		var initial = DownloadsFeature.State(profileID: .init(rawValue: UUID()))
		initial.queue = .init(downloads: [value, unsafe])
		var opened: [BrowserDownload.ID] = []
		let store = TestStore(initialState: initial) { DownloadsFeature() } withDependencies: {
			$0.browserDownloads.open = { opened.append($0) }
		}
		#expect(store.state.visibleDownloads.isEmpty)
		await store.send(.ui(.openRecent(value.id)))
		await store.send(.ui(.openRecent(unsafe.id)))
		await store.finish()
		#expect(opened == [value.id])
	}

	/// DEV-758 review: the recent rows have closed by the time a file fails to open, so the failure goes
	/// to the parent to show rather than into the panel's message.
	@Test
	internal func recentRowFailuresGoToTheParent() async {
		var value = record()
		value.status = .complete
		value.target = URL(filePath: "/tmp/moved.txt")
		var initial = DownloadsFeature.State(profileID: value.id.profileID)
		initial.queue = .init(downloads: [value])
		let store = TestStore(initialState: initial) { DownloadsFeature() } withDependencies: {
			$0.browserDownloads.open = { _ in throw BrowserDownloadsClient.Failure.fileMissing }
		}
		await store.send(.ui(.openRecent(value.id)))
		await store.receive(\.delegate.recentOpenFailed, BrowserDownloadsClient.Failure.fileMissing.localizedDescription)
		await store.finish()
	}

	private func record() -> BrowserDownload {
		.init(
			id: .init(profileID: .init(rawValue: UUID()), guid: "download"),
			profileName: "Work",
			filename: "report.txt",
			status: .inProgress,
			startedAt: Date(timeIntervalSince1970: 100)
		)
	}
}
