import BrowserCore
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

@Suite(.dependencies)
@MainActor
internal struct OnboardingPresentationTests {
	@Test
	internal func firstLaunchPresentsAndDismissalPersistsOnlyThePreference() async throws {
		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let workspace = BrowserWorkspaceClient(file: directory.appendingPathComponent("workspace.json"))
		let organization = fixture()
		let store = TestStore(initialState: state(organization)) {
			CombineReducers {
				AppFeature()
				WorkspacePersistence(workspace: workspace)
			}
		} withDependencies: {
			$0.continuousClock = ImmediateClock()
		}

		await store.send(.presentOnboardingIfNeeded) {
			$0.onboarding = .init(destination: self.destination, spaceOptions: self.spaceOptions(organization))
			$0.onboardingFocusRequest = 1

			// A first launch holds the main window back until onboarding ends (DEV-838).
			$0.windowIsOpen = false
			$0.mainWindowWaitsForOnboarding = true
		}
		await store.send(.onboarding(.ui(.dismiss))) {
			// Shared state: the delegate action runs inside this send.
			$0.$onboardingProgress.withLock { $0.introductionDismissed = true }
		}
		await store.receive(\.onboarding.delegate.dismissed) {
			$0.onboarding = nil
			$0.windowIsOpen = true
			$0.mainWindowWaitsForOnboarding = false
			$0.focusedWindowID = $0.main.id
			$0.unsavedOrganization = organization
		}
		await store.receive(\.delegate.save)

		// The main window held back for onboarding opens, then the links that waited (DEV-838).
		await store.receive(\.processRouteQueue)
		await store.receive(\.flushWorkspaceSave)
		await store.receive(\.event.saveSucceeded) {
			$0.unsavedOrganization = nil
		}

		let saved = try workspace.loadWithRecovery()
		expectNoDifference(saved.organization, organization)
		expectNoDifference(saved.preferences.onboarding, OnboardingPreferences(introductionDismissed: true))
		expectNoDifference(store.state.workspace, organization)
		expectNoDifference(store.state.main.sidebar.organization, organization)

		// The next launch reads the dismissed preference and stays quiet.
		let relaunched = TestStore(initialState: state(organization, preferences: saved.preferences)) {
			AppFeature()
		}
		await relaunched.send(.presentOnboardingIfNeeded)
	}

	@Test
	internal func closingTheWindowCountsAsDismissal() async {
		let organization = fixture()
		let store = TestStore(initialState: state(organization)) { AppFeature() }

		await store.send(.presentOnboardingIfNeeded) {
			$0.onboarding = .init(destination: self.destination, spaceOptions: self.spaceOptions(organization))
			$0.onboardingFocusRequest = 1

			// A first launch holds the main window back until onboarding ends (DEV-838).
			$0.windowIsOpen = false
			$0.mainWindowWaitsForOnboarding = true
		}
		await store.send(.ui(.command(.closeTab, .onboarding))) {
			// Shared state: the delegate action runs inside this send.
			$0.$onboardingProgress.withLock { $0.introductionDismissed = true }
		}
		await store.receive(\.ui.closeOnboarding) {
			$0.onboarding = nil
			$0.windowIsOpen = true
			$0.mainWindowWaitsForOnboarding = false
			$0.focusedWindowID = $0.main.id
			$0.unsavedOrganization = organization
		}
		await store.receive(\.delegate.save)

		// The main window held back for onboarding opens, then the links that waited (DEV-838).
		await store.receive(\.processRouteQueue)

		// A late native close notification after dismissal is ignored.
		await store.send(.ui(.closeOnboarding))
		expectNoDifference(store.state.onboardingProgress.completedSteps, [])
	}

	@Test
	internal func reopeningAfterDismissalKeepsWorkspaceAndDoesNotSaveAgain() async {
		let organization = fixture()
		var preferences = BrowserPreferences()
		preferences.onboarding = .init(introductionDismissed: true, completedSteps: [.migration])
		let store = TestStore(initialState: state(organization, preferences: preferences)) {
			AppFeature()
		}

		await store.send(.presentOnboardingIfNeeded)
		await store.send(.ui(.command(.onboarding, .application)))
		await store.receive(\.ui.openOnboarding) {
			$0.onboarding = .init(
				completedSteps: [.migration],
				destination: self.destination,
				spaceOptions: self.spaceOptions(organization)
			)
			$0.onboardingFocusRequest = 1
		}

		// Reopening an already presented window only refocuses it.
		await store.send(.ui(.openOnboarding)) {
			$0.onboardingFocusRequest = 2
		}

		await store.send(.onboarding(.ui(.dismiss)))
		await store.receive(\.onboarding.delegate.dismissed) {
			$0.onboarding = nil
		}

		expectNoDifference(store.state.workspace, organization)
		expectNoDifference(store.state.main.sidebar.organization, organization)
		expectNoDifference(store.state.persistedPreferences, preferences)
		expectNoDifference(store.state.unsavedOrganization, nil)
	}

	@Test
	internal func onboardingCommandIsAvailableEverywhereAndCloseOnlyWhilePresented() async {
		let organization = fixture()
		var appState = state(organization)
		#expect(appState.commandContext(for: .onboarding) == nil)
		let application = appState.commandContext(for: .application)
		#expect(application.map(BrowserCommand.onboarding.isEnabled(in:)) == true)

		appState.onboarding = .init(destination: destination)
		let onboarding = appState.commandContext(for: .onboarding)
		#expect(onboarding.map(BrowserCommand.closeTab.isEnabled(in:)) == true)
		#expect(onboarding.map(BrowserCommand.newSplit.isEnabled(in:)) == false)
	}

	@Test
	internal func completedStepIsPersistedSeparatelyFromDismissal() async {
		let organization = fixture()
		let store = TestStore(initialState: state(organization)) { AppFeature() }

		await store.send(.ui(.openOnboarding)) {
			$0.onboarding = .init(destination: self.destination, spaceOptions: self.spaceOptions(organization))
			$0.onboardingFocusRequest = 1
		}
		await store.send(.onboarding(.delegate(.stepCompleted(.migration)))) {
			$0.$onboardingProgress.withLock { $0.completedSteps = [.migration] }
			$0.unsavedOrganization = organization
		}
		await store.receive(\.delegate.save)
		#expect(!store.state.onboardingProgress.introductionDismissed)

		// Reporting the same step again doesn't save again.
		await store.send(.onboarding(.delegate(.stepCompleted(.migration))))
		expectNoDifference(store.state.workspace, organization)
	}

	@Test
	internal func closingIsRefusedWhileAnImportIsCommitting() async {
		let organization = fixture()
		var initial = state(organization)
		var migration = MigrationAssistantFeature.State(destination: destination)
		migration.phase = .importing
		var onboarding = OnboardingFeature.State(mode: .step(.migration), destination: destination)
		onboarding.page = .migration(.init(destination: destination, migration: migration))
		initial.onboarding = onboarding
		let store = TestStore(initialState: initial) { AppFeature() }

		await store.send(.ui(.closeOnboarding))
		await store.send(.ui(.command(.closeTab, .onboarding)))
		await store.receive(\.ui.closeOnboarding)
		#expect(store.state.onboarding != nil)
		#expect(!store.state.onboardingProgress.introductionDismissed)
	}

	@Test
	internal func quittingPartwayResumesAtTheFirstUnfinishedStep() async {
		let organization = fixture()
		let store = TestStore(initialState: state(organization)) { AppFeature() }

		await store.send(.presentOnboardingIfNeeded) {
			$0.onboarding = .init(destination: self.destination, spaceOptions: self.spaceOptions(organization))
			$0.onboardingFocusRequest = 1

			// A first launch holds the main window back until onboarding ends (DEV-838).
			$0.windowIsOpen = false
			$0.mainWindowWaitsForOnboarding = true
		}
		await store.send(.onboarding(.page(.welcome(.ui(.getStarted))))) {
			// Shared state: the delegate action runs inside this send.
			$0.$onboardingProgress.withLock { $0.completedSteps = [.welcome] }
		}
		await store.receive(\.onboarding.page.welcome.delegate.finished) {
			$0.onboarding?.completedSteps = [.welcome]
			$0.onboarding?.index = 1
			$0.onboarding?.page = .tour(.init())
		}
		await store.receive(\.onboarding.delegate.stepCompleted) {
			$0.unsavedOrganization = organization
		}
		await store.receive(\.delegate.save)
		await store.send(.onboarding(.ui(.skip))) {
			$0.onboarding?.index = 2
			$0.onboarding?.page = .migration(
				.init(destination: self.destination, spaceOptions: self.spaceOptions(organization))
			)
			$0.onboarding?.importWasShown = true
		}

		// Quitting with the window open: the next launch presents it again at the tour.
		let relaunched = TestStore(
			initialState: state(organization, preferences: store.state.persistedPreferences)
		) {
			AppFeature()
		}
		await relaunched.send(.presentOnboardingIfNeeded) {
			$0.onboarding = .init(
				completedSteps: [.welcome],
				destination: self.destination,
				spaceOptions: self.spaceOptions(organization)
			)
			$0.onboardingFocusRequest = 1

			// A first launch holds the main window back until onboarding ends (DEV-838).
			$0.windowIsOpen = false
			$0.mainWindowWaitsForOnboarding = true
		}
		#expect(relaunched.state.onboarding?.step == .tour)
		#expect(!relaunched.state.onboardingProgress.introductionDismissed)
	}

	@Test
	internal func theEndOfTheFlowHandsOffToTheMainWindow() async {
		let organization = fixture()
		var preferences = BrowserPreferences()
		preferences.onboarding.completedSteps = [.welcome, .tour, .migration, .outsideAgents]
		let store = TestStore(initialState: state(organization, preferences: preferences)) {
			AppFeature()
		}

		await store.send(.presentOnboardingIfNeeded) {
			$0.onboarding = .init(
				completedSteps: preferences.onboarding.completedSteps,
				destination: self.destination,
				spaceOptions: self.spaceOptions(organization)
			)
			$0.onboardingFocusRequest = 1

			// A first launch holds the main window back until onboarding ends (DEV-838).
			$0.windowIsOpen = false
			$0.mainWindowWaitsForOnboarding = true
		}
		#expect(store.state.onboarding?.step == .defaultBrowser)

		await store.send(.onboarding(.ui(.continueSetup))) {
			// Shared state: the delegate action runs inside this send.
			$0.$onboardingProgress.withLock { $0.introductionDismissed = true }
		}
		await store.receive(\.onboarding.delegate.handOff) {
			$0.onboarding = nil
			$0.windowIsOpen = true
			$0.mainWindowWaitsForOnboarding = false
			$0.focusedWindowID = $0.main.id
			$0.onboardingHandOffRequest = 1
			$0.unsavedOrganization = organization
		}
		await store.receive(\.delegate.save)

		// The main window held back for onboarding opens, then the links that waited (DEV-838).
		await store.receive(\.processRouteQueue)
		expectNoDifference(
			store.state.onboardingProgress.completedSteps,
			preferences.onboarding.completedSteps
		)
	}

	@Test
	internal func theHandOffSelectsTheSpaceAnImportCreated() async {
		let organization = fixture(extraSpace: imported)
		let store = TestStore(initialState: state(organization)) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.openOnboarding))
		await store.send(.onboarding(.event(.importCreatedSpace(imported))))
		await store.send(.onboarding(.ui(.skipSetup)))
		await store.receive(\.onboarding.delegate.handOff, imported)
		await store.receive(\.main.sidebar.ui.spaceSelected, imported)

		#expect(store.state.onboarding == nil)
		#expect(store.state.onboardingHandOffRequest == 1)
		#expect(store.state.main.sidebar.spaceID == imported)
	}

	@Test
	internal func settingsOpensOneStepOnItsOwn() async {
		let organization = fixture()
		let store = TestStore(initialState: state(organization)) { AppFeature() }

		await store.send(.ui(.openOnboardingStep(.defaultBrowser))) {
			$0.onboarding = .init(
				mode: .step(.defaultBrowser),
				destination: self.destination,
				spaceOptions: self.spaceOptions(organization)
			)
			$0.onboardingFocusRequest = 1
		}
		#expect(store.state.onboarding?.steps == [.defaultBrowser])

		// Finishing the step closes the window without a hand-off or a finished step.
		await store.send(.onboarding(.ui(.continueSetup))) {
			// Shared state: the delegate action runs inside this send.
			$0.$onboardingProgress.withLock { $0.introductionDismissed = true }
		}
		await store.receive(\.onboarding.delegate.dismissed) {
			$0.onboarding = nil
			$0.unsavedOrganization = organization
		}
		await store.receive(\.delegate.save)
		#expect(store.state.onboardingHandOffRequest == 0)
		expectNoDifference(store.state.onboardingProgress.completedSteps, [])
	}

	@Test(
		arguments: [
			([:], false, true),
			([:], true, false),
			(["ARX_ENGINE_PROFILE": "/tmp/smoke"], false, false),
			(["ARX_SKIP_ONBOARDING": "1"], false, false),
			(["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"], false, false),
		] as [([String: String], Bool, Bool)]
	)
	internal func automatedAndHeadlessRunsNeverPresentOnboarding(
		environment: [String: String],
		isHeadless: Bool,
		presents: Bool
	) {
		#expect(
			OnboardingLaunchPolicy.presentsAutomatically(
				environment: environment,
				isHeadless: isHeadless
			) == presents
		)
	}

	private var imported: Space.ID { .init(rawValue: UUID(5)) }

	private func spaceOptions(_ organization: BrowserOrganization) -> [MigrationAssistantFeature.SpaceOption] {
		organization.spaces.map { space in
			.init(
				profileID: space.profileID,
				profileName: organization.profiles[id: space.profileID]?.name ?? "",
				spaceID: space.id,
				spaceName: space.name
			)
		}
	}

	private var destination: MigrationDestination {
		.init(
			profileID: .init(rawValue: UUID(0)),
			spaceID: .init(rawValue: UUID(1))
		)
	}

	private func state(
		_ organization: BrowserOrganization,
		preferences: BrowserPreferences = .init()
	) -> AppFeature.State {
		.launching(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			),
			preferences: preferences
		)
	}

	private func fixture(extraSpace: Space.ID? = nil) -> BrowserOrganization {
		let profile = Profile.ID(rawValue: UUID(0))
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(2)),
			profileID: profile,
			restoration: .init(
				title: "Example",
				url: URL(string: "https://capturecontext.dev")!
			)
		)
		return .init(
			profiles: [.init(id: profile, name: "Default")],
			spaces: [
				.init(
					id: .init(rawValue: UUID(1)),
					profileID: profile,
					name: "Work",
					unpinnedTabs: [tab.id],
					selectedTabID: tab.id
				),
			] + (extraSpace.map { [.init(id: $0, profileID: profile, name: "Imported")] } ?? []),
			tabs: [tab]
		)
	}
}
