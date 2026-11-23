import BrowserEngineClient
import Testing

/// DEV-1019: the elements hidden on a site, as the site menu lists them.
internal struct BrowserHiddenElementsTests {
	@Test
	internal func aSiteGetsItsOwnAndItsParentDomainsFiltersOnce() {
		let hidden = BrowserHiddenElements(sites: [
			"news.example.com": ["news.example.com##.promo"],
			"example.com": ["example.com##.ad", "example.com,shop.example##.banner"],
			"shop.example": ["example.com,shop.example##.banner"],
			"com": ["com##.everywhere"],
			"other.example": ["other.example##.ad"],
		])
		#expect(hidden.filters(for: "News.Example.com") == [
			"news.example.com##.promo", "example.com##.ad", "example.com,shop.example##.banner", "com##.everywhere",
		])
		#expect(hidden.filters(for: "shop.example") == ["example.com,shop.example##.banner"])
		#expect(hidden.filters(for: "unknown.test").isEmpty)
	}

	@Test
	internal func theSelectorIsWhatFollowsTheSites() {
		#expect(BrowserHiddenElements.selector(of: "example.com##div[data-x=\"1\"] > .ad") == "div[data-x=\"1\"] > .ad")
		#expect(BrowserHiddenElements.selector(of: "a.example,b.example##.banner") == ".banner")
		#expect(BrowserHiddenElements.selector(of: "no marker") == "no marker")
	}
}
