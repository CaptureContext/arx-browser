import BrowserCore
import CustomDump
import Foundation
import Testing

@testable import ChromiumBrowserEngine

/// DEV-878: each tab's back/forward history, kept apart from the workspace file.
@MainActor
internal struct TabNavigationStoreTests {
	private let profile: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
	private let other: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
	private let tab: Tab.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
	private let gone: Tab.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)

	@Test
	internal func aSavedHistoryReadsBackBeforeAndAfterItLands() async throws {
		let directory = Self.directory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = TabNavigationStore(directory: directory)

		store.save(Data([1, 2, 3]), for: tab, profile: profile)
		expectNoDifference(store.load(tab, profile: profile), Data([1, 2, 3]))
		store.flush()

		let relaunched = TabNavigationStore(directory: directory)
		expectNoDifference(relaunched.load(tab, profile: profile), Data([1, 2, 3]))
		#expect(relaunched.load(tab, profile: other) == nil)

		relaunched.remove(tab, profile: profile)
		#expect(relaunched.load(tab, profile: profile) == nil)
		relaunched.flush()
		#expect(TabNavigationStore(directory: directory).load(tab, profile: profile) == nil)
	}

	@Test
	internal func clearHistoryForgetsOnlyThatProfile() async throws {
		let directory = Self.directory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = TabNavigationStore(directory: directory)
		store.save(Data([1]), for: tab, profile: profile)
		store.save(Data([2]), for: gone, profile: other)
		store.flush()

		// Gone at once, before the removal lands.
		store.removeProfile(profile)
		#expect(store.load(tab, profile: profile) == nil)
		store.flush()

		#expect(store.load(tab, profile: profile) == nil)
		expectNoDifference(TabNavigationStore(directory: directory).load(gone, profile: other), Data([2]))
	}

	@Test
	internal func launchForgetsTabsThatAreGone() async throws {
		let directory = Self.directory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = TabNavigationStore(directory: directory)
		store.save(Data([1]), for: tab, profile: profile)
		store.save(Data([2]), for: gone, profile: profile)
		store.flush()

		let relaunched = TabNavigationStore(directory: directory)
		relaunched.prune(keeping: [tab])
		relaunched.flush()

		expectNoDifference(relaunched.load(tab, profile: profile), Data([1]))
		#expect(relaunched.load(gone, profile: profile) == nil)
	}

	private static func directory() -> URL {
		FileManager.default.temporaryDirectory.appending(path: "arx-navigation-tests-\(UUID())")
	}
}
