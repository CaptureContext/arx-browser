import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-1144: which sites stay in Chromium for FairPlay, and the feature flag that says so.
internal struct FairPlayInChromiumTests {
	@Test
	internal func theFeatureFlagIsOnUnlessTurnedOff() async throws {
		let defaults = try #require(UserDefaults(suiteName: "FairPlayInChromiumTests-\(UUID())"))
		#expect(FairPlayInChromium.isOn(environment: [:], defaults: defaults))
		for off in ["0", "false", "no", "off", "OFF"] {
			#expect(!FairPlayInChromium.isOn(environment: [FairPlayInChromium.featureFlag: off], defaults: defaults))
		}
		#expect(FairPlayInChromium.isOn(environment: [FairPlayInChromium.featureFlag: "on"], defaults: defaults))
		defaults.set("off", forKey: FairPlayInChromium.featureFlag)
		#expect(!FairPlayInChromium.isOn(environment: [:], defaults: defaults))
		// The environment wins over defaults.
		#expect(FairPlayInChromium.isOn(environment: [FairPlayInChromium.featureFlag: "1"], defaults: defaults))
	}

	@Test
	internal func onlyTheExactSecureOriginIsBridged() async throws {
		#expect(FairPlayInChromium.origin(of: URL(string: "https://open.spotify.com/track/1")!) == "https://open.spotify.com")
		#expect(FairPlayInChromium.origin(of: URL(string: "https://OPEN.spotify.com:443/")!) == "https://open.spotify.com")
		#expect(FairPlayInChromium.origin(of: URL(string: "http://open.spotify.com/")!) == nil)
		#expect(FairPlayInChromium.origin(of: URL(string: "https://open.spotify.com:8443/")!) == nil)
		#expect(FairPlayInChromium.origin(of: URL(string: "https://www.spotify.com/")!) == nil)
		#expect(FairPlayInChromium.origin(of: URL(string: "https://www.netflix.com/")!) == nil)
	}

	@Test
	internal func bridgedSitesLeaveTheWebKitList() async throws {
		let preferences = WebKitPagePreferences()
		#expect(preferences.opensInWebKit(URL(string: "https://open.spotify.com/")!))

		let kept = preferences.keepingInChromium(FairPlayInChromium.origins)
		#expect(!kept.opensInWebKit(URL(string: "https://open.spotify.com/")!))
		#expect(kept.opensInWebKit(URL(string: "https://www.netflix.com/")!))
		expectNoDifference(preferences.keepingInChromium([]), preferences)

		// Only the exact origin: other pages a listed domain covers still open in WebKit.
		var custom = WebKitPagePreferences(sites: ["spotify.com"])
		custom = custom.keepingInChromium(FairPlayInChromium.origins)
		#expect(!custom.opensInWebKit(URL(string: "https://open.spotify.com/album/1")!))
		#expect(custom.opensInWebKit(URL(string: "https://accounts.spotify.com/")!))
		#expect(custom.opensInWebKit(URL(string: "https://open.spotify.com:8443/")!))
		// Never saved.
		let saved = try JSONDecoder().decode(WebKitPagePreferences.self, from: JSONEncoder().encode(custom))
		#expect(saved.chromiumOrigins.isEmpty)
	}

	@Test
	internal func protectedMediaPrefersFairPlayInTheTab() async throws {
		var preferences = WebKitPagePreferences()
		#expect(preferences.protectedMedia == .fairPlayInTab)
		#expect(preferences.answersWidevine)
		expectNoDifference(preferences.bridgedOrigins(FairPlayInChromium.origins), FairPlayInChromium.origins)
		preferences.protectedMedia = .webKitPage
		#expect(preferences.bridgedOrigins(FairPlayInChromium.origins).isEmpty)
	}

	@Test
	internal func olderPreferencesReadWithTheDefaults() async throws {
		let older = Data(#"{"isEnabled":true,"sites":["netflix.com"],"declinedSites":[]}"#.utf8)
		let preferences = try JSONDecoder().decode(WebKitPagePreferences.self, from: older)
		#expect(preferences.protectedMedia == .fairPlayInTab)
		#expect(preferences.answersWidevine)
		var changed = preferences
		changed.protectedMedia = .webKitPage
		changed.answersWidevine = false
		let decoded = try JSONDecoder().decode(WebKitPagePreferences.self, from: JSONEncoder().encode(changed))
		expectNoDifference(decoded, changed)
	}

	@Test
	internal func agentsReadAndChangeBothSettings() async throws {
		let preferences = BrowserPreferences()
		#expect(AutomationPreferenceKey.protectedMediaPlayback.value(in: preferences) == .string("fairPlayInTab"))
		#expect(AutomationPreferenceKey.widevineAnswer.value(in: preferences) == .bool(true))
		let changed = try preferences.applying([
			.init(key: .protectedMediaPlayback, value: .string("webKitPage")),
			.init(key: .widevineAnswer, value: .bool(false)),
		])
		#expect(changed.webKitPages.protectedMedia == .webKitPage)
		#expect(!changed.webKitPages.answersWidevine)
		#expect(throws: (any Error).self) {
			try preferences.applying([.init(key: .protectedMediaPlayback, value: .string("widevine"))])
		}
	}

	@Test
	internal func theEngineReadsTheWidevineAnswerAsOnOrOff() async throws {
		#expect(WidevineAnswer.featureFlag == "ARX_WIDEVINE_ANSWER")
		#expect(WidevineAnswer.defaultsValue(true) == "on")
		#expect(WidevineAnswer.defaultsValue(false) == "off")
	}
}
