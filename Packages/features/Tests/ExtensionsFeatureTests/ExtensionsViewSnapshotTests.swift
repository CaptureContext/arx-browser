import AppKit
import BrowserCore
import BrowserExtensionsClient
import ExtensionsFeature
import Foundation
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

/// Writes offscreen PNGs of Settings' extension list in light and dark when
/// `ARX_DESIGN_SNAPSHOTS` names a directory: each extension's icon on its row and in the
/// details, with a letter for one that has none, and a component's icon from its bytes.
@MainActor
@Suite(.dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct ExtensionsViewSnapshotTests {
	@Test(arguments: [false, true])
	internal func list(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let profile = Profile(id: .init(rawValue: UUID(1)), name: "Personal")
		let extensions: [(name: String, color: NSColor?)] = [
			("Claude", .systemOrange),
			("Easy Reader", .systemBlue),
			("Grammar Helper", .systemGreen),
			("Raindrop", nil),
			("uBlock Origin Lite", .systemRed),
		]
		var state = ExtensionsFeature.State(profile: profile, isAvailable: true)
		state.isPresented = true
		state.inventory = .init(
			id: UUID(10),
			profileID: profile.id,
			revision: 1,
			extensions: extensions.enumerated().map { index, item in
				.init(
					id: String(repeating: Character(UnicodeScalar(UInt8(97 + index))), count: 32),
					name: item.name,
					version: "1.\(index)",
					state: .enabled,
					iconPath: item.color.map { _ in "/fixture/\(index)/32.png" },
					// A component brings its icon's bytes: its files live in the engine.
					bundledIcon: item.name.hasPrefix("uBlock") ? item.color.flatMap { Self.png(color: $0) } : nil
				)
			}
		)
		for (index, item) in extensions.enumerated() {
			if let color = item.color, !item.name.hasPrefix("uBlock"), let icon = Self.png(color: color) {
				state.icons["/fixture/\(index)/32.png"] = icon
			}
		}
		state.selectedID = state.inventory?.extensions.last?.id

		let store = Store(initialState: state) { ExtensionsFeature() }
		let view = ExtensionsView(store: store)
			.environment(\.locale, Locale(identifier: "en_US"))
			.background(Color(nsColor: .windowBackgroundColor))

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
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "settings-extensions-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// A 64-pixel rounded square with a white dot, as a manifest icon would be.
	private static func png(color: NSColor) -> Data? {
		let pixels = 64
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
		let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
		color.setFill()
		NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
		NSColor.white.setFill()
		NSBezierPath(ovalIn: bounds.insetBy(dx: 20, dy: 20)).fill()
		NSGraphicsContext.restoreGraphicsState()

		return representation.representation(using: .png, properties: [:])
	}
}
