import BrowserDownloadsClient
import CustomDump
import DownloadsFeature
import Foundation
import Testing

/// Download failures show AppUI's text (DEV-1291); the client's English stays for agents and logs.
internal struct DownloadFailureMessageTests {
	@Test
	internal func theClientsFailuresComeFromTheCatalog() {
		let failures: [BrowserDownloadsClient.Failure] = [
			.unavailable,
			.missingDownload,
			.notOpenable,
			.fileMissing,
			.couldNotOpen,
			.couldNotStart,
			.startTimedOut,
			.notResumable,
			.couldNotTrash,
			.notRemovable,
		]

		// The catalog's English is the client's English, word for word.
		expectNoDifference(failures.map(downloadFailureMessage), failures.map { $0.errorDescription ?? "" })
	}

	@Test
	internal func anyOtherErrorKeepsItsDescription() {
		let error: NSError = .init(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disk full."])
		expectNoDifference(downloadFailureMessage(error), "Disk full.")
	}
}
