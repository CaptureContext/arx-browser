import BrowserCore
import BrowserDownloadsClient
import Foundation
import Testing

@testable import ChromiumBrowserEngine

/// Remove from List and pause state in the ledger (DEV-892).
internal struct DownloadLedgerRemovalTests {
	private let profile: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

	@Test
	internal func aRemovedTransferDoesntComeBackThisSession() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var ledger = DownloadLedger(file: directory.appending(path: "downloads.json"))
		var value = record("finished")
		value.status = .complete
		ledger.receive(value)
		#expect(try ledger.removeFinished([value.id]) == 1)
		// A notification already on its way doesn't bring it back.
		ledger.receive(value)
		#expect(ledger.records[value.id] == nil)
	}

	@Test
	internal func chromiumsAbsenceIsKnownOnlyAfterItsHistoryLoaded() {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var ledger = DownloadLedger(file: directory.appending(path: "downloads.json"))
		let seen = record("seen")
		let unseen = record("unseen")
		ledger.configure(profileIDs: [profile])
		ledger.receive(seen)
		#expect(!ledger.isKnownAbsentNatively(unseen.id))
		ledger.initialized(profileID: profile)
		#expect(ledger.isKnownAbsentNatively(unseen.id))
		#expect(!ledger.isKnownAbsentNatively(seen.id))
		// A profile that's gone won't bring anything back either.
		let other = BrowserDownload.ID(profileID: .init(rawValue: UUID()), guid: "other")
		#expect(ledger.isKnownAbsentNatively(other))
	}

	@Test
	internal func pauseStateIsNotSaved() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appending(path: "downloads.json")
		var ledger = DownloadLedger(file: file)
		var value = record("paused")
		value.isPaused = true
		value.canResume = true
		ledger.receive(value)
		#expect(ledger.records[value.id]?.isPaused == true)
		let restored = DownloadLedger(file: file)
		#expect(restored.records[value.id]?.isPaused == false)
		#expect(restored.records[value.id]?.canResume == false)
	}

	private func record(_ guid: String) -> BrowserDownload {
		.init(
			id: .init(profileID: profile, guid: guid),
			profileName: "Work",
			filename: "report.txt",
			status: .inProgress,
			startedAt: Date(timeIntervalSince1970: 100)
		)
	}

	private func temporaryDirectory() -> URL {
		let directory = FileManager.default.temporaryDirectory.appending(path: "arx-download-removal-\(UUID())")
		try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}
}
