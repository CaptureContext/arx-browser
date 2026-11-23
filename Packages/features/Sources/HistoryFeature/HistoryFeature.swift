import BrowserCore
import Foundation
import _ComposableArchitecture

/// The Library's History page (DEV-817): one profile's history by day, newest first, with search.
///
/// The page reads the profile's history as the app keeps it, so it updates live, and never writes
/// it: opening and every deletion go to the parent, which deletes through the history client.
@Reducer
public struct HistoryFeature {
	@ObservableState
	public struct State: Equatable {
		public var profileID: Profile.ID?

		/// The profile's history, newest first.
		public var entries: [BrowsingHistoryEntry]

		/// The history couldn't be read, so the page has nothing to show or delete.
		public var isUnavailable: Bool
		public var query: String

		/// A day or a site waiting for the user's confirmation.
		public var pendingDeletion: Deletion?

		public init(
			profileID: Profile.ID? = nil,
			entries: [BrowsingHistoryEntry] = [],
			isUnavailable: Bool = false,
			query: String = "",
			pendingDeletion: Deletion? = nil
		) {
			self.profileID = profileID
			self.entries = entries
			self.isUnavailable = isUnavailable
			self.query = query
			self.pendingDeletion = pendingDeletion
		}

		/// The entries the search matches, newest first.
		public var visibleEntries: [BrowsingHistoryEntry] {
			let terms = query.split(whereSeparator: \.isWhitespace)
			let matching = terms.isEmpty
			? entries
			: entries.filter { entry in
				terms.allSatisfy { term in
					entry.title.localizedStandardContains(term)
					|| entry.url.absoluteString.localizedStandardContains(term)
				}
			}
			return matching.sorted { $0.lastVisited > $1.lastVisited }
		}

		/// The visible entries by the day they were last visited, newest day first.
		public func days(in calendar: Calendar) -> [Day] {
			var days: [Day] = []
			for entry in visibleEntries {
				let start = calendar.startOfDay(for: entry.lastVisited)
				if days.last?.id == start {
					days[days.count - 1].entries.append(entry)
				} else {
					days.append(.init(id: start, entries: [entry]))
				}
			}
			return days
		}

		/// The entries a deletion removes, from the whole history, not only what the search shows.
		public func entries(
			of deletion: Deletion,
			in calendar: Calendar
		) -> [BrowsingHistoryEntry] {
			switch deletion {
			case let .day(start):
				entries.filter { calendar.startOfDay(for: $0.lastVisited) == start }

			case let .site(site):
				entries.filter { BrowsingHistoryRemoval.site(site).matches($0) }
			}
		}
	}

	/// One day of history: its start and its entries, newest first.
	public struct Day: Equatable, Identifiable, Sendable {
		public var id: Date
		public var entries: [BrowsingHistoryEntry]

		public init(
			id: Date,
			entries: [BrowsingHistoryEntry]
		) {
			self.id = id
			self.entries = entries
		}
	}

	public enum Deletion: Equatable, Sendable {
		/// The day starting at this moment.
		case day(Date)

		/// Every page of the site with this host, as it appears in an address. The removal
		/// ignores case and a leading `www.`, so these are the same pages the command bar's
		/// Delete All from removes. `HistoryFeature.site(of:)` names it for people.
		case site(String)
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case queryChanged(String)
			case open(BrowsingHistoryEntry.ID)
			case delete(BrowsingHistoryEntry.ID)
			case deleteDay(Date)
			case deleteSite(BrowsingHistoryEntry.ID)
			case deletionConfirmed
			case deletionCancelled
		}

		@CasePathable
		public enum Event: Sendable {}

		@CasePathable
		public enum Delegate: Sendable {
			/// Open this page in a new tab.
			case open(URL)

			/// Remove these pages from the profile's history, the way the command bar's Delete from
			/// History does (DEV-810).
			case remove(Profile.ID, BrowsingHistoryRemoval)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.calendar)
	private var calendar

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.queryChanged) { state, query in
			state.query = query
			return .none
		}

		Pullback(\.ui.open) { state, id in
			guard let entry = state.entries.first(where: { $0.id == id }) else { return .none }
			return .send(.delegate(.open(entry.url)))
		}

		Pullback(\.ui.delete) { state, id in
			guard
				let profileID = state.profileID,
				let entry = state.entries.first(where: { $0.id == id })
			else { return .none }

			return .send(.delegate(.remove(profileID, .entries([entry.id]))))
		}

		Pullback(\.ui.deleteDay) { state, date in
			let deletion = Deletion.day(calendar.startOfDay(for: date))
			guard state.profileID != nil, !state.entries(of: deletion, in: calendar).isEmpty
			else { return .none }

			state.pendingDeletion = deletion
			return .none
		}

		Pullback(\.ui.deleteSite) { state, id in
			guard
				state.profileID != nil,
				let entry = state.entries.first(where: { $0.id == id }),
				let host = entry.url.host(),
				!host.isEmpty
			else { return .none }

			// The host as it is: the removal normalizes it once, as it does each entry's.
			state.pendingDeletion = .site(host)
			return .none
		}

		Pullback(\.ui.deletionConfirmed) { state in
			guard
				let deletion = state.pendingDeletion,
				let profileID = state.profileID
			else { return .none }

			state.pendingDeletion = nil
			switch deletion {
			case let .day(start):
				// Read at confirmation: pages visited that day while the dialog was up go too.
				let ids = Set(state.entries(of: .day(start), in: calendar).map(\.id))
				guard !ids.isEmpty else { return .none }
				return .send(.delegate(.remove(profileID, .entries(ids))))

			case let .site(site):
				return .send(.delegate(.remove(profileID, .site(site))))
			}
		}

		Pullback(\.ui.deletionCancelled) { state in
			state.pendingDeletion = nil
			return .none
		}
	}

	/// A page's site: its host without a leading `www.`, so both spellings delete together.
	public static func site(of url: URL) -> String? {
		guard let host = url.host(), !host.isEmpty else { return nil }
		return BrowsingHistoryRemoval.siteKey(host)
	}
}
