import AppKit
import ObjectiveC
import Testing

@testable import AppFeature

@MainActor
@Suite(.dependencies, .serialized)
internal struct BrowserDockMenuTests {
	@Test
	internal func dockMenuRetainsDelegateIdentityAndFallsBackToItsOriginalImplementation() async throws {
		let fixture = DockDelegateFixture()
		let delegate: any NSApplicationDelegate = fixture
		let originalClass: AnyClass? = object_getClass(delegate)
		let applicationDelegate = NSApplication.shared.delegate
		var offered: NSMenu? = NSMenu(title: "Arx")
		BrowserDockMenu.install(on: delegate) { offered }

		#expect(delegate.applicationDockMenu?(NSApplication.shared) === offered)
		#expect(object_getClass(delegate) === originalClass)
		#expect(NSApplication.shared.delegate === applicationDelegate)
		offered = nil
		#expect(delegate.applicationDockMenu?(NSApplication.shared) === fixture.originalMenu)
	}
}

@MainActor
private final class DockDelegateFixture: NSObject, NSApplicationDelegate {
	fileprivate let originalMenu: NSMenu = NSMenu(title: "Original")

	fileprivate func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { originalMenu }
}
