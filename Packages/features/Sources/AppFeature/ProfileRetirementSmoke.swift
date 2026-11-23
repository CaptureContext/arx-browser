#if DEBUG
import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import Darwin
import Foundation
import MigrationAssistant
import MigrationAssistantFeature
import SettingsFeature
import _ComposableArchitecture

/// A separately requested, owned-root fixture. It never supplies a fake boot epoch.
internal struct ProfileRetirementSmoke: Sendable {
	internal enum Phase: String, Sendable {
		case queue, quarantine, sameBoot

		/// "Clear Arx data first" before an import (DEV-833), run on its own by
		/// `make migration-clear-smoke`: three profiles with a space and a tab each are cleared
		/// through the migration assistant, and a disposable Arx archive is imported.
		case clearForImport
	}

	internal static let argument: String = "--arx-retirement-smoke-root"
	internal static let phaseArgument: String = "--arx-retirement-smoke-phase"
	internal static let sentinel: String = "Arx profile retirement disposable fixture v1\n"
	internal let root: URL
	internal let profile: URL
	internal let application: URL
	internal let baseURL: URL
	internal let phase: Phase

	internal static let legacy: Profile.ID = .init(
		rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
	)
	internal static let ordinary: Profile.ID = .init(
		rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
	)
	internal static let survivor: Profile.ID = .init(
		rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
	)
	internal static let space: Space.ID = .init(
		rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
	)
	internal static let targetTabs: [BrowserCore.Tab.ID] = [5, 6].map {
		.init(rawValue: UUID(uuidString: "00000000-0000-4000-8000-00000000000\($0)")!)
	}
	internal static let survivorTab: BrowserCore.Tab.ID = .init(
		rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000007")!
	)

	/// The legacy and ordinary profiles' own spaces in `clearForImport`.
	internal static let targetSpaces: [Space.ID] = [8, 9].map {
		.init(rawValue: UUID(uuidString: "00000000-0000-4000-8000-00000000000\($0)")!)
	}

	/// The archive `clearForImport` imports: one profile, one space, one tab.
	internal static let importedProfile: Profile.ID = .init(
		rawValue: UUID(uuidString: "00000000-0000-4000-8000-00000000000a")!
	)
	internal static let importedSpace: Space.ID = .init(
		rawValue: UUID(uuidString: "00000000-0000-4000-8000-00000000000b")!
	)
	internal static let importedTab: BrowserCore.Tab.ID = .init(
		rawValue: UUID(uuidString: "00000000-0000-4000-8000-00000000000c")!
	)
	internal static let archiveName: String = "clear-for-import.arxtransfer"

	internal init(
		root: URL,
		profile: URL,
		application: URL,
		baseURL: URL,
		phase: Phase
	) {
		self.root = root
		self.profile = profile
		self.application = application
		self.baseURL = baseURL
		self.phase = phase
	}

	internal static func isRequested(
		environment: [String: String],
		arguments: [String]
	) -> Bool {
		environment["ARX_RETIREMENT_SMOKE_ROOT"] != nil || arguments.contains(argument)
	}

	internal static func load(
		environment: [String: String],
		arguments: [String],
		application: URL
	) throws -> Self? {
		guard isRequested(environment: environment, arguments: arguments) else { return nil }
		guard
			!RoutingSmokeFixture.isRequested(environment: environment, arguments: arguments),
			let rootPath = environment["ARX_RETIREMENT_SMOKE_ROOT"],
			let profilePath = environment["ARX_ENGINE_PROFILE"],
			let phaseName = environment["ARX_RETIREMENT_SMOKE_PHASE"],
			let phase = Phase(rawValue: phaseName),
			argumentValue(argument, in: arguments) == rootPath,
			argumentValue(phaseArgument, in: arguments) == phaseName,
			rootPath.hasPrefix("/"),
			profilePath.hasPrefix("/")
		else { throw Failure.invalidFixture }

		let root = URL(fileURLWithPath: rootPath).standardizedFileURL
		let profile = URL(fileURLWithPath: profilePath).standardizedFileURL
		guard
			root.lastPathComponent.hasPrefix("retirement-smoke-"),
			root.resolvingSymlinksInPath() == root,
			profile == root.appendingPathComponent("profile"),
			validDirectory(root),
			validDirectory(profile),
			try read(root.appendingPathComponent(".arx-retirement-smoke"), limit: 128) == Data(sentinel.utf8)
		else { throw Failure.invalidFixture }

		let bytes = try read(root.appendingPathComponent("fixture.json"), limit: 4096)
		let config = try JSONDecoder().decode(Configuration.self, from: bytes)
		guard
			config.version == 1,
			config.application.isFileURL,
			sameFile(config.application, application),
			config.baseURL.scheme == "http",
			config.baseURL.host == "127.0.0.1",
			config.baseURL.path == "/identity",
			config.baseURL.user == nil,
			config.baseURL.password == nil,
			config.baseURL.query == nil,
			config.baseURL.fragment == nil,
			let port = config.baseURL.port,
			(1...65535).contains(port)
		else { throw Failure.invalidFixture }

		if phase == .queue || phase == .clearForImport {
			guard try FileManager.default.contentsOfDirectory(atPath: profile.path).isEmpty
			else { throw Failure.invalidFixture }
		} else {
			let previous = phase == .quarantine ? "queue" : "quarantine"
			let prior = try read(root.appendingPathComponent("completion-\(previous).json"), limit: 4096)
			let completion = try JSONDecoder().decode(Completion.self, from: prior)
			guard
				completion.phase == previous,
				completion.status == "cleanExit",
				completion.pid > 1,
				sameFile(URL(fileURLWithPath: completion.application), application)
			else { throw Failure.invalidFixture }
		}
		return .init(
			root: root,
			profile: profile,
			application: application,
			baseURL: config.baseURL,
			phase: phase
		)
	}

	internal func seedWorkspace() throws {
		if phase == .clearForImport { return try seedClearForImport() }
		guard phase == .queue else { return }
		let targets = [Self.legacy, Self.ordinary]
		let targetTabs = targets.enumerated().map { index, profile in
			BrowserCore.Tab(
				id: Self.targetTabs[index],
				profileID: profile,
				savedDestination: .init(title: "Owned target", url: url(seed: index == 0 ? "legacy" : "ordinary")),
				restoration: .init(title: "Owned target", url: url(seed: index == 0 ? "legacy" : "ordinary"))
			)
		}
		let organization = BrowserOrganization(
			profiles: [
				.init(id: Self.legacy, name: "Retirement legacy fixture", favorites: [Self.targetTabs[0]]),
				.init(id: Self.ordinary, name: "Retirement ordinary fixture", favorites: [Self.targetTabs[1]]),
				.init(id: Self.survivor, name: "Retirement survivor fixture"),
			],
			legacyProfileID: Self.legacy,
			spaces: [
				.init(
					id: Self.space,
					profileID: Self.survivor,
					name: "Survivor",
					unpinnedTabs: [Self.survivorTab],
					selectedTabID: Self.survivorTab
				)
			],
			tabs: targetTabs + [
				.init(
					id: Self.survivorTab,
					profileID: Self.survivor,
					restoration: .init(title: "Survivor", url: baseURL)
				)
			]
		)
		try BrowserWorkspaceClient(file: profile.appendingPathComponent("arx-workspace.json")).save(
			organization
		)
	}

	@MainActor
	internal func run(
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient
	) async throws {
		defer {
			let snapshot = engine.snapshot(Self.survivorTab)
			let titleMatches = snapshot?.navigation.title == "survivor|survivor"
			print(
				"ARX_RETIREMENT_FIXTURE_STATE phase=\(phase.rawValue)"
				+ " available=\(store.settings.retirementAvailable)"
				+ " survivor=\(snapshot != nil)"
				+ " loading=\(snapshot?.navigation.isLoading == true)"
				+ " titleMatches=\(titleMatches)"
				+ " error=\(snapshot?.navigation.errorCode != nil)"
				+ " profiles=\(store.workspace.profiles.count)"
				+ " records=\(store.settings.profileRetirements.count)"
			)
			fflush(stdout)
		}

		if phase == .clearForImport { return try await runClearForImport(store: store, engine: engine) }
		try await wait {
			store.settings.retirementAvailable && engine.snapshot(Self.survivorTab)?.navigation.isLoading == false
		}
		if phase == .queue {
			try await engine.command(Self.survivorTab, .navigate(url(seed: "survivor")))
			try await wait { loaded(Self.survivorTab, title: "survivor|survivor", engine: engine) }
			try await engine.command(Self.survivorTab, .navigate(baseURL))
			try await wait {
				loaded(Self.survivorTab, title: "survivor|survivor", engine: engine)
					&& engine.snapshot(Self.survivorTab)?.navigation.url == baseURL
			}
			for (index, id) in [Self.legacy, Self.ordinary].enumerated() {
				guard let target = store.workspace.tabs[id: Self.targetTabs[index]]
				else { throw Failure.invalidReceipt }
				try await engine.open(target)
				let title = index == 0 ? "legacy|legacy" : "ordinary|ordinary"
				try await wait { loaded(target.id, title: title, engine: engine) }
				guard let name = store.workspace.profiles[id: id]?.name
				else { throw Failure.invalidReceipt }
				let editor = OrganizationEditor(
					kind: .removeProfile(id),
					name: name,
					eraseWebsiteData: true,
					eraseConfirmation: name
				)
				store.send(.settings(.ui(.editOrganization(editor))))
				store.send(.settings(.ui(.submitOrganizationEditor)))
				try await wait {
					!store.profileRetirement.isBusy
						&& store.profileRetirement.intents.contains { $0.profileID == id && $0.acknowledged }
				}
			}
		}
		try await wait { loaded(Self.survivorTab, title: "survivor|survivor", engine: engine) }
		let privateStore = try BrowserProfileRetirementStore(root: profile, legacyProfileID: Self.legacy)
		let consent = try privateStore.load()
		let snapshot = try await engine.profileRetirementSnapshot()
		let expected: ProfileRetirementRecord.State = phase == .queue ? .awaitingStartup : .restartRequired
		guard
			consent.count == 2,
			Set(consent.map(\.profileID)) == Set([Self.legacy, Self.ordinary]),
			consent.allSatisfy({ $0.acknowledged && snapshot.acknowledges($0.originalRequest) }),
			snapshot.records.filter({ $0.profileID == Self.legacy || $0.profileID == Self.ordinary }).allSatisfy({
				$0.state == expected
			}),
			store.workspace.profiles.map(\.id) == [Self.survivor],
			store.workspace.legacyProfileID == Self.legacy,
			store.settings.profileRetirements.count == 2,
			store.settings.profileRetirements.allSatisfy({
				$0.message != String.localized(.appUI.retirement.erased)
			})
		else { throw Failure.invalidReceipt }
		for id in [Self.legacy, Self.ordinary] {
			do {
				try await engine.prepareProfile(id)
				throw Failure.reopenedRetiredProfile
			} catch ProfileRetirementFailure.busy {}
		}
		try write(
			[
				"version": 1, "status": "passed", "phase": phase.rawValue,
				"pid": ProcessInfo.processInfo.processIdentifier, "application": application.path,
				"profile": profile.path, "requests": consent.map { $0.requestID.uuidString.lowercased() },
				"progress": phase == .queue ? "awaitingStartup" : "restartRequired",
				"survivorStorage": true, "retiredAdmissionDenied": true, "settingsDoesNotClaimErased": true,
			],
			to: "result-\(phase.rawValue).json"
		)
		print("ARX_RETIREMENT_\(phase.rawValue.uppercased())_SMOKE_SUCCESS")
		fflush(stdout)
	}

	/// Three profiles, each with a space and a tab, and a disposable archive to import.
	private func seedClearForImport() throws {
		let owners = [Self.legacy, Self.ordinary, Self.survivor]
		let spaces = Self.targetSpaces + [Self.space]
		let tabs = Self.targetTabs + [Self.survivorTab]
		let seeds = ["legacy", "ordinary", "survivor"]
		let organization = BrowserOrganization(
			profiles: [
				.init(id: Self.legacy, name: "Clear legacy fixture"),
				.init(id: Self.ordinary, name: "Clear ordinary fixture"),
				.init(id: Self.survivor, name: "Clear third fixture"),
			],
			legacyProfileID: Self.legacy,
			spaces: owners.indices.map { index in
				Space(
					id: spaces[index],
					profileID: owners[index],
					name: "Clear \(seeds[index])",
					unpinnedTabs: [tabs[index]],
					selectedTabID: tabs[index]
				)
			},
			tabs: owners.indices.map { index in
				BrowserCore.Tab(
					id: tabs[index],
					profileID: owners[index],
					restoration: .init(title: "Clear \(seeds[index])", url: url(seed: seeds[index]))
				)
			}
		)
		try BrowserWorkspaceClient(file: profile.appendingPathComponent("arx-workspace.json")).save(organization)

		let imported = BrowserOrganization(
			profiles: [.init(id: Self.importedProfile, name: "Imported fixture")],
			spaces: [
				.init(
					id: Self.importedSpace,
					profileID: Self.importedProfile,
					name: "Imported",
					unpinnedTabs: [Self.importedTab],
					selectedTabID: Self.importedTab
				)
			],
			tabs: [
				.init(
					id: Self.importedTab,
					profileID: Self.importedProfile,
					restoration: .init(title: "Imported", url: url(seed: "imported"))
				)
			]
		)
		let archive = ArxTransferArchive(
			organization: imported,
			preferences: BrowserPreferences(),
			createdAt: Date(timeIntervalSince1970: 1_800_000_000),
			appVersion: nil
		)
		try write(try archive.encoded(), to: Self.archiveName)
	}

	/// Opens Import, picks the archive, turns on "Clear Arx data first", confirms, imports, and
	/// checks that only the fresh profile and what the archive brought are left, with every
	/// old profile's retirement acknowledged and nothing erased yet.
	@MainActor
	private func runClearForImport(
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient
	) async throws {
		let old: Set<Profile.ID> = [Self.legacy, Self.ordinary, Self.survivor]
		func assistant() -> MigrationAssistantFeature.State? {
			store.onboarding?.page.migration?.migration
		}
		func send(_ action: MigrationAssistantFeature.Action) {
			store.send(.onboarding(.page(.migration(.migration(action)))))
		}

		try await wait { store.settings.retirementAvailable && store.workspace.profiles.count == 3 }
		store.send(.ui(.openImport))
		try await wait { assistant() != nil }
		if assistant()?.phase == .idle { send(.ui(.task)) }
		try await wait { assistant()?.phase == .selecting }
		guard
			let existing = assistant()?.existingData,
			existing.profileNames.count == 3,
			existing.spaceCount == 3,
			existing.tabCount == 3
		else { throw Failure.invalidReceipt }

		send(.ui(.fileChosen(root.appendingPathComponent(Self.archiveName))))
		try await wait { assistant()?.selectedSource?.kind == .arxArchive }
		send(.ui(.setClearsExistingData(true)))
		send(.ui(.inspect))
		try await wait { assistant()?.phase == .confirmingClear }
		send(.ui(.confirmClear))

		// Clearing and the review that follows it; a failure sends the assistant back to selecting.
		try await wait {
			assistant()?.phase == .previewing || assistant()?.problem == .clearFailed
		}
		guard assistant()?.phase == .previewing else { throw Failure.invalidReceipt }

		send(.ui(.startImport))
		try await wait { assistant()?.phase == .finished }
		guard
			assistant()?.report?.outcome == .completed,
			store.workspace.profiles.allSatisfy({ !old.contains($0.id) }),
			old.isSubset(of: store.workspace.retiredProfileIDs),
			store.workspace.spaces.allSatisfy({ !Self.targetSpaces.contains($0.id) && $0.id != Self.space }),
			store.workspace.tabs.contains(where: { $0.restoration.url == url(seed: "imported") }),
			store.workspace.profiles.contains(where: { $0.name == ProvisionalProfile.name }),
			!store.profileRetirement.isBusy,
			store.migrationClearing == nil
		else { throw Failure.invalidReceipt }

		let privateStore = try BrowserProfileRetirementStore(root: profile, legacyProfileID: Self.legacy)
		let consent = try privateStore.load()
		let snapshot = try await engine.profileRetirementSnapshot()
		guard
			Set(consent.map(\.profileID)) == old,
			consent.allSatisfy({ $0.acknowledged && snapshot.acknowledges($0.originalRequest) }),
			snapshot.records.filter({ old.contains($0.profileID) }).allSatisfy({ $0.state == .awaitingStartup })
		else { throw Failure.invalidReceipt }

		try write(
			[
				"version": 1, "status": "passed", "phase": phase.rawValue,
				"pid": ProcessInfo.processInfo.processIdentifier, "application": application.path,
				"profile": profile.path, "requests": consent.map { $0.requestID.uuidString.lowercased() },
				"progress": "awaitingStartup", "importCompleted": true,
				"profiles": store.workspace.profiles.map { $0.id.rawValue.uuidString.lowercased() },
			],
			to: "result-\(phase.rawValue).json"
		)
		print("ARX_RETIREMENT_\(phase.rawValue.uppercased())_SMOKE_SUCCESS")
		fflush(stdout)
	}

	internal func recordCleanExit() throws {
		try write(
			[
				"status": "cleanExit", "phase": phase.rawValue,
				"pid": ProcessInfo.processInfo.processIdentifier, "application": application.path,
			],
			to: "completion-\(phase.rawValue).json"
		)
	}

	private func url(seed: String) -> URL {
		baseURL.appending(queryItems: [.init(name: "seed", value: seed)])
	}

	@MainActor
	private func loaded(
		_ id: BrowserCore.Tab.ID,
		title: String,
		engine: BrowserEngineClient
	) -> Bool {
		guard let navigation = engine.snapshot(id)?.navigation else { return false }
		return !navigation.isLoading && navigation.errorCode == nil && navigation.title == title
	}

	@MainActor
	private func wait(until ready: () -> Bool) async throws {
		for _ in 0..<300 {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(100))
		}
		throw Failure.timedOut
	}

	private func write(
		_ value: [String: Any],
		to name: String
	) throws {
		try write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), to: name)
	}

	private func write(
		_ data: Data,
		to name: String
	) throws {
		let descriptor = open(
			root.appendingPathComponent(name).path,
			O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
			0o600
		)
		guard descriptor >= 0 else { throw Failure.resultExists }
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		try handle.write(contentsOf: data)
		guard fsync(descriptor) == 0 else { throw Failure.invalidReceipt }
		try handle.close()
	}

	private static func argumentValue(
		_ name: String,
		in arguments: [String]
	) -> String? {
		guard
			arguments.filter({ $0 == name }).count == 1,
			let index = arguments.firstIndex(of: name),
			arguments.indices.contains(index + 1)
		else { return nil }
		return arguments[index + 1]
	}

	private static func read(
		_ url: URL,
		limit: Int
	) throws -> Data {
		let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
		guard descriptor >= 0 else { throw Failure.invalidFixture }
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		var info = stat()
		guard
			fstat(descriptor, &info) == 0,
			info.st_uid == getuid(),
			info.st_nlink == 1,
			info.st_mode & S_IFMT == S_IFREG,
			info.st_mode & 0o777 == 0o600,
			(1...limit).contains(Int(info.st_size)),
			let bytes = try handle.read(upToCount: limit + 1),
			bytes.count <= limit
		else { throw Failure.invalidFixture }
		try handle.close()
		return bytes
	}

	private static func validDirectory(_ url: URL) -> Bool {
		var info = stat()
		return lstat(url.path, &info) == 0 && info.st_uid == getuid()
			&& info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o777 == 0o700
	}

	private static func sameFile(
		_ first: URL,
		_ second: URL
	) -> Bool {
		var lhs = stat()
		var rhs = stat()
		return stat(first.path, &lhs) == 0 && stat(second.path, &rhs) == 0
			&& lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
	}

	private struct Configuration: Decodable {
		internal let version: Int
		internal let application: URL
		internal let baseURL: URL

		internal init(
			version: Int,
			application: URL,
			baseURL: URL
		) {
			self.version = version
			self.application = application
			self.baseURL = baseURL
		}
	}

	private struct Completion: Decodable {
		internal let phase: String
		internal let status: String
		internal let pid: Int32
		internal let application: String

		internal init(
			phase: String,
			status: String,
			pid: Int32,
			application: String
		) {
			self.phase = phase
			self.status = status
			self.pid = pid
			self.application = application
		}
	}

	internal enum Failure: Error {
		case invalidFixture, invalidReceipt, reopenedRetiredProfile, timedOut, resultExists
	}

}
#endif
