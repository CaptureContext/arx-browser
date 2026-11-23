import AppKit
@testable import AppUI
import Foundation
import SwiftUI
import Testing

/// DEV-937: rows measure their frames only while a drag needs them, and a drop still lands where
/// the pointer is: between rows, into a folder, or onto an open tab or a Split View row to split.
/// Drops go through the hosting view's `NSDraggingDestination` entry points, as AppKit delivers
/// a real drag.
@MainActor
@Suite(
	.serialized,
	.renderTurn,
	.enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to lay out views")
)
internal struct SidebarRowDropTests {
	@Test(arguments: [false, true])
	internal func everyRowTakesDropsAboveItIntoItAndBelowIt(withPreviewHost: Bool) async throws {
		let sidebar = HostedDropSidebar(withPreviewHost: withPreviewHost)
		defer { sidebar.close() }

		var targets: [SidebarDropTarget] = []

		// From the space's name down past the last row.
		for y in stride(from: CGFloat(40), to: 460, by: 5) {
			if let target = try await sidebar.drop(at: .init(x: 120, y: y)), targets.last != target {
				targets.append(target)
			}
		}

		let folder = HostedDropSidebar.folder
		#expect(targets.contains(.inside(folder)), "\(targets)")
		for child in HostedDropSidebar.folderChildren {
			#expect(targets.contains(.before(child)), "\(targets)")
			// A pinned tab's row forms a split too (DEV-1006).
			#expect(targets.contains(.split(child)), "\(targets)")
		}
		for tab in HostedDropSidebar.tabs {
			#expect(targets.contains(.before(tab)), "\(targets)")
			#expect(targets.contains(.split(tab)), "\(targets)")
		}
		#expect(targets.contains(.split(HostedDropSidebar.splitRow)), "\(targets)")
		#expect(targets.contains(.unpinnedRoot), "\(targets)")

		// Top to bottom, as the rows are.
		let order: [SidebarItem.ID] = targets.compactMap { target in
			guard case let .split(id) = target else { return nil }
			return id
		}
		#expect(order == HostedDropSidebar.folderChildren + HostedDropSidebar.tabs + [HostedDropSidebar.splitRow], "\(targets)")
	}

	#if DEBUG
	// Frames are counted only in Debug builds.
	@Test
	internal func rowsMeasureTheirFramesOnlyWhileADragIsUnderway() {
		let preview = SidebarDragPreviewModel()
		let sidebar = HostedDropSidebar(withPreviewHost: false, preview: preview)
		defer { sidebar.close() }

		let idle = sidebar.recording { $0.renameFirstTab("Renamed") }
		#expect(idle[.rowFrame] == nil, "\(idle)")

		let item = SidebarItem(id: HostedDropSidebar.dragged, title: "Dragged", isPinned: false)
		let dragging = sidebar.recording { _ in preview.begin(.init(item: item, fromFavorites: false)) }
		#expect((dragging[.rowFrame] ?? 0) > 0, "\(dragging)")

		_ = sidebar.recording { _ in preview.end(item.id) }
		let ended = sidebar.recording { $0.renameFirstTab("Again") }
		#expect(ended[.rowFrame] == nil, "\(ended)")
	}
	#endif
}

@MainActor
private final class DropSidebarInputs {
	internal var firstTitle: String = "Tab 0"

	internal func renameFirstTab(_ title: String) {
		firstTitle = title
	}
}

@MainActor
private final class HostedDropSidebar {
	internal static let size: CGSize = .init(width: 260, height: 700)
	internal static let folder: SidebarItem.ID = .folder(uuid(100))
	internal static let folderChildren: [SidebarItem.ID] = [.tab(uuid(101)), .tab(uuid(102))]
	internal static let tabs: [SidebarItem.ID] = (0..<4).map { .tab(uuid(200 + $0)) }
	internal static let splitRow: SidebarItem.ID = .tab(uuid(300))
	internal static let dragged: SidebarItem.ID = .tab(uuid(999))

	private let inputs: DropSidebarInputs
	private let window: NSWindow
	private let host: NSHostingView<AnyView>
	private let withPreviewHost: Bool
	private let preview: SidebarDragPreviewModel?
	private var actions: [SidebarAction]

	internal init(
		withPreviewHost: Bool,
		preview: SidebarDragPreviewModel? = nil
	) {
		self.inputs = .init()
		self.withPreviewHost = withPreviewHost
		self.preview = preview
		self.actions = []
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
		render()
		settle()
	}

	#if DEBUG
	internal func recording(_ change: (DropSidebarInputs) -> Void) -> [SidebarRenderTrace.Subject: Int] {
		SidebarRenderTrace.startRecording()
		defer { SidebarRenderTrace.stopRecording() }
		change(inputs)
		render()
		settle()
		return SidebarRenderTrace.views ?? [:]
	}
	#endif

	/// Drags a tab from elsewhere to a point given from the window's top-left corner, drops it
	/// there, and returns where the sidebar moved it.
	internal func drop(at point: CGPoint) async throws -> SidebarDropTarget? {
		actions = []
		let info = try StubDraggingInfo(
			window: window,
			location: .init(x: point.x, y: host.frame.height - point.y),
			transfer: SidebarTransfer(id: Self.dragged)
		)
		guard let view = dragDestination(at: info.draggingLocation) else { return nil }
		let destination: any NSDraggingDestination = view
		_ = destination.draggingEntered?(info)
		settle(quickly: true)
		_ = destination.draggingUpdated?(info)
		settle(quickly: true)
		_ = destination.prepareForDragOperation?(info)
		_ = destination.performDragOperation?(info)
		destination.concludeDragOperation?(info)
		for _ in 0..<3 where actions.isEmpty {
			settle(quickly: true)
			try await Task.sleep(for: .milliseconds(5))
		}
		destination.draggingExited?(info)
		settle(quickly: true)
		for action in actions {
			if case let .moveItems(_, target) = action { return target }
		}
		return nil
	}

	internal func close() {
		window.close()
	}

	private func render() {
		let firstTitle = inputs.firstTitle
		let sidebar = BrowserSidebar(
			spaceName: "Space",
			savedItems: [
				SidebarItem(
					id: Self.folder,
					title: "Folder",
					children: Self.folderChildren.map { SidebarItem(id: $0, title: "Child", isPinned: true) },
					isExpanded: true
				),
			],
			unpinnedTabs: Self.tabs.enumerated().map { index, id in
				SidebarItem(id: id, title: index == 0 ? firstTitle : "Tab \(index)", isPinned: false)
			} + [
				SidebarItem(
					id: Self.splitRow,
					title: "Split",
					isPinned: false,
					split: .init(
						id: uuid(301),
						members: [
							SidebarItem(id: Self.splitRow, title: "Left", isPinned: false),
							SidebarItem(id: .tab(uuid(302)), title: "Right", isPinned: false),
						]
					)
				),
			],
			selectedID: nil,
			onAction: { [weak self] in self?.actions.append($0) }
		)
		if withPreviewHost {
			host.rootView = AnyView(sidebar.sidebarDragPreviewHost())
		} else {
			host.rootView = AnyView(sidebar.environment(\.sidebarDragPreview, preview))
		}
	}

	/// The front-most drop destination under the pointer, as AppKit picks one.
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

	private func settle(quickly: Bool = false) {
		for _ in 0..<(quickly ? 2 : 3) {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(quickly ? 0.005 : 0.02))
		}
	}
}

private func uuid(_ value: Int) -> UUID {
	UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
}
