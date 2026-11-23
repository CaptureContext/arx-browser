import AppKit
import BrowserCore
import BrowserSurfaceClient
import Testing

@Suite(.serialized)
@MainActor
internal struct BrowserUnhandledEscapeTests {
	@Test
	internal func missingHostForeignTabAndStaleSourceDecline() {
		let hosts = BrowserUnhandledEscapeHosts()
		let tabID = BrowserCore.Tab.ID(rawValue: UUID())
		let host = NSView()
		let missingHostDeclined = !hosts.accept(tabID, in: host, sourceIsCurrent: { true })
		#expect(missingHostDeclined)

		hosts.bind(tabID, to: host, handler: { _ in true })
		let foreignTabDeclined = !hosts.accept(.init(rawValue: UUID()), in: host, sourceIsCurrent: { true })
		#expect(foreignTabDeclined)
		let foreignHostDeclined = !hosts.accept(tabID, in: NSView(), sourceIsCurrent: { true })
		#expect(foreignHostDeclined)
		let staleSourceDeclined = !hosts.accept(tabID, in: host, sourceIsCurrent: { false })
		#expect(staleSourceDeclined)
		let currentHostAccepted = hosts.accept(tabID, in: host, sourceIsCurrent: { true })
		#expect(currentHostAccepted)
	}

	@Test
	internal func oldTeardownCannotClearReplacementAndDeferredWorkRechecksBinding() {
		let hosts = BrowserUnhandledEscapeHosts()
		let tabID = BrowserCore.Tab.ID(rawValue: UUID())
		let old = NSView()
		let replacement = NSView()
		let work = DeferredWork()
		hosts.bind(tabID, to: old) { current in
			work.isCurrent = current
			return true
		}
		let originalAccepted = hosts.accept(tabID, in: old, sourceIsCurrent: { true })
		#expect(originalAccepted)
		#expect(work.isCurrent?() == true)

		hosts.bind(tabID, to: replacement, handler: { _ in true })
		hosts.bind(tabID, to: old, handler: nil)
		#expect(work.isCurrent?() == false)
		let replacementAccepted = hosts.accept(tabID, in: replacement, sourceIsCurrent: { true })
		#expect(replacementAccepted)
	}

	@Test
	internal func deferredWorkDeclinesRebindNavigationAndHostDestruction() {
		let hosts = BrowserUnhandledEscapeHosts()
		let tabID = BrowserCore.Tab.ID(rawValue: UUID())
		var host: NSView? = .init()
		let work = DeferredWork()
		hosts.bind(tabID, to: host!) { current in
			work.isCurrent = current
			return true
		}
		let initialAccepted = hosts.accept(tabID, in: host!, sourceIsCurrent: { work.generation == 1 })
		#expect(initialAccepted)
		#expect(work.isCurrent?() == true)
		work.generation = 2
		#expect(work.isCurrent?() == false)
		work.generation = 1
		hosts.bind(.init(rawValue: UUID()), to: host!, handler: { _ in true })
		#expect(work.isCurrent?() == false)
		let reboundTabDeclined = !hosts.accept(tabID, in: host!, sourceIsCurrent: { true })
		#expect(reboundTabDeclined)
		host = nil
		#expect(work.isCurrent?() == false)
	}
}

@MainActor
private final class DeferredWork {
	fileprivate var isCurrent: (@MainActor @Sendable () -> Bool)?
	fileprivate var generation: Int = 1
}
