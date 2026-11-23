import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-987: a local file page's address reads as its path, `~` for the home folder.
internal struct LocalFileDisplayPathTests {
	@Test
	internal func aFileInTheHomeFolderReadsFromTilde() {
		let home = FileManager.default.homeDirectoryForCurrentUser
		let file = home.appending(path: "Developer/local reports/index.html")
		expectNoDifference(file.localFileDisplayPath, "~/Developer/local reports/index.html")
	}

	@Test
	internal func aFileElsewhereKeepsItsWholePath() {
		expectNoDifference(
			URL(string: "file:///private/tmp/a%20b/report.html")!.localFileDisplayPath,
			"/private/tmp/a b/report.html"
		)
		expectNoDifference(URL(string: "file://localhost/tmp/report.html")!.localFileDisplayPath, "/tmp/report.html")
	}

	@Test(arguments: ["https://example.test/a.html", "file://server.example/share/a.html", "about:blank"])
	internal func anythingButALocalFileHasNone(_ raw: String) {
		#expect(URL(string: raw)!.localFileDisplayPath == nil)
	}
}
