import Foundation

/// ABI56 (DEV-963): a site permission prompt the engine hands to the app to draw, while
/// ``BrowserEngineClient/setPagePromptsHosted`` is on.
public struct BrowserPagePermissionPrompt: Equatable, Sendable {
	public enum Variant: Equatable, Sendable {
		case ask

		/// Asked again after the person blocked it.
		case previouslyDenied
	}

	public enum Accuracy: Equatable, Sendable {
		case approximate
		case precise
	}

	/// What a location prompt lets the person pick.
	public enum LocationChoice: Equatable, Sendable {
		/// Approximate or precise.
		case either
		case approximateOnly

		/// The site has approximate location and asks for precise.
		case upgradeToPrecise
	}

	public struct Location: Equatable, Sendable {
		public var choice: LocationChoice
		public var initial: Accuracy

		public init(
			choice: LocationChoice,
			initial: Accuracy
		) {
			self.choice = choice
			self.initial = initial
		}
	}

	/// Binds an answer to this exact prompt.
	public var token: UInt64
	public var variant: Variant
	public var requestingOrigin: String

	/// The page's own origin when it isn't the requesting one, as for an embedded frame.
	public var embeddingOrigin: String?

	/// One per request: `notifications`, `camera`, `microphone`, `geolocation`, `clipboard`,
	/// or Chromium's own name for the rest.
	public var permissions: [String]

	/// Chromium's wording for each request, in the same order.
	public var fragments: [String]

	/// Every request supports a grant for this visit only.
	public var allowOnce: Bool
	public var location: Location?

	/// The page asked quietly: an affordance first, and the prompt only when it's clicked.
	public var quiet: Bool

	public init(
		token: UInt64,
		variant: Variant,
		requestingOrigin: String,
		embeddingOrigin: String?,
		permissions: [String],
		fragments: [String],
		allowOnce: Bool,
		location: Location?,
		quiet: Bool
	) {
		self.token = token
		self.variant = variant
		self.requestingOrigin = requestingOrigin
		self.embeddingOrigin = embeddingOrigin
		self.permissions = permissions
		self.fragments = fragments
		self.allowOnce = allowOnce
		self.location = location
		self.quiet = quiet
	}
}

/// The person's answer to a hosted permission prompt. A dismissal never blocks.
public enum BrowserPagePermissionDecision: Equatable, Sendable {
	case allow
	case allowOnce
	case block
	case dismiss
}
