import BrowserCore
import Foundation

/// The app's own copy of the last site icon each page showed, one file per profile, so a tab
/// whose page isn't loaded still shows its icon after a relaunch (DEV-809).
///
/// It's a soft cache. A live icon always replaces the stored one; a missing or failed live
/// read never erases it. Profiles are sandboxes: every entry belongs to exactly one profile's
/// file, and a removed profile's file is deleted.
@MainActor
public final class BrowserSiteIconStore {
	public typealias Writer = @Sendable (Data, URL) throws -> Void

	private let directory: URL
	private let maximumEntries: Int
	private let maximumBytes: Int
	private let writeDelay: Duration
	private let now: @Sendable () -> Date
	private let writer: Writer
	private let queue: DispatchQueue = .init(label: "dev.capturecontext.arx.site-icon-store")
	private var profiles: [Profile.ID: [String: Entry]] = [:]

	/// Each loaded profile's stored bytes, kept as icons come and go.
	private var bytes: [Profile.ID: Int] = [:]
	private var dirty: Set<Profile.ID> = []
	private var scheduledWrite: Task<Void, Never>?

	public init(
		directory: URL,
		maximumEntries: Int = 512,
		maximumBytes: Int = 4 * 1024 * 1024,
		writeDelay: Duration = .milliseconds(500),
		now: @escaping @Sendable () -> Date = Date.init,
		writer: @escaping Writer = { try $0.write(to: $1, options: .atomic) }
	) {
		self.directory = directory
		self.maximumEntries = max(1, maximumEntries)
		self.maximumBytes = max(1, maximumBytes)
		self.writeDelay = writeDelay
		self.now = now
		self.writer = writer
	}

	/// The stored PNG for a page, if any.
	public func icon(for key: BrowserSiteIconKey) -> Data? {
		guard var entry = entries(key.profileID)[key.pageURL.absoluteString]
		else { return nil }

		// Recency only orders eviction; it rides along with the next real write.
		entry.used = now()
		profiles[key.profileID]?[key.pageURL.absoluteString] = entry
		return entry.png
	}

	/// Replaces the stored icon with a live one.
	public func store(
		_ png: Data,
		for key: BrowserSiteIconKey
	) {
		guard Self.accepts(png), Self.accepts(key.pageURL) else { return }
		let profileID = key.profileID
		let address = key.pageURL.absoluteString

		// Load first, then change the profile's entries in place: a local copy of the
		// dictionary would be copied whole on every write (DEV-940).
		let existing = entries(profileID)[address]
		if existing?.png == png {
			profiles[profileID]?[address]?.used = now()
			return
		}

		profiles[profileID]?[address] = .init(png: png, used: now())
		bytes[profileID, default: 0] += png.count - (existing?.png.count ?? 0)
		evict(profileID)
		markDirty(profileID)
	}

	/// Forgets a page's stored icon: Chromium dropped the icon it had fetched for the page as
	/// another host's (DEV-1108), so the copy here would keep showing it.
	public func forget(_ key: BrowserSiteIconKey) {
		let address = key.pageURL.absoluteString
		guard let existing = entries(key.profileID)[address] else { return }

		profiles[key.profileID]?[address] = nil
		bytes[key.profileID, default: 0] -= existing.png.count
		markDirty(key.profileID)
	}

	/// Stores an icon from another browser for a page that has none yet (DEV-897). Returns
	/// whether it was stored: a page's own icon, stored or live later, always wins.
	@discardableResult
	public func seed(
		_ png: Data,
		for key: BrowserSiteIconKey
	) -> Bool {
		guard entries(key.profileID)[key.pageURL.absoluteString] == nil else { return false }

		store(png, for: key)
		return entries(key.profileID)[key.pageURL.absoluteString] != nil
	}

	/// Keeps only the given pages in each listed profile, so the cache follows the tabs that
	/// still exist instead of every page a tab ever showed.
	public func retain(
		_ keys: Set<BrowserSiteIconKey>,
		in profileIDs: Set<Profile.ID>
	) {
		for profileID in profileIDs {
			let kept = Set(keys.filter { $0.profileID == profileID }.map(\.pageURL.absoluteString))
			let current = entries(profileID)
			let retained = current.filter { kept.contains($0.key) }
			guard retained.count != current.count else { continue }
			profiles[profileID] = retained
			bytes[profileID] = Self.bytes(retained)
			markDirty(profileID)
		}
	}

	/// Deletes removed profiles' icons, in memory and on disk.
	public func remove(_ profileIDs: Set<Profile.ID>) {
		for profileID in profileIDs {
			profiles[profileID] = [:]
			bytes[profileID] = 0
			dirty.remove(profileID)
			let file = file(profileID)
			queue.async {
				try? FileManager.default.removeItem(at: file)
			}
		}
	}

	/// Writes pending changes now instead of after the coalescing delay.
	public func flush() {
		scheduledWrite?.cancel()
		scheduledWrite = nil
		let pending = dirty
		dirty.removeAll()
		guard !pending.isEmpty else { return }

		let encoder = PropertyListEncoder()
		encoder.outputFormat = .binary
		let writes: [(Data, URL)] = pending.compactMap { profileID in
			guard let data = try? encoder.encode(File(entries: profiles[profileID] ?? [:]))
			else { return nil }
			return (data, file(profileID))
		}
		queue.async { [directory, writer] in
			try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			for (data, file) in writes {
				try? writer(data, file)
			}
		}
	}

	/// Blocks until queued disk work finishes. Tests and shutdown use it.
	public func waitForDisk() {
		queue.sync {}
	}

	// MARK: - Private

	private func entries(_ profileID: Profile.ID) -> [String: Entry] {
		if let loaded = profiles[profileID] { return loaded }

		let loaded = load(profileID)
		profiles[profileID] = loaded
		bytes[profileID] = Self.bytes(loaded)
		return loaded
	}

	private func load(_ profileID: Profile.ID) -> [String: Entry] {
		// Wait for this profile's queued writes or removal so the read sees them.
		waitForDisk()
		guard
			let data = try? Data(contentsOf: file(profileID)),
			let file = try? PropertyListDecoder().decode(File.self, from: data)
		else { return [:] }

		var valid = file.entries.filter { Self.accepts($0.value.png) && URL(string: $0.key).map(Self.accepts) == true }
		var total = Self.bytes(valid)
		while valid.count > maximumEntries || total > maximumBytes {
			guard let oldest = valid.min(by: { $0.value.used < $1.value.used })
			else { break }
			valid.removeValue(forKey: oldest.key)
			total -= oldest.value.png.count
		}
		return valid
	}

	/// Drops the least recently used icons while the profile is over budget. Only a write
	/// that crosses the budget pays for the search.
	private func evict(_ profileID: Profile.ID) {
		while
			let count = profiles[profileID]?.count,
			count > maximumEntries || bytes[profileID, default: 0] > maximumBytes,
			let oldest = profiles[profileID]?.min(by: { $0.value.used < $1.value.used })
		{
			profiles[profileID]?.removeValue(forKey: oldest.key)
			bytes[profileID, default: 0] -= oldest.value.png.count
		}
	}

	private static func bytes(_ entries: [String: Entry]) -> Int {
		entries.values.reduce(0) { $0 + $1.png.count }
	}

	private func markDirty(_ profileID: Profile.ID) {
		dirty.insert(profileID)
		guard scheduledWrite == nil else { return }
		scheduledWrite = Task { [weak self, writeDelay] in
			try? await Task.sleep(for: writeDelay)
			guard !Task.isCancelled else { return }
			self?.flush()
		}
	}

	private func file(_ profileID: Profile.ID) -> URL {
		directory
			.appendingPathComponent(profileID.rawValue.uuidString)
			.appendingPathExtension("plist")
	}

	private static func accepts(_ png: Data) -> Bool {
		!png.isEmpty && png.count <= 65_536
	}

	private static func accepts(_ url: URL) -> Bool {
		url.hasWebScheme
		&& url.host != nil
		&& url.absoluteString.utf8.count <= 8192
	}

	private struct File: Codable {
		internal var entries: [String: Entry]
	}

	private struct Entry: Codable, Equatable {
		internal var png: Data
		internal var used: Date
	}
}
