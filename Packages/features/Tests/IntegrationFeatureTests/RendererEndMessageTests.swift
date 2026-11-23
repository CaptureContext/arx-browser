import AppUI
import BrowserCore
import Foundation
import Testing
import ViewerItemFeature

/// DEV-1016: the page says why its renderer ended, and when it keeps ending.
internal struct RendererEndMessageTests {
	@Test
	internal func eachCauseHasItsOwnWords() {
		let cases: [(BrowserNavigation.RendererEnd.Cause, String)] = [
			(.crashed, String.localized(.appUI.viewer.rendererCrashed)),
			(.outOfMemory, String.localized(.appUI.viewer.rendererOutOfMemory)),
			(.killed, String.localized(.appUI.viewer.rendererKilled)),
			(.endedByArx, String.localized(.appUI.viewer.rendererEndedByArx)),
			(.launchFailed, String.localized(.appUI.viewer.rendererLaunchFailed)),
			(.other, String.localized(.appUI.viewer.rendererFailed)),
		]
		for (cause, words) in cases {
			#expect(ViewerItemFeature.message(for: .init(cause: cause, number: 1)) == words)
		}
		#expect(Set(cases.map(\.1)).count == cases.count)
	}

	@Test
	internal func aSharedEndAndAPageThatKeepsEndingSaySo() {
		#expect(
			ViewerItemFeature.message(for: .init(cause: .crashed, number: 1, isShared: true))
			== String.localized(.appUI.viewer.rendererShared)
		)
		#expect(
			ViewerItemFeature.message(for: .init(cause: .crashed, number: 3, isRepeated: true))
			== String.localized(.appUI.viewer.rendererKeepsCrashing)
		)
		#expect(
			ViewerItemFeature.message(for: .init(cause: .outOfMemory, number: 3, isRepeated: true))
			== String.localized(.appUI.viewer.rendererKeepsRunningOutOfMemory)
		)

		// Without an end, the old words.
		#expect(
			ViewerItemFeature.message(for: .rendererStopped)
			== String.localized(.appUI.viewer.rendererFailed)
		)
	}
}
