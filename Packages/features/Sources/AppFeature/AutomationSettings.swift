import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import BrowserExtensionsClient
import ExtensionsFeature
import Foundation
import SettingsFeature
import _ComposableArchitecture

extension AppFeature.State {
	/// A section as this client sees it, with its revision. Extensions, site permissions
	/// and zoom are read from the engine instead, so they aren't built here.
	internal func automationSettings(
		_ section: AutomationSettingsRequest.Section,
		client: AutomationClient
	) -> AutomationSettingsResult? {
		let preferences = persistedPreferences
		var result = AutomationSettingsResult(section: section, revision: "")
		switch section {
		case .preferences:
			// Settings' row index decides what agents may change, and lists every row (DEV-1023).
			// A row its feature flag hides isn't listed, and its keys aren't either.
			let flags = settings.featureFlags
			let (keys, rows) = MainActor.assumeIsolated {
				(SettingsCategory.agentPreferenceKeys(flags), SettingsCategory.automationRows(flags))
			}
			result.preferences = keys.map { key in
				.init(key: key, value: key.value(in: preferences))
			}
			result.rows = rows

		case .routing:
			let visible = preferences.routing.rules.filter { automationPermitsRule($0, client: client) }
			let fallback = preferences.routing.fallback.flatMap { destination in
				AutomationAccess.permitsRoutingDestination(destination, client: client, organization: workspace)
				? AutomationRoutingDestination(destination)
				: nil
			}
			result.routing = .init(
				rules: visible.map(AutomationRoutingRule.init),
				hiddenRules: preferences.routing.rules.count - visible.count,
				fallback: fallback
			)

		case .searchShortcuts:
			result.searchShortcuts = preferences.searchShortcuts.map(AutomationSearchShortcut.init)

		case .keyboardShortcuts:
			result.keyboardShortcuts = BrowserCommand.allCases.map { command in
				.init(
					command: command,
					shortcut: preferences.shortcut(for: command),
					isDefault: !preferences.keyboardShortcuts.contains { $0.command == command },
					conflictResolution: preferences.shortcutConflictChoices.resolution(for: command),
					conflictResolutionIsFixed: !command.offersConflictResolution(
						shortcuts: preferences.keyboardShortcuts.shortcuts(for: command),
						followsAllKeys: settings.followsAllShortcutKeys
					)
				)
			}

		case .extensions, .sitePermissions, .zoom:
			return nil
		}
		result.revision = Self.automationSettingsRevision(result, client: client)
		return result
	}

	internal static func automationSettingsRevision(
		_ result: AutomationSettingsResult,
		client: AutomationClient
	) -> String {
		var contents = result
		contents.revision = ""
		contents.operationID = nil
		contents.targetID = nil
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		let data = (try? encoder.encode(contents)) ?? Data()
		return AutomationSecurity.digest(Data(client.grantRevision.uuidString.utf8) + data)
	}

	/// A profile's extension list revision: it changes whenever Chromium's inventory does.
	internal static func automationExtensionsRevision(
		_ inventory: BrowserExtensionInventory,
		client: AutomationClient
	) -> String {
		let fields = [
			"extensions", inventory.profileID.rawValue.uuidString, String(inventory.revision),
			client.grantRevision.uuidString,
		]
		return AutomationSecurity.digest(Data(fields.joined(separator: "\u{1F}").utf8))
	}

	/// A profile's site permissions or zoom as automation shows them, with a revision
	/// that changes whenever the section's contents do.
	internal static func automationSiteSettingsResult(
		_ section: AutomationSettingsRequest.Section,
		profileID: Profile.ID,
		settings: SiteSettings,
		client: AutomationClient
	) -> AutomationSettingsResult {
		var result = AutomationSettingsResult(section: section, revision: "")
		switch section {
		case .zoom: result.zoom = .init(profileID: profileID.rawValue, settings: settings)
		default: result.sitePermissions = .init(profileID: profileID.rawValue, settings: settings)
		}
		result.revision = automationSettingsRevision(result, client: client)
		return result
	}

	/// The pending `installExtension` behind an automation request, with its client.
	internal func automationInstallRequest(
		_ id: UUID
	) -> (AutomationClient, AutomationSettingsChange, profileID: UUID, extensionID: String)? {
		guard
			let pending = automation.pending[id],
			case let .settings(request) = pending.request.operation,
			let change = request.change,
			case let .installExtension(profileID, extensionID) = change.edit,
			let client = automationPreferences.clients.first(where: { $0.id == pending.request.clientID })
		else { return nil }
		return (client, change, profileID, extensionID)
	}

	/// Whether the Extensions sheet is in the middle of something an MCP install would spoil:
	/// reading the profile and reopening the sheet replace the authority it holds for a review,
	/// an install, a file picker, a store request or an update check (DEV-951).
	internal var extensionsSheetIsBusy: Bool {
		let sheet = settings.extensions
		guard sheet.automationInstall == nil else { return true }
		guard sheet.isPresented else { return false }
		return sheet.isWorking
		|| sheet.packageSelection != nil
		|| sheet.directorySelection != nil
		|| sheet.webstoreRequest != nil
		|| sheet.updateCheck != nil
	}

	/// A rule the grant covers: its destination stays within granted profiles and spaces.
	internal func automationPermitsRule(
		_ rule: RoutingRule,
		client: AutomationClient
	) -> Bool {
		AutomationAccess.permitsRoutingDestination(rule.destination, client: client, organization: workspace)
	}

	/// Checks a settings request against the grant and the section's current revision, and
	/// that a change is one Settings itself would accept, before anyone is asked.
	internal func automationSettingsValidation(
		_ request: AutomationSettingsRequest,
		client: AutomationClient
	) -> AutomationFailure? {
		do {
			try request.validate()
		} catch {
			return error as? AutomationFailure ?? .invalidRequest
		}

		switch request.kind {
		case let .read(_, profileID):
			guard let profileID else { return nil }
			return AutomationAccess.permitsProfile(.init(rawValue: profileID), client: client) ? nil : .denied

		case let .testRoute(_, sourceSpaceID):
			guard let sourceSpaceID else { return nil }
			let permitted = AutomationAccess.permitsSpace(.init(rawValue: sourceSpaceID), client: client, organization: workspace)
			return permitted ? nil : .denied

		case let .change(change):
			if change.edit.section.isProfileScoped, let profileID = change.edit.profileID {
				// The section's revision is checked against a fresh engine read when it runs.
				return AutomationAccess.permitsProfile(.init(rawValue: profileID), client: client) ? nil : .denied
			}
			guard let current = automationSettings(change.edit.section, client: client)
			else { return .invalidRequest }
			guard current.revision == change.expectedRevision else { return .staleTarget }

			do throws(AutomationFailure) {
				_ = try automationSettingsPlan(change.edit, client: client)
				return nil
			} catch {
				return error
			}
		}
	}

	/// Where Air Traffic Control would open the URL, without opening anything. A matching
	/// rule or fallback outside the grant is reported without its destination.
	internal func automationRouteTest(
		_ url: URL,
		sourceSpaceID: UUID?,
		client: AutomationClient
	) -> AutomationRouteTest {
		let routing = persistedPreferences.routing
		let decision = URLRouter.decide(
			url,
			preferences: routing,
			organization: workspace,
			currentSpaceID: sourceSpaceID.map(Space.ID.init(rawValue:)),
			recentSpaceIDs: recentSpaceIDs
		)
		let rule = decision.matchedRuleID.flatMap { id in routing.rules.first { $0.id == id } }
		if let rule, !automationPermitsRule(rule, client: client) {
			return .init(outcome: "hiddenRule")
		}
		guard case let .success(target) = decision.result else {
			return .init(outcome: "unresolved", ruleID: rule?.id, ruleName: rule?.name)
		}
		guard AutomationAccess.permitsSpace(target.spaceID, client: client, organization: workspace) else {
			return .init(outcome: "ungrantedDestination", ruleID: rule?.id, ruleName: rule?.name)
		}
		return .init(
			outcome: rule == nil ? "fallback" : "rule",
			ruleID: rule?.id,
			ruleName: rule?.name,
			profileID: target.profileID.rawValue,
			spaceID: target.spaceID.rawValue,
			mode: target.mode
		)
	}

	/// What a change leaves in preferences, and the Settings actions that make it so,
	/// in the order the Settings window would send them.
	internal func automationSettingsPlan(
		_ edit: AutomationSettingsEdit,
		client: AutomationClient
	) throws(AutomationFailure) -> (expected: BrowserPreferences, actions: [SettingsFeature.Action.UI]) {
		var preferences = persistedPreferences
		var actions: [SettingsFeature.Action.UI] = []
		let rules = preferences.routing.rules

		func visibleRuleIndex(_ id: UUID) throws(AutomationFailure) -> Int {
			guard let index = rules.firstIndex(where: { $0.id == id }) else { throw .staleTarget }
			guard automationPermitsRule(rules[index], client: client) else { throw .denied }
			return index
		}
		func shortcutIndex(_ keyword: String) throws(AutomationFailure) -> Int {
			let id = keyword.lowercased()
			guard let index = preferences.searchShortcuts.firstIndex(where: { $0.id == id })
			else { throw .staleTarget }
			return index
		}

		switch edit {
		case let .undoPreferences(operationID):
			// Another client's change isn't this one's to undo, and one already undone is gone.
			guard let change = automation.preferenceChange(operationID, clientID: client.id) else { throw .staleTarget }

			// Something else changed these preferences since: putting them back would undo that too.
			guard change.after.allSatisfy({ $0.key.value(in: preferences) == $0.value }) else { throw .staleTarget }

			return try automationSettingsPlan(.setPreferences(change.before), client: client)

		case let .setPreferences(values):
			// Only the keys agents can read: none a feature flag hides with its row.
			let flags = settings.featureFlags
			let keys = MainActor.assumeIsolated { SettingsCategory.agentPreferenceKeys(flags) }
			guard values.allSatisfy({ keys.contains($0.key) }) else { throw .invalidRequest }

			do {
				preferences = try preferences.applying(values)
			} catch {
				throw .invalidValue
			}
			for setting in values where !setting.key.isAppearance {
				switch (setting.key, setting.value) {
				case let (.warnsBeforeQuitting, .bool(value)): actions.append(.warnsBeforeQuitting(value))
				case let (.globalLittleArxEnabled, .bool(value)): actions.append(.globalLittleArxEnabled(value))
				case let (.automaticPictureInPicture, .bool(value)): actions.append(.automaticPictureInPicture(value))
				case let (.closesPictureInPictureOnReturn, .bool(value)): actions.append(.closesPictureInPictureOnReturn(value))
				case let (.hoverPreviewsEnabled, .bool(value)): actions.append(.hoverPreviewsEnabled(value))
				case let (.switchesToLinkTabs, .bool(value)): actions.append(.switchesToLinkTabs(value))
				case let (.fetchesUnloadedSiteIcons, .bool(value)): actions.append(.fetchesUnloadedSiteIcons(value))
				case let (.showsLinkStatus, .bool(value)): actions.append(.showsLinkStatus(value))
				case (.darkPages, _): actions.append(.darkPages(preferences.darkPages))
				case let (.soundsEnabled, .bool(value)): actions.append(.soundsEnabled(value))
				case let (.restoresWindowsAtStartup, .bool(value)): actions.append(.restoresWindowsAtStartup(value))
				case let (.opensEmptyPageAtLaunch, .bool(value)): actions.append(.opensEmptyPageAtLaunch(value))
				case let (.showsUnreadBadges, .bool(value)): actions.append(.showsUnreadBadges(value))
				case let (.hapticsEnabled, .bool(value)): actions.append(.hapticsEnabled(value))
				case let (.keepsPinnedTabsLoaded, .bool(value)): actions.append(.keepsPinnedTabsLoaded(value))
				case (.protectedMediaPlayback, _):
					actions.append(.protectedMediaPlayback(preferences.webKitPages.protectedMedia))
				case let (.widevineAnswer, .bool(value)): actions.append(.widevineAnswer(value))
				case (.newTabPlacement, _): actions.append(.newTabPlacement(preferences.newTabPlacement))
				case (.openedTabPlacement, _): actions.append(.openedTabPlacement(preferences.openedTabPlacement))
				case (.appTheme, _): actions.append(.appTheme(preferences.appTheme))
				case (.sidebarPosition, _): actions.append(.sidebarPosition(preferences.sidebarPosition))
				case (.hoverPageDetails, _), (.fullHoverPreviews, _), (.shiftHoverLoadsPages, _):
					actions.append(.hoverPreviewSources(preferences.hoverPreviewSources))
				case (.littleArxLinkBinding, _): actions.append(.littleArxLinkBinding(preferences.littleArxLinkBinding))
				case (.shiftClickLinkAction, _): actions.append(.shiftClickLinkAction(preferences.shiftClickLinkAction))
				case (.forceClickLinkAction, _): actions.append(.forceClickLinkAction(preferences.forceClickLinkAction))
				case (.crossSiteLinkFromFavorites, _):
					actions.append(.crossSiteLinkFromFavorites(preferences.crossSiteLinkFromFavorites))
				case (.crossSiteLinkFromPinnedTabs, _):
					actions.append(.crossSiteLinkFromPinnedTabs(preferences.crossSiteLinkFromPinnedTabs))
				case (.littleArxLauncherPosition, _):
					actions.append(.littleArxLauncherPosition(preferences.littleArxLauncherPosition))
				case (.runwayAppearance, _):
					actions.append(.runwayAppearance(preferences.runwayAppearance))
				case (.identityCardStyle, _):
					// Settings only cycles the style; cycle until it is the chosen one.
					var style = persistedPreferences.identityCardStyle
					while style != preferences.identityCardStyle {
						actions.append(.cycleIdentityCardStyle)
						style = style.next
					}
				default:
					throw .invalidValue
				}
			}
			if values.contains(where: \.key.isAppearance) {
				actions.append(.chromeAppearance(preferences.chromeAppearance))
			}

		case let .saveRoutingRule(value):
			var rule = value.rule
			guard AutomationAccess.permitsRoutingDestination(rule.destination, client: client, organization: workspace)
			else { throw .denied }

			// Ask has no space to check: the person picks one when a link arrives.
			if rule.destination.scope != .ask {
				do {
					_ = try URLRouter.resolve(
						rule.destination,
						preferences: preferences.routing,
						organization: workspace,
						currentSpaceID: workspace.spaces.first?.id
					)
				} catch {
					throw .routeUnresolved
				}
			}
			if rules.contains(where: { $0.id == rule.id }) {
				let index = try visibleRuleIndex(rule.id)
				rule.isEnabled = rules[index].isEnabled
				preferences.routing.rules[index] = rule
			} else {
				rule.isEnabled = true
				preferences.routing.rules.append(rule)
			}
			let editor = RoutingEditor(
				name: rule.name,
				host: rule.host,
				includesSubdomains: rule.includesSubdomains,
				scheme: rule.scheme ?? "",
				port: rule.port.map(String.init) ?? "",
				pathPrefix: rule.pathPrefix ?? "",
				destination: rule.destination,
				editingID: rule.id,
				testURL: settings.routing.testURL
			)

			// The user's own draft in the routing editor comes back afterwards.
			actions += [.routing(.changed(editor)), .routing(.save(workspace)), .routing(.changed(settings.routing))]

		case let .deleteRoutingRule(id):
			preferences.routing.rules.remove(at: try visibleRuleIndex(id))
			actions.append(.routing(.delete(id)))

		case let .moveRoutingRule(id, offset):
			let index = try visibleRuleIndex(id)
			let neighbour = index + offset
			guard rules.indices.contains(neighbour) else { throw .invalidRequest }

			// Never reorder around a rule the client can't see.
			guard automationPermitsRule(rules[neighbour], client: client) else { throw .denied }
			preferences.routing.rules.swapAt(index, neighbour)
			actions.append(.routing(.move(id, offset)))

		case let .setRoutingRuleEnabled(id, enabled):
			let index = try visibleRuleIndex(id)
			if rules[index].isEnabled != enabled {
				preferences.routing.rules[index].isEnabled = enabled
				actions.append(.routing(.toggle(id)))
			}

		case let .saveSearchShortcut(value, replacing):
			var shortcut = value
			let replaced = try replacing.map { keyword throws(AutomationFailure) in try shortcutIndex(keyword) }
			if let replaced {
				shortcut.isEnabled = preferences.searchShortcuts[replaced].isEnabled
				preferences.searchShortcuts.remove(at: replaced)
			}
			guard !preferences.searchShortcuts.contains(where: { $0.id == shortcut.id })
			else { throw .shortcutConflict }
			preferences.searchShortcuts.append(shortcut)
			do {
				try preferences.validate()
			} catch {
				throw .invalidValue
			}
			let replacedID = replacing?.lowercased()
			actions += replacedID.map { [.editShortcut($0)] } ?? []
			actions += [.draftChanged(shortcut), .saveShortcut]

			// The user's own draft in Settings comes back afterwards.
			// When the client replaced the shortcut being edited, the editor stays open on the
			// replacement, under its new keyword.
			if let editing = settings.editingKeyword {
				actions.append(.editShortcut(editing == replacedID ? shortcut.id : editing))
			} else if settings.isEditingShortcut {
				actions.append(.addShortcut)
			}
			actions.append(.draftChanged(settings.draft))

		case let .deleteSearchShortcut(keyword):
			preferences.searchShortcuts.remove(at: try shortcutIndex(keyword))
			actions.append(.deleteShortcut(keyword.lowercased()))

		case let .setSearchShortcutEnabled(keyword, enabled):
			let index = try shortcutIndex(keyword)
			if preferences.searchShortcuts[index].isEnabled != enabled {
				preferences.searchShortcuts[index].isEnabled = enabled
				actions.append(.toggleShortcut(keyword.lowercased()))
			}

		case let .setKeyboardShortcut(command, shortcut, replacesConflicts):
			if let shortcut {
				guard shortcut.isValid else { throw .invalidValue }
				guard !shortcut.isReserved else { throw .shortcutReserved }
			}
			let conflicts = shortcut.map { preferences.conflicts(for: $0, excluding: command) } ?? []
			if !conflicts.isEmpty, !replacesConflicts { throw .shortcutConflict }
			for conflict in conflicts { preferences.setShortcut(nil, for: conflict) }
			preferences.setShortcut(shortcut, for: command)
			actions.append(.assignKeyboardShortcut(command, shortcut))
			if !conflicts.isEmpty { actions.append(.replaceKeyboardShortcut) }

		case let .resetKeyboardShortcut(command, replacesConflicts):
			let conflicts = command.shortcut.map { preferences.conflicts(for: $0, excluding: command) } ?? []
			if !conflicts.isEmpty, !replacesConflicts { throw .shortcutConflict }
			actions.append(.resetKeyboardShortcut(command))
			if conflicts.isEmpty {
				preferences.keyboardShortcuts.removeAll { $0.command == command }
			} else {
				for conflict in conflicts { preferences.setShortcut(nil, for: conflict) }
				preferences.setShortcut(command.shortcut, for: command)
				actions.append(.replaceKeyboardShortcut)
			}

		case let .setShortcutConflictResolution(command, resolution):
			// As Settings' picker: none for a command that keeps its keys or has no ⌘ shortcut.
			guard command.offersConflictResolution(
				shortcuts: preferences.keyboardShortcuts.shortcuts(for: command),
				followsAllKeys: settings.followsAllShortcutKeys
			)
			else { throw .invalidValue }

			preferences.shortcutConflictChoices.setResolution(resolution, for: command)
			actions.append(.shortcutConflictResolutionChanged(command, resolution))

		case .setExtensionEnabled, .installExtension, .setSitePermission, .setSiteZoom:
			throw .invalidRequest
		}
		return (preferences, actions)
	}

	/// Rechecks a settings result at the last boundary before it leaves Arx.
	internal func automationSettingsResponseValidation(
		_ request: AutomationSettingsRequest,
		response: AutomationSettingsResult,
		client: AutomationClient
	) -> AutomationFailure? {
		guard
			client.allows(AutomationOperation.settings(request).requiredCapabilities),
			response.section == request.section,
			response.operationID == request.change?.operationID
		else { return .denied }

		if case let .testRoute(url, sourceSpaceID) = request.kind {
			guard response.route == automationRouteTest(url, sourceSpaceID: sourceSpaceID, client: client)
			else { return .staleTarget }
			return nil
		}
		if request.section.isProfileScoped {
			let profileID: UUID? = switch request.section {
			// An install whose listing couldn't be read again still names its profile.
			case .extensions: response.extensions?.profileID ?? response.installation?.profileID
			case .sitePermissions: response.sitePermissions?.profileID
			case .zoom: response.zoom?.profileID
			default: nil
			}
			let requested: UUID? = switch request.kind {
			case let .read(_, profileID): profileID
			case let .change(change): change.edit.profileID
			case .testRoute: nil
			}
			guard
				let profileID,
				profileID == requested,
				AutomationAccess.permitsProfile(.init(rawValue: profileID), client: client)
			else { return .denied }
			return nil
		}
		guard let current = automationSettings(request.section, client: client), current.revision == response.revision
		else { return .staleTarget }
		return nil
	}
}

extension BrowserAutomation {
	/// Answers a section read or route test from state, or reads a profile's extensions.
	internal func readSettings(
		_ id: UUID,
		client: AutomationClient,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			case let .settings(request) = pending.request.operation
		else { return .none }

		switch request.kind {
		case let .read(.extensions, profileID?):
			let profileID = Profile.ID(rawValue: profileID)
			state.automation.pending[id]?.executing = true
			return .run { [extensions] send in
				let result: AutomationResult
				do {
					let inventory = try await extensions.inspect(profileID)
					let canInstall = await extensions.isWebstoreImportAvailable
					result = .settings(.init(
						section: .extensions,
						revision: AppFeature.State.automationExtensionsRevision(inventory, client: client),
						extensions: .init(
							profileID: profileID.rawValue,
							items: inventory.extensions.map(AutomationExtensionItem.init),
							canInstall: canInstall
						)
					))
				} catch {
					result = .failure(Self.automationFailure(error))
				}
				await send(.automation(.event(.extensionsChanged(id, profileID, result))))
			}
			.cancellable(id: id)

		case let .read(section, profileID?) where section == .sitePermissions || section == .zoom:
			let profileID = Profile.ID(rawValue: profileID)
			state.automation.pending[id]?.executing = true
			return .run { [engine] send in
				let result: AutomationResult
				do throws(SiteSettingsFailure) {
					let settings = try await engine.siteSettings(profileID)
					result = .settings(AppFeature.State.automationSiteSettingsResult(
						section,
						profileID: profileID,
						settings: settings,
						client: client
					))
				} catch {
					result = .failure(Self.automationFailure(error))
				}
				await send(.automation(.event(.siteSettingsChanged(id, profileID, result))))
			}
			.cancellable(id: id)

		case let .read(section, _):
			guard let result = state.automationSettings(section, client: client)
			else { return finish(id, result: .failure(.invalidRequest), state: &state) }
			return finish(id, result: .settings(result), state: &state)

		case let .testRoute(url, sourceSpaceID):
			var result = state.automationSettings(.routing, client: client)
			result?.route = state.automationRouteTest(url, sourceSpaceID: sourceSpaceID, client: client)
			return finish(id, result: result.map(AutomationResult.settings) ?? .failure(.invalidRequest), state: &state)

		case .change:
			return finish(id, result: .failure(.invalidRequest), state: &state)
		}
	}

	/// Applies an approved change through the Settings feature's own actions, then reports
	/// the section once Settings holds exactly the expected preferences.
	internal func changeSettings(
		_ id: UUID,
		client: AutomationClient,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			case let .settings(request) = pending.request.operation,
			let change = request.change
		else { return .none }

		if case let .setExtensionEnabled(profileID, extensionID, enabled) = change.edit {
			return setExtensionEnabled(
				id,
				profileID: .init(rawValue: profileID),
				extensionID: extensionID,
				enabled: enabled,
				expectedRevision: change.expectedRevision,
				client: client,
				state: &state
			)
		}

		if case let .installExtension(profileID, extensionID) = change.edit {
			return installExtension(
				id,
				profileID: .init(rawValue: profileID),
				extensionID: extensionID,
				client: client,
				state: &state
			)
		}

		if let edit = change.edit.siteSettingsEdit, let profileID = change.edit.profileID {
			return changeSiteSettings(
				id,
				profileID: .init(rawValue: profileID),
				section: change.edit.section,
				edit: edit,
				expectedRevision: change.expectedRevision,
				client: client,
				state: &state
			)
		}

		let plan: (expected: BrowserPreferences, actions: [SettingsFeature.Action.UI])
		do throws(AutomationFailure) {
			plan = try state.automationSettingsPlan(change.edit, client: client)
		} catch {
			return finish(id, result: .failure(error), state: &state)
		}
		state.automation.pending[id]?.executing = true
		state.automation.pending[id]?.settlement = .preferences(plan.expected)

		// What undo puts back (DEV-1023): the keys as they were, for a change or an undo.
		if case let .setPreferences(values) = change.edit {
			let before = state.persistedPreferences
			state.automation.pending[id]?.preferencesBefore = values.map { setting in
				.init(key: setting.key, value: setting.key.value(in: before))
			}
		}
		let sent = plan.actions.map { Effect<Action>.send(.settings(.ui($0))) }
		return .concatenate(sent + [.send(.automation(.event(.managementSettled(id))))])
	}

	/// Reports a settled settings change with the section's new contents.
	internal func settingsSettled(
		_ id: UUID,
		request: AutomationSettingsRequest,
		state: inout State
	) -> Effect<Action> {
		let clients = state.automationPreferences.clients
		guard
			let pending = state.automation.pending[id],
			let change = request.change,
			let client = clients.first(where: { $0.id == pending.request.clientID }),
			var result = state.automationSettings(request.section, client: client)
		else { return finish(id, result: .failure(.denied), state: &state) }

		result.operationID = change.operationID
		state.recordPreferenceChange(change, pending: pending)
		switch change.edit {
		case let .saveRoutingRule(rule): result.targetID = rule.id.uuidString
		case let .saveSearchShortcut(shortcut, _): result.targetID = shortcut.keyword
		default: break
		}
		return finish(id, result: .settings(result), state: &state)
	}

	/// Enables or disables an extension through the same engine client Settings uses, against
	/// a fresh read of the profile's extensions, then refreshes Settings if it shows that profile.
	private func setExtensionEnabled(
		_ id: UUID,
		profileID: Profile.ID,
		extensionID: String,
		enabled: Bool,
		expectedRevision: String,
		client: AutomationClient,
		state: inout State
	) -> Effect<Action> {
		guard let operationID = state.automation.pending[id]?.request.operation.mutationID
		else { return .none }

		state.automation.pending[id]?.executing = true
		return .run { [extensions] send in
			let result: AutomationResult
			do {
				let current = try await extensions.inspect(profileID)
				guard AppFeature.State.automationExtensionsRevision(current, client: client) == expectedRevision
				else { throw AutomationFailure.staleTarget }
				guard let item = current.extensions.first(where: { $0.id == extensionID })
				else { throw AutomationFailure.staleTarget }

				let action: BrowserExtensionAction = enabled ? .enable : .disable
				let inventory: BrowserExtensionInventory
				if (item.state == .enabled) == enabled {
					inventory = current
				} else {
					inventory = try await extensions.manage(.init(inventory: current, extensionID: extensionID, action: action))
				}
				let canInstall = await extensions.isWebstoreImportAvailable
				result = .settings(.init(
					section: .extensions,
					revision: AppFeature.State.automationExtensionsRevision(inventory, client: client),
					extensions: .init(
						profileID: profileID.rawValue,
						items: inventory.extensions.map(AutomationExtensionItem.init),
						canInstall: canInstall
					),
					operationID: operationID,
					targetID: extensionID
				))
			} catch {
				result = .failure(Self.automationFailure(error))
			}
			await send(.automation(.event(.extensionsChanged(id, profileID, result))))
		}
		.cancellable(id: id)
	}

	/// Hands an `installExtension` to the Extensions sheet, whose review is the approval
	/// (DEV-951). The sheet's own load is the only read of the profile: another read would
	/// replace the authority the sheet holds for whatever the person does in it next.
	private func installExtension(
		_ id: UUID,
		profileID: Profile.ID,
		extensionID: String,
		client: AutomationClient,
		state: inout State
	) -> Effect<Action> {
		guard state.automation.pending[id]?.request.operation.mutationID != nil
		else { return .none }

		guard MainActor.assumeIsolated({ [extensions] in extensions.isWebstoreImportAvailable }) else {
			return finish(id, result: .failure(.installationUnavailable), state: &state)
		}
		guard state.workspace.profiles[id: profileID] != nil else {
			return finish(id, result: .failure(.staleTarget), state: &state)
		}
		guard !state.extensionsSheetIsBusy
		else { return finish(id, result: .failure(.busy), state: &state) }

		state.automation.pending[id]?.executing = true

		// The request must reach the sheet after it is presented for the profile (DEV-801).
		return .concatenate(
			SiteMenuRouting.openExtensions(profileID),
			.send(.settings(.extensions(.automationInstallRequested(.init(
				id: id,
				profileID: profileID,
				extensionID: extensionID,
				requester: client.name
			)))))
		)
	}

	/// Checks the extensions the sheet loaded against the request: a changed revision is
	/// stale, and an item the profile already has needs no review. Otherwise the sheet goes on.
	internal func extensionInstallInventoryLoaded(
		_ id: UUID,
		inventory: BrowserExtensionInventory,
		state: inout State
	) -> Effect<Action> {
		guard let (client, change, profileID, extensionID) = state.automationInstallRequest(id)
		else { return .none }

		let revision = AppFeature.State.automationExtensionsRevision(inventory, client: client)
		guard inventory.profileID.rawValue == profileID, revision == change.expectedRevision else {
			// Ending the request takes the install out of the sheet.
			return finish(id, result: .failure(.staleTarget), state: &state)
		}
		if let item = inventory.extensions.first(where: { $0.id == extensionID }) {
			let canInstall = MainActor.assumeIsolated { [extensions] in extensions.isWebstoreImportAvailable }
			return finish(id, result: .settings(.init(
				section: .extensions,
				revision: revision,
				extensions: .init(
					profileID: profileID,
					items: inventory.extensions.map(AutomationExtensionItem.init),
					canInstall: canInstall
				),
				installation: .init(
					profileID: profileID,
					extensionID: extensionID,
					outcome: .alreadyInstalled,
					name: item.name,
					version: item.version
				),
				operationID: change.operationID,
				targetID: extensionID
			)), state: &state)
		}
		return .send(.settings(.extensions(.automationInstallProceed(id))))
	}

	/// Reports how the review ended, with the profile's extensions as the sheet holds them.
	internal func extensionInstallFinished(
		_ id: UUID,
		outcome: ExtensionsFeature.AutomationInstallOutcome,
		inventory: BrowserExtensionInventory?,
		state: inout State
	) -> Effect<Action> {
		guard let (client, change, profileID, extensionID) = state.automationInstallRequest(id)
		else { return .none }

		let installation: AutomationExtensionInstallation
		switch outcome {
		case .busy:
			return finish(id, result: .failure(.busy), state: &state)
		case .unavailable:
			return finish(id, result: .failure(.installationUnavailable), state: &state)
		case let .installed(name, version):
			installation = .init(
				profileID: profileID,
				extensionID: extensionID,
				outcome: .installed,
				name: name,
				version: version
			)
		case let .declined(name, version):
			installation = .init(
				profileID: profileID,
				extensionID: extensionID,
				outcome: .declined,
				name: name,
				version: version
			)
		case let .alreadyInstalled(name, version):
			installation = .init(
				profileID: profileID,
				extensionID: extensionID,
				outcome: .alreadyInstalled,
				name: name,
				version: version
			)
		case let .failed(failure, name, version):
			installation = .init(
				profileID: profileID,
				extensionID: extensionID,
				outcome: .failed,
				name: name,
				version: version,
				reason: Self.installationFailureReason(failure)
			)
		}

		var result = AutomationSettingsResult(
			section: .extensions,
			revision: "",
			installation: installation,
			operationID: change.operationID,
			targetID: extensionID
		)
		if let inventory, inventory.profileID.rawValue == profileID {
			result.revision = AppFeature.State.automationExtensionsRevision(inventory, client: client)
			result.extensions = .init(
				profileID: profileID,
				items: inventory.extensions.map(AutomationExtensionItem.init),
				canInstall: MainActor.assumeIsolated { [extensions] in extensions.isWebstoreImportAvailable }
			)
		}
		return finish(id, result: .settings(result), state: &state)
	}

	/// The extensions client's failure as `installExtension` reports it.
	internal static func installationFailureReason(_ failure: BrowserExtensionsClient.Failure) -> String {
		switch failure {
		case let .invalidManifest(detail): "invalidManifest: \(detail)"
		default: String(describing: failure)
		}
	}

	/// Every engine read replaces the extension authority Settings holds, so a Settings
	/// list showing the profile reads again before the result goes out.
	internal func extensionsChanged(
		_ id: UUID,
		profileID: Profile.ID,
		result: AutomationResult,
		state: inout State
	) -> Effect<Action> {
		let extensions = state.settings.extensions
		let refresh: Effect<Action> = extensions.isPresented && extensions.profile?.id == profileID
		? .send(.settings(.extensions(.ui(.refresh))))
		: .none
		return .merge(refresh, finish(id, result: result, state: &state))
	}

	/// Applies a site-settings edit through the same engine client the Settings sheet uses,
	/// against a fresh read of the profile, then refreshes the sheet if it shows that profile.
	private func changeSiteSettings(
		_ id: UUID,
		profileID: Profile.ID,
		section: AutomationSettingsRequest.Section,
		edit: SiteSettingsEdit,
		expectedRevision: String,
		client: AutomationClient,
		state: inout State
	) -> Effect<Action> {
		guard let operationID = state.automation.pending[id]?.request.operation.mutationID
		else { return .none }

		state.automation.pending[id]?.executing = true
		return .run { [engine] send in
			let result: AutomationResult
			do {
				let current = try await engine.siteSettings(profileID)
				let before = AppFeature.State.automationSiteSettingsResult(
					section,
					profileID: profileID,
					settings: current,
					client: client
				)
				guard before.revision == expectedRevision else { throw AutomationFailure.staleTarget }

				// A truncated listing can't prove a row is absent, so the engine decides.
				let settings = current.holds(edit) && !current.isTruncated
				? current
				: try await engine.changeSiteSettings(profileID, edit)
				var after = AppFeature.State.automationSiteSettingsResult(
					section,
					profileID: profileID,
					settings: settings,
					client: client
				)
				after.operationID = operationID
				switch edit {
				case let .setPermission(origin, permission, _): after.targetID = (origin ?? "default") + " " + permission.rawValue
				case let .setZoom(host, _): after.targetID = host ?? "default"
				case let .setContentBlocking(origin, _): after.targetID = origin + " contentBlocking"
				}
				result = .settings(after)
			} catch {
				result = .failure(Self.automationFailure(error))
			}
			await send(.automation(.event(.siteSettingsChanged(id, profileID, result))))
		}
		.cancellable(id: id)
	}

	/// A Settings sheet showing the profile reads it again before the result goes out.
	internal func siteSettingsChanged(
		_ id: UUID,
		profileID: Profile.ID,
		result: AutomationResult,
		state: inout State
	) -> Effect<Action> {
		let refresh: Effect<Action> = state.settings.siteSettings?.profileID == profileID
		? .send(.settings(.siteSettings(.ui(.refresh))))
		: .none
		return .merge(refresh, finish(id, result: result, state: &state))
	}

	private static func automationFailure(_ error: any Error) -> AutomationFailure {
		if let failure = error as? AutomationFailure { return failure }
		if let failure = error as? SiteSettingsFailure {
			switch failure {
			case .invalid: return .invalidValue
			case .managed, .unavailable: return .unsupported
			case .failed: return .engineFailed
			}
		}
		switch error as? BrowserExtensionsClient.Failure {
		case .staleInventory?, .missingProfile?: return .staleTarget
		case .busy?: return .busy
		case .timeout?: return .timedOut
		case .reviewRequired?, .blockedByPolicy?, .unavailable?: return .unsupported
		case .cancelled?: return .cancelled
		default: return .engineFailed
		}
	}
}

extension AppFeature.State {
	/// Keeps a settled agent preference change for `undo`, or forgets the one an undo put back
	/// (DEV-1023).
	fileprivate mutating func recordPreferenceChange(
		_ change: AutomationSettingsChange,
		pending: AutomationState.Pending
	) {
		switch change.edit {
		case let .setPreferences(values):
			guard let before = pending.preferencesBefore else { return }

			// As Settings stored them, which may normalize a value, such as a hue of 360 to 0.
			let after = values.map { setting in
				AutomationPreferenceSetting(key: setting.key, value: setting.key.value(in: persistedPreferences))
			}
			automation.preferenceChanges.append(.init(
				operationID: change.operationID,
				clientID: pending.request.clientID,
				before: before,
				after: after
			))
			automation.preferenceChanges = Array(automation.preferenceChanges.suffix(AutomationState.preferenceChangeLimit))

		case let .undoPreferences(operationID):
			let clientID = pending.request.clientID
			automation.preferenceChanges.removeAll { change in
				change.clientID == clientID && change.operationID == UUID(uuidString: operationID)
			}

		default:
			return
		}
	}
}
