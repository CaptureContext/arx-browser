import AppKit
import BrowserCore
@testable import CommandBarFeature
import CustomDump
import Foundation
@testable import MainFeature
import Testing
@testable import ViewerFeature
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

/// DEV-993: a click anywhere in a split pane, its page included, selects that pane.
@Suite(.dependencies)
@MainActor
internal struct PaneSelectionTests {
	@Test
	internal func aClickInsideThePaneSelectsItAndOneOutsideDoesNot() throws {
		let (window, monitor) = Self.pane()
		defer { window.close() }

		#expect(monitor.selects(try Self.click(at: .init(x: 50, y: 40), in: window)))
		// A click elsewhere in the window, such as the other pane.
		#expect(!monitor.selects(try Self.click(at: .init(x: 300, y: 40), in: window)))

		let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
		other.isReleasedWhenClosed = false
		defer { other.close() }
		#expect(!monitor.selects(try Self.click(at: .init(x: 50, y: 40), in: other)))

		monitor.isHidden = true
		#expect(!monitor.selects(try Self.click(at: .init(x: 50, y: 40), in: window)))
	}

	@Test
	internal func theMonitorNeverTakesTheClickItself() {
		let (window, monitor) = Self.pane()
		defer { window.close() }
		#expect(monitor.hitTest(.init(x: 50, y: 40)) == nil)
	}

	@Test
	internal func selectingAPaneMakesItTheActiveOne() async {
		let first = UUID(1)
		let second = UUID(2)
		var state = ViewerFeature.State(item: .init())
		state.panes = [.init(id: first, item: .init()), .init(id: second, item: .init())]
		state.activePaneID = first
		let store = TestStore(initialState: state) { ViewerFeature() }

		await store.send(.ui(.focus(second))) { $0.activePaneID = second }

		// A pane that's gone selects nothing.
		await store.send(.ui(.focus(UUID(9))))
	}

	/// DEV-993: clicking a pane header's address opens the command bar on that pane, editing its
	/// address, as the sidebar's address does for the window.
	@Test
	internal func clickingAPanesAddressEditsThatPanesAddress() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let first = state.viewer.activePaneID
		let second = UUID(80)
		let address = URL(string: "https://rezka.ag/ua/films/drama/3311-babaduk-2014.html")!
		state.viewer.item.tab = organization.tabs[0]
		state.viewer.item.navigation = .init(url: URL(string: "https://capturecontext.dev/")!)
		state.viewer.panes.append(.init(id: second, item: .init(tab: organization.tabs[1], navigation: .init(url: address))))
		let store = Store(initialState: state) { MainFeature() }

		// What the header's address sends after selecting its pane.
		await store.send(.viewer(.ui(.focus(second)))).finish()
		await store.send(.ui(.paneCommand(.address, second))).finish()

		#expect(store.commandBar.isPresented)
		expectNoDifference(store.commandBar.mode, .currentTab)
		expectNoDifference(store.commandBar.query, address.absoluteString)
		expectNoDifference(store.commandBarPaneID, second)
		expectNoDifference(store.viewer.activePaneID, second)
		#expect(first != second)
	}

	/// DEV-995: a pane header's link button copies that pane's address, selected or not.
	@Test
	internal func aPanesLinkButtonCopiesThatPanesAddress() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let second = UUID(80)
		let address = URL(string: "https://rezka.ag/ua/films/drama/3311-babaduk-2014.html")!
		state.viewer.item.tab = organization.tabs[0]
		state.viewer.item.navigation = .init(url: URL(string: "https://capturecontext.dev/")!)
		state.viewer.panes.append(.init(id: second, item: .init(tab: organization.tabs[1], navigation: .init(url: address))))
		let store = TestStore(initialState: state) { MainFeature() }
		store.exhaustivity = .off

		// What the header's link button sends.
		await store.send(.ui(.paneCommand(.copyURL, second)))
		await store.receive(\.delegate.copyURL, address)
		await store.finish()
	}

	/// A 400 × 100 window whose left half is a pane's monitor.
	private static func pane() -> (NSWindow, PaneClickMonitor.MonitorView) {
		// Not deferred, so the window has the number a click event names it by.
		let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		let content = NSView(frame: .init(x: 0, y: 0, width: 400, height: 100))
		let monitor = PaneClickMonitor.MonitorView(frame: .init(x: 0, y: 0, width: 200, height: 100))
		content.addSubview(monitor)
		window.contentView = content
		return (window, monitor)
	}

	private static func click(
		at point: NSPoint,
		in window: NSWindow
	) throws -> NSEvent {
		try #require(NSEvent.mouseEvent(
			with: .leftMouseDown,
			location: point,
			modifierFlags: [],
			timestamp: 0,
			windowNumber: window.windowNumber,
			context: nil,
			eventNumber: 0,
			clickCount: 1,
			pressure: 1
		))
	}
}
