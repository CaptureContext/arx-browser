import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Popovers from the URL bar and the site menu open with nothing focused, so their first button
/// shows no focus ring until the keyboard asks for one; text input keeps its focus, and so does a
/// focus the person moves with a key while the popover opens.
@MainActor
@Suite(.renderTurn)
internal struct PopoverInitialFocusTests {
	/// A control that takes focus without Full Keyboard Access, which AppKit's buttons need.
	private final class Focusable: NSView {
		override var acceptsFirstResponder: Bool { true }
	}

	/// What a window focused on its own goes back to the window, unless it's text input.
	@Test
	internal func clearsAControlButKeepsTextInput() {
		let window = Self.window()
		defer { window.close() }
		let control = Focusable(frame: .init(x: 0, y: 0, width: 20, height: 20))
		let text = NSTextView(frame: .init(x: 30, y: 0, width: 100, height: 20))
		window.contentView?.addSubview(control)
		window.contentView?.addSubview(text)

		window.makeFirstResponder(control)
		#expect(window.firstResponder === control)
		PopoverFocusReset.ResetView.clearInitialFocus(in: window)
		#expect(window.firstResponder === window)

		window.makeFirstResponder(text)
		PopoverFocusReset.ResetView.clearInitialFocus(in: window)
		#expect(window.firstResponder === text)
	}

	/// The site menu as a popover's content: whatever its first control takes as it opens is
	/// cleared, and after the opening, focus moved by the keyboard stays.
	@Test
	internal func siteMenuOpensWithNothingFocused() {
		let (window, control) = Self.hostSiteMenu()
		defer { window.close() }

		// As AppKit and SwiftUI do on opening: the first control takes focus.
		window.makeFirstResponder(control)
		Self.wait(PopoverFocusReset.ResetView.openingDuration + .milliseconds(150))
		#expect(window.firstResponder === window)

		// Tab after opening: the person's focus stays and rings.
		window.makeFirstResponder(control)
		Self.wait(.milliseconds(150))
		#expect(window.firstResponder === control)
	}

	/// A key pressed while the popover opens is the person's: the focus it moves stays.
	@Test
	internal func aKeyDuringTheOpeningKeepsTheFocus() throws {
		let (window, control) = Self.hostSiteMenu()
		defer { window.close() }

		// The panel is up and its reset watching before the key.
		Self.wait(.milliseconds(100))
		let tab = try #require(NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: [],
			timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: window.windowNumber,
			context: nil,
			characters: "\t",
			charactersIgnoringModifiers: "\t",
			isARepeat: false,
			keyCode: 48
		))
		NSApplication.shared.sendEvent(tab)
		window.makeFirstResponder(control)
		Self.wait(PopoverFocusReset.ResetView.openingDuration + .milliseconds(150))
		#expect(window.firstResponder === control)
	}

	private static func hostSiteMenu() -> (NSWindow, NSView) {
		let menu = SiteMenu(host: "example.com", connection: .secure, profileName: "Personal")
		let host = NSHostingView(rootView: SiteMenuPanel(menu: menu, send: { _ in }, dismiss: {}).fixedSize())
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = Self.window(size: host.frame.size)
		window.contentView = host

		// Offscreen nothing lays the panel out, as a shown popover's window does.
		host.layoutSubtreeIfNeeded()
		#expect(Self.contains(PopoverFocusReset.ResetView.self, in: host))
		let control = Focusable(frame: .init(x: 0, y: 0, width: 20, height: 20))
		host.addSubview(control)
		return (window, control)
	}

	private static func contains(
		_ kind: NSView.Type,
		in view: NSView
	) -> Bool {
		view.isKind(of: kind) || view.subviews.contains { contains(kind, in: $0) }
	}

	private static func window(size: CGSize = .init(width: 200, height: 60)) -> NSWindow {
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = NSView(frame: .init(origin: .zero, size: size))
		return window
	}

	private static func wait(_ duration: Duration) {
		let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
		RunLoop.main.run(until: .now.addingTimeInterval(seconds))
	}
}
