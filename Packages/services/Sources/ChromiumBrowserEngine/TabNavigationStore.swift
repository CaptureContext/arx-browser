import BrowserCore
import Foundation

/// DEV-878: each ordinary tab's back/forward history, as the engine serializes a page's entries.
/// One small file per tab in a folder per profile, apart from the workspace file so that stays
/// small. Writes go to a background queue; the latest write is kept in memory until it lands,
/// so a tab reopened meanwhile reads it. Private tabs never reach it.
@MainActor
internal final class TabNavigationStore {
	private let directory: URL
	private let queue: DispatchQueue = .init(label: "dev.capturecontext.arx.tab-navigation", qos: .utility)

	/// Writes on their way to disk, by tab; nil data is a removal.
	private var unwritten: [Tab.ID: (generation: Int, profile: Profile.ID, data: Data?)] = [:]

	/// Profiles whose history is being removed: their files read as gone until it's done.
	private var clearing: [Profile.ID: Int] = [:]
	private var generation: Int = 0

	internal init(directory: URL) {
		self.directory = directory
	}

	internal func load(
		_ tab: Tab.ID,
		profile: Profile.ID
	) -> Data? {
		if let pending = unwritten[tab] { return pending.data }
		guard clearing[profile] == nil else { return nil }

		return try? Data(contentsOf: file(tab, profile: profile))
	}

	internal func save(
		_ data: Data,
		for tab: Tab.ID,
		profile: Profile.ID
	) {
		write(data, for: tab, profile: profile)
	}

	internal func remove(
		_ tab: Tab.ID,
		profile: Profile.ID
	) {
		write(nil, for: tab, profile: profile)
	}

	/// Clear History: every tab of the profile forgets its back/forward history.
	internal func removeProfile(_ profile: Profile.ID) {
		let folder = self.folder(profile)
		unwritten = unwritten.filter { $0.value.profile != profile }
		generation += 1
		let generation = self.generation
		clearing[profile] = generation
		queue.async { [weak self] in
			try? FileManager.default.removeItem(at: folder)
			Task { @MainActor [weak self] in
				guard self?.clearing[profile] == generation else { return }
				self?.clearing[profile] = nil
			}
		}
	}

	/// At launch: forgets the history of every tab that is neither in the workspace nor in its
	/// archive any more.
	internal func prune(keeping tabs: Set<Tab.ID>) {
		let directory = self.directory
		queue.async {
			let manager = FileManager.default
			let profiles = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
			for profile in profiles {
				let files = (try? manager.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil)) ?? []
				for file in files {
					let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
					guard id.map({ !tabs.contains(.init(rawValue: $0)) }) ?? true else { continue }
					try? manager.removeItem(at: file)
				}
			}
		}
	}

	/// Waits for every write so far, as the app quits.
	internal func flush() {
		queue.sync {}
	}

	private func write(
		_ data: Data?,
		for tab: Tab.ID,
		profile: Profile.ID
	) {
		generation += 1
		let generation = self.generation
		unwritten[tab] = (generation, profile, data)
		let file = self.file(tab, profile: profile)
		queue.async { [weak self] in
			let manager = FileManager.default
			if let data {
				try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
				try? data.write(to: file, options: [.atomic])
			} else {
				try? manager.removeItem(at: file)
			}
			Task { @MainActor [weak self] in
				guard self?.unwritten[tab]?.generation == generation else { return }
				self?.unwritten[tab] = nil
			}
		}
	}

	private func folder(_ profile: Profile.ID) -> URL {
		directory.appendingPathComponent(profile.rawValue.uuidString.lowercased(), isDirectory: true)
	}

	private func file(
		_ tab: Tab.ID,
		profile: Profile.ID
	) -> URL {
		folder(profile).appendingPathComponent("\(tab.rawValue.uuidString.lowercased()).navigation")
	}
}
