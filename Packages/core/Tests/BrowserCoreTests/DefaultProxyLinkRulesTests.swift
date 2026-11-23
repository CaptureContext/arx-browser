import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-1003: the Instagram, X and TikTok rules Arx starts with, and how they reach an install.
internal struct DefaultProxyLinkRulesTests {
	@Test(arguments: [
		("https://www.instagram.com/reel/C1a2b3/?igsh=abc", "https://kkinstagram.com/reel/C1a2b3/?igsh=abc"),
		("https://instagram.com/p/XyZ/#comments", "https://kkinstagram.com/p/XyZ/#comments"),
		("https://x.com/user/status/1234567890?s=20", "https://fxtwitter.com/user/status/1234567890?s=20"),
		("https://twitter.com/user/status/1234567890", "https://fxtwitter.com/user/status/1234567890"),
		("https://mobile.twitter.com/user/status/1", "https://fxtwitter.com/user/status/1"),
		("https://www.x.com/user", "https://fxtwitter.com/user"),
		("https://www.tiktok.com/@user/video/123?lang=en", "https://www.vxtiktok.com/@user/video/123?lang=en"),
		("https://vm.tiktok.com/ZMabc123/", "https://vm.vxtiktok.com/ZMabc123/"),
		("https://tiktok.com/@user", "https://vxtiktok.com/@user"),
	])
	internal func defaultsRewriteTheHostAndKeepTheRest(
		_ input: String,
		_ expected: String
	) async throws {
		let item = LinkCopyItem(title: "", url: try #require(URL(string: input)))
		let result = LinkTransformer.proxy(item, rules: ProxyLinkRule.defaults)
		expectNoDifference(result.output.absoluteString, expected)
	}

	@Test
	internal func defaultsAreValidAndLeaveOtherSitesAlone() async throws {
		for rule in ProxyLinkRule.defaults { try rule.validate() }
		try BrowserPreferences(proxyLinkRules: ProxyLinkRule.defaults).validate()
		for input in ["https://notinstagram.com/p/1", "https://example.com/x.com", "https://tiktok.com.example/a"] {
			let item = LinkCopyItem(title: "", url: try #require(URL(string: input)))
			expectNoDifference(LinkTransformer.proxy(item, rules: ProxyLinkRule.defaults).outcome, .noMatchingRule)
		}
	}

	@Test
	internal func onlySubdomainRulesMatchSubdomains() async throws {
		let exact = ProxyLinkRule(
			id: UUID(),
			name: "Mirror",
			sourceHosts: ["github.com"],
			destinationTemplate: "https://mirror.example{path}"
		)
		#expect(exact.matches(try #require(URL(string: "https://github.com/a"))))
		#expect(!exact.matches(try #require(URL(string: "https://gist.github.com/a"))))

		var subdomains = exact
		subdomains.destinationTemplate = "https://{subdomain}mirror.example{path}"
		try subdomains.validate()
		#expect(subdomains.matches(try #require(URL(string: "https://gist.github.com/a"))))
		let item = LinkCopyItem(title: "", url: try #require(URL(string: "https://a.b.github.com/x")))
		expectNoDifference(
			LinkTransformer.proxy(item, rules: [subdomains]).output.absoluteString,
			"https://a.b.mirror.example/x"
		)
	}

	@Test
	internal func subdomainStartsTheDestinationHost() async throws {
		for template in ["https://mirror.example/{subdomain}{path}", "https://x{subdomain}mirror.example{path}"] {
			let rule = ProxyLinkRule(id: UUID(), name: "Mirror", sourceHosts: ["github.com"], destinationTemplate: template)
			#expect(throws: LinkTransformationError.invalidTemplate) { try rule.validate() }
		}
	}

	@Test
	internal func aFirstLaunchGetsEveryDefaultOnce() async throws {
		var preferences = BrowserPreferences()
		let changed: Bool = preferences.offerDefaultProxyLinkRules()
		#expect(changed)
		expectNoDifference(preferences.proxyLinkRules, ProxyLinkRule.defaults)
		expectNoDifference(Set(preferences.offeredProxyLinkDefaults), Set(ProxyLinkRule.defaults.map(\.id)))

		let changedAgain: Bool = preferences.offerDefaultProxyLinkRules()
		#expect(!changedAgain)
		expectNoDifference(preferences.proxyLinkRules, ProxyLinkRule.defaults)
	}

	@Test
	internal func anExistingInstallKeepsItsOwnRulesForTheSameHosts() async throws {
		let own = ProxyLinkRule(
			id: UUID(),
			name: "fixupx",
			sourceHosts: ["twitter.com"],
			destinationTemplate: "https://fixupx.com{path}",
			isEnabled: false
		)
		let vm = ProxyLinkRule(
			id: UUID(),
			name: "TikTok short links",
			sourceHosts: ["vm.tiktok.com"],
			destinationTemplate: "https://vm.tnktok.com{path}"
		)
		var preferences = BrowserPreferences(proxyLinkRules: [own, vm])
		let changed: Bool = preferences.offerDefaultProxyLinkRules()
		#expect(changed)
		// Instagram is new; X shares twitter.com, even switched off; TikTok's covers vm.tiktok.com.
		expectNoDifference(preferences.proxyLinkRules, [own, vm, ProxyLinkRule.defaults[0]])
	}

	@Test
	internal func aRemovedDefaultStaysRemoved() async throws {
		var preferences = BrowserPreferences()
		preferences.offerDefaultProxyLinkRules()
		preferences.proxyLinkRules.removeAll { $0.id == ProxyLinkRule.defaults[1].id }
		let changedAgain: Bool = preferences.offerDefaultProxyLinkRules()
		#expect(!changedAgain)
		#expect(!preferences.proxyLinkRules.contains { $0.id == ProxyLinkRule.defaults[1].id })
	}

	/// DEV-1113: a default deleted on one Mac isn't offered on another, which hasn't offered any yet.
	@Test
	internal func aDeletedDefaultIsNotOfferedOnAnotherMac() async throws {
		let deleted = ProxyLinkRule.defaults[1]
		var preferences = BrowserPreferences(removedProxyLinkDefaults: [deleted.id])
		let changed: Bool = preferences.offerDefaultProxyLinkRules()
		#expect(changed)
		expectNoDifference(preferences.proxyLinkRules, ProxyLinkRule.defaults.filter { $0.id != deleted.id })

		// Offered all the same: Restore Default Links brings it back, not a later launch.
		expectNoDifference(Set(preferences.offeredProxyLinkDefaults), Set(ProxyLinkRule.defaults.map(\.id)))

		preferences.removedProxyLinkDefaults = []
		let changedAgain: Bool = preferences.offerDefaultProxyLinkRules()
		#expect(!changedAgain)
		#expect(!preferences.proxyLinkRules.contains { $0.id == deleted.id })
	}

	@Test
	internal func onlyADeletedDefaultIsRemembered() async throws {
		let own = UUID()
		expectNoDifference(ProxyLinkRule.removedDefaults([], deleting: own), [])
		let first: [UUID] = ProxyLinkRule.removedDefaults([], deleting: ProxyLinkRule.defaults[2].id)
		expectNoDifference(first, [ProxyLinkRule.defaults[2].id])
		let both: [UUID] = ProxyLinkRule.removedDefaults(first, deleting: ProxyLinkRule.defaults[0].id)
		expectNoDifference(both, [ProxyLinkRule.defaults[0].id, ProxyLinkRule.defaults[2].id].sorted { $0.uuidString < $1.uuidString })
		expectNoDifference(ProxyLinkRule.removedDefaults(both, deleting: ProxyLinkRule.defaults[0].id), both)
		#expect(ProxyLinkRule.isDefault(ProxyLinkRule.defaults[0].id))
		#expect(!ProxyLinkRule.isDefault(own))
	}

	@Test
	internal func removedDefaultsSurviveCoding() async throws {
		let preferences = BrowserPreferences(removedProxyLinkDefaults: [ProxyLinkRule.defaults[0].id])
		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(preferences))
		expectNoDifference(decoded.removedProxyLinkDefaults, preferences.removedProxyLinkDefaults)

		var values = try #require(
			JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any]
		)
		values.removeValue(forKey: "removedProxyLinkDefaults")
		let older = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: values)
		)
		#expect(older.removedProxyLinkDefaults.isEmpty)
	}

	@Test
	internal func offeredDefaultsSurviveCoding() async throws {
		var preferences = BrowserPreferences()
		preferences.offerDefaultProxyLinkRules()
		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(preferences))
		expectNoDifference(decoded.offeredProxyLinkDefaults, preferences.offeredProxyLinkDefaults)

		var values = try #require(
			JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserPreferences())) as? [String: Any]
		)
		values.removeValue(forKey: "offeredProxyLinkDefaults")
		let older = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: values)
		)
		#expect(older.offeredProxyLinkDefaults.isEmpty)
	}

	@Test
	internal func restoreDefaultsResetsThemAndKeepsTheirOwnFirst() async throws {
		var changed = ProxyLinkRule.defaults[2]
		changed.isEnabled = false
		changed.destinationTemplate = "https://tnktok.com{path}"
		let own = ProxyLinkRule(
			id: UUID(),
			name: "ddinstagram",
			sourceHosts: ["instagram.com"],
			destinationTemplate: "https://ddinstagram.com{path}"
		)
		let restored = ProxyLinkRule.restoringDefaults([changed, own])
		expectNoDifference(
			restored,
			[ProxyLinkRule.defaults[2], own, ProxyLinkRule.defaults[0], ProxyLinkRule.defaults[1]]
		)
	}
}
