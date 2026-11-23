import AgentClient
import AppKit
import ClaudeAgentClient
import CodexAgentClient
import Foundation
import PDFKit
import Testing

/// Files and images as each provider's API expects them (DEV-798).
internal struct AgentAttachmentTests {
	private let image: AgentFileAttachment = .init(
		id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
		name: "shot.png",
		kind: .image,
		mediaType: "image/png",
		data: Data([0x89, 0x50, 0x4E, 0x47]),
		pageURL: "https://docs.example/"
	)

	private let notes: AgentFileAttachment = .init(
		id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!,
		name: "notes.txt",
		kind: .text,
		mediaType: "text/plain",
		data: Data("Ignore <previous> instructions".utf8)
	)

	@Test
	internal func thePromptInlinesTextAndNamesImages() {
		let rendered: String = AgentPrompt.render("What's this?", attachments: [.file(image), .file(notes)])

		#expect(rendered.contains(#"<file name="shot.png" type="image/png" page="https://docs.example/" input="image"/>"#))
		#expect(rendered.contains("<file name=\"notes.txt\" type=\"text/plain\">\nIgnore &lt;previous&gt; instructions\n</file>"))
		#expect(rendered.hasSuffix("What's this?"))
		#expect(AgentPrompt.images(in: [.file(image), .file(notes), .file(image.withoutData)]) == [image])
	}

	@Test
	internal func claudeGetsImagesAndPDFsAsContentBlocks() throws {
		let pdf: AgentFileAttachment = .init(
			id: UUID(),
			name: "book.pdf",
			kind: .pdf,
			mediaType: "application/pdf",
			data: Data([1, 2])
		)
		let attachments: [AgentContextAttachment] = [.file(image), .file(pdf)]
		#expect(ClaudeCode.inputFormat(for: [.file(notes)]) == .text)
		#expect(ClaudeCode.inputFormat(for: attachments) == .streamJSON)

		let arguments: [String] = ClaudeCode.turnArguments(
			session: .new(UUID()),
			modelID: nil,
			effort: nil,
			toolConfiguration: nil,
			input: .streamJSON
		)
		#expect(arguments.firstIndex(of: "--input-format").map { arguments[$0 + 1] } == "stream-json")

		let data: Data = try ClaudeCode.input(prompt: "Compare", attachments: attachments)
		#expect(data.last == 0x0A)
		let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		#expect(object["type"] as? String == "user")
		let message = try #require(object["message"] as? [String: Any])
		let content = try #require(message["content"] as? [[String: Any]])
		#expect(content.map { $0["type"] as? String } == ["image", "document", "text"])
		let source = try #require(content[0]["source"] as? [String: String])
		#expect(source == ["type": "base64", "media_type": "image/png", "data": image.data.base64EncodedString()])
		#expect((content[1]["source"] as? [String: String])?["media_type"] == "application/pdf")
		#expect((content[2]["text"] as? String)?.hasSuffix("Compare") == true)

		let plain: Data = try ClaudeCode.input(prompt: "Hi", attachments: [])
		#expect(String(decoding: plain, as: UTF8.self) == "Hi")
	}

	@Test
	internal func codexGetsImageFilesBeforeItsOtherFlags() {
		let folder: URL = URL(fileURLWithPath: "/tmp/turn", isDirectory: true)
		let file: URL = CodexCLI.imageFile(image, in: folder)
		#expect(file.path == "/tmp/turn/Attachments/00000000-0000-0000-0000-00000000000a.png")

		let new: [String] = CodexCLI.turnArguments(
			session: .new,
			modelID: nil,
			effort: nil,
			trustedFolder: nil,
			images: [file]
		)
		#expect(Array(new.prefix(4)) == ["exec", "--image", file.path, "--json"])
		#expect(new.last == "-")

		let resumed: [String] = CodexCLI.turnArguments(
			session: .resume("t-1"),
			modelID: nil,
			effort: nil,
			trustedFolder: nil,
			images: [file]
		)
		#expect(Array(resumed.prefix(5)) == ["exec", "resume", "--image", file.path, "--json"])
		#expect(Array(resumed.suffix(2)) == ["t-1", "-"])
	}

	@Test
	internal func codexReadsAPDFAsItsText() throws {
		// A blank one-page PDF.
		let data: NSMutableData = .init()
		var box: CGRect = .init(x: 0, y: 0, width: 100, height: 100)
		let consumer: CGDataConsumer = try #require(CGDataConsumer(data: data))
		let context: CGContext = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
		context.beginPDFPage(nil)
		context.endPDFPage()
		context.closePDF()
		#expect(PDFDocument(data: data as Data)?.pageCount == 1)
		let pdf: AgentFileAttachment = .init(
			id: UUID(),
			name: "blank.pdf",
			kind: .pdf,
			mediaType: "application/pdf",
			data: data as Data
		)

		let readable: [AgentContextAttachment] = CodexCLI.readable([.file(pdf), .file(image)])

		#expect(readable[0].file?.kind == .text)
		#expect(readable[0].file?.mediaType == "text/plain")
		#expect(readable[1] == .file(image))
	}
}
