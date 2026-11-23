import AppKit
import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

/// DEV-725: dragging a space in the footer picker lifts it and moves it, through the real
/// buttons. A Button tracks its own press, which used to swallow the picker's drag entirely.
@MainActor
@Suite(.renderTurn, .dependencies, .enabled(if: NativeEvents.areAvailable, "Needs a window server to deliver mouse events"))
internal struct SpacePickerDragTests {
	private static let spaces = (0..<4).map {
		SidebarSpacePickerEntry(
			id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")!,
			name: "S\($0)",
			symbol: ["star", "cloud", "airplane", "bolt"][$0]
		)
	}

	@Test
	internal func draggingASpaceMovesItAndAClickStillSelects() throws {
		let log = Log()
		let size = CGSize(width: 300, height: 60)
		let host = NSHostingView(rootView:
			SidebarSpacePicker(
				spaces: Self.spaces,
				selectedID: Self.spaces[0].id,
				canReorder: true,
				onMove: { id, before in log.moves.append(.init(id: id, before: before)) }
			) { space, state in
				SidebarSpaceButton(
					name: space.name,
					symbol: space.symbol,
					isSelected: false,
					isCollapsed: state.isCollapsed,
					width: state.width,
					nudge: state.nudge,
					onSelect: { log.selected.append(space.id) },
					onDropTabs: { _ in }
				)

				// As MainView builds them: each button anchors its icon picker and appearance panel.
				.spaceIconPicker(isPresented: .constant(false), selection: .stack) { _ in }
				.floatingPanel(isPresented: .constant(false)) { EmptyView() }
			}
			.frame(width: size.width, height: size.height, alignment: .bottom)

			// As on the window's root.
			.sidebarSpaceHintHost()
			.sidebarDragPreviewHost()
		)
		host.frame = CGRect(origin: .zero, size: size)

		// Far off every screen, and never key: nothing on the Mac changes while it runs.
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
		pump(host)

		// The second space's center, in the window's coordinates.
		let cloud: CGFloat = 131
		let row: CGFloat = 18

		// The pointer arrives first, as a real one does, so the press lands on that space.
		send(.mouseMoved, x: cloud, y: row, to: window)
		pump(host)

		// Resting long enough for the space's hint to show, as a person does before dragging.
		RunLoop.main.run(until: .now.addingTimeInterval(1.3))
		pump(host)
		let resting = try render(host)
		send(.leftMouseDown, x: cloud, y: row, to: window)
		for step in 1...24 {
			send(.leftMouseDragged, x: cloud + CGFloat(step) * 4, y: row, to: window)
			RunLoop.main.run(until: .now.addingTimeInterval(0.01))
			if step == 12 {
				pump(host)

				// The space lifts and the others make room while the button is still down.
				// They used to stay put until release, so the drag showed nothing.
				#expect(try render(host) != resting, "Nothing changed on screen mid-drag")
			}
		}
		send(.leftMouseUp, x: cloud + 96, y: row, to: window)
		pump(host)

		// Past the last space: it moves to the end.
		#expect(log.moves == [.init(id: Self.spaces[1].id, before: nil)])
		#expect(log.selected.isEmpty)

		send(.leftMouseDown, x: cloud, y: row, to: window)
		send(.leftMouseUp, x: cloud, y: row, to: window)
		pump(host)
		#expect(log.selected == [Self.spaces[1].id])
		#expect(log.moves.count == 1)
	}

	private func render(_ host: NSView) throws -> Data {
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		return try #require(representation.representation(using: .png, properties: [:]))
	}

	private func pump(_ host: NSView) {
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.03))
		}
	}

	private func send(
		_ type: NSEvent.EventType,
		x: CGFloat,
		y: CGFloat,
		to window: NSWindow
	) {
		let event = NSEvent.mouseEvent(
			with: type,
			location: CGPoint(x: x, y: y),
			modifierFlags: [],
			timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: window.windowNumber,
			context: nil,
			eventNumber: 0,
			clickCount: 1,
			pressure: type == .leftMouseUp ? 0 : 1
		)
		if let event { window.sendEvent(event) }
	}
}

@MainActor
private final class Log {
	struct Move: Equatable {
		let id: UUID
		let before: UUID?
	}

	var moves: [Move] = []
	var selected: [UUID] = []
}
