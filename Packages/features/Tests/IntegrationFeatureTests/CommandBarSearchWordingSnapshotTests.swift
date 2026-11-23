import AppKit
import AppUI
import BrowserCore
import CommandBarFeature
import Foundation
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1319: the command bar as the feature lists it, with "asd" typed: the typed search, the
/// provider's suggestions and a site from history. With `ARX_DESIGN_SNAPSHOTS` naming a directory,
/// writes the rows with the typed search and then a suggestion highlighted (a row shows its label
/// while highlighted), then ⌘K's actions for the search and for the site, in light and dark.
@Suite(
	.dependencies,
	.serialized,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
@MainActor
internal struct CommandBarSearchWordingSnapshotTests {
	@Test(arguments: [false, true])
	internal func searchRowsAndActions(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let appearance = dark ? "dark" : "light"

		try render(highlighting: "destination", dark: dark)
			.write(to: directory.appending(path: "command-bar-search-rows-\(appearance).png"))
		try render(highlighting: "suggestion-asda", dark: dark)
			.write(to: directory.appending(path: "command-bar-suggestion-row-\(appearance).png"))
		try render(panelOn: "destination", dark: dark)
			.write(to: directory.appending(path: "command-bar-search-actions-\(appearance).png"))
		try render(panelOn: "history-site", dark: dark)
			.write(to: directory.appending(path: "command-bar-site-actions-\(appearance).png"))
	}

	/// ⌘K's actions for a site while the typed text can be an address, which ⌘↩ opens as is,
	/// and while it can't, in ⌘K's commands mode, where pages also open in a new tab (DEV-1319).
	@Test(arguments: [false, true])
	internal func openAsIs(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let appearance = dark ? "dark" : "light"
		for (name, query) in [("address", "asdshop.example"), ("words", "asd shop")] {
			try render(query: query, mode: .commands, panelOn: "history-site", dark: dark)
				.write(to: directory.appending(path: "command-bar-open-as-is-\(name)-\(appearance).png"))
		}
	}

	private func render(
		query: String = "asd",
		mode: CommandBarFeature.Mode = .newTab,
		highlighting highlighted: String? = nil,
		panelOn entryID: String? = nil,
		dark: Bool
	) throws -> Data {
		var state = CommandBarFeature.State(
			isPresented: true,
			query: query,
			mode: mode,
			candidates: [Self.site]
		)
		if query == "asd" {
			state.suggestions = ["asda", "asdf", "asdasd"]
			state.suggestionsQuery = "asd"
		}
		state.selectedID = entryID ?? highlighted
		if let entryID, let entry = state.entries.first(where: { $0.presentation.id == entryID }) {
			state.actionPanel = .init(entryID: entryID, selectedID: state.actions(for: entry).first?.id)
		}
		let store = Store(initialState: state) { CommandBarFeature() }

		let size = CGSize(width: 640, height: 520)
		let host = NSHostingView(rootView: AnyView(
			CommandBarView(store: store)
				.frame(width: 573)
				.padding(24)
				.frame(width: size.width, height: size.height, alignment: .top)
				.background(Color.gray.opacity(0.35))
		))
		host.frame = .init(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.appearance = window.appearance
		window.contentView = host
		defer { window.close() }
		for _ in 0..<8 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		return try #require(representation.representation(using: .png, properties: [:]))
	}

	private static let site = CommandBarFeature.Entry(
		presentation: .init(
			id: "history-site",
			title: "asd shop",
			subtitle: "https://asdshop.example/",
			actionTitle: "Open URL",
			symbol: "clock.arrow.circlepath"
		),
		intent: .openHistory(.init(
			id: UUID(7),
			profileID: .init(rawValue: UUID(1)),
			spaceID: .init(rawValue: UUID(2)),
			url: URL(string: "https://asdshop.example/")!
		))
	)
}
