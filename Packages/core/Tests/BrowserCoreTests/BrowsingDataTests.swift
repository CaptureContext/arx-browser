import CustomDump
import Foundation
import Testing
@testable import BrowserCore

internal struct BrowsingDataTests {
	private let now: Date = .init(timeIntervalSince1970: 1_800_000_000)
	private let profile: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
	private let other: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)

	@Test
	internal func rangesReachBackFromNow() {
		expectNoDifference(BrowsingDataRange.lastHour.start(before: now), now.addingTimeInterval(-3_600))
		expectNoDifference(BrowsingDataRange.lastDay.start(before: now), now.addingTimeInterval(-86_400))
		expectNoDifference(BrowsingDataRange.lastWeek.start(before: now), now.addingTimeInterval(-604_800))
		expectNoDifference(BrowsingDataRange.lastFourWeeks.start(before: now), now.addingTimeInterval(-2_419_200))
		#expect(BrowsingDataRange.allTime.start(before: now) == nil)
	}

	@Test
	internal func historyCountsAndRemovesOnlyTheRange() {
		var snapshot = BrowsingHistorySnapshot(profileID: profile, entries: [
			entry("https://new.example", at: now.addingTimeInterval(-60)),
			entry("https://old.example", at: now.addingTimeInterval(-7_200)),
		])
		let since = BrowsingDataRange.lastHour.start(before: now)
		#expect(snapshot.count(since: since) == 1)
		#expect(snapshot.count(since: nil) == 2)
		snapshot.remove(since: since)
		expectNoDifference(snapshot.entries.map(\.url.host), ["old.example"])
		snapshot.remove(since: nil)
		#expect(snapshot.entries.isEmpty)
	}

	@Test
	internal func downloadsCountFinishedTransfersOfTheProfile() {
		let queue = DownloadQueue(downloads: [
			download("a", profile, .complete, at: now.addingTimeInterval(-60)),
			download("b", profile, .inProgress, at: now.addingTimeInterval(-60)),
			download("c", profile, .cancelled, at: now.addingTimeInterval(-7_200)),
			download("d", other, .complete, at: now.addingTimeInterval(-60)),
		])
		#expect(queue.finishedCount(profileID: profile, since: now.addingTimeInterval(-3_600)) == 1)
		#expect(queue.finishedCount(profileID: profile, since: nil) == 2)
	}

	@Test
	internal func engineCountsKeepTheAppsOwn() {
		var counts = BrowsingDataCounts(history: 4, downloads: 2, cacheBytes: 10)
		counts.merge(engine: .init(cookieSites: 3, siteSettingsSites: 1))
		expectNoDifference(counts, .init(history: 4, downloads: 2, cookieSites: 3, cacheBytes: 10, siteSettingsSites: 1))
		counts.merge(engine: .init(cacheBytes: 99, cacheIsUpperBound: true))
		#expect(counts.cacheBytes == 99)
		#expect(counts.cacheIsUpperBound)
	}

	private func entry(
		_ url: String,
		at date: Date
	) -> BrowsingHistoryEntry {
		.init(id: UUID(), url: URL(string: url)!, title: url, lastVisited: date)
	}

	private func download(
		_ guid: String,
		_ profileID: Profile.ID,
		_ status: BrowserDownload.Status,
		at date: Date
	) -> BrowserDownload {
		.init(id: .init(profileID: profileID, guid: guid), profileName: "P", filename: guid, status: status, startedAt: date)
	}
}
