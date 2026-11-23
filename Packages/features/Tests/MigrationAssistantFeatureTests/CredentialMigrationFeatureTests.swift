import BrowserCore
import BrowserEngineClient
import Foundation
import MigrationAssistant
import Testing
import _ComposableArchitecture
import _TestSupport
@testable import MigrationAssistantFeature

/// Passwords and sign-ins as a kind of data in Customize that follows the profile mapping
/// (DEV-650, DEV-842), with every Keychain, presence and engine call replaced. Nothing here
/// reads a real Keychain item or profile.
@Suite(.dependencies)
@MainActor
internal struct CredentialMigrationFeatureTests {
	private let sourceID: MigrationSource.ID = .init(rawValue: "chrome")
	private let workProfile: Profile = .init(id: .init(rawValue: UUID(1)), name: "Work")
	private let homeProfile: Profile = .init(id: .init(rawValue: UUID(5)), name: "Home Life")
	private let workSession: UUID = .init(2)
	private let homeSession: UUID = .init(6)
	private let workBatch: UUID = .init(3)
	private let homeBatch: UUID = .init(7)

	private var source: CredentialSource {
		.init(
			sourceID: sourceID,
			browserName: "Google Chrome",
			keychainService: "Chrome Safe Storage",
			isKeychainItemVerified: true,
			profiles: [.init(id: "Default", name: "Work"), .init(id: "Profile 1", name: "Home")]
		)
	}

	private var mapped: [MigrationSourceProfile] {
		[.init(id: "Default", name: "Work"), .init(id: "Profile 1", name: "Home")]
	}

	private func inventory(_ profile: String) -> CredentialInventory {
		.init(
			sessionID: profile == "Default" ? workSession : homeSession,
			sourceID: sourceID,
			sourceProfileID: profile,
			passwordCount: 3,
			sites: [
				.init(host: "example.test", passwordCount: 2, cookieCount: 2),
				.init(host: "google.com", cookieCount: 4),
				.init(host: "session.test", sessionOnlyCookieCount: 1),
			]
		)
	}

	private func report(_ batch: UUID) -> CredentialReport {
		.init(
			batchID: batch,
			passwords: .init(imported: 3),
			sites: [.init(host: "google.com", result: .kept)]
		)
	}

	private var destination: MigrationDestination {
		.init(profileID: workProfile.id, spaceID: .init(rawValue: UUID(4)))
	}

	private var targets: IdentifiedArrayOf<CredentialMigrationFeature.Target> {
		[
			.init(id: "Default", sourceName: "Work", profileID: workProfile.id, profileName: "Work"),
			.init(id: "Profile 1", sourceName: "Home", profileID: homeProfile.id, profileName: "Home Life"),
		]
	}

	/// The kind as Customize leaves it once the user pressed Import.
	private var configured: CredentialMigrationFeature.State {
		.init(
			sourceID: sourceID,
			sourceName: "Google Chrome",
			mappedProfiles: mapped,
			phase: .configuring,
			source: source,
			canWrite: true,
			mode: .direct
		)
	}

	private final class Calls: @unchecked Sendable {
		private let lock: NSLock = .init()
		private var _reads: [[String]] = []
		private var _presence: [String] = []
		private var _migrations: [(CredentialSelection, Profile.ID)] = []
		private var _discarded: [UUID] = []
		private var _undone: [UUID] = []
		private var _discardedAll: Int = 0

		internal var reads: [[String]] { lock.withLock { _reads } }
		internal var presence: [String] { lock.withLock { _presence } }
		internal var migrations: [(CredentialSelection, Profile.ID)] { lock.withLock { _migrations } }
		internal var discarded: [UUID] { lock.withLock { _discarded } }
		internal var undone: [UUID] { lock.withLock { _undone } }
		internal var discardedAll: Int { lock.withLock { _discardedAll } }

		internal func read(_ profiles: [String]) { lock.withLock { _reads.append(profiles) } }
		internal func confirm(_ reason: String) { lock.withLock { _presence.append(reason) } }
		internal func migrate(
			_ selection: CredentialSelection,
			_ profile: Profile.ID
		) {
			lock.withLock { _migrations.append((selection, profile)) }
		}
		internal func discard(_ id: UUID) { lock.withLock { _discarded.append(id) } }
		internal func undo(_ id: UUID) { lock.withLock { _undone.append(id) } }
		internal func discardAll() { lock.withLock { _discardedAll += 1 } }
	}

	private func client(
		_ calls: Calls,
		source: CredentialSource?,
		canWrite: Bool = true,
		isForeground: Bool = true,
		presence: Bool = true,
		failure: CredentialMigrationFailure? = nil
	) -> CredentialMigrationClient {
		let inventories = ["Default": inventory("Default"), "Profile 1": inventory("Profile 1")]
		let workSession = self.workSession
		let workReport = report(workBatch)
		let homeReport = report(homeBatch)
		return .init(
			source: { _ in source },
			canWrite: { canWrite },
			isForeground: { isForeground },
			confirmPresence: { reason in
				calls.confirm(reason)
				return presence
			},
			readProfiles: { _, profiles in
				calls.read(profiles)
				if let failure { throw failure }
				return profiles.compactMap { inventories[$0] }
			},
			migrate: { session, selection, profile in
				calls.migrate(selection, profile)
				return session == workSession ? workReport : homeReport
			},
			undo: { calls.undo($0) },
			discard: { calls.discard($0) },
			discardAll: { calls.discardAll() }
		)
	}

	/// Default went into Work, Profile 1 into the new Home Life profile.
	private func receivingProfile() -> @Sendable (String, MigrationDestination) async -> Profile? {
		let work = workProfile
		let home = homeProfile
		return { id, _ in
			switch id {
			case "Default": work
			case "Profile 1": home
			default: nil
			}
		}
	}

	// MARK: - Loading

	@Test(arguments: [
		(true, true, false, CredentialMigrationFeature.Mode.direct),
		(true, false, false, .csv(.engineNotReady)),
		(false, true, false, .csv(.unsupported)),
		(false, true, true, .csv(.passwordsApp)),
		// Safari's sign-ins are read directly when its cookies are there (DEV-896).
		(true, true, true, .direct),
	])
	internal func loadingSaysHowPasswordsWillMove(
		hasSource: Bool,
		canWrite: Bool,
		isSafari: Bool,
		mode: CredentialMigrationFeature.Mode
	) async {
		let calls: Calls = .init()
		let sourceID: MigrationSource.ID = isSafari ? .safari : self.sourceID
		let source = hasSource ? self.source : nil
		let store = TestStore(initialState: .init(sourceID: sourceID, sourceName: "Browser")) {
			CredentialMigrationFeature()
		} withDependencies: {
			$0.credentialMigration = client(calls, source: source, canWrite: canWrite)
		}

		await store.send(.load)
		await store.receive(\.event.loaded) {
			$0.phase = .configuring
			$0.source = source
			$0.canWrite = canWrite
			$0.mode = mode
		}

		// Nothing is read while the user reviews.
		#expect(calls.reads.isEmpty)
		#expect(calls.presence.isEmpty)
		#expect(store.state.isReady == (mode == .direct))
		#expect(!store.state.isRunning)
	}

	// MARK: - Direct

	@Test
	internal func theWholeStepFollowsTheMappingWithOneKeychainRead() async {
		let calls: Calls = .init()
		let store = TestStore(initialState: configured) {
			CredentialMigrationFeature()
		} withDependencies: {
			$0.credentialMigration = client(calls, source: source)
			$0.migrationAssistant.receivingProfile = receivingProfile()
		}

		await store.send(.start(destination)) { $0.phase = .resolving }
		await store.receive(\.event.resolved) {
			$0.phase = .intro
			$0.targets = self.targets
		}
		#expect(store.state.isRunning)
		// Nothing is read until the user continues past the explanation.
		#expect(calls.reads.isEmpty)

		await store.send(.ui(.continue)) { $0.phase = .reading }
		await store.receive(\.event.read) {
			$0.phase = .choosing
			$0.inventories = [
				.init(
					inventory: self.inventory("Default"),
					selection: .init(passwords: true, signInHosts: ["example.test", "google.com"])
				),
				.init(
					inventory: self.inventory("Profile 1"),
					selection: .init(passwords: true, signInHosts: ["example.test", "google.com"])
				),
			]
		}
		#expect(calls.presence.count == 1)
		#expect(calls.reads == [["Default", "Profile 1"]])

		// Choices are per profile. A session-only site can't be selected.
		await store.send(.ui(.toggleSite("Profile 1", host: "session.test")))
		await store.send(.ui(.toggleSite("Profile 1", host: "example.test"))) {
			$0.inventories[id: "Profile 1"]?.selection.signInHosts = ["google.com"]
		}
		await store.send(.ui(.setAllSites("Default", false))) {
			$0.inventories[id: "Default"]?.selection.signInHosts = []
		}
		await store.send(.ui(.startImport)) { $0.phase = .importing }
		await store.receive(\.event.migrated) {
			$0.phase = .finished
			$0.inventories = []
			$0.reports = [
				.init(id: "Default", report: self.report(self.workBatch)),
				.init(id: "Profile 1", report: self.report(self.homeBatch)),
			]
		}

		// Each source profile's records went into the Arx profile that got its tabs.
		#expect(calls.migrations.map(\.1) == [workProfile.id, homeProfile.id])
		#expect(calls.migrations.map(\.0) == [
			.init(passwords: true, signInHosts: []),
			.init(passwords: true, signInHosts: ["google.com"]),
		])

		// Undo takes back every profile's batch.
		await store.send(.ui(.undo)) { $0.phase = .undoing }
		await store.receive(\.event.undone) {
			$0.phase = .undone
			$0.reports = []
		}
		#expect(calls.undone == [workBatch, homeBatch])

		await store.send(.ui(.close))
		await store.receive(\.delegate.closed)

		// Written records aren't discarded: their sessions already ended.
		#expect(calls.discarded.isEmpty)
	}

	@Test
	internal func aProfileWithoutAnArxProfileIsntRead() async {
		let calls: Calls = .init()
		let work = workProfile
		let store = TestStore(initialState: configured) {
			CredentialMigrationFeature()
		} withDependencies: {
			$0.credentialMigration = client(calls, source: source)
			$0.migrationAssistant.receivingProfile = { id, _ in id == "Default" ? work : nil }
		}

		await store.send(.start(destination)) { $0.phase = .resolving }
		await store.receive(\.event.resolved) {
			$0.phase = .intro
			$0.targets = [
				.init(id: "Default", sourceName: "Work", profileID: self.workProfile.id, profileName: "Work"),
				.init(id: "Profile 1", sourceName: "Home", profileID: nil, profileName: ""),
			]
		}
		await store.send(.ui(.continue)) { $0.phase = .reading }
		await store.receive(\.event.read) {
			$0.phase = .choosing
			$0.inventories = [.init(inventory: self.inventory("Default"), selection: .all(in: self.inventory("Default")))]
		}
		#expect(calls.reads == [["Default"]])
	}

	@Test(arguments: [
		(CredentialMigrationFailure.keyDenied, CredentialMigrationFeature.CSVReason.denied),
		(.keyMissing, .missing),
		(.writerUnavailable, .engineNotReady),
		(.primaryPassword, .primaryPassword),
	])
	internal func aKeyThatCantBeReadLeadsToCSV(
		failure: CredentialMigrationFailure,
		reason: CredentialMigrationFeature.CSVReason
	) async {
		let calls: Calls = .init()
		var state = configured
		state.phase = .intro
		state.targets = targets
		let store = TestStore(initialState: state) {
			CredentialMigrationFeature()
		} withDependencies: {
			$0.credentialMigration = client(calls, source: source, failure: failure)
		}

		await store.send(.ui(.continue)) { $0.phase = .reading }
		await store.receive(\.event.read) {
			$0.mode = .csv(reason)
			$0.phase = .csv(reason)
		}
		#expect(store.state.canAttachCSV)
	}

	@Test
	internal func itRunsOnlyInTheForegroundAndAfterPresence() async {
		let calls: Calls = .init()
		var state = configured
		state.phase = .intro
		state.targets = targets

		let background = TestStore(initialState: state) {
			CredentialMigrationFeature()
		} withDependencies: {
			$0.credentialMigration = client(calls, source: source, isForeground: false)
		}
		await background.send(.ui(.continue)) { $0.phase = .reading }
		await background.receive(\.event.read) {
			$0.phase = .intro
			$0.problem = .notForeground
		}
		#expect(calls.presence.isEmpty)

		let denied = TestStore(initialState: state) {
			CredentialMigrationFeature()
		} withDependencies: {
			$0.credentialMigration = client(calls, source: source, presence: false)
		}
		await denied.send(.ui(.continue)) { $0.phase = .reading }
		await denied.receive(\.event.read) {
			$0.phase = .intro
			$0.problem = .presenceDenied
		}
		#expect(calls.presence.count == 1)
		#expect(calls.reads.isEmpty)
	}

	@Test
	internal func losingFocusDuringAuthenticationStopsBeforeTheKeychain() async {
		let calls: Calls = .init()
		let checks = LockIsolated(0)
		var state = configured
		state.phase = .intro
		state.targets = targets
		var credentials = client(calls, source: source)
		credentials.isForeground = {
			checks.withValue { $0 += 1 }
			return checks.value == 1
		}
		let store = TestStore(initialState: state) {
			CredentialMigrationFeature()
		} withDependencies: { [credentials] in
			$0.credentialMigration = credentials
		}

		await store.send(.ui(.continue)) { $0.phase = .reading }
		await store.receive(\.event.read) {
			$0.phase = .intro
			$0.problem = .notForeground
		}
		#expect(calls.presence.count == 1)
		#expect(calls.reads.isEmpty)
		#expect(checks.value == 2)
	}

	@Test
	internal func closingBeforeWritingDropsEveryProfilesRecords() async {
		let calls: Calls = .init()
		var state = configured
		state.phase = .choosing
		state.targets = targets
		state.inventories = [
			.init(inventory: inventory("Default"), selection: .all(in: inventory("Default"))),
			.init(inventory: inventory("Profile 1"), selection: .all(in: inventory("Profile 1"))),
		]
		let store = TestStore(initialState: state) {
			CredentialMigrationFeature()
		} withDependencies: {
			$0.credentialMigration = client(calls, source: source)
		}

		await store.send(.ui(.close)) { $0.inventories = [] }
		await store.receive(\.delegate.closed)
		#expect(calls.discarded == [workSession, homeSession])
	}

	@Test
	internal func anUnselectedProfileIsDroppedNotWritten() async {
		let calls: Calls = .init()
		var state = configured
		state.phase = .choosing
		state.targets = targets
		state.inventories = [
			.init(inventory: inventory("Default"), selection: .init(passwords: false, signInHosts: [])),
			.init(inventory: inventory("Profile 1"), selection: .all(in: inventory("Profile 1"))),
		]
		let store = TestStore(initialState: state) {
			CredentialMigrationFeature()
		} withDependencies: {
			$0.credentialMigration = client(calls, source: source)
		}

		await store.send(.ui(.startImport)) { $0.phase = .importing }
		await store.receive(\.event.migrated) {
			$0.phase = .finished
			$0.inventories = []
			$0.reports = [.init(id: "Profile 1", report: self.report(self.homeBatch))]
		}
		#expect(calls.discarded == [workSession])
		#expect(calls.migrations.map(\.1) == [homeProfile.id])
	}

	@Test
	internal func aFailedUndoRetriesOnlyTheBatchesStillThere() async {
		let calls: Calls = .init()
		let attempts = LockIsolated(0)
		var state = configured
		state.phase = .finished
		state.targets = targets
		state.reports = [
			.init(id: "Default", report: report(workBatch)),
			.init(id: "Profile 1", report: report(homeBatch)),
		]
		var credentials = client(calls, source: source)
		let homeBatch = self.homeBatch
		credentials.undo = { batch in

			// Home's undo fails the first time only.
			if batch == homeBatch, attempts.withValue({ $0 += 1; return $0 }) == 1 {
				throw CredentialMigrationFailure.writeFailed
			}
			calls.undo(batch)
		}
		let store = TestStore(initialState: state) {
			CredentialMigrationFeature()
		} withDependencies: { [credentials] in
			$0.credentialMigration = credentials
		}

		await store.send(.ui(.undo)) { $0.phase = .undoing }
		await store.receive(\.event.undone) {
			$0.phase = .finished
			$0.problem = .undoFailed
			$0.reports = [.init(id: "Profile 1", report: self.report(self.homeBatch))]
		}
		await store.send(.ui(.undo)) {
			$0.phase = .undoing
			$0.problem = nil
		}
		await store.receive(\.event.undone) {
			$0.phase = .undone
			$0.reports = []
		}
		#expect(calls.undone == [workBatch, homeBatch])
	}

	@Test
	internal func aReadThatLandsLateDropsItsRecords() async {
		let calls: Calls = .init()
		var state = configured
		state.phase = .intro
		let store = TestStore(initialState: state) {
			CredentialMigrationFeature()
		} withDependencies: {
			$0.credentialMigration = client(calls, source: source)
		}

		await store.send(.event(.read(.success([inventory("Default"), inventory("Profile 1")]))))
		await store.finish()
		#expect(calls.discarded == [workSession, homeSession])
	}

	// MARK: - CSV

	@Test
	internal func eachCSVGoesIntoTheArxProfileOfItsSourceProfile() async {
		let imported = LockIsolated<[(Profile.ID, URL)]>([])
		let home = URL(fileURLWithPath: "/tmp/dev842-home.csv")
		var state = configured
		state.mode = .csv(.engineNotReady)
		state.canWrite = false
		let store = TestStore(initialState: state) {
			CredentialMigrationFeature()
		} withDependencies: {
			$0.migrationAssistant.receivingProfile = receivingProfile()
			$0.browserEngine.importPasswords = { profile, url throws(BrowserSavedPasswordFailure) in
				imported.withValue { $0.append((profile, url)) }
				return .init(imported: 5, conflictCount: 1, skippedCount: 2)
			}
		}

		// Customize can't import until a file is attached, and only to a mapped profile.
		#expect(!store.state.isReady)
		await store.send(.ui(.csvChosen("Elsewhere", home)))
		await store.send(.ui(.csvChosen("Profile 1", home))) { $0.csvFiles = ["Profile 1": home] }
		#expect(store.state.isReady)
		// Choosing a file reads nothing: it goes in after the ordinary import.
		#expect(imported.value.isEmpty)

		await store.send(.start(destination)) { $0.phase = .resolving }
		await store.receive(\.event.resolved) {
			$0.targets = self.targets
			$0.phase = .importingCSV
		}
		await store.receive(\.event.csvImported) {
			$0.phase = .csvFinished
			$0.csvResults = [.init(id: "Profile 1", result: .success(.init(imported: 5, conflicts: 1, skipped: 2)))]
			$0.csvFiles = [:]
		}
		#expect(imported.value.map(\.0) == [homeProfile.id])
		#expect(imported.value.map(\.1) == [home])
	}

	@Test
	internal func aBadCSVIsReportedForItsProfile() async {
		var state = configured
		state.phase = .csv(.denied)
		state.mode = .csv(.denied)
		state.targets = targets
		let store = TestStore(initialState: state) {
			CredentialMigrationFeature()
		} withDependencies: {
			$0.browserEngine.importPasswords = { profile, _ throws(BrowserSavedPasswordFailure) in
				if profile == self.workProfile.id { throw .badFormat }
				return .init(imported: 1, conflictCount: 0, skippedCount: 0)
			}
		}

		let work = URL(fileURLWithPath: "/tmp/dev842-work.csv")
		let home = URL(fileURLWithPath: "/tmp/dev842-home.csv")
		#expect(!store.state.canImportCSV)
		await store.send(.ui(.csvChosen("Default", work))) { $0.csvFiles = ["Default": work] }
		await store.send(.ui(.csvChosen("Profile 1", home))) { $0.csvFiles["Profile 1"] = home }
		await store.send(.ui(.removeCSV("Profile 1"))) { $0.csvFiles["Profile 1"] = nil }
		await store.send(.ui(.csvChosen("Profile 1", home))) { $0.csvFiles["Profile 1"] = home }
		await store.send(.ui(.importCSV)) { $0.phase = .importingCSV }

		// The good file is done; the bad one stays, to try again or replace.
		await store.receive(\.event.csvImported) {
			$0.phase = .csv(.denied)
			$0.csvFiles = ["Default": work]
			$0.csvResults = [
				.init(id: "Default", result: .failure(.badFormat)),
				.init(id: "Profile 1", result: .success(.init(imported: 1, conflicts: 0, skipped: 0))),
			]
		}
		#expect(store.state.canImportCSV)
		// A profile whose file went in takes no other.
		await store.send(.ui(.csvChosen("Profile 1", work)))

		let fixed = URL(fileURLWithPath: "/tmp/dev842-work-fixed.csv")
		await store.send(.ui(.removeCSV("Default"))) { $0.csvFiles = [:] }
		await store.send(.ui(.csvChosen("Default", fixed))) { $0.csvFiles = ["Default": fixed] }
		store.dependencies.browserEngine.importPasswords = { _, _ throws(BrowserSavedPasswordFailure) in
			.init(imported: 4, conflictCount: 0, skippedCount: 0)
		}
		await store.send(.ui(.importCSV)) { $0.phase = .importingCSV }
		await store.receive(\.event.csvImported) {
			$0.phase = .csvFinished
			$0.csvFiles = [:]
			$0.csvResults[id: "Default"] = .init(id: "Default", result: .success(.init(imported: 4, conflicts: 0, skipped: 0)))
		}
	}

	@Test
	internal func csvCanBeChosenOverTheKeychainAndBack() async {
		let file = URL(fileURLWithPath: "/tmp/dev842.csv")
		let store = TestStore(initialState: configured) {
			CredentialMigrationFeature()
		}

		await store.send(.ui(.useCSV)) { $0.mode = .csv(.chosen) }
		await store.send(.ui(.csvChosen("Default", file))) { $0.csvFiles = ["Default": file] }
		await store.send(.ui(.useDirect)) {
			$0.mode = .direct
			$0.csvFiles = [:]
		}
	}

	@Test
	internal func safariWithoutAMappingTakesOneFileForTheWholeSource() async {
		let file = URL(fileURLWithPath: "/tmp/dev842-safari.csv")
		let imported = LockIsolated<[Profile.ID]>([])
		let work = workProfile
		let state = CredentialMigrationFeature.State(
			sourceID: .safari,
			sourceName: "Safari",
			phase: .configuring,
			mode: .csv(.passwordsApp)
		)
		let store = TestStore(initialState: state) {
			CredentialMigrationFeature()
		} withDependencies: {
			$0.migrationAssistant.receivingProfile = { _, _ in work }
			$0.browserEngine.importPasswords = { profile, _ throws(BrowserSavedPasswordFailure) in
				imported.withValue { $0.append(profile) }
				return .init(imported: 2, conflictCount: 0, skippedCount: 0)
			}
		}

		#expect(store.state.sourceProfiles.map(\.name) == ["Safari"])
		let whole = CredentialMigrationFeature.State.wholeSource
		await store.send(.ui(.csvChosen(whole, file))) { $0.csvFiles = [whole: file] }
		await store.send(.start(destination)) { $0.phase = .resolving }
		await store.receive(\.event.resolved) {
			$0.targets = [.init(id: whole, sourceName: "Safari", profileID: self.workProfile.id, profileName: "Work")]
			$0.phase = .importingCSV
		}
		await store.receive(\.event.csvImported) {
			$0.phase = .csvFinished
			$0.csvResults = [.init(id: whole, result: .success(.init(imported: 2, conflicts: 0, skipped: 0)))]
			$0.csvFiles = [:]
		}
		#expect(imported.value == [workProfile.id])
	}

	/// Firefox with passwords but no bookmarks or open tabs has no profiles to map, under
	/// the new-profile default. Its one file goes where the import puts items without a
	/// profile, the destination's profile, so it can be imported (DEV-844).
	@Test
	internal func aSourceWithoutProfilesImportsItsFileIntoTheDestinationsProfile() async {
		let file = URL(fileURLWithPath: "/tmp/dev844-firefox.csv")
		let imported = LockIsolated<[Profile.ID]>([])
		var target = destination
		target.defaultRoute = .newProfile
		let work = workProfile
		let organization = BrowserOrganization(
			profiles: [work],
			spaces: [.init(id: target.spaceID, profileID: work.id, name: "Home")]
		)
		let state = CredentialMigrationFeature.State(
			sourceID: .init(rawValue: "firefox"),
			sourceName: "Firefox",
			phase: .configuring,
			mode: .csv(.chosen)
		)
		let store = TestStore(initialState: state) {
			CredentialMigrationFeature()
		} withDependencies: {
			$0.migrationAssistant.receivingProfile = { id, destination in
				organization.receivingProfile(forSourceProfile: id, destination: destination, ledger: .init())
			}
			$0.browserEngine.importPasswords = { profile, _ throws(BrowserSavedPasswordFailure) in
				imported.withValue { $0.append(profile) }
				return .init(imported: 3, conflictCount: 0, skippedCount: 0)
			}
		}

		let whole = CredentialMigrationFeature.State.wholeSource
		await store.send(.ui(.csvChosen(whole, file))) { $0.csvFiles = [whole: file] }
		await store.send(.start(target)) { $0.phase = .resolving }
		await store.receive(\.event.resolved) {
			$0.targets = [.init(id: whole, sourceName: "Firefox", profileID: work.id, profileName: "Work")]
			$0.phase = .importingCSV
		}
		await store.receive(\.event.csvImported) {
			$0.phase = .csvFinished
			$0.csvResults = [.init(id: whole, result: .success(.init(imported: 3, conflicts: 0, skipped: 0)))]
			$0.csvFiles = [:]
		}
		#expect(imported.value == [work.id])
	}

	// MARK: - In the assistant

	private func assistant(
		kind: MigrationSource.Kind,
		preservesOrganization: Bool = false
	) -> MigrationAssistantFeature.State {
		let source: MigrationSource = .init(
			id: sourceID,
			kind: kind,
			name: "Google Chrome",
			categories: [.bookmarks],
			preservesOrganization: preservesOrganization
		)
		return .init(
			destination: destination,
			mapsToNewProfiles: preservesOrganization,
			phase: .selecting,
			sources: [source],
			selectedSourceID: source.id,
			selectedCategories: [.bookmarks]
		)
	}

	@Test
	internal func passwordsAreAKindOnlyBrowsersOffer() async {
		let archive = TestStore(initialState: assistant(kind: .arxArchive)) {
			MigrationAssistantFeature()
		}
		#expect(!archive.state.offersCredentials)
		await archive.send(.ui(.toggleCredentials))

		let calls: Calls = .init()
		let store = TestStore(initialState: assistant(kind: .externalBrowser)) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.credentialMigration = client(calls, source: source)
		}

		// Off until the user turns it on.
		#expect(!store.state.includesCredentials)
		await store.send(.ui(.toggleCredentials)) {
			$0.credentials = .init(sourceID: self.sourceID, sourceName: "Google Chrome")
		}
		await store.receive(\.credentials.load)
		await store.receive(\.credentials.event.loaded) {
			$0.credentials?.phase = .configuring
			$0.credentials?.source = self.source
			$0.credentials?.canWrite = true
			$0.credentials?.mode = .direct
		}
		#expect(!store.state.showsCredentials)
		#expect(calls.reads.isEmpty)

		await store.send(.ui(.toggleCredentials)) { $0.credentials = nil }
	}

	@Test
	internal func passwordsFollowTheMappingAfterTheImport() async {
		let calls: Calls = .init()
		let planID: MigrationPlan.ID = .init(rawValue: UUID(0))
		let lookups = LockIsolated<[(String, MigrationDestination)]>([])
		let inspected = LockIsolated<[MigrationDestination]>([])
		let preview = MigrationPreview(
			sourceID: sourceID,
			snapshotID: "s",
			destination: destination,
			categories: [
				.init(
					category: .bookmarks,
					items: [.init(key: .init(sourceID: sourceID, category: .bookmarks, sourceItemID: "b"), title: "Swift", url: URL(string: "https://swift.org")!)]
				),
			],
			profiles: mapped
		)
		let report = MigrationReport(
			planID: planID,
			outcome: .completed,
			categories: [.init(category: .bookmarks, status: .committed)]
		)
		var state = assistant(kind: .externalBrowser, preservesOrganization: true)
		state.credentials = configured
		state.credentials?.mappedProfiles = []
		let home = homeProfile
		let work = workProfile
		let store = TestStore(initialState: state) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.uuid = .constant(UUID(0))
			$0.credentialMigration = client(calls, source: source)
			$0.migrationAssistant.inspect = { _, _, destination in
				inspected.withValue { $0.append(destination) }
				return preview
			}
			$0.migrationAssistant.execute = { _ in
				AsyncThrowingStream { continuation in
					continuation.yield(.finished(report))
					continuation.finish()
				}
			}
			$0.migrationAssistant.receivingProfile = { id, destination in
				lookups.withValue { $0.append((id, destination)) }
				return id == "Default" ? work : home
			}
		}

		await store.send(.ui(.inspect)) { $0.phase = .inspecting }
		await store.receive(\.event.inspected) {
			$0.phase = .previewing
			$0.preview = preview
			$0.mappings = [
				.init(id: "Default", sourceName: "Work"),
				.init(id: "Profile 1", sourceName: "Home"),
			]

			// Passwords learn the mapping as soon as there is one.
			$0.credentials?.mappedProfiles = self.mapped
		}

		// Work joins the existing profile; Home becomes a new profile named Home Life.
		await store.send(.ui(.mapProfile("Default", workProfile.id))) {
			$0.mappings[id: "Default"]?.profileID = self.workProfile.id
			$0.phase = .inspecting
		}
		await store.receive(\.event.inspected) { $0.phase = .previewing }
		await store.send(.ui(.renameProfile("Profile 1", "Home Life"))) {
			$0.mappings[id: "Profile 1"]?.newName = "Home Life"
		}

		var expected = destination
		expected.defaultRoute = .newProfile
		expected.profileRoutes = [
			"Default": .existingProfile(workProfile.id),
			"Profile 1": .newProfile(name: "Home Life"),
		]
		var plan = MigrationPlan(id: planID, preview: preview)
		plan.destination = expected

		// The mapped profiles are made even if no category brings anything into them.
		plan.profiles = mapped
		await store.send(.ui(.startImport)) {
			$0.phase = .importing
			$0.plan = plan
		}
		await store.receive(\.event.execution) {
			$0.phase = .finished
			$0.report = report
		}
		await store.receive(\.credentials.start) { $0.credentials?.phase = .resolving }
		await store.receive(\.credentials.event.resolved) {
			$0.credentials?.phase = .intro
			$0.credentials?.targets = self.targets
		}
		#expect(store.state.showsCredentials)
		// The rename reached the plan without reading the source again.
		#expect(inspected.value.count == 2)
		#expect(lookups.value.map(\.0) == ["Default", "Profile 1"])
		#expect(lookups.value.allSatisfy { $0.1 == expected })
		// Nothing was read: the step waits for Continue.
		#expect(calls.reads.isEmpty)

		await store.send(.credentials(.ui(.close)))
		await store.receive(\.credentials.delegate.closed) { $0.credentials = nil }
		#expect(store.state.phase == .finished)
	}

	@Test
	internal func passwordsAloneCanBeImported() async {
		let preview = MigrationPreview(sourceID: sourceID, snapshotID: "s", destination: destination, categories: [])
		let categories = LockIsolated<[[MigrationCategory]]>([])
		var state = assistant(kind: .externalBrowser)
		state.credentials = configured
		let store = TestStore(initialState: state) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.migrationAssistant.inspect = { _, value, _ in
				categories.withValue { $0.append(value) }
				return preview
			}
		}

		await store.send(.ui(.toggleCategory(.bookmarks))) { $0.selectedCategories = [] }
		#expect(store.state.canInspect)
		await store.send(.ui(.inspect)) { $0.phase = .inspecting }
		await store.receive(\.event.inspected) {
			$0.phase = .previewing
			$0.preview = preview
		}
		#expect(categories.value == [[]])
		#expect(store.state.canImport)

		// Without passwords, nothing is left to import.
		await store.send(.ui(.back)) {
			$0.phase = .selecting
			$0.preview = nil
		}
		await store.send(.ui(.toggleCredentials)) { $0.credentials = nil }
		#expect(!store.state.canInspect)
	}

	@Test
	internal func profilesWithOnlyPasswordsJoinTheMapping() async {
		var state = assistant(kind: .externalBrowser, preservesOrganization: true)
		state.phase = .previewing

		// The review found tabs only in Default; Profile 1 has passwords and nothing else.
		state.preview = .init(
			sourceID: sourceID,
			snapshotID: "s",
			destination: destination,
			categories: [],
			profiles: [.init(id: "Default", name: "Work")]
		)
		state.mappings = [.init(id: "Default", sourceName: "Work", newName: "Office")]
		let calls: Calls = .init()
		let store = TestStore(initialState: state) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.credentialMigration = client(calls, source: source)
		}

		await store.send(.ui(.toggleCredentials)) {
			$0.credentials = .init(
				sourceID: self.sourceID,
				sourceName: "Google Chrome",
				mappedProfiles: [.init(id: "Default", name: "Work")]
			)
		}
		await store.receive(\.credentials.load)
		await store.receive(\.credentials.event.loaded) {
			$0.credentials?.phase = .configuring
			$0.credentials?.source = self.source
			$0.credentials?.canWrite = true
			$0.credentials?.mode = .direct

			// The user's choice stays; the passwords-only profile gets the default.
			$0.mappings.append(.init(id: "Profile 1", sourceName: "Home"))
			$0.credentials?.mappedProfiles = self.mapped
		}

		// Its new profile is made with the run, so its passwords have somewhere to go.
		#expect(store.state.mappedProfiles == mapped)

		await store.send(.ui(.toggleCredentials)) {
			$0.credentials = nil
			$0.mappings.remove(id: "Profile 1")
		}
	}

	@Test
	internal func aCancelledImportDoesntMovePasswords() async {
		let planID: MigrationPlan.ID = .init(rawValue: UUID(0))
		let report = MigrationReport(planID: planID, outcome: .cancelled, categories: [])
		var state = assistant(kind: .externalBrowser)
		state.credentials = configured
		state.phase = .importing
		state.plan = .init(
			id: planID,
			sourceID: sourceID,
			snapshotID: "s",
			destination: destination,
			categories: [.bookmarks]
		)
		let store = TestStore(initialState: state) {
			MigrationAssistantFeature()
		}

		await store.send(.event(.execution(.finished(report)))) {
			$0.phase = .finished
			$0.report = report
		}
		#expect(!store.state.showsCredentials)
	}

	@Test
	internal func csvModeWaitsForAFileBeforeImport() {
		var state = assistant(kind: .externalBrowser)
		state.phase = .previewing
		state.preview = .init(sourceID: sourceID, snapshotID: "s", destination: destination, categories: [])
		state.credentials = configured
		state.credentials?.mode = .csv(.engineNotReady)
		#expect(!state.canImport)

		state.credentials?.csvFiles = ["Default": URL(fileURLWithPath: "/tmp/dev842.csv")]
		#expect(state.canImport)
	}

	@Test
	internal func anotherSourceTurnsPasswordsOff() async {
		var state = assistant(kind: .externalBrowser)
		let other: MigrationSource = .init(
			id: .init(rawValue: "other"),
			kind: .externalBrowser,
			name: "Other",
			categories: [.bookmarks]
		)
		state.sources.append(other)
		state.credentials = configured
		let store = TestStore(initialState: state) {
			MigrationAssistantFeature()
		}

		await store.send(.ui(.selectSource(other.id))) {
			$0.selectedSourceID = other.id
			$0.credentials = nil
		}
	}

	@Test
	internal func dismissingTheAssistantDropsUnwrittenRecords() async {
		let calls: Calls = .init()
		var state = assistant(kind: .externalBrowser)
		var credentials = configured
		credentials.phase = .choosing
		credentials.inventories = [.init(inventory: inventory("Default"), selection: .all(in: inventory("Default")))]
		state.credentials = credentials
		let store = TestStore(initialState: state) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.credentialMigration = client(calls, source: source)
		}

		await store.send(.ui(.dismiss)) { $0.credentials = nil }
		await store.receive(\.delegate.dismissed)
		#expect(calls.discardedAll == 1)
	}

	/// Hosts that remove the assistant themselves, like onboarding's Escape or close button,
	/// run `cancelInFlightWork`, which drops the decrypted records too.
	@Test
	internal func hostRemovalDropsUnwrittenRecords() async {
		let calls: Calls = .init()
		let store = TestStore(initialState: assistant(kind: .externalBrowser)) {
			Reduce<MigrationAssistantFeature.State, MigrationAssistantFeature.Action> { _, action in
				guard case .ui(.task) = action else { return .none }

				return MigrationAssistantFeature.cancelInFlightWork()
			}
		} withDependencies: {
			$0.credentialMigration = client(calls, source: source)
		}

		await store.send(.ui(.task))
		await store.finish()
		#expect(calls.discardedAll == 1)
	}

	@Test
	internal func theAssistantCantCloseWhileTheStepWrites() {
		var state = assistant(kind: .externalBrowser)
		var credentials = configured
		credentials.phase = .importing
		state.credentials = credentials
		#expect(!state.canDismiss)
	}

	// MARK: - Clearing Arx data first

	private var existing: MigrationAssistantFeature.ExistingData {
		.init(profileNames: ["Personal", "Work"], spaceCount: 3, tabCount: 42)
	}

	@Test
	internal func clearingIsOffByDefaultAndHiddenOnAFreshArx() async {
		let fresh = TestStore(initialState: assistant(kind: .externalBrowser)) {
			MigrationAssistantFeature()
		}
		#expect(!fresh.state.canClearExistingData)
		await fresh.send(.ui(.setClearsExistingData(true)))

		var state = assistant(kind: .externalBrowser)
		state.existingData = existing
		#expect(!state.clearsExistingData)
		#expect(state.canClearExistingData)
	}

	@Test
	internal func clearingAsksByNameThenStartsFromACleanArx() async {
		let fresh: MigrationDestination = .init(profileID: .init(rawValue: UUID(10)), spaceID: .init(rawValue: UUID(11)))
		let freshOption: MigrationAssistantFeature.SpaceOption = .init(
			profileID: fresh.profileID,
			profileName: "Arx",
			spaceID: fresh.spaceID,
			spaceName: "Space"
		)
		let inspected = LockIsolated<[MigrationDestination]>([])
		let preview: MigrationPreview = .init(
			sourceID: sourceID,
			snapshotID: "s",
			destination: fresh,
			categories: [],
			profiles: [.init(id: "Default", name: "Work")]
		)
		var state = assistant(kind: .externalBrowser, preservesOrganization: true)
		state.existingData = existing

		// A mapping onto a profile that's about to go.
		state.mappings = [.init(id: "Default", sourceName: "Work", profileID: workProfile.id)]
		let store = TestStore(initialState: state) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.migrationAssistant.inspect = { _, _, destination in
				inspected.withValue { $0.append(destination) }
				return preview
			}
		}

		await store.send(.ui(.setClearsExistingData(true))) { $0.clearsExistingData = true }

		// Review asks first, and Back keeps everything.
		await store.send(.ui(.inspect)) { $0.phase = .confirmingClear }
		await store.send(.ui(.back)) { $0.phase = .selecting }
		#expect(inspected.value.isEmpty)

		await store.send(.ui(.inspect)) { $0.phase = .confirmingClear }
		await store.send(.ui(.confirmClear)) { $0.phase = .clearing }
		await store.receive(\.delegate.clearExistingData)
		#expect(!store.state.canDismiss)

		await store.send(.event(.cleared(fresh, spaceOptions: [freshOption]))) {
			$0.destination = fresh
			$0.spaceOptions = [freshOption]
			$0.existingData = nil
			$0.clearsExistingData = false
			$0.mappings = []
			$0.phase = .inspecting
		}
		await store.receive(\.event.inspected) {
			$0.phase = .previewing
			$0.preview = preview
			$0.mappings = [.init(id: "Default", sourceName: "Work")]
		}
		#expect(inspected.value.map(\.profileID) == [fresh.profileID])
		#expect(inspected.value.first?.defaultRoute == .newProfile)
		#expect(inspected.value.first?.profileRoutes == [:])
	}

	@Test
	internal func aFailedClearImportsNothing() async {
		var state = assistant(kind: .externalBrowser)
		state.existingData = existing
		state.clearsExistingData = true
		state.phase = .clearing
		let store = TestStore(initialState: state) {
			MigrationAssistantFeature()
		}

		await store.send(.event(.clearFailed)) {
			$0.phase = .selecting
			$0.problem = .clearFailed
		}
		#expect(store.state.existingData == self.existing)
	}

	@Test
	internal func withClearingOffReviewDoesntAsk() async {
		let preview: MigrationPreview = .init(sourceID: sourceID, snapshotID: "s", destination: destination, categories: [])
		var state = assistant(kind: .externalBrowser)
		state.existingData = existing
		let store = TestStore(initialState: state) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.migrationAssistant.inspect = { _, _, _ in preview }
		}

		await store.send(.ui(.inspect)) { $0.phase = .inspecting }
		await store.receive(\.event.inspected) {
			$0.phase = .previewing
			$0.preview = preview
		}
	}
}
