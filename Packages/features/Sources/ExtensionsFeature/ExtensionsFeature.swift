import BrowserCore
import BrowserExtensionsClient
import Foundation
import _ComposableArchitecture

@Reducer
public struct ExtensionsFeature {
	@ObservableState
	public struct State: Equatable {
		public var profile: Profile?
		public var isAvailable: Bool
		public var optionsAvailable: Bool
		public var isInstallationAvailable: Bool

		/// Add to Chrome on the Chrome Web Store reaches this sheet (DEV-765).
		public var isWebstoreAvailable: Bool

		/// App-wide developer mode. Off hides folder controls; installed extensions stay.
		public var developerModeEnabled: Bool
		public var isUnpackedAvailable: Bool
		public var isPresented: Bool
		public var isWorking: Bool
		public var generation: Int
		public var inventory: BrowserExtensionInventory?

		/// The icons the inventory's extensions report, by their icon path; one that couldn't be
		/// read shows its letter.
		public var icons: [String: Data]
		public var selectedID: String?
		public var pendingRemoval: BrowserExtensionRequest?
		public var packageSelection: PackageSelection?
		public var directorySelection: DirectorySelection?
		public var pendingInstallation: BrowserExtensionInstallPrompt?

		/// A store request waiting for this profile's inventory to load.
		public var webstoreRequest: BrowserWebstoreInstallRequest?

		/// An install an MCP client asked for, from waiting for the inventory to the
		/// review's answer (DEV-951).
		public var automationInstall: AutomationInstall?

		/// Installed store extensions can be checked for updates (DEV-776).
		public var isWebstoreUpdateAvailable: Bool

		/// A Check for Updates in progress, one extension at a time.
		public var updateCheck: UpdateCheck?

		/// What the last finished check found, until the sheet reloads or closes.
		public var updateCheckResult: UpdateCheckResult?

		/// The `ARX_EXTENSION_UPDATE_REVIEW` feature flag, read at launch (DEV-1210): store updates
		/// the automatic check turned down for asking more permissions are marked for review.
		public var updateReviewsEnabled: Bool

		/// Those updates and the offers the person declined, per profile and extension, shared
		/// with the app's automatic check and the site menu.
		@Shared(.extensionUpdateReviews)
		public var updateReviews: ExtensionUpdateReviews

		/// A review asked for before the inventory loaded (from the site menu); it starts once the
		/// inventory is in.
		public var requestedReview: String?
		public var error: BrowserExtensionsClient.Failure?

		public init(
			profile: Profile? = nil,
			isAvailable: Bool = false
		) {
			self.profile = profile
			self.isAvailable = isAvailable
			self.optionsAvailable = false
			self.isInstallationAvailable = false
			self.isWebstoreAvailable = false
			self.developerModeEnabled = false
			self.isUnpackedAvailable = false
			self.isPresented = false
			self.isWorking = false
			self.generation = 0
			self.inventory = nil
			self.icons = [:]
			self.selectedID = nil
			self.pendingRemoval = nil
			self.packageSelection = nil
			self.directorySelection = nil
			self.pendingInstallation = nil
			self.webstoreRequest = nil
			self.automationInstall = nil
			self.isWebstoreUpdateAvailable = false
			self.updateCheck = nil
			self.updateCheckResult = nil
			self.updateReviewsEnabled = false
			self._updateReviews = Shared(.extensionUpdateReviews)
			self.requestedReview = nil
			self.error = nil
		}

		/// Store extensions the user may replace, in the order the sheet lists them.
		public var updatableExtensionIDs: [String] {
			inventory?.extensions.filter { $0.fromWebStore && $0.allows(.remove) }.map(\.id) ?? []
		}

		/// The store updates waiting for the person's review in this profile, with the feature
		/// flag on (DEV-1210).
		public var pendingUpdateReviews: [ExtensionUpdateReviews.Review] {
			guard updateReviewsEnabled, let profileID = profile?.id else { return [] }
			return updateReviews.pending(in: profileID)
		}

		/// The update waiting for review for one extension of this profile, if any.
		public func updateReview(_ extensionID: String) -> ExtensionUpdateReviews.Review? {
			pendingUpdateReviews.first { $0.extensionID == extensionID }
		}

		/// Load and Reload exist only in developer mode with the native capability.
		public var canLoadUnpacked: Bool { developerModeEnabled && isUnpackedAvailable }

		internal var hasSelection: Bool { packageSelection != nil || directorySelection != nil }

		/// The MCP client asking for the install under review, which the review names.
		public var reviewRequester: String? {
			guard let automationInstall, automationInstall.stage == .reviewing else { return nil }
			return automationInstall.requester
		}
	}

	/// An MCP client's `installExtension` (DEV-951). The person approves it in the same
	/// review as Add to Arx, whatever the client's approval policy; nothing installs
	/// without their click.
	public struct AutomationInstall: Equatable, Sendable {
		public enum Stage: Equatable, Sendable {
			/// Waiting for the sheet to load the profile's extensions.
			case waiting

			/// The app checks the loaded extensions against the request (its revision, an item
			/// the profile already has) before anything downloads.
			case checking

			/// The store's package is downloading and being verified.
			case preparing

			/// The review sheet shows it.
			case reviewing

			/// The review was answered; Chromium is installing or cleaning up.
			case resolving(accepted: Bool)

			/// The request ended while the package was downloading. The download finishes and is
			/// dropped, then the sheet reloads: until then the profile is still busy with it.
			case discarding
		}

		/// The automation request.
		public let id: UUID
		public let profileID: Profile.ID
		public let extensionID: String

		/// The client's name, shown in the review.
		public let requester: String
		public var stage: Stage

		/// The verified package's name and version, once prepared.
		public var name: String?
		public var version: String?

		/// Preparations the engine answered `staleInventory` in a row. A profile that has only
		/// just started keeps moving its revision for several seconds while the store's package
		/// downloads; each one reads the profile again, up to `maximumStaleAttempts`.
		public var staleAttempts: Int

		/// A third `staleInventory` in a row fails the install.
		public static let maximumStaleAttempts: Int = 3

		public init(
			id: UUID,
			profileID: Profile.ID,
			extensionID: String,
			requester: String
		) {
			self.id = id
			self.profileID = profileID
			self.extensionID = extensionID
			self.requester = requester
			self.stage = .waiting
			self.name = nil
			self.version = nil
			self.staleAttempts = 0
		}
	}

	/// How an MCP client's install ended.
	public enum AutomationInstallOutcome: Equatable, Sendable {
		case installed(name: String?, version: String?)

		/// The person cancelled the review or closed the sheet.
		case declined(name: String?, version: String?)

		/// The profile already has it; there was nothing to review.
		case alreadyInstalled(name: String, version: String)
		case failed(BrowserExtensionsClient.Failure, name: String?, version: String?)

		/// Not started: the sheet is in the middle of another install, update or selection.
		case busy

		/// Not started: this Arx can't install Chrome Web Store items.
		case unavailable
	}

	/// DEV-776. Updates that ask for nothing new install at once; one that asks for more
	/// permissions shows the review sheet first, as an install does.
	public struct UpdateCheck: Equatable, Sendable {
		public var remaining: [String]
		public var current: String?

		/// The current extension's update was accepted or is up for review.
		public var isResolving: Bool

		/// The current update was accepted, automatically or in the review sheet. A
		/// declined review also finishes with the (unchanged) inventory.
		public var isAccepted: Bool
		public var updated: [String]

		/// Newer versions the user declined in the review sheet.
		public var declined: [String]
		public var failed: [String]

		public init(remaining: [String]) {
			self.remaining = remaining
			self.current = nil
			self.isResolving = false
			self.isAccepted = false
			self.updated = []
			self.declined = []
			self.failed = []
		}
	}

	public struct UpdateCheckResult: Equatable, Sendable {
		public let updated: Int
		public let declined: Int
		public let failed: Int

		public init(
			updated: Int,
			declined: Int = 0,
			failed: Int
		) {
			self.updated = updated
			self.declined = declined
			self.failed = failed
		}
	}

	public struct PackageSelection: Equatable, Sendable, Identifiable {
		public let id: UUID
		public let inventory: BrowserExtensionInventory
		public let expectedExtensionID: String?

		public init(
			inventory: BrowserExtensionInventory,
			expectedExtensionID: String?
		) {
			self.id = UUID()
			self.inventory = inventory
			self.expectedExtensionID = expectedExtensionID
		}
	}

	/// An immutable picker context: a late folder result can only target this
	/// exact profile inventory.
	public struct DirectorySelection: Equatable, Sendable, Identifiable {
		public let id: UUID
		public let inventory: BrowserExtensionInventory

		public init(inventory: BrowserExtensionInventory) {
			self.id = UUID()
			self.inventory = inventory
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case configure(Profile?)
		case configureDeveloperMode(Bool)

		/// The Chrome Web Store asked to install an item in `profile`. The app
		/// presents this sheet for that profile first.
		case webstoreRequested(BrowserWebstoreInstallRequest)

		/// An MCP client asked to install a store item in `profile` (DEV-951). The app
		/// presents this sheet for that profile first.
		case automationInstallRequested(AutomationInstall)

		/// The MCP request behind the install ended (timed out, cancelled, disconnected or lost
		/// its grant). Its preparation or review goes away; an answered review stays answered.
		case automationInstallCancelled(UUID)

		/// The app checked the loaded extensions: download the item and show the review.
		case automationInstallProceed(UUID)

		/// Opens the review of one extension's update that waits for it (DEV-1210), once the
		/// inventory is in: from the site menu, which opens the sheet first.
		case reviewUpdateRequested(String)

		/// Selects this extension once the sheet shows it, such as one picked in the site menu.
		case reveal(String)
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case present
			case dismiss
			case refresh
			case openOptions(BrowserExtensionViewRequest)
			case select(String)
			case setEnabled(BrowserExtensionRequest)

			/// Lets the extension run in private windows, or stops it (DEV-889).
			case setAllowedInPrivate(BrowserExtensionRequest)
			case requestRemoval(BrowserExtensionRequest)
			case cancelRemoval
			case confirmRemoval(BrowserExtensionRequest)
			case choosePackage(String?)
			case cancelPackageSelection(PackageSelection)
			case selectPackage(PackageSelection, URL)
			case respondToInstallation(BrowserExtensionInstallPrompt, Bool)
			case chooseUnpackedDirectory
			case cancelDirectorySelection(DirectorySelection)
			case selectDirectory(DirectorySelection, URL)
			case reload(BrowserExtensionRequest)

			/// Opens the Chrome Web Store in this sheet's profile.
			case openWebstore

			/// Checks every installed store extension for a newer version (DEV-776).
			case checkForUpdates

			/// The row's "Update needs review" mark (DEV-1210): checks that extension alone, so its
			/// update shows the review sheet.
			case reviewUpdate(String)
		}

		@CasePathable
		public enum Event: Sendable {
			case prepared(
				Int,
				PackageSelection,
				Result<BrowserExtensionInstallPrompt, BrowserExtensionsClient.Failure>
			)
			case finished(
				Int,
				Profile.ID,
				Result<BrowserExtensionInventory, BrowserExtensionsClient.Failure>
			)
			case updatePrepared(
				Int,
				BrowserWebstoreUpdateRequest,
				Result<BrowserExtensionInstallPrompt, BrowserExtensionsClient.Failure>
			)

			/// The icons read for paths the inventory reported, by path.
			case iconsRead([String: Data])
		}

		@CasePathable
		public enum Delegate: Sendable {
			/// Open the Chrome Web Store in a window of this profile.
			case openWebstore(Profile.ID)

			/// The sheet loaded the profile for an MCP install, which waits for
			/// `automationInstallProceed`. Reading the profile again would replace the
			/// authority the sheet holds, so the app checks this inventory instead.
			case automationInstallInventoryLoaded(UUID, BrowserExtensionInventory)

			/// An MCP client's install ended; the UUID is its automation request. The
			/// inventory is the profile's extensions as the sheet holds them now, if loaded.
			case automationInstallFinished(UUID, AutomationInstallOutcome, BrowserExtensionInventory?)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.browserExtensions)
	private var client

	private enum Cancellation: Hashable {
		case request
		case icons
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.configure) { state, profile in
			let available = MainActor.assumeIsolated({ [client] in client.isAvailable })
			let optionsAvailable = MainActor.assumeIsolated({ [client] in client.optionsAvailability() })
			let installationAvailable = MainActor.assumeIsolated({ [client] in client.isInstallationAvailable })
			let unpackedAvailable = MainActor.assumeIsolated({ [client] in client.isUnpackedAvailable })
			state.isWebstoreAvailable = MainActor.assumeIsolated({ [client] in client.isWebstoreAvailable })
			state.isWebstoreUpdateAvailable = MainActor.assumeIsolated({ [client] in client.isWebstoreUpdateAvailable })

			guard
				state.profile?.id != profile?.id
				|| state.isAvailable != available
				|| state.optionsAvailable != optionsAvailable
				|| state.isInstallationAvailable != installationAvailable
				|| state.isUnpackedAvailable != unpackedAvailable
			else {
				state.profile = profile
				return .none
			}

			let pending = state.pendingInstallation
			let webstore = state.webstoreRequest
			let abandoned = abandonAutomationInstall(&state)
			state.profile = profile
			state.isAvailable = available
			state.optionsAvailable = optionsAvailable
			state.isInstallationAvailable = installationAvailable
			state.isUnpackedAvailable = unpackedAvailable
			invalidate(&state)

			guard
				state.isPresented,
				available,
				profile != nil
			else {
				state.isPresented = false
				return .merge(
					.cancel(id: Cancellation.request),
					cancelInstallation(pending),
					declineWebstore(webstore),
					abandoned
				)
			}

			return .merge(cancelInstallation(pending), declineWebstore(webstore), abandoned, load(&state))
		}

		Pullback(\.ui.present) { state in
			guard
				state.isAvailable,
				MainActor.assumeIsolated({ [client] in client.isAvailable }),
				state.profile != nil
			else { return .none }

			// The sheet already shows this profile with work in flight: a load, a store
			// download or a review. Reloading would cancel it (DEV-801).
			if state.isPresented, state.isWorking { return .none }

			state.isPresented = true
			state.isInstallationAvailable = MainActor.assumeIsolated({ [client] in client.isInstallationAvailable })
			state.isWebstoreAvailable = MainActor.assumeIsolated({ [client] in client.isWebstoreAvailable })
			state.isWebstoreUpdateAvailable = MainActor.assumeIsolated({ [client] in client.isWebstoreUpdateAvailable })
			state.isUnpackedAvailable = MainActor.assumeIsolated({ [client] in client.isUnpackedAvailable })

			// A store request or a requested review survives the reload this starts; it waits for
			// the inventory.
			let webstore = state.webstoreRequest
			let requestedReview = state.requestedReview

			let effect = load(&state)
			state.webstoreRequest = webstore
			state.requestedReview = requestedReview
			return effect
		}

		Pullback(\.webstoreRequested) { state, request in

			// One review at a time, for the profile this sheet shows.
			guard
				state.isPresented,
				state.isWebstoreAvailable,
				MainActor.assumeIsolated({ [client] in client.isWebstoreAvailable }),
				state.profile?.id == request.profileID,
				state.webstoreRequest == nil,
				state.automationInstall == nil,
				state.pendingInstallation == nil,
				!state.hasSelection
			else { return declineWebstore(request) }

			state.pendingRemoval = nil
			state.webstoreRequest = request
			return prepareWebstore(&state)
		}

		Pullback(\.automationInstallRequested) { state, request in
			guard MainActor.assumeIsolated({ [client] in client.isWebstoreImportAvailable }) else {
				return .send(.delegate(.automationInstallFinished(request.id, .unavailable, nil)))
			}

			// One review at a time, for the profile this sheet shows.
			guard
				state.isPresented,
				state.profile?.id == request.profileID,
				state.automationInstall == nil,
				state.webstoreRequest == nil,
				state.pendingInstallation == nil,
				state.updateCheck == nil,
				!state.hasSelection
			else { return .send(.delegate(.automationInstallFinished(request.id, .busy, nil))) }

			state.pendingRemoval = nil
			var install = request
			install.stage = .waiting
			state.automationInstall = install
			return checkAutomationInstall(&state)
		}

		Pullback(\.automationInstallProceed) { state, id in
			guard let install = state.automationInstall, install.id == id, install.stage == .checking
			else { return .none }

			state.automationInstall?.stage = .waiting
			return prepareAutomationInstall(&state)
		}

		Pullback(\.automationInstallCancelled) { state, id in
			guard let install = state.automationInstall, install.id == id else { return .none }

			switch install.stage {
			case .waiting, .checking, .resolving:
				state.automationInstall = nil
				return .none

			case .preparing:
				state.automationInstall?.stage = .discarding
				return .none

			case .reviewing:
				// Install can no longer be clicked for a request nobody is waiting for. Cancelling the
				// prompt frees the profile, so the reload comes after it.
				state.automationInstall = nil
				let prompt = state.pendingInstallation
				state.pendingInstallation = nil
				state.isWorking = false
				let reload: Effect<Action> = state.isPresented ? load(&state) : .none
				return .concatenate(cancelInstallation(prompt), reload)

			case .discarding:
				return .none
			}
		}

		Pullback(\.reveal) { state, extensionID in

			// While the inventory loads, `finished` keeps a selection it contains.
			let isListed = state.inventory?.extensions.contains(where: { $0.id == extensionID }) ?? true
			guard state.isPresented, isListed else { return .none }

			state.selectedID = extensionID
			return .none
		}

		Pullback(\.ui.openWebstore) { state in
			guard state.isPresented, let profileID = state.profile?.id else { return .none }

			return .send(.delegate(.openWebstore(profileID)))
		}

		Pullback(\.ui.checkForUpdates) { state in
			guard
				state.isPresented,
				!state.isWorking,
				!state.hasSelection,
				state.updateCheck == nil,
				state.webstoreRequest == nil,
				state.automationInstall == nil,
				state.pendingInstallation == nil,
				state.isWebstoreUpdateAvailable,
				MainActor.assumeIsolated({ [client] in client.isWebstoreUpdateAvailable }),
				let inventory = state.inventory,
				inventory.profileID == state.profile?.id
			else { return .none }

			state.pendingRemoval = nil
			state.error = nil
			state.updateCheckResult = nil
			state.updateCheck = .init(remaining: state.updatableExtensionIDs)
			return checkNextUpdate(&state)
		}

		Pullback(\.ui.reviewUpdate) { state, extensionID in
			reviewUpdate(extensionID, state: &state)
		}

		Pullback(\.reviewUpdateRequested) { state, extensionID in
			guard state.isPresented, state.updateReviewsEnabled else { return .none }

			state.requestedReview = extensionID
			return startRequestedReview(&state)
		}

		Pullback(\.event.updatePrepared) { state, value in
			let (generation, request, result) = value
			guard
				state.isPresented,
				state.isWorking,
				state.generation == generation,
				state.updateCheck?.current == request.extensionID,
				state.profile?.id == request.profileID,
				let inventory = state.inventory,
				inventory.id == request.inventoryID,
				inventory.revision == request.revision
			else {
				if case let .success(prompt) = result { return cancelInstallation(prompt) }
				return .none
			}

			state.isWorking = false
			switch result {
			case let .success(prompt):
				guard
					prompt.profileID == request.profileID,
					prompt.inventoryID == request.inventoryID,
					prompt.revision == request.revision,
					prompt.candidate.isUpdate,
					prompt.candidate.extensionID == request.extensionID
				else {
					state.updateCheck?.failed.append(request.extensionID)
					return .merge(cancelInstallation(prompt), load(&state))
				}

				state.updateCheck?.isResolving = true
				state.updateCheck?.isAccepted = !prompt.candidate.permissionIncrease

				// More permissions wait for the review sheet; nothing new installs now.
				guard !prompt.candidate.permissionIncrease else {
					state.pendingInstallation = prompt
					state.isWorking = true
					return .none
				}

				state.isWorking = true
				state.generation += 1
				return self.request(generation: state.generation, profileID: prompt.profileID) { [client] in
					try await client.resolveInstallation(prompt, true)
				}

			case .failure(.upToDate):
				// The store offers nothing newer now, so no update waits for review.
				if state.updateReviewsEnabled {
					state.$updateReviews.withLock { $0.withdrawn(request.extensionID, in: request.profileID) }
				}

				// Nothing changed, so the inventory still holds for the next one.
				return checkNextUpdate(&state)

			case .failure:
				state.updateCheck?.failed.append(request.extensionID)

				// The failed attempt used the inventory up; reload, then go on.
				return load(&state)
			}
		}

		Pullback(\.configureDeveloperMode) { state, enabled in
			state.developerModeEnabled = enabled

			// Turning developer mode off withdraws only the controls and any open
			// picker. Installed extensions and in-flight native work are unchanged.
			if !enabled { state.directorySelection = nil }

			return .none
		}

		Pullback(\.ui.chooseUnpackedDirectory) { state in
			guard
				state.isPresented,
				!state.isWorking,
				!state.hasSelection,
				state.automationInstall == nil,
				state.canLoadUnpacked,
				MainActor.assumeIsolated({ [client] in client.isUnpackedAvailable }),
				let inventory = state.inventory,
				inventory.profileID == state.profile?.id
			else { return .none }

			state.pendingRemoval = nil
			state.error = nil
			state.directorySelection = .init(inventory: inventory)

			return .none
		}

		Pullback(\.ui.cancelDirectorySelection) { state, selection in
			guard state.directorySelection == selection else { return .none }

			state.directorySelection = nil

			// DEV-1210: a review the site menu asked for meanwhile goes on now.
			return startRequestedReview(&state)
		}

		Pullback(\.ui.selectDirectory) { state, value in
			let (selection, directory) = value
			guard
				state.directorySelection == selection,
				state.isPresented,
				!state.isWorking,
				state.inventory == selection.inventory,
				state.profile?.id == selection.inventory.profileID
			else { return .none }

			state.directorySelection = nil
			guard
				state.canLoadUnpacked,
				MainActor.assumeIsolated({ [client] in client.isUnpackedAvailable })
			else {
				state.error = .unavailable
				return .none
			}

			state.generation += 1
			state.isWorking = true
			state.pendingRemoval = nil
			state.error = nil

			return request(
				generation: state.generation,
				profileID: selection.inventory.profileID
			) { [client] in
				try await client.loadUnpacked(.init(
					inventory: selection.inventory,
					directory: directory
				))
			}
		}

		Pullback(\.ui.reload) { state, request in
			guard
				request.action == .reload,
				state.canLoadUnpacked,
				accepts(request, state: state)
			else { return .none }

			return perform(request, state: &state)
		}

		Pullback(\.ui.dismiss) { state in
			let pending = state.pendingInstallation
			let webstore = state.webstoreRequest
			let abandoned = abandonAutomationInstall(&state)
			state.isPresented = false
			invalidate(&state)

			return .merge(
				.cancel(id: Cancellation.request),
				cancelInstallation(pending),
				declineWebstore(webstore),
				abandoned
			)
		}

		Pullback(\.ui.refresh) { state in
			guard state.isPresented, !state.isWorking, !state.hasSelection else { return .none }

			return load(&state)
		}

		Pullback(\.ui.select) { state, id in
			guard state.inventory?.extensions.contains(where: { $0.id == id }) == true
			else { return .none }

			state.selectedID = id

			return .none
		}

		Pullback(\.ui.openOptions) { state, options in
			guard
				state.isPresented,
				state.isAvailable,
				state.optionsAvailable,
				!state.isWorking,
				state.profile?.id == options.profileID,
				let inventory = state.inventory,
				inventory.id == options.inventoryID,
				inventory.revision == options.revision,
				let item = inventory.extensions.first(where: { $0.id == options.extensionID }),
				item.canOpenOptions,
				item.state == .enabled,
				!item.permissionsIncreased,
				MainActor.assumeIsolated({ [client] in client.optionsAvailability() })
			else { return .none }

			state.generation += 1
			state.isWorking = true
			state.pendingRemoval = nil
			state.error = nil
			return request(generation: state.generation, profileID: options.profileID) { [client] in
				try await client.openOptions(options)
			}
		}

		Pullback(\.ui.setEnabled) { state, request in
			guard
				request.action == .enable || request.action == .disable,
				accepts(request, state: state)
			else { return .none }

			return perform(request, state: &state)
		}

		Pullback(\.ui.setAllowedInPrivate) { state, request in
			guard
				request.action == .allowInPrivate || request.action == .disallowInPrivate,
				accepts(request, state: state)
			else { return .none }

			return perform(request, state: &state)
		}

		Pullback(\.ui.requestRemoval) { state, request in
			guard request.action == .remove, accepts(request, state: state)
			else { return .none }

			state.pendingRemoval = request

			return .none
		}

		Pullback(\.ui.cancelRemoval) { state in
			state.pendingRemoval = nil

			return .none
		}

		Pullback(\.ui.confirmRemoval) { state, request in
			guard
				state.pendingRemoval == request,
				request.action == .remove,
				accepts(request, state: state)
			else { return .none }

			return perform(request, state: &state)
		}


		Pullback(\.ui.choosePackage) { state, expectedID in
			guard
				state.isPresented,
				!state.isWorking,
				!state.hasSelection,
				state.automationInstall == nil,
				state.isInstallationAvailable,
				MainActor.assumeIsolated({ [client] in client.isInstallationAvailable }),
				let inventory = state.inventory,
				inventory.profileID == state.profile?.id
			else { return .none }

			if let expectedID {
				guard inventory.extensions.contains(where: { $0.id == expectedID && $0.allows(.remove) })
				else { return .none }
			}

			state.pendingRemoval = nil
			state.error = nil
			state.packageSelection = .init(inventory: inventory, expectedExtensionID: expectedID)

			return .none
		}

		Pullback(\.ui.cancelPackageSelection) { state, selection in
			guard state.packageSelection == selection else { return .none }

			state.packageSelection = nil

			// DEV-1210: a review the site menu asked for meanwhile goes on now.
			return startRequestedReview(&state)
		}

		Pullback(\.ui.selectPackage) { state, value in
			let (selection, url) = value
			guard
				state.packageSelection == selection,
				state.isPresented,
				!state.isWorking,
				state.inventory == selection.inventory,
				state.profile?.id == selection.inventory.profileID
			else { return .none }

			state.packageSelection = nil
			guard MainActor.assumeIsolated({ [client] in client.isInstallationAvailable }) else {
				state.error = .unavailable
				return .none
			}

			state.isWorking = true
			state.generation += 1
			let generation = state.generation
			let preparation: Effect<Action> = .run { [client] send in
				do {
					let prompt = try await client.prepareInstallation(.init(
						inventory: selection.inventory,
						selectedFile: url,
						expectedExtensionID: selection.expectedExtensionID
					))
					guard !Task.isCancelled else {
						await client.cancelInstallation(prompt)
						return
					}

					await send(.event(.prepared(generation, selection, .success(prompt))))
				} catch {
					guard !Task.isCancelled else { return }

					await send(.event(.prepared(
						generation,
						selection,
						.failure(error as? BrowserExtensionsClient.Failure ?? .failed)
					)))
				}
			}
			.cancellable(id: Cancellation.request)

			// See `request(generation:profileID:operation:)`. A stale prompt is cancelled when
			// its generation arrives.
			return .concatenate(.cancel(id: Cancellation.request), preparation)
		}

		Pullback(\.event.prepared) { state, value in
			let (generation, selection, result) = value
			guard
				state.isPresented,
				state.isWorking,
				state.generation == generation,
				state.profile?.id == selection.inventory.profileID,
				state.inventory == selection.inventory
			else {
				if case let .success(prompt) = result { return cancelInstallation(prompt) }
				return .none
			}

			if state.automationInstall?.stage == .discarding {
				// Nobody waits for this install any more: drop its package, then reload.
				state.automationInstall = nil
				state.isWorking = false
				let reload = load(&state)
				if case let .success(prompt) = result { return .concatenate(cancelInstallation(prompt), reload) }
				return reload
			}

			let automation = state.automationInstall?.stage == .preparing ? state.automationInstall : nil
			guard MainActor.assumeIsolated({ [client] in client.isInstallationAvailable }) else {
				state.isWorking = false
				state.inventory = nil
				state.error = .unavailable
				let finished: Effect<Action> = automation == nil
				? .none
				: finishAutomationInstall(&state) { .failed(.unavailable, name: $0, version: $1) }
				if case let .success(prompt) = result { return .merge(cancelInstallation(prompt), finished) }
				return finished
			}

			switch result {
			case let .success(prompt):
				let matchesExpectedExtension = selection.expectedExtensionID == nil
				|| prompt.candidate.extensionID == selection.expectedExtensionID

				// An MCP client's install shows the item it asked for, as a new install.
				let matchesAutomation = automation.map { prompt.candidate.extensionID == $0.extensionID } ?? true

				guard
					prompt.profileID == selection.inventory.profileID,
					prompt.inventoryID == selection.inventory.id,
					prompt.revision == selection.inventory.revision,
					prompt.candidate.isUpdate == (selection.expectedExtensionID != nil),
					matchesExpectedExtension,
					matchesAutomation
				else {
					state.isWorking = false
					state.inventory = nil
					state.error = .invalidResponse
					let finished: Effect<Action> = automation == nil
					? .none
					: finishAutomationInstall(&state) { .failed(.invalidResponse, name: $0, version: $1) }
					return .merge(cancelInstallation(prompt), finished)
				}

				state.pendingInstallation = prompt
				if automation != nil {
					state.automationInstall?.stage = .reviewing
					state.automationInstall?.name = prompt.candidate.name
					state.automationInstall?.version = prompt.candidate.version
				}

			case let .failure(error):
				state.isWorking = false
				state.inventory = nil
				if
					let automation,
					error == .staleInventory,
					automation.staleAttempts + 1 < AutomationInstall.maximumStaleAttempts,
					state.isPresented
				{
					// The sheet reads the profile again, its own read, and prepares once more. The
					// install holds the sheet meanwhile; a cancelled request takes it away, and an
					// item installed by then is reported so.
					state.automationInstall?.staleAttempts += 1
					state.automationInstall?.stage = .waiting
					return load(&state)
				}
				state.error = error
				if automation != nil {
					return finishAutomationInstall(&state) { .failed(error, name: $0, version: $1) }
				}
			}

			return .none
		}

		// DEV-1210: a failed preparation clears the inventory it used up without a load finishing.
		// With a review the site menu asked for waiting and nothing else holding the sheet, read the
		// profile again; the review goes on once the inventory is in.
		Pullback(\.event.prepared) { state, _ in
			guard
				state.requestedReview != nil,
				state.isPresented,
				!state.isWorking,
				state.pendingInstallation == nil,
				state.automationInstall == nil,
				state.webstoreRequest == nil,
				!state.hasSelection
			else { return .none }

			return state.inventory == nil ? load(&state) : startRequestedReview(&state)
		}

		Pullback(\.ui.respondToInstallation) { state, value in
			let (prompt, accept) = value
			guard
				state.isPresented,
				state.pendingInstallation == prompt,
				state.profile?.id == prompt.profileID
			else { return .none }

			state.pendingInstallation = nil
			let isUpdateCheck = state.updateCheck?.isResolving == true
			if isUpdateCheck { state.updateCheck?.isAccepted = accept }

			// DEV-1210: a declined update keeps the installed version, and its mark goes until the
			// store offers a newer one: from an update check, or a package of the very version that
			// waits for review.
			let waiting = state.updateReview(prompt.candidate.extensionID)
			if
				!accept,
				state.updateReviewsEnabled,
				prompt.candidate.isUpdate,
				isUpdateCheck || waiting?.version == prompt.candidate.version,
				let installed = state.inventory?.extensions.first(where: { $0.id == prompt.candidate.extensionID })
			{
				state.$updateReviews.withLock {
					$0.declined(.init(prompt.candidate, profileID: prompt.profileID, installedVersion: installed.version))
				}
			}
			if state.automationInstall?.stage == .reviewing { state.automationInstall?.stage = .resolving(accepted: accept) }

			// The list opens on what was just installed, with its Options and details.
			if accept { state.selectedID = prompt.candidate.extensionID }
			guard MainActor.assumeIsolated({ [client] in client.isInstallationAvailable }) else {
				state.isWorking = false
				state.inventory = nil
				state.error = .unavailable
				let finished = finishAutomationInstall(&state) { name, version in
					accept ? .failed(.unavailable, name: name, version: version) : .declined(name: name, version: version)
				}
				return .merge(cancelInstallation(prompt), finished)
			}

			state.generation += 1
			return request(generation: state.generation, profileID: prompt.profileID) { [client] in
				try await client.resolveInstallation(prompt, accept)
			}
		}

		Pullback(\.event.finished) { state, response in
			let (generation, profileID, result) = response

			guard
				state.isPresented,
				state.isWorking,
				state.generation == generation,
				state.profile?.id == profileID
			else { return .none }

			state.isWorking = false
			state.optionsAvailable = MainActor.assumeIsolated({ [client] in client.optionsAvailability() })

			guard
				state.isAvailable,
				MainActor.assumeIsolated({ [client] in client.isAvailable })
			else {
				state.inventory = nil
				state.error = .unavailable
				return abandonAutomationInstall(&state)
			}

			switch result {
			case let .success(inventory):
				guard
					inventory.profileID == profileID,
					inventory.revision > 0,
					Set(inventory.extensions.map(\.id)).count == inventory.extensions.count
				else {
					state.inventory = nil
					state.error = .invalidResponse
					return .none
				}

				state.inventory = inventory
				state.error = nil

				// DEV-1210: an extension that updated some other way, or went, no longer waits for review.
				if state.updateReviewsEnabled {
					state.$updateReviews.withLock { $0.reconcile(with: inventory) }
				}

				if !inventory.extensions.contains(where: { $0.id == state.selectedID }) {
					state.selectedID = inventory.extensions.first?.id
				}

				if let install = state.automationInstall {
					switch install.stage {
					case .waiting:
						// The app checked the request against the first load; a retry after a stale
						// preparation goes straight on, with a newer revision by design.
						return install.staleAttempts > 0 ? prepareAutomationInstall(&state) : checkAutomationInstall(&state)

					case let .resolving(accepted):
						let installed = inventory.extensions.contains { $0.id == install.extensionID }
						return finishAutomationInstall(&state) { name, version in
							switch (accepted, installed) {
							case (true, true): .installed(name: name, version: version)
							case (true, false): .failed(.failed, name: name, version: version)
							case (false, _): .declined(name: name, version: version)
							}
						}

					case .checking, .preparing, .reviewing, .discarding:
						break
					}
				}
				if state.webstoreRequest != nil { return prepareWebstore(&state) }
				if var check = state.updateCheck {
					if check.isResolving, let current = check.current {
						// A declined review also finishes with the unchanged inventory.
						if check.isAccepted { check.updated.append(current) } else { check.declined.append(current) }
					}
					check.isResolving = false
					check.isAccepted = false
					state.updateCheck = check
					return checkNextUpdate(&state)
				}

			case let .failure(error):
				state.inventory = nil

				// A declined or failed update doesn't stop the check: reload and go on.
				if var check = state.updateCheck, check.isResolving {
					if let current = check.current {
						if error == .cancelled { check.declined.append(current) } else { check.failed.append(current) }
					}
					check.isResolving = false
					check.isAccepted = false
					state.updateCheck = check
					return load(&state)
				}
				state.error = error
				state.updateCheck = nil
				if let install = state.automationInstall {
					switch install.stage {
					case .waiting, .resolving(accepted: true):
						return finishAutomationInstall(&state) { .failed(error, name: $0, version: $1) }

					case .resolving(accepted: false):
						return finishAutomationInstall(&state) { .declined(name: $0, version: $1) }

					case .checking, .preparing, .reviewing, .discarding:
						break
					}
				}
			}

			return .none
		}

		// Each load reads its icons again: an unpacked extension reloaded after its icon changed
		// keeps the same path.
		Pullback(\.event.finished) { state, _ in
			readIcons(&state)
		}

		// DEV-1210: a review the site menu asked for goes on once the sheet is idle again, after a
		// load, an update check, an MCP install or a store request.
		Pullback(\.event.finished) { state, _ in
			startRequestedReview(&state)
		}

		Pullback(\.event.iconsRead) { state, icons in
			let paths = Self.iconPaths(state.inventory)
			state.icons = icons.filter { paths.contains($0.key) }
			return .none
		}
	}

	/// Reads the loaded inventory's icons. Until they arrive the rows keep the icons they show,
	/// less those of extensions the inventory no longer lists.
	private func readIcons(_ state: inout State) -> Effect<Action> {
		let paths = Self.iconPaths(state.inventory)
		state.icons = state.icons.filter { paths.contains($0.key) }

		guard !paths.isEmpty else { return .cancel(id: Cancellation.icons) }

		let read: Effect<Action> = .run { [client] send in
			var icons: [String: Data] = [:]
			for path in paths.sorted() {
				if let data = await client.icon(path) { icons[path] = data }
			}
			try Task.checkCancellation()
			await send(.event(.iconsRead(icons)))
		}
		.cancellable(id: Cancellation.icons)

		// Cancelled in reducer order, as requests are: an older read finishing later only sets
		// icons the current inventory still lists.
		return .concatenate(.cancel(id: Cancellation.icons), read)
	}

	private static func iconPaths(_ inventory: BrowserExtensionInventory?) -> Set<String> {
		Set(inventory?.extensions.compactMap { $0.iconPath(pixels: iconPixels) } ?? [])
	}

	/// The pixels the details' icon covers on a 2x display, 25 points; rows draw it smaller.
	public static let iconPixels: Int = 50

	/// Hands the loaded inventory to the app for the MCP install's checks.
	private func checkAutomationInstall(_ state: inout State) -> Effect<Action> {
		guard
			let install = state.automationInstall,
			install.stage == .waiting,
			!state.isWorking,
			let inventory = state.inventory
		else { return .none }

		guard
			inventory.profileID == install.profileID,
			state.profile?.id == install.profileID
		else { return finishAutomationInstall(&state) { .failed(.missingProfile, name: $0, version: $1) } }

		state.automationInstall?.stage = .checking
		return .send(.delegate(.automationInstallInventoryLoaded(install.id, inventory)))
	}

	/// Starts the checked MCP install once this profile's inventory is loaded: native downloads
	/// and verifies the store's package by ID (DEV-845's path), then the review sheet shows it.
	private func prepareAutomationInstall(_ state: inout State) -> Effect<Action> {
		guard
			let install = state.automationInstall,
			install.stage == .waiting,
			!state.isWorking,
			let inventory = state.inventory
		else { return .none }

		guard
			inventory.profileID == install.profileID,
			state.profile?.id == install.profileID
		else { return finishAutomationInstall(&state) { .failed(.missingProfile, name: $0, version: $1) } }

		if let installed = inventory.extensions.first(where: { $0.id == install.extensionID }) {
			state.selectedID = installed.id
			return finishAutomationInstall(&state) { _, _ in
				.alreadyInstalled(name: installed.name, version: installed.version)
			}
		}

		let selection = PackageSelection(inventory: inventory, expectedExtensionID: nil)
		let request = BrowserWebstoreImportRequest(inventory: inventory, extensionID: install.extensionID)
		state.automationInstall?.stage = .preparing
		state.isWorking = true
		state.error = nil
		state.generation += 1
		let generation = state.generation
		let preparation: Effect<Action> = .run { [client] send in
			do {
				let prompt = try await client.prepareWebstoreImport(request)
				guard !Task.isCancelled else {
					await client.cancelInstallation(prompt)
					return
				}

				await send(.event(.prepared(generation, selection, .success(prompt))))
			} catch {
				guard !Task.isCancelled else { return }

				await send(.event(.prepared(
					generation,
					selection,
					.failure(error as? BrowserExtensionsClient.Failure ?? .failed)
				)))
			}
		}
		.cancellable(id: Cancellation.request)

		return .concatenate(.cancel(id: Cancellation.request), preparation)
	}

	/// Ends the MCP install with an outcome built from what the review showed, if anything.
	private func finishAutomationInstall(
		_ state: inout State,
		outcome: (_ name: String?, _ version: String?) -> AutomationInstallOutcome
	) -> Effect<Action> {
		guard let install = state.automationInstall else { return .none }

		state.automationInstall = nil
		return .send(.delegate(.automationInstallFinished(
			install.id,
			outcome(install.name, install.version),
			state.inventory
		)))
	}

	/// The sheet closed, changed profile or lost the engine under an MCP install. A review on
	/// screen counts as declined; one already answered with Install can't be confirmed, so it
	/// reports cancelled.
	private func abandonAutomationInstall(_ state: inout State) -> Effect<Action> {
		let stage = state.automationInstall?.stage
		return finishAutomationInstall(&state) { name, version in
			switch stage {
			case .reviewing?, .resolving(accepted: false)?: .declined(name: name, version: version)
			default: .failed(.cancelled, name: name, version: version)
			}
		}
	}

	/// Asks the store about the next extension of the check, or ends the check.
	/// Checks one extension's update, as Check for Updates does for all of them: one that asks for
	/// more permissions shows the review sheet (DEV-1210).
	private func reviewUpdate(
		_ extensionID: String,
		state: inout State
	) -> Effect<Action> {
		guard
			state.isPresented,
			state.updateReviewsEnabled,
			!state.isWorking,
			!state.hasSelection,
			state.updateCheck == nil,
			state.webstoreRequest == nil,
			state.automationInstall == nil,
			state.pendingInstallation == nil,
			state.isWebstoreUpdateAvailable,
			MainActor.assumeIsolated({ [client] in client.isWebstoreUpdateAvailable }),
			let inventory = state.inventory,
			inventory.profileID == state.profile?.id,
			state.updatableExtensionIDs.contains(extensionID)
		else { return .none }

		state.pendingRemoval = nil
		state.error = nil
		state.updateCheckResult = nil
		state.selectedID = extensionID
		state.updateCheck = .init(remaining: [extensionID])
		return checkNextUpdate(&state)
	}

	/// Starts the review the site menu asked for once nothing else runs: it waits for the
	/// inventory and for a check, install, store request or review in progress. Once the sheet is
	/// idle, a review it can't start (the extension went, or the store isn't reachable) is dropped.
	private func startRequestedReview(_ state: inout State) -> Effect<Action> {
		guard
			let extensionID = state.requestedReview,
			!state.isWorking,
			state.inventory != nil,
			state.updateCheck == nil,
			state.webstoreRequest == nil,
			state.automationInstall == nil,
			state.pendingInstallation == nil,
			!state.hasSelection
		else { return .none }

		state.requestedReview = nil
		return reviewUpdate(extensionID, state: &state)
	}

	private func checkNextUpdate(_ state: inout State) -> Effect<Action> {
		guard var check = state.updateCheck, !state.isWorking else { return .none }

		guard
			let inventory = state.inventory,
			inventory.profileID == state.profile?.id,
			MainActor.assumeIsolated({ [client] in client.isWebstoreUpdateAvailable })
		else {
			state.updateCheck = nil
			return .none
		}

		// An extension removed meanwhile is skipped.
		let updatable = Set(state.updatableExtensionIDs)
		check.remaining.removeAll { !updatable.contains($0) }
		guard !check.remaining.isEmpty else {
			state.updateCheck = nil
			state.updateCheckResult = .init(
				updated: check.updated.count,
				declined: check.declined.count,
				failed: check.failed.count
			)

			// A review the site menu asked for meanwhile goes on now (DEV-1210).
			return startRequestedReview(&state)
		}

		let extensionID = check.remaining.removeFirst()
		check.current = extensionID
		state.updateCheck = check
		state.isWorking = true
		state.generation += 1
		let generation = state.generation
		let request = BrowserWebstoreUpdateRequest(inventory: inventory, extensionID: extensionID)
		let preparation: Effect<Action> = .run { [client] send in
			do {
				let prompt = try await client.prepareWebstoreUpdate(request)
				guard !Task.isCancelled else {
					await client.cancelInstallation(prompt)
					return
				}

				await send(.event(.updatePrepared(generation, request, .success(prompt))))
			} catch {
				guard !Task.isCancelled else { return }

				await send(.event(.updatePrepared(
					generation,
					request,
					.failure(error as? BrowserExtensionsClient.Failure ?? .failed)
				)))
			}
		}
		.cancellable(id: Cancellation.request)

		return .concatenate(.cancel(id: Cancellation.request), preparation)
	}

	private func declineWebstore(_ request: BrowserWebstoreInstallRequest?) -> Effect<Action> {
		guard let request else { return .none }
		return .run { [client] _ in await client.declineWebstoreInstallation(request) }
	}

	/// Starts the waiting store request once this profile's inventory is loaded:
	/// native downloads and verifies the package, then the review sheet shows it.
	private func prepareWebstore(_ state: inout State) -> Effect<Action> {
		guard
			let request = state.webstoreRequest,
			!state.isWorking,
			let inventory = state.inventory
		else { return .none }

		state.webstoreRequest = nil
		guard
			inventory.profileID == request.profileID,
			state.profile?.id == request.profileID
		else { return declineWebstore(request) }

		if let installed = inventory.extensions.first(where: { $0.id == request.extensionID }) {
			state.selectedID = installed.id
			return declineWebstore(request)
		}

		let selection = PackageSelection(inventory: inventory, expectedExtensionID: nil)
		state.isWorking = true
		state.error = nil
		state.generation += 1
		let generation = state.generation
		let preparation: Effect<Action> = .run { [client] send in
			do {
				let prompt = try await client.prepareWebstoreInstallation(request, inventory)
				guard !Task.isCancelled else {
					await client.cancelInstallation(prompt)
					return
				}

				await send(.event(.prepared(generation, selection, .success(prompt))))
			} catch {
				guard !Task.isCancelled else { return }

				await send(.event(.prepared(
					generation,
					selection,
					.failure(error as? BrowserExtensionsClient.Failure ?? .failed)
				)))
			}
		}
		.cancellable(id: Cancellation.request)

		return .concatenate(.cancel(id: Cancellation.request), preparation)
	}

	private func cancelInstallation(_ prompt: BrowserExtensionInstallPrompt?) -> Effect<Action> {
		guard let prompt else { return .none }
		return .run { [client] _ in await client.cancelInstallation(prompt) }
	}

	private func invalidate(_ state: inout State) {
		state.generation += 1
		state.isWorking = false
		state.inventory = nil
		state.pendingRemoval = nil
		state.packageSelection = nil
		state.directorySelection = nil
		state.pendingInstallation = nil
		state.webstoreRequest = nil
		state.updateCheck = nil
		state.updateCheckResult = nil
		state.requestedReview = nil
		state.selectedID = nil
		state.error = nil
	}

	private func accepts(
		_ request: BrowserExtensionRequest,
		state: State
	) -> Bool {
		guard
			state.isPresented,
			state.isAvailable,
			MainActor.assumeIsolated({ [client] in client.isAvailable }),
			!state.isWorking,
			!state.hasSelection,
			state.profile?.id == request.profileID,
			let inventory = state.inventory,
			inventory.id == request.inventoryID,
			inventory.profileID == request.profileID,
			inventory.revision == request.revision,
			let item = inventory.extensions.first(where: { $0.id == request.extensionID })
		else { return false }

		return item.allows(request.action)
	}

	private func load(_ state: inout State) -> Effect<Action> {
		guard
			state.isAvailable,
			MainActor.assumeIsolated({ [client] in client.isAvailable }),
			let profileID = state.profile?.id
		else {
			invalidate(&state)
			state.error = .unavailable
			return .cancel(id: Cancellation.request)
		}

		state.generation += 1
		state.isWorking = true
		state.inventory = nil
		state.pendingRemoval = nil
		state.error = nil

		return request(generation: state.generation, profileID: profileID) { [client] in
			try await client.inspect(profileID)
		}
	}

	private func perform(
		_ request: BrowserExtensionRequest,
		state: inout State
	) -> Effect<Action> {
		state.generation += 1
		state.isWorking = true
		state.pendingRemoval = nil
		state.error = nil

		return self.request(generation: state.generation, profileID: request.profileID) { [client] in
			try await client.manage(request)
		}
	}

	private func request(
		generation: Int,
		profileID: Profile.ID,
		operation: @escaping @MainActor @Sendable () async throws -> BrowserExtensionInventory
	) -> Effect<Action> {
		let request: Effect<Action> = .run { send in
			do {
				try Task.checkCancellation()
				let inventory = try await operation()
				try Task.checkCancellation()

				await send(.event(.finished(generation, profileID, .success(inventory))))
			} catch {
				guard !Task.isCancelled else { return }

				await send(.event(.finished(
					generation,
					profileID,
					.failure(error as? BrowserExtensionsClient.Failure ?? .failed)
				)))
			}
		}
		.cancellable(id: Cancellation.request)

		// `cancelInFlight` cancels when the effect's task registers, which happens off the
		// main actor, so after back-to-back scope changes an older request could cancel this
		// one and leave the panel working. Cancel synchronously in reducer order; an older
		// request that registers later finishes with a generation that is no longer current.
		return .concatenate(.cancel(id: Cancellation.request), request)
	}
}
