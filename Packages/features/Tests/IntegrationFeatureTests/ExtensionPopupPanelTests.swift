import AppKit
import AppUI
import SwiftUI
import BrowserEngineClient
import Testing

@testable import AppFeature

/// DEV-1316: an extension's popup window, as the app gives it to the engine.
@MainActor
@Suite
internal struct ExtensionPopupPanelTests {
	/// It stays open when it loses focus (Max's reference).
	@Test
	internal func itStaysOpenWhenItLosesFocus() {
		#expect(ExtensionPopupPanel.closing == .staysOpen)
		#expect(ExtensionPopupPanel.windows.closing == .staysOpen)
	}

	/// The page fills the window under the header, at the size the engine asks for.
	@Test
	internal func thePageIsTheSizeTheEngineAsksFor() throws {
		let page = NSView()
		let window = try #require(
			ExtensionPopupPanel.windows.makeWindow(page, "Fixture", nil, CGSize(width: 320, height: 180))
		)
		defer { window.close() }

		#expect(page.window === window)
		#expect(page.frame.size == CGSize(width: 320, height: 180))
		#expect(window.contentView?.frame.size == CGSize(width: 320, height: 180 + ExtensionPopupPanel.headerHeight))
		#expect(window.title == "Fixture")
		#expect(window.canBecomeKey)
		#expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
	}

	/// A resize keeps the window's top-left corner, and the page follows.
	@Test
	internal func aResizeKeepsTheTopLeftCorner() throws {
		let page = NSView()
		let window = try #require(
			ExtensionPopupPanel.windows.makeWindow(page, "Fixture", nil, CGSize(width: 320, height: 180))
		)
		defer { window.close() }
		window.setFrameTopLeftPoint(NSPoint(x: 200, y: 700))

		ExtensionPopupPanel.windows.resizeWindow(window, CGSize(width: 400, height: 300))

		#expect(window.frame.minX == 200)
		#expect(window.frame.maxY == 700)
		#expect(page.frame.size == CGSize(width: 400, height: 300))
	}

	/// While its window shows the command bar, it fades out and lets clicks through, so it covers
	/// nothing; then it comes back.
	@Test
	internal func itStepsAsideForItsWindowsCommandBar() {
		let panel = ExtensionPopupPanel(page: NSView(), title: "Fixture", icon: nil, size: CGSize(width: 320, height: 180))
		defer { panel.close() }

		panel.stepsAside = true
		#expect(panel.isSteppedAside)
		#expect(panel.alphaValue == 0)
		#expect(panel.ignoresMouseEvents)

		panel.stepsAside = false
		#expect(!panel.isSteppedAside)
		#expect(panel.alphaValue == 1)
		#expect(!panel.ignoresMouseEvents)
	}

	/// The header shows the extension's own icon between Close and its name, as its site menu tile
	/// draws it, and the tile's letter when it has none (Max, DEV-1316).
	@Test(arguments: [true, false])
	internal func theHeaderShowsTheExtensionsIconOrItsLetter(hasIcon: Bool) throws {
		let icon = hasIcon ? try Self.iconPNG() : nil
		if let icon { #expect(ExtensionIconImage.decode(icon) != nil) }
		#expect(ExtensionIconImage.initial("Fixture") == "F")

		let window = try #require(
			ExtensionPopupPanel.windows.makeWindow(NSView(), "Fixture", icon, CGSize(width: 320, height: 180))
		)
		defer { window.close() }
		let header = try #require(window.contentView?.subviews.compactMap { $0 as? NSHostingView<ExtensionPopupHeader> }.first)
		#expect(header.rootView.title == "Fixture")
		#expect(header.rootView.icon == icon)
		#expect(header.frame.height == ExtensionPopupPanel.headerHeight)

		// It lays out: Close, the icon tile and the name fit one row.
		header.layoutSubtreeIfNeeded()
		#expect(header.fittingSize.height <= ExtensionPopupPanel.headerHeight)
	}

	/// Max's first look (DEV-1316): the header's row sat low in its band, the Close tile touching
	/// the page. Rendered in the real window, the row's drawn pixels are centred in the 56-point
	/// band, and the page starts right under it, light and dark, and after the page resizes.
	@Test(arguments: [false, true], [false, true])
	internal func theHeaderRowIsCentredAndThePageStartsUnderIt(dark: Bool, resized: Bool) throws {
		let page = NSView()
		let window = try #require(
			ExtensionPopupPanel.windows.makeWindow(page, "Fixture", nil, CGSize(width: 320, height: 180))
				as? ExtensionPopupPanel
		)
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
		window.orderFrontRegardless()
		defer { window.close() }
		if resized { window.resize(page: CGSize(width: 380, height: 240)) }
		let content = try #require(window.contentView)
		for _ in 0..<8 {
			content.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}

		let header = ExtensionPopupPanel.headerHeight
		#expect(header == 56)
		#expect(abs(page.frame.maxY - (content.bounds.height - header)) < 0.5)
		#expect(abs(content.bounds.height - (page.frame.height + header)) < 0.5)

		let row = try #require(Self.drawnRows(in: content, band: header))
		let middle = (row.top + row.bottom) / 2
		#expect(abs(middle - header / 2) <= 2, "row \(row.top)...\(row.bottom) in a \(header)-point band")
		#expect(row.bottom <= header - 6, "the row reaches \(row.bottom), the page starts at \(header)")
	}

	/// The top and bottom, in points from the window's top, of what the header draws over its
	/// background in its left part: the Close tile, the icon and the title.
	internal static func drawnRows(in view: NSView, band: CGFloat) -> (top: CGFloat, bottom: CGFloat)? {
		guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }

		view.cacheDisplay(in: view.bounds, to: bitmap)
		let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
		let bandPixels = Int(band * scale)
		let width = Int(CGFloat(bitmap.pixelsWide) * 0.6)
		guard let background = bitmap.colorAt(x: bitmap.pixelsWide - 4, y: 4)?.usingColorSpace(.deviceRGB)
		else { return nil }

		func differs(_ x: Int, _ y: Int) -> Bool {
			guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }

			let distance = abs(color.redComponent - background.redComponent)
				+ abs(color.greenComponent - background.greenComponent)
				+ abs(color.blueComponent - background.blueComponent)
			return distance > 0.25
		}

		let rows = (0..<bandPixels).filter { y in (0..<width).contains { x in differs(x, y) } }
		guard let first = rows.first, let last = rows.last else { return nil }

		return (CGFloat(first) / scale, CGFloat(last + 1) / scale)
	}

	/// A 64-pixel PNG standing in for an extension's icon.
	internal static func iconPNG() throws -> Data {
		let representation = try #require(NSBitmapImageRep(
			bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
			hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
		))
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
		NSColor.systemTeal.setFill()
		NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 56, height: 56), xRadius: 14, yRadius: 14).fill()
		NSColor.white.setFill()
		NSBezierPath(ovalIn: NSRect(x: 20, y: 20, width: 24, height: 24)).fill()
		NSGraphicsContext.restoreGraphicsState()
		return try #require(representation.representation(using: .png, properties: [:]))
	}
}

/// Writes offscreen PNGs of the popup window's header, with an icon and with the letter, light
/// and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory (DEV-1316).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct ExtensionPopupHeaderSnapshotTests {
	@Test(arguments: [false, true], [false, true])
	internal func header(dark: Bool, hasIcon: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let icon = hasIcon ? try ExtensionPopupPanelTests.iconPNG() : nil
		let window = try #require(
			ExtensionPopupPanel.windows.makeWindow(NSView(), "Fixture Extension", icon, CGSize(width: 320, height: 120))
		)
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
		window.orderFrontRegardless()
		defer { window.close() }
		let content = try #require(window.contentView)
		for _ in 0..<8 {
			content.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
		content.cacheDisplay(in: content.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		let name = "extension-popup-header-\(hasIcon ? "icon" : "letter")-\(dark ? "dark" : "light").png"
		try data.write(to: directory.appending(path: name))
	}
}
