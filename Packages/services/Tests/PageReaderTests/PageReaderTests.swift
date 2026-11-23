import BrowserCore
import BrowserEngineClient
import Foundation
import Testing

@testable import PageReaderClient

/// DEV-1028: reading mode's scripts fit the engine's limits, and the reader puts an article
/// together from the slices the engine returns.
@MainActor
internal struct PageReaderTests {
	private let tabID: Tab.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

	@Test
	internal func theVendoredReadabilityLoadsAndEveryScriptFitsTheSourceLimit() {
		#expect(PageReaderScripts.readability.contains("function Readability(doc, options)"))
		#expect(PageReaderScripts.readerable.contains("function isProbablyReaderable(doc, options = {})"))
		#expect(PageReaderScripts.probe.utf8.count < PageReaderScripts.maximumSourceBytes)
		#expect(PageReaderScripts.extract.utf8.count < PageReaderScripts.maximumSourceBytes)
		#expect(PageReaderScripts.slice(from: 30_000).utf8.count < PageReaderScripts.maximumSourceBytes)
	}

	@Test
	internal func theArticleIsReadFromACopyAndCutToPlainMarkup() {
		let script = PageReaderScripts.extract
		#expect(script.contains("new Readability(document.cloneNode(true)"))
		#expect(script.contains("'SCRIPT'"))
		#expect(script.contains("'IFRAME'"))
		#expect(script.contains("url.protocol === 'https:' || url.protocol === 'http:'"))
		#expect(script.contains("globalThis.__arxReader = { url: location.href, html }"))
		// A srcset candidate's address runs to the next space, commas and all.
		#expect(script.contains("while (i < value.length && !/\\s/.test(value[i])) i++;"))
		// A slice never ends between the two halves of a surrogate pair.
		#expect(script.contains("last >= 0xD800 && last <= 0xDBFF"))
		#expect(PageReaderScripts.slice(from: 4).contains("const next = cut(state.html, offset);"))
	}

	@Test
	internal func aLongArticleIsPutTogetherFromItsSlices() async throws {
		let first = String(repeating: "a", count: 4)
		let rest = ["bbbb", "cc"]
		let recorder = ScriptRecorder(outcomes: [
			.value(Self.json(["url": "https://example.com/story", "title": "Story", "byline": "Ann", "dir": "rtl", "length": 10, "chunk": first, "next": 4])),
			.value(Self.json(["chunk": rest[0], "next": 8])),
			.value(Self.json(["chunk": rest[1], "next": 10])),
		])

		let article = await PageReader.article(tabID, evaluate: recorder.evaluate, pause: {})

		#expect(article == ReaderArticle(
			url: URL(string: "https://example.com/story")!,
			title: "Story",
			byline: "Ann",
			isRightToLeft: true,
			html: "aaaabbbbcc"
		))
		#expect(recorder.scripts.count == 3)
		#expect(recorder.scripts[1].contains("const offset = 4;"))
		#expect(recorder.scripts[2].contains("const offset = 8;"))
	}

	@Test
	internal func aPageWithoutAnArticleOrOneThatChangedHasNone() async {
		let none = ScriptRecorder(outcomes: [.value("null")])
		#expect(await PageReader.article(tabID, evaluate: none.evaluate, pause: {}) == nil)

		// The page went elsewhere between slices.
		let changed = ScriptRecorder(outcomes: [
			.value(Self.json(["url": "https://example.com/story", "title": "Story", "length": 8, "chunk": "aaaa", "next": 4])),
			.value("null"),
		])
		#expect(await PageReader.article(tabID, evaluate: changed.evaluate, pause: {}) == nil)

		// Only web pages are shown.
		let file = ScriptRecorder(outcomes: [
			.value(Self.json(["url": "file:///Users/me/story.html", "title": "Story", "length": 4, "chunk": "aaaa", "next": 4])),
		])
		#expect(await PageReader.article(tabID, evaluate: file.evaluate, pause: {}) == nil)
	}

	@Test
	internal func aBusyTabIsAskedAgainAndAnUnavailableOneIsNotReadable() async {
		let busy = ScriptRecorder(outcomes: [], failures: [.busy, .busy], then: .value("true"))
		#expect(await PageReader.isReadable(tabID, evaluate: busy.evaluate, pause: {}))
		#expect(busy.scripts.count == 3)

		let unavailable = ScriptRecorder(outcomes: [], failures: [.unavailable], then: .value("true"))
		#expect(await !PageReader.isReadable(tabID, evaluate: unavailable.evaluate, pause: {}))
		#expect(unavailable.scripts.count == 1)

		let notArticle = ScriptRecorder(outcomes: [.value("false")])
		#expect(await !PageReader.isReadable(tabID, evaluate: notArticle.evaluate, pause: {}))
	}

	private static func json(_ object: [String: Any]) -> String {
		String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
	}
}

/// Answers each script with the next outcome, after the given failures.
@MainActor
private final class ScriptRecorder {
	internal private(set) var scripts: [String] = []
	private var outcomes: [BrowserScriptOutcome]
	private var failures: [BrowserDeveloperFailure]
	private let fallback: BrowserScriptOutcome

	internal init(
		outcomes: [BrowserScriptOutcome],
		failures: [BrowserDeveloperFailure] = [],
		then fallback: BrowserScriptOutcome = .undefined
	) {
		self.outcomes = outcomes
		self.failures = failures
		self.fallback = fallback
	}

	internal var evaluate: BrowserEngineClient.EvaluateScript {
		{ [self] _, script, _, _, authorize throws(BrowserDeveloperFailure) in
			#expect(authorize())
			scripts.append(script)
			if !failures.isEmpty { throw failures.removeFirst() }
			return outcomes.isEmpty ? fallback : outcomes.removeFirst()
		}
	}
}
