import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-1258: unread badges shown or hidden at four levels, the most specific choice winning.
internal struct UnreadBadgeVisibilityTests {
	/// Every combination of the four levels: three choices each for the tab, the site and the
	/// profile (inherit, show, hide) and two for the browser default.
	internal static let levels: [(
		tab: UnreadBadgeVisibility?,
		site: UnreadBadgeVisibility?,
		profile: UnreadBadgeVisibility?,
		browser: UnreadBadgeVisibility
	)] = {
		let choices: [UnreadBadgeVisibility?] = [nil, .show, .hide]
		var result: [(UnreadBadgeVisibility?, UnreadBadgeVisibility?, UnreadBadgeVisibility?, UnreadBadgeVisibility)] = []
		for tab in choices {
			for site in choices {
				for profile in choices {
					for browser in UnreadBadgeVisibility.allCases {
						result.append((tab, site, profile, browser))
					}
				}
			}
		}
		return result
	}()

	@Test
	internal func everyCombinationIsCovered() async throws {
		// Three choices for each of three levels, and two for the browser default.
		let count: Int = 54
		#expect(Self.levels.count == count)
	}

	@Test(arguments: Self.levels.indices)
	internal func theMostSpecificChoiceWins(index: Int) async throws {
		let (tab, site, profile, browser) = Self.levels[index]

		// The first level that chooses, from the tab to the browser default.
		let expected: UnreadBadgeVisibility = if let tab {
			tab
		} else if let site {
			site
		} else if let profile {
			profile
		} else {
			browser
		}
		expectNoDifference(
			UnreadBadgeVisibility.resolve(tab: tab, site: site, profile: profile, browser: browser),
			expected
		)

		// The overrides resolve a real tab the same way, by its site's host.
		let tabID = Tab.ID(rawValue: UUID())
		let page = Tab(
			id: tabID,
			profileID: .init(rawValue: UUID()),
			restoration: .init(title: "(3) Inbox", url: URL(string: "https://www.example.com/inbox")!)
		)
		var overrides = UnreadBadgeOverrides()
		overrides.sites["example.com"] = site
		overrides.tabs[tabID] = tab
		expectNoDifference(overrides.resolved(page, profile: profile, browser: browser), expected)
		expectNoDifference(
			overrides.inherited(by: page, profile: profile, browser: browser),
			UnreadBadgeVisibility.resolve(tab: nil, site: site, profile: profile, browser: browser)
		)
	}

	// MARK: - Saving

	@Test
	internal func hiddenSitesSavedBeforeTheLevelsAreHiddenAtTheSiteLevel() async throws {
		let encoded = try JSONEncoder().encode(BrowserPreferences())
		var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		object.removeValue(forKey: "showsUnreadBadges")
		object.removeValue(forKey: "unreadBadgeSites")
		object.removeValue(forKey: "unreadBadgeTabs")
		object["hiddenUnreadBadgeSites"] = ["capturecontext.dev", "example.com"]
		let older = try JSONSerialization.data(withJSONObject: object)

		let preferences = try JSONDecoder().decode(BrowserPreferences.self, from: older)
		#expect(preferences.showsUnreadBadges)
		expectNoDifference(preferences.unreadBadgeSites, ["capturecontext.dev": .hide, "example.com": .hide])
		expectNoDifference(preferences.unreadBadgeTabs, [:])

		// Saved again, they're the site level only: the old key isn't written back.
		let saved = try JSONEncoder().encode(preferences)
		let savedObject = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
		#expect(savedObject["hiddenUnreadBadgeSites"] == nil)
		expectNoDifference(try JSONDecoder().decode(BrowserPreferences.self, from: saved).unreadBadgeSites, preferences.unreadBadgeSites)
	}

	@Test
	internal func theSiteLevelWinsOverLeftoverHiddenSites() async throws {
		var preferences = BrowserPreferences()
		preferences.unreadBadgeSites = ["example.com": .show]
		let encoded = try JSONEncoder().encode(preferences)
		var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		object["hiddenUnreadBadgeSites"] = ["example.com"]

		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONSerialization.data(withJSONObject: object))
		expectNoDifference(decoded.unreadBadgeSites, ["example.com": .show])
	}

	@Test
	internal func everyLevelRoundTrips() async throws {
		let tabID = Tab.ID(rawValue: UUID())
		var preferences = BrowserPreferences()
		preferences.showsUnreadBadges = false
		preferences.unreadBadgeOverrides = .init(sites: ["example.com": .show], tabs: [tabID: .hide])
		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(preferences))
		#expect(!decoded.showsUnreadBadges)
		expectNoDifference(decoded.unreadBadgeOverrides, preferences.unreadBadgeOverrides)

		let profile = Profile(id: .init(rawValue: UUID()), name: "Work", unreadBadges: .hide)
		expectNoDifference(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile)).unreadBadges, .hide)

		// A profile saved before the levels inherits.
		let older = Data(#"{"id":"\#(UUID().uuidString)","name":"Home","favorites":[]}"#.utf8)
		#expect(try JSONDecoder().decode(Profile.self, from: older).unreadBadges == nil)
	}

	@Test
	internal func aProfileChoosesOrInherits() async throws {
		let profileID = Profile.ID(rawValue: UUID())
		var organization = BrowserOrganization(profiles: [.init(id: profileID, name: "Work")], spaces: [])
		organization = try organization.applying(.setProfileUnreadBadges(profileID, .hide), uuid: { UUID() })
		expectNoDifference(organization.profiles[id: profileID]?.unreadBadges, .hide)
		organization = try organization.applying(.setProfileUnreadBadges(profileID, nil), uuid: { UUID() })
		#expect(organization.profiles[id: profileID]?.unreadBadges == nil)
	}

	@Test
	internal func agentsReadAndChangeTheBrowserDefault() async throws {
		var preferences = BrowserPreferences()
		expectNoDifference(AutomationPreferenceKey.showsUnreadBadges.value(in: preferences), .bool(true))
		preferences = try preferences.applying([.init(key: .showsUnreadBadges, value: .bool(false))])
		#expect(!preferences.showsUnreadBadges)
		expectNoDifference(AutomationPreferenceKey.showsUnreadBadges.value(in: preferences), .bool(false))
	}
}
