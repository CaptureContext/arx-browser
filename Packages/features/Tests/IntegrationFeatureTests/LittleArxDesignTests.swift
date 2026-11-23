import AppKit
import BrowserCore
import CustomDump
import Foundation
import LittleArxFeature
import SwiftUI
import Testing
import _ComposableArchitecture

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct LittleArxDesignTests {
	private let visible = NSRect(x: 0, y: 25, width: 1000, height: 700)
	private let size = NSSize(width: 500, height: 100)

	@Test(arguments: [
		(LittleArxLauncherPosition.topRight, NSPoint(x: 488, y: 613)),
		(.topLeft, NSPoint(x: 12, y: 613)),
		(.topCenter, NSPoint(x: 250, y: 613)),
		(.center, NSPoint(x: 250, y: 375)),
	])
	internal func theBarOpensWhereTheSettingSays(
		position: LittleArxLauncherPosition,
		origin: NSPoint
	) {
		let frame = LittleArxPanel.launcherFrame(position: position, size: size, visible: visible)
		expectNoDifference(frame.origin, origin)
		#expect(visible.contains(frame))
	}

	// MARK: - Dragging the launcher bar (DEV-1335)

	@Test(arguments: [
		// Inside: unchanged.
		(NSRect(x: 100, y: 300, width: 500, height: 100), NSRect(x: 100, y: 300, width: 500, height: 100)),
		// Past the right and top edges: back inside, the least way.
		(NSRect(x: 800, y: 680, width: 500, height: 100), NSRect(x: 500, y: 625, width: 500, height: 100)),
		// Past the left and bottom edges.
		(NSRect(x: -60, y: -40, width: 500, height: 100), NSRect(x: 0, y: 25, width: 500, height: 100)),
		// Taller than the screen: its top stays inside.
		(NSRect(x: 100, y: 10, width: 500, height: 900), NSRect(x: 100, y: -175, width: 500, height: 900)),
	])
	internal func aDraggedBarStaysOnScreen(frame: NSRect, expected: NSRect) {
		expectNoDifference(LittleArxPanel.launcherFrameOnScreen(frame, visible: visible), expected)
	}

	/// The bar stays where it was dragged while it's open; the next one opens at the default place.
	@Test
	internal func aNewBarOpensAtTheDefaultPlaceAfterTheLastOneWasDragged() throws {
		let first = LittleArxPanel(commandOnly: true, launcherPosition: .topRight)
		let opened = first.frame
		let visible = try #require(first.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
		let moved = NSPoint(x: visible.minX + 40, y: visible.minY + 40)
		first.setFrameOrigin(moved)
		NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: first)
		RunLoop.main.run(until: .now.addingTimeInterval(0.05))

		// Where it was put, while open: its height changes keep the spot.
		expectNoDifference(first.frame.origin.x, moved.x)
		first.fitCommandBar(height: 300)
		expectNoDifference(first.frame.minX, moved.x)
		first.close()

		let second = LittleArxPanel(commandOnly: true, launcherPosition: .topRight)
		expectNoDifference(second.frame, opened)
		second.close()
	}

	/// A Little Arx showing a page moves as before: nothing pulls it back on screen (DEV-1335).
	@Test
	internal func aPageWindowIsntPulledBackOnScreen() throws {
		let window = LittleArxPanel(commandOnly: false)
		let visible = try #require(window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
		let offScreen = NSPoint(x: visible.maxX - 100, y: visible.minY + 40)
		window.setFrameOrigin(offScreen)
		NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
		RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		expectNoDifference(window.frame.origin, offScreen)
		window.close()
	}

	@Test
	internal func thePanelTakesTheKeyboardWithoutActivatingArx() {
		for commandOnly in [true, false] {
			let panel = LittleArxPanel(commandOnly: commandOnly)
			#expect(panel.styleMask.contains(.nonactivatingPanel))
			#expect(panel.canBecomeKey)
			// The bar opens on the Space the person is on; the window stays on its own (DEV-1227).
			#expect(panel.collectionBehavior.contains(.moveToActiveSpace) == commandOnly)
			#expect(panel.collectionBehavior.contains(.managed) == !commandOnly)
			#expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
		}

		let panel = LittleArxPanel(commandOnly: true)
		panel.updatePresentation(commandOnly: false)
		#expect(panel.styleMask.contains(.nonactivatingPanel))
	}

	@Test
	internal func aBarInTheCornerExpandsToAWindowOnScreen() throws {
		let panel = LittleArxPanel(commandOnly: true, launcherPosition: .topRight)
		let available = try #require(panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)

		panel.updatePresentation(commandOnly: false)

		#expect(panel.frame.maxX <= available.maxX)
		#expect(panel.frame.minX >= available.minX)
	}

	@Test
	internal func searchMatchesTheSpaceAndItsProfile() {
		let destination = LittleArxView.Destination(
			id: .init(rawValue: UUID()),
			profileID: .init(rawValue: UUID()),
			name: "Jobs",
			menuTitle: "Personal · Jobs"
		)

		#expect(destination.matches(""))
		#expect(destination.matches("  "))
		#expect(destination.matches("job"))
		#expect(destination.matches("PERSONAL"))
		#expect(!destination.matches("shops"))
	}

	@Test
	internal func olderPreferencesOpenTheBarTopRight() throws {
		var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserPreferences())) as? [String: Any])
		object.removeValue(forKey: "littleArxLauncherPosition")

		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONSerialization.data(withJSONObject: object))

		expectNoDifference(decoded.littleArxLauncherPosition, .topRight)
	}

	/// Preferences saved before the Runway had a choice of looks, or with a look this build
	/// doesn't know, show the regular Runway and keep every other preference.
	@Test(arguments: [nil, "minimal"])
	internal func olderPreferencesShowTheRegularRunway(saved: String?) throws {
		var preferences = BrowserPreferences()
		preferences.littleArxLauncherPosition = .center
		var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
		object["runwayAppearance"] = saved

		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONSerialization.data(withJSONObject: object))

		expectNoDifference(decoded.runwayAppearance, .regular)
		expectNoDifference(decoded.littleArxLauncherPosition, .center)
	}
}
