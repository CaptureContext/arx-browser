#if DEBUG
import BrowserCore
import Foundation
import _MCP

/// Reads only the public MCP envelope; trusted IPC scope identities stay hidden.
internal enum AutomationInspectionSmoke {
	internal enum Reply {
		case snapshot(Snapshot)
		case failure(AutomationFailure)
	}

	internal struct Snapshot: Equatable, Decodable {
		internal var targetID: UUID
		internal var expectedRevision: String
		internal var profileID: UUID
		internal var sessionRevision: UInt64
		internal var documentRevision: UInt64
		internal var content: PageInspectionSnapshot

		internal init(
			targetID: UUID,
			expectedRevision: String,
			profileID: UUID,
			sessionRevision: UInt64,
			documentRevision: UInt64,
			content: PageInspectionSnapshot
		) {
			self.targetID = targetID
			self.expectedRevision = expectedRevision
			self.profileID = profileID
			self.sessionRevision = sessionRevision
			self.documentRevision = documentRevision
			self.content = content
		}

		internal init(from decoder: any Decoder) throws {
			let values = try decoder.container(keyedBy: CodingKeys.self)
			guard
				try values.decode(String.self, forKey: .kind) == "inspection",
				try values.decode(Bool.self, forKey: .historical),
				try !values.decode(Bool.self, forKey: .referencesAuthorizeActions),
				let sessionRevision = try UInt64(values.decode(String.self, forKey: .sessionRevision)),
				let documentRevision = try UInt64(values.decode(String.self, forKey: .documentRevision)),
				documentRevision > 0
			else { throw AutomationSmokeFailure.invalidResponse }
			self.init(
				targetID: try values.decode(UUID.self, forKey: .targetID),
				expectedRevision: try values.decode(String.self, forKey: .expectedRevision),
				profileID: try values.decode(UUID.self, forKey: .profileID),
				sessionRevision: sessionRevision,
				documentRevision: documentRevision,
				content: try PageInspectionSnapshot(from: decoder)
			)
		}

		private enum CodingKeys: String, CodingKey {
			case kind, historical, referencesAuthorizeActions
			case targetID, expectedRevision, profileID, sessionRevision, documentRevision
		}
	}

	internal static func decode(_ result: CallTool.Result) throws -> Reply {
		guard try JSONEncoder().encode(result).count <= 262_144
		else { throw AutomationSmokeFailure.invalidResponse }
		if result.isError == true {
			guard case let .failure(failure) = try AutomationSmokeResponse.decode(result)
			else { throw AutomationSmokeFailure.invalidResponse }
			return .failure(failure)
		}
		guard
			result.isError == false,
			result.content.count == 1,
			case let .text(text, _, _) = result.content[0],
			let structured = result.structuredContent,
			try JSONDecoder().decode(Value.self, from: Data(text.utf8)) == structured
		else { throw AutomationSmokeFailure.invalidResponse }

		let envelope = try JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
		guard envelope.untrustedData else { throw AutomationSmokeFailure.invalidResponse }
		return .snapshot(envelope.result)
	}

	internal static func verify(
		_ reply: Reply,
		request: AutomationInspectionRequest,
		profileID: Profile.ID
	) throws -> Snapshot {
		guard
			case let .snapshot(snapshot) = reply,
			snapshot.targetID == request.targetID,
			snapshot.expectedRevision == request.expectedRevision,
			snapshot.profileID == profileID.rawValue
		else { throw AutomationSmokeFailure.inspectionMismatch }
		try snapshot.content.validate(for: request)
		return snapshot
	}

	internal static func verifyFixtureContent(_ snapshot: Snapshot) throws {
		let nodes = snapshot.content.nodes
		let strings = nodes.flatMap { [$0.name, $0.text].compactMap { $0 } }
		let excluded = [
			"ARX_PASSWORD_SECRET",
			"ARX_FORM_VALUE_SECRET",
			"ARX_SHADOW_PASSWORD_SECRET",
			"ARX_FORMER_PASSWORD_SECRET",
			"ARX_FRAME_SECRET",
			"ARX_CROSS_ORIGIN_SECRET",
			"ARX_CANVAS_FALLBACK_SECRET",
			"ARX_EDITABLE_SECRET",
			"ARX_GENERATED_SECRET",
			"ARX_BUTTON_NESTED_SECRET",
		]
		let hasReferencedButton = nodes.contains { node in
			node.role == "button"
			&& node.name == "Arx inspection button"
			&& node.reference != nil
		}
		guard
			strings.contains(where: { $0.contains("ARX_INSPECTION_SAFE_TEXT") }),
			strings.contains(where: { $0.contains("ARX_INSPECTION_SAFE_SHADOW_TEXT") }),
			hasReferencedButton,
			!strings.contains(where: { value in excluded.contains(where: value.contains) }),
			Set(snapshot.content.omissions) == Set(PageInspectionOmission.allCases)
		else { throw AutomationSmokeFailure.inspectionMismatch }
	}

	private struct Envelope: Decodable {
		internal let untrustedData: Bool
		internal let result: Snapshot

		internal init(
			untrustedData: Bool,
			result: Snapshot
		) {
			self.untrustedData = untrustedData
			self.result = result
		}
	}
}
#endif
