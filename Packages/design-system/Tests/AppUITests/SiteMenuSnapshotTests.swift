import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Writes offscreen PNGs of the URL bar's site menu (DEV-824) in light and dark when
/// `ARX_DESIGN_SNAPSHOTS` names a directory: icon-only actions, extension icons with a
/// letter-tile fallback, and permission pop-ups of one width. Little Arx's and Page PiP's menus
/// (DEV-1257) are written beside the main window's, from the same page. Since DEV-1333 also a key's
/// tooltip, switches on and off, and no extensions or more than a row of them.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct SiteMenuSnapshotTests {
	@Test(arguments: SiteMenu.Host.allCases, [false, true])
	internal func panel(
		in hostWindow: SiteMenu.Host,
		dark: Bool
	) throws {
		let name: String = switch hostWindow {
		case .mainWindow: "site-menu"
		case .littleArx: "site-menu-little-arx"
		case .pagePictureInPicture: "site-menu-page-pip"
		}
		try write(SiteMenuPanel(menu: Self.menu(hostWindow), send: { _ in }, dismiss: {}), name: name, dark: dark)
	}

	/// DEV-1333: a key's tooltip on hover, a switch's with its state, and Dark page on.
	@Test(arguments: [false, true])
	internal func tooltips(dark: Bool) throws {
		try write(SiteMenuPanel(menu: Self.menu(.mainWindow), tooltip: .capturePage), name: "site-menu-tooltip-capture-page", dark: dark)
		try write(SiteMenuPanel(menu: Self.menu(.mainWindow), tooltip: .webKit), name: "site-menu-tooltip-webkit", dark: dark)
	}

	/// DEV-1333: no extensions, and more than a row of them, on the menu's grid; and a site with its
	/// own choices, whose pop-ups show them.
	@Test(arguments: [false, true])
	internal func extensionCounts(dark: Bool) throws {
		var none = Self.menu(.mainWindow)
		none.extensions = []
		try write(SiteMenuPanel(menu: none, send: { _ in }, dismiss: {}), name: "site-menu-no-extensions", dark: dark)

		var many = Self.menu(.mainWindow)
		let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemIndigo, .systemPurple, .systemPink, .systemBrown, .systemGray]
		many.extensions = colors.enumerated().map { index, color in
			.init(id: "\(index)", name: "Extension \(index)", icon: SiteMenuIconFixture.png(color: color))
		}
		let own: [SitePermission: SitePermissionSetting] = [.camera: .allow, .notifications: .block]
		many.permissions = SitePermission.allCases.map {
			.init(permission: $0, setting: own[$0], defaultSetting: $0 == .popups ? .block : .ask)
		}
		many.unreadBadges = .init(site: .hide, inherited: .show)
		many.webKit = .init(isListed: true, isShown: true)
		many.darkPage = false
		try write(SiteMenuPanel(menu: many, send: { _ in }, dismiss: {}), name: "site-menu-many-extensions", dark: dark)
	}

	private static func menu(_ hostWindow: SiteMenu.Host) -> SiteMenu {
		SiteMenu(
			hostWindow: hostWindow,
			host: "news.ycombinator.com",
			connection: .secure,
			profileName: "Personal",
			canRead: true,
			extensions: [
				.init(id: "a", name: "Claude", icon: SiteMenuIconFixture.png(color: .systemOrange)),
				.init(id: "b", name: "Easy Reader", icon: SiteMenuIconFixture.png(color: .systemBlue)),
				.init(id: "c", name: "uBlock Origin Lite"),
			],
			permissions: SitePermission.allCases.map {
				.init(permission: $0, setting: nil, defaultSetting: $0 == .popups ? .block : .ask)
			},
			blocksContent: true,
			webKit: .init(isListed: false, isShown: false),
			darkPage: true,
			// DEV-1258: the site follows the profile, which shows badges.
			unreadBadges: .init(site: nil, inherited: .show),
			// DEV-1019: two hidden elements, one with a selector too long for the row.
			hiddenElements: [
				.init(id: "news.ycombinator.com##.pagetop", selector: ".pagetop"),
				.init(
					id: "news.ycombinator.com##table.itemlist > tbody > tr.athing:nth-of-type(3) > td.title",
					selector: "table.itemlist > tbody > tr.athing:nth-of-type(3) > td.title"
				),
			],
			translation: .init(languageName: "French", isTranslated: false),
			zoom: 1.25,
			canClearSiteData: true,
			canOpenSettings: true
		)
	}

	private func write(
		_ panel: SiteMenuPanel,
		name: String,
		dark: Bool
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = panel
			.background(Color(nsColor: .windowBackgroundColor))
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
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		host.frame.size = host.fittingSize
		window.setContentSize(host.frame.size)
		host.layoutSubtreeIfNeeded()
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}
}

@MainActor
@Suite
internal struct ExtensionIconImageTests {
	@Test
	internal func decodesManifestIcons() throws {
		let data = try #require(SiteMenuIconFixture.png(color: .systemGreen, pixels: 128))
		let image = try #require(ExtensionIconImage.decode(data))
		#expect(image.size == .init(width: 64, height: 64))
		#expect(ExtensionIconImage.image(data) === ExtensionIconImage.image(data))
	}

	@Test
	internal func refusesWhatIsNotAnImage() {
		#expect(ExtensionIconImage.decode(Data()) == nil)
		#expect(ExtensionIconImage.decode(Data("not an image".utf8)) == nil)
		#expect(ExtensionIconImage.decode(Data(count: 512 * 1024 + 1)) == nil)
	}

	@Test
	internal func fallsBackToTheFirstLetter() {
		#expect(SiteMenu.Extension(id: "a", name: "uBlock").initial == "U")
		#expect(SiteMenu.Extension(id: "a", name: "").initial == "?")
	}
}

internal enum SiteMenuIconFixture {
	/// A rounded square PNG, as a manifest icon would be.
	internal static func png(
		color: NSColor,
		pixels: Int = 32
	) -> Data? {
		guard
			let representation = NSBitmapImageRep(
				bitmapDataPlanes: nil,
				pixelsWide: pixels,
				pixelsHigh: pixels,
				bitsPerSample: 8,
				samplesPerPixel: 4,
				hasAlpha: true,
				isPlanar: false,
				colorSpaceName: .deviceRGB,
				bytesPerRow: 0,
				bitsPerPixel: 0
			)
		else { return nil }

		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
		let side = CGFloat(pixels)
		color.setFill()
		NSBezierPath(
			roundedRect: .init(x: 0, y: 0, width: side, height: side),
			xRadius: side / 4,
			yRadius: side / 4
		).fill()
		NSColor.white.setFill()
		NSBezierPath(ovalIn: .init(x: side / 4, y: side / 4, width: side / 2, height: side / 2)).fill()
		NSGraphicsContext.restoreGraphicsState()
		return representation.representation(using: .png, properties: [:])
	}
}
