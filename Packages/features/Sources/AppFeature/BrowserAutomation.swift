import BrowserAutomationClient
import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import BrowserExtensionsClient
import BrowserPageInspectionClient
import BrowserPageInteractionClient
import BrowserPageWaitClient
import Foundation
import _ComposableArchitecture

@Reducer
internal struct BrowserAutomation {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.automationControl)
	internal var control

	@Dependency(\.browserDownloads)
	internal var downloads

	@Dependency(\.browserEngine)
	internal var engine

	@Dependency(\.browserExtensions)
	internal var extensions

	@Dependency(\.browserPageInspection)
	internal var pageInspection

	@Dependency(\.browserPageInteraction)
	internal var pageInteraction

	@Dependency(\.browserPageWait)
	internal var pageWait

	@Dependency(\.continuousClock)
	internal var clock

	@Dependency(\.date.now)
	internal var now

	@Dependency(\.linkSharing)
	private var sharing

	@Dependency(\.uuid)
	internal var uuid

	private enum Cancellation: Hashable {
		/// Every server transition, cancelled before a newer one starts.
		case server

		/// One server transition, so a stale one can be stopped without touching a newer one.
		case serverGeneration(UUID)
	}

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.closeSettings) { state in
			state.automation.configuration = nil
			state.automation.isPresented = false
			return .none
		}

		Pullback(\.automation.ui.present) { state, presented in
			state.automation.isPresented = presented
			if !presented { state.automation.configuration = nil }
			return .none
		}

		// Settings' search found Local assistants (MCP).
		Pullback(\.settings.delegate.openAutomation) { _ in
			.send(.automation(.ui(.present(true))))
		}

		Pullback(\.automation.ui.enabled) { state, enabled in
			state.automationPreferences.isEnabled = enabled
			state.automation.generation = uuid()
			state.automation.error = nil
			let generation = state.automation.generation
			let cancelled = state.automation.pending.keys.map { Effect<Action>.cancel(id: $0) }
			for id in Array(state.automation.pending.keys) { state.discardAutomationRequest(id) }
			state.automation.hostHandles.removeAll()
			state.automation.hostReceipts.removeAll()
			state.automation.closeReceipts.removeAll()
			state.automation.batchApprovals.removeAll()
			let scopes = state.automation.inspectionScopes.values.map(\.id)
			state.automation.inspectionScopes.removeAll()
			state.automation.releasedInspections.removeAll()
			state.automation.clickReceipts.removeAll()
			state.automation.scrollReceipts.removeAll()
			state.automation.formReceipts.removeAll()
			state.automation.sessions.removeAll()
			state.automation.socketPath = nil
			return .merge(cancelled + [
				revokeInspectionScopes(scopes),
				state.saveWorkspace(),
				// `cancelInFlight` cancels when the effect's task registers, which happens off the
				// main actor, so an older toggle could cancel this one and leave the server in its
				// state. Cancel synchronously in reducer order; one that registers later is stopped
				// when it reports in.
				.concatenate(
					.cancel(id: Cancellation.server),
					server(enabled: enabled, generation: generation)
				),
			])
		}

		Pullback(\.automation.event.serverRequested) { state, generation in
			guard generation == state.automation.generation
			else { return .cancel(id: Cancellation.serverGeneration(generation)) }

			return .none
		}

		Pullback(\.automation.event.started) { state, value in
			let (generation, result) = value
			guard generation == state.automation.generation else { return .none }

			switch result {
			case let .success(path):
				state.automation.socketPath = path
				guard let request = state.automation.approvedAgentSetup else { return .none }
				state.automation.approvedAgentSetup = nil
				return createAgentClient(for: request)

			case let .failure(error):
				state.automation.error = error
				return .none
			}
		}

		Pullback(\.automation.event.agentSetupRequested) { state, request in
			guard !state.automation.isUnattended else { return .none }
			state.automation.pendingAgentSetup = request
			state.automation.isPresented = true
			return .send(.ui(.openSettings))
		}

		Pullback(\.automation.ui.declineAgentSetup) { state in
			guard let request = state.automation.pendingAgentSetup else { return .none }
			state.automation.pendingAgentSetup = nil
			return .run { [control] _ in
				withErrorReporting {
					try control.replyToAgentSetup(.init(requestID: request.id, credential: nil), request.agent)
				}
			}
		}

		Pullback(\.automation.ui.approveAgentSetup) { state in
			guard let request = state.automation.pendingAgentSetup else { return .none }
			state.automation.pendingAgentSetup = nil
			guard state.automation.socketPath != nil else {
				state.automation.approvedAgentSetup = request
				return .send(.automation(.ui(.enabled(true))))
			}
			return createAgentClient(for: request)
		}

		Pullback(\.automation.ui.connectAgent) { state, agent in
			guard !state.automation.isUnattended
			else { return .none }

			let request: AgentSetup.Request = .init(id: uuid(), agent: agent)
			guard state.automation.socketPath != nil else {
				state.automation.approvedAgentSetup = request
				return .send(.automation(.ui(.enabled(true))))
			}

			return createAgentClient(for: request)
		}

		Pullback(\.automation.event.agentSetupClientCreated) { state, value in
			let (client, token, request) = value
			guard
				let socket = state.automation.socketPath,
				state.automationPreferences.clients.count < 32
			else { return .none }

			// Setting an agent up again replaces its client, as its old credential file is gone.
			let replaced = state.automationPreferences.clients
				.filter { $0.name == client.name }
				.map(\.id)
			state.automationPreferences.clients.removeAll { replaced.contains($0.id) }
			state.automationPreferences.clients.append(client)
			let credential = AgentSetup.Credential(socket: socket, clientID: client.id, token: token)
			let invalidated = replaced.map { invalidate($0, state: &state) }
			return .merge(invalidated + [
				state.saveWorkspace(),
				.run { [control] _ in
					withErrorReporting {
						try control.replyToAgentSetup(
							.init(requestID: request.id, credential: credential),
							request.agent
						)
					}
				},
			])
		}

		Pullback(\.automation.ui.clientName) { state, name in
			state.automation.newClientName = String(name.prefix(80))
			return .none
		}

		Pullback(\.automation.ui.newClient) { state in
			state.automation.newClientName = ""
			state.automation.isAddingClient = true
			return .none
		}

		Pullback(\.automation.ui.cancelNewClient) { state in
			state.automation.newClientName = ""
			state.automation.isAddingClient = false
			return .none
		}

		Pullback(\.automation.ui.addClient) { state in
			let name = state.automation.newClientName.trimmingCharacters(in: .whitespacesAndNewlines)
			guard
				!name.isEmpty,
				state.automationPreferences.clients.count < 32
			else { return .none }

			let id = uuid()
			let revision = uuid()
			return .run { [control] send in
				do {
					let credential = try control.credential()
					let client = AutomationClient(
						id: id,
						name: name,
						credentialDigest: credential.digest,
						grantRevision: revision
					)
					await send(.automation(.event(.clientCreated(client, credential.token))))
				} catch {
					await send(.automation(.event(.finished(id, .failure(.appUnavailable)))))
				}
			}
		}

		Pullback(\.automation.event.clientCreated) { state, value in
			let (client, token) = value
			guard state.automationPreferences.clients.count < 32 else { return .none }
			state.automationPreferences.clients.append(client)
			state.automation.newClientName = ""
			state.automation.isAddingClient = false
			state.automation.configuration = AutomationConfiguration.make(
				clientID: client.id,
				token: token,
				socket: state.automation.socketPath ?? "",
				helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ArxMCP").path
			)
			return state.saveWorkspace()
		}

		Pullback(\.automation.ui.copyConfiguration) { state in
			guard let configuration = state.automation.configuration else { return .none }
			return .run { [sharing] _ in _ = await sharing.copy(configuration) }
		}

		Pullback(\.automation.ui.dismissConfiguration) { state in
			state.automation.configuration = nil
			return .none
		}

		Pullback(\.automation.ui.updateClient) { state, updated in
			let clients = state.automationPreferences.clients
			guard let index = clients.firstIndex(where: { $0.id == updated.id })
			else { return .none }

			var client = updated
			client.credentialDigest = state.automationPreferences.clients[index].credentialDigest
			client.grantRevision = uuid()
			client.mutationGrantUntil = state.automation.mutationGrantExpiry(
				for: updated,
				requested: updated.mutationGrantUntil,
				now: now
			)
			var preferences = state.automationPreferences
			preferences.clients[index] = client
			guard (try? preferences.validate()) != nil else { return .none }
			state.automationPreferences = preferences

			// The new grant revision fails every in-flight request and released reference
			// at its next check. Connected sessions stay, and their helpers see the new
			// grant on their next poll and send tools/list_changed.
			return regrant(client.id, state: &state)
		}

		Pullback(\.automation.ui.stopClient) { state, id in
			guard let index = state.automationPreferences.clients.firstIndex(where: { $0.id == id })
			else { return .none }

			state.automationPreferences.clients[index].isPaused = true

			// Stop takes back a temporary "don't ask" grant too, so resuming asks again.
			state.automationPreferences.clients[index].mutationGrantUntil = nil
			state.automationPreferences.clients[index].grantRevision = uuid()

			// A script's timers and promises outlive its request, even across same-document navigation;
			// reloading the tab is the only way to end them, so Stop does.
			// Kept until the tab closes: a page's "leave this page?" dialog can cancel the reload, and
			// Stop again then reloads again.
			let scripts = state.automation.scriptDocuments.filter { $0.clientID == id }
			let stopped = regrant(id, failure: .paused, state: &state)
			state.stopAgentPresence(of: id, now: now)
			guard !scripts.isEmpty else { return stopped }
			return .merge(stopped, .run { [engine] _ in
				for tab in Set(scripts.map(\.tabID)) {
					try? await engine.command(tab, .reload)
				}
			})
		}

		Pullback(\.automation.ui.resumeClient) { state, id in
			guard
				let index = state.automationPreferences.clients.firstIndex(where: { $0.id == id }),
				state.automationPreferences.clients[index].isPaused
			else { return .none }

			state.automationPreferences.clients[index].isPaused = false
			state.automationPreferences.clients[index].grantRevision = uuid()
			state.automation.presence = state.automation.presence.filter { _, presence in
				presence.clientID != id || !presence.isStopped
			}
			return state.saveWorkspace()
		}

		Pullback(\.automation.ui.revokeClient) { state, id in
			state.automationPreferences.clients.removeAll { $0.id == id }
			state.automation.configuration = nil
			if state.automation.unattendedClientID == id {
				state.automation.unattendedClientID = nil
			}
			return invalidate(id, state: &state)
		}

		Pullback(\.automation.event.host) { state, event in
			return host(event, state: &state)
		}

		Pullback(\.automation.event.inspected) { state, value in
			let (id, snapshots) = value
			guard var pending = state.automation.pending[id] else { return .none }
			if let failure = state.automationValidation(pending, snapshots: snapshots, now: now) {
				return finish(id, result: .failure(failure), state: &state)
			}
			if case let .command(command) = pending.request.operation, command.route {
				do throws(AutomationFailure) {
					let routed = try state.automationRoute(
						command,
						clientID: pending.request.clientID,
						snapshots: snapshots
					)
					pending.request.operation = .command(routed.command)
					pending.route = routed.route
				} catch {
					return finish(id, result: .failure(error), state: &state)
				}
				if let failure = state.automationValidation(pending, snapshots: snapshots, now: now) {
					return finish(id, result: .failure(failure), state: &state)
				}
			}
			if case let .command(command) = pending.request.operation, command.action.isHostOperation {
				let captured = state.automationHostContext(for: pending, snapshots: snapshots, now: now)
				guard let captured, pending.hostContext == nil || pending.hostContext == captured
				else { return finish(id, result: .failure(.staleTarget), state: &state) }

				pending.hostContext = captured
			}
			pending.snapshots = snapshots
			state.automation.pending[id] = pending
			let clients = state.automationPreferences.clients
			guard let client = clients.first(where: { $0.id == pending.request.clientID })
			else { return .none }

			switch pending.request.operation {
			case .signIn:
				return signIn(requestID: id, state: &state)

			case .passwordSignIn:
				return passwordSignIn(requestID: id, state: &state)

			case .wait:
				return waitForPage(requestID: id, state: &state)

			case .inspect:
				return inspectPage(requestID: id, state: &state)

			case .load:
				return loadPage(requestID: id, state: &state)

			case .pdf:
				return pdf(requestID: id, state: &state)

			case let .dialog(request) where request.action == .read:
				return pageDialog(requestID: id, state: &state)

			case let .media(request) where !request.isControl:
				return readMedia(requestID: id, client: client, state: &state)

			case .data, .link:
				return readData(id, client: client, state: &state)

			case let .settings(request) where request.change == nil:
				return readSettings(id, client: client, state: &state)

			case .logs:
				return developerLogs(requestID: id, state: &state)

			case .capture:
				return capture(requestID: id, state: &state)

			case let .inventory(cursor, limit):
				do {
					// Each open tab's window joins the items before paging, so a cursor goes stale
					// when a tab changes window (DEV-1157).
					let items = state.automationTabWindows(AutomationInventoryBuilder.items(
						client: client,
						organization: state.workspace,
						snapshots: snapshots
					))
					var inventory = try AutomationInventoryBuilder.page(items, cursor: cursor, limit: limit)
					inventory.presentations = state.automationPresentations(
						for: pending.request,
						snapshots: snapshots,
						now: now
					)
					inventory.profiles = AutomationInventoryBuilder.profiles(
						client: client,
						organization: state.workspace,
						items: items
					)
					inventory.windows = state.automationWindows(for: client)

					// Profiles and spaces resolve their appearance over the user's app-wide one.
					inventory.chromeAppearance = state.settings.chromeAppearance
					return finish(id, result: .inventory(inventory), state: &state)
				} catch {
					let failure = error as? AutomationFailure ?? .invalidRequest
					return finish(id, result: .failure(failure), state: &state)
				}

			case .settings where pending.request.operation.asksInExtensionReview:
				// An extension install asks in the Extensions sheet's review, every time, whatever the
				// approval policy or a temporary grant (DEV-951). Arx's own prompt would only come first.
				if state.automation.isUnattended {
					return finish(id, result: .failure(.userActionRequired), state: &state)
				}
				return .merge(
					changeSettings(id, client: client, state: &state),
					waitForUser(id, kind: .extensionReview, state: state)
				)

			case .command, .click, .form, .scroll, .batch, .findInPage, .dialog, .media, .settings, .script:
				// A press that pays, sends, posts or deletes asks every time, whatever the standing or
				// temporary approval, and so does a batch with one (DEV-1008).
				let operation = pending.request.operation
				var consequence = state.automationConsequence(
					of: operation,
					request: pending.request,
					snapshots: snapshots,
					now: now
				)
				if case let .batch(plan) = operation {
					let steps = state.automationStepConsequences(
						of: plan,
						request: pending.request,
						snapshots: snapshots,
						now: now
					)
					state.automation.pending[id]?.stepConsequences = steps
					consequence = steps.sorted { $0.key < $1.key }.first?.value
				}
				state.automation.pending[id]?.consequence = consequence

				// Uploads ask every time, whatever the standing or temporary approval.
				let alwaysAsks = operation.alwaysAsks || consequence != nil
				let isTemporarilyGranted = !alwaysAsks
				&& !operation.ignoresTemporaryGrant
				&& state.automation.mutationGrantIsActive(for: client, now: now)
				let isStandingGranted = !alwaysAsks && client.skipsApproval(for: operation, consequence: consequence)

				// A batch approval covers a consequential step only when the user saw that batch's prompt.
				let isApproved = pending.approved && (consequence == nil || pending.batchAskedUser != false)
				if isApproved || isTemporarilyGranted || isStandingGranted {
					state.automation.pending[id]?.approved = true
					if !pending.approved, !isStandingGranted {
						state.automation.pending[id]?.approvalExpiresAt = client.mutationGrantUntil
					}
					state.beginAgentPresence(id, now: now)
					if case .click = pending.request.operation { return click(id, state: &state) }
					if case .form = pending.request.operation { return form(id, state: &state) }
					if case .scroll = pending.request.operation { return scroll(id, state: &state) }
					if case .batch = pending.request.operation { return approveBatch(id, state: &state) }
					if case .findInPage = pending.request.operation { return findInPage(requestID: id, state: &state) }
					if case .dialog = pending.request.operation { return pageDialog(requestID: id, state: &state) }
					if case .media = pending.request.operation { return controlMedia(requestID: id, state: &state) }
					if case .settings = pending.request.operation { return changeSettings(id, client: client, state: &state) }
					if case .script = pending.request.operation { return evaluateScript(requestID: id, state: &state) }
					return execute(id, state: &state)
				}
				if state.automation.isUnattended {
					return finish(id, result: .failure(.userActionRequired), state: &state)
				}

				// A batch approval that didn't cover the step no longer counts, nor its expiry.
				state.automation.pending[id]?.approved = false
				state.automation.pending[id]?.approvalExpiresAt = nil
				state.automation.pending[id]?.batchAskedUser = nil
				state.automation.pending[id]?.awaitingApproval = true

				// Held back by launch onboarding, the approval shows once the window opens (DEV-838).
				if state.openMainWindow() { state.focusedWindowID = state.main.id }
				return waitForUser(id, kind: .approval, state: state)
			}
		}

		Pullback(\.automation.ui.approve) { state, id in
			guard
				state.automation.pending[id]?.executing == false,
				state.automation.pending[id]?.awaitingApproval == true
			else { return .none }

			state.automation.pending[id]?.approved = true
			return inspect(id, state: state)
		}

		Pullback(\.automation.ui.unattended) { state in
			state.automation.isUnattended = true
			let waiting = state.automation.pending.filter { $0.value.awaitingApproval && !$0.value.approved }.keys
			return .merge(waiting.map { finish($0, result: .failure(.userActionRequired), state: &state) })
		}

		Pullback(\.automation.ui.unattendedClient) { state, id in
			guard state.automation.isUnattended else { return .none }
			state.automation.unattendedClientID = id
			return .none
		}

		Pullback(\.automation.ui.temporaryGrantWindow) { state, seconds in
			guard seconds.isFinite, seconds > 0 else { return .none }
			state.automation.temporaryGrantWindow = min(seconds, AutomationState.temporaryGrantLimit)
			return .none
		}

		Pullback(\.automation.ui.decline) { state, id in
			finish(id, result: .failure(.approvalDeclined), state: &state)
		}

		Pullback(\.automation.event.waited) { state, value in
			waited(value.0, observation: value.1, state: &state)
		}

		Pullback(\.automation.event.finished) { state, value in
			finish(value.0, result: value.1, state: &state)
		}

		// DEV-1009: the check and the end happen together, so Stop, a pause or a revoked
		// grant that came first leaves the page alone.
		Pullback(\.automation.event.pageNotAnswering) { state, value in
			let (id, tabID, document, result) = value

			// Only the document that didn't answer: a navigation since leaves the new one alone.
			guard
				document != nil,
				state.automationMayRecover(id, tabID: tabID),
				MainActor.assumeIsolated({ [engine] in
					engine.snapshot(tabID)?.documentRevision == document && engine.endRenderer(tabID)
				})
			else { return finish(id, result: result, state: &state) }

			return .run { [engine] send in
				try? await engine.command(tabID, .reload)
				await send(.automation(.event(.finished(id, .failure(.pageNotAnswering)))))
			}
			.cancellable(id: id)
		}

		Pullback(\.automation.event.opened) { state, value in
			opened(value.0, tab: value.1, state: &state)
		}

		Pullback(\.automation.event.agentTabReuseReady) { state, value in
			reuseReady(value.0, tabID: value.1, state: &state)
		}

		Pullback(\.automation.event.hostProgress) { state, id in
			hostProgress(id, state: &state)
		}

		Pullback(\.automation.event.hostReceiptReleased) { state, id in
			state.automation.hostReceipts[id] = nil
			return .none
		}

		Pullback(\.automation.event.closed) { state, value in
			closed(value.0, token: value.1, state: &state)
		}

		Pullback(\.automation.event.scrollReceiptReleased) { state, id in
			state.automation.scrollReceipts[id] = nil
			return .none
		}

		Pullback(\.automation.event.formReceiptReleased) { state, id in
			state.automation.formReceipts[id] = nil
			return .none
		}

		Pullback(\.automation.event.clickReceiptReleased) { state, id in
			state.automation.clickReceipts[id] = nil
			return .none
		}

		Pullback(\.automation.event.managementApproved) { state, value in
			approved(value.0, previous: value.1, updated: value.2, removed: value.3, state: &state)
		}

		Pullback(\.automation.event.folderDeletionApproved) { state, value in
			folderDeleted(value.0, previous: value.1, updated: value.2, removed: value.3, state: &state)
		}

		Pullback(\.automation.event.archiveRestored) { state, value in
			archiveRestored(value.0, previous: value.1, updated: value.2, copies: value.3, state: &state)
		}

		Pullback(\.automation.event.managementSettled) { state, id in
			settled(id, state: &state)
		}

		Pullback(\.automation.event.downloadsRead) { state, queue in
			state.downloads.queue = queue
			return .none
		}

		Pullback(\.automation.event.downloadStarted) { state, value in
			let (id, queue, result) = value
			state.downloads.queue = queue
			return finish(id, result: result, state: &state)
		}

		Pullback(\.automation.event.extensionsChanged) { state, value in
			extensionsChanged(value.0, profileID: value.1, result: value.2, state: &state)
		}

		Pullback(\.settings.extensions.delegate.automationInstallInventoryLoaded) { state, value in
			extensionInstallInventoryLoaded(value.0, inventory: value.1, state: &state)
		}

		Pullback(\.settings.extensions.delegate.automationInstallFinished) { state, value in
			extensionInstallFinished(value.0, outcome: value.1, inventory: value.2, state: &state)
		}

		// However the request ends without the sheet's answer (a timeout, a cancel, a disconnect,
		// a grant change, MCP turned off), its install leaves the Extensions sheet (DEV-951).
		Reduce { state, _ in
			guard
				let install = state.settings.extensions.automationInstall,
				install.stage != .discarding,
				state.automation.pending[install.id] == nil
			else { return .none }

			return .send(.settings(.extensions(.automationInstallCancelled(install.id))))
		}

		Pullback(\.automation.event.siteSettingsChanged) { state, value in
			siteSettingsChanged(value.0, profileID: value.1, result: value.2, state: &state)
		}

		Pullback(\.automation.event.managementFailed) { state, value in
			finish(value.0, result: .failure(value.1), state: &state)
		}

		Pullback(\.main.event.movedAcrossProfiles) { state, request in
			let ids = state.automation.pending.values.filter { $0.settlement == .transfer(request.id) }.map(\.request.id)
			guard !ids.isEmpty else { return .none }
			state.automation.completedTransfers.insert(request.id)
			return .merge(ids.map { .send(.automation(.event(.managementSettled($0)))) })
		}

		Pullback(\.main.event.moveFailed) { state, value in
			let (requestID, message) = value
			let ids = state.automation.pending.values.filter { $0.settlement == .transfer(requestID) }.map(\.request.id)
			let failure: AutomationFailure = message.isEmpty ? .cancelled : .staleTarget
			return .merge(ids.map { .send(.automation(.event(.managementFailed($0, failure)))) })
		}

		Pullback(\.profileRetirement.failed) { state, _ in
			let ids = state.automation.pending.values.filter {
				guard case .profileRemoved = $0.settlement else { return false }
				return true
			}.map(\.request.id)
			return .merge(ids.map { .send(.automation(.event(.managementFailed($0, .engineFailed)))) })
		}

		Pullback(\.automation.event.closeReceiptReleased) { state, id in
			state.automation.closeReceipts[id] = nil
			return .none
		}
	}

	private func invalidate(
		_ clientID: UUID,
		state: inout State
	) -> Effect<Action> {
		let regranted = regrant(clientID, state: &state)
		state.automation.sessions = state.automation.sessions.filter { $0.value != clientID }
		return .merge(
			regranted,
			.run { [control] _ in await control.revoke(clientID) }
		)
	}

	/// Drops everything bound to the client's previous grant without ending its sessions.
	/// Its pending requests answer `failure` now (`denied`, or `paused` after Stop), since no
	/// disconnect will end them.
	private func regrant(
		_ clientID: UUID,
		failure: AutomationFailure = .denied,
		state: inout State
	) -> Effect<Action> {
		let ids = state.automation.pending.values.filter { $0.request.clientID == clientID }.map(\.request.id)
		let replies = ids.map { finish($0, result: .failure(failure), state: &state) }
		let scopes = state.automation.inspectionScopes.values.filter { $0.clientID == clientID }.map(\.id)
		state.automation.inspectionScopes = state.automation.inspectionScopes.filter { $0.value.clientID != clientID }
		state.automation.releasedInspections.removeAll { $0.request.clientID == clientID }
		state.automation.clickReceipts = state.automation.clickReceipts.filter { $0.value.request.clientID != clientID }
		state.automation.scrollReceipts = state.automation.scrollReceipts.filter { $0.value.clientID != clientID }
		state.automation.formReceipts = state.automation.formReceipts.filter { $0.value.clientID != clientID }
		state.automation.hostHandles = state.automation.hostHandles.filter { $0.value.clientID != clientID }
		state.automation.hostReceipts = state.automation.hostReceipts.filter { $0.value.request.clientID != clientID }
		state.automation.closeReceipts = state.automation.closeReceipts.filter { $0.value.request.clientID != clientID }
		state.automation.batchApprovals = state.automation.batchApprovals.filter { $0.value.clientID != clientID }
		let logs = stopDeveloperLogs(of: clientID, state: &state)
		return .merge(ids.map { .cancel(id: $0) } + replies + [
			logs,
			revokeInspectionScopes(scopes),
			state.saveWorkspace(),
		])
	}

	private func host(
		_ event: AutomationHostEvent,
		state: inout State
	) -> Effect<Action> {
		switch event {
		case let .connected(clientID, sessionID):
			let oldScope = state.automation.inspectionScopes.removeValue(forKey: sessionID)
			state.automation.releasedInspections.removeAll { $0.request.sessionID == sessionID }
			state.automation.sessions[sessionID] = clientID
			return revokeInspectionScopes(oldScope.map { [$0.id] } ?? [])

		case let .disconnected(sessionID):
			let scope = state.automation.inspectionScopes.removeValue(forKey: sessionID)
			state.automation.sessions[sessionID] = nil
			state.automation.hostHandles = state.automation.hostHandles.filter { $0.value.sessionID != sessionID }
			state.automation.hostReceipts = state.automation.hostReceipts
				.filter { $0.value.request.sessionID != sessionID }
			state.automation.releasedInspections.removeAll { $0.request.sessionID == sessionID }
			state.automation.clickReceipts = state.automation.clickReceipts
				.filter { $0.value.request.sessionID != sessionID }
			state.automation.scrollReceipts = state.automation.scrollReceipts
				.filter { $0.value.sessionID != sessionID }
			state.automation.formReceipts = state.automation.formReceipts
				.filter { $0.value.sessionID != sessionID }
			state.automation.closeReceipts = state.automation.closeReceipts
				.filter { $0.value.request.sessionID != sessionID }
			state.automation.batchApprovals[sessionID] = nil
			let ids = state.automation.pending.values.filter { $0.request.sessionID == sessionID }.map(\.request.id)
			for id in ids { state.discardAutomationRequest(id) }
			return .merge(ids.map { .cancel(id: $0) } + [
				revokeInspectionScopes(scope.map { [$0.id] } ?? []),
			])

		case let .cancel(id):
			state.automation.hostReceipts[id] = nil
			state.automation.scrollReceipts[id] = nil
			state.automation.formReceipts[id] = nil
			state.discardAutomationRequest(id)
			state.automation.closeReceipts[id] = nil
			state.automation.clickReceipts[id] = nil
			return .cancel(id: id)

		case let .inspectionReleased(request, result, grantRevision):
			state.recordReleasedInspection(request, result: result, grantRevision: grantRevision, now: now)
			return .none

		case let .scrollSubmitted(id):
			guard
				let pending = state.automation.pending[id],
				pending.executing,
				case let .scroll(request) = pending.request.operation,
				let source = pending.interactionSource
			else { return .none }

			let key = AutomationState.OperationKey(clientID: pending.request.clientID, operationID: request.operationID)
			guard let binding = state.automation.operationBindings[key] else { return .none }

			state.automation.scrollOutcomes[key] = .init(operationID: request.operationID, disposition: .possiblyDispatched)
			state.automation.scrollReceipts[id] = .init(
				requestID: id,
				clientID: pending.request.clientID,
				sessionID: pending.request.sessionID,
				operationID: request.operationID,
				binding: binding,
				grantRevision: pending.grantRevision,
				source: source
			)
			return .none

		case let .formSubmitted(id):
			guard
				let pending = state.automation.pending[id],
				pending.executing,
				case let .form(request) = pending.request.operation,
				let source = pending.interactionSource
			else { return .none }

			let key = AutomationState.OperationKey(clientID: pending.request.clientID, operationID: request.operationID)
			guard let binding = state.automation.operationBindings[key] else { return .none }

			state.automation.formOutcomes[key] = .init(operationID: request.operationID, disposition: .possiblyDispatched)
			state.automation.formReceipts[id] = .init(
				requestID: id,
				clientID: pending.request.clientID,
				sessionID: pending.request.sessionID,
				operationID: request.operationID,
				binding: binding,
				grantRevision: pending.grantRevision,
				source: source
			)
			return .none

		case let .clickSubmitted(id):
			guard
				let pending = state.automation.pending[id],
				pending.executing,
				case let .click(request) = pending.request.operation,
				let source = pending.interactionSource
			else { return .none }

			let key = AutomationState.OperationKey(clientID: pending.request.clientID, operationID: request.operationID)
			state.automation.clickOutcomes[key] = .init(operationID: request.operationID, disposition: .possiblyDispatched)
			state.automation.clickReceipts[id] = .init(
				request: pending.request,
				grantRevision: pending.grantRevision,
				source: source
			)
			return .none

		case let .request(request):
			guard
				state.automation.pending.count < 16,
				let client = state.automationPreferences.clients.first(where: { $0.id == request.clientID })
			else { return .run { [control] _ in await control.respond(request.id, .failure(.denied)) } }


			state.automation.pending[request.id] = .init(request: request, grantRevision: client.grantRevision)
			if let operationID = request.operation.mutationID {
				let key = AutomationState.OperationKey(clientID: client.id, operationID: operationID)
				let binding = AutomationSecurity.mutationBinding(request.operation)
				if state.automation.usedOperations.contains(key) {
					let sameBinding = state.automation.operationBindings[key] == binding
					if case .scroll = request.operation {
						let recorded = sameBinding ? state.automation.scrollOutcomes[key] : nil
						var result = recorded ?? .init(
							operationID: operationID,
							disposition: .possiblyDispatched
						)
						let inFlight = state.automation.pending.values.contains {
							$0.request.id != request.id
							&& $0.request.clientID == request.clientID
							&& $0.request.operation.mutationID == operationID
						}
						if inFlight && result.disposition == .notDispatched {
							result.disposition = .possiblyDispatched
						}
						result.failure = .duplicateOperation
						return finish(request.id, result: .scroll(result), state: &state)
					}
					if case .form = request.operation {
						let recorded = sameBinding ? state.automation.formOutcomes[key] : nil
						var result = recorded ?? .init(
							operationID: operationID,
							disposition: .possiblyDispatched
						)
						let inFlight = state.automation.pending.values.contains {
							$0.request.id != request.id
							&& $0.request.clientID == request.clientID
							&& $0.request.operation.mutationID == operationID
						}
						if inFlight && result.disposition == .notDispatched {
							result.disposition = .possiblyDispatched
						}
						result.failure = .duplicateOperation
						return finish(request.id, result: .form(result), state: &state)
					}
					if case .click = request.operation {
						let recorded = sameBinding ? state.automation.clickOutcomes[key] : nil
						var result = recorded ?? .init(
							operationID: operationID,
							disposition: .possiblyDispatched
						)
						let isInFlight = state.automation.pending.values.contains {
							$0.request.id != request.id
							&& $0.request.clientID == request.clientID
							&& $0.request.operation.mutationID == operationID
						}
						if isInFlight && result.disposition == .notDispatched {
							result.disposition = .possiblyDispatched
						}
						result.failure = .duplicateOperation
						return finish(request.id, result: .click(result), state: &state)
					}
					return finish(request.id, result: .failure(.duplicateOperation), state: &state)
				}
				guard
					state.automation.usedOperations.count < 4096,
					state.automation.usedOperations.filter({ $0.clientID == client.id }).count < 256
				else { return finish(request.id, result: .failure(.limitExceeded), state: &state) }

				// Never evict operation IDs: a delayed retry must not repeat a mutation in this app session.
				state.automation.usedOperations.insert(key)
				state.automation.operationBindings[key] = binding
				if case .scroll = request.operation {
					state.automation.scrollOutcomes[key] = .init(operationID: operationID, disposition: .notDispatched)
				}
				if case .form = request.operation {
					state.automation.formOutcomes[key] = .init(operationID: operationID, disposition: .notDispatched)
				}
				if case .click = request.operation {
					state.automation.clickOutcomes[key] = .init(operationID: operationID, disposition: .notDispatched)
				}
				if
					let binding,
					let approval = state.consumeBatchApproval(
						request,
						binding: binding,
						grantRevision: client.grantRevision,
						now: now
					)
				{
					state.automation.pending[request.id]?.approved = true
					state.automation.pending[request.id]?.approvalExpiresAt = approval.expiresAt
					state.automation.pending[request.id]?.batchAskedUser = approval.askedUser
				}
				let hasPendingMutation = state.automation.pending.values.contains {
					$0.request.id != request.id && $0.request.operation.mutationID != nil
				}
				if hasPendingMutation {
					return finish(request.id, result: .failure(.busy), state: &state)
				}
			}
			return inspect(request.id, state: state)
		}
	}

	private func inspect(
		_ id: UUID,
		state: State
	) -> Effect<Action> {
		let ids = state.automation.pending[id].map { state.automationSnapshotTabIDs(for: $0.request) } ?? []

		// The queue streams into state only while a Downloads surface observes it.
		// Read the ledger once per request instead, so progress never streams through actions.
		let readsDownloads = state.automation.pending[id]?.request.operation.requiredCapabilities.contains(.downloads) == true
		return .run { [engine, downloads] send in
			let snapshots = await MainActor.run {
				State.automationSnapshots(of: ids, reading: engine.snapshot)
			}
			try Task.checkCancellation()
			if readsDownloads { await send(.automation(.event(.downloadsRead(await downloads.snapshot())))) }
			await send(.automation(.event(.inspected(id, snapshots))))
		}
		.cancellable(id: id)
	}

	internal func finish(
		_ id: UUID,
		result: AutomationResult,
		state: inout State
	) -> Effect<Action> {
		guard let pending = state.automation.pending[id] else { return .none }

		// DEV-1009: a request that timed out on a tab may have met a page that stopped
		// answering. A page that doesn't answer a ping in 2 s is ended and loaded again on a
		// new renderer, and the agent hears `pageNotAnswering`.
		if
			result.failure == .timedOut,
			let tabID = pending.request.operation.pageTabID,
			state.automation.hangChecks.insert(id).inserted
		{
			return .run { [engine] send in
				let document = await MainActor.run { engine.snapshot(tabID)?.documentRevision }

				// Apart from the scripts' queue: a script the page froze on keeps that busy.
				let answered = await engine.pingPage(tabID, 2000) ?? true
				await send(.automation(.event(
					answered ? .finished(id, result) : .pageNotAnswering(id, tabID, document: document, result)
				)))
			}
			.cancellable(id: id)
		}
		state.automation.hangChecks.remove(id)

		// Any request on an agent's tab, a read too, is a use (DEV-1022).
		if let tabID = pending.request.operation.unloadTargetTabID { state.agentUsedTab(tabID) }
		var result = result
		if case var .command(response) = result, let route = pending.route {
			response.route = route
			result = .command(response)
		}
		if case let .scroll(scroll) = pending.request.operation {
			let key = AutomationState.OperationKey(clientID: pending.request.clientID, operationID: scroll.operationID)
			if case let .failure(failure) = result {
				result = .scroll(.init(
					operationID: scroll.operationID,
					disposition: state.automation.scrollOutcomes[key]?.disposition ?? .notDispatched,
					failure: failure
				))
			}
			if case let .scroll(receipt) = result {
				let recordsOriginal = receipt.failure != .duplicateOperation
				&& state.automation.usedOperations.contains(key)
				if recordsOriginal { state.automation.scrollOutcomes[key] = receipt }
			}
		}
		if case let .form(form) = pending.request.operation {
			let key = AutomationState.OperationKey(clientID: pending.request.clientID, operationID: form.operationID)
			if case let .failure(failure) = result {
				result = .form(.init(
					operationID: form.operationID,
					disposition: state.automation.formOutcomes[key]?.disposition ?? .notDispatched,
					failure: failure
				))
			}
			if case let .form(receipt) = result {
				let recordsOriginal = receipt.failure != .duplicateOperation
				&& state.automation.usedOperations.contains(key)
				if recordsOriginal { state.automation.formOutcomes[key] = receipt }
			}
		}
		if case let .click(click) = pending.request.operation {
			let key = AutomationState.OperationKey(clientID: pending.request.clientID, operationID: click.operationID)
			if case let .failure(failure) = result {
				result = .click(.init(
					operationID: click.operationID,
					disposition: state.automation.clickOutcomes[key]?.disposition ?? .notDispatched,
					failure: failure
				))
			}
			if case let .click(receipt) = result {
				let recordsOriginalAttempt = receipt.failure != .duplicateOperation
				&& state.automation.usedOperations.contains(key)
				if recordsOriginalAttempt { state.automation.clickOutcomes[key] = receipt }
			}
		}
		state.endAgentPresence(id, now: now)
		state.discardAutomationRequest(id)

		let operation: String
		switch pending.request.operation {
		case .signIn: operation = "signIn"
		case .inventory: operation = "inventory"
		case .capture: operation = "capture"
		case .inspect: operation = "inspect"
		case .load: operation = "load"
		case let .pdf(value): operation = "pdf." + value.kind.rawValue
		case .findInPage: operation = "findInPage"
		case let .dialog(value): operation = "dialog." + value.action.rawValue
		case let .media(value): operation = "media." + value.action.rawValue
		case .script: operation = "script"
		case .passwordSignIn: operation = "passwordSignIn"
		case let .logs(value): operation = "logs." + value.action.rawValue
		case let .settings(value):
			switch value.kind {
			case let .read(section, _): operation = "settings.read." + section.rawValue
			case .testRoute: operation = "settings.testRoute"
			case let .change(change): operation = "settings." + change.edit.name
			}
		case .wait: operation = "wait"
		case .click: operation = "click"
		case let .form(value): operation = value.kind.rawValue
		case .scroll: operation = "scroll"
		case .batch: operation = "batch"
		case let .data(value): operation = value.kind.rawValue
		case let .link(value): operation = "link." + value.kind.rawValue
		case let .command(value): operation = value.action.rawValue
		}
		let outcome: String
		switch result {
		case let .signIn(value): outcome = value.status.rawValue
		case .inventory: outcome = "read"
		case .capture: outcome = "captured"
		case .inspection: outcome = "inspected"
		case let .load(value): outcome = value.status.rawValue
		case .pdf: outcome = "read"
		case let .findInPage(value): outcome = value.matches.map { "\($0) matches" } ?? "noResult"
		case let .dialog(value): outcome = value.failure?.rawValue ?? (value.answered ? "answered" : "read")
		case let .media(value):
			if let failure = value.failure {
				outcome = failure.rawValue
			} else {
				outcome = switch value.action {
				case .list: "\(value.sessions.count) sessions"
				case .position: "read"
				default: "performed"
				}
			}
		case let .wait(value): outcome = value.status.rawValue
		case let .click(value): outcome = value.disposition.rawValue
		case let .form(value): outcome = value.disposition.rawValue
		case let .scroll(value): outcome = value.disposition.rawValue
		case let .command(value): outcome = value.status.rawValue
		case let .batch(value): outcome = "approved \(value.approvedSteps)"
		case .data: outcome = "read"
		case let .settings(value): outcome = value.operationID == nil ? "read" : "changed"
		case let .script(value): outcome = value.outcome.rawValue
		case let .passwordSignIn(value): outcome = value.outcome.rawValue + "." + value.reason.rawValue
		case let .logs(value):
			outcome = value.action == .start || value.action == .stop
			? (value.capturing ? "started" : "stopped")
			: "\(value.console.count + value.network.count + value.requests.count) entries"
		case let .link(value): outcome = value.outcome
		case let .failure(error): outcome = error.rawValue
		}

		state.automation.activity.append(.init(
			id: id,
			clientID: pending.request.clientID,
			operation: operation,
			outcome: outcome,
			date: now
		))
		if state.automation.activity.count > 128 {
			state.automation.activity.removeFirst(state.automation.activity.count - 128)
		}
		let reply = Effect<Action>.run { [control, result] _ in await control.respond(id, result) }
		if case .scroll = pending.request.operation {
			return .concatenate(reply, .send(.automation(.event(.scrollReceiptReleased(id)))))
		}
		if case .form = pending.request.operation {
			return .concatenate(reply, .send(.automation(.event(.formReceiptReleased(id)))))
		}
		if case .click = pending.request.operation {
			return .concatenate(reply, .send(.automation(.event(.clickReceiptReleased(id)))))
		}
		if case let .command(command) = pending.request.operation, command.action.isHostOperation {
			return .concatenate(reply, .send(.automation(.event(.hostReceiptReleased(id)))))
		}
		return reply
	}

	private func server(
		enabled: Bool,
		generation: UUID
	) -> Effect<Action> {
		.run { @MainActor [control] send in

			// Both cancellation IDs are registered by now. Report in and stop the server in one
			// main-actor turn, so a transition reduced earlier never runs after this one.
			send(.automation(.event(.serverRequested(generation))))
			try Task.checkCancellation()
			await control.stop()
			try Task.checkCancellation()
			guard enabled else { return }

			do {
				let path = try await control.start()
				send(.automation(.event(.started(generation, .success(path)))))
			} catch {
				send(.automation(.event(.started(generation, .failure(.appUnavailable)))))
			}
		}
		.cancellable(id: Cancellation.serverGeneration(generation))
		.cancellable(id: Cancellation.server)
	}

	private func createAgentClient(for request: AgentSetup.Request) -> Effect<Action> {
		let id = uuid()
		let revision = uuid()
		return .run { [control] send in
			do {
				let credential = try control.credential()
				let client = AutomationClient(
					id: id,
					name: request.agent.title,
					credentialDigest: credential.digest,
					grantRevision: revision
				)
				await send(.automation(.event(.agentSetupClientCreated(client, credential.token, request))))
			} catch {
				await send(.automation(.event(.finished(id, .failure(.appUnavailable)))))
			}
		}
	}
}

internal enum AutomationConfiguration {
	internal static func make(
		clientID: UUID,
		token: String,
		socket: String,
		helper: String
	) -> String {
		let configuration = [
			"mcpServers": [
				"arx": [
					"command": helper,
					"env": [
						"ARX_MCP_SOCKET": socket,
						"ARX_MCP_CLIENT_ID": clientID.uuidString,
						"ARX_MCP_CREDENTIAL": token,
					],
				],
			],
		]
		let data = try? JSONSerialization.data(
			withJSONObject: configuration,
			options: [.prettyPrinted, .sortedKeys]
		)
		guard let data else { return "" }

		return String(decoding: data, as: UTF8.self)
	}
}
