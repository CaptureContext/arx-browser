import AppKit
import BrowserCore
import BrowserDownloadsClient
import ChromiumEngine

@MainActor
internal final class ChromiumDownloads {
	private let runtime: ChromiumRuntime
	private let legacyProfileID: Profile.ID
	private let sourceTab: @MainActor (UInt64) -> Tab.ID?

	/// A transfer a tab's page started changed (DEV-1116).
	private let tabDownloadChanged: @MainActor (BrowserDownload) -> Void
	private var organization: BrowserOrganization = .init()
	private var knownTabSpaces: [Tab.ID: String] = [:]
	private var ledger: DownloadLedger
	private var observation: Task<Void, Never>?
	private var observers: [UUID: AsyncStream<DownloadQueue>.Continuation] = [:]

	/// Transfers Chromium already forgot, so a list removal that couldn't be saved can be retried.
	private var forgotten: Set<BrowserDownload.ID> = []

	internal init(
		runtime: ChromiumRuntime,
		legacyProfileID: Profile.ID,
		file: URL,
		organization: BrowserOrganization,
		sourceTab: @escaping @MainActor (UInt64) -> Tab.ID?,
		tabDownloadChanged: @escaping @MainActor (BrowserDownload) -> Void = { _ in }
	) {
		self.runtime = runtime
		self.legacyProfileID = legacyProfileID
		self.ledger = .init(file: file)
		self.sourceTab = sourceTab
		self.tabDownloadChanged = tabDownloadChanged

		updateOrganization(organization)
		let stream = runtime.downloadEvents()
		self.observation = Task { [weak self] in
			for await event in stream {
				guard let self else { return }
				self.receive(event)
			}
		}
	}

	deinit { observation?.cancel() }

	internal var client: BrowserDownloadsClient {
		.init(
			configure: { [self] organization in

				// Superseded requests may reach this actor after a newer configuration.
				try Task.checkCancellation()
				updateOrganization(organization)
				let profileIDs: Set<Profile.ID> = Set(organization.profiles.map(\.id))

				// A profile merged into another keeps its transfers under the kept one (DEV-1216).
				var reassigned: [Profile.ID: Profile.ID] = [:]
				for id in ledger.records.keys where !profileIDs.contains(id.profileID) {
					let kept: Profile.ID = .init(rawValue: ProfileStorageAliases.shared.profileID(forStorage: id.profileID.rawValue))
					if kept != id.profileID, profileIDs.contains(kept) {
						reassigned[id.profileID] = kept
					}
				}
				ledger.reassign(reassigned)
				ledger.configure(profileIDs: profileIDs)
				publish()

				// Profiles load on demand (DEV-880): a profile's downloads are observed once
				// something loads it, and the ledger lists every profile's records meanwhile. Only
				// a profile with a transfer left in progress, by a crash or a quit, loads now, so
				// Chromium resumes or interrupts it instead of it showing as stuck; every profile
				// does when the saved history couldn't be read, so Chromium restores its downloads.
				var firstFailure: (any Error)?
				let pending = ledger.pendingReconciliation(among: Set(organization.profiles.ids))
				for profile in pending.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
					try Task.checkCancellation()

					do {
						try await runtime.prepareProfile(profile.chromiumProfile(legacy: legacyProfileID))
					} catch {
						try Task.checkCancellation()
						if firstFailure == nil { firstFailure = error }
					}
				}

				if let firstFailure { throw firstFailure }
			},
			events: { [self] in events() },
			activeCount: { [self] in runtime.activeDownloadCount() },
			// The engine counts them synchronously, private ones and ordinary ones it couldn't
			// continue (DEV-1130). An engine built before that only lets the ledger's private
			// transfers count, which can lag one just started (DEV-966).
			unresumableCount: { [self] in runtime.lostOnQuitDownloadCount() ?? ledger.snapshot.lostOnQuitCount },
			snapshot: { [self] in ledger.snapshot },
			cancel: { [self] in try cancel($0) },
			cancelAll: { [self] in try runtime.cancelAllDownloads() },
			open: { [self] id in
				defer { publish() }

				let target = try ledger.fileForOpening(id)
				guard NSWorkspace.shared.open(target)
				else { throw BrowserDownloadsClient.Failure.couldNotOpen }
			},
			reveal: { [self] id in
				defer { publish() }

				let target = try ledger.fileForOpening(id)
				NSWorkspace.shared.activateFileViewerSelecting([target])
			},
			start: { [self] profileID, url in try await start(profileID, url: url) },
			removeHistory: { [self] ids in
				defer { publish() }
				let removed = try ledger.removeFinished(ids)

				// Chromium forgets them too, so they don't come back after a relaunch (DEV-892).
				for id in ids where ledger.records[id] == nil {
					runtime.removeDownload(profileKey: key(id.profileID), guid: id.guid)
				}
				return removed
			},
			setPaused: { [self] id, paused in try setPaused(id, paused: paused) },
			moveToTrash: { [self] id in
				defer { publish() }

				guard ledger.records[id]?.isPrivate == false
				else { throw BrowserDownloadsClient.Failure.missingDownload }

				// An engine that can't forget the transfer would keep an openable row for a trashed file.
				guard runtime.supportsDownloadControls
				else { throw BrowserDownloadsClient.Failure.unavailable }

				let target = try ledger.fileForOpening(id)
				do {
					try FileManager.default.trashItem(at: target, resultingItemURL: nil)
				} catch {
					throw BrowserDownloadsClient.Failure.couldNotTrash
				}

				// Only once Chromium forgot it too; otherwise the row stays, as missing, and can be removed later.
				guard runtime.removeDownload(profileKey: key(id.profileID), guid: id.guid) else {
					ledger.markMissing(id)
					return
				}
				forgotten.insert(id)
				_ = try ledger.removeFinished([id])
			},
			removeFromList: { [self] id in
				defer { publish() }

				guard runtime.supportsDownloadControls
				else { throw BrowserDownloadsClient.Failure.unavailable }
				guard let record = ledger.records[id], record.status != .inProgress, !record.isPrivate
				else { throw BrowserDownloadsClient.Failure.missingDownload }

				// Chromium forgets it first, so a removal it can't make yet isn't undone at the next launch.
				guard
					forgotten.contains(id)
					|| ledger.isKnownAbsentNatively(id)
					|| runtime.removeDownload(profileKey: key(id.profileID), guid: id.guid)
				else { throw BrowserDownloadsClient.Failure.notRemovable }
				forgotten.insert(id)
				_ = try ledger.removeFinished([id])
			}
		)
	}

	/// DEV-892: Pause and Resume, Chromium's own. Resume continues an interrupted transfer too,
	/// including one a quit interrupted, from the bytes on disk where the server allows it.
	private func setPaused(
		_ id: BrowserDownload.ID,
		paused: Bool
	) throws {
		guard let record = ledger.records[id]
		else { throw BrowserDownloadsClient.Failure.missingDownload }
		guard paused ? record.canPause : record.canResume
		else { throw BrowserDownloadsClient.Failure.notResumable }

		do {
			try runtime.setDownloadPaused(profileKey: key(id.profileID), guid: id.guid, paused: paused)
		} catch {
			throw BrowserDownloadsClient.Failure.notResumable
		}
	}

	/// Ordinary profiles of the current organization only; private browsing has its own keys.
	private func start(
		_ profileID: Profile.ID,
		url: URL
	) async throws -> BrowserDownload.ID {
		guard organization.profiles[id: profileID] != nil
		else { throw BrowserDownloadsClient.Failure.unavailable }

		do {
			// The profile may not be loaded yet (DEV-880).
			try await runtime.prepareProfile(profileID.chromiumProfile(legacy: legacyProfileID))
			let guid = try await runtime.startDownload(profileKey: key(profileID), url: url)
			return .init(profileID: profileID, guid: guid)
		} catch ChromiumDownloadStartFailure.failed {
			throw BrowserDownloadsClient.Failure.couldNotStart
		} catch ChromiumDownloadStartFailure.timedOut {
			throw BrowserDownloadsClient.Failure.startTimedOut
		} catch {
			throw BrowserDownloadsClient.Failure.unavailable
		}
	}

	private func updateOrganization(_ organization: BrowserOrganization) {
		self.organization = organization

		let locations = organization.tabLocations
		for tab in organization.tabs {
			let spaceID: Space.ID? = switch locations[tab.id] {
			case let .pinned(id, _), let .unpinned(id): id
			default: nil
			}

			if let name = spaceID.flatMap({ organization.spaces[id: $0] })?.name {
				knownTabSpaces[tab.id] = name
			}
		}
	}

	private func cancel(_ id: BrowserDownload.ID) throws {
		guard ledger.records[id]?.status == .inProgress
		else { throw BrowserDownloadsClient.Failure.missingDownload }

		try runtime.cancelDownload(profileKey: key(id.profileID), guid: id.guid)
	}

	private func receive(_ event: ChromiumDownloadEvent) {
		switch event {
		case let .initialized(key):
			guard let profileID = profileID(key) else { return }
			ledger.initialized(profileID: profileID)

		case let .changed(value):
			guard let profileID = profileID(value.profileKey)
			else { return }

			let tab = sourceTab(value.sourcePage)
			let status: BrowserDownload.Status = switch value.state {
			case .inProgress: .inProgress
			case .complete: .complete
			case .cancelled: .cancelled
			case .interrupted: .interrupted
			}
			let profileName = value.isPrivate
			? "Private"
			: organization.profiles[id: profileID]?.name ?? "Profile"
			let control = runtime.downloadControl(profileKey: value.profileKey, guid: value.guid) ?? []

			let download = BrowserDownload(
				id: .init(profileID: profileID, guid: value.guid),
				profileName: profileName,
				spaceName: value.isPrivate ? nil : tab.flatMap { knownTabSpaces[$0] },
				url: value.url,
				target: value.target,
				filename: value.filename,
				status: status,
				receivedBytes: value.receivedBytes,
				totalBytes: value.totalBytes,
				startedAt: value.startedAt,
				interruptReason: value.interruptReason,
				isDangerous: value.isDangerous,
				isMissing: value.isMissing,
				isPrivate: value.isPrivate,
				isPaused: control.contains(.paused),
				canResume: control.contains(.canResume),
				canPause: control.contains(.canPause),
				sourceTabID: tab
			)
			ledger.receive(download)
			publish()

			// After the queue, so a viewer that shows the transfer finds it there (DEV-1116).
			if let record = ledger.records[download.id], record.sourceTabID != nil {
				tabDownloadChanged(record)
			}
			return
		}

		publish()
	}

	private func key(_ id: Profile.ID) -> String {
		id.chromiumProfile(legacy: legacyProfileID)?.uuidString.lowercased() ?? ""
	}

	private func profileID(_ key: String) -> Profile.ID? {
		if key.isEmpty { return .chromium(nil, legacy: legacyProfileID) }
		return UUID(uuidString: key).map { .chromium($0, legacy: legacyProfileID) }
	}

	private func events() -> AsyncStream<DownloadQueue> {
		let token = UUID()
		let (stream, continuation) = AsyncStream<DownloadQueue>.makeStream(
			bufferingPolicy: .bufferingNewest(1)
		)
		observers[token] = continuation
		continuation.yield(ledger.snapshot)

		continuation.onTermination = { [weak self] _ in
			Task { @MainActor [weak self] in
				self?.observers[token] = nil
			}
		}

		return stream
	}

	private func publish() {
		let snapshot = ledger.snapshot
		for continuation in observers.values { continuation.yield(snapshot) }
	}
}
