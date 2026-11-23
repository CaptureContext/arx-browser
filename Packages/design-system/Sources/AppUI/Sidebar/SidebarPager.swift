import BrowserCore
import SwiftUI

/// A space's presentation snapshot, independent of persistence and browser sessions.
public struct SidebarSpace: Identifiable, Equatable, Sendable {
	public let id: UUID
	public var name: String
	public var symbol: String

	/// Neighbouring spaces with the same profile share one pinned URL bar and Favorites.
	public var profileID: UUID?
	public var profileName: String?
	public var isExpanded: Bool
	public var favorites: [SidebarItem]
	public var savedItems: [SidebarItem]
	public var unpinnedTabs: [SidebarItem]
	public var selectedID: SidebarItem.ID?
	public var url: URL?

	public init(
		id: UUID,
		name: String,
		symbol: String = "square.stack",
		profileID: UUID? = nil,
		profileName: String? = nil,
		isExpanded: Bool = true,
		favorites: [SidebarItem],
		savedItems: [SidebarItem],
		unpinnedTabs: [SidebarItem],
		selectedID: SidebarItem.ID?,
		url: URL?
	) {
		self.id = id
		self.name = name
		self.symbol = symbol
		self.profileID = profileID
		self.profileName = profileName
		self.isExpanded = isExpanded
		self.favorites = favorites
		self.savedItems = savedItems
		self.unpinnedTabs = unpinnedTabs
		self.selectedID = selectedID
		self.url = url
	}
}

/// What the pager reads about every space: who it belongs to and its pinned header. Cheap to build
/// for all of them, unlike the space's tabs, which only its page reads while it's mounted.
public struct SidebarSpaceSummary: Identifiable, Equatable, Sendable {
	public let id: UUID

	/// Neighbouring spaces with the same profile share one pinned URL bar and Favorites.
	public var profileID: UUID?
	public var profileName: String?

	/// Whether anything is pinned in the space, which retires the empty space's hint for good.
	public var hasSavedItems: Bool
	public var favorites: [SidebarItem]
	public var selectedID: SidebarItem.ID?
	public var url: URL?

	public init(
		id: UUID,
		profileID: UUID? = nil,
		profileName: String? = nil,
		hasSavedItems: Bool,
		favorites: [SidebarItem],
		selectedID: SidebarItem.ID?,
		url: URL?
	) {
		self.id = id
		self.profileID = profileID
		self.profileName = profileName
		self.hasSavedItems = hasSavedItems
		self.favorites = favorites
		self.selectedID = selectedID
		self.url = url
	}
}

extension SidebarSpace {
	public var summary: SidebarSpaceSummary {
		.init(
			id: id,
			profileID: profileID,
			profileName: profileName,
			hasSavedItems: !savedItems.isEmpty,
			favorites: favorites,
			selectedID: selectedID,
			url: url
		)
	}
}

/// What the pager's mounted spaces follow: the selection among the spaces there are.
private struct SidebarMountRequest: Equatable {
	fileprivate var selected: UUID
	fileprivate var spaces: [UUID]

	fileprivate init(
		selected: UUID,
		spaces: [UUID]
	) {
		self.selected = selected
		self.spaces = spaces
	}
}

/// Where the sidebar should rest. The same space at a new index means spaces changed around it.
private struct SidebarPlacement: Equatable {
	fileprivate var id: UUID
	fileprivate var index: Int
	fileprivate var isLibraryOpen: Bool

	fileprivate init(
		id: UUID,
		index: Int,
		isLibraryOpen: Bool
	) {
		self.id = id
		self.index = index
		self.isLibraryOpen = isLibraryOpen
	}
}

/// The window's spaces side by side, swiped between, with the toolbar, pinned headers and footer.
///
/// Only the spaces the track shows and the few nearest the selected space, on either side, are
/// mounted, each reading its own tabs through `space` from its own page. So a change in one
/// space's tabs re-renders only that space, and the work stays the same however many tabs the
/// other spaces hold. Only the toolbar's buttons read `navigation`, so the active tab's loads
/// re-render neither the pager nor any space.
public struct SidebarPager<Footer: View, LibraryPanel: View>: View {
	private let spaces: [SidebarSpaceSummary]
	private let space: (UUID) -> SidebarSpace?
	private let selectedSpaceID: UUID
	private let onSelectSpace: (UUID) -> Void
	private let onAction: (UUID, SidebarAction) -> Void
	private let onCopyURL: () -> Void
	private let onRevealSpace: (_ spaceID: UUID?, _ isLanding: Bool) -> Void
	private let navigation: () -> SidebarNavigation
	private let isNewTabPending: Bool
	private let splitIDs: Set<SidebarItem.ID>
	private let canClearTabs: Bool
	private let library: SidebarLibrary?
	private let spaceMenu: ((UUID) -> AnyView)?

	/// Offered from the profile capsule; `nil` leaves the capsule as a plain label.
	private let profileMenu: ((UUID) -> AnyView)?
	private let canRenameSpaces: Bool

	/// The Create a Space page past the last space (DEV-1109); `nil` keeps the last space's
	/// rubber band alone.
	private let spaceCreation: SidebarSpaceCreation?

	/// Counts choices of the selected space made elsewhere, such as the switcher's button for it,
	/// which leave the Create a Space page for it (DEV-1126). The pager's own selections never
	/// choose the space already selected, so they never count.
	private let spaceReselections: Int

	/// Where the window's background reads which spaces the sidebar stands between (DEV-1310).
	private let reveal: SidebarSpaceReveal?

	/// A space's appearance over its profile's, which its page takes on while another space is
	/// selected; nil leaves every page the window's.
	private let spaceAppearance: ((UUID) -> AppearanceOverride?)?
	private let footer: Footer
	private let libraryPanel: LibraryPanel

	/// How far the active space's rows have scrolled under the footer, read only by the footer's
	/// edge, so a scroll near the list's end doesn't run the pager's body every frame (DEV-1235).
	@SwiftUI.State
	private var footerEdge: SidebarScrollEdges

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@Environment(\.sidebarWidths)
	private var widths

	@Environment(\.isEnabled)
	private var isEnabled

	@Environment(\.sidebarAcceptsDrops)
	private var acceptsDrops

	@SwiftUI.State
	private var track: SidebarTrackDriver

	@SwiftUI.State
	private var pinnedHeights: [UUID: CGFloat]

	/// The space a sidebar drag started in, which stays mounted until the drag ends.
	@SwiftUI.State
	private var drags: SidebarPagerDrags

	/// The space on screen, which its drop destinations ask about.
	@SwiftUI.State
	private var activeSpace: SidebarActiveSpace

	/// The spaces kept mounted beside the ones the track shows.
	@SwiftUI.State
	private var mounts: SidebarPagerMounts

	/// Where each space was scrolled, for a space that comes back after being unmounted.
	@SwiftUI.State
	private var scrollMemory: SidebarScrollMemory

	/// What the pages report from their own hosting view (`SidebarSlidLayer`).
	@SwiftUI.State
	private var pagesBridge: SidebarLayerBridge

	/// The same for each profile's Favorites, in a layer of their own.
	@SwiftUI.State
	private var favoritesBridges: SidebarLayerBridges

	/// The pinned URL bar's height, which every space's rows start under.
	@SwiftUI.State
	private var urlBarHeight: CGFloat

	/// Once anything has been pinned anywhere, the hint has done its job for good.
	@AppStorage("sidebar.hasPinnedItem")
	private var hasPinnedItem: Bool = false

	/// - Parameters:
	///   - space: A space's name, state and tabs, read by its page while it's mounted. Reading the
	///     window's state here ties a re-render to that space alone.
	///   - navigation: The active tab's navigation, read only by the toolbar's buttons.
	///   - spaceMenu: A space's ⋯ menu, built when the menu reads it.
	public init(
		spaces: [SidebarSpaceSummary],
		selectedSpaceID: UUID,
		space: @escaping (UUID) -> SidebarSpace?,
		navigation: @escaping () -> SidebarNavigation = { .init() },
		isNewTabPending: Bool = false,
		splitIDs: Set<SidebarItem.ID> = [],
		canClearTabs: Bool = true,
		library: SidebarLibrary? = nil,
		spaceMenu: ((UUID) -> AnyView)? = nil,
		profileMenu: ((UUID) -> AnyView)? = nil,
		canRenameSpaces: Bool = true,
		spaceCreation: SidebarSpaceCreation? = nil,
		spaceReselections: Int = 0,
		reveal: SidebarSpaceReveal? = nil,
		spaceAppearance: ((UUID) -> AppearanceOverride?)? = nil,
		onSelectSpace: @escaping (UUID) -> Void,
		onRevealSpace: @escaping (_ spaceID: UUID?, _ isLanding: Bool) -> Void = { _, _ in },
		onAction: @escaping (UUID, SidebarAction) -> Void,
		onCopyURL: @escaping () -> Void,
		@ViewBuilder footer: () -> Footer,
		@ViewBuilder libraryPanel: () -> LibraryPanel
	) {
		self.spaces = spaces
		self.space = space
		self.spaceReselections = spaceReselections
		self.reveal = reveal
		self.spaceAppearance = spaceAppearance
		self.selectedSpaceID = selectedSpaceID
		self.onSelectSpace = onSelectSpace
		self.onRevealSpace = onRevealSpace
		self.onAction = onAction
		self.onCopyURL = onCopyURL
		self.navigation = navigation
		self.isNewTabPending = isNewTabPending
		self.splitIDs = splitIDs
		self.canClearTabs = canClearTabs
		self.library = library
		self.spaceMenu = spaceMenu
		self.profileMenu = profileMenu
		self.canRenameSpaces = canRenameSpaces
		let spaceCreation: SidebarSpaceCreation? = SidebarSpaceCreation.isEnabled ? spaceCreation : nil
		self.spaceCreation = spaceCreation
		let track: SidebarTrack = .init(
			spaceIndex: spaces.firstIndex { $0.id == selectedSpaceID } ?? 0,
			libraryProgress: library?.progress.wrappedValue ?? 0,
			pageCount: spaces.count,
			pageWidth: BrowserMetrics.Library.minimumWidth,
			libraryWidth: BrowserMetrics.Library.minimumWidth,
			hasLibrary: library != nil,
			offersCreation: spaceCreation != nil
		)
		self._track = .init(initialValue: .init(track: track))
		self.footer = footer()
		self.libraryPanel = libraryPanel()
		self._pinnedHeights = .init(initialValue: [:])
		self._footerEdge = .init(initialValue: .init())
		self._drags = .init(initialValue: .init())
		self._activeSpace = .init(initialValue: .init(id: library?.isOpen == true ? nil : selectedSpaceID))

		// The selected space and its neighbours at once; the rest of what's wanted at rest.
		self._mounts = .init(initialValue: .init(Self.wantedSpaces(around: selectedSpaceID, in: spaces, reach: 1)))
		self._scrollMemory = .init(initialValue: .init())
		self._pagesBridge = .init(initialValue: .init())
		self._favoritesBridges = .init(initialValue: .init())
		self._urlBarHeight = .init(initialValue: 0)
	}

	/// Every space's tabs at once, as previews and tests build them.
	public init(
		spaces: [SidebarSpace],
		selectedSpaceID: UUID,
		navigation: SidebarNavigation = .init(),
		isNewTabPending: Bool = false,
		splitIDs: Set<SidebarItem.ID> = [],
		canClearTabs: Bool = true,
		library: SidebarLibrary? = nil,
		spaceMenu: ((UUID) -> AnyView)? = nil,
		profileMenu: ((UUID) -> AnyView)? = nil,
		canRenameSpaces: Bool = true,
		spaceCreation: SidebarSpaceCreation? = nil,
		onSelectSpace: @escaping (UUID) -> Void,
		onRevealSpace: @escaping (_ spaceID: UUID?, _ isLanding: Bool) -> Void = { _, _ in },
		onAction: @escaping (UUID, SidebarAction) -> Void,
		onCopyURL: @escaping () -> Void,
		@ViewBuilder footer: () -> Footer,
		@ViewBuilder libraryPanel: () -> LibraryPanel
	) {
		self.init(
			spaces: spaces.map(\.summary),
			selectedSpaceID: selectedSpaceID,
			space: { id in spaces.first { $0.id == id } },
			navigation: { navigation },
			isNewTabPending: isNewTabPending,
			splitIDs: splitIDs,
			canClearTabs: canClearTabs,
			library: library,
			spaceMenu: spaceMenu,
			profileMenu: profileMenu,
			canRenameSpaces: canRenameSpaces,
			spaceCreation: spaceCreation,
			onSelectSpace: onSelectSpace,
			onRevealSpace: onRevealSpace,
			onAction: onAction,
			onCopyURL: onCopyURL,
			footer: footer,
			libraryPanel: libraryPanel
		)
	}

	public var body: some View {
		let _ = SidebarRenderTrace.pagerBody()
		ZStack(alignment: .topLeading) {
			spacesLayer
				.frame(width: widths.base)
				.frame(maxWidth: .infinity, alignment: .leading)
				.modifier(SidebarLibraryTransition(
					progress: libraryProgress,
					range: 0...0.5,
					travel: BrowserMetrics.Library.spacesTravel,
					hiddenScale: BrowserMetrics.Library.spacesHiddenScale,
					isOutgoing: true,
					reducesMotion: reduceMotion
				))
				.allowsHitTesting(!isLibraryOpen)
				.siteIconsShown(libraryProgress < 1)
				.environment(\.sidebarAcceptsDrops, acceptsDrops && !isLibraryOpen)

				// The Library's Spaces page shows the same tabs; only the surface on screen opens a picker.
				.environment(\.sidebarPresentsTabIconPicker, !isLibraryOpen)
				.accessibilityHidden(isLibraryOpen)

			// Always mounted, so the first frame of a swipe has nothing to build.
			if let library {
				// Overlaid, because a page wider than the sidebar would push the whole sidebar off to the left.
				Color.clear
					.overlay(alignment: .leading) {
						SidebarLibraryPage(library: library, panel: libraryPanel)

							// Its panel stays mounted while the Library is shut.
							.siteIconsShown(libraryProgress > 0)
							.frame(width: libraryWidth)
							.offset(x: (libraryProgress - 1) * libraryWidth)
					}
					.allowsHitTesting(library.isOpen)
					.environment(\.sidebarAcceptsDrops, acceptsDrops && library.isOpen)
					.environment(\.sidebarPresentsTabIconPicker, library.isOpen)
					.accessibilityHidden(!library.isOpen)
					.onPreferenceChange(SidebarNestedScrollKey.self) { track.nestedScrollChanged($0) }
			}

			// Above both layers: the window controls keep their place across the transition.
			SidebarToolbar(
				navigation: navigation,
				libraryProgress: libraryProgress,
				isLibraryOpen: isLibraryOpen,
				profileName: spaces.first { $0.id == selectedSpaceID }?.profileName,
				profileMenu: profileMenu.map { menu in { [selectedSpaceID] in menu(selectedSpaceID) } }
			) {
				onAction(selectedSpaceID, .toggleSidebar)
			}
			.frame(width: widths.base)
		}
		.clipped()
		.background {
			SidebarTrackMonitor(
				driver: track,
				handlers: .init(
					isEnabled: isEnabled,
					reduceMotion: reduceMotion,
					progressChanged: setLibraryProgress,
					committed: commit,
					tracked: reveal,
					landing: land,
					creationLanded: landOnCreation,
					willSlide: { [mounts, spaces] index in

						// Built before the sidebar slides to it, not while it does.
						if spaces.indices.contains(index) { mounts.keep(spaces[index].id) }
					}
				),
				pageCount: spaces.count,
				selectedIndex: spaces.firstIndex { $0.id == selectedSpaceID } ?? 0,
				spaceIDs: spaces.map(\.id),
				reveal: reveal,
				libraryWidth: libraryWidth,
				hasLibrary: library != nil,
				offersCreation: spaceCreation != nil
			)
		}
		.onChange(of: spaces.contains(where: \.hasSavedItems), initial: true) { _, hasPinned in
			if hasPinned { hasPinnedItem = true }
		}
		.onChange(of: placement) { previous, placement in

			// Built before the sidebar slides to it, not while it does.
			mounts.keep(placement.id)
			if previous.id == placement.id, previous.isLibraryOpen == placement.isLibraryOpen {
				track.shift(by: placement.index - previous.index)
			} else {
				track.present(spaceIndex: placement.index, isLibraryOpen: placement.isLibraryOpen)
			}
		}
		.onChange(of: spaceReselections) { track.closeCreation() }
		.onChange(of: activeSpaceID, initial: true) { _, id in activeSpace.id = id }
		.task(id: SidebarMountRequest(selected: selectedSpaceID, spaces: spaces.map(\.id))) { [mounts, track] in
			await Self.mount(
				Self.wantedSpaces(around: selectedSpaceID, in: spaces),
				among: Set(spaces.map(\.id)),
				in: mounts,
				onceRested: track
			)
		}
	}

	/// How long the sidebar has rested on a selection before the pager builds the selected
	/// space's neighbours, so the slide there has landed and been drawn.
	private static var mountDelay: Duration { .milliseconds(200) }

	/// The pause between one page built or let go and the next.
	private static var mountPause: Duration { .milliseconds(120) }

	/// The selected space, then the spaces around it, the nearest first and the one after before
	/// the one before, as many as the pager keeps: what's kept mounted, the most wanted first.
	///
	/// With only its neighbours wanted, a second jump made before the sidebar had rested built
	/// the space it went to as the swipe uncovered it, under the fingers (DEV-1310).
	private static func wantedSpaces(
		around selectedSpaceID: UUID,
		in spaces: [SidebarSpaceSummary],
		reach: Int = SidebarPagerMounts.capacity / 2
	) -> [UUID] {
		guard let index = spaces.firstIndex(where: { $0.id == selectedSpaceID })
		else { return [] }

		let around: [Int] = (1...max(reach, 1)).flatMap { [index + $0, index - $0] }
		return ([index] + around)
			.filter(spaces.indices.contains)
			.map { spaces[$0].id }
	}

	/// Builds the selected space's neighbours and lets go of spaces visited long ago, a page at
	/// a time, once the sidebar has rested on the selection. A new selection starts it over.
	private static func mount(
		_ wanted: [UUID],
		among existing: Set<UUID>,
		in mounts: SidebarPagerMounts,
		onceRested track: SidebarTrackDriver
	) async {
		do {
			// The whole delay at rest, however long the slide there took.
			repeat {
				while !track.isAtRest { try await Task.sleep(for: mountPause) }
				try await Task.sleep(for: mountDelay)
			} while !track.isAtRest
			while mounts.step(toward: wanted, among: existing) {
				repeat {
					try await Task.sleep(for: mountPause)
				} while !track.isAtRest
			}
		} catch {
			return
		}
	}

	private var libraryProgress: CGFloat { library?.progress.wrappedValue ?? 0 }

	private var libraryWidth: CGFloat { widths.expanded ?? BrowserMetrics.Library.minimumWidth }

	private var isLibraryOpen: Bool { library?.isOpen == true }

	private var placement: SidebarPlacement {
		.init(
			id: selectedSpaceID,
			index: spaces.firstIndex { $0.id == selectedSpaceID } ?? 0,
			isLibraryOpen: isLibraryOpen
		)
	}

	/// The space that takes clicks and drops: none while the Library or the Create a Space page
	/// covers the spaces.
	private var activeSpaceID: UUID? {
		isLibraryOpen || track.isCreationOpen ? nil : selectedSpaceID
	}

	private func isActive(_ space: SidebarSpaceSummary) -> Bool {
		space.id == selectedSpaceID && !isLibraryOpen && !track.isCreationOpen
	}

	/// Selects the space first, because selecting one closes the Library.
	private func commit(
		isLibraryOpen: Bool,
		spaceIndex: Int
	) {
		if spaces.indices.contains(spaceIndex), spaces[spaceIndex].id != selectedSpaceID {
			onSelectSpace(spaces[spaceIndex].id)
		}
		if library?.isOpen != isLibraryOpen { library?.setOpen(isLibraryOpen) }
	}

	/// Landing on the Create a Space page shows the last space under it, with the Library shut;
	/// returns whether that changed anything for the window to present back.
	private func landOnCreation(lastSpace: Int) -> Bool {
		let selectsLast = spaces.indices.contains(lastSpace) && spaces[lastSpace].id != selectedSpaceID
		let shutsLibrary = library?.isOpen == true
		commit(isLibraryOpen: false, spaceIndex: lastSpace)
		return selectsLast || shutsLibrary
	}

	/// The space a swipe uncovers next to the selected one, so its page can get ready.
	private func reveal(_ track: SidebarTrack) {
		let selected = spaces.firstIndex { $0.id == selectedSpaceID }
		let revealed = selected.flatMap { track.revealedSpace(from: $0) }
		onRevealSpace(revealed.map { spaces[$0].id }, false)
	}

	/// The space the sidebar is settling on, whose page can show before it's selected.
	private func land(_ stop: SidebarTrack.Stop?) {
		guard
			case let .space(index) = stop,
			spaces.indices.contains(index),
			spaces[index].id != selectedSpaceID
		else { return onRevealSpace(nil, false) }

		onRevealSpace(spaces[index].id, true)
	}

	private func setLibraryProgress(_ progress: CGFloat) {
		guard library?.progress.wrappedValue != progress else { return }
		var transaction = Transaction()
		transaction.disablesAnimations = true
		withTransaction(transaction) {
			library?.progress.wrappedValue = progress
		}
	}

	private var spacesLayer: some View {
		VStack(spacing: 0) {
			Color.clear.frame(height: BrowserMetrics.Toolbar.height)
			pages
			footer
				.environment(\.sidebarSpaceSlide, .init(driver: track, spaces: spaces.map(\.id)))
				.background {
					// Rows scrolling down under the footer get the same progressive edge as under
					// the header, from the bottom (DEV-826).
					SidebarFooterEdge(edges: footerEdge)
				}
				.zIndex(1)
		}
	}

	private func pageToAdjacentSpace(_ edge: SidebarDragEdge) {
		guard let index = spaces.firstIndex(where: { $0.id == selectedSpaceID })
		else { return }
		let adjacent = index + (edge == .leading ? -1 : 1)
		if spaces.indices.contains(adjacent) { onSelectSpace(spaces[adjacent].id) }
	}

	private var pinnedGroups: [SidebarPinnedGroup] { SidebarPinnedGroup.groups(of: spaces) }

	/// The selected space speaks for its group; a group off screen shows its first space.
	private func representative(of group: SidebarPinnedGroup) -> SidebarSpaceSummary {
		spaces[group.spaces].first { $0.id == selectedSpaceID } ?? spaces[group.spaces.lowerBound]
	}

	private func isActive(_ group: SidebarPinnedGroup) -> Bool {
		spaces[group.spaces].contains { $0.id == selectedSpaceID } && !isLibraryOpen && !track.isCreationOpen
	}

	/// How far a space's rows start below the top: under the URL bar and its profile's Favorites.
	private func pinnedHeight(ofSpaceAt index: Int) -> CGFloat {
		let favorites: CGFloat = pinnedGroups
			.first { $0.spaces.contains(index) }
			.flatMap { pinnedHeights[$0.id] } ?? 0
		return urlBarHeight + favorites
	}

	/// The URL bar, pinned: it stays where it is through every swipe and only shows another
	/// space's address (DEV-1310). It used to belong to each profile's header
	/// and slide away with it.
	private func urlBar(pageWidth: CGFloat) -> some View {
		let isShown: Bool = !isLibraryOpen && !track.isCreationOpen
		return URLBar(
			url: spaces.first { $0.id == selectedSpaceID }?.url,
			onActivate: { onAction(selectedSpaceID, .openCommandBar) },
			onCopy: onCopyURL
		)
		.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
		.padding(.bottom, BrowserMetrics.Sidebar.sectionSpacing)
		.frame(width: pageWidth)
		.onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
			urlBarHeight = $0
		}

		// The Create a Space page has the sidebar to itself.
		.opacity(track.isCreationOpen ? 0 : 1)
		.animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: track.isCreationOpen)
		.transformPreference(CommandBarAnchorsKey.self) { anchors in
			if !isShown { anchors.url = nil }
		}
		.accessibilityHidden(!isShown)
		.allowsHitTesting(isShown)
	}

	/// A profile's Favorites, on a layer of their own that the track slides: still through that
	/// profile's spaces, and away with the pages past them.
	private func favorites(
		_ group: SidebarPinnedGroup,
		pageWidth: CGFloat,
		availableHeight: CGFloat
	) -> some View {
		let space = representative(of: group)
		let isPending = isNewTabPending && space.id == selectedSpaceID
		let bridge: SidebarLayerBridge = favoritesBridges.bridge(for: group.id)

		// The last space's give belongs to the page, not to what is pinned above it. With the
		// Create a Space page after it (DEV-1109), the last Favorites go with their space
		// instead, so the page arrives with nothing over it.
		let end: CGFloat = CGFloat(spaces.count - 1) + (spaceCreation != nil ? 1 : 0)
		return SidebarLayerFittedFrame(bridge: bridge, width: pageWidth) {
			SidebarSlidLayer(
				driver: track,
				bridge: bridge,
				pageWidth: pageWidth,
				size: .fitted(limit: availableHeight),
				offset: { position in group.offset(at: min(max(position, 0), end)) }
			) {
				FavoritesGrid(
					items: space.favorites,
					profileID: space.profileID,
					// A pending new tab takes over the highlight until the command bar resolves it.
					selectedID: isPending ? nil : space.selectedID,
					splitIDs: isPending || space.id != selectedSpaceID ? [] : splitIDs,
					availableHeight: availableHeight,
					onAction: { onAction(space.id, $0) }
				)
				.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
				.padding(.bottom, BrowserMetrics.Section.dividerSpacing)
				.frame(width: pageWidth)
				.modifier(SidebarPinnedIconsShown(driver: track, group: group))
			}
		}
		.background { SidebarLayerPreviewRelay(bridge: bridge) }
		.onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
			pinnedHeights[group.id] = $0
		}
		.offset(y: urlBarHeight)
		.accessibilityHidden(!isActive(group))
		.allowsHitTesting(isActive(group))

		// Another group's Favorites sit beside the sidebar, over the page (DEV-793).
		.environment(\.sidebarAcceptsDrops, acceptsDrops && isActive(group))
		.environment(\.sidebarPresentsTabIconPicker, isActive(group) && !isLibraryOpen)
		.modifier(SidebarPageAppearance(
			override: space.id == selectedSpaceID ? nil : spaceAppearance?(space.id)
		))
	}

	private var pages: some View {
		GeometryReader { geometry in

			// Read outside the geometry-change closure, which is `@Sendable` while `GeometryProxy` is not.
			let pageWidth: CGFloat = geometry.size.width

			// Every space keeps its place, mounted or not, so the track's offset is the same. A
			// drag's source space stays mounted while hover paging moves it offscreen, keeping its
			// drag provider alive.
			// Read here, in the pager's own hosting view. The pages below are built in theirs,
			// where SwiftUI doesn't follow this view's state, so a value read there went stale.
			let pinnedHeights: [CGFloat] = spaces.indices.map(pinnedHeight(ofSpaceAt:))
			let showsPinnedHint: Bool = !hasPinnedItem
			let pageHeight: CGFloat = geometry.size.height
			let drags: SidebarPagerDrags = drags
			let mounts: SidebarPagerMounts = mounts
			let scrollMemory: SidebarScrollMemory = scrollMemory
			let activeSpace: SidebarActiveSpace = activeSpace

			// In a hosting view of their own, on a layer the track slides (`SidebarSlidLayer`):
			// a frame of a slide lays nothing out.
			SidebarSlidLayer(
				driver: track,
				bridge: pagesBridge,
				pageWidth: pageWidth,
				size: .pages(spaces.count + (spaceCreation == nil ? 0 : 1)),
				offset: { position in -position }
			) {
			HStack(spacing: 0) {
				ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
					SidebarPagerSlot(
						driver: track,
						drags: drags,
						mounts: mounts,
						index: index,
						spaceID: space.id
					) {
						SidebarPagerPage(
							id: space.id,
							space: self.space,
							splitIDs: space.id == selectedSpaceID ? splitIDs : [],
							isNewTabPending: isNewTabPending && space.id == selectedSpaceID,
							canClearTabs: canClearTabs,
							pinnedHeight: pinnedHeights[index],
							spaceMenu: spaceMenu.map { menu in { menu(space.id) } },
							showsPinnedHint: showsPinnedHint,
							canRenameSpace: canRenameSpaces,
							onDragAtEdge: pageToAdjacentSpace,
							onAction: { onAction(space.id, $0) }
						)
					}
					.environment(\.sidebarDragOrigin, .init(drags: drags, spaceID: space.id))
					.environment(\.sidebarScrollSlot, .init(memory: scrollMemory, spaceID: space.id))
					.frame(width: pageWidth, height: pageHeight)
					.transformPreference(SidebarFooterOverlapKey.self) { overlap in
						if !isActive(space) { overlap = 0 }
					}
					.accessibilityHidden(!isActive(space))
					.allowsHitTesting(isActive(space))

					// The next space's list sits right of the sidebar, over the page's leading side, and
					// SwiftUI registers its drop destination there despite hit-testing being off (DEV-793).
					.environment(\.sidebarDropGate, .init(active: activeSpace, spaceID: space.id))
					.modifier(SidebarPageAppearance(
						override: space.id == selectedSpaceID ? nil : spaceAppearance?(space.id)
					))
					.id(space.id)
				}

				if let spaceCreation {
					SidebarSpaceCreationSlot(driver: track) {
						SidebarSpaceCreationPage(
							creation: spaceCreation,
							profileID: spaces.first { $0.id == selectedSpaceID }?.profileID,
							onCreate: { track.creationSubmitted() },
							onCancel: { track.closeCreation() }
						)
					}
					.frame(width: pageWidth, height: pageHeight)
					.accessibilityHidden(!track.isCreationOpen)
					.allowsHitTesting(track.isCreationOpen)
				}
			}
			.onPreferenceChange(SidebarFooterOverlapKey.self) { [footerEdge] in footerEdge.footer = $0 }
			}
			.frame(width: pageWidth, height: geometry.size.height)
			.background { SidebarLayerPreviewRelay(bridge: pagesBridge) }
			.onGeometryChange(for: CGFloat.self) { _ in pageWidth } action: {
				track.pageWidthChanged($0)
			}

			ForEach(pinnedGroups) { group in
				favorites(
					group,
					pageWidth: pageWidth,
					availableHeight: geometry.size.height
				)
			}

			urlBar(pageWidth: pageWidth)
		}
		.overlay(alignment: .trailing) {
			if spaceCreation != nil { SidebarSpaceCreationBubble(driver: track) }
		}
		.clipped()
	}
}

extension SidebarPager where LibraryPanel == EmptyView {
	public init(
		spaces: [SidebarSpace],
		selectedSpaceID: UUID,
		navigation: SidebarNavigation = .init(),
		isNewTabPending: Bool = false,
		splitIDs: Set<SidebarItem.ID> = [],
		canClearTabs: Bool = true,
		library: SidebarLibrary? = nil,
		onSelectSpace: @escaping (UUID) -> Void,
		onAction: @escaping (UUID, SidebarAction) -> Void,
		onCopyURL: @escaping () -> Void,
		@ViewBuilder footer: () -> Footer
	) {
		self.init(
			spaces: spaces,
			selectedSpaceID: selectedSpaceID,
			navigation: navigation,
			isNewTabPending: isNewTabPending,
			splitIDs: splitIDs,
			canClearTabs: canClearTabs,
			library: library,
			onSelectSpace: onSelectSpace,
			onAction: onAction,
			onCopyURL: onCopyURL,
			footer: footer,
			libraryPanel: { EmptyView() }
		)
	}
}

/// The progressive edge over the pager's footer, as strong as the active space's rows have
/// scrolled under it.
private struct SidebarFooterEdge: View {
	private let edges: SidebarScrollEdges

	fileprivate init(edges: SidebarScrollEdges) {
		self.edges = edges
	}

	fileprivate var body: some View {
		ArxProgressiveEdge(
			veil: .chrome,
			edge: .bottom,
			ramp: SidebarScrollEdgeMetrics.ramp,
			style: .sidebar
		)
		.padding(.top, -SidebarScrollEdgeMetrics.overhang)
		.opacity(edges.footer)
	}
}
