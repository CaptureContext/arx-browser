import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// A headless run stopped right after a change still writes it (DEV-865): every stop sends
/// `flushWorkspaceSave` and flushes history, waiting at most `HeadlessShutdown.saveDeadline`.
/// The tests decide when time is up; none of them measures the wall clock.
@Suite(.dependencies, .timeLimit(.minutes(3)))
@MainActor
internal struct HeadlessSaveFlushTests {
	@Test
	internal func aStopRightAfterAChangeWritesItWithoutTheCoalescingWait() async throws {
		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent("workspace.json")
		let workspace = BrowserWorkspaceClient(file: file)
		var organization = IntegrationFeatureTests().fixture()

		// A tab opened just before SIGTERM.
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(500)),
			profileID: organization.profiles[0].id,
			restoration: .init(title: "Opened", url: URL(string: "https://capturecontext.dev/opened")!)
		)
		organization.tabs.append(tab)
		organization.spaces[0].unpinnedTabs.append(tab.id)
		let initialState = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: initialState) {
			WorkspacePersistence(workspace: workspace)
		} withDependencies: {
			// Never advanced: only the stop's flush can write.
			$0.continuousClock = TestClock()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.delegate(.save(organization)))

		// The stop's flush writes at once: the coalescing clock is never advanced.
		await store.send(.flushWorkspaceSave).finish()
		expectNoDifference(try BrowserWorkspaceClient(file: file).load()?.tabs[id: tab.id], tab)
	}

	@Test
	internal func theStopWaitsForWorkThatFinishes() async throws {
		let done = LockIsolated(false)

		// Time never runs out: only the work can end the wait.
		let finished = await HeadlessShutdown.finish({
			await Task.yield()
			done.setValue(true)
		}, timeout: { _ in })
		#expect(finished)
		#expect(done.value)
	}

	@Test
	internal func theStopGivesUpOnWorkThatHangs() async throws {
		let (gate, open) = AsyncStream<Void>.makeStream()
		let done = LockIsolated(false)

		// Time is up at once, while the work waits for a gate that only opens afterwards.
		let finished = await HeadlessShutdown.finish({
			for await _ in gate {}
			done.setValue(true)
		}, timeout: { expire in expire() })
		#expect(!finished)
		#expect(!done.value)
		open.finish()
	}

	@Test
	internal func workFinishingAfterTheTimeoutDoesNotChangeTheAnswer() async throws {
		let (gate, open) = AsyncStream<Void>.makeStream()
		let expire = LockIsolated<(@Sendable () -> Void)?>(nil)
		let answer = Task {
			await HeadlessShutdown.finish({
				for await _ in gate {}
			}, timeout: { fire in expire.setValue(fire) })
		}
		while expire.value == nil { await Task.yield() }
		expire.value?()
		open.finish()
		#expect(await answer.value == false)
	}
}
