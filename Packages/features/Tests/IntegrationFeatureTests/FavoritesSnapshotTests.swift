import AppKit
@testable import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

/// Writes offscreen PNGs of Favorites and its drag preview for visual self-review (DEV-736),
/// when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(.renderTurn, .dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct FavoritesSnapshotTests {
	private static let sites: [(String, String)] = [
		("YouTube", "https://www.youtube.com"),
		("GitHub", "https://github.com"),
		("Gmail", "https://mail.google.com"),
		("Figma", "https://www.figma.com"),
		("Linear", "https://linear.app"),
		("Example", "https://example.com"),
	]

	@Test(arguments: [(1, false), (2, false), (2, true), (6, false), (6, true)])
	internal func grid(count: Int, dark: Bool) throws {
		let items = (0..<count).map { Self.item($0) }
		try render(
			name: "favorites-grid-\(count)\(dark ? "-dark" : "")",
			size: .init(width: 280, height: 140),
			dark: dark
		) {
			FavoritesGrid(items: items, selectedID: items[min(1, count - 1)].id, availableHeight: 800) { _ in }
				.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
		}
	}

	@Test(arguments: [false, true])
	internal func emptyDropZone(dark: Bool) throws {
		let model = SidebarDragPreviewModel()
		model.begin(.init(item: Self.item(0), fromFavorites: false))
		try render(name: "favorites-drop-zone\(dark ? "-dark" : "")", size: .init(width: 280, height: 140), dark: dark) {
			FavoritesGrid(items: [], selectedID: nil, availableHeight: 800) { _ in }
				.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
				.environment(\.sidebarDragPreview, model)
		}
	}

	@Test(arguments: [false, true])
	internal func previews(dark: Bool) throws {
		let shapes: [SidebarDragPreviewModel.Shape] = [
			.row(width: 250),
			.tile(.init(width: 60, height: BrowserMetrics.Favorites.tileHeight)),
		]
		try render(name: "favorites-previews\(dark ? "-dark" : "")", size: .init(width: 300, height: 360), dark: dark) {
			VStack(alignment: .leading, spacing: 18) {
				ForEach(0..<4, id: \.self) { index in
					HStack(spacing: 18) {
						ForEach(Array(shapes.enumerated()), id: \.offset) { _, shape in
							let size: CGSize = switch shape {
							case let .row(width): .init(width: width - 70, height: BrowserMetrics.Row.height)
							case let .tile(size): size
							}
							SidebarDragPreviewCard(
								item: .init(item: Self.item(index), fromFavorites: false),
								shape: shape
							)
							.frame(width: size.width, height: size.height)
						}
					}
				}
				SidebarRow(
					item: SidebarItem(id: .folder(UUID(100)), title: "Automations", symbol: "folder"),
					isDropTarget: true
				) { _ in }
			}
			.padding(16)
		}
	}

	/// The Library's Spaces page: each column in its own space's appearance (DEV-736).
	@Test(arguments: [false, true])
	internal func spacesOverview(dark: Bool) throws {
		let spaces = [(UUID(1), "Personal", 120.0), (UUID(2), "Work", 20.0), (UUID(3), "Inherits", nil)].map { id, name, _ in
			SidebarSpace(id: id, name: name, favorites: [], savedItems: [], unpinnedTabs: [Self.item(0)], selectedID: nil, url: nil)
		}
		let hues: [UUID: Double] = [UUID(1): 120, UUID(2): 20]
		try render(name: "spaces-overview\(dark ? "-dark" : "")", size: .init(width: 900, height: 300), dark: dark) {
			SidebarSpacesOverview(
				spaces: spaces,
				spaceMenu: { _ in AnyView(EmptyView()) },
				appearance: { id in
					hues[id].map { AppearanceOverride(tintHue: $0, tintIntensity: 0.7) } ?? .init()
				},
				globalAppearance: .init(tint: .default, grain: .default),
				profileMenu: { _ in AnyView(EmptyView()) },
				onAction: { _, _ in },
				onChangeIcon: { _, _ in },
				onMoveSpace: { _, _ in }
			)
		}
	}

	private static func item(_ index: Int) -> SidebarItem {
		let site = sites[index % sites.count]
		return SidebarItem(
			id: .tab(UUID(index + 1)),
			title: site.0,
			siteIcon: .init(profileID: UUID(1), pageURL: URL(string: site.1)!)
		)
	}

	private func render(
		name: String,
		size: CGSize,
		dark: Bool,
		@ViewBuilder content: () -> some View
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let host = NSHostingView(
			rootView: content()
				.padding(.vertical, 16)
				.frame(width: size.width, height: size.height, alignment: .top)
				.background(BrowserChromeBackground(textured: true))

				// Glass and material don't draw offscreen; review their solid stand-ins.
				.environment(\.sidebarIsStatic, true)
		)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = CGRect(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "\(name).png"))
		window.close()
	}
}
