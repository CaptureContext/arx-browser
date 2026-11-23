@testable import AppUI
import AppKit
import Foundation
import SwiftUI
import Testing

/// The Raised look's floating Actions ⌘K (DEV-1277) answers the pointer: a click opens the
/// actions, as ⌘K does.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: CGSessionCopyCurrentDictionary() != nil, "Needs a window server to deliver mouse events")
)
internal struct CommandBarActionsButtonTests {
	@Test
	internal func clickingActionsOpensTheActions() {
		let log = Log()
		let host = FloatingHost(log: log)
		defer { host.close() }

		host.click(at: .init(x: host.size.width / 2, y: host.size.height / 2))
		#expect(log.events == ["actions"])
	}
}

private final class Log {
	var events: [String] = []
}

/// The floating button in a borderless window far off every screen, which never becomes key.
@MainActor
private final class FloatingHost {
	private let window: NSWindow
	private let host: NSHostingView<AnyView>
	internal let size: CGSize

	internal init(log: Log) {
		let view = CommandBarActionsButton(
			actionsKey: "⌘K",
			onShowActions: { log.events.append("actions") }
		)
		.fixedSize()
		self.host = NSHostingView(rootView: AnyView(view))
		self.size = host.fittingSize
		host.frame = CGRect(origin: .zero, size: size)
		self.window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		window.orderFrontRegardless()
		settle()
	}

	/// A click at `point` in the view, from its bottom-left corner as AppKit counts.
	internal func click(at point: CGPoint) {
		for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
			let event = NSEvent.mouseEvent(
				with: type,
				location: point,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: 0,
				clickCount: type == .mouseMoved ? 0 : 1,
				pressure: type == .leftMouseDown ? 1 : 0
			)
			if let event { NSApp.sendEvent(event) }
		}
		settle()
	}

	internal func close() {
		window.close()
	}

	private func settle() {
		for _ in 0..<3 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.03))
		}
	}
}
