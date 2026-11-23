import AppKit
import CustomDump
import Foundation
import SwiftUI
import Testing
import _ComposableArchitecture

@testable import AppFeature

/// The picker's panel with its real view. SwiftUI shares one field editor between windows, so
/// these run one at a time: a field focused by another test would take it.
@MainActor
@Suite(.renderTurn, .dependencies, .serialized)
internal struct RoutingProfilePickerPanelTests {
	/// The picker's search field didn't take the keyboard when SwiftUI's focus on appear missed
	/// the panel becoming key: typing went nowhere until the field was clicked (DEV-858).
	@Test
	internal func searchFieldTakesTheKeyboardBeforeTheFirstLayout() {
		let panel = RoutingProfilePickerPanel(size: .init(width: 300, height: 200), anchor: .zero)
		defer {
			panel.contentView = nil
			panel.close()
		}

		panel.contentView = NSHostingView(rootView: SearchContent(query: ""))
		panel.focusSearchField()

		#expect(panel.firstResponder is NSTextView)
	}

	@Test
	internal func searchFieldKeepsTheKeyboardOnceItHasIt() throws {
		let panel = RoutingProfilePickerPanel(size: .init(width: 300, height: 200), anchor: .zero)
		defer {
			panel.contentView = nil
			panel.close()
		}

		panel.contentView = NSHostingView(rootView: SearchContent(query: "work"))
		panel.focusSearchField()
		let editor = try #require(panel.firstResponder as? NSTextView)
		editor.setSelectedRange(NSRange(location: 2, length: 0))

		panel.focusSearchField()

		#expect(panel.firstResponder === editor)
		#expect(editor.selectedRange() == NSRange(location: 2, length: 0))
	}

	/// Esc in the panel's search field drops the link, even pressed as the panel opens, before
	/// SwiftUI has seen the field take the keyboard.
	@Test
	internal func escAsItOpensOpensNothing() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.liveStore()
		store.send(.ui(.routeURLs([harness.askURL(1)])))
		let panel = try await harness.openPanel(store)
		defer { harness.close(panel) }

		try harness.press(keyCode: 53, characters: "\u{1B}", in: panel)
		try await harness.waitUntil { store.routingInbox.picker == nil }

		#expect(store.routingInbox.requests.isEmpty)
		#expect(store.littleWindows.isEmpty)
		expectNoDifference(harness.opened.value, [])
	}

	/// Return in the panel's search field opens the link in the highlighted profile, even pressed
	/// as the panel opens.
	@Test
	internal func returnAsItOpensOpensTheLink() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.liveStore()
		store.send(.ui(.routeURLs([harness.askURL(1)])))
		let panel = try await harness.openPanel(store)
		defer { harness.close(panel) }

		try harness.press(keyCode: 36, characters: "\r", in: panel)
		try await harness.waitUntil { !store.littleWindows.isEmpty }

		#expect(store.routingInbox.picker == nil)
		expectNoDifference(harness.opened.value.map(\.restoration.url), [harness.askURL(1)])
		expectNoDifference(harness.opened.value.map(\.profileID), [harness.work.id])
	}

	/// The search field keeps the keyboard, and so its caret, while the arrow keys move the
	/// highlight and Tab is pressed: the list never takes focus or draws a focus ring (DEV-953).
	@Test
	internal func arrowsAndTabKeepTheSearchField() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.liveStore()
		store.send(.ui(.routeURLs([harness.askURL(1)])))
		let panel = try await harness.openPanel(store)
		defer { harness.close(panel) }

		// SwiftUI has seen the field take the keyboard, as before a person presses a key.
		try await Task.sleep(for: .milliseconds(200))
		let editor = try #require(panel.firstResponder as? NSTextView)

		try harness.press(keyCode: 125, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!), in: panel)
		try await harness.waitUntil { store.routingInbox.picker?.highlightedID == harness.club.id }
		#expect(panel.firstResponder === editor)

		try harness.press(keyCode: 48, characters: "\t", in: panel)
		try await Task.sleep(for: .milliseconds(200))
		#expect(panel.firstResponder === editor)
		expectNoDifference(store.routingInbox.picker?.highlightedID, harness.club.id)

		try harness.press(keyCode: 126, characters: String(UnicodeScalar(NSUpArrowFunctionKey)!), in: panel)
		try await harness.waitUntil { store.routingInbox.picker?.highlightedID == harness.work.id }
		#expect(panel.firstResponder === editor)
	}

	/// SwiftUI alone, without the panel's help when it becomes key, focuses the search field.
	@Test
	internal func viewFocusesTheSearchFieldOnAppear() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.liveStore()
		store.send(.ui(.routeURLs([harness.askURL(1)])))
		try await harness.waitUntil { store.routingInbox.picker != nil }
		let picker = try #require(store.routingInbox.picker)
		let content = NSHostingView(rootView: RoutingProfilePickerView(store: store, picker: picker))
		let panel = RoutingProfilePickerPanel(size: content.fittingSize, anchor: .zero)
		defer { harness.close(panel) }
		panel.contentView = content

		try await harness.waitUntil { panel.firstResponder is NSTextView }
	}

	/// Another window's SwiftUI field taking the shared field editor doesn't leave the picker
	/// without a caret: the search field takes it back (DEV-953).
	@Test
	internal func searchFieldTakesTheKeyboardBackFromAnotherWindow() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.liveStore()
		store.send(.ui(.routeURLs([harness.askURL(1)])))
		let panel = try await harness.openPanel(store)
		defer { harness.close(panel) }

		// On screen, as the app shows it, but out of sight and without taking the keyboard.
		panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
		panel.orderFront(nil)

		// SwiftUI has seen the field take the keyboard, so its focus on appear has run.
		try await Task.sleep(for: .milliseconds(200))

		let other = NSWindow(
			contentRect: .init(x: -10_000, y: -10_000, width: 220, height: 60),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		other.isReleasedWhenClosed = false
		defer {
			other.contentView = nil
			other.close()
		}
		let content = NSHostingView(rootView: SearchContent(query: ""))
		other.contentView = content
		content.layoutSubtreeIfNeeded()
		let field = try #require(Self.firstEditableField(in: content))
		other.makeFirstResponder(field)
		#expect(!(panel.firstResponder is NSTextView))

		try await harness.waitUntil { (panel.firstResponder as? NSView)?.window === panel }
		#expect(panel.firstResponder is NSTextView)
	}

	private static func firstEditableField(in view: NSView) -> NSTextField? {
		if let field = view as? NSTextField, field.isEditable { return field }
		for subview in view.subviews {
			if let field = firstEditableField(in: subview) { return field }
		}
		return nil
	}
}

/// A header and a search field, as the picker lays them out.
private struct SearchContent: View {
	@SwiftUI.State
	var query: String

	var body: some View {
		VStack(spacing: 0) {
			Text("Open in")
			TextField("Search", text: $query)
				.textFieldStyle(.plain)
		}
		.frame(width: 200)
	}
}
