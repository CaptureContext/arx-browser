import BrowserCore
import CustomDump
import Foundation
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test(arguments: [false, true])
	internal func temporaryPeekCloseHonorsBeforeUnloadAndRejectsRepeatedRequests(_ permitted: Bool) async {
		let state = peekFixture()
		let (decisions, continuation) = AsyncStream<Bool>.makeStream()
		var requested: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { PeekFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { id in
				requested.append(id)
				for await decision in decisions { return decision }
				return false
			}
		}
		await store.send(.ui(.close)) { $0.phase = .closing }
		await store.send(.ui(.close))
		continuation.yield(permitted)
		continuation.finish()
		if permitted {
			await store.receive(\.event.closeDecision)
			await store.receive(\.delegate.close)

		} else {
			await store.receive(\.event.closeDecision) { $0.phase = .idle }
		}
		await store.finish()
		expectNoDifference(requested, [state.tab.id])
		expectNoDifference(store.state.tab, state.tab)
	}

	@Test
	internal func existingPeekReturnsSessionWithoutBeforeUnloadOrPromotionToTemporaryHost() async {
		let store = TestStore(initialState: peekFixture(isTemporary: false)) { PeekFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { _ in
				Issue.record("Existing session is not being closed")
				return false
			}
		}
		await store.send(.ui(.promote(.littleArx)))
		await store.send(.ui(.close)) { $0.phase = .closing }
		await store.receive(\.event.closeDecision)
		await store.receive(\.delegate.close)
	}

	@Test
	internal func cancelledPeekReplacementKeepsCurrentSessionAndAllowsRetry() async {
		let state = peekFixture()
		let destination = URL(string: "https://next.example/path")!
		let store = TestStore(initialState: state) { PeekFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { _ in false }
		}
		await store.send(.ui(.replace(destination))) {
			$0.phase = .replacing
			$0.replacementURL = destination
		}
		await store.receive(\.event.closeDecision) {
			$0.phase = .idle
			$0.replacementURL = nil
		}
		expectNoDifference(store.state.tab, state.tab)
		await store.send(.ui(.promote(.tab))) { $0.phase = .promoting }
		await store.receive(\.delegate.promote)
		await store.send(.event(.promotionFailed("Try again"))) {
			$0.phase = .idle
			$0.error = "Try again"
		}
		expectNoDifference(store.state.tab, state.tab)
	}

	@Test
	internal func peekReplacementValidatesHTTPAndRejectsCredentialOrExternalSchemes() {
		for invalid in [
			"file:///tmp/example",
			"javascript:alert(1)",
			"https://name:secret@capturecontext.dev",
			"capturecontext.dev",
			"https:///path",
		] {
			expectNoDifference(PeekFeature.previewURL(invalid), nil)
		}
		expectNoDifference(
			PeekFeature.previewURL(" https://capturecontext.dev/path?q=value#fragment ")?.absoluteString,
			"https://capturecontext.dev/path?q=value#fragment"
		)
	}

	private func peekFixture(isTemporary: Bool = true) -> PeekFeature.State {
		let organization = fixture()
		return .init(
			id: UUID(80),
			source: .init(
				windowID: UUID(81),
				paneID: UUID(82),
				tabID: organization.tabs[0].id,
				spaceID: organization.spaces[0].id,
				profileID: organization.profiles[0].id,
				identity: "Default · Work"
			),
			tab: organization.tabs[1],
			isTemporary: isTemporary
		)
	}
}
