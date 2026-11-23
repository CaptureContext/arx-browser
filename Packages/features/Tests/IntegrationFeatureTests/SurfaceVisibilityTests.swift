import AppKit
import BrowserCore
import CustomDump
import Foundation
import Testing

@testable import BrowserSurfaceClient

@Suite(.dependencies)
@MainActor
internal struct SurfaceVisibilityTests {
	@Test
	internal func bindingChangesDiscardQueuedOldSourceReportsAndTeardownReleasesToken() async throws {
		let client = BrowserSurfaceClient(
			attach: { _, host in
				if host.subviews.isEmpty {
					host.addSubview(NSView(frame: .init(x: 0, y: 0, width: 100, height: 100)))
				}
			},
			detach: { host in host.subviews.forEach { $0.removeFromSuperview() } }
		)
		let coordinator = BrowserSurface.Coordinator(client: client)
		var reports: [BrowserSurfaceVisibility] = []
		coordinator.onVisibility = { reports.append($0) }
		let host = coordinator.makeHost()
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 200, height: 200),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		let first = BrowserCore.Tab.ID(rawValue: UUID(1))
		let replacement = BrowserCore.Tab.ID(rawValue: UUID(2))
		coordinator.update(tabID: first, isFocused: false, isSuppressed: false, in: host)
		coordinator.update(tabID: replacement, isFocused: false, isSuppressed: false, in: host)
		for _ in 0..<10 { await Task.yield() }
		let report = try #require(reports.last)
		expectNoDifference(report.tabID, replacement)
		expectNoDifference(report.isVisible, false)
		#expect(!reports.contains(where: { $0.tabID == first }))
		coordinator.stop()
		for _ in 0..<10 { await Task.yield() }
		expectNoDifference(reports.last, .init(hostID: report.hostID, tabID: replacement, isVisible: nil))
		window.contentView = nil
		window.close()
	}
}
