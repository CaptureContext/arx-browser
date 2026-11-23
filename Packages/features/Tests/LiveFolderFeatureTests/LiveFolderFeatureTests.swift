import BrowserCore
import CustomDump
import Foundation
import LiveFolderClient
import LiveFolderFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-926: live folders refresh, badge and stop, with a fake client and a test clock.
@Suite(.dependencies)
@MainActor
internal struct LiveFolderFeatureTests {
	private final class Answers: @unchecked Sendable {
		private let lock: NSLock = .init()
		private var _queue: [Result<[LiveFolderItem], LiveFolderFailure>]
		private var _fetches: Int = 0

		internal init(_ queue: [Result<[LiveFolderItem], LiveFolderFailure>]) {
			self._queue = queue
		}

		internal var fetches: Int { lock.withLock { _fetches } }

		internal func next() -> Result<[LiveFolderItem], LiveFolderFailure> {
			lock.withLock {
				_fetches += 1
				return _queue.isEmpty ? .failure(.unreachable) : _queue.removeFirst()
			}
		}
	}

	private static let folder: Folder.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000926")!)
	private static let now: Date = .init(timeIntervalSince1970: 1_800_000_000)

	private static func item(_ id: String) -> LiveFolderItem {
		.init(id: id, title: "PR \(id)", url: URL(string: "https://github.com/arx/browser/pull/\(id)")!)
	}

	private func store(
		_ answers: Answers,
		clock: TestClock<Duration> = .init()
	) -> TestStoreOf<LiveFolderFeature> {
		TestStore(initialState: .init()) { LiveFolderFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.date.now = Self.now
			$0.liveFolders = .init(
				isAvailable: { _ in true },
				fetch: { _ throws(LiveFolderFailure) in try answers.next().get() }
			)
		}
	}

	@Test
	internal func aLiveFolderBadgesNewPullRequestsUntilOpened() async throws {
		let clock: TestClock<Duration> = .init()
		let answers: Answers = .init([
			.success([Self.item("1")]),
			.success([Self.item("2"), Self.item("1")]),
		])
		let store = store(answers, clock: clock)
		let source: LiveFolderSource = .gitHubPullRequests(.reviewRequested)
		let configuration = LiveFolderConfiguration(folderID: Self.folder, source: source)

		let task = await store.send(.ui(.task))
		await store.send(.ui(.makeLive(Self.folder, source))) {
			$0.folders = [.init(configuration: configuration, isRefreshing: true)]
		}
		await store.receive(\.event.fetched) {
			$0.folders[id: Self.folder]?.isRefreshing = false
			$0.folders[id: Self.folder]?.contents = .init(items: [Self.item("1")], refreshedAt: Self.now)
		}
		#expect(store.state.badgeCount(for: Self.folder) == 0)

		await clock.advance(by: LiveFolderFeature.refreshInterval)
		await store.receive(\.event.timerTicked) {
			$0.folders[id: Self.folder]?.isRefreshing = true
		}
		await store.receive(\.event.fetched) {
			$0.folders[id: Self.folder]?.isRefreshing = false
			$0.folders[id: Self.folder]?.contents = .init(
				items: [Self.item("2"), Self.item("1")],
				unseen: ["2"],
				refreshedAt: Self.now
			)
		}
		#expect(store.state.badgeCount(for: Self.folder) == 1)

		await store.send(.ui(.opened(Self.folder))) {
			$0.folders[id: Self.folder]?.contents.unseen = []
		}
		await task.cancel()
		#expect(answers.fetches == 2)
	}

	@Test
	internal func aFailureKeepsWhatWasListed() async throws {
		let answers: Answers = .init([.success([Self.item("1")]), .failure(.unauthorized)])
		let store = store(answers)
		let source: LiveFolderSource = .gitHubPullRequests(.authored)
		await store.send(.ui(.makeLive(Self.folder, source))) {
			$0.folders = [.init(configuration: .init(folderID: Self.folder, source: source), isRefreshing: true)]
		}
		await store.receive(\.event.fetched) {
			$0.folders[id: Self.folder]?.isRefreshing = false
			$0.folders[id: Self.folder]?.contents = .init(items: [Self.item("1")], refreshedAt: Self.now)
		}
		await store.send(.ui(.refresh(Self.folder))) {
			$0.folders[id: Self.folder]?.isRefreshing = true
		}
		await store.receive(\.event.fetched) {
			$0.folders[id: Self.folder]?.isRefreshing = false
			$0.folders[id: Self.folder]?.contents.failure = .unauthorized
		}
	}

	@Test
	internal func aLateAnswerForAnotherSourceOrAStoppedFolderIsDropped() async throws {
		let store = store(.init([]))
		store.exhaustivity = .off
		let authored: LiveFolderSource = .gitHubPullRequests(.authored)
		await store.send(.ui(.makeLive(Self.folder, authored)))
		await store.skipReceivedActions()

		await store.send(.event(.fetched(Self.folder, .gitHubPullRequests(.reviewRequested), .success([Self.item("9")]))))
		#expect(store.state.folders[id: Self.folder]?.contents.items.isEmpty == true)

		await store.send(.foldersChanged([]))
		#expect(store.state.folders.isEmpty)
		await store.send(.event(.fetched(Self.folder, authored, .success([Self.item("9")]))))
		#expect(store.state.folders.isEmpty)
	}

	@Test
	internal func withoutAnAccountNothingIsFetched() async throws {
		let store = TestStore(initialState: LiveFolderFeature.State()) { LiveFolderFeature() } withDependencies: {
			$0.date.now = Self.now
			$0.liveFolders = .running(accounts: .none) { _ in
				Issue.record("No request without an account")
				throw URLError(.notConnectedToInternet)
			}
		}
		let source: LiveFolderSource = .gitHubPullRequests(.authored)
		await store.send(.ui(.makeLive(Self.folder, source))) {
			$0.folders = [.init(configuration: .init(folderID: Self.folder, source: source), isRefreshing: true)]
		}
		await store.receive(\.event.fetched) {
			$0.folders[id: Self.folder]?.isRefreshing = false
			$0.folders[id: Self.folder]?.contents.failure = .notSignedIn
		}
	}
}
