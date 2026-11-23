import CustomDump
import Foundation
import Testing
@testable import BrowserCore

/// DEV-1015: visit and typed counts in history, and the score the command bar ranks them by.
internal struct HistoryFrecencyTests {
	private let now: Date = .init(timeIntervalSince1970: 1_800_000_000)
	private let profile: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
	private let work: Space.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!)
	private let home: Space.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!)

	@Test
	internal func aNewViewCountsAndATitleUpdateDoesNot() async throws {
		let url = URL(string: "https://news.example/")!
		var snapshot = BrowsingHistorySnapshot(profileID: profile)

		snapshot.record(.init(url: url, title: "News", date: now, isTyped: true, spaceID: work), id: UUID(1))
		snapshot.record(.init(url: url, title: "News · Today", date: now + 1, isNew: false), id: UUID(2))
		snapshot.record(.init(url: url, title: "News", date: now + 60, spaceID: home), id: UUID(3))

		let entry = try #require(snapshot.entries.first)
		expectNoDifference(snapshot.entries.count, 1)
		expectNoDifference(entry.id, UUID(1))
		expectNoDifference(entry.visitCount, 2)
		expectNoDifference(entry.typedCount, 1)
		expectNoDifference(entry.lastSpaceID, home)
		expectNoDifference(entry.lastVisited, now + 60)

		// A title update from an older tab in another space leaves the space as it is.
		snapshot.record(.init(url: url, title: "News · Work", date: now + 90, isNew: false, spaceID: work), id: UUID(4))
		expectNoDifference(snapshot.entries.first?.lastSpaceID, home)
		expectNoDifference(snapshot.entries.first?.title, "News · Work")
	}

	@Test
	internal func aViewRecordedAfterANewerTitleUpdateStillCounts() async throws {
		let url = URL(string: "https://news.example/")!
		var snapshot = BrowsingHistorySnapshot(profileID: profile)
		snapshot.record(.init(url: url, title: "News", date: now), id: UUID(1))

		snapshot.record(.init(url: url, title: "News · Later", date: now + 20, isNew: false), id: UUID(2))
		snapshot.record(.init(url: url, title: "News · Earlier", date: now + 10, isTyped: true), id: UUID(3))

		let entry = try #require(snapshot.entries.first)
		expectNoDifference(entry.visitCount, 2)
		expectNoDifference(entry.typedCount, 1)
		expectNoDifference(entry.title, "News · Later")
		expectNoDifference(entry.lastVisited, now + 20)
	}

	@Test
	internal func importsKeepTheLargerCountsSoImportingTwiceCountsNothingTwice() async throws {
		let url = URL(string: "https://mail.example/")!
		var snapshot = BrowsingHistorySnapshot(profileID: profile)
		snapshot.record(.init(url: url, title: "Mail", date: now, spaceID: work), id: UUID(1))

		let imported = BrowsingHistoryEntry(
			id: UUID(9),
			url: url,
			title: "Inbox",
			lastVisited: now - 86_400,
			visitCount: 40,
			typedCount: 12
		)
		snapshot.merge(imported, id: UUID(2))
		snapshot.merge(imported, id: UUID(3))
		snapshot.merge(
			.init(id: UUID(9), url: URL(string: "https://new.example/")!, title: "New", lastVisited: now - 60, visitCount: 3),
			id: UUID(4)
		)

		let mail = try #require(snapshot.entries.first { $0.url == url })
		expectNoDifference(mail.id, UUID(1))
		expectNoDifference(mail.title, "Mail")
		expectNoDifference(mail.visitCount, 40)
		expectNoDifference(mail.typedCount, 12)
		expectNoDifference(mail.lastVisited, now)
		let added = try #require(snapshot.entries.first { $0.url.host() == "new.example" })
		expectNoDifference(added.id, UUID(4))
		expectNoDifference(added.visitCount, 3)
		#expect(snapshot.isValid)
	}

	@Test
	internal func historyWrittenBeforeCountsReadsAsOneVisitEach() async throws {
		let json = Data("""
		{"id":"00000000-0000-0000-0000-000000000001","url":"https://old.example/","title":"Old","lastVisited":0}
		""".utf8)

		let entry = try JSONDecoder().decode(BrowsingHistoryEntry.self, from: json)

		expectNoDifference(entry.visitCount, 1)
		expectNoDifference(entry.typedCount, 0)
		expectNoDifference(entry.lastSpaceID, nil)
		let roundTrip = try JSONDecoder().decode(BrowsingHistoryEntry.self, from: JSONEncoder().encode(entry))
		expectNoDifference(roundTrip, entry)
	}

	@Test
	internal func aFrequentlyTypedAddressOutscoresARarelyVisitedOne() async throws {
		let typed = BrowsingHistoryEntry(
			id: UUID(1),
			url: URL(string: "https://news.ycombinator.com/")!,
			title: "Hacker News",
			lastVisited: now - 86_400 * 10,
			visitCount: 30,
			typedCount: 20
		)
		let rare = BrowsingHistoryEntry(
			id: UUID(2),
			url: URL(string: "https://news.com/")!,
			title: "News",
			lastVisited: now - 60,
			visitCount: 1
		)

		#expect(HistoryFrecency.score(of: typed, at: now) > HistoryFrecency.score(of: rare, at: now))
	}

	@Test
	internal func theScoreFadesWithAgeAndRisesInItsOwnSpace() async throws {
		var entry = BrowsingHistoryEntry(
			id: UUID(1),
			url: URL(string: "https://docs.example/")!,
			title: "Docs",
			lastVisited: now,
			visitCount: 10,
			lastSpaceID: work
		)
		let fresh = HistoryFrecency.score(of: entry, at: now)
		expectNoDifference(fresh, 10)
		expectNoDifference(HistoryFrecency.score(of: entry, at: now, in: work), 15)
		expectNoDifference(HistoryFrecency.score(of: entry, at: now, in: home), 10)

		entry.lastVisited = now - 86_400 * 20
		expectNoDifference(HistoryFrecency.score(of: entry, at: now), 5)
		entry.lastVisited = now - 86_400 * 365
		expectNoDifference(HistoryFrecency.score(of: entry, at: now), 1)
	}
}

extension UUID {
	fileprivate init(_ value: UInt8) {
		self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
	}
}
