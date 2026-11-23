import BrowserCore
import CustomDump
import Foundation
import Testing

@testable import AppFeature

/// The arx:// link alert says what the link does in one whole sentence per case, instead of
/// fragments joined in code (DEV-1291).
@MainActor
internal struct ArxLinkDescriptionTests {
	@Test
	internal func eachCommandIsOneSentence() throws {
		let page: URL = try #require(URL(string: "https://example.com/a"))

		expectNoDifference(
			[
				BrowserWindow.describe(.open(page, space: nil, profile: nil)),
				BrowserWindow.describe(.open(page, space: "Work", profile: "Personal")),
				BrowserWindow.describe(.open(page, space: nil, profile: "Personal")),
				BrowserWindow.describe(.littleArx(nil, space: nil)),
				BrowserWindow.describe(.littleArx(page, space: nil)),
				BrowserWindow.describe(.littleArx(nil, space: "Work")),
				BrowserWindow.describe(.littleArx(page, space: "Work")),
				BrowserWindow.describe(.switchSpace("Work")),
			],
			[
				"Open https://example.com/a.",
				"Open https://example.com/a in the space “Work”.",
				"Open https://example.com/a in the profile “Personal”.",
				"Open Little Arx.",
				"Open https://example.com/a in Little Arx.",
				"Open Little Arx in the space “Work”.",
				"Open https://example.com/a in Little Arx, in the space “Work”.",
				"Switch to the space “Work”.",
			]
		)
	}
}
