import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Hide Element's toast keeps clear of the outlined element (DEV-1298).
@Suite
internal struct HideElementToastPlacementTests {
	private let page: CGSize = .init(width: 1000, height: 700)
	private let toast: CGSize = .init(width: HideElementToast.Metrics.width, height: 48)

	@Test
	internal func itSitsAtTheBottomRightWhileTheOutlineIsElsewhere() {
		#expect(HideElementToastPlacement.resolve(target: nil, toast: toast, page: page) == .trailing)
		let top = CGRect(x: 600, y: 40, width: 300, height: 200)
		#expect(HideElementToastPlacement.resolve(target: top, toast: toast, page: page) == .trailing)
	}

	@Test
	internal func itMovesToTheBottomLeftWhenTheOutlineComesNear() {
		// Just above the toast, within its clearance.
		let near = CGRect(x: 700, y: 560, width: 200, height: 70)
		#expect(HideElementToastPlacement.resolve(target: near, toast: toast, page: page) == .leading)
		// It stays there while that's clear, even once the outline leaves the right.
		let elsewhere = CGRect(x: 500, y: 100, width: 100, height: 100)
		#expect(HideElementToastPlacement.resolve(target: elsewhere, toast: toast, page: page, current: .leading) == .leading)
	}

	@Test
	internal func itFadesWhenTheOutlineCoversBothCorners() {
		let footer = CGRect(x: 0, y: 600, width: 1000, height: 100)
		#expect(HideElementToastPlacement.resolve(target: footer, toast: toast, page: page) == .faded)
		// And comes back once nothing's outlined.
		#expect(HideElementToastPlacement.resolve(target: nil, toast: toast, page: page, current: .faded) == .trailing)
	}
}

/// Offscreen PNGs of Hide Element's mode (DEV-1298) for visual self-review, when
/// `ARX_DESIGN_SNAPSHOTS` names a directory: a page with an element outlined in the mode's red,
/// the scope pointer over it, and the toast at the bottom right, collapsed and expanded, on a
/// light and a dark page; and the pointer alone, enlarged. Offscreen renders can't draw Liquid
/// Glass, so these show its material fallback.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct HideElementToastSnapshotTests {
	@Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
	internal func mode(dark: Bool, expanded: Bool) throws {
		let size: CGSize = .init(width: 900, height: 560)
		let target = CGRect(x: 40, y: 188, width: 520, height: 120)
		let view = ZStack(alignment: .topLeading) {
			FakePage(dark: dark, target: target)
			Outline(target: target, dark: dark, label: "Recommended for you")
			Image(nsImage: NSCursor.hideElement.image)
				.offset(x: target.midX + 60 - HideElementCursorLayout.hotSpot.x, y: target.midY - HideElementCursorLayout.hotSpot.y)
		}
		.frame(width: size.width, height: size.height, alignment: .topLeading)
		.overlay(alignment: .bottomTrailing) {
			HideElementToast(
				site: "news.example",
				entries: Self.entries,
				isExpanded: expanded,
				selection: expanded ? Self.entries[1].id : nil,
				canUndo: true,
				undo: {},
				done: {},
				toggle: {},
				show: { _ in }
			)
			.padding(HideElementToast.Metrics.edgeInset)
		}
		.environment(\.sidebarIsStatic, true)

		try write(view, size: size, dark: dark, name: "hide-element-toast-\(expanded ? "expanded" : "collapsed")-\(dark ? "dark" : "light")")
	}

	/// DEV-1315, as reported: the pointer over the toast, with the page's text running under it.
	/// Before, the picker outlined what lay under the toast (here the page's whole column, as on
	/// the reported page), so the toast faded to 30 % and the scope pointer stayed on it; or, for
	/// a smaller element, moved to the bottom left from under the click. After, the pointer over
	/// it has left the page: nothing's outlined, the pointer is the arrow, and the toast holds
	/// still, solid.
	@Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
	internal func pointerOverTheToast(dark: Bool, expanded: Bool) throws {
		for fixed in [false, true] {
			let size: CGSize = .init(width: 900, height: 560)
			let column = CGRect(x: 4, y: 4, width: size.width - 8, height: size.height - 8)
			let toastSize: CGSize = .init(width: HideElementToast.Metrics.width, height: expanded ? 200 : 48)
			let placement = HideElementToastPlacement.resolve(target: column, toast: toastSize, page: size, isPointerOver: fixed)

			// `main`'s faded opacity, for the before.
			let opacity = placement == .faded ? (fixed ? HideElementToast.Metrics.fadedOpacity : 0.3) : 1
			let cursor = fixed ? NSCursor.arrow.image : NSCursor.hideElement.image
			let pointer = CGPoint(x: size.width - 120, y: size.height - 34)
			let view = ZStack(alignment: .topLeading) {
				ReportedPage(dark: dark)
				if !fixed {
					Outline(target: column, dark: dark, label: "div.main")
				}
			}
			.frame(width: size.width, height: size.height, alignment: .topLeading)
			.overlay(alignment: .bottomTrailing) {
				HideElementToast(
					site: "www.example.com",
					entries: Array(Self.entries.prefix(2)),
					isExpanded: expanded,
					canUndo: true,
					undo: {},
					done: {},
					toggle: {},
					show: { _ in }
				)
				.opacity(opacity)
				.padding(HideElementToast.Metrics.edgeInset)
			}
			.overlay(alignment: .topLeading) {
				Image(nsImage: cursor).offset(x: pointer.x, y: pointer.y)
			}
			.environment(\.sidebarIsStatic, true)

			let name = "hide-element-pointer-over-toast-\(fixed ? "after" : "before")-\(expanded ? "expanded" : "collapsed")-\(dark ? "dark" : "light")"
			try write(view, size: size, dark: dark, name: name)
		}
	}

	/// DEV-1315: the toast faded on purpose, while the pointer is on the page over an element
	/// under both of its places, such as a footer, still reads.
	@Test(arguments: [false, true])
	internal func fadedOverAFooter(dark: Bool) throws {
		let size: CGSize = .init(width: 900, height: 560)
		let footer = CGRect(x: 0, y: 420, width: size.width, height: 140)
		let view = ZStack(alignment: .topLeading) {
			ReportedPage(dark: dark)
			Outline(target: footer.insetBy(dx: 4, dy: 4), dark: dark, label: "footer")
			Image(nsImage: NSCursor.hideElement.image).offset(x: 300, y: 460)
		}
		.frame(width: size.width, height: size.height, alignment: .topLeading)
		.overlay(alignment: .bottomTrailing) {
			HideElementToast(site: "www.example.com", entries: [], isExpanded: false, canUndo: true, undo: {}, done: {}, toggle: {}, show: { _ in })
				.opacity(HideElementToast.Metrics.fadedOpacity)
				.padding(HideElementToast.Metrics.edgeInset)
		}
		.environment(\.sidebarIsStatic, true)

		try write(view, size: size, dark: dark, name: "hide-element-faded-over-footer-\(dark ? "dark" : "light")")
	}

	@Test(arguments: [false, true])
	internal func pointer(dark: Bool) throws {
		let image = NSCursor.hideElement.image
		let view = HStack(spacing: 24) {
			Image(nsImage: image)
				.resizable()
				.interpolation(.high)
				.frame(width: image.size.width * 4, height: image.size.height * 4)
			Image(nsImage: image)
		}
		.padding(24)
		.background(dark ? Color(white: 0.08) : .white)

		try write(view, size: .init(width: 24 * 3 + 96 + 24 + 24, height: 96 + 48), dark: dark, name: "hide-element-pointer-\(dark ? "dark" : "light")")
	}

	private static let entries: [HideElementToast.Entry] = [
		.init(id: "news.example##div.newsletter", title: "Sign up for our newsletter", detail: "Section · div.newsletter", symbol: "square.dashed"),
		.init(id: "news.example##aside#promo", title: "Recommended for you", detail: "Sidebar · aside#promo", symbol: "sidebar.right"),
		.init(id: "news.example##img.ad", title: "Sponsored", detail: "Image · img.ad", symbol: "photo"),
		.init(id: "news.example##div[data-testid=\"cookie-banner\"]", title: "We use cookies", detail: "Element · div[data-testid=\"cookie-banner\"]", symbol: "square.dashed"),
	]

	private func write(
		_ view: some View,
		size: CGSize,
		dark: Bool,
		name: String
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
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
		try data.write(to: directory.appending(path: "\(name).png"))
		window.close()
	}
}

/// A news page, drawn the way a site would be.
private struct FakePage: View {
	let dark: Bool
	let target: CGRect

	var body: some View {
		let text = dark ? Color(white: 0.9) : Color(white: 0.12)
		let line = dark ? Color(white: 0.22) : Color(white: 0.9)
		ZStack(alignment: .topLeading) {
			(dark ? Color(red: 0.05, green: 0.07, blue: 0.09) : .white)
			VStack(alignment: .leading, spacing: 14) {
				Text(verbatim: "News Example").font(.system(size: 22, weight: .bold)).foregroundStyle(text)
				ForEach(0..<3, id: \.self) { _ in
					RoundedRectangle(cornerRadius: 3).fill(line).frame(width: 520, height: 10)
				}
			}
			.padding(40)
			VStack(alignment: .leading, spacing: 8) {
				Text(verbatim: "Recommended for you").font(.system(size: 16, weight: .semibold)).foregroundStyle(text)
				RoundedRectangle(cornerRadius: 3).fill(line).frame(width: 440, height: 10)
				RoundedRectangle(cornerRadius: 3).fill(line).frame(width: 380, height: 10)
			}
			.padding(16)
			.frame(width: target.width, height: target.height, alignment: .topLeading)
			.background(RoundedRectangle(cornerRadius: 8).stroke(line))
			.offset(x: target.minX, y: target.minY)
			VStack(alignment: .leading, spacing: 10) {
				ForEach(0..<8, id: \.self) { index in
					RoundedRectangle(cornerRadius: 3).fill(line).frame(width: index.isMultiple(of: 3) ? 300 : 520, height: 10)
				}
			}
			.offset(x: 40, y: 336)
			RoundedRectangle(cornerRadius: 8).fill(line.opacity(0.6))
				.frame(width: 260, height: 260)
				.offset(x: 600, y: 40)
		}
	}
}

/// The engine's outline and label as the page script draws them (`ChromiumElementPicker`), in
/// Hide Element's red, for the composite render.
private struct Outline: View {
	let target: CGRect
	let dark: Bool
	let label: String

	var body: some View {
		let red = HideElementToast.red
		let box = target.insetBy(dx: -2, dy: -2)
		ZStack(alignment: .topLeading) {
			RoundedRectangle(cornerRadius: 6)
				.fill(red.opacity(dark ? 0.2 : 0.1))
				.overlay(RoundedRectangle(cornerRadius: 6).stroke(red, lineWidth: 2))
				.background(RoundedRectangle(cornerRadius: 7.5).stroke(red.opacity(dark ? 0.28 : 0.18), lineWidth: 3).padding(-1.5))
				.frame(width: box.width, height: box.height)
				.offset(x: box.minX, y: box.minY)
			Text(verbatim: label)
				.font(.system(size: 12, weight: .semibold))
				.foregroundStyle(.white)
				.padding(.horizontal, 6)
				.padding(.vertical, 2)
				.background(RoundedRectangle(cornerRadius: 4).fill(red))
				.offset(x: box.minX, y: box.minY - 22)
		}
	}
}

/// A page of running text, its lines across the toast's corner, as on the reported page.
private struct ReportedPage: View {
	let dark: Bool

	var body: some View {
		let text = dark ? Color(white: 0.86) : Color(white: 0.14)
		ZStack(alignment: .topLeading) {
			(dark ? Color(red: 0.27, green: 0.18, blue: 0.19) : .white)
			VStack(alignment: .leading, spacing: 18) {
				Text(verbatim: "Example Model").font(.system(size: 24, weight: .bold)).foregroundStyle(text)
				ForEach(0..<9, id: \.self) { _ in
					Text(
						verbatim: "Strong results on coding benchmarks, analytical reasoning, and production-grade agents while offering speed and value"
					)
					.font(.system(size: 19))
					.foregroundStyle(text)
					.lineLimit(1)
					.fixedSize()
				}
			}
			.padding(28)
		}
	}
}
