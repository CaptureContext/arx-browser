import AgentClient
import BrowserCore
import Foundation
import MigrationAssistant
import MigrationAssistantFeature
import OutsideAgentsFeature
import _ComposableArchitecture

/// The paged onboarding window.
///
/// It never edits organization, profiles or sessions. The parent owns presentation,
/// persistence and the hand-off; this feature only reports finished steps and
/// where the flow ended.
@Reducer
public struct OnboardingFeature {
	@ObservableState
	public struct State: Equatable {
		/// Whether the window shows the whole flow or one step opened from Settings.
		public var mode: Mode

		/// The pages this window steps through, in order.
		public var steps: [OnboardingStep]

		/// The index of the visible page in `steps`.
		public var index: Int

		/// The visible page's own state.
		public var page: Page

		/// Which way the last page change went, so the view slides the right way.
		public var direction: Direction

		/// Finished steps, supplied by the parent from persisted preferences.
		public var completedSteps: [OnboardingStep]

		/// Where the import page imports into, supplied by the parent.
		public var destination: MigrationDestination?

		/// Existing spaces the import page can import into, supplied by the parent.
		public var spaceOptions: [MigrationAssistantFeature.SpaceOption]

		/// What "Clear Arx data first" would remove, supplied by a parent that can clear
		/// (DEV-833). Nil on a fresh Arx.
		public var existingData: MigrationAssistantFeature.ExistingData?

		/// A space an import created, which the hand-off selects in the main window.
		public var importedSpaceID: Space.ID?

		/// How the "Sync with iCloud" step ended (DEV-1215), once it has. The parent sets
		/// `adopted` when its background wait adopts iCloud's workspace later.
		public var iCloudResolution: OnboardingICloud.Resolution?

		/// The import page has been shown in this window, so something may have been imported,
		/// passwords and sign-ins included, which the workspace doesn't show (DEV-1215).
		public var importWasShown: Bool

		/// Opens at the first unfinished step of `mode`.
		///
		/// - Parameters:
		///   - offersICloud: The flow includes "Sync with iCloud" (DEV-1215). The parent sets it
		///     while the first launch's Default profile is held back for that step.
		///   - iCloudResolution: How that step ended before a relaunch, when it adopted iCloud's
		///     workspace.
		public init(
			mode: Mode = .flow,
			completedSteps: [OnboardingStep] = [],
			destination: MigrationDestination? = nil,
			spaceOptions: [MigrationAssistantFeature.SpaceOption] = [],
			existingData: MigrationAssistantFeature.ExistingData? = nil,
			offersICloud: Bool = false,
			iCloudResolution: OnboardingICloud.Resolution? = nil
		) {
			let steps: [OnboardingStep] = mode.steps(offersICloud: offersICloud)
			let step: OnboardingStep = OnboardingFlow.resumeStep(
				in: steps,
				completed: completedSteps
			) ?? .welcome

			self.init(
				mode: mode,
				steps: steps,
				index: steps.firstIndex(of: step) ?? 0,
				page: OnboardingFlow.page(
					for: step,
					destination: destination,
					spaceOptions: spaceOptions,
					existingData: existingData,
					iCloudResolution: iCloudResolution
				),
				direction: .forward,
				completedSteps: completedSteps,
				destination: destination,
				spaceOptions: spaceOptions,
				importedSpaceID: nil,
				existingData: existingData
			)
			self.iCloudResolution = iCloudResolution
		}

		public init(
			mode: Mode,
			steps: [OnboardingStep],
			index: Int,
			page: Page,
			direction: Direction,
			completedSteps: [OnboardingStep],
			destination: MigrationDestination?,
			spaceOptions: [MigrationAssistantFeature.SpaceOption],
			importedSpaceID: Space.ID?,
			existingData: MigrationAssistantFeature.ExistingData? = nil
		) {
			self.mode = mode
			self.steps = steps
			self.index = index
			self.page = page
			self.direction = direction
			self.completedSteps = completedSteps
			self.destination = destination
			self.spaceOptions = spaceOptions
			self.importedSpaceID = importedSpaceID
			self.existingData = existingData
			self.iCloudResolution = nil
			self.importWasShown = page.migration != nil
		}

		/// iCloud's workspace replaced the first launch's (DEV-1215).
		public var workspaceCameFromICloud: Bool {
			iCloudResolution?.adoptedWorkspace == true
		}

		/// Takes the host's current destination, spaces and data, for this flow, its import
		/// page and the open assistant (DEV-833).
		public mutating func updateMigrationTargets(
			destination: MigrationDestination?,
			spaceOptions: [MigrationAssistantFeature.SpaceOption],
			existingData: MigrationAssistantFeature.ExistingData?
		) {
			self.destination = destination
			self.spaceOptions = spaceOptions
			self.existingData = existingData
			guard case var .migration(migration) = page else { return }

			migration.updateMigrationTargets(
				destination: destination,
				spaceOptions: spaceOptions,
				existingData: existingData
			)
			page = .migration(migration)
		}

		/// The visible step.
		public var step: OnboardingStep {
			steps.indices.contains(index) ? steps[index] : .welcome
		}

		/// Back is offered after the first page of the full flow, and between tour pages, but
		/// not once an import has completed: what it brought stays, so there's nothing to redo.
		public var canGoBack: Bool {
			if page.tour?.isOnFirstPage == false { return true }
			if page.migration?.isCompleted == true { return false }

			return mode == .flow && index > 0
		}

		/// Page dots are shown when there's more than one page; each tour page has its own.
		public var showsProgress: Bool {
			progress != nil
		}

		/// One dot per page, counting each tour page, and the visible one.
		public var progress: Progress? {
			let counts: [Int] = steps.map { step in
				step == .tour ? OnboardingTour.Page.allCases.count : 1
			}
			let count: Int = counts.reduce(0, +)
			guard count > 1 else { return nil }

			let current: Int = counts.prefix(index).reduce(0, +) + (page.tour?.index ?? 0)
			return .init(count: count, current: current)
		}

		/// The footer is hidden while the import assistant shows its own controls.
		public var showsFooter: Bool {
			page.migration?.migration == nil
		}

		/// Closing and leaving the page are refused while an import may be committing,
		/// macOS's default-browser confirmation may be showing, or the outside-agents page
		/// is installing the command or writing an agent app's configuration.
		public var canClose: Bool {
			guard page.defaultBrowser?.isRequesting != true
			else { return false }

			if let outsideAgents = page.outsideAgents {
				guard outsideAgents.toolActivity == nil, outsideAgents.adding == nil
				else { return false }
			}

			return page.migration?.canClose ?? true
		}
	}

	public enum Mode: Equatable, Sendable {
		/// Every page of ``OnboardingFlow/steps``, ending in the hand-off to the main window.
		case flow

		/// A single step opened from Settings; finishing it just closes the window.
		case step(OnboardingStep)

		public var steps: [OnboardingStep] {
			steps(offersICloud: false)
		}

		public func steps(offersICloud: Bool) -> [OnboardingStep] {
			switch self {
			case .flow: OnboardingFlow.steps(offersICloud: offersICloud)
			case let .step(step): [step]
			}
		}
	}

	/// Where the page dots are.
	public struct Progress: Equatable, Sendable {
		public var count: Int
		public var current: Int

		public init(
			count: Int,
			current: Int
		) {
			self.count = count
			self.current = current
		}
	}

	public enum Direction: Equatable, Sendable {
		case forward
		case backward
	}

	/// The visible page. Each case is its own child feature, built by ``OnboardingFlow``.
	@CasePathable
	@dynamicMemberLookup
	public enum Page: Equatable {
		case welcome(OnboardingWelcome.State)
		case iCloud(OnboardingICloud.State)
		case tour(OnboardingTour.State)
		case placeholder(OnboardingPlaceholder.State)
		case migration(OnboardingImport.State)
		case connectAgent(OnboardingConnectAgent.State)
		case outsideAgents(OutsideAgents.State)
		case defaultBrowser(OnboardingDefaultBrowser.State)
	}

	@CasePathable
	public enum Action: Sendable {
		case page(PageAction)
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum PageAction: Sendable {
			case welcome(OnboardingWelcome.Action)
			case iCloud(OnboardingICloud.Action)
			case tour(OnboardingTour.Action)
			case placeholder(OnboardingPlaceholder.Action)
			case migration(OnboardingImport.Action)
			case connectAgent(OnboardingConnectAgent.Action)
			case outsideAgents(OutsideAgents.Action)
			case defaultBrowser(OnboardingDefaultBrowser.Action)
		}

		@CasePathable
		public enum UI: Sendable {
			/// Continue, also on Return. Moves on without finishing the step;
			/// a page records its step itself when its work actually finishes.
			/// On the tour it shows the next tour page, and leaving the last one finishes the tour.
			case continueSetup

			/// Back to the previous page of the flow.
			case back

			/// Moves on without finishing the step. On the tour it leaves every tour page.
			case skip

			/// Leaves onboarding from the welcome page and goes straight to the main window.
			case skipSetup

			/// Shows the import page and opens its assistant.
			case importData

			/// The window's close button, Escape or Command-W.
			case dismiss
		}

		@CasePathable
		public enum Event: Sendable {
			/// An import committed and created this space.
			case importCreatedSpace(Space.ID)
		}

		@CasePathable
		public enum Delegate: Sendable {
			/// The flow ended; the parent closes the window and moves into the main window,
			/// selecting the imported space when there is one.
			case handOff(Space.ID?)

			/// The window closed without reaching the end of the flow.
			case dismissed

			/// A step actually finished; the parent persists it.
			case stepCompleted(OnboardingStep)

			/// Connect on the connect-your-agent page; the parent makes the provider every
			/// ordinary profile's assistant.
			case agentConnected(AgentProvider)

			/// The "Sync with iCloud" step ended, by its own buttons or by leaving the page
			/// (DEV-1215); the parent adopts iCloud's workspace or lets Default sync again.
			case iCloudResolved(OnboardingICloud.Resolution)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		// Pages run before this feature, which may replace the page in response.
		// Two scopes, since one chain of every page is too much for the type checker.
		Scope(state: \.page, action: \.page) {
			EmptyReducer()
				.ifCaseLet(\.welcome, action: \.welcome) { OnboardingWelcome() }
				.ifCaseLet(\.iCloud, action: \.iCloud) { OnboardingICloud() }
				.ifCaseLet(\.tour, action: \.tour) { OnboardingTour() }
				.ifCaseLet(\.placeholder, action: \.placeholder) { OnboardingPlaceholder() }
				.ifCaseLet(\.connectAgent, action: \.connectAgent) { OnboardingConnectAgent() }
		}

		Scope(state: \.page, action: \.page) {
			EmptyReducer()
				.ifCaseLet(\.migration, action: \.migration) { OnboardingImport() }
				.ifCaseLet(\.outsideAgents, action: \.outsideAgents) { OutsideAgents() }
				.ifCaseLet(\.defaultBrowser, action: \.defaultBrowser) { OnboardingDefaultBrowser() }
		}

		// Arx was cleared for an import (DEV-833): the pages after it import into the fresh
		// profile and space, and there's nothing left to clear.
		Pullback(\.page.migration.migration.event.cleared) { state, value in
			let (destination, spaceOptions) = value
			state.destination = destination
			state.spaceOptions = spaceOptions
			state.existingData = nil
			return .none
		}

		Pullback(\.ui.continueSetup) { state in
			guard case var .tour(tour) = state.page else { return state.advance() }
			guard state.canClose else { return .none }

			if tour.showNext() {
				state.page = .tour(tour)
				state.direction = .forward
				return .none
			}

			return .merge(
				state.complete(.tour),
				state.advance()
			)
		}

		Pullback(\.ui.skip) { state in
			state.advance()
		}

		Pullback(\.ui.back) { state in
			guard state.canGoBack, state.canClose else { return .none }

			if case var .tour(tour) = state.page, tour.showPrevious() {
				state.page = .tour(tour)
				state.direction = .backward
				return .none
			}

			return state.show(index: state.index - 1, direction: .backward)
		}

		Pullback(\.ui.skipSetup) { state in
			guard state.mode == .flow else { return state.close() }

			return .send(.delegate(.handOff(state.importedSpaceID)))
		}

		Pullback(\.ui.importData) { state in
			guard state.step != .migration else {
				return .send(.page(.migration(.ui(.importData))))
			}
			guard state.canClose else { return .none }

			let leaving: Effect<Action>
			if let index = state.steps.firstIndex(of: .migration) {
				leaving = state.show(index: index, direction: index < state.index ? .backward : .forward)
			} else {
				state.mode = .step(.migration)
				state.steps = [.migration]
				leaving = state.show(index: 0, direction: .forward)
			}
			return .merge(
				leaving,
				.send(.page(.migration(.ui(.importData))))
			)
		}

		Pullback(\.ui.dismiss) { state in
			state.close()
		}

		Pullback(\.event.importCreatedSpace) { state, id in
			state.importedSpaceID = id
			return .none
		}

		Pullback(\.page.welcome.delegate.finished) { state in
			.merge(
				state.complete(.welcome),
				state.advance()
			)
		}

		Pullback(\.page.iCloud.delegate.resolved) { state, resolution in
			state.iCloudResolution = resolution
			let finished: Effect<Action> = resolution.finishesStep ? state.complete(.iCloud) : .none
			let reported: Effect<Action> = .send(.delegate(.iCloudResolved(resolution)))

			// Without an account the page steps aside, the way it was being passed.
			let next: Effect<Action> = resolution == .unavailable && state.direction == .backward && state.index > 0
			? state.show(index: state.index - 1, direction: .backward)
			: state.advance()
			return .concatenate(finished, reported, next)
		}

		Pullback(\.page.migration.delegate.completed) { state in
			state.complete(.migration)
		}

		Pullback(\.page.connectAgent.delegate.connected) { state, provider in
			.merge(
				state.complete(.connectAgent),
				.send(.delegate(.agentConnected(provider))),
				state.advance()
			)
		}

		// Adding Arx to an agent app is what the page is for; the person moves on with Continue.
		Pullback(\.page.outsideAgents.delegate.connect) { state, _ in
			state.complete(.outsideAgents)
		}

		Pullback(\.page.defaultBrowser.delegate.madeDefault) { state in
			.merge(
				state.complete(.defaultBrowser),
				state.advance()
			)
		}

		Pullback(\.page.defaultBrowser.delegate.foundDefault) { state in
			state.complete(.defaultBrowser)
		}
	}

	/// Cancels the import page's discovery and inspection, the outside-agents and
	/// connect-your-agent pages' checks and the default-browser page's status check, so a parent can drop this state once
	/// `canClose` allows it.
	public static func cancelInFlightWork<Action>() -> Effect<Action> {
		.merge(
			OnboardingImport.cancelInFlightWork(),
			OnboardingICloud.cancelInFlightWork(),
			OutsideAgents.cancelInFlightWork(),
			OnboardingConnectAgent.cancelInFlightWork(),
			OnboardingDefaultBrowser.cancelInFlightWork()
		)
	}
}

extension OnboardingFeature.State {
	/// Moves to the next page, or ends the flow after the last one.
	fileprivate mutating func advance() -> Effect<OnboardingFeature.Action> {
		guard canClose else { return .none }

		let next: Int = index + 1
		guard steps.indices.contains(next) else {
			switch mode {
			case .flow: return .send(.delegate(.handOff(importedSpaceID)))
			case .step: return close()
			}
		}

		return show(index: next, direction: .forward)
	}

	/// Replaces the page, cancelling the work the page being left may still have in flight.
	fileprivate mutating func show(
		index: Int,
		direction: OnboardingFeature.Direction
	) -> Effect<OnboardingFeature.Action> {
		guard steps.indices.contains(index) else { return .none }

		var leaving: Effect<OnboardingFeature.Action> = switch page {
		case .defaultBrowser: OnboardingDefaultBrowser.cancelInFlightWork()
		case .outsideAgents: OutsideAgents.cancelInFlightWork()
		case .connectAgent: OnboardingConnectAgent.cancelInFlightWork()
		case .iCloud: OnboardingICloud.cancelInFlightWork()
		case .welcome, .tour, .placeholder, .migration: .none
		}

		// Leaving "Sync with iCloud" undecided is Not now, or Continue without waiting once it
		// started syncing (DEV-1215).
		if let resolution = page.iCloud?.resolutionOnLeaving {
			iCloudResolution = resolution
			leaving = .merge(
				leaving,
				resolution.finishesStep ? complete(.iCloud) : .none,
				.send(.delegate(.iCloudResolved(resolution)))
			)
		}

		self.index = index
		self.direction = direction
		page = OnboardingFlow.page(
			for: steps[index],
			destination: destination,
			spaceOptions: spaceOptions,
			existingData: existingData,
			iCloudResolution: iCloudResolution
		)

		if page.migration != nil {
			importWasShown = true
		}

		// Back from the step after the tour lands on its last page.
		if direction == .backward, case var .tour(tour) = page {
			tour.showLast()
			page = .tour(tour)
		}
		return leaving
	}

	/// Records a finished step once.
	fileprivate mutating func complete(_ step: OnboardingStep) -> Effect<OnboardingFeature.Action> {
		guard !completedSteps.contains(step) else { return .none }

		completedSteps.append(step)
		return .send(.delegate(.stepCompleted(step)))
	}

	fileprivate func close() -> Effect<OnboardingFeature.Action> {
		guard canClose else { return .none }

		return .merge(
			OnboardingFeature.cancelInFlightWork(),
			.send(.delegate(.dismissed))
		)
	}
}
