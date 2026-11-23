import CustomDump
import Foundation
import Testing
@testable import BrowserCore

/// DEV-884: content blocking off for one site, as the site menu reads and changes it.
internal struct ContentBlockingSiteTests {
	@Test
	internal func blockingIsOnUnlessARuleCoversTheSite() {
		let settings = SiteSettings(
			contentBlockingIsAvailable: true,
			contentBlockingOff: ["https://news.example", "[*.]shop.example"]
		)

		#expect(!settings.blocksContent(on: "https://news.example"))
		#expect(settings.blocksContent(on: "http://news.example"))
		#expect(!settings.blocksContent(on: "https://cart.shop.example"))
		#expect(settings.blocksContent(on: "https://other.example"))
		// An address that isn't an origin keeps blocking on.
		#expect(settings.blocksContent(on: "not a url"))
	}

	@Test
	internal func rulesCoveringASiteIncludeWiderOnes() {
		let settings = SiteSettings(
			contentBlockingIsAvailable: true,
			contentBlockingOff: ["https://cart.shop.example", "[*.]shop.example", "https://news.example"]
		)
		expectNoDifference(
			settings.contentBlockingRules(covering: "https://cart.shop.example"),
			["[*.]shop.example", "https://cart.shop.example"]
		)
		expectNoDifference(settings.contentBlockingRules(covering: "https://other.example"), [])
	}

	@Test(arguments: [
		("https://news.example", true),
		("http://localhost:8080", true),
		("[*.]shop.example", true),
		("https://[*.]shop.example:8443", false),
		("[*.]shop.example:*", false),
		("[*.]", false),
		("news.example", false),
	])
	internal func onlyRulesTheEngineAppliesAsListedCount(_ rule: String, _ applies: Bool) {
		#expect(SiteSettings.isContentBlockingRule(rule) == applies)
	}

	@Test
	internal func aManagedRuleKeepsBlockingOn() {
		let settings = SiteSettings(
			contentBlockingIsAvailable: true,
			contentBlockingOff: ["https://news.example"],
			contentBlockingManaged: ["[*.]news.example"]
		)
		#expect(settings.blocksContent(on: "https://news.example"))
		#expect(settings.contentBlockingIsManaged(on: "https://news.example"))
		#expect(!settings.contentBlockingIsManaged(on: "https://other.example"))
	}

	@Test
	internal func aMoreSpecificManagedAllowWins() {
		let settings = SiteSettings(
			contentBlockingIsAvailable: true,
			contentBlockingOff: ["https://intranet.corp.example"],
			contentBlockingManaged: ["[*.]corp.example"],
			contentBlockingManagedOff: ["https://intranet.corp.example"]
		)
		#expect(!settings.blocksContent(on: "https://intranet.corp.example"))
		#expect(settings.blocksContent(on: "https://mail.corp.example"))
		#expect(settings.contentBlockingIsManaged(on: "https://intranet.corp.example"))
	}

	@Test
	internal func theEditHoldsOnlyOnceTheSiteMatches() {
		let off = SiteSettings(contentBlockingIsAvailable: true, contentBlockingOff: ["https://news.example"])
		#expect(off.holds(.setContentBlocking(origin: "https://news.example", isOn: false)))
		#expect(!off.holds(.setContentBlocking(origin: "https://news.example", isOn: true)))
		#expect(SiteSettings().holds(.setContentBlocking(origin: "https://news.example", isOn: true)))
	}

	@Test(arguments: ["", "news.example", "https://news.example/path", "javascript:alert(1)"])
	internal func editsNameAnExactOrigin(_ origin: String) {
		#expect(throws: SiteSettingsFailure.invalid) {
			try SiteSettingsEdit.setContentBlocking(origin: origin, isOn: false).validate()
		}
	}

	@Test
	internal func theListIsSorted() {
		expectNoDifference(
			SiteSettings(contentBlockingOff: ["https://b.example", "https://a.example"]).contentBlockingOff,
			["https://a.example", "https://b.example"]
		)
	}

	@Test
	internal func preferencesDefaultToBlockingWithoutCookieListsAndOlderSavesKeepThat() throws {
		#expect(BrowserPreferences().blocksContent)
		#expect(!BrowserPreferences().blocksCookieBanners)
		let data = try JSONEncoder().encode(BrowserPreferences())
		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		#expect(values.removeValue(forKey: "blocksContent") != nil)
		#expect(values.removeValue(forKey: "blocksCookieBanners") != nil)
		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: values)
		)
		#expect(decoded.blocksContent && !decoded.blocksCookieBanners)

		var changed = BrowserPreferences()
		changed.blocksContent = false
		changed.blocksCookieBanners = true
		let saved = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(changed))
		#expect(!saved.general.blocksContent && saved.general.blocksCookieBanners)
	}
}
