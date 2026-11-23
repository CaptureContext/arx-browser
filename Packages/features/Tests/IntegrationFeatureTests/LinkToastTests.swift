@testable import AppFeature
import BrowserCore
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// The copy-link toast (DEV-769): it stays about 2.5 s once shown, waits while the pointer is
/// over it, and offers the original link when cleaning changed the copied one.
extension IntegrationFeatureTests {
	@Test
	internal func linkToastExpiresAfterItsDurationOnceShown() async throws {
		let clock: TestClock<Duration> = .init()
		let (state, feedback) = try toastState()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
		}

		await store.send(.ui(.linkFeedbackShown))
		await clock.advance(by: .seconds(2))
		await clock.advance(by: .milliseconds(500))
		await store.receive(\.event.linkFeedbackExpired) {
			$0.linkActionFeedback = nil
		}
		#expect(feedback.title == "Copied Clean Link")
	}

	@Test
	internal func hoveringHoldsTheLinkToastUntilThePointerLeaves() async throws {
		let clock: TestClock<Duration> = .init()
		let (state, _) = try toastState()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
		}

		await store.send(.ui(.linkFeedbackShown))
		await clock.advance(by: .seconds(2))
		await store.send(.ui(.linkFeedbackHovered(true))) {
			$0.linkFeedbackIsHovered = true
		}

		// Held however long the pointer stays, and not restarted by new feedback meanwhile.
		await clock.advance(by: .seconds(30))
		await store.send(.ui(.linkFeedbackShown))
		await clock.advance(by: .seconds(30))

		await store.send(.ui(.linkFeedbackHovered(false))) {
			$0.linkFeedbackIsHovered = false
		}
		await clock.advance(by: .seconds(1))
		await clock.advance(by: .milliseconds(500))
		await store.receive(\.event.linkFeedbackExpired) {
			$0.linkActionFeedback = nil
		}
	}

	@Test
	internal func dismissingOrAStaleTimerLeavesNoToastBehind() async throws {
		let clock: TestClock<Duration> = .init()
		let (state, _) = try toastState()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
		}

		// An earlier copy's timer never closes this copy's toast.
		await store.send(.event(.linkFeedbackExpired(state.linkActionGeneration - 1)))
		await store.send(.ui(.linkFeedbackShown))
		await store.send(.ui(.dismissLinkFeedback)) {
			$0.linkActionFeedback = nil
		}

		// Dismissing cancels the timer, so nothing is left to expire.
		await store.finish()
	}

	@Test
	internal func copyOriginalFromTheToastCopiesTheUncleanedLink() async throws {
		let clock: TestClock<Duration> = .init()
		let (state, feedback) = try toastState()
		var copied: [String] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.linkSharing.copy = {
				copied.append($0)
				return true
			}
		}

		let originals = feedback.changedOriginals
		expectNoDifference(originals.map(\.url.absoluteString), ["https://capturecontext.dev/arx?utm_source=mail&id=7"])
		expectNoDifference(feedback.copiedURLs.map(\.absoluteString), ["https://capturecontext.dev/arx?id=7"])

		await store.send(.ui(.copyLinks(.original, items: originals, sourceWindowID: state.main.id))) {
			$0.linkActionGeneration += 1
		}
		let result = LinkTransformer.copy(originals, mode: .original)
		await store.receive(\.event.linkActionFinished) {
			$0.linkActionFeedback = .init(windowID: state.main.id, result: result, status: .copied)
		}
		expectNoDifference(copied, ["https://capturecontext.dev/arx?utm_source=mail&id=7"])

		let current = try #require(store.state.linkActionFeedback)
		#expect(current.title == "Copied Current URL")
		#expect(current.changedOriginals.isEmpty)
		#expect(current.copiedURLs == originals.map(\.url))
	}

	@Test
	internal func toastTitlesNameWhatWasCopied() throws {
		let tracked = try #require(URL(string: "https://capturecontext.dev/arx?utm_source=mail"))
		let plain = try #require(URL(string: "https://capturecontext.dev/arx"))
		func feedback(
			_ mode: LinkCopyMode,
			_ urls: [URL],
			status: LinkActionFeedback.Status = .copied
		) -> LinkActionFeedback {
			let items: [LinkCopyItem] = urls.map { .init(title: "Arx", url: $0) }
			return .init(windowID: nil, result: LinkTransformer.copy(items, mode: mode), status: status)
		}

		#expect(feedback(.original, [tracked]).title == "Copied Current URL")
		#expect(feedback(.clean, [plain]).title == "Copied Current URL")
		#expect(feedback(.clean, [plain]).changedOriginals.isEmpty)
		#expect(feedback(.clean, [tracked]).title == "Copied Clean Link")
		#expect(feedback(.markdownOriginal, [plain]).title == "Copied Markdown Link")
		#expect(feedback(.proxy, [plain]).title == "Copied Current URL")
		#expect(feedback(.original, [plain, tracked]).title == "Copied 2 Links")
		#expect(feedback(.original, [plain], status: .copyFailed).title == "Couldn't Copy Link")
		#expect(!feedback(.original, [plain], status: .share(.cancelled)).isShown)
		#expect(feedback(.original, [plain], status: .share(.shared)).isShown)
	}

	/// A window showing the toast for a cleaned copy.
	private func toastState() throws -> (AppFeature.State, LinkActionFeedback) {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let url = try #require(URL(string: "https://capturecontext.dev/arx?utm_source=mail&id=7"))
		let result = LinkTransformer.copy([.init(title: "Arx", url: url)], mode: .clean)
		let feedback: LinkActionFeedback = .init(windowID: state.main.id, result: result, status: .copied)
		state.linkActionGeneration = 3
		state.linkActionFeedback = feedback
		return (state, feedback)
	}
}
