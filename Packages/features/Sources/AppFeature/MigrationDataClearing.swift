import BrowserCore
import BrowserEngineClient
import MigrationAssistant
import MigrationAssistantFeature
import OnboardingFeature
import ViewerFeature
import _ComposableArchitecture

/// "Clear Arx data first" in the migration assistant, done by the host (DEV-833).
internal struct MigrationClearing: Equatable, Sendable {
	internal enum Step: Equatable, Sendable {
		/// Waiting for every old page to agree to close; nothing has changed yet.
		case approving

		/// The fresh profile and space are published and must reach disk before any profile
		/// retires, or a crash could leave a saved workspace with no profile to open.
		case saving

		/// Retiring the old profiles in turn.
		case retiring
	}

	/// The fresh profile and space the import goes into.
	internal var fresh: ProvisionalProfile

	/// The old profiles still to retire, the first one retiring now.
	internal var retiring: [Profile.ID]
	internal var step: Step
}

@CasePathable
public enum MigrationClearingAction: Sendable {
	/// Every page of the old profiles agreed to close and closed.
	case approved(previous: BrowserOrganization, updated: BrowserOrganization, closed: [BrowserCore.Tab.ID])

	/// A page refused to close, or the check couldn't run. Nothing changed but the pages closed
	/// so far, which windows showing them open again.
	case refused(closed: [BrowserCore.Tab.ID])
}

/// Clears Arx before an import, when the user turned on "Clear Arx data first" (DEV-650) and
/// confirmed what goes.
///
/// The clear must name exactly what Arx holds now, or it's refused and the assistant shows the
/// current data. Every page of the old profiles, favorites too, must agree to close first, as
/// when Settings removes a space; a page that refuses leaves Arx as it was. Then one fresh
/// Default profile and space replace every space, so each window shows the fresh space, and
/// that reaches disk before anything retires. Each old profile is then retired in turn through
/// `ProfileRetirement`: a durable intent first, the engine erasing the profile's data on its
/// next start, never files deleted here. The assistant hears `cleared` with the fresh
/// destination, or `clearFailed`. A failure part of the way through keeps the fresh space and
/// the profiles retired so far, the others stay without spaces and can be retired from
/// Settings, and onboarding imports into what's left.
@Reducer
internal struct MigrationDataClearing {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.uuid)
	private var uuid

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.onboarding.page.migration.migration.delegate.clearExistingData) { state, confirmed in
			guard
				state.migrationClearing == nil,
				state.canClearForMigration
			else { return Self.answer(cleared: nil) }

			// Arx changed since the assistant counted it: the user confirmed something else.
			// Show what's there now; the next confirmation names it.
			guard confirmed == state.migrationExistingData else {
				state.refreshMigrationTargets(preferring: nil)
				return Self.answer(cleared: nil)
			}

			let fresh: ProvisionalProfile = .init(
				profileID: .init(rawValue: uuid()),
				spaceID: .init(rawValue: uuid())
			)
			let previous: BrowserOrganization = state.workspace
			let updated: BrowserOrganization
			do {
				updated = try previous.replacingSpaces(with: fresh, uuid: { uuid() })
			} catch {
				return Self.answer(cleared: nil)
			}

			// Every tab of the old profiles, favorites too, closes here, each page asked in the same
			// step that closes it, so a page that reloads after agreeing is asked again. Retirement
			// would otherwise ask a loaded favorite once the spaces are gone.
			let closing: [BrowserCore.Tab.ID] = previous.tabs.map(\.id)
			state.migrationClearing = .init(
				fresh: fresh,
				retiring: previous.profiles.map(\.id),
				step: .approving
			)

			// The question Settings asks before removing a space with tabs, bound to the document
			// that answers it. A refusal stops here, and nothing else changes.
			return .run { @MainActor [engine] send in
				guard let close = engine.closeAuthorized else {
					send(.migrationClearing(.refused(closed: [])))
					return
				}

				var closed: [BrowserCore.Tab.ID] = []

				// A page shown again while a later one was asking is asked again, a few times at most.
				// Every tab goes through the engine, also one without a page yet: a pending open
				// is refused there rather than finishing after the tab is gone.
				for _ in 0..<3 {
					for id in closing {
						let revision: UInt64? = engine.snapshot(id)?.revision
						let agreed: Bool = (try? await close(id, revision, { true }, {})) ?? false
						guard agreed, !Task.isCancelled else {
							send(.migrationClearing(.refused(closed: closed)))
							return
						}
						if revision != nil { closed.append(id) }
					}

					// Checked and published in this one main-actor turn, so nothing reopens in between;
					// once published, the old tabs are gone from every window.
					if closing.allSatisfy({ engine.snapshot($0) == nil }) {
						send(.migrationClearing(.approved(previous: previous, updated: updated, closed: closed)))
						return
					}
				}
				send(.migrationClearing(.refused(closed: closed)))
			}
		}

		Pullback(\.migrationClearing.refused) { state, closed in
			guard state.migrationClearing?.step == .approving else { return .none }

			state.migrationClearing = nil
			return .merge(state.reshowing(Set(closed)), Self.answer(cleared: nil))
		}

		Pullback(\.migrationClearing.approved) { state, value in
			let (previous, updated, closed) = value
			guard
				let clearing = state.migrationClearing,
				clearing.step == .approving
			else { return .none }
			guard state.workspace == previous, state.canClearForMigration else {
				state.migrationClearing = nil
				return .merge(state.reshowing(Set(closed)), Self.answer(cleared: nil))
			}

			state.migrationClearing?.step = .saving
			state.workspace = updated
			state.unsavedOrganization = updated
			state.settings.selectedProfileID = clearing.fresh.profileID

			// A first onboarding's provisional Default is about to be retired; the fresh Default
			// takes its place, so an import that makes its own profiles can settle it the same way.
			if state.onboardingProgress.provisionalProfile != nil {
				state.$onboardingProgress.withLock { $0.provisionalProfile = clearing.fresh }
			}

			// Reconciling moves every window whose space went to the first space left: the fresh one.
			var effects: [Effect<Action>] = [
				.send(.settings(.event(.organizationChanged))),
				.send(.main(.reconcile(updated))),
			]
			for id in state.windows.filter({ !$0.isPrivate }).map(\.id) {
				effects.append(.send(.windows(.element(id: id, action: .reconcile(updated)))))
			}

			// Written at once while clearing; retiring starts once it's on disk.
			effects.append(.send(.delegate(.save(updated))))
			return .concatenate(effects)
		}

		// A new assistant offers what Arx holds now, after imports or clears since onboarding opened.
		Pullback(\.onboarding.page.migration.ui.importData) { state in
			state.refreshMigrationExistingData()
			return .none
		}

		Pullback(\.onboarding.page.migration.ui.customize) { state in
			state.refreshMigrationExistingData()
			return .none
		}

		// Onboarding can open before retirement's availability is known; offer the option once it is.
		Pullback(\.profileRetirement.refreshed) { state, _ in
			state.refreshMigrationExistingData()
			return .none
		}

		Pullback(\.profileRetirement.refreshFailed) { state, _ in
			state.refreshMigrationExistingData()
			return .none
		}

		Pullback(\.event.saveSucceeded) { state, value in
			let (organization, _) = value
			guard
				let clearing = state.migrationClearing,
				clearing.step == .saving,
				organization.profiles.ids.contains(clearing.fresh.profileID),
				organization.spaces.ids.contains(clearing.fresh.spaceID)
			else { return .none }

			state.migrationClearing?.step = .retiring
			return retireNext(&state)
		}

		// Nothing retired yet: the fresh space stays, and the old profiles stay without spaces.
		Pullback(\.event.saveFailed) { state, _ in
			guard
				let clearing = state.migrationClearing,
				clearing.step == .saving
			else { return .none }

			state.migrationClearing = nil
			state.refreshMigrationTargets(preferring: clearing.fresh)
			return Self.answer(cleared: nil)
		}

		Pullback(\.profileRetirement.ended) { state, value in
			let (id, retired) = value
			guard
				let clearing = state.migrationClearing,
				clearing.step == .retiring,
				clearing.retiring.first == id
			else { return .none }

			// The fresh space and the profiles retired so far stay; import into what's left.
			guard retired else {
				state.migrationClearing = nil
				state.refreshMigrationTargets(preferring: clearing.fresh)
				return Self.answer(cleared: nil)
			}

			state.migrationClearing?.retiring.removeFirst()
			return retireNext(&state)
		}
	}

	/// Retires the next old profile, or answers the assistant once none is left.
	private func retireNext(_ state: inout State) -> Effect<Action> {
		guard let clearing = state.migrationClearing else { return .none }
		guard let next = clearing.retiring.first else {
			state.migrationClearing = nil
			return Self.answer(cleared: clearing.fresh)
		}

		return .send(.profileRetirement(.begin(next)))
	}

	private static func answer(cleared fresh: ProvisionalProfile?) -> Effect<Action> {
		guard let fresh else {
			return .send(.onboarding(.page(.migration(.migration(.event(.clearFailed))))))
		}

		let option: MigrationAssistantFeature.SpaceOption = .init(
			profileID: fresh.profileID,
			profileName: ProvisionalProfile.name,
			spaceID: fresh.spaceID,
			spaceName: ProvisionalProfile.name
		)
		return .send(.onboarding(.page(.migration(.migration(.event(.cleared(
			.init(profileID: fresh.profileID, spaceID: fresh.spaceID),
			spaceOptions: [option]
		)))))))
	}
}

extension AppFeature.State {
	/// What "Clear Arx data first" would remove, for the migration assistant. Nil, which hides
	/// the option, while retirement isn't durable here, and while the workspace holds only what a
	/// fresh install starts with: there's nothing to clear (DEV-833).
	internal var migrationExistingData: MigrationAssistantFeature.ExistingData? {
		// What came from iCloud in this onboarding (DEV-1215) isn't offered for clearing: retiring
		// it would reach every Mac.
		guard
			settings.retirementAvailable,
			!workspaceHoldsOnlyFreshInstallDefaults,
			onboarding?.workspaceCameFromICloud != true,
			!onboardingProgress.adoptedICloudWorkspace
		else { return nil }

		return .init(
			profileNames: workspace.profiles.map(\.name),
			spaceCount: workspace.spaces.count,
			tabCount: workspace.tabs.count
		)
	}

	/// One profile with one space, and no tab, pinned tab, favorite, folder or archived entry.
	internal var workspaceHoldsOnlyFreshInstallDefaults: Bool {
		workspace.profiles.count <= 1
		&& workspace.spaces.count <= 1
		&& workspace.tabs.isEmpty
		&& workspace.folders.isEmpty
		&& workspace.archive.isEmpty
		&& workspace.profiles.allSatisfy { $0.favorites.isEmpty }
		&& workspace.spaces.allSatisfy { $0.savedItems.isEmpty && $0.unpinnedTabs.isEmpty }
	}

	/// Every space with its profile, for the import page and the assistant.
	internal var migrationSpaceOptions: [MigrationAssistantFeature.SpaceOption] {
		workspace.spaces.compactMap { space in
			workspace.profiles[id: space.profileID].map { profile in
				.init(
					profileID: profile.id,
					profileName: profile.name,
					spaceID: space.id,
					spaceName: space.name
				)
			}
		}
	}

	/// Opens again the pages a stopped clear closed, where a window shows them.
	fileprivate func reshowing(_ closed: Set<BrowserCore.Tab.ID>) -> Effect<AppFeature.Action> {
		guard !closed.isEmpty else { return .none }

		func reshow(_ viewer: ViewerFeature.State) -> [ViewerFeature.Action] {
			guard viewer.isSplit else {
				guard let tab = viewer.item.tab, closed.contains(tab.id) else { return [] }

				return [.item(.show(tab))]
			}

			// The pane's own item, since the viewer skips a pane that already holds the tab.
			return viewer.panes.compactMap { pane in
				guard let tab = pane.item.tab, closed.contains(tab.id) else { return nil }

				return .panes(.element(id: pane.id, action: .item(.show(tab))))
			}
		}

		var effects: [Effect<AppFeature.Action>] = reshow(main.viewer).map { .send(.main(.viewer($0))) }
		for window in windows where !window.isPrivate {
			effects += reshow(window.viewer).map { .send(.windows(.element(id: window.id, action: .viewer($0)))) }
		}
		return .merge(effects)
	}

	/// Updates what onboarding offers to clear, while no clear runs and it differs.
	internal mutating func refreshMigrationExistingData() {
		guard
			migrationClearing == nil,
			let current = onboarding,
			current.existingData != migrationExistingData
		else { return }

		refreshMigrationTargets(preferring: nil)
	}

	/// Points onboarding, its import page and the open assistant at the workspace as it is
	/// now: `fresh`'s space when it's there, otherwise the destination they had while it still
	/// exists, otherwise the main window's space.
	fileprivate mutating func refreshMigrationTargets(preferring fresh: ProvisionalProfile?) {
		guard let current = onboarding else { return }

		let candidates: [MigrationDestination?] = [
			fresh.map { .init(profileID: $0.profileID, spaceID: $0.spaceID) },
			current.destination,
			.init(profileID: main.sidebar.space.profileID, spaceID: main.sidebar.spaceID),
		]
		let spaces: IdentifiedArrayOf<Space> = workspace.spaces
		let destination: MigrationDestination? = candidates.lazy.compactMap { $0 }.first { candidate in
			spaces[id: candidate.spaceID]?.profileID == candidate.profileID
		}
		let spaceOptions: [MigrationAssistantFeature.SpaceOption] = migrationSpaceOptions
		let existingData: MigrationAssistantFeature.ExistingData? = migrationExistingData
		onboarding?.updateMigrationTargets(
			destination: destination,
			spaceOptions: spaceOptions,
			existingData: existingData
		)
	}

	/// Whether every old profile could retire once its spaces are gone: nothing else is
	/// retiring or quitting, and no Little Arx, Peek or private window uses one of them.
	fileprivate var canClearForMigration: Bool {
		let profiles: Set<Profile.ID> = Set(workspace.profiles.map(\.id))
		return settings.retirementAvailable
		&& !profileRetirement.isBusy
		&& !checkingQuit
		&& !shouldQuit
		&& !hasPendingProfileTransfers
		&& !littleWindows.contains { profiles.contains($0.tab.profileID) }
		&& !peeks.contains { profiles.contains($0.tab.profileID) }
		&& !privateProfileOpeners.values.contains { profiles.contains($0) }
	}
}

extension BrowserOrganization {
	/// This organization with one fresh Default profile and space in place of every space.
	/// The old profiles stay, without spaces, until they're retired.
	fileprivate func replacingSpaces(
		with fresh: ProvisionalProfile,
		uuid: () -> UUID
	) throws -> Self {
		var result = self

		// Archived tabs all belong to the old profiles.
		result.archive = []
		result.profiles.append(contentsOf: fresh.organization.profiles)
		result.spaces.append(contentsOf: fresh.organization.spaces)
		for space in spaces {
			result = try result.applying(.removeSpace(space.id), uuid: uuid)
		}
		return result
	}
}
