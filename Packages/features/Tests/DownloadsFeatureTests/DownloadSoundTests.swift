import BrowserCore
import BrowserDownloadsClient
import CustomDump
import DownloadsFeature
import Foundation
import SoundFeedbackClient
import Testing
import _ComposableArchitecture
import _TestSupport

/// Which transfers make a sound (DEV-1256): a finished one plays `done`, a failed one `couldNot`,
/// and one the person cancelled, or one that was over before Arx started watching, nothing.
@Suite(.dependencies)
@MainActor
internal struct DownloadSoundTests {
	private let since: Date = .init(timeIntervalSince1970: 1_000)

	/// Feeds `snapshots` to the app's outcome watch and returns the sounds it asked for.
	private func sounds(
		for snapshots: [[BrowserDownload]]
	) async throws -> [SoundFeedback] {
		let sounds: LockIsolated<[SoundFeedback]> = .init([])
		let (stream, continuation) = AsyncStream<DownloadQueue>.makeStream()
		let store = TestStore(initialState: DownloadsFeature.State()) { DownloadsFeature() } withDependencies: {
			$0.browserDownloads.events = { stream }
			$0.date.now = since
			$0.soundFeedback = .init(
				play: { sound in sounds.withValue { $0.append(sound) } },
				pagesChanged: { _, _ in }
			)
		}

		await store.send(.soundOutcomes)
		for downloads in snapshots {
			continuation.yield(.init(downloads: downloads.filter { !$0.isPrivate }, privateDownloads: downloads))
		}
		continuation.finish()
		await store.finish()
		return sounds.value
	}

	private func download(
		_ guid: String,
		_ status: BrowserDownload.Status,
		interruptReason: Int = 0,
		startedAt: Date? = nil,
		isPrivate: Bool = false
	) -> BrowserDownload {
		.init(
			id: .init(profileID: .init(rawValue: UUID(0)), guid: guid),
			profileName: "Work",
			filename: "\(guid).zip",
			status: status,
			startedAt: startedAt ?? since.addingTimeInterval(1),
			interruptReason: interruptReason,
			isPrivate: isPrivate
		)
	}

	@Test
	internal func aFinishedDownloadPlaysDone() async throws {
		let sounds = try await sounds(for: [
			[download("a", .inProgress)],
			[download("a", .complete)],
		])
		expectNoDifference(sounds, [.done])
	}

	@Test
	internal func aPrivateDownloadThatFinishesPlaysDone() async throws {
		let sounds = try await sounds(for: [
			[download("a", .inProgress, isPrivate: true)],
			[download("a", .complete, isPrivate: true)],
		])
		expectNoDifference(sounds, [.done])
	}

	/// A small file can be over before the queue first shows it running.
	@Test
	internal func aDownloadFirstSeenFinishedPlaysDoneWhenItStartedSinceWatching() async throws {
		let sounds = try await sounds(for: [
			[],
			[download("a", .complete)],
		])
		expectNoDifference(sounds, [.done])
	}

	@Test
	internal func aFailedDownloadPlaysCouldNot() async throws {
		// FILE_FAILED (1) and NETWORK_FAILED (20).
		for reason in [1, 20] {
			let sounds = try await sounds(for: [
				[download("a", .inProgress)],
				[download("a", .interrupted, interruptReason: reason)],
			])
			expectNoDifference(sounds, [.couldNot])
		}
	}

	/// The queue keeps only its newest snapshot, so a resumed transfer can go from failed to
	/// finished with its running state never seen.
	@Test
	internal func aDownloadResumedAndFinishedBetweenSnapshotsPlaysDone() async throws {
		let earlier = since.addingTimeInterval(-60)
		let sounds = try await sounds(for: [
			[download("a", .interrupted, interruptReason: 20, startedAt: earlier)],
			[download("a", .complete, startedAt: earlier)],
		])
		expectNoDifference(sounds, [.done])
	}

	/// After a relaunch a saved transfer the engine no longer has turns from running to
	/// interrupted with no reason: nothing failed just now.
	@Test
	internal func aSavedDownloadARelaunchReconciledIsSilent() async throws {
		let earlier = since.addingTimeInterval(-60)
		let sounds = try await sounds(for: [
			[download("a", .inProgress, startedAt: earlier)],
			[download("a", .interrupted, interruptReason: 0, startedAt: earlier)],
		])
		expectNoDifference(sounds, [])
	}

	@Test
	internal func aDownloadThePersonCancelledIsSilent() async throws {
		let sounds = try await sounds(for: [
			[download("a", .inProgress), download("b", .inProgress), download("c", .inProgress)],
			[
				download("a", .cancelled),
				// USER_CANCELED, USER_SHUTDOWN and CRASH aren't failures to hear about.
				download("b", .interrupted, interruptReason: 40),
				download("c", .interrupted, interruptReason: 41),
			],
		])
		expectNoDifference(sounds, [])
	}

	/// History and transfers a relaunch reconciled are over already.
	@Test
	internal func downloadsOverBeforeWatchingAreSilent() async throws {
		let earlier = since.addingTimeInterval(-60)
		let sounds = try await sounds(for: [
			[
				download("a", .complete, startedAt: earlier),
				download("b", .interrupted, interruptReason: 20, startedAt: earlier),
			],
			[
				download("a", .complete, startedAt: earlier),
				download("b", .interrupted, interruptReason: 20, startedAt: earlier),
			],
		])
		expectNoDifference(sounds, [])
	}

	@Test
	internal func progressAndPausingAreSilentAndEachOutcomeSoundsOnce() async throws {
		var paused = download("a", .inProgress)
		paused.isPaused = true
		let sounds = try await sounds(for: [
			[download("a", .inProgress), download("b", .inProgress), download("c", .inProgress)],
			[paused, download("b", .inProgress), download("c", .inProgress)],
			[download("a", .complete), download("b", .complete), download("c", .complete)],
			[download("a", .complete), download("b", .complete), download("c", .complete)],
		])

		// The client turns repeats within two seconds into one sound; the watch asks once a snapshot.
		expectNoDifference(sounds, [.done])
	}

	@Test
	internal func aResumedDownloadThatFailsAgainSoundsAgain() async throws {
		let sounds = try await sounds(for: [
			[download("a", .inProgress)],
			[download("a", .interrupted, interruptReason: 20)],
			[download("a", .inProgress)],
			[download("a", .complete)],
		])
		expectNoDifference(sounds, [.couldNot, .done])
	}
}
