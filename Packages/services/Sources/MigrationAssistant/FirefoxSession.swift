import BrowserCore
import Compression
import Foundation

/// Reads the session files of Firefox-based browsers: Firefox's open tabs and Zen's
/// spaces, Essentials, pinned tabs and folders.
///
/// Both are JSON compressed in Mozilla's `mozLz4` container: the magic `mozLz40\0`,
/// the decompressed size as a little-endian `UInt32`, then one raw LZ4 block.
internal enum FirefoxSession {
	internal static let magic: Data = Data("mozLz40\u{0}".utf8)

	/// Session files are a few megabytes; anything far larger isn't one.
	internal static let maximumSize: Int = 256 * 1024 * 1024

	/// Where Firefox keeps the session: the running browser's recovery file first, then
	/// the file it writes when it quits.
	internal static let firefoxFiles: [String] = [
		"sessionstore-backups/recovery.jsonlz4",
		"sessionstore.jsonlz4",
	]

	/// Zen 1.18 and later keep spaces and pinned tabs in their own session file.
	internal static let zenFile: String = "zen-sessions.jsonlz4"

	// MARK: - mozLz4

	internal static func decompress(_ data: Data) throws -> Data {
		var reader: ByteReader = .init(data)
		guard
			reader.bytes(magic.count) == magic,
			let size = reader.uint32().map(Int.init),
			size <= maximumSize,
			let block = reader.bytes(reader.remaining)
		else { throw MigrationFailure.unreadableSource("A Firefox session file has an unknown format.") }

		guard size > 0 else { return Data() }

		// Apple's decoder stops short when the buffer is exactly the expected size, so it
		// gets room to spare and the result must still match the header.
		let capacity = size + 64
		var output = Data(count: capacity)
		let written = output.withUnsafeMutableBytes { destination in
			block.withUnsafeBytes { source in
				compression_decode_buffer(
					destination.baseAddress!.assumingMemoryBound(to: UInt8.self),
					capacity,
					source.baseAddress!.assumingMemoryBound(to: UInt8.self),
					block.count,
					nil,
					COMPRESSION_LZ4_RAW
				)
			}
		}
		guard written == size
		else { throw MigrationFailure.unreadableSource("A Firefox session file couldn't be decompressed.") }

		return output.prefix(size)
	}

	/// The `mozLz4` form of some bytes, for writing fixtures.
	internal static func compress(_ data: Data) -> Data {
		var output = magic
		withUnsafeBytes(of: UInt32(data.count).littleEndian) { output.append(contentsOf: $0) }
		guard !data.isEmpty else { return output }

		// Apple's encoder gives up without generous room, even for data that compresses well.
		let capacity = max(data.count * 2, 4096)
		var block = Data(count: capacity)
		let written = block.withUnsafeMutableBytes { destination in
			data.withUnsafeBytes { source in
				compression_encode_buffer(
					destination.baseAddress!.assumingMemoryBound(to: UInt8.self),
					capacity,
					source.baseAddress!.assumingMemoryBound(to: UInt8.self),
					data.count,
					nil,
					COMPRESSION_LZ4_RAW
				)
			}
		}
		return output + block.prefix(written)
	}

	internal static func json(_ data: Data) throws -> [String: Any] {
		guard let object = try JSONSerialization.jsonObject(with: decompress(data)) as? [String: Any]
		else { throw MigrationFailure.unreadableSource("A Firefox session file has an unknown format.") }

		return object
	}

	// MARK: - Tabs

	/// A tab's current page: `entries` with a 1-based `index`.
	internal static func page(of tab: [String: Any]) -> (url: String, title: String)? {
		guard
			let entries = tab["entries"] as? [[String: Any]],
			!entries.isEmpty
		else { return nil }

		let index = (tab["index"] as? Int).map { min(max($0, 1), entries.count) } ?? entries.count
		let entry = entries[index - 1]
		guard let url = entry["url"] as? String else { return nil }

		return (url, entry["title"] as? String ?? "")
	}

	/// Firefox's open tabs, every window's in order. Hidden tabs (another extension's or a
	/// collapsed group's bookkeeping) are left out; pinned tabs stay open tabs, as in Chrome.
	internal static func firefoxOpenTabs(_ session: [String: Any]) -> [(url: String, title: String)] {
		let windows = session["windows"] as? [[String: Any]] ?? []
		return windows.flatMap { window in
			(window["tabs"] as? [[String: Any]] ?? []).compactMap { tab in
				(tab["hidden"] as? Bool) == true ? nil : page(of: tab)
			}
		}
	}

	// MARK: - Zen

	/// A Zen space and what it holds, read from `zen-sessions.jsonlz4` or from the tables
	/// older Zen versions kept in `places.sqlite`.
	internal struct ZenSpace: Equatable, Sendable {
		internal var id: String
		internal var name: String
		internal var icon: String?

		internal init(
			id: String,
			name: String,
			icon: String? = nil
		) {
			self.id = id
			self.name = name
			self.icon = icon
		}
	}

	internal struct ZenTab: Equatable, Sendable {
		internal enum Place: Equatable, Sendable {
			/// Essentials, shown in every space of the profile.
			case essential

			/// Pinned in its space.
			case pinned

			/// An ordinary open tab in its space.
			case open
		}

		internal var id: String
		internal var place: Place
		internal var spaceID: String?
		internal var url: String
		internal var title: String
		internal var customTitle: String?

		/// Its folder's ID, when it's in one.
		internal var folderID: String?

		/// Where a pinned tab is now, when it navigated away from the page it returns to.
		internal var currentURL: String?
		internal var currentTitle: String?

		/// Its place among the source's tabs and folders.
		internal var order: Double

		internal init(
			id: String,
			place: Place,
			spaceID: String?,
			url: String,
			title: String,
			customTitle: String? = nil,
			folderID: String? = nil,
			currentURL: String? = nil,
			currentTitle: String? = nil,
			order: Double = 0
		) {
			self.id = id
			self.place = place
			self.spaceID = spaceID
			self.url = url
			self.title = title
			self.customTitle = customTitle
			self.folderID = folderID
			self.currentURL = currentURL
			self.currentTitle = currentTitle
			self.order = order
		}
	}

	internal struct ZenFolder: Equatable, Sendable {
		internal var id: String
		internal var name: String
		internal var parentID: String?
		internal var spaceID: String?
		internal var isCollapsed: Bool

		/// Its place among the source's tabs and folders, when the source stores one.
		internal var order: Double?

		/// What it follows, as Zen's `prevSiblingInfo` says: `start`, or a tab or folder ID.
		internal var previousSibling: PreviousSibling?

		internal enum PreviousSibling: Equatable, Sendable {
			case start
			case tab(String)
			case folder(String)
		}

		internal init(
			id: String,
			name: String,
			parentID: String? = nil,
			spaceID: String? = nil,
			isCollapsed: Bool = false,
			order: Double? = nil,
			previousSibling: PreviousSibling? = nil
		) {
			self.id = id
			self.name = name
			self.parentID = parentID
			self.spaceID = spaceID
			self.isCollapsed = isCollapsed
			self.order = order
			self.previousSibling = previousSibling
		}
	}

	internal struct ZenLayout: Equatable, Sendable {
		internal var spaces: [ZenSpace]
		internal var tabs: [ZenTab]
		internal var folders: [ZenFolder]

		internal init(
			spaces: [ZenSpace] = [],
			tabs: [ZenTab] = [],
			folders: [ZenFolder] = []
		) {
			self.spaces = spaces
			self.tabs = tabs
			self.folders = folders
		}

		internal var isEmpty: Bool { spaces.isEmpty && tabs.isEmpty }
	}

	/// Zen 1.18+: `{spaces, tabs, folders, …}`. Tabs carry `zenWorkspace`, `zenEssential`,
	/// `pinned` and `groupId`; Glance previews and empty placeholder tabs are skipped.
	internal static func zenLayout(_ session: [String: Any]) -> ZenLayout {
		let spaces: [ZenSpace] = (session["spaces"] as? [[String: Any]] ?? []).compactMap { space in
			guard let id = space["uuid"] as? String else { return nil }

			return .init(id: id, name: space["name"] as? String ?? "", icon: space["icon"] as? String)
		}
		let folders: [ZenFolder] = (session["folders"] as? [[String: Any]] ?? []).compactMap { folder in
			guard let id = folder["id"] as? String else { return nil }

			return .init(
				id: id,
				name: folder["name"] as? String ?? "",
				parentID: folder["parentId"] as? String,
				spaceID: folder["workspaceId"] as? String,
				isCollapsed: folder["collapsed"] as? Bool ?? false,
				previousSibling: previousSibling(folder["prevSiblingInfo"] as? [String: Any])
			)
		}
		let tabs: [ZenTab] = (session["tabs"] as? [[String: Any]] ?? []).enumerated().compactMap { offset, tab in
			guard
				tab["zenIsGlance"] as? Bool != true,
				tab["zenIsEmpty"] as? Bool != true,
				let page = page(of: tab)
			else { return nil }

			let place: ZenTab.Place = if tab["zenEssential"] as? Bool == true {
				.essential
			} else if tab["pinned"] as? Bool == true {
				.pinned
			} else {
				.open
			}
			let id = tab["zenSyncId"] as? String ?? tab["zenPinnedId"] as? String ?? "tab-\(offset)"

			// A pin returns to the page it was pinned at; where it is now is kept beside it.
			let initial = ((tab["_zenPinnedInitialState"] as? [String: Any])?["entry"] as? [String: Any])
				.flatMap { entry in (entry["url"] as? String).map { ($0, entry["title"] as? String ?? "") } }
			let saved = place == .open ? nil : initial
			let moved = saved.map { $0.0 != page.url } ?? false
			return .init(
				id: id,
				place: place,
				spaceID: tab["zenWorkspace"] as? String,
				url: saved?.0 ?? page.url,
				title: saved?.1 ?? page.title,
				customTitle: (tab["zenStaticLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 },
				folderID: tab["groupId"] as? String,
				currentURL: moved ? page.url : nil,
				currentTitle: moved ? page.title : nil,
				order: Double(offset)
			)
		}
		return .init(spaces: spaces, tabs: tabs, folders: folders)
	}

	/// Zen 1.17 and earlier: `zen_workspaces` and `zen_pins` in `places.sqlite`. Pins rows
	/// are tabs or, with `is_group`, folders; `folder_parent_uuid` nests them.
	internal static func zenLayout(_ database: SQLiteDatabase) throws -> ZenLayout {
		guard try database.hasTable("zen_workspaces") else { return .init() }

		let spaces = try database.rows(
			"SELECT uuid, name, icon FROM zen_workspaces ORDER BY position, id"
		) { row in
			ZenSpace(id: row.text(0) ?? "", name: row.text(1) ?? "", icon: row.text(2))
		}
		guard try database.hasTable("zen_pins") else { return .init(spaces: spaces) }

		let columns = try Set(database.rows("PRAGMA table_info(zen_pins)") { $0.text(1) ?? "" })
		let parent = columns.contains("folder_parent_uuid") ? "folder_parent_uuid" : "NULL"
		let edited = columns.contains("edited_title") ? "edited_title" : "0"
		let collapsed = columns.contains("is_folder_collapsed") ? "is_folder_collapsed" : "0"
		var tabs: [ZenTab] = []
		var folders: [ZenFolder] = []
		_ = try database.rows(
			"""
			SELECT uuid, title, url, workspace_uuid, is_essential, is_group, \(parent), \(edited), \(collapsed)
			FROM zen_pins ORDER BY position, id
			"""
		) { row in
			let id = row.text(0) ?? ""
			let order = Double(tabs.count + folders.count)
			if row.int(5) != 0 {
				folders.append(
					.init(
						id: id,
						name: row.text(1) ?? "",
						parentID: row.text(6),
						spaceID: row.text(3),
						isCollapsed: row.int(8) != 0,
						order: order
					)
				)
			} else {
				let title = row.text(1) ?? ""
				tabs.append(
					.init(
						id: id,
						place: row.int(4) != 0 ? .essential : .pinned,
						spaceID: row.text(3),
						url: row.text(2) ?? "",
						title: title,
						customTitle: row.int(7) != 0 && !title.isEmpty ? title : nil,
						folderID: row.text(6),
						order: order
					)
				)
			}
		}
		return .init(spaces: spaces, tabs: tabs, folders: folders)
	}

	/// Zen 1.17 and earlier kept only pins in `places.sqlite`; their other open tabs are in
	/// Firefox's session file, each with its space in the `zen-workspace-id` attribute.
	/// Pinned tabs are left out because the pins table already has them.
	///
	/// Zen 1.18 and later leave windows marked `isZenUnsynced` out of `zen-sessions.jsonlz4`;
	/// `unsyncedWindowsOnly` reads just those.
	internal static func zenLegacyOpenTabs(
		_ session: [String: Any],
		unsyncedWindowsOnly: Bool = false
	) -> [ZenTab] {
		let windows = (session["windows"] as? [[String: Any]] ?? []).filter { window in
			!unsyncedWindowsOnly || window["isZenUnsynced"] as? Bool == true
		}
		var occurrences: [String: Int] = [:]
		return windows.flatMap { window in
			(window["tabs"] as? [[String: Any]] ?? []).compactMap { tab -> ZenTab? in

				// An unsynced window's pins are in no other file, so they come as open tabs.
				guard
					unsyncedWindowsOnly || tab["pinned"] as? Bool != true,
					tab["hidden"] as? Bool != true,
					tab["zenIsGlance"] as? Bool != true,
					let page = page(of: tab)
				else { return nil }

				let attributes = tab["attributes"] as? [String: Any] ?? [:]
				let occurrence = occurrences[page.url, default: 0]
				occurrences[page.url] = occurrence + 1
				return .init(
					id: "open/" + page.url + "#\(occurrence)",
					place: .open,
					spaceID: tab["zenWorkspace"] as? String ?? attributes["zen-workspace-id"] as? String,
					url: page.url,
					title: page.title,
					// Open tabs come after every pin.
					order: Double(Int32.max) + Double(occurrences.values.reduce(0, +))
				)
			}
		}
	}

	/// Records for a Zen profile's layout: spaces in order, Essentials as the profile's
	/// favorites, pinned tabs and their folders as bookmarks, the rest as open tabs.
	internal static func zenRecords(
		_ layout: ZenLayout,
		profile: MigrationSourceProfile
	) -> [MigrationRecord] {
		let spaces: [String: MigrationSourceSpace] = Dictionary(
			layout.spaces.map { space in
				(
					space.id,
					MigrationSourceSpace(
						id: profile.id + MigrationBrowserSources.spaceSeparator + space.id,
						name: space.name.isEmpty ? profile.name : space.name,
						icon: emoji(space.icon),
						profile: profile
					)
				)
			},
			uniquingKeysWith: { first, _ in first }
		)
		let folders: [String: ZenFolder] = Dictionary(
			layout.folders.map { ($0.id, $0) },
			uniquingKeysWith: { first, _ in first }
		)

		/// Outermost first; a cycle or a missing parent ends the chain.
		func path(_ id: String?) -> [MigrationSourceFolder] {
			var chain: [MigrationSourceFolder] = []
			var seen: Set<String> = []
			var next = id
			while let current = next, let folder = folders[current], seen.insert(current).inserted {
				chain.insert(
					.init(id: profile.id + "/" + folder.id, name: folder.name, isExpanded: !folder.isCollapsed),
					at: 0
				)
				next = folder.parentID
			}
			return chain
		}

		var records: [MigrationRecord] = layout.spaces.compactMap { space in
			spaces[space.id].map { source in
				.init(sourceItemID: "space:" + source.id, kind: .space, category: .bookmarks, space: source)
			}
		}

		// Folders no pinned tab will create are records of their own. Open tabs don't keep
		// their folders, so a folder of only open tabs needs a record too.
		let filled = Set(layout.tabs.filter { $0.place == .pinned }.flatMap { path($0.folderID).map(\.id) })
		let orders = folderOrders(layout)
		var entries: [(order: Place, record: MigrationRecord)] = []
		for folder in layout.folders {
			let chain = path(folder.id)
			guard
				let last = chain.last,
				!filled.contains(last.id),
				let space = folder.spaceID.flatMap({ spaces[$0] })
			else { continue }

			entries.append((
				orders[folder.id] ?? .init(base: .infinity),
				.init(
					sourceItemID: "folder:" + last.id,
					kind: .folder,
					category: .bookmarks,
					folders: chain,
					space: space
				)
			))
		}
		for tab in layout.tabs {
			let id = profile.id + "/" + tab.id
			switch tab.place {
			case .essential:
				entries.append((
					.init(base: tab.order),
					.init(
						sourceItemID: id,
						category: .favorites,
						title: tab.title,
						url: tab.url,
						profile: profile,
						currentURL: tab.currentURL,
						currentTitle: tab.currentTitle,
						customTitle: tab.customTitle
					)
				))

			case .pinned, .open:
				// A tab whose space is gone has nowhere to go but the destination.
				let space = tab.spaceID.flatMap { spaces[$0] }
				entries.append((
					.init(base: tab.order),
					.init(
						sourceItemID: id,
						category: tab.place == .pinned ? .bookmarks : .openTabs,
						title: tab.title,
						url: tab.url,
						folders: tab.place == .pinned ? path(tab.folderID) : [],
						space: space,
						currentURL: tab.currentURL,
						currentTitle: tab.currentTitle,
						customTitle: tab.customTitle
					)
				))
			}
		}

		// Folders and tabs keep the source's order; the sort is stable for equal places.
		records += entries.enumerated()
			.sorted { lhs, rhs in
				lhs.element.order == rhs.element.order ? lhs.offset < rhs.offset : lhs.element.order < rhs.element.order
			}
			.map(\.element.record)
		return records
	}

	/// `prevSiblingInfo`: `{type: "start" | "tab" | "group", id}`.
	private static func previousSibling(_ info: [String: Any]?) -> ZenFolder.PreviousSibling? {
		guard let info else { return nil }

		switch info["type"] as? String {
		case "start": return .start
		case "tab": return (info["id"] as? String).map(ZenFolder.PreviousSibling.tab)
		case "group": return (info["id"] as? String).map(ZenFolder.PreviousSibling.folder)
		default: return nil
		}
	}

	/// Where a record goes: after the tab or stored position `base`, then `step` places
	/// along a chain of folders that follow it.
	internal struct Place: Comparable, Sendable {
		internal var base: Double
		internal var step: Int = 0

		internal static func < (lhs: Self, rhs: Self) -> Bool {
			lhs.base == rhs.base ? lhs.step < rhs.step : lhs.base < rhs.base
		}
	}

	/// Each folder's place among the tabs: its stored order, or the next step after the tab
	/// or folder it follows. A folder whose place can't be found goes last.
	private static func folderOrders(_ layout: ZenLayout) -> [String: Place] {
		var tabOrders: [String: Double] = [:]
		for tab in layout.tabs {
			tabOrders[tab.id] = tab.order
		}
		let folders: [String: ZenFolder] = Dictionary(
			layout.folders.map { ($0.id, $0) },
			uniquingKeysWith: { first, _ in first }
		)
		var orders: [String: Place] = [:]

		/// The folder and every folder inside it, however deep (DEV-651).
		func subtree(of root: String) -> Set<String> {
			var members: Set<String> = [root]
			var grew: Bool = true
			while grew {
				grew = false
				for folder in layout.folders where !members.contains(folder.id) {
					guard let parent = folder.parentID, members.contains(parent) else { continue }

					members.insert(folder.id)
					grew = true
				}
			}
			return members
		}

		func order(
			of id: String,
			visiting: Set<String>
		) -> Place? {
			if let known = orders[id] { return known }
			guard let folder = folders[id], !visiting.contains(id) else { return nil }

			let resolved: Place? = if let stored = folder.order {
				.init(base: stored)
			} else {
				switch folder.previousSibling {
				case .start:
					// The start of its parent folder, or of the space.
					if let parent = folder.parentID {
						order(of: parent, visiting: visiting.union([id])).map { .init(base: $0.base, step: $0.step + 1) }
							?? layout.tabs.filter { $0.folderID == parent }.map(\.order).min().map { .init(base: $0, step: -1) }
					} else {
						.init(base: -1, step: 1)
					}
				case let .tab(tab): tabOrders[tab].map { .init(base: $0, step: 1) }
				case let .folder(previous):
					// After the previous folder and the tabs in it, its subfolders' included.
					order(of: previous, visiting: visiting.union([id])).map { start in
						let members: Set<String> = subtree(of: previous)
						let inside = layout.tabs
							.filter { $0.folderID.map(members.contains) ?? false }
							.map(\.order)
							.max()
						if let inside, inside > start.base {
							return .init(base: inside, step: 1)
						}
						return .init(base: start.base, step: start.step + 1)
					}
				case nil: nil
				}
			}
			orders[id] = resolved
			return resolved
		}

		for folder in layout.folders {
			_ = order(of: folder.id, visiting: [])
		}
		return orders
	}

	/// Zen's icons are emoji or its own SVG names; only emoji carry over.
	private static func emoji(_ icon: String?) -> String? {
		icon.flatMap(SpaceIcon.init(rawValue:)).flatMap { $0.isEmoji ? $0.rawValue : nil }
	}
}
