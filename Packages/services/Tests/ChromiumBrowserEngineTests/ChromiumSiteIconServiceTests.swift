import AppKit
import BrowserCore
import BrowserSiteIconClient
import ChromiumBridge
import CustomDump
import Foundation
import Testing
import _TestSupport

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumSiteIconServiceTests {
	/// A saved tab shows the page it loaded and, once closed, its saved page: the stored icons
	/// of both outlive a relaunch (DEV-1294).
	@Test
	internal func storedIconsAreKeptForASavedTabsPageAndItsSavedPage() {
		let profile = Profile.ID(rawValue: UUID(1))
		let saved = URL(string: "https://fixture.invalid/saved")!
		let loaded = URL(string: "https://fixture.invalid/saved/inbox")!
		let other = URL(string: "https://fixture.invalid/other")!
		let organization = BrowserOrganization(
			profiles: [.init(id: profile, name: "Fixture")],
			tabs: [
				.init(
					id: .init(rawValue: UUID(2)),
					profileID: profile,
					savedDestination: .init(title: "Saved", url: saved),
					restoration: .init(title: "Inbox", url: loaded)
				),
				.init(
					id: .init(rawValue: UUID(3)),
					profileID: profile,
					restoration: .init(title: "Other", url: other)
				),
			]
		)

		expectNoDifference(
			ChromiumBrowserEngine.siteIconKeys(organization),
			[
				.init(profileID: profile, pageURL: saved),
				.init(profileID: profile, pageURL: loaded),
				.init(profileID: profile, pageURL: other),
			]
		)
	}

	@Test
	internal func retainedPreReadyClientDoesNotCacheUnavailableAndStartsWhenReady() async throws {
		let profile = Profile.ID(rawValue: UUID(1))
		let key = BrowserSiteIconKey(profileID: profile, pageURL: URL(string: "https://fixture.invalid/saved")!)
		let readiness = Readiness()
		var queries: [BrowserSiteIconKey] = []
		var subscriptions = 0
		var imageLookup: CheckedContinuation<Data?, Never>?
		defer { imageLookup?.resume(returning: nil) }
		let (changes, continuation) = AsyncStream<ChromiumSiteIconInvalidation>.makeStream()
		defer { continuation.finish() }
		let service = ChromiumSiteIconService(
			profiles: [profile],
			isRunning: { readiness.isRunning },
			configure: { _ in },
			lookup: { key in
				queries.append(key)
				return await withCheckedContinuation { imageLookup = $0 }
			},
			changes: {
				subscriptions += 1
				return changes
			}
		)
		let client = service.client
		var before = client.icons(key).makeAsyncIterator()
		let unavailable = await before.next()
		expectNoDifference(unavailable, nil)
		expectNoDifference(queries, [])
		expectNoDifference(subscriptions, 0)

		readiness.isRunning = true
		var ready = client.icons(key).makeAsyncIterator()

		// bufferingNewest(1) may coalesce an immediate image with its placeholder.
		// Hold the lookup until this test has actually consumed the initial nil.
		let placeholder = await ready.next()
		expectNoDifference(placeholder, .some(nil))
		for _ in 0..<1000 {
			if imageLookup != nil { break }
			await Task.yield()
		}
		let lookup = try #require(imageLookup)
		imageLookup = nil
		lookup.resume(returning: Data([7]))
		let image = await ready.next()
		expectNoDifference(image, .some(Data([7])))
		expectNoDifference(queries, [key])
		expectNoDifference(subscriptions, 1)

		readiness.isRunning = false
		var stopped = client.icons(key).makeAsyncIterator()
		let after = await stopped.next()
		expectNoDifference(after, nil)
	}

	/// DEV-940 follow-up: a headless run's windows read every icon without fetching it, so a
	/// relaunch asks no site for a missing one.
	@Test
	internal func neverFetchingClientReadsOnlyTheDatabase() async throws {
		let profile = Profile.ID(rawValue: UUID(1))
		let key = BrowserSiteIconKey(profileID: profile, pageURL: URL(string: "https://fixture.invalid/saved")!)
		let readiness = Readiness()
		readiness.isRunning = true
		var fetches: [Bool] = []
		let (changes, continuation) = AsyncStream<ChromiumSiteIconInvalidation>.makeStream()
		defer { continuation.finish() }
		let service = ChromiumSiteIconService(
			profiles: [profile],
			isRunning: { readiness.isRunning },
			configure: { _ in },
			lookupIcon: { _, mayFetch in
				fetches.append(mayFetch)
				return nil
			},
			changes: { changes }
		)
		var headless = service.client.neverFetching.icons(key).makeAsyncIterator()
		_ = await headless.next()
		for _ in 0..<1000 {
			if !fetches.isEmpty { break }
			await Task.yield()
		}
		expectNoDifference(fetches, [false])

		// A window someone sees fetches it.
		var shown = service.client.icons(key).makeAsyncIterator()
		_ = await shown.next()
		for _ in 0..<1000 {
			if fetches.count > 1 { break }
			await Task.yield()
		}
		expectNoDifference(fetches, [false, true])
	}

	/// DEV-796: the setting reaches the engine, and turning it back on asks again for the
	/// icons that missed while it was off.
	@Test
	internal func fetchingUnloadedIconsReachesTheEngineAndRetriesMisses() async throws {
		let profile = Profile.ID(rawValue: UUID(1))
		let key = BrowserSiteIconKey(profileID: profile, pageURL: URL(string: "https://fixture.invalid/saved")!)
		var settings: [Bool] = []
		var answers: [Data?] = [nil, Data([9])]
		var lookups = 0
		let (changes, continuation) = AsyncStream<ChromiumSiteIconInvalidation>.makeStream()
		defer { continuation.finish() }
		let service = ChromiumSiteIconService(
			profiles: [profile],
			isRunning: { true },
			configure: { _ in },
			lookup: { _ in
				lookups += 1
				return answers.isEmpty ? nil : answers.removeFirst()
			},
			changes: { changes },
			setFetch: { settings.append($0) }
		)
		let client = service.client

		// On is the engine's default: nothing to tell it.
		client.setFetchesUnloadedIcons(true)
		expectNoDifference(settings, [])

		client.setFetchesUnloadedIcons(false)
		client.setFetchesUnloadedIcons(false)
		expectNoDifference(settings, [false])

		var icons = client.icons(key).makeAsyncIterator()
		_ = await icons.next()
		for _ in 0..<1000 where lookups < 1 { await Task.yield() }
		expectNoDifference(lookups, 1)

		client.setFetchesUnloadedIcons(true)
		expectNoDifference(settings, [false, true])
		var image: Data?? = nil
		for _ in 0..<1000 {
			image = await icons.next()
			if image == .some(Data([9])) { break }
		}
		expectNoDifference(image, .some(Data([9])))
		expectNoDifference(lookups, 2)
	}

	/// A lookup that started while fetching was off and is still running when it's turned
	/// back on asks once more when it ends, instead of caching its miss.
	@Test
	internal func turningFetchingOnRetriesALookupStillInFlight() async throws {
		let profile = Profile.ID(rawValue: UUID(1))
		let key = BrowserSiteIconKey(profileID: profile, pageURL: URL(string: "https://fixture.invalid/saved")!)
		var pending: CheckedContinuation<Data?, Never>?
		defer { pending?.resume(returning: nil) }
		var lookups = 0
		let (changes, continuation) = AsyncStream<ChromiumSiteIconInvalidation>.makeStream()
		defer { continuation.finish() }
		let service = ChromiumSiteIconService(
			profiles: [profile],
			isRunning: { true },
			configure: { _ in },
			lookup: { _ in
				lookups += 1
				if lookups == 1 { return await withCheckedContinuation { pending = $0 } }
				return Data([9])
			},
			changes: { changes }
		)
		let client = service.client
		client.setFetchesUnloadedIcons(false)

		var icons = client.icons(key).makeAsyncIterator()
		_ = await icons.next()
		for _ in 0..<1000 where pending == nil { await Task.yield() }
		let first = try #require(pending)
		pending = nil

		client.setFetchesUnloadedIcons(true)
		first.resume(returning: nil)
		var image: Data?? = nil
		for _ in 0..<1000 {
			image = await icons.next()
			if image == .some(Data([9])) { break }
		}
		expectNoDifference(image, .some(Data([9])))
		expectNoDifference(lookups, 2)
	}

	@Test
	internal func preReadyClientShowsTheStoredIconOfAnUnloadedTab() async throws {
		let profile = Profile.ID(rawValue: UUID(1))
		let stranger = Profile.ID(rawValue: UUID(2))
		let key = BrowserSiteIconKey(profileID: profile, pageURL: URL(string: "https://fixture.invalid/saved")!)
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arx-site-icons-\(UUID())")
		defer { try? FileManager.default.removeItem(at: directory) }
		let stored = BrowserSiteIconStore(directory: directory)
		stored.store(Data([5]), for: key)
		stored.store(Data([6]), for: .init(profileID: stranger, pageURL: key.pageURL))
		let service = ChromiumSiteIconService(
			profiles: [profile],
			isRunning: { false },
			configure: { _ in },
			lookup: { _ in
				Issue.record("A pre-ready read reached Chromium")
				return nil
			},
			changes: { .finished },
			stored: stored
		)

		var icons = service.client.icons(key).makeAsyncIterator()
		let icon = await icons.next()
		let ended = await icons.next()
		expectNoDifference(icon, .some(Data([5])))
		expectNoDifference(ended, nil)

		// A profile the service wasn't configured for never reads another's store.
		var strangers = service.client.icons(.init(profileID: stranger, pageURL: key.pageURL)).makeAsyncIterator()
		let none = await strangers.next()
		expectNoDifference(none, nil)

		service.client.removeProfiles([profile])
		var removed = service.client.icons(key).makeAsyncIterator()
		let afterRemoval = await removed.next()
		expectNoDifference(afterRemoval, nil)
	}

	@Test
	internal func engineFactoryRetainsTheSameClientAcrossRuntimeReadiness() async throws {
		NativeFixture.prepared = []
		var api = ArxEngineAPI()
		api.prepare_profile = { key, _ in
			MainActor.assumeIsolated {
				NativeFixture.prepared.append(String(cString: key!))
			}
		}
		let runtime = ChromiumRuntime(api: api)
		defer { runtime.finish() }
		let profile = Profile.ID(rawValue: UUID(1))
		let engine = ChromiumBrowserEngine(runtime: runtime, profileID: profile)
		let client = engine.siteIcons(organization: .init(profiles: [.init(id: profile, name: "Fixture")]))
		let key = BrowserSiteIconKey(profileID: profile, pageURL: URL(string: "https://fixture.invalid/saved")!)
		var before = client.icons(key).makeAsyncIterator()
		let unavailable = await before.next()
		expectNoDifference(unavailable, nil)

		runtime.didBecomeReady()
		var ready = client.icons(key).makeAsyncIterator()
		_ = await ready.next()
		for _ in 0..<1000 {
			if !NativeFixture.prepared.isEmpty { break }
			await Task.yield()
		}
		expectNoDifference(NativeFixture.prepared, [""])
		runtime.finish()
		var stopped = client.icons(key).makeAsyncIterator()
		let after = await stopped.next()
		expectNoDifference(after, nil)
	}

	@Test(arguments: [true, false])
	internal func lifecycleRefreshesCachedMissingIconWithoutNativeIconCallback(
		close: Bool
	) async throws {
		var api = ArxEngineAPI()
		api.create_page = { _, _ in 1 }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { NativeFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.destroy_page = { _ in }
		api.history_count = { _ in 0 }
		let runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
		defer { runtime.finish() }
		let profile = Profile.ID(rawValue: UUID(1))
		let engine = ChromiumBrowserEngine(runtime: runtime, profileID: profile)
		var reads = 0
		var initialRead: CheckedContinuation<Data?, Never>?
		let cache = ChromiumSiteIconCache(
			profiles: [profile],
			configure: { runtime.configureSiteIconProfiles($0.isEmpty ? [] : [nil]) },
			lookup: { _ in
				reads += 1
				if reads == 1 {
					return await withCheckedContinuation { initialRead = $0 }
				}
				return Data([7])
			}
		)
		cache.observe(engine.siteIconChanges())
		let page = try runtime.makePage()
		let savedURL = URL(string: "https://fixture.invalid/saved")!

		// The page starts loading the saved URL; nothing has finished yet.
		var navigation = page.navigation
		navigation.url = savedURL
		navigation.isLoading = true
		page.receive(navigation)
		var images = cache.client.icons(.init(profileID: profile, pageURL: savedURL)).makeAsyncIterator()
		_ = await images.next()
		for _ in 0..<1000 {
			if initialRead != nil { break }
			await Task.yield()
		}
		let read = try #require(initialRead)
		read.resume(returning: nil)
		initialRead = nil
		let missing = await images.next()
		expectNoDifference(missing, .some(nil))
		expectNoDifference(reads, 1)

		// The database changed, but the document's weak native icon task vanished.
		// Only the ordinary lifecycle event is delivered through the real adapter. It
		// names the saved URL even after the load redirected away from it.
		if close {
			page.close()

		} else {
			navigation.url = URL(string: "https://fixture.invalid/replacement")!
			page.receive(navigation)
			navigation.isLoading = false
			page.receive(navigation)
		}
		let refreshed = await images.next()
		expectNoDifference(refreshed, .some(Data([7])))

		// The replacement address no row shows is probed once more for its favicon.
		let expected = close ? 2 : 3
		for _ in 0..<1000 where reads < expected { await Task.yield() }
		for _ in 0..<100 { await Task.yield() }
		expectNoDifference(reads, expected)
	}

	@Test
	internal func profileRemovedBeforeActivationCannotQueryLater() async throws {
		let profile = Profile.ID(rawValue: UUID(1))
		let readiness = Readiness()
		let (changes, continuation) = AsyncStream<ChromiumSiteIconInvalidation>.makeStream()
		defer { continuation.finish() }
		let service = ChromiumSiteIconService(
			profiles: [profile],
			isRunning: { readiness.isRunning },
			configure: { _ in },
			lookup: { _ in
				Issue.record("Removed profile reached favicon lookup")
				return nil
			},
			changes: { changes }
		)
		let client = service.client
		client.configureProfiles([])
		readiness.isRunning = true
		var images = client.icons(.init(profileID: profile, pageURL: URL(string: "https://fixture.invalid")!))
			.makeAsyncIterator()
		let fallback = await images.next()
		let ended = await images.next()
		expectNoDifference(fallback, .some(nil))
		expectNoDifference(ended, nil)
	}
}

@MainActor
private enum NativeFixture {
	fileprivate static let view: NSView = .init()
	fileprivate static var prepared: [String] = []
}

@MainActor
private final class Readiness {
	fileprivate var isRunning: Bool = false

	fileprivate init() {}
}
