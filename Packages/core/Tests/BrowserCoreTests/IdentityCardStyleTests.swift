import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct IdentityCardStyleTests {
	@Test
	internal func cyclingVisitsEveryStyleInOrderAndWraps() {
		var style: IdentityCardStyle = .holographicFoil
		var visited: [IdentityCardStyle] = [style]
		for _ in 1..<IdentityCardStyle.allCases.count {
			style = style.next
			visited.append(style)
		}
		expectNoDifference(visited, [
			.holographicFoil, .liquidGlass, .smokedGlass, .prismGlass, .spaceTint,
			.graphite, .titanium, .obsidianGold, .carbon, .sunsetGrain, .memberPass,
		])
		expectNoDifference(IdentityCardStyle.memberPass.next, .holographicFoil)
	}

	@Test(arguments: ["missing", "unknown", "number"])
	internal func missingOrUnknownStylesFallBackWithoutLosingOtherPreferences(stored: String) throws {
		var preferences = BrowserPreferences()
		preferences.warnsBeforeQuitting = false
		let data = try JSONEncoder().encode(preferences)
		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		values["identityCardStyle"] = switch stored {
		case "unknown": "aurora"
		case "number": 7
		default: nil
		}
		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: values)
		)
		expectNoDifference(decoded.identityCardStyle, .holographicFoil)
		expectNoDifference(decoded.warnsBeforeQuitting, false)
	}

	@Test
	internal func theChosenStyleRoundTrips() throws {
		var preferences = BrowserPreferences()
		preferences.identityCardStyle = .memberPass
		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONEncoder().encode(preferences)
		)
		expectNoDifference(decoded.identityCardStyle, .memberPass)
	}
}
