import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Writes offscreen PNGs for the custom tab icon ticket (DEV-1251) when `ARX_DESIGN_SNAPSHOTS` names
/// a directory: the icon picker with its reset button, tabs and a Favorite with chosen icons, a
/// space without an icon showing the dot, and Figma's link and site-menu glyphs beside the SF
/// Symbols they replace.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct TabIconSnapshotTests {
	@Test(arguments: [false, true])
	internal func picker(dark: Bool) throws {
		try write(
			SpaceIconPicker(selection: .star, onReset: {}, onSelect: { _ in })
				.background(BrowserTheme.fill),
			name: "tab-icon-picker",
			dark: dark
		)
	}

	@Test(arguments: [false, true])
	internal func tabsAndFavorite(dark: Bool) throws {
		let view = VStack(alignment: .leading, spacing: BrowserMetrics.Row.spacing) {
			HStack {
				FavoriteTile(item: Self.item("Soup", icon: .init(emoji: "🍲")), onAction: { _ in })
				FavoriteTile(item: Self.item("Site", icon: nil), onAction: { _ in })
			}
			SidebarRow(item: Self.item("Chosen symbol", icon: .star), onAction: { _ in })
			SidebarRow(item: Self.item("Chosen emoji", icon: .init(emoji: "🦊")), selected: true, onAction: { _ in })
			SidebarRow(item: Self.item("Site icon", icon: nil), onAction: { _ in })
		}
		.frame(width: 240)
		.environment(\.sidebarIsStatic, true)
		try write(view, name: "tab-icon-rows", dark: dark)
	}

	@Test(arguments: [false, true])
	internal func spaceDot(dark: Bool) throws {
		let view = HStack(spacing: 0) {
			SidebarSpaceButton(name: "No icon", symbol: SpaceIcon.dot.rawValue, isSelected: true, onSelect: {}, onDropTabs: { _ in })
			SidebarSpaceButton(name: "Book", symbol: SpaceIcon.book.rawValue, isSelected: false, onSelect: {}, onDropTabs: { _ in })
			SidebarSpaceButton(name: "Collapsed", symbol: SpaceIcon.book.rawValue, isSelected: false, isCollapsed: true, onSelect: {}, onDropTabs: { _ in })
		}
		try write(view, name: "space-dot", dark: dark)
	}

	@Test(arguments: [false, true])
	internal func figmaSymbols(dark: Bool) throws {
		let view = HStack(spacing: 12) {
			Image(systemName: "link")
			FigmaSymbol(.link, pointSize: BrowserMetrics.PaneHeader.symbolSize)
			Image(systemName: "slider.horizontal.2.square")
			FigmaSymbol(.siteMenu, pointSize: BrowserMetrics.PaneHeader.symbolSize)
		}
		.font(.system(size: BrowserMetrics.PaneHeader.symbolSize, weight: .medium))
		.foregroundStyle(BrowserTheme.secondary)
		try write(view, name: "figma-symbols", dark: dark)
	}

	/// Figma's two glyphs and the SF Symbols they replace at the URL bar's size, each in its frame
	/// (blue) with the box its ink fills (red), drawn four times larger so the boxes read, and the
	/// two Figma glyphs at their real size as the URL bar shows them (DEV-1251). Prints each one's
	/// ink box and ink area at the real size.
	@Test(arguments: [false, true])
	internal func figmaSymbolBounds(dark: Bool) throws {
		let size: CGFloat = BrowserMetrics.URLBar.actionSymbolSize
		let glyphs: [(name: String, view: (CGFloat) -> AnyView)] = [
			("figma link", { AnyView(FigmaSymbol(.link, pointSize: $0)) }),
			("figma siteMenu", { AnyView(FigmaSymbol(.siteMenu, pointSize: $0)) }),
			("sf link", { AnyView(Image(systemName: "link").font(.system(size: $0, weight: .semibold))) }),
			("sf slider", { AnyView(Image(systemName: "slider.horizontal.2.square").font(.system(size: $0, weight: .semibold))) }),
		]
		let zoom: CGFloat = 4
		var cells: [AnyView] = []
		for glyph in glyphs {
			let ink = try Self.ink(of: glyph.view(size), scale: 8)
			print("glyph \(glyph.name): frame \(ink.frame.size) ink box \(ink.box) ink area \(ink.area) pt²")
			cells.append(AnyView(
				glyph.view(size * zoom)
					.frame(width: ink.frame.width * zoom, height: ink.frame.height * zoom)
					.overlay(alignment: .topLeading) {
						Rectangle()
							.stroke(.red, lineWidth: 1)
							.frame(width: ink.box.width * zoom, height: ink.box.height * zoom)
							.offset(x: ink.box.minX * zoom, y: ink.box.minY * zoom)
					}
					.border(.blue.opacity(0.6), width: 1)
			))
		}
		let view = VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 24) {
				ForEach(cells.indices, id: \.self) { cells[$0] }
			}
			HStack(spacing: 2) {
				FigmaSymbol(.link, pointSize: size)
					.frame(width: BrowserMetrics.URLBar.actionSize, height: BrowserMetrics.URLBar.actionSize)
				FigmaSymbol(.siteMenu, pointSize: size)
					.frame(width: BrowserMetrics.URLBar.actionSize, height: BrowserMetrics.URLBar.actionSize)
			}
		}
		.foregroundStyle(BrowserTheme.secondary)
		try write(view, name: "figma-symbol-bounds", dark: dark)
	}

	/// The frame a glyph takes, the box its ink fills and the ink's area, all in points.
	private static func ink(
		of glyph: AnyView,
		scale: CGFloat
	) throws -> (frame: CGRect, box: CGRect, area: CGFloat) {
		let renderer = ImageRenderer(content: glyph.foregroundStyle(.black))
		renderer.scale = scale
		let image = try #require(renderer.cgImage)
		let width = image.width
		let height = image.height
		var pixels = [UInt8](repeating: 0, count: width * height * 4)
		let context = try #require(CGContext(
			data: &pixels,
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: width * 4,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		))
		context.draw(image, in: .init(x: 0, y: 0, width: width, height: height))
		var minX = width
		var minY = height
		var maxX = -1
		var maxY = -1
		var alpha: CGFloat = 0
		for y in 0..<height {
			for x in 0..<width {
				let value = pixels[(y * width + x) * 4 + 3]
				guard value > 24 else { continue }
				alpha += CGFloat(value) / 255
				minX = min(minX, x)
				maxX = max(maxX, x)
				minY = min(minY, y)
				maxY = max(maxY, y)
			}
		}

		// The context's first row in memory is the image's top.
		let box: CGRect = .init(
			x: CGFloat(minX) / scale,
			y: CGFloat(minY) / scale,
			width: CGFloat(maxX - minX + 1) / scale,
			height: CGFloat(maxY - minY + 1) / scale
		)
		let frame: CGRect = .init(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
		return (frame, box, alpha / (scale * scale))
	}

	private static func item(
		_ title: String,
		icon: SpaceIcon?
	) -> SidebarItem {
		.init(id: .tab(UUID()), title: title, isPinned: false, customIcon: icon)
	}

	private func write(
		_ content: some View,
		name: String,
		dark: Bool
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = content
			.padding(12)
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
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
