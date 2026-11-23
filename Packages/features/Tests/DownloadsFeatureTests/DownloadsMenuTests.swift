import BrowserCore
import BrowserDownloadsClient
import CustomDump
import DownloadsFeature
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// Pause and resume, Copy Link, Remove from List and Move to Trash (DEV-892).
@Suite(.dependencies)
@MainActor
internal struct DownloadsMenuTests {
	@Test
	internal func pauseAndResumeOnlyWhenTheEngineOffersThem() async {
		var running = record()
		running.canPause = true
		var paused = record(guid: "paused")
		paused.isPaused = true
		paused.canResume = true
		var interrupted = record(guid: "interrupted")
		interrupted.status = .interrupted
		let calls = LockIsolated<[String]>([])
		let store = TestStore(initialState: state(running, paused, interrupted)) { DownloadsFeature() } withDependencies: {
			$0.browserDownloads.setPaused = { id, isPaused in calls.withValue { $0.append(id.guid + (isPaused ? " pause" : " resume")) } }
		}

		await store.send(.ui(.pause(running.id)))
		await store.send(.ui(.resume(paused.id)))

		// Not resumable: the engine said Chromium can't continue it.
		await store.send(.ui(.resume(interrupted.id)))
		await store.send(.ui(.pause(paused.id)))
		await store.finish()
		expectNoDifference(calls.value, ["download pause", "paused resume"])
	}

	@Test
	internal func copyLinkHandsTheSourceToTheParent() async throws {
		var download = record()
		download.url = URL(string: "https://example.com/file.zip")
		var noLink = record(guid: "blob")
		noLink.url = URL(string: "blob:https://example.com/1")
		let store = TestStore(initialState: state(download, noLink)) { DownloadsFeature() }

		await store.send(.ui(.copyLink(download.id)))
		await store.receive(\.delegate.copyLink, try #require(download.url))
		await store.send(.ui(.copyLink(noLink.id)))
	}

	@Test
	internal func removeFromListAndMoveToTrashOnlyForFinishedDownloads() async {
		let running = record()
		var finished = record(guid: "finished")
		finished.status = .complete
		finished.target = URL(filePath: "/tmp/report.txt")
		var privateFinished = finished
		privateFinished.id.guid = "private"
		privateFinished.isPrivate = true
		let removed = LockIsolated<[BrowserDownload.ID]>([])
		let trashed = LockIsolated<[BrowserDownload.ID]>([])
		var initial = state(running, finished)
		initial.queue.privateDownloads = [privateFinished]
		let store = TestStore(initialState: initial) { DownloadsFeature() } withDependencies: {
			$0.browserDownloads.removeFromList = { id in removed.withValue { $0.append(id) } }
			$0.browserDownloads.moveToTrash = { id in trashed.withValue { $0.append(id) } }
		}

		await store.send(.ui(.removeFromList(running.id)))
		await store.send(.ui(.removeFromList(finished.id)))
		await store.send(.ui(.moveToTrash(running.id)))
		await store.send(.ui(.moveToTrash(finished.id)))
		await store.send(.ui(.filterChanged(.privateTransfers))) { $0.filter = .privateTransfers }
		await store.send(.ui(.removeFromList(privateFinished.id)))
		await store.finish()
		expectNoDifference(removed.value, [finished.id])
		expectNoDifference(trashed.value, [finished.id])
	}

	@Test
	internal func failuresShowTheirMessage() async {
		var running = record()
		running.canPause = true
		let store = TestStore(initialState: state(running)) { DownloadsFeature() } withDependencies: {
			$0.browserDownloads.setPaused = { _, _ in throw BrowserDownloadsClient.Failure.notResumable }
		}

		await store.send(.ui(.pause(running.id)))
		await store.receive(\.event.operationFailed) {
			$0.message = BrowserDownloadsClient.Failure.notResumable.errorDescription
		}
	}

	@Test
	internal func pauseStateIsNeverSaved() throws {
		var download = record()
		download.isPaused = true
		download.canResume = true
		download.canPause = true
		let data = try JSONEncoder().encode(download)
		let text = String(decoding: data, as: UTF8.self)
		#expect(!text.contains("isPaused") && !text.contains("canResume") && !text.contains("canPause"))
		let decoded = try JSONDecoder().decode(BrowserDownload.self, from: data)
		#expect(!decoded.isPaused && !decoded.canResume && !decoded.canPause)
		expectNoDifference(decoded.id, download.id)
	}

	private let profileID: Profile.ID = .init(rawValue: UUID())

	private func state(_ downloads: BrowserDownload...) -> DownloadsFeature.State {
		var state = DownloadsFeature.State(profileID: profileID)
		state.queue = .init(downloads: downloads)
		return state
	}

	private func record(guid: String = "download") -> BrowserDownload {
		.init(
			id: .init(profileID: profileID, guid: guid),
			profileName: "Work",
			filename: "report.txt",
			status: .inProgress,
			startedAt: Date(timeIntervalSince1970: 100)
		)
	}
}
