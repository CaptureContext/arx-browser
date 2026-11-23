@testable import AppUI
import CustomDump
import Foundation
import Testing

/// What the URL bar shows for a page (DEV-987: a local file shows its path, not the placeholder).
internal struct URLBarAddressTests {
	@Test
	internal func aWebPageShowsItsHostOrWholeAddress() {
		let url = URL(string: "https://capturecontext.dev/docs?q=1")!
		expectNoDifference(URLBar.displayAddress(for: url, showsFullURL: false), "capturecontext.dev")
		expectNoDifference(URLBar.displayAddress(for: url, showsFullURL: true), url.absoluteString)
	}

	@Test
	internal func aLocalFileShowsItsPathOrWholeAddress() {
		let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: "local-reports/index.html")
		expectNoDifference(URLBar.displayAddress(for: file, showsFullURL: false), "~/local-reports/index.html")
		expectNoDifference(URLBar.displayAddress(for: file, showsFullURL: true), file.absoluteString)
	}
}
