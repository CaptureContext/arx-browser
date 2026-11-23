import BrowserCore
import CryptoKit
import Foundation

/// Saved pictures of pages, so a hover card keeps one after its tab unloads (DEV-730).
///
/// Each profile has its own folder, `<directory>/<profile UUID>/`, with one JPEG per page named
/// by the SHA-256 of its address, so file names don't reveal it. A file's modification date is
/// when the picture was taken. Profiles are sandboxes: nothing is read across folders, clearing
/// a profile's history deletes its pictures, and private windows never reach the store.
///
/// A picture is dated when its capture started (`takenAt`), so one still being taken or
/// encoded when a profile's pictures are deleted is refused when it lands, instead of bringing
/// the folder back.
public actor BrowserPagePreviewStore {
	public static let maximumPictureBytes: Int = 512 * 1024

	private let directory: URL
	private let maximumEntries: Int
	private let maximumBytes: Int
	private var indexes: [Profile.ID: [String: Entry]]

	/// When each profile's pictures were last deleted; older pictures can't be stored after it.
	private var removedAt: [Profile.ID: Date]
	private let now: @Sendable () -> Date

	private struct Entry: Equatable {
		internal var bytes: Int
		internal var takenAt: Date
	}

	public init(
		directory: URL,
		maximumEntries: Int = 256,
		maximumBytes: Int = 32 * 1024 * 1024,
		now: @escaping @Sendable () -> Date = Date.init
	) {
		self.directory = directory
		self.maximumEntries = max(1, maximumEntries)
		self.maximumBytes = max(1, maximumBytes)
		self.indexes = [:]
		self.removedAt = [:]
		self.now = now
	}

	/// The saved picture of a page, if any.
	public func picture(for key: BrowserPagePreviewKey) -> BrowserPagePicture? {
		guard
			Self.accepts(key.pageURL),
			let entry = index(key.profileID)[Self.name(key.pageURL)],
			let jpeg = try? Data(contentsOf: file(key)),
			Self.accepts(jpeg)
		else { return nil }
		return .init(jpeg: jpeg, takenAt: entry.takenAt)
	}

	/// Saves a picture, replacing the page's older one, then evicts the oldest pictures past
	/// the profile's bounds.
	public func store(
		_ picture: BrowserPagePicture,
		for key: BrowserPagePreviewKey
	) {
		guard Self.accepts(picture.jpeg), Self.accepts(key.pageURL) else { return }

		// A capture that started before the profile's pictures were deleted is stale.
		if let removed = removedAt[key.profileID], picture.takenAt <= removed { return }
		let folder = folder(key.profileID)
		let file = file(key)
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try picture.jpeg.write(to: file, options: .atomic)
			try FileManager.default.setAttributes([.modificationDate: picture.takenAt], ofItemAtPath: file.path)
		} catch {
			try? FileManager.default.removeItem(at: file)
			indexes[key.profileID]?[Self.name(key.pageURL)] = nil
			return
		}
		var entries = index(key.profileID)
		entries[Self.name(key.pageURL)] = .init(bytes: picture.jpeg.count, takenAt: picture.takenAt)
		indexes[key.profileID] = evicting(entries, in: key.profileID)
	}

	/// Keeps only the given pages' pictures in each listed profile, so the store follows the
	/// tabs that still exist instead of every page a tab ever showed.
	public func retain(
		_ keys: Set<BrowserPagePreviewKey>,
		in profileIDs: Set<Profile.ID>
	) {
		for profileID in profileIDs {
			let kept = Set(keys.filter { $0.profileID == profileID }.map { Self.name($0.pageURL) })
			var entries = index(profileID)
			for name in entries.keys where !kept.contains(name) {
				try? FileManager.default.removeItem(at: file(name, in: profileID))
				entries[name] = nil
			}
			indexes[profileID] = entries
		}
	}

	/// Deletes a profile's pictures taken at or after `since`, or every one of them for nil.
	public func remove(
		_ profileID: Profile.ID,
		since: Date?
	) {
		removedAt[profileID] = now()
		guard let since else {
			try? FileManager.default.removeItem(at: folder(profileID))
			indexes[profileID] = [:]
			return
		}
		var entries = index(profileID)
		for (name, entry) in entries where entry.takenAt >= since {
			try? FileManager.default.removeItem(at: file(name, in: profileID))
			entries[name] = nil
		}
		indexes[profileID] = entries
	}

	/// Deletes removed profiles' pictures.
	public func remove(_ profileIDs: Set<Profile.ID>) {
		for profileID in profileIDs {
			remove(profileID, since: nil)
		}
	}

	// MARK: - Private

	private func index(_ profileID: Profile.ID) -> [String: Entry] {
		if let loaded = indexes[profileID] { return loaded }

		let loaded = load(profileID)
		indexes[profileID] = loaded
		return loaded
	}

	private func load(_ profileID: Profile.ID) -> [String: Entry] {
		let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
		guard let files = try? FileManager.default.contentsOfDirectory(
			at: folder(profileID),
			includingPropertiesForKeys: keys,
			options: [.skipsHiddenFiles]
		) else { return [:] }

		var entries: [String: Entry] = [:]
		for file in files where file.pathExtension == "jpg" {
			let name = file.deletingPathExtension().lastPathComponent
			guard
				Self.isName(name),
				let values = try? file.resourceValues(forKeys: Set(keys)),
				values.isRegularFile == true,
				let bytes = values.fileSize,
				(1...Self.maximumPictureBytes).contains(bytes),
				let takenAt = values.contentModificationDate
			else {
				try? FileManager.default.removeItem(at: file)
				continue
			}
			entries[name] = .init(bytes: bytes, takenAt: takenAt)
		}
		return evicting(entries, in: profileID)
	}

	private func evicting(
		_ entries: [String: Entry],
		in profileID: Profile.ID
	) -> [String: Entry] {
		var entries = entries
		var bytes = entries.values.reduce(0) { $0 + $1.bytes }
		while entries.count > maximumEntries || bytes > maximumBytes {
			guard let oldest = entries.min(by: { $0.value.takenAt < $1.value.takenAt })
			else { break }
			try? FileManager.default.removeItem(at: file(oldest.key, in: profileID))
			entries.removeValue(forKey: oldest.key)
			bytes -= oldest.value.bytes
		}
		return entries
	}

	private func folder(_ profileID: Profile.ID) -> URL {
		directory.appendingPathComponent(profileID.rawValue.uuidString, isDirectory: true)
	}

	private func file(_ key: BrowserPagePreviewKey) -> URL {
		file(Self.name(key.pageURL), in: key.profileID)
	}

	private func file(
		_ name: String,
		in profileID: Profile.ID
	) -> URL {
		folder(profileID).appendingPathComponent(name).appendingPathExtension("jpg")
	}

	/// The page's file name: the SHA-256 of its address, in hex.
	internal static func name(_ url: URL) -> String {
		SHA256.hash(data: Data(url.absoluteString.utf8))
			.map { String(format: "%02x", $0) }
			.joined()
	}

	private static func isName(_ name: String) -> Bool {
		name.count == 64 && name.allSatisfy(\.isHexDigit)
	}

	private static func accepts(_ jpeg: Data) -> Bool {
		(1...maximumPictureBytes).contains(jpeg.count) && jpeg.starts(with: [0xFF, 0xD8, 0xFF])
	}

	private static func accepts(_ url: URL) -> Bool {
		url.hasWebScheme
		&& url.host() != nil
		&& url.absoluteString.utf8.count <= 8192
	}
}
