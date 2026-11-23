@testable import AppFeature
import AppUI
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-804: which favorites get Live Calendar, and how its day is read and kept. The page is a
/// stand-in here; `GoogleCalendarReaderTests` runs the reader against real layout. Each read
/// gets its own previews on a clock that doesn't wait, so how long a day takes to settle is
/// counted in polls, not in however long a busy machine takes to run them.
extension IntegrationFeatureTests {
	@Test
	internal func googleCalendarAddressesNameTheirAccount() {
		func site(_ string: String) -> SidebarPreviewSite? { SidebarPreviewSite(url: URL(string: string)!) }
		expectNoDifference(site("https://calendar.google.com/calendar/u/0/r"), .googleCalendar(account: 0))
		expectNoDifference(site("https://calendar.google.com/calendar/u/3/r/week/2026/11/15"), .googleCalendar(account: 3))
		expectNoDifference(site("https://calendar.google.com/calendar/r"), .googleCalendar(account: 0))
		expectNoDifference(site("https://calendar.google.com/settings"), nil)
		expectNoDifference(site("http://calendar.google.com/calendar/u/0/r"), nil)
	}

	@Test
	internal func onlyAFavoriteCalendarWithTheFlagAndOptionOnGetsLiveCalendar() {
		var organization = fixture()
		organization.tabs[0].restoration = .init(title: "Calendar", url: URL(string: "https://calendar.google.com/calendar/u/1/r/week")!)
		organization.profiles[0].favorites = [organization.tabs[0].id]
		let calendar = organization.tabs[0].id.rawValue
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let sources = HoverPreviewSources()

		// Without the feature flag, the favorite keeps its ordinary card.
		#expect(state.sidebarSiteSource(in: state.main.id, tabID: calendar, sources: sources) == nil)
		expectNoDifference(
			state.sidebarSiteSource(in: state.main.id, tabID: calendar, sources: sources, liveCalendar: true),
			.calendar(account: 1)
		)

		// The option, and Disable Live Calendar on this favorite's card, each turn it off.
		#expect(state.sidebarSiteSource(in: state.main.id, tabID: calendar, sources: .init(calendars: false), liveCalendar: true) == nil)
		#expect(state.sidebarSiteSource(
			in: state.main.id,
			tabID: calendar,
			sources: .init(disabledCalendars: [calendar]),
			liveCalendar: true
		) == nil)

		// Disabling another favorite leaves this one on.
		expectNoDifference(
			state.sidebarSiteSource(in: state.main.id, tabID: calendar, sources: .init(disabledCalendars: [UUID()]), liveCalendar: true),
			.calendar(account: 1)
		)

		// A calendar tab that isn't a favorite gets nothing.
		state.workspace.profiles[0].favorites = []
		#expect(state.sidebarSiteSource(in: state.main.id, tabID: calendar, sources: sources, liveCalendar: true) == nil)
	}

	@Test
	internal func privateWindowsGetNoLiveCalendar() {
		var organization = fixture()
		organization.tabs[0].restoration = .init(title: "Calendar", url: URL(string: "https://calendar.google.com/calendar/u/0/r")!)
		organization.profiles[0].favorites = [organization.tabs[0].id]
		let state = AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: true
		))
		#expect(state.sidebarSiteSource(
			in: state.main.id,
			tabID: organization.tabs[0].id.rawValue,
			sources: .init(),
			liveCalendar: true
		) == nil)
	}

	/// The favorite's own page, on screen showing today's day view, is read in place and the day
	/// is kept for five minutes; Refresh reads it again.
	@Test
	internal func aFavoriteShowingTodayIsReadInPlaceAndKept() async throws {
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(401)),
			profileID: .init(rawValue: UUID(402)),
			restoration: .init(title: "Calendar", url: GoogleCalendarReader.dayURL(account: 0, day: .now))
		)
		var reads = 0
		var opened: [BrowserCore.Tab] = []
		let clients = SidebarPreviewClients(
			snapshot: { id in
				id == tab.id
				? .init(navigation: .init(url: tab.restoration.url), revision: 1, isVisibleForCapture: true)
				: nil
			},
			readScript: { id, script in
				#expect(id == tab.id)
				#expect(script == GoogleCalendarReader.script)
				reads += 1
				return #"{"version":1,"status":"ok","events":[{"title":"Standup","start":540,"end":570,"allDay":false}]}"#
			},
			openPage: { opened.append($0) }
		)
		let now = Date()
		let previews = SidebarCalendarPreviews(clock: NoWaitClock())

		let day = await previews.day(for: tab, account: 0, refresh: false, clients: clients, now: now)
		expectNoDifference(day.status, .loaded([.init(id: 0, title: "Standup", start: 540, end: 570)]))
		#expect(day.fetchedAt != nil)
		// Reads a second apart agreed before the day counted.
		let firstReads = reads
		#expect(firstReads >= 2)
		_ = await previews.day(for: tab, account: 0, refresh: false, clients: clients, now: now.addingTimeInterval(60))
		#expect(reads == firstReads)
		_ = await previews.day(for: tab, account: 0, refresh: true, clients: clients, now: now.addingTimeInterval(61))
		#expect(reads > firstReads)
		#expect(opened.isEmpty)
	}

	/// A favorite that isn't on screen showing today is read from a page of its own, opened in its
	/// profile at today's day view, muted, and closed again; its own page is never read.
	@Test
	internal func aFavoriteNotShowingTodayIsReadFromAPageOfItsOwnThatCloses() async throws {
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(411)),
			profileID: .init(rawValue: UUID(412)),
			restoration: .init(title: "Calendar", url: URL(string: "https://calendar.google.com/calendar/u/2/r/week")!)
		)
		var opened: [BrowserCore.Tab] = []
		var muted: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		var reads = 0
		let clients = SidebarPreviewClients(
			snapshot: { id in
				if id == tab.id {
					// Loaded but in the background, on its week view.
					return .init(navigation: .init(url: tab.restoration.url), revision: 1)
				}
				guard let page = opened.first(where: { $0.id == id }), !closed.contains(id) else { return nil }
				return .init(navigation: .init(url: page.restoration.url), revision: 1)
			},
			readScript: { id, _ in
				#expect(id != tab.id)
				reads += 1

				// The app draws its grid after the page loads.
				return reads == 1
				? #"{"version":1,"status":"failed","reason":"noGrid"}"#
				: #"{"version":1,"status":"ok","events":[{"title":"Offsite","allDay":true}]}"#
			},
			openPage: { opened.append($0) },
			mutePage: { muted.append($0) },
			closePage: { closed.append($0) }
		)

		let now = Date()
		let day = await SidebarCalendarPreviews(clock: NoWaitClock()).day(for: tab, account: 2, refresh: true, clients: clients, now: now)
		expectNoDifference(day.status, .loaded([.init(id: 0, title: "Offsite")]))
		let page = try #require(opened.first)
		#expect(opened.count == 1)
		#expect(page.id != tab.id)
		#expect(page.profileID == tab.profileID)
		expectNoDifference(page.restoration.url, GoogleCalendarReader.dayURL(account: 2, day: now))
		expectNoDifference(muted, [page.id])
		expectNoDifference(closed, [page.id])
		#expect(reads >= 3)
	}

	/// A read that spans a navigation is dropped: what it saw may be another day's page.
	@Test
	internal func aReadAcrossANavigationIsDropped() async throws {
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(461)),
			profileID: .init(rawValue: UUID(462)),
			restoration: .init(title: "Calendar", url: GoogleCalendarReader.dayURL(account: 0, day: .now))
		)
		var document: UInt64 = 1
		var reads = 0
		let clients = SidebarPreviewClients(
			snapshot: { _ in
				.init(navigation: .init(url: tab.restoration.url), revision: 1, documentRevision: document, isVisibleForCapture: true)
			},
			readScript: { _, _ in
				reads += 1
				if reads == 1 {
					// The page moves on while this read runs.
					document += 1
					return #"{"version":1,"status":"ok","events":[{"title":"Yesterday","allDay":true}]}"#
				}
				return #"{"version":1,"status":"ok","events":[{"title":"Today","allDay":true}]}"#
			}
		)
		let day = await SidebarCalendarPreviews(clock: NoWaitClock()).day(for: tab, account: 0, refresh: true, clients: clients)
		expectNoDifference(day.status, .loaded([.init(id: 0, title: "Today")]))
	}

	/// A page that just opened is blank until its navigation is reported: that's waiting, not a
	/// signed-out calendar.
	@Test
	internal func aNewPageStartsBlankAndIsWaitedFor() async throws {
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(481)),
			profileID: .init(rawValue: UUID(482)),
			restoration: .init(title: "Calendar", url: URL(string: "https://calendar.google.com/calendar/u/0/r/week")!)
		)
		var opened: [BrowserCore.Tab] = []
		var looks = 0
		let clients = SidebarPreviewClients(
			snapshot: { id in
				guard let page = opened.first(where: { $0.id == id }) else { return nil }
				looks += 1
				return .init(navigation: .init(url: looks <= 2 ? URL(string: "about:blank") : page.restoration.url), revision: 1)
			},
			readScript: { _, _ in #"{"version":1,"status":"ok","events":[{"title":"Standup","allDay":true}]}"# },
			openPage: { opened.append($0) }
		)
		let day = await SidebarCalendarPreviews(clock: NoWaitClock()).day(for: tab, account: 0, refresh: true, clients: clients)
		expectNoDifference(day.status, .loaded([.init(id: 0, title: "Standup")]))
	}

	/// A reload starts the settling again: the new page's empty grid isn't the old one's day.
	@Test
	internal func aReloadStartsSettlingAgain() async throws {
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(471)),
			profileID: .init(rawValue: UUID(472)),
			restoration: .init(title: "Calendar", url: GoogleCalendarReader.dayURL(account: 0, day: .now))
		)
		var snapshots = 0
		var reads = 0
		let clients = SidebarPreviewClients(
			snapshot: { _ in
				snapshots += 1

				// Each read looks twice; the page reloads after the third read.
				return .init(
					navigation: .init(url: tab.restoration.url),
					revision: 1,
					documentRevision: snapshots <= 6 ? 1 : 2,
					isVisibleForCapture: true
				)
			},
			readScript: { _, _ in
				reads += 1
				return reads <= 4
				? #"{"version":1,"status":"ok","events":[]}"#
				: #"{"version":1,"status":"ok","events":[{"title":"Standup","start":540,"end":570,"allDay":false}]}"#
			}
		)
		let day = await SidebarCalendarPreviews(clock: NoWaitClock()).day(for: tab, account: 0, refresh: true, clients: clients)
		expectNoDifference(day.status, .loaded([.init(id: 0, title: "Standup", start: 540, end: 570)]))
	}

	/// Calendar draws its grid before its events arrive: an empty day that fills in isn't taken
	/// as the day.
	@Test
	internal func aDayIsTakenOnlyOnceItSettles() async throws {
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(451)),
			profileID: .init(rawValue: UUID(452)),
			restoration: .init(title: "Calendar", url: GoogleCalendarReader.dayURL(account: 0, day: .now))
		)
		var reads = 0
		let clients = SidebarPreviewClients(
			snapshot: { _ in .init(navigation: .init(url: tab.restoration.url), revision: 1, isVisibleForCapture: true) },
			readScript: { _, _ in
				reads += 1
				return reads <= 2
				? #"{"version":1,"status":"ok","events":[]}"#
				: #"{"version":1,"status":"ok","events":[{"title":"Standup","start":540,"end":570,"allDay":false}]}"#
			}
		)
		let day = await SidebarCalendarPreviews(clock: NoWaitClock()).day(for: tab, account: 0, refresh: true, clients: clients)
		expectNoDifference(day.status, .loaded([.init(id: 0, title: "Standup", start: 540, end: 570)]))
	}

	/// A page that doesn't look as expected shows the failure, never guessed times.
	@Test
	internal func aReadThatFailsShowsTheFailure() async throws {
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(421)),
			profileID: .init(rawValue: UUID(422)),
			restoration: .init(title: "Calendar", url: GoogleCalendarReader.dayURL(account: 0, day: .now))
		)
		let clients = SidebarPreviewClients(
			snapshot: { _ in .init(navigation: .init(url: tab.restoration.url), revision: 1, isVisibleForCapture: true) },
			readScript: { _, _ in #"{"version":1,"status":"failed","reason":"unhookedEvents"}"# }
		)
		let day = await SidebarCalendarPreviews(clock: NoWaitClock()).day(for: tab, account: 0, refresh: true, clients: clients)
		expectNoDifference(day.status, .failed)
		#expect(day.fetchedAt != nil)
	}

	/// Signed out, Google sends the page to its sign-in: that's a failure, not an empty day.
	@Test
	internal func aSignedOutCalendarFails() async throws {
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(431)),
			profileID: .init(rawValue: UUID(432)),
			restoration: .init(title: "Calendar", url: URL(string: "https://calendar.google.com/calendar/u/0/r")!)
		)
		var opened: [BrowserCore.Tab.ID] = []
		var reads = 0
		let clients = SidebarPreviewClients(
			snapshot: { id in
				opened.contains(id)
				? .init(navigation: .init(url: URL(string: "https://accounts.google.com/ServiceLogin")), revision: 1)
				: nil
			},
			readScript: { _, _ in
				reads += 1
				return nil
			},
			openPage: { opened.append($0.id) }
		)
		let day = await SidebarCalendarPreviews(clock: NoWaitClock()).day(for: tab, account: 0, refresh: true, clients: clients)
		expectNoDifference(day.status, .failed)
		#expect(reads == 0)
	}

	@Test
	internal func theProbeReportsCountsAndTheReadersVerdictWithoutText() async throws {
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(441)),
			profileID: .init(rawValue: UUID(442)),
			restoration: .init(title: "Calendar", url: GoogleCalendarReader.dayURL(account: 0, day: .now))
		)
		let clients = SidebarPreviewClients(
			snapshot: { _ in .init(navigation: .init(url: tab.restoration.url), revision: 1, isVisibleForCapture: true) },
			readScript: { _, script in
				script == GoogleCalendarReader.probeScript
				? #"{"probe":1,"view":"/calendar/u/0/r/day","eventIDs":3,"dayCellHeights":[40,1152]}"#
				: #"{"version":1,"status":"ok","events":[{"title":"Secret meeting","start":600,"end":660,"allDay":false}]}"#
			}
		)
		let report = try #require(await SidebarCalendarPreviews(clock: NoWaitClock()).probe(for: tab, account: 0, clients: clients))
		expectNoDifference(
			report,
			"Live Calendar probe v1 source=favorite dayCellHeights=40,1152 eventIDs=3 probe=1 view=/calendar/u/0/r/day reader=ok timed=1 allDay=0"
		)
		#expect(!report.contains("Secret"))
		#expect(!report.contains("600"))
	}
}
