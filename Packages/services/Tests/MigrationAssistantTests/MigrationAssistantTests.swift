import BrowserCore
import CustomDump
import Foundation
import MigrationAssistant
import Testing
import _TestSupport

internal struct MigrationAssistantTests {
	private let planID: MigrationPlan.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!)

	@Test
	internal func aMacWithoutSupportedBrowsersOffersNoSources() throws {
		let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
		expectNoDifference(MigrationBrowserSources.adapters(home: home).map(\.source), [])
	}

	@Test
	internal func inspectionKeepsRepeatedURLsAndReportsInvalidDataWithoutWriting() async throws {
		let destination = FixtureDestination()
		let client = MigrationAssistantClient.running(
			adapters: [MigrationFixtures.adapter()],
			writer: destination.writer
		)

		let sources = try await client.discover()
		expectNoDifference(sources, [MigrationFixtures.source])
		let preview = try await client.inspect(
			MigrationFixtures.sourceID,
			[.openTabs, .bookmarks],
			MigrationFixtures.destination
		)

		expectNoDifference(preview.snapshotID, "snapshot-1")
		expectNoDifference(preview.categories.map(\.category), [.bookmarks, .openTabs])
		let bookmarks = preview.categories[0]
		expectNoDifference(bookmarks.items.map(\.key.sourceItemID), ["b1", "b2", "b3"])
		expectNoDifference(bookmarks.items.map(\.title), ["Swift", "developer.apple.com", "Existing"])
		expectNoDifference(bookmarks.issues.map(\.reason), [.invalidURL, .repeatedSourceItem])
		let tabs = preview.categories[1]
		expectNoDifference(tabs.items.map(\.key.sourceItemID), ["t1", "t2"])
		expectNoDifference(tabs.issues.map(\.reason), [.invalidURL])

		expectNoDifference(destination.commits.value, [])
		expectNoDifference(destination.organization.value, MigrationFixtures.organization())
	}

	@Test
	internal func executionCommitsEachCategoryIntoTheDestinationSpace() async throws {
		let destination = FixtureDestination()
		let client = MigrationAssistantClient.running(
			adapters: [MigrationFixtures.adapter()],
			writer: destination.writer
		)
		let preview = try await client.inspect(
			MigrationFixtures.sourceID,
			[.bookmarks, .openTabs],
			MigrationFixtures.destination
		)
		let plan = MigrationPlan(id: planID, preview: preview)

		let events = try await collect(client.execute(plan))

		expectNoDifference(events.compactMap(\.progress).map(\.category), [nil, .bookmarks, .openTabs, nil])
		let report = try #require(events.last?.report)
		expectNoDifference(report.outcome, .completed)
		expectNoDifference(report.importedCount, 5)
		expectNoDifference(report.retryableCategories, [])

		let organization = destination.organization.value
		try organization.validate()
		let space = try #require(organization.spaces.first)
		expectNoDifference(space.unpinnedTabs.first, MigrationFixtures.existingTabID)
		expectNoDifference(space.unpinnedTabs.count, 3)
		let root = try #require(organization.folders.first { $0.name == "Fixture Browser" })
		expectNoDifference(space.savedItems, [.folder(root.id)])
		expectNoDifference(organization.folders.map(\.name), ["Fixture Browser", "Dev", "Apple"])

		// A URL the space already has, and one repeated in the source, are both kept.
		expectNoDifference(
			organization.tabs.filter { $0.reopeningURL.absoluteString == "https://capturecontext.dev" }.count,
			2
		)
		expectNoDifference(
			organization.tabs.filter { $0.reopeningURL.absoluteString == "https://swift.org" }.count,
			2
		)
	}

	@Test
	internal func partialFailureReportsRetryableCategoryAndRetryIsIdempotent() async throws {
		let destination = FixtureDestination()
		destination.failures.setValue([.openTabs: 1])
		let client = MigrationAssistantClient.running(
			adapters: [MigrationFixtures.adapter()],
			writer: destination.writer
		)
		let plan = MigrationPlan(
			id: planID,
			preview: try await client.inspect(
				MigrationFixtures.sourceID,
				[.bookmarks, .openTabs],
				MigrationFixtures.destination
			)
		)

		let first = try #require(try await collect(client.execute(plan)).last?.report)
		expectNoDifference(first.outcome, .partiallyCompleted)
		expectNoDifference(first.categories.map(\.status), [.committed, .failed])
		expectNoDifference(first.retryableCategories, [.openTabs])
		expectNoDifference(first.categories[1].issues.last?.reason, .commitFailed("The disk is full."))
		let afterFailure = destination.organization.value
		expectNoDifference(afterFailure.spaces[0].unpinnedTabs, [MigrationFixtures.existingTabID])

		let retry = try #require(try await collect(client.execute(plan)).last?.report)
		expectNoDifference(retry.outcome, .completed)
		expectNoDifference(retry.categories[0].imported, [])
		expectNoDifference(
			retry.categories[0].alreadyImported,
			[MigrationFixtures.key(.bookmarks, "b1"), MigrationFixtures.key(.bookmarks, "b2"), MigrationFixtures.key(.bookmarks, "b3")]
		)
		expectNoDifference(
			retry.categories[1].imported,
			[MigrationFixtures.key(.openTabs, "t1"), MigrationFixtures.key(.openTabs, "t2")]
		)
		expectNoDifference(destination.commits.value.map(\.category), [.bookmarks, .openTabs])

		// A third run changes nothing.
		let again = try #require(try await collect(client.execute(plan)).last?.report)
		expectNoDifference(again.importedCount, 0)
		expectNoDifference(destination.commits.value.count, 2)
	}

	@Test
	internal func everyCommitFailingIsAFailedRun() async throws {
		let destination = FixtureDestination()
		destination.failures.setValue([.bookmarks: 1, .openTabs: 1])
		let client = MigrationAssistantClient.running(
			adapters: [MigrationFixtures.adapter()],
			writer: destination.writer
		)
		let plan = MigrationPlan(
			id: planID,
			preview: try await client.inspect(
				MigrationFixtures.sourceID,
				[.bookmarks, .openTabs],
				MigrationFixtures.destination
			)
		)

		let report = try #require(try await collect(client.execute(plan)).last?.report)
		expectNoDifference(report.outcome, .failed)
		expectNoDifference(report.retryableCategories, [.bookmarks, .openTabs])
		expectNoDifference(destination.organization.value, MigrationFixtures.organization())
	}

	@Test
	internal func cancellationStopsAtTheNextCategoryAndKeepsCommittedWork() async throws {
		let destination = FixtureDestination()
		let base = destination.writer
		let client = LockIsolated<MigrationAssistantClient?>(nil)
		let planID = self.planID
		let writer = MigrationDestinationWriter(
			state: base.state,
			commit: { batch in
				try await base.commit(batch)

				// The user cancels while the first category is committing.
				await client.value?.cancel(planID)
			}
		)
		client.setValue(.running(adapters: [MigrationFixtures.adapter()], writer: writer))
		let running = try #require(client.value)
		let plan = MigrationPlan(
			id: planID,
			preview: try await running.inspect(
				MigrationFixtures.sourceID,
				[.bookmarks, .openTabs],
				MigrationFixtures.destination
			)
		)

		let report = try #require(try await collect(running.execute(plan)).last?.report)
		expectNoDifference(report.outcome, .cancelled)
		expectNoDifference(report.categories.map(\.status), [.committed, .notStarted])
		expectNoDifference(report.retryableCategories, [.openTabs])
		expectNoDifference(destination.commits.value.map(\.category), [.bookmarks])
	}

	@Test
	internal func changedSourceUnknownSourceAndInvalidDestinationNeverCommit() async throws {
		let snapshotID = LockIsolated("snapshot-1")
		let destination = FixtureDestination()
		let client = MigrationAssistantClient.running(
			adapters: [MigrationFixtures.adapter(snapshotID: snapshotID)],
			writer: destination.writer
		)
		let plan = MigrationPlan(
			id: planID,
			preview: try await client.inspect(
				MigrationFixtures.sourceID,
				[.bookmarks],
				MigrationFixtures.destination
			)
		)

		snapshotID.setValue("snapshot-2")
		await #expect(throws: MigrationFailure.sourceChanged) {
			try await collect(client.execute(plan))
		}

		var unknown = plan
		unknown.sourceID = .init(rawValue: "missing")
		await #expect(throws: MigrationFailure.unknownSource) {
			try await collect(client.execute(unknown))
		}

		let otherProfile = MigrationDestination(
			profileID: .init(rawValue: UUID()),
			spaceID: MigrationFixtures.spaceID
		)
		await #expect(throws: MigrationFailure.invalidDestination) {
			try await client.inspect(MigrationFixtures.sourceID, [.bookmarks], otherProfile)
		}
		expectNoDifference(destination.commits.value, [])
	}

	@Test
	internal func unreadableSourceIsReportedWithoutTouchingTheDestination() async throws {
		let destination = FixtureDestination()
		let client = MigrationAssistantClient.running(
			adapters: [MigrationFixtures.adapter(fails: true)],
			writer: destination.writer
		)

		await #expect(throws: MigrationFailure.unreadableSource("The source file is unreadable.")) {
			try await client.inspect(MigrationFixtures.sourceID, [.bookmarks], MigrationFixtures.destination)
		}
		expectNoDifference(destination.organization.value, MigrationFixtures.organization())
	}

	@discardableResult
	private func collect(
		_ stream: AsyncThrowingStream<MigrationEvent, any Error>
	) async throws -> [MigrationEvent] {
		var events: [MigrationEvent] = []
		for try await event in stream { events.append(event) }
		return events
	}
}

extension MigrationEvent {
	fileprivate var progress: MigrationProgress? {
		guard case let .progress(value) = self else { return nil }
		return value
	}

	fileprivate var report: MigrationReport? {
		guard case let .finished(value) = self else { return nil }
		return value
	}
}
