import BrowserCore
import CustomDump
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

/// Air Traffic Control's builder: one pattern per route, and routes saved as they change.
@Suite(.dependencies)
@MainActor
internal struct RoutingBuilderTests {
	private static let base = RoutingRule(
		id: UUID(0),
		name: "",
		host: "",
		destination: .init(scope: .currentSpace, mode: .mainBrowser)
	)

	@Test(arguments: [
		("github.com/capturecontext", nil, "github.com", nil, "/capturecontext"),
		("localhost:3000", nil, "localhost", 3000, nil),
		("http://example.com/a%20b", "http", "example.com", nil, "/a%20b"),
		("  linear.app/  ", nil, "linear.app", nil, nil),
		("[::1]:3000/a", nil, "::1", 3000, "/a"),
	] as [(String, String?, String, Int?, String?)])
	internal func aPatternIsAHostWithAnOptionalPortAndPath(
		pattern: String,
		scheme: String?,
		host: String,
		port: Int?,
		path: String?
	) throws {
		let rule = try #require(RoutingPattern.apply(pattern, to: Self.base))
		#expect(rule.scheme == scheme)
		#expect(rule.host == host)
		#expect(rule.port == port)
		#expect(rule.pathPrefix == path)
		try rule.validate()

		// What the field shows for the saved route reads back as the same route.
		#expect(RoutingPattern.apply(RoutingPattern.text(for: rule), to: Self.base) == rule.with(name: RoutingPattern.text(for: rule)))
	}

	@Test(arguments: ["", "   ", "https://example.com/?q=1"])
	internal func somethingThatIsntAHostIsntAPattern(pattern: String) {
		#expect(RoutingPattern.apply(pattern, to: Self.base) == nil)
	}

	@Test
	internal func aNewRouteIsAddedAndThenChangedInPlace() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off
		let draft = try #require(RoutingPattern.apply("github.com/capturecontext", to: Self.base))
		await store.send(.ui(.routing(.add(draft, organization))))
		let saved = try #require(store.state.routingPreferences.rules.first)
		#expect(saved.id == UUID(0))
		#expect(saved.pathPrefix == "/capturecontext")

		var little = saved
		little.destination = .init(scope: .space(organization.spaces[0].id), mode: .littleArx)
		await store.send(.ui(.routing(.update(little, organization))))
		expectNoDifference(store.state.routingPreferences.rules, [little])

		// A destination that's gone is refused on that route's row.
		var missing = little
		missing.destination.scope = .space(.init(rawValue: UUID(99)))
		await store.send(.ui(.routing(.update(missing, organization))))
		expectNoDifference(store.state.routingPreferences.rules, [little])
		#expect(store.state.routing.failedRuleID == little.id)
		#expect(store.state.routing.error == .missingSpace)
	}
}

extension RoutingRule {
	fileprivate func with(name: String) -> Self {
		var rule = self
		rule.name = name
		return rule
	}
}
