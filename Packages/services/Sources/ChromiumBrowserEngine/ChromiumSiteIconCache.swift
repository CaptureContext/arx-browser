import BrowserCore
import BrowserSiteIconClient
import Foundation

/// One answer from Chromium's favicon database.
internal struct ChromiumSiteIconAnswer: Equatable, Sendable {
	internal let png: Data

	/// The favicon the bitmap belongs to, shared by every page mapped to it (DEV-940).
	internal let iconURL: URL?

	internal init(
		png: Data,
		iconURL: URL?
	) {
		self.png = png
		self.iconURL = iconURL
	}
}

@MainActor
internal final class ChromiumSiteIconCache {
	/// The second argument says whether a database miss may fetch the icon: false for
	/// probes nobody shows (DEV-940).
	private let lookup: @MainActor @Sendable (BrowserSiteIconKey, Bool) async throws -> ChromiumSiteIconAnswer?
	private let configure: @MainActor @Sendable (Set<Profile.ID>) -> Void
	private let maximumEntries: Int
	private let maximumBytes: Int
	private let maximumConcurrent: Int

	/// Reads that may fetch a missing icon from its site, a few at a time, so a relaunch
	/// doesn't ask dozens of sites at once. Database reads go on past them.
	private let maximumFetching: Int

	/// The persisted fallback for pages Chromium has no icon for right now (DEV-809).
	private let stored: BrowserSiteIconStore?
	private var profiles: Set<Profile.ID> = []
	private var cache: [BrowserSiteIconKey: Entry] = [:]

	/// The bytes `cache` holds, kept as entries come and go instead of summed per answer.
	private var cachedBytes: Int = 0

	/// Cached keys by their last access, so the least recently used one is found without
	/// scanning the cache. Accesses only grow, so `oldestAccess` only moves forward.
	private var recency: [UInt64: BrowserSiteIconKey] = [:]
	private var oldestAccess: UInt64 = 1
	private var observers: [BrowserSiteIconKey: [UUID: AsyncStream<Data?>.Continuation]] = [:]

	/// The observers showing their icon on screen, which may have a missing one fetched from
	/// its site. The others are mounted off screen and read only what's on this Mac.
	private var fetchingObservers: [BrowserSiteIconKey: Set<UUID>] = [:]

	/// Every cached or observed key by its profile and comparable address, so a page's
	/// change finds its rows without visiting every row (DEV-940).
	private var addresses: [Address: Set<BrowserSiteIconKey>] = [:]

	/// Tracked keys whose canonical address is a guess (unusual escapes, hosts or
	/// characters). Every page change in their profile re-reads them, so a guess that
	/// differs from Chromium's canonical form can't leave a row stale.
	private var uncertain: [Profile.ID: Set<BrowserSiteIconKey>] = [:]

	/// The favicon each tracked key's last bitmap belonged to, kept while the key is
	/// observed even if its bitmap is evicted, and the keys by favicon. Pages mapped to
	/// one favicon share its bitmap, so a change to it changes them all (DEV-940).
	private var keyIcons: [BrowserSiteIconKey: URL] = [:]
	private var iconKeys: [Address: Set<BrowserSiteIconKey>] = [:]
	private var loads: [BrowserSiteIconKey: Load] = [:]
	private var queue: LookupQueue = .init()

	/// Queued reads that would fetch, waiting for a fetch slot.
	private var waitingFetches: LookupQueue = .init()
	private var nextLoad: UInt64 = 1
	private var access: UInt64 = 0
	private var observation: Task<Void, Never>?
	private var invalidationTask: Task<Void, Never>?
	private var pendingInvalidations: [Profile.ID: PendingInvalidation] = [:]
	private var refreshAfterLoad: Set<BrowserSiteIconKey> = []

	/// Unobserved keys read once more because a change named their page: if their
	/// favicon's bytes changed, the rows sharing it are re-read too (DEV-940).
	private var probes: Set<BrowserSiteIconKey> = []

	/// What each observed key's rows show now (a hash of the bitmap; absent for none),
	/// kept apart from the cache, so a refresh can tell a row whose bitmap the budget
	/// evicted is stale.
	private var shown: [BrowserSiteIconKey: Int] = [:]

	/// Keys whose last read failed (a timeout, a busy engine), favicon unknown: any page
	/// change in their profile reads them again.
	private var failures: Set<BrowserSiteIconKey> = []

	/// When each favicon last changed, counted in changes, with its newest bytes when a
	/// read discovered them (nil when a notification named it). A read that started
	/// earlier and answers with that favicon but other bytes reads again. Cleared
	/// whenever no read is in flight.
	private var iconChanges: [Address: (count: UInt64, bytes: Int?)] = [:]
	private var iconChangeCount: UInt64 = 0

	internal init(
		profiles: Set<Profile.ID>,
		maximumEntries: Int = 256,
		maximumBytes: Int = 4 * 1024 * 1024,
		maximumConcurrent: Int = 8,
		maximumFetching: Int = 4,
		stored: BrowserSiteIconStore? = nil,
		configure: @escaping @MainActor @Sendable (Set<Profile.ID>) -> Void,
		lookupIcon: @escaping @MainActor @Sendable (BrowserSiteIconKey, Bool) async throws -> ChromiumSiteIconAnswer?
	) {
		self.maximumEntries = max(1, maximumEntries)
		self.maximumBytes = max(1, maximumBytes)
		self.maximumConcurrent = max(1, min(maximumConcurrent, 16))
		self.maximumFetching = max(1, min(maximumFetching, self.maximumConcurrent))
		self.stored = stored
		self.configure = configure
		self.lookup = lookupIcon
		configureProfiles(profiles)
	}

	/// For answers without a favicon address.
	internal convenience init(
		profiles: Set<Profile.ID>,
		maximumEntries: Int = 256,
		maximumBytes: Int = 4 * 1024 * 1024,
		maximumConcurrent: Int = 8,
		maximumFetching: Int = 4,
		stored: BrowserSiteIconStore? = nil,
		configure: @escaping @MainActor @Sendable (Set<Profile.ID>) -> Void,
		lookup: @escaping @MainActor @Sendable (BrowserSiteIconKey) async throws -> Data?
	) {
		self.init(
			profiles: profiles,
			maximumEntries: maximumEntries,
			maximumBytes: maximumBytes,
			maximumConcurrent: maximumConcurrent,
			maximumFetching: maximumFetching,
			stored: stored,
			configure: configure,
			lookupIcon: { key, _ in try await lookup(key).map { .init(png: $0, iconURL: nil) } }
		)
	}

	deinit {
		observation?.cancel()
		invalidationTask?.cancel()
		for load in loads.values {
			load.task.cancel()
		}
	}

	internal var client: BrowserSiteIconClient {
		.init(
			configureProfiles: { [self] in configureProfiles($0) },
			icons: { [self] in icons($0, fetches: true) },
			cachedIcons: { [self] in icons($0, fetches: false) },
			removeProfiles: { [stored] in stored?.remove($0) }
		)
	}

	internal func observe(_ changes: AsyncStream<ChromiumSiteIconInvalidation>) {
		observation?.cancel()
		observation = Task { [weak self] in
			for await change in changes {
				guard !Task.isCancelled else { return }
				self?.scheduleInvalidation(change)
			}
			guard !Task.isCancelled else { return }
			self?.configureProfiles([])
		}
	}

	internal func configureProfiles(_ current: Set<Profile.ID>) {
		profiles = current
		configure(current)
		for key in Array(cache.keys) where !current.contains(key.profileID) {
			removeEntry(key)
		}
		queue.removeAll { !current.contains($0.profileID) }
		waitingFetches.removeAll { !current.contains($0.profileID) }
		pendingInvalidations = pendingInvalidations.filter { current.contains($0.key) }
		uncertain = uncertain.filter { current.contains($0.key) }
		refreshAfterLoad = refreshAfterLoad.filter { current.contains($0.profileID) }
		probes = probes.filter { current.contains($0.profileID) }
		shown = shown.filter { current.contains($0.key.profileID) }
		failures = failures.filter { current.contains($0.profileID) }
		for key in loads.keys.filter({ !current.contains($0.profileID) }) {
			loads.removeValue(forKey: key)?.task.cancel()
		}
		for key in observers.keys.filter({ !current.contains($0.profileID) }) {
			guard let removed = observers.removeValue(forKey: key)
			else { continue }
			fetchingObservers.removeValue(forKey: key)
			untrackIfUnused(key)
			for observer in removed.values {
				observer.yield(nil)
				observer.finish()
			}
		}
		startQueued()
	}

	/// Forgets misses and asks again for the icons still on screen, as after fetching for
	/// pages that aren't loaded is turned back on (DEV-796).
	internal func retryMisses() {
		for (key, entry) in cache where entry.data == nil {
			removeEntry(key)
		}
		for key in observers.keys where cache[key] == nil {
			if loads[key] != nil {
				// A lookup that started while fetching was off asks once more when it ends.
				refreshAfterLoad.insert(key)

			} else {
				enqueue(key)
			}
		}
	}

	internal func scheduleInvalidation(_ change: ChromiumSiteIconInvalidation) {
		guard profiles.contains(change.profileID), change.isCurrent()
		else { return }
		let pages = change.pageURLs.map { Set($0.compactMap { Address.canonical($0)?.page }) }
		let icons = Set(change.iconURLs.map(\.absoluteString))

		// A change without a favicon (a lifecycle one) is probed through its pages.
		var probed: [String: URL] = [:]
		if icons.isEmpty {
			for url in change.pageURLs ?? [] {
				guard let page = Address.canonical(url)?.page else { continue }
				probed[page] = url
			}
		}
		if var pending = pendingInvalidations[change.profileID] {
			// A burst refreshes the union of its pages, or the whole profile if any asks.
			pending.isCurrent = change.isCurrent
			pending.pages = pending.pages.flatMap { known in pages.map { known.union($0) } }
			pending.icons.formUnion(icons)
			pending.probed.merge(probed) { first, _ in first }
			pendingInvalidations[change.profileID] = pending

		} else {
			pendingInvalidations[change.profileID] = .init(
				isCurrent: change.isCurrent,
				pages: pages,
				icons: icons,
				probed: probed
			)
		}
		guard invalidationTask == nil else { return }

		invalidationTask = Task { [weak self] in
			await Task.yield()
			guard !Task.isCancelled else { return }
			self?.flushInvalidations()
		}
	}

	private func flushInvalidations() {
		invalidationTask = nil
		let changes = pendingInvalidations
		pendingInvalidations.removeAll()
		for (profileID, change) in changes {
			guard profiles.contains(profileID), change.isCurrent()
			else { continue }

			// A page's change names the addresses Chromium updated: the page and the
			// aliases its load went through, plus every page sharing the favicon it
			// reported. Only a profile-wide change, such as cleared history, re-reads
			// every key in the profile (DEV-940). Keys are still read exactly; a canonical
			// address only picks which ones; never a host fallback.
			guard let pages = change.pages else {
				for key in Set(addresses.filter({ $0.key.profileID == profileID }).values.flatMap(\.self)) {
					invalidate(key)
				}
				continue
			}

			if !change.icons.isEmpty, !loads.isEmpty {
				// A read in flight may answer with one of these favicons from before the
				// change, whatever favicon its key had: it checks when it answers. Reads
				// this change starts below begin after it.
				iconChangeCount += 1
				for icon in change.icons {
					iconChanges[.init(profileID: profileID, page: icon)] = (iconChangeCount, nil)
				}
			}

			// A change without a favicon (a lifecycle one, recovering a lost
			// notification) reads each page it names once more, tracked or not, cached
			// or not, so new bytes for that page's favicon reach the rows sharing it.
			let untracked = change.probed.filter { addresses[.init(profileID: profileID, page: $0.key)] == nil }
			var named: [BrowserSiteIconKey: Bool] = [:]
			for page in pages {
				for key in addresses[.init(profileID: profileID, page: page)] ?? [] {
					named[key] = change.probed[page] != nil
				}
			}
			let others = Set(change.icons.flatMap { iconKeys[.init(profileID: profileID, page: $0)] ?? [] })
				.union(uncertain[profileID] ?? [])
				.union(failures.filter { $0.profileID == profileID })
				.subtracting(named.keys)
			for (key, probing) in named {
				invalidate(key, probing: probing)
			}
			for key in others {
				invalidate(key)
			}
			for url in untracked.values {
				guard
					url.hasWebScheme,
					url.host != nil,
					url.absoluteString.utf8.count <= 8192
				else { continue }
				probe(.init(profileID: profileID, pageURL: url))
			}
		}
	}

	/// Observed icons stay cached until their refresh lands, so views keep showing them
	/// and an unchanged result is not re-delivered. Unobserved ones are forgotten, unless
	/// `probing` or already probed: then they are read once more.
	private func invalidate(
		_ key: BrowserSiteIconKey,
		probing: Bool = false
	) {
		guard observers[key] != nil else {
			guard probing || probes.contains(key)
			else { return removeEntry(key) }
			return probe(key)
		}

		// A lifecycle read repairs the rows sharing the page's favicon, so it survives
		// the page's own row going away.
		if probing { probes.insert(key) }

		if loads[key] != nil {
			// Drain one read, then refresh once for the whole notification burst.
			refreshAfterLoad.insert(key)

		} else {
			enqueue(key)
		}
	}

	/// Reads an unobserved key once more; its answer only repairs the rows sharing its
	/// favicon. One in flight may answer from before the change, so it reads again.
	private func probe(_ key: BrowserSiteIconKey) {
		probes.insert(key)
		if loads[key] != nil {
			refreshAfterLoad.insert(key)

		} else {
			enqueue(key)
		}
	}

	/// A key's images: the stored one at once, then Chromium's. `fetches` says the view
	/// shows it on screen, so a missing icon may be fetched from its site; a view mounted
	/// off screen reads only Chromium's database until one that shows it asks.
	internal func icons(
		_ key: BrowserSiteIconKey,
		fetches: Bool
	) -> AsyncStream<Data?> {
		guard
			profiles.contains(key.profileID),
			key.pageURL.hasWebScheme,
			key.pageURL.host != nil,
			key.pageURL.absoluteString.utf8.count <= 8192
		else {
			return .init { continuation in
				continuation.yield(nil)
				continuation.finish()
			}
		}

		let id = UUID()
		let stream = AsyncStream<Data?>(bufferingPolicy: .bufferingNewest(1)) { continuation in
			observers[key, default: [:]][id] = continuation
			if fetches { fetchingObservers[key, default: []].insert(id) }
			track(key)
			let image: Data?
			if let entry = cache[key] {
				setEntry(entry.data, iconURL: keyIcons[key], for: key)

				// A probe's answer reaches the store once a row shows it.
				if let data = entry.data { stored?.store(data, for: key) }
				image = entry.data ?? stored?.icon(for: key)

			} else {
				// Until Chromium answers, the last icon this page showed stands in.
				image = stored?.icon(for: key)
			}
			continuation.yield(image)
			show(image, for: key)
			continuation.onTermination = { [weak self] _ in
				Task { @MainActor in self?.removeObserver(id, key: key) }
			}
		}
		if cache[key] == nil { enqueue(key) }
		return stream
	}

	/// Shows a newly stored icon to a page's observers while Chromium has none for it.
	internal func storedIconChanged(_ key: BrowserSiteIconKey) {
		guard cache[key]?.data == nil, let icon = stored?.icon(for: key) else { return }

		for observer in observers[key]?.values ?? [:].values {
			observer.yield(icon)
		}
	}

	private func removeObserver(
		_ id: UUID,
		key: BrowserSiteIconKey
	) {
		observers[key]?.removeValue(forKey: id)
		let wasFetching = fetchingObservers[key]?.remove(id) != nil
		if fetchingObservers[key]?.isEmpty == true { fetchingObservers.removeValue(forKey: key) }
		guard observers[key]?.isEmpty == true else {
			if wasFetching { stopFetchNobodyWants(key) }
			return
		}
		observers.removeValue(forKey: key)
		shown.removeValue(forKey: key)
		untrackIfUnused(key)

		// A probe's read goes on for the rows sharing its favicon.
		guard !probes.contains(key) else { return }
		queue.remove(key)
		waitingFetches.remove(key)
		refreshAfterLoad.remove(key)
		loads.removeValue(forKey: key)?.task.cancel()
		startQueued()
	}

	/// The last view that let a key's icon be fetched has gone, while others still show what's
	/// stored: a fetch under way stops, and a database read takes its place, as when the command
	/// bar's highlight moves off a bang whose site Arx was asking for its icon (DEV-1311).
	private func stopFetchNobodyWants(_ key: BrowserSiteIconKey) {
		guard
			!wantsFetch(key),
			let load = loads[key],
			load.mayFetch
		else { return }

		loads.removeValue(forKey: key)
		load.task.cancel()
		refreshAfterLoad.remove(key)
		enqueue(key)
	}

	/// Whether a view shows the key's icon on screen, so a missing one may be fetched.
	private func wantsFetch(_ key: BrowserSiteIconKey) -> Bool {
		fetchingObservers[key]?.isEmpty == false
	}

	private func enqueue(_ key: BrowserSiteIconKey) {
		if loads[key] == nil {
			queue.append(key)
		}
		startQueued()
	}

	private func startQueued() {
		while
			loads.count < maximumConcurrent,
			nextLoad < UInt64.max,
			let key = nextQueued()
		{
			let id = nextLoad
			nextLoad += 1
			let mayFetch = wantsFetch(key)
			let task = Task { [weak self, lookup] in
				let answer: ChromiumSiteIconAnswer?
				let failed: Bool
				do {
					try Task.checkCancellation()
					answer = try await lookup(key, mayFetch)
					failed = false
				} catch {
					// Icons are optional decoration. Failed reads retain the globe fallback.
					answer = nil
					failed = true
				}
				guard !Task.isCancelled else { return }
				self?.complete(key, id: id, answer: answer, failed: failed)
			}
			loads[key] = .init(id: id, task: task, startedAt: iconChangeCount, mayFetch: mayFetch)
		}
	}

	/// The next read to start: a waiting fetch while a fetch slot is free, otherwise the next
	/// queued read. A fetch with no free slot waits apart, so database reads go on past it.
	private func nextQueued() -> BrowserSiteIconKey? {
		let fetching = loads.values.count(where: \.mayFetch)
		if fetching < maximumFetching {
			while let key = waitingFetches.popFirst() {
				if isReadable(key) { return key }
			}
		}
		while let key = queue.popFirst() {
			guard isReadable(key) else { continue }
			if wantsFetch(key), fetching >= maximumFetching {
				waitingFetches.append(key)
				continue
			}
			return key
		}
		return nil
	}

	/// Whether a queued key still needs a read: its profile is configured, a view or a
	/// probe wants it, and no read of it is running.
	private func isReadable(_ key: BrowserSiteIconKey) -> Bool {
		profiles.contains(key.profileID)
		&& (observers[key]?.isEmpty == false || probes.contains(key))
		&& loads[key] == nil
	}

	private func complete(
		_ key: BrowserSiteIconKey,
		id: UInt64,
		answer: ChromiumSiteIconAnswer?,
		failed: Bool = false
	) {
		guard
			let load = loads[key],
			load.id == id,
			profiles.contains(key.profileID)
		else { return }
		loads.removeValue(forKey: key)
		let answered = answer?.png.hashValue
		let overtaken = answer?.iconURL
			.flatMap { iconChanges[.init(profileID: key.profileID, page: $0.absoluteString)] }
			.map { $0.count > load.startedAt && $0.bytes != answered } ?? false
		if loads.isEmpty { iconChanges.removeAll() }
		if refreshAfterLoad.remove(key) != nil || overtaken {
			// A probe stays one for its follow-up read.
			enqueue(key)
			return
		}
		probes.remove(key)
		if !load.mayFetch, answer == nil {
			// A database-only miss isn't what a row on screen would get: it could still
			// fetch. A row shown on screen by now reads with fetching. Otherwise the old
			// answer, which this read was meant to replace, is forgotten, so a row that
			// comes on screen later reads again; rows off screen keep what they show.
			if wantsFetch(key) {
				enqueue(key)

			} else {
				removeEntry(key)
			}
			return startQueued()
		}
		if failed { failures.insert(key) } else { failures.remove(key) }

		let bounded = answer.flatMap { $0.png.count <= 65_536 ? $0.png : nil }
		let iconURL = bounded == nil ? nil : answer?.iconURL
		let previous = cache[key]
		setEntry(bounded, iconURL: iconURL, for: key)
		while cache.count > maximumEntries || cachedBytes > maximumBytes, let oldest = leastRecentlyUsed() {
			removeEntry(oldest)
		}

		// A live icon refreshes the stored one; a miss keeps showing what was stored. A
		// probe nobody shows stays out of the store, which keeps the tabs' icons.
		if let bounded, observers[key] != nil { stored?.store(bounded, for: key) }
		let image = bounded ?? stored?.icon(for: key)

		// Rows also update when what they show is no longer what they'd get, as when the stored
		// copy they show was forgotten (DEV-1108).
		let showsOther = observers[key] != nil && shown[key] != image?.hashValue
		if previous == nil || previous?.data != bounded || showsOther {
			for observer in observers[key]?.values ?? [:].values {
				observer.yield(image)
			}
			if observers[key] != nil { show(image, for: key) }
		}
		if let bounded, let iconURL {
			// Pages mapped to one favicon share its bitmap. A row showing other bytes,
			// or an unobserved answer cached with them, is stale though no change named
			// it, as after a lost notification (DEV-940). Rows are compared by what they
			// show, so a re-read row matches afterwards and the repair ends.
			let icon = Address(profileID: key.profileID, page: iconURL.absoluteString)
			let current = bounded.hashValue
			if previous?.data != bounded, !loads.isEmpty {
				// Reads in flight that started earlier and answer with other bytes for
				// this favicon read again.
				iconChangeCount += 1
				iconChanges[icon] = (iconChangeCount, current)
			}
			for sibling in iconKeys[icon] ?? [] where sibling != key && loads[sibling] == nil {
				let isStale = if observers[sibling] != nil {
					shown[sibling] != current
				} else {
					cache[sibling].map { $0.data != bounded } ?? false
				}
				if isStale { invalidate(sibling) }
			}
		}
		startQueued()
	}

	// MARK: - Bookkeeping

	private func show(
		_ image: Data?,
		for key: BrowserSiteIconKey
	) {
		shown[key] = image?.hashValue
	}

	/// Caches `data` for `key` as its most recent access, keeping the byte total, the
	/// recency order and the address index in step.
	private func setEntry(
		_ data: Data?,
		iconURL: URL?,
		for key: BrowserSiteIconKey
	) {
		access &+= 1
		let entry = Entry(data: data, access: access)
		if let replaced = cache.updateValue(entry, forKey: key) {
			cachedBytes -= replaced.bytes
			recency.removeValue(forKey: replaced.access)

		} else {
			track(key)
		}
		cachedBytes += entry.bytes
		recency[access] = key

		// A miss or failed read keeps the favicon the row may still show from the store.
		if data != nil { setIcon(iconURL, for: key) }
	}

	private func removeEntry(_ key: BrowserSiteIconKey) {
		guard let removed = cache.removeValue(forKey: key)
		else { return }

		cachedBytes -= removed.bytes
		recency.removeValue(forKey: removed.access)
		untrackIfUnused(key)
	}

	private func setIcon(
		_ iconURL: URL?,
		for key: BrowserSiteIconKey
	) {
		guard keyIcons[key] != iconURL else { return }
		if let old = keyIcons.removeValue(forKey: key) {
			let address = Address(profileID: key.profileID, page: old.absoluteString)
			iconKeys[address]?.remove(key)
			if iconKeys[address]?.isEmpty == true { iconKeys.removeValue(forKey: address) }
		}
		guard let iconURL else { return }
		keyIcons[key] = iconURL
		iconKeys[.init(profileID: key.profileID, page: iconURL.absoluteString), default: []].insert(key)
	}

	/// Amortized O(1): every access number is stepped over at most once.
	private func leastRecentlyUsed() -> BrowserSiteIconKey? {
		while oldestAccess <= access {
			if let key = recency[oldestAccess] { return key }
			oldestAccess += 1
		}
		return nil
	}

	private func track(_ key: BrowserSiteIconKey) {
		guard let canonical = Address.canonical(key.pageURL) else { return }
		addresses[.init(profileID: key.profileID, page: canonical.page), default: []].insert(key)
		if !canonical.isCertain { uncertain[key.profileID, default: []].insert(key) }
	}

	private func untrackIfUnused(_ key: BrowserSiteIconKey) {
		guard
			cache[key] == nil,
			observers[key] == nil,
			let canonical = Address.canonical(key.pageURL)
		else { return }

		setIcon(nil, for: key)
		failures.remove(key)
		let address = Address(profileID: key.profileID, page: canonical.page)
		addresses[address]?.remove(key)
		if addresses[address]?.isEmpty == true { addresses.removeValue(forKey: address) }
		uncertain[key.profileID]?.remove(key)
		if uncertain[key.profileID]?.isEmpty == true { uncertain.removeValue(forKey: key.profileID) }
	}

	private struct Entry {
		internal let data: Data?
		internal let access: UInt64

		internal var bytes: Int { data?.count ?? 0 }

		internal init(
			data: Data?,
			access: UInt64
		) {
			self.data = data
			self.access = access
		}
	}

	private struct PendingInvalidation {
		internal var isCurrent: @MainActor @Sendable () -> Bool

		/// Canonical page addresses to re-read, or nil for every key in the profile.
		internal var pages: Set<String>?

		/// Favicon addresses whose pages to re-read.
		internal var icons: Set<String>

		/// Pages named by changes without a favicon, by canonical address: probed.
		internal var probed: [String: URL]
	}

	/// A profile and an address: a page's in the canonical form Chromium's GURL gives
	/// it, or a favicon's as Chromium reported it. It only chooses which exact keys a
	/// change re-reads.
	private struct Address: Hashable {
		internal let profileID: Profile.ID
		internal let page: String

		internal init(
			profileID: Profile.ID,
			page: String
		) {
			self.profileID = profileID
			self.page = page
		}

		/// The page address as GURL canonicalizes an http(s) URL: lowercase scheme and
		/// host, no default port, `/` for an empty path and dot segments (`.`, `..`,
		/// and their `%2e` spellings) resolved. The fragment is dropped. `isCertain` is
		/// false when GURL might write it differently (user info, a host or path
		/// character GURL escapes or rewrites, a lowercase escape, a numeric host).
		internal static func canonical(_ url: URL) -> (page: String, isCertain: Bool)? {
			guard
				let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
				let scheme = components.scheme?.lowercased(),
				scheme == "http" || scheme == "https",
				let rawHost = components.percentEncodedHost,
				!rawHost.isEmpty
			else { return nil }

			let host = rawHost.lowercased()
			let rawPath = components.percentEncodedPath
			let path = removingDotSegments(rawPath)

			// GURL may turn `%2E` outside a dot segment into `.`, by a feature switch.
			let certain = path != nil
			&& components.percentEncodedUser == nil
			&& components.percentEncodedPassword == nil
			&& isCertainHost(host)
			&& rawPath.range(of: "%2e", options: .caseInsensitive) == nil
			&& isCertain(rawPath, allowed: pathCharacters)
			&& isCertain(components.percentEncodedQuery ?? "", allowed: queryCharacters)
			let port: String = switch (scheme, components.port) {
			case (_, nil), ("http", 80), ("https", 443): ""
			case let (_, port?): ":\(port)"
			}
			let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
			return ("\(scheme)://\(host)\(port)\(path ?? rawPath)\(query)", certain)
		}

		private static let pathCharacters: Set<Character> = .init(
			"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=:@/[]%"
		)

		/// GURL escapes `'` in a special scheme's query.
		private static let queryCharacters: Set<Character> = pathCharacters.subtracting("'").union("?")
		private static let hexDigits: Set<Character> = .init("0123456789ABCDEF")

		/// Only GURL-safe characters, and escapes as GURL writes them (uppercase).
		private static func isCertain(
			_ part: String,
			allowed: Set<Character>
		) -> Bool {
			let characters = Array(part)
			var index = 0
			while index < characters.count {
				let character = characters[index]
				guard allowed.contains(character) else { return false }
				if character == "%" {
					guard
						index + 2 < characters.count,
						hexDigits.contains(characters[index + 1]),
						hexDigits.contains(characters[index + 2])
					else { return false }
					index += 3

				} else {
					index += 1
				}
			}
			return true
		}

		/// A plain DNS name or a canonical dotted IPv4 address. GURL rewrites other
		/// numeric hosts (`0x7f.1`, `127.1`), IPv6 literals (`[0:0:0:0:0:0:0:1]` is
		/// `[::1]`) and internationalized names, so those are guesses.
		private static func isCertainHost(_ host: String) -> Bool {
			guard host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
			else { return false }
			let labels = host.split(separator: ".", omittingEmptySubsequences: false)
			let last = labels.last(where: { !$0.isEmpty }) ?? ""
			guard last.first?.isNumber == true else { return true }

			// A numeric last label makes it an IPv4 address: certain only as GURL writes one.
			return labels.count == 4 && labels.allSatisfy { label in
				guard let value = Int(label), (0...255).contains(value) else { return false }
				return String(value) == label
			}
		}

		/// RFC 3986 dot-segment removal, with GURL's `%2e` spellings of `.` and `..`.
		/// Nil when the path doesn't start with `/`.
		private static func removingDotSegments(_ path: String) -> String? {
			if path.isEmpty { return "/" }
			guard path.hasPrefix("/") else { return nil }

			var output: [Substring] = []
			let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
			for (index, segment) in segments.enumerated() {
				let isLast = index == segments.count - 1
				switch segment.lowercased().replacingOccurrences(of: "%2e", with: ".") {
				case ".":
					if isLast { output.append("") }

				case "..":
					if !output.isEmpty { output.removeLast() }
					if isLast { output.append("") }

				default:
					output.append(segment)
				}
			}
			return "/" + output.joined(separator: "/")
		}
	}

	/// Lookups waiting for a free slot, first in first out, each key at most once.
	/// Appending, popping and removing are O(1) (amortized); removal is lazy.
	private struct LookupQueue {
		private var order: [BrowserSiteIconKey] = []
		private var head: Int = 0
		private var members: Set<BrowserSiteIconKey> = []

		internal init() {}

		internal mutating func append(_ key: BrowserSiteIconKey) {
			guard members.insert(key).inserted else { return }
			order.append(key)
		}

		internal mutating func remove(_ key: BrowserSiteIconKey) {
			members.remove(key)
		}

		internal mutating func removeAll(where shouldRemove: (BrowserSiteIconKey) -> Bool) {
			members = members.filter { !shouldRemove($0) }
		}

		internal mutating func popFirst() -> BrowserSiteIconKey? {
			while head < order.count {
				let key = order[head]
				head += 1

				// A removed key, or an earlier place of one appended again, is skipped.
				guard members.remove(key) != nil else { continue }
				compact()
				return key
			}
			order.removeAll(keepingCapacity: true)
			head = 0
			return nil
		}

		private mutating func compact() {
			guard head >= 64, head * 2 >= order.count else { return }
			order.removeFirst(head)
			head = 0
		}
	}

	private struct Load {
		internal let id: UInt64
		internal let task: Task<Void, Never>

		/// `iconChangeCount` when the read started.
		internal let startedAt: UInt64

		/// False for a database-only probe.
		internal let mayFetch: Bool

		internal init(
			id: UInt64,
			task: Task<Void, Never>,
			startedAt: UInt64,
			mayFetch: Bool
		) {
			self.id = id
			self.task = task
			self.startedAt = startedAt
			self.mayFetch = mayFetch
		}
	}
}

extension AsyncStream<ChromiumSiteIconInvalidation>.Continuation {
	/// Yields a change. When the full buffer drops an older one, a profile-wide change
	/// for its profile takes its place, so no row loses its refresh (DEV-940).
	internal func yieldKeepingRefreshes(_ change: ChromiumSiteIconInvalidation) {
		var pending = [change]
		var recovered: Set<Profile.ID> = []
		while let next = pending.popLast() {
			guard
				case let .dropped(lost) = yield(next),
				recovered.insert(lost.profileID).inserted
			else { continue }
			pending.append(.init(profileID: lost.profileID, pageURLs: nil, isCurrent: lost.isCurrent))
		}
	}
}

/// Profile identity is captured before a closing page leaves the engine registry.
/// The predicate rejects notifications queued before profile removal/recreation.
internal struct ChromiumSiteIconInvalidation: Sendable {
	internal let profileID: Profile.ID

	/// The pages whose icons may have changed, or nil when any icon in the profile may have.
	internal let pageURLs: Set<URL>?

	/// Favicons whose bitmaps may have changed; every page mapped to one shares it.
	internal let iconURLs: Set<URL>
	internal let isCurrent: @MainActor @Sendable () -> Bool

	internal init(
		profileID: Profile.ID,
		pageURLs: Set<URL>?,
		iconURLs: Set<URL> = [],
		isCurrent: @escaping @MainActor @Sendable () -> Bool
	) {
		self.profileID = profileID
		self.pageURLs = pageURLs
		self.iconURLs = iconURLs
		self.isCurrent = isCurrent
	}
}
