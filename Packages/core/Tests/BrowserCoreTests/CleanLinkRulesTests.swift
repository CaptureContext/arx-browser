import BrowserCore
import CustomDump
import Foundation
import Testing

/// The data-driven clean-link rules (DEV-918), one test per rule kind and site.
internal struct CleanLinkRulesTests {
	private func cleaned(_ string: String) -> String {
		LinkTransformer.clean(.init(title: "", url: URL(string: string)!)).output.absoluteString
	}

	@Test
	internal func theShippedRulesDecodeWithTheCommonList() async throws {
		let rules = CleanLinkRules.bundled
		#expect(rules != CleanLinkRules.fallback)
		#expect(rules.parameters.count >= 60)
		#expect(Set(rules.parameters).count == rules.parameters.count)
		expectNoDifference(rules.prefixes, ["utm_", "pk_", "piwik_", "mtm_", "matomo_", "hsa_", "itm_"])
		expectNoDifference(
			rules.sites.map(\.name),
			["YouTube", "Spotify", "X", "LinkedIn", "Amazon", "Instagram", "TikTok", "Reddit", "Facebook"]
		)

		// Everything the short list removed is still removed.
		for name in CleanLinkRules.fallback.parameters {
			#expect(rules.parameters.contains(name))
		}
		#expect(LinkTransformer.trackingParameterNames == rules.parameters)
	}

	@Test(arguments: [
		("https://a.example/?gclid=1&yclid=2&_hsenc=3&mkt_tok=4&keep=5", "https://a.example/?keep=5"),
		("https://a.example/?pk_campaign=a&mtm_source=b&hsa_acc=c&itm_source=d&q=e", "https://a.example/?q=e"),
		("https://a.example/?UTM_Source=a&Q=b", "https://a.example/?Q=b"),
	])
	internal func commonParametersAndPrefixesGoEverywhere(
		_ input: String,
		_ expected: String
	) async throws {
		#expect(cleaned(input) == expected)
	}

	@Test(arguments: [
		// YouTube `si`, also on short links and subdomains.
		("https://www.youtube.com/watch?v=abc&si=share&t=40", "https://www.youtube.com/watch?v=abc&t=40"),
		("https://youtu.be/abc?si=share", "https://youtu.be/abc"),
		("https://music.youtube.com/watch?v=abc&feature=share", "https://music.youtube.com/watch?v=abc"),
		// Spotify `si`.
		("https://open.spotify.com/track/1?si=abc", "https://open.spotify.com/track/1"),
		// X `s` and `t`.
		("https://x.com/arx/status/1?s=20&t=abc", "https://x.com/arx/status/1"),
		("https://twitter.com/arx/status/1?ref_src=twsrc", "https://twitter.com/arx/status/1"),
		// LinkedIn `trk`.
		("https://www.linkedin.com/in/arx?trk=public&originalSubdomain=uk", "https://www.linkedin.com/in/arx?originalSubdomain=uk"),
		// Amazon `ref`, its prefixes and the `/ref=…` path tail.
		(
			"https://www.amazon.com/dp/B000/ref=sr_1_1?keywords=book&ref=x&pd_rd_w=1&pf_rd_p=2&qid=3",
			"https://www.amazon.com/dp/B000?keywords=book"
		),
		("https://www.amazon.co.uk/gp/product/B000/ref=ppx_yo", "https://www.amazon.co.uk/gp/product/B000"),
		// Instagram, TikTok, Reddit and Facebook share tags.
		("https://www.instagram.com/p/abc/?igsh=xyz", "https://www.instagram.com/p/abc/"),
		("https://www.tiktok.com/@arx/video/1?_t=8&_r=1&lang=en", "https://www.tiktok.com/@arx/video/1?lang=en"),
		("https://www.reddit.com/r/swift/comments/1/?share_id=abc", "https://www.reddit.com/r/swift/comments/1/"),
		("https://www.facebook.com/share/abc?mibextid=xyz", "https://www.facebook.com/share/abc"),
	])
	internal func siteRulesApplyOnTheirSiteOnly(
		_ input: String,
		_ expected: String
	) async throws {
		#expect(cleaned(input) == expected)
	}

	@Test(arguments: [
		// The same names elsewhere mean something else.
		"https://capturecontext.dev/watch?si=share&t=40",
		"https://example.com/search?s=swift&t=1",
		"https://notamazon.com/dp/B000/ref=sr_1_1?ref=x",
		"https://amazon.com.evil.example/ref=x?ref=y",
		// A path that's only the tracking segment keeps it.
		"https://www.amazon.com/ref=nav_logo",
		// Parameters that choose what's shown stay: the seller's offer, the variant, the
		// carousel image.
		"https://www.amazon.com/dp/B000?smid=A1&psc=1&th=1",
		"https://www.instagram.com/p/abc/?img_index=2",
	])
	internal func siteRulesLeaveOtherSitesAlone(_ input: String) async throws {
		#expect(cleaned(input) == input)
	}

	@Test
	internal func signedLinksStayExactEvenOnASite() async throws {
		let url = "https://www.amazon.com/dp/B000/ref=sr_1_1?ref=x&X-Amz-Signature=abc"
		let result = LinkTransformer.clean(.init(title: "", url: URL(string: url)!))
		expectNoDifference(result.outcome, .sensitiveParametersPreserved)
		#expect(result.output.absoluteString == url)
	}

	@Test
	internal func rulesComeFromData() async throws {
		let json = #"""
		{"version": 1, "parameters": ["Track"], "prefixes": ["x_"],
		 "sites": [{"name": "Shop", "hosts": ["Shop.example"], "parameters": ["Aff"], "pathSegmentPrefixes": ["via="]}]}
		"""#
		let rules = try JSONDecoder().decode(CleanLinkRules.self, from: Data(json.utf8)).normalized
		let item = LinkCopyItem(title: "", url: URL(string: "https://www.shop.example/item/1/via=home?track=1&x_a=2&aff=3&id=4")!)
		let result = LinkTransformer.clean(item, rules: rules)
		#expect(result.output.absoluteString == "https://www.shop.example/item/1?id=4")
		expectNoDifference(result.outcome, .cleaned(["track", "x_a", "aff", "/via=home"]))
	}
}
