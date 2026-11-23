import BrowserCore
import BrowserPagePreviewClient
import CustomDump
import Foundation
import Testing

/// DEV-730: saved pictures of pages, per profile.
internal struct BrowserPagePreviewStoreTests {
	private let directory: URL = FileManager.default.temporaryDirectory
		.appendingPathComponent("arx-page-previews-\(UUID().uuidString)", isDirectory: true)
	private let work: Profile.ID = .init(rawValue: UUID())
	private let home: Profile.ID = .init(rawValue: UUID())
	private let page: URL = URL(string: "https://example.com/report")!

	@Test
	internal func picturesSurviveANewStoreOnTheSameDirectory() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let picture = Self.picture(1, at: 100)
		await BrowserPagePreviewStore(directory: directory).store(picture, for: key(work))

		let reopened = BrowserPagePreviewStore(directory: directory)
		let read = try #require(await reopened.picture(for: key(work)))
		expectNoDifference(read.jpeg, picture.jpeg)
		#expect(abs(read.takenAt.timeIntervalSince(picture.takenAt)) < 1)
	}

	@Test
	internal func profilesNeverShareAPicture() async {
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserPagePreviewStore(directory: directory)
		await store.store(Self.picture(1, at: 100), for: key(work))

		#expect(await store.picture(for: key(home)) == nil)
		#expect(await BrowserPagePreviewStore(directory: directory).picture(for: key(home)) == nil)
	}

	@Test
	internal func fileNamesDoNotRevealTheAddress() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		await BrowserPagePreviewStore(directory: directory).store(Self.picture(1, at: 100), for: key(work))

		let folder = directory.appendingPathComponent(work.rawValue.uuidString)
		let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
		#expect(names.count == 1)
		#expect(names.allSatisfy { !$0.contains("example") && $0.hasSuffix(".jpg") && $0.count == 68 })
	}

	@Test
	internal func clearingHistoryDeletesTheProfilesPicturesOnly() async {
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserPagePreviewStore(directory: directory)
		await store.store(Self.picture(1, at: 100), for: key(work))
		await store.store(Self.picture(2, at: 100), for: key(home))

		await store.remove(work, since: nil)

		#expect(await store.picture(for: key(work)) == nil)
		#expect(await store.picture(for: key(home)) != nil)
		#expect(await BrowserPagePreviewStore(directory: directory).picture(for: key(work)) == nil)
	}

	@Test
	internal func clearingRecentHistoryKeepsOlderPictures() async {
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserPagePreviewStore(directory: directory)
		let older = URL(string: "https://example.com/older")!
		await store.store(Self.picture(1, at: 100), for: .init(profileID: work, pageURL: older))
		await store.store(Self.picture(2, at: 10_000), for: key(work))

		await store.remove(work, since: Date(timeIntervalSince1970: 5_000))

		#expect(await store.picture(for: .init(profileID: work, pageURL: older)) != nil)
		#expect(await store.picture(for: key(work)) == nil)
	}

	@Test
	internal func aPictureStartedBeforeItsProfileWasClearedIsRefused() async {
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserPagePreviewStore(directory: directory, now: { Date(timeIntervalSince1970: 1_000) })
		await store.store(Self.picture(1, at: 500), for: key(work))
		await store.remove(work, since: nil)

		// Taken (started) before the clear, landing after it: refused, and the folder stays gone.
		await store.store(Self.picture(2, at: 900), for: key(work))
		#expect(await store.picture(for: key(work)) == nil)
		#expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(work.rawValue.uuidString).path))
		// Removing a profile works the same way.
		await store.remove([home])
		await store.store(Self.picture(3, at: 1_000), for: key(home))
		#expect(await store.picture(for: key(home)) == nil)

		// A picture started after the clear is kept.
		await store.store(Self.picture(4, at: 1_100), for: key(work))
		#expect(await store.picture(for: key(work)) != nil)
	}

	@Test
	internal func aRangedClearAlsoRefusesPicturesStartedBeforeIt() async {
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserPagePreviewStore(directory: directory, now: { Date(timeIntervalSince1970: 1_000) })
		await store.remove(work, since: Date(timeIntervalSince1970: 800))

		await store.store(Self.picture(1, at: 950), for: key(work))
		#expect(await store.picture(for: key(work)) == nil)
	}

	@Test
	internal func removingAProfileDeletesItsFolder() async {
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserPagePreviewStore(directory: directory)
		await store.store(Self.picture(1, at: 100), for: key(work))

		await store.remove([work])

		#expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(work.rawValue.uuidString).path))
	}

	@Test
	internal func retainingTabPagesPrunesTheRest() async {
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserPagePreviewStore(directory: directory)
		let closed = URL(string: "https://example.com/closed")!
		await store.store(Self.picture(1, at: 100), for: key(work))
		await store.store(Self.picture(2, at: 100), for: .init(profileID: work, pageURL: closed))
		await store.store(Self.picture(3, at: 100), for: key(home))

		await store.retain([key(work)], in: [work])

		#expect(await store.picture(for: key(work)) != nil)
		#expect(await store.picture(for: .init(profileID: work, pageURL: closed)) == nil)
		// Profiles that weren't listed are left alone.
		#expect(await store.picture(for: key(home)) != nil)
	}

	@Test
	internal func evictionKeepsTheNewestPictures() async {
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserPagePreviewStore(directory: directory, maximumEntries: 2)
		let pages = (0..<3).map { URL(string: "https://example.com/\($0)")! }
		for (index, page) in pages.enumerated() {
			await store.store(Self.picture(UInt8(index), at: Double(100 * (index + 1))), for: .init(profileID: work, pageURL: page))
		}

		#expect(await store.picture(for: .init(profileID: work, pageURL: pages[0])) == nil)
		#expect(await store.picture(for: .init(profileID: work, pageURL: pages[1])) != nil)
		#expect(await store.picture(for: .init(profileID: work, pageURL: pages[2])) != nil)
	}

	@Test
	internal func refusesNonWebPagesAndThingsThatAreNotBoundedJPEGs() async {
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserPagePreviewStore(directory: directory)
		let file = BrowserPagePreviewKey(profileID: work, pageURL: URL(string: "file:///etc/hosts")!)
		await store.store(Self.picture(1, at: 100), for: file)
		await store.store(.init(jpeg: Data("not a jpeg".utf8), takenAt: .now), for: key(work))
		let huge = Data([0xFF, 0xD8, 0xFF]) + Data(count: BrowserPagePreviewStore.maximumPictureBytes)
		await store.store(.init(jpeg: huge, takenAt: .now), for: key(home))

		#expect(await store.picture(for: file) == nil)
		#expect(await store.picture(for: key(work)) == nil)
		#expect(await store.picture(for: key(home)) == nil)
	}

	private func key(_ profileID: Profile.ID) -> BrowserPagePreviewKey {
		.init(profileID: profileID, pageURL: page)
	}

	private static func picture(
		_ marker: UInt8,
		at seconds: TimeInterval
	) -> BrowserPagePicture {
		.init(jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0, marker]), takenAt: Date(timeIntervalSince1970: seconds))
	}
}
