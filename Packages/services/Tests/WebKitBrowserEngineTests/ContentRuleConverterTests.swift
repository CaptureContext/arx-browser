import CustomDump
import Foundation
import Testing

@testable import WebKitBrowserEngine

internal struct ContentRuleConverterTests {
	private typealias Rule = ContentRuleConverter.Rule

	@Test
	internal func hostAnchorsSeparatorsAndWildcards() async throws {
		#expect(ContentRuleConverter.urlFilter("||ads.example.com^") == #"^[^:]+://+([^:/]+\.)?ads\.example\.com[/:]"#)
		#expect(ContentRuleConverter.urlFilter("|https://track.") == #"^https://track\."#)
		#expect(ContentRuleConverter.urlFilter("/banner/*/ad.js|") == #"/banner/.*/ad\.js$"#)
		#expect(ContentRuleConverter.urlFilter("*/pixel?id=") == #"/pixel\?id="#)
		#expect(ContentRuleConverter.urlFilter("&ad_type=^") == #"&ad_type=[^a-zA-Z0-9_.%-]"#)
		#expect(ContentRuleConverter.urlFilter("a|b") == nil)
	}

	@Test
	internal func networkFiltersKeepTheirOptions() async throws {
		let conversion = ContentRuleConverter().convert("""
		! A comment
		[Adblock Plus 2.0]
		||ads.example.com^$third-party,script
		||cdn.example.net/ads/$image,domain=news.example|~sub.news.example
		||frames.example^$subdocument,domain=a.example|b.example
		/pop.js$~third-party,xhr
		@@||ads.example.com/ok.js$script
		@@||shop.example^$document
		@@||blog.example^$generichide
		/^https?:\\/\\/regex/$script
		||redirected.example^$redirect=noopjs
		||anything.example^$~script
		*$image
		""")

		expectNoDifference(conversion.blocking, [
			Rule(
				trigger: .init(
					urlFilter: #"^[^:]+://+([^:/]+\.)?ads\.example\.com[/:]"#,
					resourceType: ["script"],
					loadType: ["third-party"]
				),
				action: .init(type: "block")
			),
			Rule(
				trigger: .init(
					urlFilter: #"^[^:]+://+([^:/]+\.)?frames\.example[/:]"#,
					resourceType: ["document"],
					loadContext: ["child-frame"],
					ifDomain: ["*a.example", "*b.example"]
				),
				action: .init(type: "block")
			),
			Rule(
				trigger: .init(
					urlFilter: #"/pop\.js"#,
					resourceType: ["fetch"],
					loadType: ["first-party"]
				),
				action: .init(type: "block")
			),
		])
		expectNoDifference(conversion.exceptions, [
			Rule(
				trigger: .init(
					urlFilter: #"^[^:]+://+([^:/]+\.)?ads\.example\.com/ok\.js"#,
					resourceType: ["script"]
				),
				action: .init(type: "ignore-previous-rules")
			),
			Rule(
				trigger: .init(urlFilter: ".*", ifDomain: ["*shop.example"]),
				action: .init(type: "ignore-previous-rules")
			),
		])

		// `$generichide` turns element hiding off for the site, not its blocking.
		expectNoDifference(conversion.hidingExceptions, [
			Rule(
				trigger: .init(urlFilter: ".*", ifDomain: ["*blog.example"]),
				action: .init(type: "ignore-previous-rules")
			),
		])
		let ordered = conversion.rules()
		let hidingException = try #require(ordered.firstIndex(of: conversion.hidingExceptions[0]))
		let firstBlock = try #require(ordered.firstIndex(of: conversion.blocking[0]))
		#expect(hidingException < firstBlock)
	}

	@Test
	internal func elementHidingIsBatchedAndScoped() async throws {
		let generic = (1 ... 51).map { "##.ad-\($0)" }.joined(separator: "\n")
		let conversion = ContentRuleConverter().convert("""
		\(generic)
		news.example,video.example##.sponsored
		~safe.example##.promo
		example.com##.text:has-text(Ad)
		example.com##+js(nowebrtc)
		example.com#@#.ad
		example.com#?#.x
		""")

		expectNoDifference(Array(conversion.hiding.prefix(2)), [
			Rule(
				trigger: .init(urlFilter: ".*", ifDomain: ["*news.example", "*video.example"]),
				action: .init(type: "css-display-none", selector: ".sponsored")
			),
			Rule(
				trigger: .init(urlFilter: ".*", unlessDomain: ["*safe.example"]),
				action: .init(type: "css-display-none", selector: ".promo")
			),
		])
		#expect(conversion.blocking.isEmpty)
		let batches = conversion.hiding.dropFirst(2)
		#expect(batches.count == 2)
		#expect(batches.first?.action.selector?.hasPrefix(".ad-1, .ad-2, ") == true)
		#expect(batches.last?.action.selector == ".ad-51")
		#expect(conversion.exceptions.isEmpty)
	}

	/// DEV-1202: WebKit can't match entity domains (`kat.*`). A filter whose sites are all entity
	/// domains, with plain exceptions, became "everywhere but the exceptions": uBlock's
	/// `*$script,1p,domain=kat.*|~kat.ai` blocked every site's own scripts in WebKit pages, and
	/// Apple's Apple Pay demo never showed its button.
	@Test
	internal func filtersForEntityDomainsOnlyAreLeftOut() async throws {
		let conversion = ContentRuleConverter().convert("""
		*$script,1p,domain=~kat.ai|~kat.pink|kat.*|kickass.*
		||ads.example^$domain=news.example|news.*
		||track.example^$domain=~local.example|~[::1]
		~vipbox.pl,vipbox.*##.position-absolute
		news.example,news.*##.sponsored
		""")

		#expect(conversion.blocking.allSatisfy { $0.trigger.urlFilter != ".*" })
		expectNoDifference(conversion.blocking.map(\.trigger.ifDomain), [["*news.example"], nil])

		// A skipped exception only applies a filter on one more site, so the filter stays.
		expectNoDifference(conversion.blocking.last?.trigger.unlessDomain, ["*local.example"])
		expectNoDifference(conversion.hiding, [
			Rule(
				trigger: .init(urlFilter: ".*", ifDomain: ["*news.example"]),
				action: .init(type: "css-display-none", selector: ".sponsored")
			),
		])
		#expect(ContentRuleConverter.domainScope(["kat.*", "~kat.ai"]) == nil)
		#expect(ContentRuleConverter.domainScope(["kat.*"]) == nil)
	}

	/// A list compiled by an older conversion compiles again, though its text hasn't changed.
	@Test
	@MainActor
	internal func aNewConversionCompilesSavedListsAgain() async throws {
		let source = WebKitContentRules.defaultSources[0]
		let current = WebKitContentRules.identifier(of: source, text: "||ads.example^", extraExceptions: [])
		let older = WebKitContentRules.identifier(
			of: source,
			text: "||ads.example^",
			extraExceptions: [],
			revision: ContentRuleConverter.revision - 1
		)

		#expect(current != older)
		#expect(current.hasPrefix(source.name + "-"))
		#expect(current == WebKitContentRules.identifier(of: source, text: "||ads.example^", extraExceptions: []))
	}

	@Test
	internal func limitKeepsEveryExceptionAfterTheBlocks() async throws {
		let block = Rule(trigger: .init(urlFilter: "a"), action: .init(type: "block"))
		let allow = Rule(trigger: .init(urlFilter: "b"), action: .init(type: "ignore-previous-rules"))
		let hide = Rule(trigger: .init(urlFilter: ".*"), action: .init(type: "css-display-none", selector: ".ad"))
		let conversion = ContentRuleConverter.Conversion(
			hiding: Array(repeating: hide, count: 4),
			blocking: Array(repeating: block, count: 10),
			exceptions: Array(repeating: allow, count: 3)
		)
		let rules = conversion.rules(limit: 8)
		#expect(rules.count == 8)
		#expect(rules.suffix(3).allSatisfy { $0 == allow })
		#expect(rules.prefix(5).allSatisfy { $0 == block })
		// With room to spare, hiding comes first.
		let roomy = conversion.rules(limit: 100)
		#expect(roomy.prefix(4).allSatisfy { $0 == hide })
		#expect(roomy.count == 17)
	}

	@Test
	internal func jsonUsesWebKitKeys() async throws {
		let json = try ContentRuleConverter.json([
			.init(
				trigger: .init(urlFilter: "ads/", loadType: ["third-party"], ifDomain: ["*a.example"]),
				action: .init(type: "block")
			),
		])
		#expect(json == #"[{"action":{"type":"block"},"trigger":{"if-domain":["*a.example"],"load-type":["third-party"],"url-filter":"ads/"}}]"#)
	}
}
