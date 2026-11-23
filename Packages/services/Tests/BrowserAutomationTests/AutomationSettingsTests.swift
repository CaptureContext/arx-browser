import BrowserAutomationClient
import BrowserCore
import BrowserMCPServer
import CustomDump
import Foundation
import Testing
import _MCP

internal struct AutomationSettingsTests {
	private static let revision: String = .init(repeating: "a", count: 64)

	private static func change(
		_ action: String,
		_ arguments: [String: Value] = [:]
	) -> [String: Value] {
		arguments.merging([
			"action": .string(action),
			"operationID": .string(UUID().uuidString),
			"expectedRevision": .string(revision),
		]) { $1 }
	}

	private static func edit(_ arguments: [String: Value]) throws -> AutomationSettingsEdit? {
		guard case let .settings(request) = try AutomationTools.operation(name: "browser_settings", arguments: arguments)
		else { return nil }
		return request.change?.edit
	}

	@Test
	internal func settingsNeedBrowserAdminAndChangesAreMutations() throws {
		expectNoDifference(AutomationTools.requiredCapabilities(forTool: "browser_settings"), [.read, .browserAdmin])
		#expect(!AutomationTools.definitions(for: .init(capabilities: [.read, .organize])).map(\.name).contains("browser_settings"))
		#expect(AutomationTools.definitions(for: .init(capabilities: [.read, .browserAdmin])).map(\.name).contains("browser_settings"))

		let read = try AutomationTools.operation(
			name: "browser_settings",
			arguments: ["action": .string("read"), "section": .string("routing")]
		)
		expectNoDifference(read.requiredCapabilities, [.read, .browserAdmin])
		expectNoDifference(read.riskTier, .read)
		#expect(read.mutationID == nil)

		let set = try AutomationTools.operation(
			name: "browser_settings",
			arguments: Self.change("setPreferences", ["values": .object(["warnsBeforeQuitting": .bool(false)])])
		)
		expectNoDifference(set.riskTier, .mutate)
		#expect(set.mutationID != nil)
		let delete = try AutomationTools.operation(
			name: "browser_settings",
			arguments: Self.change("deleteSearchShortcut", ["keyword": .string("w")])
		)
		expectNoDifference(delete.riskTier, .destructive)

		// Changes never ride on a batch approval.
		#expect(throws: AutomationFailure.self) {
			try AutomationBatchPlan(batchID: UUID(), steps: [set]).validate()
		}
	}

	@Test
	internal func preferenceValuesFollowEachKeysSchema() throws {
		expectNoDifference(
			try Self.edit(Self.change("setPreferences", [
				"values": .object([
					"warnsBeforeQuitting": .bool(false),
					"forceClickLinkAction": .string("newTab"),
					"shiftClickLinkAction": .string("littleArx"),
					"crossSiteLinkFromFavorites": .string("currentTab"),
					"grainSize": .int(2),
				]),
			])),
			.setPreferences([
				.init(key: .crossSiteLinkFromFavorites, value: .string("currentTab")),
				.init(key: .forceClickLinkAction, value: .string("newTab")),
				.init(key: .grainSize, value: .number(2)),
				.init(key: .shiftClickLinkAction, value: .string("littleArx")),
				.init(key: .warnsBeforeQuitting, value: .bool(false)),
			])
		)

		let refused: [(String, Value, AutomationFailure)] = [
			("warnsBeforeQuitting", .string("no"), .invalidValue),
			("forceClickLinkAction", .string("sideways"), .invalidValue),
			// The switches these choices replaced (DEV-1239) are no longer settings.
			("shiftClickLinkAction", .bool(false), .invalidValue),
			("shiftClickLinkAction", .string("currentTab"), .invalidValue),
			("crossSiteLinkFromFavorites", .string("newWindow"), .invalidValue),
			("crossSiteLinkFromPinnedTabs", .bool(true), .invalidValue),
			("shiftClickPeekEnabled", .bool(false), .invalidRequest),
			("crossSitePeekFromPinnedTabs", .bool(true), .invalidRequest),
			("grainSize", .double(3.5), .invalidValue),
			("tintHue", .double(-1), .invalidValue),
			("tintIntensity", .bool(true), .invalidValue),
			("developerModeEnabled", .bool(true), .protectedSetting),
			("automation", .object([:]), .protectedSetting),
			("noSuchPreference", .bool(true), .invalidRequest),
		]
		for (key, value, failure) in refused {
			#expect(throws: failure, "\(key)") {
				try AutomationTools.operation(
					name: "browser_settings",
					arguments: Self.change("setPreferences", ["values": .object([key: value])])
				)
			}
		}
		for key in AutomationPreferenceKey.allCases {
			#expect(!AutomationPreferenceKey.protectedNames.contains(key.rawValue))
		}
	}

	@Test
	internal func preferencesApplyAsSettingsStoresThem() throws {
		let preferences = try BrowserPreferences().applying([
			.init(key: .tintHue, value: .number(360)),
			.init(key: .grainEnabled, value: .bool(false)),
			.init(key: .littleArxLauncherPosition, value: .string("center")),
			.init(key: .runwayAppearance, value: .string("compact")),
			.init(key: .automaticPictureInPicture, value: .bool(true)),
		])

		// A full turn of the hue is stored as 0, as the Settings appearance editor stores it.
		expectNoDifference(preferences.chromeTint.hue, 0)
		#expect(!preferences.grainEnabled)
		expectNoDifference(preferences.littleArxLauncherPosition, .center)
		expectNoDifference(preferences.runwayAppearance, .compact)
		#expect(preferences.automaticPictureInPicture.isEnabled)

		#expect(throws: AutomationFailure.invalidValue) {
			try BrowserPreferences().applying([.init(key: .grainIntensity, value: .number(2))])
		}
		#expect(throws: AutomationFailure.invalidValue) {
			try BrowserPreferences().applying([.init(key: .identityCardStyle, value: .string("unknown"))])
		}
	}

	@Test
	internal func keyboardShortcutsParseAndRefuseReservedChords() throws {
		expectNoDifference(
			try Self.edit(Self.change("setKeyboardShortcut", [
				"command": .string("newTab"),
				"shortcut": .object(["key": .string("Y"), "modifiers": .array([.string("command"), .string("shift")])]),
			])),
			.setKeyboardShortcut(.newTab, .init(key: "y", modifiers: [.command, .shift]), replacesConflicts: false)
		)
		expectNoDifference(
			try Self.edit(Self.change("setKeyboardShortcut", [
				"command": .string("newTab"),
				"shortcut": .null,
				"replace": .bool(true),
			])),
			.setKeyboardShortcut(.newTab, nil, replacesConflicts: true)
		)
		expectNoDifference(
			try Self.edit(Self.change("resetKeyboardShortcut", ["command": .string("reload")])),
			.resetKeyboardShortcut(.reload, replacesConflicts: false)
		)
		// Conflict resolution (DEV-1332).
		expectNoDifference(
			try Self.edit(Self.change("setShortcutConflictResolution", [
				"command": .string("findInPage"),
				"resolution": .string("delayed"),
			])),
			.setShortcutConflictResolution(.findInPage, .delayed)
		)
		#expect(throws: AutomationFailure.invalidRequest) {
			try Self.edit(Self.change("setShortcutConflictResolution", [
				"command": .string("findInPage"),
				"resolution": .string("page"),
			]))
		}
		#expect(throws: AutomationFailure.shortcutReserved) {
			try Self.edit(Self.change("setKeyboardShortcut", [
				"command": .string("newTab"),
				"shortcut": .object(["key": .string("c"), "modifiers": .array([.string("command")])]),
			]))
		}

		// A chord needs command or control, and modifier names are an exact list.
		#expect(throws: AutomationFailure.invalidValue) {
			try Self.edit(Self.change("setKeyboardShortcut", [
				"command": .string("newTab"),
				"shortcut": .object(["key": .string("k"), "modifiers": .array([.string("shift")])]),
			]))
		}
		#expect(throws: AutomationFailure.invalidRequest) {
			try Self.edit(Self.change("setKeyboardShortcut", [
				"command": .string("newTab"),
				"shortcut": .object(["key": .string("k"), "modifiers": .array([.string("hyper")])]),
			]))
		}
		#expect(throws: AutomationFailure.invalidRequest) {
			try Self.edit(Self.change("setKeyboardShortcut", ["command": .string("newTab")]))
		}
	}

	@Test
	internal func routingRulesSearchShortcutsAndExtensionsParse() throws {
		let ruleID = UUID()
		let spaceID = UUID()
		expectNoDifference(
			try Self.edit(Self.change("saveRoutingRule", [
				"rule": .object([
					"id": .string(ruleID.uuidString),
					"name": .string("Docs"),
					"host": .string("docs.capturecontext.dev"),
					"pathPrefix": .string("/api"),
					"destination": .object([
						"scope": .string("space"),
						"id": .string(spaceID.uuidString),
						"mode": .string("littleArx"),
					]),
				]),
			])),
			.saveRoutingRule(.init(
				id: ruleID,
				name: "Docs",
				host: "docs.capturecontext.dev",
				pathPrefix: "/api",
				destination: .init(scope: .space, id: spaceID, mode: .littleArx)
			))
		)

		// A new rule gets an ID from the helper; currentSpace takes no ID.
		guard case let .saveRoutingRule(created)? = try Self.edit(Self.change("saveRoutingRule", [
			"rule": .object([
				"name": .string("Mail"),
				"host": .string("mail.capturecontext.dev"),
				"destination": .object(["scope": .string("currentSpace")]),
			]),
		])) else {
			Issue.record("No rule")
			return
		}
		expectNoDifference(created.destination, .init(scope: .currentSpace, mode: .mainBrowser))
		#expect(throws: AutomationFailure.self) {
			try Self.edit(Self.change("saveRoutingRule", [
				"rule": .object([
					"name": .string("Mail"),
					"host": .string("mail.capturecontext.dev"),
					"destination": .object(["scope": .string("currentSpace"), "id": .string(spaceID.uuidString)]),
				]),
			]))
		}
		#expect(throws: AutomationFailure.invalidValue) {
			try Self.edit(Self.change("saveRoutingRule", [
				"rule": .object([
					"name": .string("Bad"),
					"host": .string("mail.capturecontext.dev"),
					"pathPrefix": .string("no-slash"),
					"destination": .object(["scope": .string("currentSpace")]),
				]),
			]))
		}
		#expect(throws: AutomationFailure.invalidRequest) {
			try Self.edit(Self.change("moveRoutingRule", ["ruleID": .string(ruleID.uuidString), "offset": .int(2)]))
		}

		expectNoDifference(
			try Self.edit(Self.change("saveSearchShortcut", [
				"shortcut": .object([
					"keyword": .string("cc"),
					"name": .string("CaptureContext"),
					"template": .string("https://capturecontext.dev/search?q={query}"),
				]),
				"replacing": .string("old"),
			])),
			.saveSearchShortcut(
				.init(name: "CaptureContext", keyword: "cc", template: "https://capturecontext.dev/search?q={query}"),
				replacing: "old"
			)
		)
		#expect(throws: AutomationFailure.invalidValue) {
			try Self.edit(Self.change("saveSearchShortcut", [
				"shortcut": .object([
					"keyword": .string("cc"),
					"name": .string("No query"),
					"template": .string("https://capturecontext.dev/search"),
				]),
			]))
		}

		let profileID = UUID()
		let extensionID = String(repeating: "a", count: 32)
		expectNoDifference(
			try Self.edit(Self.change("setExtensionEnabled", [
				"profileID": .string(profileID.uuidString),
				"extensionID": .string(extensionID),
				"enabled": .bool(false),
			])),
			.setExtensionEnabled(profileID: profileID, extensionID: extensionID, false)
		)
		#expect(throws: AutomationFailure.invalidRequest) {
			try Self.edit(Self.change("setExtensionEnabled", [
				"profileID": .string(profileID.uuidString),
				"extensionID": .string("not-an-extension"),
				"enabled": .bool(false),
			]))
		}

		// Only the extensions section names a profile.
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(
				name: "browser_settings",
				arguments: ["action": .string("read"), "section": .string("extensions")]
			)
		}
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(
				name: "browser_settings",
				arguments: ["action": .string("read"), "section": .string("routing"), "profileID": .string(profileID.uuidString)]
			)
		}

		// Changes need an operation ID and the section's revision.
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationTools.operation(
				name: "browser_settings",
				arguments: ["action": .string("deleteSearchShortcut"), "keyword": .string("w")]
			)
		}
	}

	@Test
	internal func installExtensionTakesAStoreIDOrItemPage() throws {
		let profileID = UUID()
		let id = String(repeating: "b", count: 32)
		let install = AutomationSettingsEdit.installExtension(profileID: profileID, extensionID: id)
		for arguments: [String: Value] in [
			["extensionID": .string(id)],
			["url": .string("https://chromewebstore.google.com/detail/store-item/\(id)")],
			["url": .string("https://chromewebstore.google.com/detail/\(id)?hl=en")],
			["url": .string("https://chrome.google.com/webstore/detail/store-item/\(id)")],
		] {
			expectNoDifference(
				try Self.edit(Self.change("installExtension", arguments.merging(["profileID": .string(profileID.uuidString)]) { $1 })),
				install
			)
		}

		// Not a store item, or both or neither of extensionID and url.
		for url in [
			"http://chromewebstore.google.com/detail/store-item/\(id)",
			"https://chromewebstore.google.com.example/detail/store-item/\(id)",
			"https://chromewebstore.google.com/search/\(id)",
			"https://chromewebstore.google.com/detail/a/b/\(id)",
			"https://user@chromewebstore.google.com/detail/store-item/\(id)",
			"https://chromewebstore.google.com/detail/store-item/" + String(repeating: "z", count: 32),
		] {
			#expect(throws: AutomationFailure.invalidValue, "\(url)") {
				try Self.edit(Self.change("installExtension", ["profileID": .string(profileID.uuidString), "url": .string(url)]))
			}
		}
		#expect(throws: AutomationFailure.invalidValue) {
			try Self.edit(Self.change("installExtension", ["profileID": .string(profileID.uuidString), "extensionID": .string(String(repeating: "q", count: 32))]))
		}
		#expect(throws: AutomationFailure.invalidRequest) {
			try Self.edit(Self.change("installExtension", [
				"profileID": .string(profileID.uuidString),
				"extensionID": .string(id),
				"url": .string("https://chromewebstore.google.com/detail/\(id)"),
			]))
		}
		#expect(throws: AutomationFailure.invalidRequest) {
			try Self.edit(Self.change("installExtension", ["profileID": .string(profileID.uuidString)]))
		}
		#expect(throws: AutomationFailure.invalidRequest) {
			try Self.edit(Self.change("installExtension", ["extensionID": .string(id)]))
		}
	}

	@Test
	internal func installExtensionAlwaysAsksInTheReviewAndIsNeverBatched() throws {
		let operation = try AutomationTools.operation(
			name: "browser_settings",
			arguments: Self.change("installExtension", [
				"profileID": .string(UUID().uuidString),
				"extensionID": .string(String(repeating: "b", count: 32)),
			])
		)
		#expect(operation.alwaysAsks && operation.asksInExtensionReview)
		expectNoDifference(operation.riskTier, .mutate)
		#expect(operation.mutationID != nil)
		#expect(throws: AutomationFailure.self) {
			try AutomationBatchPlan(batchID: UUID(), steps: [operation]).validate()
		}

		let enable = try AutomationTools.operation(
			name: "browser_settings",
			arguments: Self.change("setExtensionEnabled", [
				"profileID": .string(UUID().uuidString),
				"extensionID": .string(String(repeating: "b", count: 32)),
				"enabled": .bool(true),
			])
		)
		#expect(!enable.alwaysAsks && !enable.asksInExtensionReview)
	}

	@Test
	internal func sitePermissionsAndZoomParse() throws {
		let profileID = UUID()
		let profile: [String: Value] = ["profileID": .string(profileID.uuidString)]
		expectNoDifference(
			try Self.edit(Self.change("setSitePermission", profile.merging([
				"origin": .string("Meet.Example/room"),
				"permission": .string("camera"),
				"setting": .string("block"),
			]) { $1 })),
			.setSitePermission(profileID: profileID, origin: "https://meet.example", .camera, .block)
		)

		// No origin is the profile's default; null removes a site's own setting.
		expectNoDifference(
			try Self.edit(Self.change("setSitePermission", profile.merging([
				"permission": .string("notifications"),
				"setting": .string("block"),
			]) { $1 })),
			.setSitePermission(profileID: profileID, origin: nil, .notifications, .block)
		)
		expectNoDifference(
			try Self.edit(Self.change("setSitePermission", profile.merging([
				"origin": .string("https://[*.]example.com"),
				"permission": .string("popups"),
				"setting": .null,
			]) { $1 })),
			.setSitePermission(profileID: profileID, origin: "https://[*.]example.com", .popups, nil)
		)
		expectNoDifference(
			try Self.edit(Self.change("setSiteZoom", profile.merging([
				"host": .string("https://Docs.Example/a"),
				"factor": .double(1.5),
			]) { $1 })),
			.setSiteZoom(profileID: profileID, host: "docs.example", factor: 1.5)
		)
		expectNoDifference(
			try Self.edit(Self.change("setSiteZoom", profile.merging(["factor": .int(2)]) { $1 })),
			.setSiteZoom(profileID: profileID, host: nil, factor: 2)
		)

		let refused: [(AutomationFailure, [String: Value])] = [
			// Pop-ups have no prompt to ask with.
			(.invalidValue, ["permission": .string("popups"), "origin": .string("a.example"), "setting": .string("ask")]),
			// A default never allows a permission that prompts.
			(.invalidValue, ["permission": .string("camera"), "setting": .string("allow")]),
			(.invalidValue, ["permission": .string("camera"), "origin": .string("javascript:alert(1)"), "setting": .string("allow")]),
			(.invalidValue, ["permission": .string("camera"), "origin": .string("a.example"), "setting": .string("sometimes")]),
			(.invalidRequest, ["permission": .string("midi"), "origin": .string("a.example"), "setting": .string("allow")]),
			(.invalidRequest, ["permission": .string("camera"), "origin": .string("a.example")]),
		]
		for (failure, arguments) in refused {
			#expect(throws: failure, "\(arguments)") {
				try Self.edit(Self.change("setSitePermission", profile.merging(arguments) { $1 }))
			}
		}
		#expect(throws: AutomationFailure.invalidValue) {
			try Self.edit(Self.change("setSiteZoom", profile.merging(["host": .string("a.example"), "factor": .double(8)]) { $1 }))
		}
		#expect(throws: AutomationFailure.invalidRequest) {
			try Self.edit(Self.change("setSiteZoom", profile.merging(["host": .string("a.example")]) { $1 }))
		}
		#expect(throws: AutomationFailure.invalidRequest) {
			try Self.edit(Self.change("setSiteZoom", ["factor": .double(1.5)]))
		}

		// Both sections belong to one profile.
		for section in ["sitePermissions", "zoom"] {
			#expect(throws: AutomationFailure.invalidRequest) {
				try AutomationTools.operation(
					name: "browser_settings",
					arguments: ["action": .string("read"), "section": .string(section)]
				)
			}
			guard case let .settings(request) = try AutomationTools.operation(
				name: "browser_settings",
				arguments: ["action": .string("read"), "section": .string(section), "profileID": .string(profileID.uuidString)]
			) else {
				Issue.record("No settings read for \(section)")
				continue
			}
			expectNoDifference(request.section.rawValue, section)
		}
	}

	@Test
	internal func bindingsCoverEveryChangedValue() throws {
		func binding(_ value: Bool) -> String? {
			AutomationSecurity.mutationBinding(.settings(.init(.change(.init(
				operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
				expectedRevision: Self.revision,
				edit: .setPreferences([.init(key: .warnsBeforeQuitting, value: .bool(value))])
			)))))
		}
		#expect(binding(true) != nil)
		#expect(binding(true) == binding(true))
		#expect(binding(true) != binding(false))
		#expect(AutomationSecurity.mutationBinding(.settings(.init(.read(.routing, profileID: nil)))) == nil)

		func appearance(_ change: AutomationAppearanceChange) -> String? {
			AutomationSecurity.mutationBinding(.command(.init(
				operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
				action: .setSpaceAppearance,
				targetID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
				expectedRevision: Self.revision,
				appearance: change
			)))
		}
		let inherits = AutomationAppearanceChange(inherit: [.tintHue, .grainSize, .theme])
		expectNoDifference(appearance(inherits), appearance(.init(inherit: [.theme, .grainSize, .tintHue])))
		#expect(appearance(.init(set: .init(tintHue: 10))) != appearance(.init(set: .init(tintHue: 20))))
	}

	@Test
	internal func appearanceArgumentsChooseInheritOrClear() throws {
		func command(
			_ tool: String,
			_ action: String,
			_ extra: [String: Value]
		) throws -> AutomationCommand? {
			let arguments: [String: Value] = [
				"operationID": .string(UUID().uuidString),
				"action": .string(action),
				"targetID": .string(UUID().uuidString),
				"expectedRevision": .string(Self.revision),
			].merging(extra) { $1 }
			guard case let .command(command) = try AutomationTools.operation(name: tool, arguments: arguments)
			else { return nil }
			return command
		}

		let space = try command("browser_spaces", "setSpaceAppearance", [
			"appearance": .object([
				"tintHue": .int(200),
				"tintIntensity": .double(0.5),
				"grainEnabled": .null,
				"theme": .string("system"),
			]),
		])
		expectNoDifference(
			space?.appearance,
			.init(set: .init(tintHue: 200, tintIntensity: 0.5), inherit: [.grainEnabled, .theme])
		)
		let cleared = try command("browser_profiles", "setProfileAppearance", ["clearAppearance": .bool(true)])
		expectNoDifference(cleared?.appearance, .init(clearsAll: true))

		let refused: [[String: Value]] = [
			[:],
			["appearance": .object([:])],
			["appearance": .object(["tintHue": .int(361)])],
			["appearance": .object(["grainSize": .double(0.5)])],
			["appearance": .object(["tintIntensity": .double(1.5)])],
			["appearance": .object(["theme": .string("sepia")])],
			["appearance": .object(["shadow": .bool(true)])],
		]
		for extra in refused {
			#expect(throws: AutomationFailure.self, "\(extra)") {
				try command("browser_profiles", "setProfileAppearance", extra)
			}
		}

		// Appearance belongs to the appearance actions only.
		#expect(throws: AutomationFailure.self) {
			try command("browser_spaces", "renameSpace", ["name": .string("A"), "appearance": .object(["tintHue": .int(1)])])
		}

		let applied = AutomationAppearanceChange(
			set: .init(theme: .dark, tintHue: 360),
			inherit: [.grainSize]
		).applied(to: .init(tintIntensity: 0.7, grainSize: 2))
		expectNoDifference(applied, .init(theme: .dark, tintHue: 0, tintIntensity: 0.7))
		expectNoDifference(
			AutomationAppearanceChange(set: .init(grainEnabled: false), clearsAll: true)
				.applied(to: .init(tintIntensity: 0.7)),
			.init(grainEnabled: false)
		)

		let resolved = AutomationResolvedAppearance(
			global: .default,
			profile: .init(theme: .dark, tintHue: 10),
			space: .init(tintHue: 120)
		)
		expectNoDifference(resolved.theme, "dark")
		expectNoDifference(resolved.tintHue, 120)
		expectNoDifference(resolved.tintIntensity, ChromeTint.default.intensity)
	}

	/// DEV-1134: the accent, Match site and gradient, as Settings and a space's Appearance offer them.
	@Test
	internal func appearanceArgumentsTakeAccentMatchSiteAndGradient() throws {
		func command(_ extra: [String: Value]) throws -> AutomationCommand? {
			let arguments: [String: Value] = [
				"operationID": .string(UUID().uuidString),
				"action": .string("setSpaceAppearance"),
				"targetID": .string(UUID().uuidString),
				"expectedRevision": .string(Self.revision),
			].merging(extra) { $1 }
			guard case let .command(command) = try AutomationTools.operation(name: "browser_spaces", arguments: arguments)
			else { return nil }
			return command
		}

		let chosen = try command([
			"appearance": .object([
				"accentColor": .string("teal"),
				"matchesSite": .bool(true),
				"gradient": .object([
					"stops": .array([.object(["hue": .int(30), "intensity": .double(0.5)])]),
					"angle": .int(90),
				]),
			]),
		])
		expectNoDifference(
			chosen?.appearance,
			.init(set: .init(
				gradient: .init(stops: [.init(hue: 30, intensity: 0.5)], angle: 90),
				matchesSite: true,
				accent: ChromeAccent.Preset.teal.accent
			))
		)

		let custom = try command(["appearance": .object(["accentColor": .string("#336699"), "gradient": .string("plain")])])
		expectNoDifference(custom?.appearance?.set.accent, .init(red: 0.2, green: 0.4, blue: 0.6))
		expectNoDifference(custom?.appearance?.set.gradient, .plain)

		let inherits = try command(["appearance": .object(["accentColor": .null, "matchesSite": .null, "gradient": .null])])
		expectNoDifference(inherits?.appearance, .init(inherit: [.accentColor, .matchesSite, .gradient]))

		let refused: [[String: Value]] = [
			["appearance": .object(["accentColor": .string("automatic")])],
			["appearance": .object(["accentColor": .string("#33669")])],
			["appearance": .object(["accentColor": .bool(true)])],
			["appearance": .object(["matchesSite": .string("yes")])],
			["appearance": .object(["gradient": .string("rainbow")])],
			["appearance": .object(["gradient": .object(["stops": .array([.object(["hue": .int(400), "intensity": .double(0.5)])])])])],
			["appearance": .object(["gradient": .object(["stops": .array([.object(["hue": .int(10)])])])])],
			[
				"appearance": .object(["gradient": .object(["stops": .array(Array(
					repeating: .object(["hue": .int(10), "intensity": .double(0.5)]),
					count: 3
				))])]),
			],
		]
		for extra in refused {
			#expect(throws: AutomationFailure.self, "\(extra)") {
				try command(extra)
			}
		}

		// Inheriting a field drops just that choice, and the others stay.
		let current = AppearanceOverride(tintHue: 10, matchesSite: true, accent: ChromeAccent.Preset.red.accent)
		expectNoDifference(
			AutomationAppearanceChange(inherit: [.accentColor]).applied(to: current),
			.init(tintHue: 10, matchesSite: true)
		)

		let resolved = AutomationResolvedAppearance(
			global: .init(accent: ChromeAccent.Preset.green.accent),
			profile: .init(matchesSite: true, accent: ChromeAccent.Preset.red.accent),
			space: .init(gradient: .init(stops: [.init(hue: 200, intensity: 0.4)]))
		)
		expectNoDifference(resolved.accentColor, "red")
		#expect(resolved.matchesSite)
		expectNoDifference(resolved.gradient?.stops, [.init(hue: 200, intensity: 0.4)])
		let automatic = AutomationResolvedAppearance(global: .default, profile: nil, space: nil)
		expectNoDifference(automatic.accentColor, "automatic")
		#expect(!automatic.matchesSite)
		#expect(automatic.gradient == nil)
	}

	/// DEV-1170: agents choose Match site at all three levels: the preferences' browser default,
	/// and on, off or inherit for a profile or space. Off survives the trip, since it's no longer
	/// what nothing chosen means.
	@Test
	internal func matchSiteRoundTripsAtEveryLevel() throws {
		let preference = try Self.edit(Self.change("setPreferences", ["values": .object(["matchesSite": .bool(true)])]))
		expectNoDifference(preference, .setPreferences([.init(key: .matchesSite, value: .bool(true))]))
		guard case let .setPreferences(settings) = preference else { throw AutomationFailure.invalidRequest }
		let preferences = try BrowserPreferences().applying(settings)
		#expect(preferences.chromeMatchesSite)

		func appearance(_ matchesSite: Value) throws -> AutomationAppearanceChange? {
			let arguments: [String: Value] = [
				"operationID": .string(UUID().uuidString),
				"action": .string("setSpaceAppearance"),
				"targetID": .string(UUID().uuidString),
				"expectedRevision": .string(Self.revision),
				"appearance": .object(["matchesSite": matchesSite]),
			]
			guard case let .command(command) = try AutomationTools.operation(name: "browser_spaces", arguments: arguments)
			else { return nil }
			return command.appearance
		}

		// Off, through the command's encoding as an approval or undo keeps it, onto a space saved
		// with it on.
		let off = try #require(try appearance(.bool(false)))
		let decoded = try JSONDecoder().decode(AutomationAppearanceChange.self, from: JSONEncoder().encode(off))
		let saved = try JSONDecoder().decode(AppearanceOverride.self, from: Data(#"{"matchesSite":true}"#.utf8))
		let space = decoded.applied(to: saved)
		expectNoDifference(space, .init(matchesSite: false))
		let stored = try JSONDecoder().decode(AppearanceOverride.self, from: JSONEncoder().encode(space))
		expectNoDifference(stored, space)
		let resolvedOff = AutomationResolvedAppearance(global: preferences.chromeAppearance, profile: nil, space: stored)
		#expect(!resolvedOff.matchesSite)

		// Null goes back to the browser default.
		let inherit = try #require(try appearance(.null))
		expectNoDifference(inherit, .init(inherit: [.matchesSite]))
		let inherited = AutomationResolvedAppearance(
			global: preferences.chromeAppearance,
			profile: nil,
			space: inherit.applied(to: stored)
		)
		#expect(inherited.matchesSite)
	}

	@Test
	internal func inventoryReportsOwnAppearanceOverrides() {
		var organization = BrowserAutomationTests.organization()
		organization.profiles[0].appearance = .init(tintHue: 30)
		organization.spaces[0].appearance = .init(grainEnabled: false)
		var client = BrowserAutomationTests.client(organization)
		client.scopes = [.profile(organization.profiles[0].id)]
		let items = AutomationInventoryBuilder.items(client: client, organization: organization, snapshots: [:])
		expectNoDifference(items.first { $0.kind == .profile }?.appearance, .init(tintHue: 30))
		expectNoDifference(items.first { $0.id == organization.spaces[0].id.rawValue }?.appearance, .init(grainEnabled: false))
		let profiles = AutomationInventoryBuilder.profiles(client: client, organization: organization, items: items)
		expectNoDifference(profiles.first?.appearance, .init(tintHue: 30))
	}
}
