import AppLinkClient
import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// Arx's prompt for a page's link to another app (DEV-857), in place of Chrome's
/// "Open app?" dialog on the page's window.
///
/// A handler's script is announced with Air Traffic Control's verb, Land, so it's clear Arx
/// runs the person's script rather than opening an app. A script that fails or times out
/// shows its error here, with Open app as the fallback.
@Reducer
public struct AppLinkPrompt {
	@ObservableState
	public struct State: Equatable, Identifiable {
		public let id: UUID

		/// The window the prompt is shown on: the page's own.
		public let windowID: UUID
		public let request: BrowserExternalLink
		public let handler: AppLinkHandler

		/// The handling for the page's profile; Open app in private windows.
		public let handling: AppLinkHandling

		/// The page's profile name, nil in a private window.
		public let profileName: String?

		/// The app Open opens: the handling's chosen one, or for a script the handler's fallback.
		/// Nil for System default (DEV-862).
		public let application: AppLinkApplication?

		/// The chosen app's name, the app macOS opens the link with, or the handler's name.
		public var appName: String

		/// Where the app Open opens is, for its icon: the chosen one's, else the one macOS uses.
		public var appPath: String?

		/// Why the script can't take this link. The prompt then offers Open app only.
		public let failure: AppLinkError?

		/// The page's site is always allowed for this handler: the prompt shows only on failure.
		public let skipsPrompt: Bool

		/// The handler is one of the person's. False for a link no handler takes (DEV-1259):
		/// Always allow then saves the handler, with the site, as a new app link.
		public let isSaved: Bool

		/// Arx's own place for the link (DEV-1193): only for Arx's built-in handler of another
		/// browser's pages, such as `chrome://settings/passwords`. Open in Arx offers it.
		public let arxPlace: SettingsAddress?
		public var phase: Phase
		public var showsScript: Bool
		public var alwaysAllow: Bool
		public var copied: Bool

		public init(
			id: UUID,
			windowID: UUID,
			request: BrowserExternalLink,
			decision: AppLinkDecision,
			profileName: String?,
			appName: String?,
			appPath: String? = nil
		) {
			self.id = id
			self.windowID = windowID
			self.request = request
			self.handler = decision.handler
			let arxPlace = decision.handler.isBuiltIn ? BrowserSchemeLink(string: request.link)?.place : nil
			self.arxPlace = arxPlace

			// Open in Arx with no place for the link opens the browser instead.
			self.handling = decision.handling == .openInArx && arxPlace == nil
			? decision.handler.fallback
			: decision.handling
			self.profileName = request.isPrivate ? nil : profileName
			let application = self.handling.opensApp
			? self.handling.application
			: decision.handler.fallback.application
			self.application = application
			self.appName = application?.name
				?? appName.flatMap { $0.isEmpty ? nil : $0 }
				?? decision.handler.name
			self.appPath = application?.path ?? appPath
			self.failure = decision.failure
			self.skipsPrompt = decision.skipsPrompt
			self.isSaved = decision.isSaved
			self.phase = .asking
			self.showsScript = false
			self.alwaysAllow = false
			self.copied = false
		}

		/// The main action is Open in Arx (DEV-1193).
		public var opensInArx: Bool {
			handling == .openInArx && arxPlace != nil
		}

		/// The script that runs on confirm, when one may.
		public var script: String? {
			failure == nil ? handling.script : nil
		}

		public var isPresented: Bool {
			!(skipsPrompt && phase == .running)
		}

		/// The script or the app failed.
		public var isFailed: Bool {
			if case .failed = phase { return true }
			return false
		}

		/// The page that asked moved on: nothing may run or open, and the prompt can only close.
		public mutating func sourceDidChange() {
			guard phase != .running else { return }
			phase = .sourceChanged
			alwaysAllow = false
		}

		/// Always allow needs a known site and a handling the person can see. Private windows
		/// never remember a site: the grant would outlive the window and reach every profile.
		public var offersAlwaysAllow: Bool {
			!request.isPrivate && AppLinkHandler.mayRemember(request.sourceOrigin) && failure == nil
		}

		/// "Claude Work" for Land in Claude Work; the app's name alone without a profile.
		public var landingName: String {
			[handler.name, profileName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
		}
	}

	public enum Phase: Equatable, Sendable {
		case asking
		case running

		/// The script failed or timed out, or the app didn't open. Open app stays available.
		case failed(Failure)

		/// The page that asked moved on before the person answered. Nothing runs or opens.
		case sourceChanged
	}

	public enum Failure: Equatable, Sendable {
		case script(status: Int32, message: String, log: URL?)
		case timedOut(log: URL?)
		case unavailable(String)
		case appDidNotOpen

		/// The chosen app is gone. Only System default is offered; nothing opens on its own.
		case applicationMissing(AppLinkApplication)
	}

	@CasePathable
	public enum Action: Sendable {
		/// Runs the handling without asking, for a site that's always allowed.
		case start
		case scriptFinished(AppLinkScriptOutcome)
		case appOpened(AppLinkOpenOutcome, AppLinkApplication?)
		case copiedExpired
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			/// The main button: Land in ‹handler› ‹profile›, or Open ‹app›.
			case confirm

			/// Open app, the fallback after a script failed.
			case openApp

			/// Open with whatever macOS assigns to the scheme, offered when the chosen app is gone.
			case openWithSystemDefault
			case cancel

			/// Open in Arx, beside Open ‹app› when Arx has a place for the link (DEV-1193).
			case openInArx
			case copyLink
			case toggleScript
			case alwaysAllowChanged(Bool)
		}

		@CasePathable
		public enum Event: Sendable {}

		@CasePathable
		public enum Delegate: Sendable {
			/// Remember the page's origin for this handler.
			case alwaysAllow(handlerID: UUID, origin: String)

			/// Save the prompt's handler, for the link no handler took, with the page's origin
			/// always allowed (DEV-1259).
			case saveHandler(AppLinkHandler, link: String)

			/// The chosen app was found somewhere else: keep where it is now (DEV-862).
			case applicationMoved(from: AppLinkApplication, to: AppLinkApplication)

			/// Open Arx's place for the link (DEV-1193), for the page's window and profile.
			case openInArx(SettingsAddress, windowID: UUID, profileID: Profile.ID?)

			/// The prompt is done; the app removes it.
			case finished
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.appLinks)
	private var appLinks

	@Dependency(\.continuousClock)
	private var clock

	private enum Cancellation: Hashable { case copied }

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.start) { state in
			guard state.skipsPrompt, state.phase == .asking else { return .none }
			return carryOut(&state)
		}

		Pullback(\.ui.confirm) { state in
			guard state.phase == .asking else { return .none }
			var effects: [Effect<Action>] = []
			if state.alwaysAllow, state.offersAlwaysAllow, let origin = state.request.sourceOrigin {
				if state.isSaved {
					effects.append(.send(.delegate(.alwaysAllow(handlerID: state.handler.id, origin: origin))))
				} else {
					var handler = state.handler
					handler.alwaysAllowedOrigins = [origin]
					effects.append(.send(.delegate(.saveHandler(handler, link: state.request.link))))
				}
			}
			effects.append(carryOut(&state))
			return .merge(effects)
		}

		Pullback(\.ui.openApp) { state in
			switch state.phase {
			// Always allow remembers the main action; an alternative waits until it's unticked.
			case .asking where state.alwaysAllow && state.arxPlace != nil: return .none
			case .asking, .failed: return open(&state, with: state.application)
			case .running, .sourceChanged: return .none
			}
		}

		// Only once the chosen app turned out to be missing: never instead of it unasked.
		Pullback(\.ui.openWithSystemDefault) { state in
			guard case .failed(.applicationMissing) = state.phase else { return .none }
			return open(&state, with: nil)
		}

		Pullback(\.ui.openInArx) { state in
			guard
				state.phase == .asking && !state.alwaysAllow || state.isFailed,
				let place = state.arxPlace
			else { return .none }
			return openInArx(place, &state)
		}

		Pullback(\.ui.cancel) { state in
			guard state.phase != .running else { return .none }
			return .send(.delegate(.finished))
		}

		Pullback(\.ui.copyLink) { state in
			let link = state.request.link
			state.copied = true
			return .run { [appLinks, clock] send in
				await appLinks.copyLink(link)
				try await clock.sleep(for: .seconds(1.5))
				await send(.copiedExpired)
			}
			.cancellable(id: Cancellation.copied, cancelInFlight: true)
		}

		Pullback(\.copiedExpired) { state in
			state.copied = false
			return .none
		}

		Pullback(\.ui.toggleScript) { state in
			state.showsScript.toggle()
			return .none
		}

		Pullback(\.ui.alwaysAllowChanged) { state, value in
			state.alwaysAllow = value && state.offersAlwaysAllow
			return .none
		}

		Pullback(\.scriptFinished) { state, outcome in
			guard state.phase == .running else { return .none }
			switch outcome {
			case .succeeded:
				return .send(.delegate(.finished))
			case let .failed(status, message, log):
				state.phase = .failed(.script(status: status, message: message, log: log))
			case let .timedOut(log):
				state.phase = .failed(.timedOut(log: log))
			case let .unavailable(reason):
				state.phase = .failed(.unavailable(reason))
			}
			return .none
		}

		Pullback(\.appOpened) { state, value in
			let (outcome, application) = value
			guard state.phase == .running else { return .none }
			switch outcome {
			case .opened:
				return .send(.delegate(.finished))
			case let .openedMoved(moved):
				guard let application else { return .send(.delegate(.finished)) }
				return .concatenate(
					.send(.delegate(.applicationMoved(from: application, to: moved))),
					.send(.delegate(.finished))
				)
			case .didNotOpen:
				state.phase = .failed(.appDidNotOpen)
			case .applicationMissing:
				state.phase = application.map { .failed(.applicationMissing($0)) } ?? .failed(.appDidNotOpen)
			}
			return .none
		}
	}

	/// Runs the script for this profile, or opens Arx's place or the app when there's none to run.
	private func carryOut(_ state: inout State) -> Effect<Action> {
		if state.opensInArx, let place = state.arxPlace { return openInArx(place, &state) }
		guard let script = state.script else { return open(&state, with: state.application) }
		state.phase = .running
		let run = AppLinkScript(
			script: script,
			link: state.request.link,
			scheme: state.handler.scheme,
			profileID: state.request.profileID.rawValue.uuidString,
			profileName: state.profileName ?? "",
			sourceOrigin: state.request.sourceOrigin ?? ""
		)
		return .run { [appLinks] send in
			await send(.scriptFinished(appLinks.runScript(run)))
		}
	}

	/// Arx's own place, for the page's window and profile; the prompt is then done.
	private func openInArx(
		_ place: SettingsAddress,
		_ state: inout State
	) -> Effect<Action> {
		state.phase = .running
		let request = state.request
		return .concatenate(
			.send(.delegate(.openInArx(
				place,
				windowID: state.windowID,
				profileID: request.isPrivate ? nil : request.profileID
			))),
			.send(.delegate(.finished))
		)
	}

	/// Opens the link in `application`, or System default when nil.
	private func open(
		_ state: inout State,
		with application: AppLinkApplication?
	) -> Effect<Action> {
		guard let url = URL(string: state.request.link) else {
			state.phase = .failed(.appDidNotOpen)
			return .none
		}
		state.phase = .running
		return .run { [appLinks] send in
			await send(.appOpened(appLinks.openApp(url, application), application))
		}
	}
}
