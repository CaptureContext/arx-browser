import AppUI
import Testing

@testable import ExtensionsFeature

/// DEV-776. What a finished Check for Updates says.
internal struct ExtensionsUpdateCheckMessageTests {
	private let current: String = .localized(.appUI.extensions.updatesCurrent)

	@Test
	internal func nothingNewerIsUpToDate() {
		#expect(ExtensionsPresentation.updateCheck(.init(updated: 0, failed: 0)) == current)
	}

	@Test
	internal func declinedUpdatesAreSkippedNotUpToDate() {
		let message = ExtensionsPresentation.updateCheck(.init(updated: 0, declined: 1, failed: 0))
		#expect(message == String.localized(.appUI.extensions.updatesSkipped(1)))
		#expect(!message.contains(current))
	}

	@Test
	internal func updatedSkippedAndFailedAreAllReported() {
		let message = ExtensionsPresentation.updateCheck(.init(updated: 2, declined: 1, failed: 1))
		#expect(message == [
			String.localized(.appUI.extensions.updatesInstalled(2)),
			String.localized(.appUI.extensions.updatesSkipped(1)),
			String.localized(.appUI.extensions.updatesFailed(1)),
		].joined(separator: " "))
	}
}
