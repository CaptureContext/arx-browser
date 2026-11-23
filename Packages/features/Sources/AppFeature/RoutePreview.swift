import BrowserCore
import Foundation
import _ComposableArchitecture

public struct RoutePreview: Equatable, Identifiable, Sendable {
	public let id: UUID
	public let candidate: Candidate
	public var override: RoutingDestination?
	public var decision: RoutingDecision
	public var failure: Failure?

	public init(
		id: UUID,
		candidate: Candidate,
		decision: RoutingDecision
	) {
		self.id = id
		self.candidate = candidate
		self.override = nil
		self.decision = decision
		self.failure = nil
	}

	public struct Candidate: Equatable, Sendable {
		public let url: URL
		public let source: Source

		public init(
			url: URL,
			source: Source
		) {
			self.url = url
			self.source = source
		}
	}

	public struct Source: Equatable, Sendable {
		public let target: AppFeature.CommandTarget
		public let windowID: UUID
		public let tabID: BrowserCore.Tab.ID
		public let profileID: Profile.ID
		public let spaceID: Space.ID

		public init(
			target: AppFeature.CommandTarget,
			windowID: UUID,
			tabID: BrowserCore.Tab.ID,
			profileID: Profile.ID,
			spaceID: Space.ID
		) {
			self.target = target
			self.windowID = windowID
			self.tabID = tabID
			self.profileID = profileID
			self.spaceID = spaceID
		}
	}

	public enum Failure: Equatable, Sendable {
		case sourceChanged
		case destinationChanged
	}

	/// The binding retains the presentation identity even when SwiftUI writes a nil item on dismissal.
	public struct Presentation: Equatable, Sendable {
		public let id: UUID?
		public var value: RoutePreview?

		public init(
			id: UUID?,
			value: RoutePreview?
		) {
			self.id = id
			self.value = value
		}
	}
}

@CasePathable
public enum RoutePreviewAction: Sendable {
	case ui(UI)
	case event(Event)
	case delegate(Delegate)
	case observation(ObservationAction<Observation>)

	@CasePathable
	public enum UI: Sendable {
		case present(RoutePreview.Candidate)
		case choose(UUID, RoutingDestination?)
		case refresh(UUID)
		case confirm(UUID)
		case cancel(UUID)
		case presentationChanged(RoutePreview.Presentation)
	}

	@CasePathable
	public enum Event: Sendable {}

	@CasePathable
	public enum Delegate: Sendable {}

	@CasePathable
	public enum Observation: Equatable, Sendable {}
}
