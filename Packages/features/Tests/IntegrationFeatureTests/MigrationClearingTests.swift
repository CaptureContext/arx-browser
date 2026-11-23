import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MigrationAssistant
import MigrationAssistantFeature
import OnboardingFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// "Clear Arx data first" before an import (DEV-833): the host replaces every space with one
/// fresh Default profile and space once the old pages agree to close, retires each old profile
/// in turn through profile retirement, and answers the assistant.
@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct MigrationClearingTests {
	// MARK: - What Arx holds

	@Test
	internal func aPristineFirstLaunchOffersNoClear() async {
		let fixture = MigrationClearingFixture()
		var state = fixture.state()
		let provisional = ProvisionalProfile(profileID: fixture.work, spaceID: fixture.workSpace)
		state.workspace = provisional.organization
		state.$onboardingProgress.withLock { $0.provisionalProfile = provisional }

		// One Default profile and space and nothing in them: nothing to clear, so no toggle.
		#expect(state.workspaceHoldsOnlyFreshInstallDefaults)
		#expect(state.migrationExistingData == nil)

		state.onboarding = nil
		let store = fixture.store(state)
		await store.send(.ui(.openOnboardingStep(.migration)))
		#expect(store.state.onboarding?.existingData == nil)
		await store.send(.onboarding(.page(.migration(.ui(.importData)))))
		#expect(store.state.onboarding?.page.migration?.migration?.existingData == nil)
	}

	@Test(arguments: FirstLaunchAddition.allCases)
	internal func anythingBeyondAFreshInstallOffersTheClear(_ addition: FirstLaunchAddition) {
		let fixture = MigrationClearingFixture()
		var state = fixture.state()
		let provisional = ProvisionalProfile(profileID: fixture.work, spaceID: fixture.workSpace)
		state.workspace = provisional.organization
		state.$onboardingProgress.withLock { $0.provisionalProfile = provisional }
		addition.apply(to: &state.workspace, profileID: fixture.work, spaceID: fixture.workSpace)

		#expect(!state.workspaceHoldsOnlyFreshInstallDefaults)
		let existing = state.migrationExistingData
		#expect(existing != nil, "\(addition)")
		if addition == .tab {
			expectNoDifference(existing, .init(profileNames: ["Default"], spaceCount: 1, tabCount: 1))
		}
	}

	/// One thing a fresh install doesn't start with.
	internal enum FirstLaunchAddition: CaseIterable, Sendable {
		case tab, pinnedTab, favorite, folder, archivedTab, secondSpace, secondProfile

		internal func apply(
			to workspace: inout BrowserOrganization,
			profileID: Profile.ID,
			spaceID: Space.ID
		) {
			let tab = BrowserCore.Tab(
				id: .init(rawValue: UUID(900)),
				profileID: profileID,
				restoration: .init(title: "Page", url: URL(string: "https://example.com/")!)
			)
			switch self {
			case .tab:
				workspace.tabs.append(tab)
				workspace.spaces[id: spaceID]?.unpinnedTabs.append(tab.id)
			case .pinnedTab:
				workspace.tabs.append(tab)
				workspace.spaces[id: spaceID]?.savedItems.append(.tab(tab.id))
			case .favorite:
				workspace.tabs.append(tab)
				workspace.profiles[id: profileID]?.favorites.append(tab.id)
			case .folder:
				let folder = Folder(id: .init(rawValue: UUID(901)), spaceID: spaceID, name: "Folder")
				workspace.folders.append(folder)
				workspace.spaces[id: spaceID]?.savedItems.append(.folder(folder.id))
			case .archivedTab:
				workspace.archive.append(.init(
					id: .init(rawValue: UUID(902)),
					groupID: UUID(903),
					closedAt: Date(timeIntervalSince1970: 0),
					originalSpaceID: spaceID,
					originalSpaceName: "Default",
					originalIndex: 0,
					tab: tab
				))
			case .secondSpace:
				workspace.spaces.append(.init(id: .init(rawValue: UUID(904)), profileID: profileID, name: "Second"))
			case .secondProfile:
				workspace.profiles.append(.init(id: .init(rawValue: UUID(905)), name: "Second"))
			}
		}
	}

	@Test
	internal func profilesSpacesAndTabsAreCountedOnlyWhereRetirementIsDurable() {
		let fixture = MigrationClearingFixture()
		var state = fixture.state()

		expectNoDifference(
			state.migrationExistingData,
			.init(profileNames: ["Work", "Home"], spaceCount: 2, tabCount: 2)
		)

		state.settings.retirementAvailable = false
		#expect(state.migrationExistingData == nil)
	}

	@Test
	internal func theImportPageAndItsAssistantGetWhatArxHolds() async {
		let fixture = MigrationClearingFixture()
		var state = fixture.state()
		state.onboarding = nil
		let store = fixture.store(state)

		await store.send(.ui(.openOnboardingStep(.migration)))
		let existing = MigrationAssistantFeature.ExistingData(profileNames: ["Work", "Home"], spaceCount: 2, tabCount: 2)
		expectNoDifference(store.state.onboarding?.existingData, existing)
		expectNoDifference(store.state.onboarding?.page.migration?.existingData, existing)

		await store.send(.onboarding(.page(.migration(.ui(.importData)))))
		expectNoDifference(store.state.onboarding?.page.migration?.migration?.existingData, existing)
	}

	@Test
	internal func aFinishedImportForAnotherDestinationIsDroppedWithIt() {
		let fixture = MigrationClearingFixture()
		var page = OnboardingImport.State(
			destination: .init(profileID: fixture.work, spaceID: fixture.workSpace),
			phase: .finished,
			problem: .importFailed
		)
		page.updateMigrationTargets(
			destination: .init(profileID: fixture.home, spaceID: fixture.homeSpace),
			spaceOptions: [],
			existingData: nil
		)

		expectNoDifference(page.phase, .idle)
		#expect(page.problem == nil)
		#expect(page.plan == nil)
		#expect(page.report == nil)
	}

	// MARK: - Clearing

	@Test
	internal func clearingLeavesOneFreshProfileAndSpaceAndRetiresEveryOldProfileInTurn() async {
		let fixture = MigrationClearingFixture()
		let store = fixture.store(fixture.state())

		await store.send(fixture.clear)
		await store.receive(\.migrationClearing.approved)
		await store.send(fixture.saved(store))
		await store.receive(\.profileRetirement.ended)
		await store.receive(\.profileRetirement.ended)
		await store.receive(\.onboarding.page.migration.migration.event.cleared)
		await store.finish()

		let fresh = store.state.workspace.profiles.first
		let space = store.state.workspace.spaces.first
		expectNoDifference(store.state.workspace.profiles.map(\.name), ["Default"])
		expectNoDifference(store.state.workspace.spaces.map(\.name), ["Default"])
		expectNoDifference(store.state.workspace.spaces.first?.profileID, fresh?.id)
		#expect(store.state.workspace.tabs.isEmpty)
		expectNoDifference(store.state.workspace.retiredProfileIDs, [fixture.work, fixture.home])
		expectNoDifference(store.state.main.sidebar.spaceID, space?.id)

		// Both pages were asked before anything changed, then, once the fresh space was saved,
		// each profile retired on its own.
		expectNoDifference(fixture.events, [
			"permit \(fixture.workTab.rawValue)",
			"permit \(fixture.homeTab.rawValue)",
			"queue \(fixture.work.rawValue)",
			"queue \(fixture.home.rawValue)",
		])
		expectNoDifference(fixture.persisted.map(\.profileID), [fixture.work, fixture.home])
		#expect(store.state.migrationClearing == nil)
		#expect(!store.state.profileRetirement.isBusy)

		let assistant = store.state.onboarding?.page.migration?.migration
		expectNoDifference(assistant?.destination, fresh.flatMap { profile in
			space.map { .init(profileID: profile.id, spaceID: $0.id) }
		})
		#expect(assistant?.existingData == nil)
		#expect(store.state.onboarding?.existingData == nil)
		expectNoDifference(store.state.onboarding?.destination?.spaceID, space?.id)
	}

	@Test
	internal func onboardingStaysOpenWhileArxIsCleared() async throws {
		let fixture = MigrationClearingFixture()
		fixture.holdsRetirement = true
		let store = fixture.store(fixture.state())

		await store.send(fixture.clear)
		await store.receive(\.migrationClearing.approved)
		await store.send(fixture.saved(store))
		try await fixture.waitForRetirement()
		await store.send(.ui(.closeOnboarding))
		#expect(store.state.onboarding != nil)
		#expect(store.state.migrationClearing != nil)

		fixture.holdsRetirement = false
		fixture.releaseRetirement()
		await store.receive(\.onboarding.page.migration.migration.event.cleared)
		await store.finish()

		await store.send(.ui(.closeOnboarding))
		#expect(store.state.onboarding == nil)
	}

	@Test
	internal func aPageThatRefusesToCloseLeavesArxAsItWas() async {
		let fixture = MigrationClearingFixture()
		fixture.refusing = [fixture.homeTab]
		let state = fixture.state()
		let store = fixture.store(state)

		await store.send(fixture.clear)
		await store.receive(\.migrationClearing.refused)
		await store.receive(\.onboarding.page.migration.migration.event.clearFailed)
		await store.finish()

		expectNoDifference(store.state.workspace, state.workspace)
		#expect(!fixture.events.contains { $0.hasPrefix("queue") })
		#expect(store.state.migrationClearing == nil)
		expectNoDifference(store.state.onboarding?.page.migration?.migration?.problem, .clearFailed)
	}

	@Test
	internal func aRefusalOpensAgainTheShownPageThatClosedBeforeIt() async {
		let fixture = MigrationClearingFixture()
		fixture.refusing = [fixture.homeTab]
		var state = fixture.state()
		state.main.viewer.item = .init(tab: state.workspace.tabs[id: fixture.workTab])
		let store = fixture.store(state)

		await store.send(fixture.clear)
		await store.receive(\.migrationClearing.refused)
		await store.skipReceivedActions()
		await store.finish()

		expectNoDifference(store.state.main.viewer.item.tab?.id, fixture.workTab)
		#expect(!fixture.closed.contains(fixture.workTab))
		expectNoDifference(store.state.workspace, state.workspace)
	}

	@Test
	internal func aRefusalOpensAgainASplitPaneThatClosedBeforeIt() async {
		let fixture = MigrationClearingFixture()
		fixture.refusing = [fixture.homeTab]
		var state = fixture.state()
		state.main.viewer.panes = [
			.init(id: UUID(70), item: .init(tab: state.workspace.tabs[id: fixture.workTab])),
			.init(id: UUID(71)),
		]
		let store = fixture.store(state)

		await store.send(fixture.clear)
		await store.receive(\.migrationClearing.refused)
		await store.skipReceivedActions()
		await store.finish()

		#expect(!fixture.closed.contains(fixture.workTab))
		expectNoDifference(store.state.main.viewer.panes[id: UUID(70)]?.item.tab?.id, fixture.workTab)
	}

	@Test
	internal func aTabStillOpeningStopsTheClearBeforeAnythingChanges() async {
		let fixture = MigrationClearingFixture()
		fixture.opening = [fixture.homeTab]
		let state = fixture.state()
		let store = fixture.store(state)

		await store.send(fixture.clear)
		await store.receive(\.migrationClearing.refused)
		await store.receive(\.onboarding.page.migration.migration.event.clearFailed)
		await store.finish()

		expectNoDifference(store.state.workspace, state.workspace)
	}

	@Test
	internal func aPageShownAgainWhileAnotherAsksIsAskedAgain() async throws {
		let fixture = MigrationClearingFixture()
		fixture.holdsClose = fixture.homeTab
		let store = fixture.store(fixture.state())

		await store.send(fixture.clear)
		try await fixture.waitForClose()

		// Choosing another space waits until the clear ends, like any change while a profile retires.
		await store.send(.main(.sidebar(.ui(.spaceSelected(fixture.homeSpace)))))
		expectNoDifference(store.state.main.sidebar.spaceID, fixture.workSpace)
		expectNoDifference(store.state.settings.organizationError, String.localized(.appUI.retirement.busy))

		// Work's page closed and is shown again anyway, as an open already under way would.
		fixture.closed.removeAll { $0 == fixture.workTab }
		fixture.releaseClose()
		await store.receive(\.migrationClearing.approved)
		await store.send(fixture.saved(store))
		await store.receive(\.onboarding.page.migration.migration.event.cleared)
		await store.finish()

		expectNoDifference(fixture.events.filter { $0 == "permit \(fixture.workTab.rawValue)" }.count, 2)
		#expect(fixture.closed.contains(fixture.workTab))
	}

	@Test
	internal func aFailedRetirementStopsWithTheFreshSpaceAndTheProfilesRetiredSoFar() async {
		let fixture = MigrationClearingFixture()
		fixture.failing = [fixture.home]
		let store = fixture.store(fixture.state())

		await store.send(fixture.clear)
		await store.receive(\.migrationClearing.approved)
		await store.send(fixture.saved(store))
		await store.receive(\.profileRetirement.ended)
		await store.receive(\.profileRetirement.ended)
		await store.receive(\.onboarding.page.migration.migration.event.clearFailed)
		await store.finish()

		// Home stays, without spaces, and can be retired again from Settings.
		expectNoDifference(store.state.workspace.profiles.map(\.name), ["Home", "Default"])
		expectNoDifference(store.state.workspace.spaces.map(\.name), ["Default"])
		expectNoDifference(store.state.workspace.retiredProfileIDs, [fixture.work])
		#expect(store.state.migrationClearing == nil)
		#expect(!store.state.profileRetirement.isBusy)
		expectNoDifference(
			store.state.profileRetirement.intents.first { $0.profileID == fixture.home }?.acknowledged,
			false
		)

		// Onboarding imports into what's left: the fresh space, with Home still to clear.
		let space = store.state.workspace.spaces.first
		let page = store.state.onboarding?.page.migration
		expectNoDifference(page?.destination?.spaceID, space?.id)
		expectNoDifference(page?.migration?.destination?.spaceID, space?.id)
		expectNoDifference(page?.migration?.spaceOptions.map(\.spaceID), space.map { [$0.id] })
		expectNoDifference(store.state.onboarding?.destination?.spaceID, space?.id)
		expectNoDifference(page?.migration?.existingData?.profileNames, ["Home", "Default"])
	}

	@Test
	internal func favoritesAndArchivedTabsGoToo() async {
		let fixture = MigrationClearingFixture()
		fixture.hasFavorite = true
		fixture.hasArchive = true
		let store = fixture.store(fixture.state())

		await store.send(fixture.clear)
		await store.receive(\.migrationClearing.approved)
		await store.send(fixture.saved(store))
		await store.receive(\.onboarding.page.migration.migration.event.cleared)
		await store.finish()

		#expect(store.state.workspace.archive.isEmpty)
		#expect(store.state.workspace.tabs.isEmpty)
		// The favorite's page closed with the others, before Home retired.
		#expect(fixture.closed.contains(fixture.favorite))
		// Asked once: retirement found it closed.
		expectNoDifference(fixture.events.filter { $0 == "permit \(fixture.favorite.rawValue)" }.count, 1)
	}

	@Test
	internal func onboardingOffersTheClearOnceRetirementTurnsOutDurable() async {
		let fixture = MigrationClearingFixture()
		var state = fixture.state()
		state.settings.retirementAvailable = false
		let destination = state.onboarding?.destination
		state.onboarding?.updateMigrationTargets(destination: destination, spaceOptions: [], existingData: nil)
		let store = fixture.store(state)
		#expect(store.state.onboarding?.page.migration?.migration?.existingData == nil)

		await store.send(.profileRetirement(.refreshed(.init(revision: 7, isDurable: true, records: []))))

		expectNoDifference(store.state.onboarding?.existingData, fixture.existing)
		expectNoDifference(store.state.onboarding?.page.migration?.migration?.existingData, fixture.existing)
	}

	@Test
	internal func reopeningImportOffersWhatArxHoldsNow() async {
		let fixture = MigrationClearingFixture()
		var state = fixture.state()
		let destination = state.onboarding?.destination
		state.onboarding?.updateMigrationTargets(destination: destination, spaceOptions: [], existingData: nil)
		if case var .migration(page) = state.onboarding?.page {
			page.migration = nil
			state.onboarding?.page = .migration(page)
		}
		let store = fixture.store(state)

		await store.send(.ui(.openImport))
		await store.skipReceivedActions()

		expectNoDifference(store.state.onboarding?.existingData, fixture.existing)
		expectNoDifference(store.state.onboarding?.page.migration?.migration?.existingData, fixture.existing)
	}

	@Test
	internal func aFailedSaveStopsBeforeAnyProfileRetires() async {
		let fixture = MigrationClearingFixture()
		let store = fixture.store(fixture.state())

		await store.send(fixture.clear)
		await store.receive(\.migrationClearing.approved)
		await store.send(.event(.saveFailed("The disk is full.")))
		await store.receive(\.onboarding.page.migration.migration.event.clearFailed)
		await store.finish()

		#expect(!fixture.events.contains { $0.hasPrefix("queue") })
		expectNoDifference(store.state.workspace.profiles.map(\.name), ["Work", "Home", "Default"])
		expectNoDifference(store.state.workspace.spaces.map(\.name), ["Default"])
		#expect(store.state.migrationClearing == nil)
		expectNoDifference(
			store.state.onboarding?.page.migration?.migration?.destination?.spaceID,
			store.state.workspace.spaces.first?.id
		)
	}

	@Test
	internal func aFavoriteThatRefusesToCloseLeavesArxAsItWas() async {
		let fixture = MigrationClearingFixture()
		fixture.hasFavorite = true
		fixture.refusing = [fixture.favorite]
		let state = fixture.state()
		expectNoDifference(state.migrationExistingData, fixture.existing)
		let store = fixture.store(state)

		await store.send(fixture.clear)
		await store.receive(\.migrationClearing.refused)
		await store.receive(\.onboarding.page.migration.migration.event.clearFailed)
		await store.finish()

		expectNoDifference(store.state.workspace, state.workspace)
		#expect(fixture.events.contains("permit \(fixture.favorite.rawValue)"))
		#expect(!fixture.events.contains { $0.hasPrefix("queue") })
	}

	@Test
	internal func aClearNamingOtherDataIsRefusedAndShowsWhatArxHoldsNow() async {
		let fixture = MigrationClearingFixture()
		let state = fixture.state()
		let store = fixture.store(state)
		let stale = MigrationAssistantFeature.ExistingData(profileNames: ["Work"], spaceCount: 1, tabCount: 1)

		await store.send(.onboarding(.page(.migration(.migration(.delegate(.clearExistingData(stale)))))))
		await store.receive(\.onboarding.page.migration.migration.event.clearFailed)
		await store.finish()

		expectNoDifference(store.state.workspace, state.workspace)
		#expect(fixture.events.isEmpty)
		expectNoDifference(store.state.onboarding?.page.migration?.migration?.existingData, fixture.existing)
	}

	@Test
	internal func aPrivateWindowOpenedFromAnOldProfileStopsTheClearBeforeAnythingChanges() async {
		let fixture = MigrationClearingFixture()
		var state = fixture.state()
		state.privateProfileOpeners = [.init(rawValue: UUID(90)): fixture.home]
		let store = fixture.store(state)

		await store.send(fixture.clear)
		await store.receive(\.onboarding.page.migration.migration.event.clearFailed)
		await store.finish()

		expectNoDifference(store.state.workspace, state.workspace)
		#expect(fixture.events.isEmpty)
	}

	@Test
	internal func aFirstOnboardingsProvisionalDefaultIsReplacedByTheFreshOne() async {
		let fixture = MigrationClearingFixture()
		let state = fixture.state()
		let provisional = ProvisionalProfile(profileID: fixture.work, spaceID: fixture.workSpace)
		state.$onboardingProgress.withLock { $0.provisionalProfile = provisional }
		let store = fixture.store(state)

		await store.send(fixture.clear)
		await store.receive(\.migrationClearing.approved)
		await store.send(fixture.saved(store))
		await store.receive(\.onboarding.page.migration.migration.event.cleared)
		await store.finish()

		let fresh = store.state.onboardingProgress.provisionalProfile
		#expect(fresh != provisional)
		expectNoDifference(fresh?.profileID, store.state.workspace.profiles.first?.id)
		expectNoDifference(fresh?.spaceID, store.state.workspace.spaces.first?.id)
	}
}

/// Two profiles, Work and Home, each with a space and a tab, and an engine that retires
/// profiles durably unless told to fail.
@MainActor
private final class MigrationClearingFixture {
	internal let work: Profile.ID = .init(rawValue: UUID(1))
	internal let home: Profile.ID = .init(rawValue: UUID(2))
	internal let workSpace: Space.ID = .init(rawValue: UUID(11))
	internal let homeSpace: Space.ID = .init(rawValue: UUID(12))
	internal let workTab: BrowserCore.Tab.ID = .init(rawValue: UUID(21))
	internal let homeTab: BrowserCore.Tab.ID = .init(rawValue: UUID(22))

	/// A favorite of Home's, when `hasFavorite`.
	internal let favorite: BrowserCore.Tab.ID = .init(rawValue: UUID(23))
	internal var hasFavorite: Bool = false

	/// An archived tab of Work's, when `hasArchive`.
	internal var hasArchive: Bool = false

	/// Pages closed through the engine.
	internal var closed: [BrowserCore.Tab.ID] = []

	/// Tabs whose page is still opening: no snapshot yet, and the engine refuses to close them.
	internal var opening: Set<BrowserCore.Tab.ID> = []

	/// A page whose close waits for `releaseClose()`.
	internal var holdsClose: BrowserCore.Tab.ID?
	private var heldClose: CheckedContinuation<Void, Never>?
	private let document: WorkspaceDocument = .unsaved()

	internal var events: [String] = []
	internal var persisted: [ProfileRetirementIntent] = []

	/// Pages that refuse to close.
	internal var refusing: Set<BrowserCore.Tab.ID> = []

	/// Profiles the engine fails to retire.
	internal var failing: Set<Profile.ID> = []

	/// Holds the next retirement until `releaseRetirement()`.
	internal var holdsRetirement: Bool = false
	private var heldRetirement: CheckedContinuation<Void, Never>?
	private var revision: UInt64 = 7
	private var retired: [Profile.ID: UUID] = [:]

	internal var existing: MigrationAssistantFeature.ExistingData {
		.init(
			profileNames: organization.profiles.map(\.name),
			spaceCount: organization.spaces.count,
			tabCount: organization.tabs.count
		)
	}

	/// The fresh workspace reaching disk.
	internal func saved(_ store: TestStoreOf<AppFeature>) -> AppFeature.Action {
		.event(.saveSucceeded(store.state.workspace, store.state.persistedPreferences))
	}

	internal var clear: AppFeature.Action {
		.onboarding(.page(.migration(.migration(.delegate(.clearExistingData(existing))))))
	}

	internal var organization: BrowserOrganization {
		var organization = BrowserOrganization(
			profiles: [.init(id: work, name: "Work"), .init(id: home, name: "Home")],
			spaces: [
				.init(id: workSpace, profileID: work, name: "Work", unpinnedTabs: [workTab], selectedTabID: workTab),
				.init(id: homeSpace, profileID: home, name: "Home", unpinnedTabs: [homeTab], selectedTabID: homeTab),
			],
			tabs: [
				.init(id: workTab, profileID: work, restoration: .init(title: "Work", url: URL(string: "https://capturecontext.dev/work")!)),
				.init(id: homeTab, profileID: home, restoration: .init(title: "Home", url: URL(string: "https://capturecontext.dev/home")!)),
			]
		)
		if hasFavorite {
			organization.profiles[id: home]?.favorites = [favorite]
			organization.tabs.append(
				.init(
					id: favorite,
					profileID: home,
					savedDestination: .init(title: "Mail", url: URL(string: "https://capturecontext.dev/mail")!),
					restoration: .init(title: "Mail", url: URL(string: "https://capturecontext.dev/mail")!)
				)
			)
		}
		if hasArchive {
			organization.archive = [
				.init(
					id: .init(rawValue: UUID(24)),
					groupID: UUID(25),
					closedAt: Date(timeIntervalSince1970: 1_800_000_000),
					originalSpaceID: workSpace,
					originalSpaceName: "Work",
					originalIndex: 0,
					tab: .init(
						id: .init(rawValue: UUID(26)),
						profileID: work,
						restoration: .init(title: "Old", url: URL(string: "https://capturecontext.dev/old")!)
					)
				)
			]
		}
		return organization
	}

	/// Onboarding's import page with the assistant waiting for the host to clear.
	internal func state() -> AppFeature.State {
		var state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: workSpace))
		}
		state.settings.retirementAvailable = true
		let destination = MigrationDestination(profileID: work, spaceID: workSpace)
		var page = OnboardingImport.State(destination: destination, existingData: existing)
		page.migration = .init(
			destination: destination,
			phase: .clearing,
			existingData: existing,
			clearsExistingData: true
		)
		var onboarding = OnboardingFeature.State(
			mode: .step(.migration),
			destination: destination,
			existingData: existing
		)
		onboarding.page = .migration(page)
		state.onboarding = onboarding
		return state
	}

	internal func store(_ state: AppFeature.State) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.workspaceDocument = document
			$0.browserEngine.status = { .ready }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.close = { [self] id in closed.append(id) }

			// A page is open until closed, or until shown again.
			$0.browserEngine.snapshot = { [self] id in
				closed.contains(id) || opening.contains(id) ? nil : .init(navigation: .init(), revision: 3)
			}
			$0.browserEngine.open = { [self] tab in closed.removeAll { $0 == tab.id } }
			$0.browserEngine.permitsClosing = { _ in
				Issue.record("Clearing asks each page in the step that closes it")
				return false
			}
			$0.browserEngine.retirementIsAvailable = { true }
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.blockProfileRetirement = { _ in }
			$0.browserEngine.profileRetirementSnapshot = { [self] in snapshot() }

			// Asks the page's current document, then closes it. A closed page has nothing to ask.
			$0.browserEngine.closeAuthorized = { [self] id, _, authorize, didClose in
				guard !opening.contains(id) else { return false }
				guard !closed.contains(id) else { return true }
				events.append("permit \(id.rawValue)")
				if holdsClose == id {
					holdsClose = nil
					await withCheckedContinuation { heldClose = $0 }
				}
				guard authorize() else { throw ProfileRetirementFailure.stale }
				guard !refusing.contains(id) else { return false }

				closed.append(id)
				didClose()
				return true
			}
			$0.browserEngine.retireProfile = { [self] request, authorize in
				events.append("queue \(request.profileID.rawValue)")
				if holdsRetirement { await withCheckedContinuation { heldRetirement = $0 } }
				guard authorize(), !failing.contains(request.profileID)
				else { throw ProfileRetirementFailure.io }

				retired[request.profileID] = request.requestID
				revision += 1
				return snapshot()
			}
			$0.profileRetirementPersistence.record = { [self] intent in persisted.append(intent) }
			$0.profileRetirementPersistence.acknowledge = { _ in }
			$0.profileRetirementPersistence.authorize = { _ in true }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}

	internal func waitForRetirement() async throws {
		for _ in 0..<1000 {
			if heldRetirement != nil { return }
			await Task.yield()
		}
		throw ProfileRetirementFailure.busy
	}

	internal func waitForClose() async throws {
		for _ in 0..<1000 {
			if heldClose != nil { return }
			await Task.yield()
		}
		throw ProfileRetirementFailure.busy
	}

	internal func releaseClose() {
		heldClose?.resume()
		heldClose = nil
	}

	internal func releaseRetirement() {
		heldRetirement?.resume()
		heldRetirement = nil
	}

	private func snapshot() -> ProfileRetirementSnapshot {
		.init(
			revision: revision,
			isDurable: true,
			records: [work, home].map { id in
				.init(
					profileID: id,
					requestID: retired[id],
					state: retired[id] == nil ? .active : .awaitingStartup
				)
			}
		)
	}
}
