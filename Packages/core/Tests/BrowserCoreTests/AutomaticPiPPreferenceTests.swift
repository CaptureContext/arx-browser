import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct AutomaticPiPPreferenceTests {
	@Test
	internal func ordinarySitesDefaultOnAndExactOptOutsRoundTrip() async throws {
		var preferences = BrowserPreferences()
		let source = BrowserMediaSource(
			id: .init(
				tabID: .init(rawValue: UUID()),
				profileID: .init(rawValue: UUID()),
				generation: 1
			),
			revision: 1,
			title: "Video",
			site: .init(url: URL(string: "https://capturecontext.dev/path")!)
		)
		#expect(preferences.automaticPictureInPicture.permits(source))
		preferences.automaticPictureInPicture.setEnabled(false, for: source)
		#expect(!preferences.automaticPictureInPicture.permits(source))
		let data = try JSONEncoder().encode(preferences)
		expectNoDifference(try JSONDecoder().decode(BrowserPreferences.self, from: data), preferences)
		var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		old["automaticPictureInPicture"] = nil
		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: old)
		)
		#expect(decoded.automaticPictureInPicture.disabledSites.isEmpty)
		#expect(decoded.automaticPictureInPicture.permits(source))
		var legacy = old
		legacy["automaticPictureInPicture"] = ["enabledSites": [Any]()]
		let migrated = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: legacy)
		)
		#expect(migrated.automaticPictureInPicture.permits(source))
		var privateSource = source
		privateSource.isPrivate = true
		#expect(!decoded.automaticPictureInPicture.permits(privateSource))
	}
}
