import BrowserCore
import CryptoKit
import Foundation

/// The browsers Arx can read on this Mac. A browser that isn't installed, or whose
/// files can't be read, simply isn't offered.
public enum MigrationBrowserSources {
	/// Joins a profile's ID to its space IDs, so favorites can follow their profile's routes.
	internal static let spaceSeparator: String = "/"

	/// Sources a hand check against the real browser has confirmed are always offered.
	/// The others (every unchecked `ChromiumBrowser`, Firefox, Zen, Safari and Chromium
	/// open tabs, DEV-651, DEV-831, DEV-896) are offered only with `includesUnchecked`. The
	/// app passes `offersUncheckedSources`, which is on unless the `MigrationUncheckedSources`
	/// default turns it off.
	public static func adapters(
		home: URL = FileManager.default.homeDirectoryForCurrentUser,
		includesUnchecked: Bool = false
	) -> [MigrationSourceAdapter] {
		let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
		var adapters: [MigrationSourceAdapter?] = [arc(support.appending(path: "Arc", directoryHint: .isDirectory))]

		// Checked browsers first, so onboarding lists them first.
		let browsers = ChromiumBrowser.all.filter(\.isChecked)
		+ (includesUnchecked ? ChromiumBrowser.all.filter { !$0.isChecked } : [])
		adapters += browsers.map { browser in
			chromium(browser, home: home, readsOpenTabs: includesUnchecked)
		}
		if includesUnchecked {
			adapters += MozillaBrowser.allCases.map { browser in
				mozilla(browser, root: support.appending(path: browser.folder, directoryHint: .isDirectory))
			}
			adapters.append(safari(.init(home: home)))
		}
		return adapters.compactMap { $0 }
	}

	/// Whether the app offers sources that haven't had their real-browser check (DEV-840).
	///
	/// They're on unless the `MigrationUncheckedSources` default is set to `NO`.
	public static var offersUncheckedSources: Bool {
		offersUncheckedSources(in: .standard)
	}

	internal static func offersUncheckedSources(in defaults: UserDefaults) -> Bool {
		defaults.object(forKey: "MigrationUncheckedSources") as? Bool ?? true
	}

	/// Browsers on this Mac that aren't offered, listed so they aren't hidden (DEV-651).
	///
	/// Without `includesUnchecked`: Safari, which ships with macOS, and Firefox and Zen when
	/// their support folder exists; only the folder's presence is checked. With it, every
	/// one of them is offered and nothing is listed.
	public static func unsupportedBrowsers(
		home: URL = FileManager.default.homeDirectoryForCurrentUser,
		includesUnchecked: Bool = false
	) -> [MigrationUnsupportedBrowser] {
		guard !includesUnchecked else { return [] }

		let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
		let safari: MigrationUnsupportedBrowser = .init(
			id: MigrationSource.ID.safari.rawValue,
			name: "Safari",
			applicationIdentifier: "com.apple.Safari"
		)

		return [safari] + MozillaBrowser.allCases.compactMap { browser in
			let folder = support.appending(path: browser.folder, directoryHint: .isDirectory)
			return FileManager.default.fileExists(atPath: folder.path(percentEncoded: false))
			? .init(id: browser.rawValue, name: browser.name, applicationIdentifier: browser.applicationIdentifier)
			: nil
		}
	}

	/// When a file was last written, read from its attributes without opening it.
	internal static func modificationDate(of file: URL) -> Date? {
		let attributes = try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
		return attributes?[.modificationDate] as? Date
	}

	internal static func arc(_ root: URL) -> MigrationSourceAdapter? {
		let sidebar = root.appending(path: "StorableSidebar.json")
		guard FileManager.default.isReadableFile(atPath: sidebar.path) else { return nil }

		let id: MigrationSource.ID = .init(rawValue: "arc")
		let source: MigrationSource = .init(
			id: id,
			kind: .externalBrowser,
			name: "Arc",
			categories: [.favorites, .bookmarks, .openTabs, .history, .extensions],
			preservesOrganization: true,
			applicationIdentifier: "company.thebrowser.Browser",
			lastUsed: modificationDate(of: sidebar)
		)
		let userData = root.appending(path: "User Data", directoryHint: .isDirectory)
		return .init(source: source) {
			let localState = try? Data(contentsOf: userData.appending(path: "Local State"))
			let sidebar = try ArcSidebar.snapshot(
				sidebar: Data(contentsOf: sidebar),
				localState: localState
			)
			var snapshot = try chromiumProfileData(
				adding: sidebar,
				profiles: chromiumProfiles(localState),
				directory: { userData.appending(path: $0, directoryHint: .isDirectory) }
			)

			// Icons ride along without changing the snapshot ID (DEV-897).
			snapshot.records = ChromiumFavicons.addingIcons(to: snapshot.records) {
				userData.appending(path: $0, directoryHint: .isDirectory)
			}
			return snapshot
		}
	}

	/// Adds each profile's history and installed extensions to a snapshot (DEV-845).
	///
	/// History is read from a private copy of the profile's `History` database. A profile
	/// whose files can't be read just adds nothing. The snapshot's ID stays the one it
	/// had: a running browser writes its history and preferences on every visit, and
	/// both merge by key (history by URL, extensions install by ID), so newer rows when
	/// the import runs do no harm.
	internal static func chromiumProfileData(
		adding snapshot: MigrationSnapshot,
		profiles: [MigrationSourceProfile],
		history: Bool = true,
		extensions: Bool = true,
		directory: (String) -> URL
	) throws -> MigrationSnapshot {
		var snapshot = snapshot
		let fileManager: FileManager = .default
		for profile in profiles {
			let folder = directory(profile.id)
			let database = folder.appending(path: "History")
			if history, fileManager.isReadableFile(atPath: database.path(percentEncoded: false)) {
				let records = try? FirefoxPlaces.withCopy(of: database, logSuffixes: ["-journal", "-wal"]) {
					try ChromiumHistory.records($0, profile: profile)
				}
				snapshot.records += records ?? []
			}
			guard extensions else { continue }

			let listed = ChromiumExtensionSettings.extensions(
				preferences: try? Data(contentsOf: folder.appending(path: "Preferences")),
				securePreferences: try? Data(contentsOf: folder.appending(path: "Secure Preferences")),
				profile: profile,
				localizedName: { id, version, key, defaultLocale in
					guard let version else { return nil }

					let locales = folder.appending(path: "Extensions/\(id)/\(version)/_locales", directoryHint: .isDirectory)
					let preferred: [String?] = [Locale.current.identifier, Locale.current.language.languageCode?.identifier, defaultLocale, "en"]
					for locale in preferred.compactMap({ $0 }) {
						let file = locales.appending(path: "\(locale)/messages.json")
						if let message = ChromiumExtensionSettings.message(key, in: try? Data(contentsOf: file)) {
							return message
						}
					}
					return nil
				}
			)
			snapshot.issues += listed.map { value in
				.init(
					sourceItemID: profile.id + "/" + value.id,
					category: .extensions,
					reason: .reinstallManually(value)
				)
			}
		}
		return snapshot
	}

	internal static func chromium(
		_ browser: ChromiumBrowser,
		home: URL,
		readsOpenTabs: Bool = false
	) -> MigrationSourceAdapter? {
		chromium(
			id: browser.id.rawValue,
			name: browser.name,
			applicationIdentifier: browser.applicationIdentifier,
			root: browser.userData(home: home),
			keepsDefaultProfileAtRoot: browser.keepsDefaultProfileAtRoot,
			readsOpenTabs: readsOpenTabs
		)
	}

	internal static func chromium(
		id: String,
		name: String,
		applicationIdentifier: String? = nil,
		root: URL,
		keepsDefaultProfileAtRoot: Bool = false,
		readsOpenTabs: Bool = false
	) -> MigrationSourceAdapter? {
		let localState = root.appending(path: "Local State")
		guard FileManager.default.isReadableFile(atPath: localState.path) else { return nil }

		let source: MigrationSource = .init(
			id: .init(rawValue: id),
			kind: .externalBrowser,
			name: name,
			categories: readsOpenTabs ? [.bookmarks, .openTabs, .history] : [.bookmarks, .history],
			preservesOrganization: true,
			applicationIdentifier: applicationIdentifier,
			// Chromium rewrites Local State whenever it quits.
			lastUsed: modificationDate(of: localState)
		)

		@Sendable
		func directory(_ profile: String) -> URL {
			ChromiumProfileLayout.directory(
				profile: profile,
				userData: root,
				keepsDefaultProfileAtRoot: keepsDefaultProfileAtRoot
			)
		}

		return .init(source: source) {
			let state = try Data(contentsOf: localState)
			let profiles = try ChromiumProfileLayout.profiles(
				localState: state,
				keepsDefaultProfileAtRoot: keepsDefaultProfileAtRoot,
				name: name
			)
			let bookmarks = try ChromiumBookmarks.snapshot(
				browser: id,
				profiles: profiles,
				bookmarks: { profile in
					try? Data(contentsOf: directory(profile).appending(path: "Bookmarks"))
				},
				session: { profile in
					guard readsOpenTabs else { return nil }

					return ChromiumSession.latestSession(in: directory(profile))
				}
			)

			// The same History database as Arc's (DEV-845); extensions stay Arc's for now.
			return try chromiumProfileData(
				adding: bookmarks,
				profiles: profiles,
				extensions: false,
				directory: directory
			)
		}
	}

	/// Safari, offered whenever its folder exists: reading it needs Full Disk Access, which
	/// features ask for before inspecting it (DEV-840). Without access, `lastUsed` is unknown.
	internal static func safari(_ location: SafariData.Location) -> MigrationSourceAdapter? {
		guard FileManager.default.fileExists(atPath: location.library.path(percentEncoded: false))
		else { return nil }

		let source: MigrationSource = .init(
			id: .safari,
			kind: .externalBrowser,
			name: "Safari",
			categories: [.favorites, .bookmarks, .openTabs, .history],
			preservesOrganization: true,
			applicationIdentifier: "com.apple.Safari",
			lastUsed: modificationDate(of: location.bookmarks),
			requiresFullDiskAccess: true
		)
		return .init(source: source) {
			try SafariData.snapshot(location)
		}
	}

	/// Firefox and the browsers built on it that share its profile layout.
	internal enum MozillaBrowser: String, CaseIterable, Sendable {
		case firefox
		case zen

		internal var name: String {
			switch self {
			case .firefox: "Firefox"
			case .zen: "Zen"
			}
		}

		internal var applicationIdentifier: String {
			switch self {
			case .firefox: "org.mozilla.firefox"
			case .zen: "app.zen-browser.zen"
			}
		}

		/// The folder in Application Support that holds `profiles.ini`.
		internal var folder: String {
			switch self {
			case .firefox: "Firefox"
			case .zen: "zen"
			}
		}
	}

	internal static func mozilla(
		_ browser: MozillaBrowser,
		root: URL
	) -> MigrationSourceAdapter? {
		let ini = root.appending(path: "profiles.ini")
		guard
			let text = try? String(contentsOf: ini, encoding: .utf8),
			case let profiles = FirefoxPlaces.profiles(ini: text, root: root),
			profiles.contains(where: { FileManager.default.isReadableFile(atPath: $0.places.path(percentEncoded: false)) })
		else { return nil }

		let categories: [MigrationCategory] = switch browser {
		case .firefox: [.bookmarks, .openTabs, .history]
		case .zen: [.favorites, .bookmarks, .openTabs, .history]
		}
		let source: MigrationSource = .init(
			id: .init(rawValue: browser.rawValue),
			kind: .externalBrowser,
			name: browser.name,
			categories: categories,
			preservesOrganization: true,
			applicationIdentifier: browser.applicationIdentifier,
			// The browser writes its bookmarks database as it's used.
			lastUsed: profiles.compactMap { modificationDate(of: $0.places) }.max()
		)
		return .init(source: source) {
			try MozillaProfiles.snapshot(browser: browser, profiles: profiles)
		}
	}

	/// Identifies what was read rather than the file's bytes: browsers rewrite these
	/// files for unrelated reasons, which shouldn't invalidate a review.
	internal static func snapshotID(
		_ records: [MigrationRecord],
		issues: [MigrationIssue] = [],
		preferences: MigrationPortablePreferences? = nil
	) -> String {
		var hash = SHA256()
		func add(_ value: String) { hash.update(data: Data((value + "\u{1F}").utf8)) }
		if let preferences { add(digest(of: preferences)) }
		for record in records {
			add(record.sourceItemID)
			add("\(record.kind)")
			add(record.category.rawValue)
			add(record.title)
			add(record.url)
			add(record.currentURL ?? "")
			add(record.currentTitle ?? "")
			add(record.customTitle ?? "")
			add(record.space?.id ?? "")
			add(record.space?.name ?? "")
			add(record.profile?.id ?? "")
			add(record.lastVisited.map { "\($0.timeIntervalSince1970)" } ?? "")
			if let archived = record.archived {
				add(archived.groupID)
				add("\(archived.closedAt.timeIntervalSince1970)")
				add("\(archived.index)")
			}
			for folder in record.folders {
				add(folder.id)
				add(folder.name)
			}
		}
		for issue in issues { add(issue.sourceItemID ?? "") }
		return hash.finalize().map { String(format: "%02x", $0) }.joined()
	}

	internal static func digest(of preferences: MigrationPortablePreferences) -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		let data = (try? encoder.encode(preferences)) ?? Data()
		return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	/// Display names from a Chromium `Local State`, by profile directory, in its order.
	///
	/// Leaves out profiles a browser keeps for itself, such as Arc's `__ARC_SYSTEM_PROFILE`,
	/// unless `includingSystem` is set.
	internal static func chromiumProfiles(
		_ data: Data?,
		includingSystem: Bool = false
	) throws -> [MigrationSourceProfile] {
		guard let data else { return [] }

		let object = try JSONSerialization.jsonObject(with: data)
		guard
			let root = object as? [String: Any],
			let profile = root["profile"] as? [String: Any],
			let cache = profile["info_cache"] as? [String: Any]
		else { return [] }

		return cache.keys.sorted().compactMap { directory in
			let name = (cache[directory] as? [String: Any])?["name"] as? String
			let isSystem: Bool = isSystemProfile(name: name ?? directory) || isSystemProfile(name: directory)
			if !includingSystem, isSystem { return nil }
			return .init(id: directory, name: name?.isEmpty == false ? name ?? directory : directory)
		}
	}

	/// Arc names its internal profile `__ARC_SYSTEM_PROFILE`; it holds no user data.
	internal static func isSystemProfile(name: String) -> Bool {
		name.hasPrefix("__ARC_")
	}
}

// MARK: - Arc

/// Reads Arc's `StorableSidebar.json`.
///
/// The format is Arc's own and undocumented, so anything unexpected is treated as
/// absent rather than guessed at. Arrays alternate an identifier with its value.
internal enum ArcSidebar {
	internal static func snapshot(
		sidebar: Data,
		localState: Data?
	) throws -> MigrationSnapshot {
		guard
			let root = try JSONSerialization.jsonObject(with: sidebar) as? [String: Any],
			let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [Any],
			let container = spacesContainer(in: containers)
		else {
			throw MigrationFailure.unreadableSource("Arc's sidebar file has an unknown format.")
		}

		var names: [String: String] = [:]
		for profile in try MigrationBrowserSources.chromiumProfiles(localState, includingSystem: true) {
			names[profile.id] = profile.name
		}
		let items: [String: [String: Any]] = Dictionary(
			objects(in: container["items"]).compactMap { item in
				(item["id"] as? String).map { ($0, item) }
			},
			uniquingKeysWith: { first, _ in first }
		)
		var reader: Reader = .init(
			items: items,
			profileNames: names
		)
		reader.readFavorites(container["topAppsContainerIDs"])
		for space in objects(in: container["spaces"]) {
			reader.read(space)
		}
		return .init(
			id: MigrationBrowserSources.snapshotID(reader.records, issues: reader.issues),
			records: reader.records,
			issues: reader.issues
		)
	}

	/// The dictionaries of an alternating array.
	private static func objects(in value: Any?) -> [[String: Any]] {
		(value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
	}

	/// The container that holds the spaces; the others hold unrelated sidebar state.
	private static func spacesContainer(in containers: [Any]) -> [String: Any]? {
		containers.lazy
			.compactMap { $0 as? [String: Any] }
			.first { $0["spaces"] != nil }
	}

	private struct Reader {
		internal let items: [String: [String: Any]]
		internal let profileNames: [String: String]
		internal var records: [MigrationRecord]
		internal var issues: [MigrationIssue]

		internal init(
			items: [String: [String: Any]],
			profileNames: [String: String],
			records: [MigrationRecord] = [],
			issues: [MigrationIssue] = []
		) {
			self.items = items
			self.profileNames = profileNames
			self.records = records
			self.issues = issues
		}

		/// `[{"default": true} or {"custom": …}, id, …]`
		internal mutating func readFavorites(_ value: Any?) {
			guard let pairs = value as? [Any] else { return }

			for index in stride(from: 0, to: pairs.count - 1, by: 2) {
				guard
					let key = pairs[index] as? [String: Any],
					let id = pairs[index + 1] as? String
				else { continue }

				let profile = self.profile(key)
				guard !MigrationBrowserSources.isSystemProfile(name: profile.name) else { continue }

				for child in children(of: id) {
					walk(
						child,
						category: .favorites,
						folders: [],
						space: nil,
						profile: profile
					)
				}
			}
		}

		internal mutating func read(_ space: [String: Any]) {
			guard let id = space["id"] as? String else { return }

			let profile = self.profile(space["profile"] as? [String: Any] ?? [:])
			guard !MigrationBrowserSources.isSystemProfile(name: profile.name) else { return }

			let customInfo = space["customInfo"] as? [String: Any]
			let iconType = customInfo?["iconType"] as? [String: Any]
			let source: MigrationSourceSpace = .init(
				id: profile.id + MigrationBrowserSources.spaceSeparator + id,
				name: (space["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? profile.name,
				icon: Self.emoji(iconType?["icon"] as? String),
				// The space's colors (DEV-897).
				appearance: ArcSpaceTheme.appearance(customInfo?["windowTheme"]),
				profile: profile
			)
			guard let pairs = space["containerIDs"] as? [Any] else { return }

			// Fixes the space's place in the order, and keeps it if it's empty.
			records.append(
				.init(
					sourceItemID: "space:" + id,
					kind: .space,
					category: .bookmarks,
					space: source
				)
			)
			for index in stride(from: 0, to: pairs.count - 1, by: 2) {
				guard
					let kind = pairs[index] as? String,
					let container = pairs[index + 1] as? String,
					let category = Self.category(ofContainerKind: kind)
				else { continue }

				for child in children(of: container) {
					walk(
						child,
						category: category,
						folders: [],
						space: source,
						profile: nil
					)
				}
			}
		}

		private static func category(ofContainerKind kind: String) -> MigrationCategory? {
			switch kind {
			case "pinned": .bookmarks
			case "unpinned": .openTabs
			default: nil
			}
		}

		/// Arc's symbol names aren't known to match Arx's, so only emoji carry over.
		private static func emoji(_ icon: String?) -> String? {
			icon.flatMap(SpaceIcon.init(rawValue:)).flatMap { $0.isEmoji ? $0.rawValue : nil }
		}

		private func profile(_ value: [String: Any]) -> MigrationSourceProfile {
			let custom = (value["custom"] as? [String: Any])?["_0"] as? [String: Any]
			let directory = custom?["directoryBasename"] as? String ?? "Default"
			return .init(id: directory, name: profileNames[directory] ?? directory)
		}

		private func children(of id: String) -> [String] {
			items[id]?["childrenIds"] as? [String] ?? []
		}

		private mutating func walk(
			_ id: String,
			category: MigrationCategory,
			folders: [MigrationSourceFolder],
			space: MigrationSourceSpace?,
			profile: MigrationSourceProfile?
		) {
			guard
				let item = items[id],
				let data = item["data"] as? [String: Any]
			else { return }

			if let tab = data["tab"] as? [String: Any] {
				let customTitle = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
				records.append(
					.init(
						sourceItemID: id,
						category: category,
						title: customTitle ?? tab["savedTitle"] as? String ?? "",
						url: tab["savedURL"] as? String ?? "",
						folders: folders,
						space: space,
						profile: profile
					)
				)

			} else if data["list"] != nil {
				let contents = children(of: id)
				let folder: MigrationSourceFolder = .init(id: id, name: item["title"] as? String ?? "")
				if contents.isEmpty, category == .bookmarks {
					records.append(
						.init(
							sourceItemID: "folder:" + id,
							kind: .folder,
							category: category,
							folders: folders + [folder],
							space: space
						)
					)
				}
				for child in contents {
					walk(
						child,
						category: category,
						folders: folders + [folder],
						space: space,
						profile: profile
					)
				}

			} else if data["splitView"] != nil {
				// Arx saves no split groups yet, so its tabs stay in place side by side in the list.
				for child in children(of: id) {
					walk(
						child,
						category: category,
						folders: folders,
						space: space,
						profile: profile
					)
				}

			} else if data["easel"] != nil {
				issues.append(.init(sourceItemID: id, category: category, reason: .unsupported(.easel)))

			} else if data["arcDocument"] != nil {
				issues.append(.init(sourceItemID: id, category: category, reason: .unsupported(.note)))

			} else if data["welcomeToArc"] != nil {
				issues.append(
					.init(
						sourceItemID: id,
						category: category,
						reason: .unsupported(.onboardingItem)
					)
				)
			}
		}
	}
}

// MARK: - Chromium

/// Reads the `Bookmarks` file and the open tabs of each profile in a Chromium-based
/// browser, using Chromium's own formats. Each profile becomes one source space.
internal enum ChromiumBookmarks {
	internal static func snapshot(
		browser: String,
		localState: Data,
		bookmarks: (String) -> Data?,
		session: (String) -> Data? = { _ in nil }
	) throws -> MigrationSnapshot {
		try snapshot(
			browser: browser,
			profiles: MigrationBrowserSources.chromiumProfiles(localState),
			bookmarks: bookmarks,
			session: session
		)
	}

	internal static func snapshot(
		browser: String,
		profiles: [MigrationSourceProfile],
		bookmarks: (String) -> Data?,
		session: (String) -> Data? = { _ in nil }
	) throws -> MigrationSnapshot {
		var records: [MigrationRecord] = []

		for profile in profiles {
			let roots = bookmarks(profile.id)
				.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
				.flatMap { $0["roots"] as? [String: Any] }

			// A session file that can't be read only means no open tabs for this profile.
			let windows = session(profile.id).flatMap { try? ChromiumSession.windows($0) } ?? []
			guard roots != nil || !windows.isEmpty else { continue }

			let space: MigrationSourceSpace = .init(
				id: profile.id + MigrationBrowserSources.spaceSeparator + browser,
				name: profile.name,
				profile: profile
			)
			records.append(
				.init(
					sourceItemID: "space:" + space.id,
					kind: .space,
					category: .bookmarks,
					space: space
				)
			)
			records += openTabs(windows, profile: profile, space: space)
			guard let roots else { continue }

			// The bookmarks bar is the space's top level; the others keep their own folder.
			for (name, nested) in [("bookmark_bar", false), ("other", true), ("synced", true)] {
				guard let root = roots[name] as? [String: Any] else { continue }

				let hasChildren = (root["children"] as? [Any])?.isEmpty == false
				let folders: [MigrationSourceFolder] = nested && hasChildren
				? [.init(id: profile.id + "/" + name, name: root["name"] as? String ?? name)]
				: []
				for child in root["children"] as? [[String: Any]] ?? [] {
					walk(
						child,
						profile: profile,
						space: space,
						folders: folders,
						records: &records
					)
				}
			}
		}
		return .init(
			id: MigrationBrowserSources.snapshotID(records),
			records: records
		)
	}

	/// Every window's tabs, in order, as one list. Pinned tabs stay open tabs: in Chrome
	/// they belong to the window, not to a place that outlives it.
	///
	/// Chromium's tab IDs change every launch, so a tab is known by its URL and how many
	/// times that URL came before it. Importing again adds only tabs that weren't there.
	private static func openTabs(
		_ windows: [[ChromiumSession.Tab]],
		profile: MigrationSourceProfile,
		space: MigrationSourceSpace
	) -> [MigrationRecord] {
		var occurrences: [String: Int] = [:]
		return windows.joined().map { tab in
			let occurrence = occurrences[tab.url, default: 0]
			occurrences[tab.url] = occurrence + 1
			return .init(
				sourceItemID: profile.id + "/open/" + tab.url + "#\(occurrence)",
				category: .openTabs,
				title: tab.title,
				url: tab.url,
				space: space
			)
		}
	}

	private static func walk(
		_ node: [String: Any],
		profile: MigrationSourceProfile,
		space: MigrationSourceSpace,
		folders: [MigrationSourceFolder],
		records: inout [MigrationRecord]
	) {
		let nodeID = node["guid"] as? String ?? node["id"] as? String ?? UUID().uuidString
		let id = profile.id + "/" + nodeID
		switch node["type"] as? String {
		case "url":
			records.append(
				.init(
					sourceItemID: id,
					category: .bookmarks,
					title: node["name"] as? String ?? "",
					url: node["url"] as? String ?? "",
					folders: folders,
					space: space
				)
			)

		case "folder":
			let children = node["children"] as? [[String: Any]] ?? []
			let folder: MigrationSourceFolder = .init(id: id, name: node["name"] as? String ?? "")
			if children.isEmpty {
				records.append(
					.init(
						sourceItemID: "folder:" + id,
						kind: .folder,
						category: .bookmarks,
						folders: folders + [folder],
						space: space
					)
				)
			}
			for child in children {
				walk(
					child,
					profile: profile,
					space: space,
					folders: folders + [folder],
					records: &records
				)
			}

		default:
			break
		}
	}
}
