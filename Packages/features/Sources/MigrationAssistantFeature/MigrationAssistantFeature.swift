import BrowserCore
import Foundation
import MigrationAssistant
import _ComposableArchitecture

/// Customize: source and kinds of data, a profile mapping, preview, progress, cancellation,
/// results and retry over the MigrationAssistant service. Passwords and sign-ins are one of
/// the kinds and follow the mapping (DEV-842). Hosts (OnboardingFeature, Settings) supply
/// the current space and the other places to import into, and handle the delegate.
@Reducer
public struct MigrationAssistantFeature {
	@ObservableState
	public struct State: Equatable {
		/// Where imported items go. Without one, inspection is refused.
		public var destination: MigrationDestination?

		/// Existing spaces, whose profiles the user can map a source profile onto.
		public var spaceOptions: [SpaceOption]

		/// Where each source profile goes, in source order, once the source was read.
		public var mappings: IdentifiedArrayOf<ProfileMapping>

		/// Source profiles nobody mapped yet go into new Arx profiles; otherwise into the
		/// destination's profile.
		public var mapsToNewProfiles: Bool
		public var phase: Phase
		public var sources: [MigrationSource]
		public var selectedSourceID: MigrationSource.ID?
		public var selectedCategories: Set<MigrationCategory>
		public var preview: MigrationPreview?

		/// Kept after a run so Retry reuses the same idempotent plan.
		public var plan: MigrationPlan?
		public var progress: MigrationProgress?
		public var report: MigrationReport?
		public var problem: Problem?

		/// "Passwords and sign-ins", while the user has the kind turned on (DEV-650, DEV-842).
		/// It takes over the modal after the ordinary import.
		public var credentials: CredentialMigrationFeature.State?

		/// What Arx already holds, from a host that can clear it. Nil on a fresh Arx, or
		/// when the host can't clear, which hides "Clear Arx data first".
		public var existingData: ExistingData?

		/// "Clear Arx data first": off unless the user turns it on.
		public var clearsExistingData: Bool

		/// Whether Arx can read sources macOS protects with Full Disk Access (Safari, DEV-840).
		public var fullDiskAccess: FullDiskAccessStatus

		/// Chrome Web Store extensions the import brought, installed one at a time after it
		/// (DEV-845), before passwords.
		public var extensionImport: ExtensionImportFeature.State?

		/// The only kinds of data the host lets the assistant bring, or nil for every kind a
		/// source has. Passwords and sign-ins aren't a category and stay offered. Onboarding
		/// sets it after adopting iCloud's workspace, so iCloud's profiles, spaces and
		/// bookmarks can't come in a second time (DEV-1220).
		public let categoryLimit: Set<MigrationCategory>?

		/// Whether a source profile may go into a new Arx profile. When false, every source
		/// profile goes into an existing one, the current profile by default (DEV-1220).
		public let allowsNewProfiles: Bool

		public init(
			destination: MigrationDestination?,
			spaceOptions: [SpaceOption] = [],
			mappings: IdentifiedArrayOf<ProfileMapping> = [],
			mapsToNewProfiles: Bool = false,
			phase: Phase = .idle,
			sources: [MigrationSource] = [],
			selectedSourceID: MigrationSource.ID? = nil,
			selectedCategories: Set<MigrationCategory> = [],
			preview: MigrationPreview? = nil,
			plan: MigrationPlan? = nil,
			progress: MigrationProgress? = nil,
			report: MigrationReport? = nil,
			problem: Problem? = nil,
			credentials: CredentialMigrationFeature.State? = nil,
			existingData: ExistingData? = nil,
			clearsExistingData: Bool = false,
			fullDiskAccess: FullDiskAccessStatus = .unknown,
			extensionImport: ExtensionImportFeature.State? = nil,
			categoryLimit: Set<MigrationCategory>? = nil,
			allowsNewProfiles: Bool = true
		) {
			self.destination = destination
			self.spaceOptions = spaceOptions
			self.mappings = mappings
			self.mapsToNewProfiles = mapsToNewProfiles && allowsNewProfiles
			self.phase = phase
			self.sources = sources
			self.selectedSourceID = selectedSourceID
			self.selectedCategories = categoryLimit.map(selectedCategories.intersection) ?? selectedCategories
			self.categoryLimit = categoryLimit
			self.allowsNewProfiles = allowsNewProfiles
			self.preview = preview
			self.plan = plan
			self.progress = progress
			self.report = report
			self.problem = problem
			self.credentials = credentials
			self.existingData = existingData
			self.clearsExistingData = clearsExistingData
			self.fullDiskAccess = fullDiskAccess
			self.extensionImport = extensionImport
		}

		public var selectedSource: MigrationSource? {
			sources.first { $0.id == selectedSourceID }
		}

		/// The kinds of data the selected source offers within ``categoryLimit``.
		public var offeredCategories: [MigrationCategory] {
			guard let source = selectedSource else { return [] }
			guard let categoryLimit else { return source.categories }

			return source.categories.filter(categoryLimit.contains)
		}

		/// Takes the host's current destination, spaces and data, for example after Arx was
		/// cleared only in part (DEV-833). Mappings onto profiles that may be gone start over
		/// when the destination moves.
		public mutating func updateTargets(
			destination: MigrationDestination?,
			spaceOptions: [SpaceOption],
			existingData: ExistingData?
		) {
			if destination != self.destination { mappings = [] }
			self.destination = destination
			self.spaceOptions = spaceOptions
			self.existingData = existingData
			if existingData == nil { clearsExistingData = false }
		}

		/// Whether the source's profiles are mapped at all. Files without profiles of their
		/// own go into the current space.
		public var offersMapping: Bool {
			selectedSource?.offersLayouts == true
		}

		/// The destination with the user's mapping applied.
		public var resolvedDestination: MigrationDestination? {
			guard var destination else { return nil }
			guard offersMapping else { return destination }

			if mapsToNewProfiles {
				destination.defaultRoute = .newProfile
			}
			for mapping in mappings {
				destination.profileRoutes[mapping.id] = mapping.route
			}
			return destination
		}

		/// Arx profiles a source profile can go into, once each in the host's order, with the
		/// current one first when the host didn't list it.
		public var profileOptions: [ProfileOption] {
			var options: [ProfileOption] = []
			for option in spaceOptions where !options.contains(where: { $0.id == option.profileID }) {
				options.append(.init(id: option.profileID, name: option.profileName))
			}
			if let destination, !options.contains(where: { $0.id == destination.profileID }) {
				options.insert(.init(id: destination.profileID, name: ""), at: 0)
			}
			return options
		}

		/// The user turned Passwords and sign-ins on.
		public var includesCredentials: Bool {
			credentials != nil
		}

		public var canInspect: Bool {
			phase == .selecting
			&& destination != nil
			&& selectedSource != nil
			&& !needsFullDiskAccess

			// Passwords and sign-ins alone are enough.
			&& (!selectedCategories.isEmpty || credentials != nil)
		}

		/// The selected source needs Full Disk Access that Arx doesn't have (yet), so the
		/// assistant asks for it instead of showing the categories.
		public var needsFullDiskAccess: Bool {
			selectedSource?.requiresFullDiskAccess == true && fullDiskAccess != .granted
		}

		/// The choice shows only while selecting and only when there's something to clear.
		public var canClearExistingData: Bool {
			phase == .selecting && existingData != nil
		}

		public var canImport: Bool {
			guard phase == .previewing, let preview else { return false }

			// Passwords in CSV mode need a file before Import.
			if let credentials, !credentials.isReady { return false }

			// Extensions commit nothing but are listed, and store ones install after the run.
			return preview.importableCount > 0
			|| credentials != nil
			|| preview.categories.contains { !$0.reinstalls.isEmpty }
		}

		/// The credentials step has taken over the modal.
		public var showsCredentials: Bool {
			credentials?.isRunning == true
		}

		public var canRetry: Bool {
			phase == .finished
			&& plan != nil
			&& !(report?.retryableCategories.isEmpty ?? true)

			// A retry starts over, so it waits for the extensions under way.
			&& !(extensionImport?.isRunning ?? false)
		}

		/// Passwords and sign-ins are offered for browsers. Arx files carry none.
		public var offersCredentials: Bool {
			selectedSource?.offersCredentials == true
		}

		/// Dismissal is refused while a commit or a clear may be running; cancel first.
		public var canDismiss: Bool {
			phase != .importing
			&& phase != .cancelling
			&& phase != .clearing
			&& !(extensionImport?.isRunning ?? false)
			&& (credentials?.canClose ?? true)
		}
	}

	/// Where one source profile goes (DEV-842).
	public struct ProfileMapping: Equatable, Identifiable, Sendable {
		/// The source profile's ID.
		public var id: String
		public var sourceName: String

		/// The existing Arx profile it goes into, or nil for a new one.
		public var profileID: Profile.ID?

		/// The new profile's name. Kept while an existing profile is picked, so switching
		/// back restores it.
		public var newName: String

		public init(
			id: String,
			sourceName: String,
			profileID: Profile.ID? = nil,
			newName: String? = nil
		) {
			self.id = id
			self.sourceName = sourceName
			self.profileID = profileID
			self.newName = newName ?? sourceName
		}

		public var route: MigrationProfileRoute {
			profileID.map(MigrationProfileRoute.existingProfile) ?? .newProfile(name: newName)
		}
	}

	public struct ProfileOption: Equatable, Identifiable, Sendable {
		public var id: Profile.ID

		/// Empty when the host didn't name it.
		public var name: String

		public init(
			id: Profile.ID,
			name: String
		) {
			self.id = id
			self.name = name
		}
	}

	public struct SpaceOption: Equatable, Hashable, Identifiable, Sendable {
		public var profileID: Profile.ID
		public var profileName: String
		public var spaceID: Space.ID
		public var spaceName: String

		public var id: Space.ID { spaceID }

		public init(
			profileID: Profile.ID,
			profileName: String,
			spaceID: Space.ID,
			spaceName: String
		) {
			self.profileID = profileID
			self.profileName = profileName
			self.spaceID = spaceID
			self.spaceName = spaceName
		}
	}

	/// What "Clear Arx data first" would remove, as the host counts it.
	public struct ExistingData: Equatable, Sendable {
		public var profileNames: [String]
		public var spaceCount: Int
		public var tabCount: Int

		public init(
			profileNames: [String],
			spaceCount: Int,
			tabCount: Int
		) {
			self.profileNames = profileNames
			self.spaceCount = spaceCount
			self.tabCount = tabCount
		}
	}

	public enum Phase: Equatable, Sendable {
		case idle
		case discovering
		case selecting

		/// "Clear Arx data first" is on: the user confirms what will be removed.
		case confirmingClear

		/// The host is removing Arx's data through profile retirement.
		case clearing
		case inspecting
		case previewing
		case importing
		case cancelling
		case finished
	}

	public enum Problem: Equatable, Sendable {
		case discoveryFailed
		case missingDestination
		case inspectionFailed

		/// The source changed after the preview; it must be reviewed again.
		case sourceChanged
		case importFailed
		case unreadableFile
		case newerFile
		case fileTooLarge

		/// The host couldn't clear Arx's data. Nothing was imported.
		case clearFailed
	}

	@CasePathable
	public enum Action: Sendable {
		case credentials(CredentialMigrationFeature.Action)
		case extensionImport(ExtensionImportFeature.Action)
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case task
			case selectSource(MigrationSource.ID)
			case toggleCategory(MigrationCategory)

			/// Passwords and sign-ins as a kind of data, off until the user turns it on.
			case toggleCredentials
			case fileChosen(URL)

			/// A source profile into an existing Arx profile, or a new one for nil.
			case mapProfile(String, Profile.ID?)

			/// The name of the new profile a source profile goes into.
			case renameProfile(String, String)
			case inspect
			case back
			case startImport
			case cancel
			case retry
			case done
			case dismiss
			case setClearsExistingData(Bool)

			/// The user confirmed removing everything `existingData` lists.
			case confirmClear

			/// Opens System Settings › Privacy & Security › Full Disk Access.
			case allowFullDiskAccess
		}

		@CasePathable
		public enum Event: Sendable {
			case discovered([MigrationSource])
			case discoveryFailed
			case fileAdded(MigrationSource)
			case fileFailed(MigrationFailure?)
			case inspected(MigrationPreview)
			case inspectionFailed(MigrationFailure?)
			case execution(MigrationEvent)
			case executionFailed(MigrationFailure?)

			/// The host cleared Arx; imports go into its fresh profile and space.
			case cleared(MigrationDestination, spaceOptions: [SpaceOption])
			case clearFailed

			/// Arx came to the front, maybe after the user allowed Full Disk Access.
			case applicationBecameActive
			case fullDiskAccessChecked(Bool)
		}

		@CasePathable
		public enum Delegate: Sendable {
			/// The user closed the results of a run.
			case finished(MigrationReport)

			/// The user left without a finished run.
			case dismissed

			/// The user confirmed "Clear Arx data first". The host retires every profile
			/// through profile retirement, leaves one fresh profile and space, and answers
			/// with `event(.cleared)` or `event(.clearFailed)`.
			case clearExistingData(ExistingData)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.fullDiskAccess)
	private var fullDiskAccess

	@Dependency(\.migrationAssistant)
	private var migration

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
			selection
			execution
			clearing
			mapping
			credentialStep
			access
		}
		.ifLet(\.credentials, action: \.credentials) {
			CredentialMigrationFeature()
		}
		.ifLet(\.extensionImport, action: \.extensionImport) {
			ExtensionImportFeature()
		}
	}

	/// Cancels discovery and inspection and drops decrypted passwords and cookies that
	/// weren't written. An import is never cancelled this way; hosts drop this state only
	/// while `canDismiss` is true.
	public static func cancelInFlightWork<Action>() -> Effect<Action> {
		.merge(
			.cancel(id: Cancellation.discovery),
			.cancel(id: Cancellation.inspection),
			.cancel(id: Cancellation.access),
			// Decrypted passwords and cookies never outlive the assistant (DEV-650).
			.run { _ in
				@Dependency(\.credentialMigration)
				var credentialMigration

				await credentialMigration.discardAll()
			}
		)
	}

	private var selection: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.task) { state in
				guard state.phase == .idle else { return .none }

				state.phase = .discovering
				state.problem = nil
				return .run { [migration] send in
					do {
						await send(.event(.discovered(try await migration.discover())))
					} catch {
						await send(.event(.discoveryFailed))
					}
				}
				.cancellable(id: Cancellation.discovery, cancelInFlight: true)
			}

			Pullback(\.event.discovered) { state, sources in
				guard state.phase == .discovering else { return .none }

				state.phase = .selecting
				state.sources = sources
				if let source = sources.first(where: { $0.id == state.selectedSourceID }) ?? sources.first {
					state.select(source)
				}
				return state.checkAccessIfNeeded(client: fullDiskAccess)
			}

			Pullback(\.event.discoveryFailed) { state in
				guard state.phase == .discovering else { return .none }

				state.phase = .selecting
				state.problem = .discoveryFailed
				return .none
			}

			Pullback(\.ui.selectSource) { state, id in
				guard
					state.phase == .selecting,
					let source = state.sources.first(where: { $0.id == id })
				else { return .none }

				state.select(source)
				return state.checkAccessIfNeeded(client: fullDiskAccess)
			}

			Pullback(\.ui.toggleCategory) { state, category in
				guard
					state.phase == .selecting,
					state.offeredCategories.contains(category)
				else { return .none }

				if state.selectedCategories.contains(category) {
					state.selectedCategories.remove(category)
				} else {
					state.selectedCategories.insert(category)
				}
				return .none
			}

			Pullback(\.ui.inspect) { state in
				guard state.canInspect else { return .none }

				if state.clearsExistingData, state.existingData != nil {
					state.phase = .confirmingClear
					state.problem = nil
					return .none
				}
				return state.inspect(client: migration)
			}

			Pullback(\.ui.fileChosen) { state, url in
				guard state.phase == .selecting else { return .none }

				state.problem = nil
				return .run { [migration] send in
					do {
						await send(.event(.fileAdded(try await migration.addFile(url))))
					} catch {
						await send(.event(.fileFailed(error as? MigrationFailure)))
					}
				}
			}

			Pullback(\.event.fileAdded) { state, source in
				guard state.phase == .selecting else { return .none }

				state.sources.removeAll { $0.id == source.id }
				state.sources.append(source)
				state.select(source)
				return .none
			}

			Pullback(\.event.fileFailed) { state, failure in
				guard state.phase == .selecting else { return .none }

				switch failure {
				case .unsupportedVersion: state.problem = .newerFile
				case .fileTooLarge: state.problem = .fileTooLarge
				default: state.problem = .unreadableFile
				}
				return .none
			}

			Pullback(\.event.inspected) { state, preview in
				guard state.phase == .inspecting else { return .none }

				let read = state.resolvedDestination?.routing
				state.phase = .previewing
				state.preview = preview
				state.refreshMappings()

				// The read before couldn't know the source's profiles. When their default mapping
				// sends them somewhere else (an existing profile instead of the current space),
				// read again, so the review and the plan describe the same place.
				guard state.resolvedDestination?.routing != read else { return .none }

				return state.inspect(client: migration)
			}

			Pullback(\.event.inspectionFailed) { state, failure in
				guard state.phase == .inspecting else { return .none }

				state.phase = .selecting
				state.problem = failure == .invalidDestination
				? .missingDestination
				: .inspectionFailed
				return .none
			}

			Pullback(\.ui.back) { state in
				if state.phase == .confirmingClear {
					state.phase = .selecting
					return .none
				}
				guard state.phase == .previewing || state.phase == .finished else { return .none }

				state.returnToSelection()
				return .none
			}
		}
	}

	private var execution: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.startImport) { state in
				guard state.canImport, let preview = state.preview else { return .none }

				var plan = MigrationPlan(id: .init(rawValue: uuid()), preview: preview)

				// Renaming a new profile doesn't change what's imported, so it doesn't read the
				// source again: the names come from the mapping as it is now.
				if let destination = state.resolvedDestination {
					plan.destination = destination
				}

				// Passwords follow the mapping, so its new profiles are made even when no
				// category brings anything into them.
				if state.credentials != nil {
					let mapped = state.mappedProfiles
					let ids = Set(mapped.map(\.id))
					plan.profiles = mapped + plan.profiles.filter { !ids.contains($0.id) }
				}
				state.plan = plan
				return state.run(plan, client: migration)
			}

			Pullback(\.ui.retry) { state in
				guard state.canRetry, let plan = state.plan else { return .none }

				// The same plan is idempotent: committed items are skipped by key.
				return state.run(plan, client: migration)
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

				case let .finished(report):
					guard report.planID == plan.id else { return .none }

					state.phase = .finished
					state.report = report
					guard report.outcome != .cancelled else { return .none }

					// Store extensions go into the profiles the import made, then passwords.
					let extensions: ExtensionImportFeature.State = .init(
						destination: plan.destination,
						report: report,
						sourceName: state.selectedSource?.name
					)
					guard extensions.hasInstallableExtensions else {
						state.extensionImport = nil
						return state.startCredentials(plan.destination)
					}

					state.extensionImport = extensions
					return .send(.extensionImport(.start))
				}
				return .none
			}

			Pullback(\.extensionImport.delegate.finished) { state in
				guard let plan = state.plan else { return .none }

				return state.startCredentials(plan.destination)
			}

			Pullback(\.event.executionFailed) { state, failure in
				guard state.phase == .importing || state.phase == .cancelling else { return .none }

				if failure == .sourceChanged {
					state.returnToSelection()
					state.problem = .sourceChanged
				} else {
					state.phase = state.report == nil ? .previewing : .finished
					state.problem = .importFailed
				}
				return .none
			}

			Pullback(\.ui.cancel) { state in
				switch state.phase {
				case .inspecting:
					state.phase = .selecting
					return .cancel(id: Cancellation.inspection)

				case .importing:
					guard let plan = state.plan else { return .none }

					// Keep consuming the stream so the cancelled report arrives.
					state.phase = .cancelling
					return .run { [migration] _ in await migration.cancel(plan.id) }

				default:
					return .none
				}
			}

			Pullback(\.ui.done) { state in
				guard
					state.phase == .finished,
					state.canDismiss,
					let report = state.report
				else { return .none }

				return .send(.delegate(.finished(report)))
			}

			Pullback(\.ui.dismiss) { state in
				guard state.canDismiss else { return .none }

				// Decrypted records that weren't written go with the assistant.
				state.credentials = nil
				return .merge(
					Self.cancelInFlightWork(),
					.send(.delegate(.dismissed))
				)
			}
		}
	}
}

extension MigrationAssistantFeature {
	/// "Clear Arx data first" (DEV-650): off by default, confirmed by name, done by the host.
	private var clearing: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.setClearsExistingData) { state, isOn in
				guard state.canClearExistingData else { return .none }

				state.clearsExistingData = isOn
				return .none
			}

			Pullback(\.ui.confirmClear) { state in
				guard
					state.phase == .confirmingClear,
					state.clearsExistingData,
					let existing = state.existingData
				else { return .none }

				state.phase = .clearing
				return .send(.delegate(.clearExistingData(existing)))
			}

			// A clean Arx: the source maps onto fresh profiles, so review against it.
			Pullback(\.event.cleared) { state, value in
				guard state.phase == .clearing else { return .none }

				let (destination, spaceOptions) = value
				state.destination = destination
				state.spaceOptions = spaceOptions
				state.existingData = nil
				state.clearsExistingData = false

				// Existing profiles the user mapped onto are gone.
				state.mappings = []
				state.phase = .selecting
				return state.inspect(client: migration)
			}

			Pullback(\.event.clearFailed) { state in
				guard state.phase == .clearing else { return .none }

				state.phase = .selecting
				state.problem = .clearFailed
				return .none
			}
		}
	}

	/// Each source profile into a new Arx profile, with a name, or an existing one (DEV-842).
	private var mapping: some ReducerOf<Self> {
		CombineReducers {
			// Whether something was already imported depends on where it would go.
			Pullback(\.ui.mapProfile) { state, value in
				let (id, profileID) = value

				// Nil maps to a new profile, when the host allows one; an existing one must be
				// among the options.
				let isOffered: Bool = profileID.map { profileID in
					state.profileOptions.contains { $0.id == profileID }
				} ?? state.allowsNewProfiles
				guard
					state.phase == .previewing,
					state.mappings[id: id] != nil,
					isOffered
				else { return .none }

				state.mappings[id: id]?.profileID = profileID
				return state.inspect(client: migration)
			}

			Pullback(\.ui.renameProfile) { state, value in
				let (id, name) = value
				guard
					state.phase == .previewing,
					state.mappings[id: id]?.profileID == nil
				else { return .none }

				state.mappings[id: id]?.newName = name
				return .none
			}
		}
	}

	private var credentialStep: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.toggleCredentials) { state in
				guard
					state.phase == .selecting || state.phase == .previewing,
					state.offersCredentials,
					let source = state.selectedSource
				else { return .none }

				guard state.credentials == nil else {
					state.credentials = nil

					// Profiles that only had passwords leave the mapping with them.
					state.refreshMappings()
					return .none
				}

				state.credentials = .init(
					sourceID: source.id,
					sourceName: source.name,
					mappedProfiles: state.mappedProfiles
				)
				return .send(.credentials(.load))
			}

			// Profiles with passwords but nothing else (no bookmarks or open tabs) join the
			// mapping once the browser's profiles are known.
			Pullback(\.credentials.event.loaded) { state, _ in
				state.refreshMappings()
				return .none
			}

			Pullback(\.credentials.delegate.closed) { state in
				state.credentials = nil
				return .none
			}
		}
	}
}

extension MigrationAssistantFeature {
	/// Full Disk Access for Safari (DEV-840): checked when such a source is selected and
	/// whenever Arx comes back to the front, since it's granted in System Settings.
	private var access: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.allowFullDiskAccess) { state in
				guard state.needsFullDiskAccess else { return .none }

				return .run { [fullDiskAccess] _ in await fullDiskAccess.openSettings() }
			}

			Pullback(\.event.applicationBecameActive) { state in
				state.checkAccessIfNeeded(client: fullDiskAccess)
			}

			Pullback(\.event.fullDiskAccessChecked) { state, isGranted in
				state.fullDiskAccess = isGranted ? .granted : .denied
				return .none
			}
		}
	}
}

extension MigrationDestination {
	/// Where items go, without new profiles' names, which change nothing a review counts.
	/// A mapping to a new profile is the same as no mapping under a new-profile default.
	fileprivate var routing: Self {
		var routing = self
		routing.profileRoutes = profileRoutes.compactMapValues { route in
			switch route {
			case .newProfile: defaultRoute == .newProfile ? nil : .newProfile(name: "")
			case .existingProfile: route
			}
		}
		return routing
	}
}

extension MigrationAssistantFeature.State {
	/// The source profiles passwords follow: the mapped ones, while the source is mapped.
	public var mappedProfiles: [MigrationSourceProfile] {
		guard offersMapping else { return [] }

		return mappings.map { .init(id: $0.id, name: $0.sourceName) }
	}

	/// Checks Full Disk Access while the selected source needs it and Arx doesn't have it.
	/// Access isn't taken back while Arx runs (macOS quits an app that loses it), so a
	/// granted answer is kept.
	fileprivate func checkAccessIfNeeded(
		client: FullDiskAccessClient
	) -> Effect<MigrationAssistantFeature.Action> {
		guard needsFullDiskAccess else { return .none }

		return .run { send in
			await send(.event(.fullDiskAccessChecked(await client.isGranted())))
		}
		.cancellable(id: MigrationAssistantFeature.Cancellation.access, cancelInFlight: true)
	}

	/// The mapping for the profiles the review read, plus, while passwords are on, the
	/// browser's profiles that hold only passwords. Without a review yet, the mapping stays
	/// as it is: the next read rebuilds it.
	fileprivate mutating func refreshMappings() {
		guard let preview else { return }

		var profiles = preview.profiles
		let passwordProfiles: [MigrationSourceProfile] = credentials?.source?.profiles ?? []
		for profile in passwordProfiles where !profiles.contains(where: { $0.id == profile.id }) {
			profiles.append(profile)
		}
		updateMappings(profiles)
	}

	/// Adds a mapping for each source profile the source shows now, keeping the user's
	/// choices for the others, and tells passwords about them.
	fileprivate mutating func updateMappings(_ profiles: [MigrationSourceProfile]) {
		guard offersMapping else {
			mappings = []
			return
		}

		let existing = mapsToNewProfiles ? nil : destination?.profileID
		let current = mappings
		mappings = .init(
			uniqueElements: profiles.map { profile in
				current[id: profile.id] ?? .init(
					id: profile.id,
					sourceName: profile.name,
					profileID: existing
				)
			}
		)
		let mapped = mappedProfiles
		credentials?.mappedProfiles = mapped
	}

	fileprivate mutating func select(_ source: MigrationSource) {
		selectedSourceID = source.id
		selectedCategories = Set(offeredCategories)
		mapsToNewProfiles = source.preservesOrganization && allowsNewProfiles
		mappings = []
		preview = nil

		// Passwords are opt-in for each source.
		credentials = nil
	}

	fileprivate mutating func inspect(
		client: MigrationAssistantClient
	) -> Effect<MigrationAssistantFeature.Action> {
		guard
			let destination = resolvedDestination,
			let sourceID = selectedSourceID
		else {
			problem = .missingDestination
			return .none
		}

		let categories = selectedCategories
			.filter { categoryLimit?.contains($0) ?? true }
			.sorted()
		phase = .inspecting
		problem = nil
		return .run { send in
			do {
				let preview = try await client.inspect(sourceID, categories, destination)
				await send(.event(.inspected(preview)))
			} catch {
				await send(.event(.inspectionFailed(error as? MigrationFailure)))
			}
		}
		.cancellable(id: MigrationAssistantFeature.Cancellation.inspection, cancelInFlight: true)
	}

	/// Passwords and sign-ins follow the mapping into the profiles the import made.
	fileprivate func startCredentials(
		_ destination: MigrationDestination
	) -> Effect<MigrationAssistantFeature.Action> {
		guard credentials != nil else { return .none }

		return .send(.credentials(.start(destination)))
	}

	fileprivate mutating func returnToSelection() {
		phase = .selecting
		extensionImport = nil
		preview = nil
		plan = nil
		progress = nil
		report = nil
		problem = nil
	}

	fileprivate mutating func run(
		_ plan: MigrationPlan,
		client: MigrationAssistantClient
	) -> Effect<MigrationAssistantFeature.Action> {
		phase = .importing
		progress = nil
		report = nil
		extensionImport = nil
		problem = nil
		return .run { send in
			do {
				for try await event in client.execute(plan) {
					await send(.event(.execution(event)))
				}
			} catch {
				await send(.event(.executionFailed(error as? MigrationFailure)))
			}
		}
		.cancellable(id: MigrationAssistantFeature.Cancellation.execution, cancelInFlight: true)
	}
}
