import AppKit
import SwiftUI

/// Selects a split pane on any mouse-down inside it (DEV-993): its header, its page, an empty
/// pane or a chat tab. It watches clicks with a local monitor and hands every event back
/// unchanged, so the page or control under the pointer still gets the click, and it never takes
/// part in hit testing.
internal struct PaneClickMonitor: NSViewRepresentable {
	internal let onClick: @MainActor () -> Void

	internal init(onClick: @escaping @MainActor () -> Void) {
		self.onClick = onClick
	}

	internal func makeNSView(context: Context) -> MonitorView {
		let view = MonitorView()
		view.onClick = onClick
		return view
	}

	internal func updateNSView(
		_ view: MonitorView,
		context: Context
	) {
		view.onClick = onClick
	}

	internal static func dismantleNSView(
		_ view: MonitorView,
		coordinator: ()
	) {
		view.stopMonitoring()
	}

	internal final class MonitorView: NSView {
		internal var onClick: @MainActor () -> Void = {}
		private var monitor: Any?

		/// Never the view a click lands on: the pane's own content gets it.
		internal override func hitTest(_ point: NSPoint) -> NSView? { nil }

		internal override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			stopMonitoring()
			guard self.window != nil else { return }

			let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
			self.monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
				MainActor.assumeIsolated {
					guard let self, self.selects(event) else { return }
					self.onClick()
				}
				return event
			}
		}

		internal func stopMonitoring() {
			if let monitor { NSEvent.removeMonitor(monitor) }
			monitor = nil
		}

		/// Whether `event` is a click in this pane's window, inside the pane, while it's shown.
		internal func selects(_ event: NSEvent) -> Bool {
			guard
				let window = self.window,
				event.window === window,
				!self.isHiddenOrHasHiddenAncestor
			else { return false }

			return self.bounds.contains(self.convert(event.locationInWindow, from: nil))
		}
	}
}
