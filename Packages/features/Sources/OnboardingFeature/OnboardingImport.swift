import BrowserCore
import DefaultBrowserClient
import Foundation
import MigrationAssistant
import MigrationAssistantFeature
import _ComposableArchitecture

/// "Make it yours": a one-page import summary over MigrationAssistant.
///
/// The page finds the browsers on this Mac, preselects the default browser when Arx
/// can read it (otherwise the one used most recently) and inspects it once per browser
/// and spaces choice. Categories switch on and off without inspecting again. "Bring from"
/// runs the import inline with progress and cancel; "Customize…" opens the full
/// `MigrationAssistantFeature` with the same choices filled in.
///
/// Only a completed import finishes the step. Partial, failed and cancelled imports stay
/// on the page with Try Again, and nothing in the other browser is ever changed.
@Reducer
public struct OnboardingImport {
	@ObservableState
	public struct State: Equatable {
		/// Where imports go, supplied by the parent.
		public var destination: MigrationDestination?

		/// Existing spaces the full assistant can import into, supplied by the parent.
		public var spaceOptions: [MigrationAssistantFeature.SpaceOption]

		/// What "Clear Arx data first" would remove, supplied by a parent that can clear
		/// (DEV-833). The full assistant offers the option only with it.
		public var existingData: MigrationAssistantFeature.ExistingData?

		public var phase: Phase

		/// Browsers Arx can import from, in discovery order.
		public var sources: [MigrationSource]

		/// Browsers on this Mac that Arx can't import from yet, listed so they aren't hidden.
		public var unsupportedBrowsers: [MigrationUnsupportedBrowser]

		/// The bundle identifier of the browser that opens links now, when it could be read.
		public var defaultBrowserIdentifier: String?

		public var selectedSourceID: MigrationSource.ID?
		public var selectedCategories: Set<MigrationCategory>

		/// Whether the source's spaces come in as spaces of their own, or as one list in
		/// the current space. Only offered for sources with spaces.
		public var keepsSpaces: Bool

		/// Inspections already made, so switching back and forth never reads the source again.
		public var previews: [Choice: MigrationPreview]

		/// The choice being inspected now.
		public var inspecting: Choice?

		/// Kept after a run so Try Again reuses the same idempotent plan.
		public var plan: MigrationPlan?
		public var progress: MigrationProgress?
		public var report: MigrationReport?
		public var problem: Problem?

		/// The full assistant while it's open on this page.
		public var migration: MigrationAssistantFeature.State?

		/// Whether Arx can read sources macOS protects with Full Disk Access (Safari, DEV-840).
		public var fullDiskAccess: FullDiskAccessStatus

		/// Chrome Web Store extensions the import brought, installed after it with the user's
		/// review of each (DEV-845). The step finishes once they're done.
		public var extensionImport: ExtensionImportFeature.State?

		/// Onboarding adopted iCloud's workspace (DEV-1215): profiles, spaces, pinned tabs,
		/// Favorites, Tab Archive and preferences came from there, so the page says so and offers
		/// only what iCloud doesn't sync (``MigrationCategory/outsideICloud``, and passwords and
		/// sign-ins through Customize), into the current space.
		public var workspaceCameFromICloud: Bool

		public init(
			destination: MigrationDestination? = nil,
			spaceOptions: [MigrationAssistantFeature.SpaceOption] = [],
			phase: Phase = .idle,
			sources: [MigrationSource] = [],
			unsupportedBrowsers: [MigrationUnsupportedBrowser] = [],
			defaultBrowserIdentifier: String? = nil,
			selectedSourceID: MigrationSource.ID? = nil,
			selectedCategories: Set<MigrationCategory> = [],
			keepsSpaces: Bool = false,
			previews: [Choice: MigrationPreview] = [:],
			inspecting: Choice? = nil,
			plan: MigrationPlan? = nil,
			progress: MigrationProgress? = nil,
			report: MigrationReport? = nil,
			problem: Problem? = nil,
			migration: MigrationAssistantFeature.State? = nil,
			fullDiskAccess: FullDiskAccessStatus = .unknown,
			extensionImport: ExtensionImportFeature.State? = nil,
			existingData: MigrationAssistantFeature.ExistingData? = nil,
			workspaceCameFromICloud: Bool = false
		) {
			self.destination = destination
			self.spaceOptions = spaceOptions
			self.existingData = existingData
			self.phase = phase
			self.sources = sources
			self.unsupportedBrowsers = unsupportedBrowsers
			self.defaultBrowserIdentifier = defaultBrowserIdentifier
			self.selectedSourceID = selectedSourceID
			self.selectedCategories = selectedCategories
			self.keepsSpaces = keepsSpaces
			self.previews = previews
			self.inspecting = inspecting
			self.plan = plan
			self.progress = progress
			self.report = report
			self.problem = problem
			self.migration = migration
			self.fullDiskAccess = fullDiskAccess
			self.extensionImport = extensionImport
			self.workspaceCameFromICloud = workspaceCameFromICloud
		}

		/// The categories this page may bring from `source`.
		public func offeredCategories(of source: MigrationSource) -> [MigrationCategory] {
			guard workspaceCameFromICloud else { return source.categories }

			return source.categories.filter(MigrationCategory.outsideICloud.contains)
		}

		public var selectedSource: MigrationSource? {
			sources.first { $0.id == selectedSourceID }
		}

		/// What the full assistant may bring: everything, or after iCloud only what iCloud
		/// doesn't sync, with passwords and sign-ins still offered (DEV-1220).
		public var assistantCategoryLimit: Set<MigrationCategory>? {
			workspaceCameFromICloud ? MigrationCategory.outsideICloud : nil
		}

		/// Takes the host's current destination, spaces and data, here and in the open
		/// assistant (DEV-833). Previews and a finished run made for another destination are
		/// dropped, so Try Again can't run a plan aimed at profiles that are gone.
		public mutating func updateMigrationTargets(
			destination: MigrationDestination?,
			spaceOptions: [MigrationAssistantFeature.SpaceOption],
			existingData: MigrationAssistantFeature.ExistingData?
		) {
			if destination != self.destination {
				previews = [:]
				if phase == .finished {
					phase = sources.isEmpty ? .idle : .choosing
					plan = nil
					progress = nil
					report = nil
					problem = nil
				}
			}
			self.destination = destination
			self.spaceOptions = spaceOptions
			self.existingData = existingData
			migration?.updateTargets(
				destination: destination,
				spaceOptions: spaceOptions,
				existingData: existingData
			)
		}

		/// The selected browser and spaces choice, which together decide what inspection returns.
		public var choice: Choice? {
			guard let source = selectedSource else { return nil }

			return .init(
				sourceID: source.id,
				keepsSpaces: keepsSpaces && source.offersLayouts
			)
		}

		/// The inspection for the current choice, once it's been read.
		public var preview: MigrationPreview? {
			choice.flatMap { previews[$0] }
		}

		/// The selected browser needs Full Disk Access that Arx doesn't have (yet), so the page
		/// asks for it instead of showing the categories.
		public var needsFullDiskAccess: Bool {
			selectedSource?.requiresFullDiskAccess == true && fullDiskAccess != .granted
		}

		public var isInspecting: Bool {
			inspecting != nil && inspecting == choice
		}

		/// The categories "Bring from" would run: switched on, and with something to bring.
		public var plannedCategories: [MigrationCategory] {
			guard let preview else { return [] }

			return preview.categories
				.filter { selectedCategories.contains($0.category) }
				.filter { !workspaceCameFromICloud || MigrationCategory.outsideICloud.contains($0.category) }
				.filter { !$0.items.isEmpty || $0.preferences != nil || !$0.reinstalls.isEmpty }
				.map(\.category)
		}

		public var canImport: Bool {
			phase == .choosing && !plannedCategories.isEmpty
		}

		public var canRetry: Bool {
			phase == .finished
			&& plan != nil
			&& report?.outcome != .completed
			&& !(report?.retryableCategories.isEmpty ?? true)
			&& !(extensionImport?.isRunning ?? false)
		}

		public var isCompleted: Bool {
			phase == .finished
			&& report?.outcome == .completed
			&& !(extensionImport?.isRunning ?? false)
		}

		/// Closing and leaving are refused while an import may be committing.
		public var canClose: Bool {
			phase != .importing
			&& phase != .cancelling
			&& !(extensionImport?.isRunning ?? false)
			&& migration?.canDismiss ?? true
		}

		/// Where imported items go for a choice: new profiles matching the source's
		/// when its spaces are kept, otherwise the current space.
		public func destination(for choice: Choice) -> MigrationDestination? {
			guard var destination else { return nil }

			if choice.keepsSpaces {
				destination.defaultRoute = .newProfile
			}
			return destination
		}
	}

	/// What an inspection depends on.
	public struct Choice: Hashable, Sendable {
		public var sourceID: MigrationSource.ID
		public var keepsSpaces: Bool

		public init(
			sourceID: MigrationSource.ID,
			keepsSpaces: Bool
		) {
			self.sourceID = sourceID
			self.keepsSpaces = keepsSpaces
		}
	}

	public enum Phase: Equatable, Sendable {
		case idle
		case discovering

		/// Browsers are listed; the user picks one and its categories.
		case choosing
		case importing
		case cancelling

		/// A run ended; `report` holds its result.
		case finished
	}

	public enum Problem: Equatable, Sendable {
		case discoveryFailed
		case missingDestination
		case inspectionFailed

		/// The source changed after it was read; it's read again before importing.
		case sourceChanged
		case importFailed
	}

	/// What discovery found.
	public struct Discovery: Equatable, Sendable {
		public var sources: [MigrationSource]
		public var unsupportedBrowsers: [MigrationUnsupportedBrowser]
		public var defaultBrowserIdentifier: String?

		public init(
			sources: [MigrationSource],
			unsupportedBrowsers: [MigrationUnsupportedBrowser] = [],
			defaultBrowserIdentifier: String? = nil
		) {
			self.sources = sources
			self.unsupportedBrowsers = unsupportedBrowsers
			self.defaultBrowserIdentifier = defaultBrowserIdentifier
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case migration(MigrationAssistantFeature.Action)
		case extensionImport(ExtensionImportFeature.Action)
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			/// The page appeared; finds browsers the first time.
			case task
			case selectSource(MigrationSource.ID)
			case toggleCategory(MigrationCategory)
			case setKeepsSpaces(Bool)

			/// "Bring from <browser>", also on Return.
			case bring
			case cancel
			case retry

			/// Opens the full assistant with this page's choices filled in.
			case customize

			/// Opens the full assistant with this page's choices and Passwords and sign-ins on
			/// (DEV-842).
			case setUpPasswords

			/// Opens the full assistant from the start, as Settings' Import does.
			case importData

			/// Opens System Settings › Privacy & Security › Full Disk Access.
			case allowFullDiskAccess
		}

		@CasePathable
		public enum Event: Sendable {
			case discovered(Discovery)
			case discoveryFailed
			case inspected(Choice, MigrationPreview)
			case inspectionFailed(Choice, MigrationFailure?)
			case execution(MigrationEvent)
			case executionFailed(MigrationFailure?)

			/// Arx came to the front, maybe after the user allowed Full Disk Access.
			case applicationBecameActive
			case fullDiskAccessChecked(Bool)
		}

		@CasePathable
		public enum Delegate: Sendable {
			/// An import committed every planned category.
			case completed
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.date)
	private var date

	@Dependency(\.defaultBrowser)
	private var defaultBrowser

	@Dependency(\.fullDiskAccess)
	private var fullDiskAccess

	@Dependency(\.migrationAssistant)
	private var migrationAssistant

	@Dependency(\.uuid)
	private var uuid

	fileprivate enum Cancellation: Hashable {
		case discovery
		case inspection
		case execution
		case access
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		CombineReducers {
			choosing
			importing
			assistant
			access
		}
		.ifLet(\.migration, action: \.migration) {
			MigrationAssistantFeature()
		}
		.ifLet(\.extensionImport, action: \.extensionImport) {
			ExtensionImportFeature()
		}
	}

	/// Cancels discovery and inspection, here and in the full assistant. An import is
	/// never cancelled this way; hosts drop this state only while `canClose` is true.
	public static func cancelInFlightWork<Action>() -> Effect<Action> {
		.merge(
			.cancel(id: Cancellation.discovery),
			.cancel(id: Cancellation.inspection),
			.cancel(id: Cancellation.access),
			MigrationAssistantFeature.cancelInFlightWork()
		)
	}

	/// The browser to preselect: the default browser when Arx can read it, otherwise
	/// the one used most recently, otherwise the first one found.
	public static func preferredSource(
		in sources: [MigrationSource],
		defaultBrowserIdentifier: String?
	) -> MigrationSource? {
		if let defaultBrowserIdentifier {
			let match: MigrationSource? = sources.first { $0.applicationIdentifier == defaultBrowserIdentifier }
			if let match { return match }
		}

		let recent: MigrationSource? = sources
			.filter { $0.lastUsed != nil }
			.max { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
		return recent ?? sources.first
	}

	// MARK: - Choosing

	private var choosing: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.task) { state in
				guard state.phase == .idle else { return .none }

				state.phase = .discovering
				state.problem = nil
				return .run { [migrationAssistant, defaultBrowser] send in
					do {
						let sources: [MigrationSource] = try await migrationAssistant.discover()
						let unsupported: [MigrationUnsupportedBrowser] = await migrationAssistant.unsupportedBrowsers()
						let identifier: String? = await Self.currentDefault(defaultBrowser)
						await send(.event(.discovered(
							.init(
								sources: sources,
								unsupportedBrowsers: unsupported,
								defaultBrowserIdentifier: identifier
							)
						)))
					} catch {
						await send(.event(.discoveryFailed))
					}
				}
				.cancellable(id: Cancellation.discovery, cancelInFlight: true)
			}

			Pullback(\.event.discovered) { state, discovery in
				guard state.phase == .discovering else { return .none }

				state.phase = .choosing
				state.sources = discovery.sources
				state.unsupportedBrowsers = discovery.unsupportedBrowsers
				state.defaultBrowserIdentifier = discovery.defaultBrowserIdentifier
				let preferred: MigrationSource? = Self.preferredSource(
					in: discovery.sources,
					defaultBrowserIdentifier: discovery.defaultBrowserIdentifier
				)
				guard let preferred else { return .none }

				state.select(preferred)
				return state.prepare(client: migrationAssistant, access: fullDiskAccess)
			}

			Pullback(\.event.discoveryFailed) { state in
				guard state.phase == .discovering else { return .none }

				state.phase = .choosing
				state.problem = .discoveryFailed
				return .none
			}

			Pullback(\.ui.selectSource) { state, id in
				guard
					state.phase == .choosing,
					let source = state.sources.first(where: { $0.id == id })
				else { return .none }

				if state.selectedSourceID != id {
					state.select(source)
				}

				// Choosing the same browser again retries an inspection that failed.
				return state.prepare(client: migrationAssistant, access: fullDiskAccess)
			}

			Pullback(\.ui.toggleCategory) { state, category in
				guard
					state.phase == .choosing,
					let source = state.selectedSource,
					state.offeredCategories(of: source).contains(category)
				else { return .none }

				if state.selectedCategories.contains(category) {
					state.selectedCategories.remove(category)
				} else {
					state.selectedCategories.insert(category)
				}
				return .none
			}

			Pullback(\.ui.setKeepsSpaces) { state, keepsSpaces in
				guard
					state.phase == .choosing,
					!state.workspaceCameFromICloud,
					state.selectedSource?.offersLayouts == true,
					state.keepsSpaces != keepsSpaces
				else { return .none }

				state.keepsSpaces = keepsSpaces
				return state.inspectIfNeeded(client: migrationAssistant)
			}

			Pullback(\.event.inspected) { state, value in
				let (choice, preview) = value
				guard state.inspecting == choice else { return .none }

				state.inspecting = nil
				state.previews[choice] = preview
				return .none
			}

			Pullback(\.event.inspectionFailed) { state, value in
				let (choice, failure) = value
				guard state.inspecting == choice else { return .none }

				state.inspecting = nil
				state.problem = failure == .invalidDestination
				? .missingDestination
				: .inspectionFailed
				return .none
			}
		}
	}

	// MARK: - Importing

	private var importing: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.bring) { state in
				guard state.canImport, var preview = state.preview else { return .none }

				let planned: Set<MigrationCategory> = Set(state.plannedCategories)
				preview.categories.removeAll { !planned.contains($0.category) }
				let plan: MigrationPlan = .init(id: .init(rawValue: uuid()), preview: preview)
				state.plan = plan
				return state.run(plan, client: migrationAssistant, date: date)
			}

			Pullback(\.ui.retry) { state in
				guard state.canRetry, let plan = state.plan else { return .none }

				// The same plan is idempotent: committed items are skipped by key.
				return state.run(plan, client: migrationAssistant, date: date)
			}

			Pullback(\.ui.cancel) { state in
				guard state.phase == .importing, let plan = state.plan else { return .none }

				// Keep consuming the stream so the cancelled report arrives.
				state.phase = .cancelling
				return .run { [migrationAssistant] _ in await migrationAssistant.cancel(plan.id) }
			}

			Pullback(\.event.execution) { state, event in
				guard
					state.phase == .importing || state.phase == .cancelling,
					let plan = state.plan
				else { return .none }

				switch event {
				case let .progress(progress):
					guard progress.planID == plan.id else { return .none }

					state.progress = progress
					return .none

				case let .finished(report):
					guard report.planID == plan.id else { return .none }

					return state.finish(report, installingExtensionsTo: plan.destination)
				}
			}

			// The step finishes once the store extensions are done, however each went.
			Pullback(\.extensionImport.delegate.finished) { state in
				guard state.phase == .finished, state.report?.outcome == .completed else { return .none }

				return .send(.delegate(.completed))
			}

			Pullback(\.event.executionFailed) { state, failure in
				guard state.phase == .importing || state.phase == .cancelling else { return .none }

				state.progress = nil
				guard failure == .sourceChanged else {
					state.phase = state.report == nil ? .choosing : .finished
					state.problem = .importFailed
					return .none
				}

				// Nothing was committed; read the source again so the counts are current.
				state.phase = .choosing
				state.plan = nil
				state.report = nil
				state.previews = [:]
				let effect: Effect<Action> = state.inspectIfNeeded(client: migrationAssistant)
				state.problem = .sourceChanged
				return effect
			}
		}
	}

	// MARK: - Full assistant

	private var assistant: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.customize) { state in
				guard state.migration == nil, state.canClose else { return .none }

				guard state.phase == .choosing else {
					state.migration = .init(
						destination: state.destination,
						spaceOptions: state.spaceOptions,
						existingData: state.existingData,
						categoryLimit: state.assistantCategoryLimit,
						allowsNewProfiles: !state.workspaceCameFromICloud
					)
					return .none
				}

				// The assistant starts at its selection with this page's choices, so it
				// doesn't look for browsers again.
				state.migration = .init(
					destination: state.destination,
					spaceOptions: state.spaceOptions,
					mapsToNewProfiles: state.choice?.keepsSpaces == true,
					phase: .selecting,
					sources: state.sources,
					selectedSourceID: state.selectedSourceID,
					selectedCategories: state.selectedCategories,
					existingData: state.existingData,
					fullDiskAccess: state.fullDiskAccess,
					categoryLimit: state.assistantCategoryLimit,
					allowsNewProfiles: !state.workspaceCameFromICloud
				)
				state.inspecting = nil
				return .cancel(id: Cancellation.inspection)
			}

			// Passwords need the assistant's explanation and their own step, so the page hands
			// them to Customize with the kind already on.
			Pullback(\.ui.setUpPasswords) { state in
				guard
					state.migration == nil,
					state.canClose,
					state.phase == .choosing,
					state.selectedSource?.offersCredentials == true
				else { return .none }

				return .concatenate(
					.send(.ui(.customize)),
					.send(.migration(.ui(.toggleCredentials)))
				)
			}

			Pullback(\.ui.importData) { state in
				guard state.migration == nil, state.canClose else { return .none }

				state.migration = .init(
					destination: state.destination,
					spaceOptions: state.spaceOptions,
					existingData: state.existingData,
					categoryLimit: state.assistantCategoryLimit,
					allowsNewProfiles: !state.workspaceCameFromICloud
				)
				state.inspecting = nil
				return .merge(
					.cancel(id: Cancellation.discovery),
					.cancel(id: Cancellation.inspection)
				)
			}

			// The page shows the assistant's result, and Try Again reruns its plan here. The
			// assistant installed the store extensions already.
			Pullback(\.migration.delegate.finished) { state, report in
				state.plan = state.migration?.plan
				state.keepAccess(from: state.migration)
				let extensions = state.migration?.extensionImport
				state.migration = nil
				let effect = state.finish(report, installingExtensionsTo: nil)
				state.extensionImport = extensions
				return effect
			}

			// Arx was cleared for the assistant (DEV-833): later imports from this page go into
			// the fresh profile and space too, and there's nothing left to clear.
			Pullback(\.migration.event.cleared) { state, value in
				let (destination, spaceOptions) = value
				state.updateMigrationTargets(
					destination: destination,
					spaceOptions: spaceOptions,
					existingData: nil
				)
				return .none
			}

			Pullback(\.migration.delegate.dismissed) { state in
				state.keepAccess(from: state.migration)
				state.migration = nil

				// Access may have been granted while the assistant was open.
				return state.prepare(client: migrationAssistant, access: fullDiskAccess)
			}
		}
	}

	// MARK: - Full Disk Access

	/// Safari's data needs Full Disk Access (DEV-840), granted in System Settings. Arx checks
	/// when Safari is selected and whenever it comes back to the front, and reads Safari once
	/// access is there. The full assistant, while open, checks for itself.
	private var access: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.allowFullDiskAccess) { state in
				guard state.phase == .choosing, state.needsFullDiskAccess else { return .none }

				return .run { [fullDiskAccess] _ in await fullDiskAccess.openSettings() }
			}

			Pullback(\.event.applicationBecameActive) { state in
				guard state.migration == nil else {
					return .send(.migration(.event(.applicationBecameActive)))
				}

				return state.checkAccessIfNeeded(fullDiskAccess)
			}

			Pullback(\.event.fullDiskAccessChecked) { state, isGranted in
				state.fullDiskAccess = isGranted ? .granted : .denied
				return state.inspectIfNeeded(client: migrationAssistant)
			}
		}
	}

	@MainActor
	private static func currentDefault(_ client: DefaultBrowserClient) -> String? {
		client.isAvailable() ? client.currentBrowserIdentifier() : nil
	}
}

extension OnboardingImport.State {
	fileprivate mutating func select(_ source: MigrationSource) {
		selectedSourceID = source.id
		selectedCategories = Set(offeredCategories(of: source))

		// iCloud's spaces are already here: what's brought goes into the current space.
		keepsSpaces = source.preservesOrganization && !workspaceCameFromICloud
		problem = nil
	}

	/// Keeps what the full assistant learned about Full Disk Access when it closes.
	fileprivate mutating func keepAccess(from migration: MigrationAssistantFeature.State?) {
		guard let migration, migration.fullDiskAccess != .unknown else { return }

		fullDiskAccess = migration.fullDiskAccess
	}

	/// Reads the selected browser, or first checks Full Disk Access when it needs that.
	fileprivate mutating func prepare(
		client: MigrationAssistantClient,
		access: FullDiskAccessClient
	) -> Effect<OnboardingImport.Action> {
		.merge(checkAccessIfNeeded(access), inspectIfNeeded(client: client))
	}

	/// Checks Full Disk Access while the selected browser needs it and Arx doesn't have it.
	/// A granted answer is kept: macOS quits an app whose access is taken away.
	fileprivate func checkAccessIfNeeded(
		_ client: FullDiskAccessClient
	) -> Effect<OnboardingImport.Action> {
		guard phase == .choosing, needsFullDiskAccess else { return .none }

		return .run { send in
			await send(.event(.fullDiskAccessChecked(await client.isGranted())))
		}
		.cancellable(id: OnboardingImport.Cancellation.access, cancelInFlight: true)
	}

	/// Inspects the current choice unless it was already read or is being read.
	fileprivate mutating func inspectIfNeeded(
		client: MigrationAssistantClient
	) -> Effect<OnboardingImport.Action> {
		guard
			phase == .choosing,
			!needsFullDiskAccess,
			let choice,
			let source = selectedSource,
			previews[choice] == nil,
			inspecting != choice
		else { return .none }

		guard let destination = destination(for: choice) else {
			problem = .missingDestination
			return .none
		}

		// Every category the source has, so each switch shows its count without reading again.
		let categories: [MigrationCategory] = source.categories.sorted()
		inspecting = choice
		problem = nil
		let inspection: Effect<OnboardingImport.Action> = .run { send in
			do {
				let preview: MigrationPreview = try await client.inspect(choice.sourceID, categories, destination)
				await send(.event(.inspected(choice, preview)))
			} catch {
				await send(.event(.inspectionFailed(choice, error as? MigrationFailure)))
			}
		}
		.cancellable(id: OnboardingImport.Cancellation.inspection)

		// `cancelInFlight` cancels when the task registers, off the main actor, so an older
		// inspection could cancel this one and leave this choice inspecting for good. Cancel in
		// reducer order instead; an older inspection that registers late is for another choice,
		// which `inspected` ignores.
		return .concatenate(.cancel(id: OnboardingImport.Cancellation.inspection), inspection)
	}

	fileprivate mutating func run(
		_ plan: MigrationPlan,
		client: MigrationAssistantClient,
		date: DateGenerator
	) -> Effect<OnboardingImport.Action> {
		phase = .importing
		progress = nil
		report = nil
		problem = nil
		extensionImport = nil
		return .run { send in
			var throttle: OnboardingImportProgressThrottle = .init()
			do {
				for try await event in client.execute(plan) {
					if case .progress = event, !throttle.admits(date.now) { continue }

					await send(.event(.execution(event)))
				}
			} catch {
				await send(.event(.executionFailed(error as? MigrationFailure)))
			}
		}
		.cancellable(id: OnboardingImport.Cancellation.execution, cancelInFlight: true)
	}

	/// Shows a run's result. Inspections are dropped because what was already imported changed.
	///
	/// With a destination, the report's Chrome Web Store extensions are installed into it
	/// first (DEV-845), and a completed import finishes the step once they're done.
	fileprivate mutating func finish(
		_ report: MigrationReport,
		installingExtensionsTo destination: MigrationDestination?
	) -> Effect<OnboardingImport.Action> {
		phase = .finished
		self.report = report
		progress = nil
		problem = nil
		previews = [:]
		extensionImport = nil
		if let destination, report.outcome != .cancelled {
			let extensions: ExtensionImportFeature.State = .init(
				destination: destination,
				report: report,
				sourceName: selectedSource?.name
			)
			if extensions.hasInstallableExtensions {
				extensionImport = extensions
				return .send(.extensionImport(.start))
			}
		}
		guard report.outcome == .completed else { return .none }

		return .send(.delegate(.completed))
	}
}

/// Lets at most ten progress updates a second through. The run's final report is
/// never throttled, so the page always ends on the real result.
public struct OnboardingImportProgressThrottle: Sendable {
	public static let interval: TimeInterval = 0.1

	private var lastAdmitted: Date?

	public init() {
		self.lastAdmitted = nil
	}

	public mutating func admits(_ now: Date) -> Bool {
		if let lastAdmitted, now.timeIntervalSince(lastAdmitted) < Self.interval { return false }

		lastAdmitted = now
		return true
	}
}

extension MigrationCategory {
	/// What an import still brings once iCloud's workspace was adopted (DEV-1215): iCloud syncs
	/// profiles, spaces, pinned tabs, Favorites, Tab Archive and preferences, but not history
	/// already in another browser, open tabs or extensions. Passwords and sign-ins aren't
	/// categories; Set Up… brings them.
	public static let outsideICloud: Set<MigrationCategory> = [.openTabs, .history, .extensions]
}
