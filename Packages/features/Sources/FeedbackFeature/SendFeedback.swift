import DiagnosticsClient
import Foundation

/// Help › Send Feedback (DEV-1284): what the person sends, as the backend's `POST /v1/feedback`
/// takes it (`arx-browser-backend`, `src/feedback.ts`). The two change together.
public enum SendFeedback {
	/// What the report is about. The backend labels it by kind; a vulnerability is Urgent.
	public enum Kind: String, CaseIterable, Codable, Equatable, Sendable {
		case bug
		case feature
		case vulnerability
		case other
	}

	/// The sheet's limits, the backend's too.
	public enum Limits {
		public static let attachments: Int = 5

		/// All attachments together.
		public static let attachmentBytes: Int = 4 * 1_024 * 1_024

		public static let messageCharacters: Int = ProblemReport.descriptionLimit
		public static let emailCharacters: Int = 254

		/// The diagnostics file; older entries are left out until it fits.
		public static let diagnosticsBytes: Int = 1_024 * 1_024

		/// A picture is re-encoded no wider or taller than a Retina screen.
		public static let pictureSide: Int = 2_880
	}

	/// `text` cut to `limit` UTF-16 code units, as the backend counts (JavaScript's `length`),
	/// never inside a character.
	public static func capped(
		_ text: String,
		to limit: Int
	) -> String {
		guard text.utf16.count > limit
		else { return text }

		var result: String = ""
		var used: Int = 0
		for character in text {
			let size: Int = character.utf16.count
			guard used + size <= limit
			else { break }

			used += size
			result.append(character)
		}
		return result
	}

	/// The file types the backend takes. Anything else is refused before it's attached.
	public static let attachmentTypes: Set<String> = [
		"image/png", "image/jpeg", "image/gif", "image/heic", "image/webp",
		"video/mp4", "video/quicktime",
		"text/plain", "application/pdf",
	]
}

/// A file going with the report, already within the limits.
public struct FeedbackAttachment: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var name: String

	/// A MIME type in ``SendFeedback/attachmentTypes``.
	public var contentType: String
	public var data: Data

	public init(
		id: UUID,
		name: String,
		contentType: String,
		data: Data
	) {
		self.id = id
		self.name = name
		self.contentType = contentType
		self.data = data
	}

	public var isPicture: Bool { contentType.hasPrefix("image/") }

	/// The extension the tile shows for a file that isn't a picture.
	public var fileExtension: String {
		let ext: String = (name as NSString).pathExtension
		return ext.isEmpty ? "FILE" : ext.uppercased()
	}
}

/// What's kept between openings until it's sent (DEV-1284): the kind, the text, the files, the
/// switch and the email. A sent report leaves only the email, which is remembered.
public struct FeedbackDraft: Codable, Equatable, Sendable {
	public var kind: SendFeedback.Kind
	public var message: String
	public var email: String
	public var includesDiagnostics: Bool
	public var attachments: [FeedbackAttachment]

	public init(
		kind: SendFeedback.Kind = .bug,
		message: String = "",
		email: String = "",
		includesDiagnostics: Bool = true,
		attachments: [FeedbackAttachment] = []
	) {
		self.kind = kind
		self.message = message
		self.email = email
		self.includesDiagnostics = includesDiagnostics
		self.attachments = attachments
	}

	/// What's left after sending: the email only.
	public var afterSending: Self { .init(email: email) }

	public var attachmentBytes: Int { attachments.reduce(0) { $0 + $1.data.count } }
}

/// One report as it's posted.
public struct FeedbackSubmission: Equatable, Sendable {
	public var kind: SendFeedback.Kind
	public var message: String
	public var email: String?
	public var environment: DiagnosticsEnvironment

	/// The diagnostics file's JSON, when Include diagnostics is on.
	public var diagnostics: Data?
	public var attachments: [FeedbackAttachment]

	public init(
		kind: SendFeedback.Kind,
		message: String,
		email: String?,
		environment: DiagnosticsEnvironment,
		diagnostics: Data?,
		attachments: [FeedbackAttachment]
	) {
		self.kind = kind
		self.message = message
		self.email = email
		self.environment = environment
		self.diagnostics = diagnostics
		self.attachments = attachments
	}
}

/// Why a report didn't go, or a file couldn't be attached, in words the sheet shows.
public enum FeedbackFailure: Error, Equatable, Sendable {
	/// Send with nothing written.
	case emptyMessage
	case invalidEmail

	/// No connection to the backend.
	case offline

	/// The backend refused the size, the count or a file's type.
	case tooLarge

	/// Too many reports from this Mac's address for now.
	case tooMany

	/// The backend is down, or Linear didn't take the report.
	case unavailable

	/// The backend refused the form.
	case refused

	/// Attaching would go past five files.
	case tooManyFiles

	/// A file, even made smaller, would take the attachments past 4 MB. `total` is the
	/// attachments' size with it.
	case fileTooLarge(name: String, total: Int)

	/// A file of a type the report can't carry.
	case unsupportedFile(name: String)
	case unreadableFile(name: String)
}
