import BrowserCore
import Foundation

/// A position in one page read. It binds the document and DOM version it was cut
/// from, so a continuation either reads that same version or fails with
/// `staleCursor`; a page never mixes two versions.
internal struct AutomationPageCursor: Codable, Equatable, Sendable {
	internal static let maximumLength: Int = 1024

	internal var kind: Kind
	internal var targetID: UUID
	internal var documentID: String
	internal var domVersion: String
	internal var offset: Int
	internal var limit: Int
	internal var format: AutomationReadableText.Format?
	internal var scope: AutomationReadableText.Scope?
	internal var query: String?
	internal var frameID: String?
	internal var formValues: Bool?
	internal var bounds: Bool?

	internal init(
		kind: Kind,
		targetID: UUID,
		documentID: String,
		domVersion: String,
		offset: Int,
		limit: Int,
		format: AutomationReadableText.Format? = nil,
		scope: AutomationReadableText.Scope? = nil,
		query: String? = nil,
		frameID: String? = nil,
		formValues: Bool = false,
		bounds: Bool = false
	) {
		self.kind = kind
		self.targetID = targetID
		self.documentID = documentID
		self.domVersion = domVersion
		self.offset = offset
		self.limit = limit
		self.format = format
		self.scope = scope
		self.query = query
		self.frameID = frameID
		self.formValues = formValues ? true : nil
		self.bounds = bounds ? true : nil
	}

	internal enum Kind: String, Codable, Sendable {
		case inspect
		case read
		case find
	}

	/// Whether `snapshot` is the exact version this cursor was cut from.
	internal func matches(_ snapshot: PageInspectionSnapshot) -> Bool {
		snapshot.documentID == documentID && snapshot.domVersion == domVersion
	}

	internal func encoded() throws -> String {
		let data = try JSONEncoder().encode(self)
		let text = data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
		guard text.utf8.count <= Self.maximumLength
		else { throw AutomationFailure.limitExceeded }

		return text
	}

	internal static func decode(
		_ text: String,
		as kind: Kind
	) throws -> Self {
		guard
			!text.isEmpty,
			text.utf8.count <= maximumLength,
			text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
		else { throw AutomationFailure.invalidRequest }

		var base64 = text
			.replacingOccurrences(of: "-", with: "+")
			.replacingOccurrences(of: "_", with: "/")
		base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)

		guard
			let data = Data(base64Encoded: base64),
			let cursor = try? JSONDecoder().decode(Self.self, from: data),
			cursor.kind == kind,
			cursor.offset >= 0,
			cursor.limit > 0,
			!cursor.documentID.isEmpty,
			cursor.documentID.utf8.count <= 128,
			UInt64(cursor.domVersion).map(String.init) == cursor.domVersion
		else { throw AutomationFailure.invalidRequest }

		return cursor
	}
}
