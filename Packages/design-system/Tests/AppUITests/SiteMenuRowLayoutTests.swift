import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// The Unread badges row is a row of the Site Settings list like the permissions' (DEV-1333): the
/// same spacing from the row above, and a pop-up of the same frame on the same trailing edge.
/// Measured in a hosted panel, as the app lays it out: each pop-up is backed by an AppKit view.
@MainActor
@Suite(.renderTurn)
internal struct SiteMenuRowLayoutTests {
	@Test
	internal func unreadBadgesSitsInTheListLikeAPermission() throws {
		let menu = SiteMenu(
			host: "capturecontext.dev",
			connection: .secure,
			permissions: SitePermission.allCases.map {
				.init(permission: $0, setting: nil, defaultSetting: $0 == .popups ? .block : .ask)
			},
			blocksContent: true,
			unreadBadges: .init(site: nil, inherited: .show)
		)

		// Top to bottom: the six permissions' pop-ups, then Unread badges'.
		let popUps = try Self.popUpFrames(SiteMenuPanel(menu: menu, send: { _ in }, dismiss: {}))
		try #require(popUps.count == SitePermission.allCases.count + 1)

		let permissionStep = popUps[0].minY - popUps[1].minY
		for (above, below) in zip(popUps, popUps.dropFirst()) {
			#expect(abs(above.minY - below.minY - permissionStep) < 0.5, "rows \(permissionStep) apart, but \(above.minY - below.minY) here")
			#expect(abs(below.width - above.width) < 0.5)
			#expect(abs(below.height - above.height) < 0.5)
			#expect(abs(below.maxX - above.maxX) < 0.5)
		}
	}

	/// The frames, in the window, of the views backing the panel's closed pop-ups: as tall as one
	/// (22 points), at the list's trailing edge. Sorted top to bottom.
	private static func popUpFrames(_ panel: SiteMenuPanel) throws -> [CGRect] {
		let host = NSHostingView(rootView: panel.fixedSize())
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		defer { window.close() }

		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let trailing: CGFloat = SiteMenuPanel.width - SiteMenuPanel.Grid.padding
		var frames: [CGRect] = []
		var views: [NSView] = [host]
		while let view = views.popLast() {
			views.append(contentsOf: view.subviews)
			let frame = view.convert(view.bounds, to: nil)
			if view !== host, abs(frame.height - 22) < 0.5, abs(frame.maxX - trailing) < 1, frame.width < 140 {
				frames.append(frame)
			}
		}
		return frames.sorted { $0.minY > $1.minY }
	}
}
