import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-646: the app-wide and per-profile Settings controls, their defaults and older saves.
internal struct SettledSettingsTests {
	@Test
	internal func defaultsMatchTheSettledChoices() {
		let preferences = BrowserPreferences()
		#expect(preferences.restoresWindowsAtStartup)
		#expect(preferences.hapticsEnabled)
		#expect(!preferences.soundsEnabled)
		#expect(preferences.hoverPreviewsEnabled)
		#expect(preferences.tabsLastViewed.isEmpty)

		let profile = Profile(id: .init(rawValue: UUID()), name: "Work")
		#expect(profile.tabArchiveInterval == nil)
		expectNoDifference(profile.effectiveTabArchiveInterval, .sixHours)
		#expect(profile.suggestsRemotely)
		#expect(!profile.showsWholeURL)
	}

	@Test
	internal func preferencesSavedBeforeTheseSettingsKeepTheirValuesAndGetDefaults() throws {
		var preferences = BrowserPreferences()
		preferences.warnsBeforeQuitting = false
		let data = try JSONEncoder().encode(preferences)
		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		for key in ["restoresWindowsAtStartup", "hapticsEnabled", "soundsEnabled", "hoverPreviewsEnabled", "tabsLastViewed"] {
			#expect(values.removeValue(forKey: key) != nil, "\(key) is saved")
		}

		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: values)
		)
		#expect(decoded.restoresWindowsAtStartup)
		#expect(decoded.hapticsEnabled)
		#expect(!decoded.soundsEnabled)
		#expect(decoded.hoverPreviewsEnabled)
		#expect(decoded.tabsLastViewed.isEmpty)
		#expect(!decoded.warnsBeforeQuitting)
	}

	@Test
	internal func changedPreferencesRoundTrip() throws {
		let tab = Tab.ID(rawValue: UUID())
		let viewed = Date(timeIntervalSince1970: 1_000)
		var preferences = BrowserPreferences()
		preferences.restoresWindowsAtStartup = false
		preferences.hapticsEnabled = false
		preferences.soundsEnabled = true
		preferences.hoverPreviewsEnabled = false
		preferences.tabsLastViewed = [tab: viewed]

		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(preferences))
		expectNoDifference(decoded, preferences)
		expectNoDifference(decoded.general.restoresWindowsAtStartup, false)
		expectNoDifference(decoded.general.hapticsEnabled, false)
		expectNoDifference(decoded.general.soundsEnabled, true)
		expectNoDifference(decoded.general.hoverPreviewsEnabled, false)
	}

	@Test
	internal func damagedTabActivityDoesNotLoseOtherPreferences() throws {
		var preferences = BrowserPreferences()
		preferences.hapticsEnabled = false
		let data = try JSONEncoder().encode(preferences)
		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		values["tabsLastViewed"] = "not a list"

		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: values)
		)
		#expect(decoded.tabsLastViewed.isEmpty)
		#expect(!decoded.hapticsEnabled)
	}

	@Test
	internal func profilesSavedBeforeTheseSettingsUseTheDefaults() throws {
		let id = UUID()
		let data = Data(#"{"id": "\#(id.uuidString)", "name": "Work", "favorites": [], "searchEngine": "duckDuckGo"}"#.utf8)

		let profile = try JSONDecoder().decode(Profile.self, from: data)
		expectNoDifference(profile.name, "Work")
		#expect(profile.tabArchiveInterval == nil)
		expectNoDifference(profile.effectiveTabArchiveInterval, .sixHours)
		#expect(profile.suggestsRemotely)
		#expect(!profile.showsWholeURL)
	}

	@Test
	internal func settingsChangeOnlyTheirProfile() throws {
		let work = Profile.ID(rawValue: UUID())
		let personal = Profile.ID(rawValue: UUID())
		let organization = BrowserOrganization(profiles: [
			.init(id: work, name: "Work"),
			.init(id: personal, name: "Personal"),
		])

		var changed = try organization.applying(.setTabArchiveInterval(work, .week), uuid: UUID.init)
		changed = try changed.applying(.setRemoteSearchSuggestions(work, false), uuid: UUID.init)
		changed = try changed.applying(.setShowsFullURL(work, true), uuid: UUID.init)
		expectNoDifference(changed.profiles[id: work]?.tabArchiveInterval, .week)
		#expect(changed.profiles[id: work]?.suggestsRemotely == false)
		#expect(changed.profiles[id: work]?.showsWholeURL == true)
		expectNoDifference(changed.profiles[id: personal], organization.profiles[id: personal])

		let decoded = try JSONDecoder().decode(BrowserOrganization.self, from: JSONEncoder().encode(changed))
		expectNoDifference(decoded.profiles, changed.profiles)

		let off = try changed.applying(.setTabArchiveInterval(work, .never), uuid: UUID.init)
		expectNoDifference(off.profiles[id: work]?.effectiveTabArchiveInterval, .never)
		let reset = try off.applying(.setTabArchiveInterval(work, nil), uuid: UUID.init)
		#expect(reset.profiles[id: work]?.tabArchiveInterval == nil)
		expectNoDifference(reset.profiles[id: work]?.effectiveTabArchiveInterval, .sixHours)
		#expect(throws: OrganizationChangeError.missingItem) {
			try organization.applying(.setShowsFullURL(.init(rawValue: UUID()), true), uuid: UUID.init)
		}
	}

	/// Four choices, after the six-hour default, then Never (DEV-1326).
	@Test
	internal func archiveIntervalsMatchArcAfterTheDefault() {
		let hours: [TimeInterval?] = [6, 12, 24, 7 * 24, 30 * 24].map { $0 * 3_600 } + [nil]
		expectNoDifference(TabArchiveInterval.allCases.map(\.duration), hours)
		expectNoDifference(TabArchiveInterval.default, .sixHours)
	}

	/// DEV-1326: a new profile, one saved before the default with no value, and one that chose
	/// Never, as JSON and as the stored raw value.
	@Test
	internal func archiveDefaultTellsNoChoiceFromNever() throws {
		let id = UUID()
		let decode = { (interval: String?) throws -> Profile in
			let field = interval.map { #", "tabArchiveInterval": "\#($0)""# } ?? ""
			let json = #"{"id": "\#(id.uuidString)", "name": "Work", "favorites": []\#(field)}"#
			return try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
		}

		let new = Profile(id: .init(rawValue: id), name: "Work")
		expectNoDifference(new.effectiveTabArchiveInterval.duration, 6 * 3_600)

		let unchosen = try decode(nil)
		#expect(unchosen.tabArchiveInterval == nil)
		expectNoDifference(unchosen.effectiveTabArchiveInterval, .sixHours)

		let never = try decode("never")
		expectNoDifference(never.tabArchiveInterval, .never)
		#expect(never.effectiveTabArchiveInterval.duration == nil)
		expectNoDifference(
			try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(never)),
			never
		)

		// A value from a newer build reads as no choice rather than failing the profile.
		let unknown = try decode("fortnight")
		#expect(unknown.tabArchiveInterval == nil)
		expectNoDifference(unknown.effectiveTabArchiveInterval, .sixHours)
	}
}
