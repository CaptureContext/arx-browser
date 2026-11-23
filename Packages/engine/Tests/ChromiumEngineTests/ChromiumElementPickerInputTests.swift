import AppKit
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-1206: the view the element picker lays over a page takes the mouse and the keys, so the
/// page's own view never gets them, and hands them on as commands; the wheel still scrolls the
/// page.
@MainActor
@Suite
internal struct ChromiumElementPickerInputTests {
	@Test
	internal func itCoversThePageAndTakesItsClicks() throws {
		let fixture = Fixture()
		defer { fixture.window.close() }

		#expect(fixture.input.frame == fixture.pageView.bounds)
		#expect(fixture.pageView.subviews.last === fixture.input)
		// Whatever the page draws, a click lands on the picker's view.
		#expect(fixture.window.contentView?.hitTest(.init(x: 100, y: 100)) === fixture.input)

		fixture.send(.leftMouseDown, at: .init(x: 100, y: 200))
		fixture.send(.leftMouseUp, at: .init(x: 102, y: 201))

		// Window points from the bottom-left corner, the view's from the top-left.
		#expect(fixture.input.drain() == [.click(.init(x: 102, y: 99))])
		#expect(fixture.content.events.isEmpty)

		// A drag picks nothing.
		fixture.send(.leftMouseDown, at: .init(x: 100, y: 200))
		fixture.send(.leftMouseUp, at: .init(x: 160, y: 200))
		#expect(fixture.input.drain() == [])

		fixture.send(.rightMouseDown, at: .init(x: 100, y: 200))
		#expect(fixture.input.drain() == [.menu])
		#expect(fixture.content.events.isEmpty)

		// A Control-click is a secondary click too, and picks nothing.
		fixture.send(.leftMouseDown, at: .init(x: 100, y: 200), modifiers: .control)
		fixture.send(.leftMouseUp, at: .init(x: 100, y: 200), modifiers: .control)
		#expect(fixture.input.drain() == [.menu])
	}

	/// DEV-1298: in Hide Element's mode, Esc, Return, ⌘Z and the open list's keys are the app's,
	/// queued with the rest, so ⌘Z after a click waits for that click's pick (Codex, round 3).
	@Test
	internal func inHideElementsModeTheAppsKeysWaitTheirTurn() throws {
		let fixture = Fixture()
		defer { fixture.window.close() }
		fixture.input.takesAppKeys = true

		fixture.send(.leftMouseDown, at: .init(x: 100, y: 200))
		fixture.send(.leftMouseUp, at: .init(x: 100, y: 200))
		#expect(fixture.input.performKeyEquivalent(with: try #require(fixture.key(6, characters: "z", modifiers: .command))))
		#expect(fixture.input.drain() == [.click(.init(x: 100, y: 100)), .app(.undo)])

		for (code, key) in [(53, ChromiumElementPicker.Key.escape), (36, .return)] {
			fixture.input.keyDown(with: try #require(fixture.key(UInt16(code))))
			#expect(fixture.input.drain() == [.app(key)])
		}

		// Space hides what's outlined; ↑ and ↓ widen and narrow, or move through the open list.
		fixture.input.keyDown(with: try #require(fixture.key(49, characters: " ")))
		fixture.input.keyDown(with: try #require(fixture.key(126)))
		#expect(fixture.input.drain() == [.key("Enter"), .key("ArrowUp")])
		fixture.input.listIsOpen = true
		fixture.input.keyDown(with: try #require(fixture.key(126)))
		fixture.input.keyDown(with: try #require(fixture.key(51)))
		#expect(fixture.input.drain() == [.app(.up), .app(.delete)])
	}

	/// DEV-1315: a tracking area hears the pointer through whatever covers its view. Over Hide
	/// Element's toast the pointer has left the page, so nothing under the toast is outlined and
	/// the toast doesn't move away from the pointer on its way to a click, and the click is the
	/// toast's.
	@Test
	internal func thePointerOverSomethingCoveringThePageHasLeftIt() throws {
		let toast = CGRect(x: 200, y: 10, width: 180, height: 60)
		let fixture = Fixture(cover: toast)
		defer { fixture.window.close() }

		// As the tracking area delivers them: to the view, whatever is on top.
		fixture.input.mouseMoved(with: try #require(fixture.event(.mouseMoved, at: .init(x: 100, y: 200))))
		fixture.input.mouseMoved(with: try #require(fixture.event(.mouseMoved, at: .init(x: 300, y: 40))))
		fixture.input.mouseMoved(with: try #require(fixture.event(.mouseMoved, at: .init(x: 310, y: 50))))
		#expect(fixture.input.drain() == [.pointer(.init(x: 100, y: 100)), .leave])

		// Back on the page, it outlines again.
		fixture.input.mouseMoved(with: try #require(fixture.event(.mouseMoved, at: .init(x: 120, y: 200))))
		#expect(fixture.input.drain() == [.pointer(.init(x: 120, y: 100))])

		// A click on the toast, its padding included, is the toast's.
		for point in [CGPoint(x: 201, y: 11), CGPoint(x: 290, y: 40), CGPoint(x: 379, y: 69)] {
			#expect(fixture.window.contentView?.hitTest(point) === fixture.cover)
			fixture.send(.leftMouseDown, at: point)
			fixture.send(.leftMouseUp, at: point)
		}
		#expect(fixture.input.drain() == [])
		#expect(fixture.content.events.isEmpty)
		#expect(fixture.cover?.events == ["mouseDown", "mouseUp", "mouseDown", "mouseUp", "mouseDown", "mouseUp"])
	}

	@Test
	internal func movesInARowCountAsTheLast() throws {
		let fixture = Fixture()
		defer { fixture.window.close() }

		fixture.send(.mouseMoved, at: .init(x: 10, y: 290))
		fixture.send(.mouseMoved, at: .init(x: 20, y: 280))
		fixture.input.mouseExited(with: try #require(fixture.event(.mouseMoved, at: .zero)))
		fixture.send(.mouseMoved, at: .init(x: 30, y: 270))
		#expect(fixture.input.drain() == [.pointer(.init(x: 20, y: 20)), .leave, .pointer(.init(x: 30, y: 30))])
		#expect(!fixture.input.hasPending)

		// What a busy page didn't take goes back ahead of what came since.
		fixture.send(.mouseMoved, at: .init(x: 40, y: 260))
		fixture.input.restore([.key("Enter")])
		#expect(fixture.input.drain() == [.key("Enter"), .pointer(.init(x: 40, y: 40))])
	}

	@Test
	internal func itTakesTheKeyboardAndGivesItBack() throws {
		let fixture = Fixture()
		defer { fixture.window.close() }

		#expect(fixture.window.firstResponder === fixture.input)
		for (code, key) in [(53, "Escape"), (126, "ArrowUp"), (125, "ArrowDown"), (36, "Enter"), (76, "Enter")] {
			fixture.input.keyDown(with: try #require(fixture.key(UInt16(code))))
			#expect(fixture.input.drain() == [.key(key)])
		}

		// Other keys go nowhere: not to the picker, and not to the page.
		fixture.input.keyDown(with: try #require(fixture.key(0, characters: "a")))
		#expect(fixture.input.drain() == [])
		#expect(fixture.content.events.isEmpty)

		fixture.input.remove()
		#expect(fixture.input.superview == nil)
		#expect(fixture.window.firstResponder === fixture.content)
	}

	/// Whatever hands the keyboard to the page while the picker is open, the app focusing the
	/// page or the page itself, hands it to the picker; the rest of the window keeps it until the
	/// page is clicked.
	@Test
	internal func theKeyboardComesBackFromThePageButNotFromTheRestOfTheWindow() async throws {
		let fixture = Fixture()
		defer { fixture.window.close() }

		fixture.window.makeFirstResponder(fixture.content)
		try await Task.sleep(for: .milliseconds(50))
		#expect(fixture.window.firstResponder === fixture.input)

		fixture.window.makeFirstResponder(fixture.outside)
		try await Task.sleep(for: .milliseconds(50))
		#expect(fixture.window.firstResponder === fixture.outside)

		fixture.send(.leftMouseDown, at: .init(x: 200, y: 150))
		#expect(fixture.window.firstResponder === fixture.input)

		// A page that joins another window, as one staged under a space swipe does, doesn't take
		// that window's keyboard.
		let other = NSWindow(
			contentRect: .init(x: -10_000, y: -10_000, width: 400, height: 300),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		other.isReleasedWhenClosed = false
		defer { other.close() }
		let field = PageContent(frame: .init(x: 0, y: 0, width: 20, height: 20))
		let stage = NSView(frame: .init(x: 0, y: 0, width: 400, height: 300))
		stage.addSubview(field)
		other.contentView = stage
		other.makeFirstResponder(field)
		stage.addSubview(fixture.pageView)
		#expect(other.firstResponder === field)
		fixture.window.contentView?.addSubview(fixture.pageView)

		// Gone, it takes nothing back.
		fixture.input.remove()
		fixture.window.makeFirstResponder(fixture.content)
		try await Task.sleep(for: .milliseconds(50))
		#expect(fixture.window.firstResponder === fixture.content)
	}

	/// A page has one picker view at a time: a newer one replaces one an earlier session hasn't
	/// taken away yet and gives the keyboard back to what had it before either.
	@Test
	internal func aNewerViewReplacesAnEarlierOne() throws {
		let fixture = Fixture()
		defer { fixture.window.close() }

		let newer = ChromiumElementPickerInput.install(over: fixture.pageView)
		#expect(fixture.pageView.subviews.filter { $0 is ChromiumElementPickerInput }.count == 1)
		#expect(fixture.input.superview == nil)
		#expect(fixture.window.firstResponder === newer)

		// The earlier session's own removal comes late and changes nothing.
		fixture.input.remove()
		#expect(fixture.window.firstResponder === newer)

		newer.remove()
		#expect(fixture.window.firstResponder === fixture.content)
	}

	@Test
	internal func theWheelStillScrollsThePage() throws {
		let fixture = Fixture()
		defer { fixture.window.close() }

		let scroll = try #require(CGEvent(
			scrollWheelEvent2Source: nil,
			units: .pixel,
			wheelCount: 1,
			wheel1: -12,
			wheel2: 0,
			wheel3: 0
		).flatMap(NSEvent.init(cgEvent:)))
		fixture.input.scrollWheel(with: scroll)
		#expect(fixture.content.events == ["scrollWheel"])
		#expect(fixture.input.drain() == [.refresh])
	}

	// MARK: - Fixture

	/// The page's own view, recording what reaches it.
	@MainActor
	private final class PageContent: NSView {
		var events: [String] = []

		override var acceptsFirstResponder: Bool { true }

		override func mouseDown(with event: NSEvent) { events.append("mouseDown") }
		override func mouseUp(with event: NSEvent) { events.append("mouseUp") }
		override func rightMouseDown(with event: NSEvent) { events.append("rightMouseDown") }
		override func keyDown(with event: NSEvent) { events.append("keyDown") }
		override func scrollWheel(with event: NSEvent) { events.append("scrollWheel") }
	}

	@MainActor
	private struct Fixture {
		let window: NSWindow
		let pageView: NSView
		let content: PageContent

		/// Something else in the window, such as the sidebar.
		let outside: PageContent
		let input: ChromiumElementPickerInput

		/// Something the window draws over the page, such as Hide Element's toast, when there's one.
		let cover: PageContent?

		init(cover coverFrame: CGRect? = nil) {
			window = NSWindow(
				contentRect: .init(x: -10_000, y: -10_000, width: 400, height: 300),
				styleMask: [.borderless],
				backing: .buffered,
				defer: false
			)
			window.isReleasedWhenClosed = false
			let container = NSView(frame: .init(x: 0, y: 0, width: 400, height: 300))
			outside = PageContent(frame: .init(x: 0, y: 0, width: 20, height: 20))
			container.addSubview(outside)
			pageView = NSView(frame: container.bounds)
			content = PageContent(frame: pageView.bounds)
			pageView.addSubview(content)
			container.addSubview(pageView)
			cover = coverFrame.map { PageContent(frame: $0) }
			if let cover { container.addSubview(cover, positioned: .above, relativeTo: pageView) }
			window.contentView = container
			window.makeFirstResponder(content)
			input = ChromiumElementPickerInput.install(over: pageView)
		}

		func event(
			_ type: NSEvent.EventType,
			at point: CGPoint,
			modifiers: NSEvent.ModifierFlags = []
		) -> NSEvent? {
			NSEvent.mouseEvent(
				with: type,
				location: point,
				modifierFlags: modifiers,
				timestamp: 0,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: 0,
				clickCount: 1,
				pressure: 1
			)
		}

		/// Sends a mouse event to the view the window's hit-testing finds, as AppKit does.
		func send(
			_ type: NSEvent.EventType,
			at point: CGPoint,
			modifiers: NSEvent.ModifierFlags = []
		) {
			guard
				let event = event(type, at: point, modifiers: modifiers),
				let target = window.contentView?.hitTest(point)
			else { return }

			switch type {
			case .leftMouseDown: target.mouseDown(with: event)
			case .leftMouseUp: target.mouseUp(with: event)
			case .rightMouseDown: target.rightMouseDown(with: event)
			case .mouseMoved: target.mouseMoved(with: event)
			default: break
			}
		}

		func key(
			_ code: UInt16,
			characters: String = "",
			modifiers: NSEvent.ModifierFlags = []
		) -> NSEvent? {
			NSEvent.keyEvent(
				with: .keyDown,
				location: .zero,
				modifierFlags: modifiers,
				timestamp: 0,
				windowNumber: window.windowNumber,
				context: nil,
				characters: characters,
				charactersIgnoringModifiers: characters,
				isARepeat: false,
				keyCode: code
			)
		}
	}
}
