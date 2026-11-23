import AppKit
@testable import AppUI
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Writes DEV-1187's row motion frame by frame when `ARX_DESIGN_SNAPSHOTS` names a directory: a
/// new tab sliding in at the top of the open tabs and a closed tab collapsing out, each as a strip
/// of frames 50 ms apart (PNG) and as a 50 fps loop (GIF), in light and dark. Each frame draws the
/// row at the spring's progress for its time, as `SidebarRowReveal` lays it out in the sidebar.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: SidebarChromeSnapshot.directory != nil)
)
internal struct SidebarRowMotionSnapshotTests {
	private static let titles: [String] = [
		"Inbox (3) - Mail",
		"Arx MVP - Linear",
		"PR Flow - How a PR Gets Reviewed",
		"Swift Forums",
	]

	private static let rows: [SidebarItem] = titles.map {
		.init(id: .tab(UUID()), title: $0, isPinned: false)
	}

	private static let newTab: SidebarItem = .init(id: .tab(UUID()), title: "New Tab", isPinned: false)

	private static let size: CGSize = .init(width: 260, height: 190)

	private enum Scene: String, CaseIterable {
		/// ⌘T: the new tab slides in at the top and takes the selection.
		case opening = "sidebar-row-motion-open"

		/// The second tab closes and the rows below close up.
		case closing = "sidebar-row-motion-close"
	}

	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func frames(_ appearance: NSAppearance.Name) throws {
		let directory = try #require(SidebarChromeSnapshot.directory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let suffix: String = appearance == .darkAqua ? "dark" : "light"
		for scene in Scene.allCases {
			let stripTimes: [TimeInterval] = stride(from: 0.0, through: 0.35, by: 0.05).map { $0 }
			let strip = try stripTimes.map { try Self.frame(scene, at: $0, appearance: appearance) }
			try Self.writeStrip(strip, times: stripTimes, to: directory.appending(path: "\(scene.rawValue)-\(suffix).png"))

			// 0.4 s of motion at 50 fps, GIF's finest step that viewers play at its speed, then the
			// rest held for 0.6 s before the loop starts over.
			let loop = try (0...20).map { try Self.frame(scene, at: Double($0) / 50, appearance: appearance) }
			try Self.writeGIF(loop, to: directory.appending(path: "\(scene.rawValue)-\(suffix).gif"))
		}
	}

	private static func frame(
		_ scene: Scene,
		at time: TimeInterval,
		appearance: NSAppearance.Name
	) throws -> CGImage {
		let progress: CGFloat = SidebarRowMotion.progress(at: time)
		let view = VStack(alignment: .leading, spacing: BrowserMetrics.Row.spacing) {
			switch scene {
			case .opening:
				SidebarRow(item: newTab, selected: true, onAction: { _ in })
					.modifier(SidebarRowReveal(progress: progress))
				ForEach(rows) { SidebarRow(item: $0, onAction: { _ in }) }

			case .closing:
				SidebarRow(item: rows[0], selected: true, onAction: { _ in })
				SidebarRow(item: rows[1], onAction: { _ in })
					.modifier(SidebarRowReveal(progress: 1 - progress))
				ForEach(rows.dropFirst(2)) { SidebarRow(item: $0, onAction: { _ in }) }
			}
		}
		.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
		.padding(.top, 12)
		.frame(width: size.width, height: size.height, alignment: .top)
		.environment(\.sidebarIsStatic, true)
		.environment(\.browserAccentIsEnabled, true)

		let representation = try SidebarChromeSnapshot.render(view, size: size, appearance: appearance)
		return try #require(representation.cgImage)
	}

	/// The frames side by side, each captioned with its time.
	private static func writeStrip(
		_ frames: [CGImage],
		times: [TimeInterval],
		to url: URL
	) throws {
		let first = try #require(frames.first)
		let scale: CGFloat = CGFloat(first.width) / size.width
		let gap: CGFloat = 8
		let caption: CGFloat = 18
		let canvas: CGSize = .init(
			width: (size.width + gap) * CGFloat(frames.count) - gap,
			height: size.height + caption
		)
		let image = NSImage(size: canvas, flipped: true) { _ in
			NSColor.windowBackgroundColor.setFill()
			NSRect(origin: .zero, size: canvas).fill()
			for (index, frame) in frames.enumerated() {
				let x: CGFloat = (size.width + gap) * CGFloat(index)
				let label = "\(Int((times[index] * 1_000).rounded())) ms" as NSString
				label.draw(
					at: .init(x: x + 4, y: 2),
					withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
				)
				NSImage(cgImage: frame, size: size).draw(
					in: .init(x: x, y: caption, width: size.width, height: size.height),
					from: .zero,
					operation: .sourceOver,
					fraction: 1,
					respectFlipped: true,
					hints: nil
				)
			}
			return true
		}
		let representation = try #require(NSBitmapImageRep(
			bitmapDataPlanes: nil,
			pixelsWide: Int(canvas.width * scale),
			pixelsHigh: Int(canvas.height * scale),
			bitsPerSample: 8,
			samplesPerPixel: 4,
			hasAlpha: true,
			isPlanar: false,
			colorSpaceName: .deviceRGB,
			bytesPerRow: 0,
			bitsPerPixel: 0
		))
		representation.size = canvas
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
		image.draw(in: .init(origin: .zero, size: canvas))
		NSGraphicsContext.restoreGraphicsState()
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: url)
	}

	private static func writeGIF(
		_ frames: [CGImage],
		to url: URL
	) throws {
		let destination = try #require(CGImageDestinationCreateWithURL(
			url as CFURL,
			UTType.gif.identifier as CFString,
			frames.count,
			nil
		))
		CGImageDestinationSetProperties(destination, [
			kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
		] as CFDictionary)
		for (index, frame) in frames.enumerated() {
			let delay: Double = index == frames.count - 1 ? 0.6 : 0.02
			CGImageDestinationAddImage(destination, frame, [
				kCGImagePropertyGIFDictionary: [
					kCGImagePropertyGIFDelayTime: delay,
					kCGImagePropertyGIFUnclampedDelayTime: delay,
				],
			] as CFDictionary)
		}
		#expect(CGImageDestinationFinalize(destination))
	}
}
