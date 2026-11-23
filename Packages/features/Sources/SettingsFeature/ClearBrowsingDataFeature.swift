import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import BrowserHistoryClient
import Foundation
import _ComposableArchitecture

/// Clear Browsing Data for one ordinary profile (DEV-647): what to remove, how far
/// back, and how much of each there is. The engine clears what Chromium stores; the
/// app's own history and Downloads list are cleared here and through the delegate.
@Reducer
public struct ClearBrowsingDataFeature {
	@ObservableState
	public struct State: Equatable {
		public var profileID: Profile.ID
		public var profileName: String
		public var kinds: Set<BrowsingDataKind>
		public var range: BrowsingDataRange
		public var counts: BrowsingDataCounts
		public var isCounting: Bool
		public var isClearing: Bool
		public var notice: Notice?

		public init(
			profileID: Profile.ID,
			profileName: String,
			kinds: Set<BrowsingDataKind> = BrowsingDataKind.defaults,
			range: BrowsingDataRange = .lastHour
		) {
			self.profileID = profileID
			self.profileName = profileName
			self.kinds = kinds
			self.range = range
			self.counts = .init()
			self.isCounting = false
			self.isClearing = false
			self.notice = nil
		}

		public var canClear: Bool {
			!kinds.isEmpty && !isClearing
		}
	}

	public enum Notice: Equatable, Sendable {
		/// Some kinds couldn't be cleared fully, or at all.
		case partial(Set<BrowsingDataKind>)
		case failed(ProfileDataFailure)
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case appeared
			case kindToggled(BrowsingDataKind, Bool)
			case rangeChanged(BrowsingDataRange)
			case clear
			case cancel
		}

		@CasePathable
		public enum Event: Sendable {
			/// Counts for the range they were taken for.
			case counted(BrowsingDataRange, BrowsingDataCounts)
			case engineCounted(BrowsingDataRange, BrowsingDataCounts)
			case cleared(failed: Set<BrowsingDataKind>, failure: ProfileDataFailure?)
		}

		@CasePathable
		public enum Delegate: Sendable {
			/// Removes the profile's history entries since a moment, or all of them when nil.
			case clearHistory(Profile.ID, since: Date?)

			/// The profile's cookies or cache were cleared: what the app fetched with them goes
			/// too (DEV-1142).
			case clearedSiteData(Profile.ID)
			case dismiss
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.browserDownloads)
	private var downloads

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.browserHistory)
	private var history

	@Dependency(\.date.now)
	private var now

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.appeared) { state in
			count(&state)
		}

		Pullback(\.ui.kindToggled) { state, value in
			let (kind, isOn) = value
			if isOn {
				state.kinds.insert(kind)
			} else {
				state.kinds.remove(kind)
			}
			state.notice = nil
			return .none
		}

		Pullback(\.ui.rangeChanged) { state, range in
			guard range != state.range else { return .none }

			state.range = range
			state.notice = nil
			return count(&state)
		}

		Pullback(\.event.counted) { state, value in
			let (range, counts) = value
			guard range == state.range else { return .none }

			state.counts.history = counts.history
			state.counts.downloads = counts.downloads
			return .none
		}

		Pullback(\.event.engineCounted) { state, value in
			let (range, counts) = value
			guard range == state.range else { return .none }

			state.isCounting = false
			state.counts.merge(engine: counts)
			return .none
		}

		Pullback(\.ui.clear) { state in
			guard state.canClear else { return .none }

			state.isClearing = true
			state.notice = nil
			return clear(state)
		}

		Pullback(\.event.cleared) { state, value in
			state.isClearing = false
			if let failure = value.failure {
				state.notice = .failed(failure)
				return count(&state)
			}
			if !value.failed.isEmpty {
				state.notice = .partial(value.failed)
				return count(&state)
			}
			return .merge(
				.cancel(id: Cancellation.count),
				.send(.delegate(.dismiss))
			)
		}

		Pullback(\.ui.cancel) { state in

			// A clear in flight finishes; only the sheet goes away.
			.merge(
				.cancel(id: Cancellation.count),
				.send(.delegate(.dismiss))
			)
		}
	}

	private func count(_ state: inout State) -> Effect<Action> {
		let profileID = state.profileID
		let range = state.range
		let since = range.start(before: now)
		state.isCounting = true
		state.counts = .init()
		let count: Effect<Action> = .run { [engine, history, downloads] send in
			var local = BrowsingDataCounts()
			local.downloads = await downloads.snapshot().finishedCount(profileID: profileID, since: since)
			if history.isAvailable, let outcome = try? await history.load(profileID) {
				local.history = outcome.snapshot.count(since: since)
			}
			await send(.event(.counted(range, local)))

			let counted: BrowsingDataCounts
			if await engine.profileDataIsAvailable() {
				counted = (try? await engine.countBrowsingData(
					profileID,
					Self.engineCounted,
					since
				)) ?? .init()
			} else {
				counted = .init()
			}
			await send(.event(.engineCounted(range, counted)))
		}
		.cancellable(id: Cancellation.count)

		// `cancelInFlight` cancels when the task registers, off the main actor, so an older
		// count could cancel this one and leave the sheet counting. Cancel in reducer order
		// instead; an older count that registers late reports another range and is ignored.
		return .concatenate(.cancel(id: Cancellation.count), count)
	}

	/// The engine first, so a failure there leaves the app's lists as they were
	/// unless only those were asked for.
	private func clear(_ state: State) -> Effect<Action> {
		let profileID = state.profileID
		let kinds = state.kinds
		let since = state.range.start(before: now)
		return .run { [engine, downloads] send in

			// Picked before the engine clears, so a download that finishes meanwhile,
			// which Chromium keeps, stays in the list too.
			let finishedDownloads = kinds.contains(.downloads)
			? await downloads.snapshot().finished(profileID: profileID, since: since)
			: []
			var failed: Set<BrowsingDataKind> = []
			let engineKinds = kinds.subtracting(Self.appOnly)
			do throws(ProfileDataFailure) {
				if await engine.profileDataIsAvailable() {
					failed = try await engine.clearBrowsingData(profileID, kinds, since)
				} else if !engineKinds.isEmpty {
					throw .unavailable
				}
			} catch {
				// History and the Downloads list are the app's own; clear them anyway
				// when there's no engine, so long as nothing else was asked for. A
				// policy that keeps history, or any other failure, stops everything.
				guard engineKinds.isEmpty, error == .unavailable else {
					await send(.event(.cleared(failed: [], failure: error)))
					return
				}
			}

			if kinds.contains(.downloads) {
				do {
					_ = try await downloads.removeHistory(finishedDownloads)
				} catch {
					failed.insert(.downloads)
				}
			}
			if kinds.contains(.history) {
				await send(.delegate(.clearHistory(profileID, since: since)))
			}
			if !kinds.intersection(Self.siteData).subtracting(failed).isEmpty {
				await send(.delegate(.clearedSiteData(profileID)))
			}
			await send(.event(.cleared(failed: failed, failure: nil)))
		}
		.cancellable(id: Cancellation.clear)
	}

	/// Kinds that hold what sites know of the profile, which hover cards' site details were
	/// fetched with (DEV-1142).
	private static let siteData: Set<BrowsingDataKind> = [.cookies, .cache]

	/// Kinds the engine counts; the app counts history and downloads itself.
	private static let engineCounted: Set<BrowsingDataKind> = [.cookies, .cache, .autofill, .siteSettings]

	/// Kinds that are also, or only, the app's own lists.
	private static let appOnly: Set<BrowsingDataKind> = [.history, .downloads]

	private enum Cancellation: Hashable {
		case count
		case clear
	}
}
