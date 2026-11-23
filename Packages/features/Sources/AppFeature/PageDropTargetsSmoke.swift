#if DEBUG
import AppKit
import AppUI
import BrowserCore
import Foundation
import _ComposableArchitecture

/// DEV-793: over the page, only the page's own drop zones may take a dragged tab. The pager keeps
/// every space's sidebar laid out in a row, with the next space's list right of the sidebar, over
/// the page, and SwiftUI registers a drop destination's view over its frame whether or not it's on
/// screen. This checks the window as AppKit sees it: with another space in the row, no SwiftUI drop
/// view covers the page, with the sidebar pinned or collapsed.
///
/// A real drag needs the window server's event tap, which the smoke doesn't have; the page's own
/// zones appear only while a sidebar row drags, so none are expected here. The hosted
/// `PageDropTargetTests` in AppUI drive drops at each of the page's four zones.
internal enum PageDropTargetsSmoke {
	@MainActor
	internal static func run(
		store: StoreOf<AppFeature>,
		window: NSWindow?
	) async throws {
		guard let window, let current = store.main.viewer.item.tab
		else { throw Failure.missingSource }

		// A space after the shown one, so its list is the page's neighbour.
		let neighbour = Space.ID(rawValue: UUID())
		store.send(.settings(.delegate(.changeOrganization(.createSpace(
			neighbour,
			profileID: current.profileID,
			name: "Drop targets smoke",
			icon: .stack
		)))))
		try await wait("The neighbouring space was not reconciled") {
			store.main.sidebar.organization.spaces.ids.contains(neighbour)
		}
		guard store.main.sidebar.spaceID != neighbour else { throw Failure.missingSource }

		let wasPinned = store.main.sidebar.sidebarIsVisible
		defer {
			if store.main.sidebar.sidebarIsVisible != wasPinned {
				store.send(.main(.sidebar(.ui(.sidebar(.toggleSidebar)))))
			}
			store.send(.settings(.delegate(.changeOrganization(.removeSpace(neighbour)))))
		}

		for pinned in [true, false] {
			if store.main.sidebar.sidebarIsVisible != pinned {
				store.send(.main(.sidebar(.ui(.sidebar(.toggleSidebar)))))
			}
			try await wait("The sidebar did not \(pinned ? "pin" : "collapse")") {
				store.main.sidebar.sidebarIsVisible == pinned
			}

			// Let the sidebar's animation finish and SwiftUI place the drop views.
			try await Task.sleep(for: .milliseconds(600))

			guard let content = window.contentView else { throw Failure.missingSource }
			let bounds = content.convert(content.bounds, to: nil)
			let sidebarEdge = pinned ? bounds.minX + CGFloat(store.main.sidebarWidth) + 1 : bounds.minX
			let page = CGRect(x: sidebarEdge, y: bounds.minY, width: bounds.maxX - sidebarEdge, height: bounds.height)

			let covering = dropViews(in: content).filter { frame in
				let overlap = frame.intersection(page)
				return !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5
			}
			guard covering.isEmpty else {
				throw Failure.pageCovered("\(pinned ? "pinned" : "collapsed"): \(covering) over \(page)")
			}
			print("ARX_PAGE_DROP_TARGETS_\(pinned ? "PINNED" : "COLLAPSED")_CLEAR")
		}
		print("ARX_PAGE_DROP_TARGETS_SMOKE_SUCCESS")
	}

	/// The window frames of SwiftUI's drop destination views, which AppKit picks by frame alone.
	@MainActor
	private static func dropViews(in view: NSView) -> [CGRect] {
		var frames: [CGRect] = []
		func walk(_ view: NSView) {
			if
				!view.isHiddenOrHasHiddenAncestor,
				!view.registeredDraggedTypes.isEmpty,
				String(describing: type(of: view)).contains("PlatformDraggingDestinationView")
			{
				frames.append(view.convert(view.bounds, to: nil))
			}
			view.subviews.forEach(walk)
		}
		walk(view)
		return frames
	}

	@MainActor
	private static func wait(
		_ message: String,
		until ready: () -> Bool
	) async throws {
		for _ in 0..<100 {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(100))
		}
		throw Failure.timedOut(message)
	}

	private enum Failure: Error {
		case missingSource
		case pageCovered(String)
		case timedOut(String)
	}
}
#endif
