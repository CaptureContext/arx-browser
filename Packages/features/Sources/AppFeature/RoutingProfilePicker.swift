import BrowserCore
import Foundation
import _ComposableArchitecture

/// The panel at the pointer that asks which profile a link opens in, when its route asks for a
/// destination (DEV-858). Return opens the link in Little Arx, in the chosen profile's most
/// recent space. Esc or losing focus drops the link, and nothing loads before a choice.
public struct RoutingProfilePicker: Equatable, Sendable {
	/// The request in `RoutingInbox.requests` the picker answers.
	public let requestID: UUID
	public let url: URL

	/// Most recent first: the profile of the space in front, then of the spaces used before it,
	/// then the rest in sidebar order.
	public let options: [Option]
	public var query: String
	public var highlightedID: Profile.ID?

	public init(
		requestID: UUID,
		url: URL,
		options: [Option],
		query: String = "",
		highlightedID: Profile.ID? = nil
	) {
		self.requestID = requestID
		self.url = url
		self.options = options
		self.query = query
		self.highlightedID = highlightedID ?? options.first?.id
	}

	/// The options whose profile or space name contains the query.
	public var results: [Option] {
		options.filter { $0.matches(query) }
	}

	/// The option Return opens: the highlighted one when it's still listed, else the first.
	public var selection: Option? {
		let results = results
		return results.first { $0.id == highlightedID } ?? results.first
	}

	public struct Option: Equatable, Identifiable, Sendable {
		public let id: Profile.ID
		public let name: String

		/// The space the link would open in: the profile's most recent one.
		public let spaceID: Space.ID
		public let spaceName: String
		public let spaceIcon: String?

		public init(
			id: Profile.ID,
			name: String,
			spaceID: Space.ID,
			spaceName: String,
			spaceIcon: String? = nil
		) {
			self.id = id
			self.name = name
			self.spaceID = spaceID
			self.spaceName = spaceName
			self.spaceIcon = spaceIcon
		}

		public func matches(_ query: String) -> Bool {
			let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
			return query.isEmpty
			|| name.localizedCaseInsensitiveContains(query)
			|| spaceName.localizedCaseInsensitiveContains(query)
		}
	}

	/// Every profile with a space, most recently used first. A profile's place is set by its
	/// first space in `currentSpaceID` followed by `recentSpaceIDs`, the order `.profile`
	/// routes already use to pick the space.
	public static func options(
		organization: BrowserOrganization,
		currentSpaceID: Space.ID?,
		recentSpaceIDs: [Space.ID]
	) -> [Option] {
		let recent = (currentSpaceID.map { [$0] } ?? []) + recentSpaceIDs
		var order: [Profile.ID] = []
		for spaceID in recent {
			guard
				let profileID = organization.spaces[id: spaceID]?.profileID,
				organization.profiles.ids.contains(profileID),
				!order.contains(profileID)
			else { continue }
			order.append(profileID)
		}
		order += organization.profiles.ids.filter { !order.contains($0) }

		return order.compactMap { profileID in
			guard
				let profile = organization.profiles[id: profileID],
				let target = try? URLRouter.resolve(
					.init(scope: .profile(profileID)),
					preferences: .init(),
					organization: organization,
					currentSpaceID: currentSpaceID,
					recentSpaceIDs: recentSpaceIDs
				),
				let space = organization.spaces[id: target.spaceID]
			else { return nil }
			return .init(
				id: profile.id,
				name: profile.name,
				spaceID: space.id,
				spaceName: space.name,
				spaceIcon: space.icon?.rawValue
			)
		}
	}
}

@CasePathable
public enum RoutingProfilePickerAction: Sendable {
	case ui(UI)
	case event(Event)
	case delegate(Delegate)
	case observation(ObservationAction<Observation>)

	@CasePathable
	public enum UI: Sendable {
		case setQuery(String)

		/// The arrow keys: -1 up, 1 down, stopping at either end.
		case move(Int)
		case highlight(Profile.ID)

		/// Return, or a click on a row after it highlights.
		case confirm

		/// ⌘1–⌘9: opens the link in the result with that number, counted from 1.
		case openNumber(Int)

		/// Esc.
		case cancel

		/// The panel stopped being key. It names its request, so a closing panel can't cancel
		/// the next link's picker.
		case lostFocus(UUID)
	}

	@CasePathable
	public enum Event: Sendable {
		/// A window can show the picker. Until then, and in headless runs, Ask uses the
		/// Incoming Links list.
		case hostAvailable
	}

	@CasePathable
	public enum Delegate: Sendable {}

	@CasePathable
	public enum Observation: Equatable, Sendable {}
}

@Reducer
internal struct RoutingProfilePicking {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.profilePicker.event.hostAvailable) { state in
			state.routingInbox.picksProfileAtPointer = true
			return .none
		}

		Pullback(\.profilePicker.ui.setQuery) { state, query in

			// The field writes its text back when editing ends and starts again; the same text
			// keeps the highlight where the arrow keys left it.
			guard var picker = state.routingInbox.picker, picker.query != query else { return .none }
			picker.query = query
			picker.highlightedID = picker.results.first?.id
			state.routingInbox.picker = picker
			return .none
		}

		Pullback(\.profilePicker.ui.move) { state, offset in
			guard var picker = state.routingInbox.picker else { return .none }
			let results = picker.results
			guard !results.isEmpty else { return .none }
			let current = results.firstIndex { $0.id == picker.highlightedID } ?? -offset
			picker.highlightedID = results[min(max(current + offset, 0), results.count - 1)].id
			state.routingInbox.picker = picker
			return .none
		}

		Pullback(\.profilePicker.ui.highlight) { state, id in
			guard
				var picker = state.routingInbox.picker,
				picker.results.contains(where: { $0.id == id })
			else { return .none }
			picker.highlightedID = id
			state.routingInbox.picker = picker
			return .none
		}

		Pullback(\.profilePicker.ui.confirm) { state in
			guard let picker = state.routingInbox.picker else { return .none }
			guard let option = picker.selection else { return .none }
			state.routingInbox.picker = nil
			guard
				let index = state.routingInbox.requests.firstIndex(where: { $0.id == picker.requestID }),
				state.routingInbox.requests[index].status == .choosingProfile
			else { return .send(.processRouteQueue) }

			// The same route the Incoming Links list would take: this profile's most recent
			// space, which the queue resolves again when it opens.
			state.routingInbox.requests[index].override = .init(scope: .profile(option.id), mode: .littleArx)
			state.routingInbox.requests[index].status = .queued
			return .send(.processRouteQueue)
		}

		Pullback(\.profilePicker.ui.openNumber) { state, number in
			guard
				var picker = state.routingInbox.picker,
				picker.results.indices.contains(number - 1)
			else { return .none }
			picker.highlightedID = picker.results[number - 1].id
			state.routingInbox.picker = picker
			return .send(.profilePicker(.ui(.confirm)))
		}

		Pullback(\.profilePicker.ui.cancel) { state in
			guard let picker = state.routingInbox.picker else { return .none }
			return state.dismissProfilePicker(picker.requestID)
		}

		Pullback(\.profilePicker.ui.lostFocus) { state, requestID in
			state.dismissProfilePicker(requestID)
		}
	}
}

extension AppFeature.State {
	/// Drops the link the picker asks about, so nothing opens, and moves on to the next one.
	fileprivate mutating func dismissProfilePicker(_ requestID: UUID) -> Effect<AppFeature.Action> {
		guard routingInbox.picker?.requestID == requestID else { return .none }
		routingInbox.picker = nil
		routingInbox.requests.removeAll { $0.id == requestID && $0.status == .choosingProfile }
		return .send(.processRouteQueue)
	}

	/// Whether the queue asks about this link at the pointer rather than in Incoming Links: its
	/// route, or an override, asks, and a window can show the picker. A reviewed route (Route
	/// Current URL) names its target and never asks.
	internal func asksForProfileAtPointer(
		_ request: RoutingRequest,
		decision: RoutingDecision
	) -> Bool {
		guard
			routingInbox.picksProfileAtPointer,
			request.expectedTarget == nil,
			decision.result == .failure(.missingDestination)
		else { return false }
		return decision.destination == nil || decision.destination?.scope == .ask
	}
}
