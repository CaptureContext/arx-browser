import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

// Saved passwords (DEV-708). Chromium's password manager keeps them per
// profile; the engine fills and submits them itself. Accounts and usernames
// reach the store only to show the user; a password value never does, and
// agents only ever see an outcome.

/// The accounts listed for a pending password sign-in.
public struct PasswordSignInListing: Equatable, Sendable {
	public var tabID: BrowserCore.Tab.ID
	public var profileID: Profile.ID
	public var origin: String
	internal var document: String
	public var accounts: [BrowserSavedAccount]
	public var selectedAccountID: UInt32?

	/// The user's choice in the approval: let agents sign in here without asking.
	public var allowsWithoutAsking: Bool

	public init(
		tabID: BrowserCore.Tab.ID,
		profileID: Profile.ID,
		origin: String,
		document: String,
		accounts: [BrowserSavedAccount],
		selectedAccountID: UInt32?,
		allowsWithoutAsking: Bool
	) {
		self.tabID = tabID
		self.profileID = profileID
		self.origin = origin
		self.document = document
		self.accounts = accounts
		self.selectedAccountID = selectedAccountID
		self.allowsWithoutAsking = allowsWithoutAsking
	}
}

extension AppFeature.State {
	/// A permitted, loaded HTTP(S) tab of a granted profile at the exact origin and revision.
	internal func automationPasswordSignInValidation(
		_ request: AutomationPasswordSignInRequest,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		do {
			try request.validate()
		} catch {
			return .invalidRequest
		}
		guard client.allowsSignIn else { return .denied }
		guard
			let tab = workspace.tabs.first(where: { $0.id.rawValue == request.targetID }),
			AutomationAccess.permitsTab(tab.id, client: client, organization: workspace),
			workspace.profiles.ids.contains(tab.profileID)
		else { return .denied }

		guard let snapshot = snapshots[tab.id] else { return .notLoaded }

		// DEV-873: Arx unloaded its page to free memory; `load` brings it back.
		guard !snapshot.navigation.isUnloaded else { return .notLoaded }
		guard
			snapshot.nativeProfileID == tab.profileID,
			(snapshot.nativePageID ?? 0) > 0,
			(snapshot.documentRevision ?? 0) > 0,
			!snapshot.navigation.isLoading,
			snapshot.navigation.errorCode == nil
		else { return .notReady }

		let revision = AutomationInventoryBuilder
			.items(client: client, organization: workspace, snapshots: snapshots)
			.first(where: { $0.id == request.targetID })?.revision
		guard
			revision == request.expectedRevision,
			Self.signInOrigin(snapshot.navigation.url) == request.origin
		else { return .staleTarget }

		return nil
	}

	/// A tab whose current document holds a filled password that didn't sign in
	/// can't be captured, read or acted in: the page's own "show password" could
	/// reveal it. The tab's next document lifts it.
	internal func automationPasswordQuarantine(
		_ operation: AutomationOperation,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		for target in operation.pageTargets {
			let tabID = BrowserCore.Tab.ID(rawValue: target)
			guard let quarantined = automation.passwordQuarantine[tabID] else { continue }

			// An unknown document might still be the filled one.
			let current = snapshots[tabID]?.documentRevision ?? quarantined
			if current == quarantined { return .authenticationProtected }
		}
		return nil
	}
}

@Reducer
internal struct AutomationPasswords {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	private enum Cancellation: Hashable {
		case saveOffers
	}

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.automation.ui.observePasswordSaves) { _ in
			.run { [engine] send in
				for await offer in await engine.passwordSaveOffers() {
					await send(.automation(.event(.passwordSaveOffered(offer))))
				}
			}
			.cancellable(id: Cancellation.saveOffers, cancelInFlight: true)
		}

		Pullback(\.automation.event.passwordSaveOffered) { state, offer in
			let replaced = state.automation.passwordSave
			state.automation.passwordSave = offer
			guard let replaced, replaced.tabID != offer.tabID else { return .none }

			return .run { [engine] _ in
				_ = await engine.answerPasswordSave(replaced.tabID, replaced.token, .notNow)
			}
		}

		Pullback(\.automation.ui.answerPasswordSave) { state, answer in
			guard let offer = state.automation.passwordSave else { return .none }

			state.automation.passwordSave = nil
			return .run { [engine] _ in
				_ = await engine.answerPasswordSave(offer.tabID, offer.token, answer)
			}
		}

		Pullback(\.automation.ui.passwordAccount) { state, value in
			let (id, account) = value
			guard
				state.automation.pending[id]?.awaitingApproval == true,
				state.automation.passwordSignIns[id]?.accounts.contains(where: { $0.id == account }) == true
			else { return .none }

			state.automation.passwordSignIns[id]?.selectedAccountID = account
			return .none
		}

		Pullback(\.automation.ui.passwordAllowsWithoutAsking) { state, value in
			let (id, allows) = value
			guard state.automation.pending[id]?.awaitingApproval == true else { return .none }

			state.automation.passwordSignIns[id]?.allowsWithoutAsking = allows
			return .none
		}

		Pullback(\.automation.ui.removeAgentSignInSite) { state, site in
			guard state.automationPreferences.agentSignInSites.contains(site)
			else { return .none }

			state.automationPreferences.agentSignInSites.removeAll { $0 == site }
			return state.saveWorkspace()
		}

		Pullback(\.automation.event.passwordAccountsListed) { state, value in
			let (id, result) = value
			return BrowserAutomation().passwordAccountsListed(id, result: result, state: &state)
		}

		Pullback(\.automation.event.passwordSignInFinished) { state, value in
			let (id, tabID, result) = value
			return BrowserAutomation().passwordSignInFinished(id, tabID: tabID, result: result, state: &state)
		}
	}
}

extension BrowserAutomation {
	/// Lists the tab's saved accounts first; a later pass, after the user's
	/// approval or with the site's standing permission, signs in.
	internal func passwordSignIn(
		requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[requestID],
			case let .passwordSignIn(request) = pending.request.operation
		else { return finish(requestID, result: .failure(.staleTarget), state: &state) }

		if let listing = state.automation.passwordSignIns[requestID] {
			guard pending.approved else { return .none }
			return attemptPasswordSignIn(requestID, request: request, listing: listing, state: &state)
		}

		let tabID = BrowserCore.Tab.ID(rawValue: request.targetID)
		return .run { [engine] send in
			let result: Result<BrowserSavedAccounts, BrowserPasswordFailure>
			do throws(BrowserPasswordFailure) {
				guard await engine.passwordsAreAvailable() else { throw .unavailable }
				result = .success(try await engine.savedAccounts(tabID))
			} catch {
				result = .failure(error)
			}
			await send(.automation(.event(.passwordAccountsListed(requestID, result))))
		}
		.cancellable(id: requestID)
	}

	internal func passwordAccountsListed(
		_ requestID: UUID,
		result: Result<BrowserSavedAccounts, BrowserPasswordFailure>,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[requestID],
			case let .passwordSignIn(request) = pending.request.operation,
			state.automation.passwordSignIns[requestID] == nil
		else { return .none }

		let listed: BrowserSavedAccounts
		switch result {
		case let .success(value): listed = value
		case let .failure(failure): return finishPasswordSignIn(requestID, request: request, failure: failure, state: &state)
		}
		let tabID = BrowserCore.Tab.ID(rawValue: request.targetID)
		guard
			listed.origin == request.origin,
			let tab = state.workspace.tabs[id: tabID]
		else { return finish(requestID, result: .failure(.staleTarget), state: &state) }
		guard !listed.accounts.isEmpty
		else { return finishPasswordSignIn(requestID, request: request, outcome: .failed, reason: .noSavedPassword, state: &state) }

		let allowed = state.automationPreferences.allowsAgentSignIn(
			profileID: tab.profileID,
			origin: request.origin
		)
		let preferred = listed.accounts.first(where: \.hasForm) ?? listed.accounts[0]
		state.automation.passwordSignIns[requestID] = .init(
			tabID: tabID,
			profileID: tab.profileID,
			origin: request.origin,
			document: listed.document,
			accounts: listed.accounts,
			selectedAccountID: preferred.id,
			allowsWithoutAsking: allowed
		)

		// One account on a site the user allowed: no question to ask.
		if allowed, listed.accounts.count == 1 {
			state.automation.pending[requestID]?.approved = true
			return attemptPasswordSignIn(
				requestID,
				request: request,
				listing: state.automation.passwordSignIns[requestID]!,
				state: &state
			)
		}
		if state.automation.isUnattended {
			let reason: AutomationPasswordSignInResult.Reason = allowed ? .chooseAccount : .approval
			return finishPasswordSignIn(requestID, request: request, outcome: .needsUser, reason: reason, state: &state)
		}
		state.automation.pending[requestID]?.awaitingApproval = true

		// Held back by launch onboarding, the approval shows once the window opens (DEV-838).
		if state.openMainWindow() { state.focusedWindowID = state.main.id }
		return waitForUser(requestID, kind: .approval, state: state)
	}

	/// The final authorization runs immediately before the engine fills.
	private func attemptPasswordSignIn(
		_ requestID: UUID,
		request: AutomationPasswordSignInRequest,
		listing: PasswordSignInListing,
		state: inout State
	) -> Effect<Action> {
		guard let account = listing.selectedAccountID
		else { return finishPasswordSignIn(requestID, request: request, outcome: .needsUser, reason: .chooseAccount, state: &state) }

		var effects: [Effect<Action>] = []
		let site = AgentSignInSite(profileID: listing.profileID, origin: listing.origin)
		if listing.allowsWithoutAsking, !state.automationPreferences.agentSignInSites.contains(site) {
			state.automationPreferences.agentSignInSites.append(site)
			effects.append(state.saveWorkspace())
		}

		state.automation.pending[requestID]?.executing = true
		state.automation.pending[requestID]?.awaitingApproval = false

		// Filling and submitting a saved password changes the page: show the agent's indicator (DEV-899).
		state.beginAgentPresence(requestID, now: now)
		let tabID = listing.tabID

		// The form about to be sent carries the password under a name redaction may not know, so
		// request details stop and drop what they kept before filling (DEV-924).
		_ = MainActor.assumeIsolated { engine.setNetworkCapture(tabID, false) }
		let document = listing.document
		effects.append(
			.run { [engine, control] send in
				let result: Result<BrowserPasswordSignInResult, BrowserPasswordFailure>
				do throws(BrowserPasswordFailure) {
					result = .success(try await engine.signInWithPassword(
						tabID,
						document,
						request.frameID,
						account
					) { control.authorize(requestID) })
				} catch {
					result = .failure(error)
				}
				await send(.automation(.event(.passwordSignInFinished(requestID, tabID, result))))
			}
			.cancellable(id: requestID)
		)
		return .merge(effects)
	}

	internal func passwordSignInFinished(
		_ requestID: UUID,
		tabID: BrowserCore.Tab.ID,
		result: Result<BrowserPasswordSignInResult, BrowserPasswordFailure>,
		state: inout State
	) -> Effect<Action> {
		let filled: Bool
		let passwordVisible: Bool
		let signedIn: Bool
		switch result {
		case let .success(value):
			filled = value.filled
			passwordVisible = value.passwordVisible
			signedIn = value.outcome == .signedIn
		case let .failure(.stale(value)), let .failure(.timedOut(value)):
			filled = value
			passwordVisible = true
			signedIn = false
		case .failure:
			filled = false
			passwordVisible = false
			signedIn = false
		}

		// Recorded whether or not the request is still pending: the value is in the page.
		if filled, passwordVisible || !signedIn {
			let revision = MainActor.assumeIsolated { engine.snapshot(tabID)?.documentRevision }
			if let revision { state.automation.passwordQuarantine[tabID] = revision }

			// Request details kept so far may hold the password the page just sent (DEV-924).
			_ = MainActor.assumeIsolated { engine.setNetworkCapture(tabID, false) }
		}

		guard
			let pending = state.automation.pending[requestID],
			case let .passwordSignIn(request) = pending.request.operation
		else { return .none }

		switch result {
		case let .success(value):
			return finishPasswordSignIn(
				requestID,
				request: request,
				outcome: value.outcome,
				reason: value.reason,
				state: &state
			)
		case let .failure(failure):
			return finishPasswordSignIn(requestID, request: request, failure: failure, state: &state)
		}
	}

	private func finishPasswordSignIn(
		_ requestID: UUID,
		request: AutomationPasswordSignInRequest,
		outcome: AutomationPasswordSignInResult.Outcome,
		reason: AutomationPasswordSignInResult.Reason,
		state: inout State
	) -> Effect<Action> {
		finish(
			requestID,
			result: .passwordSignIn(.init(operationID: request.operationID, outcome: outcome, reason: reason)),
			state: &state
		)
	}

	private func finishPasswordSignIn(
		_ requestID: UUID,
		request: AutomationPasswordSignInRequest,
		failure: BrowserPasswordFailure,
		state: inout State
	) -> Effect<Action> {
		switch failure {
		case .stale:
			finishPasswordSignIn(requestID, request: request, outcome: .failed, reason: .navigation, state: &state)
		case .timedOut:
			finishPasswordSignIn(requestID, request: request, outcome: .failed, reason: .timedOut, state: &state)
		case .unavailable:
			finish(requestID, result: .failure(.unsupported), state: &state)
		case .busy:
			finish(requestID, result: .failure(.busy), state: &state)
		case .invalid:
			finish(requestID, result: .failure(.invalidRequest), state: &state)
		case .denied:
			finish(requestID, result: .failure(.denied), state: &state)
		}
	}
}
