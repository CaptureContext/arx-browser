import BrowserCore
import Foundation
import LiveFolderClient
import _ComposableArchitecture

/// Live folders (DEV-926): pinned folders that fill themselves from a source, refresh on a
/// timer and badge what's new until the folder is opened.
///
/// The feature owns the folders' sources and contents. It isn't composed into the sidebar
/// yet: that, saving the sources and how a user signs in to a source's service wait for
/// Max's decisions, recorded on DEV-926. Until then `LiveFolderClient.liveValue` has no
/// account and every refresh ends in `notSignedIn` without a request.
@Reducer
public struct LiveFolderFeature {
	@ObservableState
	public struct State: Equatable {
		public var folders: IdentifiedArrayOf<LiveFolder>

		public init(folders: IdentifiedArrayOf<LiveFolder> = []) {
			self.folders = folders
		}

		/// The badge for a folder: how many of its items are new.
		public func badgeCount(for id: Folder.ID) -> Int {
			folders[id: id]?.contents.badgeCount ?? 0
		}
	}

	public struct LiveFolder: Equatable, Identifiable, Sendable {
		public var configuration: LiveFolderConfiguration
		public var contents: LiveFolderContents
		public var isRefreshing: Bool

		public var id: Folder.ID { configuration.folderID }

		public init(
			configuration: LiveFolderConfiguration,
			contents: LiveFolderContents = .init(),
			isRefreshing: Bool = false
		) {
			self.configuration = configuration
			self.contents = contents
			self.isRefreshing = isRefreshing
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		/// The folders that still exist; live folders for others stop.
		case foldersChanged(Set<Folder.ID>)

		@CasePathable
		public enum UI: Sendable {
			/// Starts refreshing every live folder on a timer.
			case task
			case makeLive(Folder.ID, LiveFolderSource)
			case stopLive(Folder.ID)
			case refresh(Folder.ID)

			/// The user opened or expanded the folder: its badge clears.
			case opened(Folder.ID)
		}

		@CasePathable
		public enum Event: Sendable {
			case fetched(Folder.ID, LiveFolderSource, Result<[LiveFolderItem], LiveFolderFailure>)
			case timerTicked
		}

		@CasePathable
		public enum Delegate: Sendable {}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	/// How often every live folder refreshes while the feature runs.
	public static let refreshInterval: Duration = .seconds(15 * 60)

	private enum Cancellation: Hashable {
		case timer
		case fetch(Folder.ID)
	}

	@Dependency(\.continuousClock)
	private var clock

	@Dependency(\.date.now)
	private var now

	@Dependency(\.liveFolders)
	private var client

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.task) { _ in
			.run { [clock] send in
				for await _ in clock.timer(interval: Self.refreshInterval) {
					await send(.event(.timerTicked))
				}
			}
			.cancellable(id: Cancellation.timer, cancelInFlight: true)
		}

		Pullback(\.ui.makeLive) { state, value in
			let (id, source) = value
			let configuration = LiveFolderConfiguration(folderID: id, source: source)

			// A new source starts over: the old items belong to the old one.
			if state.folders[id: id]?.configuration != configuration {
				state.folders[id: id] = .init(configuration: configuration)
			}
			return refresh(id, state: &state)
		}

		Pullback(\.ui.stopLive) { state, id in
			state.folders.remove(id: id)
			return .cancel(id: Cancellation.fetch(id))
		}

		Pullback(\.ui.refresh) { state, id in
			refresh(id, state: &state)
		}

		Pullback(\.ui.opened) { state, id in
			guard let contents = state.folders[id: id]?.contents else { return .none }

			state.folders[id: id]?.contents = contents.markingSeen()
			return .none
		}

		Pullback(\.event.timerTicked) { state in
			let ids = Array(state.folders.ids)
			var effects: [Effect<Action>] = []
			for id in ids { effects.append(refresh(id, state: &state)) }
			return .merge(effects)
		}

		Pullback(\.event.fetched) { state, value in
			let (id, source, result) = value

			// A late answer for a folder that stopped or changed source is dropped.
			guard
				var folder = state.folders[id: id],
				folder.configuration.source == source
			else { return .none }

			folder.isRefreshing = false
			switch result {
			case let .success(items):
				folder.contents = folder.contents.refreshed(with: items, at: now)

			case let .failure(failure):
				folder.contents = folder.contents.failed(failure)
			}
			state.folders[id: id] = folder
			return .none
		}

		Pullback(\.foldersChanged) { state, existing in
			let gone = state.folders.ids.filter { !existing.contains($0) }
			for id in gone { state.folders.remove(id: id) }
			return .merge(gone.map { .cancel(id: Cancellation.fetch($0)) })
		}
	}

	private func refresh(
		_ id: Folder.ID,
		state: inout State
	) -> Effect<Action> {
		guard let folder = state.folders[id: id], !folder.isRefreshing else { return .none }

		state.folders[id: id]?.isRefreshing = true
		let source = folder.configuration.source
		return .run { [client] send in
			let result: Result<[LiveFolderItem], LiveFolderFailure>
			do throws(LiveFolderFailure) {
				result = .success(try await client.fetch(source))
			} catch {
				result = .failure(error)
			}
			await send(.event(.fetched(id, source, result)))
		}
		.cancellable(id: Cancellation.fetch(id), cancelInFlight: true)
	}
}
