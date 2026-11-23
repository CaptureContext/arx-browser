import BrowserCore
import BrowserSiteIconClient
import Foundation
import Testing
import _TestSupport

@Suite
@MainActor
internal struct BrowserSiteIconStoreTests {
	private static let profile: Profile.ID = .init(rawValue: UUID(1))
	private static let otherProfile: Profile.ID = .init(rawValue: UUID(2))
	private static let page: URL = URL(string: "https://capturecontext.dev/a?b=c#d")!

	@Test
	internal func storedIconsSurviveARelaunchInTheirOwnProfile() throws {
		let directory = Self.temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserSiteIconStore(directory: directory)
		store.store(Data([1]), for: .init(profileID: Self.profile, pageURL: Self.page))
		store.flush()
		store.waitForDisk()

		let relaunched = BrowserSiteIconStore(directory: directory)
		#expect(relaunched.icon(for: .init(profileID: Self.profile, pageURL: Self.page)) == Data([1]))
		#expect(relaunched.icon(for: .init(profileID: Self.otherProfile, pageURL: Self.page)) == nil)
		let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
		#expect(files == ["\(Self.profile.rawValue.uuidString).plist"])
	}

	@Test
	internal func aLiveIconReplacesTheStoredOne() {
		let directory = Self.temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let key = BrowserSiteIconKey(profileID: Self.profile, pageURL: Self.page)
		let store = BrowserSiteIconStore(directory: directory)
		store.store(Data([1]), for: key)
		store.store(Data([2]), for: key)
		#expect(store.icon(for: key) == Data([2]))
		store.flush()
		store.waitForDisk()
		#expect(BrowserSiteIconStore(directory: directory).icon(for: key) == Data([2]))
	}

	/// An icon Chromium dropped as another host's is forgotten here too, on disk as well
	/// (DEV-1108); other pages keep theirs.
	@Test
	internal func aForgottenIconIsGoneAfterARelaunch() {
		let directory = Self.temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let key = BrowserSiteIconKey(profileID: Self.profile, pageURL: Self.page)
		let other = BrowserSiteIconKey(profileID: Self.profile, pageURL: URL(string: "https://other.example/")!)
		let store = BrowserSiteIconStore(directory: directory)
		store.store(Data([1]), for: key)
		store.store(Data([2]), for: other)
		store.forget(key)
		store.forget(key)
		#expect(store.icon(for: key) == nil)
		store.flush()
		store.waitForDisk()
		let relaunched = BrowserSiteIconStore(directory: directory)
		#expect(relaunched.icon(for: key) == nil)
		#expect(relaunched.icon(for: other) == Data([2]))
	}

	@Test
	internal func removingAProfileDeletesOnlyItsIcons() throws {
		let directory = Self.temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let mine = BrowserSiteIconKey(profileID: Self.profile, pageURL: Self.page)
		let other = BrowserSiteIconKey(profileID: Self.otherProfile, pageURL: Self.page)
		let store = BrowserSiteIconStore(directory: directory)
		store.store(Data([1]), for: mine)
		store.store(Data([2]), for: other)
		store.flush()
		store.remove([Self.profile])
		store.waitForDisk()

		#expect(store.icon(for: mine) == nil)
		let relaunched = BrowserSiteIconStore(directory: directory)
		#expect(relaunched.icon(for: mine) == nil)
		#expect(relaunched.icon(for: other) == Data([2]))
		let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
		#expect(files == ["\(Self.otherProfile.rawValue.uuidString).plist"])
	}

	@Test
	internal func retainingTabPagesPrunesTheRest() {
		let directory = Self.temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let kept = BrowserSiteIconKey(profileID: Self.profile, pageURL: Self.page)
		let dropped = BrowserSiteIconKey(profileID: Self.profile, pageURL: URL(string: "https://example.com")!)
		let untouched = BrowserSiteIconKey(profileID: Self.otherProfile, pageURL: URL(string: "https://example.com")!)
		let store = BrowserSiteIconStore(directory: directory)
		store.store(Data([1]), for: kept)
		store.store(Data([2]), for: dropped)
		store.store(Data([3]), for: untouched)
		store.retain([kept], in: [Self.profile])
		store.flush()
		store.waitForDisk()

		let relaunched = BrowserSiteIconStore(directory: directory)
		#expect(relaunched.icon(for: kept) == Data([1]))
		#expect(relaunched.icon(for: dropped) == nil)
		#expect(relaunched.icon(for: untouched) == Data([3]))
	}

	@Test
	internal func evictionKeepsTheMostRecentlyUsedWithinBounds() {
		let directory = Self.temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let clock = Clock()
		let store = BrowserSiteIconStore(directory: directory, maximumEntries: 2, now: { clock.tick() })
		let keys = (0..<3).map {
			BrowserSiteIconKey(profileID: Self.profile, pageURL: URL(string: "https://site\($0).dev")!)
		}
		store.store(Data([0]), for: keys[0])
		store.store(Data([1]), for: keys[1])
		_ = store.icon(for: keys[0])
		store.store(Data([2]), for: keys[2])

		#expect(store.icon(for: keys[0]) == Data([0]))
		#expect(store.icon(for: keys[1]) == nil)
		#expect(store.icon(for: keys[2]) == Data([2]))
	}

	@Test
	internal func refusesOversizedIconsAndNonWebPages() {
		let directory = Self.temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserSiteIconStore(directory: directory)
		let file = BrowserSiteIconKey(profileID: Self.profile, pageURL: URL(string: "file:///tmp/a.html")!)
		let web = BrowserSiteIconKey(profileID: Self.profile, pageURL: Self.page)
		store.store(Data([1]), for: file)
		store.store(Data(count: 65_537), for: web)
		store.store(Data(), for: web)
		#expect(store.icon(for: file) == nil)
		#expect(store.icon(for: web) == nil)
	}

	@Test
	internal func importedIconsFillOnlyPagesWithoutOne() async throws {
		let directory = Self.temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let key = BrowserSiteIconKey(profileID: Self.profile, pageURL: Self.page)
		let other = BrowserSiteIconKey(profileID: Self.profile, pageURL: URL(string: "https://swift.org/")!)
		let store = BrowserSiteIconStore(directory: directory)
		store.store(Data([1]), for: key)

		// DEV-897: an imported icon never replaces the page's own, and a live one replaces it.
		#expect(!store.seed(Data([9]), for: key))
		#expect(store.icon(for: key) == Data([1]))
		#expect(store.seed(Data([9]), for: other))
		#expect(store.icon(for: other) == Data([9]))
		store.store(Data([2]), for: other)
		#expect(store.icon(for: other) == Data([2]))
		#expect(!store.seed(Data(count: 65_537), for: .init(profileID: Self.otherProfile, pageURL: Self.page)))
	}

	private static func temporaryDirectory() -> URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("arx-site-icons-\(UUID())")
	}
}

private final class Clock: @unchecked Sendable {
	private let lock: NSLock = .init()
	private var seconds: TimeInterval = 0

	fileprivate func tick() -> Date {
		lock.withLock {
			seconds += 1
			return Date(timeIntervalSince1970: seconds)
		}
	}
}
