import BrowserCore
import Foundation
import _MCP

extension AutomationTools {
	/// Page actions that accept `returnSnapshot: true` to act and observe in one call.
	public static let returnSnapshotTools: Set<String> = [
		"browser_click",
		"browser_replace_text",
		"browser_select_value",
		"browser_keypress",
		"browser_scroll",
		"browser_hover",
		"browser_drag",
		"browser_type",
		"browser_set_checked",
		"browser_upload",
	]

	/// Tools a `browser_batch` step may name.
	public static let batchStepTools: Set<String> = [
		"browser_inventory",
		"browser_tabs",
		"browser_folders",
		"browser_hosts",
		"browser_spaces",
		"browser_profiles",
		"browser_windows",
		"browser_command",
		"browser_capture",
		"browser_inspect",
		"browser_wait",
		"browser_click",
		"browser_replace_text",
		"browser_select_value",
		"browser_keypress",
		"browser_scroll",
		"browser_hover",
		"browser_drag",
		"browser_type",
		"browser_set_checked",
	]

	/// The organization commands, split by what they act on.
	public enum CommandTool: String, CaseIterable, Sendable {
		case tabs = "browser_tabs"
		case folders = "browser_folders"
		case hosts = "browser_hosts"
		case spaces = "browser_spaces"
		case profiles = "browser_profiles"
		case windows = "browser_windows"
		case archive = "browser_archive"
		case downloads = "browser_downloads"

		public var actions: [AutomationCommand.Action] {
			switch self {
			case .tabs:
				[
					.openTab, .selectTab, .navigate, .reload, .back, .forward, .stop, .closeTab, .pinTab, .unpinTab,
					.moveTab, .addFavorite, .removeFavorite, .updateSavedURL, .removeSavedEntry,
				]

			case .folders:
				[.createFolder, .renameFolder, .moveFolder, .ungroupFolder, .deleteFolder]

			case .hosts:
				[.openPeek, .openLittleArx, .promotePeekToTab, .promotePeekToLittleArx, .promoteLittleArx]

			case .spaces:
				[.createSpace, .renameSpace, .setSpaceTheme, .setSpaceAppearance, .moveSpace, .deleteSpace, .selectSpace]

			case .profiles:
				[.createProfile, .renameProfile, .setProfileAppearance, .deleteProfile]

			case .windows:
				[.openSplit, .swapSplit, .closeSplit, .focusWindow]

			case .archive:
				[.restoreArchived]

			case .downloads:
				[.startDownload, .cancelDownload, .revealDownload]
			}
		}

		/// Archive and downloads list through a paginated data read instead of inventory.
		public var dataKind: AutomationDataRequest.Kind? {
			switch self {
			case .archive: .archive
			case .downloads: .downloads
			default: nil
			}
		}

		/// Spaces, profiles and windows also answer `action: "list"`, which needs only read.
		public var lists: Bool {
			switch self {
			case .spaces, .profiles, .windows, .archive, .downloads: true
			case .tabs, .folders, .hosts: false
			}
		}

		internal var definition: Tool {
			.init(
				name: rawValue,
				title: title,
				description: description + " " + commonNote,
				inputSchema: AutomationTools.schema(
					properties: properties,
					required: lists ? ["action"] : ["operationID", "action", "targetID", "expectedRevision"]
				),
				annotations: .init(
					readOnlyHint: false,
					destructiveHint: actions.contains { $0.riskTier == .destructive },
					idempotentHint: false,
					openWorldHint: self == .tabs || self == .hosts || self == .downloads
				)
			)
		}

		private var title: String {
			switch self {
			case .tabs: "Open, navigate, move, pin, favorite and close tabs"
			case .folders: "Create, rename, move, ungroup and delete folders"
			case .hosts: "Open and promote Peek and Little Arx"
			case .spaces: "List and manage spaces"
			case .profiles: "List and manage profiles"
			case .windows: "List windows, focus them and manage Split View"
			case .archive: "Search and restore archived tabs"
			case .downloads: "List, start, cancel and reveal downloads"
			}
		}

		private var description: String {
			switch self {
			case .tabs:
				"""
				openTab targets a space and needs url; with route:true Air Traffic Control picks the destination \
				(targetID is then the source space, and the result's route says where it went). openTab's windowID \
				names the window that keeps the new tab (one browser_windows lists; never with route); the main window \
				otherwise. \
				selectTab, navigate (url), reload, back, forward and stop target a loaded tab. \
				selectTab shows the tab, which wakes it if Chromium froze it in the background (it freezes tabs beyond \
				the five most recently shown or opened, headless runs included) and keeps it running while selected: \
				select a tab before waiting for it to change. A navigation wakes a frozen tab only while it loads. \
				closeTab is destructive: open tabs go to the archive; pins and Favorites keep their saved entry. \
				pinTab, unpinTab and moveTab take destinationID and destinationRevision. A moveTab into a space of \
				another profile reopens the URL and saved metadata there; the live session and cookies stay behind. \
				addFavorite adds the tab to its profile's Favorites (destinationID: the Favorite to insert before), \
				removeFavorite returns a Favorite to destinationID's open tabs, updateSavedURL saves a pin's current URL, \
				and removeSavedEntry deletes a pin or Favorite (destructive; Undo is in Arx).
				"""

			case .folders:
				"""
				createFolder targets a space and needs name. renameFolder targets a folder and needs name. \
				moveFolder moves the whole subtree into destinationID (a space or folder in the same profile). \
				ungroupFolder keeps the children in place; deleteFolder closes everything inside after each page allows it. \
				Refresh inventory after any tree change.
				"""

			case .hosts:
				"""
				Every action needs focus:true. openPeek needs sourceTabID and sourceRevision, and previews url \
				or, without one, targetID. openLittleArx targets a space and needs url. \
				Promotions take presentationID and presentationRevision from inventory presentations; \
				promoteLittleArx targets a same-profile space.
				"""

			case .spaces:
				"""
				action list returns granted spaces with revisions. Changes need the browser admin class: \
				createSpace targets a profile item (whole-profile grants list them) with name and optional icon; \
				renameSpace takes name and/or icon; setSpaceTheme takes theme light, dark or system; \
				setSpaceAppearance takes appearance and/or clearAppearance (see below); moveSpace places the space before destinationID (or last); deleteSpace is destructive and moves the \
				contents into destinationID when given, otherwise closes them; the last space can't be deleted. \
				selectSpace (organize class) shows the space in the main window. \
				Each listed space carries its own appearance override (absent when it inherits everything) and \
				resolvedAppearance, what its window chrome shows. \(appearanceNote)
				"""

			case .profiles:
				"""
				action list returns granted profiles with names. Changes need the browser admin class and target \
				profile items, which only whole-profile grants list. createProfile and renameProfile take name; a new \
				profile is not granted until the user grants it. deleteProfile is destructive, erases the profile's \
				browsing data, and needs a profile with no spaces left. setProfileAppearance takes appearance and/or \
				clearAppearance; its spaces inherit each field they don't choose themselves. Listed profiles carry \
				their appearance override and resolvedAppearance. \(appearanceNote)
				"""

			case .windows:
				"""
				action list returns windows showing a granted space, with the granted tabs in their panes; isMain \
				marks the main window. When each window keeps its own open tabs, inventory names an open tab's window \
				in its windowID, and openTab can name one. \
				openSplit targets a tab and shows it beside the current page in the main window. With splitTabs \
				(one to three {id, revision} tab items) it instead makes a Split View of 2 to 4 tabs of the target's \
				space, the target first, side by side or stacked as orientation says (horizontal or vertical). The split \
				shares the target's list: every other tab moves next to the target, so beside an open target a pinned \
				tab becomes open, beside a pinned target or in its folder an open tab is pinned there, and a tab of \
				another space of the profile moves over. A Favorite of the profile joins as a member and stays in \
				Favorites; the target can't be a Favorite. Tabs leave any split they were in, and panes start equal. swapSplit (reverses the panes) and \
				closeSplit (the active pane) and focusWindow target a window and its revision. Organize class.
				"""

			case .archive:
				"""
				action list pages through Tab Archive entries of granted spaces or whole profiles, newest first, \
				filtered by query. restoreArchived (organize class) reopens one entry as a new tab in its original \
				space, or in destinationID (a granted space of the same profile) when that space is gone; the entry \
				leaves the archive, so a retry can't restore it twice.
				"""

			case .downloads:
				"""
				Needs the downloads class and whole-profile grants. action list pages through downloads, newest \
				first, filtered by query; private downloads never appear. startDownload targets a profile item \
				(whole-profile grants list them) and needs an http(s) url; Arx asks the user every time unless their \
				approval policy skips it (a temporary grant doesn't cover it, and it can't be a batch step). Chromium \
				saves it where that profile saves downloads, with its usual prompts and safety checks, and the result's \
				targetID is the new download's ID once the transfer exists; list it to follow progress. \
				cancelDownload stops one in progress and revealDownload shows a finished file in Finder.
				"""
			}
		}

		private var appearanceNote: String {
			"""
			appearance is an object of override fields: theme (light, dark; null or system inherits), tintHue \
			(0 to 360 degrees), tintIntensity (0 to 1), grainEnabled, grainIntensity (0 to 1), grainSize \
			(1 to 3), accentColor (a preset name or #RRGGBB: folders, focus rings and Arx's highlights), \
			matchesSite (true or false: whether the chrome takes the shown page's color, the tint only for pages \
			without one; the matchesSite preference is the default) \
			and gradient ("plain" for the tint's own, or {stops: [{hue, intensity}] with one or two more colors, \
			angle: 0 to 360}). A field set to null goes back to inheriting from the profile, or for a profile \
			from Arx Settings; fields left out stay as they are. clearAppearance:true clears the whole override \
			first. resolvedAppearance shows the result, accentColor automatic when nothing chose one.
			"""
		}

		private var commonNote: String {
			"""
			Pass the target's current inventory revision and a fresh operationID UUID; never retry after a disconnect. \
			Arx may ask the user first, depending on their approval policy. Cross-profile moves return \
			crossProfileTransferUnsupported. Results report accepted or committed, not page completion.
			"""
		}

		private var properties: [String: Value] {
			var properties: [String: Value] = [
				"operationID": AutomationTools.string(maximum: 36),
				"action": .object([
					"type": .string("string"),
					"enum": .array(actions.map { .string($0.rawValue) }),
				]),
				"targetID": AutomationTools.string(maximum: 36),
				"expectedRevision": AutomationTools.string(maximum: 64),
				"focus": .object(["type": .string("boolean")]),
			]
			switch self {
			case .tabs:
				properties["url"] = AutomationTools.string(maximum: 4096)
				properties["destinationID"] = AutomationTools.string(maximum: 36)
				properties["destinationRevision"] = AutomationTools.string(maximum: 64)
				properties["route"] = .object([
					"type": .string("boolean"),
					"description": .string("openTab only: apply Air Traffic Control rules; targetID is the source space."),
				])
				properties["windowID"] = AutomationTools.windowIDSchema

			case .folders:
				properties["name"] = AutomationTools.string(maximum: 256)
				properties["destinationID"] = AutomationTools.string(maximum: 36)
				properties["destinationRevision"] = AutomationTools.string(maximum: 64)

			case .hosts:
				properties["url"] = AutomationTools.string(maximum: 4096)
				properties["sourceTabID"] = AutomationTools.string(maximum: 36)
				properties["sourceRevision"] = AutomationTools.string(maximum: 64)
				properties["presentationID"] = AutomationTools.string(maximum: 36)
				properties["presentationRevision"] = AutomationTools.string(maximum: 64)

			case .spaces:
				properties["name"] = AutomationTools.string(maximum: 256)
				properties["icon"] = AutomationTools.string(maximum: 64)
				properties["theme"] = .object([
					"type": .string("string"),
					"enum": .array(["light", "dark", "system"].map(Value.string)),
				])
				properties["destinationID"] = AutomationTools.string(maximum: 36)
				properties["destinationRevision"] = AutomationTools.string(maximum: 64)
				properties["appearance"] = AutomationTools.appearanceSchema
				properties["clearAppearance"] = .object(["type": .string("boolean")])

			case .profiles:
				properties["name"] = AutomationTools.string(maximum: 256)
				properties["appearance"] = AutomationTools.appearanceSchema
				properties["clearAppearance"] = .object(["type": .string("boolean")])

			case .windows:
				properties["splitTabs"] = .object([
					"type": .string("array"),
					"minItems": .int(1),
					"maxItems": .int(3),
					"items": .object([
						"type": .string("object"),
						"properties": .object([
							"id": AutomationTools.string(maximum: 36),
							"revision": AutomationTools.string(maximum: 64),
						]),
						"required": .array([.string("id"), .string("revision")]),
						"additionalProperties": .bool(false),
					]),
					"description": .string("openSplit only: the other tabs of a 2–4 tab Split View, after targetID."),
				])
				properties["orientation"] = .object([
					"type": .string("string"),
					"enum": .array(["horizontal", "vertical"].map(Value.string)),
					"description": .string("openSplit with splitTabs: side by side (horizontal) or stacked (vertical)."),
				])

			case .archive, .downloads:
				if self == .downloads {
					properties["url"] = AutomationTools.string(maximum: 4096)
				}
				properties["query"] = AutomationTools.string(maximum: 256, minimum: 0)
				properties["cursor"] = AutomationTools.string(maximum: 128)
				properties["limit"] = .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(100)])
				if self == .archive {
					properties["destinationID"] = AutomationTools.string(maximum: 36)
					properties["destinationRevision"] = AutomationTools.string(maximum: 64)
				}
			}
			if lists {
				properties["action"] = .object([
					"type": .string("string"),
					"enum": .array([.string("list")] + actions.map { .string($0.rawValue) }),
				])
			}
			return properties
		}
	}

	internal static var historyDefinition: Tool {
		.init(
			name: "browser_history",
			title: "Search browsing history",
			description: """
			Needs the history class. Searches visited pages of whole-profile grants only, newest first, \
			case-insensitively by title and sanitized URL. URLs drop user information, query and fragment; \
			titles may still be private. Results are paginated with nextCursor.
			""",
			inputSchema: schema(properties: [
				"query": string(maximum: 256, minimum: 0),
				"cursor": string(maximum: 128),
				"limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(100)]),
			]),
			annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
		)
	}

	internal static var linksDefinition: Tool {
		.init(
			name: "browser_links",
			title: "Clean, proxy or resolve links",
			description: """
			Only text comes back; nothing is opened or fetched. kind clean removes tracking parameters from url \
			(sensitive parameters are kept); proxy applies the user's first matching Proxy Link rule; bang resolves \
			query, such as "!w swift" or "!mdn fetch", to a destination URL: the user's search shortcuts first, then \
			Arx's bundled list of over 13,000 bangs (from Helium; Kagi Search and imput, MIT).
			""",
			inputSchema: schema(
				properties: [
					"kind": .object([
						"type": .string("string"),
						"enum": .array(AutomationLinkRequest.Kind.allCases.map { .string($0.rawValue) }),
					]),
					"url": string(maximum: 4096),
					"query": string(maximum: 1024),
				],
				required: ["kind"]
			),
			annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
		)
	}

	internal static var batchDefinition: Tool {
		.init(
			name: "browser_batch",
			title: "Run several browser steps under one approval",
			description: """
			Runs up to 16 steps in order, each {"tool", "arguments"} exactly as that tool takes them. \
			Arx asks the user once for the whole list when any step needs approval, and only steps on that list, \
			in that order, run under it. Every step keeps its own operationID, authorization and receipt. \
			The batch stops at the first step that fails or is not dispatched; later steps never run and \
			nothing is retried. Allowed tools: \(batchStepTools.sorted().joined(separator: ", ")). \
			Later steps cannot use results of earlier ones, so take snapshots and revisions before the batch.
			""",
			inputSchema: schema(
				properties: [
					"steps": .object([
						"type": .string("array"),
						"minItems": .int(1),
						"maxItems": .int(AutomationBatchPlan.maximumSteps),
						"items": .object([
							"type": .string("object"),
							"properties": .object([
								"tool": .object([
									"type": .string("string"),
									"enum": .array(batchStepTools.sorted().map(Value.string)),
								]),
								"arguments": .object(["type": .string("object")]),
							]),
							"required": .array([.string("tool"), .string("arguments")]),
							"additionalProperties": .bool(false),
						]),
					]),
				],
				required: ["steps"]
			),
			annotations: .init(
				readOnlyHint: false,
				destructiveHint: true,
				idempotentHint: false,
				openWorldHint: true
			)
		)
	}

	internal static var returnSnapshotSchema: Value {
		.object([
			"type": .string("boolean"),
			"description": .string(
				"Also return a fresh snapshot of the same document after the action, or snapshotUnavailable with the reason."
			),
		])
	}
}

extension Tool {
	internal func adding(
		property name: String,
		_ schema: Value
	) -> Tool {
		guard
			case var .object(root) = inputSchema,
			case var .object(properties) = root["properties"]
		else { return self }

		properties[name] = schema
		root["properties"] = .object(properties)
		return .init(
			name: self.name,
			title: title,
			description: description,
			inputSchema: .object(root),
			annotations: annotations,
			outputSchema: outputSchema,
			icons: icons,
			_meta: _meta
		)
	}
}
