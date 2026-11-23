import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// The fallback prompt (DEV-877): a Chromium page asked for protected video or music, which
/// Arx's Chromium can't play. "Open in WebKit" lists the site and moves the page; "Stay on Page"
/// leaves it, and "Don't ask again for this site" remembers that.
///
/// With WebKit pages off, a listed site's page is told why it can't play instead, and offered
/// the site's own app when it's installed (DEV-1000).
@Reducer
public struct WebKitPrompt {
	@ObservableState
	public struct State: Equatable, Identifiable {
		public let id: UUID

		/// The window showing the page, where the prompt is a sheet.
		public let windowID: UUID
		public let request: ProtectedMediaRequest
		public let kind: Kind
		public var dontAskAgain: Bool

		public init(
			id: UUID,
			windowID: UUID,
			request: ProtectedMediaRequest,
			kind: Kind = .offer,
			dontAskAgain: Bool = false
		) {
			self.id = id
			self.windowID = windowID
			self.request = request
			self.kind = kind
			self.dontAskAgain = dontAskAgain
		}

		/// The site as the title names it.
		public var host: String {
			let host = request.url.host() ?? request.url.absoluteString
			return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
		}
	}

	public enum Kind: Equatable, Sendable {
		/// WebKit pages are on: the page may move there.
		case offer

		/// WebKit pages are off: the page can't play, and the site's app may (DEV-1000).
		case unavailable(app: SiteApp?)
	}

	/// The installed app that plays the site, and the link that opens the page's item in it.
	public struct SiteApp: Equatable, Sendable {
		public var name: String
		public var url: URL

		/// Where the app is, for its icon.
		public var path: String?

		public init(
			name: String,
			url: URL,
			path: String? = nil
		) {
			self.name = name
			self.url = url
			self.path = path
		}
	}

	public enum Answer: Equatable, Sendable {
		case openInWebKit
		case openApp(URL, dontAskAgain: Bool)
		case stay(dontAskAgain: Bool)
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case openInWebKitButtonTapped
			case openAppButtonTapped
			case stayButtonTapped
			case dontAskAgainChanged(Bool)
		}

		@CasePathable
		public enum Event: Sendable {}

		@CasePathable
		public enum Delegate: Sendable {
			case answered(ProtectedMediaRequest, Answer)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.dontAskAgainChanged) { state, isOn in
			state.dontAskAgain = isOn
			return .none
		}

		Pullback(\.ui.openInWebKitButtonTapped) { state in
			.send(.delegate(.answered(state.request, .openInWebKit)))
		}

		Pullback(\.ui.openAppButtonTapped) { state in
			guard case let .unavailable(app?) = state.kind else { return .none }
			return .send(.delegate(.answered(state.request, .openApp(app.url, dontAskAgain: state.dontAskAgain))))
		}

		Pullback(\.ui.stayButtonTapped) { state in
			.send(.delegate(.answered(state.request, .stay(dontAskAgain: state.dontAskAgain))))
		}
	}
}
