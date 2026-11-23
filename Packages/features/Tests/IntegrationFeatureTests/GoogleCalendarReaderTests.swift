import CustomDump
import Foundation
import Testing
import WebKit

@testable import AppFeature

/// DEV-804: the Live Calendar reader against hand-written pages shaped like Google Calendar's
/// day view. The script runs in a WebKit page here, in a world of its own like the developer
/// world, so its geometry is real layout. No real calendar data is involved.
@MainActor
@Suite(.timeLimit(.minutes(1)))
internal struct GoogleCalendarReaderTests {
	// MARK: - The script against fixtures

	@Test
	internal func aDayViewGivesTimesFromLayoutAndTitlesFromText() async throws {
		let value = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: Self.dayEvents, allDay: Self.allDayEvent))
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: value),
			.success(.init(events: [
				.init(title: "Team offsite"),
				.init(title: "Standup", start: 540, end: 570),
				.init(title: "Overlap left", start: 600, end: 660),
				.init(title: "Overlap right", start: 600, end: 660),
				.init(title: "Design review", start: 840, end: 915),
			]))
		)
	}

	@Test
	internal func aTwentyFourHourClockWithWordsAfterTheTimeStillReadsTheTitle() async throws {
		let column = Self.chip(id: "de", top: 672, height: 48, title: "Planung", time: "14:00–15:00 Uhr")
		let value = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: column))
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: value),
			.success(.init(events: [.init(title: "Planung", start: 840, end: 900)]))
		)
	}

	/// Titles without letters are titles too; a time with am or pm attached is still a time.
	@Test
	internal func titlesWithoutLettersAreKeptAndTimesAreSkipped() async throws {
		let column = [
			Self.chip(id: "one", top: 432, height: 24, title: "1:1", time: "9 – 9:30am"),
			Self.chip(id: "cake", top: 576, height: 48, title: "🎂", time: "12 – 1pm"),
			Self.chip(id: "late", top: 720, height: 48, title: "Retro", time: "3:00pm–4:00pm"),
		]
		.joined()
		let value = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: column))
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: value),
			.success(.init(events: [
				.init(title: "1:1", start: 540, end: 570),
				.init(title: "🎂", start: 720, end: 780),
				.init(title: "Retro", start: 900, end: 960),
			]))
		)
	}

	/// A time label is told apart by the event's own start, so localized labels with a word in
	/// them aren't titles, and a title with the hour in it still is.
	@Test
	internal func timeLabelsMatchTheEventsOwnStart() async throws {
		let column = [
			Self.chip(id: "one", top: 672, height: 48, title: "1:1", time: "14:00–15:00 Uhr"),
			Self.chip(id: "sprint", top: 432, height: 48, title: "Sprint 9 review", time: "9 – 10am"),
		]
		.joined()
		let value = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: column))
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: value),
			.success(.init(events: [
				.init(title: "Sprint 9 review", start: 540, end: 600),
				.init(title: "1:1", start: 840, end: 900),
			]))
		)
	}

	/// What follows the title and time (a place, a person) is never the title, even when the
	/// title looks like a time.
	@Test
	internal func metadataAfterTheTimeIsNeverTheTitle() async throws {
		let column = [
			Self.chip(id: "one", top: 624, height: 48, title: "1:1", time: "1 – 2pm", extra: "Meeting room"),
			Self.chip(id: "first", top: 432, height: 48, title: nil, time: "9 – 10am", extra: "Standup"),
		]
		.joined()
		let value = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: column))
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: value),
			.success(.init(events: [
				.init(title: "Standup", start: 540, end: 600),
				.init(title: "1:1", start: 780, end: 840),
			]))
		)
	}

	/// A time first, then a title that looks like a time, still finds the title; two time labels
	/// in a row can't be told apart, so the read fails rather than show a time as a title.
	@Test
	internal func timeFirstChipsFindTheirTitleOrFail() async throws {
		let timeFirst = Self.chip(id: "a", top: 624, height: 48, title: nil, time: "1 – 2pm", extra: "1:1")
		let read = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: timeFirst))
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: read),
			.success(.init(events: [.init(title: "1:1", start: 780, end: 840)]))
		)

		// Same hour at both ends: the end's minute tells the label from the title.
		let sameHour = Self.chip(id: "d", top: 624, height: 24, title: "1:1", time: "1 – 1:30pm")
		let sameHourRead = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: sameHour))
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: sameHourRead),
			.success(.init(events: [.init(title: "1:1", start: 780, end: 810)]))
		)

		// Localized labels before the title are times too.
		let localized = [
			Self.chip(id: "ja", top: 432, height: 48, title: nil, time: "午前9時～午前10時", extra: "朝会"),
			Self.chip(id: "ko", top: 528, height: 48, title: nil, time: "오전 11시~오후 12시", extra: "회의"),
		]
		.joined()
		let localizedRead = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: localized))
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: localizedRead),
			.success(.init(events: [
				.init(title: "朝会", start: 540, end: 600),
				.init(title: "회의", start: 660, end: 720),
			]))
		)

		// Digits in another script are digits too.
		let arabic = Self.chip(id: "ar", top: 432, height: 48, title: nil, time: "٩:٠٠–١٠:٠٠", extra: "اجتماع")
		let arabicRead = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: arabic))
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: arabicRead),
			.success(.init(events: [.init(title: "اجتماع", start: 540, end: 600)]))
		)

		// A start alone isn't a range: "10:30am" is the time, "Standup" the title.
		let startOnly = Self.chip(id: "c", top: 504, height: 24, title: nil, time: "10:30am", extra: "Standup")
		let started = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: startOnly))
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: started),
			.success(.init(events: [.init(title: "Standup", start: 630, end: 660)]))
		)

		let ambiguous = Self.chip(id: "b", top: 432, height: 48, title: "9am", time: "9 – 10am")
		let failed = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: ambiguous))
		expectNoDifference(GoogleCalendarReader.day(fromScriptValue: failed), .failure(.untitledEvent))
	}

	@Test
	internal func aLoneLocalizedTimeIsNoTitle() async throws {
		let column = Self.chip(id: "untitled", top: 672, height: 48, title: nil, time: "14:00–15:00 Uhr")
		let value = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: column))
		expectNoDifference(GoogleCalendarReader.day(fromScriptValue: value), .failure(.untitledEvent))
	}

	/// While the page says it's loading, nothing is read: the caller reads again.
	@Test
	internal func aBusyPageIsStillLoading() async throws {
		let page = Self.page(column: Self.dayEvents).replacingOccurrences(of: #"<div role="main">"#, with: #"<div role="main" aria-busy="true">"#)
		let value = try await Self.run(GoogleCalendarReader.script, on: page)
		expectNoDifference(GoogleCalendarReader.day(fromScriptValue: value), .failure(.stillLoading))
	}

	@Test
	internal func anEmptyDayIsADayWithNoEvents() async throws {
		let value = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: ""))
		expectNoDifference(GoogleCalendarReader.day(fromScriptValue: value), .success(.init(events: [])))
	}

	/// Events that lost their hooks must not read as an empty day.
	@Test
	internal func eventsWithoutTheirHooksFail() async throws {
		let column = """
		<div style="position:absolute; top:432px; height:24px; left:0; right:0">
			<div role="button" aria-label="9am to 9:30am, Standup"><div aria-hidden="true"><span>Standup</span></div></div>
		</div>
		"""
		let value = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: column))
		expectNoDifference(GoogleCalendarReader.day(fromScriptValue: value), .failure(.unhookedEvents))
	}

	/// All-day events that lost their hooks mustn't read as a day without them.
	@Test
	internal func allDayEventsWithoutTheirHooksFail() async throws {
		let allDay = #"<div role="button" aria-label="Team offsite, All day"><div aria-hidden="true"><span>Team offsite</span></div></div>"#
		let value = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: "", allDay: allDay))
		expectNoDifference(GoogleCalendarReader.day(fromScriptValue: value), .failure(.unhookedEvents))
	}

	@Test
	internal func aPageWithoutTheGridFails() async throws {
		let value = try await Self.run(GoogleCalendarReader.script, on: "<html><body><div>Loading…</div></body></html>")
		expectNoDifference(GoogleCalendarReader.day(fromScriptValue: value), .failure(.noGrid))
	}

	@Test
	internal func aGridWithoutDayCellsFails() async throws {
		let value = try await Self.run(GoogleCalendarReader.script, on: #"<div role="grid"><div role="gridcell">1</div></div>"#)
		expectNoDifference(GoogleCalendarReader.day(fromScriptValue: value), .failure(.noDayColumn))
	}

	@Test
	internal func aWeekViewIsNotReadAsADay() async throws {
		let columns = (0..<7).map { index in
			#"<div role="gridcell" data-datekey="\#(index)" style="position:relative; display:inline-block; width:100px; height:1152px"></div>"#
		}
		.joined()
		let value = try await Self.run(GoogleCalendarReader.script, on: #"<div role="main"><div role="grid">\#(columns)</div></div>"#)
		expectNoDifference(GoogleCalendarReader.day(fromScriptValue: value), .failure(.notDayView))
	}

	@Test
	internal func aShortColumnIsNotTheDay() async throws {
		let value = try await Self.run(
			GoogleCalendarReader.script,
			on: #"<div role="grid"><div role="gridcell" data-datekey="1" style="height:200px"></div></div>"#
		)
		expectNoDifference(GoogleCalendarReader.day(fromScriptValue: value), .failure(.noTimedColumn))
	}

	@Test
	internal func anEventPastTheEndOfTheDayFails() async throws {
		let column = Self.chip(id: "late", top: 1140, height: 48, title: "Late", time: "11:45pm")
		let value = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: column))
		expectNoDifference(GoogleCalendarReader.day(fromScriptValue: value), .failure(.eventOutsideDay))
	}

	@Test
	internal func anEventWithOnlyATimeFails() async throws {
		let column = Self.chip(id: "untitled", top: 432, height: 24, title: nil, time: "9 – 9:30")
		let value = try await Self.run(GoogleCalendarReader.script, on: Self.page(column: column))
		expectNoDifference(GoogleCalendarReader.day(fromScriptValue: value), .failure(.untitledEvent))
	}

	/// The probe is for checking a real calendar by hand: counts and the view's path, no text.
	@Test
	internal func theProbeCountsHooksAndReportsNoEventText() async throws {
		let value = try await Self.run(GoogleCalendarReader.probeScript, on: Self.page(column: Self.dayEvents, allDay: Self.allDayEvent))
		let report = try #require(GoogleCalendarReader.probeReport(fromScriptValue: value))
		for text in ["Standup", "Overlap", "Design review", "Team offsite", "9:30", "am"] {
			#expect(!report.contains(text), "the probe report leaked \(text)")
		}
		#expect(report.contains("eventIDs=5"))
		#expect(report.contains("eventChips=4"))
		#expect(report.contains("events=5"))
		#expect(report.contains("eventsInTallestCell=4"))
		#expect(report.contains("unhookedButtonsInTallestCell=0"))
		#expect(report.contains("dayCells=2"))
		#expect(report.contains("view=/calendar/u/0/r/day"))
	}

	// MARK: - Checking what the page returned

	@Test
	internal func anotherVersionsResultIsRefused() {
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: #"{"version":2,"status":"ok","events":[]}"#),
			.failure(.wrongVersion)
		)
	}

	@Test
	internal func unknownReasonsAndShapesAreUnreadable() {
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: #"{"version":1,"status":"failed","reason":"somethingNew"}"#),
			.failure(.unreadable)
		)
		expectNoDifference(GoogleCalendarReader.day(fromScriptValue: "null"), .failure(.unreadable))
		expectNoDifference(GoogleCalendarReader.day(fromScriptValue: "not json"), .failure(.unreadable))
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: #"{"version":1,"status":"ok","events":[{"title":"All day","allDay":true,"start":0}]}"#),
			.failure(.unreadable)
		)
	}

	@Test
	internal func impossibleTimesAreRefusedNotRounded() {
		for event in [
			#"{"title":"A","start":-5,"end":30,"allDay":false}"#,
			#"{"title":"A","start":600,"end":1500,"allDay":false}"#,
			#"{"title":"A","start":600,"end":600,"allDay":false}"#,
			#"{"title":"A","start":600.5,"end":660,"allDay":false}"#,
			#"{"title":"A","start":600,"allDay":false}"#,
		] {
			expectNoDifference(
				GoogleCalendarReader.day(fromScriptValue: #"{"version":1,"status":"ok","events":[\#(event)]}"#),
				.failure(.eventOutsideDay)
			)
		}
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: #"{"version":1,"status":"ok","events":[{"title":"  ","start":0,"end":30,"allDay":false}]}"#),
			.failure(.untitledEvent)
		)
	}

	@Test
	internal func tooManyEventsAreRefused() {
		let events = Array(repeating: #"{"title":"A","allDay":true}"#, count: GoogleCalendarReader.maximumEvents + 1)
		expectNoDifference(
			GoogleCalendarReader.day(fromScriptValue: #"{"version":1,"status":"ok","events":[\#(events.joined(separator: ","))]}"#),
			.failure(.tooManyEvents)
		)
	}

	// MARK: - Addresses

	@Test
	internal func onlyTheAccountsDayViewOfTodayIsReadInPlace() throws {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = try #require(TimeZone(identifier: "Europe/Warsaw"))
		let today = try #require(calendar.date(from: .init(year: 2026, month: 11, day: 15, hour: 13)))

		for (address, expected) in [
			// A bare day view may still be yesterday's.
			("https://calendar.google.com/calendar/u/0/r/day", false),
			("https://calendar.google.com/calendar/u/0/r/day/2026/11/15", true),
			("https://calendar.google.com/calendar/u/0/r/day/2026/11/14", false),
			("https://calendar.google.com/calendar/u/0/r/week", false),
			("https://calendar.google.com/calendar/u/1/r/day", false),
			("https://calendar.google.com/calendar/r", false),
			("http://calendar.google.com/calendar/u/0/r/day", false),
			("https://calendar.example.com/calendar/u/0/r/day", false),
		] {
			let url = try #require(URL(string: address))
			#expect(GoogleCalendarReader.showsDay(url, account: 0, day: today, calendar: calendar) == expected, "\(address)")
		}
		expectNoDifference(
			GoogleCalendarReader.dayURL(account: 2, day: today, calendar: calendar).absoluteString,
			"https://calendar.google.com/calendar/u/2/r/day/2026/11/15"
		)
		expectNoDifference(
			GoogleCalendarReader.newEventURL(account: 1).absoluteString,
			"https://calendar.google.com/calendar/u/1/r/eventedit"
		)
	}

	/// Google's addresses are Gregorian whatever calendar the Mac uses.
	@Test
	internal func addressesUseGregorianDatesOnAnyCalendar() throws {
		var buddhist = Calendar(identifier: .buddhist)
		buddhist.timeZone = try #require(TimeZone(identifier: "Asia/Bangkok"))
		let today = try #require(buddhist.date(from: .init(year: 2569, month: 11, day: 15, hour: 9)))

		expectNoDifference(
			GoogleCalendarReader.dayURL(account: 0, day: today, calendar: buddhist).absoluteString,
			"https://calendar.google.com/calendar/u/0/r/day/2026/11/15"
		)
		#expect(GoogleCalendarReader.showsDay(
			try #require(URL(string: "https://calendar.google.com/calendar/u/0/r/day/2026/11/15")),
			account: 0,
			day: today,
			calendar: buddhist
		))
	}

	// MARK: - Fixtures

	/// A column 1,152 points tall: 48 points an hour, as Google Calendar draws it.
	private static func page(
		column: String,
		allDay: String = ""
	) -> String {
		"""
		<html><body style="margin:0">
		<div role="main">
			<div role="grid" aria-label="A day">
				<div role="row"><div role="columnheader">DAY</div></div>
				<div role="row"><div role="gridcell" data-datekey="100" style="position:relative; height:40px">\(allDay)</div></div>
				<div style="height:300px; overflow-y:scroll">
					<div role="row">
						<div role="gridcell" data-datekey="100" style="position:relative; height:1152px">\(column)</div>
					</div>
				</div>
			</div>
		</div>
		</body></html>
		"""
	}

	private static func chip(
		id: String,
		top: Int,
		height: Int,
		left: Int = 0,
		width: Int = 300,
		title: String?,
		time: String,
		extra: String? = nil
	) -> String {
		"""
		<div data-eventid="\(id)" style="position:absolute; top:\(top)px; height:\(height)px; left:\(left)px; width:\(width)px">
			<div role="button" data-eventchip="" aria-label="\(time), \(title ?? "")">
				<div aria-hidden="true">\(title.map { "<span>\($0)</span>" } ?? "")<span>\(time)</span>\(extra.map { "<span>\($0)</span>" } ?? "")</div>
			</div>
		</div>
		"""
	}

	private static var dayEvents: String {
		[
			chip(id: "a", top: 432, height: 24, title: "Standup", time: "9 – 9:30am"),
			chip(id: "b", top: 480, height: 48, width: 150, title: "Overlap left", time: "10 – 11am"),
			chip(id: "c", top: 480, height: 48, left: 150, width: 150, title: "Overlap right", time: "10 – 11am"),
			chip(id: "d", top: 672, height: 60, title: "Design review", time: "2 – 3:15pm"),
		]
		.joined()
	}

	private static var allDayEvent: String {
		#"<div role="button" data-eventid="all" aria-label="Team offsite, All day"><div aria-hidden="true"><span>Team offsite</span></div></div>"#
	}

	/// Runs a reader script the way the engine does: as an async function body in a world of its
	/// own, returning its value as JSON.
	private static func run(
		_ script: String,
		on html: String
	) async throws -> String {
		let webView = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600))
		let loader = PageLoader()
		webView.navigationDelegate = loader
		webView.loadHTMLString(html, baseURL: URL(string: "https://calendar.google.com/calendar/u/0/r/day/2026/11/15"))
		try await loader.finished()
		let value = try await webView.callAsyncJavaScript(
			"return JSON.stringify(await (async () => {\n\(script)\n})());",
			contentWorld: .defaultClient
		)
		return try #require(value as? String)
	}

	@MainActor
	private final class PageLoader: NSObject, WKNavigationDelegate {
		private var continuation: CheckedContinuation<Void, any Error>?
		private var result: Result<Void, any Error>?

		internal func finished() async throws {
			if let result { return try result.get() }
			try await withCheckedThrowingContinuation { self.continuation = $0 }
		}

		internal func webView(
			_ webView: WKWebView,
			didFinish navigation: WKNavigation!
		) {
			complete(.success(()))
		}

		internal func webView(
			_ webView: WKWebView,
			didFail navigation: WKNavigation!,
			withError error: any Error
		) {
			complete(.failure(error))
		}

		private func complete(_ result: Result<Void, any Error>) {
			guard self.result == nil else { return }
			self.result = result
			continuation?.resume(with: result)
			continuation = nil
		}
	}
}
