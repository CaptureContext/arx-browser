import AppKit
@testable import AppUI
import CustomDump
import Foundation
import SwiftUI
import Testing

/// DEV-804: Live Calendar's timeline places overlapping events side by side.
internal struct SidebarLiveCalendarTests {
	@Test
	internal func overlappingEventsShareTheirGroupsLanes() {
		let placed = SidebarCalendarTimeline.lanes([
			.init(id: 0, title: "All day"),
			.init(id: 1, title: "A", start: 540, end: 600),
			.init(id: 2, title: "B", start: 570, end: 630),
			.init(id: 3, title: "C", start: 600, end: 660),
			.init(id: 4, title: "D", start: 720, end: 780),
		])
		expectNoDifference(
			placed.map { "\($0.event.title) \($0.lane)/\($0.laneCount)" },
			["A 0/2", "B 1/2", "C 0/2", "D 0/1"]
		)
	}

	@Test
	internal func eventsThatOnlyTouchDontShareLanes() {
		let placed = SidebarCalendarTimeline.lanes([
			.init(id: 1, title: "A", start: 540, end: 600),
			.init(id: 2, title: "B", start: 600, end: 660),
		])
		expectNoDifference(placed.map(\.laneCount), [1, 1])
	}
}

/// Writes offscreen PNGs of the Live Calendar card, light and dark, when `ARX_DESIGN_SNAPSHOTS`
/// names a directory: a day with all-day and overlapping events and the current time, the gear's
/// options, a read that failed, and one still loading. The events are made up.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct SidebarLiveCalendarSnapshotTests {
	/// 2:20 PM today, so the timeline opens on the afternoon.
	private static let now: Date = Calendar.current.date(bySettingHour: 14, minute: 20, second: 0, of: .now)!

	@Test(arguments: [false, true])
	internal func day(dark: Bool) throws {
		try render(
			SidebarCalendarCard(
				calendar: .init(day: { _ in
					.init(
						status: .loaded([
							.init(id: 0, title: "Team offsite"),
							.init(id: 1, title: "Design review", start: 13 * 60, end: 14 * 60),
							.init(id: 2, title: "Arx weekly", start: 14 * 60 + 30, end: 15 * 60 + 30),
							.init(id: 3, title: "1:1 with Ana", start: 15 * 60, end: 15 * 60 + 30),
							.init(id: 4, title: "Gym", start: 18 * 60, end: 19 * 60),
						]),
						fetchedAt: Self.now
					)
				}),
				now: { Self.now }
			),
			name: "live-calendar-day",
			dark: dark
		)
	}

	/// The gear's options, drawn in the card so the hover panel keeps the pointer.
	@Test(arguments: [false, true])
	internal func options(dark: Bool) throws {
		try render(
			SidebarCalendarCard(
				calendar: .init(day: { _ in .init(status: .loaded([]), fetchedAt: .now) }),
				now: { Self.now },
				showsOptions: true
			),
			name: "live-calendar-options",
			dark: dark
		)
	}

	@Test(arguments: [false, true])
	internal func couldNotRead(dark: Bool) throws {
		try render(
			SidebarCalendarCard(
				calendar: .init(day: { _ in .init(status: .failed, fetchedAt: Self.now) }),
				now: { Self.now }
			),
			name: "live-calendar-failed",
			dark: dark
		)
	}

	@Test(arguments: [false, true])
	internal func loading(dark: Bool) throws {
		try render(
			SidebarCalendarCard(
				calendar: .init(day: { _ in
					try? await Task.sleep(for: .seconds(60))
					return .init(status: .failed)
				}),
				now: { Self.now }
			),
			name: "live-calendar-loading",
			dark: dark
		)
	}

	private func render(
		_ content: some View,
		name: String,
		dark: Bool
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let radius = BrowserMetrics.FloatingPanel.cornerRadius
		let view = content
			.background(.regularMaterial, in: .rect(cornerRadius: radius, style: .continuous))
			.clipShape(.rect(cornerRadius: radius, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: radius, style: .continuous)
					.strokeBorder(BrowserTheme.pageBorder, lineWidth: BrowserMetrics.PageCard.borderWidth)
			}
			.padding(16)
			.background { BrowserChromeBackground(textured: true) }
			.fixedSize()

		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = host.appearance
		window.contentView = host

		// The day arrives from a task and the timeline scrolls to the current time.
		for _ in 0..<8 {
			host.layoutSubtreeIfNeeded()
			host.frame.size = host.fittingSize
			window.setContentSize(host.frame.size)
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
