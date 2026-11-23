import AppUI
import BrowserCore
import Foundation

/// Live Calendar (DEV-804, behind `ARX_LIVE_CALENDAR`): today's day for Google Calendar
/// favorites, read by `GoogleCalendarReader` from Google Calendar's own page in the favorite's
/// profile, so it goes only to Google with that profile's cookies.
///
/// A read happens when a card asks, never on a timer, and is kept in memory (never on disk) for
/// `lifetime`. The favorite's own page is read only while it's on screen showing today's day
/// view; otherwise a page of its own opens off screen, muted, in the favorite's profile, and
/// closes after the read. Nothing shows it, stages it or wakes the favorite's frozen page
/// (DEV-941), and the profile's idle release applies once it closes (DEV-880). Event titles and
/// times are never logged.
@MainActor
internal final class SidebarCalendarPreviews {
	internal static let shared: SidebarCalendarPreviews = .init()

	/// A day read this recently is shown again without reading the page.
	internal static let lifetime: TimeInterval = 300

	/// How long a page opened for a read may take to load and draw its grid.
	internal static let loadTimeout: Duration = .seconds(20)

	/// How often a page still drawing its grid is read again.
	internal static let pollInterval: Duration = .milliseconds(400)

	/// A day counts once reads this far apart agree: Calendar draws its grid before its events
	/// arrive, so one read alone could be an empty or partial day.
	internal static let settleDuration: Duration = .seconds(1)

	internal typealias Read = Result<GoogleCalendarReader.Day, GoogleCalendarReader.Failure>

	private struct Entry {
		internal var account: Int

		/// The day it was read for, so yesterday's read is never shown today.
		internal var day: Date
		internal var fetchedAt: Date
		internal var read: Read
	}

	/// A read in progress, for one favorite's account on one day.
	private struct ReadKey: Hashable {
		internal var tab: BrowserCore.Tab.ID
		internal var account: Int
		internal var day: Date
	}

	/// Times the reading: how often a page is read again, how long a day takes to settle and when
	/// a read gives up.
	private let clock: any Clock<Duration>
	private var entries: [BrowserCore.Tab.ID: Entry]
	private var inFlight: [ReadKey: Task<Entry, Never>]

	/// Pages opened for a read open one at a time: each runs the whole calendar app.
	private var lastLoad: Task<Void, Never>?

	/// The app uses `shared`; a test makes its own, with a clock that doesn't wait.
	internal init(clock: any Clock<Duration> = ContinuousClock()) {
		self.clock = clock
		self.entries = [:]
		self.inFlight = [:]
		self.lastLoad = nil
	}

	/// Today's day for a calendar favorite: kept, or read now. With `refresh`, it's read again.
	internal func day(
		for tab: BrowserCore.Tab,
		account: Int,
		refresh: Bool,
		clients: SidebarPreviewClients,
		now: Date = .now,
		calendar: Calendar = .current
	) async -> SidebarCalendarDay {
		let today = calendar.startOfDay(for: now)
		if
			!refresh,
			let entry = entries[tab.id],
			entry.account == account,
			entry.day == today,
			now.timeIntervalSince(entry.fetchedAt) < Self.lifetime
		{ return Self.day(entry) }

		let key = ReadKey(tab: tab.id, account: account, day: today)
		let task: Task<Entry, Never>
		if let pending = inFlight[key] {
			task = pending
		} else {
			// Unstructured, so a card that goes away mid-read still leaves the result for the next.
			task = Task { @MainActor in
				let read = await self.read(tab: tab, account: account, now: now, clients: clients, calendar: calendar)
				return Entry(account: account, day: today, fetchedAt: .now, read: read)
			}
			inFlight[key] = task
		}
		let entry = await task.value
		if inFlight[key] == task { inFlight[key] = nil }
		entries[tab.id] = entry
		return Self.day(entry)
	}

	/// The structure-only probe for hand checks: hook counts and the reader's verdict, with no
	/// event titles or times. Nil when no calendar page could be reached.
	internal func probe(
		for tab: BrowserCore.Tab,
		account: Int,
		clients: SidebarPreviewClients,
		now: Date = .now,
		calendar: Calendar = .current
	) async -> String? {
		await withCalendarPage(tab: tab, account: account, now: now, clients: clients, calendar: calendar) { page, source in
			let read = await self.readUntilDrawn(
				page,
				account: account,
				now: now,
				calendar: calendar,
				clients: clients,
				clock: self.clock
			)
			guard
				let value = await clients.readScript(page, GoogleCalendarReader.probeScript),
				let counts = GoogleCalendarReader.probeReport(fromScriptValue: value)
			else { return nil }
			return "Live Calendar probe v\(GoogleCalendarReader.version) source=\(source) \(counts) \(Self.verdict(read))"
		} ?? nil
	}

	// MARK: - Reading

	private func read(
		tab: BrowserCore.Tab,
		account: Int,
		now: Date,
		clients: SidebarPreviewClients,
		calendar: Calendar
	) async -> Read {
		await withCalendarPage(tab: tab, account: account, now: now, clients: clients, calendar: calendar) { page, _ in
			await self.readUntilDrawn(
				page,
				account: account,
				now: now,
				calendar: calendar,
				clients: clients,
				clock: self.clock
			)
		} ?? .failure(.timedOut)
	}

	/// Runs `body` with a page showing today's day view for the account: the favorite's own when
	/// it's on screen showing it, otherwise a page of its own that loads off screen and closes after.
	/// Nil when no page could be opened.
	private func withCalendarPage<Value: Sendable>(
		tab: BrowserCore.Tab,
		account: Int,
		now: Date,
		clients: SidebarPreviewClients,
		calendar: Calendar,
		body: @escaping @MainActor (BrowserCore.Tab.ID, String) async -> Value
	) async -> Value? {
		if
			let snapshot = clients.snapshot(tab.id),
			snapshot.isVisibleForCapture,
			!snapshot.navigation.isLoading,
			let url = snapshot.navigation.url,
			GoogleCalendarReader.showsDay(url, account: account, day: now, calendar: calendar)
		{
			return await body(tab.id, "favorite")
		}

		let previous = lastLoad
		let load = Task { @MainActor () -> Value? in
			_ = await previous?.value
			let page = BrowserCore.Tab(
				id: .init(rawValue: UUID()),
				profileID: tab.profileID,
				restoration: .init(
					title: "",
					url: GoogleCalendarReader.dayURL(account: account, day: now, calendar: calendar)
				)
			)
			do {
				try await clients.openPage(page)
			} catch {
				clients.closePage(page.id)
				return nil
			}
			defer { clients.closePage(page.id) }
			clients.mutePage(page.id)
			return await body(page.id, "ownPage")
		}
		lastLoad = Task { _ = await load.value }
		return await load.value
	}

	/// Reads the page, again and again while it's still loading or drawing its grid, until reads
	/// `settleDuration` apart agree on the day, the reader fails for a reason waiting won't fix,
	/// or time runs out. A day that never settles is a failure, not the last partial read.
	///
	/// Every read must start and end on the same document showing today's day view for the
	/// account; a read across a navigation is dropped, and a page that stays elsewhere fails.
	private func readUntilDrawn<C: Clock<Duration>>(
		_ page: BrowserCore.Tab.ID,
		account: Int,
		now: Date,
		calendar: Calendar,
		clients: SidebarPreviewClients,
		clock: C
	) async -> Read {
		let showsToday = { (url: URL) in
			GoogleCalendarReader.showsDay(url, account: account, day: now, calendar: calendar)
		}
		let deadline = clock.now.advanced(by: Self.loadTimeout)

		// The day being confirmed, on the document it was read from: a reload starts it again.
		var settling: (day: GoogleCalendarReader.Day, document: UInt64?, since: C.Instant)?
		var isElsewhere = false
		while clock.now < deadline {
			if
				let snapshot = clients.snapshot(page),
				let url = snapshot.navigation.url,
				!snapshot.navigation.isLoading
			{
				let navigation = snapshot.navigation

				// A page that just opened starts blank before its navigation is reported.
				if url.scheme?.lowercased() == "about" {
					try? await clock.sleep(for: Self.pollInterval)
					continue
				}
				if navigation.errorCode != nil { return .failure(.unreadable) }

				// Signed out, Google sends the page to its sign-in instead.
				guard url.host()?.lowercased() == "calendar.google.com" else { return .failure(.noGrid) }
				isElsewhere = !showsToday(url)
				if
					!isElsewhere,
					let value = await clients.readScript(page, GoogleCalendarReader.script),
					let after = clients.snapshot(page),
					after.documentRevision == snapshot.documentRevision,
					let afterURL = after.navigation.url,
					showsToday(afterURL)
				{
					let read = GoogleCalendarReader.day(fromScriptValue: value)
					switch read {
					case let .success(day):
						if let settling, settling.day == day, settling.document == snapshot.documentRevision {
							if settling.since.duration(to: clock.now) >= Self.settleDuration { return read }
						} else {
							settling = (day, snapshot.documentRevision, clock.now)
						}

					// The app loads and draws its grid after the page loads.
					case .failure(.stillLoading), .failure(.noGrid), .failure(.noDayColumn), .failure(.noTimedColumn):
						settling = nil

					case .failure:
						return read
					}
				} else {
					// Another day or account, or a read across a navigation: nothing from it counts.
					settling = nil
				}
			} else {
				// Loading again: whatever was settling belonged to the page before.
				settling = nil
			}
			try? await clock.sleep(for: Self.pollInterval)
		}
		return .failure(isElsewhere ? .notDayView : .timedOut)
	}

	// MARK: - The card's day

	private static func day(_ entry: Entry) -> SidebarCalendarDay {
		switch entry.read {
		case let .success(day):
			.init(
				status: .loaded(day.events.enumerated().map { index, event in
					.init(id: index, title: event.title, start: event.start, end: event.end)
				}),
				fetchedAt: entry.fetchedAt
			)

		case .failure:
			.init(status: .failed, fetchedAt: entry.fetchedAt)
		}
	}

	/// The reader's outcome for the probe: counts and a reason, never titles or times.
	private static func verdict(_ read: Read) -> String {
		switch read {
		case let .success(day):
			"reader=ok timed=\(day.events.filter { !$0.isAllDay }.count) allDay=\(day.events.filter(\.isAllDay).count)"
		case let .failure(failure):
			"reader=failed reason=\(failure.rawValue)"
		}
	}
}
