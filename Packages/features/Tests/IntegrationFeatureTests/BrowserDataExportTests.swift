import BrowserCore
import BrowserExtensionsClient
import BrowserHistoryClient
import CustomDump
import Foundation
import MainFeature
import MigrationAssistant
import Testing
import _ComposableArchitecture
import _TestSupport
@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct BrowserDataExportTests {
	private static let destination: URL = URL(fileURLWithPath: "/exports/Arx Archive.json")

	private struct Fixture {
		internal let store: StoreOf<AppFeature>
		internal let written: LockIsolated<[URL: Data]>
	}

	private func fixture(
		destination: URL? = destination,
		extensionsAvailable: Bool = false,
		write: (@Sendable (Data, URL) async throws -> Void)? = nil
	) -> Fixture {
		let written = LockIsolated<[URL: Data]>([:])
		let organization = IntegrationFeatureTests().fixture()
		let main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let store = Store(initialState: AppFeature.State(main: main)) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 1_000)
			$0.browserDataExportClient = .init(
				chooseDestination: { _ in destination },
				write: write ?? { data, url in written.withValue { $0[url] = data } },
				appVersion: { "9.9" }
			)
			$0.browserHistory = .init(
				load: { profile in
					.init(
						snapshot: .init(
							profileID: profile,
							entries: [
								.init(
									id: UUID(70),
									url: URL(string: "https://visited.example.org")!,
									title: "Visited ✨",
									lastVisited: Date(timeIntervalSince1970: 500)
								),
							]
						)
					)
				}
			)
			$0.browserExtensions = .init(
				isAvailable: extensionsAvailable,
				inspect: { profile in
					.init(
						id: UUID(80),
						profileID: profile,
						revision: 1,
						extensions: [
							.init(
								id: "aaaabbbbccccddddeeeeffffgggghhhh",
								name: "Reader",
								version: "1",
								fromWebStore: true,
								state: .enabled
							),
						]
					)
				}
			)
		}
		return .init(store: store, written: written)
	}

	private func archive(_ fixture: Fixture) throws -> ArxTransferArchive {
		try ArxTransferArchive.decode(try #require(fixture.written.value[Self.destination]))
	}

	@Test
	internal func anArchiveLeavesHistoryAndTheTabArchiveOutUnlessIncluded() async throws {
		let fixture = fixture()

		await fixture.store.send(.ui(.exportBrowserData(.archive))).finish()

		let archive = try archive(fixture)
		expectNoDifference(archive.version, 2)
		expectNoDifference(archive.appVersion, "9.9")
		expectNoDifference(archive.createdAt, Date(timeIntervalSince1970: 1_000))
		#expect(archive.history == nil)
		#expect(archive.archivedTabs == nil)
		expectNoDifference(archive.extensions, [])
		expectNoDifference(fixture.store.browserDataExport.progress, nil)
	}

	@Test
	internal func includedHistoryTabArchiveAndExtensionsAreWritten() async throws {
		let fixture = fixture(extensionsAvailable: true)
		fixture.store.send(.browserDataExport(.includesHistoryChanged(true)))
		fixture.store.send(.browserDataExport(.includesArchivedTabsChanged(true)))

		await fixture.store.send(.ui(.exportBrowserData(.archive))).finish()

		let archive = try archive(fixture)
		let profiles = fixture.store.workspace.profiles.map(\.id)
		expectNoDifference(archive.history?.map(\.profileID), profiles.map(\.rawValue))
		expectNoDifference(archive.history?.map(\.entries.first?.title), profiles.map { _ in "Visited ✨" })
		expectNoDifference(archive.archivedTabs, [])
		expectNoDifference(archive.extensions?.map(\.name), profiles.map { _ in "Reader" })
		expectNoDifference(archive.categories, ["organization", "preferences", "extensions", "history", "archivedTabs"])
	}

	@Test
	internal func bookmarksIgnoreTheArchiveChoices() async throws {
		let fixture = fixture()
		fixture.store.send(.browserDataExport(.includesHistoryChanged(true)))

		await fixture.store.send(.ui(.exportBrowserData(.bookmarks))).finish()

		let html = String(decoding: try #require(fixture.written.value[Self.destination]), as: UTF8.self)
		#expect(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
	}

	@Test
	internal func choosingNoDestinationWritesNothing() async {
		let fixture = fixture(destination: nil)

		await fixture.store.send(.ui(.exportBrowserData(.archive))).finish()

		expectNoDifference(fixture.written.value, [:])
		expectNoDifference(fixture.store.browserDataExport.progress, nil)
	}

	@Test
	internal func cancellingStopsTheExportBeforeItsFileIsWritten() async {
		let started = AsyncStream.makeStream(of: Void.self)
		let fixture = fixture(write: { _, _ in
			started.continuation.yield()
			try await Task.never()
		})

		let task = fixture.store.send(.ui(.exportBrowserData(.archive)))
		for await _ in started.stream { break }
		#expect(fixture.store.browserDataExport.progress?.step == .writing)

		// A second request while one runs is ignored.
		fixture.store.send(.ui(.exportBrowserData(.bookmarks)))
		expectNoDifference(fixture.store.browserDataExport.progress?.format, .archive)

		fixture.store.send(.browserDataExport(.cancelTapped))
		await task.finish()

		expectNoDifference(fixture.store.browserDataExport.progress, nil)
		expectNoDifference(fixture.written.value, [:])
	}

	@Test
	internal func aFailedWriteEndsTheExport() async {
		let fixture = fixture(write: { _, _ in throw CocoaError(.fileWriteNoPermission) })

		await fixture.store.send(.ui(.exportBrowserData(.archive))).finish()

		expectNoDifference(fixture.store.browserDataExport.progress, nil)
	}

	@Test
	internal func progressReachesTheStoreAtMostTenTimesASecondPerStep() {
		let start: ContinuousClock.Instant = .now
		let elapsed = LockIsolated<Duration>(.zero)
		var reporter = BrowserDataExportProgressReporter(
			interval: BrowserDataExporting.progressInterval,
			now: { start.advanced(by: elapsed.value) }
		)
		func reading(_ completed: Int) -> BrowserDataExportProgress {
			.init(format: .archive, step: .readingHistory, completed: completed, total: 100)
		}

		var allowed: [Int] = []
		for completed in 0..<20 {
			elapsed.setValue(.milliseconds(completed * 30))
			if reporter.allows(reading(completed)) { allowed.append(completed) }
		}

		// A step change goes through at once.
		let writing = reporter.allows(.init(format: .archive, step: .writing, total: 1))

		expectNoDifference(allowed, [0, 4, 8, 12, 16])
		#expect(writing)
	}
}
