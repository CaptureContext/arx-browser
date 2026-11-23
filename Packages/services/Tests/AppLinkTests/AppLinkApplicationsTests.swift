import AppLinkClient
import BrowserCore
import Foundation
import Testing

/// Reading apps for App Links' picker, and finding a chosen one again (DEV-862).
internal struct AppLinkApplicationsTests {
	private let directory: URL = FileManager.default.temporaryDirectory
		.appending(path: "arx-app-link-apps-\(UUID().uuidString)", directoryHint: .isDirectory)

	@discardableResult
	private func makeApp(
		_ name: String,
		in folder: URL,
		bundleID: String,
		schemes: [String]?
	) throws -> URL {
		let app = folder.appending(path: name + ".app", directoryHint: .isDirectory)
		let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
		var info: [String: Any] = [
			"CFBundleIdentifier": bundleID,
			"CFBundleName": name,
			"CFBundlePackageType": "APPL",
		]
		if let schemes {
			info["CFBundleURLTypes"] = [["CFBundleURLName": bundleID, "CFBundleURLSchemes": schemes]]
		}
		let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
		try data.write(to: contents.appending(path: "Info.plist"))
		return app
	}

	@Test
	internal func schemesSkipWebSchemesAndRepeats() {
		let types: [[String: Any]] = [
			["CFBundleURLSchemes": ["Claude", "https"]],
			["CFBundleURLSchemes": ["claude", "x-claude+beta.1", "not a scheme"]],
		]
		#expect(AppLinkApplicationChoice.schemes(fromURLTypes: types) == ["claude", "x-claude+beta.1"])
		#expect(AppLinkApplicationChoice.schemes(fromURLTypes: nil).isEmpty)
		#expect(AppLinkApplicationChoice.schemes(fromURLTypes: "junk").isEmpty)
	}

	@Test
	internal func choiceReadsNameIDSchemesAndABookmark() throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = try makeApp(
			"Fixture",
			in: directory,
			bundleID: "dev.arx.fixture",
			schemes: ["Fixture-One", "fixture-two"]
		)

		let choice = try #require(AppLinkApplications.choice(at: url))
		#expect(choice.application.name == "Fixture")
		#expect(choice.application.bundleID == "dev.arx.fixture")
		#expect(choice.application.path == url.standardizedFileURL.path(percentEncoded: false))
		#expect(choice.application.bookmark != nil)
		#expect(choice.schemes == ["fixture-one", "fixture-two"])
		#expect(AppLinkApplications.choice(at: directory) == nil)
	}

	@Test
	internal func installedListsAppsThatDeclareSchemesOneFolderDeep() throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		try makeApp("Zeta", in: directory, bundleID: "dev.arx.zeta", schemes: ["zeta"])
		try makeApp("Plain", in: directory, bundleID: "dev.arx.plain", schemes: nil)
		try makeApp("Web Only", in: directory, bundleID: "dev.arx.web", schemes: ["https"])
		try makeApp("Alpha", in: directory.appending(path: "Vendor"), bundleID: "dev.arx.alpha", schemes: ["alpha"])

		let installed = AppLinkApplications.installed(in: [directory], registeredSchemes: [], applicationsForScheme: { _ in [] })
		#expect(installed.map(\.application.name) == ["Alpha", "Zeta"])
		#expect(installed.map(\.schemes) == [["alpha"], ["zeta"]])

		// Listed without bookmarks; picking one makes it.
		let zeta = installed[1].application
		#expect(zeta.bookmark == nil)
		let picked = AppLinkApplications.bookmarked(zeta)
		#expect(picked.bookmark != nil)
		#expect(AppLinkApplications.bookmarked(picked) == picked)
	}

	@Test
	internal func locateFollowsAMoveAndNeverOpensAnotherApp() throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = try makeApp("Fixture", in: directory, bundleID: "dev.arx.fixture", schemes: ["fixture"])
		let application = try #require(AppLinkApplications.choice(at: url)).application
		#expect(AppLinkApplications.locate(application)?.standardizedFileURL == url.standardizedFileURL)

		// Moved: the bookmark finds it.
		let moved = directory.appending(path: "Elsewhere", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
		let destination = moved.appending(path: "Fixture Copy.app", directoryHint: .isDirectory)
		try FileManager.default.moveItem(at: url, to: destination)
		let found = try #require(AppLinkApplications.locate(application))
		#expect(found.resolvingSymlinksInPath().path(percentEncoded: false)
			== destination.resolvingSymlinksInPath().path(percentEncoded: false))

		// The move is kept: the refreshed app has the new path and a bookmark of its own.
		let refreshed = try #require(AppLinkApplications.refreshed(application, at: found))
		#expect(refreshed.path == found.standardizedFileURL.path(percentEncoded: false))
		#expect(refreshed.bookmark != nil)
		#expect(refreshed.bundleID == application.bundleID)
		#expect(AppLinkApplications.refreshed(application, at: url) == nil)

		// The same app back at the chosen path wins: bookmarks resolve by path first, which is
		// what keeps an app found after an update replaces its bundle in place.
		let copy = try makeApp("Fixture", in: directory, bundleID: "dev.arx.fixture", schemes: ["fixture"])
		#expect(AppLinkApplications.locate(application)?.standardizedFileURL == copy.standardizedFileURL)
		try FileManager.default.removeItem(at: copy)

		// Another app at the old path isn't it.
		try FileManager.default.removeItem(at: destination)
		try makeApp("Fixture", in: directory, bundleID: "dev.arx.other", schemes: ["fixture"])
		#expect(AppLinkApplications.locate(application) == nil)

		// Gone.
		try FileManager.default.removeItem(at: url)
		#expect(AppLinkApplications.locate(application) == nil)
		var withoutBookmark = application
		withoutBookmark.bookmark = nil
		#expect(AppLinkApplications.locate(withoutBookmark) == nil)
	}

	/// Linear registers `linear` with Launch Services while it runs and declares no scheme in
	/// its `Info.plist`, so a list read from `CFBundleURLTypes` alone left it out (DEV-1259).
	@Test
	internal func installedListsAppsLaunchServicesRegistersForAScheme() throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let linear = try makeApp("Linear", in: directory, bundleID: "com.linear", schemes: nil)
		let zeta = try makeApp("Zeta", in: directory, bundleID: "dev.arx.zeta", schemes: ["zeta"])
		let elsewhere = directory.appending(path: "Elsewhere/Deeper", directoryHint: .isDirectory)
		let tool = try makeApp("Tool", in: elsewhere, bundleID: "dev.arx.tool", schemes: nil)
		try makeApp("Plain", in: directory, bundleID: "dev.arx.plain", schemes: nil)

		let registered: [String: [URL]] = ["linear": [linear], "zeta": [zeta], "tool": [tool], "zeta-extra": [zeta]]
		let installed = AppLinkApplications.installed(
			in: [directory],
			registeredSchemes: ["linear", "https", "zeta", "tool", "zeta-extra", "missing"],
			applicationsForScheme: { registered[$0] ?? [] }
		)
		#expect(installed.map(\.application.name) == ["Linear", "Tool", "Zeta"])
		#expect(installed.map(\.schemes) == [["linear"], ["tool"], ["zeta", "zeta-extra"]])
		#expect(installed.first?.application.bundleID == "com.linear")
	}

	@Test
	internal func registeredSchemesReadLaunchServicesHandlers() throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let preferences = directory.appending(path: "handlers.plist")
		let handlers: [[String: Any]] = [
			["LSHandlerURLScheme": "linear", "LSHandlerRoleAll": "com.linear"],
			["LSHandlerURLScheme": "https", "LSHandlerRoleAll": "dev.capturecontext.arx"],
			["LSHandlerContentType": "public.html", "LSHandlerRoleAll": "dev.capturecontext.arx"],
			["LSHandlerURLScheme": "Slack", "LSHandlerRoleAll": "com.tinyspeck.slackmacgap"],
			["LSHandlerURLScheme": "linear", "LSHandlerRoleAll": "com.linear"],
		]
		let data = try PropertyListSerialization.data(fromPropertyList: ["LSHandlers": handlers], format: .binary, options: 0)
		try data.write(to: preferences)
		#expect(AppLinkApplications.registeredSchemes(in: preferences) == ["linear", "slack"])
		#expect(AppLinkApplications.registeredSchemes(in: directory.appending(path: "missing.plist")).isEmpty)
	}
}
