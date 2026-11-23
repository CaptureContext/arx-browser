import AppKit
import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

@MainActor
internal struct ChromeTintTests {
	private static let tints: [(name: String, tint: ChromeTint)] = [
		("neutral", .init(intensity: 0)),
		("default", .default),
		("vibrant", .init(intensity: 1)),
	]

	/// The default tint must look exactly like the asset colors it replaced.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func defaultTintMatchesTheShippedAssets(_ appearance: NSAppearance.Name) throws {
		let isDark = appearance == .darkAqua
		let resources: [(ChromePalette.Surface, _ColorResource, _ColorResource)] = [
			(.sidebar, .browser.sidebarTop, .browser.sidebarBottom),
			(.page, .browser.pageTop, .browser.pageBottom),
		]
		for (surface, top, bottom) in resources {
			let palette = ChromePalette(tint: .default, surface: surface, isDark: isDark)
			try expectEqual(palette.top, resolved(top, appearance: appearance))
			try expectEqual(palette.bottom, resolved(bottom, appearance: appearance))
		}
	}

	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func tintsRenderDistinctly(_ appearance: NSAppearance.Name) throws {
		var images: Set<Data> = []
		for (name, tint) in Self.tints {
			let representation = try render(
				ChromeTintSample(tint: tint),
				size: Self.sampleSize,
				appearance: appearance
			)
			images.insert(try #require(representation.tiffRepresentation))
			try write(representation, name: "chrome-tint-\(name)", appearance: appearance)
		}
		#expect(images.count == Self.tints.count)
	}

	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func spaceEditorRenders(_ appearance: NSAppearance.Name) throws {
		let editor = SpaceThemeEditor(
			choices: .init(tintHue: 130),
			inherited: .default,
			onCommit: { _ in },
			onClear: {}
		)
		.frame(width: SpaceThemeEditor.width)
		.padding(14)
		.background(.regularMaterial)
		let representation = try render(editor, size: .init(width: 328, height: 520), appearance: appearance)
		try write(representation, name: "chrome-appearance-editor", appearance: appearance)
	}

	private static let sampleSize = CGSize(width: 320, height: 200)

	private func expectEqual(
		_ rgb: ChromePalette.RGB,
		_ color: NSColor
	) {
		#expect(abs(rgb.red - color.redComponent) < 0.5 / 255)
		#expect(abs(rgb.green - color.greenComponent) < 0.5 / 255)
		#expect(abs(rgb.blue - color.blueComponent) < 0.5 / 255)
	}

	private func resolved(
		_ resource: _ColorResource,
		appearance name: NSAppearance.Name
	) throws -> NSColor {
		let appearance = try #require(NSAppearance(named: name))
		var color: NSColor?
		appearance.performAsCurrentDrawingAppearance {
			color = NSColor.resource(resource)?.usingColorSpace(.sRGB)
		}
		return try #require(color)
	}

	/// Writes a PNG for visual review when `ARX_DESIGN_SNAPSHOTS` names a directory.
	private func write(
		_ representation: NSBitmapImageRep,
		name: String,
		appearance: NSAppearance.Name
	) throws {
		guard let path = ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] else { return }
		let directory = URL(fileURLWithPath: path, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		let suffix = appearance == .darkAqua ? "dark" : "light"
		try data.write(to: directory.appending(path: "\(name)-\(suffix).png"))
	}

	private func render(
		_ view: some View,
		size: CGSize,
		appearance name: NSAppearance.Name
	) throws -> NSBitmapImageRep {
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: name)

		let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
		host.safeAreaRegions = []
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host

		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}

		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		window.close()
		return representation
	}
}

/// The chrome with the fills drawn over it: a hovered row, a selected row, and the page card's hairline.
private struct ChromeTintSample: View {
	fileprivate let tint: ChromeTint

	fileprivate var body: some View {
		HStack(spacing: 10) {
			VStack(alignment: .leading, spacing: 4) {
				row("Selected", fill: BrowserTheme.selection)
				row("Hovered", fill: BrowserTheme.hover)
				row("Resting", fill: .clear)
				Spacer()
			}
			.frame(width: 130)
			Color.clear
				.browserPageCard()
		}
		.padding(10)
		.background { BrowserChromeBackground(textured: true) }
		.browserChromeAppearance(.init(tint: tint, grain: .init(isEnabled: false)))
	}

	private func row(
		_ title: String,
		fill: Color
	) -> some View {
		Text(title)
			.font(.system(size: 13))
			.foregroundStyle(BrowserTheme.text)
			.padding(.horizontal, 8)
			.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
			.background(fill, in: .rect(cornerRadius: 6, style: .continuous))
	}
}
