import BrowserCore
import DiagnosticsClient
import Foundation
import ImageIO
import UniformTypeIdentifiers
import _Dependencies

/// Sends Send Feedback's reports to Arx's backend (DEV-1284) and keeps the unsent draft.
///
/// Live, it posts the form to `POST /v1/feedback` at ``ArxService/backendURL(environment:)``.
/// Debug builds talk to a fake that takes every report, unless `ARX_BACKEND_URL` points them at a
/// backend (a local `pnpm dev`). Tests set every closure they use.
public struct SendFeedbackClient: Sendable {
	public var send: @Sendable (FeedbackSubmission) async throws(FeedbackFailure) -> Void
	public var loadDraft: @Sendable () async -> FeedbackDraft
	public var saveDraft: @Sendable (FeedbackDraft) async -> Void

	public init(
		send: @escaping @Sendable (FeedbackSubmission) async throws(FeedbackFailure) -> Void,
		loadDraft: @escaping @Sendable () async -> FeedbackDraft,
		saveDraft: @escaping @Sendable (FeedbackDraft) async -> Void
	) {
		self.send = send
		self.loadDraft = loadDraft
		self.saveDraft = saveDraft
	}
}

// MARK: - Live

extension SendFeedbackClient {
	/// Posts to `backend`, and keeps the draft in `draftFile`.
	public static func live(
		backend: URL,
		draftFile: URL,
		session: URLSession = .shared
	) -> Self {
		let drafts: FeedbackDraftFile = .init(url: draftFile)
		return .init(
			send: { submission throws(FeedbackFailure) in
				try await post(submission, to: backend, session: session)
			},
			loadDraft: { await drafts.load() },
			saveDraft: { await drafts.save($0) }
		)
	}

	/// A backend that takes every report after a moment, for Debug builds and previews.
	public static func fake(draftFile: URL?) -> Self {
		let drafts: FeedbackDraftFile? = draftFile.map(FeedbackDraftFile.init)
		return .init(
			send: { _ throws(FeedbackFailure) in try? await Task.sleep(for: .milliseconds(600)) },
			loadDraft: { await drafts?.load() ?? .init() },
			saveDraft: { await drafts?.save($0) }
		)
	}

	/// `~/Library/Application Support/<data folder>/Feedback Draft.json`.
	public static var draftFile: URL {
		ArxEdition.current
			.applicationSupport(home: FileManager.default.homeDirectoryForCurrentUser)
			.appendingPathComponent("Feedback Draft.json")
	}

	private static func post(
		_ submission: FeedbackSubmission,
		to backend: URL,
		session: URLSession
	) async throws(FeedbackFailure) {
		let boundary: String = "arx-feedback-\(UUID().uuidString)"
		var request: URLRequest = .init(url: backend.appendingPathComponent("v1/feedback"))
		request.httpMethod = "POST"
		request.timeoutInterval = 60
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		request.httpBody = FeedbackForm.body(submission, boundary: boundary)

		let response: URLResponse
		do {
			(_, response) = try await session.data(for: request)
		} catch {
			throw .offline
		}
		if let failure = FeedbackForm.failure(status: (response as? HTTPURLResponse)?.statusCode ?? 0) {
			throw failure
		}
	}
}

// MARK: - Form

/// The multipart form the backend reads, and what its answers mean.
public enum FeedbackForm {
	/// The body for `submission`: `kind`, `message`, `email` when there is one, the versions, the
	/// diagnostics file and the attachments.
	public static func body(
		_ submission: FeedbackSubmission,
		boundary: String
	) -> Data {
		var body: Data = .init()
		func append(_ text: String) { body.append(Data(text.utf8)) }

		func field(_ name: String, _ value: String) {
			append("--\(boundary)\r\n")
			append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
			append(value)
			append("\r\n")
		}

		func file(_ name: String, filename: String, contentType: String, data: Data) {
			append("--\(boundary)\r\n")
			append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(quoted(filename))\"\r\n")
			append("Content-Type: \(contentType)\r\n\r\n")
			body.append(data)
			append("\r\n")
		}

		let environment: DiagnosticsEnvironment = submission.environment
		field("kind", submission.kind.rawValue)
		field("message", submission.message)
		if let email = submission.email { field("email", email) }
		field("appVersion", GitHubIssue.appVersion(environment))
		if environment.engineVersion != nil || environment.chromiumVersion != nil {
			field("engineVersion", GitHubIssue.engineVersion(environment))
		}
		field("macOSVersion", "\(environment.macOSVersion), \(environment.architecture)")
		if let diagnostics = submission.diagnostics {
			file("diagnostics", filename: "diagnostics.json", contentType: "application/json", data: diagnostics)
		}
		for attachment in submission.attachments {
			file("attachment", filename: attachment.name, contentType: attachment.contentType, data: attachment.data)
		}
		append("--\(boundary)--\r\n")
		return body
	}

	/// A file name inside a quoted header value: no quotes, backslashes or line breaks.
	private static func quoted(_ name: String) -> String {
		String(name.unicodeScalars.filter { !"\"\\\r\n".unicodeScalars.contains($0) })
	}

	/// What a status means for the sheet: `nil` when the report was filed.
	public static func failure(status: Int) -> FeedbackFailure? {
		switch status {
		case 200 ..< 300: nil
		case 413, 415: .tooLarge
		case 429: .tooMany
		case 400 ..< 500: .refused
		default: .unavailable
		}
	}

	/// Include diagnostics' file: the versions and what Report a Problem saves, without its
	/// description. When it's over ``SendFeedback/Limits/diagnosticsBytes``, the oldest crash
	/// reports, stalls, hang reports and unclean exits are left out until it fits.
	public static func diagnostics(
		_ diagnostics: ProblemReport.Diagnostics,
		environment: DiagnosticsEnvironment,
		limit: Int = SendFeedback.Limits.diagnosticsBytes
	) -> Data? {
		struct File: Encodable {
			var environment: DiagnosticsEnvironment
			var diagnostics: ProblemReport.Diagnostics
		}

		let encoder: JSONEncoder = .init()
		encoder.outputFormatting = [.sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		var trimmed: ProblemReport.Diagnostics = diagnostics
		while true {
			guard let data = try? encoder.encode(File(environment: environment, diagnostics: trimmed))
			else { return nil }

			if data.count <= limit { return data }

			// Newest first in each list: halve the longest.
			let counts: [Int] = [
				trimmed.crashReports.count,
				trimmed.stalls?.count ?? 0,
				trimmed.hangReports?.count ?? 0,
				trimmed.uncleanExits?.count ?? 0,
			]
			guard let longest = counts.max(), longest > 0
			else { return nil }

			let keep: Int = longest / 2
			if trimmed.crashReports.count == longest {
				trimmed.crashReports = Array(trimmed.crashReports.prefix(keep))
			} else if trimmed.stalls?.count == longest {
				trimmed.stalls = trimmed.stalls.map { Array($0.prefix(keep)) }
			} else if trimmed.hangReports?.count == longest {
				trimmed.hangReports = trimmed.hangReports.map { Array($0.prefix(keep)) }
			} else {
				trimmed.uncleanExits = trimmed.uncleanExits.map { Array($0.prefix(keep)) }
			}
		}
	}
}

// MARK: - Attachments

/// Turns a file or pasted picture into an attachment within the limits.
public enum FeedbackAttachments {
	/// The attachment for a file of `data`, made smaller when it's a still picture too large for
	/// `room` (the bytes left of the 4 MB). A picture re-encodes as a JPEG no larger than a
	/// Retina screen; films and moving pictures go as they are or not at all.
	public static func attachment(
		id: UUID,
		name: String,
		data: Data,
		room: Int
	) -> Result<FeedbackAttachment, FeedbackFailure> {
		// The backend refuses an empty file, and with it the whole report.
		guard !data.isEmpty
		else { return .failure(.unreadableFile(name: name)) }

		guard let contentType = contentType(name: name, data: data)
		else { return .failure(.unsupportedFile(name: name)) }

		if data.count <= room, data.count <= SendFeedback.Limits.attachmentBytes {
			return .success(.init(id: id, name: name, contentType: contentType, data: data))
		}

		if contentType.hasPrefix("image/"), !moves(data), let smaller = smallerPicture(data, room: room) {
			let base: String = (name as NSString).deletingPathExtension
			return .success(.init(id: id, name: (base.isEmpty ? "Picture" : base) + ".jpg", contentType: "image/jpeg", data: smaller))
		}
		return .failure(.fileTooLarge(name: name, total: SendFeedback.Limits.attachmentBytes - room + data.count))
	}

	/// The MIME type the backend takes for the file, from its contents for pictures, from its
	/// name otherwise; `nil` for anything else.
	public static func contentType(
		name: String,
		data: Data
	) -> String? {
		if let source = CGImageSourceCreateWithData(data as CFData, nil),
		   let identifier = CGImageSourceGetType(source) as String?,
		   let type = UTType(identifier)?.preferredMIMEType,
		   SendFeedback.attachmentTypes.contains(type) {
			return type
		}
		let ext: String = (name as NSString).pathExtension
		guard let type = UTType(filenameExtension: ext)?.preferredMIMEType, SendFeedback.attachmentTypes.contains(type)
		else { return nil }

		return type
	}

	private static func moves(_ data: Data) -> Bool {
		CGImageSourceCreateWithData(data as CFData, nil).map { CGImageSourceGetCount($0) > 1 } ?? false
	}

	/// The picture as a JPEG that fits `room`, as large as that allows.
	private static func smallerPicture(
		_ data: Data,
		room: Int
	) -> Data? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil)
		else { return nil }

		for side in [SendFeedback.Limits.pictureSide, 1_920, 1_280] {
			let options: [CFString: Any] = [
				kCGImageSourceCreateThumbnailFromImageAlways: true,
				kCGImageSourceCreateThumbnailWithTransform: true,
				kCGImageSourceThumbnailMaxPixelSize: side,
			]
			guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
			else { return nil }

			for quality in [0.85, 0.7, 0.55] {
				let output: NSMutableData = .init()
				guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
				else { return nil }

				CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
				guard CGImageDestinationFinalize(destination)
				else { return nil }

				if output.length <= room { return output as Data }
			}
		}
		return nil
	}
}

// MARK: - Draft file

/// The unsent draft on disk, files included; written atomically, readable only by the person.
private actor FeedbackDraftFile {
	private let url: URL

	internal init(url: URL) {
		self.url = url
	}

	internal func load() -> FeedbackDraft {
		guard let data = try? Data(contentsOf: url), let draft = try? JSONDecoder().decode(FeedbackDraft.self, from: data)
		else { return .init() }

		return draft
	}

	internal func save(_ draft: FeedbackDraft) {
		do {
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try JSONEncoder().encode(draft).write(to: url, options: [.atomic, .completeFileProtection])
			try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
		} catch {
			// A draft that can't be kept only lasts until Arx quits.
		}
	}
}

// MARK: - Dependency

extension SendFeedbackClient: DependencyKey {
	public static var liveValue: Self {
		let environment: [String: String] = ProcessInfo.processInfo.environment
		#if DEBUG
		// Debug builds never file real reports unless pointed at a backend on purpose.
		guard environment["ARX_BACKEND_URL"] != nil
		else { return .fake(draftFile: draftFile) }
		#endif
		return .live(backend: ArxService.backendURL(environment: environment), draftFile: draftFile)
	}

	public static var previewValue: Self { .fake(draftFile: nil) }

	public static var testValue: Self {
		.init(
			send: { _ throws(FeedbackFailure) in reportIssue("SendFeedbackClient.send is unimplemented") },
			loadDraft: unimplemented("SendFeedbackClient.loadDraft", placeholder: .init()),
			saveDraft: { _ in }
		)
	}
}

extension DependencyValues {
	public var sendFeedback: SendFeedbackClient {
		get { self[SendFeedbackClient.self] }
		set { self[SendFeedbackClient.self] = newValue }
	}
}
