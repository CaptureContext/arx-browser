import CustomDump
import Foundation
import Testing

@testable import BrowserCore

/// `arx://` diagnostic pages (DEV-898).
internal struct DiagnosticPageTests {
	@Test
	internal func bothSchemesOpenTheEnginePage() throws {
		let arx = try #require(DiagnosticPage.typed("arx://gpu"))
		expectNoDifference(arx.page, .gpu)
		expectNoDifference(arx.url.absoluteString, "chrome://gpu")

		let chrome = try #require(DiagnosticPage.typed(" CHROME://net-internals/#dns "))
		expectNoDifference(chrome.page, .netInternals)
		expectNoDifference(chrome.url.absoluteString, "chrome://net-internals/#dns")
	}

	@Test
	internal func onlyTheAllowlistOpens() {
		#expect(DiagnosticPage.typed("arx://settings") == nil)
		#expect(DiagnosticPage.typed("chrome://flags") == nil)
		#expect(DiagnosticPage.typed("chrome://gpu?x=1") == nil)
		#expect(DiagnosticPage.typed("chrome://user@gpu") == nil)
		#expect(DiagnosticPage.typed("https://gpu") == nil)
	}

	@Test
	internal func versionAndGPUAreForEveryone() {
		let everyone = DiagnosticPage.allCases.filter { $0.isAvailable(developerModeEnabled: false) }
		expectNoDifference(everyone, [.version, .gpu])
		#expect(DiagnosticPage.allCases.allSatisfy { $0.isAvailable(developerModeEnabled: true) })
	}

	@Test
	internal func theAddressBarShowsTheArxForm() throws {
		let url = try #require(URL(string: "chrome://inspect/#devices"))
		expectNoDifference(DiagnosticPage.displayAddress(for: url), "arx://inspect/#devices")
		#expect(DiagnosticPage.displayAddress(for: URL(string: "https://example.com")!) == nil)
		#expect(DiagnosticPage.displayAddress(for: URL(string: "chrome://flags")!) == nil)
	}
}
