import DiagnosticsClient
import Foundation
import Testing

/// The prefilled new issue page Report a Problem opens (DEV-887).
internal struct GitHubIssueTests {
	private static func items(_ url: URL) throws -> [String: String] {
		let components: URLComponents = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
		return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
	}

	@Test
	internal func prefillsTheFormWithTheDescriptionAndVersionsOnly() throws {
		let url: URL = GitHubIssue.newIssueURL(
			description: "Tabs vanish & come back = odd + #3",
			environment: .preview,
			attachment: "Arx Problem Report 2026-11-14 at 10.15.00.json"
		)
		#expect(url.absoluteString.hasPrefix("https://github.com/capturecontext/arx-browser/issues/new?"))
		let items: [String: String] = try Self.items(url)
		#expect(items == [
			"template": "problem-report.yml",
			"description": "Tabs vanish & come back = odd + #3",
			"arx-version": "0.3.0 (12)",
			"engine-version": "Helium 0.20.1.1, Chromium 147.0.7727.55",
			"macos-version": "macOS 27.0 (26A425), arm64",
			"attachment": "Arx Problem Report 2026-11-14 at 10.15.00.json",
		])

		// Reserved characters are encoded, so the description can't add or change a field.
		#expect(!url.absoluteString.contains("+"))
		#expect(url.fragment == nil)
	}

	@Test
	internal func withoutAFileThereIsNoAttachmentField() throws {
		var environment: DiagnosticsEnvironment = .preview
		environment.engineVersion = nil
		environment.chromiumVersion = nil
		let items: [String: String] = try Self.items(
			GitHubIssue.newIssueURL(description: "It froze", environment: environment, attachment: nil)
		)
		#expect(items["attachment"] == nil)
		#expect(items["engine-version"] == "Helium unknown")
	}

	@Test
	internal func aLongDescriptionIsCutToFitTheAddress() throws {
		let long: String = String(repeating: "é ünïcode ", count: 2_000)
		let url: URL = GitHubIssue.newIssueURL(description: long, environment: .preview, attachment: nil)
		#expect(url.absoluteString.count <= GitHubIssue.addressLimit)
		let description: String = try #require(try Self.items(url)["description"])
		#expect(description.hasSuffix(GitHubIssue.cutMarker))
		#expect(long.hasPrefix(String(description.dropLast(GitHubIssue.cutMarker.count))))
		#expect(url.absoluteString.count > GitHubIssue.addressLimit - 100)

		#expect(!GitHubIssue.fits(description: long, environment: .preview))
		#expect(GitHubIssue.fits(description: "Short \n\n[…]", environment: .preview))

		let short: URL = GitHubIssue.newIssueURL(description: "Short", environment: .preview, attachment: nil)
		#expect(try Self.items(short)["description"] == "Short")
	}

	@Test
	internal func theIssueFormKeepsTheFieldsTheAppFills() throws {
		var root: URL = URL(fileURLWithPath: #filePath)
		while !FileManager.default.fileExists(atPath: root.appendingPathComponent(".github").path) {
			root.deleteLastPathComponent()
			try #require(root.path != "/")
		}
		let form: String = try String(
			contentsOf: root.appendingPathComponent(".github/ISSUE_TEMPLATE/\(GitHubIssue.template)"),
			encoding: .utf8
		)
		for field in [
			GitHubIssue.Field.description,
			GitHubIssue.Field.app,
			GitHubIssue.Field.engine,
			GitHubIssue.Field.system,
			GitHubIssue.Field.attachment,
		] {
			#expect(form.contains("id: \(field)\n"), "\(field) is missing from the issue form")
		}
	}
}
