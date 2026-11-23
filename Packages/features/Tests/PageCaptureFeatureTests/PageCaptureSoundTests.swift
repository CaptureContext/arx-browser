import BrowserCaptureClient
import BrowserCore
import CustomDump
import Foundation
import PageCaptureFeature
import SoundFeedbackClient
import Testing
import _ComposableArchitecture
import _TestSupport

/// Which captures make a sound (DEV-1256): one that went to the clipboard or a file plays
/// `capture`, one that couldn't be taken or saved plays `couldNot`, and the rest stay silent.
@Suite(.dependencies)
@MainActor
internal struct PageCaptureSoundTests {
	private typealias Fixtures = PageCaptureFixtures

	private let sounds: LockIsolated<[SoundFeedback]> = .init([])

	private var recording: SoundFeedbackClient {
		.init(
			play: { [sounds] sound in sounds.withValue { $0.append(sound) } },
			pagesChanged: { _, _ in }
		)
	}

	private func captured() throws -> PageCaptureFeature.State {
		let frame = try Fixtures.frame()
		var state = Fixtures.state(phase: .captured)
		state.frame = frame
		state.image = frame.image
		state.selection = state.viewport
		return state
	}

	@Test
	internal func copyingPlaysCapture() async throws {
		let state = try captured()
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.pageCaptureExport.copy = { _ in }
			$0.soundFeedback = recording
		}

		await store.send(.ui(.copy)) { $0.isWorking = true }
		await store.receive(\.event.finished) { $0.isWorking = false }
		await store.receive(\.delegate.dismiss)
		expectNoDifference(sounds.value, [.capture])
	}

	@Test
	internal func savingPlaysCaptureAndCancelingTheSavePanelIsSilent() async throws {
		let destination: LockIsolated<URL?> = .init(URL(filePath: "/tmp/page.png"))
		let state = try captured()
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.pageCaptureExport.save = { _, _, _ in destination.value }
			$0.soundFeedback = recording
		}
		store.exhaustivity = .off

		destination.setValue(nil)
		await store.send(.ui(.save))
		await store.receive(\.event.saved)
		expectNoDifference(sounds.value, [])

		destination.setValue(URL(filePath: "/tmp/page.png"))
		await store.send(.ui(.save))
		await store.receive(\.event.saved)
		await store.receive(\.delegate.dismiss)
		expectNoDifference(sounds.value, [.capture])
	}

	/// Edit opens the picture in Preview, in plain sight.
	@Test
	internal func editingIsSilent() async throws {
		let state = try captured()
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.pageCaptureExport.edit = { _, _ in }
			$0.soundFeedback = recording
		}

		await store.send(.ui(.edit)) { $0.isWorking = true }
		await store.receive(\.event.finished) { $0.isWorking = false }
		await store.receive(\.delegate.dismiss)
		expectNoDifference(sounds.value, [])
	}

	@Test
	internal func aCaptureThatFailsPlaysCouldNot() async throws {
		let store = TestStore(initialState: Fixtures.state(phase: .selecting)) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.captureAuthorized = { _, _ in throw PageCaptureFailure.busy }
			$0.soundFeedback = recording
		}
		store.exhaustivity = .off

		await store.send(.capture(.init(x: 0, y: 0, width: 10, height: 10)))
		await store.receive(\.event.failed)
		await store.finish()
		expectNoDifference(sounds.value, [.couldNot])
	}

	@Test
	internal func aCopyThatFailsPlaysCouldNot() async throws {
		let state = try captured()
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.pageCaptureExport.copy = { _ in throw PageCaptureFailure.encodingFailed }
			$0.soundFeedback = recording
		}
		store.exhaustivity = .off

		await store.send(.ui(.copy))
		await store.receive(\.event.failed)
		await store.finish()
		expectNoDifference(sounds.value, [.couldNot])
	}

	/// A page that changed under the overlay is taken again quietly; only giving up is heard.
	@Test
	internal func aChangedPageIsRetakenQuietlyUntilArxGivesUp() async throws {
		let store = TestStore(initialState: Fixtures.state(phase: .selecting)) { PageCaptureFeature() } withDependencies: {
			$0.pageCaptureAuthorization.authorize = { _, _ in false }
			$0.soundFeedback = recording
		}
		store.exhaustivity = .off

		for attempt in 1...3 {
			await store.send(.capture(.init(x: 0, y: 0, width: 10, height: 10)))
			await store.receive(\.event.failed)
			if attempt <= PageCaptureFeature.maximumStaleRetries { await store.receive(\.delegate.retake) }
			await store.finish()
			expectNoDifference(sounds.value, attempt <= PageCaptureFeature.maximumStaleRetries ? [] : [.couldNot])
		}
	}
}
