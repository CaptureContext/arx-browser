import AppKit
import Foundation
import Testing
import WebKit

@testable import PageTranslationClient

/// DEV-1120: text hidden with `visibility`, on itself or from around it, is never collected, so it
/// never leaves the Mac for Google. A visible run beside it still is, and so is text made visible
/// again inside a hidden block.
@MainActor
@Suite
internal struct PageTranslationVisibilityTests {
	private static let html: String = """
	<!doctype html>
	<html><body>
	<p>Visible words <span style="visibility: hidden">secret words</span> and more words.</p>
	<div style="visibility: hidden">
	  <p>Hidden paragraph <span style="visibility: visible">shown again</span></p>
	</div>
	<p style="visibility: collapse">Collapsed sentence</p>
	</body></html>
	"""

	@Test
	internal func segmentsLeaveOutHiddenRuns() async throws {
		let segments: [PageTranslationScripts.Segment] = try await Self.run(PageTranslationScripts.collectSegments())
		let texts = segments.flatMap(\.runs).map(\.text)
		let joined = texts.joined(separator: "|")

		#expect(joined.contains("Visible words"), "\(texts)")
		#expect(joined.contains("and more words."), "\(texts)")
		#expect(joined.contains("shown again"), "\(texts)")
		#expect(!joined.contains("secret"), "\(texts)")
		#expect(!joined.contains("Hidden paragraph"), "\(texts)")
		#expect(!joined.contains("Collapsed"), "\(texts)")
	}

	@Test
	internal func piecesLeaveOutHiddenText() async throws {
		let pieces: [PageTranslationScripts.Piece] = try await Self.run(PageTranslationScripts.collect())
		let texts = pieces.map(\.text)

		#expect(texts.contains("Visible words"), "\(texts)")
		#expect(texts.contains("shown again"), "\(texts)")
		#expect(!texts.contains { $0.contains("secret") || $0.contains("Hidden") || $0.contains("Collapsed") }, "\(texts)")
	}

	/// Loads the page offscreen, runs the collecting script as the engine does, as a function
	/// body, and decodes what it returns.
	private static func run<Value: Decodable>(_ script: String) async throws -> Value {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		let view = WKWebView(frame: .init(x: 0, y: 0, width: 720, height: 560), configuration: configuration)
		let window = NSWindow(
			contentRect: .init(x: -10_000, y: -10_000, width: 720, height: 560),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = view
		defer { window.close() }

		view.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
		for _ in 0 ..< 100 where view.isLoading {
			try await Task.sleep(for: .milliseconds(50))
		}
		let wrapped = "const collected = (() => {\n\(script)\n})();\nreturn JSON.stringify(collected);"
		let result = try await view.callAsyncJavaScript(wrapped, contentWorld: .page)
		let json = try #require(result as? String)
		return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
	}
}
