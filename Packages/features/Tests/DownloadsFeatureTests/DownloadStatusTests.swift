import AppUI
import BrowserCore
import Foundation
import Testing

@testable import DownloadsFeature

/// The status line of a download that stopped (DEV-1152): one Resume continues, such as one a quit
/// stopped (DEV-966), says so without Chromium's reason; one that can't continue keeps it.
@MainActor
internal struct DownloadStatusTests {
	@Test
	internal func resumableInterruptedDownloadSaysResumeContinuesIt() {
		let download = record(status: .interrupted, interruptReason: 50, canResume: true)

		#expect(download.statusDescription == String.localized(.appUI.downloads.resumable))
		#expect(!download.statusDescription.contains("50"))
	}

	@Test
	internal func unresumableInterruptedDownloadKeepsItsReason() {
		let download = record(status: .interrupted, interruptReason: 41)

		#expect(download.statusDescription == String.localized(.appUI.downloads.interrupted) + " (41)")
	}

	@Test
	internal func pausedDownloadStaysPaused() {
		let download = record(status: .inProgress, isPaused: true, canResume: true)

		#expect(download.statusDescription == String.localized(.appUI.downloads.paused))
	}

	@Test
	internal func blockedDownloadSaysBlockedEvenWhenResumable() {
		let download = record(status: .interrupted, interruptReason: 50, isDangerous: true, canResume: true)

		#expect(download.statusDescription == String.localized(.appUI.downloads.blocked))
	}

	private func record(
		status: BrowserDownload.Status,
		interruptReason: Int = 0,
		isDangerous: Bool = false,
		isPaused: Bool = false,
		canResume: Bool = false
	) -> BrowserDownload {
		.init(
			id: .init(profileID: .init(rawValue: UUID()), guid: "download"),
			profileName: "Work",
			filename: "report.txt",
			status: status,
			startedAt: Date(timeIntervalSince1970: 100),
			interruptReason: interruptReason,
			isDangerous: isDangerous,
			isPaused: isPaused,
			canResume: canResume
		)
	}
}
