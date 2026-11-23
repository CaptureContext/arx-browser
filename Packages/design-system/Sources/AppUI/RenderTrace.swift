import os

/// Counts view body evaluations by name, so render-count tests can hold the command bar, the
/// window chrome and Settings to a ceiling (DEV-902), as `SidebarRenderTrace` does for sidebar
/// rows. Each evaluation is a Points of Interest signpost in Instruments; Debug builds also count
/// them while a test is recording.
@MainActor
public enum RenderTrace {
	private static let signposter: OSSignposter = .init(
		subsystem: "dev.capturecontext.arx",
		category: .pointsOfInterest
	)

	#if DEBUG
	/// Body evaluations per name since `startRecording()`, or nil when nothing records.
	public private(set) static var counts: [String: Int]?

	public static func startRecording() { counts = [:] }

	public static func stopRecording() { counts = nil }

	/// The bodies `change` caused, counted until it returns.
	public static func recording(_ change: () -> Void) -> [String: Int] {
		startRecording()
		defer { stopRecording() }
		change()
		return counts ?? [:]
	}
	#endif

	public static func body(_ name: StaticString) {
		signposter.emitEvent(name)
		#if DEBUG
		counts?["\(name)", default: 0] += 1
		#endif
	}
}
