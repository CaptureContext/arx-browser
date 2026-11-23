@testable import AppFeature
import BrowserCore
import BrowserPagePreviewClient
import CoreGraphics
import CustomDump
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import _ComposableArchitecture
import _TestSupport

/// DEV-730: hover card pictures for pages that aren't loaded. DEV-1142: site details with the
/// tab's profile.
extension IntegrationFeatureTests {
	@Test
	@MainActor
	internal func anUnloadedTabShowsItsSavedPictureBeforeAnythingIsFetchedOrLoaded() async throws {
		let page = Self.previewPage(UUID(401))
		let saved = try #require(PagePictureCodec.jpeg(Self.image(width: 400, height: 250)))
		let calls = PagePictureCalls()
		let clients = calls.clients(saved: saved)

		let image = await SidebarPagePictures.shared.picture(
			of: page,
			sources: .init(pageDetails: true, fullPages: true),
			clients: clients
		)

		#expect(image?.width == 400)
		expectNoDifference(calls.reads, [page.key])
		#expect(calls.opened.isEmpty)
		#expect(calls.fetched.isEmpty)
	}

	@Test
	@MainActor
	internal func aPrivateWindowNeitherReadsSavesNorFetches() async throws {
		var page = Self.previewPage(UUID(402))
		page.isPrivate = true
		let calls = PagePictureCalls()

		let image = await SidebarPagePictures.shared.picture(
			of: page,
			sources: .init(pageDetails: true, fullPages: true),
			clients: calls.clients(saved: nil)
		)

		#expect(image == nil)
		#expect(page.key == nil)
		#expect(calls.reads.isEmpty)
		#expect(calls.opened.isEmpty)
		#expect(calls.fetched.isEmpty)
		#expect(calls.stored.isEmpty)
	}

	@Test
	@MainActor
	internal func withoutASavedPictureTheSitesOwnPictureAndDescriptionAreUsed() async throws {
		let page = Self.previewPage(UUID(403))
		let calls = PagePictureCalls()
		calls.details = .init(description: "What the page is about", imageURL: URL(string: "https://example.com/card.png"))
		calls.published = try Self.pngData(width: 1_200, height: 630)
		let clients = calls.clients(saved: nil)

		let image = await SidebarPagePictures.shared.picture(
			of: page,
			sources: .init(pageDetails: true, fullPages: false),
			clients: clients
		)
		let key = try #require(page.key)
		let summary = await SidebarPageDetails.shared.details(for: key, clients: clients)?.description

		#expect(image?.width == SidebarThumbnails.maximumWidth)
		#expect(summary == "What the page is about")
		// One fetch of the page answers both, and nothing is saved or loaded.
		expectNoDifference(calls.fetched, [page.tab.restoration.url, URL(string: "https://example.com/card.png")!])
		#expect(calls.opened.isEmpty)
		#expect(calls.stored.isEmpty)

		SidebarPageDetails.shared.forget([page.tab.profileID])
	}

	@Test
	@MainActor
	internal func withBothOptionsOffNothingIsFetchedOrLoaded() async {
		let page = Self.previewPage(UUID(404))
		let calls = PagePictureCalls()

		let image = await SidebarPagePictures.shared.picture(
			of: page,
			sources: .init(pageDetails: false, fullPages: false),
			clients: calls.clients(saved: nil)
		)

		#expect(image == nil)
		#expect(calls.fetched.isEmpty)
		#expect(calls.opened.isEmpty)
	}

	@Test
	@MainActor
	internal func aLoadedPagesNewPictureIsSavedForItsCurrentAddressOutsidePrivateWindows() async throws {
		let ordinary = Self.previewPage(UUID(406))
		var hidden = Self.previewPage(UUID(407))
		hidden.isPrivate = true
		let current = URL(string: "https://example.com/moved-on")!
		let calls = PagePictureCalls()
		calls.frame = try Self.pngImage(width: 800, height: 500)
		calls.live = [ordinary.tab.id: current, hidden.tab.id: current]
		let clients = calls.clients(saved: nil)

		#expect(await SidebarPagePictures.shared.picture(of: ordinary, sources: .init(), clients: clients) != nil)
		#expect(await SidebarPagePictures.shared.picture(of: hidden, sources: .init(), clients: clients) != nil)

		await waitWhile { calls.stored.isEmpty }
		try await Task.sleep(for: .milliseconds(100))
		expectNoDifference(calls.stored, [.init(profileID: ordinary.tab.profileID, pageURL: current)])
		#expect(calls.reads.isEmpty)
	}

	/// DEV-1142: with the profile's cookies wired, both requests carry the page's credentials,
	/// which read the tab's own profile; the site's picture shows and no page is created.
	@Test
	@MainActor
	internal func siteDetailsAskWithTheTabsProfile() async throws {
		let page = Self.previewPage(UUID(408))
		let calls = PagePictureCalls()
		calls.details = .init(description: "Signed in", imageURL: URL(string: "https://example.com/card.png"))
		calls.published = try Self.pngData(width: 1_200, height: 630)
		let clients = calls.clients(saved: nil, withCookies: true)

		let image = await SidebarPagePictures.shared.picture(
			of: page,
			sources: .init(pageDetails: true, fullPages: false),
			clients: clients
		)

		#expect(image != nil)
		#expect(calls.opened.isEmpty)
		expectNoDifference(calls.credentials.map(\.?.pageURL), [page.tab.restoration.url, page.tab.restoration.url])
		let credentials = try #require(calls.credentials.first ?? nil)
		_ = await credentials.cookies(page.tab.restoration.url)
		expectNoDifference(calls.cookieReads, [.init(profileID: page.tab.profileID, pageURL: page.tab.restoration.url)])

		SidebarPageDetails.shared.forget([page.tab.profileID])
	}

	/// With `ARX_SITE_PREVIEW_IMAGES` off nothing carries cookies, as in DEV-730.
	@Test
	@MainActor
	internal func withoutTheProfilesCookiesSiteDetailsCarryNone() async throws {
		let page = Self.previewPage(UUID(409))
		let calls = PagePictureCalls()
		calls.details = .init(imageURL: URL(string: "https://example.com/card.png"))
		calls.published = try Self.pngData(width: 1_200, height: 630)

		_ = await SidebarPagePictures.shared.picture(
			of: page,
			sources: .init(pageDetails: true, fullPages: false),
			clients: calls.clients(saved: nil)
		)

		#expect(calls.credentials.count == 2)
		#expect(calls.credentials.allSatisfy { $0 == nil })

		SidebarPageDetails.shared.forget([page.tab.profileID])
	}

	/// DEV-1142: clearing a profile's cookies or cache forgets the site details fetched with them.
	@Test
	@MainActor
	internal func clearingAProfilesSiteDataForgetsItsSiteDetails() async throws {
		let organization = fixture()
		let profile = organization.profiles[0].id
		let key = BrowserPagePreviewKey(profileID: profile, pageURL: URL(string: "https://example.com/\(UUID())")!)
		let calls = PagePictureCalls()
		calls.details = .init(description: "Cached")
		let clients = calls.clients(saved: nil, withCookies: true)
		_ = await SidebarPageDetails.shared.details(for: key, clients: clients)
		_ = await SidebarPageDetails.shared.details(for: key, clients: clients)
		#expect(calls.fetched.count == 1)

		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.settings(.delegate(.clearedSiteData(profile))))
		await store.finish()

		_ = await SidebarPageDetails.shared.details(for: key, clients: clients)
		#expect(calls.fetched.count == 2)
		SidebarPageDetails.shared.forget([profile])
	}

	@Test
	internal func clearingAProfilesHistoryDeletesItsSavedPictures() async throws {
		let organization = fixture()
		let profile = organization.profiles[0].id
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let removed = LockIsolated<[String]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserPagePreviews = .init(
				removeSince: { id, since in
					removed.withValue { $0.append("\(id.rawValue) \(since.map { "\($0.timeIntervalSince1970)" } ?? "all")") }
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.delegate(.clearHistory(profile))))
		await store.send(.settings(.delegate(.clearHistorySince(profile, Date(timeIntervalSince1970: 50)))))
		await store.finish()

		expectNoDifference(removed.value, ["\(profile.rawValue) all", "\(profile.rawValue) 50.0"])
	}

	@Test
	internal func removingAProfileDeletesItsSavedPictures() async throws {
		var organization = fixture()
		let removedProfile = Profile.ID(rawValue: UUID(91))
		organization.profiles.append(.init(id: removedProfile, name: "Removed"))
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.sidebar.organization = state.workspace
		let removed = LockIsolated<[Set<Profile.ID>]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserPagePreviews = .init(removeProfiles: { ids in removed.withValue { $0.append(ids) } })
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.delegate(.changeOrganization(.removeProfile(removedProfile)))))
		await store.finish()

		expectNoDifference(removed.value, [[removedProfile]])
	}

	@Test
	internal func aMainWindowTabsPictureBelongsToItsProfileAndLastAddress() throws {
		let organization = fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let tab = organization.tabs[0]

		let page = try #require(state.sidebarPreviewPage(in: state.main.id, tabID: tab.id.rawValue))

		#expect(!page.isPrivate)
		expectNoDifference(page.key, .init(profileID: tab.profileID, pageURL: tab.restoration.url))
		#expect(state.sidebarPreviewPage(in: UUID(999), tabID: tab.id.rawValue) == nil)
	}

	// MARK: - Shift + hover (DEV-1029)

	/// A private window fetches nothing, and a loaded page's card takes its live picture as usual.
	@Test
	@MainActor
	internal func shiftHoverLoadsNothingInAPrivateWindowOrForALoadedPage() async throws {
		var hidden = Self.previewPage(UUID(411))
		hidden.isPrivate = true
		let loaded = Self.previewPage(UUID(412))
		let calls = PagePictureCalls()
		calls.frame = try Self.pngImage(width: 800, height: 500)
		calls.live[loaded.tab.id] = loaded.tab.restoration.url
		let clients = calls.clients(saved: nil)

		#expect(await SidebarPagePictures.shared.livePicture(of: hidden, clients: clients) == nil)
		#expect(await SidebarPagePictures.shared.livePicture(of: loaded, clients: clients) == nil)
		#expect(calls.opened.isEmpty)
		#expect(calls.reads.isEmpty)
		#expect(calls.stored.isEmpty)
	}

	/// The window's previews offer the live load only while the setting is on, apart from Full
	/// previews.
	@Test
	@MainActor
	internal func theLiveLoadIsOfferedOnlyWhileShiftHoverIsOn() throws {
		let organization = fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))

		// Preferences are shared, so each store reads them as they are when its previews are made.
		state.settings.$general.withLock {
			$0.hoverPreviewsEnabled = true
			$0.hoverPreviewSources = .init(fullPages: true, shiftLoadsPages: false)
		}
		let off = Store(initialState: state) { EmptyReducer<AppFeature.State, AppFeature.Action>() }
		let withoutShift = try #require(sidebarHoverPreviews(store: off, windowID: state.main.id, clients: .init()))
		#expect(withoutShift.livePage == nil)

		state.settings.$general.withLock { $0.hoverPreviewSources = .init(fullPages: false, shiftLoadsPages: true) }
		let on = Store(initialState: state) { EmptyReducer<AppFeature.State, AppFeature.Action>() }
		let withShift = try #require(sidebarHoverPreviews(store: on, windowID: state.main.id, clients: .init()))
		#expect(withShift.livePage != nil)
	}

	/// Loading a page off screen takes one page at a time (`SidebarPagePictures`), so the tests
	/// that load one run one after another.
	@Suite(.serialized)
	internal struct PageLoads {
		@Test
		@MainActor
		internal func fullPreviewsLoadAPageOfItsOwnSilenceItTakeItsPictureAndCloseIt() async throws {
			let page = IntegrationFeatureTests.previewPage(UUID(405))
			let calls = PagePictureCalls()
			calls.frame = try IntegrationFeatureTests.pngImage(width: 800, height: 500)
			let clients = calls.clients(saved: nil)

			let image = await SidebarPagePictures.shared.picture(
				of: page,
				sources: .init(pageDetails: false, fullPages: true),
				clients: clients
			)

			#expect(image?.width == SidebarThumbnails.maximumWidth)
			let opened = try #require(calls.opened.first)
			#expect(calls.opened.count == 1)
			// A page of its own: another ID, the tab's profile and last address, nothing else.
			#expect(opened.id != page.tab.id)
			#expect(opened.profileID == page.tab.profileID)
			#expect(opened.reopeningURL == page.tab.restoration.url)
			#expect(opened.savedDestination == nil)
			expectNoDifference(calls.muted, [opened.id])
			expectNoDifference(calls.closed, [opened.id])
			#expect(calls.fetched.isEmpty)

			// The picture is saved for the tab's own address in its profile.
			await waitWhile { calls.stored.isEmpty }
			expectNoDifference(calls.stored, [page.key])
		}

		/// A request that comes while the tab's page is loading, such as the card Shift replaced
		/// asking again, takes the same picture; one for another tab finds the load busy.
		@Test
		@MainActor
		internal func requestsDuringALoadShareItForTheSameTab() async throws {
			let page = IntegrationFeatureTests.previewPage(UUID(413))
			let other = IntegrationFeatureTests.previewPage(UUID(414))
			let calls = PagePictureCalls()
			calls.frame = try IntegrationFeatureTests.pngImage(width: 800, height: 500)
			let clients = calls.clients(saved: nil)

			let first = Task { await SidebarPagePictures.shared.livePicture(of: page, clients: clients) }
			for _ in 0..<1_000 where calls.opened.isEmpty {
				await Task.yield()
			}
			try #require(calls.opened.count == 1)

			let busy = await SidebarPagePictures.shared.livePicture(of: other, clients: clients)
			let second = await SidebarPagePictures.shared.picture(
				of: page,
				sources: .init(pageDetails: false, fullPages: true),
				clients: clients
			)
			let firstImage = await first.value

			#expect(busy == nil)
			#expect(firstImage?.width == SidebarThumbnails.maximumWidth)
			#expect(second?.width == SidebarThumbnails.maximumWidth)
			#expect(calls.opened.count == 1)
		}

		/// A tab whose address changed while its old page loads doesn't take the old page's picture.
		@Test
		@MainActor
		internal func aLoadIsntSharedWithTheSameTabAtAnotherAddress() async throws {
			let page = IntegrationFeatureTests.previewPage(UUID(415))
			var moved = page
			moved.tab.restoration.url = URL(string: "https://example.com/elsewhere")!
			let calls = PagePictureCalls()
			calls.frame = try IntegrationFeatureTests.pngImage(width: 800, height: 500)
			let clients = calls.clients(saved: nil)

			let first = Task { await SidebarPagePictures.shared.livePicture(of: page, clients: clients) }
			for _ in 0..<1_000 where calls.opened.isEmpty {
				await Task.yield()
			}
			try #require(calls.opened.count == 1)

			#expect(await SidebarPagePictures.shared.livePicture(of: moved, clients: clients) == nil)
			#expect(await first.value != nil)
			#expect(calls.opened.count == 1)
			// The picture is saved for the address it was taken at, never the new one.
			await waitWhile { calls.stored.isEmpty }
			expectNoDifference(calls.stored, [page.key])
		}

		/// Shift + hover loads the page instantly: a fresh load, saved picture or not, with Full
		/// previews off; the new picture is saved.
		@Test
		@MainActor
		internal func shiftHoverLoadsAFreshPageWhateverIsSavedOrFullPreviewsSays() async throws {
			let page = IntegrationFeatureTests.previewPage(UUID(410))
			let calls = PagePictureCalls()
			calls.frame = try IntegrationFeatureTests.pngImage(width: 800, height: 500)
			let saved = try #require(PagePictureCodec.jpeg(IntegrationFeatureTests.image(width: 400, height: 250)))

			let image = await SidebarPagePictures.shared.livePicture(of: page, clients: calls.clients(saved: saved))

			#expect(image?.width == SidebarThumbnails.maximumWidth)
			#expect(calls.reads.isEmpty)
			let opened = try #require(calls.opened.first)
			#expect(calls.opened.count == 1)
			#expect(opened.id != page.tab.id)
			#expect(opened.profileID == page.tab.profileID)
			expectNoDifference(calls.muted, [opened.id])
			expectNoDifference(calls.closed, [opened.id])
			#expect(calls.fetched.isEmpty)
			await waitWhile { calls.stored.isEmpty }
			expectNoDifference(calls.stored, [page.key])
		}
	}

	// MARK: - Fixtures

	/// Each page has a profile of its own: site details are cached for the whole process, and
	/// tests run in parallel, so one test forgetting its profile must not clear another's.
	private static func previewPage(_ id: UUID) -> SidebarPreviewPage {
		.init(
			tab: .init(
				id: .init(rawValue: id),
				profileID: .init(rawValue: id),
				savedDestination: .init(title: "Saved", url: URL(string: "https://example.com/saved")!),
				restoration: .init(title: "Report", url: URL(string: "https://example.com/report/\(id.uuidString)")!)
			),
			isPrivate: false
		)
	}

	private static func image(
		width: Int,
		height: Int
	) throws -> CGImage {
		let context = try #require(CGContext(
			data: nil,
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		))
		context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		return try #require(context.makeImage())
	}

	private static func pngData(
		width: Int,
		height: Int
	) throws -> Data {
		let data = NSMutableData()
		let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
		CGImageDestinationAddImage(destination, try image(width: width, height: height), nil)
		#expect(CGImageDestinationFinalize(destination))
		return data as Data
	}

	private static func pngImage(
		width: Int,
		height: Int
	) throws -> PageCaptureImage {
		.init(png: try pngData(width: width, height: height), width: width, height: height)
	}
}

/// Records what hover card pictures asked of the engine and the picture client.
@MainActor
private final class PagePictureCalls {
	internal var reads: [BrowserPagePreviewKey?] = []
	internal var opened: [BrowserCore.Tab] = []
	internal var muted: [BrowserCore.Tab.ID] = []
	internal var closed: [BrowserCore.Tab.ID] = []
	internal var fetched: [URL] = []

	/// What each site details request carried: nil for no cookies.
	internal var credentials: [PageFetchCredentials?] = []

	/// The profile and address each cookie read was for.
	internal var cookieReads: [BrowserPagePreviewKey] = []
	internal var stored: [BrowserPagePreviewKey?] = []
	internal var details: PageDetails?
	internal var published: Data?
	internal var frame: PageCaptureImage?

	/// Loaded tabs and their current address.
	internal var live: [BrowserCore.Tab.ID: URL] = [:]

	internal func clients(
		saved: Data?,
		withCookies: Bool = false
	) -> SidebarPreviewClients {
		let siteCookies: (@MainActor @Sendable (Profile.ID, URL) async -> [HTTPCookie]) = { [self] profileID, url in
			cookieReads.append(.init(profileID: profileID, pageURL: url))
			return []
		}
		return .init(
			snapshot: { [self] id in
				if let url = live[id] {
					return .init(navigation: .init(url: url), revision: 1, isVisibleForCapture: false)
				}
				guard opened.contains(where: { $0.id == id }), !closed.contains(id) else { return nil }
				return .init(
					navigation: .init(url: opened.first { $0.id == id }?.restoration.url),
					revision: 1,
					isVisibleForCapture: false
				)
			},
			capture: .init(
				isAvailable: { true },
				offscreenIsAvailable: { true },
				captureAuthorized: { [self] request, _ in
					guard let frame else { throw PageCaptureFailure.unavailable }
					return .init(
						request: request,
						documentID: "fixture",
						image: frame,
						viewportWidth: Double(frame.width),
						viewportHeight: Double(frame.height),
						deviceScale: 1,
						wasLoading: false
					)
				}
			),
			pagePreviews: .init(
				picture: { [self] key in
					await MainActor.run { reads.append(key) }
					return saved.map { .init(jpeg: $0, takenAt: .now) }
				},
				store: { [self] _, key in await MainActor.run { stored.append(key) } },
				details: { [self] url, credentials in
					await MainActor.run {
						fetched.append(url)
						self.credentials.append(credentials)
						return details
					}
				},
				image: { [self] url, credentials in
					await MainActor.run {
						fetched.append(url)
						self.credentials.append(credentials)
						return published
					}
				}
			),
			siteCookies: withCookies ? siteCookies : nil,
			openPage: { [self] tab in opened.append(tab) },
			mutePage: { [self] id in muted.append(id) },
			closePage: { [self] id in closed.append(id) }
		)
	}
}
