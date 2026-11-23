import Foundation
import Testing

@testable import ChromiumBrowserEngine

/// DEV-1116: only a tab with nothing committed shows the transfer its navigation became.
/// The address can't tell, since Chromium keeps an aborted address visible in an untouched blank
/// tab.
internal struct ChromiumPageDownloadTests {
	@Test
	internal func aTabWithNothingCommittedHasNoPage() async throws {
		#expect(ChromiumBrowserEngine.hasNoPage(current: nil))
	}

	@Test
	internal func aCommittedPageIsKept() async throws {
		#expect(!ChromiumBrowserEngine.hasNoPage(current: URL(string: "https://capturecontext.dev/files")!))
		// A popup a site wrote into keeps its blank address.
		#expect(!ChromiumBrowserEngine.hasNoPage(current: URL(string: "about:blank")!))
	}
}
