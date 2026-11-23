#if DEBUG
// Sidebar bodies are counted only in Debug builds.
import AppKit
@testable import AppUI
import BrowserCore
import BrowserSurfaceClient
import Foundation
@testable import MainFeature
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-937: in the window as it's built, the active tab's navigation re-renders neither the
/// pager nor any space's sidebar, and a tab change in one space re-renders no other space.
@MainActor
@Suite(.renderTurn, .dependencies, .serialized, .enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to lay out views"))
internal struct MainSidebarRenderCountTests {
	@Test
	internal func theActiveTabsNavigationRendersNoSidebar() {
		let window = HostedMainWindow()
		defer { window.close() }

		let tab = window.activeTab
		let url = tab.restoration.url
		let title = tab.restoration.title
		let events: [BrowserNavigation] = [
			.init(url: url, title: title, isLoading: true, canGoBack: true),
			.init(url: url, title: title, isLoading: true, canGoBack: true, canGoForward: true),
			.init(url: url, title: title, isLoading: false, canGoBack: true, canGoForward: true),
		]
		for navigation in events {
			let rendered = window.recording { $0.send(.viewer(.item(.event(.navigation(tab.id, 1, navigation))))) }
			#expect(rendered[.pager] == nil, "\(rendered)")
			#expect(!rendered.keys.contains { if case .sidebar = $0 { true } else { false } }, "\(rendered)")
		}
		#expect(window.store.viewer.item.navigation == events.last)
	}

	@Test
	internal func aTabChangeInOneSpaceRendersNoOtherSpace() {
		let window = HostedMainWindow()
		defer { window.close() }

		let tab = window.tab(5, inSpace: 0)
		let rendered = window.recording { $0.send(.sidebar(.ui(.sidebar(.rename(.tab(tab.rawValue), "Renamed"))))) }
		#expect(rendered[.sidebar(HostedMainWindow.names[0])] != nil, "\(rendered)")
		#expect(rendered[.sidebar(HostedMainWindow.names[1])] == nil, "\(rendered)")
		#expect(rendered[.sidebar(HostedMainWindow.names[2])] == nil, "\(rendered)")
	}
}

@MainActor
private final class HostedMainWindow {
	static let names: [String] = ["Work", "Home", "Read"]
	static let size: CGSize = .init(width: 1_000, height: 700)
	private static let tabsPerSpace: Int = 30

	let store: StoreOf<MainFeature>
	private let window: NSWindow
	private let host: NSHostingView<AnyView>

	init() {
		let profile = Profile.ID(rawValue: UUID(1))
		var tabs: [BrowserCore.Tab] = []
		let spaces: [Space] = Self.names.indices.map { space in
			let ids: [BrowserCore.Tab.ID] = (0..<Self.tabsPerSpace).map { index in
				let id = Self.tabID(index, inSpace: space)
				let url = URL(string: "https://example.com/\(space)/\(index)")!
				tabs.append(.init(id: id, profileID: profile, restoration: .init(title: "Tab \(index)", url: url)))
				return id
			}
			return Space(
				id: .init(rawValue: UUID(100 + space)),
				profileID: profile,
				name: Self.names[space],
				unpinnedTabs: ids,
				selectedTabID: ids[0]
			)
		}
		let organization = BrowserOrganization(
			profiles: [.init(id: profile, name: "Default")],
			spaces: spaces,
			tabs: tabs
		)

		// The middle space, so the spaces either side are mounted too.
		var state = MainFeature.State(organization: organization, spaceID: spaces[1].id)
		let active = organization.tabs[id: Self.tabID(0, inSpace: 1)]
		state.viewer.item = .init(tab: active, navigation: .init(url: active?.restoration.url), generation: 1)
		self.store = Store(initialState: state) { MainFeature() } withDependencies: {
			$0.continuousClock = TestClock()
		}

		self.host = NSHostingView(rootView: AnyView(EmptyView()))
		host.frame = CGRect(origin: .zero, size: Self.size)

		// Never shown: the window only gives the hosting view somewhere to lay out.
		self.window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: Self.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		host.rootView = AnyView(
			MainView(
				store: store,
				surface: .init(attach: { _, _ in }, detach: { _ in })
			)
		)
		settleUntilQuiet()
	}

	var activeTab: BrowserCore.Tab {
		store.viewer.item.tab!
	}

	func tab(
		_ index: Int,
		inSpace space: Int
	) -> BrowserCore.Tab.ID {
		Self.tabID(index, inSpace: space)
	}

	func recording(_ change: (StoreOf<MainFeature>) -> Void) -> [SidebarRenderTrace.Subject: Int] {
		SidebarRenderTrace.startRecording()
		defer { SidebarRenderTrace.stopRecording() }
		change(store)
		settle()
		return SidebarRenderTrace.views ?? [:]
	}

	func close() {
		window.close()
	}

	private static func tabID(
		_ index: Int,
		inSpace space: Int
	) -> BrowserCore.Tab.ID {
		.init(rawValue: UUID(1_000 + space * 100 + index))
	}

	/// Lets the window finish its first layout and the effects its store starts, so none of it
	/// lands in a test's counts on a loaded machine.
	private func settleUntilQuiet() {
		for _ in 0..<10 {
			SidebarRenderTrace.startRecording()
			settle()
			let rendered = SidebarRenderTrace.views ?? [:]
			SidebarRenderTrace.stopRecording()
			if rendered.isEmpty { return }
		}
	}

	private func settle() {
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.02))
		}
	}
}
#endif
