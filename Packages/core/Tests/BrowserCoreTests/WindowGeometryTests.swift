import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct WindowGeometryTests {
	@Test
	internal func legacyWindowRecordsDecodeWithoutGeometry() async throws {
		let record = BrowserWindowPresentation(id: UUID(), activeSpaceID: .init(rawValue: UUID()), spaces: [])
		let data = try JSONEncoder().encode(record)
		let decoded = try JSONDecoder().decode(BrowserWindowPresentation.self, from: data)
		expectNoDifference(decoded, record)
		#expect(decoded.geometry == nil)
	}

	@Test
	internal func frameDisplayAndFullScreenRoundTrip() async throws {
		let geometry = BrowserWindowGeometry(frame: .init(x: 1900, y: 100, width: 1000, height: 800), displayID: 42, isFullScreen: true)
		let record = BrowserWindowPresentation(id: UUID(), activeSpaceID: .init(rawValue: UUID()), spaces: [], geometry: geometry)
		let decoded = try JSONDecoder().decode(BrowserWindowPresentation.self, from: JSONEncoder().encode(record))
		expectNoDifference(decoded, record)
	}

	@Test
	internal func disconnectedDisplayMovesTheWholeWindowOntoAVisibleDisplay() async throws {
		let geometry = BrowserWindowGeometry(frame: .init(x: 2200, y: 100, width: 1000, height: 800), displayID: 42)
		let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
		let frame = try #require(geometry.restoredFrame(on: [.init(id: 1, visibleFrame: visible)], minimumSize: .init(width: 760, height: 620)))
		expectNoDifference(frame, CGRect(x: 440, y: 100, width: 1000, height: 800))
		#expect(visible.contains(frame))
	}

	@Test
	internal func changedResolutionClampsTheFrameAndInvalidGeometryIsIgnored() async throws {
		let display = BrowserWindowGeometry.Display(id: 42, visibleFrame: .init(x: -1000, y: 0, width: 1000, height: 700))
		let geometry = BrowserWindowGeometry(frame: .init(x: -2000, y: 700, width: 1500, height: 900), displayID: 42)
		expectNoDifference(geometry.restoredFrame(on: [display], minimumSize: .init(width: 760, height: 620)), display.visibleFrame)
		var invalid = geometry
		invalid.frame.origin.x = .infinity
		#expect(invalid.restoredFrame(on: [display], minimumSize: .zero) == nil)
		#expect(geometry.restoredFrame(on: [], minimumSize: .zero) == nil)
	}

	@Test
	internal func closeWindowCanBeReboundAndClosesEmptyWindows() async throws {
		var preferences = BrowserPreferences()
		expectNoDifference(preferences.shortcut(for: .closeWindow), .init(key: "w", modifiers: [.command, .shift]))
		preferences.setShortcut(.init(key: "w", modifiers: [.command, .option]), for: .closeWindow)
		try preferences.validate()
		expectNoDifference(preferences.shortcut(for: .closeWindow), .init(key: "w", modifiers: [.command, .option]))
		#expect(BrowserCommand.closeWindow.isEnabled(in: .init(host: .main)))
		#expect(!BrowserCommand.closeWindow.isEnabled(in: .init(host: .application)))
	}
}
