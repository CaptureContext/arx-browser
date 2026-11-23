import AppKit
import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import Foundation
import SwiftUI
import Testing
import _ComposableArchitecture

@testable import LittleArxFeature

/// Writes offscreen PNGs of Little Arx for visual self-review, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(.renderTurn, .dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct LittleArxSnapshotTests {
	private typealias Destination = LittleArxView.Destination

	private func write(
		_ view: some View,
		size: CGSize,
		name: String,
		dark: Bool = true,
		afterAppearing: () -> Void = {}
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

		// Offscreen renders can't draw Liquid Glass; the chrome's solid fills stand in.
		let host = NSHostingView(rootView: view.environment(\.sidebarIsStatic, true))
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for step in 0..<6 {
			if step == 3 { afterAppearing() }
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: name))
		window.close()
	}

	@Test(arguments: [false, true])
	func window(dark: Bool) throws {
		let organization = IntegrationFeatureTests().fixture()
		let space = organization.spaces[0]
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID()),
			profileID: space.profileID,
			restoration: .init(title: "GitHub", url: URL(string: "https://github.com/CaptureContext")!)
		)
		var state = LittleArxFeature.State(id: UUID(), spaceID: space.id, tab: tab)
		state.viewer.navigation.url = tab.restoration.url
		let store = Store(initialState: state) { LittleArxFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in nil }
		}
		let view = LittleArxView(
			store: store,
			surface: .liveValue,
			profiles: organization.profiles,
			onCommandHeightChange: { _ in },
			destinations: organization.spaces.map {
				.init(id: $0.id, profileID: $0.profileID, name: $0.name, menuTitle: $0.name)
			}
		)
		let appearance = dark ? "dark" : "light"
		try write(view, size: .init(width: 900, height: 200), name: "little-window-\(appearance).png", dark: dark)

		// Showing the tab resets navigation, so history arrives the way the engine reports it.
		try write(view, size: .init(width: 900, height: 200), name: "little-window-back-\(appearance).png", dark: dark) {
			var navigation = store.viewer.navigation
			navigation.canGoBack = true
			store.send(.viewer(.event(.navigation(tab.id, store.viewer.generation, navigation))))
		}
	}

	@Test
	func spacePicker() throws {
		let profile = Profile.ID(rawValue: UUID())
		let names = [
			("Personal", "bookmark.fill"),
			("CaptureContext", "chevron.left.forwardslash.chevron.right"),
			("Shops", "bag.fill"),
			("Jobs", "briefcase.fill"),
		]
		let destinations = names.map { name, icon in
			Destination(id: .init(rawValue: UUID()), profileID: profile, name: name, menuTitle: name, icon: icon)
		}
		let view = LittleArxSpacePicker(
			destinations: destinations,
			currentSpaceID: destinations[0].id,
			onSelect: { _ in },
			onDismiss: {}
		)
		try write(view.padding(20), size: .init(width: 260, height: 260), name: "little-spaces.png")
	}
}
