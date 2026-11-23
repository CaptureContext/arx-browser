import BrowserCore
import CustomDump
import Foundation
import HistoryFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct HistoryFeatureTests {
	@Test
	internal func groupsEntriesByDayInTheUsersTimeZoneNewestFirst() {
		let state = HistoryFeature.State(profileID: Fixture.profileID, entries: Fixture.entries.shuffled())
		let days = state.days(in: Fixture.calendar)

		expectNoDifference(days.map(\.id), [Fixture.day(0), Fixture.day(-1), Fixture.day(-5)])
		expectNoDifference(days.map { $0.entries.map(\.title) }, [
			["Arx", "Point-Free", "Late night"],
			["Swift Forums", "Point-Free Episode"],
			["Old news"],
		])
	}

	@Test
	internal func searchMatchesEveryWordInTitleOrAddress() async {
		let store = TestStore(initialState: Fixture.state()) { HistoryFeature() }

		await store.send(.ui(.queryChanged("point"))) { $0.query = "point" }
		expectNoDifference(store.state.visibleEntries.map(\.title), ["Point-Free", "Point-Free Episode"])

		await store.send(.ui(.queryChanged("forums swift"))) { $0.query = "forums swift" }
		expectNoDifference(store.state.days(in: Fixture.calendar).map(\.id), [Fixture.day(-1)])

		await store.send(.ui(.queryChanged("capturecontext.dev"))) { $0.query = "capturecontext.dev" }
		expectNoDifference(store.state.visibleEntries.map(\.title), ["Arx"])

		await store.send(.ui(.queryChanged("nothing like this"))) { $0.query = "nothing like this" }
		#expect(store.state.days(in: Fixture.calendar).isEmpty)

		await store.send(.ui(.queryChanged("  "))) { $0.query = "  " }
		#expect(store.state.visibleEntries.count == Fixture.entries.count)
	}

	@Test
	internal func openingAnEntryAsksForANewTab() async {
		let store = TestStore(initialState: Fixture.state()) { HistoryFeature() }

		await store.send(.ui(.open(Fixture.entries[1].id)))
		await store.receive(\.delegate.open, Fixture.entries[1].url)
		await store.send(.ui(.open(UUID(999))))
	}

	@Test
	internal func deletingAnEntryDeletesOnlyItsAddressAtOnce() async {
		let deleted = LockIsolated<[BrowsingHistoryRemoval]>([])
		let store = TestStore(initialState: Fixture.state()) { Fixture.recording(deleted) }

		await store.send(.ui(.delete(Fixture.entries[0].id)))
		await store.receive(\.delegate.remove)
		expectNoDifference(deleted.value, [.entries([Fixture.entries[0].id])])
	}

	@Test
	internal func deletingADayConfirmsFirstAndRemovesTheWholeDayEvenWhileSearching() async {
		let deleted = LockIsolated<[BrowsingHistoryRemoval]>([])
		let store = TestStore(initialState: Fixture.state(query: "point")) { Fixture.recording(deleted) } withDependencies: {
			$0.calendar = Fixture.calendar
		}

		await store.send(.ui(.deleteDay(Fixture.date(day: 0, hour: 15)))) {
			$0.pendingDeletion = .day(Fixture.day(0))
		}
		await store.send(.ui(.deletionConfirmed)) {
			$0.pendingDeletion = nil
		}
		await store.receive(\.delegate.remove)

		// The search shows only Point-Free, but the day's other pages go too.
		expectNoDifference(deleted.value, [.entries(Set(Fixture.entries.prefix(3).map(\.id)))])
	}

	@Test
	internal func cancellingADeletionDeletesNothing() async {
		let store = TestStore(initialState: Fixture.state()) { HistoryFeature() } withDependencies: {
			$0.calendar = Fixture.calendar
		}

		await store.send(.ui(.deleteDay(Fixture.day(-1)))) {
			$0.pendingDeletion = .day(Fixture.day(-1))
		}
		await store.send(.ui(.deletionCancelled)) {
			$0.pendingDeletion = nil
		}
		await store.send(.ui(.deletionConfirmed))

		// A day with no history asks nothing.
		await store.send(.ui(.deleteDay(Fixture.day(-3))))
	}

	@Test
	internal func deletingASiteRemovesEveryPageOfItWithOrWithoutWWW() async {
		let deleted = LockIsolated<[BrowsingHistoryRemoval]>([])
		let store = TestStore(initialState: Fixture.state()) { Fixture.recording(deleted) } withDependencies: {
			$0.calendar = Fixture.calendar
		}

		let pointFree = Fixture.entries.first { $0.title == "Point-Free" }!
		await store.send(.ui(.deleteSite(pointFree.id))) {
			$0.pendingDeletion = .site("www.pointfree.co")
		}
		await store.send(.ui(.deletionConfirmed)) {
			$0.pendingDeletion = nil
		}
		await store.receive(\.delegate.remove)

		// The command bar's Delete All from removes the same pages: both spellings of the site.
		expectNoDifference(deleted.value, [.site("www.pointfree.co")])
		expectNoDifference(
			Fixture.entries.filter { BrowsingHistoryRemoval.site("pointfree.co").matches($0) }.map(\.title),
			["Point-Free", "Point-Free Episode"]
		)
	}

	/// The host goes up as it is, so a removal normalizes it once, as it does each entry's.
	@Test
	internal func deletingASiteNormalizesItsHostOnlyOnce() async {
		let odd = BrowsingHistoryEntry(
			id: UUID(20),
			url: URL(string: "https://www.www.example.com/")!,
			title: "Odd",
			lastVisited: Fixture.date(day: 0, hour: 10)
		)
		let deleted = LockIsolated<[BrowsingHistoryRemoval]>([])
		let store = TestStore(initialState: HistoryFeature.State(
			profileID: Fixture.profileID,
			entries: Fixture.entries + [odd]
		)) { Fixture.recording(deleted) }

		await store.send(.ui(.deleteSite(odd.id))) {
			$0.pendingDeletion = .site("www.www.example.com")
		}
		expectNoDifference(store.state.entries(of: .site("www.www.example.com"), in: Fixture.calendar), [odd])
		await store.send(.ui(.deletionConfirmed)) {
			$0.pendingDeletion = nil
		}
		await store.receive(\.delegate.remove)
		expectNoDifference(deleted.value, [.site("www.www.example.com")])
	}

	@Test
	internal func withoutAProfileNothingIsDeleted() async {
		var state = Fixture.state()
		state.profileID = nil
		let store = TestStore(initialState: state) { HistoryFeature() } withDependencies: {
			$0.calendar = Fixture.calendar
		}

		await store.send(.ui(.delete(Fixture.entries[0].id)))
		await store.send(.ui(.deleteDay(Fixture.day(0))))
		await store.send(.ui(.deleteSite(Fixture.entries[0].id)))
	}

	@Test
	internal func dayTitlesNameTodayAndYesterdayAndShowTheYearOnlyWhenOlder() {
		let now = Fixture.date(day: 0, hour: 12)
		let locale = Locale(identifier: "en_US")
		let title = { (date: Date) in
			HistoryFeature.title(ofDay: date, now: now, calendar: Fixture.calendar, locale: locale)
		}

		#expect(title(Fixture.day(0)) == "Today")
		#expect(title(Fixture.day(-1)) == "Yesterday")
		#expect(title(Fixture.day(-5)) == "Friday, November 6")
		#expect(title(Fixture.day(-330)).hasSuffix(", 2025"))
		// Just before midnight in Kyiv is still that day there.
		#expect(title(Fixture.date(day: -1, hour: 23, minute: 30)) == "Yesterday")
	}

	@Test
	internal func siteDropsALeadingWWWAndIgnoresCase() {
		#expect(HistoryFeature.site(of: URL(string: "https://WWW.Example.com/a")!) == "example.com")
		#expect(HistoryFeature.site(of: URL(string: "https://docs.example.com/")!) == "docs.example.com")
	}
}

internal enum Fixture {
	internal static let profileID = Profile.ID(rawValue: UUID(1))

	/// Kyiv is two hours ahead of UTC in November, so a visit at 23:30 there is the next day in UTC.
	internal static let calendar: Calendar = {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
		calendar.locale = Locale(identifier: "en_US")
		return calendar
	}()

	/// Wednesday, 11 November 2026, at this hour in Kyiv, moved by whole days.
	internal static func date(
		day: Int,
		hour: Int,
		minute: Int = 0
	) -> Date {
		let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: hour, minute: minute))!
		return calendar.date(byAdding: .day, value: day, to: base)!
	}

	internal static func day(_ offset: Int) -> Date {
		calendar.startOfDay(for: date(day: offset, hour: 12))
	}

	internal static let entries: [BrowsingHistoryEntry] = [
		entry(1, "Arx", "https://capturecontext.dev/arx", date(day: 0, hour: 18)),
		entry(2, "Point-Free", "https://www.pointfree.co/", date(day: 0, hour: 9)),
		entry(3, "Late night", "https://example.com/late", date(day: 0, hour: 0, minute: 30)),
		entry(4, "Swift Forums", "https://forums.swift.org/", date(day: -1, hour: 23, minute: 30)),
		entry(5, "Point-Free Episode", "https://pointfree.co/episodes/ep300", date(day: -1, hour: 8)),
		entry(6, "Old news", "https://news.example.org/", date(day: -5, hour: 7)),
	]

	/// The feature, also recording each removal it sends up.
	internal static func recording(_ deleted: LockIsolated<[BrowsingHistoryRemoval]>) -> some ReducerOf<HistoryFeature> {
		CombineReducers {
			HistoryFeature()
			Reduce<HistoryFeature.State, HistoryFeature.Action> { _, action in
				if case let .delegate(.remove(_, removal)) = action { deleted.withValue { $0.append(removal) } }
				return .none
			}
		}
	}

	internal static func state(query: String = "") -> HistoryFeature.State {
		.init(profileID: profileID, entries: entries, query: query)
	}

	private static func entry(
		_ id: Int,
		_ title: String,
		_ url: String,
		_ date: Date
	) -> BrowsingHistoryEntry {
		.init(id: UUID(id), url: URL(string: url)!, title: title, lastVisited: date)
	}
}
