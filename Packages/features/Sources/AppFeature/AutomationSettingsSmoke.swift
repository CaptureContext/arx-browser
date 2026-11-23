#if DEBUG
import BrowserCore
import Foundation
import _ComposableArchitecture
import _MCP

/// Reads and changes Settings and a space's appearance through the bundled MCP helper,
/// then puts every value back.
@MainActor
internal enum AutomationSettingsSmoke {
	internal static func run(
		store: StoreOf<AppFeature>,
		session: () throws -> AutomationSmokeSession,
		client: AutomationClient,
		profileID: Profile.ID,
		spaceID: Space.ID
	) async throws {
		var granted = client
		granted.scopes += [.profile(profileID)]
		granted.capabilities.remove(.browserAdmin)
		granted.mutationGrantUntil = Date().addingTimeInterval(90)
		await store.send(.automation(.ui(.updateClient(granted)))).finish()
		try await wait("sessions closed after the grant change") { store.automation.sessions.isEmpty }

		// Without browser admin a direct call is denied before anything is read.
		let unclassed = try session()
		try await unclassed.connect(grantedBy: store.automationPreferences)
		let refused = try await unclassed.settings(["action": .string("read"), "section": .string("preferences")])
		guard refused == .failure(.denied)
		else { throw AutomationSmokeMismatch(.authorizationFailed, check: "mcpSettings.unclassedRead", expected: "denied", actual: "\(refused)") }
		guard await unclassed.close() else { throw AutomationSmokeFailure.helperFailed }

		granted.capabilities.insert(.browserAdmin)
		await store.send(.automation(.ui(.updateClient(granted)))).finish()
		try await wait("sessions closed after granting browser admin") { store.automation.sessions.isEmpty }
		let session = try session()
		try await session.connect(grantedBy: store.automationPreferences)

		let original = store.settings.general.warnsBeforeQuitting
		let read = try await session.settings(["action": .string("read"), "section": .string("preferences")])
		guard
			case let .settings(section) = read,
			section.preferences?.first(where: { $0.key == .warnsBeforeQuitting })?.value == .bool(original)
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.read", expected: "the allowlisted preferences", actual: "\(read)") }

		// The temporary grant covers the change; Settings holds it once the result comes back.
		let changed = try await session.settings(setPreference(!original, revision: section.revision))
		guard
			case let .settings(after) = changed,
			after.operationID != nil,
			store.settings.general.warnsBeforeQuitting == !original
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.setPreferences", expected: "Settings changed", actual: "\(changed)") }
		print("ARX_MCP_SETTINGS_PHASE_CHANGED")

		let stale = try await session.settings(setPreference(original, revision: section.revision))
		guard stale == .failure(.staleTarget), store.settings.general.warnsBeforeQuitting == !original
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.staleRevision", expected: "staleTarget", actual: "\(stale)") }

		let restored = try await session.settings(setPreference(original, revision: after.revision))
		guard case .settings = restored, store.settings.general.warnsBeforeQuitting == original
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.restore", expected: "the original value", actual: "\(restored)") }

		var protected = setPreference(original, revision: after.revision)
		protected["values"] = .object(["developerModeEnabled": .bool(true)])
		let protectedResult = try await session.settings(protected)
		guard protectedResult == .failure(.protectedSetting), !store.settings.general.developerModeEnabled
		else { throw AutomationSmokeMismatch(.authorizationFailed, check: "mcpSettings.protected", expected: "protectedSetting", actual: "\(protectedResult)") }

		guard case let .settings(keyboard) = try await session.settings([
			"action": .string("read"),
			"section": .string("keyboardShortcuts"),
		]) else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.keyboardRead", expected: "keyboard shortcuts", actual: "missing") }
		let shortcuts = store.settings.keyboardShortcuts
		let conflict = try await session.settings([
			"action": .string("setKeyboardShortcut"),
			"operationID": .string(UUID().uuidString),
			"expectedRevision": .string(keyboard.revision),
			"command": .string(BrowserCommand.newTab.rawValue),
			"shortcut": .object(["key": .string("k"), "modifiers": .array([.string("command")])]),
		])
		guard conflict == .failure(.shortcutConflict), store.settings.keyboardShortcuts == shortcuts
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.shortcutConflict", expected: "shortcutConflict", actual: "\(conflict)") }
		print("ARX_MCP_SETTINGS_PHASE_REFUSED")

		let previous = store.workspace.spaces[id: spaceID]?.appearance
		try await setAppearance(
			["appearance": .object(["tintHue": .int(200), "grainEnabled": .bool(false)])],
			spaceID: spaceID,
			in: session
		)
		guard
			store.workspace.spaces[id: spaceID]?.appearance?.tintHue == 200,
			store.workspace.spaces[id: spaceID]?.appearance?.grainEnabled == false
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.spaceAppearance", expected: "tint 200 without grain", actual: "\(String(describing: store.workspace.spaces[id: spaceID]?.appearance))") }

		try await setAppearance(restoring: previous, spaceID: spaceID, in: session)
		guard store.workspace.spaces[id: spaceID]?.appearance == previous
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.spaceAppearanceRestore", expected: "\(String(describing: previous))", actual: "\(String(describing: store.workspace.spaces[id: spaceID]?.appearance))") }

		try await siteSettings(store: store, profileID: profileID, in: session)
		try await profileData(store: store, profileID: profileID)
		guard await session.close() else { throw AutomationSmokeFailure.helperFailed }

		print("ARX_MCP_SETTINGS_NATIVE_SMOKE_SUCCESS")
	}

	/// DEV-716: a site permission and a site zoom through MCP reach the profile's Site
	/// Settings sheet at once, a stale revision is refused, and both are removed again.
	private static func siteSettings(
		store: StoreOf<AppFeature>,
		profileID: Profile.ID,
		in session: AutomationSmokeSession
	) async throws {
		let origin = "https://site-settings.arx-smoke.example"
		let host = "zoom.arx-smoke.example"
		await store.send(.settings(.ui(.showSiteSettings(profileID)))).finish()
		guard store.settings.siteSettings?.profileID == profileID
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.siteSettingsSheet", expected: "the profile's sheet", actual: "missing") }
		store.send(.settings(.siteSettings(.ui(.appeared))))
		try await wait("site settings loaded") { store.settings.siteSettings?.isLoading == false }

		func read(_ section: String) async throws -> AutomationSettingsResult {
			let result = try await session.settings([
				"action": .string("read"),
				"section": .string(section),
				"profileID": .string(profileID.rawValue.uuidString),
			])
			guard case let .settings(value) = result
			else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.\(section)Read", expected: "the section", actual: "\(result)") }
			return value
		}
		func permission(
			_ setting: Value,
			revision: String
		) -> [String: Value] {
			[
				"action": .string("setSitePermission"),
				"operationID": .string(UUID().uuidString),
				"expectedRevision": .string(revision),
				"profileID": .string(profileID.rawValue.uuidString),
				"origin": .string(origin),
				"permission": .string("camera"),
				"setting": setting,
			]
		}
		func zoom(
			_ factor: Value,
			revision: String
		) -> [String: Value] {
			[
				"action": .string("setSiteZoom"),
				"operationID": .string(UUID().uuidString),
				"expectedRevision": .string(revision),
				"profileID": .string(profileID.rawValue.uuidString),
				"host": .string(host),
				"factor": factor,
			]
		}

		let permissions = try await read("sitePermissions")
		let blocked = try await session.settings(permission(.string("block"), revision: permissions.revision))
		guard case let .settings(afterBlock) = blocked, afterBlock.sitePermissions?.sites.contains(where: { $0.origin == origin }) == true
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.setSitePermission", expected: "camera blocked", actual: "\(blocked)") }
		try await wait("Settings shows the blocked camera") {
			store.settings.siteSettings?.settings.exception(origin: origin, permission: .camera)?.setting == .block
		}
		let stale = try await session.settings(permission(.null, revision: permissions.revision))
		guard stale == .failure(.staleTarget)
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.sitePermissionStale", expected: "staleTarget", actual: "\(stale)") }
		let removed = try await session.settings(permission(.null, revision: afterBlock.revision))
		guard case .settings = removed
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.removeSitePermission", expected: "removed", actual: "\(removed)") }
		try await wait("Settings drops the camera") {
			store.settings.siteSettings?.settings.exception(origin: origin, permission: .camera) == nil
		}

		let zooms = try await read("zoom")
		let zoomed = try await session.settings(zoom(.double(1.5), revision: zooms.revision))
		guard case let .settings(afterZoom) = zoomed, afterZoom.zoom?.sites.contains(.init(host: host, factor: 1.5)) == true
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.setSiteZoom", expected: "150%", actual: "\(zoomed)") }
		try await wait("Settings shows the zoom") { store.settings.siteSettings?.settings.zoom(for: host) == 1.5 }
		let unzoomed = try await session.settings(zoom(.null, revision: afterZoom.revision))
		guard case .settings = unzoomed
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.removeSiteZoom", expected: "removed", actual: "\(unzoomed)") }
		try await wait("Settings drops the zoom") { store.settings.siteSettings?.settings.zoom(for: host) == nil }

		await store.send(.settings(.ui(.siteSettingsPresented(false)))).finish()
		print("ARX_MCP_SETTINGS_PHASE_SITE_SETTINGS")
	}

	/// DEV-647: the profile's downloads folder round-trips "Ask where to save" through
	/// the engine, and Clear Browsing Data counts with the engine and clears site
	/// settings from the last hour, closing its sheet.
	private static func profileData(
		store: StoreOf<AppFeature>,
		profileID: Profile.ID
	) async throws {
		await store.send(.settings(.ui(.loadDownloadSettings(profileID)))).finish()
		try await wait("downloads folder read") { store.settings.downloadSettings[profileID] != nil }
		guard let original = store.settings.downloadSettings[profileID], !original.asksWhereToSave
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "settingsProfileData.downloads", expected: "a folder, not asking", actual: "\(String(describing: store.settings.downloadSettings[profileID]))") }
		await store.send(.settings(.ui(.asksWhereToSave(profileID, true)))).finish()
		try await wait("ask where to save on") { store.settings.downloadSettings[profileID]?.asksWhereToSave == true }
		await store.send(.settings(.ui(.asksWhereToSave(profileID, false)))).finish()
		try await wait("ask where to save off") { store.settings.downloadSettings[profileID]?.asksWhereToSave == false }
		guard store.settings.downloadSettings[profileID]?.directory == original.directory
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "settingsProfileData.folderKept", expected: "\(original.directory)", actual: "\(String(describing: store.settings.downloadSettings[profileID]))") }

		await store.send(.settings(.ui(.showClearBrowsingData(profileID)))).finish()
		guard store.settings.clearBrowsingData?.profileID == profileID
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "settingsProfileData.clearSheet", expected: "the profile's sheet", actual: "missing") }
		store.send(.settings(.clearBrowsingData(.ui(.appeared))))
		try await wait("browsing data counted") { store.settings.clearBrowsingData?.isCounting == false }
		guard
			let counts = store.settings.clearBrowsingData?.counts,
			counts.cookieSites != nil,
			counts.cacheBytes != nil,
			counts.siteSettingsSites != nil
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "settingsProfileData.counts", expected: "engine counts", actual: "\(String(describing: store.settings.clearBrowsingData?.counts))") }
		for kind in BrowsingDataKind.allCases {
			await store.send(.settings(.clearBrowsingData(.ui(.kindToggled(kind, kind == .siteSettings))))).finish()
		}
		store.send(.settings(.clearBrowsingData(.ui(.clear))))
		try await wait("clear browsing data finished") { store.settings.clearBrowsingData == nil }
		print("ARX_MCP_SETTINGS_PHASE_PROFILE_DATA")
	}

	private static func setPreference(
		_ warns: Bool,
		revision: String
	) -> [String: Value] {
		[
			"action": .string("setPreferences"),
			"operationID": .string(UUID().uuidString),
			"expectedRevision": .string(revision),
			"values": .object(["warnsBeforeQuitting": .bool(warns)]),
		]
	}

	private static func setAppearance(
		restoring appearance: AppearanceOverride?,
		spaceID: Space.ID,
		in session: AutomationSmokeSession
	) async throws {
		var fields: [String: Value] = [:]
		if let theme = appearance?.theme { fields["theme"] = .string(theme.rawValue) }
		if let hue = appearance?.tintHue { fields["tintHue"] = .double(hue) }
		if let intensity = appearance?.tintIntensity { fields["tintIntensity"] = .double(intensity) }
		if let enabled = appearance?.grainEnabled { fields["grainEnabled"] = .bool(enabled) }
		if let intensity = appearance?.grainIntensity { fields["grainIntensity"] = .double(intensity) }
		if let size = appearance?.grainSize { fields["grainSize"] = .double(size) }
		if let accent = appearance?.accent { fields["accentColor"] = .string(accent.hex) }
		if let matchesSite = appearance?.matchesSite { fields["matchesSite"] = .bool(matchesSite) }
		if let gradient = appearance?.gradient {
			fields["gradient"] = gradient.stops.isEmpty
			? .string("plain")
			: .object([
				"stops": .array(gradient.stops.map { .object(["hue": .double($0.hue), "intensity": .double($0.intensity)]) }),
				"angle": .double(gradient.angle),
			])
		}
		var arguments: [String: Value] = ["clearAppearance": .bool(true)]
		if !fields.isEmpty { arguments["appearance"] = .object(fields) }
		try await setAppearance(arguments, spaceID: spaceID, in: session)
	}

	private static func setAppearance(
		_ arguments: [String: Value],
		spaceID: Space.ID,
		in session: AutomationSmokeSession
	) async throws {
		guard
			case let .inventory(inventory) = try await session.inventory(),
			let space = inventory.items.first(where: { $0.kind == .space && $0.id == spaceID.rawValue })
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.spaceItem", expected: "the granted space", actual: "missing") }

		let result = try AutomationSmokeResponse.decode(try await session.rawCall(
			"browser_spaces",
			arguments: arguments.merging([
				"action": .string(AutomationCommand.Action.setSpaceAppearance.rawValue),
				"operationID": .string(UUID().uuidString),
				"targetID": .string(space.id.uuidString),
				"expectedRevision": .string(space.revision),
			]) { $1 }
		))
		guard case let .command(command) = result, command.status == .committed
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpSettings.setSpaceAppearance", expected: "committed", actual: "\(result)") }
	}

	private static func wait(
		_ site: String,
		timeout: Duration = .seconds(10),
		_ condition: @MainActor () async -> Bool
	) async throws {
		let start = ContinuousClock.now
		while !(await condition()) {
			guard ContinuousClock.now - start < timeout
			else { throw SmokeDiagnostics.timeout(site: "AutomationSettingsSmoke.\(site)", since: start, state: "") }

			try await Task.sleep(for: .milliseconds(50))
		}
	}
}

extension AutomationSmokeSession {
	/// Calls `browser_settings`; a section decodes as settings, anything else as the other tools do.
	internal func settings(_ arguments: [String: Value]) async throws -> AutomationResult {
		let result = try await rawCall("browser_settings", arguments: arguments)
		guard
			result.isError != true,
			let structured = result.structuredContent,
			let envelope = try? JSONDecoder().decode(
				SettingsEnvelope.self,
				from: JSONEncoder().encode(structured)
			),
			envelope.untrustedData
		else { return try AutomationSmokeResponse.decode(result) }

		return .settings(envelope.result)
	}

	private struct SettingsEnvelope: Decodable {
		fileprivate let untrustedData: Bool
		fileprivate let result: AutomationSettingsResult
	}
}
#endif
