import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-802: the Previews options for folders, mail and recent pages. DEV-730: page details and
/// Full previews. DEV-804: Live Calendar and its flag.
internal struct HoverPreviewSourcesTests {
	@Test
	internal func everySourceButFullPreviewsStartsOn() {
		expectNoDifference(
			BrowserPreferences().hoverPreviewSources,
			.init(folders: true, mail: true, recentPages: true, pageDetails: true, fullPages: false)
		)
		expectNoDifference(BrowserPreferences().general.hoverPreviewSources, .init())
	}

	@Test
	internal func preferencesSavedBeforeTheOptionsGetTheDefaults() throws {
		var preferences = BrowserPreferences()
		preferences.hapticsEnabled = false
		let data = try JSONEncoder().encode(preferences)
		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		#expect(values.removeValue(forKey: "hoverPreviewSources") != nil)

		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: values)
		)
		expectNoDifference(decoded.hoverPreviewSources, .init())
		#expect(!decoded.hapticsEnabled)
	}

	@Test
	internal func missingOrDamagedOptionsKeepTheirDefaultAndTheRestSurvive() throws {
		let decoded = try JSONDecoder().decode(
			HoverPreviewSources.self,
			from: Data(#"{"folders": false, "mail": "yes", "calendars": true}"#.utf8)
		)
		expectNoDifference(decoded, .init(folders: false, mail: true, recentPages: true))
	}

	@Test
	internal func optionsSavedBeforePageDetailsAndFullPreviewsGetTheirDefaults() throws {
		let decoded = try JSONDecoder().decode(
			HoverPreviewSources.self,
			from: Data(#"{"folders": true, "mail": false, "recentPages": true}"#.utf8)
		)
		expectNoDifference(decoded, .init(folders: true, mail: false, recentPages: true, pageDetails: true, fullPages: false))

		let damaged = try JSONDecoder().decode(
			HoverPreviewSources.self,
			from: Data(#"{"pageDetails": 1, "fullPages": "on"}"#.utf8)
		)
		expectNoDifference(damaged, .init())
	}

	@Test
	internal func changedOptionsRoundTripThroughGeneral() throws {
		var preferences = BrowserPreferences()
		var general = preferences.general
		general.hoverPreviewSources = .init(folders: false, mail: false, recentPages: true, pageDetails: false, fullPages: true)
		preferences.general = general

		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(preferences))
		expectNoDifference(
			decoded.hoverPreviewSources,
			.init(folders: false, mail: false, recentPages: true, pageDetails: false, fullPages: true)
		)
		expectNoDifference(decoded, preferences)
	}

	// MARK: - Shift + hover (DEV-1029)

	@Test
	internal func optionsSavedBeforeShiftHoverKeepItOff() throws {
		let decoded = try JSONDecoder().decode(
			HoverPreviewSources.self,
			from: Data(#"{"folders": true, "pageDetails": true, "fullPages": true}"#.utf8)
		)
		#expect(!decoded.shiftLoadsPages)
		#expect(decoded.fullPages)

		let damaged = try JSONDecoder().decode(HoverPreviewSources.self, from: Data(#"{"shiftLoadsPages": "yes"}"#.utf8))
		#expect(!damaged.shiftLoadsPages)
	}

	@Test
	internal func shiftHoverRoundTripsApartFromFullPreviews() throws {
		let sources: HoverPreviewSources = .init(fullPages: false, shiftLoadsPages: true)
		let decoded = try JSONDecoder().decode(HoverPreviewSources.self, from: JSONEncoder().encode(sources))
		expectNoDifference(decoded, sources)
		#expect(!decoded.fullPages)
	}

	// MARK: - Live Calendar (DEV-804)

	@Test
	internal func optionsSavedBeforeLiveCalendarGetItsDefaults() throws {
		let decoded = try JSONDecoder().decode(
			HoverPreviewSources.self,
			from: Data(#"{"folders": true, "mail": true, "recentPages": false, "pageDetails": true, "fullPages": true}"#.utf8)
		)
		expectNoDifference(decoded.calendars, true)
		expectNoDifference(decoded.disabledCalendars, [])
		expectNoDifference(decoded.recentPages, false)
	}

	@Test
	internal func damagedCalendarOptionsKeepTheirDefaults() throws {
		let decoded = try JSONDecoder().decode(
			HoverPreviewSources.self,
			from: Data(#"{"calendars": "off", "disabledCalendars": ["not a UUID"]}"#.utf8)
		)
		expectNoDifference(decoded, .init())
	}

	@Test
	internal func disabledCalendarsRoundTrip() throws {
		let sources: HoverPreviewSources = .init(calendars: true, disabledCalendars: [UUID(), UUID()])
		let decoded = try JSONDecoder().decode(HoverPreviewSources.self, from: JSONEncoder().encode(sources))
		expectNoDifference(decoded, sources)
	}

	/// A value that's neither on nor off leaves it at its default, on (DEV-1143).
	@Test(arguments: [
		("1", true), ("true", true), ("YES", true),
		("0", false), ("no", false), ("", true), ("on", true), ("maybe", true),
	])
	internal func theFeatureFlagReadsTheEnvironment(
		value: String,
		isEnabled: Bool
	) throws {
		let defaults = try #require(UserDefaults(suiteName: "LiveCalendarFlag-\(UUID())"))
		#expect(LiveCalendar.isEnabled(environment: [LiveCalendar.featureFlag: value], defaults: defaults) == isEnabled)
	}

	@Test
	internal func theFeatureFlagFallsBackToDefaultsAndIsOnWithoutEither() throws {
		let suite = "LiveCalendarFlag-\(UUID())"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		// On by default (DEV-1143).
		#expect(LiveCalendar.isEnabled(environment: [:], defaults: defaults))
		defaults.set("0", forKey: LiveCalendar.featureFlag)
		#expect(!LiveCalendar.isEnabled(environment: [:], defaults: defaults))
		// The environment wins over defaults.
		#expect(LiveCalendar.isEnabled(environment: [LiveCalendar.featureFlag: "1"], defaults: defaults))
	}

	// MARK: - DEV-1142

	@Test
	internal func theUnloadedPageChoiceStartsWithTheSitesPicture() {
		#expect(HoverPreviewSources().unloadedPages == .sitePicture)
	}

	@Test
	internal func theUnloadedPageChoiceReadsAndWritesTheSavedSwitches() {
		var sources = HoverPreviewSources(folders: false, mail: false)
		for choice in UnloadedPagePreview.allCases {
			sources.unloadedPages = choice
			#expect(sources.unloadedPages == choice)
			// The other sources stay as they were.
			#expect(!sources.folders && !sources.mail && sources.recentPages)
		}

		sources.unloadedPages = .loadPage
		#expect(sources.pageDetails && sources.fullPages)
		sources.unloadedPages = .savedPicture
		#expect(!sources.pageDetails && !sources.fullPages)

		// Full previews switched on with the site's picture off, before the choice: still loads.
		#expect(HoverPreviewSources(pageDetails: false, fullPages: true).unloadedPages == .loadPage)
	}

	@Test
	internal func theSitePreviewImagesFeatureFlagIsOnUnlessTurnedOff() throws {
		let suite = "SitePreviewImagesFeatureFlag-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let name = SitePreviewImagesFeatureFlag.name

		#expect(name == "ARX_SITE_PREVIEW_IMAGES")
		#expect(SitePreviewImagesFeatureFlag.isOn(environment: [:], defaults: defaults))
		#expect(!SitePreviewImagesFeatureFlag.isOn(environment: [name: "0"], defaults: defaults))
		#expect(SitePreviewImagesFeatureFlag.isOn(environment: [name: "maybe"], defaults: defaults))

		defaults.set("off", forKey: name)
		#expect(!SitePreviewImagesFeatureFlag.isOn(environment: [:], defaults: defaults))
		// The environment wins over user defaults.
		#expect(SitePreviewImagesFeatureFlag.isOn(environment: [name: "yes"], defaults: defaults))
	}

	/// DEV-1029: agents read and change Shift + hover through `browser_settings`, like the
	/// other Previews switches.
	@Test
	internal func shiftHoverLoadsPagesIsAnAutomationSwitch() throws {
		let key = AutomationPreferenceKey.shiftHoverLoadsPages
		#expect(key.schema == .boolean)
		expectNoDifference(key.value(in: BrowserPreferences()), .bool(false))

		let on = try BrowserPreferences().applying([.init(key: key, value: .bool(true))])
		#expect(on.hoverPreviewSources.shiftLoadsPages)
		expectNoDifference(key.value(in: on), .bool(true))
		#expect(!on.hoverPreviewSources.fullPages)
	}
}
