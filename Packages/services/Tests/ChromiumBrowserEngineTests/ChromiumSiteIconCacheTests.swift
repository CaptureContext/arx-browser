import BrowserCore
import BrowserSiteIconClient
import CustomDump
import Foundation
import Testing
import _TestSupport

@testable import ChromiumBrowserEngine

@Suite(.timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumSiteIconCacheTests {
	@Test
	internal func storedIconShowsUntilChromiumAnswersAndSurvivesAMiss() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arx-site-icons-\(UUID())")
		defer { try? FileManager.default.removeItem(at: directory) }
		let stored = BrowserSiteIconStore(directory: directory)
		let fixture = Fixture(stored: stored)
		defer { fixture.finish() }
		stored.store(Data([9]), for: fixture.key)

		var images = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		let unloaded = await images.next()
		expectNoDifference(unloaded, .some(Data([9])))
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: nil)
		let afterMiss = await images.next()
		expectNoDifference(afterMiss, .some(Data([9])))
		expectNoDifference(stored.icon(for: fixture.key), Data([9]))

		// A profile without a stored icon still opens with nothing.
		let other = BrowserSiteIconKey(profileID: Fixture.otherProfile, pageURL: fixture.key.pageURL)
		var others = fixture.cache.client.icons(other).makeAsyncIterator()
		let none = await others.next()
		expectNoDifference(none, .some(nil))
	}

	/// A stored copy forgotten during a read (Chromium dropped the icon it came from as another
	/// host's, DEV-1108) leaves the rows that showed it, though both reads missed.
	@Test
	internal func aForgottenStoredIconLeavesTheRowsShowingIt() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arx-site-icons-\(UUID())")
		defer { try? FileManager.default.removeItem(at: directory) }
		let stored = BrowserSiteIconStore(directory: directory)
		let fixture = Fixture(stored: stored)
		defer { fixture.finish() }
		stored.store(Data([9]), for: fixture.key)

		var images = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		let first = await images.next()
		expectNoDifference(first, .some(Data([9])))
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: nil)
		let kept = await images.next()
		expectNoDifference(kept, .some(Data([9])))

		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [fixture.key.pageURL]))
		try await fixture.waitForCalls(2)
		stored.forget(fixture.key)
		fixture.reply(1, bytes: nil)
		let forgotten = await images.next()
		expectNoDifference(forgotten, .some(nil))
	}

	@Test
	internal func loadingThePageRefreshesTheStoredIcon() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arx-site-icons-\(UUID())")
		defer { try? FileManager.default.removeItem(at: directory) }
		let stored = BrowserSiteIconStore(directory: directory)
		let fixture = Fixture(stored: stored)
		defer { fixture.finish() }
		stored.store(Data([9]), for: fixture.key)

		var images = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		_ = await images.next()
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: [1])
		let live = await images.next()
		expectNoDifference(live, .some(Data([1])))

		// The page loads again with a new icon: Chromium reports the change.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change)
		try await fixture.waitForCalls(2)
		fixture.reply(1, bytes: [2])
		let refreshed = await images.next()
		expectNoDifference(refreshed, .some(Data([2])))
		expectNoDifference(stored.icon(for: fixture.key), Data([2]))
		stored.flush()
		stored.waitForDisk()
		expectNoDifference(BrowserSiteIconStore(directory: directory).icon(for: fixture.key), Data([2]))
	}

	@Test
	internal func subscribersCoalesceAndProfilesNeverShareCachedBytes() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		var first = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		var second = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		_ = await first.next()
		_ = await second.next()
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: [1])
		let a = await first.next()
		let b = await second.next()
		expectNoDifference(a, .some(Data([1])))
		expectNoDifference(b, .some(Data([1])))

		let other = BrowserSiteIconKey(profileID: Fixture.otherProfile, pageURL: fixture.key.pageURL)
		var third = fixture.cache.client.icons(other).makeAsyncIterator()
		_ = await third.next()
		try await fixture.waitForCalls(2)
		expectNoDifference(fixture.calls, [fixture.key, other])
		fixture.reply(1, bytes: [2])
		let c = await third.next()
		expectNoDifference(c, .some(Data([2])))
	}

	@Test
	internal func profileRemovalClearsSubscribersAndRejectsLateReplyAfterRecreation() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		var old = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		_ = await old.next()
		try await fixture.waitForCalls(1)
		fixture.cache.configureProfiles([])
		let removed = await old.next()
		let ended = await old.next()
		expectNoDifference(removed, .some(nil))
		expectNoDifference(ended, nil)
		expectNoDifference(fixture.configured.last, [])

		fixture.cache.configureProfiles([Fixture.profile])
		var replacement = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		_ = await replacement.next()
		try await fixture.waitForCalls(2)
		fixture.reply(0, bytes: [1])
		fixture.reply(1, bytes: [2])
		let current = await replacement.next()
		expectNoDifference(current, .some(Data([2])))
	}

	@Test
	internal func notificationBurstDrainsOneOldLookupAndRefreshesOnce() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		var images = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		_ = await images.next()
		try await fixture.waitForCalls(1)

		let validity = InvalidationValidity()
		for _ in 0..<10 {
			fixture.cache.scheduleInvalidation(validity.change)
		}
		try await validity.waitForChecks(11)
		expectNoDifference(fixture.calls.count, 1)
		fixture.reply(0, bytes: [1])
		try await fixture.waitForCalls(2)
		fixture.reply(1, bytes: [2])
		let current = await images.next()
		expectNoDifference(current, .some(Data([2])))
		expectNoDifference(fixture.calls.count, 2)
	}

	@Test
	internal func profileUpdateRefreshesCanonicalAndSameDocumentSavedAliasesOnlyInItsProfile() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let canonicalAlias = BrowserSiteIconKey(
			profileID: Fixture.profile,
			pageURL: URL(string: "https://fixture.invalid")!
		)
		let sameDocumentAlias = fixture.key
		let otherProfile = BrowserSiteIconKey(
			profileID: Fixture.otherProfile,
			pageURL: canonicalAlias.pageURL
		)
		var canonical = fixture.cache.client.icons(canonicalAlias).makeAsyncIterator()
		var sameDocument = fixture.cache.client.icons(sameDocumentAlias).makeAsyncIterator()
		var other = fixture.cache.client.icons(otherProfile).makeAsyncIterator()
		_ = await canonical.next()
		_ = await sameDocument.next()
		_ = await other.next()
		try await fixture.waitForCalls(3)
		for (index, key) in fixture.calls.enumerated() {
			fixture.reply(index, bytes: key == otherProfile ? [9] : nil)
		}
		_ = await canonical.next()
		_ = await sameDocument.next()
		_ = await other.next()

		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change)
		try await fixture.waitForCalls(5)
		expectNoDifference(Set(fixture.calls.suffix(2)), [canonicalAlias, sameDocumentAlias])
		for index in 3..<5 {
			fixture.reply(index, bytes: [7])
		}
		let canonicalImage = await canonical.next()
		let sameDocumentImage = await sameDocument.next()
		expectNoDifference(canonicalImage, .some(Data([7])))
		expectNoDifference(sameDocumentImage, .some(Data([7])))

		var otherCached = fixture.cache.client.icons(otherProfile).makeAsyncIterator()
		let untouched = await otherCached.next()
		expectNoDifference(untouched, .some(Data([9])))
		expectNoDifference(fixture.calls.count, 5)
	}

	@Test
	internal func pageLoadWithAHundredRowsMountedReadsOnlyThatPage() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let keys = (0..<100).map { index in
			BrowserSiteIconKey(
				profileID: Fixture.profile,
				pageURL: URL(string: "https://site\(index).fixture.invalid/page")!
			)
		}
		let rows = keys.map { Row(fixture.cache.client.icons($0)) }
		defer { rows.forEach { $0.stop() } }
		for index in keys.indices {
			try await fixture.waitForCalls(index + 1)
			fixture.reply(index, bytes: [UInt8(index)])
			try await rows[index].waitForValues(2)
		}
		expectNoDifference(Set(fixture.calls), Set(keys))

		// One page finished loading; its alias spelling differs only in canonical form.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [
			URL(string: "HTTPS://Site42.fixture.invalid:443/page#top")!,
			URL(string: "https://unobserved.fixture.invalid/")!,
		]))

		// The row is re-read, and the untracked alias is probed once in case it shares
		// a favicon with a row: two lookups, not a hundred.
		try await fixture.waitForCalls(102)
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(fixture.calls.count, 102)
		expectNoDifference(fixture.calls[100], keys[42])
		expectNoDifference(fixture.calls[101].pageURL, URL(string: "https://unobserved.fixture.invalid/"))
		fixture.reply(100, bytes: [200])
		fixture.reply(101, bytes: nil)
		try await rows[42].waitForValues(3)
		expectNoDifference(rows[42].values.last, .some(Data([200])))

		// Only a profile-wide change, such as cleared history, re-reads every row, the rows
		// on screen four at a time, as they may fetch.
		fixture.cache.scheduleInvalidation(validity.change)
		try await fixture.waitForCalls(102 + 4)
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(fixture.calls.count, 102 + 4)
	}

	@Test
	internal func pageChangeForgetsUnobservedIconsOfThatPageOnly() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let other = BrowserSiteIconKey(
			profileID: Fixture.profile,
			pageURL: URL(string: "https://fixture.invalid/other")!
		)
		for (index, key) in [fixture.key, other].enumerated() {
			var images = fixture.cache.client.icons(key).makeAsyncIterator()
			_ = await images.next()
			try await fixture.waitForCalls(index + 1)
			fixture.reply(index, bytes: [1])
			_ = await images.next()
		}

		// Let the ended streams unsubscribe.
		for _ in 0..<100 {
			await Task.yield()
		}

		// Chromium reported the page's favicon, so nothing needs probing.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(
			pageURLs: [fixture.key.pageURL],
			iconURLs: [URL(string: "https://fixture.invalid/favicon.ico")!]
		))
		try await validity.waitForChecks(2)
		expectNoDifference(fixture.calls.count, 2)

		var otherAgain = fixture.cache.client.icons(other).makeAsyncIterator()
		let cached = await otherAgain.next()
		expectNoDifference(cached, .some(Data([1])))
		var keyAgain = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		_ = await keyAgain.next()
		try await fixture.waitForCalls(3)
		expectNoDifference(fixture.calls.last, fixture.key)
	}

	@Test
	internal func burstOfPageChangesRefreshesTheirUnionOnce() async throws {
		let fixture = Fixture(maximumConcurrent: 1)
		defer { fixture.finish() }
		let keys = (0..<3).map { index in
			BrowserSiteIconKey(
				profileID: Fixture.profile,
				pageURL: URL(string: "https://fixture.invalid/\(index)")!
			)
		}
		let rows = keys.map { Row(fixture.cache.client.icons($0)) }
		defer { rows.forEach { $0.stop() } }
		for index in keys.indices {
			try await fixture.waitForCalls(index + 1)
			fixture.reply(index, bytes: [1])
			try await rows[index].waitForValues(2)
		}

		let validity = InvalidationValidity()
		for key in [keys[0], keys[1], keys[0]] {
			fixture.cache.scheduleInvalidation(validity.change(pageURLs: [key.pageURL]))
		}
		for call in 3..<5 {
			try await fixture.waitForCalls(call + 1)
			fixture.reply(call, bytes: [2])
		}
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(Set(fixture.calls.suffix(2)), [keys[0], keys[1]])
		expectNoDifference(fixture.calls.count, 5)
	}

	@Test
	internal func changedFaviconRefreshesEveryPageMappedToIt() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let shared = URL(string: "https://fixture.invalid/favicon.ico")!
		let other = URL(string: "https://elsewhere.invalid/favicon.ico")!
		let keys = ["a", "b", "c"].map { name in
			BrowserSiteIconKey(profileID: Fixture.profile, pageURL: URL(string: "https://fixture.invalid/\(name)")!)
		}
		let rows = keys.map { Row(fixture.cache.client.icons($0)) }
		defer { rows.forEach { $0.stop() } }
		for index in keys.indices {
			try await fixture.waitForCalls(index + 1)
			fixture.reply(index, bytes: [1], iconURL: index == 2 ? other : shared)
			try await rows[index].waitForValues(2)
		}

		// /a's favicon changed; /b shows the same favicon, /c another.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [keys[0].pageURL], iconURLs: [shared]))
		try await fixture.waitForCalls(5)
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(fixture.calls.count, 5)
		expectNoDifference(Set(fixture.calls.suffix(2)), [keys[0], keys[1]])
	}

	@Test
	internal func evictedRowKeepsItsFaviconForLaterChanges() async throws {
		let fixture = Fixture(maximumEntries: 1)
		defer { fixture.finish() }
		let shared = URL(string: "https://fixture.invalid/favicon.ico")!
		let keys = ["a", "b"].map { name in
			BrowserSiteIconKey(profileID: Fixture.profile, pageURL: URL(string: "https://fixture.invalid/\(name)")!)
		}
		let rows = keys.map { Row(fixture.cache.client.icons($0)) }
		defer { rows.forEach { $0.stop() } }
		for index in keys.indices {
			try await fixture.waitForCalls(index + 1)
			fixture.reply(index, bytes: [1], iconURL: shared)
			try await rows[index].waitForValues(2)
		}

		// Caching /b evicted /a's bitmap, but /a is still on screen with that favicon.
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(fixture.calls.count, 2)

		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [keys[1].pageURL], iconURLs: [shared]))
		try await fixture.waitForCalls(4)
		expectNoDifference(Set(fixture.calls.suffix(2)), Set(keys))
	}

	@Test
	internal func lifecycleChangeOfAnUnobservedPageProbesItsSharedFavicon() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let shared = URL(string: "https://fixture.invalid/favicon.ico")!
		let keys = ["a", "b"].map { name in
			BrowserSiteIconKey(profileID: Fixture.profile, pageURL: URL(string: "https://fixture.invalid/\(name)")!)
		}

		// /a was shown and is cached; its row is gone. /b is on screen.
		do {
			var first = fixture.cache.client.icons(keys[0]).makeAsyncIterator()
			_ = await first.next()
			try await fixture.waitForCalls(1)
			fixture.reply(0, bytes: [1], iconURL: shared)
			_ = await first.next()
		}
		let row = Row(fixture.cache.client.icons(keys[1]))
		defer { row.stop() }
		try await fixture.waitForCalls(2)
		fixture.reply(1, bytes: [1], iconURL: shared)
		try await row.waitForValues(2)
		for _ in 0..<100 {
			await Task.yield()
		}

		// /a's load ended without a favicon notification: /a is read once more, and its
		// new bytes reach /b. Another change while that read is in flight repeats it.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [keys[0].pageURL]))
		try await fixture.waitForCalls(3)
		expectNoDifference(fixture.calls.last, keys[0])
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [keys[0].pageURL]))
		try await validity.waitForChecks(4)
		fixture.reply(2, bytes: [1], iconURL: shared)
		try await fixture.waitForCalls(4)
		expectNoDifference(fixture.calls.last, keys[0])
		fixture.reply(3, bytes: [2], iconURL: shared)
		try await fixture.waitForCalls(5)
		expectNoDifference(fixture.calls.last, keys[1])
		fixture.reply(4, bytes: [2], iconURL: shared)
		try await row.waitForValues(3)
		expectNoDifference(row.values.last, .some(Data([2])))
	}

	@Test
	internal func lifecycleChangeOfAnUntrackedPageProbesItsFavicon() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let shared = URL(string: "https://fixture.invalid/favicon.ico")!
		let row = Row(fixture.cache.client.icons(fixture.key))
		defer { row.stop() }
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: [1], iconURL: shared)
		try await row.waitForValues(2)

		// A page no row shows changed the shared favicon; its notification was lost.
		let untracked = BrowserSiteIconKey(
			profileID: Fixture.profile,
			pageURL: URL(string: "https://fixture.invalid/untracked")!
		)
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [untracked.pageURL]))
		try await fixture.waitForCalls(2)
		expectNoDifference(fixture.calls.last, untracked)
		fixture.reply(1, bytes: [2], iconURL: shared)
		try await fixture.waitForCalls(3)
		expectNoDifference(fixture.calls.last, fixture.key)
		fixture.reply(2, bytes: [2], iconURL: shared)
		try await row.waitForValues(3)
		expectNoDifference(row.values.last, .some(Data([2])))
	}

	@Test
	internal func probeOvertakenByAnotherLifecycleChangeReadsAgain() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let untracked = BrowserSiteIconKey(
			profileID: Fixture.profile,
			pageURL: URL(string: "https://fixture.invalid/untracked")!
		)
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [untracked.pageURL]))
		try await fixture.waitForCalls(1)
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [untracked.pageURL]))
		try await validity.waitForChecks(4)
		fixture.reply(0, bytes: [1])
		try await fixture.waitForCalls(2)
		expectNoDifference(fixture.calls, [untracked, untracked])
	}

	@Test
	internal func lifecycleChangeProbesANamedCachedMiss() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let shared = URL(string: "https://fixture.invalid/favicon.ico")!
		let other = BrowserSiteIconKey(profileID: Fixture.profile, pageURL: URL(string: "https://fixture.invalid/other")!)

		// /other was shown once and missed; its row is gone.
		do {
			var images = fixture.cache.client.icons(other).makeAsyncIterator()
			_ = await images.next()
			try await fixture.waitForCalls(1)
			fixture.reply(0, bytes: nil)
			_ = await images.next()
		}
		let row = Row(fixture.cache.client.icons(fixture.key))
		defer { row.stop() }
		try await fixture.waitForCalls(2)
		fixture.reply(1, bytes: [1], iconURL: shared)
		try await row.waitForValues(2)
		for _ in 0..<100 {
			await Task.yield()
		}

		// /other loaded with the shared favicon and changed it; its notification was lost.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [other.pageURL]))
		try await fixture.waitForCalls(3)
		expectNoDifference(fixture.calls.last, other)
		fixture.reply(2, bytes: [2], iconURL: shared)
		try await fixture.waitForCalls(4)
		expectNoDifference(fixture.calls.last, fixture.key)
	}

	@Test
	internal func repairRefreshesARowWhoseBitmapWasEvicted() async throws {
		let fixture = Fixture(maximumEntries: 1)
		defer { fixture.finish() }
		let shared = URL(string: "https://fixture.invalid/favicon.ico")!
		let keys = ["a", "b"].map { name in
			BrowserSiteIconKey(profileID: Fixture.profile, pageURL: URL(string: "https://fixture.invalid/\(name)")!)
		}
		let rows = keys.map { Row(fixture.cache.client.icons($0)) }
		defer { rows.forEach { $0.stop() } }
		for index in keys.indices {
			try await fixture.waitForCalls(index + 1)
			fixture.reply(index, bytes: [1], iconURL: shared)
			try await rows[index].waitForValues(2)
		}

		// /b's load ended without a notification; its new bytes show /a is stale,
		// though /a's bitmap was evicted. Once /a matches, the repair stops.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [keys[1].pageURL]))
		try await fixture.waitForCalls(3)
		fixture.reply(2, bytes: [2], iconURL: shared)
		try await fixture.waitForCalls(4)
		expectNoDifference(fixture.calls.last, keys[0])
		fixture.reply(3, bytes: [2], iconURL: shared)
		try await rows[0].waitForValues(3)
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(fixture.calls.count, 4)
	}

	@Test
	internal func failedReadKeepsTheRowsFavicon() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let shared = URL(string: "https://fixture.invalid/favicon.ico")!
		let row = Row(fixture.cache.client.icons(fixture.key))
		defer { row.stop() }
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: [1], iconURL: shared)
		try await row.waitForValues(2)

		// The row's own refresh fails; a later change to its favicon still finds it.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [fixture.key.pageURL]))
		try await fixture.waitForCalls(2)
		fixture.reply(1, bytes: nil)
		try await row.waitForValues(3)
		fixture.cache.scheduleInvalidation(validity.change(
			pageURLs: [URL(string: "https://fixture.invalid/other")!],
			iconURLs: [shared]
		))
		try await fixture.waitForCalls(3)
		expectNoDifference(fixture.calls.last, fixture.key)
	}

	@Test
	internal func droppedInvalidationBecomesAProfileRefresh() async throws {
		let (changes, continuation) = AsyncStream<ChromiumSiteIconInvalidation>.makeStream(
			bufferingPolicy: .bufferingNewest(2)
		)
		let validity = InvalidationValidity()
		for name in ["a", "b", "c"] {
			continuation.yieldKeepingRefreshes(validity.change(pageURLs: [URL(string: "https://fixture.invalid/\(name)")!]))
		}
		continuation.finish()
		var received: [Set<URL>?] = []
		for await change in changes {
			received.append(change.pageURLs)
		}
		expectNoDifference(received, [[URL(string: "https://fixture.invalid/c")!], nil])
	}

	@Test
	internal func rowsSharingAChangedFaviconAreReadOnceEach() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let shared = URL(string: "https://fixture.invalid/favicon.ico")!
		let keys = ["a", "b"].map { name in
			BrowserSiteIconKey(profileID: Fixture.profile, pageURL: URL(string: "https://fixture.invalid/\(name)")!)
		}
		let rows = keys.map { Row(fixture.cache.client.icons($0)) }
		defer { rows.forEach { $0.stop() } }
		for index in keys.indices {
			try await fixture.waitForCalls(index + 1)
			fixture.reply(index, bytes: [1], iconURL: shared)
			try await rows[index].waitForValues(2)
		}

		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [keys[0].pageURL], iconURLs: [shared]))
		try await fixture.waitForCalls(4)
		fixture.reply(2, bytes: [2], iconURL: shared)
		fixture.reply(3, bytes: [2], iconURL: shared)
		for row in rows {
			try await row.waitForValues(3)
		}
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(fixture.calls.count, 4)
	}

	@Test
	internal func lifecycleReadOutlivesItsRow() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let shared = URL(string: "https://fixture.invalid/favicon.ico")!
		let other = BrowserSiteIconKey(profileID: Fixture.profile, pageURL: URL(string: "https://fixture.invalid/other")!)
		let row = Row(fixture.cache.client.icons(fixture.key))
		defer { row.stop() }
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: [1], iconURL: shared)
		try await row.waitForValues(2)
		let going = Row(fixture.cache.client.icons(other))
		try await fixture.waitForCalls(2)
		fixture.reply(1, bytes: [1], iconURL: shared)
		try await going.waitForValues(2)

		// /other's load ended without a notification; its row goes away mid-read.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [other.pageURL]))
		try await fixture.waitForCalls(3)
		going.stop()
		for _ in 0..<100 {
			await Task.yield()
		}
		fixture.reply(2, bytes: [2], iconURL: shared)
		try await fixture.waitForCalls(4)
		expectNoDifference(fixture.calls.last, fixture.key)
	}

	@Test
	internal func olderReadIsRepeatedWhenAProbeFoundNewerBytes() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let shared = URL(string: "https://fixture.invalid/favicon.ico")!
		let untracked = BrowserSiteIconKey(
			profileID: Fixture.profile,
			pageURL: URL(string: "https://fixture.invalid/untracked")!
		)
		let row = Row(fixture.cache.client.icons(fixture.key))
		defer { row.stop() }
		try await fixture.waitForCalls(1)

		// While the row's first read is in flight, a probe finds the favicon's new bytes.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [untracked.pageURL]))
		try await fixture.waitForCalls(2)
		fixture.reply(1, bytes: [2], iconURL: shared)
		for _ in 0..<100 {
			await Task.yield()
		}
		fixture.reply(0, bytes: [1], iconURL: shared)
		try await fixture.waitForCalls(3)
		expectNoDifference(fixture.calls.last, fixture.key)
		fixture.reply(2, bytes: [2], iconURL: shared)
		try await row.waitForValues(2)
		expectNoDifference(row.values.last, .some(Data([2])))
	}

	@Test
	internal func oneFaviconChangeReadsARowOnce() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let icon = URL(string: "https://fixture.invalid/favicon.ico")!
		let row = Row(fixture.cache.client.icons(fixture.key))
		defer { row.stop() }
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: [1], iconURL: icon)
		try await row.waitForValues(2)

		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [fixture.key.pageURL], iconURLs: [icon]))
		try await fixture.waitForCalls(2)
		fixture.reply(1, bytes: [2], iconURL: icon)
		try await row.waitForValues(3)
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(fixture.calls.count, 2)
	}

	@Test
	internal func probeNobodyShowsStaysOutOfTheStore() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arx-site-icons-\(UUID())")
		defer { try? FileManager.default.removeItem(at: directory) }
		let stored = BrowserSiteIconStore(directory: directory)
		let fixture = Fixture(stored: stored)
		defer { fixture.finish() }
		let untracked = BrowserSiteIconKey(
			profileID: Fixture.profile,
			pageURL: URL(string: "https://fixture.invalid/untracked")!
		)
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [untracked.pageURL]))
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: [1])
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(stored.icon(for: untracked), nil)

		// Nobody shows it, so a database miss must not fetch the site's icon.
		expectNoDifference(fixture.fetches, [false])
	}

	@Test
	internal func probedIconReachesTheStoreOnceARowShowsIt() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arx-site-icons-\(UUID())")
		defer { try? FileManager.default.removeItem(at: directory) }
		let stored = BrowserSiteIconStore(directory: directory)
		let fixture = Fixture(stored: stored)
		defer { fixture.finish() }
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [fixture.key.pageURL]))
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: [4])
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(stored.icon(for: fixture.key), nil)

		var images = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		let shown = await images.next()
		expectNoDifference(shown, .some(Data([4])))
		expectNoDifference(stored.icon(for: fixture.key), Data([4]))
		expectNoDifference(fixture.calls.count, 1)
	}

	@Test
	internal func databaseOnlyMissDoesNotStopARowFromFetching() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [fixture.key.pageURL]))
		try await fixture.waitForCalls(1)

		// A row mounts while the database-only probe is in flight; the probe misses.
		let row = Row(fixture.cache.client.icons(fixture.key))
		defer { row.stop() }
		fixture.reply(0, bytes: nil)
		try await fixture.waitForCalls(2)
		expectNoDifference(fixture.fetches, [false, true])
		fixture.reply(1, bytes: [5])
		try await row.waitForValues(2)
		expectNoDifference(row.values.last, .some(Data([5])))
	}

	@Test
	internal func databaseOnlyMissForgetsTheOldAnswer() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let icon = URL(string: "https://fixture.invalid/favicon.ico")!
		do {
			var images = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
			_ = await images.next()
			try await fixture.waitForCalls(1)
			fixture.reply(0, bytes: [1], iconURL: icon)
			_ = await images.next()
		}
		for _ in 0..<100 {
			await Task.yield()
		}

		// The page's lifecycle probe misses in the database; a later row fetches.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [fixture.key.pageURL]))
		try await fixture.waitForCalls(2)
		expectNoDifference(fixture.fetches.last, false)
		fixture.reply(1, bytes: nil)
		for _ in 0..<100 {
			await Task.yield()
		}
		let row = Row(fixture.cache.client.icons(fixture.key))
		defer { row.stop() }
		try await fixture.waitForCalls(3)
		expectNoDifference(fixture.fetches.last, true)
	}

	@Test
	internal func failedReadIsRetriedByTheNextPageChange() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let row = Row(fixture.cache.client.icons(fixture.key))
		defer { row.stop() }
		try await fixture.waitForCalls(1)
		fixture.fail(0)
		for _ in 0..<100 {
			await Task.yield()
		}

		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(
			pageURLs: [URL(string: "https://fixture.invalid/other")!],
			iconURLs: [URL(string: "https://fixture.invalid/favicon.ico")!]
		))
		try await fixture.waitForCalls(2)
		expectNoDifference(fixture.calls.last, fixture.key)
	}

	@Test
	internal func readInFlightIsRepeatedWhenItsNewFaviconChanged() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let old = URL(string: "https://fixture.invalid/old.ico")!
		let new = URL(string: "https://fixture.invalid/new.ico")!
		let row = Row(fixture.cache.client.icons(fixture.key))
		defer { row.stop() }
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: [1], iconURL: old)
		try await row.waitForValues(2)

		// The row's page moved to a new favicon; while its refresh is in flight, another
		// page reports a change to that new favicon.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [fixture.key.pageURL], iconURLs: [old]))
		try await fixture.waitForCalls(2)
		fixture.cache.scheduleInvalidation(validity.change(
			pageURLs: [URL(string: "https://fixture.invalid/other")!],
			iconURLs: [new]
		))
		try await validity.waitForChecks(4)
		fixture.reply(1, bytes: [2], iconURL: new)
		try await fixture.waitForCalls(3)
		fixture.reply(2, bytes: [3], iconURL: new)
		try await row.waitForValues(3)
		expectNoDifference(row.values.last, .some(Data([3])))
	}

	@Test
	internal func firstReadInFlightIsRepeatedAfterAFaviconChange() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let shared = URL(string: "https://fixture.invalid/favicon.ico")!
		let row = Row(fixture.cache.client.icons(fixture.key))
		defer { row.stop() }
		try await fixture.waitForCalls(1)

		// Another page changes the favicon while this row's first read is in flight.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(
			pageURLs: [URL(string: "https://fixture.invalid/other")!],
			iconURLs: [shared]
		))
		try await validity.waitForChecks(2)
		fixture.reply(0, bytes: [1], iconURL: shared)
		try await fixture.waitForCalls(2)
		fixture.reply(1, bytes: [2], iconURL: shared)
		try await row.waitForValues(2)
		expectNoDifference(row.values.last, .some(Data([2])))
	}

	@Test
	internal func refreshWithNewBytesRereadsPagesSharingItsFavicon() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let shared = URL(string: "https://fixture.invalid/favicon.ico")!
		let other = URL(string: "https://elsewhere.invalid/favicon.ico")!
		let keys = ["a", "b", "c"].map { name in
			BrowserSiteIconKey(profileID: Fixture.profile, pageURL: URL(string: "https://fixture.invalid/\(name)")!)
		}
		let rows = keys.map { Row(fixture.cache.client.icons($0)) }
		defer { rows.forEach { $0.stop() } }
		for index in keys.indices {
			try await fixture.waitForCalls(index + 1)
			fixture.reply(index, bytes: [1], iconURL: index == 2 ? other : shared)
			try await rows[index].waitForValues(2)
		}

		// A lifecycle change names only /a; its new bitmap shows /b is stale.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [keys[0].pageURL]))
		try await fixture.waitForCalls(4)
		fixture.reply(3, bytes: [2], iconURL: shared)
		try await fixture.waitForCalls(5)
		expectNoDifference(fixture.calls.last, keys[1])
		fixture.reply(4, bytes: [2], iconURL: shared)
		try await rows[1].waitForValues(3)
		expectNoDifference(rows[1].values.last, .some(Data([2])))
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(fixture.calls.count, 5)
	}

	@Test
	internal func canonicalAddressesResolveDotSegmentsAndGuessesRefreshOnAnyChange() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let pages = [
			"https://Fixture.invalid:443/a/./b/../c",
			"https://fixture.invalid/x/%2E%2E/y",
			"http://[0:0:0:0:0:0:0:1]/",
			"https://fixture.invalid/plain",
		]
		let keys = pages.map { BrowserSiteIconKey(profileID: Fixture.profile, pageURL: URL(string: $0)!) }
		let rows = keys.map { Row(fixture.cache.client.icons($0)) }
		defer { rows.forEach { $0.stop() } }
		for index in keys.indices {
			try await fixture.waitForCalls(index + 1)
			fixture.reply(index, bytes: [1])
			try await rows[index].waitForValues(2)
		}

		// GURL writes the first as /a/c. The encoded dots and the long IPv6 spelling
		// are guesses, so any page change in the profile re-reads them; the plain
		// page waits for its own.
		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change(pageURLs: [URL(string: "https://fixture.invalid/a/c")!]))
		try await fixture.waitForCalls(7)
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(fixture.calls.count, 7)
		expectNoDifference(Set(fixture.calls.suffix(3)), [keys[0], keys[1], keys[2]])
	}

	@Test
	internal func byteBudgetEvictsTheLeastRecentlyUsedIcon() async throws {
		let fixture = Fixture(maximumBytes: 5)
		defer { fixture.finish() }
		let keys = (0..<3).map { index in
			BrowserSiteIconKey(
				profileID: Fixture.profile,
				pageURL: URL(string: "https://fixture.invalid/\(index)")!
			)
		}
		for (index, key) in keys.prefix(2).enumerated() {
			var images = fixture.cache.client.icons(key).makeAsyncIterator()
			_ = await images.next()
			try await fixture.waitForCalls(index + 1)
			fixture.reply(index, bytes: [1, 1])
			_ = await images.next()
		}

		// Reading the first again makes the second the least recently used.
		var first = fixture.cache.client.icons(keys[0]).makeAsyncIterator()
		_ = await first.next()
		var third = fixture.cache.client.icons(keys[2]).makeAsyncIterator()
		_ = await third.next()
		try await fixture.waitForCalls(3)
		fixture.reply(2, bytes: [3, 3])
		_ = await third.next()

		var firstAgain = fixture.cache.client.icons(keys[0]).makeAsyncIterator()
		let cached = await firstAgain.next()
		expectNoDifference(cached, .some(Data([1, 1])))
		expectNoDifference(fixture.calls.count, 3)
		var second = fixture.cache.client.icons(keys[1]).makeAsyncIterator()
		_ = await second.next()
		try await fixture.waitForCalls(4)
		expectNoDifference(fixture.calls.last, keys[1])
	}

	@Test
	internal func generationIsRecheckedAfterInvalidationWasQueued() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		var images = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		_ = await images.next()
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: [3])
		_ = await images.next()

		let validity = InvalidationValidity()
		fixture.cache.scheduleInvalidation(validity.change)
		validity.isCurrent = false
		try await validity.waitForChecks(2)
		var cached = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		let current = await cached.next()
		expectNoDifference(current, .some(Data([3])))
		expectNoDifference(fixture.calls.count, 1)
	}

	@Test
	internal func boundedCacheEvictionLoadsTheExactSavedURLAgain() async throws {
		let fixture = Fixture(maximumEntries: 1)
		defer { fixture.finish() }
		var first = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		_ = await first.next()
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: [1])
		_ = await first.next()

		let another = BrowserSiteIconKey(
			profileID: Fixture.profile,
			pageURL: URL(string: "https://fixture.invalid/second")!
		)
		var second = fixture.cache.client.icons(another).makeAsyncIterator()
		_ = await second.next()
		try await fixture.waitForCalls(2)
		fixture.reply(1, bytes: [2])
		_ = await second.next()

		var reloaded = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		_ = await reloaded.next()
		try await fixture.waitForCalls(3)
		expectNoDifference(fixture.calls, [fixture.key, another, fixture.key])
		fixture.reply(2, bytes: [3])
		let current = await reloaded.next()
		expectNoDifference(current, .some(Data([3])))
	}

	@Test
	internal func concurrentReadsAreBoundedAndMissingIsCached() async throws {
		let fixture = Fixture(maximumConcurrent: 1)
		defer { fixture.finish() }
		var first = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		let another = BrowserSiteIconKey(profileID: Fixture.otherProfile, pageURL: fixture.key.pageURL)
		var second = fixture.cache.client.icons(another).makeAsyncIterator()
		_ = await first.next()
		_ = await second.next()
		try await fixture.waitForCalls(1)
		expectNoDifference(fixture.calls, [fixture.key])
		fixture.reply(0, bytes: nil)
		_ = await first.next()
		try await fixture.waitForCalls(2)
		fixture.reply(1, bytes: [2])
		_ = await second.next()

		var cached = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		let missing = await cached.next()
		expectNoDifference(missing, .some(nil))
		expectNoDifference(fixture.calls.count, 2)
	}

	/// DEV-940 follow-up: a row mounted off screen (a neighbouring space, the shut Library)
	/// reads only Chromium's database, and its icon is fetched from the site once a row
	/// showing it asks.
	@Test
	internal func offscreenRowNeverFetchesUntilARowShowsIt() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let offscreen = Row(fixture.cache.client.cachedIcons(fixture.key))
		defer { offscreen.stop() }
		try await fixture.waitForCalls(1)
		expectNoDifference(fixture.fetches, [false])
		fixture.reply(0, bytes: nil)
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(fixture.calls.count, 1)

		let shown = Row(fixture.cache.client.icons(fixture.key))
		defer { shown.stop() }
		try await fixture.waitForCalls(2)
		expectNoDifference(fixture.fetches, [false, true])
		fixture.reply(1, bytes: [6])
		try await shown.waitForValues(2)
		try await offscreen.waitForValues(2)
		expectNoDifference(shown.values.last, .some(Data([6])))
		expectNoDifference(offscreen.values.last, .some(Data([6])))
	}

	/// A row coming on screen while its off-screen read is in flight fetches once the
	/// database misses.
	@Test
	internal func rowComingOnScreenDuringItsDatabaseReadFetchesAfterTheMiss() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let offscreen = Row(fixture.cache.client.cachedIcons(fixture.key))
		defer { offscreen.stop() }
		try await fixture.waitForCalls(1)
		let shown = Row(fixture.cache.client.icons(fixture.key))
		defer { shown.stop() }
		offscreen.stop()
		fixture.reply(0, bytes: nil)
		try await fixture.waitForCalls(2)
		expectNoDifference(fixture.fetches, [false, true])
	}

	/// An icon Chromium already has reaches an off-screen row without any fetch.
	@Test
	internal func offscreenRowShowsWhatTheDatabaseHas() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let offscreen = Row(fixture.cache.client.cachedIcons(fixture.key))
		defer { offscreen.stop() }
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: [3])
		try await offscreen.waitForValues(2)
		expectNoDifference(offscreen.values.last, .some(Data([3])))

		// Coming on screen shows the same answer without another read.
		let shown = Row(fixture.cache.client.icons(fixture.key))
		defer { shown.stop() }
		try await shown.waitForValues(1)
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(shown.values, [Data([3])])
		expectNoDifference(fixture.fetches, [false])
	}

	/// DEV-1311: a bang listed in the command bar reads only the database. Highlighted, it may
	/// fetch: once, for the field and the row together, when the database has nothing, and not
	/// at all when it has the icon.
	@Test
	internal func aSelectedBangFetchesOnceOnlyWhenNothingIsStored() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let stored = Fixture.page(1)
		let missing = Fixture.page(2)
		let listed = [Row(fixture.cache.client.cachedIcons(stored)), Row(fixture.cache.client.cachedIcons(missing))]
		defer { listed.forEach { $0.stop() } }
		try await fixture.waitForCalls(2)
		expectNoDifference(fixture.fetches, [false, false])
		fixture.reply(0, bytes: [4])
		fixture.reply(1, bytes: nil)
		try await listed[0].waitForValues(2)
		for _ in 0..<100 {
			await Task.yield()
		}

		// Highlighting the one with a stored icon reads nothing more.
		let storedRow = Row(fixture.cache.client.icons(stored))
		let storedField = Row(fixture.cache.client.icons(stored))
		defer { [storedRow, storedField].forEach { $0.stop() } }
		try await storedField.waitForValues(1)
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(fixture.calls.count, 2)
		expectNoDifference(storedField.values, [Data([4])])

		// Highlighting the other fetches it once, for its row and the field.
		let missingRow = Row(fixture.cache.client.icons(missing))
		let missingField = Row(fixture.cache.client.icons(missing))
		defer { [missingRow, missingField].forEach { $0.stop() } }
		try await fixture.waitForCalls(3)
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(fixture.calls, [stored, missing, missing])
		expectNoDifference(fixture.fetches, [false, false, true])
	}

	/// DEV-1311: when the command bar's highlight moves off a bang, the fetch of its site's icon
	/// stops, and the row, still listed, reads only the database again.
	@Test
	internal func aFetchStopsWhenTheLastViewThatAllowedItGoes() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let listed = Row(fixture.cache.client.cachedIcons(fixture.key))
		defer { listed.stop() }
		try await fixture.waitForCalls(1)
		fixture.reply(0, bytes: nil)
		for _ in 0..<100 {
			await Task.yield()
		}

		let row = Row(fixture.cache.client.icons(fixture.key))
		let field = Row(fixture.cache.client.icons(fixture.key))
		try await fixture.waitForCalls(2)
		expectNoDifference(fixture.fetches, [false, true])

		// The field moves on first: the row still allows the fetch, so it goes on.
		field.stop()
		for _ in 0..<100 {
			await Task.yield()
		}
		#expect(fixture.cancelled.isEmpty)

		row.stop()
		for _ in 0..<200 {
			if fixture.cancelled.contains(1), fixture.calls.count >= 3 { break }
			await Task.yield()
		}
		expectNoDifference(fixture.cancelled, [1])
		expectNoDifference(fixture.fetches, [false, true, false])
	}

	/// A relaunch's rows on screen fetch a few icons at a time; database reads for rows off
	/// screen go on past the waiting fetches.
	@Test
	internal func fetchesRunAFewAtATimeWhileDatabaseReadsGoOn() async throws {
		let fixture = Fixture(maximumFetching: 2)
		defer { fixture.finish() }
		let pages = (0..<5).map { Fixture.page($0) }
		let shown = pages.map { Row(fixture.cache.client.icons($0)) }
		defer { shown.forEach { $0.stop() } }
		try await fixture.waitForCalls(2)
		for _ in 0..<100 {
			await Task.yield()
		}
		expectNoDifference(fixture.calls, Array(pages[0..<2]))
		expectNoDifference(fixture.fetches, [true, true])

		let offscreen = Row(fixture.cache.client.cachedIcons(Fixture.page(9)))
		defer { offscreen.stop() }
		try await fixture.waitForCalls(3)
		expectNoDifference(fixture.calls.last, Fixture.page(9))
		expectNoDifference(fixture.fetches.last, false)

		var answered = 0
		while answered < pages.count {
			let inFlight = fixture.pendingFetches
			#expect(inFlight <= 2, "\(inFlight) fetches at once")
			fixture.reply(try #require(fixture.oldestPendingFetch), bytes: [UInt8(answered)])
			answered += 1
			for _ in 0..<100 {
				await Task.yield()
			}
		}
		expectNoDifference(Set(fixture.calls.filter { $0 != Fixture.page(9) }), Set(pages))
		expectNoDifference(fixture.fetches.filter { $0 }.count, pages.count)
	}

	@Test
	internal func runtimeObservationEndingRevokesCachedAndPendingImages() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let (changes, continuation) = AsyncStream<ChromiumSiteIconInvalidation>.makeStream()
		fixture.cache.observe(changes)
		var images = fixture.cache.client.icons(fixture.key).makeAsyncIterator()
		_ = await images.next()
		try await fixture.waitForCalls(1)
		continuation.finish()
		let removed = await images.next()
		let ended = await images.next()
		fixture.reply(0, bytes: [1])
		expectNoDifference(removed, .some(nil))
		expectNoDifference(ended, nil)
		expectNoDifference(fixture.configured.last, [])
	}

	@Test
	internal func unknownPrivateProfileAndUnsupportedURLNeverLoad() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let privateKey = BrowserSiteIconKey(profileID: .init(rawValue: UUID(90)), pageURL: fixture.key.pageURL)
		let unsupported = BrowserSiteIconKey(profileID: Fixture.profile, pageURL: URL(string: "file:///private")!)
		for key in [privateKey, unsupported] {
			var images = fixture.cache.client.icons(key).makeAsyncIterator()
			let fallback = await images.next()
			let ended = await images.next()
			expectNoDifference(fallback, .some(nil))
			expectNoDifference(ended, nil)
		}
		expectNoDifference(fixture.calls, [])
	}
}

@MainActor
private final class Fixture {
	fileprivate static let profile: Profile.ID = .init(rawValue: UUID(1))
	fileprivate static let otherProfile: Profile.ID = .init(rawValue: UUID(2))
	fileprivate let key: BrowserSiteIconKey = .init(
		profileID: Fixture.profile,
		pageURL: URL(string: "https://fixture.invalid/saved")!
	)
	fileprivate var calls: [BrowserSiteIconKey] = []

	/// Whether each call may fetch on a database miss.
	fileprivate var fetches: [Bool] = []
	fileprivate var configured: [Set<Profile.ID>] = []

	/// Calls whose read was cancelled, as the engine's request is when its task is.
	fileprivate var cancelled: Set<Int> = []
	private var pending: [Int: CheckedContinuation<ChromiumSiteIconAnswer?, any Error>] = [:]
	fileprivate var cache: ChromiumSiteIconCache!

	fileprivate init(
		maximumEntries: Int = 256,
		maximumBytes: Int = 4 * 1024 * 1024,
		maximumConcurrent: Int = 8,
		maximumFetching: Int = 4,
		stored: BrowserSiteIconStore? = nil
	) {
		self.cache = .init(
			profiles: [Self.profile, Self.otherProfile],
			maximumEntries: maximumEntries,
			maximumBytes: maximumBytes,
			maximumConcurrent: maximumConcurrent,
			maximumFetching: maximumFetching,
			stored: stored,
			configure: { [weak self] in self?.configured.append($0) },
			lookupIcon: { [weak self] key, mayFetch in
				guard let self else { return nil }
				let id = self.calls.count
				self.calls.append(key)
				self.fetches.append(mayFetch)
				return try await withTaskCancellationHandler {
					try await withCheckedThrowingContinuation { continuation in
						self.pending[id] = continuation
					}
				} onCancel: {
					Task { @MainActor [weak self] in
						self?.cancelled.insert(id)
						self?.fail(id)
					}
				}
			}
		)
	}

	/// Another page of the fixture's profile.
	fileprivate static func page(_ index: Int) -> BrowserSiteIconKey {
		.init(profileID: profile, pageURL: URL(string: "https://fixture.invalid/page-\(index)")!)
	}

	/// Calls that may fetch and haven't been answered.
	fileprivate var pendingFetches: Int {
		pending.keys.count(where: { fetches[$0] })
	}

	fileprivate var oldestPendingFetch: Int? {
		pending.keys.filter { fetches[$0] }.min()
	}

	fileprivate func waitForCalls(_ count: Int) async throws {
		for _ in 0..<1000 {
			if calls.count >= count { return }
			await Task.yield()
		}
		throw Failure.missingCall
	}

	fileprivate func reply(
		_ id: Int,
		bytes: [UInt8]?,
		iconURL: URL? = nil
	) {
		pending.removeValue(forKey: id)?.resume(returning: bytes.map { .init(png: Data($0), iconURL: iconURL) })
	}

	fileprivate func fail(_ id: Int) {
		pending.removeValue(forKey: id)?.resume(throwing: Failure.lookupFailed)
	}

	fileprivate func finish() {
		cache.configureProfiles([])
		for value in pending.values {
			value.resume(returning: nil)
		}
		pending.removeAll()
	}

	private enum Failure: Error {
		case missingCall
		case lookupFailed
	}
}

/// One mounted sidebar row: every image its stream delivered.
@MainActor
private final class Row {
	fileprivate private(set) var values: [Data?] = []
	private var task: Task<Void, Never>?

	fileprivate init(_ stream: AsyncStream<Data?>) {
		self.task = Task { [weak self] in
			for await value in stream {
				self?.values.append(value)
			}
		}
	}

	fileprivate func waitForValues(_ count: Int) async throws {
		for _ in 0..<1000 {
			if values.count >= count { return }
			await Task.yield()
		}
		throw Failure.missingValue
	}

	fileprivate func stop() {
		task?.cancel()
	}

	private enum Failure: Error {
		case missingValue
	}
}

@MainActor
private final class InvalidationValidity {
	fileprivate var isCurrent: Bool = true
	private var checks: Int = 0

	fileprivate init() {}

	/// Any icon in the profile may have changed.
	fileprivate var change: ChromiumSiteIconInvalidation {
		change(pageURLs: nil)
	}

	fileprivate func change(
		pageURLs: Set<URL>?,
		iconURLs: Set<URL> = []
	) -> ChromiumSiteIconInvalidation {
		.init(profileID: Fixture.profile, pageURLs: pageURLs, iconURLs: iconURLs) { [self] in
			checks += 1
			return isCurrent
		}
	}

	fileprivate func waitForChecks(_ count: Int) async throws {
		for _ in 0..<1000 {
			if checks >= count { return }
			await Task.yield()
		}
		throw Failure.missingValidation
	}

	private enum Failure: Error {
		case missingValidation
	}
}
