import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Foundation
import OnboardingFeature
import Testing
import WorkspaceDatabase
import WorkspaceSync
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-1215: the first launch's Default profile is held on this Mac for onboarding's "Sync with
/// iCloud", then removed when iCloud's workspace is adopted or let sync again otherwise. iCloud is
/// never reached: its rows are written to the store as a sync engine would.
@Suite(.dependencies)
@MainActor
internal struct OnboardingICloudAdoptionTests {
	private nonisolated static let provisional = ProvisionalProfile(
		profileID: .init(rawValue: UUID(0)),
		spaceID: .init(rawValue: UUID(1))
	)
	private nonisolated static let iCloudProfile: UUID = UUID(20)
	private nonisolated static let iCloudHome: UUID = UUID(21)
	private nonisolated static let iCloudProjects: UUID = UUID(22)

	private struct Fixture {
		let directory: URL
		let client: BrowserWorkspaceClient
		let document: WorkspaceDocument

		/// Makes the store unreadable, as a reload that throws finds it, or readable again (DEV-1221):
		/// this Mac's file says another save than the store's, as when a save was cut short.
		func setStoreReadable(_ isReadable: Bool) throws {
			let store: WorkspaceDatabase = try #require(client.workspaceDatabase)
			try store.database.write { db in
				try db.execute(sql: isReadable
				? #"UPDATE "local"."storeInfo" SET "value" = replace("value", '-stale', '') WHERE "id" = 'revision'"#
				: #"UPDATE "local"."storeInfo" SET "value" = "value" || '-stale' WHERE "id" = 'revision'"#
				)
			}
		}

		/// Another Mac's profile with two spaces arrives, as the step's first fetch writes it.
		func receiveICloudWorkspace() throws {
			let store: WorkspaceDatabase = try #require(client.workspaceDatabase)
			try store.database.write { db in
				try db.seed {
					ProfileRecord(id: OnboardingICloudAdoptionTests.iCloudProfile, name: "Work", position: "V")
					SpaceRecord(
						id: OnboardingICloudAdoptionTests.iCloudHome,
						profileID: OnboardingICloudAdoptionTests.iCloudProfile,
						name: "Home",
						position: "V"
					)
					SpaceRecord(
						id: OnboardingICloudAdoptionTests.iCloudProjects,
						profileID: OnboardingICloudAdoptionTests.iCloudProfile,
						name: "Projects",
						position: "W"
					)
				}
			}
		}
	}

	/// A first launch as BrowserWindow makes it with the step on: Default is "This Mac only".
	private static var firstLaunch: (BrowserOrganization, BrowserPreferences) {
		var organization: BrowserOrganization = provisional.organization
		organization.profiles[id: provisional.profileID]?.syncsWithICloud = false
		var preferences: BrowserPreferences = .init()
		preferences.onboarding.provisionalProfile = provisional
		preferences.onboarding.heldForICloud = provisional.profileID
		return (organization, preferences)
	}

	// MARK: - Presenting

	@Test
	internal func theFlowOffersTheStepWhileDefaultIsHeld() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store: TestStoreOf<AppFeature> = store(fixture)

		await store.send(.presentOnboardingIfNeeded)
		let onboarding = try #require(store.state.onboarding)
		#expect(onboarding.steps.prefix(2) == [.welcome, .iCloud])
		#expect(store.state.onboardingProgress.heldForICloud == Self.provisional.profileID)
	}

	@Test
	internal func withTheFeatureFlagTurnedOffSinceDefaultSyncsAndTheStepIsLeftOut() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store: TestStoreOf<AppFeature> = store(fixture) { $0.onboardingICloudEnabled = false }

		await store.send(.presentOnboardingIfNeeded)
		await store.skipReceivedActions(strict: false)
		#expect(store.state.onboarding?.steps.contains(.iCloud) == false)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
		#expect(store.state.workspace.profiles[id: Self.provisional.profileID]?.syncsWithICloud == nil)
	}

	@Test
	internal func withoutSyncHereDefaultSyncsAndTheStepIsLeftOut() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store: TestStoreOf<AppFeature> = store(fixture, syncIsAvailable: false)

		await store.send(.presentOnboardingIfNeeded)
		await store.skipReceivedActions(strict: false)
		#expect(store.state.onboarding?.steps.contains(.iCloud) == false)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
		#expect(store.state.workspace.profiles[id: Self.provisional.profileID]?.isThisMacOnly == false)
	}

	// MARK: - Adopted

	@Test
	internal func iCloudsWorkspaceReplacesDefaultAndOpensTheSpaceUsedLast() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store: TestStoreOf<AppFeature> = store(fixture)
		await store.send(.presentOnboardingIfNeeded)

		try fixture.receiveICloudWorkspace()
		await store.send(.onboarding(.delegate(.iCloudResolved(.adopted(lastUsedSpaceID: Self.iCloudProjects)))))
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.workspace.profiles.map(\.id.rawValue), [Self.iCloudProfile])
		expectNoDifference(store.state.workspace.spaces.map(\.id.rawValue), [Self.iCloudHome, Self.iCloudProjects])
		#expect(store.state.main.sidebar.spaceID.rawValue == Self.iCloudProjects)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
		#expect(store.state.onboardingProgress.provisionalProfile == nil)
		#expect(store.state.iCloudAdoption == nil)
		// The engine's original profile directory keeps its owner's identity.
		#expect(store.state.workspace.legacyProfileID == Self.provisional.profileID)
		// Until onboarding ends, even across a relaunch, nothing iCloud brought is offered for clearing.
		#expect(store.state.onboardingProgress.adoptedICloudWorkspace)
		#expect(store.state.migrationExistingData == nil)

		await store.send(.onboarding(.ui(.skipSetup)))
		await store.skipReceivedActions(strict: false)
		#expect(!store.state.onboardingProgress.adoptedICloudWorkspace)
	}

	@Test
	internal func aRelaunchAfterAdoptingKeepsTheImportLimitedToWhatICloudDoesntSync() async throws {
		var (organization, preferences) = Self.firstLaunch
		organization = .init(
			profiles: [.init(id: .init(rawValue: Self.iCloudProfile), name: "Work")],
			spaces: [.init(id: .init(rawValue: Self.iCloudHome), profileID: .init(rawValue: Self.iCloudProfile), name: "Home")]
		)
		preferences.onboarding = .init(completedSteps: [.welcome, .iCloud], adoptedICloudWorkspace: true)
		let fixture: Fixture = try fixture(organization, preferences)
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store: TestStoreOf<AppFeature> = store(fixture)

		await store.send(.presentOnboardingIfNeeded)
		let onboarding = try #require(store.state.onboarding)
		#expect(onboarding.workspaceCameFromICloud)
		#expect(store.state.migrationExistingData == nil)
	}

	@Test
	internal func withoutTheSpaceUsedLastItOpensTheFirstOne() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store: TestStoreOf<AppFeature> = store(fixture)
		await store.send(.presentOnboardingIfNeeded)

		try fixture.receiveICloudWorkspace()
		await store.send(.onboarding(.delegate(.iCloudResolved(.adopted(lastUsedSpaceID: UUID(99))))))
		await store.skipReceivedActions(strict: false)

		#expect(store.state.main.sidebar.spaceID.rawValue == Self.iCloudHome)
		#expect(!store.state.workspace.profiles.ids.contains(Self.provisional.profileID))
	}

	@Test
	internal func adoptionWaitsForTheReadOfWhatWasFetched() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }

		// An edit waits to be saved, so the read waits too.
		let store: TestStoreOf<AppFeature> = store(fixture) { $0.unsavedOrganization = $0.workspace }
		await store.send(.presentOnboardingIfNeeded)

		try fixture.receiveICloudWorkspace()
		await store.send(.onboarding(.delegate(.iCloudResolved(.adopted(lastUsedSpaceID: Self.iCloudHome)))))
		await store.skipReceivedActions(strict: false)

		#expect(store.state.iCloudAdoption != nil)
		#expect(store.state.workspace.profiles.ids.contains(Self.provisional.profileID))
		#expect(store.state.onboardingProgress.heldForICloud == Self.provisional.profileID)
		// Onboarding closing meanwhile doesn't let Default sync or settle it: adoption still removes it.
		await store.send(.onboarding(.ui(.dismiss)))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.profiles[id: Self.provisional.profileID]?.isThisMacOnly == true)
		#expect(store.state.onboardingProgress.provisionalProfile == Self.provisional)

		try await landSaves(store, fixture)
		#expect(!store.state.workspace.profiles.ids.contains(Self.provisional.profileID))
		#expect(store.state.main.sidebar.spaceID.rawValue == Self.iCloudHome)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
		#expect(!store.state.onboardingProgress.adoptedICloudWorkspace)
	}

	/// DEV-1221: a read that throws keeps the workspace as it was, which isn't an iCloud without
	/// spaces. Default stays held and isn't removed until a later read reaches the store.
	@Test
	internal func aReadThatFailsKeepsDefaultHeldAndTriesAgain() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let clock: TestClock<Duration> = .init()
		let store: TestStoreOf<AppFeature> = store(fixture, clock: clock)
		await store.send(.presentOnboardingIfNeeded)

		try fixture.receiveICloudWorkspace()
		try fixture.setStoreReadable(false)
		await store.send(.onboarding(.delegate(.iCloudResolved(.adopted(lastUsedSpaceID: Self.iCloudProjects)))))
		await store.receive(\.event.workspaceSyncReadFailed)
		await store.skipReceivedActions(strict: false)

		#expect(store.state.iCloudAdoption != nil)
		#expect(store.state.onboardingProgress.heldForICloud == Self.provisional.profileID)
		#expect(store.state.workspace.profiles[id: Self.provisional.profileID]?.isThisMacOnly == true)
		#expect(!store.state.workspace.profiles.ids.contains(.init(rawValue: Self.iCloudProfile)))

		// Still unreadable when the retry comes: Default stays held, and it tries again.
		await clock.advance(by: .seconds(5))
		await store.receive(\.event.workspaceSyncReadFailed)
		await store.skipReceivedActions(strict: false)
		#expect(store.state.onboardingProgress.heldForICloud == Self.provisional.profileID)

		try fixture.setStoreReadable(true)
		await clock.advance(by: .seconds(5))
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.workspace.profiles.map(\.id.rawValue), [Self.iCloudProfile])
		#expect(store.state.main.sidebar.spaceID.rawValue == Self.iCloudProjects)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
		#expect(store.state.iCloudAdoption == nil)
	}

	@Test
	internal func anAdoptionStillReadingWhenTheImportPageShowsKeepsDefault() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }

		// An edit waits to be saved, so the read waits, and onboarding moves on meanwhile.
		let store: TestStoreOf<AppFeature> = store(fixture) { $0.unsavedOrganization = $0.workspace }
		await store.send(.presentOnboardingIfNeeded)

		try fixture.receiveICloudWorkspace()
		await store.send(.onboarding(.delegate(.iCloudResolved(.adopted(lastUsedSpaceID: Self.iCloudHome)))))
		while store.state.onboarding?.step != .migration {
			await store.send(.onboarding(.ui(.continueSetup)))
		}
		await store.skipReceivedActions(strict: false)
		#expect(store.state.iCloudAdoption != nil)

		// Passwords may have come into Default by now, which the workspace doesn't show.
		try await landSaves(store, fixture)
		#expect(store.state.iCloudAdoption == nil)
		#expect(store.state.workspace.profiles.ids.contains(Self.provisional.profileID))
		#expect(store.state.workspace.profiles[id: Self.provisional.profileID]?.syncsWithICloud == nil)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
	}

	@Test
	internal func iCloudWithNothingToOpenKeepsDefault() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store: TestStoreOf<AppFeature> = store(fixture)
		await store.send(.presentOnboardingIfNeeded)

		await store.send(.onboarding(.delegate(.iCloudResolved(.adopted(lastUsedSpaceID: nil)))))
		await store.skipReceivedActions(strict: false)

		#expect(store.state.workspace.profiles.map(\.id) == [Self.provisional.profileID])
		#expect(store.state.workspace.profiles[0].isThisMacOnly == false)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
	}

	// MARK: - Empty, Continue without waiting, Not now

	@Test(arguments: [
		OnboardingICloud.Resolution.empty,
		.notNow,
		.unavailable,
	])
	internal func everyOtherOutcomeLetsDefaultSync(_ resolution: OnboardingICloud.Resolution) async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store: TestStoreOf<AppFeature> = store(fixture)
		await store.send(.presentOnboardingIfNeeded)

		await store.send(.onboarding(.delegate(.iCloudResolved(resolution))))
		await store.skipReceivedActions(strict: false)

		#expect(store.state.workspace.profiles.map(\.id) == [Self.provisional.profileID])
		#expect(store.state.workspace.profiles[0].syncsWithICloud == nil)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
		// Default is still provisional: an import with its own profiles can still replace it.
		#expect(store.state.onboardingProgress.provisionalProfile == Self.provisional)
	}

	// MARK: - Continue without waiting

	@Test
	internal func goingOnWithoutWaitingStillAdoptsWhatICloudHadWhileOnboardingIsOpen() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let joins: Joins = .init([.finished(.init(hasWorkspace: true, lastUsedSpaceID: Self.iCloudProjects))])
		let store: TestStoreOf<AppFeature> = store(fixture, joins: joins)
		await store.send(.presentOnboardingIfNeeded)

		try fixture.receiveICloudWorkspace()
		await store.send(.onboarding(.delegate(.iCloudResolved(.continuedWithoutWaiting))))
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.workspace.profiles.map(\.id.rawValue), [Self.iCloudProfile])
		#expect(store.state.main.sidebar.spaceID.rawValue == Self.iCloudProjects)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
		#expect(!store.state.waitsForICloudInBackground)
		// The import page that comes next offers only what iCloud doesn't sync.
		#expect(store.state.onboarding?.workspaceCameFromICloud == true)
		// The wait never turns sync on itself.
		#expect(joins.turnedSyncOn.value == [false])
	}

	@Test
	internal func anEmptyICloudFoundLaterLetsDefaultSync() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }

		// Offline first: the wait asks again.
		let joins: Joins = .init([.unavailable], [.fetching(.organization), .finished(.init(hasWorkspace: false))])
		let store: TestStoreOf<AppFeature> = store(fixture, joins: joins)
		await store.send(.presentOnboardingIfNeeded)

		await store.send(.onboarding(.delegate(.iCloudResolved(.continuedWithoutWaiting))))
		await store.skipReceivedActions(strict: false)

		#expect(joins.turnedSyncOn.value == [false, false])
		#expect(store.state.workspace.profiles[id: Self.provisional.profileID]?.syncsWithICloud == nil)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
	}

	@Test
	internal func syncTurnedOffWhileWaitingLetsDefaultSync() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store: TestStoreOf<AppFeature> = store(fixture, joins: .init([.turnedOff]))
		await store.send(.presentOnboardingIfNeeded)

		await store.send(.onboarding(.delegate(.iCloudResolved(.continuedWithoutWaiting))))
		await store.skipReceivedActions(strict: false)

		#expect(store.state.workspace.profiles[id: Self.provisional.profileID]?.syncsWithICloud == nil)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
	}

	@Test
	internal func onboardingEndingWhileWaitingKeepsDefaultHeldThenLetsItSync() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let answer: AsyncStream<OnboardingSyncEvent>.Continuation
		let stream: AsyncStream<OnboardingSyncEvent>
		(stream, answer) = AsyncStream.makeStream()
		let joins: Joins = .init(streams: [stream])
		let store: TestStoreOf<AppFeature> = store(fixture, joins: joins)
		await store.send(.presentOnboardingIfNeeded)

		await store.send(.onboarding(.delegate(.iCloudResolved(.continuedWithoutWaiting))))
		await store.send(.onboarding(.ui(.skipSetup)))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.onboarding == nil)
		#expect(store.state.waitsForICloudInBackground)
		#expect(store.state.workspace.profiles[id: Self.provisional.profileID]?.isThisMacOnly == true)

		// iCloud had a workspace, but Default is the person's now: it syncs beside it, and Settings
		// offers to merge profiles of the same name (DEV-1216).
		// The save onboarding's end asked for lands, so reads aren't held back.
		try await landSaves(store, fixture)

		try fixture.receiveICloudWorkspace()
		answer.yield(.finished(.init(hasWorkspace: true, lastUsedSpaceID: Self.iCloudHome)))
		answer.finish()
		await store.receive(\.event.onboardingICloudFetched)
		await store.skipReceivedActions(strict: false)

		// A read with preferences unsaved saves them first and reads after.
		try await landSaves(store, fixture)

		#expect(store.state.workspace.profiles.ids.contains(Self.provisional.profileID))
		#expect(store.state.workspace.profiles[id: Self.provisional.profileID]?.syncsWithICloud == nil)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
	}

	@Test
	internal func anAnswerAfterTheImportPageWasShownKeepsDefault() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let (stream, answer) = AsyncStream<OnboardingSyncEvent>.makeStream()
		let store: TestStoreOf<AppFeature> = store(fixture, joins: .init(streams: [stream]))
		await store.send(.presentOnboardingIfNeeded)

		await store.send(.onboarding(.delegate(.iCloudResolved(.continuedWithoutWaiting))))

		// On to "Make it yours", where passwords may come into Default without the workspace showing it.
		while store.state.onboarding?.step != .migration {
			await store.send(.onboarding(.ui(.continueSetup)))
		}
		await store.skipReceivedActions(strict: false)
		#expect(store.state.onboarding?.importWasShown == true)
		#expect(store.state.waitsForICloudInBackground)
		try await landSaves(store, fixture)

		try fixture.receiveICloudWorkspace()
		answer.yield(.finished(.init(hasWorkspace: true, lastUsedSpaceID: Self.iCloudHome)))
		answer.finish()
		await store.receive(\.event.onboardingICloudFetched)
		await store.skipReceivedActions(strict: false)
		try await landSaves(store, fixture)

		#expect(store.state.workspace.profiles.ids.contains(Self.provisional.profileID))
		#expect(store.state.workspace.profiles[id: Self.provisional.profileID]?.syncsWithICloud == nil)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
		#expect(store.state.onboarding?.workspaceCameFromICloud == false)
	}

	@Test
	internal func aRelaunchWhileWaitingLetsDefaultSync() async throws {
		var (organization, preferences) = Self.firstLaunch
		preferences.onboarding.introductionDismissed = true
		preferences.onboarding.completedSteps = [.welcome, .iCloud]
		organization.profiles[id: Self.provisional.profileID]?.syncsWithICloud = false
		let fixture: Fixture = try fixture(organization, preferences)
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let joins: Joins = .init([.finished(.init(hasWorkspace: true))])
		let store: TestStoreOf<AppFeature> = store(fixture, joins: joins)

		await store.send(.presentOnboardingIfNeeded)
		await store.skipReceivedActions(strict: false)

		// What an import put in Default before the relaunch can't be told: it isn't removed.
		#expect(joins.turnedSyncOn.value.isEmpty)
		#expect(!store.state.waitsForICloudInBackground)
		#expect(store.state.workspace.profiles[id: Self.provisional.profileID]?.syncsWithICloud == nil)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
	}

	// MARK: - Onboarding ending

	@Test
	internal func closingOnboardingBeforeTheStepDecidesLetsDefaultSync() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store: TestStoreOf<AppFeature> = store(fixture)
		await store.send(.presentOnboardingIfNeeded)

		await store.send(.onboarding(.ui(.skipSetup)))
		await store.skipReceivedActions(strict: false)

		#expect(store.state.onboarding == nil)
		#expect(store.state.workspace.profiles[id: Self.provisional.profileID]?.syncsWithICloud == nil)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
	}

	@Test
	internal func aRelaunchAfterOnboardingEndedLetsAHeldDefaultSync() async throws {
		var (organization, preferences) = Self.firstLaunch
		preferences.onboarding.introductionDismissed = true
		organization.profiles[id: Self.provisional.profileID]?.syncsWithICloud = false
		let fixture: Fixture = try fixture(organization, preferences)
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store: TestStoreOf<AppFeature> = store(fixture)

		await store.send(.presentOnboardingIfNeeded)
		await store.skipReceivedActions(strict: false)

		#expect(store.state.onboarding == nil)
		#expect(store.state.workspace.profiles[id: Self.provisional.profileID]?.syncsWithICloud == nil)
		#expect(store.state.onboardingProgress.heldForICloud == nil)
	}

	@Test
	internal func aHeldDefaultIsStillPristine() {
		let (organization, _) = Self.firstLaunch
		#expect(Self.provisional.isPristine(in: organization, ledger: .init()))
	}

	// MARK: - Helpers

	/// Writes what the store asked to save, as BrowserWindow does, and reports each save landing.
	private func landSaves(
		_ store: TestStoreOf<AppFeature>,
		_ fixture: Fixture
	) async throws {
		for _ in 0..<5 {
			try await fixture.document.flush()
			let saved: BrowserPreferences = withDependencies {
				$0.workspaceDocument = fixture.document
			} operation: {
				store.state.persistedPreferences
			}
			let organization: BrowserOrganization = store.state.unsavedOrganization ?? store.state.workspace
			await store.send(.event(.saveSucceeded(organization, saved)))
			await store.skipReceivedActions(strict: false)
			guard store.state.unsavedOrganization != nil || store.state.syncReloadPending else { return }
		}
	}

	private func fixture(
		_ organization: BrowserOrganization = Self.firstLaunch.0,
		_ preferences: BrowserPreferences = Self.firstLaunch.1
	) throws -> Fixture {
		let directory: URL = .temporaryDirectory.appendingPathComponent("OnboardingICloudAdoptionTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let client: BrowserWorkspaceClient = .init(
			file: directory.appendingPathComponent("arx-workspace.json"),
			storage: .sqlite,
			separatePreferencesConnection: true
		)
		_ = try client.loadWithRecovery()
		try client.save(organization, preferences: preferences)
		let document: WorkspaceDocument = .init(client: client, organization: organization, preferences: preferences)
		return .init(directory: directory, client: client, document: document)
	}

	private func store(
		_ fixture: Fixture,
		syncIsAvailable: Bool = true,
		joins: Joins = .init(),
		clock: any Clock<Duration> = ImmediateClock(),
		configure: (inout AppFeature.State) -> Void = { _ in }
	) -> TestStoreOf<AppFeature> {
		let organization: BrowserOrganization = fixture.document.organization ?? Self.firstLaunch.0
		let preferences: BrowserPreferences = fixture.document.savedPreferences
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State.launching(
				main: .init(organization: organization, spaceID: organization.spaces[0].id),
				preferences: preferences
			)
		}
		state.onboardingICloudEnabled = true
		configure(&state)
		let ids = LockIsolated(1_000)
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
			$0.continuousClock = clock
			$0.uuid = .init {
				ids.withValue { $0 += 1 }
				return UUID(ids.value)
			}
			$0.browserEngine.prepareProfile = { _ in }
			var sync: WorkspaceSyncClient = .unavailable
			sync.isAvailable = { syncIsAvailable }
			sync.joinFromOnboarding = { turningSyncOn in joins.next(turningSyncOn: turningSyncOn) }
			$0.workspaceSync = sync
		}
		store.exhaustivity = Exhaustivity.off
		return store
	}
}

/// Plays back one stream per call of `joinFromOnboarding`, the last one again once they run out.
private final class Joins: Sendable {
	private let streams: LockIsolated<[AsyncStream<OnboardingSyncEvent>]>
	private let events: [[OnboardingSyncEvent]]
	private let calls: LockIsolated<Int> = .init(0)

	/// What each call asked for.
	let turnedSyncOn: LockIsolated<[Bool]> = .init([])

	init(_ events: [OnboardingSyncEvent]...) {
		self.events = events
		self.streams = .init([])
	}

	init(streams: [AsyncStream<OnboardingSyncEvent>]) {
		self.events = []
		self.streams = .init(streams)
	}

	func next(turningSyncOn: Bool) -> AsyncStream<OnboardingSyncEvent> {
		turnedSyncOn.withValue { $0.append(turningSyncOn) }
		let call: Int = calls.withValue { $0 += 1; return $0 - 1 }
		if let stream = streams.withValue({ $0.isEmpty ? nil : $0.removeFirst() }) {
			return stream
		}
		let events: [OnboardingSyncEvent] = events.isEmpty ? [] : events[min(call, events.count - 1)]
		return AsyncStream { continuation in
			events.forEach { continuation.yield($0) }
			continuation.finish()
		}
	}
}
