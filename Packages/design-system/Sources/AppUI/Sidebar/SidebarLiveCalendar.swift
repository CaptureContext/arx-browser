import Foundation
import SwiftUI

/// Live Calendar (DEV-804): today's day for a calendar favorite, read by the feature from the
/// calendar's own page in the favorite's profile. Nothing here fetches.
public struct SidebarCalendarDay: Equatable, Sendable {
	public struct Event: Identifiable, Equatable, Sendable {
		public var id: Int
		public var title: String

		/// Minutes after midnight; nil for all-day events.
		public var start: Int?
		public var end: Int?

		public init(
			id: Int,
			title: String,
			start: Int? = nil,
			end: Int? = nil
		) {
			self.id = id
			self.title = title
			self.start = start
			self.end = end
		}

		public var isAllDay: Bool { start == nil }
	}

	public enum Status: Equatable, Sendable {
		case loading
		case loaded([Event])

		/// The page couldn't be read: no times are guessed.
		case failed
	}

	public var status: Status

	/// When the day was last read, for "Last fetch".
	public var fetchedAt: Date?

	public init(
		status: Status,
		fetchedAt: Date? = nil
	) {
		self.status = status
		self.fetchedAt = fetchedAt
	}
}

/// What a calendar favorite's card can do. The feature supplies it only for calendar favorites
/// while Live Calendar is on.
public struct SidebarLiveCalendar: Sendable {
	/// Today's day. With `refresh`, the page is read again even when a recent read is kept.
	public var day: @MainActor @Sendable (_ refresh: Bool) async -> SidebarCalendarDay

	/// Opens the calendar's new-event page in a new tab.
	public var newEvent: @MainActor @Sendable () -> Void

	/// Sets this favorite back to the ordinary card.
	public var disable: @MainActor @Sendable () -> Void

	/// Counts the page structure the reader depends on, with no event text, for checking a real
	/// calendar by hand. Nil when the page couldn't be reached.
	public var checkPage: @MainActor @Sendable () async -> String?

	public init(
		day: @escaping @MainActor @Sendable (_ refresh: Bool) async -> SidebarCalendarDay,
		newEvent: @escaping @MainActor @Sendable () -> Void = {},
		disable: @escaping @MainActor @Sendable () -> Void = {},
		checkPage: @escaping @MainActor @Sendable () async -> String? = { nil }
	) {
		self.day = day
		self.newEvent = newEvent
		self.disable = disable
		self.checkPage = checkPage
	}
}

// MARK: - Card

/// A scrolling day timeline with a line at the current time, all-day events above it, and
/// buttons for the card's menu and a new event.
internal struct SidebarCalendarCard: View {
	private let calendar: SidebarLiveCalendar
	private let now: () -> Date

	@SwiftUI.State
	private var day: SidebarCalendarDay

	@SwiftUI.State
	private var probeReport: String?

	@SwiftUI.State
	private var isCheckingPage: Bool

	/// The gear's options, drawn inside the card: a menu's own window would take the pointer out
	/// of the hover panel and close it.
	@SwiftUI.State
	private var showsOptions: Bool

	internal init(
		calendar: SidebarLiveCalendar,
		now: @escaping () -> Date = Date.init,
		showsOptions: Bool = false
	) {
		self.calendar = calendar
		self.now = now
		self._day = .init(initialValue: .init(status: .loading))
		self._probeReport = .init(initialValue: nil)
		self._isCheckingPage = .init(initialValue: false)
		self._showsOptions = .init(initialValue: showsOptions)
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			if case let .loaded(events) = day.status {
				allDay(events.filter(\.isAllDay))
			}
			ZStack {
				// Redrawn each minute so the line for now moves; that reads nothing.
				TimelineView(.everyMinute) { _ in
					SidebarCalendarTimeline(
						events: timedEvents,
						now: now(),
						dimmed: !isLoaded
					)
				}
				overlay
			}
		}
		.frame(width: Self.width, height: Self.height, alignment: .top)
		.overlay(alignment: .bottomTrailing) { controls }
		.task { day = await calendar.day(false) }
	}

	private var timedEvents: [SidebarCalendarDay.Event] {
		guard case let .loaded(events) = day.status else { return [] }
		return events.filter { !$0.isAllDay }
	}

	private var isLoaded: Bool {
		guard case .loaded = day.status else { return false }
		return true
	}

	@ViewBuilder
	private func allDay(_ events: [SidebarCalendarDay.Event]) -> some View {
		if !events.isEmpty {
			VStack(alignment: .leading, spacing: 3) {
				ForEach(events.prefix(Self.allDayLimit)) { event in
					Text(event.title)
						.font(.system(size: 11, weight: .medium))
						.lineLimit(1)
						.truncationMode(.tail)
						.padding(.horizontal, 6)
						.padding(.vertical, 2)
						.frame(maxWidth: .infinity, alignment: .leading)
						.background(Color.accentColor.opacity(0.16), in: .rect(cornerRadius: 4, style: .continuous))
						.accessibilityLabel(String.localized(.appUI.sidebar.liveCalendarAllDayEvent(event.title)))
				}
				if events.count > Self.allDayLimit {
					Text(String.localized(.appUI.sidebar.liveCalendarMoreAllDay(events.count - Self.allDayLimit)))
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
				}
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 8)
			Divider()
		}
	}

	@ViewBuilder
	private var overlay: some View {
		if let probeReport {
			VStack(alignment: .leading, spacing: 8) {
				Text(probeReport)
					.font(.system(size: 10, design: .monospaced))
					.textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
				HStack {
					Button(String.localized(.appUI.sidebar.liveCalendarCopyReport)) {
						NSPasteboard.general.clearContents()
						NSPasteboard.general.setString(probeReport, forType: .string)
					}
					Spacer()
					Button(String.localized(.appUI.sidebar.liveCalendarDone)) { self.probeReport = nil }
				}
				.controlSize(.small)
			}
			.padding(10)
			.background(.background, in: .rect(cornerRadius: 8, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.strokeBorder(BrowserTheme.border, lineWidth: 0.5)
			}
			.padding(10)
		} else {
			switch day.status {
			case .loading:
				VStack(spacing: 6) {
					ProgressView()
						.controlSize(.small)
					Text(String.localized(.appUI.sidebar.liveCalendarReading))
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
				}

			case .failed:
				VStack(spacing: 8) {
					Text(String.localized(.appUI.sidebar.liveCalendarCouldNotRead))
						.font(.system(size: 12, weight: .medium))
						.multilineTextAlignment(.center)
					Button(String.localized(.appUI.sidebar.liveCalendarRefresh)) { refresh() }
						.controlSize(.small)
				}
				.padding(12)
				.background(.background, in: .rect(cornerRadius: 8, style: .continuous))
				.overlay {
					RoundedRectangle(cornerRadius: 8, style: .continuous)
						.strokeBorder(BrowserTheme.border, lineWidth: 0.5)
				}

			case .loaded:
				EmptyView()
			}
		}
	}

	private var controls: some View {
		VStack(alignment: .trailing, spacing: 6) {
			if showsOptions {
				options
					.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
			}
			buttons
		}
		.padding(10)
		.animation(.snappy(duration: 0.18), value: showsOptions)
	}

	private var options: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text(lastFetch)
				.font(.system(size: 12))
				.foregroundStyle(.secondary)
				.padding(.horizontal, 10)
				.padding(.vertical, 5)
			option(String.localized(.appUI.sidebar.liveCalendarRefresh)) { refresh() }
			Divider()
				.padding(.vertical, 3)
			option(String.localized(.appUI.sidebar.liveCalendarCheckPage)) { checkPage() }
				.disabled(isCheckingPage)
			Divider()
				.padding(.vertical, 3)
			option(String.localized(.appUI.sidebar.liveCalendarDisable)) { calendar.disable() }
		}
		.padding(.vertical, 5)
		.frame(width: 210, alignment: .leading)
		.background(.background, in: .rect(cornerRadius: 10, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.strokeBorder(BrowserTheme.border, lineWidth: 0.5)
		}
		.shadow(color: .black.opacity(0.12), radius: 8, y: 2)
	}

	private func option(
		_ title: String,
		action: @escaping () -> Void
	) -> some View {
		SidebarCalendarOption(title: title) {
			showsOptions = false
			action()
		}
	}

	private var buttons: some View {
		HStack(spacing: 8) {
			Button { showsOptions.toggle() } label: {
				Image(systemName: "gearshape.fill")
					.font(.system(size: 13, weight: .medium))
					.frame(width: 30, height: 30)
					.background(.thinMaterial, in: .circle)
			}
			.buttonStyle(.plain)
			.accessibilityLabel(String.localized(.appUI.sidebar.liveCalendarOptions))
			Button(action: calendar.newEvent) {
				Image(systemName: "plus")
					.font(.system(size: 14, weight: .medium))
					.frame(width: 30, height: 30)
					.background(.background, in: .circle)
					.overlay { Circle().strokeBorder(BrowserTheme.border, lineWidth: 0.5) }
			}
			.buttonStyle(.plain)
			.accessibilityLabel(String.localized(.appUI.sidebar.liveCalendarNewEvent))
		}
	}

	private var lastFetch: String {
		guard let fetchedAt = day.fetchedAt else {
			return String.localized(.appUI.sidebar.liveCalendarNotFetched)
		}
		let relative = fetchedAt.formatted(.relative(presentation: .named))
		return String.localized(.appUI.sidebar.liveCalendarLastFetch(relative))
	}

	private func refresh() {
		day = .init(status: .loading, fetchedAt: day.fetchedAt)
		Task { day = await calendar.day(true) }
	}

	private func checkPage() {
		isCheckingPage = true
		Task {
			probeReport = await calendar.checkPage() ?? String.localized(.appUI.sidebar.liveCalendarCheckFailed)
			isCheckingPage = false
		}
	}

	internal static let width: CGFloat = 288
	internal static let height: CGFloat = 320
	private static let allDayLimit: Int = 3
}

/// One row of the card's options, highlighted under the pointer like a menu item.
private struct SidebarCalendarOption: View {
	internal let title: String
	internal let action: () -> Void

	@SwiftUI.State
	private var isHovered: Bool = false

	@Environment(\.isEnabled)
	private var isEnabled

	internal var body: some View {
		Button(action: action) {
			Text(title)
				.font(.system(size: 13))
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 10)
				.padding(.vertical, 4)
				.contentShape(.rect)
				.background(
					isHovered && isEnabled ? Color.accentColor.opacity(0.16) : .clear,
					in: .rect(cornerRadius: 5, style: .continuous)
				)
				.padding(.horizontal, 5)
		}
		.buttonStyle(.plain)
		.foregroundStyle(isEnabled ? .primary : .secondary)
		.onHover { isHovered = $0 }
	}
}

// MARK: - Timeline

/// Twenty-four hour rows with the day's events placed by their minutes, side by side when they
/// overlap, and a line at the current time. Opens scrolled to just before now.
internal struct SidebarCalendarTimeline: View {
	private let events: [SidebarCalendarDay.Event]
	private let now: Date
	private let dimmed: Bool

	internal init(
		events: [SidebarCalendarDay.Event],
		now: Date,
		dimmed: Bool
	) {
		self.events = events
		self.now = now
		self.dimmed = dimmed
	}

	internal var body: some View {
		ScrollViewReader { proxy in
			ScrollView(.vertical) {
				ZStack(alignment: .topLeading) {
					VStack(spacing: 0) {
						ForEach(0..<24, id: \.self) { hour in
							row(hour).id(hour)
						}
					}
					GeometryReader { geometry in
						let width = geometry.size.width - Self.labelWidth - Self.trailingInset
						ForEach(Self.lanes(events)) { placed in
							block(placed.event)
								.frame(
									width: max(width / CGFloat(placed.laneCount) - 2, 8),
									height: max(CGFloat(placed.event.duration) / 60 * Self.hourHeight - 2, 14)
								)
								.offset(
									x: Self.labelWidth + width / CGFloat(placed.laneCount) * CGFloat(placed.lane),
									y: CGFloat(placed.event.start ?? 0) / 60 * Self.hourHeight + 1
								)
						}
						nowLine(width: geometry.size.width)
					}
				}
				.frame(height: Self.hourHeight * 24)
				.opacity(dimmed ? 0.45 : 1)
			}
			.scrollIndicators(.automatic)
			.onAppear { proxy.scrollTo(max(minutes(now) / 60 - 1, 0), anchor: .top) }
		}
	}

	private func row(_ hour: Int) -> some View {
		VStack(spacing: 0) {
			Divider()
			HStack(alignment: .top, spacing: 0) {
				Text(hourLabel(hour))
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.monospacedDigit()
					.frame(width: Self.labelWidth - 6, alignment: .leading)
					.padding(.leading, 10)
					.padding(.top, 3)
				Spacer(minLength: 0)
			}
			Spacer(minLength: 0)
		}
		.frame(height: Self.hourHeight)
		.accessibilityHidden(true)
	}

	private func block(_ event: SidebarCalendarDay.Event) -> some View {
		HStack(spacing: 0) {
			Rectangle()
				.fill(Color.accentColor)
				.frame(width: 3)
			VStack(alignment: .leading, spacing: 0) {
				Text(event.title)
					.font(.system(size: 11, weight: .semibold))
					.lineLimit(event.duration >= 45 ? 2 : 1)
				if event.duration >= 45 {
					Text(timeRange(event))
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}
			.padding(.horizontal, 5)
			.padding(.vertical, 2)
			Spacer(minLength: 0)
		}
		.frame(maxHeight: .infinity, alignment: .top)

		// Opaque, so the hour lines don't run through the event.
		.background(Color.accentColor.opacity(0.16))
		.background(.background)
		.clipShape(.rect(cornerRadius: 4, style: .continuous))
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("\(event.title), \(timeRange(event))")
	}

	/// The line for now, in the Mac's time zone. Events are placed where the calendar draws them,
	/// in its own time zone; the two match unless the calendar is set to another zone.
	private func nowLine(width: CGFloat) -> some View {
		let y = CGFloat(minutes(now)) / 60 * Self.hourHeight
		return ZStack(alignment: .leading) {
			Rectangle()
				.fill(Color.accentColor)
				.frame(width: width - Self.labelWidth - Self.trailingInset + 4, height: 2)
				.offset(x: Self.labelWidth - 4)
			Circle()
				.fill(Color.accentColor)
				.frame(width: 8, height: 8)
				.offset(x: Self.labelWidth - 8)
		}
		.offset(y: y - 4)
		.frame(height: 8)
		.accessibilityHidden(true)
	}

	private func minutes(_ date: Date) -> Int {
		let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
		return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
	}

	/// A wall-clock time for labels, on a fixed day with no daylight-saving change, so minute 600
	/// always reads 10:00, even on a day the clocks change. Minute 1440 is the next midnight.
	private func date(minutes: Int) -> Date {
		Self.labelMidnight.addingTimeInterval(TimeInterval(minutes * 60))
	}

	/// Midnight on 15 January 2001, a day without a clock change in practically every time zone.
	private static var labelMidnight: Date {
		Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15)) ?? .init(timeIntervalSinceReferenceDate: 0)
	}

	private func hourLabel(_ hour: Int) -> String {
		date(minutes: hour * 60).formatted(.dateTime.hour())
	}

	private func timeRange(_ event: SidebarCalendarDay.Event) -> String {
		guard let start = event.start, let end = event.end else { return "" }
		return (date(minutes: start)..<date(minutes: end)).formatted(.interval.hour().minute())
	}

	// MARK: Layout

	internal struct Placed: Identifiable, Sendable {
		internal var event: SidebarCalendarDay.Event
		internal var lane: Int
		internal var laneCount: Int

		internal var id: Int { event.id }
	}

	/// Places each event in the first lane free at its start; events that overlap share their
	/// group's lane count, so they sit side by side at equal widths.
	nonisolated internal static func lanes(_ events: [SidebarCalendarDay.Event]) -> [Placed] {
		let timed = events
			.filter { $0.start != nil && $0.end != nil }
			.sorted { ($0.start ?? 0, $0.id) < ($1.start ?? 0, $1.id) }
		var placed: [Placed] = []
		var group: [Placed] = []
		var laneEnds: [Int] = []
		var groupEnd: Int = -1

		func closeGroup() {
			let count = max(laneEnds.count, 1)
			placed += group.map { .init(event: $0.event, lane: $0.lane, laneCount: count) }
			group = []
			laneEnds = []
		}

		for event in timed {
			let start = event.start ?? 0
			let end = event.end ?? start
			if start >= groupEnd { closeGroup() }
			let lane = laneEnds.firstIndex { $0 <= start } ?? laneEnds.count
			if lane == laneEnds.count { laneEnds.append(end) } else { laneEnds[lane] = end }
			group.append(.init(event: event, lane: lane, laneCount: 1))
			groupEnd = max(groupEnd, end)
		}
		closeGroup()
		return placed
	}

	internal static let hourHeight: CGFloat = 44
	private static let labelWidth: CGFloat = 52
	private static let trailingInset: CGFloat = 8
}

extension SidebarCalendarDay.Event {
	internal var duration: Int { max((end ?? 0) - (start ?? 0), 0) }
}
