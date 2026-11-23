#if DEBUG
import AppKit
import AppUI
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// The Hide Element toast clicks ticket's hand check (DEV-1315), in the app's own window, with
/// the pointer and the clicks posted as a mouse sends them, so the picker's tracking area hears
/// them as it hears a person's.
///
/// On a page whose footer runs under both of the toast's places and with a box under its
/// bottom-right one, Hide Element opens (⇧⌘H) and one click on the page hides a paragraph. The
/// pointer goes over the footer, then onto the toast: there nothing may be outlined, and the toast
/// must hold still and solid. Then clicks on the toast's padding, its corners, its title and the
/// gaps between its controls must change nothing: no element hidden, none shown, the mode still
/// on. Each control must do its own thing: the chevron opens the list (whose padding and header
/// again change nothing), the entry's eye shows its element again, Undo takes back a second pick
/// and Done ends the mode.
@MainActor
internal enum HideElementToastSmoke {
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		window: NSWindow,
		baseURL: URL
	) async throws {
		let fixture = baseURL.deletingLastPathComponent().appending(path: "hide.html")
		window.makeKeyAndOrderFront(nil)
		store.send(.ui(.openURLInSpace(fixture, store.main.sidebar.spaceID, .mainBrowser)))
		try await HandCheckSmoke.wait("hide element page") {
			let navigation = store.main.viewer.item.navigation
			return navigation.url == fixture && !navigation.isLoading && store.main.viewer.item.tab != nil
		}
		guard let tab = store.main.viewer.item.tab?.id else { throw HandCheckSmoke.Failure("no page tab") }

		func session() -> HideElementFeature.State? { store.hideElementSessions[id: tab] }

		func picker(in window: NSWindow) -> NSView? {
			guard let root = window.contentView?.superview else { return nil }
			return HandCheckSmoke.views(under: root).first { $0.identifier?.rawValue == UndoRoute.hideElementInput }
		}

		// A new profile's content blocker restarts once soon after its first launch; until it's
		// back the engine refuses the mode and the command does nothing (one run in seven on
		// 23 Nov, the same press taken two seconds later). The phase is about the toast, so it
		// waits for the page to take the mode before pressing.
		try await HandCheckSmoke.wait("the page takes Hide Element", seconds: 30) { engine.canHideElementsFixture(tab) }
		try HandCheckSmoke.press(.hideElement, store: store, window: window)

		// The engine lays its picker over the page a moment after the session starts.
		try await HandCheckSmoke.wait("picker over the page", context: { describe(session()) }) {
			session()?.isFinishing == false && picker(in: window) != nil
		}
		guard let input = picker(in: window) else { throw HandCheckSmoke.Failure("no picker over the page") }
		let page = input.convert(input.bounds, to: nil)
		let content = NSPoint(x: page.midX, y: page.maxY - 60)

		// A pick, so Undo has something to take back and the list an entry.
		try post(.mouseMoved, at: content, in: window)
		try await Task.sleep(for: .milliseconds(200))
		try post(click: content, in: window)
		try await HandCheckSmoke.wait("the first pick", context: { describe(session()) }) {
			session()?.entries.count == 1 && session()?.undoable.count == 1
		}

		// Over the footer the toast fades, and over the toast it's solid and nothing's outlined.
		let collapsed = try toast(in: window).frame
		try post(.mouseMoved, at: .init(x: collapsed.midX, y: collapsed.minY - 4), in: window)
		try await Task.sleep(for: .milliseconds(300))
		try post(.mouseMoved, at: .init(x: collapsed.minX + 3, y: collapsed.midY), in: window)
		try await HandCheckSmoke.wait("nothing outlined under the toast", context: { describe(session()) }) {
			session()?.target == nil
		}
		try await Task.sleep(for: .milliseconds(400))
		let held = try toast(in: window).frame
		guard held == collapsed else { throw HandCheckSmoke.Failure("the toast moved under the pointer: \(collapsed) → \(held)") }

		try await clickNothing(around: try controls(in: window), toast: held, store: store, session: session, window: window)

		// The chevron opens the list; its padding and its header change nothing either.
		try post(click: try control(String.localized(.appUI.siteMenu.hiddenElements), in: window), in: window)
		try await HandCheckSmoke.wait("the list open") { session()?.isExpanded == true }
		try await Task.sleep(for: .milliseconds(400))
		let expanded = try toast(in: window).frame
		try await clickNothing(around: try controls(in: window), toast: expanded, store: store, session: session, window: window)

		// The entry's eye shows its element again.
		guard let entry = session()?.entries.first else { throw HandCheckSmoke.Failure("the list lost its entry") }
		let title = entry.presentation.title
		try post(click: try control(String.localized(.appUI.siteMenu.showHiddenElementNamed(title)), in: window), in: window)
		try await HandCheckSmoke.wait("the eye showed it again", context: { describe(session()) }) {
			session()?.entries.isEmpty == true
		}

		// Undo takes back a second pick.
		try post(.mouseMoved, at: content, in: window)
		try await Task.sleep(for: .milliseconds(200))
		try post(click: content, in: window)
		try await HandCheckSmoke.wait("the second pick", context: { describe(session()) }) { session()?.undoable.count == 1 }
		try post(click: try control(String.localized(.appUI.menu.undo), in: window), in: window)
		try await HandCheckSmoke.wait("Undo", context: { describe(session()) }) { session()?.undoable.isEmpty == true }

		// Done ends the mode.
		try post(click: try control(String.localized(.appUI.common.done), in: window), in: window)
		try await HandCheckSmoke.wait("Done") { session() == nil }
		print(HandCheckSmoke.Phase.hideElementToast.successMarker)
	}

	/// Clicks on the toast that land on no control: inside each corner, along each edge, on its
	/// title and between its controls. None may hide or show anything or end the mode.
	private static func clickNothing(
		around controls: [NSRect],
		toast: NSRect,
		store: StoreOf<AppFeature>,
		session: () -> HideElementFeature.State?,
		window: NSWindow
	) async throws {
		let before = session()
		let inset = toast.insetBy(dx: 3, dy: 3)
		var points: [NSPoint] = [
			.init(x: inset.minX, y: inset.minY), .init(x: inset.maxX, y: inset.minY),
			.init(x: inset.minX, y: inset.maxY), .init(x: inset.maxX, y: inset.maxY),
			.init(x: inset.midX, y: inset.minY), .init(x: inset.midX, y: inset.maxY),
			.init(x: inset.minX, y: inset.midY), .init(x: toast.minX + 60, y: toast.minY + 24),
		]

		// The gaps between neighbouring controls on a row.
		let sorted = controls.sorted { $0.minX < $1.minX }
		for (left, right) in zip(sorted, sorted.dropFirst()) where abs(left.midY - right.midY) < 4 && right.minX > left.maxX {
			points.append(.init(x: (left.maxX + right.minX) / 2, y: left.midY))
		}
		for point in points where !controls.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) {
			try post(click: point, in: window)
			try await Task.sleep(for: .milliseconds(150))
			let now = session()
			guard
				let now,
				now.isFinishing == false,
				now.entries.ids == before?.entries.ids,
				now.undoable == before?.undoable,
				now.isExpanded == before?.isExpanded
			else {
				throw HandCheckSmoke.Failure("a click on the toast at \(point) changed the mode: \(describe(before)) → \(describe(now))")
			}
		}
	}

	// MARK: - The toast

	/// The toast's accessibility element, which contains its controls, and its frame in window points.
	private static func toast(in window: NSWindow) throws -> (element: NSAccessibilityProtocol, frame: NSRect) {
		let label = String.localized(.appUI.hideElement.command)
		let elements = HandCheckSmoke.accessibilityElements(in: window)
		guard
			let element = elements
				.first(where: { $0.accessibilityLabel() == label && $0.accessibilityFrame().width >= HideElementToast.Metrics.width - 1 })
		else {
			// SwiftUI builds the toast's accessibility elements only while an assistive client
			// (VoiceOver, Accessibility Inspector, a screen-control tool) is asking the app.
			let labelled = elements.filter { $0.accessibilityLabel()?.isEmpty == false }.count
			throw HandCheckSmoke.Failure("no toast in the window's accessibility: \(labelled) of \(elements.count) elements have a label")
		}
		return (element, window.convertFromScreen(element.accessibilityFrame()))
	}

	/// The frames of the toast's buttons, in window points.
	private static func controls(in window: NSWindow) throws -> [NSRect] {
		let toast = try toast(in: window).frame
		return HandCheckSmoke.accessibilityElements(in: window)
			.filter { $0.accessibilityRole() == .button }
			.map { window.convertFromScreen($0.accessibilityFrame()) }
			.filter { toast.contains($0) && $0.width < toast.width / 2 }
	}

	/// The centre of the toast's button labelled `text`, in window points.
	private static func control(
		_ text: String,
		in window: NSWindow
	) throws -> NSPoint {
		let toast = try toast(in: window).frame
		guard
			let element = HandCheckSmoke.accessibilityElements(in: window).first(where: { element in
				let frame = window.convertFromScreen(element.accessibilityFrame())
				return element.accessibilityRole() == .button && toast.contains(frame)
					&& (element.accessibilityLabel() == text || element.accessibilityTitle()?.hasPrefix(text) == true
						|| element.accessibilityLabel()?.hasPrefix(text) == true)
			})
		else { throw HandCheckSmoke.Failure("no \(text) button on the toast") }
		let frame = window.convertFromScreen(element.accessibilityFrame())
		return .init(x: frame.midX, y: frame.midY)
	}

	// MARK: - The mouse

	/// A move posted as the mouse sends it, at `point` in window points.
	private static func post(
		_ type: CGEventType,
		at point: NSPoint,
		in window: NSWindow
	) throws {
		let screen = window.convertPoint(toScreen: point)

		// Quartz counts from the top of the main display.
		let height = NSScreen.screens.first?.frame.height ?? 0
		guard
			let event = CGEvent(
				mouseEventSource: CGEventSource(stateID: .hidSystemState),
				mouseType: type,
				mouseCursorPosition: .init(x: screen.x, y: height - screen.y),
				mouseButton: .left
			)
		else { throw HandCheckSmoke.Failure("no mouse event") }
		event.post(tap: .cghidEventTap)
	}

	private static func post(
		click point: NSPoint,
		in window: NSWindow
	) throws {
		try post(.mouseMoved, at: point, in: window)
		try post(.leftMouseDown, at: point, in: window)
		try post(.leftMouseUp, at: point, in: window)
	}

	private static func describe(_ session: HideElementFeature.State?) -> String {
		guard let session else { return "no mode" }
		return "entries=\(session.entries.count) undoable=\(session.undoable.count) expanded=\(session.isExpanded) "
			+ "target=\(String(describing: session.target)) finishing=\(session.isFinishing)"
	}
}
#endif
