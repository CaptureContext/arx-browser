import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// Asks before an `arx://` link a page opened drives Arx (DEV-929). Private pages' links and
/// Arx's own `arx://` pages are dropped; the engine has already kept Chrome from launching them.
@Reducer
internal struct ArxLinkConfirmations {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.uuid)
	private var uuid

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.event.arxLinkFromPage) { state, link in
			guard
				!state.shouldQuit,
				!state.checkingQuit,
				!link.isPrivate,
				let url = URL(string: link.link),
				let command = ArxURLCommand(url),
				let placement = state.nativeContentPlacement(
					tabID: link.sourceTabID,
					profileID: link.profileID,
					isPrivate: false
				)
			else { return .none }

			// The newest link replaces one still waiting: the engine keeps only the newest
			// link's source guard, and the window swaps its sheet.
			state.arxLinkConfirmation = .init(
				id: uuid(),
				command: command,
				source: link.sourceOrigin ?? "",
				windowID: placement.windowID,
				sourceTabID: link.sourceTabID,
				sourceDocumentRevision: link.sourceDocumentRevision,
				sourceToken: link.sourceToken
			)
			return .none
		}

		Pullback(\.ui.confirmArxLink) { state, id in
			guard
				let confirmation = state.arxLinkConfirmation,
				confirmation.id == id
			else { return .none }

			state.arxLinkConfirmation = nil

			// The page or frame that asked must still be there, as for links to other apps.
			let client = engine
			let isCurrent = MainActor.assumeIsolated {
				client.snapshot(confirmation.sourceTabID)?.documentRevision == confirmation.sourceDocumentRevision
				&& client.externalLinkIsCurrent(confirmation.sourceTabID, confirmation.sourceToken)
			}
			guard isCurrent else { return .none }

			return .send(.ui(.arxURLCommand(confirmation.command)))
		}

		Pullback(\.ui.cancelArxLink) { state, id in
			if state.arxLinkConfirmation?.id == id { state.arxLinkConfirmation = nil }
			return .none
		}
	}
}
