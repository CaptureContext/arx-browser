import Foundation
import Testing

@testable import PageTranslationClient

internal struct PageTranslationScriptsTests {
	@Test
	internal func applyCarriesTheTranslationsAsJSON() async throws {
		let script = PageTranslationScripts.apply([.init(id: 3, text: "Bonjour \"monde\" </b>")])
		#expect(script.contains(#"[{"id":3,"text":"Bonjour \"monde\" </b>"}]"#))
		#expect(script.contains("state.originals.set(node, { original, translated: node.nodeValue })"))
		#expect(PageTranslationScripts.restore.contains("if (node.nodeValue !== translated) continue;"))
		#expect(PageTranslationScripts.collect(limit: 0).contains("const limit = 1;"))
		#expect(PageTranslationScripts.restore.contains("globalThis.__arxTranslation = undefined"))
	}

	@Test
	internal func batchesFitTheSourceLimit() async throws {
		let pieces = (0 ..< 10).map { PageTranslationScripts.Piece(id: $0, text: String(repeating: "a", count: 1000)) }
		let batches = PageTranslationScripts.batches(pieces, maximumBytes: 5000)
		#expect(batches.flatMap { $0 } == pieces)
		for batch in batches {
			#expect(PageTranslationScripts.apply(batch).utf8.count <= 5000)
		}
		let huge = PageTranslationScripts.Piece(id: 99, text: String(repeating: "b", count: 10_000))
		#expect(PageTranslationScripts.batches([huge], maximumBytes: 5000).isEmpty)
	}

	@Test
	internal func baseLanguagesKeepChineseScripts() async throws {
		#expect(PageTranslationClient.baseLanguage("fr-CA") == "fr")
		#expect(PageTranslationClient.baseLanguage("en") == "en")
		#expect(PageTranslationClient.baseLanguage("zh-Hant-TW") == "zh-Hant")
	}
}
