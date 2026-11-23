import AppKit
@testable import AppFeature
import AppUI
import BrowserCore
import BrowserSurfaceClient
import Foundation
import SwiftUI
import Testing
import ViewerItemFeature
import _ComposableArchitecture
@testable import MainFeature

/// Writes offscreen PNGs of a split view with the link toast in its right pane (DEV-780), alone
/// and with the sidebar's notice stacked below it (DEV-777), light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory. Offscreen renders can't draw Liquid
/// Glass, so the toast shows its material fallback.
@MainActor
@Suite(.renderTurn, .dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct LinkToastPaneSnapshotTests {
	@Test(arguments: [false, true], [false, true])
	func splitWithToastInOnePane(dark: Bool, withNotice: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let fixtures = IntegrationFeatureTests()
		var (state, panes) = fixtures.splitState(focused: 1)
		state.linkActionGeneration = 1
		if withNotice {
			state.main.sidebar.message = String.localized(.appUI.preview.invalidMove)
		}
		state.linkActionFeedback = .init(
			windowID: state.main.id,
			paneID: panes[1].id,
			result: LinkTransformer.copy([.init(title: "", url: panes[1].url)], mode: .original),
			status: .copied
		)

		// A clock that never ticks, so the toast stays for the render.
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = TestClock()
		}
		let windowID = state.main.id
		let items = state.main.viewer.panes.map { pane in
			Store(initialState: pane.item) { ViewerItemFeature() }
		}

		let view = HStack(spacing: BrowserMetrics.PageCard.inset) {
			ForEach(items.indices, id: \.self) { index in
				ViewerItemView(store: items[index], surface: .liveValue, isFocused: index == 1, showsLoading: false)
					.browserPageCard()
			}
		}
		.padding(BrowserMetrics.PageCard.inset)

		// As MainView draws the sidebar's notice, and the app the window's link toast around it.
		.overlay {
			Color.clear
				.allowsHitTesting(false)
				.modifier(SidebarNoticeToast(store: store.scope(state: \.main, action: \.main)))
		}
		.modifier(LinkFeedbackToast(
			store: store,
			windowID: windowID,
			topInset: BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset,
			trailingInset: BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset
		))
		.environment(\.browserPageNotice, pageLinkFeedbackNotice(store: store, windowID: windowID))
		.environment(\.sidebarIsStatic, true)
		.background { BrowserChromeBackground(textured: true) }

		let size: CGSize = .init(width: 900, height: 260)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let host = NSHostingView(rootView: view)
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<8 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "link-toast-split\(withNotice ? "-notice" : "")-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
