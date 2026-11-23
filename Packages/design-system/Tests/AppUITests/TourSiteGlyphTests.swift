@testable import AppUI
import Testing

/// The tour's sample favicons (DEV-791) round-trip through an item's `symbol`, and nothing else
/// is read as one.
internal struct TourSiteGlyphTests {
	@Test(arguments: TourSiteGlyph.allCases)
	internal func glyphRoundTripsThroughItsSymbol(_ glyph: TourSiteGlyph) {
		#expect(TourSiteGlyph(symbol: glyph.symbol) == glyph)
	}

	@Test(arguments: ["globe", "envelope.fill", SidebarItem.assistantSymbol, "arx.sample.", "arx.sample.unknown"])
	internal func otherSymbolsAreNotGlyphs(_ symbol: String) {
		#expect(TourSiteGlyph(symbol: symbol) == nil)
	}
}
