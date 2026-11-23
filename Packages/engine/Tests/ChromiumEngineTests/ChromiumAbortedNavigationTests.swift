import AppKit
import ChromiumBridge
import CustomDump
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-1116: a navigation Chromium ends with `ERR_ABORTED`, such as one that became a download,
/// commits nothing and shows no error page, so the page keeps what it had.
@MainActor
internal struct ChromiumAbortedNavigationTests {
	private static let url: URL = URL(string: "https://example.com/report")!

	private static func navigation(_ errorCode: Int?) -> ChromiumPage.Navigation {
		.init(
			url: url,
			title: "Report",
			isLoading: false,
			canGoBack: false,
			canGoForward: false,
			errorCode: errorCode
		)
	}

	@Test
	internal func anAbortedNavigationIsNoPageError() async throws {
		let runtime = ChromiumRuntime(api: ArxEngineAPI())
		let page = ChromiumPage(id: 7, view: NSView(), runtime: runtime, isPrivate: false)

		page.receive(Self.navigation(nil))
		page.receive(Self.navigation(ChromiumPage.abortedErrorCode))

		expectNoDifference(page.navigation.errorCode, nil)
	}

	@Test
	internal func anAbortedNavigationKeepsThePagesOwnError() async throws {
		let runtime = ChromiumRuntime(api: ArxEngineAPI())
		let page = ChromiumPage(id: 7, view: NSView(), runtime: runtime, isPrivate: false)

		page.receive(Self.navigation(-105))
		page.receive(Self.navigation(ChromiumPage.abortedErrorCode))
		expectNoDifference(page.navigation.errorCode, -105)

		page.receive(Self.navigation(nil))
		page.receive(Self.navigation(ChromiumPage.abortedErrorCode))
		expectNoDifference(page.navigation.errorCode, nil)

		page.receive(Self.navigation(-106))
		expectNoDifference(page.navigation.errorCode, -106)
	}
}
