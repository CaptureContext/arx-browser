import AppKit
@testable import AppUI
import Foundation
import SwiftUI
import Testing

/// DEV-736: Favorites always fit the width the sidebar gives them.
@Suite(.renderTurn, .dependencies)
@MainActor
internal struct FavoritesGridWidthTests {
	/// The sidebar narrowing, as after a resize or closing the Library, used to leave the grid
	/// at its old width: it sized itself to tiles laid out for the width it measured last.
	@Test(arguments: [(400.0, 250.0), (480.0, 240.0), (250.0, 400.0)])
	internal func theGridFollowsTheSidebarWhenItNarrowsOrWidens(
		from first: CGFloat,
		to second: CGFloat
	) throws {
		let probe = WidthProbe()
		let items = (0..<4).map { SidebarItem(id: .tab(UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")!), title: "\($0)") }
		let host = NSHostingView(rootView: ProbedGrid(items: items, probe: probe))
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: .init(width: first, height: 200)),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		defer { window.close() }

		settle(host, width: first)
		#expect(probe.width == first)

		settle(host, width: second)
		#expect(probe.width == second)
	}

	/// Five favorites lay out two rows, and the grid is exactly that tall: the space header below
	/// it is never covered, and nothing scrolls.
	@Test(arguments: [4, 5, 9])
	internal func theGridIsAsTallAsItsRows(count: Int) throws {
		let probe = WidthProbe()
		let items = (0..<count).map { SidebarItem(id: .tab(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!), title: "\($0)") }
		let host = NSHostingView(rootView: ProbedGrid(items: items, probe: probe))
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: .init(width: 264, height: 400)),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		defer { window.close() }
		settle(host, width: 264)
		let rows = CGFloat((count + 3) / 4)
		#expect(probe.height == rows * FavoritesGridLayout.tileHeight + (rows - 1) * FavoritesGridLayout.spacing)
	}

	private func settle(
		_ host: NSView,
		width: CGFloat
	) {
		host.frame = CGRect(x: 0, y: 0, width: width, height: 200)
		for _ in 0..<8 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.03))
		}
	}
}

@MainActor
private final class WidthProbe {
	var width: CGFloat = 0
	var height: CGFloat = 0
}

private struct ProbedGrid: View {
	let items: [SidebarItem]
	let probe: WidthProbe

	var body: some View {
		FavoritesGrid(items: items, selectedID: nil, availableHeight: 800) { _ in }
			.onGeometryChange(for: CGSize.self) { $0.size } action: {
				probe.width = $0.width
				probe.height = $0.height
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
	}
}
