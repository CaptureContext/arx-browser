import AppLinkClient
import BrowserCore
import BrowserEngineClient
import Foundation
import LittleArxFeature
import MainFeature
import _ComposableArchitecture

/// A page's link for another app, taken from the engine, and the window its prompt goes on.
public struct AppLinkPresentation: Equatable, Sendable {
	public let link: BrowserExternalLink
	public let windowID: UUID

	public init(
		link: BrowserExternalLink,
		windowID: UUID
	) {
		self.link = link
		self.windowID = windowID
	}
}

extension AppFeature.State {
	/// The prompt's window when Arx takes `link`: a handler matches it, or none does and macOS
	/// has an app for its scheme (DEV-1259), and its tab is on screen in a window. Nil leaves
	/// the link to Chrome, which without an app for the scheme neither asks nor opens anything.
	///
	/// - Parameters:
	///   - hasSystemApp: macOS has an app for the link's scheme (`AppLinkClient.appPath`).
	internal func appLinkPresentation(
		for link: BrowserExternalLink,
		hasSystemApp: Bool
	) -> AppLinkPresentation? {
		// Arx's built-in handler for Chrome's pages (DEV-1193) takes a link only while its
		// feature flag is on, and never one of Chromium's debug or destructive pages.
		if
			let url = URL(string: link.link),
			settings.routingPreferences.appLinks.handler(for: url)?.isBuiltIn == true,
			!FeatureFlag.browserLinks.isOn() || BrowserSchemeLink(url)?.isRefused != false
		{
			return nil
		}
		let preferences = settings.routingPreferences.appLinks
		let isMatched = preferences.decide(
			link: link.link,
			profileID: link.profileID,
			isPrivate: link.isPrivate,
			sourceOrigin: link.sourceOrigin
		) != nil

		// Every link for another app gets Arx's prompt, never Chrome's dialog (DEV-1259). A link
		// that comes while a handler runs is taken too, and `presentAppLink` drops it, unless it
		// comes from the running prompt's own page: the engine keeps one source token per page,
		// and taking this link would replace the one the prompt's Open app fallback checks.
		let isRunningPromptsPage = appLinkPrompt.map { $0.phase == .running && $0.request.sourceTabID == link.sourceTabID } ?? false
		guard
			!shouldQuit,
			!checkingQuit,
			!isRunningPromptsPage,
			isMatched || hasSystemApp && preferences.unmatchedScheme(link: link.link) != nil,
			let placement = nativeContentPlacement(
				tabID: link.sourceTabID,
				profileID: link.profileID,
				isPrivate: link.isPrivate
			)
		else { return nil }

		return .init(link: link, windowID: placement.windowID)
	}

	/// The prompt for `presentation`, decided again against the current settings. A link no
	/// handler takes asks about `appName`, the app macOS assigns, with a handler that isn't saved
	/// (DEV-1259); without one there's no prompt.
	internal func appLinkPrompt(
		for presentation: AppLinkPresentation,
		id: UUID,
		appName: String?,
		appPath: String? = nil
	) -> AppLinkPrompt.State? {
		let link = presentation.link
		let preferences = settings.routingPreferences.appLinks
		guard
			let decision = preferences.decide(
				link: link.link,
				profileID: link.profileID,
				isPrivate: link.isPrivate,
				sourceOrigin: link.sourceOrigin
			) ?? appName.flatMap({ preferences.decideUnmatched(link: link.link, appName: $0, handlerID: id) })
		else { return nil }

		return .init(
			id: id,
			windowID: presentation.windowID,
			request: link,
			decision: decision,
			profileName: link.isPrivate ? nil : workspace.profiles[id: link.profileID]?.name,
			appName: appName,
			appPath: appPath
		)
	}
}

/// Shows Arx's prompt for a page's app link, runs what it confirms, and remembers Always
/// allow with the handler in the routing preferences.
@Reducer
internal struct AppLinkRouting {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.uuid)
	private var uuid

	@Dependency(\.appLinks)
	private var appLinks

	@Dependency(\.browserEngine)
	private var engine

	internal var body: some ReducerOf<Self> {
		// Before the prompt acts: the page that asked must still show the same document, as
		// Chrome's guarded dialog requires.
		Reduce { state, action in
			guard
				let prompt = state.appLinkPrompt,
				Self.actsOnTheLink(action)
			else { return .none }

			let request = prompt.request
			let client = engine
			let isCurrent = MainActor.assumeIsolated {
				client.snapshot(request.sourceTabID)?.documentRevision == request.sourceDocumentRevision

				// The frame that asked, checked natively with Chrome's own source guard.
				&& client.externalLinkIsCurrent(request.sourceTabID, request.sourceToken)
			}
			guard !isCurrent else { return .none }

			// Changed here, before the prompt sees the action, so it runs and opens nothing.
			state.appLinkPrompt?.sourceDidChange()
			return .none
		}

		CombineReducers {
			Pullback(\.presentAppLink) { state, presentation in

				// A running script keeps its prompt; links are declined meanwhile, so this one
				// raced it and is dropped.
				if let current = state.appLinkPrompt, current.phase == .running { return .none }
				let client = appLinks
				let url = URL(string: presentation.link.link)
				let (appName, appPath) = url.map { url in
					MainActor.assumeIsolated { (client.appName(url), client.appPath(url)) }
				} ?? (nil, nil)
				guard let prompt = state.appLinkPrompt(for: presentation, id: uuid(), appName: appName, appPath: appPath)
				else { return .none }

				state.appLinkPrompt = prompt
				return prompt.skipsPrompt ? .send(.appLinkPrompt(.start)) : .none
			}

			Pullback(\.appLinkPrompt.delegate.alwaysAllow) { state, value in
				state.settings.$routingPreferences.withLock { preferences in
					guard
						let index = preferences.appLinks.handlers.firstIndex(where: { $0.id == value.handlerID }),
						!preferences.appLinks.handlers[index].alwaysAllowedOrigins.contains(value.origin)
					else { return }
					preferences.appLinks.handlers[index].alwaysAllowedOrigins.append(value.origin)
				}
				return .none
			}

			// Always allow on a link no handler took (DEV-1259) saves its handler as the person's
			// own app link, with the site. When a handler that takes the link was saved or switched
			// on while the prompt was open, nothing is saved: the site was allowed only the Open
			// the prompt showed, never that handler's own handling.
			Pullback(\.appLinkPrompt.delegate.saveHandler) { state, value in
				let (handler, link) = value
				state.settings.$routingPreferences.withLock { preferences in
					guard
						!preferences.appLinks.handlers.contains(where: { $0.id == handler.id }),
						preferences.appLinks.unmatchedScheme(link: link) == handler.scheme,
						(try? handler.validate()) != nil
					else { return }
					preferences.appLinks.handlers.append(handler)
				}
				return .none
			}

			// Every handler and handling that opens the app that moved follows it.
			Pullback(\.appLinkPrompt.delegate.applicationMoved) { state, value in
				let (old, moved) = value
				state.settings.$routingPreferences.withLock { preferences in
					preferences.appLinks.handlers = preferences.appLinks.handlers.map { $0.replacingApplication(old, with: moved) }
				}
				return .none
			}

			Pullback(\.appLinkPrompt.delegate.finished) { state in
				state.appLinkPrompt = nil
				return .none
			}
		}
		.ifLet(\.appLinkPrompt, action: \.appLinkPrompt) { AppLinkPrompt() }

		// Another app's link typed in a window's command bar (DEV-1189): the app macOS assigns
		// opens it, as the prompt's Open does. No page asked for it, so nothing asks again.
		Pullback(\.main.delegate.openAppLink) { _, url in
			openApp(url)
		}

		Pullback(\.windows) { _, action in
			guard case let .element(_, .delegate(.openAppLink(url))) = action else { return .none }
			return openApp(url)
		}

		Pullback(\.littleWindows) { _, action in
			guard case let .element(_, .delegate(.openAppLink(url))) = action else { return .none }
			return openApp(url)
		}
	}

	private func openApp(_ url: URL) -> Effect<Action> {
		.run { [appLinks] _ in
			_ = await appLinks.openApp(url, nil)
		}
	}

	private static func actsOnTheLink(_ action: Action) -> Bool {
		switch action {
		case .appLinkPrompt(.start),
			.appLinkPrompt(.ui(.confirm)),
			.appLinkPrompt(.ui(.openApp)),
			.appLinkPrompt(.ui(.openInArx)),
			.appLinkPrompt(.ui(.openWithSystemDefault)): true
		default: false
		}
	}
}
