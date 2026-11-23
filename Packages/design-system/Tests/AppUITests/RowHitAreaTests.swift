@testable import AppUI
import AppKit
import Foundation
import SwiftUI
import Testing

/// DEV-1002: a click in a row's empty space, far right of its text, selects the row.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: CGSessionCopyCurrentDictionary() != nil, "Needs a window server to deliver mouse events")
)
internal struct RowHitAreaTests {
	private static let size: CGSize = .init(width: 300, height: 44)

	/// Well right of the short title, in the row's empty space.
	private static let emptySpace: CGPoint = .init(x: 280, y: 22)

	/// The control: a plain button's empty space took no click, which is what Extensions had.
	@Test
	internal func aPlainRowMissesAClickInItsEmptySpace() async throws {
		let clicks = ClickLog()
		let host = ClickHost(
			Button { clicks.count += 1 } label: {
				Text(verbatim: "uBlock")
					.padding(10)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.buttonStyle(.plain),
			size: Self.size
		)
		defer { host.close() }

		host.click(at: Self.emptySpace)
		#expect(clicks.count == 0)
		host.click(at: .init(x: 20, y: 22))
		#expect(clicks.count == 1)
	}

	@Test(arguments: [false, true])
	internal func aListRowTakesAClickInItsEmptySpace(isSelected: Bool) async throws {
		let clicks = ClickLog()
		let host = ClickHost(
			Button { clicks.count += 1 } label: {
				Text(verbatim: "uBlock").padding(10)
			}
			.buttonStyle(.arxListRow(isSelected: isSelected)),
			size: Self.size
		)
		defer { host.close() }

		host.click(at: Self.emptySpace)
		#expect(clicks.count == 1)
	}

	@Test
	internal func aSettingsRowTakesAClickInItsEmptySpace() async throws {
		let clicks = ClickLog()
		let host = ClickHost(
			Button { clicks.count += 1 } label: {
				HStack {
					Text(verbatim: "Work")
					Spacer()
				}
				.settingsGroupRow()
			}
			.buttonStyle(.settingsGroupRow),
			size: Self.size
		)
		defer { host.close() }

		host.click(at: Self.emptySpace)
		#expect(clicks.count == 1)
	}

	@Test
	internal func rowHitAreaTakesATapInItsEmptySpace() async throws {
		let clicks = ClickLog()
		let host = ClickHost(
			Text(verbatim: "Space › Folder")
				.rowHitArea()
				.onTapGesture { clicks.count += 1 },
			size: Self.size
		)
		defer { host.close() }

		host.click(at: Self.emptySpace)
		#expect(clicks.count == 1)
	}
}

@MainActor
private final class ClickLog {
	var count: Int = 0
}

/// A view in a borderless window far off every screen, which never becomes key.
@MainActor
private final class ClickHost {
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

	/// A click at `point` in the view, from its bottom-left corner as AppKit counts.
	internal func click(at point: CGPoint) {
		for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
			let event = NSEvent.mouseEvent(
				with: type,
				location: point,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: 0,
				clickCount: type == .mouseMoved ? 0 : 1,
				pressure: type == .leftMouseDown ? 1 : 0
			)
			if let event { NSApp.sendEvent(event) }
		}
		settle()
	}

	internal func close() {
		window.close()
	}

	private func settle() {
		for _ in 0..<3 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.03))
		}
	}
}
