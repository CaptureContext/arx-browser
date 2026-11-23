import AgentClient
import AppUI
import Foundation
import ImageIO
import UniformTypeIdentifiers
import _ComposableArchitecture

/// Why something the person dropped, pasted, picked or captured didn't join the message (DEV-798).
public enum ChatAttachmentIssue: Equatable, Sendable {
	/// The provider doesn't take it, or not this many.
	case limit(AgentAttachmentProblem, provider: AgentProvider)

	/// Neither an image, a PDF nor text.
	case unsupported(name: String)

	/// It couldn't be read, such as a folder or a file that went away.
	case unreadable(name: String)

	/// Too large to send at all, even scaled down.
	case tooLarge(name: String)

	public var message: String {
		switch self {
		case let .limit(.tooManyFiles(limit), provider):
			String.localized(.appUI.chat.attachLimitFiles(provider.title, limit))

		case let .limit(.tooManyImages(limit), provider):
			String.localized(.appUI.chat.attachLimitImages(provider.title, limit))

		case let .limit(.tooLarge(name, limit), provider):
			String.localized(.appUI.chat.attachLimitSize(
				name,
				provider.title,
				ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
			))

		case let .limit(.unsupported(name), provider):
			String.localized(.appUI.chat.attachLimitType(name, provider.title))

		case let .unsupported(name):
			String.localized(.appUI.chat.attachUnsupported(name))

		case let .unreadable(name):
			String.localized(.appUI.chat.attachUnreadable(name))

		case let .tooLarge(name):
			String.localized(.appUI.chat.attachTooLarge(name))
		}
	}
}

/// A file or image read for the composer, or why it couldn't be.
public enum ChatAttachmentLoad: Equatable, Sendable {
	case loaded(AgentFileAttachment)
	case failed(ChatAttachmentIssue)
}

/// Reads files and images for the composer: images are scaled to what every provider takes and
/// get a small preview, PDFs and text are read as they are (DEV-798).
public struct ChatAttachmentLoader: Sendable {
	public var files: @Sendable ([URL]) async -> [ChatAttachmentLoad]
	public var image: @Sendable (_ data: Data, _ name: String, _ pageURL: String?) async -> ChatAttachmentLoad

	public init(
		files: @escaping @Sendable ([URL]) async -> [ChatAttachmentLoad],
		image: @escaping @Sendable (_ data: Data, _ name: String, _ pageURL: String?) async -> ChatAttachmentLoad
	) {
		self.files = files
		self.image = image
	}
}

extension ChatAttachmentLoader: DependencyKey {
	public static var liveValue: Self {
		.init(
			files: { urls in urls.map(ChatAttachmentReader.read) },
			image: { data, name, pageURL in ChatAttachmentReader.image(data, name: name, pageURL: pageURL) }
		)
	}

	public static var testValue: Self {
		.init(
			files: { _ in
				reportIssue("ChatAttachmentLoader.files is unimplemented")
				return []
			},
			image: { _, name, _ in
				reportIssue("ChatAttachmentLoader.image is unimplemented")
				return .failed(.unreadable(name: name))
			}
		)
	}
}

extension DependencyValues {
	public var chatAttachmentLoader: ChatAttachmentLoader {
		get { self[ChatAttachmentLoader.self] }
		set { self[ChatAttachmentLoader.self] = newValue }
	}
}

/// The live reading and image scaling behind ``ChatAttachmentLoader``.
public enum ChatAttachmentReader {
	/// The longest side an attached image keeps. Claude scales anything larger down anyway
	/// (https://docs.claude.com/en/docs/build-with-claude/vision).
	public static let maxImageSide: Int = 2_048

	/// The most bytes an attached image keeps, under every provider's limit.
	public static let maxImageBytes: Int = 3_500_000

	/// The longest side of a chip's preview, in pixels.
	public static let previewSide: Int = 160

	/// Text files larger than this aren't read; providers take far less.
	public static let maxReadBytes: Int = 40_000_000

	public static func read(_ url: URL) -> ChatAttachmentLoad {
		let name: String = url.lastPathComponent
		let values: URLResourceValues? = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .fileSizeKey])
		guard values?.isDirectory != true
		else { return .failed(.unsupported(name: name)) }

		let type: UTType? = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
		if let size = values?.fileSize, size > maxReadBytes {
			return .failed(.tooLarge(name: name))
		}
		guard let data = try? Data(contentsOf: url)
		else { return .failed(.unreadable(name: name)) }

		if type?.conforms(to: .image) == true {
			return image(data, name: name, pageURL: nil)
		}
		if type?.conforms(to: .pdf) == true {
			return .loaded(.init(id: UUID(), name: name, kind: .pdf, mediaType: "application/pdf", data: data))
		}
		if type.map(isText) ?? true, let text = String(data: data, encoding: .utf8) {
			return .loaded(.init(
				id: UUID(),
				name: name,
				kind: .text,
				mediaType: type?.preferredMIMEType ?? "text/plain",
				data: Data(text.utf8)
			))
		}
		return .failed(.unsupported(name: name))
	}

	private static func isText(_ type: UTType) -> Bool {
		[.text, .sourceCode, .json, .xml, .propertyList, .commaSeparatedText]
			.contains { type.conforms(to: $0) }
	}

	/// An image as the providers take it: PNG, JPEG, GIF or WebP within ``maxImageSide`` and
	/// ``maxImageBytes`` are kept as they are, anything else is scaled into JPEG or PNG.
	public static func image(
		_ data: Data,
		name: String,
		pageURL: String?
	) -> ChatAttachmentLoad {
		guard
			let source = CGImageSourceCreateWithData(data as CFData, nil),
			CGImageSourceGetCount(source) > 0,
			let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			let width = properties[kCGImagePropertyPixelWidth] as? Int,
			let height = properties[kCGImagePropertyPixelHeight] as? Int
		else { return .failed(.unreadable(name: name)) }

		let type: UTType? = (CGImageSourceGetType(source) as String?).flatMap(UTType.init)
		let mediaType: String? = type?.preferredMIMEType
		let preview: Data? = thumbnail(source, side: previewSide, as: .png)
		if
			let mediaType,
			AgentFileAttachment.imageMediaTypes.contains(mediaType),
			max(width, height) <= maxImageSide,
			data.count <= maxImageBytes
		{
			return .loaded(.init(id: UUID(), name: name, kind: .image, mediaType: mediaType, data: data, preview: preview, pageURL: pageURL))
		}

		// Screenshots and captures stay sharp as PNG; photos and anything still too large become JPEG.
		let hasAlpha: Bool = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
		for side in [maxImageSide, 1_568, 1_024] {
			let side: Int = min(side, max(width, height))
			for format in hasAlpha ? [UTType.png] : [.png, .jpeg] {
				guard
					let scaled = thumbnail(source, side: side, as: format),
					scaled.count <= maxImageBytes
				else { continue }

				return .loaded(.init(
					id: UUID(),
					name: renamed(name, for: format),
					kind: .image,
					mediaType: format.preferredMIMEType ?? "image/png",
					data: scaled,
					preview: preview,
					pageURL: pageURL
				))
			}
		}
		return .failed(.tooLarge(name: name))
	}

	private static func thumbnail(
		_ source: CGImageSource,
		side: Int,
		as format: UTType
	) -> Data? {
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: side,
		]
		guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
		else { return nil }

		let data: NSMutableData = .init()
		guard let destination = CGImageDestinationCreateWithData(data, format.identifier as CFString, 1, nil)
		else { return nil }

		let properties: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
		CGImageDestinationAddImage(destination, image, properties as CFDictionary)
		guard CGImageDestinationFinalize(destination)
		else { return nil }

		return data as Data
	}

	private static func renamed(
		_ name: String,
		for format: UTType
	) -> String {
		let base: String = (name as NSString).deletingPathExtension
		let fileExtension: String = format.preferredFilenameExtension ?? "png"
		return (base.isEmpty ? name : base) + "." + fileExtension
	}
}
