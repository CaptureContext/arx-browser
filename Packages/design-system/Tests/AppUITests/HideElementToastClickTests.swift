@testable import AppUI
import AppKit
import SwiftUI
import Testing

/// DEV-1315: clicks on Hide Element's toast went to the page. The toast hit-tests over all of
/// it, but the element picker under it heard the pointer through it and outlined what lay below,
/// and the toast moved away, or faded, from the pointer on its way to a click.
@Suite
internal struct HideElementToastHoldTests {
	private let page: CGSize = .init(width: 1000, height: 700)
	private let toast: CGSize = .init(width: HideElementToast.Metrics.width, height: 48)

	/// An element under the toast's bottom-right place, as the picker outlined through it.
	private let underTheToast = CGRect(x: 700, y: 620, width: 200, height: 60)

	/// A footer across the page's bottom, under both of the toast's places.
	private let footer = CGRect(x: 0, y: 600, width: 1000, height: 100)

	@Test
	internal func itHoldsItsPlaceWhileThePointerIsOverIt() {
		// Without the pointer over it, it moves away, as it should for the outline.
		#expect(HideElementToastPlacement.resolve(target: underTheToast, toast: toast, page: page) == .leading)
		#expect(HideElementToastPlacement.resolve(target: underTheToast, toast: toast, page: page, isPointerOver: true) == .trailing)
		#expect(
			HideElementToastPlacement.resolve(target: underTheToast, toast: toast, page: page, current: .leading, isPointerOver: true)
				== .leading
		)
	}

	@Test
	internal func itIsSolidWhileThePointerIsOverIt() {
		#expect(HideElementToastPlacement.resolve(target: footer, toast: toast, page: page) == .faded)
		#expect(HideElementToastPlacement.resolve(target: footer, toast: toast, page: page, current: .faded, isPointerOver: true) == .trailing)
	}
}

/// Every click inside the toast's bounds, its padding and the gaps between its controls
/// included, is the toast's: none reaches the page's view under it, in a window that isn't key,
/// as Peek and Little Arx can be.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: CGSessionCopyCurrentDictionary() != nil, "Needs a window server to deliver mouse events")
)
internal struct HideElementToastClickTests {
	@Test(arguments: [false, true])
	internal func everyClickInTheToastIsTheToasts(expanded: Bool) throws {
		let size = CGSize(width: 900, height: 560)
		let page = RecordingPage()
		let log = ActionLog()
		let frame = FrameBox()
		let view = ZStack {
			PageStandIn(view: page)
			HideElementToast(
				site: "news.example",
				entries: [
					.init(id: "a", title: "Sign up", detail: "Section · div.a", symbol: "square.dashed"),
					.init(id: "b", title: "Sponsored", detail: "Image · img.b", symbol: "photo"),
				],
				isExpanded: expanded,
				canUndo: true,
				undo: { log.actions.insert("undo") },
				done: { log.actions.insert("done") },
				toggle: { log.actions.insert("toggle") },
				show: { log.actions.insert("show \($0)") }
			)
			.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame.value = $0 }
			.padding(HideElementToast.Metrics.edgeInset)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		}
		.frame(width: size.width, height: size.height)

		let host = NSHostingView(rootView: view)
		host.frame = .init(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		window.orderFrontRegardless()
		defer { window.close() }
		settle(host)

		// SwiftUI's frame is from the top left; AppKit's from the bottom left.
		let toast = frame.value
		#expect(toast.width == HideElementToast.Metrics.width)
		let bounds = CGRect(x: toast.minX, y: size.height - toast.maxY, width: toast.width, height: toast.height)
		let step: CGFloat = 6
		var x = bounds.minX + 1
		while x < bounds.maxX {
			var y = bounds.minY + 1
			while y < bounds.maxY {
				click(at: .init(x: x, y: y), in: window)
				y += step
			}
			x += step
		}
		settle(host)

		#expect(page.events.isEmpty)
		// The grid lands on each control too, and each answers.
		#expect(log.actions.isSuperset(of: ["undo", "done", "toggle"]))
		if expanded { #expect(log.actions.isSuperset(of: ["show a", "show b"])) }

		// And a click beside the toast is the page's, so the stand-in hears clicks.
		click(at: .init(x: 20, y: 20), in: window)
		#expect(page.events == ["mouseDown"])
	}

	private func click(
		at point: CGPoint,
		in window: NSWindow
	) {
		for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
			let event = NSEvent.mouseEvent(
				with: type,
				location: point,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: 0,
				clickCount: 1,
				pressure: type == .leftMouseDown ? 1 : 0
			)
			if let event { NSApp.sendEvent(event) }
		}
	}

	private func settle(_ host: NSView) {
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
	}
}

@MainActor
private final class ActionLog {
	var actions: Set<String> = []
}

@MainActor
private final class FrameBox {
	var value: CGRect = .zero
}

/// The page's view: it takes the first click, as the element picker's view over a page does.
private final class RecordingPage: NSView {
	var events: [String] = []

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
	override func mouseDown(with event: NSEvent) { events.append("mouseDown") }
}

private struct PageStandIn: NSViewRepresentable {
	let view: NSView

	func makeNSView(context: Context) -> NSView { view }

	func updateNSView(
		_ nsView: NSView,
		context: Context
	) {}
}
