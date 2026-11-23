import AppKit
@testable import AppUI
import Foundation
import Observation
import SwiftUI
import Testing

/// DEV-940 follow-up: a relaunch fetches the missing icons of the rows on screen only. Rows
/// mounted off screen (the spaces next to the shown one, the other profiles' Favorites, the
/// shut Library) read only the icons already on this Mac, and a collapsed folder's rows don't
/// exist until it opens. Switching space or opening a folder fetches what then shows.
@MainActor
@Suite(
	.serialized,
	.renderTurn,
	.enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to lay out views")
)
internal struct SidebarSiteIconDemandTests {
	@Test
	internal func aRelaunchFetchesOnlyTheIconsOnScreen() async throws {
		let sidebar = HostedSidebar(spaceCount: 3, selected: 1)
		defer { sidebar.close() }

		let fetched = sidebar.loader.fetched
		#expect(fetched.contains(Page.tab(0, inSpace: 1)))
		#expect(fetched.contains(Page.favorite(ofSpace: 1)))
		#expect(fetched.allSatisfy { $0.space == 1 }, "\(fetched.map(\.name).sorted())")
		// The list is lazy: rows far below the fold aren't built, so they ask for nothing.
		#expect(!fetched.contains(Page.tab(tabsPerSpace - 1, inSpace: 1)))
		// A collapsed folder's rows don't exist.
		#expect(!sidebar.loader.requested.contains(Page.folderTab(0, inSpace: 1)))

		// The neighbouring spaces are mounted, ready for a swipe, and show only what's stored.
		let cached = sidebar.loader.cached
		#expect(cached.contains(Page.tab(0, inSpace: 0)))
		#expect(cached.contains(Page.tab(0, inSpace: 2)))
		#expect(cached.contains(Page.favorite(ofSpace: 0)))
		#expect(cached.contains(Page.favorite(ofSpace: 2)))
	}

	@Test
	internal func switchingSpaceFetchesThatSpacesIcons() async throws {
		let sidebar = HostedSidebar(spaceCount: 3, selected: 1)
		defer { sidebar.close() }
		#expect(!sidebar.loader.fetched.contains(Page.tab(0, inSpace: 2)))

		sidebar.update(settling: true) { $0.selectedSpaceID = HostedSidebar.spaceID(2) }

		let fetched = sidebar.loader.fetched
		#expect(fetched.contains(Page.tab(0, inSpace: 2)))
		#expect(fetched.contains(Page.favorite(ofSpace: 2)))
		#expect(!fetched.contains(Page.tab(0, inSpace: 0)))
		#expect(!fetched.contains(Page.favorite(ofSpace: 0)))
	}

	@Test
	internal func openingAFolderFetchesItsRowsIcons() async throws {
		let sidebar = HostedSidebar(spaceCount: 3, selected: 1)
		defer { sidebar.close() }
		#expect(!sidebar.loader.requested.contains(Page.folderTab(0, inSpace: 1)))

		sidebar.update { $0.spaces[1].savedItems[0].isExpanded = true }

		let fetched = sidebar.loader.fetched
		for index in 0..<folderTabCount {
			#expect(fetched.contains(Page.folderTab(index, inSpace: 1)))
		}

		// A neighbouring space's folder opening off screen still fetches nothing.
		sidebar.update { $0.spaces[2].savedItems[0].isExpanded = true }
		#expect(!sidebar.loader.fetched.contains(Page.folderTab(0, inSpace: 2)))
		#expect(sidebar.loader.cached.contains(Page.folderTab(0, inSpace: 2)))
	}

	@Test
	internal func aHiddenSidebarFetchesNothing() async throws {
		let sidebar = HostedSidebar(spaceCount: 3, selected: 1, isShown: false)
		defer { sidebar.close() }

		#expect(sidebar.loader.fetched.isEmpty, "\(sidebar.loader.fetched.map(\.name).sorted())")
		#expect(sidebar.loader.cached.contains(Page.tab(0, inSpace: 1)))
	}
}

private let tabsPerSpace: Int = 40
private let folderTabCount: Int = 3

/// A row's page, named after its space and place so a test can tell which view asked.
private enum Page {
	internal static func tab(
		_ index: Int,
		inSpace space: Int
	) -> SidebarItem.SiteIcon {
		icon("s\(space)-tab\(index)", space: space)
	}

	internal static func folderTab(
		_ index: Int,
		inSpace space: Int
	) -> SidebarItem.SiteIcon {
		icon("s\(space)-folder\(index)", space: space)
	}

	internal static func favorite(ofSpace space: Int) -> SidebarItem.SiteIcon {
		icon("s\(space)-favorite", space: space)
	}

	/// Each space has a profile of its own, so each shows its own Favorites.
	internal static func profile(_ space: Int) -> UUID {
		UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", 0xF00 + space))!
	}

	private static func icon(
		_ name: String,
		space: Int
	) -> SidebarItem.SiteIcon {
		.init(profileID: profile(space), pageURL: URL(string: "https://\(name).fixture.invalid/")!)
	}
}

extension SidebarItem.SiteIcon {
	fileprivate var name: String { pageURL.host() ?? "" }

	fileprivate var space: Int? {
		name.split(separator: "-").first.flatMap { Int($0.dropFirst()) }
	}
}

/// Records which icons views asked for, and whether they may fetch them. Every stream stays
/// open with nothing, as for a site with no stored icon.
@MainActor
private final class RecordingSiteIcons {
	private(set) var fetched: Set<SidebarItem.SiteIcon> = []
	private(set) var cached: Set<SidebarItem.SiteIcon> = []

	internal var requested: Set<SidebarItem.SiteIcon> { fetched.union(cached) }

	internal var loader: BrowserSiteIconLoader {
		.init(
			icons: { [self] key in
				fetched.insert(key)
				return .init { $0.yield(nil) }
			},
			cachedIcons: { [self] key in
				cached.insert(key)
				return .init { $0.yield(nil) }
			}
		)
	}
}

private func uuid(
	_ space: Int,
	_ index: Int
) -> UUID {
	UUID(uuidString: String(format: "00000000-0000-0000-%04x-%012x", space, index))!
}

@MainActor
@Observable
private final class SidebarInputs {
	internal var spaces: [SidebarSpace]
	internal var selectedSpaceID: UUID
	internal var isShown: Bool

	internal init(
		spaceCount: Int,
		selected: Int,
		isShown: Bool
	) {
		self.spaces = (0..<spaceCount).map { space in
			let folder = SidebarItem(
				id: .folder(uuid(space, 0xF0)),
				title: "Folder",
				children: (0..<folderTabCount).map { index in
					SidebarItem(
						id: .tab(uuid(space, 0x100 + index)),
						title: "Folder tab \(index)",
						siteIcon: Page.folderTab(index, inSpace: space)
					)
				}
			)
			return SidebarSpace(
				id: HostedSidebar.spaceID(space),
				name: "Space \(space)",
				profileID: Page.profile(space),
				favorites: [
					SidebarItem(
						id: .tab(uuid(space, 0x200)),
						title: "Favorite",
						siteIcon: Page.favorite(ofSpace: space)
					),
				],
				savedItems: [folder],
				unpinnedTabs: (0..<tabsPerSpace).map { index in
					SidebarItem(
						id: .tab(uuid(space, index)),
						title: "Tab \(index)",
						siteIcon: Page.tab(index, inSpace: space),
						isPinned: false
					)
				},
				selectedID: .tab(uuid(space, 0)),
				url: nil
			)
		}
		self.selectedSpaceID = HostedSidebar.spaceID(selected)
		self.isShown = isShown
	}
}

/// The window's sidebar as the window builds it: the pager in the docked or hidden layout,
/// with the window's icon loader.
private struct SidebarRoot: View {
	internal let inputs: SidebarInputs
	internal let loader: BrowserSiteIconLoader

	internal var body: some View {
		BrowserSidebarLayout(isPinned: inputs.isShown) {
			SidebarPager(
				spaces: inputs.spaces.map(\.summary),
				selectedSpaceID: inputs.selectedSpaceID,
				space: { [inputs] id in inputs.spaces.first { $0.id == id } },
				onSelectSpace: { [inputs] in inputs.selectedSpaceID = $0 },
				onAction: { _, _ in },
				onCopyURL: {}
			) {
				Color.clear.frame(height: 40)
			} libraryPanel: {
				EmptyView()
			}
		} page: {
			Color.clear
		}
		.environment(\.browserSiteIcons, loader)
	}
}

@MainActor
private final class HostedSidebar {
	internal static let size: CGSize = .init(width: 900, height: 700)

	internal let loader: RecordingSiteIcons
	private let inputs: SidebarInputs
	private let window: NSWindow
	private let host: NSHostingView<SidebarRoot>

	internal init(
		spaceCount: Int,
		selected: Int,
		isShown: Bool = true
	) {
		self.loader = .init()
		self.inputs = .init(spaceCount: spaceCount, selected: selected, isShown: isShown)
		self.host = NSHostingView(rootView: SidebarRoot(inputs: inputs, loader: loader.loader))
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

		// The track's spring runs on the screen's display link, so the window sits on a screen,
		// transparent and passing every click through.
		if let screen = NSScreen.main {
			window.alphaValue = 0
			window.ignoresMouseEvents = true
			window.setFrameOrigin(screen.visibleFrame.origin)
			window.orderFrontRegardless()
		}
		settle()
	}

	internal static func spaceID(_ index: Int) -> UUID { uuid(index, 0xFFFF) }

	/// Changes the inputs and lets the window catch up, and when `settling`, lets the track's
	/// spring come to rest.
	internal func update(
		settling: Bool = false,
		_ change: (SidebarInputs) -> Void
	) {
		change(inputs)
		settle()
		guard settling else { return }
		for _ in 0..<60 {
			RunLoop.main.run(until: .now.addingTimeInterval(0.03))
			host.layoutSubtreeIfNeeded()
		}
		settle()
	}

	internal func close() {
		window.close()
	}

	/// Lays out and lets the icons' tasks start.
	private func settle() {
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.02))
		}
	}
}
