import BrowserCore
import BrowserSiteIconClient
import Foundation

/// Keeps the dependency stable across construction before Chromium owns the run loop.
@MainActor
internal final class ChromiumSiteIconService {
	private let isRunning: @MainActor @Sendable () -> Bool
	private let configure: @MainActor @Sendable (Set<Profile.ID>) -> Void
	private let lookup: @MainActor @Sendable (BrowserSiteIconKey, Bool) async throws -> ChromiumSiteIconAnswer?
	private let changes: @MainActor @Sendable () -> AsyncStream<ChromiumSiteIconInvalidation>
	private let stored: BrowserSiteIconStore?
	private let setFetch: @MainActor @Sendable (Bool) -> Void
	private var profiles: Set<Profile.ID>
	private var fetchesUnloadedIcons: Bool = true
	private var cache: ChromiumSiteIconCache?

	internal init(
		profiles: Set<Profile.ID>,
		isRunning: @escaping @MainActor @Sendable () -> Bool,
		configure: @escaping @MainActor @Sendable (Set<Profile.ID>) -> Void,
		lookupIcon: @escaping @MainActor @Sendable (BrowserSiteIconKey, Bool) async throws -> ChromiumSiteIconAnswer?,
		changes: @escaping @MainActor @Sendable () -> AsyncStream<ChromiumSiteIconInvalidation>,
		stored: BrowserSiteIconStore? = nil,
		setFetch: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
	) {
		self.profiles = profiles
		self.isRunning = isRunning
		self.configure = configure
		self.lookup = lookupIcon
		self.changes = changes
		self.stored = stored
		self.setFetch = setFetch
		configure(profiles)
	}

	/// For answers without a favicon address.
	internal convenience init(
		profiles: Set<Profile.ID>,
		isRunning: @escaping @MainActor @Sendable () -> Bool,
		configure: @escaping @MainActor @Sendable (Set<Profile.ID>) -> Void,
		lookup: @escaping @MainActor @Sendable (BrowserSiteIconKey) async throws -> Data?,
		changes: @escaping @MainActor @Sendable () -> AsyncStream<ChromiumSiteIconInvalidation>,
		stored: BrowserSiteIconStore? = nil,
		setFetch: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
	) {
		self.init(
			profiles: profiles,
			isRunning: isRunning,
			configure: configure,
			lookupIcon: { key, _ in try await lookup(key).map { .init(png: $0, iconURL: nil) } },
			changes: changes,
			stored: stored,
			setFetch: setFetch
		)
	}

	internal var client: BrowserSiteIconClient {
		.init(
			configureProfiles: { [self] in configureProfiles($0) },
			icons: { [self] in icons($0, fetches: true) },
			cachedIcons: { [self] in icons($0, fetches: false) },
			removeProfiles: { [stored] in stored?.remove($0) },
			setFetchesUnloadedIcons: { [self] in setFetchesUnloadedIcons($0) },
			seed: { [self] in seed($0) }
		)
	}

	/// Stores imported icons for pages without one and shows them where nothing live is
	/// showing yet (DEV-897).
	private func seed(_ icons: [BrowserSiteIconKey: Data]) {
		guard let stored else { return }

		for (key, png) in icons where profiles.contains(key.profileID) {
			guard stored.seed(png, for: key) else { continue }

			cache?.storedIconChanged(key)
		}
	}

	private func setFetchesUnloadedIcons(_ enabled: Bool) {
		guard fetchesUnloadedIcons != enabled else { return }
		fetchesUnloadedIcons = enabled
		setFetch(enabled)
		if enabled { cache?.retryMisses() }
	}

	private func configureProfiles(_ current: Set<Profile.ID>) {
		profiles = current
		if let cache {
			cache.configureProfiles(current)

		} else {
			configure(current)
		}
	}

	private func icons(
		_ key: BrowserSiteIconKey,
		fetches: Bool
	) -> AsyncStream<Data?> {
		// A pre-ready read must not become a permanent negative cache entry. The stored icon,
		// if any, is still shown.
		guard isRunning() else {
			let icon = profiles.contains(key.profileID) ? stored?.icon(for: key) : nil
			return .init { continuation in
				if let icon { continuation.yield(icon) }
				continuation.finish()
			}
		}
		if let cache { return cache.icons(key, fetches: fetches) }

		let cache = ChromiumSiteIconCache(
			profiles: profiles,
			stored: stored,
			configure: configure,
			lookupIcon: lookup
		)
		cache.observe(changes())
		self.cache = cache
		return cache.icons(key, fetches: fetches)
	}
}
