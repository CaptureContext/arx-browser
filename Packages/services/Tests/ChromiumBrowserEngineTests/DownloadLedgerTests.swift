import BrowserCore
import BrowserDownloadsClient
import Foundation
import Testing

@testable import ChromiumBrowserEngine

internal struct DownloadLedgerTests {
	@Test
	internal func preservesOriginAndCompletionAcrossRestart() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let target = directory.appending(path: "report.txt")
		try Data("complete".utf8).write(to: target)
		let file = directory.appending(path: "downloads.json")
		var ledger = DownloadLedger(file: file)
		var value = record(target: target)
		ledger.receive(value)
		value.profileName = "Renamed"
		value.spaceName = nil
		value.receivedBytes = 8
		ledger.receive(value)
		#expect(ledger.snapshot.downloads.first?.receivedBytes == 8)
		#expect(ledger.snapshot.downloads.first?.profileName == "Work")
		#expect(ledger.snapshot.downloads.first?.spaceName == "Research")
		value.status = .complete
		ledger.receive(value)
		var restored = DownloadLedger(file: file)
		#expect(restored.snapshot.downloads.first?.status == .complete)
		#expect(restored.snapshot.downloads.first?.receivedBytes == 8)
		#expect(try restored.fileForOpening(value.id) == target)
	}

	/// DEV-1116. The tab that started a transfer stays known after it closes, and is never saved.
	@Test
	internal func keepsTheSourceTabWithoutSavingIt() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appending(path: "downloads.json")
		let tab = Tab.ID(rawValue: UUID())
		var ledger = DownloadLedger(file: file)
		var value = record()
		value.sourceTabID = tab
		ledger.receive(value)
		value.sourceTabID = nil
		value.receivedBytes = 8
		ledger.receive(value)
		#expect(ledger.records[value.id]?.sourceTabID == tab)

		let saved = try String(contentsOf: file, encoding: .utf8)
		#expect(!saved.contains(tab.rawValue.uuidString))
		let restored = DownloadLedger(file: file)
		#expect(restored.records[value.id]?.sourceTabID == nil)
	}

	@Test
	internal func reconcilesOnlyMissingActiveItemsAfterAuthoritativeInitialization() {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appending(path: "downloads.json")
		var ledger = DownloadLedger(file: file)
		let missing = record()
		var observed = record()
		observed.id.guid = "seen"
		ledger.receive(missing)
		ledger.receive(observed)
		var restored = DownloadLedger(file: file)
		#expect(restored.snapshot.activeCount == 2)
		restored.receive(observed)
		restored.initialized(profileID: missing.id.profileID)
		#expect(restored.records[missing.id]?.status == .interrupted)
		#expect(restored.records[observed.id]?.status == .inProgress)
	}

	/// DEV-880. A transfer a crash left in progress waits on its profile loading, until
	/// Chromium reports it or initialization settles it.
	@Test
	internal func persistedActiveRecordsKeepTheirProfilePendingUntilReconciled() {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appending(path: "downloads.json")
		var ledger = DownloadLedger(file: file)
		let active = record()
		var finished = record()
		finished.id = .init(profileID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!), guid: "done")
		finished.status = .complete
		ledger.receive(active)
		ledger.receive(finished)

		// This session saw it: nothing to reconcile.
		#expect(ledger.pendingReconciliation(among: [active.id.profileID, finished.id.profileID]).isEmpty)

		var restored = DownloadLedger(file: file)
		#expect(restored.pendingReconciliation(among: [active.id.profileID, finished.id.profileID]) == [active.id.profileID])
		restored.initialized(profileID: active.id.profileID)
		#expect(restored.pendingReconciliation(among: [active.id.profileID]).isEmpty)

		var resumed = DownloadLedger(file: file)
		resumed.receive(active)
		#expect(resumed.pendingReconciliation(among: [active.id.profileID]).isEmpty)
	}

	/// DEV-880. Unreadable history leaves Chromium the only record, so every profile waits on
	/// its enumeration once.
	@Test
	internal func unreadableHistoryKeepsEveryProfilePendingUntilChromiumEnumeratesIt() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appending(path: "downloads.json")
		try Data("damaged".utf8).write(to: file)
		let first = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
		let second = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
		var ledger = DownloadLedger(file: file)
		#expect(ledger.snapshot.message != nil)
		#expect(ledger.pendingReconciliation(among: [first, second]) == [first, second])
		ledger.initialized(profileID: first)
		#expect(ledger.pendingReconciliation(among: [first, second]) == [second])
		// Readable history trusts its records.
		#expect(DownloadLedger(file: directory.appending(path: "missing.json")).pendingReconciliation(among: [first]).isEmpty)
	}

	@Test
	internal func firstConfigureInterruptsOrphanedPersistedActiveRecordsOnly() {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appending(path: "downloads.json")
		var ledger = DownloadLedger(file: file)
		let orphan = record()
		var complete = orphan
		complete.id.guid = "complete"
		complete.status = .complete
		ledger.receive(orphan)
		ledger.receive(complete)
		var restored = DownloadLedger(file: file)
		restored.configure(profileIDs: [])
		#expect(restored.records[orphan.id]?.status == .interrupted)
		#expect(restored.records[complete.id]?.status == .complete)
		#expect(restored.records[complete.id]?.profileName == "Work")
		#expect(restored.records[complete.id]?.spaceName == "Research")
	}

	@Test
	internal func configurationNeverInterruptsLiveTransfersOrLaterProfileDeletion() {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var ledger = DownloadLedger(file: directory.appending(path: "downloads.json"))
		let live = record()
		ledger.receive(live)
		ledger.configure(profileIDs: [])
		#expect(ledger.records[live.id]?.status == .inProgress)
		ledger.configure(profileIDs: [live.id.profileID])
		ledger.configure(profileIDs: [])
		#expect(ledger.records[live.id]?.status == .inProgress)
		#expect(ledger.records[live.id]?.profileName == "Work")
	}

	@Test
	internal func neverPersistsPrivateRecordsOrOriginLabels() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appending(path: "downloads.json")
		var ledger = DownloadLedger(file: file)
		var value = record()
		value.isPrivate = true
		value.profileName = "SECRET_ORIGIN"
		value.url = URL(string: "https://private.example/SECRET_URL")
		ledger.receive(value)
		#expect(ledger.snapshot.downloads.isEmpty)
		#expect(ledger.snapshot.privateDownloads.count == 1)
		#expect(ledger.snapshot.activeCount == 1)
		let persisted = try String(contentsOf: file, encoding: .utf8)
		#expect(!persisted.contains("SECRET"))
		#expect(!persisted.contains(value.id.guid))
		#expect(DownloadLedger(file: file).snapshot.privateDownloads.isEmpty)
	}

	@Test(arguments: [BrowserDownload.Status.cancelled, .interrupted, .inProgress])
	internal func cannotOpenIncompleteTransfer(status: BrowserDownload.Status) {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var ledger = DownloadLedger(file: directory.appending(path: "downloads.json"))
		var value = record()
		value.status = status
		ledger.receive(value)
		#expect(throws: BrowserDownloadsClient.Failure.notOpenable) { try ledger.fileForOpening(value.id) }
	}

	@Test
	internal func rechecksMissingFileAndBlocksDangerousFiles() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let target = directory.appending(path: "report.txt")
		try Data().write(to: target)
		var ledger = DownloadLedger(file: directory.appending(path: "downloads.json"))
		var value = record(target: target)
		value.status = .complete
		ledger.receive(value)
		try FileManager.default.removeItem(at: target)
		#expect(throws: BrowserDownloadsClient.Failure.fileMissing) { try ledger.fileForOpening(value.id) }
		#expect(ledger.records[value.id]?.isMissing == true)
		try Data().write(to: target)
		value.isDangerous = true
		ledger.receive(value)
		#expect(throws: BrowserDownloadsClient.Failure.notOpenable) { try ledger.fileForOpening(value.id) }
	}

	@Test
	internal func reportsPersistenceFailureWithoutLosingActiveTransfer() {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var ledger = DownloadLedger(file: directory)
		ledger.receive(record())
		#expect(ledger.snapshot.message != nil)
		#expect(ledger.snapshot.activeCount == 1)
	}

	@Test
	internal func profileRemovedBeforeNativePreparationReconcilesOnlyUnseenPersistedTransfers() {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appending(path: "downloads.json")
		var original = DownloadLedger(file: file)
		let pending = record()
		original.receive(pending)
		var restored = DownloadLedger(file: file)
		restored.configure(profileIDs: [pending.id.profileID])
		var live = pending
		live.id.guid = "live"
		restored.receive(live)
		var privateTransfer = pending
		privateTransfer.id.guid = "private"
		privateTransfer.isPrivate = true
		restored.receive(privateTransfer)

		// The ordinary profile is removed while native preparation is still suspended.
		restored.configure(profileIDs: [])
		#expect(restored.records[pending.id]?.status == .interrupted)
		#expect(restored.records[live.id]?.status == .inProgress)
		#expect(restored.records[privateTransfer.id]?.status == .inProgress)
	}

	@Test
	internal func clearingDownloadHistoryForgetsOnlyThePickedFinishedTransfers() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appending(path: "downloads.json")
		var ledger = DownloadLedger(file: file)
		var recent = record()
		recent.id.guid = "recent"
		recent.status = .complete
		recent.startedAt = Date(timeIntervalSince1970: 500)
		var old = recent
		old.id.guid = "old"
		old.startedAt = Date(timeIntervalSince1970: 50)
		var active = recent
		active.id.guid = "active"
		active.status = .inProgress
		var other = recent
		other.id.guid = "other"
		other.id.profileID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
		for value in [recent, old, active, other] {
			ledger.receive(value)
		}

		#expect(try ledger.removeFinished([recent.id, active.id]) == 1)
		#expect(ledger.records[recent.id] == nil)
		#expect(ledger.records[old.id] != nil)
		// Still running, so it stays.
		#expect(ledger.records[active.id] != nil)
		#expect(ledger.records[other.id] != nil)
		#expect(try ledger.removeFinished([old.id]) == 1)
		// The removal is saved, so it survives a restart.
		let restored = DownloadLedger(file: file)
		#expect(Set(restored.records.keys.map(\.guid)) == ["active", "other"])
	}

	private func record(target: URL? = nil) -> BrowserDownload {
		.init(
			id: .init(profileID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), guid: "download-guid"),
			profileName: "Work",
			spaceName: "Research",
			target: target,
			filename: "report.txt",
			status: .inProgress,
			startedAt: Date(timeIntervalSince1970: 100)
		)
	}

	private func temporaryDirectory() -> URL {
		let directory = FileManager.default.temporaryDirectory.appending(path: "arx-download-tests-\(UUID())")
		try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}
}
