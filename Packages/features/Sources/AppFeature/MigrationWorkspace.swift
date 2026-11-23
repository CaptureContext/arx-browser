import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserHistoryClient
import BrowserSiteIconClient
import Foundation
import MigrationAssistant
import _ComposableArchitecture

/// Serves MigrationAssistant's reads and commits from the workspace this feature owns.
///
/// A commit prepares any new profile's native data first, writes imported history
/// to the history store, then publishes the organization and its ledger together
/// through the normal save path, and only answers once that exact state has been
/// saved. History merges by URL, so writing it again after a failed save adds nothing.
@Reducer
internal struct MigrationWorkspace {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.browserHistory)
	private var history

	@Dependency(\.migrationWorkspace)
	private var bridge

	@Dependency(\.browserSiteIcons)
	private var siteIcons

	@Dependency(\.uuid)
	private var uuid

	private enum Cancellation: Hashable {
		case requests
	}

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.main.ui.task) { _ in
			.run { [bridge] send in
				for await request in bridge.requests {
					await send(.migrationWorkspace(.request(request)))
				}
			}
			.cancellable(id: Cancellation.requests, cancelInFlight: true)
		}

		Pullback(\.migrationWorkspace.request) { state, request in
			switch request {
			case let .state(id):
				let current = MigrationDestinationState(
					organization: state.workspace,
					ledger: state.migrationLedger
				)
				return .run { [bridge] _ in await bridge.answer(id, state: current) }

			case let .commit(id, batch):
				return commit(batch, id: id, state: &state)
			}
		}

		Pullback(\.migrationWorkspace.approved) { state, value in
			let (id, previous, updated, ledger, portable, icons) = value
			guard
				state.workspace == previous,
				state.migrationCommit == nil,
				state.canCommitMigration
			else { return fail(id, String.localized(.appUI.management.workspaceChanged)) }

			var preferences = state.persistedPreferences
			if let portable {
				do {
					preferences = try preferences.applyingMigration(portable)
				} catch {
					return fail(id, error.localizedDescription)
				}
			}
			preferences.migrationLedger = ledger
			let createdSpace: Space.ID? = updated.spaces.ids.first { !previous.spaces.ids.contains($0) }
			state.publishAdditiveOrganization(updated)
			state.commit(organization: state.workspace, preferences: preferences)
			state.migrationCommit = id

			// Saves; shared keys already reach every reader. Imported tabs show the icons the
			// source showed until their pages load (DEV-897); publishing has configured their
			// profiles for the icon service by the time this runs.
			let seed: Effect<Action> = icons.isEmpty
			? .none
			: .run { [siteIcons] _ in await siteIcons.seed(icons) }
			let save: Effect<Action> = .merge(state.saveWorkspace(), seed)

			// Onboarding's hand-off lands in the space an import made.
			guard let createdSpace, state.onboarding != nil else { return save }

			return .merge(
				save,
				.send(.onboarding(.event(.importCreatedSpace(createdSpace))))
			)
		}

		Pullback(\.event.saveSucceeded) { state, value in
			let (organization, preferences) = value
			guard
				let id = state.migrationCommit,
				organization == state.workspace,
				preferences == state.persistedPreferences
			else { return .none }

			state.migrationCommit = nil
			return .run { [bridge] _ in await bridge.answerCommitted(id) }
		}

		Pullback(\.event.saveFailed) { state, message in
			guard let id = state.migrationCommit else { return .none }

			// The change stays in memory with its ledger and the app keeps retrying the
			// save, so running the plan again skips it rather than importing it twice.
			state.migrationCommit = nil
			return fail(id, message)
		}
	}

	private func commit(
		_ batch: MigrationBatch,
		id: UUID,
		state: inout State
	) -> Effect<Action> {
		guard state.canCommitMigration, state.migrationCommit == nil else {
			return fail(id, String.localized(.appUI.management.busy))
		}

		let previous = state.workspace
		var ledger = state.migrationLedger
		let updated: BrowserOrganization
		do {
			updated = try previous.applyingMigration(batch, ledger: &ledger, makeID: { uuid() })
		} catch {
			return fail(id, error.localizedDescription)
		}

		let existing = Set(previous.profiles.map(\.id))
		let created = updated.profiles.map(\.id).filter { !existing.contains($0) }
		let preferences = batch.preferences
		let entries = updated
			.migrationHistory(batch, ledger: ledger)
			.sorted { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }
		guard entries.isEmpty || history.isAvailable else {
			return fail(id, String.localized(.appUI.migration.historyUnavailable))
		}

		let epochs = state.history.epochs
		let icons = Self.importedIcons(batch, previous: previous, updated: updated, ledger: ledger)
		return .run { [engine, bridge, history, ledger] send in
			do {
				for profile in created { try await engine.prepareProfile(profile) }
			} catch {
				await bridge.fail(id, message: String.localized(.appUI.management.profilePreparationFailed))
				return
			}

			for (profileID, profileEntries) in entries {
				let outcome: BrowserHistoryClient.Outcome
				do {
					outcome = try await history.merge(profileID, profileEntries)
				} catch {
					await bridge.fail(id, message: String.localized(.appUI.migration.historyUnavailable))
					return
				}
				await send(.history(.received(outcome, epoch: epochs[profileID, default: 0])))
				guard outcome.failure == nil else {
					await bridge.fail(id, message: String.localized(.appUI.migration.historyUnavailable))
					return
				}
			}
			await send(.migrationWorkspace(.approved(id, previous, updated, ledger, preferences, icons: icons)))
		}
	}

	/// The source's icon for each tab the batch added, keyed as the sidebar asks for it: the
	/// tab's profile and the pages it shows (DEV-1294). An icon only goes to the profile its item landed
	/// in, so two source profiles' icons for one address never mix.
	private static func importedIcons(
		_ batch: MigrationBatch,
		previous: BrowserOrganization,
		updated: BrowserOrganization,
		ledger: MigrationLedger
	) -> [BrowserSiteIconKey: Data] {
		var icons: [BrowserSiteIconKey: Data] = [:]
		for item in batch.items {
			guard
				let url = item.url,
				let icon = item.icon,
				let profileID = updated.receivingProfile(for: item, destination: batch.destination, ledger: ledger)
			else { continue }

			icons[.init(profileID: profileID, pageURL: url)] = icon
		}
		guard !icons.isEmpty else { return [:] }

		let existing = Set(previous.tabs.ids)
		var keyed: [BrowserSiteIconKey: Data] = [:]
		for tab in updated.tabs where !existing.contains(tab.id) {
			// The row shows where the tab is, and a saved tab its saved page once closed
			// (DEV-1294). Each page keeps its own imported icon; one without borrows the other
			// page's only when both are on the same site.
			let keys = tab.siteIconURLs.map { BrowserSiteIconKey(profileID: tab.profileID, pageURL: $0) }
			for key in keys {
				let sameSite = keys.filter { $0 != key && $0.pageURL.host == key.pageURL.host }
				guard let icon = icons[key] ?? sameSite.lazy.compactMap({ icons[$0] }).first
				else { continue }

				keyed[key] = keyed[key] ?? icon
			}
		}
		return keyed
	}

	private func fail(
		_ id: UUID,
		_ message: String
	) -> Effect<Action> {
		.run { [bridge] _ in await bridge.fail(id, message: message) }
	}
}

@CasePathable
public enum MigrationWorkspaceAction: Sendable {
	case request(MigrationWorkspaceBridge.Request)

	/// `icons` are the source's icons for the tabs the commit adds (DEV-897), seeded once the
	/// new profiles are published, so the icon service accepts them.
	case approved(
		UUID,
		BrowserOrganization,
		BrowserOrganization,
		MigrationLedger,
		MigrationPortablePreferences?,
		icons: [BrowserSiteIconKey: Data] = [:]
	)
}

extension AppFeature.State {
	fileprivate var canCommitMigration: Bool {
		!checkingQuit && !shouldQuit && !hasPendingProfileTransfers && !profileRetirement.isBusy
	}
}
