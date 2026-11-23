import AppKit
@testable import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing
import WebKit

/// DEV-1028: reading mode's page, its appearance, and where its links go.
@Suite(.renderTurn)
@MainActor
internal struct ReaderTests {
	private static let article: ReaderArticle = .init(
		url: URL(string: "https://news.example/2026/11/story")!,
		title: "Rivers <and> \"Bridges\"",
		byline: "Ann O'Neil",
		siteName: "News & Views",
		language: "en",
		html: "<p>The river runs <a href=\"https://news.example/map\">past the mill</a>.</p>"
	)

	@Test
	internal func thePageRunsNoScriptAndEscapesTheArticlesDetails() {
		let html = ReaderDocument.html(Self.article, appearance: .init(theme: .sepia, textSize: 20, width: 800))
		#expect(html.contains(#"content="default-src 'none'; img-src https: http: data:; style-src 'unsafe-inline'""#))
		#expect(html.contains("Rivers &lt;and&gt; &quot;Bridges&quot;"))
		#expect(html.contains("Ann O&#39;Neil"))
		#expect(html.contains("News &amp; Views"))
		#expect(html.contains(#"lang="en" dir="ltr" data-theme="sepia""#))
		#expect(html.contains("--reader-size: 20px"))
		#expect(html.contains("--reader-width: 800px"))
		#expect(html.contains(Self.article.html))

		var arabic = Self.article
		arabic.isRightToLeft = true
		arabic.siteName = nil
		let rightToLeft = ReaderDocument.html(arabic, appearance: .init())
		#expect(rightToLeft.contains(#"dir="rtl""#))
		// Without a site name, the address's host names it.
		#expect(rightToLeft.contains(#"<p class="arx-reader-site">news.example</p>"#))
	}

	@Test
	internal func restylingKeepsTheDocumentAndChangesItsVariables() {
		let script = ReaderDocument.restyle(.init(theme: .dark, textSize: 25, width: 960))
		#expect(script.contains("dataset.theme = 'dark'"))
		#expect(script.contains("--reader-size: 25px"))
		#expect(script.contains("color-scheme: dark"))
	}

	@Test
	internal func textSizeAndWidthStepWithinTheirRanges() {
		let smallest = ReaderAppearance(textSize: 1)
		#expect(smallest.textSize == ReaderAppearance.textSizes.first)
		#expect(!smallest.canShrinkText)
		#expect(smallest.steppingText(by: -1).textSize == smallest.textSize)
		#expect(smallest.steppingText(by: 1).textSize == 16)

		let widest = ReaderAppearance(width: 5_000)
		#expect(widest.width == ReaderAppearance.widths.last)
		#expect(!widest.canWiden)
		#expect(widest.steppingWidth(by: -1).width == 800)
		#expect(ReaderAppearance.Theme.allCases.count == 4)
	}

	@Test
	internal func linksOpenInThePageAndAnchorsScrollTheArticle() {
		typealias Coordinator = ReaderWebView.Coordinator
		let article = Self.article.url

		// The reader's own document loads once.
		#expect(Coordinator.decision(for: article, isLink: false, isMainFrame: true, isLoadingDocument: true, article: article) == .load)
		#expect(Coordinator.decision(for: article, isLink: false, isMainFrame: true, isLoadingDocument: false, article: article) == .refuse)
		// A footnote in the article scrolls to it.
		let footnote = URL(string: "https://news.example/2026/11/story#note-1")!
		#expect(Coordinator.decision(for: footnote, isLink: true, isMainFrame: true, isLoadingDocument: false, article: article) == .scroll)
		// A link elsewhere is for the page under the reader.
		let map = URL(string: "https://news.example/map")!
		#expect(Coordinator.decision(for: map, isLink: true, isMainFrame: true, isLoadingDocument: false, article: article) == .open(map))
		// An email link goes to the page too, which hands it to Mail.
		let mail = URL(string: "mailto:editor@news.example")!
		#expect(Coordinator.decision(for: mail, isLink: true, isMainFrame: true, isLoadingDocument: false, article: article) == .open(mail))
		// Nothing else navigates: not a script address, a redirect or a frame.
		let script = URL(string: "javascript:alert(1)")!
		#expect(Coordinator.decision(for: script, isLink: true, isMainFrame: true, isLoadingDocument: false, article: article) == .refuse)
		#expect(Coordinator.decision(for: map, isLink: false, isMainFrame: true, isLoadingDocument: false, article: article) == .refuse)
		#expect(Coordinator.decision(for: map, isLink: true, isMainFrame: false, isLoadingDocument: false, article: article) == .refuse)
	}

	/// DEV-1066: Find marks every match in the article, case-insensitively and literally, steps
	/// through them both ways, and clears them, leaving the article's text as it was. An article
	/// element whose id matches the search's own name doesn't stand in for its state.
	@Test
	internal func findMarksStepsAndClearsTheArticlesMatches() async throws {
		var article = Self.article
		article.html = """
		<p>The river runs. A River bend, and <b>rivers</b>.</p><p id="arxReaderFind">a.b and axb</p>
		<details><summary>More</summary><p>A delta.</p></details>
		"""
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = false
		let view = WKWebView(frame: .init(x: 0, y: 0, width: 720, height: 560), configuration: configuration)
		view.loadHTMLString(ReaderDocument.html(article, appearance: .init()), baseURL: article.url)
		for _ in 0 ..< 200 where view.isLoading {
			try await Task.sleep(for: .milliseconds(25))
		}
		#expect(!view.isLoading)
		let text = await Self.evaluate("document.body.textContent", as: String.self, in: view)

		// The title, "Rivers", and three in the text, one of them in bold.
		var find = ReaderFind().next("river", forward: true, newSession: true)
		#expect(await Self.run(find, in: view) == .init(matches: 4, active: 1))
		find = find.next("river", forward: true, newSession: false)
		#expect(await Self.run(find, in: view) == .init(matches: 4, active: 2))
		find = find.next("river", forward: false, newSession: false)
		#expect(await Self.run(find, in: view) == .init(matches: 4, active: 1))
		find = find.next("river", forward: false, newSession: false)
		#expect(await Self.run(find, in: view) == .init(matches: 4, active: 4))
		// The query is text, not a pattern.
		find = find.next("a.b", forward: true, newSession: true)
		#expect(await Self.run(find, in: view) == .init(matches: 1, active: 1))
		find = find.next("nowhere", forward: true, newSession: true)
		#expect(await Self.run(find, in: view) == .init(matches: 0, active: 0))
		// A match in a collapsed section opens it.
		find = find.next("delta", forward: true, newSession: true)
		#expect(await Self.run(find, in: view) == .init(matches: 1, active: 1))
		#expect(await Self.evaluate("document.querySelector('details').open", as: Bool.self, in: view) == true)

		find = find.next("", forward: true, newSession: true)
		#expect(await Self.run(find, in: view) == nil)
		let marks = await Self.evaluate("document.querySelectorAll('mark.arx-reader-match').length", as: Int.self, in: view)
		#expect(marks == 0)
		let cleared = await Self.evaluate("document.body.textContent", as: String.self, in: view)
		#expect(cleared == text)
	}

	private static func run(
		_ find: ReaderFind,
		in view: WKWebView
	) async -> BrowserNavigation.FindResult? {
		await withCheckedContinuation { continuation in
			view.evaluateJavaScript(find.script, in: nil, in: .defaultClient) { result in
				continuation.resume(returning: ReaderFind.result(try? result.get()))
			}
		}
	}

	/// What a script returns in the reader's client world, as `ReaderWebView` runs it.
	private static func evaluate<Value: Sendable>(
		_ script: String,
		as type: Value.Type,
		in view: WKWebView
	) async -> Value? {
		await withCheckedContinuation { continuation in
			view.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
				continuation.resume(returning: (try? result.get()) as? Value)
			}
		}
	}

	/// The reader in each theme, rendered by WebKit, when `ARX_DESIGN_SNAPSHOTS` names a directory.
	@Test(.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
	internal func snapshots() async throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		var article = Self.article
		article.title = "How the river shaped the town"
		article.siteName = "News & Views"
		article.html = """
		<p>For three centuries the river decided where the town could grow. The mill came first, then the
		bridge, and only then the <a href="https://news.example/market">market square</a> people know today.</p>
		<h2>The mill</h2>
		<p>Built in 1724, the mill turned the river's fall into flour for the whole valley.</p>
		<blockquote>"Nothing moved here that the water didn't allow," the miller wrote.</blockquote>
		<p>When the railway arrived, the town finally turned its back on the water.</p>
		"""
		for theme in ReaderAppearance.Theme.allCases {
			let configuration = WKWebViewConfiguration()
			configuration.websiteDataStore = .nonPersistent()
			configuration.defaultWebpagePreferences.allowsContentJavaScript = false
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
			view.loadHTMLString(ReaderDocument.html(article, appearance: .init(theme: theme)), baseURL: article.url)
			for _ in 0..<100 where view.isLoading {
				try await Task.sleep(for: .milliseconds(50))
			}
			try await Task.sleep(for: .milliseconds(300))
			let image = try await view.takeSnapshot(configuration: nil)
			let representation = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
			let data = try #require(representation.representation(using: .png, properties: [:]))
			try data.write(to: directory.appending(path: "reader-\(theme.rawValue).png"))
		}
	}
}
