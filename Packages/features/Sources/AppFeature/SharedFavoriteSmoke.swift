#if DEBUG
import AppKit
import AppUI
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// Switches between two spaces that both show the same Favorite, with a real Chromium page.
/// The page must stay in its host, in the window, on the same document (DEV-771).
internal enum SharedFavoriteSmoke {
	@MainActor
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine
	) async throws {
		guard
			let favorite = store.main.viewer.item.tab,
			engine.isAttached(favorite.id)
		else { throw Failure.missingSource }

		let sourceSpace = store.main.sidebar.spaceID
		let otherSpace = Space.ID(rawValue: UUID())
		store.send(.settings(.delegate(.changeOrganization(.createSpace(
			otherSpace,
			profileID: favorite.profileID,
			name: "Favorite smoke",
			icon: .stack
		)))))
		try await wait("Second space was not reconciled") {
			store.main.sidebar.organization.spaces.ids.contains(otherSpace)
		}

		let item = SidebarItem.ID.tab(favorite.id.rawValue)
		store.send(.main(.sidebar(.ui(.move(item, .favoritesRoot, sourceSpace)))))
		try await wait("The page did not become a Favorite") {
			store.workspace.profiles[id: favorite.profileID]?.favorites.contains(favorite.id) == true
			&& store.main.viewer.item.tab?.id == favorite.id
		}
		let live = try Live(engine: engine, tabID: favorite.id)

		for space in [otherSpace, sourceSpace, otherSpace, sourceSpace] {
			store.send(.main(.sidebar(.ui(.spaceSelected(space)))))
			try await wait("The space switch did not settle") {
				store.main.viewer.spaceID == space && store.main.viewer.item.tab?.id == favorite.id
			}

			// Let SwiftUI apply the switch before looking at the page's host.
			try await Task.sleep(for: .milliseconds(300))
			try live.verify(engine: engine)
		}

		store.send(.main(.sidebar(.ui(.move(item, .unpinnedRoot, sourceSpace)))))
		try await wait("The Favorite did not return to the space") {
			store.workspace.profiles[id: favorite.profileID]?.favorites.contains(favorite.id) == false
			&& store.main.viewer.item.tab?.id == favorite.id
		}
		print("ARX_SHARED_FAVORITE_SMOKE_SUCCESS")
	}

	/// The page as it was before the switches.
	@MainActor
	private struct Live {
		internal let tabID: BrowserCore.Tab.ID
		internal let view: NSView
		internal let host: NSView
		internal let snapshot: BrowserSessionSnapshot

		internal init(
			engine: ChromiumBrowserEngine,
			tabID: BrowserCore.Tab.ID
		) throws {
			guard
				let view = engine.hostView(tabID),
				let host = view.superview,
				let snapshot = engine.client.snapshot(tabID)
			else { throw Failure.missingSource }

			self.tabID = tabID
			self.view = view
			self.host = host
			self.snapshot = snapshot
		}

		/// A new host means SwiftUI rebuilt the page card and the page left the window on the way;
		/// a new document or URL means the page navigated.
		internal func verify(engine: ChromiumBrowserEngine) throws {
			guard
				engine.hostView(tabID) === view,
				view.superview === host,
				view.window != nil,
				engine.isAttached(tabID)
			else { throw Failure.rehosted }

			guard
				let current = engine.client.snapshot(tabID),
				current.nativePageID == snapshot.nativePageID,
				current.documentRevision == snapshot.documentRevision,
				current.navigation.url == snapshot.navigation.url
			else { throw Failure.navigated }
		}
	}

	@MainActor
	private static func wait(
		_ message: String,
		until ready: () -> Bool
	) async throws {
		for _ in 0..<150 {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(100))
		}
		throw Failure.timedOut(message)
	}

	private enum Failure: Error {
		case missingSource
		case rehosted
		case navigated
		case timedOut(String)
	}
}
#endif
