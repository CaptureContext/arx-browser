import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct URLRoutingTests {
	@Test
	internal func hostMatchingNormalizesCaseIDNAndSeparatesDomainBoundaries() async throws {
		var rule = rule(host: "CaPtUrEcOnTeXt.DEV.")
		try rule.validate()
		#expect(rule.matches(URL(string: "https://CAPTURECONTEXT.dev/a")!))
		#expect(!rule.matches(URL(string: "https://www.capturecontext.dev/a")!))
		rule.includesSubdomains = true
		#expect(rule.matches(URL(string: "https://a.b.capturecontext.dev/a")!))
		#expect(!rule.matches(URL(string: "https://notcapturecontext.dev/a")!))
		#expect(!rule.matches(URL(string: "https://capturecontext.dev.attacker.test/a")!))
		rule.host = "bücher.example"
		#expect(rule.matches(URL(string: "https://xn--bcher-kva.example/a")!))
	}

	@Test
	internal func schemePortAndEncodedPathSemanticsAreLiteral() async throws {
		var rule = rule(host: "capturecontext.dev")
		rule.pathPrefix = "/docs"
		#expect(rule.matches(URL(string: "https://capturecontext.dev/docs2?q=/other#route")!))
		#expect(!rule.matches(URL(string: "https://capturecontext.dev/Docs")!))
		#expect(!rule.matches(URL(string: "https://capturecontext.dev/%64ocs")!))
		#expect(rule.matches(URL(string: "http://capturecontext.dev:80/docs")!))
		#expect(!rule.matches(URL(string: "https://capturecontext.dev:8443/docs")!))
		rule.port = 8443
		rule.scheme = "https"
		#expect(rule.matches(URL(string: "https://capturecontext.dev:8443/docs")!))
		#expect(!rule.matches(URL(string: "http://capturecontext.dev:8443/docs")!))
		#expect(!rule.matches(URL(string: "file:///docs")!))
	}

	@Test
	internal func IPv6HostsUseExactCanonicalMatchingAndEmptyPathsRepresentRoot() async throws {
		var rule = rule(host: "[2001:db8::1]")
		rule.pathPrefix = "/"
		try rule.validate()
		#expect(rule.matches(URL(string: "https://[2001:0DB8:0:0:0:0:0:1]")!))
		#expect(!rule.matches(URL(string: "https://[2001:db8::2]")!))
		#expect(throws: (any Error).self) { try self.rule(host: "[:::]").validate() }
	}

	@Test
	internal func invalidRuleDefinitionsAreRejected() async throws {
		let invalidHosts: [String] = [
			"capturecontext.dev:443",
			"https://capturecontext.dev",
			"*.capturecontext.dev",
			"capturecontext.dev/path",
			"example..com",
		]

		for host in invalidHosts {
			#expect(throws: (any Error).self) { try rule(host: host).validate() }
		}
		for path in ["docs", "/docs?x=1", "/a b", "/docs#hash", "/%ZZ"] {
			var invalid = rule(host: "capturecontext.dev")
			invalid.pathPrefix = path
			#expect(throws: (any Error).self) { try invalid.validate() }
		}
	}

	@Test
	internal func orderedRulesRespectDisabledRulesAndExplicitOverrides() async throws {
		let organization = fixture()
		var first = rule(host: "capturecontext.dev")
		first.isEnabled = false
		var second = rule(host: "capturecontext.dev")
		second.destination = .init(scope: .space(organization.spaces[1].id), mode: .mainBrowser)
		let preferences = RoutingPreferences(rules: [first, second])
		let url = URL(string: "https://capturecontext.dev/a?code=auth&state=untouched#fragment")!
		let decision = URLRouter.decide(
			url,
			preferences: preferences,
			organization: organization,
			currentSpaceID: organization.spaces[0].id
		)
		expectNoDifference(decision.matchedRuleID, second.id)
		expectNoDifference(decision.url, url)
		expectNoDifference(
			try decision.result.get(),
			.init(
				profileID: organization.profiles[0].id,
				spaceID: organization.spaces[1].id,
				mode: .mainBrowser
			)
		)
		let override = URLRouter.decide(
			url,
			preferences: preferences,
			organization: organization,
			currentSpaceID: organization.spaces[0].id,
			override: .init(scope: .currentSpace)
		)
		expectNoDifference(override.matchedRuleID, nil)
		expectNoDifference(try override.result.get().spaceID, organization.spaces[0].id)
	}

	@Test
	internal func aProfileOpensItsMostRecentSpaceAndAskOpensNothing() async throws {
		let work = Profile.ID(rawValue: UUID())
		let home = Profile.ID(rawValue: UUID())
		let empty = Profile.ID(rawValue: UUID())
		let mail = Space.ID(rawValue: UUID())
		let code = Space.ID(rawValue: UUID())
		let personal = Space.ID(rawValue: UUID())
		let organization = BrowserOrganization(
			profiles: [.init(id: work, name: "Work"), .init(id: home, name: "Home"), .init(id: empty, name: "Empty")],
			spaces: [
				.init(id: mail, profileID: work, name: "Mail"),
				.init(id: code, profileID: work, name: "Code"),
				.init(id: personal, profileID: home, name: "Personal"),
			]
		)
		let preferences = RoutingPreferences()
		func space(
			_ profile: Profile.ID,
			current: Space.ID?,
			recent: [Space.ID] = []
		) throws -> Space.ID {
			try URLRouter.resolve(
				.init(scope: .profile(profile)),
				preferences: preferences,
				organization: organization,
				currentSpaceID: current,
				recentSpaceIDs: recent
			).spaceID
		}

		// Nothing of the profile used yet: its first space.
		expectNoDifference(try space(work, current: personal), mail)

		// The profile's space used last, or the one in front when it's the profile's.
		expectNoDifference(try space(work, current: personal, recent: [personal, code, mail]), code)
		expectNoDifference(try space(work, current: mail, recent: [code]), mail)
		#expect(throws: URLRoutingError.missingSpace) { try space(empty, current: mail) }

		// A route that asks matches, and resolves to nothing until a destination is picked.
		var asking = rule(host: "accounts.google.com")
		asking.destination = .init(scope: .ask)
		let decision = URLRouter.decide(
			URL(string: "https://accounts.google.com/o/oauth2")!,
			preferences: .init(rules: [asking]),
			organization: organization,
			currentSpaceID: mail
		)
		expectNoDifference(decision.matchedRuleID, asking.id)
		expectNoDifference(decision.result, .failure(.missingDestination))
	}

	/// DEV-987: a local file opened with Arx goes where a link no rule matches goes, even when
	/// a rule names localhost; a file on another host, or another scheme, isn't routed.
	@Test
	internal func aLocalFileTakesTheFallbackWhateverTheRules() async throws {
		let organization = fixture()
		var localhost = rule(host: "localhost")
		localhost.destination = .init(scope: .space(organization.spaces[1].id), mode: .mainBrowser)
		let preferences = RoutingPreferences(rules: [localhost])
		let fallback = try #require(preferences.fallback)
		for raw in ["file:///Users/max/local-reports/index.html", "file://localhost/tmp/a%20b.html"] {
			let decision = URLRouter.decide(
				URL(string: raw)!,
				preferences: preferences,
				organization: organization,
				currentSpaceID: organization.spaces[0].id
			)
			expectNoDifference(decision.matchedRuleID, nil)
			expectNoDifference(decision.destination, fallback)
			expectNoDifference(
				try decision.result.get(),
				.init(profileID: organization.profiles[0].id, spaceID: organization.spaces[0].id, mode: fallback.mode)
			)
		}
		for raw in ["file://server.example/share/a.html", "ftp://example.test/a"] {
			let decision = URLRouter.decide(
				URL(string: raw)!,
				preferences: preferences,
				organization: organization,
				currentSpaceID: organization.spaces[0].id
			)
			expectNoDifference(decision.result, .failure(.unsupportedURL))
		}
	}

	@Test
	internal func missingRulesDoNotFallThrough() async throws {
		let organization = fixture()
		var preferences = RoutingPreferences()
		var missing = rule(host: "capturecontext.dev")
		missing.destination = .init(scope: .space(.init(rawValue: UUID())))
		preferences.rules = [missing]
		let decision = URLRouter.decide(
			URL(string: "https://capturecontext.dev")!,
			preferences: preferences,
			organization: organization,
			currentSpaceID: organization.spaces[0].id
		)
		expectNoDifference(decision.result, .failure(.missingSpace))
		expectNoDifference(decision.matchedRuleID, missing.id)
	}

	@Test
	internal func routingPreferencesRoundTripAndOlderPreferencesKeepCurrentLittleArxFallback() async throws {
		var preferences = BrowserPreferences()
		preferences.routing = .init(rules: [rule(host: "capturecontext.dev")], fallback: nil)
		let data = try JSONEncoder().encode(preferences)
		expectNoDifference(try JSONDecoder().decode(BrowserPreferences.self, from: data), preferences)
		var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		object.removeValue(forKey: "routing")
		let older = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: object)
		)
		expectNoDifference(older.routing, RoutingPreferences())
	}

	private func rule(host: String) -> RoutingRule {
		.init(id: UUID(), name: "Rule", host: host, destination: .init(scope: .currentSpace))
	}

	private func fixture() -> BrowserOrganization {
		let profileID = Profile.ID(rawValue: UUID())
		return .init(
			profiles: [.init(id: profileID, name: "Default")],
			spaces: [
				.init(id: .init(rawValue: UUID()), profileID: profileID, name: "First"),
				.init(id: .init(rawValue: UUID()), profileID: profileID, name: "Second"),
			]
		)
	}
}
