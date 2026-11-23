import AppKit
import ChromiumBridge
import CustomDump
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumSiteIconTests {
	@Test
	internal func copiesBoundedPNGAndUsesExactProfileAndPage() async throws {
		let fixture = SiteIconFixture()
		let task = Task { try await fixture.lookup() }
		let request = try await fixture.nextCall()
		expectNoDifference(request.key, fixture.profile.uuidString.lowercased())
		expectNoDifference(request.url, fixture.url.absoluteString)
		fixture.deliver(request.id)
		let icon = try #require(try await task.value)
		expectNoDifference(icon.png, SiteIconFixture.png)
		expectNoDifference(icon.width, 1)
		expectNoDifference(icon.height, 1)
	}

	@Test
	internal func missingResultUsesFallbackWithoutInventingImage() async throws {
		let fixture = SiteIconFixture()
		let task = Task { try await fixture.lookup() }
		fixture.deliver(try await fixture.nextCall().id, status: ARX_SITE_ICON_MISSING)
		let value = try await task.value
		expectNoDifference(value, nil)
	}

	/// A miss that names an icon dropped one fetched before DEV-1108 as another host's.
	@Test
	internal func aMissNamingADroppedIconSaysItWasDiscarded() async throws {
		let fixture = SiteIconFixture()
		let task = Task { try await fixture.lookup() }
		fixture.deliver(
			try await fixture.nextCall().id,
			status: ARX_SITE_ICON_MISSING,
			iconURL: "https://accounts.example/favicon.ico"
		)
		await #expect(throws: ChromiumSiteIconFailure.discarded) { try await task.value }
	}

	@Test
	internal func queuedCompletionAfterCancelCannotCompleteNewQuery() async throws {
		let fixture = SiteIconFixture()
		let old = Task { try await fixture.lookup() }
		let original = try await fixture.nextCall()
		old.cancel()
		await #expect(throws: CancellationError.self) { try await old.value }

		let next = Task { try await fixture.lookup() }
		let replacement = try await fixture.nextCall()
		#expect(replacement.id > original.id)
		fixture.deliver(original.id)
		fixture.deliver(replacement.id, status: ARX_SITE_ICON_MISSING)
		let value = try await next.value
		expectNoDifference(value, nil)
		expectNoDifference(SiteIconFixture.cancelled, [original.id])
	}

	@Test(arguments: [true, false])
	internal func cancellationOrDisposalAfterCompletionBeforeResumeRejectsResult(
		cancel: Bool
	) async throws {
		let fixture = SiteIconFixture()
		let task = Task { try await fixture.lookup() }
		fixture.deliver(try await fixture.nextCall().id)
		if cancel {
			task.cancel()
			await #expect(throws: CancellationError.self) { try await task.value }

		} else {
			fixture.bridge.configure(profiles: [])
			await #expect(throws: ChromiumSiteIconFailure.unavailable) { try await task.value }
		}
	}

	@Test
	internal func profileRemovalAndRecreationRejectOldScopeAndLateCompletion() async throws {
		let fixture = SiteIconFixture()
		let oldScope = try fixture.bridge.scope(profileID: fixture.profile)
		let old = Task { try await fixture.lookup() }
		let original = try await fixture.nextCall()
		fixture.bridge.configure(profiles: [])
		fixture.bridge.configure(profiles: [fixture.profile])
		await #expect(throws: ChromiumSiteIconFailure.unavailable) { try await old.value }
		await #expect(throws: ChromiumSiteIconFailure.unavailable) {
			try await fixture.bridge.lookup(pageURL: fixture.url, scope: oldScope)
		}

		let next = Task { try await fixture.lookup() }
		let replacement = try await fixture.nextCall()
		fixture.deliver(original.id)
		fixture.deliver(replacement.id, status: ARX_SITE_ICON_MISSING)
		let value = try await next.value
		expectNoDifference(value, nil)
	}

	@Test
	internal func privateAndReleasedPrivateProfilesNeverQueryDatabase() async throws {
		var api = ArxEngineAPI()
		api.prepare_private_profile = { _ in true }
		api.release_private_profile = { _ in }
		api.lookup_site_icon = { _, _, _ in Issue.record("Private icon reached native database") }
		api.prepare_profile = { _, _ in Issue.record("Private icon prepared ordinary storage") }
		let runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
		defer { runtime.finish() }
		let privateID = UUID()
		try runtime.preparePrivateProfile(privateID)
		for released in [false, true] {
			if released { runtime.releasePrivateProfile(privateID) }
			runtime.configureSiteIconProfiles([privateID])
			await #expect(throws: ChromiumSiteIconFailure.unavailable) {
				try await runtime.siteIcon(pageURL: SiteIconFixture.pageURL, profileID: privateID)
			}
		}
	}

	@Test
	internal func queuedChangeSurvivesPageClosureButNotProfileRecreation() async throws {
		let runtime = SiteIconFixture.makePageRuntime()
		runtime.didBecomeReady()
		defer { runtime.finish() }
		runtime.configureSiteIconProfiles([nil])
		let page = try runtime.makePage()
		var changes = runtime.siteIconChanges().makeAsyncIterator()

		runtime.receiveSiteIconChange(page: page.id, url: SiteIconFixture.pageURL.absoluteString)
		page.close()
		let change = try #require(await changes.next())
		expectNoDifference(change.pageID, page.id)
		expectNoDifference(change.profileID, nil)
		#expect(runtime.isCurrentSiteIconChange(change))

		runtime.configureSiteIconProfiles([])
		runtime.configureSiteIconProfiles([nil])
		#expect(!runtime.isCurrentSiteIconChange(change))
	}

	@Test
	internal func oldPageCannotEmitChangesIntoReplacementProfileGeneration() async throws {
		let runtime = SiteIconFixture.makePageRuntime()
		runtime.didBecomeReady()
		runtime.configureSiteIconProfiles([nil])
		let page = try runtime.makePage()
		var changes = runtime.siteIconChanges().makeAsyncIterator()
		runtime.configureSiteIconProfiles([])
		runtime.configureSiteIconProfiles([nil])

		runtime.receiveSiteIconChange(page: page.id, url: SiteIconFixture.pageURL.absoluteString)
		runtime.finish()
		let change = await changes.next()
		expectNoDifference(change, nil)
	}

	@Test
	internal func lifecycleRefreshesTerminalNavigationAndCloseWithoutProgressStorms() async throws {
		let runtime = SiteIconFixture.makePageRuntime()
		runtime.didBecomeReady()
		runtime.configureSiteIconProfiles([nil])
		let page = try runtime.makePage()
		let stream = runtime.siteIconChanges()

		var navigation = page.navigation
		navigation.url = SiteIconFixture.pageURL
		navigation.isLoading = true
		page.receive(navigation)
		for progress in 0..<20 {
			navigation.title = "Loading \(progress)"
			page.receive(navigation)
		}
		navigation.isLoading = false
		page.receive(navigation)
		navigation.title = "Finished"
		page.receive(navigation)
		navigation.canGoBack = true
		page.receive(navigation)

		navigation.isLoading = true
		page.receive(navigation)
		navigation.isLoading = false
		navigation.errorCode = -105
		page.receive(navigation)
		page.receive(navigation)
		navigation.url = URL(string: "about:blank")
		navigation.errorCode = nil
		page.receive(navigation)
		page.close()
		runtime.finish()

		var changes: [ChromiumSiteIconChange] = []
		for await change in stream {
			changes.append(change)
		}

		// Two load ends, the second load's start, the error page and the close.
		expectNoDifference(changes.count, 5)
		#expect(changes.allSatisfy {
			$0.pageID == page.id && $0.pageURLs == [SiteIconFixture.pageURL] && $0.profileID == nil
		})
	}

	@Test
	internal func changesNameThePageAndTheAddressesItsLoadWentThrough() async throws {
		let runtime = SiteIconFixture.makePageRuntime()
		runtime.didBecomeReady()
		runtime.configureSiteIconProfiles([nil])
		let page = try runtime.makePage()
		let stream = runtime.siteIconChanges()
		let saved = URL(string: "http://fixture.invalid/")!
		let redirected = URL(string: "https://www.fixture.invalid/home")!
		let next = URL(string: "https://www.fixture.invalid/next")!

		var navigation = page.navigation
		navigation.url = saved
		navigation.isLoading = true
		page.receive(navigation)
		navigation.url = redirected
		page.receive(navigation)
		runtime.receiveSiteIconChange(page: page.id, url: redirected.absoluteString)
		navigation.isLoading = false
		page.receive(navigation)

		// The favicon often arrives after the load ends; it still names the redirect.
		runtime.receiveSiteIconChange(page: page.id, url: redirected.absoluteString)

		// A new load starts a new trail.
		navigation.url = next
		navigation.isLoading = true
		page.receive(navigation)
		navigation.isLoading = false
		page.receive(navigation)
		runtime.finish()

		var changes: [ChromiumSiteIconChange] = []
		for await change in stream {
			changes.append(change)
		}
		expectNoDifference(changes.map(\.pageURLs), [
			[saved, redirected],
			[saved, redirected],
			[saved, redirected],
			// The next load's start names the outgoing document's addresses.
			[saved, redirected],
			[next],
		])
		#expect(changes.allSatisfy { $0.pageID == page.id && !$0.isProfileWide })
	}

	@Test
	internal func serverRedirectsAndFaviconAddressesReachTheChange() async throws {
		let runtime = SiteIconFixture.makePageRuntime()
		runtime.didBecomeReady()
		runtime.configureSiteIconProfiles([nil])
		let page = try runtime.makePage()
		let stream = runtime.siteIconChanges()
		let start = URL(string: "https://fixture.invalid/start")!
		let middle = URL(string: "https://middle.fixture.invalid/hop")!
		let end = URL(string: "https://www.fixture.invalid/end")!

		// The snapshots show only the start and the end of the chain.
		var navigation = page.navigation
		navigation.url = start
		navigation.isLoading = true
		page.receive(navigation)
		navigation.url = end
		navigation.isLoading = false
		page.receive(navigation)

		// Native reports the whole chain after the load ended; the middle is new.
		runtime.receiveSiteIconRedirects(page: page.id, urls: [start, middle, end].map(\.absoluteString))

		// Nothing new: no change.
		runtime.receiveSiteIconRedirects(page: page.id, urls: [middle, end].map(\.absoluteString))
		runtime.receiveSiteIconChange(
			page: page.id,
			url: end.absoluteString,
			iconURL: "https://www.fixture.invalid/favicon.ico"
		)
		runtime.finish()

		var changes: [ChromiumSiteIconChange] = []
		for await change in stream {
			changes.append(change)
		}
		expectNoDifference(changes.map(\.pageURLs), [
			[start, end],
			[start, end, middle],
			[start, end, middle],
		])
		expectNoDifference(changes.map(\.iconURL), [
			nil,
			nil,
			URL(string: "https://www.fixture.invalid/favicon.ico"),
		])
	}

	@Test
	internal func truncatedRedirectChainRefreshesTheProfile() async throws {
		let runtime = SiteIconFixture.makePageRuntime()
		runtime.didBecomeReady()
		runtime.configureSiteIconProfiles([nil])
		let page = try runtime.makePage()
		let stream = runtime.siteIconChanges()
		var navigation = page.navigation
		navigation.url = URL(string: "https://fixture.invalid/7")
		navigation.isLoading = true
		page.receive(navigation)
		runtime.receiveSiteIconRedirects(
			page: page.id,
			urls: (0..<8).map { "https://fixture.invalid/\($0)" },
			truncated: true
		)

		// The favicon is stored after the commit: that change reads the profile too.
		runtime.receiveSiteIconChange(page: page.id, url: "https://fixture.invalid/7", iconURL: "https://fixture.invalid/favicon.ico")
		navigation.isLoading = false
		page.receive(navigation)

		// A new load is a new trail.
		navigation.url = URL(string: "https://fixture.invalid/next")
		navigation.isLoading = true
		page.receive(navigation)
		navigation.isLoading = false
		page.receive(navigation)
		runtime.finish()

		var changes: [ChromiumSiteIconChange] = []
		for await change in stream {
			changes.append(change)
		}
		expectNoDifference(changes.map(\.isProfileWide), [true, true, true, true, false])
	}

	@Test
	internal func trailOverflowBeforeTheIconIsKnownRefreshesTheProfile() async throws {
		let runtime = SiteIconFixture.makePageRuntime()
		runtime.didBecomeReady()
		runtime.configureSiteIconProfiles([nil])
		let page = try runtime.makePage()
		let stream = runtime.siteIconChanges()
		var navigation = page.navigation
		navigation.url = URL(string: "https://fixture.invalid/start")
		navigation.isLoading = true
		page.receive(navigation)

		// Nine early same-document addresses: the first falls off the trail.
		for index in 0..<9 {
			runtime.receiveSiteIconRedirects(page: page.id, urls: ["https://fixture.invalid/\(index)"])
		}
		runtime.receiveSiteIconChange(page: page.id, url: "https://fixture.invalid/8")

		// A new load whose icon is known before its trail overflows stays page-scoped.
		navigation.url = URL(string: "https://fixture.invalid/next")
		page.receive(navigation)
		navigation.isLoading = false
		page.receive(navigation)
		navigation.isLoading = true
		page.receive(navigation)
		runtime.receiveSiteIconChange(page: page.id, url: "https://fixture.invalid/next")
		for index in 0..<9 {
			navigation.url = URL(string: "https://fixture.invalid/spa/\(index)")
			navigation.isLoading = false
			page.receive(navigation)
		}
		runtime.finish()

		var changes: [ChromiumSiteIconChange] = []
		for await change in stream {
			changes.append(change)
		}

		// Seven page changes until the trail overflows; from then on the first load's
		// changes (two addresses, its icon, its end, the next load's start) are
		// profile-wide. The second load's icon and nine pushState changes aren't.
		expectNoDifference(
			changes.map(\.isProfileWide),
			Array(repeating: false, count: 7) + Array(repeating: true, count: 5) + Array(repeating: false, count: 10)
		)
	}

	@Test
	internal func databaseOnlyLookupUsesTheCachedEntry() async throws {
		CachedLookupStub.urls = []
		var api = ArxEngineAPI()
		api.lookup_site_icon = { _, _, _ in Issue.record("A database-only read may fetch") }
		api.lookup_cached_site_icon = { _, url, _ in
			MainActor.assumeIsolated { CachedLookupStub.urls.append(String(cString: url!)) }
		}
		let bridge = ChromiumSiteIcons(api: api)
		bridge.configure(profiles: [nil])
		let task = Task { try await bridge.lookup(pageURL: SiteIconFixture.pageURL, scope: bridge.scope(profileID: nil), mayFetch: false) }
		for _ in 0..<1000 where CachedLookupStub.urls.isEmpty {
			await Task.yield()
		}
		expectNoDifference(CachedLookupStub.urls, [SiteIconFixture.pageURL.absoluteString])
		bridge.stop()

		// Stopping cancels the lookup, so it ends with an error; only its end matters here.
		_ = try? await task.value
	}

	@Test
	internal func completionCarriesTheFaviconAddress() async throws {
		let fixture = SiteIconFixture()
		let task = Task { try await fixture.lookup() }
		let call = try await fixture.nextCall()
		SiteIconFixture.png.withUnsafeBytes { bytes in
			fixture.bridge.complete(
				call.id,
				status: ARX_SITE_ICON_SUCCESS,
				bytes: bytes.bindMemory(to: UInt8.self).baseAddress,
				count: bytes.count,
				width: 1,
				height: 1,
				iconURL: "https://fixture.invalid/favicon.ico"
			)
		}
		let icon = try await task.value
		expectNoDifference(icon?.iconURL, URL(string: "https://fixture.invalid/favicon.ico"))
	}

	@Test
	internal func replacingALoadedDocumentRefreshesItsAddressesFirst() async throws {
		let runtime = SiteIconFixture.makePageRuntime()
		runtime.didBecomeReady()
		runtime.configureSiteIconProfiles([nil])
		let page = try runtime.makePage()
		let stream = runtime.siteIconChanges()
		let first = URL(string: "https://fixture.invalid/first")!
		let second = URL(string: "https://fixture.invalid/second")!

		var navigation = page.navigation
		navigation.url = first
		navigation.isLoading = true
		page.receive(navigation)
		navigation.isLoading = false
		page.receive(navigation)

		// The first page writes its icon, then a link replaces it before Chromium's
		// notification is delivered; the snapshot still shows the first address.
		navigation.isLoading = true
		page.receive(navigation)
		navigation.url = second
		page.receive(navigation)
		navigation.isLoading = false
		page.receive(navigation)
		runtime.finish()

		var changes: [ChromiumSiteIconChange] = []
		for await change in stream {
			changes.append(change)
		}
		expectNoDifference(changes.map(\.pageURLs), [[first], [first], [first, second]])
	}

	@Test
	internal func overflowingBufferTurnsADroppedChangeIntoAProfileRefresh() async throws {
		let runtime = SiteIconFixture.makePageRuntime()
		runtime.didBecomeReady()
		runtime.configureSiteIconProfiles([nil])
		let page = try runtime.makePage()
		let stream = runtime.siteIconChanges()
		for index in 0..<300 {
			runtime.receiveSiteIconChange(page: page.id, url: "https://fixture.invalid/\(index)")
		}
		runtime.finish()

		var changes: [ChromiumSiteIconChange] = []
		for await change in stream {
			changes.append(change)
		}
		let last = URL(string: "https://fixture.invalid/299")
		let hasProfileRefresh = changes.contains(where: \.isProfileWide)
		let hasLast = changes.contains { $0.pageURLs.last == last }
		expectNoDifference(changes.count, 256)
		#expect(hasProfileRefresh)
		#expect(hasLast)
	}

	@Test
	internal func pageWithoutAWebAddressPublishesNothing() async throws {
		let runtime = SiteIconFixture.makePageRuntime()
		runtime.didBecomeReady()
		runtime.configureSiteIconProfiles([nil])
		let page = try runtime.makePage()
		let stream = runtime.siteIconChanges()
		var navigation = page.navigation
		navigation.url = URL(string: "about:blank")
		navigation.isLoading = true
		page.receive(navigation)
		navigation.isLoading = false
		page.receive(navigation)
		page.close()
		runtime.finish()

		var changes: [ChromiumSiteIconChange] = []
		for await change in stream {
			changes.append(change)
		}
		expectNoDifference(changes, [])
	}

	@Test
	internal func clearingHistoryRefreshesTheWholeProfileButClearingCacheDoesNot() async throws {
		ProfileDataStub.reset()
		var api = ArxEngineAPI()
		api.prepare_profile = { _, request in
			MainActor.assumeIsolated { ProfileDataStub.prepares.append(request) }
		}
		api.count_browsing_data = { _, _, _, _ in }
		api.clear_browsing_data = { request, _, _, _ in
			MainActor.assumeIsolated { ProfileDataStub.clears.append(request) }
		}
		api.download_settings = { _, _ in }
		api.set_download_settings = { _, _, _, _ in }
		let runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
		defer { runtime.finish() }
		runtime.configureSiteIconProfiles([nil])
		let preparing = Task { try await runtime.prepareProfile(nil) }
		let prepare = try await ProfileDataStub.next { ProfileDataStub.prepares }
		runtime.complete(prepare, true)
		try await preparing.value
		var changes = runtime.siteIconChanges().makeAsyncIterator()

		for kinds: Set<ChromiumBrowsingDataKind> in [[.cache], [.history, .cookies]] {
			let clearing = Task { try await runtime.clearBrowsingData(profile: nil, kinds: kinds, since: nil) }
			let clear = try await ProfileDataStub.next { ProfileDataStub.clears }
			let bytes = Array(#"{"failed":[]}"#.utf8)
			bytes.withUnsafeBufferPointer { buffer in
				runtime.profileData.complete(clear, status: ARX_PROFILE_DATA_OK, json: buffer.baseAddress, count: buffer.count)
			}
			_ = try await clearing.value
		}
		let change = try #require(await changes.next())
		#expect(change.isProfileWide)
		expectNoDifference(change.pageID, nil)
		expectNoDifference(change.profileID, nil)
		#expect(runtime.isCurrentSiteIconChange(change))
	}

	@Test
	internal func lifecycleCannotRefreshRemovedOrRecreatedProfileFromItsOldPage() async throws {
		let runtime = SiteIconFixture.makePageRuntime()
		runtime.didBecomeReady()
		runtime.configureSiteIconProfiles([nil])
		let page = try runtime.makePage()
		let stream = runtime.siteIconChanges()
		runtime.configureSiteIconProfiles([])
		runtime.configureSiteIconProfiles([nil])
		var navigation = page.navigation
		navigation.url = SiteIconFixture.pageURL
		page.receive(navigation)
		page.close()
		runtime.finish()

		var changes: [ChromiumSiteIconChange] = []
		for await change in stream {
			changes.append(change)
		}
		expectNoDifference(changes, [])
	}

	@Test
	internal func privateLifecycleNeverPublishesFaviconRefreshes() async throws {
		let runtime = SiteIconFixture.makePageRuntime()
		runtime.didBecomeReady()
		let profileID = UUID()
		try runtime.preparePrivateProfile(profileID)
		runtime.configureSiteIconProfiles([profileID])
		let page = try await runtime.makePage(profile: profileID)
		let stream = runtime.siteIconChanges()
		var navigation = page.navigation
		navigation.url = SiteIconFixture.pageURL
		page.receive(navigation)
		page.close()
		runtime.finish()

		var changes: [ChromiumSiteIconChange] = []
		for await change in stream {
			changes.append(change)
		}
		expectNoDifference(changes, [])
	}

	@Test
	internal func oversizedPayloadRejectedBeforePointerAccess() async throws {
		let fixture = SiteIconFixture()
		let task = Task { try await fixture.lookup() }
		fixture.bridge.complete(
			try await fixture.nextCall().id,
			status: ARX_SITE_ICON_SUCCESS,
			bytes: nil,
			count: 65_537,
			width: 1,
			height: 1
		)
		await #expect(throws: ChromiumSiteIconFailure.limitExceeded) { try await task.value }
	}

	@Test
	internal func malformedImageOrDimensionMismatchCannotReachPresentation() async throws {
		#expect(throws: ChromiumSiteIconFailure.invalidResponse) {
			try ChromiumSiteIcon(png: Data([1, 2, 3]), width: 1, height: 1)
		}
		#expect(throws: ChromiumSiteIconFailure.invalidResponse) {
			try ChromiumSiteIcon(png: SiteIconFixture.png, width: 2, height: 1)
		}
		#expect(throws: ChromiumSiteIconFailure.limitExceeded) {
			try ChromiumSiteIcon(png: SiteIconFixture.png, width: 33, height: 1)
		}
	}

	@Test(arguments: [ARX_SITE_ICON_UNAVAILABLE, ARX_SITE_ICON_TIMEOUT, ARX_SITE_ICON_BUSY])
	internal func preservesNativeFailure(_ status: ArxSiteIconStatus) async throws {
		let fixture = SiteIconFixture()
		let task = Task { try await fixture.lookup() }
		fixture.deliver(try await fixture.nextCall().id, status: status)
		await #expect(throws: ChromiumSiteIconFailure(status: status)) { try await task.value }
	}

	@Test
	internal func shutdownDrainsPendingRequestsAndDeniesNewScope() async throws {
		let fixture = SiteIconFixture()
		let task = Task { try await fixture.lookup() }
		let request = try await fixture.nextCall()
		fixture.bridge.stop()
		fixture.deliver(request.id)
		await #expect(throws: ChromiumSiteIconFailure.unavailable) { try await task.value }
		#expect(throws: ChromiumSiteIconFailure.unavailable) {
			try fixture.bridge.scope(profileID: fixture.profile)
		}
	}
}

@MainActor
private enum CachedLookupStub {
	fileprivate static var urls: [String] = []
}

@MainActor
private enum ProfileDataStub {
	fileprivate static var prepares: [UInt64] = []
	fileprivate static var clears: [UInt64] = []

	fileprivate static func reset() {
		prepares = []
		clears = []
	}

	fileprivate static func next(_ requests: () -> [UInt64]) async throws -> UInt64 {
		for _ in 0..<1000 {
			if let id = requests().last {
				prepares.removeAll { $0 == id }
				clears.removeAll { $0 == id }
				return id
			}
			await Task.yield()
		}
		throw Failure.missingRequest
	}

	private enum Failure: Error {
		case missingRequest
	}
}

@MainActor
private final class SiteIconFixture {
	private static let view: NSView = .init()
	fileprivate static let pageURL: URL = URL(string: "https://fixture.invalid/saved/page")!
	fileprivate static let png: Data = Data(
		base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
	)!
	fileprivate static var calls: [Call] = []
	fileprivate static var cancelled: [UInt64] = []
	fileprivate let profile: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
	fileprivate let url: URL = SiteIconFixture.pageURL
	fileprivate let bridge: ChromiumSiteIcons

	fileprivate init() {
		Self.calls = []
		Self.cancelled = []
		var api = ArxEngineAPI()
		api.lookup_site_icon = { key, url, id in
			MainActor.assumeIsolated {
				SiteIconFixture.calls.append(.init(
					id: id,
					key: String(cString: key!),
					url: String(cString: url!)
				))
			}
		}
		api.cancel_site_icon = { id in
			MainActor.assumeIsolated { SiteIconFixture.cancelled.append(id) }
		}
		self.bridge = .init(api: api)
		bridge.configure(profiles: [profile])
	}

	fileprivate static func makePageRuntime() -> ChromiumRuntime {
		var api = ArxEngineAPI()
		api.create_page = { _, _ in 1 }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { SiteIconFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.destroy_page = { _ in }
		api.history_count = { _ in 0 }
		api.prepare_private_profile = { _ in true }
		return .init(api: api)
	}

	fileprivate func lookup() async throws -> ChromiumSiteIcon? {
		try await bridge.lookup(pageURL: url, scope: bridge.scope(profileID: profile))
	}

	fileprivate func nextCall() async throws -> Call {
		for _ in 0..<1000 {
			if !Self.calls.isEmpty { return Self.calls.removeFirst() }
			await Task.yield()
		}
		throw Failure.missingCall
	}

	fileprivate func deliver(
		_ id: UInt64,
		status: ArxSiteIconStatus = ARX_SITE_ICON_SUCCESS,
		iconURL: String? = nil
	) {
		Self.png.withUnsafeBytes { bytes in
			bridge.complete(
				id,
				status: status,
				bytes: bytes.bindMemory(to: UInt8.self).baseAddress,
				count: bytes.count,
				width: 1,
				height: 1,
				iconURL: iconURL
			)
		}
	}

	fileprivate struct Call {
		fileprivate let id: UInt64
		fileprivate let key: String
		fileprivate let url: String

		fileprivate init(
			id: UInt64,
			key: String,
			url: String
		) {
			self.id = id
			self.key = key
			self.url = url
		}
	}

	private enum Failure: Error {
		case missingCall
	}
}
