@testable import AppUI
import CoreGraphics
import Foundation
import SwiftUI
import Testing

/// DEV-736: the Favorites grid's layout, where a drag over it lands, and site colors.
@MainActor
internal struct FavoritesDragTests {
	private static let width: CGFloat = 264
	private static let spacing: CGFloat = FavoritesGridLayout.spacing
	private static let height: CGFloat = FavoritesGridLayout.tileHeight

	// MARK: - Layout

	@Test(arguments: [(1, 1), (2, 2), (3, 3), (4, 4), (5, 4), (8, 4), (9, 4)])
	internal func tilesShareARowEquallyUpToFour(
		count: Int,
		columns: Int
	) {
		let layout = FavoritesGridLayout(itemCount: count, width: Self.width, availableHeight: 1_000)
		#expect(layout.columns == columns)
		let tileWidth = (Self.width - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns)
		#expect(layout.tileWidth == tileWidth)
		// Every row spans the full width, and every tile keeps the same height.
		let lastInRow = layout.frame(at: columns - 1)
		#expect(lastInRow.maxX == Self.width)
		for index in 0..<count {
			#expect(layout.frame(at: index).height == Self.height)
		}
	}

	@Test
	internal func oneFavoriteFillsTheRowAndTwoTakeHalves() {
		let one = FavoritesGridLayout(itemCount: 1, width: Self.width, availableHeight: 1_000)
		#expect(one.frame(at: 0) == CGRect(x: 0, y: 0, width: Self.width, height: Self.height))

		let two = FavoritesGridLayout(itemCount: 2, width: Self.width, availableHeight: 1_000)
		let half = (Self.width - Self.spacing) / 2
		#expect(two.frame(at: 0) == CGRect(x: 0, y: 0, width: half, height: Self.height))
		#expect(two.frame(at: 1) == CGRect(x: half + Self.spacing, y: 0, width: half, height: Self.height))
	}

	@Test
	internal func aFifthFavoriteWrapsAtQuarterWidth() {
		let layout = FavoritesGridLayout(itemCount: 5, width: Self.width, availableHeight: 1_000)
		let quarter = (Self.width - 3 * Self.spacing) / 4
		#expect(layout.rows == 2)
		#expect(layout.frame(at: 4) == CGRect(x: 0, y: Self.height + Self.spacing, width: quarter, height: Self.height))
		#expect(layout.contentHeight == 2 * Self.height + Self.spacing)
	}

	@Test
	internal func noWidthYetDrawsNothingWide() {
		let layout = FavoritesGridLayout(itemCount: 3, availableHeight: 600)
		#expect(layout.tileWidth == 0)
		#expect(FavoritesGridLayout(itemCount: 3, width: .nan, availableHeight: 600).tileWidth == 0)
	}

	@Test
	internal func keyboardNavigationFollowsTheColumnsActuallyShown() {
		let three = FavoritesGridLayout(itemCount: 3, width: Self.width, availableHeight: 600)

		// One row: nothing above or below.
		#expect(three.neighbor(of: 1, direction: .down) == nil)
		#expect(three.neighbor(of: 1, direction: .up) == nil)
		#expect(three.neighbor(of: 1, direction: .right) == 2)

		let six = FavoritesGridLayout(itemCount: 6, width: Self.width, availableHeight: 600)
		#expect(six.neighbor(of: 1, direction: .down) == 5)
		#expect(six.neighbor(of: 3, direction: .down) == 5)
		#expect(six.neighbor(of: 5, direction: .up) == 1)
	}

	// MARK: - Fitting the sidebar

	@Test(arguments: [240.0, 250, 286, 400, 480])
	internal func theGridIsExactlyAsWideAsItsOffered(width: CGFloat) {
		for count in 1...9 {
			let size = FavoritesGridStack.size(proposedWidth: width, cellCount: count)
			#expect(size.width == width)
			// Every tile, open cell included, stays inside that width.
			for cell in 0..<count {
				let frame = FavoritesGridStack.frame(cell: cell, cellCount: count, width: width)
				#expect(frame.minX >= 0)
				#expect(frame.maxX <= width + 0.0001)
			}
		}
	}

	@Test
	internal func tilesNeverSetTheGridsWidth() {
		// Asked for an ideal size, the grid claims no width, so its tiles can't widen the sidebar.
		#expect(FavoritesGridStack.size(proposedWidth: nil, cellCount: 4).width == 0)
		#expect(FavoritesGridStack.size(proposedWidth: .infinity, cellCount: 4).width == 0)
		#expect(FavoritesGridStack.size(proposedWidth: -10, cellCount: 4).width == 0)
	}

	@Test
	internal func narrowingTheSidebarShrinksEveryTile() {
		// The bug: after the sidebar narrowed from 400 to 250, four tiles stayed laid out for 400.
		let wide = FavoritesGridStack.frame(cell: 3, cellCount: 4, width: 400)
		let narrow = FavoritesGridStack.frame(cell: 3, cellCount: 4, width: 250)
		#expect(wide.maxX == 400)
		#expect(narrow.maxX == 250)
		#expect(narrow.width == (250 - 3 * Self.spacing) / 4)
	}

	@Test
	internal func aFavoriteDraggedOutStaysInsideTheGrid() {
		// Five favorites, the fifth dragged out toward the page: the grid has one row left, and
		// the tile, which draws nothing, sits in it rather than in the row that's gone.
		let height = FavoritesGridStack.size(proposedWidth: 264, cellCount: 4).height
		let frame = FavoritesGridStack.frame(cell: nil, cellCount: 4, width: 264)
		#expect(frame.maxY <= height)
		#expect(height == Self.height)
	}

	/// A few rows never scroll; only a collection taller than its share of the sidebar does, so its
	/// last favorites and the tabs below stay in reach.
	@Test
	internal func onlyACollectionTooTallForTheSidebarScrolls() {
		let maximum = FavoritesGrid.maximumHeight(600)
		#expect(maximum == 180)
		#expect(FavoritesGridLayout(itemCount: 5, availableHeight: 600).contentHeight <= maximum)
		#expect(FavoritesGridLayout(itemCount: 48, availableHeight: 600).contentHeight > maximum)
		// A very short sidebar still shows one row.
		#expect(FavoritesGrid.maximumHeight(40) == Self.height)
	}

	/// The grid is exactly as tall as its rows, before a drag, while a tile is out and after it's
	/// back, so nothing below it is covered and no room is kept for a row that isn't there.
	@Test
	internal func theGridIsAsTallAsTheRowsItLaysOut() {
		func height(_ cells: Int) -> CGFloat { FavoritesGridStack.size(proposedWidth: 264, cellCount: cells).height }
		#expect(height(5) == 2 * Self.height + Self.spacing)
		// Dragged out: four stay, one row.
		#expect(height(4) == Self.height)
		// Back over the grid with its cell held open: two rows again.
		#expect(
			height(FavoritesArrangement(staying: (0..<4).map { UUID($0) }.map { .tab($0) }, insertion: 4).cellCount)
			== 2 * Self.height + Self.spacing
		)

		// Dropped back: the five favorites in their order, two rows.
		#expect(
			height(FavoritesArrangement(order: (0..<5).map { UUID($0) }.map { .tab($0) }).cellCount)
			== 2 * Self.height + Self.spacing
		)
		#expect(height(0) == 0)
	}

	// MARK: - Dropping

	@Test
	internal func theCellUnderThePointerSplitsGapsBetweenNeighbours() {
		let layout = FavoritesGridLayout(itemCount: 4, width: Self.width, availableHeight: 600)
		let pitch = layout.tileWidth + Self.spacing
		#expect(layout.cell(at: CGPoint(x: 1, y: 10)) == 0)
		// Just short of the middle of the gap stays left; just past it goes right.
		#expect(layout.cell(at: CGPoint(x: pitch - Self.spacing / 2 - 0.5, y: 10)) == 0)
		#expect(layout.cell(at: CGPoint(x: pitch - Self.spacing / 2 + 0.5, y: 10)) == 1)
		// Past either edge clamps to the nearest cell.
		#expect(layout.cell(at: CGPoint(x: -40, y: -40)) == 0)
		#expect(layout.cell(at: CGPoint(x: 900, y: 900)) == 3)
	}

	@Test
	internal func aDragOpensACellAmongTheFavoritesThatStay() {
		// Three staying favorites plus the open cell: four quarter-width columns.
		let quarter = (Self.width - 3 * Self.spacing) / 4
		let pitch = quarter + Self.spacing
		for column in 0..<4 {
			let point = CGPoint(x: CGFloat(column) * pitch + quarter / 2, y: Self.height / 2)
			#expect(FavoritesDrop.insertion(at: point, staying: 3, width: Self.width, availableHeight: 600) == column)
		}

		// Below the last row lands at the end.
		let below = CGPoint(x: Self.width - 4, y: 400)
		#expect(FavoritesDrop.insertion(at: below, staying: 3, width: Self.width, availableHeight: 600) == 3)
		// With nothing to stay among, the drag takes the only cell.
		#expect(FavoritesDrop.insertion(at: .zero, staying: 0, width: Self.width, availableHeight: 600) == 0)
	}

	@Test
	internal func theOpenCellBecomesTheDropTarget() {
		let ids: [SidebarItem.ID] = [.tab(UUID(1)), .tab(UUID(2)), .tab(UUID(3))]
		#expect(FavoritesDrop.target(inserting: 0, among: ids) == .before(ids[0]))
		#expect(FavoritesDrop.target(inserting: 2, among: ids) == .before(ids[2]))
		#expect(FavoritesDrop.target(inserting: 3, among: ids) == .favoritesRoot)
		#expect(FavoritesDrop.target(inserting: 0, among: []) == .favoritesRoot)
	}

	@Test
	internal func theOthersMakeRoomForTheOpenCell() {
		let ids: [SidebarItem.ID] = [.tab(UUID(1)), .tab(UUID(2)), .tab(UUID(3))]
		let resting = FavoritesArrangement(staying: ids, insertion: nil)
		#expect(resting.cellCount == 3)
		#expect(resting.cells == [ids[0]: 0, ids[1]: 1, ids[2]: 2])

		let opened = FavoritesArrangement(staying: ids, insertion: 1)
		#expect(opened.cellCount == 4)
		#expect(opened.cells == [ids[0]: 0, ids[1]: 2, ids[2]: 3])

		// Out-of-range insertions clamp to the ends.
		#expect(FavoritesArrangement(staying: ids, insertion: 9).cells == resting.cells)
		#expect(FavoritesArrangement(staying: ids, insertion: -1).cells == [ids[0]: 1, ids[1]: 2, ids[2]: 3])
	}

	@Test
	internal func reorderingAFavoriteLeavesItsOwnCellOpenUnderThePointer() {
		// Dragging the second of three: two stay, and hovering where it was opens that cell again.
		let ids: [SidebarItem.ID] = [.tab(UUID(1)), .tab(UUID(2)), .tab(UUID(3))]
		let staying = [ids[0], ids[2]]
		let layout = FavoritesGridLayout(itemCount: 3, width: Self.width, availableHeight: 600)
		let original = layout.frame(at: 1)
		let insertion = FavoritesDrop.insertion(
			at: CGPoint(x: original.midX, y: original.midY),
			staying: staying.count,
			width: Self.width,
			availableHeight: 600
		)
		#expect(insertion == 1)
		#expect(FavoritesArrangement(staying: staying, insertion: insertion).cells == [ids[0]: 0, ids[2]: 2])
		#expect(FavoritesDrop.target(inserting: insertion, among: staying) == .before(ids[2]))
	}

	// MARK: - Preview

	@Test
	internal func thePreviewTakesTheShapeOfWhatItsOver() {
		let model = SidebarDragPreviewModel()
		let list = UUID(1)
		let favorites = UUID(2)
		let item = SidebarDragPreviewModel.Item(
			item: SidebarItem(id: .tab(UUID(9)), title: "GitHub"),
			fromFavorites: false
		)
		model.update(owner: list, location: .init(x: 10, y: 10), shape: .row(width: 200))
		#expect(model.hover == nil, "Nothing is dragged yet")

		model.begin(item)
		model.update(owner: list, location: .init(x: 100, y: 300), shape: .row(width: 200))
		#expect(model.frame == CGRect(
			x: 100 - SidebarDragPreviewModel.rowGrab,
			y: 300 - BrowserMetrics.Row.height / 2,
			width: 200,
			height: BrowserMetrics.Row.height
		))

		// Favorites takes over before the list says the pointer left.
		model.update(owner: favorites, location: .init(x: 60, y: 40), shape: .tile(.init(width: 80, height: 44)))
		model.leave(owner: list)
		#expect(model.shape == .tile(.init(width: 80, height: 44)))
		#expect(model.frame == CGRect(x: 20, y: 18, width: 80, height: 44))

		// Out over the page again, it's a row as wide as the list's.
		model.leave(owner: favorites)
		#expect(model.shape == .row(width: 200))

		model.end(.tab(UUID(8)))
		#expect(model.item == item, "Another item's drag ending changes nothing")
		model.end(item.id)
		#expect(model.item == nil)
		#expect(model.frame == nil)
	}

	@Test
	internal func aDropWithReduceMotionEndsAtOnce() {
		let model = SidebarDragPreviewModel()
		let item = SidebarDragPreviewModel.Item(
			item: SidebarItem(id: .tab(UUID(9)), title: "GitHub"),
			fromFavorites: true
		)
		model.begin(item)
		model.drop(settlingInto: CGRect(x: 0, y: 0, width: 80, height: 44), reduceMotion: true)
		#expect(model.item == nil)

		model.begin(item)
		model.drop(settlingInto: CGRect(x: 0, y: 0, width: 80, height: 44), reduceMotion: false)
		#expect(model.frame == CGRect(x: 0, y: 0, width: 80, height: 44))
		// The source's end arrives while it settles; the settle finishes it.
		model.end(item.id)
		#expect(model.item == item)

		// The source still reporting that drag after the drop doesn't restart it: a new session
		// would drop the order the grid holds and play the move again.
		let dropped = model.session
		model.begin(item, isNew: false)
		#expect(model.session == dropped)
		#expect(model.frame == CGRect(x: 0, y: 0, width: 80, height: 44))

		// Picking the same favorite up again while it settles is a new drag.
		let session = model.session
		model.begin(item)
		#expect(model.session == session + 1)
		#expect(model.frame == nil)
		// The source repeating itself during that drag is not, nor its page's title changing.
		model.begin(item)
		#expect(model.session == session + 1)
		let renamed = SidebarDragPreviewModel.Item(
			item: SidebarItem(id: .tab(UUID(9)), title: "GitHub · Pull requests"),
			fromFavorites: true
		)
		model.begin(renamed)
		#expect(model.item == renamed)
		#expect(model.session == session + 1)
	}

	@Test
	internal func aSelectionDragsAllItsItems() {
		let ids: [SidebarItem.ID] = [.tab(UUID(1)), .tab(UUID(2))]
		let selected = SidebarDragPreviewModel.Item(
			item: SidebarItem(id: ids[1], title: "Two", moveSelection: ids),
			fromFavorites: true
		)
		#expect(selected.ids == ids)
		let alone = SidebarDragPreviewModel.Item(
			item: SidebarItem(id: .tab(UUID(3)), title: "Three", moveSelection: ids),
			fromFavorites: true
		)
		#expect(alone.ids == [.tab(UUID(3))])
	}
}

/// DEV-736: brand colors for known sites, then the favicon's color, then the accent.
@MainActor
internal struct SiteColorTests {
	@Test(arguments: [
		("youtube.com", SiteBrandColor.solid(.init(hex: 0xFF0000))),
		("www.youtube.com", .solid(.init(hex: 0xFF0000))),
		("m.youtube.com", .solid(.init(hex: 0xFF0000))),
		("YOUTUBE.COM.", .solid(.init(hex: 0xFF0000))),
		("linear.app", .solid(.init(hex: 0x5E6AD2))),
		("open.spotify.com", .solid(.init(hex: 0x1DB954))),
		("www.icloud.com", .solid(.init(hex: 0x3693F3))),
		("web.telegram.org", .solid(.init(hex: 0x26A5E4))),
	])
	internal func knownSitesUseTheirBrandColor(
		host: String,
		color: SiteBrandColor
	) {
		#expect(SiteBrandTable.color(forHost: host) == color)
	}

	@Test
	internal func googleAndGmailUseTheMulticolorGradient() throws {
		let gmail = try #require(SiteBrandTable.color(forHost: "mail.google.com"))
		guard case let .gradient(colors) = gmail else {
			Issue.record("Gmail should be a gradient, got \(gmail)")
			return
		}
		#expect(colors.count == 4)
		#expect(SiteBrandTable.color(forHost: "www.google.com") == gmail)
		#expect(SiteBrandTable.color(forHost: "workspace.google.com") == gmail)
	}

	@Test
	internal func theLongestMatchingDomainWins() {
		// docs.google.com has its own entry, which beats google.com's.
		#expect(SiteBrandTable.color(forHost: "docs.google.com") == .solid(.init(hex: 0x4285F4)))
	}

	@Test
	internal func githubFollowsTheAppearance() throws {
		let github = try #require(SiteBrandTable.color(forHost: "github.com"))
		guard case let .adaptive(light, dark) = github else {
			Issue.record("GitHub should adapt to the appearance, got \(github)")
			return
		}
		#expect(light != dark)
		#expect(dark == .init(hex: 0xFFFFFF))
		#expect(SiteHighlight.brand(github).colors(scheme: .dark) == [Color(red: 1, green: 1, blue: 1)])
	}

	@Test(arguments: ["", "example.com", "notyoutube.com", "youtube.com.evil.net", "localhost"])
	internal func unknownOrLookalikeHostsHaveNoBrand(host: String) {
		#expect(SiteBrandTable.color(forHost: host) == nil)
	}

	@Test
	internal func theTableIsEasyToExtendWithoutDuplicates() {
		var seen: Set<String> = []
		for entry in SiteBrandTable.entries {
			for domain in entry.domains {
				#expect(domain == domain.lowercased())
				#expect(!seen.contains(domain), "\(domain) is listed twice")
				seen.insert(domain)
			}
		}
	}

	@Test
	internal func highlightsFallBackFromBrandToFaviconToAccent() {
		let favicon = SiteRGB(hex: 0x00AA55)
		#expect(SiteHighlight.resolve(host: "youtube.com", favicon: favicon) == .brand(.solid(.init(hex: 0xFF0000))))
		#expect(SiteHighlight.resolve(host: "example.com", favicon: favicon) == .favicon(favicon))
		#expect(SiteHighlight.resolve(host: "example.com", favicon: nil) == .accent)
		#expect(SiteHighlight.resolve(host: nil, favicon: nil) == .accent)
	}

	@Test
	internal func faviconColorsStayWithTheirProfile() {
		let cache = SiteColorCache()
		let url = URL(string: "https://example.com/page")!
		let mine = SidebarItem.SiteIcon(profileID: UUID(1), pageURL: url)
		let theirs = SidebarItem.SiteIcon(profileID: UUID(2), pageURL: url)
		cache.store(.init(hex: 0x00AA55), for: .init(mine))
		#expect(cache.highlight(for: mine) == .favicon(.init(hex: 0x00AA55)))
		#expect(cache.highlight(for: theirs) == .accent)
		#expect(cache.highlight(for: nil) == .accent)
	}

	@Test
	internal func theDominantColorIgnoresGraysAndTransparency() throws {
		// Half transparent, a quarter white, a quarter-ish green with a little red.
		let green = try #require(Self.image(width: 16, height: 16) { x, y in
			if y < 8 { return (0, 0, 0, 0) }
			if x < 4 { return (255, 255, 255, 255) }
			if x == 15 { return (230, 20, 20, 255) }
			return (20, 200, 80, 255)
		})
		let color = try #require(FaviconPalette.dominantColor(of: green))
		#expect(abs(color.red - 20 / 255) < 0.02)
		#expect(abs(color.green - 200 / 255) < 0.02)
		#expect(abs(color.blue - 80 / 255) < 0.02)

		let gray = try #require(Self.image(width: 8, height: 8) { x, _ in
			x < 4 ? (128, 128, 128, 255) : (0, 0, 0, 255)
		})
		#expect(FaviconPalette.dominantColor(of: gray) == nil)

		let clear = try #require(Self.image(width: 8, height: 8) { _, _ in (255, 0, 0, 0) })
		#expect(FaviconPalette.dominantColor(of: clear) == nil)
	}

	private static func image(
		width: Int,
		height: Int,
		pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
	) -> CGImage? {
		var bytes = [UInt8]()
		for y in 0..<height {
			for x in 0..<width {
				let (red, green, blue, alpha) = pixel(x, y)

				// Premultiplied, as the context expects.
				let scale = Double(alpha) / 255
				bytes += [UInt8(Double(red) * scale), UInt8(Double(green) * scale), UInt8(Double(blue) * scale), alpha]
			}
		}
		guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
		return CGImage(
			width: width,
			height: height,
			bitsPerComponent: 8,
			bitsPerPixel: 32,
			bytesPerRow: width * 4,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
			provider: provider,
			decode: nil,
			shouldInterpolate: false,
			intent: .defaultIntent
		)
	}
}

extension UUID {
	fileprivate init(_ value: Int) {
		self.init(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
	}
}

/// DEV-736: a reorder lands where the grid showed it, even when the drag's end arrives first.
internal struct FavoritesDropResolutionTests {
	private static let ids: [SidebarItem.ID] = (1...4).map { .tab(UUID($0)) }
	private static let width: CGFloat = 264

	private static func point(cell: Int) -> CGPoint {
		let frame = FavoritesGridLayout(itemCount: 4, width: width, availableHeight: 600).frame(at: cell)
		return .init(x: frame.midX, y: frame.midY)
	}

	@Test(arguments: [
		// Third to the end: Maxim's recording, which used to land back where it started.
		(2, 3, SidebarDropTarget.favoritesRoot),
		// Last to the start.
		(3, 0, .before(.tab(UUID(1)))),
		// One right, one left.
		(1, 2, .before(.tab(UUID(4)))),
		(2, 1, .before(.tab(UUID(2)))),
		// Back onto its own cell: before the one that followed it, so nothing moves.
		(1, 1, .before(.tab(UUID(3)))),
	])
	internal func theDroppedFavoriteLeavesTheGridBeforeItsCellIsFound(
		source: Int,
		cell: Int,
		target: SidebarDropTarget
	) {
		let drop = FavoritesDrop.resolve(
			dropping: [Self.ids[source]],
			at: Self.point(cell: cell),
			among: Self.ids,
			width: Self.width,
			availableHeight: 600
		)
		#expect(drop.insertion == cell)
		#expect(drop.cellCount == 4)
		#expect(drop.target == target)
		if case let .before(anchor) = drop.target {
			#expect(anchor != Self.ids[source], "A move can't anchor on the item it moves")
		}
	}

	@Test
	internal func aTabFromTheListOpensAFifthCell() {
		let drop = FavoritesDrop.resolve(
			dropping: [.tab(UUID(9))],
			at: CGPoint(x: Self.width - 2, y: 2),
			among: Self.ids,
			width: Self.width,
			availableHeight: 600
		)
		#expect(drop.cellCount == 5)
		#expect(drop.insertion == 3)
		#expect(drop.target == .before(Self.ids[3]))
	}
}
