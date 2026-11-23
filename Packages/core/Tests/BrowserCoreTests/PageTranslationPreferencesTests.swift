import BrowserCore
import Foundation
import Testing

internal struct PageTranslationPreferencesTests {
	@Test
	internal func neverAndAlwaysArePerProfile() async throws {
		var preferences = TranslationPreferences()
		let work = Profile.ID(rawValue: UUID())
		let home = Profile.ID(rawValue: UUID())
		preferences[work].setNeverTranslates(true, for: URL(string: "https://www.lemonde.fr/a")!)
		preferences[work].setAlwaysTranslates(true, language: "fr")

		#expect(preferences[work].neverTranslates(URL(string: "https://lemonde.fr/b")!))
		#expect(preferences[work].neverTranslates(URL(string: "https://news.lemonde.fr")!))
		#expect(!preferences[work].neverTranslates(URL(string: "https://example.fr")!))
		#expect(preferences[work].alwaysTranslates("fr"))
		#expect(!preferences[home].alwaysTranslates("fr"))
		#expect(!preferences[home].neverTranslates(URL(string: "https://lemonde.fr")!))

		preferences[work].setNeverTranslates(false, for: URL(string: "https://lemonde.fr")!)
		preferences[work].setAlwaysTranslates(false, language: "fr")
		#expect(preferences.profiles.isEmpty)
	}

	@Test
	internal func preferencesRoundTrip() async throws {
		var browser = BrowserPreferences()
		let profile = Profile.ID(rawValue: UUID())
		browser.translation[profile].setAlwaysTranslates(true, language: "de")
		let data = try JSONEncoder().encode(browser)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: data).translation == browser.translation)
		var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		old["translation"] = nil
		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONSerialization.data(withJSONObject: old))
		#expect(decoded.translation == .init())
	}

	@Test
	internal func providerQualityAndTargetDefaultAndRoundTrip() async throws {
		#expect(TranslationPreferences().provider == .apple)
		#expect(TranslationPreferences().quality == .automatic)
		#expect(TranslationPreferences().targetLanguage == nil)

		let chosen = TranslationPreferences(provider: .google, quality: .faster, targetLanguage: "de")
		let data = try JSONEncoder().encode(chosen)
		#expect(try JSONDecoder().decode(TranslationPreferences.self, from: data) == chosen)

		// A file from before DEV-996, or from a later Arx with a provider this one lacks.
		let old = try JSONDecoder().decode(TranslationPreferences.self, from: Data(#"{"profiles":[]}"#.utf8))
		#expect(old == .init())
		let unknown = try JSONDecoder().decode(
			TranslationPreferences.self,
			from: Data(#"{"profiles":[],"provider":"deepl","quality":"best"}"#.utf8)
		)
		#expect(unknown.provider == .apple)
		#expect(unknown.quality == .automatic)
	}

	@Test
	internal func privateChoicesAddToTheOpeners() async throws {
		let opener = ProfileTranslationPreferences(neverSites: ["lemonde.fr"], alwaysLanguages: ["de"])
		let own = ProfileTranslationPreferences(neverSites: ["lemonde.fr", "spiegel.de"], alwaysLanguages: [])
		let merged = opener.adding(own)
		#expect(merged.neverSites == ["lemonde.fr", "spiegel.de"])
		#expect(merged.alwaysLanguages == ["de"])
	}

	@Test
	internal func theFeatureFlagReadsTheEnvironmentThenDefaults() async throws {
		let defaults = try #require(UserDefaults(suiteName: "PageTranslationFeatureFlag-\(UUID().uuidString)"))

		// On by default (DEV-1143).
		#expect(PageTranslationFeatureFlag.isEnabled(environment: [:], defaults: defaults))
		#expect(!PageTranslationFeatureFlag.isEnabled(environment: ["ARX_TRANSLATE": "0"], defaults: defaults))
		defaults.set("no", forKey: "ARX_TRANSLATE")
		#expect(!PageTranslationFeatureFlag.isEnabled(environment: [:], defaults: defaults))
		#expect(PageTranslationFeatureFlag.isEnabled(environment: ["ARX_TRANSLATE": "on"], defaults: defaults))
	}
}
