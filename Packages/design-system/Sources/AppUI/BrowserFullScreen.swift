import AppKit
import SwiftUI

extension EnvironmentValues {
	/// Whether the window is in full screen or entering it (DEV-912). The sidebar's toolbar then
	/// gives the window controls' space back, and the controls return to the title bar macOS
	/// reveals at the top edge.
	@Entry
	public var browserWindowIsFullScreen: Bool = false
}

/// Follows the window's full screen as macOS starts each transition, so the layout changes in
/// step with the system's animation rather than after it (DEV-912).
internal struct BrowserFullScreenObserver: NSViewRepresentable {
	private let changed: @MainActor (Bool) -> Void

	internal init(changed: @escaping @MainActor (Bool) -> Void) {
		self.changed = changed
	}

	internal func makeNSView(context: Context) -> ObserverView {
		ObserverView()
	}

	internal func updateNSView(
		_ view: ObserverView,
		context: Context
	) {
		view.changed = changed
	}

	internal final class ObserverView: NSView {
		fileprivate var changed: (@MainActor (Bool) -> Void)?
		private var observations: [NSObjectProtocol] = []

		internal override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			observations.forEach(NotificationCenter.default.removeObserver)
			observations = []
			guard let window else { return }

			let center = NotificationCenter.default

			// The did-notifications settle a transition that never finished, such as a refused entry.
			let entering: [Notification.Name] = [
				NSWindow.willEnterFullScreenNotification,
				NSWindow.didEnterFullScreenNotification,
			]
			let leaving: [Notification.Name] = [
				NSWindow.willExitFullScreenNotification,
				NSWindow.didExitFullScreenNotification,
			]
			for (names, isFullScreen) in [(entering, true), (leaving, false)] {
				for name in names {
					observations.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
						MainActor.assumeIsolated { self?.changed?(isFullScreen) }
					})
				}
			}

			// A window that opens in full screen, after this pass of the view tree.
			let isFullScreen = window.styleMask.contains(.fullScreen)
			DispatchQueue.main.async { [weak self] in
				MainActor.assumeIsolated { self?.changed?(isFullScreen) }
			}
		}

		internal override func hitTest(_ point: NSPoint) -> NSView? { nil }
	}
}
