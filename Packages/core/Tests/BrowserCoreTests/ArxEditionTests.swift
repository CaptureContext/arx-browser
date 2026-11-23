import BrowserCore
import Foundation
import Testing

internal struct ArxEditionTests {
	private static let home: URL = .init(filePath: "/Users/person", directoryHint: .isDirectory)

	@Test
	func theAppsBundleIdentifierNamesItsEdition() {
		#expect(ArxEdition.hosting(bundleIdentifier: "dev.capturecontext.arx.dev", executable: nil) == .development)
		#expect(ArxEdition.hosting(bundleIdentifier: "dev.capturecontext.arx", executable: nil) == .release)
	}

	@Test
	func aToolInsideTheAppTakesTheAppsEdition() {
		let executable: URL = .init(filePath: "/Users/person/Developer/Arx.app/Contents/Helpers/ArxMCP")
		var asked: [String] = []
		let edition: ArxEdition = .hosting(bundleIdentifier: nil, executable: executable) { app in
			asked.append(app.path)
			return "dev.capturecontext.arx.dev"
		}

		#expect(edition == .development)
		#expect(asked == ["/Users/person/Developer/Arx.app"])
	}

	@Test
	func anythingElseIsTheInstalledArx() {
		let copied: URL = .init(filePath: "/Users/person/.local/bin/arx")

		#expect(ArxEdition.hosting(bundleIdentifier: nil, executable: copied) { _ in nil } == .release)
		#expect(ArxEdition.hosting(bundleIdentifier: "com.apple.dt.xctest.tool", executable: nil) == .release)
		let other: URL = .init(filePath: "/Applications/Other.app/Contents/MacOS/Other")
		#expect(ArxEdition.hosting(bundleIdentifier: nil, executable: other) { _ in "com.example.other" } == .release)
	}

	@Test
	func eachEditionHasItsOwnFolders() {
		#expect(ArxEdition.release.applicationSupport(home: Self.home).path == "/Users/person/Library/Application Support/dev.capturecontext.arx")
		#expect(ArxEdition.development.applicationSupport(home: Self.home).path == "/Users/person/Library/Application Support/dev.capturecontext.arx.dev")
		#expect(ArxEdition.release.namedSupport(home: Self.home).path == "/Users/person/Library/Application Support/Arx")
		#expect(ArxEdition.development.namedSupport(home: Self.home).path == "/Users/person/Library/Application Support/Arx Dev")
		#expect(ArxEdition.development.isDevelopment)
		#expect(!ArxEdition.release.isDevelopment)
	}

	/// `make run-preview`: Debug built as Arx, with its own data folder and agents' folder, so it
	/// never opens the installed Arx's profiles.
	@Test
	func infoPlistCanNameItsOwnFolders() {
		let preview: ArxEdition = ArxEdition.release.naming(from: [
			ArxEdition.InfoKey.dataFolder: "dev.capturecontext.arx.preview",
			ArxEdition.InfoKey.supportName: "Arx Preview",
		])

		#expect(preview.bundleIdentifier == "dev.capturecontext.arx")
		#expect(preview.applicationSupport(home: Self.home).path == "/Users/person/Library/Application Support/dev.capturecontext.arx.preview")
		#expect(preview.namedSupport(home: Self.home).path == "/Users/person/Library/Application Support/Arx Preview")
		#expect(!preview.isDevelopment)
		#expect(preview != .release)
	}

	/// Every other build's Info.plist names its bundle identifier and name, or nothing.
	@Test
	func missingOrMatchingNamesKeepTheEditionsFolders() {
		#expect(ArxEdition.release.naming(from: nil) == .release)
		#expect(ArxEdition.development.naming(from: [ArxEdition.InfoKey.dataFolder: ""]) == .development)
		#expect(ArxEdition.release.naming(from: [
			ArxEdition.InfoKey.dataFolder: "dev.capturecontext.arx",
			ArxEdition.InfoKey.supportName: "Arx",
		]) == .release)
	}
}
