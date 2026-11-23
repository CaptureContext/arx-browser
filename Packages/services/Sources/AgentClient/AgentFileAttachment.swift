import Foundation

/// A file or image a person attached to a message: dropped, pasted, picked, or captured from a
/// page (DEV-798). Adapters send images as image inputs, PDFs as documents where the provider
/// reads them, and text inline in the prompt.
public struct AgentFileAttachment: Identifiable, Equatable, Codable, Sendable {
	public var id: UUID
	public var name: String
	public var kind: Kind

	/// The media type the provider receives, such as `image/png`.
	public var mediaType: String

	/// The bytes sent to the provider. Empty in the transcript, which keeps only ``preview``.
	public var data: Data

	/// The size of ``data``, kept when the transcript drops the bytes.
	public var byteCount: Int

	/// A small PNG for an image's chip.
	public var preview: Data?

	/// The page a capture came from.
	public var pageURL: String?

	public init(
		id: UUID,
		name: String,
		kind: Kind,
		mediaType: String,
		data: Data,
		byteCount: Int? = nil,
		preview: Data? = nil,
		pageURL: String? = nil
	) {
		self.id = id
		self.name = name
		self.kind = kind
		self.mediaType = mediaType
		self.data = data
		self.byteCount = byteCount ?? data.count
		self.preview = preview
		self.pageURL = pageURL
	}

	public enum Kind: String, Codable, Sendable {
		case image
		case pdf
		case text
	}

	/// The attachment as a message in the transcript keeps it: name, kind and preview, no bytes.
	public var withoutData: Self {
		var copy: Self = self
		copy.data = Data()
		return copy
	}

	/// A text file's contents.
	public var text: String? {
		kind == .text ? String(decoding: data, as: UTF8.self) : nil
	}

	/// Image types every provider reads.
	public static let imageMediaTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
}

extension AgentContextAttachment {
	/// The attached file, if this is one.
	public var file: AgentFileAttachment? {
		guard case let .file(file) = self
		else { return nil }

		return file
	}

	/// The attachment as a message in the transcript keeps it.
	public var withoutData: Self {
		guard case let .file(file) = self
		else { return self }

		return .file(file.withoutData)
	}
}

/// What a provider accepts in one message (DEV-798). Checked before a turn starts, so the
/// person gets a clear message instead of a provider error.
public struct AgentAttachmentLimits: Equatable, Sendable {
	public var maxFiles: Int
	public var maxImages: Int
	public var maxImageBytes: Int
	public var maxPDFBytes: Int
	public var maxTextBytes: Int

	public init(
		maxFiles: Int,
		maxImages: Int,
		maxImageBytes: Int,
		maxPDFBytes: Int,
		maxTextBytes: Int
	) {
		self.maxFiles = maxFiles
		self.maxImages = maxImages
		self.maxImageBytes = maxImageBytes
		self.maxPDFBytes = maxPDFBytes
		self.maxTextBytes = maxTextBytes
	}

	/// Claude's Messages API: images up to 5 MB once base64-encoded and 20 to a message in Claude
	/// Code, PDFs up to 32 MB per request (https://docs.claude.com/en/docs/build-with-claude/vision).
	public static let claude: Self = .init(
		maxFiles: 10,
		maxImages: 20,
		maxImageBytes: 3_750_000,
		maxPDFBytes: 20_000_000,
		maxTextBytes: 500_000
	)

	/// Codex reads images from files given with `--image`. PDFs reach it as their text.
	public static let codex: Self = .init(
		maxFiles: 10,
		maxImages: 10,
		maxImageBytes: 10_000_000,
		maxPDFBytes: 20_000_000,
		maxTextBytes: 500_000
	)

	/// The first problem with `attachments`, or `nil` when the provider takes all of them.
	public func problem(with attachments: [AgentContextAttachment]) -> AgentAttachmentProblem? {
		let files: [AgentFileAttachment] = attachments.compactMap(\.file)
		if files.count > maxFiles {
			return .tooManyFiles(limit: maxFiles)
		}
		let images: Int = files.filter { $0.kind == .image }.count
		if images > maxImages {
			return .tooManyImages(limit: maxImages)
		}
		for file in files {
			if file.kind == .image, !AgentFileAttachment.imageMediaTypes.contains(file.mediaType) {
				return .unsupported(name: file.name)
			}
			let limit: Int = switch file.kind {
			case .image: maxImageBytes
			case .pdf: maxPDFBytes
			case .text: maxTextBytes
			}
			if file.byteCount > limit {
				return .tooLarge(name: file.name, limit: limit)
			}
		}
		return nil
	}
}

/// Why attachments can't go with a message.
public enum AgentAttachmentProblem: Equatable, Sendable {
	case tooManyFiles(limit: Int)
	case tooManyImages(limit: Int)
	case tooLarge(name: String, limit: Int)
	case unsupported(name: String)
}

extension AgentProvider {
	/// What the provider accepts in one message.
	public var attachmentLimits: AgentAttachmentLimits {
		switch self {
		case .openAI: .codex
		default: .claude
		}
	}
}
