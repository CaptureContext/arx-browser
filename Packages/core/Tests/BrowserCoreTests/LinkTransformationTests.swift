import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct LinkTransformationTests {
	@Test
	internal func proxyTemplatesCanUseTheHostWithoutDoublingThePathSlash() throws {
		let rule = ProxyLinkRule(
			id: UUID(),
			name: "Mirror",
			sourceHosts: ["github.com"],
			destinationTemplate: "https://kk{host}/{path}{query}"
		)
		try rule.validate()
		let item = LinkCopyItem(title: "", url: URL(string: "https://github.com/a/b?q=1")!)
		let result = LinkTransformer.proxy(item, rules: [rule])
		expectNoDifference(result.output.absoluteString, "https://kkgithub.com/a/b?q=1")
	}

	@Test
	internal func cleanLinksPreserveEncodingUnknownParametersDuplicatesAndFragments() async throws {
		let item = LinkCopyItem(
			title: "東京",
			url: URL(
				string: "https://capturecontext.dev/%E6%9D%B1%E4%BA%AC/a%2Fb"
				+ "?keep=1&%75tm_source=a&keep=2&utm_source=b&unknown=%2B+%20#/route?utm_source=inside"
			)!
		)
		let result = LinkTransformer.clean(item)
		expectNoDifference(
			result.output.absoluteString,
			"https://capturecontext.dev/%E6%9D%B1%E4%BA%AC/a%2Fb?keep=1&keep=2&unknown=%2B+%20#/route?utm_source=inside"
		)
		expectNoDifference(result.outcome, .cleaned(["utm_source", "utm_source"]))
		expectNoDifference(result.original, item)
	}

	@Test
	internal func cleanLinksKeepSignedShareAndAuthenticationParametersUntouched() async throws {
		for key in ["X-Amz-Signature", "%73ig", "token", "code", "state", "Policy", "expires"] {
			let item = LinkCopyItem(
				title: "",
				url: URL(string: "https://capturecontext.dev/file?utm_source=mail&\(key)=secret")!
			)
			let result = LinkTransformer.clean(item)
			expectNoDifference(result.output, item.url)
			expectNoDifference(result.outcome, .sensitiveParametersPreserved)
		}
		let share = LinkCopyItem(title: "", url: URL(string: "https://capturecontext.dev/watch?si=share&t=40#position")!)
		expectNoDifference(LinkTransformer.clean(share).output, share.url)
	}

	@Test
	internal func cleanLinksRemoveOnlyTheNarrowKnownSetAndKeepEmptyComponents() async throws {
		for (input, expected) in [
			("https://capturecontext.dev/?utm_source=a#", "https://capturecontext.dev/#"),
			("https://capturecontext.dev/?a=&utm_source=a&&b=2&", "https://capturecontext.dev/?a=&&b=2&"),
			// `utm_` is a prefix rule (DEV-918); `ref` is tracking only on Amazon.
			(
				"https://capturecontext.dev/?utm_custom=drop&ref=keep&fbclid=drop&utm_=keep",
				"https://capturecontext.dev/?ref=keep&utm_=keep"
			),
			("https://capturecontext.dev/?#", "https://capturecontext.dev/?#"),
		] {
			let result = LinkTransformer.clean(.init(title: "", url: URL(string: input)!))
			expectNoDifference(result.output.absoluteString, expected)
		}
	}

	@Test
	internal func proxyRulesPreserveEncodedComponentsAndApplyOnlyOneSubstitution() async throws {
		let item = LinkCopyItem(
			title: "Post",
			url: URL(string: "https://X.COM/person/status/a%2Fb?tag=one&tag=two+three#%E6%9D%B1")!
		)
		let first = proxyRule()
		let chain = proxyRule(
			id: 101,
			hosts: ["fxtwitter.com"],
			destination: "https://example.org{path}{query}{fragment}"
		)
		let result = LinkTransformer.proxy(item, rules: [first, chain])
		expectNoDifference(
			result.output.absoluteString,
			"https://fxtwitter.com/person/status/a%2Fb?tag=one&tag=two+three#%E6%9D%B1"
		)
		expectNoDifference(result.outcome, .proxy(first))
		let alreadyProxied = LinkTransformer.proxy(.init(title: "", url: result.output), rules: [first])
		expectNoDifference(alreadyProxied.output, result.output)
		expectNoDifference(alreadyProxied.outcome, .noMatchingRule)
	}

	@Test
	internal func proxyRulesRespectHostBoundariesExplicitSubdomainsAndIDNA() async throws {
		let rule = proxyRule()
		for host in ["notx.com", "x.com.example.org", "www.x.com", "mobile.x.com"] {
			let item = LinkCopyItem(title: "", url: URL(string: "https://\(host)/post")!)
			expectNoDifference(LinkTransformer.proxy(item, rules: [rule]).outcome, .noMatchingRule)
		}
		let explicit = proxyRule(hosts: ["x.com", "www.x.com", "bücher.example"])
		for host in ["WWW.X.COM", "x.com.", "xn--bcher-kva.example"] {
			#expect(explicit.matches(URL(string: "https://\(host)/post")!))
		}
	}

	@Test
	internal func proxyAlternativesUseOrderEnabledStateAndAnExplicitOverride() async throws {
		let item = LinkCopyItem(title: "", url: URL(string: "https://instagram.com/reel/123/?a=1#")!)
		let first = proxyRule(
			hosts: ["instagram.com"],
			destination: "https://ddinstagram.com{path}{query}{fragment}"
		)
		let second = proxyRule(
			id: 101,
			hosts: ["instagram.com"],
			destination: "https://kkinstagram.com{path}{query}{fragment}"
		)
		expectNoDifference(LinkTransformer.proxy(item, rules: [first, second]).output.host(), "ddinstagram.com")
		expectNoDifference(
			LinkTransformer.proxy(item, rules: [first, second], preferredRuleID: second.id).output.host(),
			"kkinstagram.com"
		)
		var disabled = first
		disabled.isEnabled = false
		expectNoDifference(LinkTransformer.proxy(item, rules: [disabled, second]).outcome, .proxy(second))
		expectNoDifference(
			LinkTransformer.proxy(item, rules: [disabled, second], preferredRuleID: first.id).outcome,
			.preserved(.missingPreferredRule)
		)
	}

	@Test
	internal func proxyTemplatesValidatePlaceholderPositionsAndAuthority() async throws {
		for template in [
			"https://{path}.capturecontext.dev", "https://capturecontext.dev/path{query}/suffix",
			"https://capturecontext.dev/?fixed=1{query}", "https://capturecontext.dev/{unknown}",
			"https://capturecontext.dev/{path}/{path}", "https://capturecontext.dev{fragment}{query}",
			"https://user:secret@capturecontext.dev{path}", "https://capturecontext.dev:8080{path}",
			"javascript:alert(1)",
		] {
			#expect(throws: (any Error).self) { try proxyRule(destination: template).validate() }
		}
		for host in ["", "*.x.com", "https://x.com", "x.com/evil", "x.com:443", "x.com@evil.com"] {
			#expect(throws: (any Error).self) { try proxyRule(hosts: [host]).validate() }
		}
		let fixed = proxyRule(destination: "http://capturecontext.dev:80/fixed{query}{fragment}")
		try fixed.validate()
		let result = LinkTransformer.proxy(
			.init(title: "", url: URL(string: "https://x.com/old?#")!),
			rules: [fixed]
		)
		expectNoDifference(result.output.absoluteString, "http://capturecontext.dev:80/fixed?#")
	}

	@Test
	internal func unsupportedProxyInputsArePreservedAndNeverReachAnotherHost() async throws {
		let inputs: [String] = [
			"file:///tmp/private",
			"ftp://x.com/a",
			"https://user:secret@x.com/a",
			"https://x.com:8443/a",
		]

		for input in inputs {
			let item = LinkCopyItem(title: "", url: URL(string: input)!)
			let result = LinkTransformer.proxy(item, rules: [proxyRule()])
			expectNoDifference(result.output, item.url)
			guard case .preserved = result.outcome else {
				Issue.record("Unsafe input was not reported as preserved")
				continue
			}
		}
	}

	@Test
	internal func markdownEscapesTitlesAndPreservesTheRequestedOrderAndExactURLs() async throws {
		let items: [LinkCopyItem] = [
			.init(title: "A [link] *bold*\\\n東京", url: URL(string: "https://x.com/a(b)?utm_source=one")!),
			.init(title: "Second", url: URL(string: "https://capturecontext.dev/2#")!),
		]
		let result = LinkTransformer.copy(items, mode: .markdownOriginal)
		expectNoDifference(
			result.text,
			"[A \\[link\\] \\*bold\\*\\\\ 東京](<https://x.com/a(b)?utm_source=one>)\n"
			+ "[Second](<https://capturecontext.dev/2#>)"
		)
		expectNoDifference(result.transformations.map(\.original), items)
		let proxy = LinkTransformer.copy(items, mode: .markdownProxy, rules: [proxyRule()])
		#expect(proxy.text.contains("https://fxtwitter.com/a(b)?utm_source=one"))
		#expect(proxy.text.hasSuffix("[Second](<https://capturecontext.dev/2#>)"))
	}

	internal func proxyRule(
		id: Int = 100,
		hosts: [String] = ["x.com", "twitter.com"],
		destination: String = "https://fxtwitter.com{path}{query}{fragment}"
	) -> ProxyLinkRule {
		.init(
			id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(id))),
			name: "Example proxy",
			sourceHosts: hosts,
			destinationTemplate: destination
		)
	}
}
