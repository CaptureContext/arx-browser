import AppKit
import BrowserCore
import BrowserSurfaceClient
import CustomDump
import Foundation
import PeekFeature
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1173: Peek drew its page grayed out, because the page sat on a material.
///
/// Chromium's page view allows vibrancy, so on a material AppKit gave its layer a plus-lighter
/// filter: the page added onto the material's gray instead of covering it. A page in Peek
/// must draw as it does in a tab, with nothing blending its layer into what's behind.
@MainActor
@Suite(.renderTurn, .dependencies, .serialized)
internal struct PeekPageBlendingTests {
	@Test(arguments: [NSAppearance.Name.darkAqua, .aqua])
	internal func peekPageCoversWhatIsBehindIt(_ appearance: NSAppearance.Name) async throws {
		var page: ChromiumLikePage?
		let client = BrowserSurfaceClient(
			attach: { _, host in
				guard page?.superview !== host else { return }
				let view = ChromiumLikePage(frame: host.bounds)
				view.autoresizingMask = [.width, .height]
				host.addSubview(view)
				page = view
			},
			detach: { _ in }
		)
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(1173)),
			profileID: .init(rawValue: UUID(1)),
			restoration: .init(title: "Dark page", url: URL(string: "https://dark.example")!)
		)
		var state = PeekFeature.State(
			id: UUID(1174),
			source: .init(
				windowID: UUID(1175),
				paneID: UUID(1176),
				tabID: nil,
				spaceID: .init(rawValue: UUID(1177)),
				profileID: tab.profileID,
				identity: "Default"
			),
			tab: tab,
			isTemporary: true
		)
		state.viewer.tab = tab
		let store = Store(initialState: state) { PeekFeature() }
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 640, height: 480),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: appearance)
		defer {
			window.contentView = nil
			window.close()
		}
		let content = NSHostingView(rootView: PeekView(store: store, surface: client))
		window.contentView = content
		content.layoutSubtreeIfNeeded()
		window.displayIfNeeded()
		await waitWhile { page?.window == nil }
		content.layoutSubtreeIfNeeded()
		window.displayIfNeeded()

		let mounted = try #require(page)
		#expect(mounted.window === window)
		expectNoDifference(blendedLayers(from: mounted, to: content), [])
	}

	/// Layers from the page up to the window's content that blend into what's behind them.
	private func blendedLayers(
		from page: NSView,
		to root: NSView
	) -> [String] {
		var blended: [String] = []
		var view: NSView? = page
		while let current = view {
			if let layer = current.layer, let filter = layer.compositingFilter {
				blended.append("\(type(of: current)): \(filter)")
			}
			if current === root { break }
			view = current.superview
		}
		return blended
	}
}

/// Stands in for Chromium's `WebContentsViewCocoa`, which allows vibrancy and draws into its own
/// layer.
private final class ChromiumLikePage: NSView {
	override var allowsVibrancy: Bool { true }

	override init(frame: NSRect) {
		super.init(frame: frame)
		self.wantsLayer = true
	}

	required init?(coder: NSCoder) { nil }

	override func makeBackingLayer() -> CALayer {
		let layer = CALayer()
		layer.backgroundColor = NSColor(srgbRed: 13 / 255, green: 17 / 255, blue: 23 / 255, alpha: 1).cgColor
		return layer
	}
}
