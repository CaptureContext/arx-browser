import BrowserCore
import Foundation
import _ComposableArchitecture

/// Profile-scoped archive presentation. The parent commits workspace and engine transactions.
@Reducer
public struct TabArchiveFeature {
	@ObservableState
	public struct State: Equatable {
		public var entries: [ArchivedTab]
		public var spaces: IdentifiedArrayOf<Space>
		public var profiles: IdentifiedArrayOf<Profile>
		public var profileID: Profile.ID?
		public var profileName: String
		public var query: String

		/// Limits the list to tabs closed in one space. Only the Library's panel offers it.
		public var spaceFilter: Space.ID?
		public var selectedIDs: Set<ArchivedTab.ID>
		public var isPresented: Bool
		public var isWorking: Bool
		public var confirmsClear: Bool
		public var restorationConfirmation: RestorationConfirmation?
		public var message: String?

		public init(
			entries: [ArchivedTab] = [],
			spaces: IdentifiedArrayOf<Space> = [],
			profiles: IdentifiedArrayOf<Profile> = [],
			profileID: Profile.ID? = nil,
			profileName: String = "",
			query: String = "",
			spaceFilter: Space.ID? = nil,
			selectedIDs: Set<ArchivedTab.ID> = [],
			isPresented: Bool = false,
			isWorking: Bool = false,
			confirmsClear: Bool = false,
			restorationConfirmation: RestorationConfirmation? = nil,
			message: String? = nil
		) {
			self.entries = entries
			self.spaces = spaces
			self.profiles = profiles
			self.profileID = profileID
			self.profileName = profileName
			self.query = query
			self.spaceFilter = spaceFilter
			self.selectedIDs = selectedIDs
			self.isPresented = isPresented
			self.isWorking = isWorking
			self.confirmsClear = confirmsClear
			self.restorationConfirmation = restorationConfirmation
			self.message = message
		}

		/// How long the profile's regular tabs go unviewed before they're archived (DEV-1326), or
		/// nil without a profile.
		public var archiveInterval: TabArchiveInterval? {
			profileID.flatMap { profiles[id: $0]?.effectiveTabArchiveInterval }
		}

		public var visibleEntries: [ArchivedTab] {
			entries
				.filter { entry in
					entry.matches(query)
					&& (spaceFilter == nil || entry.originalSpaceID == spaceFilter)
				}
				.sorted { $0.closedAt > $1.closedAt }
		}
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
			case spaceFilterChanged(Space.ID?)
			case selectionChanged(Set<ArchivedTab.ID>)
			case restoreSelected(ArchiveDestination?)
			case restoreGroup(UUID, ArchiveDestination?)
			case restoreConfirmed(RestorationConfirmation)
			case restoreCancelled
			case deleteSelected
			case clearRequested
			case clearConfirmed
			case clearCancelled
			case dismissed
		}

		@CasePathable
		public enum Event: Sendable {}

		@CasePathable
		public enum Delegate: Sendable {
			case restore([ArchivedTab.ID], ArchiveDestination?)
			case delete([ArchivedTab.ID])
			case clear(Profile.ID)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.queryChanged) { state, query in
			state.query = query
			state.selectedIDs.formIntersection(state.visibleEntries.map(\.id))
			state.restorationConfirmation = nil
			return .none
		}
		Pullback(\.ui.spaceFilterChanged) { state, space in
			state.spaceFilter = space
			state.selectedIDs.formIntersection(state.visibleEntries.map(\.id))
			state.restorationConfirmation = nil
			return .none
		}
		Pullback(\.ui.selectionChanged) { state, ids in
			state.selectedIDs = ids.intersection(state.entries.map(\.id))
			state.restorationConfirmation = nil
			return .none
		}
		Pullback(\.ui.restoreSelected) { state, destination in
			guard !state.isWorking, !state.selectedIDs.isEmpty else { return .none }
			let entries = state.entries.filter { state.selectedIDs.contains($0.id) }
			return requestRestoration(entries, to: destination, state: &state)
		}

		Pullback(\.ui.restoreGroup) { state, value in
			guard !state.isWorking else { return .none }
			let entries = state.entries.filter { $0.groupID == value.0 }
			return requestRestoration(entries, to: value.1, state: &state)
		}

		Pullback(\.ui.restoreConfirmed) { state, confirmation in
			guard
				!state.isWorking,
				state.restorationConfirmation == confirmation,
				confirmation.matches(state)
			else { return .none }

			state.restorationConfirmation = nil
			let ids = confirmation.entries.map(\.id)
			return .send(.delegate(.restore(ids, confirmation.destination)))
		}

		Pullback(\.ui.restoreCancelled) { state in
			state.restorationConfirmation = nil
			return .none
		}
		Pullback(\.ui.deleteSelected) { state in
			guard !state.isWorking else { return .none }
			return .send(.delegate(.delete(Array(state.selectedIDs))))
		}
		Pullback(\.ui.clearRequested) { state in
			state.confirmsClear = !state.isWorking && !state.entries.isEmpty
			return .none
		}
		Pullback(\.ui.clearCancelled) { state in
			state.confirmsClear = false
			return .none
		}
		Pullback(\.ui.clearConfirmed) { state in
			guard
				state.confirmsClear,
				!state.isWorking,
				let profile = state.profileID
			else { return .none }
			state.confirmsClear = false
			return .send(.delegate(.clear(profile)))
		}
		Pullback(\.ui.dismissed) { state in
			guard !state.isWorking else { return .none }
			state.isPresented = false
			state.restorationConfirmation = nil
			return .none
		}
	}

	private func requestRestoration(
		_ entries: [ArchivedTab],
		to destination: ArchiveDestination?,
		state: inout State
	) -> Effect<Action> {
		guard !entries.isEmpty else { return .none }
		guard let destination else {
			return .send(.delegate(.restore(entries.map(\.id), nil)))
		}
		guard
			let space = state.spaces[id: destination.spaceID],
			space.profileID == destination.profileID,
			let profile = state.profiles[id: destination.profileID]
		else { return .none }

		guard destination.profileID != state.profileID else {
			return .send(.delegate(.restore(entries.map(\.id), destination)))
		}

		state.restorationConfirmation = .init(
			entries: entries,
			destination: destination,
			profileName: profile.name,
			spaceName: space.name
		)
		return .none
	}
}

extension TabArchiveFeature {
	public struct RestorationConfirmation: Equatable, Sendable {
		public let entries: [ArchivedTab]
		public let destination: ArchiveDestination
		public let profileName: String
		public let spaceName: String

		public init(
			entries: [ArchivedTab],
			destination: ArchiveDestination,
			profileName: String,
			spaceName: String
		) {
			self.entries = entries
			self.destination = destination
			self.profileName = profileName
			self.spaceName = spaceName
		}

		public func matches(_ state: State) -> Bool {
			state.spaces[id: destination.spaceID]?.profileID == destination.profileID
			&& state.profiles.ids.contains(destination.profileID)
			&& entries.allSatisfy { entry in
				entry.tab.profileID == state.profileID && state.entries.contains(entry)
			}
		}
	}
}
