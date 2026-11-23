import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import SettingsFeature
import _ComposableArchitecture

public struct ProfileRetirementState: Equatable, Sendable {
	public var intents: [ProfileRetirementIntent]
	public var snapshot: ProfileRetirementSnapshot?
	public var isBusy: Bool
	public var operationID: UUID?
	public var profileID: Profile.ID?
	public var original: BrowserOrganization?
	public var error: String?

	public init(intents: [ProfileRetirementIntent] = []) {
		self.intents = intents
		self.snapshot = nil
		self.isBusy = false
		self.operationID = nil
		self.profileID = nil
		self.original = nil
		self.error = nil
	}
}

@CasePathable
public enum ProfileRetirementAction: Sendable {
	case refresh
	case begin(Profile.ID)
	case prepared(UUID, ProfileRetirementIntent)
	case finished(UUID, ProfileRetirementSnapshot)
	case failed(UUID, String)
	case refreshed(ProfileRetirementSnapshot)
	case refreshFailed(String)

	/// A `begin` for this profile came to an end: retired (acknowledged by the engine), or
	/// refused or failed with the workspace as it was. Clearing Arx before a migration
	/// (DEV-833) retires one profile after another on it.
	case ended(Profile.ID, retired: Bool)
}

@Reducer
internal struct ProfileRetirement {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.profileRetirementPersistence)
	private var persistence

	@Dependency(\.uuid)
	private var uuid

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.settings.delegate.retireProfile) { _, id in .send(.profileRetirement(.begin(id))) }
		Pullback(\.settings.ui.retryProfileRetirement) { state, id in
			guard state.profileRetirement.intents.contains(where: { $0.profileID == id })
			else { return .none }
			return .send(.profileRetirement(.begin(id)))
		}

		Pullback(\.profileRetirement.begin) { state, id in
			guard
				!state.profileRetirement.isBusy,
				!state.checkingQuit,
				!state.shouldQuit,
				!state.hasPendingProfileTransfers,
				let profile = state.workspace.profiles[id: id],
				!state.workspace.spaces.contains(where: { $0.profileID == id }),
				!state.littleWindows.contains(where: { $0.tab.profileID == id }),
				!state.peeks.contains(where: { $0.tab.profileID == id }),
				// A private window it opened runs in its private context (DEV-889).
				!state.privateProfileOpeners.values.contains(id)
			else {
				return .merge(
					failure(String.localized(.appUI.management.profileInUse)),
					.send(.profileRetirement(.ended(id, retired: false)))
				)
			}
			let prior = state.profileRetirement.intents.first { $0.profileID == id }
			guard prior?.acknowledged != true else {
				return .concatenate(
					.send(.profileRetirement(.refresh)),
					.send(.profileRetirement(.ended(id, retired: true)))
				)
			}
			let operation = uuid()
			let request = prior?.requestID ?? uuid()
			state.profileRetirement.isBusy = true
			state.profileRetirement.operationID = operation
			state.profileRetirement.profileID = id
			state.profileRetirement.original = state.workspace
			state.profileRetirement.error = nil
			state.settings.isManagingOrganization = true
			return .run { [engine, persistence] send in
				do {
					guard await engine.retirementIsAvailable()
					else { throw ProfileRetirementFailure.unavailable }
					if prior == nil { try await engine.prepareProfile(id) }
					let snapshot = try await engine.profileRetirementSnapshot()
					if let prior, snapshot.acknowledges(prior.originalRequest) {
						try await persistence.acknowledge(prior.requestID)
						await send(.profileRetirement(.finished(operation, snapshot)))
						return
					}
					guard
						snapshot.isDurable,
						snapshot.revision > 0,
						snapshot.records.contains(where: { $0.profileID == id && $0.state == .active })
					else { throw ProfileRetirementFailure.stale }
					var intent =
						prior
						?? .init(
							profileID: id,
							profileName: profile.name,
							requestID: request,
							expectedRevision: snapshot.revision
						)
					intent.attemptRevision = snapshot.revision
					await send(.profileRetirement(.prepared(operation, intent)))
				} catch {
					await send(.profileRetirement(.failed(operation, String.localized(.appUI.retirement.failed))))
				}
			}
		}

		Pullback(\.profileRetirement.prepared) { state, value in
			let (operation, intent) = value
			guard state.profileRetirement.operationID == operation else { return .none }
			guard state.authorizesRetirement(operation) else {
				return .send(
					.profileRetirement(.failed(operation, String.localized(.appUI.management.workspaceChanged)))
				)
			}
			if let index = state.profileRetirement.intents.firstIndex(where: { $0.profileID == intent.profileID }) {
				state.profileRetirement.intents[index] = intent
			} else {
				state.profileRetirement.intents.append(intent)
			}
			state.updateRetirementRows()
			let tabs = state.workspace.tabs.filter { $0.profileID == intent.profileID }.map(\.id)
			return .run { [engine, persistence] send in
				do {
					await engine.blockProfileRetirement(intent.profileID)
					guard await persistence.authorize(operation)
					else { throw ProfileRetirementFailure.stale }
					try await persistence.record(intent)
					guard let close = engine.closeAuthorized
					else { throw ProfileRetirementFailure.unavailable }
					for tab in tabs {
						let revision = await engine.snapshot(tab)?.revision
						let closed = try await close(tab, revision, { persistence.authorize(operation) }, {})
						guard closed else { throw ProfileRetirementFailure.busy }
					}
					let snapshot = try await engine.retireProfile(
						intent.attemptRequest,
						{ persistence.authorize(operation) }
					)
					guard snapshot.acknowledges(intent.originalRequest)
					else { throw ProfileRetirementFailure.io }
					try await persistence.acknowledge(intent.requestID)
					await send(.profileRetirement(.finished(operation, snapshot)))
				} catch {
					await send(.profileRetirement(.failed(operation, String.localized(.appUI.retirement.failed))))
				}
			}
		}

		Pullback(\.profileRetirement.finished) { state, value in
			let (operation, snapshot) = value
			guard state.profileRetirement.operationID == operation else { return .none }
			state.profileRetirement.isBusy = false
			state.profileRetirement.operationID = nil
			state.profileRetirement.original = nil
			let ended: Effect<Action> = state.profileRetirement.profileID.map { id in
				.send(.profileRetirement(.ended(id, retired: true)))
			} ?? .none
			return .concatenate(publish(snapshot, state: &state), ended)
		}

		Pullback(\.profileRetirement.failed) { state, value in
			let (operation, message) = value
			guard state.profileRetirement.operationID == operation else { return .none }
			state.profileRetirement.isBusy = false
			state.profileRetirement.operationID = nil
			state.profileRetirement.original = nil
			state.profileRetirement.error = message
			state.updateRetirementRows()
			let ended: Effect<Action> = state.profileRetirement.profileID.map { id in
				.send(.profileRetirement(.ended(id, retired: false)))
			} ?? .none
			return .merge(failure(message), ended)
		}

		Pullback(\.profileRetirement.refresh) { state in
			guard !state.profileRetirement.isBusy else { return .none }
			let intents = state.profileRetirement.intents
			return .run { [engine, persistence] send in
				do {
					let snapshot = try await engine.profileRetirementSnapshot()
					for intent in intents where snapshot.acknowledges(intent.originalRequest) {
						try await persistence.acknowledge(intent.requestID)
					}
					await send(.profileRetirement(.refreshed(snapshot)))
				} catch {
					await send(.profileRetirement(.refreshFailed(String.localized(.appUI.retirement.unavailable))))
				}
			}
		}

		Pullback(\.profileRetirement.refreshed) { state, snapshot in
			guard !state.profileRetirement.isBusy else { return .none }
			return publish(snapshot, state: &state)
		}
		Pullback(\.profileRetirement.refreshFailed) { state, message in
			guard !state.profileRetirement.isBusy else { return .none }
			state.settings.retirementAvailable = false
			state.profileRetirement.error = message
			state.updateRetirementRows()
			return .none
		}
	}

	private func failure(_ message: String) -> Effect<Action> {
		.send(.settings(.event(.organizationChangeFailed(message))))
	}

	private func publish(
		_ snapshot: ProfileRetirementSnapshot,
		state: inout State
	) -> Effect<Action> {
		state.profileRetirement.snapshot = snapshot
		state.profileRetirement.error = nil
		state.settings.retirementAvailable = snapshot.isDurable
		for index in state.profileRetirement.intents.indices {
			if snapshot.acknowledges(state.profileRetirement.intents[index].originalRequest) {
				state.profileRetirement.intents[index].acknowledged = true
			}
		}
		state.updateRetirementRows()
		let retired = Set(state.profileRetirement.intents.filter(\.acknowledged).map(\.profileID))
		do {
			let organization = try state.workspace.excludingRetiredProfiles(retired)
			guard organization != state.workspace
			else { return .send(.settings(.event(.organizationChanged))) }
			state.workspace = organization
			state.unsavedOrganization = organization
			state.settings.selectedProfileID = organization.profiles.first?.id
			var effects: [Effect<Action>] = [.send(.main(.reconcile(organization)))]
			for id in state.windows.filter({ !$0.isPrivate }).map(\.id) {
				effects.append(.send(.windows(.element(id: id, action: .reconcile(organization)))))
			}
			effects.append(.send(.settings(.event(.organizationChanged))))
			effects.append(.send(.delegate(.save(organization))))
			return .concatenate(effects)
		} catch {
			state.profileRetirement.error = String.localized(.appUI.retirement.blocked)
			return failure(String.localized(.appUI.retirement.blocked))
		}
	}
}

extension AppFeature.Action {
	internal var permittedDuringRetirement: Bool {
		switch self {
		case .ui(.windowBecameKey), .ui(.focusWindow), .ui(.closeWindow), .ui(.closeAdditionalWindow),
			.ui(.closeSettings), .ui(.closeOnboarding), .ui(.closeCapture), .ui(.exitPageFullScreen),
			.ui(.closePagePictureInPicture):
			true

		case .ui, .settings(.ui), .settings(.delegate(.changeOrganization)),
			.settings(.delegate(.retireProfile)), .settings(.delegate(.openAutomation)), .automation(.ui),
			.archiveInactiveTabs:
			false

		// The link menus' and Share's internal actions, blocked as the clicks behind them are.
		case .sharePage, .openInNewWindow, .openInMainWindow, .openInPrivateWindow, .downloadURL, .downloadLink:
			false

		case let .main(action): action.permittedDuringRetirement

		case let .windows(.element(_, action)): action.permittedDuringRetirement

		case .littleWindows(.element(_, .ui(.close))), .littleWindows(.element(_, .ui(.lostFocus))): true

		case .littleWindows(.element(_, .ui)), .littleWindows(.element(_, .changeProfile)),
			.littleWindows(.element(_, .dispatchCommand)), .littleWindows(.element(_, .navigateFromCommandBar)),
			.littleWindows(.element(_, .commandBar(.ui))):
			false

		// The profile picker may still close, and choose again once the profile is gone.
		case .profilePicker(.ui(.confirm)): false

		case .peeks(.element(_, .ui(.close))): true

		case .peeks(.element(_, .ui)): false

		default: true
		}
	}
}

extension MainFeature.Action {
	fileprivate var permittedDuringRetirement: Bool {
		switch self {
		case .ui, .sidebar(.ui), .commandBar(.ui), .archive(.ui), .dispatchCommand,
			.present, .openFolderTabs, .transferTabs, .performTabMove, .archiveInactiveTabs:
			false
		default: true
		}
	}
}

extension ProfileRetirementIntent {
	internal var originalRequest: ProfileRetirementRequest {
		.init(profileID: profileID, requestID: requestID, expectedRevision: expectedRevision)
	}

	internal var attemptRequest: ProfileRetirementRequest {
		.init(profileID: profileID, requestID: requestID, expectedRevision: attemptRevision)
	}
}

extension AppFeature.State {
	internal func authorizesRetirement(_ operation: UUID) -> Bool {
		guard let profileID = profileRetirement.profileID else { return false }
		return profileRetirement.isBusy && profileRetirement.operationID == operation
			&& profileRetirement.original?.legacyProfileID == workspace.legacyProfileID
			&& workspace.profiles.count > 1 && workspace.profiles.ids.contains(profileID)
			&& !workspace.spaces.contains { $0.profileID == profileID }
			&& !checkingQuit && !shouldQuit && !hasPendingProfileTransfers
			&& !littleWindows.contains { $0.tab.profileID == profileID }
			&& !peeks.contains { $0.tab.profileID == profileID }
	}

	internal mutating func updateRetirementRows() {
		settings.profileRetirements = profileRetirement.intents.map { intent in
			let receipt = profileRetirement.snapshot
			let progress = receipt?.acknowledges(intent.originalRequest) == true
			? receipt?.records.first { $0.profileID == intent.profileID && $0.requestID == intent.requestID }?.state
			: nil
			let message: String =
				switch progress {
				case .awaitingStartup: String.localized(.appUI.retirement.awaitingStartup)
				case .quarantinePending: String.localized(.appUI.retirement.quarantinePending)
				case .restartRequired: String.localized(.appUI.retirement.restartRequired)
				case .verificationPending: String.localized(.appUI.retirement.verificationPending)
				case .erased: String.localized(.appUI.retirement.erased)
				case .blocked: String.localized(.appUI.retirement.blocked)
				case .active, nil: String.localized(.appUI.retirement.uncertain)
				}
			return .init(
				id: intent.profileID,
				name: intent.profileName,
				message: message,
				canRetry: !intent.acknowledged
			)
		}
	}
}
