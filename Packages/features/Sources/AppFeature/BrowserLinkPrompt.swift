import BrowserCore
import Foundation
import _ComposableArchitecture

/// "Arx can't open this" (DEV-1193): a `chrome://` or `arc://` link Arx has no place for, whose
/// browser isn't installed or didn't take it. A question about a `chrome://` link Arx can open
/// is App Links' prompt, through its built-in handler for Chrome's pages.
@Reducer
public struct BrowserLinkPrompt {
	@ObservableState
	public struct State: Equatable, Identifiable, Sendable {
		public let id: UUID

		/// Where the link came from: the window the notice is a sheet on.
		public let origin: Origin
		public let link: BrowserSchemeLink

		public init(
			id: UUID,
			origin: Origin,
			link: BrowserSchemeLink
		) {
			self.id = id
			self.origin = origin
			self.link = link
		}

		/// The window the notice is a sheet on: the page's own, or the main window for a link
		/// from another app.
		public var windowID: UUID { origin.windowID }

		public var source: Source { origin.source }
	}

	/// Where a link came from.
	public struct Origin: Equatable, Sendable {
		/// The window a notice about it goes on.
		public var windowID: UUID

		/// The profile of the page or window it came from, which Arx's place opens for; nil for a
		/// private one. A floating page's profile may differ from its window's.
		public var profileID: Profile.ID?
		public var source: Source

		public init(
			windowID: UUID,
			profileID: Profile.ID?,
			source: Source
		) {
			self.windowID = windowID
			self.profileID = profileID
			self.source = source
		}
	}

	public enum Source: Equatable, Sendable {
		/// A page's link.
		case page

		/// A link another app opened with Arx.
		case otherApp
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case delegate(Delegate)

		@CasePathable
		public enum UI: Sendable {
			/// OK or Escape.
			case dismissButtonTapped
		}

		@CasePathable
		public enum Delegate: Sendable {
			case dismissed(UUID)
		}
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.dismissButtonTapped) { state in
			.send(.delegate(.dismissed(state.id)))
		}
	}
}
