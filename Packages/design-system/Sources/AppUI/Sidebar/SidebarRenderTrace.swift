import os

/// Counts sidebar body evaluations, so a change in the tab tree can be checked to reach only the
/// rows, and the spaces, it touches. Each evaluation is a signpost event (Points of Interest in
/// Instruments); Debug builds also count them while a test is recording.
@MainActor
internal enum SidebarRenderTrace {
	/// A view above the rows whose body is counted.
	internal enum Subject: Hashable {
		case pager

		/// A space's sidebar, by the space's name.
		case sidebar(String)

		/// A row's frame, measured for a drag.
		case rowFrame
	}

	private static let signposter: OSSignposter = .init(
		subsystem: "dev.capturecontext.arx",
		category: .pointsOfInterest
	)

	#if DEBUG
	/// Body evaluations per row since `startRecording()`, or nil when nothing records.
	internal private(set) static var counts: [SidebarItem.ID: Int]?

	/// Body evaluations per view above the rows since `startRecording()`, or nil when nothing records.
	internal private(set) static var views: [Subject: Int]?

	internal static func startRecording() {
		counts = [:]
		views = [:]
	}

	internal static func stopRecording() {
		counts = nil
		views = nil
	}
	#endif

	internal static func rowBody(_ id: SidebarItem.ID) {
		signposter.emitEvent("SidebarRow.body")
		#if DEBUG
		counts?[id, default: 0] += 1
		#endif
	}

	internal static func pagerBody() {
		signposter.emitEvent("SidebarPager.body")
		#if DEBUG
		views?[.pager, default: 0] += 1
		#endif
	}

	internal static func sidebarBody(_ spaceName: String) {
		signposter.emitEvent("BrowserSidebar.body")
		#if DEBUG
		views?[.sidebar(spaceName), default: 0] += 1
		#endif
	}

	internal static func rowFrame() {
		#if DEBUG
		views?[.rowFrame, default: 0] += 1
		#endif
	}
}
