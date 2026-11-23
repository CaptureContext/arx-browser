import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation
import ViewerItemFeature
import _ComposableArchitecture

public enum PeekDestination: Equatable, Sendable {
	case tab
	case littleArx
}

/// A temporary presentation. The parent owns session transfer and workspace commits.
@Reducer
public struct PeekFeature {
	@ObservableState
	public struct State: Equatable, Identifiable {
		public let id: UUID
		public let source: Source
		public let isTemporary: Bool
		public var tab: BrowserCore.Tab
		public var viewer: ViewerItemFeature.State
		public var phase: Phase
		public var location: String
		public var locationFocusRequest: Int
		public var error: String?
		public var replacementURL: URL?
		public var orphanCloseRequested: Bool

		/// Where the link was clicked, in screen coordinates; nil for keyboard, menu, and routing.
		public let origin: CGPoint?

		public init(
			id: UUID,
			source: Source,
			tab: BrowserCore.Tab,
			isTemporary: Bool,
			origin: CGPoint? = nil,
			phase: Phase = .idle,
			locationFocusRequest: Int = 0,
			error: String? = nil,
			replacementURL: URL? = nil,
			orphanCloseRequested: Bool = false
		) {
			self.id = id
			self.origin = origin
			self.source = source
			self.tab = tab
			self.isTemporary = isTemporary
			self.viewer = .init()
			self.phase = phase
			self.location = tab.restoration.url.absoluteString
			self.locationFocusRequest = locationFocusRequest
			self.error = error
			self.replacementURL = replacementURL
			self.orphanCloseRequested = orphanCloseRequested
		}
	}

	public struct Source: Equatable, Sendable {
		public enum Host: Equatable, Sendable {
			case window
			case littleArx(generation: Int)
		}

		public let host: Host
		public let windowID: UUID
		public let paneID: UUID
		public let tabID: BrowserCore.Tab.ID?
		public let spaceID: Space.ID
		public let profileID: Profile.ID
		public let identity: String

		public init(
			windowID: UUID,
			paneID: UUID,
			tabID: BrowserCore.Tab.ID?,
			spaceID: Space.ID,
			profileID: Profile.ID,
			identity: String,
			host: Host = .window
		) {
			self.host = host
			self.windowID = windowID
			self.paneID = paneID
			self.tabID = tabID
			self.spaceID = spaceID
			self.profileID = profileID
			self.identity = identity
		}
	}

	public enum Phase: Equatable, Sendable {
		case idle
		case closing
		case replacing
		case promoting
		case releasing
	}

	@CasePathable
	public enum Action: Sendable {
		case viewer(ViewerItemFeature.Action)
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case task
			case close
			case focusLocation
			case locationChanged(String)
			case previewLocation
			case replace(URL)
			case promote(PeekDestination)
		}

		@CasePathable
		public enum Event: Sendable {
			case closeDecision(Bool)
			case promotionFailed(String)
		}

		@CasePathable
		public enum Delegate: Sendable {
			case close
			case replace(URL)
			case promote(PeekDestination)
			case navigation(BrowserCore.Tab.ID, BrowserNavigation)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.browserEngine)
	private var engine

	public init() {}

	public var body: some ReducerOf<Self> {
		Scope(state: \.viewer, action: \.viewer) { ViewerItemFeature() }
		Pullback(\.ui.task) { state in .send(.viewer(.show(state.tab))) }
		Pullback(\.ui.focusLocation) { state in
			guard state.phase == .idle else { return .none }
			state.locationFocusRequest += 1
			return .none
		}
		Pullback(\.ui.locationChanged) { state, location in
			state.location = location
			return .none
		}
		Pullback(\.ui.previewLocation) { state in
			guard let url = Self.previewURL(state.location) else {
				state.error = String.localized(.appUI.peek.invalidURL)
				return .none
			}
			return .send(.ui(.replace(url)))
		}
		Pullback(\.ui.replace) { state, url in
			guard
				state.phase == .idle,
				Self.previewURL(url.absoluteString) != nil
			else { return .none }
			state.phase = .replacing
			state.replacementURL = url
			state.error = nil
			return closeDecision(state)
		}
		Pullback(\.ui.close) { state in
			guard state.phase == .idle else { return .none }
			state.phase = .closing
			state.error = nil
			return closeDecision(state)
		}
		Pullback(\.event.closeDecision) { state, permitted in
			guard state.phase == .closing || state.phase == .replacing else { return .none }
			guard permitted else {
				state.phase = .idle
				state.replacementURL = nil
				return .none
			}
			if let replacement = state.replacementURL {
				return .send(.delegate(.replace(replacement)))
			}
			return .send(.delegate(.close))
		}
		Pullback(\.ui.promote) { state, destination in
			guard
				state.phase == .idle,
				state.isTemporary || destination == .tab
			else { return .none }
			state.phase = .promoting
			state.error = nil
			return .send(.delegate(.promote(destination)))
		}
		Pullback(\.event.promotionFailed) { state, message in
			state.phase = .idle
			state.error = message
			return .none
		}
		Pullback(\.viewer.delegate.navigation) { state, value in
			let (id, navigation) = value
			guard id == state.tab.id else { return .none }
			if !navigation.isLoading, navigation.errorCode == nil {
				if let url = navigation.url {
					state.tab.restoration.url = url
					state.location = url.absoluteString
				}
				if !navigation.title.isEmpty { state.tab.restoration.title = navigation.title }
			}
			return state.isTemporary ? .none : .send(.delegate(.navigation(id, navigation)))
		}
	}

	private func closeDecision(_ state: State) -> Effect<Action> {
		// Returning an existing session to its owner does not discard page state.
		guard state.isTemporary else { return .send(.event(.closeDecision(true))) }
		return .run { [engine, id = state.tab.id] send in
			let permitted = await engine.permitsClosing(id)
			guard !Task.isCancelled else { return }
			await send(.event(.closeDecision(permitted)))
		}
	}

	public static func previewURL(_ text: String) -> URL? {
		let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard
			let components = URLComponents(string: trimmedText),
			["http", "https"].contains(components.scheme?.lowercased() ?? ""),
			components.host?.isEmpty == false,
			components.user == nil,
			components.password == nil
		else { return nil }
		return components.url
	}
}

extension PeekFeature.State {
	/// The tab this Peek was opened from, with the site it shows, for that tab's sidebar row and
	/// Favorite tile (DEV-1224). `nil` for a Peek that didn't come from a tab, and once it's
	/// released into a tab or Little Arx.
	public var peekedTab: BrowserPeekedTab? {
		guard let tabID = source.tabID, phase != .releasing, phase != .promoting else { return nil }

		let url: URL = viewer.navigation.url ?? tab.restoration.url
		let title: String = viewer.navigation.title.isEmpty ? tab.restoration.title : viewer.navigation.title
		return .init(
			tabID: tabID.rawValue,
			siteIcon: .init(profileID: tab.profileID.rawValue, pageURL: url),
			title: title.isEmpty ? url.host() ?? url.absoluteString : title
		)
	}
}
