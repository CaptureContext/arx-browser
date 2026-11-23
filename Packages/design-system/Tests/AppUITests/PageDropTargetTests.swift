import AppKit
@testable import AppUI
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// DEV-793: a tab dropped on the page goes to the page's drop zones, never to a sidebar that
/// isn't under the pointer. Drops go through the hosting view's `NSDraggingDestination` entry
/// points, the way AppKit delivers a real drag, at window points.
@MainActor
@Suite(
	.serialized,
	.renderTurn,
	.enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to lay out views")
)
internal struct PageDropTargetTests {
	@Test(arguments: [true, false])
	internal func theLeftSideOfThePageTakesTheDrop(pinned: Bool) async throws {
		let window = HostedWindow(isPinned: pinned)
		defer { window.close() }

		// 60 pt into the page: right of a pinned sidebar, where the next space's list sits; with
		// the sidebar hidden, where that list sits once the sidebar moves out of the window.
		let x = (pinned ? HostedWindow.sidebarWidth : 0) + 60
		let result = try await window.drop(at: .init(x: x, y: 300))
		#expect(result == .page(.leading), "\(result)")
	}

	@Test(arguments: [true, false])
	internal func eachEdgeOfThePageTakesTheDrop(pinned: Bool) async throws {
		let window = HostedWindow(isPinned: pinned)
		defer { window.close() }

		let page = window.pageFrame
		let points: [(CGPoint, SplitDropEdge)] = [
			(.init(x: page.minX + 40, y: page.midY), .leading),
			(.init(x: page.maxX - 40, y: page.midY), .trailing),
			(.init(x: page.midX, y: page.minY + 30), .top),
			(.init(x: page.midX, y: page.maxY - 30), .bottom),
		]
		for (point, edge) in points {
			let result = try await window.drop(at: point)
			#expect(result == .page(edge), "\(point): \(result)")
		}
	}

	/// Every point on the page, the strip along the sidebar included, goes to the page.
	@Test
	internal func noPointOnThePageGoesToTheSidebar() async throws {
		let window = HostedWindow(isPinned: true)
		defer { window.close() }

		let page = window.pageFrame
		for x in stride(from: page.minX + 2, to: page.maxX, by: page.width / 6) {
			for y in stride(from: page.minY + 2, to: page.maxY, by: page.height / 4) {
				let result = try await window.drop(at: .init(x: x, y: y))
				guard case .page = result else {
					Issue.record("(\(x), \(y)): \(result)")
					continue
				}
			}
		}
	}

	@Test
	internal func theSidebarStillTakesDropsOverItself() async throws {
		let window = HostedWindow(isPinned: true)
		defer { window.close() }

		let result = try await window.drop(at: .init(x: 100, y: 300))
		#expect(result == .sidebar(HostedWindow.first), "\(result)")
	}

	/// With the last space shown, the one before it sits left of the window and the sidebar
	/// belongs to the shown space alone.
	@Test
	internal func theShownSpaceTakesSidebarDropsAndThePageKeepsItsOwn() async throws {
		let window = HostedWindow(isPinned: true, selected: HostedWindow.second)
		defer { window.close() }

		let sidebar = try await window.drop(at: .init(x: 100, y: 300))
		#expect(sidebar == .sidebar(HostedWindow.second), "\(sidebar)")
		let page = try await window.drop(at: .init(x: HostedWindow.sidebarWidth + 60, y: 300))
		#expect(page == .page(.leading), "\(page)")
	}
}

private enum DropResult: Equatable, CustomStringConvertible {
	case none
	case page(SplitDropEdge)
	case sidebar(UUID)
	case spaceSelected(UUID)

	internal var description: String {
		switch self {
		case .none: "none"
		case let .page(edge): "page(\(edge))"
		case let .sidebar(id): "sidebar(\(id == HostedWindow.first ? "first" : "second"))"
		case let .spaceSelected(id): "selected(\(id == HostedWindow.first ? "first" : "second"))"
		}
	}
}

@MainActor
private final class HostedWindow {
	internal static let sidebarWidth: CGFloat = 260
	internal static let size: CGSize = .init(width: 1000, height: 600)
	internal nonisolated static let first: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
	internal nonisolated static let second: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
	internal static let draggedTab: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!

	private let window: NSWindow
	private let host: NSHostingView<AnyView>
	private var results: [DropResult] = []
	private(set) var pageFrame: CGRect = .zero

	internal init(
		isPinned: Bool,
		selected: UUID = HostedWindow.first
	) {
		self.host = NSHostingView(rootView: AnyView(EmptyView()))
		host.frame = CGRect(origin: .zero, size: Self.size)
		self.window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: Self.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host

		host.rootView = AnyView(
			BrowserSidebarLayout(isPinned: isPinned, width: Self.sidebarWidth) {
				SidebarPager(
					spaces: [Self.space(Self.first, tab: Self.draggedTab), Self.space(Self.second, tab: UUID())],
					selectedSpaceID: selected,
					onSelectSpace: { [weak self] in self?.results.append(.spaceSelected($0)) },
					onAction: { [weak self] space, action in
						if action.is(\.moveItems) { self?.results.append(.sidebar(space)) }
					},
					onCopyURL: {}
				) {
					EmptyView()
				}
			} page: {
				SplitDropZones(
					draggedTabID: Self.draggedTab,
					refusal: { _, _ in nil },
					onDrop: { [weak self] _, edge in self?.results.append(.page(edge)) }
				)
				.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [weak self] in
					self?.pageFrame = $0
				}
			}
		)
		settle()
	}

	private static func space(
		_ id: UUID,
		tab: UUID
	) -> SidebarSpace {
		.init(
			id: id,
			name: id == first ? "First" : "Second",
			favorites: [],
			savedItems: [],
			unpinnedTabs: (0..<6).map { index in
				SidebarItem(
					id: .tab(index == 0 ? tab : UUID()),
					title: "Tab \(index)",
					isPinned: false
				)
			},
			selectedID: nil,
			url: nil
		)
	}

	/// Drags a sidebar tab to a point given from the window's top-left corner and drops it there.
	internal func drop(at point: CGPoint) async throws -> DropResult {
		results = []
		let info = try StubDraggingInfo(
			window: window,
			location: .init(x: point.x, y: host.frame.height - point.y),
			transfer: SidebarTransfer(id: .tab(Self.draggedTab))
		)
		let destination: any NSDraggingDestination = dragDestination(at: info.draggingLocation) ?? host
		_ = destination.draggingEntered?(info)
		settle()
		_ = destination.draggingUpdated?(info)
		settle()
		_ = destination.prepareForDragOperation?(info)
		let accepted = destination.performDragOperation?(info) ?? false
		destination.concludeDragOperation?(info)
		for _ in 0..<20 where results.isEmpty {
			settle()
			try await Task.sleep(for: .milliseconds(20))
		}
		guard accepted || !results.isEmpty else { return .none }
		return results.first { if case .spaceSelected = $0 { false } else { true } } ?? results.first ?? .none
	}

	/// The view AppKit sends a drag to: the front-most one registered for its type whose frame
	/// holds the pointer. SwiftUI registers one `_PlatformDraggingDestinationView` per drop
	/// destination; those views don't answer `hitTest`, so their frames decide.
	private func dragDestination(at location: NSPoint) -> NSView? {
		func frontMost(in view: NSView) -> NSView? {
			for subview in view.subviews.reversed() {
				if let found = frontMost(in: subview) { return found }
			}
			let frame = view.convert(view.bounds, to: nil)
			return !view.registeredDraggedTypes.isEmpty && frame.contains(location) ? view : nil
		}
		return frontMost(in: host)
	}

	internal func close() {
		window.close()
	}

	private func settle() {
		for _ in 0..<3 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.02))
		}
	}
}

/// What AppKit hands a drag destination, for a drag that carries one sidebar transfer.
@MainActor
internal final class StubDraggingInfo: NSObject, @MainActor NSDraggingInfo {
	private let window: NSWindow
	private let location: NSPoint
	private let pasteboard: NSPasteboard
	private static var sequence: Int = 1_000

	internal init(
		window: NSWindow,
		location: NSPoint,
		transfer: SidebarTransfer
	) throws {
		self.window = window
		self.location = location
		self.pasteboard = NSPasteboard(name: .init("dev.capturecontext.arx.tests.drag.\(UUID().uuidString)"))
		pasteboard.clearContents()
		let item = NSPasteboardItem()
		item.setData(try JSONEncoder().encode(transfer), forType: .init(UTType.sidebarItem.identifier))
		pasteboard.writeObjects([item])
		Self.sequence += 1
		self.draggingSequenceNumber = Self.sequence
	}

	internal var draggingDestinationWindow: NSWindow? { window }
	internal var draggingSourceOperationMask: NSDragOperation { .move }
	internal var draggingLocation: NSPoint { location }
	internal var draggedImageLocation: NSPoint { location }
	internal var draggedImage: NSImage? { nil }
	internal var draggingPasteboard: NSPasteboard { pasteboard }
	internal var draggingSource: Any? { nil }
	internal let draggingSequenceNumber: Int
	internal var draggingFormation: NSDraggingFormation = .none
	internal var animatesToDestination: Bool = false
	internal var numberOfValidItemsForDrop: Int = 1
	internal var springLoadingHighlight: NSSpringLoadingHighlight { .none }

	internal func slideDraggedImage(to screenPoint: NSPoint) {}

	internal func enumerateDraggingItems(
		options enumOpts: NSDraggingItemEnumerationOptions = [],
		for view: NSView?,
		classes classArray: [AnyClass],
		searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
		using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
	) {}

	internal func resetSpringLoading() {}

	// AppKit's own dragging info answers these private selectors, and SwiftUI's drop handling
	// asks for them.
	private var lastOperation: UInt = 0

	@objc(_lastDragDestinationOperation)
	internal func lastDragDestinationOperation() -> UInt { lastOperation }

	@objc(_setLastDragDestinationOperation:)
	internal func setLastDragDestinationOperation(_ operation: UInt) { lastOperation = operation }
}
