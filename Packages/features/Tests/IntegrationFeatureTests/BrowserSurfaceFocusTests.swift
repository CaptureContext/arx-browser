import AppKit
import BrowserCore
import BrowserSurfaceClient
import CustomDump
import Foundation
import SwiftUI
import Testing
import _TestSupport

@MainActor
@Suite(.renderTurn, .dependencies, .serialized)
internal struct BrowserSurfaceFocusTests {
	@Test
	internal func focusedPaneWaitsForNativeMountAndDoesNotStealFocusOnLaterMounts() async throws {
		let tabID = BrowserCore.Tab.ID(rawValue: UUID(10))
		var host: NSView?
		var focused: [BrowserCore.Tab.ID] = []
		let client = BrowserSurfaceClient(
			attach: { _, view in host = view },
			detach: { _ in },
			focus: { focused.append($0) }
		)
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 400, height: 300),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		defer {
			window.contentView = nil
			window.close()
		}
		let content = NSHostingView(rootView: BrowserSurface(tabID: tabID, client: client, isFocused: true))
		window.contentView = content
		content.layoutSubtreeIfNeeded()
		window.update()
		let mounted = try #require(host)
		expectNoDifference(focused, [])
		mounted.addSubview(NSView())
		await waitWhile { focused.isEmpty }

		expectNoDifference(focused, [tabID])
		mounted.addSubview(NSView())
		await Task.yield()
		expectNoDifference(focused, [tabID])
	}

	@Test
	internal func backgroundPaneMountDoesNotRequestNativeFocus() async throws {
		var host: NSView?
		let client = BrowserSurfaceClient(
			attach: { _, view in host = view },
			detach: { _ in },
			focus: { _ in Issue.record("Background pane stole focus") }
		)
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 400, height: 300),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		defer {
			window.contentView = nil
			window.close()
		}
		let content = NSHostingView(rootView: BrowserSurface(tabID: .init(rawValue: UUID(10)), client: client, isFocused: false))
		window.contentView = content
		content.layoutSubtreeIfNeeded()
		window.update()
		try #require(host).addSubview(NSView())
	}

	@Test
	internal func replacingFocusedPageTransfersResponderAfterNativeViewChangesWindow() async throws {
		let originalID: BrowserCore.Tab.ID = .init(rawValue: UUID(10))
		let promotedID: BrowserCore.Tab.ID = .init(rawValue: UUID(11))
		let originalView: FocusableView = .init()
		let promotedView: FocusableView = .init()
		let pages: [BrowserCore.Tab.ID: NSView] = [
			originalID: originalView,
			promotedID: promotedView,
		]
		var focusRequests: [BrowserCore.Tab.ID] = []
		var focusHadWindow: [Bool] = []
		let client: BrowserSurfaceClient = .init(
			attach: { id, host in
				guard let page = pages[id]
				else { return }
				guard page.superview !== host
				else { return }

				host.subviews.forEach { $0.removeFromSuperview() }
				host.addSubview(page)
			},
			detach: { host in host.subviews.forEach { $0.removeFromSuperview() } },
			focus: { id in
				guard let page = pages[id]
				else { return }

				focusRequests.append(id)
				focusHadWindow.append(page.window != nil)
				page.window?.makeFirstResponder(page)
			}
		)
		let destination: NSWindow = .init(
			contentRect: .init(x: 0, y: 0, width: 400, height: 300),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		let source: NSWindow = .init(
			contentRect: .init(x: 0, y: 0, width: 400, height: 300),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		destination.isReleasedWhenClosed = false
		source.isReleasedWhenClosed = false
		defer {
			destination.contentView = nil
			source.contentView = nil
			destination.close()
			source.close()
		}

		let content = NSHostingView(rootView: BrowserSurface(tabID: originalID, client: client))
		destination.contentView = content
		content.layoutSubtreeIfNeeded()
		destination.update()
		source.contentView = NSView()
		source.contentView?.addSubview(promotedView)
		#expect(source.makeFirstResponder(promotedView))
		#expect(destination.firstResponder === originalView)

		promotedView.removeFromSuperview()
		content.rootView = BrowserSurface(tabID: promotedID, client: client)
		content.layoutSubtreeIfNeeded()
		destination.update()

		expectNoDifference(focusRequests, [originalID, promotedID])
		expectNoDifference(focusHadWindow, [true, true])
		#expect(promotedView.window === destination)
		#expect(destination.firstResponder === promotedView)
	}

	@Test
	internal func queuedNativeMountDoesNotStealFocusAfterPaneDeactivation() async throws {
		let tabID: BrowserCore.Tab.ID = .init(rawValue: UUID(10))
		var host: NSView?
		var focused: [BrowserCore.Tab.ID] = []
		let client: BrowserSurfaceClient = .init(
			attach: { _, view in host = view },
			detach: { _ in },
			focus: { focused.append($0) }
		)
		let window: NSWindow = .init(
			contentRect: .init(x: 0, y: 0, width: 400, height: 300),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		defer {
			window.contentView = nil
			window.close()
		}

		let content = NSHostingView(rootView: BrowserSurface(tabID: tabID, client: client))
		window.contentView = content
		content.layoutSubtreeIfNeeded()
		window.update()
		try #require(host).addSubview(NSView())
		content.rootView = BrowserSurface(tabID: tabID, client: client, isFocused: false)
		content.layoutSubtreeIfNeeded()
		window.update()

		for _ in 0..<20 {
			await Task.yield()
		}

		expectNoDifference(focused, [])
	}

	@Test(arguments: [false, true])
	internal func peekUnderlyingSurfaceCannotReclaimFocusOrBorrowedSession(_ isSuppressed: Bool) async throws {
		let tabID = BrowserCore.Tab.ID(rawValue: UUID(10))
		var host: NSView?
		var attached: Set<BrowserCore.Tab.ID> = []
		let client = BrowserSurfaceClient(
			attach: { id, view in
				attached.insert(id)
				host = view
			},
			detach: { host = $0 },
			focus: { _ in Issue.record("Underlying surface reclaimed Peek focus") }
		)
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 400, height: 300),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		defer {
			window.contentView = nil
			window.close()
		}
		let content = NSHostingView(
			rootView: BrowserSurface(tabID: tabID, client: client, isFocused: true)
				.environment(\.suppressedBrowserTabs, isSuppressed ? [tabID] : [])
				.environment(\.browserSurfaceIsInteractive, false)
		)
		window.contentView = content
		content.layoutSubtreeIfNeeded()
		window.update()
		try #require(host).addSubview(NSView())
		expectNoDifference(attached, isSuppressed ? [] : [tabID])
	}

}

@MainActor
private final class FocusableView: NSView {
	internal override var acceptsFirstResponder: Bool { true }
}
