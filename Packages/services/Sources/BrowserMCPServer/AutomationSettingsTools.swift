import BrowserCore
import Foundation
import _MCP

extension AutomationTools {
	/// The `browser_settings` actions besides the edits: a section read and the Air Traffic Control tester.
	internal static let settingsReadActions: [String] = ["read", "testRoute"]

	internal static let settingsEditActions: [String] = [
		"setPreferences",
		"saveRoutingRule",
		"deleteRoutingRule",
		"moveRoutingRule",
		"setRoutingRuleEnabled",
		"saveSearchShortcut",
		"deleteSearchShortcut",
		"setSearchShortcutEnabled",
		"setKeyboardShortcut",
		"resetKeyboardShortcut",
		"setShortcutConflictResolution",
		"setExtensionEnabled",
		"installExtension",
		"setSitePermission",
		"setSiteZoom",
		"undo",
	]

	internal static var settingsDefinition: Tool {
		.init(
			name: "browser_settings",
			title: "Read and change Arx settings",
			description: """
			Needs the browser admin class. read returns one section with its revision: preferences (an allowlist, \
			each with its type, choices or range), routing (Air Traffic Control rules in order and the fallback; \
			rules sending links to profiles or spaces outside this grant are left out and counted in hiddenRules), \
			searchShortcuts, keyboardShortcuts (every command, with isDefault, conflictResolution and \
			conflictResolutionIsFixed), or one profile's extensions, \
			sitePermissions (each permission's default with its choices, and each site's own settings) or zoom \
			(the default page zoom and each host's, as factors where 1 is 100%); these three take profileID, \
			need a whole-profile grant and refuse private profiles. testRoute reports where Air Traffic Control would open url \
			(sourceSpaceID: the granted space current-space rules use) without opening anything. \
			Every other action changes the section through the same steps as Arx Settings, so Settings updates \
			at once; it needs a fresh operationID and the section's revision as expectedRevision (staleTarget \
			when it changed), asks the user unless their approval policy skips it, can't be a batch step and \
			returns the section's new contents and revision. The preferences section also lists rows: every row \
			Settings' search finds, with id, title, path and access: agent (keys names the preferences it \
			changes, or section the section that edits it), user (only the person changes it: privacy, \
			security, passwords, accounts, AI, permissions, system and resource limits) or ui (nothing to \
			set). setPreferences takes values, an object of keys from the preferences section; developer mode, \
			security and automation access are never readable or writable (protectedSetting). undo takes \
			undoOperationID, the operationID of your own earlier setPreferences, and puts those preferences \
			back while they still hold what it set (staleTarget otherwise); its expectedRevision is the \
			preferences section's. saveRoutingRule takes rule {id (omit to create), name, host, \
			includesSubdomains, scheme, port, pathPrefix, destination {scope currentSpace, ask, profile (its \
			most recent space) or space, id for profile and space, mode mainBrowser or littleArx}}; the destination must be granted. deleteRoutingRule, \
			moveRoutingRule (offset -1 or 1) and setRoutingRuleEnabled (enabled) take ruleID. \
			saveSearchShortcut takes shortcut {keyword, name, template with {query}, homepage} and replacing \
			(the keyword it replaces); deleteSearchShortcut and setSearchShortcutEnabled take keyword. \
			setKeyboardShortcut takes command and shortcut {key, modifiers: command, option, shift, control} \
			or null to remove it; a shortcut another command uses reports shortcutConflict unless replace is \
			true, which takes it from that command; editing keys macOS keeps report shortcutReserved. \
			resetKeyboardShortcut restores the default under the same rule. setShortcutConflictResolution takes \
			command and resolution: arx (Arx runs the command; the page never sees the keys), site (the page \
			gets the keys; the command runs only if the page doesn't use them), both (the page gets the keys; \
			pressed again within 1 to 2 seconds they run the command) or delayed (Arx holds the keys for 1 to \
			2 seconds: pressed again they run the command, otherwise the page gets them); invalidValue for a \
			command whose conflictResolutionIsFixed. \
			setExtensionEnabled takes profileID, \
			extensionID and enabled; an extension whose new permissions wait for review can only be enabled \
			by the user in Arx. installExtension takes profileID and a Chrome Web Store item as extensionID \
			(its 32-letter ID) or url (its chromewebstore.google.com page), and is offered when the extensions \
			section's canInstall is true (otherwise installationUnavailable). It always opens the profile's \
			Extensions sheet with Arx's install review, which shows the verified package, its permissions and \
			your name, whatever the approval policy; it waits for the user's answer, can't run unattended \
			(userActionRequired) and reports installation.outcome: installed, declined, alreadyInstalled \
			(no review) or failed with installation.reason. setSitePermission takes profileID, permission (camera, microphone, location, \
			notifications, popups or clipboard), origin (an http(s) site such as https://meet.google.com; omit \
			it to change the profile's default) and setting (allow, block or ask; popups take no ask, a default \
			takes ask or block, and popups allow or block; null removes the site's own setting). Allowing a site \
			anything but pop-ups always asks the user, whatever their approval policy. setSiteZoom takes \
			profileID, host (omit it for the default zoom) and factor (0.25 to 5, or null to remove the host's \
			zoom). A setting policy, an extension or supervision decides reports unsupported.
			""",
			inputSchema: schema(
				properties: [
					"action": .object([
						"type": .string("string"),
						"enum": .array((settingsReadActions + settingsEditActions).map(Value.string)),
					]),
					"section": .object([
						"type": .string("string"),
						"enum": .array(AutomationSettingsRequest.Section.allCases.map { .string($0.rawValue) }),
					]),
					"profileID": string(maximum: 36),
					"url": string(maximum: 4096),
					"sourceSpaceID": string(maximum: 36),
					"operationID": string(maximum: 36),
					"undoOperationID": string(maximum: 36),
					"expectedRevision": string(maximum: 64),
					"values": .object([
						"type": .string("object"),
						"minProperties": .int(1),
						"maxProperties": .int(AutomationPreferenceKey.allCases.count),
					]),
					"rule": .object(["type": .string("object")]),
					"ruleID": string(maximum: 36),
					"offset": .object(["type": .string("integer"), "enum": .array([.int(-1), .int(1)])]),
					"enabled": .object(["type": .string("boolean")]),
					"shortcut": .object(["type": .array([.string("object"), .string("null")])]),
					"replacing": string(maximum: 64),
					"keyword": string(maximum: 64),
					"command": .object([
						"type": .string("string"),
						"enum": .array(BrowserCommand.allCases.map { .string($0.rawValue) }),
					]),
					"replace": .object(["type": .string("boolean")]),
					"resolution": .object([
						"type": .string("string"),
						"enum": .array(ShortcutConflictResolution.allCases.map { .string($0.rawValue) }),
					]),
					"extensionID": string(maximum: 32),
					"origin": string(maximum: 2048),
					"permission": .object([
						"type": .string("string"),
						"enum": .array(SitePermission.allCases.map { .string($0.rawValue) }),
					]),
					"setting": .object([
						"type": .array([.string("string"), .string("null")]),
						"enum": .array(SitePermissionSetting.allCases.map { .string($0.rawValue) } + [.null]),
					]),
					"host": string(maximum: 2048),
					"factor": .object([
						"type": .array([.string("number"), .string("null")]),
						"minimum": .double(SiteSettings.zoomRange.lowerBound),
						"maximum": .double(SiteSettings.zoomRange.upperBound),
					]),
				],
				required: ["action"]
			),
			annotations: .init(
				readOnlyHint: false,
				destructiveHint: true,
				idempotentHint: false,
				openWorldHint: false
			)
		)
	}

	internal static func settingsOperation(_ arguments: [String: Value]) throws -> AutomationOperation {
		guard let action = try optionalString("action", in: arguments, maximum: 32)
		else { throw AutomationFailure.invalidRequest }

		func keys(_ allowed: Set<String>) throws {
			guard Set(arguments.keys).isSubset(of: allowed.union(["action"]))
			else { throw AutomationFailure.invalidRequest }
		}
		func uuid(_ key: String) throws -> UUID? {
			guard let text = try optionalString(key, in: arguments, maximum: 36) else { return nil }
			guard let id = UUID(uuidString: text) else { throw AutomationFailure.invalidRequest }
			return id
		}
		func required<Value>(_ value: Value?) throws -> Value {
			guard let value else { throw AutomationFailure.invalidRequest }
			return value
		}
		func flag(_ key: String) throws -> Bool {
			guard let value = arguments[key]?.boolValue
			else { throw AutomationFailure.invalidRequest }
			return value
		}

		let request: AutomationSettingsRequest
		switch action {
		case "read":
			try keys(["section", "profileID"])
			let section = try required(
				try optionalString("section", in: arguments, maximum: 32)
					.flatMap(AutomationSettingsRequest.Section.init(rawValue:))
			)
			request = .init(.read(section, profileID: try uuid("profileID")))

		case "testRoute":
			try keys(["url", "sourceSpaceID"])
			let text = try required(try optionalString("url", in: arguments, maximum: 4096))
			let url = try required(URL(string: text, encodingInvalidCharacters: false))
			request = .init(.testRoute(url, sourceSpaceID: try uuid("sourceSpaceID")))

		default:
			let edit: AutomationSettingsEdit
			let common: Set<String> = ["operationID", "expectedRevision"]
			switch action {
			case "setPreferences":
				try keys(common.union(["values"]))
				edit = .setPreferences(try preferenceSettings(arguments["values"]))

			case "undo":
				try keys(common.union(["undoOperationID"]))
				edit = .undoPreferences(
					operationID: try required(try optionalString("undoOperationID", in: arguments, maximum: 36))
				)

			case "saveRoutingRule":
				try keys(common.union(["rule"]))
				edit = .saveRoutingRule(try routingRule(arguments["rule"]))

			case "deleteRoutingRule":
				try keys(common.union(["ruleID"]))
				edit = .deleteRoutingRule(try required(try uuid("ruleID")))

			case "moveRoutingRule":
				try keys(common.union(["ruleID", "offset"]))
				edit = .moveRoutingRule(try required(try uuid("ruleID")), offset: try required(arguments["offset"]?.intValue))

			case "setRoutingRuleEnabled":
				try keys(common.union(["ruleID", "enabled"]))
				edit = .setRoutingRuleEnabled(try required(try uuid("ruleID")), try flag("enabled"))

			case "saveSearchShortcut":
				try keys(common.union(["shortcut", "replacing"]))
				edit = .saveSearchShortcut(
					try searchShortcut(arguments["shortcut"]),
					replacing: try optionalString("replacing", in: arguments, maximum: 64)
				)

			case "deleteSearchShortcut":
				try keys(common.union(["keyword"]))
				edit = .deleteSearchShortcut(try required(try optionalString("keyword", in: arguments, maximum: 64)))

			case "setSearchShortcutEnabled":
				try keys(common.union(["keyword", "enabled"]))
				edit = .setSearchShortcutEnabled(
					try required(try optionalString("keyword", in: arguments, maximum: 64)),
					try flag("enabled")
				)

			case "setKeyboardShortcut", "resetKeyboardShortcut":
				let isReset = action == "resetKeyboardShortcut"
				try keys(common.union(isReset ? ["command", "replace"] : ["command", "shortcut", "replace"]))
				let command = try required(
					try optionalString("command", in: arguments, maximum: 64).flatMap(BrowserCommand.init(rawValue:))
				)
				let replaces = arguments["replace"] == nil ? false : try flag("replace")
				if isReset {
					edit = .resetKeyboardShortcut(command, replacesConflicts: replaces)
				} else {
					guard let value = arguments["shortcut"]
					else { throw AutomationFailure.invalidRequest }
					edit = .setKeyboardShortcut(command, try keyboardShortcut(value), replacesConflicts: replaces)
				}

			case "setShortcutConflictResolution":
				try keys(common.union(["command", "resolution"]))
				edit = .setShortcutConflictResolution(
					try required(
						try optionalString("command", in: arguments, maximum: 64).flatMap(BrowserCommand.init(rawValue:))
					),
					try required(
						try optionalString("resolution", in: arguments, maximum: 16)
							.flatMap(ShortcutConflictResolution.init(rawValue:))
					)
				)

			case "setExtensionEnabled":
				try keys(common.union(["profileID", "extensionID", "enabled"]))
				edit = .setExtensionEnabled(
					profileID: try required(try uuid("profileID")),
					extensionID: try required(try optionalString("extensionID", in: arguments, maximum: 32)),
					try flag("enabled")
				)

			case "installExtension":
				try keys(common.union(["profileID", "extensionID", "url"]))
				let id = try optionalString("extensionID", in: arguments, maximum: 32)
				let url = try optionalString("url", in: arguments, maximum: 2048)

				// Exactly one of them names the store item.
				guard (id == nil) != (url == nil) else { throw AutomationFailure.invalidRequest }
				guard let extensionID = BrowserWebstoreInstallRequest.extensionID(fromStoreReference: id ?? url ?? "")
				else { throw AutomationFailure.invalidValue }
				edit = .installExtension(profileID: try required(try uuid("profileID")), extensionID: extensionID)

			case "setSitePermission":
				try keys(common.union(["profileID", "origin", "permission", "setting"]))
				let permission = try required(
					try optionalString("permission", in: arguments, maximum: 32).flatMap(SitePermission.init(rawValue:))
				)
				let setting: SitePermissionSetting?
				switch arguments["setting"] {
				case .null?: setting = nil
				case let .string(text)?:
					guard let value = SitePermissionSetting(rawValue: text)
					else { throw AutomationFailure.invalidValue }
					setting = value
				default: throw AutomationFailure.invalidRequest
				}

				// Listed patterns wider than one origin are passed as they are, to be removed.
				let origin = try optionalString("origin", in: arguments, maximum: 2048).map { text in
					SiteSettings.origin(text) ?? text
				}
				edit = .setSitePermission(profileID: try required(try uuid("profileID")), origin: origin, permission, setting)

			case "setSiteZoom":
				try keys(common.union(["profileID", "host", "factor"]))
				let factor: Double?
				switch arguments["factor"] {
				case .null?: factor = nil
				case let value? where number(value) != nil: factor = number(value)
				default: throw AutomationFailure.invalidRequest
				}
				let host = try optionalString("host", in: arguments, maximum: 2048).map { text in
					SiteSettings.zoomHost(text) ?? text
				}
				edit = .setSiteZoom(profileID: try required(try uuid("profileID")), host: host, factor: factor)

			default:
				throw AutomationFailure.invalidRequest
			}
			request = .init(.change(.init(
				operationID: try required(try uuid("operationID")),
				expectedRevision: try required(try optionalString("expectedRevision", in: arguments, maximum: 64)),
				edit: edit
			)))
		}
		try request.validate()
		return .settings(request)
	}

	internal static func settingsPayload(_ settings: AutomationSettingsResult) throws -> Value {
		guard case var .object(value) = try Value(encoding: settings)
		else { throw AutomationFailure.invalidRequest }
		value["kind"] = .string("settings")
		return .object(value)
	}

	// MARK: - Arguments

	/// Values sorted by key, so the same request always binds the same approval.
	private static func preferenceSettings(_ value: Value?) throws -> [AutomationPreferenceSetting] {
		guard case let .object(values) = value, !values.isEmpty
		else { throw AutomationFailure.invalidRequest }

		if !Set(values.keys).isDisjoint(with: AutomationPreferenceKey.protectedNames) {
			throw AutomationFailure.protectedSetting
		}
		return try values.keys.sorted().map { name in
			guard let key = AutomationPreferenceKey(rawValue: name)
			else { throw AutomationFailure.invalidRequest }

			let setting: AutomationPreferenceValue
			switch values[name] {
			case let .bool(flag)?: setting = .bool(flag)
			case let .string(text)? where text.utf8.count <= 64: setting = .string(text)
			case let raw? where number(raw) != nil: setting = .number(number(raw)!)
			default: throw AutomationFailure.invalidValue
			}
			return .init(key: key, value: setting)
		}
	}

	private static func routingRule(_ value: Value?) throws -> AutomationRoutingRule {
		guard
			case let .object(rule) = value,
			Set(rule.keys).isSubset(of: [
				"id", "name", "host", "includesSubdomains", "scheme", "port", "pathPrefix", "destination",
			]),
			let name = try optionalString("name", in: rule, maximum: 256),
			let host = try optionalString("host", in: rule, maximum: 256),
			case let .object(destination) = rule["destination"],
			Set(destination.keys).isSubset(of: ["scope", "id", "mode"]),
			let scope = try optionalString("scope", in: destination, maximum: 32)
				.flatMap(AutomationRoutingDestination.Scope.init(rawValue:))
		else { throw AutomationFailure.invalidRequest }

		let id = try optionalString("id", in: rule, maximum: 36)
		let destinationID = try optionalString("id", in: destination, maximum: 36)
		let mode = try optionalString("mode", in: destination, maximum: 32)
		let port = rule["port"]
		guard
			id.map({ UUID(uuidString: $0) != nil }) ?? true,
			destinationID.map({ UUID(uuidString: $0) != nil }) ?? true,
			mode.map({ RoutingWindowMode(rawValue: $0) != nil }) ?? true,
			port.map({ $0.intValue != nil }) ?? true,
			rule["includesSubdomains"].map({ $0.boolValue != nil }) ?? true
		else { throw AutomationFailure.invalidRequest }

		return .init(
			id: id.flatMap(UUID.init(uuidString:)) ?? UUID(),
			name: name,
			host: host,
			includesSubdomains: rule["includesSubdomains"]?.boolValue ?? false,
			scheme: try optionalString("scheme", in: rule, maximum: 8),
			port: port?.intValue,
			pathPrefix: try optionalString("pathPrefix", in: rule, maximum: 1024),
			destination: .init(
				scope: scope,
				id: destinationID.flatMap(UUID.init(uuidString:)),
				mode: mode.flatMap(RoutingWindowMode.init(rawValue:)) ?? .mainBrowser
			)
		)
	}

	private static func searchShortcut(_ value: Value?) throws -> SearchShortcut {
		guard
			case let .object(shortcut) = value,
			Set(shortcut.keys).isSubset(of: ["keyword", "name", "template", "homepage"]),
			let keyword = try optionalString("keyword", in: shortcut, maximum: 64),
			let name = try optionalString("name", in: shortcut, maximum: 256),
			let template = try optionalString("template", in: shortcut, maximum: 4096)
		else { throw AutomationFailure.invalidRequest }

		let homepage = try optionalString("homepage", in: shortcut, maximum: 4096)
		let url = homepage.flatMap { URL(string: $0, encodingInvalidCharacters: false) }
		guard homepage == nil || url != nil else { throw AutomationFailure.invalidRequest }

		return .init(name: name, keyword: keyword, template: template, homepage: url)
	}

	private static func keyboardShortcut(_ value: Value) throws -> KeyboardShortcut? {
		if value == .null { return nil }
		guard
			case let .object(chord) = value,
			Set(chord.keys).isSubset(of: ["key", "modifiers"]),
			let key = try optionalString("key", in: chord, maximum: 16),
			case let .array(names) = chord["modifiers"] ?? .array([]),
			names.count <= 4
		else { throw AutomationFailure.invalidRequest }

		let modifiers = try names.map { name in
			guard let text = name.stringValue else { throw AutomationFailure.invalidRequest }
			return text
		}
		guard let shortcut = AutomationKeyChord(key: key, modifiers: modifiers).shortcut
		else { throw AutomationFailure.invalidRequest }
		return shortcut
	}
}

// MARK: - Appearance

extension AutomationTools {
	internal static var appearanceSchema: Value {
		let number: (Double, Double) -> Value = { minimum, maximum in
			.object([
				"type": .array([.string("number"), .string("null")]),
				"minimum": .double(minimum),
				"maximum": .double(maximum),
			])
		}
		return .object([
			"type": .string("object"),
			"properties": .object([
				"theme": .object([
					"type": .array([.string("string"), .string("null")]),
					"enum": .array(["light", "dark", "system"].map(Value.string) + [.null]),
				]),
				"tintHue": number(0, 360),
				"tintIntensity": number(0, 1),
				"grainEnabled": .object(["type": .array([.string("boolean"), .string("null")])]),
				"grainIntensity": number(0, 1),
				"grainSize": number(1, 3),
				"accentColor": .object([
					"type": .array([.string("string"), .string("null")]),
					"description": .string(
						"A preset (\(ChromeAccent.Preset.allCases.map(\.rawValue).joined(separator: ", "))) or #RRGGBB."
					),
				]),
				"matchesSite": .object(["type": .array([.string("boolean"), .string("null")])]),
				"gradient": .object([
					"type": .array([.string("object"), .string("string"), .string("null")]),
					"description": .string("\"plain\" for the tint's own gradient, or up to two more colors at an angle."),
					"properties": .object([
						"stops": .object([
							"type": .string("array"),
							"maxItems": .int(ChromeGradient.maximumStops),
							"items": .object([
								"type": .string("object"),
								"properties": .object([
									"hue": number(0, 360),
									"intensity": number(0, 1),
								]),
								"required": .array([.string("hue"), .string("intensity")]),
								"additionalProperties": .bool(false),
							]),
						]),
						"angle": number(0, 360),
					]),
					"additionalProperties": .bool(false),
				]),
			]),
			"additionalProperties": .bool(false),
		])
	}

	/// `appearance` fields to choose, with null returning a field to inheriting, and `clearAppearance`.
	internal static func appearanceChange(_ arguments: [String: Value]) throws -> AutomationAppearanceChange? {
		let clearsAll: Bool
		switch arguments["clearAppearance"] {
		case nil: clearsAll = false
		case let .bool(flag)?: clearsAll = flag
		default: throw AutomationFailure.invalidRequest
		}
		guard let value = arguments["appearance"] else {
			return clearsAll ? .init(clearsAll: true) : nil
		}
		guard
			case let .object(fields) = value,
			Set(fields.keys).isSubset(of: AutomationAppearanceField.allCases.map(\.rawValue))
		else { throw AutomationFailure.invalidRequest }

		var change = AutomationAppearanceChange(clearsAll: clearsAll)
		for (name, value) in fields {
			guard let field = AutomationAppearanceField(rawValue: name)
			else { throw AutomationFailure.invalidRequest }

			if value == .null {
				change.inherit.insert(field)
				continue
			}
			switch field {
			case .theme:
				guard let text = value.stringValue else { throw AutomationFailure.invalidRequest }
				if text == "system" {
					change.inherit.insert(.theme)
				} else {
					guard let theme = AppearanceOverride.Theme(rawValue: text)
					else { throw AutomationFailure.invalidRequest }
					change.set.theme = theme
				}

			case .grainEnabled:
				guard let flag = value.boolValue else { throw AutomationFailure.invalidRequest }
				change.set.grainEnabled = flag

			case .tintHue, .tintIntensity, .grainIntensity, .grainSize:
				guard let number = number(value) else { throw AutomationFailure.invalidRequest }
				switch field {
				case .tintHue: change.set.tintHue = number
				case .tintIntensity: change.set.tintIntensity = number
				case .grainIntensity: change.set.grainIntensity = number
				default: change.set.grainSize = number
				}

			case .accentColor:
				guard let text = value.stringValue else { throw AutomationFailure.invalidRequest }
				guard let accent = ChromeAccent.Preset(rawValue: text)?.accent ?? ChromeAccent(hex: text)
				else { throw AutomationFailure.invalidValue }
				change.set.accent = accent

			case .matchesSite:
				guard let flag = value.boolValue else { throw AutomationFailure.invalidRequest }
				change.set.matchesSite = flag

			case .gradient:
				change.set.gradient = try gradient(value)
			}
		}
		return change
	}

	/// `"plain"`, or `{stops: [{hue, intensity}], angle}` with the angle 135 when left out.
	private static func gradient(_ value: Value) throws -> ChromeGradient {
		if value.stringValue == "plain" { return .plain }
		guard
			case let .object(fields) = value,
			Set(fields.keys).isSubset(of: ["stops", "angle"]),
			case let .array(stops)? = fields["stops"]
		else { throw AutomationFailure.invalidRequest }

		let tints: [ChromeTint] = try stops.map { stop in
			guard
				case let .object(stop) = stop,
				Set(stop.keys) == ["hue", "intensity"],
				let hue = number(stop["hue"]),
				let intensity = number(stop["intensity"])
			else { throw AutomationFailure.invalidRequest }
			return ChromeTint(hue: hue, intensity: intensity)
		}
		let angle: Double = switch fields["angle"] {
		case nil: ChromeGradient.defaultAngle
		case let value?:
			if let number = number(value) { number } else { throw AutomationFailure.invalidRequest }
		}
		return ChromeGradient(stops: tints, angle: angle)
	}
}
