import AppUI
import BrowserCore
import Foundation
import OutsideAgentsFeature
import SettingsFeature
import SwiftUI
import _ComposableArchitecture

internal struct AutomationSettingsView: View {
	internal let store: StoreOf<AppFeature>
	private let height: CGFloat

	/// `height` is the sheet's; the design snapshot passes a tall one to show every section.
	internal init(
		store: StoreOf<AppFeature>,
		height: CGFloat = 620
	) {
		self.store = store
		self.height = height
	}

	internal var body: some View {
		// The sheet Air Traffic Control and Search Shortcuts use too.
		SettingsSheet(
			String.localized(.appUI.automation.title),
			trail: [SettingsCategory.advanced.title],
			width: 680,
			height: height,
			close: { store.send(.automation(.ui(.present(false)))) }
		) {
			VStack(alignment: .leading, spacing: 22) {
				if let request = store.automation.pendingAgentSetup {
					SettingsSection(
						String.localized(.appUI.automation.setupRequest(request.agent.title)),
						caption: String.localized(.appUI.automation.setupDetail)
					) {
						HStack {
							Spacer()
							Button(String.localized(.appUI.automation.setupDecline)) {
								store.send(.automation(.ui(.declineAgentSetup)))
							}
							Button(String.localized(.appUI.automation.setupApprove)) {
								store.send(.automation(.ui(.approveAgentSetup)))
							}
							.buttonStyle(.arx(.primary))
						}
						.settingsGroupRow()
					}
				}
				Text(localized: .appUI.automation.description)
					.font(.callout)
					.foregroundStyle(.secondary)

				// The same component as onboarding's "Outside agents" page, including the MCP switch.
				OutsideAgentsView(store: store.scope(state: \.outsideAgents, action: \.outsideAgents))
				clients
				agentTabs
				passwordSites
				activity
			}
		}
	}

	/// Adding a client, the credential it's shown once, and each client's access.
	private var clients: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(localized: .appUI.automation.clients)
				.font(.system(size: 13, weight: .semibold))
				.padding(.horizontal, 14)
				.accessibilityAddTraits(.isHeader)

			// A button that opens a form with the client's name (DEV-1001).
			Button(String.localized(.appUI.automation.addClientButton), systemImage: "plus") {
				store.send(.automation(.ui(.newClient)))
			}
			.disabled(store.automation.socketPath == nil)
			.padding(.horizontal, 14)
			.sheet(
				isPresented: Binding(
					get: { store.automation.isAddingClient },
					set: { if !$0 { store.send(.automation(.ui(.cancelNewClient))) } }
				)
			) {
				SettingsListForm(
					title: String.localized(.appUI.automation.addClientTitle),
					primaryTitle: String.localized(.appUI.settings.siteForm.add),
					isValid: canAddClient,
					onCancel: { store.send(.automation(.ui(.cancelNewClient))) },
					onSubmit: { store.send(.automation(.ui(.addClient))) }
				) {
					SettingsTextField(
						String.localized(.appUI.automation.clientName),
						text: Binding(
							get: { store.automation.newClientName },
							set: { store.send(.automation(.ui(.clientName($0)))) }
						),
						prompt: String.localized(.appUI.automation.clientNameExample)
					)
				}
			}
			if let configuration = store.automation.configuration {
				SettingsSection {
					VStack(alignment: .leading, spacing: 8) {
						Label(String.localized(.appUI.automation.configuration), systemImage: "key.horizontal")
							.font(.headline)
						Text(localized: .appUI.automation.configurationNote)
							.font(.caption)
							.foregroundStyle(.secondary)
						Text(configuration)
							.font(.caption.monospaced())
							.textSelection(.enabled)
						HStack {
							Button(String.localized(.appUI.automation.copyConfiguration)) {
								store.send(.automation(.ui(.copyConfiguration)))
							}
							Button(String.localized(.appUI.automation.dismissConfiguration)) {
								store.send(.automation(.ui(.dismissConfiguration)))
							}
						}
					}
					.padding(.vertical, 10)
				}
			}
			ForEach(store.automationPreferences.clients) { client in
				AutomationClientEditor(store: store, client: client)
			}
			Text(localized: .appUI.automation.limitations)
				.font(.caption)
				.foregroundStyle(.secondary)
				.padding(.horizontal, 14)
		}
	}

	/// How long an agent's tab may sit unused before it's tidied, with `ARX_AGENT_TABS` on (DEV-1022).
	@ViewBuilder
	private var agentTabs: some View {
		if store.automation.agentTabsEnabled {
			SettingsSection(
				String.localized(.appUI.automation.agentTabsTitle),
				footer: String.localized(.appUI.automation.agentTabsFooter)
			) {
				SettingsRow(String.localized(.appUI.automation.agentTabsCleanup)) {
					Picker(
						String.localized(.appUI.automation.agentTabsCleanup),
						selection: Binding(
							get: { store.automationPreferences.agentTabCleanup },
							set: { store.send(.automation(.ui(.agentTabCleanup($0)))) }
						)
					) {
						Text(localized: .appUI.automation.agentTabsNever).tag(AgentTabCleanup.never)
						Text(localized: .appUI.automation.agentTabsFifteenMinutes).tag(AgentTabCleanup.fifteenMinutes)
						Text(localized: .appUI.automation.agentTabsOneHour).tag(AgentTabCleanup.oneHour)
					}
					.labelsHidden()
					.fixedSize()
				}
			}
		}
	}

	@ViewBuilder
	private var passwordSites: some View {
		let sites = store.automationPreferences.agentSignInSites
		if !sites.isEmpty {
			SettingsSection(
				String.localized(.appUI.automation.passwordSites),
				caption: String.localized(.appUI.automation.passwordSitesDetail)
			) {
				ForEach(sites, id: \.self) { site in
					SettingsRow(site.origin, detail: profileName(site.profileID)) {
						Button(String.localized(.appUI.automation.passwordSiteRemove)) {
							store.send(.automation(.ui(.removeAgentSignInSite(site))))
						}
					}
				}
			}
		}
	}

	@ViewBuilder
	private var activity: some View {
		let entries = store.automation.activity.reversed()
		if !entries.isEmpty {
			SettingsSection(
				String.localized(.appUI.automation.activity),
				footer: String.localized(.appUI.automation.activityNote)
			) {
				ForEach(entries) { entry in
					HStack {
						Text(entry.date, style: .time).foregroundStyle(.secondary)
						Text(clientName(entry.clientID))
						Text(entry.operation).font(.caption.monospaced())
						Spacer()
						Text(entry.outcome).font(.caption.monospaced()).foregroundStyle(.secondary)
					}
					.font(.caption)
					.padding(.vertical, 6)
				}
			}
		}
	}

	private var canAddClient: Bool {
		let name = store.automation.newClientName.trimmingCharacters(in: .whitespacesAndNewlines)
		return store.automation.socketPath != nil && !name.isEmpty
	}

	private func profileName(_ id: Profile.ID) -> String {
		store.workspace.profiles[id: id]?.name ?? ""
	}

	private func clientName(_ id: UUID) -> String {
		store.automationPreferences.clients.first(where: { $0.id == id })?.name
			?? id.uuidString
	}
}

private struct AutomationClientEditor: View {
	fileprivate let store: StoreOf<AppFeature>
	fileprivate let client: AutomationClient

	fileprivate init(
		store: StoreOf<AppFeature>,
		client: AutomationClient
	) {
		self.store = store
		self.client = client
	}

	fileprivate var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(spacing: 8) {
				Image(systemName: "sparkles")
					.foregroundStyle(.secondary)
					.accessibilityHidden(true)
				Text(client.name).font(.headline)
				let sessions = store.automation.sessions.values.filter { $0 == client.id }.count
				Label {
					Text(sessions, format: .number)
				} icon: {
					Circle()
						.fill(sessions > 0 ? Color.green : Color.secondary)
						.frame(width: 7, height: 7)
				}
				.font(.caption)
				.foregroundStyle(.secondary)
				.help(String.localized(.appUI.automation.connected))
				.accessibilityLabel(Text(localized: .appUI.automation.connected))
				.accessibilityValue(Text(sessions, format: .number))
				if client.isPaused {
					Text(localized: .appUI.automation.paused)
						.font(.caption.weight(.semibold))
						.foregroundStyle(.orange)
						.help(String.localized(.appUI.automation.pausedNote))
				}
				Spacer()

				// Pause is the page indicator's Stop, kept here for a client not acting right now (DEV-899).
				if client.isPaused {
					Button(String.localized(.appUI.automation.resume)) {
						store.send(.automation(.ui(.resumeClient(client.id))))
					}
					.accessibilityIdentifier("automation-resume-\(client.id)")
				} else {
					Button(String.localized(.appUI.automation.pause)) {
						store.send(.automation(.ui(.stopClient(client.id))))
					}
					.accessibilityIdentifier("automation-pause-\(client.id)")
				}
				Button(String.localized(.appUI.automation.revoke), role: .destructive) {
					store.send(.automation(.ui(.revokeClient(client.id))))
				}
			}
			.padding(.horizontal, 14)

			SettingsSection {
				DisclosureGroup {
					VStack(alignment: .leading) {
						ForEach(store.workspace.profiles) { profile in
							Toggle(
								String.localized(.appUI.automation.wholeProfile(profile.name)),
								isOn: scope(.profile(profile.id))
							)
						}
						ForEach(store.workspace.spaces) { space in
							Toggle(space.name, isOn: scope(.space(space.id, profileID: space.profileID)))
								.disabled(client.scopes.contains(.profile(space.profileID)))
						}
						ForEach(store.workspace.tabs) { tab in
							if let location = AutomationAccess.location(of: tab.id, in: store.workspace) {
								Toggle(
									tab.displayTitle,
									isOn: scope(.tab(tab.id, profileID: tab.profileID, location: location))
								)
								.font(.caption)
								.padding(.leading, 16)
								.disabled(client.scopes.contains(.profile(tab.profileID)))
							}
						}
					}
					.padding(.vertical, 6)
				} label: {
					HStack(spacing: 10) {
						rowIcon("square.on.square.dashed")
						Text(localized: .appUI.automation.scope)
					}
				}
				.help(String.localized(.appUI.automation.scopeNote))
				.padding(.vertical, 10)
			}

			SettingsSection(String.localized(.appUI.automation.group.see)) {
				capability("list.bullet.indent", .appUI.automation.read, note: .appUI.automation.readNote, binding(\.allowsRead))
				capability("doc.text", .appUI.automation.pageContent, note: .appUI.automation.pageContentNote, binding(\.allowsPageContent))
				capability("camera.viewfinder", .appUI.automation.screenshots, note: .appUI.automation.screenshotsNote, binding(\.allowsScreenshots))
				capability("clock.arrow.circlepath", .appUI.automation.history, note: .appUI.automation.historyNote, capability(.history))
				capability("arrow.down.circle", .appUI.automation.downloads, note: .appUI.automation.downloadsNote, capability(.downloads))
			}

			SettingsSection(String.localized(.appUI.automation.group.act)) {
				capability(
					"cursorarrow.click",
					.appUI.automation.pageInteraction,
					note: .appUI.automation.pageInteractionNote,
					binding(\.allowsPageInteraction)
				)
				capability("rectangle.stack", .appUI.automation.manageBrowser, note: .appUI.automation.manageBrowserNote, binding(\.allowsManagement))
				capability("gearshape.2", .appUI.automation.browserAdmin, note: .appUI.automation.browserAdminNote, capability(.browserAdmin))
				capability("key", .appUI.automation.signInGrant, note: .appUI.automation.signInGrantNote, binding(\.allowsSignIn))
				capability("folder", .appUI.automation.files, note: .appUI.automation.filesNote, capability(.files))
				capability("scope", .appUI.automation.focusedTab, note: .appUI.automation.focusedTabNote, binding(\.allowsFocusedTab))
				HStack(spacing: 10) {
					rowIcon("hand.raised")
					Text(localized: .appUI.automation.approvalPolicy)
					Spacer(minLength: 12)
					Picker(
						String.localized(.appUI.automation.approvalPolicy),
						selection: Binding(
							get: { client.approvalPolicy },
							set: { policy in change { $0.approvalPolicy = policy } }
						)
					) {
						Text(localized: .appUI.automation.policy.alwaysAsk).tag(AutomationApprovalPolicy.alwaysAsk)
						Text(localized: .appUI.automation.policy.destructiveOnly).tag(AutomationApprovalPolicy.destructiveOnly)
						Text(localized: .appUI.automation.policy.never).tag(AutomationApprovalPolicy.never)
					}
					.labelsHidden()
					.fixedSize()
				}
				.capabilityRow()
				.help(String.localized(.appUI.automation.policyNote))
				temporaryAccess
			}

			SettingsSection(
				String.localized(.appUI.automation.group.developer),
				content: {
					developerCapability("chevron.left.forwardslash.chevron.right", .appUI.automation.script, note: .appUI.automation.scriptNote, .script)
					developerCapability("hammer", .appUI.automation.devtools, note: .appUI.automation.devtoolsNote, .devtools)
					developerCapability(
						"network",
						.appUI.automation.networkDetails,
						note: .appUI.automation.networkDetailsNote,
						.networkDetails
					)
				},
				footer: {
					if !store.settings.general.developerModeEnabled {
						Text(localized: .appUI.automation.developerModeNote)
					}
				}
			)
		}
		.padding(.top, 4)
	}

	@ViewBuilder
	private var temporaryAccess: some View {
		switch store.automation.mutationGrant(for: client, now: Date()) {
		case .none:
			HStack(spacing: 10) {
				rowIcon("timer")
				Text(localized: .appUI.automation.temporary)
				Spacer(minLength: 12)
				Button(String.localized(.appUI.automation.temporaryAllow)) {
					change { $0.mutationGrantUntil = Date().addingTimeInterval(900) }
				}
				.disabled(!canGrantTemporaryAccess)
			}
			.capabilityRow()

		case let .temporary(until):
			HStack(spacing: 10) {
				rowIcon("timer")
				Text(localized: .appUI.automation.grantUntil)
				Text(until, style: .time)
				Spacer()
				revokeGrantButton
			}
			.capabilityRow()

		case let .headlessRun(until):
			HStack(spacing: 10) {
				rowIcon("timer")
				if let until {
					Text(localized: .appUI.automation.headlessRunGrantUntil)
					Text(until, style: .time)
				} else {
					Text(localized: .appUI.automation.headlessRunGrant)
				}
				Spacer()
				revokeGrantButton
			}
			.capabilityRow()
		}
	}

	private func rowIcon(_ symbol: String) -> some View {
		Image(systemName: symbol)
			.font(.system(size: 13))
			.foregroundStyle(.secondary)
			.frame(width: 20)
			.accessibilityHidden(true)
	}

	private var canGrantTemporaryAccess: Bool {
		client.allowsRead
			&& (client.allowsManagement || client.allowsPageInteraction)
			&& client.approvalPolicy != .never
			&& !client.scopes.isEmpty
	}

	/// A developer-tier class can be granted only with developer mode on, and
	/// removed at any time.
	private func developerCapability(
		_ symbol: String,
		_ title: _XCStringResource,
		note: _XCStringResource,
		_ value: AutomationCapability
	) -> some View {
		capability(symbol, title, note: note, capability(value))
			.disabled(!store.settings.general.developerModeEnabled && !client.capabilities.contains(value))
	}

	private func capability(_ capability: AutomationCapability) -> Binding<Bool> {
		Binding(
			get: { client.capabilities.contains(capability) },
			set: { granted in
				change { client in
					if granted {
						client.capabilities.insert(capability)
					} else {
						client.capabilities.remove(capability)
					}
				}
			}
		)
	}

	/// One access class: its icon, its name and a switch. What it allows is the row's tooltip and
	/// VoiceOver hint, so the list stays short.
	private func capability(
		_ symbol: String,
		_ title: _XCStringResource,
		note: _XCStringResource,
		_ isOn: Binding<Bool>
	) -> some View {
		HStack(spacing: 10) {
			rowIcon(symbol)
			Text(localized: title)
			Spacer(minLength: 12)
			Toggle(String.localized(title), isOn: isOn)
				.toggleStyle(.switch)
				.controlSize(.small)
				.labelsHidden()
		}
		.capabilityRow()
		.help(String.localized(note))
		.accessibilityElement(children: .combine)
		.accessibilityHint(Text(localized: note))
	}

	private var revokeGrantButton: some View {
		Button(String.localized(.appUI.automation.revokeTemporary)) {
			change { $0.mutationGrantUntil = nil }
		}
	}

	private func binding(_ keyPath: WritableKeyPath<AutomationClient, Bool>) -> Binding<Bool> {
		Binding(
			get: { client[keyPath: keyPath] },
			set: { value in change { $0[keyPath: keyPath] = value } }
		)
	}

	private func scope(_ scope: AutomationScope) -> Binding<Bool> {
		Binding(
			get: { client.scopes.contains(scope) },
			set: { enabled in
				change { client in
					client.scopes.removeAll { $0 == scope }
					if enabled { client.scopes.append(scope) }
				}
			}
		)
	}

	private func change(_ edit: (inout AutomationClient) -> Void) {
		var client = client
		edit(&client)
		store.send(.automation(.ui(.updateClient(client))))
	}
}

extension View {
	/// A compact Settings row, for the long list of access classes.
	fileprivate func capabilityRow() -> some View {
		padding(.vertical, 6)
			.frame(minHeight: 34)
	}
}
