import AppKit
import AppUI
import BrowserCore
import Foundation
@testable import MainFeature
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

/// Writes offscreen PNGs of the sidebar's notice toast (DEV-777) over a page card, alone and
/// below a link toast, light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
/// Offscreen renders can't draw Liquid Glass, so the toasts show their material fallback.
@MainActor
@Suite(.renderTurn, .dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct SidebarNoticeSnapshotTests {
	@Test(arguments: [false, true], [false, true])
	internal func noticeOverThePage(dark: Bool, belowLinkToast: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let profile = Profile.ID(rawValue: UUID(0))
		let space = Space.ID(rawValue: UUID(100))
		var state = MainFeature.State(
			organization: .init(
				profiles: [.init(id: profile, name: "Default")],
				spaces: [.init(id: space, profileID: profile, name: "Work")],
				tabs: []
			),
			spaceID: space
		)
		state.sidebar.message = String.localized(.appUI.management.workspaceChanged)

		// A clock that never ticks, so the toast stays for the render.
		let store = Store(initialState: state) { MainFeature() } withDependencies: {
			$0.continuousClock = TestClock()
		}

		let page = VStack(alignment: .leading, spacing: 10) {
			RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.12)).frame(width: 220, height: 14)
			RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)).frame(width: 380, height: 10)
			RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)).frame(width: 320, height: 10)
		}
		.padding(24)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
		.browserPageCard()
		.padding(BrowserMetrics.PageCard.inset)

		let topInset: CGFloat = BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset
		let view = ZStack {
			page
			Color.clear
				.allowsHitTesting(false)
				.modifier(SidebarNoticeToast(store: store))
		}

		// As the window's link toast does while it shows: the notice stacks below it.
		.environment(\.arxToastStackOffset, belowLinkToast ? ArxToastMetrics.stackOffset(below: 0) : 0)
		.arxToast(isPresented: belowLinkToast, topInset: topInset, trailingInset: topInset) {
			ArxToast("Copied Current URL") {
				Button {} label: { Image(systemName: "square.and.arrow.up") }
					.buttonStyle(.arxRaised(size: .small))
			}
		}
		.environment(\.sidebarIsStatic, true)
		.background { BrowserChromeBackground(textured: true) }

		let size: CGSize = .init(width: 720, height: 240)
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
		try data.write(to: directory.appending(path: "sidebar-notice\(belowLinkToast ? "-stacked" : "")-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
