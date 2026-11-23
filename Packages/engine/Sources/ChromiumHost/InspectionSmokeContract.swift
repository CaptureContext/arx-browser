import Foundation
import ChromiumEngine

/// Exact owned-fixture expectations; never used to interpret arbitrary page content.
internal enum InspectionSmokeContract {
	internal static let safeText: String = "ARX_INSPECTION_SAFE_TEXT"
	internal static let safeShadowText: String = "ARX_INSPECTION_SAFE_SHADOW_TEXT"
	internal static let buttonName: String = "Arx inspection button"

	/// Buttons without an explicit name, named by their own words (DEV-1008).
	internal static let plainButtonNames: [String] = ["Arx plain button", "Arx submit input"]
	internal static let replaceControlName: String = "Replace content"
	internal static let reinsertControlName: String = "Remove and reinsert"
	internal static let excluded: [String] = [
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

	internal static func baseURL(_ url: URL) throws -> URL {
		guard
			let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
			parts.scheme == "http",
			parts.host == "127.0.0.1",
			let port = parts.port,
			(1...65_535).contains(port),
			parts.path == "/index.html",
			parts.user == nil,
			parts.password == nil,
			parts.query == nil,
			parts.fragment == nil
		else { throw Failure.invalidFixture }

		return url.deletingLastPathComponent()
	}

	internal static func reference(
		in snapshot: ChromiumInspectionSnapshot,
		named name: String
	) throws -> String {
		let matches = snapshot.nodes.filter { $0.role == "button" && $0.name == name }
		guard matches.count == 1, let reference = matches.first?.reference
		else { throw Failure.missingReference }

		return reference
	}

	internal static func verify(_ snapshot: ChromiumInspectionSnapshot) throws {
		let texts = snapshot.nodes.flatMap { [$0.name, $0.text].compactMap { $0 } }
		guard
			texts.contains(safeText),
			texts.contains(safeShadowText),
			Set(snapshot.omissions) == Set(ChromiumInspectionOmission.allCases),
			snapshot.omissions.count == ChromiumInspectionOmission.allCases.count
		else { throw Failure.missingSemantics }

		guard !excluded.contains(where: { secret in texts.contains { $0.contains(secret) } })
		else { throw Failure.privateContent }

		_ = try reference(in: snapshot, named: buttonName)
		for name in plainButtonNames {
			_ = try reference(in: snapshot, named: name)
		}
	}

	internal enum Failure: Error, Equatable {
		case invalidFixture
		case missingReference
		case missingSemantics
		case privateContent
	}
}
