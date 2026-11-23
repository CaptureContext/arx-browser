import Foundation
import Testing
import Translation

@testable import PageTranslationClient

/// DEV-996: sentences go out whole, with their links and code as runs, and each run's
/// translation comes back to its own node.
internal struct PageTranslationSegmentsTests {
	private typealias Run = PageTranslationScripts.Run

	private let sentence: [Run] = [
		.init(text: "Klicken Sie "),
		.init(text: "hier"),
		.init(text: ", um "),
		.init(text: "config.yaml", translate: false),
		.init(text: " zu öffnen."),
	]

	@Test
	internal func appleRunsAreMarkedAndKeptRunsSkipTranslation() async throws {
		let text = AppleTranslationRuns.attributed(sentence)
		#expect(String(text.characters) == "Klicken Sie hier, um config.yaml zu öffnen.")
		let runs = Array(text.runs)
		#expect(runs.count == 5)
		#expect(runs.map { $0.link?.absoluteString } == (0 ..< 5).map { "arx-run:\($0)" })
		#expect(runs.map { $0.translation.skipsTranslation ?? false } == [false, false, false, true, false])
	}

	@Test
	internal func appleTextsFollowTheMarksWhereverTheWordsMoved() async throws {
		// The translation reorders the sentence and drops the mark on one run's words.
		var translated = AttributedString()
		for (index, words) in [(0, "Click "), (1, "here "), (4, "to open "), (3, "config.yaml")] {
			var piece = AttributedString(words)
			piece.link = URL(string: "arx-run:\(index)")
			translated.append(piece)
		}
		translated.append(AttributedString("."))

		let arranged = try #require(AppleTranslationRuns.texts(from: translated, runs: sentence))
		#expect(arranged.texts == ["Click ", "here ", "", nil, "to open "])
		// The runs move to the translation's order, and the full stop after the code goes in a
		// node of its own.
		#expect(arranged.order == [
			.init(run: 0, text: ""), .init(run: 1, text: ""), .init(run: 4, text: ""), .init(run: 3, text: ""),
			.init(run: nil, text: "."),
		])
	}

	@Test
	internal func runsInTheirOwnOrderStayWhereTheyAre() async throws {
		let chunks: [PageTranslationScripts.Placement] = [
			.init(run: 0, text: "Click "), .init(run: 1, text: "here"), .init(run: 2, text: " to open "),
			.init(run: 3, text: "config.yaml"), .init(run: 4, text: "."),
		]
		let arranged = try #require(PageTranslationScripts.arrange(chunks, runs: sentence))
		#expect(arranged.texts == ["Click ", "here", " to open ", nil, "."])
		#expect(arranged.order == nil)
	}

	@Test
	internal func aRunSplitAroundAnotherKeepsItsLaterWordsWhereTheyFall() async throws {
		let runs: [Run] = [
			.init(text: "Lisez le fichier ", plain: true),
			.init(text: "config.yaml", translate: false),
			.init(text: " avant de commencer.", plain: true),
		]
		let chunks: [PageTranslationScripts.Placement] = [
			.init(run: 0, text: "Read the "), .init(run: 1, text: "config.yaml"), .init(run: 0, text: " file"),
			.init(run: 2, text: " before you start."),
		]
		let arranged = try #require(PageTranslationScripts.arrange(chunks, runs: runs))
		#expect(arranged.texts == ["Read the ", nil, " before you start."])
		#expect(arranged.order == [
			.init(run: 0, text: ""), .init(run: 1, text: ""), .init(run: nil, text: " file"), .init(run: 2, text: ""),
		])
	}

	@Test
	internal func appleWordsWithNoMarkGoToTheFirstTranslatedRun() async throws {
		let arranged = try #require(AppleTranslationRuns.texts(from: AttributedString("Click here"), runs: sentence))
		#expect(arranged.texts == ["Click here", "", "", nil, ""])
		#expect(arranged.order == nil)
	}

	@Test
	internal func aTranslationWithNoWordsKeepsTheSegment() async throws {
		#expect(AppleTranslationRuns.texts(from: AttributedString(" . "), runs: sentence) == nil)
		#expect(AppleTranslationRuns.texts(from: AttributedString("x"), runs: [.init(text: "a", translate: false)]) == nil)
	}

	@Test
	internal func googleHTMLMarksEveryRunAndEscapesText() async throws {
		let html = GoogleTranslation.html([.init(text: "A < B & C "), .init(text: "x>y", translate: false)])
		#expect(html == "<a i=0>A &lt; B &amp; C </a><code i=1>x&gt;y</code>")
	}

	@Test
	internal func googleTextsFollowTheMarkers() async throws {
		let answer = "Click <a i=1>here</a> to open <code i=3>config.yaml</code>&amp; <b>go</b>&#39;s."
		let arranged = try #require(GoogleTranslation.texts(from: answer, runs: sentence))

		// "Click " has no marker of its own: it opens the sentence, so it's the first run's.
		// What follows the kept code is no run's, so it gets a node of its own after the code.
		#expect(arranged.texts == ["Click ", "here to open ", "", nil, ""])
		#expect(arranged.order == [
			.init(run: 0, text: ""), .init(run: 1, text: ""), .init(run: 3, text: ""), .init(run: nil, text: "& go's."),
		])
		let unmarked = try #require(GoogleTranslation.texts(from: "Click <a i=0>here</a> &amp; go", runs: sentence))
		#expect(unmarked.texts[0] == "Click here & go")
	}

	@Test
	internal func googlePlainTextGoesUnmarkedAndComesBackInReadingOrder() async throws {
		let runs: [Run] = [
			.init(text: "Lisez le fichier ", plain: true),
			.init(text: "config.yaml", translate: false),
			.init(text: " avant de ", plain: true),
			.init(text: "commencer"),
			.init(text: ".", plain: true),
		]
		#expect(GoogleTranslation.html(runs) == "Lisez le fichier <code i=1>config.yaml</code> avant de <a i=3>commencer</a>.")
		let answer = "Read the <code i=1>config.yaml</code> file before <a i=3>starting</a> ."
		let arranged = try #require(GoogleTranslation.texts(from: answer, runs: runs))
		#expect(arranged.texts == ["Read the ", nil, " file before ", "starting", " ."])
		#expect(arranged.order == nil)
	}

	@Test
	internal func googleAnswersDecodeWithAndWithoutTheDetectedLanguage() async throws {
		#expect(GoogleTranslation.decode(Data(#"["Hello."]"#.utf8), count: 1) == ["Hello."])
		#expect(GoogleTranslation.decode(Data(#"[["Hello.","de"],["World.","fr"]]"#.utf8), count: 2) == ["Hello.", "World."])
		#expect(GoogleTranslation.decode(Data(#""Hello.""#.utf8), count: 1) == ["Hello."])
		#expect(GoogleTranslation.decode(Data(#"["Hello."]"#.utf8), count: 2) == nil)
		#expect(GoogleTranslation.decode(Data("<html>".utf8), count: 1) == nil)
	}

	@Test
	internal func googleRequestsCarryNoCookiesAndOneQPerSegment() async throws {
		let request = GoogleTranslation.request(["<a i=0>a&b</a>", "c d"], source: "zh-Hans", target: "en")
		let url = try #require(request.url)
		let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
		#expect(url.host() == "translate.googleapis.com")
		#expect(items.first { $0.name == "client" }?.value == "gtx")
		#expect(items.first { $0.name == "sl" }?.value == "zh-CN")
		#expect(items.first { $0.name == "format" }?.value == "html")
		#expect(request.httpMethod == "POST")
		#expect(!request.httpShouldHandleCookies)
		let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
		#expect(body == "q=%3Ca%20i%3D0%3Ea%26b%3C%2Fa%3E&q=c%20d")
	}

	@Test
	internal func googleRequestsStayUnderTheCharacterLimit() async throws {
		let html = Array(repeating: String(repeating: "a", count: 2000), count: 5)
		#expect(GoogleTranslation.requests(html) == [0 ..< 2, 2 ..< 4, 4 ..< 5])
		#expect(GoogleTranslation.requests([]) == [])
	}

	@Test
	internal func entitiesUnescape() async throws {
		#expect(GoogleTranslation.unescape("a &amp; b &lt;c&gt; &#233; &#x263A; &nbsp;& &unknown;") == "a & b <c> é ☺ \u{00A0}& &unknown;")
	}

	@Test
	internal func segmentScriptsKeepStateInTheirWorldAndCarryTranslationsAsJSON() async throws {
		let collect = PageTranslationScripts.collectSegments(limit: 0)
		#expect(collect.contains("const limit = 1;"))
		#expect(collect.contains("globalThis.__arxTranslation ??="))
		#expect(collect.contains("state.pending.set(id, { nodes, sources, block });"))
		let apply = PageTranslationScripts.applySegments([.init(id: 7, texts: ["Hi \"you\" </b>", nil])])
		#expect(apply.contains(#"[{"id":7,"texts":["Hi \"you\" </b>",null]}]"#))
		#expect(apply.contains("state.moves.push({ block: container, pieces, slots, extras });"))
		#expect(apply.contains("if (group.length > 1 && child.nodeType === Node.ELEMENT_NODE) arrange(child, group);"))
		#expect(apply.contains("state.done.add(extra);"))
		#expect(collect.contains("tag(item) === 'BR'"))
		#expect(collect.contains("plain: item.parentElement === block"))
		#expect(collect.contains("item.splitText(cut);"))
		// The words of no run reach the page script as an explicit null.
		let moved = PageTranslationScripts.applySegments([.init(id: 1, texts: ["a"], order: [.init(run: nil, text: ".")])])
		#expect(moved.contains(#"{"run":null,"text":"."}"#))
		#expect(collect.contains("if (unusable(item.parentElement, block)) continue;"))
		#expect(PageTranslationScripts.restore.contains("for (const { block, pieces, slots, extras } of (state.moves || []).slice().reverse())"))
		#expect(collect.contains("if (segments.length >= limit) break;"))
		#expect(apply.contains("state.originals.set(node, { original, translated: node.nodeValue });"))
	}

	@Test
	internal func segmentBatchesFitTheSourceLimit() async throws {
		let segments = (0 ..< 10).map { PageTranslationScripts.TranslatedSegment(id: $0, texts: [String(repeating: "a", count: 1000)]) }

		// Room for about two segments past the script itself.
		let limit = PageTranslationScripts.applySegments([]).utf8.count + 5000
		let batches = PageTranslationScripts.segmentBatches(segments, maximumBytes: limit)
		#expect(batches.flatMap { $0 } == segments)
		#expect(batches.count > 1)
		for batch in batches {
			#expect(PageTranslationScripts.applySegments(batch).utf8.count <= limit)
		}
	}
}
