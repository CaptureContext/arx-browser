@testable import AppUI
import AppKit
import Foundation
import SwiftUI
import Testing

/// Sidebar tabs select as the mouse button goes down (DEV-914, on by default again in DEV-994);
/// `ARX_SIDEBAR_PRESS_SELECTS` off brings back selection on the click's release (DEV-976).
/// One serialized suite: the flag and the monitors are app-wide.
@MainActor
@Suite(
	.serialized,
	.renderTurn
)
internal struct SidebarPressActivationTests {
	private let id: SidebarItem.ID = .tab(UUID())

	// MARK: - The flag

	/// On unless turned off (DEV-994, DEV-1143).
	@Test
	internal func theFlagIsOnUnlessTurnedOff() {
		#expect(SidebarPressActivation.isOn(read: { _ in nil }))
		#expect(SidebarPressActivation.isOn(read: { _ in "1" }))
		for value in ["0", "false", "NO", "off"] {
			#expect(!SidebarPressActivation.isOn(read: { $0 == "ARX_SIDEBAR_PRESS_SELECTS" ? value : nil }), "\(value)")
		}
	}

	/// Rows and tiles register a press target only through `hover`.
	@Test
	internal func offAPressSelectsNothingAndNoMonitorIsInstalled() {
		let restore = Self.flag(false)
		defer { restore() }

		var activations: Int = 0
		SidebarPressActivation.hover(id) { activations += 1 }

		#expect(!SidebarPressActivation.isInstalled)
		SidebarPressActivation.press(clickCount: 1, modifiers: [])
		#expect(activations == 0)
		// The click on release finds no press to take over, so the row selects as before.
		#expect(!SidebarPressActivation.consume(id))
	}

	// MARK: - Flag off: real rows and tiles

	// Real mouse events reach a row and a Favorite tile: the press selects nothing and the release
	// selects. A window off every screen never gets hover from the window server, so these don't
	// reach the press path itself; every row and tile registers through `hover`, which does
	// nothing with the flag off (above).

	@Test(.enabled(if: CGSessionCopyCurrentDictionary() != nil, "Needs a window server to deliver mouse events"))
	internal func offARowSelectsOnReleaseNotOnThePress() {
		let restore = Self.flag(false)
		defer { restore() }

		var received: [SidebarAction] = []
		let item = SidebarItem(id: id, title: "Unselected", isPinned: false)
		let host = HostedView(SidebarRow(item: item) { received.append($0) }, size: .init(width: 240, height: 40))
		defer { host.close() }

		host.send(.mouseMoved)
		host.send(.leftMouseDown)
		#expect(!received.contains { $0.is(\.select) }, "A press that may start a drag selects nothing: \(received)")

		host.send(.leftMouseUp)
		#expect(received.contains { Self.selects($0, id) }, "\(received)")
		#expect(!SidebarPressActivation.isInstalled)
	}

	@Test(.enabled(if: CGSessionCopyCurrentDictionary() != nil, "Needs a window server to deliver mouse events"))
	internal func offAFavoriteSelectsOnReleaseNotOnThePress() {
		let restore = Self.flag(false)
		defer { restore() }

		var received: [SidebarAction] = []
		let item = SidebarItem(id: id, title: "Favorite", isPinned: true)
		let host = HostedView(FavoriteTile(item: item) { received.append($0) }, size: .init(width: 80, height: 80))
		defer { host.close() }

		host.send(.mouseMoved)
		host.send(.leftMouseDown)
		#expect(!received.contains { $0.is(\.select) }, "A press that may start a drag selects nothing: \(received)")

		host.send(.leftMouseUp)
		#expect(received.contains { Self.selects($0, id) }, "\(received)")
		#expect(!SidebarPressActivation.isInstalled)
	}

	// MARK: - Flag on: DEV-914's press selection

	@Test
	internal func onAPlainPressSelectsTheHoveredTabOnceAndItsClickDoesNothingMore() async throws {
		let restore = Self.flag(true)
		defer { restore() }

		var activations: Int = 0
		SidebarPressActivation.hover(id) { activations += 1 }
		#expect(SidebarPressActivation.isInstalled)

		SidebarPressActivation.press(clickCount: 1, modifiers: [])
		#expect(activations == 1)
		#expect(SidebarPressActivation.consume(id))
		#expect(!SidebarPressActivation.consume(id))
		SidebarPressActivation.leave(id)
	}

	@Test
	internal func onModifiedPressesDoubleClicksAndOtherRowsWaitForRelease() async throws {
		let restore = Self.flag(true)
		defer { restore() }

		var activations: Int = 0
		SidebarPressActivation.hover(id) { activations += 1 }

		SidebarPressActivation.press(clickCount: 1, modifiers: .command)
		SidebarPressActivation.press(clickCount: 1, modifiers: .shift)
		SidebarPressActivation.press(clickCount: 1, modifiers: .control)
		SidebarPressActivation.press(clickCount: 2, modifiers: [])
		#expect(activations == 0)
		#expect(!SidebarPressActivation.consume(id))

		// Leaving another row's target keeps this one; leaving this one ends it.
		SidebarPressActivation.leave(.tab(UUID()))
		SidebarPressActivation.leave(id)
		SidebarPressActivation.press(clickCount: 1, modifiers: [])
		#expect(activations == 0)
	}

	private static func selects(
		_ action: SidebarAction,
		_ id: SidebarItem.ID
	) -> Bool {
		guard case let .select(selected) = action else { return false }
		return selected == id
	}

	/// Sets the flag from a clean state and returns what puts the previous setting back.
	private static func flag(_ enabled: Bool) -> () -> Void {
		let previous = SidebarPressActivation.isEnabled
		SidebarPressActivation.reset()
		SidebarPressActivation.isEnabled = enabled
		return {
			SidebarPressActivation.reset()
			SidebarPressActivation.isEnabled = previous
		}
	}
}

/// One view in a borderless window far off every screen, clicked at its centre with real events.
@MainActor
private final class HostedView {
	private let window: NSWindow
	private let host: NSHostingView<AnyView>

	internal init(
		_ view: some View,
		size: CGSize
	) {
		self.host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
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

	internal func send(_ type: NSEvent.EventType) {
		let event = NSEvent.mouseEvent(
			with: type,
			location: CGPoint(x: host.frame.midX, y: host.frame.midY),
			modifierFlags: [],
			timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: window.windowNumber,
			context: nil,
			eventNumber: 0,
			clickCount: type == .mouseMoved ? 0 : 1,
			pressure: type == .leftMouseDown ? 1 : 0
		)
		if let event { NSApp.sendEvent(event) }
		settle()
	}

	internal func close() {
		window.close()
	}

	private func settle() {
		for _ in 0..<3 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.02))
		}
	}
}
