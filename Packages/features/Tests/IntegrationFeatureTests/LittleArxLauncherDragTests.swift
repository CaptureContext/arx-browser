import AppKit
import BrowserCore
import Foundation
import LittleArxFeature
import SwiftUI
import Testing
import _ComposableArchitecture

@testable import AppFeature
@testable import AppUI

/// DEV-1335: the launcher bar moves by its background and stays open. The bar is the real
/// `LittleArxPanel` hosting the real `LittleArxView`, and the press goes to the panel, as AppKit
/// delivers it. The bar used to hand its drags to the window server (`WindowDragGesture`), and it
/// closed as soon as one began: it lost the keyboard, which closes it. Synthetic events can't start
/// a window server move, so on that bar this test sees no move rather than the close.
@MainActor
@Suite(.renderTurn, .dependencies, .enabled(if: NativeEvents.areAvailable, "Needs a window server to deliver mouse events"))
internal struct LittleArxLauncherDragTests {
	/// An empty strip of the bar, under the field, in the window's coordinates.
	private static let empty = CGPoint(x: 240, y: 14)

	/// One bar for every step: a press on its background that moves drags it and leaves it open
	/// with the field focused, a plain click there does nothing, and losing the keyboard to another
	/// window still closes it, as a click outside it does.
	@Test
	internal func theBarMovesByItsBackgroundAndStaysOpen() async throws {
		let launcher = try await Launcher.open()
		defer { launcher.close() }
		let opened = launcher.panel.frame.origin
		#expect(launcher.hit(Self.empty) is WindowBackgroundDragView, "The press doesn't land on the bar's background")

		launcher.drag(from: Self.empty, by: .init(dx: 60, dy: -30))

		let dragged = CGPoint(x: opened.x + 60, y: opened.y - 30)
		expectNoDifference(launcher.panel.frame.origin, dragged)
		#expect(launcher.panel.isKeyWindow)
		#expect(launcher.resignations == 0)
		#expect(launcher.isOpen)
		#expect(launcher.fieldHasFocus)

		launcher.drag(from: Self.empty, by: .zero)

		expectNoDifference(launcher.panel.frame.origin, dragged)
		#expect(launcher.panel.isKeyWindow)
		#expect(launcher.isOpen)
		#expect(launcher.fieldHasFocus)

		let other = NSPanel(
			contentRect: .init(x: -10_000, y: -9_000, width: 200, height: 100),
			styleMask: [.titled, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		other.isReleasedWhenClosed = false
		defer { other.close() }
		other.orderFrontRegardless()
		other.makeKey()
		launcher.spin(0.1)

		#expect(launcher.resignations == 1)
		#expect(!launcher.isOpen)
	}
}

/// A launcher bar as BrowserWindow shows one, off every screen so nothing on the Mac changes:
/// in front, with the keyboard, and closing when it loses the keyboard.
@MainActor
private final class Launcher: NSObject, NSWindowDelegate {
	let panel: LittleArxPanel
	let store: StoreOf<LittleArxFeature>
	private(set) var resignations = 0

	/// Opens one and waits for its field to take the keyboard.
	static func open() async throws -> Launcher {
		let store = Store(initialState: LittleArxFeature.State(
			id: UUID(),
			spaceID: .init(rawValue: UUID()),
			tab: .init(
				id: .init(rawValue: UUID()),
				profileID: .init(rawValue: UUID()),
				restoration: .init(title: "Launcher", url: URL(string: "about:blank")!)
			),
			isCommandOnly: true
		)) { LittleArxFeature() } withDependencies: {
			$0.browserEngine.events = { _ in .finished }
		}
		await store.send(.ui(.task)).finish()
		let launcher = Launcher(store: store)

		// The field takes the keyboard as the bar opens, as it does in the app.
		let field = try #require(launcher.field, "The launcher has no field")
		launcher.panel.makeFirstResponder(field)
		launcher.spin(0.05)
		try #require(launcher.panel.isKeyWindow)
		try #require(launcher.isOpen)
		try #require(launcher.fieldHasFocus, "First responder: \(String(describing: launcher.panel.firstResponder))")
		return launcher
	}

	private init(store: StoreOf<LittleArxFeature>) {
		self.store = store
		panel = LittleArxPanel(commandOnly: true)
		super.init()

		let host = NSHostingView(rootView: LittleArxView(
			store: store,
			surface: .init(attach: { _, _ in }, detach: { _ in }),
			profiles: [],
			onCommandHeightChange: { [weak panel] in panel?.fitCommandBar(height: $0) },
			destinations: []
		))
		panel.contentView = host
		panel.setFrameOrigin(.init(x: -10_000, y: -10_000))
		panel.delegate = self
		panel.orderFrontRegardless()
		panel.makeKey()
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			spin(0.05)
		}
	}

	/// Still a launcher bar: losing the keyboard closes it and drops its command bar.
	var isOpen: Bool { store.commandBarContext != nil }

	/// The field edits text: its field editor has the keyboard.
	var fieldHasFocus: Bool {
		guard let editor = panel.firstResponder as? NSTextView else { return false }
		return editor.delegate === field
	}

	var field: NSTextField? {
		func find(_ view: NSView) -> NSTextField? {
			if let field = view as? NSTextField, field.accessibilityIdentifier() == "command-bar-input" { return field }
			return view.subviews.lazy.compactMap(find).first
		}
		return panel.contentView.flatMap(find)
	}

	func hit(_ point: CGPoint) -> NSView? {
		panel.contentView?.superview?.hitTest(point)
	}

	/// A press at `point`, moved by `offset` in steps, and its release: the press through the
	/// panel, as AppKit delivers it, and the pointer's moves and release to the drag that tracks
	/// the press, as AppKit's queue and the pointer would give them.
	func drag(
		from point: CGPoint,
		by offset: CGVector
	) {
		let start = panel.convertPoint(toScreen: point)
		let count = 12
		var steps: [WindowBackgroundDragView.Step] = (1...count).filter { _ in offset != .zero }.map { step in
			let fraction = CGFloat(step) / CGFloat(count)
			return .init(location: .init(x: start.x + offset.dx * fraction, y: start.y + offset.dy * fraction), isRelease: false)
		}
		steps.append(.init(location: .init(x: start.x + offset.dx, y: start.y + offset.dy), isRelease: true))

		let appKitQueue = WindowBackgroundDragView.nextStep
		WindowBackgroundDragView.nextStep = { _ in steps.isEmpty ? nil : steps.removeFirst() }
		defer { WindowBackgroundDragView.nextStep = appKitQueue }
		if let down = event(.leftMouseDown, at: point) { panel.sendEvent(down) }
		spin(0.2)
	}

	func spin(_ seconds: TimeInterval) {
		RunLoop.main.run(until: .now.addingTimeInterval(seconds))
	}

	func close() {
		panel.delegate = nil
		panel.contentView = nil
		panel.close()
	}

	func windowDidResignKey(_ notification: Notification) {
		resignations += 1

		// As BrowserWindow does.
		store.send(.ui(.lostFocus))
	}

	private func event(
		_ type: NSEvent.EventType,
		at point: CGPoint
	) -> NSEvent? {
		NSEvent.mouseEvent(
			with: type,
			location: point,
			modifierFlags: [],
			timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: panel.windowNumber,
			context: nil,
			eventNumber: 0,
			clickCount: 1,
			pressure: type == .leftMouseUp ? 0 : 1
		)
	}
}
