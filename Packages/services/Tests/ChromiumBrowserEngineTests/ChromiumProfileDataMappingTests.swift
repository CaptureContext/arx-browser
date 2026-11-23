import BrowserCore
import ChromiumEngine
import Foundation
import Testing

@testable import ChromiumBrowserEngine

/// How Settings sees native counts, download settings and failures (DEV-647).
@Suite
@MainActor
internal struct ChromiumProfileDataMappingTests {
	@Test
	internal func countsMapFromNative() {
		let counts = ChromiumBrowserEngine.browsingDataCounts(.init(
			cookies: .init(sites: 4),
			cache: .init(bytes: 1_048_576, upperLimit: true),
			autofill: .init(entries: 7, addresses: 1, cards: 2)
		))
		#expect(counts == .init(
			cookieSites: 4,
			cacheBytes: 1_048_576,
			cacheIsUpperBound: true,
			autofill: .init(entries: 7, addresses: 1, cards: 2)
		))
	}

	@Test
	internal func kindsKeepTheirNamesAcrossTheBoundary() {
		#expect(Set(BrowsingDataKind.allCases.map(\.rawValue)) == Set(ChromiumBrowsingDataKind.allCases.map(\.rawValue)))
		#expect(ChromiumBrowserEngine.chromiumKinds([.history, .siteSettings]) == [.history, .siteSettings])
	}

	@Test
	internal func downloadSettingsMapToFolders() {
		let settings = ChromiumBrowserEngine.downloadSettings(.init(
			directory: "/Users/a/My Files",
			ask: true,
			defaultDirectory: "/Users/a/Downloads",
			managed: true
		))
		#expect(settings.directory.path(percentEncoded: false).hasPrefix("/Users/a/My Files"))
		#expect(settings.asksWhereToSave)
		#expect(settings.defaultDirectory.lastPathComponent == "Downloads")
		#expect(settings.isManaged)
	}

	@Test(arguments: [
		(ChromiumProfileDataFailure.unavailable, ProfileDataFailure.unavailable),
		(.invalid(reason: "directory"), .invalid),
		(.busy, .busy),
		(.managed, .managed),
		(.failed, .failed),
	])
	internal func failuresMapFromNative(
		native: ChromiumProfileDataFailure,
		failure: ProfileDataFailure
	) {
		#expect(ChromiumBrowserEngine.profileDataFailure(native) == failure)
	}
}
