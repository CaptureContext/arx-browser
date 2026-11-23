import BrowserCore
import Foundation
import Synchronization

public enum AutomationInventoryBuilder {
	public static func items(
		client: AutomationClient,
		organization: BrowserOrganization,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> [AutomationInventoryItem] {
		guard client.allowsRead else { return [] }

		derivations?.record(\.inventories)
		let pass = Pass(client: client, organization: organization, snapshots: snapshots, indexed: true)
		var items: [AutomationInventoryItem] = []

		// Profile items exist only for whole-profile grants, the targets of profile
		// and space management. Other grants keep their inventory unchanged.
		for profile in organization.profiles {
			if let item = pass.item(for: profile) { items.append(item) }
		}
		for space in organization.spaces {
			if let item = pass.item(for: space) { items.append(item) }
		}
		let folderRevisions = pass.folderRevisions()
		for folder in organization.folders {
			if let item = pass.item(for: folder, revisions: folderRevisions) { items.append(item) }
		}
		for tab in organization.tabs {
			if let item = pass.item(for: tab) { items.append(item) }
		}
		return items
	}

	/// The item `items(client:organization:snapshots:)` lists first with this ID (and kind),
	/// derived without building the rest of the inventory. Authority is checked exactly as
	/// the full projection checks it, so a call that targets one item validates only that item.
	public static func item(
		_ id: UUID,
		kind: AutomationInventoryItem.Kind? = nil,
		client: AutomationClient,
		organization: BrowserOrganization,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationInventoryItem? {
		guard client.allowsRead else { return nil }

		let pass = Pass(client: client, organization: organization, snapshots: snapshots, indexed: false)
		func accepts(_ candidate: AutomationInventoryItem.Kind) -> Bool { kind == nil || kind == candidate }

		if
			accepts(.profile),
			let profile = organization.profiles[id: .init(rawValue: id)],
			let item = pass.item(for: profile)
		{
			return item
		}
		if
			accepts(.space),
			let space = organization.spaces[id: .init(rawValue: id)],
			let item = pass.item(for: space)
		{
			return item
		}
		if
			accepts(.folder),
			let folder = organization.folders[id: .init(rawValue: id)],
			AutomationAccess.permitsSpace(folder.spaceID, client: client, organization: organization),
			let item = pass.item(for: folder, revisions: pass.folderRevisions())
		{
			return item
		}
		if
			accepts(.tab),
			let tab = organization.tabs[id: .init(rawValue: id)],
			let item = pass.item(for: tab)
		{
			return item
		}
		return nil
	}

	/// Profiles the client can see: those it holds a profile scope for, plus the
	/// profiles of the items it can see. Names come from the canonical organization.
	public static func profiles(
		client: AutomationClient,
		organization: BrowserOrganization,
		items: [AutomationInventoryItem]
	) -> [AutomationProfileItem] {
		guard client.allowsRead else { return [] }

		let visible = Set(items.map(\.profileID))
		return organization.profiles
			.filter { visible.contains($0.id.rawValue) || AutomationAccess.permitsProfile($0.id, client: client) }
			.map { .init(id: $0.id.rawValue, name: String($0.name.prefix(256)), appearance: $0.appearance) }
	}

	/// Every granted tab's current revision, for resource subscriptions.
	public static func changes(
		client: AutomationClient,
		organization: BrowserOrganization,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationChangeDigest {
		let tabs = items(client: client, organization: organization, snapshots: snapshots)
			.filter { $0.kind == .tab }
			.prefix(AutomationChangeDigest.maximumTabs)
		return .init(tabs: Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.revision) }))
	}

	public static func page(
		_ items: [AutomationInventoryItem],
		cursor: String?,
		limit: Int
	) throws -> AutomationInventory {
		guard (1 ... 100).contains(limit) else { throw AutomationFailure.invalidRequest }

		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		let fingerprint = AutomationSecurity.digest(try encoder.encode(items))
		let offset: Int
		if let cursor {
			let parts = cursor.split(separator: ":")
			guard
				parts.count == 2,
				parts[0] == fingerprint,
				let parsed = Int(parts[1]),
				parsed >= 0,
				parsed < items.count
			else { throw AutomationFailure.staleCursor }

			offset = parsed
		} else {
			offset = 0
		}

		let end = min(offset + limit, items.count)
		return .init(
			items: Array(items[offset..<end]),
			nextCursor: end < items.count ? "\(fingerprint):\(end)" : nil
		)
	}

	/// The digest that makes a revision opaque, memoized by its complete input.
	fileprivate static func revision(
		_ components: [String],
		client: AutomationClient
	) -> String {
		let input = [client.grantRevision.uuidString] + components
		return revisionCache.value(for: input) { digest(input) }
	}

	fileprivate static func digest(_ input: [String]) -> String {
		derivations?.record(\.revisions)
		let data = (try? JSONEncoder().encode(input)) ?? Data()
		return AutomationSecurity.digest(data)
	}

	private static let revisionCache: AutomationDerivationCache<[String], String> = .init(limit: 4096)
	fileprivate static let tabItemCache: AutomationDerivationCache<
		TabItemInput,
		AutomationInventoryItem
	> = .init(limit: 8192)
}

extension AutomationInventoryBuilder {
	/// Counts the inventory's costly derivations while bound to `$derivations`, so tests can
	/// pin how much work one request does as the number of tabs grows.
	public final class Derivations: Sendable {
		public struct Counts: Equatable, Sendable {
			/// Complete inventory projections.
			public var inventories: Int = 0

			/// Walks of the organization to find where tabs are: once per projection, or once per single lookup.
			public var locationWalks: Int = 0

			/// Revision digests computed rather than found in the cache.
			public var revisions: Int = 0

			public init() {}
		}

		private let storage: Mutex<Counts> = .init(Counts())

		public init() {}

		public var counts: Counts { storage.withLock { $0 } }

		fileprivate func record(_ count: WritableKeyPath<Counts, Int>) {
			storage.withLock { $0[keyPath: count] += 1 }
		}
	}

	@TaskLocal
	public static var derivations: Derivations?
}

/// Everything a tab item is derived from, and nothing else. The item is computed from this
/// value alone, so a cached item can't be stale: any change to the grant revision, the tab,
/// its disclosed location or its session changes the key.
fileprivate struct TabItemInput: Hashable, Sendable {
	internal struct Session: Hashable, Sendable {
		internal var revision: UInt64
		internal var documentRevision: UInt64?
		internal var isLoading: Bool

		/// DEV-1116: the file the tab's navigation became, while it has no page of its own.
		internal var downloadedFile: String?
		internal var failed: Bool

		/// DEV-873: a tab Arx unloaded to free memory loads again like a saved one.
		internal var isUnloaded: Bool

		/// DEV-1009: the page's renderer stopped answering.
		internal var notAnswering: Bool = false

		/// DEV-1016: why its renderer ended, when the tab failed that way.
		internal var failureReason: String?
	}

	internal var grantRevision: UUID
	internal var bindsDocument: Bool
	internal var tabID: UUID
	internal var profileID: UUID
	internal var spaceID: UUID?
	internal var parentID: UUID?
	internal var isPinned: Bool
	internal var title: String
	internal var url: URL
	internal var automationClientID: UUID?
	internal var session: Session?

	internal var item: AutomationInventoryItem {
		let state: AutomationInventoryItem.SessionState
		if let session {
			if session.isUnloaded {
				state = .unloaded
			} else if session.failed {
				state = .failed
			} else if session.notAnswering {
				state = .notAnswering
			} else {
				state = session.isLoading ? .loading : .ready
			}
		} else {
			state = .unloaded
		}

		let sanitized = AutomationAccess.sanitizedURL(url)

		// Exact-tab grants bind location privately in permitsTab. Their public
		// revision must not reveal changes to otherwise excluded ancestry.
		var revisionValues = [
			grantRevision.uuidString,
			tabID.uuidString, profileID.uuidString, spaceID?.uuidString ?? "undisclosed",
			parentID?.uuidString ?? "root", isPinned ? "pinned" : "open",
			String(session?.revision ?? 0), url.absoluteString, title,
		]
		if bindsDocument {
			revisionValues.append(session?.documentRevision.map(String.init) ?? "no-document-authority")
		}

		var item = AutomationInventoryItem(
			id: tabID,
			kind: .tab,
			title: String(title.prefix(256)),
			profileID: profileID,
			spaceID: spaceID,
			parentID: parentID,
			url: sanitized.flatMap { $0.utf8.count <= 2048 ? $0 : nil },
			host: sanitized == nil ? nil : url.host(percentEncoded: false),
			isPinned: isPinned,
			downloadedFile: session?.downloadedFile.map { String($0.prefix(256)) },
			sessionState: state,
			revision: AutomationInventoryBuilder.digest(revisionValues),
			automationClientID: automationClientID
		)
		if state == .failed { item.failureReason = session?.failureReason }
		return item
	}
}

extension AutomationInventoryBuilder {
	/// DEV-1016: the inventory's `failureReason` for a renderer end.
	internal static func failureReason(_ end: BrowserNavigation.RendererEnd) -> String {
		if end.isRepeated {
			return end.cause == .outOfMemory || end.cause == .killed ? "keepsRunningOutOfMemory" : "keepsCrashing"
		}
		return end.cause.rawValue
	}
}

/// One projection of the organization for one client. A full pass indexes tab locations and
/// folder membership once; a single-item pass resolves only what its item needs.
private struct Pass {
	internal struct Placement: Hashable {
		internal var tabID: BrowserCore.Tab.ID
		internal var spaceID: Space.ID
	}

	internal struct Index {
		internal var locations: [BrowserCore.Tab.ID: BrowserOrganization.TabLocation]

		/// Each folder's first containing folder, in organization order.
		internal var folderParents: [Folder.ID: Folder.ID]

		/// Each tab's first containing folder within a space, in organization order.
		internal var tabFolders: [Placement: Folder.ID]
	}

	internal let client: AutomationClient
	internal let organization: BrowserOrganization
	internal let snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	internal let index: Index?

	internal init(
		client: AutomationClient,
		organization: BrowserOrganization,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		indexed: Bool
	) {
		self.client = client
		self.organization = organization
		self.snapshots = snapshots
		guard indexed else {
			self.index = nil
			return
		}

		AutomationInventoryBuilder.derivations?.record(\.locationWalks)
		var folderParents: [Folder.ID: Folder.ID] = [:]
		var tabFolders: [Placement: Folder.ID] = [:]
		for folder in organization.folders {
			for child in folder.children {
				switch child {
				case let .folder(id):
					if folderParents[id] == nil { folderParents[id] = folder.id }

				case let .tab(id):
					let placement = Placement(tabID: id, spaceID: folder.spaceID)
					if tabFolders[placement] == nil { tabFolders[placement] = folder.id }
				}
			}
		}
		self.index = .init(
			locations: organization.tabLocations,
			folderParents: folderParents,
			tabFolders: tabFolders
		)
	}

	internal func item(for profile: Profile) -> AutomationInventoryItem? {
		guard AutomationAccess.permitsProfile(profile.id, client: client) else { return nil }

		return .init(
			id: profile.id.rawValue,
			kind: .profile,
			title: String(profile.name.prefix(256)),
			profileID: profile.id.rawValue,
			revision: AutomationInventoryBuilder.revision(
				["profile", profile.id.rawValue.uuidString, profile.name],
				client: client
			),
			appearance: profile.appearance
		)
	}

	internal func item(for space: Space) -> AutomationInventoryItem? {
		guard AutomationAccess.permitsSpace(space.id, client: client, organization: organization)
		else { return nil }

		return .init(
			id: space.id.rawValue,
			kind: .space,
			title: String(space.name.prefix(256)),
			profileID: space.profileID.rawValue,
			revision: AutomationInventoryBuilder.revision(
				[space.id.rawValue.uuidString, space.profileID.rawValue.uuidString, space.name],
				client: client
			),
			appearance: space.appearance
		)
	}

	internal func item(
		for folder: Folder,
		revisions: [Folder.ID: String]
	) -> AutomationInventoryItem? {
		guard
			AutomationAccess.permitsSpace(folder.spaceID, client: client, organization: organization),
			let space = organization.spaces[id: folder.spaceID],
			let revision = revisions[folder.id]
		else { return nil }

		let parent: Folder.ID?
		if let index {
			parent = index.folderParents[folder.id]
		} else {
			parent = organization.folders.first(where: { $0.children.contains(.folder(folder.id)) })?.id
		}
		return .init(
			id: folder.id.rawValue,
			kind: .folder,
			title: String(folder.name.prefix(256)),
			profileID: space.profileID.rawValue,
			spaceID: space.id.rawValue,
			parentID: parent?.rawValue,
			revision: revision
		)
	}

	internal func item(for tab: BrowserCore.Tab) -> AutomationInventoryItem? {
		let location = location(of: tab.id)
		guard AutomationAccess.permitsTab(tab, at: location, client: client, organization: organization)
		else { return nil }

		let spaceID: Space.ID?
		if
			case let .space(id) = location,
			AutomationAccess.permitsSpace(id, client: client, organization: organization)
		{
			spaceID = id
		} else {
			spaceID = nil
		}

		let parent: Folder.ID?
		if let spaceID {
			if let index {
				parent = index.tabFolders[.init(tabID: tab.id, spaceID: spaceID)]
			} else {
				parent = organization.folders.first {
					$0.spaceID == spaceID && $0.children.contains(.tab(tab.id))
				}?.id
			}
		} else {
			parent = nil
		}

		let snapshot = snapshots[tab.id]
		let input = TabItemInput(
			grantRevision: client.grantRevision,
			bindsDocument: client.allowsScreenshots || client.allowsPageContent,
			tabID: tab.id.rawValue,
			profileID: tab.profileID.rawValue,
			spaceID: spaceID?.rawValue,
			parentID: parent?.rawValue,
			isPinned: tab.savedDestination != nil,
			title: tab.displayTitle,
			url: snapshot?.navigation.url ?? tab.restoration.url,
			automationClientID: tab.automationClientID,
			session: snapshot.map {
				.init(
					revision: $0.revision,
					documentRevision: $0.documentRevision,
					isLoading: $0.navigation.isLoading,
					downloadedFile: $0.navigation.download?.filename,
					failed: $0.navigation.errorCode != nil,
					isUnloaded: $0.navigation.isUnloaded,
					notAnswering: $0.navigation.isUnresponsive,
					failureReason: $0.navigation.failure == .rendererStopped
					? $0.navigation.rendererEnd.map(AutomationInventoryBuilder.failureReason)
					: nil
				)
			}
		)
		return AutomationInventoryBuilder.tabItemCache.value(for: input) { input.item }
	}

	private func location(of id: BrowserCore.Tab.ID) -> AutomationTabLocation? {
		if let index { return index.locations[id].map(AutomationTabLocation.init) }

		AutomationInventoryBuilder.derivations?.record(\.locationWalks)
		return AutomationAccess.location(of: id, in: organization)
	}

	/// Moves authorize the complete ordered subtree, including each parent relationship.
	/// Navigation and disclosure do not change membership or require a new move approval.
	internal func folderRevisions() -> [Folder.ID: String] {
		let permittedFolders = organization.folders.filter {
			AutomationAccess.permitsSpace($0.spaceID, client: client, organization: organization)
		}
		let folders = Dictionary(
			permittedFolders.map { ($0.id, $0) },
			uniquingKeysWith: { first, _ in first }
		)
		var parents: [Folder.ID: Folder.ID] = [:]
		for folder in permittedFolders {
			for case let .folder(id) in folder.children where parents[id] == nil {
				parents[id] = folder.id
			}
		}

		var revisions: [Folder.ID: String] = [:]
		var visiting: Set<Folder.ID> = []
		func resolve(_ id: Folder.ID) -> String {
			if let value = revisions[id] { return value }
			guard
				let folder = folders[id],
				let profile = organization.spaces[id: folder.spaceID]?.profileID,
				visiting.insert(id).inserted
			else {
				return AutomationInventoryBuilder.revision(
					["unavailable-folder", id.rawValue.uuidString],
					client: client
				)
			}

			defer { visiting.remove(id) }
			var components = [
				"folder", id.rawValue.uuidString, parents[id]?.rawValue.uuidString ?? "root",
				folder.spaceID.rawValue.uuidString, profile.rawValue.uuidString, folder.name
			]
			for child in folder.children {
				switch child {
				case let .folder(id):
					components += ["folder", id.rawValue.uuidString, resolve(id)]

				case let .tab(id):
					components += [
						"tab", id.rawValue.uuidString,
						organization.tabs[id: id]?.profileID.rawValue.uuidString ?? "missing"
					]
				}
			}

			let value = AutomationInventoryBuilder.revision(components, client: client)
			revisions[id] = value
			return value
		}

		for folder in permittedFolders { _ = resolve(folder.id) }
		return revisions
	}
}

/// A bounded memo shared by every projection. Values depend only on their keys, so the
/// cache is emptied when full rather than tracking recency.
fileprivate final class AutomationDerivationCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
	private let storage: Mutex<[Key: Value]> = .init([:])
	private let limit: Int

	internal init(limit: Int) {
		self.limit = limit
	}

	internal func value(
		for key: Key,
		derive: () -> Value
	) -> Value {
		if let cached = storage.withLock({ $0[key] }) { return cached }

		let value = derive()
		storage.withLock { values in
			if values.count >= limit { values.removeAll(keepingCapacity: true) }
			values[key] = value
		}
		return value
	}
}
