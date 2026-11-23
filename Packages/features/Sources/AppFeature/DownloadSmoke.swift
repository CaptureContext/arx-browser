#if DEBUG
import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import CryptoKit
import Foundation

/// Exercises the signed app's real native queue using only disposable fixture tabs and files.
@MainActor
internal enum DownloadSmoke {
	internal static func run(
		engine: BrowserEngineClient,
		downloads: BrowserDownloadsClient,
		organization: BrowserOrganization,
		baseURL: URL,
		metadataFile: URL,
		environment: [String: String]
	) async throws {
		var runner = try Runner(
			engine: engine,
			downloads: downloads,
			organization: organization,
			baseURL: baseURL,
			metadataFile: metadataFile,
			environment: environment
		)

		do {
			try await runner.run()
			try await downloads.configure(organization)
		} catch {
			// This helper is only used inside the disposable app-smoke process.
			try? downloads.cancelAll()
			throw error
		}
	}
}

extension DownloadSmoke {
	private struct Failure: LocalizedError {
		internal var errorDescription: String?

		internal init(_ message: String) {
			self.errorDescription = "Download smoke: " + message
		}
	}

	@MainActor
	internal struct Runner {
		private let engine: BrowserEngineClient
		private let downloads: BrowserDownloadsClient
		private let baseURL: URL
		private let metadataFile: URL
		private let directory: URL
		private let expectedHash: String
		private let expectedBytes: Int
		private let slowHash: String
		private let slowBytes: Int
		private let privateMarker: String
		private let profileID: Profile.ID
		private let profileName: String
		private let spaceID: Space.ID
		private let spaceName: String
		private var organization: BrowserOrganization
		private var tabs: Set<Tab.ID>

		internal init(
			engine: BrowserEngineClient,
			downloads: BrowserDownloadsClient,
			organization: BrowserOrganization,
			baseURL: URL,
			metadataFile: URL,
			environment: [String: String]
		) throws {
			guard
				baseURL.scheme == "http",
				baseURL.host == "127.0.0.1",
				let space = organization.spaces.first,
				let profile = organization.profiles[id: space.profileID],
				let directory = environment["ARX_DOWNLOAD_SMOKE_DIRECTORY"],
				let expectedHash = environment["ARX_DOWNLOAD_SMOKE_SHA256"],
				let expectedBytes = environment["ARX_DOWNLOAD_SMOKE_BYTES"].flatMap(Int.init),
				let slowHash = environment["ARX_DOWNLOAD_SMOKE_SLOW_SHA256"],
				let slowBytes = environment["ARX_DOWNLOAD_SMOKE_SLOW_BYTES"].flatMap(Int.init),
				let privateMarker = environment["ARX_DOWNLOAD_SMOKE_PRIVATE_MARKER"],
				!privateMarker.isEmpty
			else { throw Failure("missing controlled fixture configuration") }

			self.engine = engine
			self.downloads = downloads
			self.organization = organization
			self.baseURL = baseURL
			self.metadataFile = metadataFile
			self.directory = URL(
				filePath: directory,
				directoryHint: .isDirectory
			).resolvingSymlinksInPath()
			self.expectedHash = expectedHash
			self.expectedBytes = expectedBytes
			self.slowHash = slowHash
			self.slowBytes = slowBytes
			self.privateMarker = privateMarker
			self.profileID = profile.id
			self.profileName = profile.name
			self.spaceID = space.id
			self.spaceName = space.name
			self.tabs = []
		}

		internal mutating func run() async throws {
			let privateID = Profile.ID(rawValue: UUID())

			defer {
				for id in tabs { engine.close(id) }
				engine.releasePrivateProfile(privateID)
			}

			let firstTab = try await open("complete")
			let first = try await wait(firstTab) { $0.status == .complete }
			try verify(
				first,
				bytes: expectedBytes,
				hash: expectedHash,
				phase: "ordinary-complete"
			)
			try verifyDownloadingPage(firstTab, shows: first, phase: "ordinary-complete")

			guard
				first.profileName == profileName,
				first.spaceName == spaceName
			else { throw Failure("ordinary origin labels were lost") }

			engine.close(firstTab.id)

			let duplicateTab = try await open("duplicate")
			let duplicate = try await wait(duplicateTab) { $0.status == .complete }
			try verify(
				duplicate,
				bytes: expectedBytes,
				hash: expectedHash,
				phase: "ordinary-duplicate"
			)

			guard first.target != duplicate.target else {
				throw Failure("filename collision overwrote the first download")
			}

			try verify(
				first,
				bytes: expectedBytes,
				hash: expectedHash,
				phase: "ordinary-original-retained"
			)
			engine.close(duplicateTab.id)

			let slowTab = try await open("slow")
			_ = try await progress(slowTab)
			engine.close(slowTab.id)
			let continued = try await wait(slowTab) { $0.status == .complete }
			try verify(
				continued,
				bytes: slowBytes,
				hash: slowHash,
				phase: "ordinary-source-closed"
			)

			let cancelTab = try await open("slow")
			let cancellable = try await progress(cancelTab)
			try downloads.cancel(cancellable.id)
			let cancelled = try await wait(cancelTab) { $0.status == .cancelled }

			guard !cancelled.canOpen else {
				throw Failure("cancelled download became openable")
			}
			try verifyDownloadingPage(cancelTab, shows: cancelled, phase: "ordinary-cancelled")

			engine.close(cancelTab.id)

			let truncatedTab = try await open("truncated")
			let truncated = try await wait(truncatedTab) { $0.status == .interrupted }

			guard !truncated.canOpen else {
				throw Failure("truncated response was presented as complete")
			}

			engine.close(truncatedTab.id)

			try await verifyPauseAndResume()

			try engine.preparePrivateProfile(privateID, nil)
			let privateTab = try await open("slow", privateID: privateID)
			print("ARX_DOWNLOAD_SMOKE_PHASE private-progress started")
			let privateProgress = try await progress(privateTab)
			print("ARX_DOWNLOAD_SMOKE_PHASE private-progress passed")

			guard
				privateProgress.isPrivate,
				privateProgress.spaceName == nil,
				downloads.activeCount() > 0
			else { throw Failure("private transfer was missing from the active private queue") }

			engine.close(privateTab.id)
			engine.releasePrivateProfile(privateID)
			print("ARX_DOWNLOAD_SMOKE_PHASE private-source-closed started")
			let privateComplete = try await wait(privateTab) { $0.status == .complete }
			try verify(
				privateComplete,
				bytes: slowBytes,
				hash: slowHash,
				phase: "private-source-closed"
			)
			try await verifyPrivateReopening(privateID)
			let queue = downloads.snapshot()

			guard
				queue.privateDownloads.contains(where: { $0.id == privateComplete.id }),
				!queue.downloads.contains(where: { $0.id == privateComplete.id || $0.isPrivate }),
				downloads.activeCount() == 0
			else { throw Failure("private queue isolation or terminal native activity was incorrect") }

			let metadata = try String(contentsOf: metadataFile, encoding: .utf8).lowercased()
			let privateValues = [privateMarker, privateID.rawValue.uuidString]
			+ queue.privateDownloads.map(\.id.guid)

			for value in privateValues {
				guard !metadata.contains(value.lowercased())
				else { throw Failure("private record was persisted") }
			}

			print("ARX_DOWNLOAD_SMOKE_SUCCESS")
		}

		/// DEV-892: Pause stops the bytes, Resume finishes the same file, and Remove from List
		/// forgets it while the file stays. The relaunch half is `DownloadResumeSmoke`.
		private mutating func verifyPauseAndResume() async throws {
			let tab = try await open("resumable")
			let running = try await wait(tab) { $0.status == .inProgress && $0.receivedBytes > 0 && $0.canPause }
			try downloads.setPaused(running.id, true)
			_ = try await wait(tab) { $0.isPaused && $0.canResume }

			// Bytes already in flight may still land; after that, nothing more arrives.
			try await Task.sleep(for: .milliseconds(500))
			let settled = try await wait(tab) { _ in true }
			try await Task.sleep(for: .milliseconds(1_500))
			let stalled = try await wait(tab) { _ in true }
			guard stalled.isPaused, stalled.receivedBytes == settled.receivedBytes, stalled.receivedBytes < slowBytes
			else { throw Failure("a paused download kept receiving bytes") }
			print("ARX_DOWNLOAD_SMOKE_PHASE paused passed")

			try downloads.setPaused(stalled.id, false)
			let resumed = try await wait(tab) { $0.status == .complete }
			try verify(resumed, bytes: slowBytes, hash: slowHash, phase: "ordinary-paused-resumed")
			engine.close(tab.id)

			try downloads.removeFromList(resumed.id)
			guard !downloads.snapshot().downloads.contains(where: { $0.id == resumed.id })
			else { throw Failure("Remove from List kept the download") }
			guard let target = resumed.target, FileManager.default.fileExists(atPath: target.path)
			else { throw Failure("Remove from List deleted the file") }
			print("ARX_DOWNLOAD_SMOKE_PHASE resumed passed")
		}

		private mutating func verifyPrivateReopening(_ privateID: Profile.ID) async throws {
			try engine.preparePrivateProfile(privateID, nil)
			try await visitPrivateIdentity(
				privateID,
				setting: "private",
				expecting: "private|private"
			)
			let retiredTab = try await open("retained", privateID: privateID)
			let retiredTransfer = try await progress(retiredTab)
			engine.close(retiredTab.id)
			engine.releasePrivateProfile(privateID)

			// Reopening must create fresh browsing storage while the previous
			// context remains alive solely to finish its private transfer.
			try engine.preparePrivateProfile(privateID, nil)
			try await visitPrivateIdentity(
				privateID,
				setting: "",
				expecting: "empty|empty"
			)
			let replacementTab = try await open("slow", privateID: privateID)
			let replacementTransfer = try await progress(replacementTab)

			guard
				retiredTransfer.id != replacementTransfer.id,
				downloads.activeCount() >= 2
			else { throw Failure("reopening did not retain independent private transfers") }

			try downloads.cancel(retiredTransfer.id)
			_ = try await wait(retiredTab) { $0.status == .cancelled }
			let replacementComplete = try await wait(replacementTab) { $0.status == .complete }
			try verify(
				replacementComplete,
				bytes: slowBytes,
				hash: slowHash,
				phase: "private-replacement"
			)
			engine.close(replacementTab.id)
			engine.releasePrivateProfile(privateID)
			print("ARX_PRIVATE_DOWNLOAD_REOPEN_SMOKE_SUCCESS")
		}

		private mutating func visitPrivateIdentity(
			_ privateID: Profile.ID,
			setting identity: String,
			expecting title: String
		) async throws {
			let url = baseURL.deletingLastPathComponent()
				.appendingPathComponent("identity.html")
				.appending(queryItems: [.init(name: "set", value: identity)])
			let tab = Tab(
				id: .init(rawValue: UUID()),
				profileID: privateID,
				restoration: .init(title: "Private identity fixture", url: url)
			)
			tabs.insert(tab.id)
			defer { engine.close(tab.id) }
			try await engine.open(tab)

			let deadline = ContinuousClock.now.advanced(by: .seconds(10))

			while ContinuousClock.now < deadline {
				let navigation = engine.snapshot(tab.id)?.navigation
				let matchesIdentity = navigation?.url == url
				&& navigation?.title == title
				&& navigation?.isLoading == false

				if matchesIdentity { return }
				try await Task.sleep(for: .milliseconds(100))
			}

			throw Failure("private storage was not isolated across active-download reopening")
		}

		private mutating func open(
			_ endpoint: String,
			privateID: Profile.ID? = nil
		) async throws -> Tab {
			let id = Tab.ID(rawValue: UUID())
			var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
			components.path = "/downloads/" + endpoint
			components.queryItems = [
				.init(
					name: "smoke",
					value: privateID == nil ? id.rawValue.uuidString : privateMarker
				),
				.init(name: "tab", value: id.rawValue.uuidString)
			]

			let tab = Tab(
				id: id,
				profileID: privateID ?? profileID,
				restoration: .init(title: "Download smoke", url: components.url!)
			)
			tabs.insert(id)

			if privateID == nil {
				organization.tabs.append(tab)
				let index = organization.spaces.index(id: spaceID)!
				organization.spaces[index].unpinnedTabs.append(id)
				try await downloads.configure(organization)
			}

			try await engine.open(tab)
			return tab
		}

		/// DEV-1116: a tab opened for a file has no page to keep, so it shows the transfer
		/// instead of a page error.
		private func verifyDownloadingPage(
			_ tab: Tab,
			shows record: BrowserDownload,
			phase: StaticString
		) throws {
			let navigation = engine.snapshot(tab.id)?.navigation
			guard navigation?.errorCode == nil, navigation?.download?.id == record.id else {
				let error = navigation?.errorCode.map(String.init) ?? "nil"

				// Why, without full addresses: whether the tab has a page, what its history says
				// (the current entry's scheme and host only), and whether the transfer knows its tab.
				let current = navigation?.history.first(where: \.isCurrent)
				throw Failure(
					"tab did not show its download (phase=\(phase) error=\(error) "
					+ "showsDownload=\(navigation?.download != nil) hasSnapshot=\(navigation != nil) "
					+ "committed=\(engine.documentType(tab.id) != nil) "
					+ "hasNoPage=\(navigation?.hasNoPage == true) "
					+ "historyEntries=\(navigation?.history.count ?? 0) hasCurrentEntry=\(current != nil) "
					+ "currentIsFile=\(current?.url == tab.restoration.url) "
					+ "currentScheme=\(current?.url.scheme ?? "nil") currentHost=\(current?.url.host() ?? "nil") "
					+ "knowsTab=\(record.sourceTabID == tab.id))"
				)
			}
		}

		private func progress(_ tab: Tab) async throws -> BrowserDownload {
			try await wait(tab) {
				$0.status == .inProgress
				&& $0.receivedBytes > 0
				&& $0.receivedBytes < $0.totalBytes
			}
		}

		private func wait(
			_ tab: Tab,
			until predicate: (BrowserDownload) -> Bool
		) async throws -> BrowserDownload {
			let deadline = ContinuousClock.now.advanced(by: .seconds(30))
			var lastRecord: BrowserDownload?

			while ContinuousClock.now < deadline {
				let queue = downloads.snapshot()
				let record = (queue.downloads + queue.privateDownloads).first {
					$0.url == tab.restoration.url
				}

				if let record {
					lastRecord = record
					if predicate(record) { return record }
					guard record.status == .inProgress
					else { throw Failure("unexpected \(record.status) state, native reason \(record.interruptReason)") }
				}

				try await Task.sleep(for: .milliseconds(100))
			}

			// State classifications identify the failed boundary without printing
			// private URLs, filenames, profile keys or download identifiers.
			let diagnostic = lastRecord.map { record in
				"status=\(record.status.rawValue) receivedBytes=\(record.receivedBytes) "
				+ "totalBytes=\(record.totalBytes) hasTarget=\(record.target != nil) "
				+ "isDangerous=\(record.isDangerous) nativeReason=\(record.interruptReason)"
			} ?? "record=missing"
			throw Failure("timed out waiting for native download state (\(diagnostic))")
		}

		internal func verify(
			_ record: BrowserDownload,
			bytes: Int,
			hash: String,
			phase: StaticString
		) throws {
			let target = record.target?.resolvingSymlinksInPath()
			let destinationMatches = target?.deletingLastPathComponent() == directory
			let diagnostic = [
				"phase=\(phase)",
				"canOpen=\(record.canOpen)",
				"status=\(record.status.rawValue)",
				"receivedBytes=\(record.receivedBytes)",
				"expectedBytes=\(bytes)",
				"totalBytes=\(record.totalBytes)",
				"destinationMatches=\(destinationMatches)",
				"isDangerous=\(record.isDangerous)",
				"isMissing=\(record.isMissing)"
			].joined(separator: " ")
			print("ARX_DOWNLOAD_SMOKE_VERIFY \(diagnostic)")

			guard
				record.canOpen,
				record.receivedBytes == bytes,
				let target,
				destinationMatches
			else {
				throw Failure(
					"completed download did not use the configured destination and byte count (\(diagnostic))"
				)
			}

			let data = try Data(contentsOf: target)
			let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

			guard data.count == bytes, actual == hash
			else { throw Failure("downloaded bytes did not match the fixture (phase=\(phase))") }
		}
	}
}
#endif
