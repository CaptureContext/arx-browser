import AppKit
import SwiftUI

/// Tells a focus move made from the keyboard apart from focus a window hands out by itself
/// (DEV-797): a sheet focuses its first button as it opens, and that button shouldn't show the
/// focus ring until the person actually moves focus with Tab.
///
/// It watches the app's key presses for Tab and Shift-Tab and remembers when the last one went
/// by. A control that gains focus right after one draws its ring; one that gains focus any
/// other way doesn't.
@MainActor
internal enum ArxKeyboardFocus {
	/// How long after a Tab press a control gaining focus counts as moved to by the keyboard.
	internal static let window: TimeInterval = 0.5

	private static var lastNavigation: Date?
	private static var monitor: Any?

	/// Starts watching key presses, once per app.
	internal static func start() {
		guard monitor == nil
		else { return }

		monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in

			// Tab, with or without Shift.
			if event.keyCode == 48 {
				lastNavigation = .now
			}
			return event
		}
	}

	/// Whether focus moving now was moved by the keyboard.
	internal static var isNavigating: Bool {
		guard let lastNavigation
		else { return false }

		return Date.now.timeIntervalSince(lastNavigation) < window
	}

	/// For tests: as if Tab had just been pressed, or never.
	internal static func reset(navigatedAt date: Date?) {
		lastNavigation = date
	}
}

/// Whether a focused control shows its ring: only when focus came to it from the keyboard.
private struct ArxKeyboardFocusRing: ViewModifier {
	internal let isFocused: Bool

	@Binding
	internal var showsRing: Bool

	internal func body(content: Content) -> some View {
		content
			.onAppear { ArxKeyboardFocus.start() }
			.onChange(of: isFocused, initial: true) { _, focused in
				showsRing = focused && ArxKeyboardFocus.isNavigating
			}
	}
}

extension View {
	/// Sets `showsRing` when the control gains focus from Tab and clears it when it loses focus,
	/// so focus a sheet hands its first button on opening never draws the ring (DEV-797).
	internal func arxKeyboardFocusRing(
		isFocused: Bool,
		showsRing: Binding<Bool>
	) -> some View {
		modifier(ArxKeyboardFocusRing(isFocused: isFocused, showsRing: showsRing))
	}
}
