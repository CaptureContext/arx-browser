import AppKit
import SwiftUI

extension View {
	/// Opens a popover's content with nothing focused: no ring on its first button until the
	/// keyboard asks for one. As a popover opens, AppKit and SwiftUI focus its first control, so
	/// the site menu's Share button showed a focus ring though nobody had used the keyboard. Tab
	/// or Full Keyboard Access still moves to the first control and rings it, and the
	/// accessibility order is unchanged. A text field keeps the focus it opens with.
	public func popoverOpensWithoutFocus() -> some View {
		background(PopoverFocusReset())
	}
}

/// Hands the first responder back to the popover's window as the content appears and when the
/// window first becomes key, so the window's first Tab goes to the first control.
internal struct PopoverFocusReset: NSViewRepresentable {
	internal func makeNSView(context: Context) -> ResetView {
		ResetView()
	}

	internal func updateNSView(
		_ view: ResetView,
		context: Context
	) {}

	internal final class ResetView: NSView {
		/// How long after the content shows the opening's focus is still cleared: the content
		/// picks its first responder over the first few turns, and again once the window is key.
		internal static let openingDuration: Duration = .milliseconds(250)

		private var observer: (any NSObjectProtocol)?
		private var monitor: Any?

		/// Run-loop timers in the common modes, which fire while a popover opens during a click.
		private var timers: [Timer] = []
		private var isDone: Bool = false

		override internal func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			stop()
			guard let window, !isDone else { return }

			observer = NotificationCenter.default.addObserver(
				forName: NSWindow.didBecomeKeyNotification,
				object: window,
				queue: nil
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.schedule(after: .zero) { $0.clear() } }
			}

			// A key pressed in the popover is the person's: their focus stays.
			monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
				MainActor.assumeIsolated {
					if let self, event.window === self.window { self.finish() }
				}
				return event
			}
			for delay in [Duration.zero, .milliseconds(50), .milliseconds(150), Self.openingDuration] {
				schedule(after: delay) { $0.clear() }
			}
			schedule(after: Self.openingDuration + .milliseconds(10)) { $0.finish() }
		}

		override internal func removeFromSuperview() {
			stop()
			super.removeFromSuperview()
		}

		private func schedule(
			after delay: Duration,
			_ body: @escaping @MainActor (ResetView) -> Void
		) {
			let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
			let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
				MainActor.assumeIsolated {
					guard let self else { return }

					body(self)
				}
			}
			RunLoop.main.add(timer, forMode: .common)
			timers.append(timer)
		}

		private func clear() {
			guard !isDone, let window else { return }

			Self.clearInitialFocus(in: window)
		}

		/// Only the opening's focus: from here on, focus is the person's.
		private func finish() {
			isDone = true
			stop()
		}

		private func stop() {
			if let observer { NotificationCenter.default.removeObserver(observer) }
			observer = nil
			if let monitor { NSEvent.removeMonitor(monitor) }
			monitor = nil
			for timer in timers { timer.invalidate() }
			timers.removeAll()
		}

		/// Clears what the window focused on its own: a control, never text input.
		internal static func clearInitialFocus(in window: NSWindow) {
			guard
				let responder = window.firstResponder,
				responder !== window,
				!(responder is NSText)
			else { return }

			window.makeFirstResponder(nil)
		}

		override internal func hitTest(_ point: NSPoint) -> NSView? { nil }

		override internal func isAccessibilityElement() -> Bool { false }
	}
}
