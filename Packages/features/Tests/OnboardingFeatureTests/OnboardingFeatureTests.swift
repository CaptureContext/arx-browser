import BrowserCore
import Foundation
import MigrationAssistant
import MigrationAssistantFeature
import OnboardingFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct OnboardingFeatureTests {
	// MARK: - Paging

	@Test
	internal func firstLaunchOpensTheWelcomePage() {
		let state = OnboardingFeature.State()

		#expect(state.steps == OnboardingFlow.steps)
		#expect(state.step == .welcome)
		#expect(state.page == .welcome(.init()))
		#expect(!state.canGoBack)
		#expect(state.showsProgress)
	}

	@Test
	internal func getStartedFinishesTheWelcomeStepAndMovesOn() async {
		let store = TestStore(initialState: OnboardingFeature.State()) {
			OnboardingFeature()
		}

		await store.send(.page(.welcome(.ui(.getStarted))))
		await store.receive(\.page.welcome.delegate.finished) {
			$0.completedSteps = [.welcome]
			$0.index = 1
			$0.page = .tour(.init())
		}
		await store.receive(\.delegate.stepCompleted)
	}

	@Test
	internal func continueAndBackMoveThroughPagesWithoutRecordingSteps() async {
		let completed: [OnboardingStep] = [.welcome, .tour]
		let store = TestStore(initialState: OnboardingFeature.State(completedSteps: completed)) {
			OnboardingFeature()
		}
		#expect(store.state.step == .migration)

		await store.send(.ui(.continueSetup)) {
			$0.index = 3
			$0.page = .outsideAgents(.init())
		}
		await store.send(.ui(.back)) {
			$0.index = 2
			$0.page = .migration(.init())
			$0.direction = .backward
		}
		await store.send(.ui(.continueSetup)) {
			$0.index = 3
			$0.page = .outsideAgents(.init())
			$0.direction = .forward
		}
		#expect(store.state.completedSteps == completed)
	}

	// MARK: - Tour

	@Test
	internal func continueStepsThroughTheTourPagesAndFinishesTheTourAfterTheLast() async {
		let store = TestStore(initialState: OnboardingFeature.State(completedSteps: [.welcome])) {
			OnboardingFeature()
		}
		#expect(store.state.step == .tour)
		#expect(store.state.page.tour?.page == .peek)

		for index in 1..<OnboardingTour.Page.allCases.count {
			await store.send(.ui(.continueSetup)) {
				$0.page = .tour(.init(index: index))
			}
		}
		#expect(store.state.page.tour?.page == .littleArx)
		#expect(store.state.completedSteps == [.welcome])

		await store.send(.ui(.continueSetup)) {
			$0.index = 2
			$0.page = .migration(.init())
			$0.completedSteps = [.welcome, .tour]
			$0.importWasShown = true
		}
		await store.receive(\.delegate.stepCompleted, .tour)
	}

	@Test
	internal func backMovesBetweenTourPagesAndReturnsToTheLastOneFromTheNextStep() async {
		let store = TestStore(
			initialState: OnboardingFeature.State(completedSteps: [.welcome, .tour])
		) {
			OnboardingFeature()
		}
		#expect(store.state.step == .migration)

		await store.send(.ui(.back)) {
			$0.index = 1
			$0.page = .tour(.init(index: 4))
			$0.direction = .backward
		}
		await store.send(.ui(.back)) {
			$0.page = .tour(.init(index: 3))
		}
		await store.send(.ui(.back)) {
			$0.page = .tour(.init(index: 2))
		}
		await store.send(.ui(.back)) {
			$0.page = .tour(.init(index: 1))
		}
		await store.send(.ui(.back)) {
			$0.page = .tour(.init(index: 0))
		}
		#expect(store.state.canGoBack)

		await store.send(.ui(.back)) {
			$0.index = 0
			$0.page = .welcome(.init())
		}

		// There's nothing before the welcome page.
		await store.send(.ui(.back))
	}

	@Test
	internal func skipLeavesTheWholeTourWithoutRecordingIt() async {
		let store = TestStore(
			initialState: OnboardingFeature.State(
				mode: .flow,
				steps: OnboardingFlow.steps,
				index: 1,
				page: .tour(.init(index: 1)),
				direction: .forward,
				completedSteps: [.welcome],
				destination: nil,
				spaceOptions: [],
				importedSpaceID: nil
			)
		) {
			OnboardingFeature()
		}

		await store.send(.ui(.skip)) {
			$0.index = 2
			$0.page = .migration(.init())
			$0.importWasShown = true
		}
		#expect(store.state.completedSteps == [.welcome])
	}

	@Test
	internal func progressCountsEveryTourPage() {
		let pages: Int = OnboardingTour.Page.allCases.count
		let steps: Int = OnboardingFlow.steps.count
		var state = OnboardingFeature.State(completedSteps: [.welcome])

		#expect(state.progress == .init(count: steps - 1 + pages, current: 1))

		state.page = .tour(.init(index: 2))
		#expect(state.progress == .init(count: steps - 1 + pages, current: 3))

		let migration = OnboardingFeature.State(completedSteps: [.welcome, .tour])
		#expect(migration.progress == .init(count: steps - 1 + pages, current: 1 + pages))
	}

	@Test
	internal func theTourOpenedOnItsOwnPagesWithBackAndClosesAfterTheLastPage() async {
		let store = TestStore(initialState: OnboardingFeature.State(mode: .step(.tour))) {
			OnboardingFeature()
		}
		#expect(!store.state.canGoBack)
		#expect(store.state.progress == .init(count: OnboardingTour.Page.allCases.count, current: 0))

		await store.send(.ui(.continueSetup)) {
			$0.page = .tour(.init(index: 1))
		}
		#expect(store.state.canGoBack)

		await store.send(.ui(.back)) {
			$0.page = .tour(.init(index: 0))
			$0.direction = .backward
		}
		await store.send(.ui(.skip))
		await store.receive(\.delegate.dismissed)
	}

	@Test
	internal func skipMovesOnWithoutRecordingTheStep() async {
		let completed: [OnboardingStep] = [.welcome, .tour]
		let store = TestStore(initialState: OnboardingFeature.State(completedSteps: completed)) {
			OnboardingFeature()
		}

		await store.send(.ui(.skip)) {
			$0.index = 3
			$0.page = .outsideAgents(.init())
		}
		#expect(store.state.completedSteps == completed)
	}

	@Test
	internal func skipSetupOnTheWelcomePageHandsOffWithoutRecording() async {
		let store = TestStore(initialState: OnboardingFeature.State()) {
			OnboardingFeature()
		}

		await store.send(.ui(.skipSetup))
		await store.receive(\.delegate.handOff)
		#expect(store.state.completedSteps.isEmpty)
	}

	@Test
	internal func theLastPageHandsOffWithTheImportedSpace() async {
		let space = Space.ID(rawValue: UUID(9))
		let completed: [OnboardingStep] = [.welcome, .tour, .migration, .outsideAgents]
		let store = TestStore(initialState: OnboardingFeature.State(completedSteps: completed)) {
			OnboardingFeature()
		}
		#expect(store.state.step == .defaultBrowser)

		await store.send(.event(.importCreatedSpace(space))) {
			$0.importedSpaceID = space
		}
		await store.send(.ui(.continueSetup))
		await store.receive(\.delegate.handOff, space)
	}

	// MARK: - Resuming

	@Test(
		arguments: [
			([], OnboardingStep.welcome),
			([.welcome], .tour),
			([.welcome, .migration], .tour),
			([.welcome, .tour, .migration], .outsideAgents),
			(OnboardingFlow.steps, .welcome),
		] as [([OnboardingStep], OnboardingStep)]
	)
	internal func reopeningResumesAtTheFirstUnfinishedStep(
		completed: [OnboardingStep],
		expected: OnboardingStep
	) {
		let state = OnboardingFeature.State(completedSteps: completed)

		#expect(state.step == expected)
		#expect(state.index == OnboardingFlow.steps.firstIndex(of: expected))
	}

	// MARK: - Single steps

	@Test
	internal func aStepOpenedOnItsOwnClosesWhenDone() async {
		let store = TestStore(initialState: OnboardingFeature.State(mode: .step(.defaultBrowser))) {
			OnboardingFeature()
		}
		#expect(store.state.steps == [.defaultBrowser])
		#expect(!store.state.canGoBack)
		#expect(!store.state.showsProgress)

		await store.send(.ui(.back))
		await store.send(.ui(.continueSetup))
		await store.receive(\.delegate.dismissed)
	}

	// MARK: - Dismissal

	@Test
	internal func dismissDelegatesWithoutRecordingCompletedSteps() async {
		let store = TestStore(initialState: OnboardingFeature.State(completedSteps: [.welcome])) {
			OnboardingFeature()
		}

		await store.send(.ui(.dismiss))
		await store.receive(\.delegate.dismissed)
		#expect(store.state.completedSteps == [.welcome])
	}

	@Test
	internal func dismissIsRefusedWhileAnImportIsRunning() async {
		var state = migrating()
		var migration = MigrationAssistantFeature.State(destination: destination)
		migration.phase = .importing
		state.page = .migration(.init(destination: destination, migration: migration))
		let store = TestStore(initialState: state) { OnboardingFeature() }

		#expect(!store.state.canClose)
		await store.send(.ui(.dismiss))
		await store.send(.ui(.continueSetup))
	}

	// MARK: - Import

	@Test
	internal func importOpensTheImportPageAndItsAssistant() async {
		let store = TestStore(initialState: OnboardingFeature.State(destination: destination)) {
			OnboardingFeature()
		}

		await store.send(.ui(.importData)) {
			$0.index = 2
			$0.page = .migration(.init(destination: self.destination))
			$0.importWasShown = true
		}
		await store.receive(\.page.migration.ui.importData) {
			$0.page = .migration(
				.init(
					destination: self.destination,
					migration: .init(destination: self.destination)
				)
			)
		}
		#expect(!store.state.showsFooter)

		await store.send(.page(.migration(.migration(.delegate(.dismissed))))) {
			$0.page = .migration(.init(destination: self.destination))
		}
		#expect(store.state.completedSteps.isEmpty)
	}

	@Test(arguments: [MigrationReport.Outcome.partiallyCompleted, .failed, .cancelled])
	internal func onlyACompletedImportRecordsTheMigrationStep(
		outcome: MigrationReport.Outcome
	) async {
		let store = TestStore(initialState: migrating()) { OnboardingFeature() }

		await store.send(.page(.migration(.migration(.delegate(.finished(report(outcome))))))) {
			$0.page = .migration(finished(outcome))
		}
	}

	@Test
	internal func completedImportReportsTheStepOnce() async {
		let store = TestStore(initialState: migrating()) { OnboardingFeature() }

		await store.send(.page(.migration(.migration(.delegate(.finished(report(.completed))))))) {
			$0.page = .migration(finished(.completed))
		}
		await store.receive(\.page.migration.delegate.completed) {
			$0.completedSteps = [.migration]
		}
		await store.receive(\.delegate.stepCompleted)

		await store.send(.page(.migration(.ui(.importData)))) {
			var page = finished(.completed)
			page.migration = .init(destination: self.destination)
			$0.page = .migration(page)
		}
		await store.send(.page(.migration(.migration(.delegate(.finished(report(.completed))))))) {
			$0.page = .migration(finished(.completed))
		}
		await store.receive(\.page.migration.delegate.completed)
	}

	@Test
	internal func backLeavesOnceAnImportCompletes() {
		var state = OnboardingFeature.State(mode: .flow, destination: destination)
		state.index = state.steps.firstIndex(of: .migration) ?? 0
		state.page = .migration(finished(.failed))
		#expect(state.canGoBack)

		// What it brought stays in Arx, so there's nothing to go back for.
		state.page = .migration(finished(.completed))
		#expect(!state.canGoBack)
	}

	// MARK: - Helpers

	private var destination: MigrationDestination {
		.init(
			profileID: .init(rawValue: UUID(0)),
			spaceID: .init(rawValue: UUID(1))
		)
	}

	private func migrating() -> OnboardingFeature.State {
		var state = OnboardingFeature.State(
			mode: .step(.migration),
			destination: destination
		)
		state.page = .migration(
			.init(
				destination: destination,
				migration: .init(destination: destination)
			)
		)
		return state
	}

	/// The import page showing the result the assistant reported.
	private func finished(_ outcome: MigrationReport.Outcome) -> OnboardingImport.State {
		.init(
			destination: destination,
			phase: .finished,
			report: report(outcome)
		)
	}

	private func report(_ outcome: MigrationReport.Outcome) -> MigrationReport {
		.init(
			planID: .init(rawValue: UUID(2)),
			outcome: outcome,
			categories: []
		)
	}
}
