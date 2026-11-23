import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-1170: Match site has the accent's three levels, Settings' default, a profile's and a
/// space's, the most specific winning.
internal struct MatchSiteLevelsTests {
	// MARK: - Resolution

	@Test(arguments: [false, true])
	internal func theMostSpecificChoiceWins(global: Bool) {
		let appWide = ChromeAppearance(matchesSite: global)
		let levels: [Bool?] = [nil, false, true]
		for profile in levels {
			for space in levels {
				let resolved = ChromeAppearance.resolve(
					global: appWide,
					profile: .init(matchesSite: profile),
					space: .init(matchesSite: space)
				)
				expectNoDifference(resolved.matchesSite, space ?? profile ?? global, "profile \(String(describing: profile)), space \(String(describing: space))")
			}
		}
	}

	@Test
	internal func inheritingDropsOnlyThatChoice() {
		let space = AppearanceOverride(tintHue: 30, matchesSite: false, accent: ChromeAccent.Preset.red.accent)

		let inheriting = space.inheritingMatchSite()

		expectNoDifference(inheriting, .init(tintHue: 30, accent: ChromeAccent.Preset.red.accent))
		#expect(ChromeAppearance.resolve(global: .init(matchesSite: true), profile: nil, space: inheriting).matchesSite)
	}

	@Test
	internal func theAppWideChoiceIsEveryLevelsChoiceAtSettings() {
		// Settings edits the app-wide level through an override with every setting chosen.
		let chosen = AppearanceOverride(ChromeAppearance(matchesSite: true))
		expectNoDifference(chosen.matchesSite, true)
		#expect(chosen.applied(to: .default).matchesSite)
		#expect(!AppearanceOverride(ChromeAppearance.default).applied(to: .init(matchesSite: true)).matchesSite)
	}

	// MARK: - Saving

	/// The coders the workspace file and database columns save with.
	private static var savingEncoder: JSONEncoder {
		let encoder: JSONEncoder = .init()
		encoder.userInfo[AppearanceOverride.storageCoding] = true
		return encoder
	}

	private static var loadingDecoder: JSONDecoder {
		let decoder: JSONDecoder = .init()
		decoder.userInfo[AppearanceOverride.storageCoding] = true
		return decoder
	}

	@Test
	internal func aSpaceSavedWithMatchSiteOnKeepsItAndEveryOtherInherits() throws {
		func decoded(_ json: String) throws -> AppearanceOverride {
			try Self.loadingDecoder.decode(AppearanceOverride.self, from: Data(json.utf8))
		}

		// Before DEV-1170 a space chose on, and off was the only default there was.
		expectNoDifference(try decoded(#"{"matchesSite":true,"tintHue":120}"#), .init(tintHue: 120, matchesSite: true))
		expectNoDifference(try decoded(#"{"matchesSite":false,"tintHue":120}"#), .init(tintHue: 120))
		expectNoDifference(try decoded(#"{"tintHue":120}"#), .init(tintHue: 120))

		// Since, off is a choice of its own, over a default that's on.
		expectNoDifference(try decoded(#"{"matchSite":false}"#), .init(matchesSite: false))
		expectNoDifference(try decoded(#"{"matchSite":false,"matchesSite":true}"#), .init(matchesSite: false))
	}

	@Test(arguments: [nil, false, true] as [Bool?])
	internal func everyChoiceReadsBackAsSaved(_ matchesSite: Bool?) throws {
		let chosen = AppearanceOverride(grainEnabled: false, matchesSite: matchesSite)

		let encoded = try Self.savingEncoder.encode(chosen)

		expectNoDifference(try Self.loadingDecoder.decode(AppearanceOverride.self, from: encoded), chosen)

		// An earlier build reads on as on, and anything else as off, its only default.
		let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		expectNoDifference(object["matchesSite"] as? Bool, matchesSite == true ? true : nil)
	}

	/// Agents and the automation helper see `matchesSite` itself: on, off or absent.
	@Test(arguments: [nil, false, true] as [Bool?])
	internal func agentsSeeEveryChoiceAsMatchesSite(_ matchesSite: Bool?) throws {
		let chosen = AppearanceOverride(grainEnabled: false, matchesSite: matchesSite)

		let encoded = try JSONEncoder().encode(chosen)

		let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		expectNoDifference(Set(object.keys), matchesSite == nil ? ["grainEnabled"] : ["grainEnabled", "matchesSite"])
		expectNoDifference(object["matchesSite"] as? Bool, matchesSite)
		expectNoDifference(try JSONDecoder().decode(AppearanceOverride.self, from: encoded), chosen)

		// What was saved reads the same way.
		expectNoDifference(try JSONDecoder().decode(AppearanceOverride.self, from: Self.savingEncoder.encode(chosen)), chosen)
	}

	@Test
	internal func aWorkspaceSavedBeforeKeepsItsSpacesLooks() throws {
		let profileID = Profile.ID(rawValue: UUID())
		let on = Space(id: .init(rawValue: UUID()), profileID: profileID, name: "On", appearance: .init(matchesSite: true))
		let off = Space(id: .init(rawValue: UUID()), profileID: profileID, name: "Off", appearance: .init(tintHue: 200))
		let organization = BrowserOrganization(
			profiles: [.init(id: profileID, name: "Personal")],
			spaces: [on, off]
		)
		var object = try #require(JSONSerialization.jsonObject(with: Self.savingEncoder.encode(organization)) as? [String: Any])

		// As an earlier build saved them: a space that had it off said so.
		var spaces = try #require(object["spaces"] as? [[String: Any]])
		for index in spaces.indices {
			var appearance = try #require(spaces[index]["appearance"] as? [String: Any])
			appearance["matchesSite"] = appearance["matchSite"] ?? false
			appearance.removeValue(forKey: "matchSite")
			spaces[index]["appearance"] = appearance
		}
		object["spaces"] = spaces
		let saved = try JSONSerialization.data(withJSONObject: object)

		let loaded = try Self.loadingDecoder.decode(BrowserOrganization.self, from: saved)

		expectNoDifference(loaded.spaces[id: on.id]?.appearance, .init(matchesSite: true))
		expectNoDifference(loaded.spaces[id: off.id]?.appearance, .init(tintHue: 200))
		let everywhere = ChromeAppearance(matchesSite: true)
		let offSpace = loaded.spaces[id: off.id]?.appearance
		#expect(ChromeAppearance.resolve(global: everywhere, profile: nil, space: offSpace).matchesSite)
	}

	@Test
	internal func preferencesSavedBeforeHaveItOff() throws {
		var preferences = BrowserPreferences()
		preferences.chromeMatchesSite = true
		let encoded = try JSONEncoder().encode(preferences)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: encoded).chromeAppearance.matchesSite)

		var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		object.removeValue(forKey: "chromeMatchesSite")
		let older = try JSONSerialization.data(withJSONObject: object)
		#expect(try !JSONDecoder().decode(BrowserPreferences.self, from: older).chromeMatchesSite)
		#expect(!BrowserPreferences().chromeAppearance.matchesSite)
	}

	@Test
	internal func anAppearanceEncodedBeforeHasItOff() throws {
		let appearance = ChromeAppearance(accent: ChromeAccent.Preset.teal.accent, matchesSite: true)
		let encoded = try JSONEncoder().encode(appearance)
		expectNoDifference(try JSONDecoder().decode(ChromeAppearance.self, from: encoded), appearance)

		var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		object.removeValue(forKey: "matchesSite")
		let older = try JSONSerialization.data(withJSONObject: object)
		expectNoDifference(
			try JSONDecoder().decode(ChromeAppearance.self, from: older),
			.init(accent: ChromeAccent.Preset.teal.accent)
		)
	}

	// MARK: - Agents

	@Test
	internal func agentsReadAndChooseTheAppWideDefault() throws {
		var preferences = BrowserPreferences()
		expectNoDifference(AutomationPreferenceKey.matchesSite.value(in: preferences), .bool(false))
		#expect(AutomationPreferenceKey.matchesSite.isAppearance)

		preferences = try preferences.applying([.init(key: .matchesSite, value: .bool(true))])

		#expect(preferences.chromeMatchesSite)
		expectNoDifference(AutomationPreferenceKey.matchesSite.value(in: preferences), .bool(true))

		// Choosing it leaves the rest of the appearance as it was.
		expectNoDifference(preferences.chromeAppearance, .init(matchesSite: true))
		#expect(throws: AutomationFailure.invalidValue) {
			try preferences.applying([.init(key: .matchesSite, value: .string("on"))])
		}
	}

	@Test
	internal func agentsSeeTheMatchSiteInEffect() {
		let everywhere = ChromeAppearance(matchesSite: true)

		#expect(AutomationResolvedAppearance(global: everywhere, profile: nil, space: nil).matchesSite)
		#expect(!AutomationResolvedAppearance(global: everywhere, profile: .init(matchesSite: false), space: nil).matchesSite)
		#expect(AutomationResolvedAppearance(global: everywhere, profile: .init(matchesSite: false), space: .init(matchesSite: true)).matchesSite)
		#expect(!AutomationResolvedAppearance(global: .default, profile: .init(matchesSite: true), space: .init(matchesSite: false)).matchesSite)
	}

	@Test
	internal func anAgentsOffSurvivesItsTripThroughApproval() throws {
		// Approvals, undo and the helper's requests use the plain coders.
		let change = AutomationAppearanceChange(set: .init(matchesSite: false))
		let decoded = try JSONDecoder().decode(AutomationAppearanceChange.self, from: JSONEncoder().encode(change))

		expectNoDifference(decoded, change)
		expectNoDifference(decoded.setFields, [.matchesSite])
		expectNoDifference(decoded.applied(to: .init(matchesSite: true, accent: ChromeAccent.Preset.red.accent)), .init(matchesSite: false, accent: ChromeAccent.Preset.red.accent))
		expectNoDifference(AutomationAppearanceChange(inherit: [.matchesSite]).applied(to: .init(matchesSite: false)), .init())
	}
}
