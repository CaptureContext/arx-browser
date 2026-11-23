import AppKit
import SwiftUI

/// A sidebar tab dropped outside every Arx window, where nothing took it (DEV-793). The window
/// moves the tab into Little Arx at the drop point.
public enum SidebarTabTearOff {
	/// Whether a drag that ended with `operation` at `point` landed outside every window in
	/// `windowFrames`. Both are in screen coordinates. A drop something accepted never tears off,
	/// and neither does a drag the user cancelled with Escape: both end with `.cancel`, so
	/// `cancelledByKey` tells them apart.
	public static func isOutside(
		point: CGPoint,
		operation: DropOperation,
		cancelledByKey: Bool = false,
		windowFrames: [CGRect]
	) -> Bool {
		guard !cancelledByKey else { return false }

		switch operation {
		case .cancel, .forbidden:
			return !windowFrames.contains { $0.contains(point) }

		default:
			return false
		}
	}

	/// Checks a drag that just ended against the app's visible windows, at the pointer.
	@MainActor
	internal static func droppedOutside(_ operation: DropOperation) -> CGPoint? {
		let point = NSEvent.mouseLocation
		let frames = NSApp.windows
			.filter { $0.isVisible && !$0.isMiniaturized && $0.isOnActiveSpace }
			.map(\.frame)
		return isOutside(
			point: point,
			operation: operation,
			cancelledByKey: dragCancelledByKey,
			windowFrames: frames
		) ? point : nil
	}

	/// Escape ends a drag with the same `.cancel` as a drop nothing took. The drag ended on Escape
	/// when the event that ended it was Escape, or Escape is still held down.
	@MainActor
	private static var dragCancelledByKey: Bool {
		let escape: UInt16 = 53
		if
			let event = NSApp.currentEvent,
			[.keyDown, .keyUp].contains(event.type),
			event.keyCode == escape
		{ return true }

		return CGEventSource.keyState(.combinedSessionState, key: escape)
	}
}

private enum SidebarTabDroppedOutsideKey: EnvironmentKey {
	internal static var defaultValue: (@MainActor (UUID, CGPoint) -> Void)? { nil }
}

extension EnvironmentValues {
	/// A single unpinned tab dropped outside every Arx window, with the drop point in screen
	/// coordinates (DEV-793).
	public var sidebarTabDroppedOutside: (@MainActor (UUID, CGPoint) -> Void)? {
		get { self[SidebarTabDroppedOutsideKey.self] }
		set { self[SidebarTabDroppedOutsideKey.self] = newValue }
	}
}
