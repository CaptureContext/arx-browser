import Foundation

/// Reads today from Google Calendar's day view (DEV-804, Live Calendar).
///
/// Everything that knows the page's shape is in this file: the read-only script that runs in the
/// calendar page's developer world, the structure-only probe, and the checks on what the script
/// returns. When Google changes the page, this is the one file to fix, and `version` goes up.
///
/// The script reads data attributes, ARIA roles and layout, never class names. Times come from
/// where each event sits in the 24-hour column, so they don't depend on the account's language
/// or clock; titles come from the event's visible text. Whenever the page doesn't look as
/// expected the read fails, and the card says so: it never guesses a time.
internal enum GoogleCalendarReader {
	internal static let version: Int = 1

	/// More than this and the page isn't the day view the reader expects.
	internal static let maximumEvents: Int = 60
	internal static let maximumTitleLength: Int = 300

	/// Why a read failed. None of these carries anything from the page but its shape.
	internal enum Failure: String, Error, Equatable, Sendable, CaseIterable {
		/// The page says it's still loading (`aria-busy` or a progress bar): read again.
		case stillLoading = "loading"

		/// No `role="grid"`: not the calendar grid, or not rendered yet.
		case noGrid

		/// No `role="gridcell"` with `data-datekey`.
		case noDayColumn

		/// No day cell tall enough to be a 24-hour column.
		case noTimedColumn

		/// More than one timed column: a week or multi-day view.
		case notDayView

		/// Buttons with labels in the column that carry no event hook: the hooks changed.
		case unhookedEvents

		/// An event's box doesn't fit inside the day.
		case eventOutsideDay

		/// An event with no readable title.
		case untitledEvent

		/// More events than a day view shows.
		case tooManyEvents

		/// The script didn't return, or returned something else entirely.
		case unreadable

		/// The script is from another version of this reader.
		case wrongVersion

		/// The page didn't finish loading in time.
		case timedOut
	}

	// MARK: - The script

	/// Runs as the body of an async function in the page's developer world and returns a plain
	/// object. It reads nothing outside the calendar grid and changes nothing.
	internal static let script: String = """
	const version = \(version);
	const fail = (reason) => ({ version, status: "failed", reason });
	const hook = "[data-eventid], [data-eventchip]";
	// Event boxes, outermost only: a hooked element inside another belongs to it.
	const chipsIn = (root) => Array.from(root.querySelectorAll(hook)).filter((element) => {
		const outer = element.parentElement && element.parentElement.closest(hook);
		return !outer || !root.contains(outer);
	});
	// A text is the event's time label when its numbers include the event's own start (hour in
	// either clock, and its minute unless it's on the hour), the end's hour too when it names a
	// range, and it has at most a short word besides am or pm: "9 – 9:30am", "14:00–15:00 Uhr".
	// "1:1" at 1 pm isn't one: it has two numbers and no 2. All-day events have no time label.
	// Digits in other scripts ("٩:٠٠–١٠:٠٠") read as ASCII ones; a digit from a script not listed
	// stays unreadable, so its text is never taken for a time.
	const zeros = [0x30, 0x660, 0x6f0, 0x966, 0x9e6, 0xa66, 0xae6, 0xbe6, 0xc66, 0xce6, 0xd66, 0xe50, 0xed0, 0xf20, 0x1040, 0x17e0, 0xff10];
	const ascii = (text) => text.replace(/\\p{Nd}/gu, (digit) => {
		const code = digit.codePointAt(0);
		const zero = zeros.find((value) => code >= value && code <= value + 9);
		return zero === undefined ? "?" : String(code - zero);
	});
	const isTime = (label, start, end) => {
		if (start === null) return false;
		const text = ascii(label);
		const numbers = (text.match(/\\d+/g) || []).map(Number);
		const shows = (minutes) => {
			const hour = Math.floor(minutes / 60) % 24;
			return numbers.includes(hour) || numbers.includes(hour % 12 || 12);
		};
		const minute = start % 60;
		const minuteShown = minute === 0 || numbers.includes(minute);
		// What's left once the start's and end's minutes are taken out are hours: two or more
		// make a range, and then the end's hour must be one of them ("10:30am" is no range).
		const hours = numbers.slice();
		for (const value of [start % 60, end % 60]) {
			const index = hours.indexOf(value);
			if (index >= 0) hours.splice(index, 1);
		}
		// A range shows its end: the hour, and the minute unless it's on the hour, so "1:1" is no
		// label for 1:00–1:30 ("1 – 1:30pm" is).
		const endShown = hours.length < 2 || (shows(end) && (end % 60 === 0 || numbers.includes(end % 60)));
		// Words that only mark a time don't count: am and pm, and their equivalents in other
		// languages ("午前9時～午前10時", "오전 9시", "9 h", "14 Uhr").
		const letters = text
			.replace(/[ap]\\.?\\s?m\\.?/gi, "")
			.replace(/午前|午後|上午|下午|中午|早上|晚上|凌晨|時|分|点|點|오전|오후|시|분/g, "")
			.replace(/(?<!\\p{L})(?:uhr|h)(?!\\p{L})/giu, "")
			.replace(/[^\\p{L}]/gu, "").length;
		return shows(start) && minuteShown && endShown && letters <= 3;
	};
	// The title is the event's first visible text, unless that is its time label and the next
	// text isn't: then the time came first and the next text is the title. Whatever follows (a
	// place, a person) never is. A lone time label, or two in a row, can't be told from a title,
	// so there's no title and the read fails.
	const titleOf = (chip, start, end) => {
		const source = chip.querySelector('[aria-hidden="true"]') || chip;
		const walker = document.createTreeWalker(source, NodeFilter.SHOW_TEXT);
		const texts = [];
		while (walker.nextNode()) {
			const text = (walker.currentNode.nodeValue || "").trim();
			if (text) texts.push(text);
		}
		const title = texts.length === 0 ? null
			: !isTime(texts[0], start, end) ? texts[0]
			: texts.length === 1 || isTime(texts[1], start, end) ? null
			: texts[1];
		return title ? title.slice(0, \(maximumTitleLength)) : null;
	};
	if (document.querySelector('[role="main"][aria-busy="true"], [role="main"] [aria-busy="true"], [role="progressbar"]:not([aria-hidden="true"])')) return fail("loading");
	if (!document.querySelector('[role="grid"]')) return fail("noGrid");
	const cells = Array.from(document.querySelectorAll('[role="gridcell"][data-datekey]'))
		.map((cell) => ({ cell, rect: cell.getBoundingClientRect() }))
		.sort((a, b) => b.rect.height - a.rect.height);
	if (cells.length === 0) return fail("noDayColumn");
	const column = cells[0];
	if (!(column.rect.height >= 24 * 20)) return fail("noTimedColumn");
	if (cells.filter((entry) => entry.rect.height >= column.rect.height * 0.9).length !== 1) return fail("notDayView");
	// In any day cell, timed or all-day: events that lost their hooks mustn't read as no events.
	const unhooked = cells.flatMap((entry) => Array.from(entry.cell.querySelectorAll('[role="button"][aria-label]')))
		.filter((element) => !element.closest(hook));
	if (unhooked.length > 0) return fail("unhookedEvents");
	const minutesPerPixel = 1440 / column.rect.height;
	const events = [];
	for (const chip of chipsIn(column.cell)) {
		const rect = chip.getBoundingClientRect();
		const start = Math.round((rect.top - column.rect.top) * minutesPerPixel);
		const end = Math.round((rect.bottom - column.rect.top) * minutesPerPixel);
		if (!(rect.height > 0) || start < 0 || end > 1440 || end <= start) return fail("eventOutsideDay");
		const title = titleOf(chip, start, end);
		if (!title) return fail("untitledEvent");
		events.push({ title, start, end, allDay: false });
	}
	const main = column.cell.closest('[role="main"]') || document;
	for (const chip of chipsIn(main)) {
		if (column.cell.contains(chip)) continue;
		const title = titleOf(chip, null, null);
		if (!title) return fail("untitledEvent");
		events.push({ title, allDay: true });
	}
	if (events.length > \(maximumEvents)) return fail("tooManyEvents");
	return { version, status: "ok", events };
	"""

	/// Counts the hooks the reader depends on, for checking a real calendar by hand. It returns
	/// numbers and the view's path only: no titles, times or other text from the page.
	internal static let probeScript: String = """
	const count = (selector, root = document) => root.querySelectorAll(selector).length;
	const hook = "[data-eventid], [data-eventchip]";
	const chipsIn = (root) => Array.from(root.querySelectorAll(hook)).filter((element) => {
		const outer = element.parentElement && element.parentElement.closest(hook);
		return !outer || !root.contains(outer);
	});
	const cells = Array.from(document.querySelectorAll('[role="gridcell"][data-datekey]'));
	const heights = cells.map((cell) => Math.round(cell.getBoundingClientRect().height));
	const tallest = cells.reduce((best, cell) => !best || cell.getBoundingClientRect().height > best.getBoundingClientRect().height ? cell : best, null);
	return {
		probe: \(version),
		view: location.pathname.split("/").slice(0, 6).join("/"),
		grids: count('[role="grid"]'),
		mains: count('[role="main"]'),
		busy: count('[aria-busy="true"]'),
		progressBars: count('[role="progressbar"]'),
		dayCells: cells.length,
		dayCellHeights: heights.slice(0, 12),
		eventIDs: count("[data-eventid]"),
		eventChips: count("[data-eventchip]"),
		hookedButtons: Array.from(document.querySelectorAll(hook)).filter((element) => element.matches('[role="button"]') || element.querySelector('[role="button"]')).length,
		hookedWithLabel: Array.from(document.querySelectorAll(hook)).filter((element) => element.hasAttribute("aria-label") || element.querySelector("[aria-label]")).length,
		hookedWithHiddenText: Array.from(document.querySelectorAll(hook)).filter((element) => element.querySelector('[aria-hidden="true"]')).length,
		events: chipsIn(document).length,
		eventsInTallestCell: tallest ? chipsIn(tallest).length : 0,
		unhookedButtonsInTallestCell: tallest ? Array.from(tallest.querySelectorAll('[role="button"][aria-label]')).filter((element) => !element.closest(hook)).length : 0,
		unhookedButtonsInDayCells: cells.flatMap((cell) => Array.from(cell.querySelectorAll('[role="button"][aria-label]'))).filter((element) => !element.closest(hook)).length,
	};
	"""

	// MARK: - Reading the result

	/// The day's events, already checked.
	internal struct Day: Equatable, Sendable {
		internal struct Event: Equatable, Sendable {
			internal var title: String

			/// Minutes after midnight; nil for all-day events.
			internal var start: Int?
			internal var end: Int?

			internal init(
				title: String,
				start: Int? = nil,
				end: Int? = nil
			) {
				self.title = title
				self.start = start
				self.end = end
			}

			internal var isAllDay: Bool { start == nil }
		}

		internal var events: [Event]

		internal init(events: [Event]) {
			self.events = events
		}
	}

	private struct Payload: Decodable {
		internal struct Event: Decodable {
			internal var title: String?
			internal var start: Double?
			internal var end: Double?
			internal var allDay: Bool?
		}

		internal var version: Int?
		internal var status: String?
		internal var reason: String?
		internal var events: [Event]?
	}

	/// Checks the script's JSON value again on this side: the page runs it, so nothing it returns
	/// is trusted. Anything off makes the whole read fail.
	internal static func day(fromScriptValue value: String) -> Result<Day, Failure> {
		guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(value.utf8))
		else { return .failure(.unreadable) }
		guard payload.version == version else { return .failure(.wrongVersion) }

		switch payload.status {
		case "failed":
			return .failure(payload.reason.flatMap(Failure.init(rawValue:)) ?? .unreadable)

		case "ok":
			guard let events = payload.events else { return .failure(.unreadable) }
			guard events.count <= maximumEvents else { return .failure(.tooManyEvents) }
			var checked: [Day.Event] = []
			for event in events {
				guard
					let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines),
					!title.isEmpty,
					title.count <= maximumTitleLength
				else { return .failure(.untitledEvent) }

				if event.allDay == true {
					guard event.start == nil, event.end == nil else { return .failure(.unreadable) }
					checked.append(.init(title: title))
					continue
				}
				guard
					event.allDay == false,
					let start = event.start,
					let end = event.end,
					start.rounded() == start,
					end.rounded() == end,
					start >= 0,
					end <= 1440,
					start < end
				else { return .failure(.eventOutsideDay) }
				checked.append(.init(title: title, start: Int(start), end: Int(end)))
			}

			// All-day events first, then by start time.
			let sorted = checked.enumerated().sorted { lhs, rhs in
				switch (lhs.element.start, rhs.element.start) {
				case (nil, nil): lhs.offset < rhs.offset
				case (nil, _): true
				case (_, nil): false
				case let (left?, right?): left == right ? lhs.offset < rhs.offset : left < right
				}
			}
			return .success(.init(events: sorted.map(\.element)))

		default:
			return .failure(.unreadable)
		}
	}

	/// The probe's counts as one line of `key=value` pairs, for copying into a report.
	internal static func probeReport(fromScriptValue value: String) -> String? {
		guard
			let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
			object["probe"] != nil
		else { return nil }
		return object.keys.sorted().compactMap { key -> String? in
			switch object[key] {
			case let number as NSNumber: "\(key)=\(number)"
			case let string as String: "\(key)=\(string)"
			case let numbers as [NSNumber]: "\(key)=\(numbers.map(\.stringValue).joined(separator: ","))"
			default: nil
			}
		}
		.joined(separator: " ")
	}

	// MARK: - Addresses

	/// Today's day view for the account at `/calendar/u/<account>/`. Google's addresses use
	/// Gregorian dates whatever calendar the Mac is set to; `calendar` gives the time zone.
	internal static func dayURL(
		account: Int,
		day: Date,
		calendar: Calendar = .current
	) -> URL {
		let parts = gregorian(in: calendar).dateComponents([.year, .month, .day], from: day)
		return URL(string: "https://calendar.google.com/calendar/u/\(account)/r/day/\(parts.year ?? 1970)/\(parts.month ?? 1)/\(parts.day ?? 1)")!
	}

	/// The page that starts a new event for the account.
	internal static func newEventURL(account: Int) -> URL {
		URL(string: "https://calendar.google.com/calendar/u/\(account)/r/eventedit")!
	}

	/// Whether an open page shows the day view of `day` for the account, so the reader can use it
	/// as it is. Its address must name the day: a bare `/r/day` left open since yesterday still
	/// shows yesterday. Anything else is read from a page of its own.
	internal static func showsDay(
		_ url: URL,
		account: Int,
		day: Date,
		calendar: Calendar = .current
	) -> Bool {
		guard
			url.scheme?.lowercased() == "https",
			url.host()?.lowercased() == "calendar.google.com"
		else { return false }
		let parts = url.pathComponents.filter { $0 != "/" }

		// calendar/u/<n>/r/day[/<year>/<month>/<day>]
		guard
			parts.count >= 5,
			parts[0] == "calendar",
			parts[1] == "u",
			Int(parts[2]) == account,
			parts[3] == "r",
			parts[4] == "day"
		else { return false }
		guard parts.count >= 8 else { return false }

		let today = gregorian(in: calendar).dateComponents([.year, .month, .day], from: day)
		return Int(parts[5]) == today.year && Int(parts[6]) == today.month && Int(parts[7]) == today.day
	}

	private static func gregorian(in calendar: Calendar) -> Calendar {
		var gregorian = Calendar(identifier: .gregorian)
		gregorian.timeZone = calendar.timeZone
		return gregorian
	}
}
