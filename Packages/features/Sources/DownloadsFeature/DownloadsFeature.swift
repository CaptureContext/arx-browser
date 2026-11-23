import AppUI
import BrowserCore
import BrowserDownloadsClient
import Foundation
import SoundFeedbackClient
import _ComposableArchitecture

@Reducer
public struct DownloadsFeature {
	@ObservableState
	public struct State: Equatable {
		public var queue: DownloadQueue
		public var profileID: Profile.ID?
		public var filter: Filter

		/// Profiles picked in the Library's filter pane. While any are, the panel shows only their
		/// downloads, and the header lists them as chips.
		public var profileFilter: Set<Profile.ID>
		public var isFilterPanePresented: Bool
		public var isPresented: Bool
		public var message: String?
		public var query: String

		/// Library panels showing downloads. The queue stays observed while any of them or the window does.
		public var panelCount: Int

		public init(
			profileID: Profile.ID? = nil,
			queue: DownloadQueue = .init(),
			filter: Filter = .currentProfile,
			profileFilter: Set<Profile.ID> = [],
			isFilterPanePresented: Bool = false,
			isPresented: Bool = false,
			message: String? = nil,
			query: String = "",
			panelCount: Int = 0
		) {
			self.profileID = profileID
			self.queue = queue
			self.filter = filter
			self.profileFilter = profileFilter
			self.isFilterPanePresented = isFilterPanePresented
			self.isPresented = isPresented
			self.message = message
			self.query = query
			self.panelCount = panelCount
		}

		public var visibleDownloads: [BrowserDownload] {
			switch filter {
			case .currentProfile: queue.downloads.filter { $0.id.profileID == profileID }
			case .allProfiles where profileFilter.isEmpty: queue.downloads
			case .allProfiles: queue.downloads.filter { profileFilter.contains($0.id.profileID) }
			case .privateTransfers: queue.privateDownloads
			}
		}

		/// The filters the header shows as chips: picked profiles, or Private Transfers.
		public var activeFilterCount: Int {
			filter == .privateTransfers ? 1 : profileFilter.count
		}

		public var searchedDownloads: [BrowserDownload] {
			visibleDownloads
				.filter { download in
					query.isEmpty
					|| download.filename.localizedStandardContains(query)
					|| download.url?.host()?.localizedStandardContains(query) == true
				}
				.sorted { $0.startedAt > $1.startedAt }
		}
	}

	public enum Filter: Hashable, Sendable {
		case currentProfile
		case allProfiles
		case privateTransfers
	}

	@CasePathable
	public enum Action: Sendable {
		/// Listens to the queue for as long as the app runs, and sounds each transfer's outcome
		/// (DEV-1256): finished, or failed without the person cancelling it. Sent once by the app,
		/// whether or not any downloads surface is showing.
		case soundOutcomes
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case appeared
			case dismissed
			case filterChanged(Filter)

			/// Filter opens or closes the pane under the header.
			case filterPaneToggled

			/// The pane's Done.
			case filterPaneDismissed

			/// A profile chip in the pane: picks or unpicks it.
			case profileFilterToggled(Profile.ID)

			/// A profile's chip in the header: unpicks it.
			case profileFilterRemoved(Profile.ID)

			/// Private Transfers, in the pane or as a header chip.
			case privateTransfersToggled
			case queryChanged(String)
			case panelAppeared
			case panelDisappeared
			case cancel(BrowserDownload.ID)
			case open(BrowserDownload.ID)

			/// A row the Library button fanned out. It lists its window's profile whatever the panel's
			/// filter shows, so any download in the queue may open.
			case openRecent(BrowserDownload.ID)
			case reveal(BrowserDownload.ID)

			/// DEV-892: Pause and Resume, Copy Link, Remove from List and Move to Trash.
			case pause(BrowserDownload.ID)
			case resume(BrowserDownload.ID)
			case copyLink(BrowserDownload.ID)
			case removeFromList(BrowserDownload.ID)
			case moveToTrash(BrowserDownload.ID)
		}

		@CasePathable
		public enum Event: Sendable {
			case queueChanged(DownloadQueue)
			case operationFailed(String)
		}

		@CasePathable
		public enum Delegate: Sendable {
			/// A recent row couldn't open its file. The rows have closed by then and the panel may not
			/// be showing, so the parent shows the message instead of `message`.
			case recentOpenFailed(String)

			/// Copy Link: the parent copies the transfer's source address.
			case copyLink(URL)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.browserDownloads)
	private var downloads

	@Dependency(\.soundFeedback)
	private var soundFeedback

	private enum Cancellation: Hashable {
		case observation
		case outcomes
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.soundOutcomes) { _ in
			.run { [downloads, soundFeedback] _ in
				var outcomes: DownloadOutcomes?
				for await queue in await downloads.events() {
					// Watching starts with the first snapshot, which the queue sends at once.
					var current: DownloadOutcomes = outcomes ?? .startingNow()
					let sounds = current.sounds(after: queue)
					outcomes = current
					for sound in sounds {
						await soundFeedback.play(sound)
					}
				}
			}
			.cancellable(id: Cancellation.outcomes, cancelInFlight: true)
		}

		Pullback(\.ui.appeared) { _ in observeQueue() }

		Pullback(\.ui.dismissed) { state in
			state.isPresented = false
			return state.panelCount > 0 ? .none : .cancel(id: Cancellation.observation)
		}

		Pullback(\.ui.panelAppeared) { state in
			state.panelCount += 1
			return observeQueue()
		}

		Pullback(\.ui.panelDisappeared) { state in
			state.panelCount = max(state.panelCount - 1, 0)
			state.query = state.panelCount > 0 ? state.query : ""
			return state.panelCount > 0 || state.isPresented ? .none : .cancel(id: Cancellation.observation)
		}

		Pullback(\.ui.queryChanged) { state, query in
			state.query = query
			return .none
		}

		Pullback(\.ui.filterChanged) { state, filter in
			state.filter = filter
			state.profileFilter = []
			state.message = nil
			return .none
		}

		Pullback(\.ui.filterPaneToggled) { state in
			state.isFilterPanePresented.toggle()
			return .none
		}

		Pullback(\.ui.filterPaneDismissed) { state in
			state.isFilterPanePresented = false
			return .none
		}

		Pullback(\.ui.profileFilterToggled) { state, profileID in
			if state.profileFilter.contains(profileID) {
				state.profileFilter.remove(profileID)
			} else {
				state.profileFilter.insert(profileID)
			}
			state.applyProfileFilter()
			return .none
		}

		Pullback(\.ui.profileFilterRemoved) { state, profileID in
			state.profileFilter.remove(profileID)
			state.applyProfileFilter()
			return .none
		}

		Pullback(\.ui.privateTransfersToggled) { state in
			state.profileFilter = []
			state.filter = state.filter == .privateTransfers ? .currentProfile : .privateTransfers
			state.message = nil
			return .none
		}

		Pullback(\.ui.cancel) { state, id in
			guard state.visibleDownloads.contains(where: { $0.id == id && $0.status == .inProgress })
			else { return .none }

			state.message = nil
			return .run { [downloads] send in
				do { try await downloads.cancel(id) }
				catch { await send(.event(.operationFailed(downloadFailureMessage(error)))) }
			}
		}

		Pullback(\.ui.open) { state, id in
			guard state.visibleDownloads.contains(where: { $0.id == id && $0.canOpen })
			else { return .none }

			state.message = nil
			return .run { [downloads] send in
				do { try await downloads.open(id) }
				catch { await send(.event(.operationFailed(downloadFailureMessage(error)))) }
			}
		}

		Pullback(\.ui.openRecent) { state, id in
			let transfers: [BrowserDownload] = state.queue.downloads + state.queue.privateDownloads
			guard transfers.contains(where: { $0.id == id && $0.canOpen })
			else { return .none }

			return .run { [downloads] send in
				do { try await downloads.open(id) }
				catch { await send(.delegate(.recentOpenFailed(downloadFailureMessage(error)))) }
			}
		}

		Pullback(\.ui.reveal) { state, id in
			guard state.visibleDownloads.contains(where: { $0.id == id && $0.canOpen })
			else { return .none }

			state.message = nil
			return .run { [downloads] send in
				do { try await downloads.reveal(id) }
				catch { await send(.event(.operationFailed(downloadFailureMessage(error)))) }
			}
		}

		Pullback(\.ui.pause) { state, id in
			guard let download = state.transfer(id), download.canPause else { return .none }

			state.message = nil
			return .run { [downloads] send in
				do { try await downloads.setPaused(id, true) }
				catch { await send(.event(.operationFailed(downloadFailureMessage(error)))) }
			}
		}

		Pullback(\.ui.resume) { state, id in
			guard let download = state.transfer(id), download.canResume else { return .none }

			state.message = nil
			return .run { [downloads] send in
				do { try await downloads.setPaused(id, false) }
				catch { await send(.event(.operationFailed(downloadFailureMessage(error)))) }
			}
		}

		Pullback(\.ui.copyLink) { state, id in
			guard let download = state.transfer(id), download.canCopyLink, let url = download.url
			else { return .none }

			return .send(.delegate(.copyLink(url)))
		}

		Pullback(\.ui.removeFromList) { state, id in
			guard let download = state.transfer(id), download.canRemoveFromList else { return .none }

			state.message = nil
			return .run { [downloads] send in
				do { try await downloads.removeFromList(id) }
				catch { await send(.event(.operationFailed(downloadFailureMessage(error)))) }
			}
		}

		Pullback(\.ui.moveToTrash) { state, id in
			guard let download = state.transfer(id), download.canMoveToTrash else { return .none }

			state.message = nil
			return .run { [downloads] send in
				do { try await downloads.moveToTrash(id) }
				catch { await send(.event(.operationFailed(downloadFailureMessage(error)))) }
			}
		}

		Pullback(\.event.queueChanged) { state, queue in
			state.queue = queue
			return .none
		}

		Pullback(\.event.operationFailed) { state, message in
			state.message = message
			return .none
		}
	}

	private func observeQueue() -> Effect<Action> {
		.run { [downloads] send in
			for await queue in await downloads.events() {
				await send(.event(.queueChanged(queue)))
			}
		}.cancellable(id: Cancellation.observation, cancelInFlight: true)
	}
}

extension DownloadsFeature.State {
	/// A transfer this surface lists.
	fileprivate func transfer(_ id: BrowserDownload.ID) -> BrowserDownload? {
		visibleDownloads.first { $0.id == id }
	}

	/// Picked profiles narrow every profile's downloads; with none picked, the panel follows the
	/// current profile again.
	fileprivate mutating func applyProfileFilter() {
		filter = profileFilter.isEmpty ? .currentProfile : .allProfiles
		message = nil
	}
}

/// The outcomes of transfers that ran while the app watched (DEV-1256), from one queue snapshot to
/// the next. Transfers already finished when it started, such as last week's history or ones a
/// relaunch reconciled as interrupted, make no sound.
public struct DownloadOutcomes: Equatable, Sendable {
	/// Chromium's interrupt reasons that aren't a failure the person needs to hear about:
	/// `USER_CANCELED` (40), `USER_SHUTDOWN` (41) and `CRASH` (50), from
	/// `components/download/public/common/download_interrupt_reason_values.h`, and `NONE` (0):
	/// nothing failed, a relaunch found a saved transfer the engine no longer has.
	public static let quietInterruptReasons: Set<Int> = [0, 40, 41, 50]

	/// When watching began. A transfer first seen already finished counts only if it started since.
	public var since: Date
	public var statuses: [BrowserDownload.ID: BrowserDownload.Status]

	public init(
		since: Date,
		statuses: [BrowserDownload.ID: BrowserDownload.Status] = [:]
	) {
		self.since = since
		self.statuses = statuses
	}

	/// Outcomes watched from now on. Reads the date only here, so a test whose queue never sends
	/// a snapshot needs no date.
	public static func startingNow() -> Self {
		@Dependency(\.date)
		var date

		return .init(since: date.now)
	}

	/// The sounds for transfers that ended between the last snapshot and `queue`, each sound once.
	public mutating func sounds(after queue: DownloadQueue) -> [SoundFeedback] {
		var sounds: [SoundFeedback] = []
		for download in queue.downloads + queue.privateDownloads {
			let previous: BrowserDownload.Status? = statuses[download.id]
			statuses[download.id] = download.status

			// Seen running; or resumed and finished between two snapshots, as the queue keeps only
			// the newest; or started while watching and already over when first seen, as a small
			// file can be.
			let ran = previous == .inProgress
				|| (previous == .interrupted && download.status == .complete)
				|| (previous == nil && download.startedAt >= since)
			guard ran, previous != download.status, let sound = Self.sound(for: download)
			else { continue }

			if !sounds.contains(sound) { sounds.append(sound) }
		}
		return sounds
	}

	private static func sound(for download: BrowserDownload) -> SoundFeedback? {
		switch download.status {
		case .complete:
			.done
		case .interrupted where !quietInterruptReasons.contains(download.interruptReason):
			.couldNot
		case .inProgress, .cancelled, .interrupted:
			nil
		}
	}
}

// MARK: - Failure messages

extension BrowserDownloadsClient.Failure {
	/// The failure in the interface's language (DEV-1291). `errorDescription` stays English for
	/// agents and logs.
	public var localizedMessage: String {
		switch self {
		case .unavailable: String.localized(.appUI.downloads.failure.unavailable)
		case .missingDownload: String.localized(.appUI.downloads.failure.missingDownload)
		case .notOpenable: String.localized(.appUI.downloads.failure.notOpenable)
		case .fileMissing: String.localized(.appUI.downloads.failure.fileMissing)
		case .couldNotOpen: String.localized(.appUI.downloads.failure.couldNotOpen)
		case .couldNotStart: String.localized(.appUI.downloads.failure.couldNotStart)
		case .startTimedOut: String.localized(.appUI.downloads.failure.startTimedOut)
		case .notResumable: String.localized(.appUI.downloads.failure.notResumable)
		case .couldNotTrash: String.localized(.appUI.downloads.failure.couldNotTrash)
		case .notRemovable: String.localized(.appUI.downloads.failure.notRemovable)
		}
	}
}

/// What to show for an error a download action threw: the localized message for the client's
/// own failures, the error's description for any other.
public func downloadFailureMessage(_ error: any Error) -> String {
	(error as? BrowserDownloadsClient.Failure)?.localizedMessage ?? error.localizedDescription
}
