import ChromiumBridge
import Testing

@testable import ChromiumEngine

/// DEV-1130: the transfers a quit would lose are read from the engine's export while it runs;
/// an engine built before the export has no count to give.
@MainActor
internal struct ChromiumLostOnQuitDownloadsTests {
	@Test
	internal func readsTheEnginesCountWhileRunning() {
		let runtime = ChromiumRuntime(api: ArxEngineAPI())
		runtime.optionalExports.lostOnQuitDownloadCount = { 3 }
		#expect(runtime.lostOnQuitDownloadCount() == 0)
		runtime.didBecomeReady()
		#expect(runtime.lostOnQuitDownloadCount() == 3)
	}

	@Test
	internal func anOlderEngineHasNoCount() {
		let runtime = ChromiumRuntime(api: ArxEngineAPI())
		runtime.didBecomeReady()
		#expect(runtime.lostOnQuitDownloadCount() == nil)
	}
}
