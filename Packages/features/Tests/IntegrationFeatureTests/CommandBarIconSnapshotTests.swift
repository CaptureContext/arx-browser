import AppKit
import AppUI
import BrowserCore
@testable import CommandBarFeature
import Foundation
import SwiftUI
import Testing
import _ComposableArchitecture

/// Writes offscreen PNGs of the command bar's field icon (DEV-1311) with a site, a tab, a search
/// and a command highlighted, of the bang list and of a bang's scoped search, when `ARX_DESIGN_SNAPSHOTS` names a
/// directory.
///
/// A favicon that arrives after a view appears never draws in an offscreen window, which isn't
/// on screen to commit it, so the site and the tab here are the onboarding tour's sample sites,
/// whose icons draw at once through the same icon view (`TourSiteGlyph`). The bangs' stored
/// favicons can't be drawn this way: `CommandBarSiteIconFetchTests` and
/// `ChromiumSiteIconCacheTests` prove which are read and when one is fetched.
@MainActor
@Suite(.renderTurn, .dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct CommandBarIconSnapshotTests {
	internal enum Scene: String, CaseIterable, Sendable {
		case site
		case tab
		case search
		case command
		case bangs

		/// "!yt" then Return: YouTube's scoped search.
		case scope

		/// "!yt" typed, before Return (DEV-1321).
		case bangKeyword

		/// YouTube's scoped search before a query (DEV-1321).
		case emptyScope
	}

	@Test(arguments: Scene.allCases)
	internal func fieldIcon(_ scene: Scene) throws {
		for dark in [false, true] {
			let store = Store(initialState: Self.state(scene)) { CommandBarFeature() }
			let view = CommandBarView(store: store)
				.frame(width: 640)
				.environment(\.commandBarIsStatic, true)
				.environment(\.locale, Locale(identifier: "en_US"))
				.padding(24)
				.background(Color(nsColor: .windowBackgroundColor))
				.fixedSize()

			try write(view, dark: dark, name: "command-bar-icon-\(scene.rawValue)-\(dark ? "dark" : "light").png")
		}
	}

	private static let profileID: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000001311")!)

	private static func state(_ scene: Scene) -> CommandBarFeature.State {
		var state = CommandBarFeature.State(
			mode: .newTab,
			candidates: candidates,
			bangs: .init(parsing: bangs)
		)
		state.isPresented = true
		state.bangIconProfileID = profileID
		switch scene {
		case .site:
			state.query = "ca"
			state.selectedID = "history-capturecontext"

		case .tab:
			state.query = "ca"
			state.selectedID = "tab-calendar"

		case .search:
			state.query = "ca"
			state.selectedID = "destination"

		case .command:
			state.query = "reload"
			state.selectedID = "command-reload"

		case .bangs:
			state.query = "!"
			state.selectedID = state.entries.first?.presentation.id

		case .scope:
			state.siteSearchKeyword = "yt"
			state.query = "cats"
			state.selectedID = state.entries.first?.presentation.id

		case .bangKeyword:
			state.query = "!yt"
			state.selectedID = state.entries.first?.presentation.id

		case .emptyScope:
			state.siteSearchKeyword = "yt"
			state.query = ""
			state.selectedID = state.entries.first?.presentation.id
		}
		return state
	}

	private static var candidates: [CommandBarFeature.Entry] {
		[
			.init(
				presentation: .init(
					id: "history-capturecontext",
					title: "CaptureContext: indie studio for Apple apps and Swift packages",
					subtitle: "https://capturecontext.dev/",
					actionTitle: "Open",
					symbol: "arx.sample.docs"
				),
				intent: .open(URL(string: "https://capturecontext.dev/")!)
			),
			.init(
				presentation: .init(
					id: "history-tools",
					title: "Tools · CaptureContext",
					subtitle: "https://capturecontext.dev/tools",
					actionTitle: "Open",
					symbol: "clock.arrow.circlepath",
					siteIcon: icon("https://capturecontext.dev/tools")
				),
				intent: .open(URL(string: "https://capturecontext.dev/tools")!)
			),
			.init(
				presentation: .init(
					id: "tab-calendar",
					title: "Google Calendar",
					subtitle: "https://calendar.google.com/calendar",
					actionTitle: "Switch to Tab",
					symbol: "arx.sample.calendar"
				),
				intent: .selectTab(.init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000ca1e")!))
			),
			.command(.reload, bindings: []),
		]
	}

	private static let bangs: String = """
	gh github	GitHub	1	https://github.com/search?q={query}
	yt youtube	YouTube	1	https://www.youtube.com/results?search_query={query}
	w wiki	Wikipedia	1	https://en.wikipedia.org/wiki/Special:Search?search={query}
	a amazon	Amazon.com	1	https://www.amazon.com/s?k={query}
	"""

	private static func icon(_ address: String) -> SidebarItem.SiteIcon {
		.init(profileID: profileID.rawValue, pageURL: URL(string: address)!)
	}

	private func write(
		_ view: some View,
		dark: Bool,
		name: String
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: host.fittingSize)

		// Never shown: the window only gives the hosting view somewhere to lay out.
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
		try data.write(to: directory.appending(path: name))
		window.close()
	}
}
