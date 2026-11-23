import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// DEV-1225's reset feedback with Reduce Motion: a tint the row shows instead of shaking.
@MainActor
@Suite(.renderTurn)
internal struct SidebarResetShakeTests {
	private static let first: SidebarItem = .init(
		id: .tab(UUID(uuidString: "00000000-0000-0000-0000-000000000031")!),
		title: "Linear"
	)
	private static let second: SidebarItem = .init(
		id: .tab(UUID(uuidString: "00000000-0000-0000-0000-000000000032")!),
		title: "GitHub"
	)

	/// A selected Split View row paints an opaque fill: the tint must still show over it, as it
	/// does on a plain row.
	@Test(arguments: [true, false])
	internal func theReduceMotionTintShowsOverTheRow(isSplit: Bool) throws {
		let plain: NSBitmapImageRep = try bitmap(row(isSplit: isSplit, highlight: 0, reduceMotion: true))
		let tinted: NSBitmapImageRep = try bitmap(row(isSplit: isSplit, highlight: 0.22, reduceMotion: true))

		// Over the row it shifts the colors by about 24 of 255; under a selected row's fill, by
		// next to nothing.
		#expect(meanChange(from: plain, to: tinted) > 5)
	}

	/// Without Reduce Motion the row shakes and never tints.
	@Test
	internal func theShakeDoesntTint() throws {
		let plain: NSBitmapImageRep = try bitmap(row(isSplit: true, highlight: 0, reduceMotion: false))
		let midShake: NSBitmapImageRep = try bitmap(row(isSplit: true, highlight: 0.22, reduceMotion: false))
		#expect(meanChange(from: plain, to: midShake) == 0)
	}

	private func row(
		isSplit: Bool,
		highlight: Double,
		reduceMotion: Bool
	) -> some View {
		let content: AnyView = isSplit
		? AnyView(SplitSidebarRow(
			item: Self.first,
			split: .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000033")!, members: [Self.first, Self.second]),
			selected: true,
			onAction: { _ in }
		))
		: AnyView(SidebarRow(item: Self.second, selected: true, onAction: { _ in }))
		return content
			.modifier(SidebarResetFrame(offset: 0, highlight: highlight, reduceMotion: reduceMotion))
			.tint(.blue)
	}

	/// The pixels of `view` hosted in a window as the sidebar is.
	/// The mean change of every pixel's red, green and blue, from 0 to 255.
	private func meanChange(
		from old: NSBitmapImageRep,
		to new: NSBitmapImageRep
	) -> Double {
		guard old.pixelsWide == new.pixelsWide, old.pixelsHigh == new.pixelsHigh else { return .infinity }

		var total: Double = 0
		for y in 0..<old.pixelsHigh {
			for x in 0..<old.pixelsWide {
				guard
					let a = old.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
					let b = new.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
				else { continue }
				total += abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
					+ abs(a.blueComponent - b.blueComponent)
			}
		}
		return total * 255 / 3 / Double(old.pixelsWide * old.pixelsHigh)
	}

	private func bitmap(_ view: some View) throws -> NSBitmapImageRep {
		let host = NSHostingView(
			rootView: view
				.frame(width: 300)
				.background(Color.black)
				.transaction { $0.disablesAnimations = true }
		)
		host.appearance = NSAppearance(named: .darkAqua)
		host.frame = .init(origin: .zero, size: .init(width: 300, height: max(host.fittingSize.height, 40)))
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = host.appearance
		window.contentView = host
		defer {
			window.contentView = nil
			window.close()
		}
		for _ in 0..<3 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.03))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		return representation
	}
}
