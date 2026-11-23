import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of the Library's filter controls (DEV-770) in every state: the Filter
/// button quiet, open and counting, choice chips plain and selected, and header chips, at rest,
/// hovered and pressed, light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct SidebarLibraryFilterSnapshotTests {
	private static let states: [(name: String, override: ArxControlStateOverride)] = [
		("normal", .init()),
		("hover", .init(isHovered: true)),
		("pressed", .init(isHovered: true, isPressed: true)),
	]

	@Test(arguments: [false, true])
	internal func states(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = VStack(alignment: .leading, spacing: 14) {
			ForEach(Self.states, id: \.name) { state in
				HStack(spacing: 10) {
					Text(verbatim: state.name)
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.frame(width: 56, alignment: .leading)
					SidebarLibraryFilterButton(title: "Filter", count: 0, isOpen: false) {}
					SidebarLibraryFilterButton(title: "Filter", count: 0, isOpen: true) {}
					SidebarLibraryFilterButton(title: "Filter", count: 2, isOpen: false) {}
					SidebarLibraryFilterButton(title: "Filter", count: 2, isOpen: false, showsTitle: false) {}
					SidebarLibraryChoiceChip("Home", isSelected: false) {}
					SidebarLibraryChoiceChip("Work", isSelected: true) {}
					SidebarLibraryFilterChip("pointfree") {}
				}
				.arxControlState(state.override)
			}
		}
		.padding(20)
		.background { BrowserChromeBackground(textured: true) }
		.fixedSize()

		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = host.appearance
		window.contentView = host
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "library-filter-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
