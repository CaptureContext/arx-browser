import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// The glass search field answers Escape for its own field while it's being edited (DEV-1297),
/// before the window dispatches the key, as the find bar and a folder's hover preview need: never
/// with a modifier, and never for another field in the window.
@MainActor
@Suite(.renderTurn, .serialized)
internal struct ArxGlassSearchFieldTests {
	private final class Counter {
		var escapes: Int = 0
	}

	private enum Focus: Hashable {
		case glass
		case other
	}

	private struct Fields: View {
		let counter: Counter
		let focus: Focus

		@State
		private var query: String = "arx"

		@State
		private var other: String = ""

		@FocusState
		private var focused: Focus?

		var body: some View {
			VStack {
				ArxGlassSearchField(placeholder: "Find", isEmpty: query.isEmpty, onEscape: { counter.escapes += 1 }) {
					TextField("Find", text: $query, prompt: Text(verbatim: ""))
						.focused($focused, equals: .glass)
				}
				TextField("Other", text: $other)
					.focused($focused, equals: .other)
			}
			.frame(width: 300)
			.padding(20)
			.onAppear { focused = focus }
		}
	}

	@Test
	internal func escapeInItsFieldIsAnswered() throws {
		let counter = Counter()
		let window = Self.host(Fields(counter: counter, focus: .glass))
		defer { window.close() }

		try Self.press(in: window)
		#expect(counter.escapes == 1)
	}

	@Test
	internal func escapeWithAModifierIsNot() throws {
		let counter = Counter()
		let window = Self.host(Fields(counter: counter, focus: .glass))
		defer { window.close() }

		try Self.press(modifiers: .command, in: window)
		try Self.press(modifiers: .option, in: window)
		#expect(counter.escapes == 0)
	}

	@Test
	internal func escapeInAnotherFieldIsNot() throws {
		let counter = Counter()
		let window = Self.host(Fields(counter: counter, focus: .other))
		defer { window.close() }

		try Self.press(in: window)
		#expect(counter.escapes == 0)
	}

	/// In a window kept off every screen and never made key; the field editor in place.
	private static func host(_ view: some View) -> NSWindow {
		let host = NSHostingView(rootView: view)
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		for _ in 0..<8 where !(window.firstResponder is NSTextView) {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.025))
		}
		#expect(window.firstResponder is NSTextView, "a field is being edited")
		return window
	}

	/// Escape as the app receives a key press: `sendEvent` runs its key monitors before the window.
	private static func press(
		modifiers: NSEvent.ModifierFlags = [],
		in window: NSWindow
	) throws {
		let event = try #require(NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: modifiers,
			timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: window.windowNumber,
			context: nil,
			characters: "\u{1b}",
			charactersIgnoringModifiers: "\u{1b}",
			isARepeat: false,
			keyCode: 53
		))
		NSApplication.shared.sendEvent(event)
		RunLoop.main.run(until: .now.addingTimeInterval(0.05))
	}
}
