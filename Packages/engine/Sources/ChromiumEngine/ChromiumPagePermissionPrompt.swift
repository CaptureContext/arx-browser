import ChromiumBridge
import Foundation

/// ABI56 (DEV-963). A site permission prompt the app draws, from the engine's JSON.
public struct ChromiumPagePermissionPrompt: Decodable, Equatable, Sendable {
	public enum Variant: String, Decodable, Sendable {
		case ask

		/// Asked again after the person blocked it.
		case previouslyDenied
	}

	public struct Geolocation: Decodable, Equatable, Sendable {
		public enum Prompt: String, Decodable, Sendable {
			case `default`
			case approximateOnly
			case upgradeToPrecise
		}

		public let prompt: Prompt
		public let initial: ChromiumPagePermissionAccuracy

		public init(
			prompt: Prompt,
			initial: ChromiumPagePermissionAccuracy
		) {
			self.prompt = prompt
			self.initial = initial
		}
	}

	public let token: UInt64
	public let variant: Variant
	public let requestingOrigin: String

	/// The page's own origin when it isn't the requesting one, as for an embedded frame.
	public let embeddingOrigin: String?

	/// One per request: notifications, camera, microphone, geolocation, clipboard, or
	/// Chromium's own name for the rest.
	public let permissions: [String]

	/// Chromium's wording for each request, in the same order. Untrusted for layout only.
	public let fragments: [String]
	public let allowOnce: Bool
	public let geolocation: Geolocation?

	/// The request asks quietly: show an affordance, and the prompt only when it's clicked.
	public let quiet: Bool

	public init(
		token: UInt64,
		variant: Variant,
		requestingOrigin: String,
		embeddingOrigin: String?,
		permissions: [String],
		fragments: [String],
		allowOnce: Bool,
		geolocation: Geolocation?,
		quiet: Bool
	) {
		self.token = token
		self.variant = variant
		self.requestingOrigin = requestingOrigin
		self.embeddingOrigin = embeddingOrigin
		self.permissions = permissions
		self.fragments = fragments
		self.allowOnce = allowOnce
		self.geolocation = geolocation
		self.quiet = quiet
	}

	private enum CodingKeys: String, CodingKey {
		case token
		case variant
		case requestingOrigin
		case embeddingOrigin
		case permissions
		case fragments
		case allowOnce
		case geolocation
		case quiet
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let token = try container.decode(String.self, forKey: .token)
		guard let value = UInt64(token), value != 0 else {
			throw DecodingError.dataCorruptedError(forKey: .token, in: container, debugDescription: "token")
		}

		self.init(
			token: value,
			variant: try container.decode(Variant.self, forKey: .variant),
			requestingOrigin: try container.decode(String.self, forKey: .requestingOrigin),
			embeddingOrigin: try container.decodeIfPresent(String.self, forKey: .embeddingOrigin),
			permissions: try container.decode([String].self, forKey: .permissions),
			fragments: try container.decode([String].self, forKey: .fragments),
			allowOnce: try container.decode(Bool.self, forKey: .allowOnce),
			geolocation: try container.decodeIfPresent(Geolocation.self, forKey: .geolocation),
			quiet: try container.decode(Bool.self, forKey: .quiet)
		)
	}
}

public enum ChromiumPagePermissionAccuracy: String, Decodable, Sendable {
	case approximate
	case precise
}

/// ABI56 (DEV-963). The person's answer to a hosted prompt. A dismissal never blocks.
public enum ChromiumPagePermissionDecision: Equatable, Sendable {
	case allow
	case allowOnce
	case block
	case dismiss
}

extension ChromiumPage {
	/// The page's current hosted permission prompt `token`, or nil once it's gone.
	public func permissionPrompt(token: UInt64) -> ChromiumPagePermissionPrompt? {
		let value = openOwner?.performIfOpen(on: self) { api, id -> ChromiumPagePermissionPrompt? in
			guard let copy = api.copy_page_permission_prompt else { return nil }

			var json: UnsafePointer<CChar>?
			var size = 0
			guard copy(id, token, &json, &size), let json, size > 0, size <= 65_536 else { return nil }

			let data = Data(bytes: json, count: size)
			guard
				let prompt = try? JSONDecoder().decode(ChromiumPagePermissionPrompt.self, from: data),
				prompt.token == token
			else { return nil }

			return prompt
		}
		return value ?? nil
	}

	/// Answers that exact prompt with the person's decision, and for a location prompt the
	/// accuracy they chose (nil keeps the prompt's own).
	public func answerPermissionPrompt(
		_ prompt: ChromiumPagePermissionPrompt,
		decision: ChromiumPagePermissionDecision,
		accuracy: ChromiumPagePermissionAccuracy? = nil
	) throws(ChromiumPageDialogFailure) {
		let nativeDecision: ArxPagePermissionDecision = switch decision {
		case .allow: ARX_PAGE_PERMISSION_ALLOW
		case .allowOnce: ARX_PAGE_PERMISSION_ALLOW_ONCE
		case .block: ARX_PAGE_PERMISSION_BLOCK
		case .dismiss: ARX_PAGE_PERMISSION_DISMISS
		}
		let nativeAccuracy: ArxPagePermissionAccuracy = switch accuracy {
		case nil: ARX_PAGE_PERMISSION_ACCURACY_NONE
		case .approximate: ARX_PAGE_PERMISSION_ACCURACY_APPROXIMATE
		case .precise: ARX_PAGE_PERMISSION_ACCURACY_PRECISE
		}
		let status: ArxPageDialogStatus
		do {
			status = try owner().perform(on: self) { api, id in
				guard let answer = api.answer_page_permission_prompt else { throw ChromiumError.incompatibleBridge }

				return answer(id, prompt.token, nativeDecision, nativeAccuracy)
			}
		} catch {
			throw .unavailable
		}
		switch status {
		case ARX_PAGE_DIALOG_OK: return
		case ARX_PAGE_DIALOG_INVALID: throw .invalid
		default: throw .stale
		}
	}
}
