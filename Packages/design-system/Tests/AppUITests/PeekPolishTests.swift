import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// DEV-1224: the page behind an open Peek dims, and the tab it came from shows the peeked site.
@MainActor
@Suite(.renderTurn)
internal struct PeekPolishTests {
	private static let paneID: UUID = .init(uuidString: "00000000-0000-0000-0000-000000001224")!

	@Test
	internal func onlyTheTabThePeekCameFromShowsTheBadge() {
		let tabID: UUID = .init()
		let peek: BrowserPeekedTab = .init(tabID: tabID, siteIcon: nil, title: "YouTube")

		#expect(peek.isOpened(from: .tab(tabID)))
		#expect(!peek.isOpened(from: .tab(UUID())))
		// A folder with the same identity isn't the tab.
		#expect(!peek.isOpened(from: .folder(tabID)))
	}

	/// A Split View group draws its own row, a segment per member (batch 16's review): the member
	/// a Peek came from shows the badge there too, and a Peek from another tab changes nothing.
	@Test
	internal func theBadgeShowsOnTheSourceTabsRowOrSplitSegment() throws {
		let source: UUID = .init(uuidString: "00000000-0000-0000-0000-000000000021")!
		let elsewhere: BrowserPeekedTab = .init(tabID: UUID(), siteIcon: nil, title: "Elsewhere")
		let fromSource: BrowserPeekedTab = .init(tabID: source, siteIcon: nil, title: "YouTube")
		let split = SplitSidebarRow(
			item: .init(id: .tab(UUID(uuidString: "00000000-0000-0000-0000-000000000020")!), title: "Linear"),
			split: .init(
				id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
				members: [
					.init(id: .tab(UUID(uuidString: "00000000-0000-0000-0000-000000000020")!), title: "Linear"),
					.init(id: .tab(source), title: "GitHub"),
				]
			),
			selected: true,
			onAction: { _ in }
		)
		let row = SidebarRow(item: .init(id: .tab(source), title: "GitHub", isPinned: false), onAction: { _ in })

		let splitPlain: Data = try bitmap(of: split, peek: nil)
		#expect(try bitmap(of: split, peek: elsewhere) == splitPlain)
		#expect(try bitmap(of: split, peek: fromSource) != splitPlain)
		let rowPlain: Data = try bitmap(of: row, peek: nil)
		#expect(try bitmap(of: row, peek: elsewhere) == rowPlain)
		#expect(try bitmap(of: row, peek: fromSource) != rowPlain)
	}

	/// The pixels of `view` hosted in a window as the sidebar is, with `peek` in its environment.
	private func bitmap(
		of view: some View,
		peek: BrowserPeekedTab?
	) throws -> Data {
		let host = NSHostingView(
			rootView: view
				.environment(\.browserPeekedTab, peek)
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
		return try #require(representation.representation(using: .png, properties: [:]))
	}

	/// Pages are AppKit views, so the dimming must reach a hosted NSView, not only SwiftUI content.
	@Test(arguments: [true, false])
	internal func thePageBehindAPeekDims(isPeeking: Bool) throws {
		let page: NSView = .init()
		page.wantsLayer = true
		let view = PageStandIn(view: page)
			.frame(width: 200, height: 120)
			.browserRecedesBehindPeek(paneID: Self.paneID)
			.environment(\.browserRecedingPaneID, isPeeking ? Self.paneID : nil)
			.transaction { $0.disablesAnimations = true }
		let host = NSHostingView(rootView: view)
		host.frame = .init(x: 0, y: 0, width: 200, height: 120)
		let window = NSWindow(
			contentRect: host.frame,
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		defer {
			window.contentView = nil
			window.close()
		}
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			window.displayIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}

		#expect(page.window === window)
		let opacity: Double = effectiveOpacity(of: page, in: host)
		let expected: Double = isPeeking ? BrowserMetrics.Peek.backgroundOpacity : 1
		#expect(abs(opacity - expected) < 0.01, "page opacity \(opacity)")
	}

	/// The opacity of every layer from the page's up to the hosting view's. A layer-backed view's
	/// `alphaValue` is its layer's opacity, so only layers count.
	private func effectiveOpacity(
		of page: NSView,
		in root: NSView
	) -> Double {
		var opacity: Double = 1
		var layer: CALayer? = page.layer
		while let current = layer {
			opacity *= Double(current.opacity)
			if current === root.layer { break }
			layer = current.superlayer
		}
		return opacity
	}
}

private struct PageStandIn: NSViewRepresentable {
	let view: NSView

	func makeNSView(context: Context) -> NSView { view }

	func updateNSView(
		_ nsView: NSView,
		context: Context
	) {}
}
