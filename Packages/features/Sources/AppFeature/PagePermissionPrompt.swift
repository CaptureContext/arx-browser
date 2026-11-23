import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// The `ARX_PAGE_PROMPTS` feature flag (DEV-963): Arx draws a page's permission prompt itself,
/// in the family of the app link prompt, instead of the engine's `NSAlert`. Off by default.
///
/// Read once at launch: BrowserWindow then asks the engine (ABI56) to hand ordinary prompts to
/// the app, and `PagePermissionPromptRouting` shows them on the page's own window. Off, or with
/// an engine that can't, the engine's sheet shows as before.
public enum PagePrompts {
	public static let featureFlag: String = FeatureFlag.pagePrompts.name

	/// The environment first, then user defaults, as the other `ARX_*` feature flags read.
	/// `1`, `true` or `yes` turns it on; anything else, or nothing, keeps the engine's prompt.
	public static func isEnabled(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.pagePrompts.isOn(environment: environment, defaults: defaults)
	}
}

/// A page's permission request as the prompt shows it, read from the dialog the engine
/// describes through `dialog_bridge` (ABI31), the same one MCP's permission sheet reads.
public struct PagePermissionRequest: Equatable, Sendable {
	public enum Accuracy: Equatable, Hashable, Sendable {
		case approximate
		case precise
	}

	/// Binds an answer to this exact request.
	public var token: String

	/// The requesting site as people know it: `github.com`, with `https://` left out.
	public var site: String

	/// The site of the page that embeds the requesting frame, when that's another one.
	public var embedder: String?

	/// The permissions Arx names, in the order the page asked.
	public var permissions: [SitePermission]

	/// Chromium's wording for asks Arx has no name for.
	public var otherRequests: [String]

	/// Allow Once is offered when every ask supports a grant for this visit only.
	public var offersAllowOnce: Bool

	/// The location accuracies the person may pick, and the one picked first.
	public var accuracies: [Accuracy]
	public var initialAccuracy: Accuracy

	/// The page asked quietly: an affordance first, and the prompt only when it's clicked.
	public var quiet: Bool

	public init(
		token: String,
		site: String,
		embedder: String? = nil,
		permissions: [SitePermission],
		otherRequests: [String] = [],
		offersAllowOnce: Bool = false,
		accuracies: [Accuracy] = [],
		initialAccuracy: Accuracy = .approximate,
		quiet: Bool = false
	) {
		self.token = token
		self.site = site
		self.embedder = embedder
		self.permissions = permissions
		self.otherRequests = otherRequests
		self.offersAllowOnce = offersAllowOnce
		self.accuracies = accuracies
		self.initialAccuracy = initialAccuracy
		self.quiet = quiet
	}

	/// The request in a prompt the engine hands to the app (ABI56): its permissions by name,
	/// Chromium's wording for the others, whether Allow Once applies, and the location
	/// accuracies to pick from when the prompt offers a choice.
	public init(prompt: BrowserPagePermissionPrompt) {
		var permissions: [SitePermission] = []
		var others: [String] = []
		for (index, name) in prompt.permissions.enumerated() {
			if let permission = Self.permission(engineName: name) {
				if !permissions.contains(permission) { permissions.append(permission) }
			} else {
				others.append(prompt.fragments.indices.contains(index) ? prompt.fragments[index] : name)
			}
		}
		let initial: Accuracy = prompt.location?.initial == .precise ? .precise : .approximate
		self.init(
			token: String(prompt.token),
			site: Self.site(prompt.requestingOrigin),
			embedder: prompt.embeddingOrigin.map(Self.site),
			permissions: permissions,
			otherRequests: others,
			offersAllowOnce: prompt.allowOnce,
			// Approximate only, or an upgrade to precise, leaves one accuracy, shown but not picked.
			accuracies: Self.accuracies(prompt.location),
			initialAccuracy: initial,
			quiet: prompt.quiet
		)
	}

	/// The request in an ABI31 permission dialog: its origin is the requesting origin, then
	/// "Embedded in <origin>" for a frame of another site; its message is one line per ask, in
	/// Chromium's wording. ABI31 says neither whether Allow Once applies nor the location
	/// accuracies, so neither shows until the engine says so. Nil for any other dialog.
	public init?(dialog: BrowserPageDialog) {
		guard dialog.kind == .permission else { return nil }

		let origins = (dialog.origin ?? "")
			.split(separator: "\n")
			.map { $0.trimmingCharacters(in: .whitespaces) }
		guard let requesting = origins.first, !requesting.isEmpty else { return nil }

		let embedded = origins.dropFirst()
			.first { $0.hasPrefix(Self.embeddedPrefix) }
			.map { String($0.dropFirst(Self.embeddedPrefix.count)) }
		var permissions: [SitePermission] = []
		var others: [String] = []
		for line in dialog.message.split(separator: "\n").map(String.init) where !line.isEmpty {
			if let permission = Self.permission(named: line) {
				if !permissions.contains(permission) { permissions.append(permission) }
			} else {
				others.append(line)
			}
		}
		self.init(
			token: dialog.token,
			site: Self.site(requesting),
			embedder: embedded.map(Self.site),
			permissions: permissions,
			otherRequests: others
		)
	}

	private static let embeddedPrefix: String = "Embedded in "

	/// `https://github.com` reads as `github.com`; any other scheme stays, since it says
	/// something about the page.
	private static func site(_ origin: String) -> String {
		origin.hasPrefix("https://") ? String(origin.dropFirst("https://".count)) : origin
	}

	/// The accuracies a location prompt offers: both to pick from, or the one it's fixed to.
	private static func accuracies(_ location: BrowserPagePermissionPrompt.Location?) -> [Accuracy] {
		switch location?.choice {
		case .either: [.approximate, .precise]
		case .approximateOnly: [.approximate]
		case .upgradeToPrecise: [.precise]
		case nil: []
		}
	}

	/// The engine's names for the permissions Arx names (ABI56).
	private static func permission(engineName name: String) -> SitePermission? {
		switch name {
		case "notifications": .notifications
		case "camera": .camera
		case "microphone": .microphone
		case "geolocation": .location
		case "clipboard": .clipboard
		default: nil
		}
	}

	/// Chromium's message fragments for the permissions Arx names (`GetMessageTextFragment`).
	/// An ask it doesn't recognize keeps Chromium's wording.
	private static func permission(named fragment: String) -> SitePermission? {
		let text = fragment.lowercased()
		if text.contains("notification") { return .notifications }
		if text.contains("camera") { return .camera }
		if text.contains("microphone") { return .microphone }
		if text.contains("location") { return .location }
		if text.contains("clipboard") { return .clipboard }
		return nil
	}
}

/// Arx's site permission prompt (DEV-963). The person's choice reaches the host as one answer;
/// the host hands it to the engine's permission prompt delegate, which rechecks the source.
@Reducer
public struct PagePermissionPrompt {
	@ObservableState
	public struct State: Equatable, Identifiable {
		public var id: String { request.token }
		public var windowID: UUID
		public var tabID: BrowserCore.Tab.ID
		public var request: PagePermissionRequest
		public var accuracy: PagePermissionRequest.Accuracy

		/// Shown as a prompt; a quiet request waits behind its affordance until it's clicked.
		public var isRevealed: Bool

		/// Answered: the buttons stay put until the host closes the prompt.
		public var isAnswered: Bool

		public init(
			windowID: UUID,
			tabID: BrowserCore.Tab.ID,
			request: PagePermissionRequest
		) {
			self.windowID = windowID
			self.tabID = tabID
			self.request = request
			self.accuracy = request.initialAccuracy
			self.isRevealed = !request.quiet
			self.isAnswered = false
		}
	}

	/// What the person chose. Cancel dismisses: the page may ask again, and it's never Block.
	public enum Decision: Equatable, Sendable {
		case allow
		case allowOnce
		case block
		case dismiss
	}

	public struct Answer: Equatable, Sendable {
		public var token: String
		public var decision: Decision

		/// The accuracy picked, for a location ask that offered a choice.
		public var accuracy: PagePermissionRequest.Accuracy?

		public init(
			token: String,
			decision: Decision,
			accuracy: PagePermissionRequest.Accuracy?
		) {
			self.token = token
			self.decision = decision
			self.accuracy = accuracy
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
			/// A quiet request's affordance was clicked: show the prompt.
			case review
			case allow
			case allowOnce
			case block
			case cancel
			case accuracyChanged(PagePermissionRequest.Accuracy)
		}

		@CasePathable
		public enum Event: Sendable {}

		@CasePathable
		public enum Delegate: Sendable {
			case answered(Answer)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.review) { state in
			state.isRevealed = true
			return .none
		}
		Pullback(\.ui.allow) { state in answer(.allow, state: &state) }
		Pullback(\.ui.allowOnce) { state in
			guard state.request.offersAllowOnce else { return .none }

			return answer(.allowOnce, state: &state)
		}
		Pullback(\.ui.block) { state in answer(.block, state: &state) }
		Pullback(\.ui.cancel) { state in answer(.dismiss, state: &state) }

		Pullback(\.ui.accuracyChanged) { state, accuracy in
			guard !state.isAnswered, state.request.accuracies.contains(accuracy) else { return .none }

			state.accuracy = accuracy
			return .none
		}
	}

	/// One answer per prompt; a second click or key while the host closes it does nothing.
	private func answer(
		_ decision: Decision,
		state: inout State
	) -> Effect<Action> {
		guard !state.isAnswered else { return .none }

		state.isAnswered = true
		let accuracy: PagePermissionRequest.Accuracy? = state.request.accuracies.count > 1 && decision != .dismiss
		? state.accuracy
		: nil
		return .send(.delegate(.answered(.init(token: state.request.token, decision: decision, accuracy: accuracy))))
	}
}
