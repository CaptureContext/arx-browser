import SwiftUI

/// Shared chrome dimensions, in points. Colors live in `BrowserTheme`.
public enum BrowserMetrics {
	/// The page inset in the tinted window.
	public enum PageCard {
		public static let inset: CGFloat = 8
		public static let cornerRadius: CGFloat = 8
		public static let borderWidth: CGFloat = 0.5
		public static let shadow: BrowserShadow = .init(opacity: 0.12, radius: 3, y: 1)

		/// How solid the card is under a homepage that paints no ground of its own, so the
		/// window's background, the space's theme, shows through it.
		public static let seeThroughOpacity: Double = 0.55

		/// The web viewport's clip. Under a header, such as the developer header, its top
		/// corners are square so the page meets the header; the card keeps its outer corners
		/// (DEV-786).
		public static func viewportShape(squaresTopCorners: Bool) -> UnevenRoundedRectangle {
			let top = squaresTopCorners ? 0 : cornerRadius
			return .init(
				cornerRadii: .init(
					topLeading: top,
					bottomLeading: cornerRadius,
					bottomTrailing: cornerRadius,
					topTrailing: top
				),
				style: .continuous
			)
		}
	}

	public enum IconPicker {
		public static let width: CGFloat = 304
		public static let padding: CGFloat = 14
		public static let spacing: CGFloat = 10
		public static let columns: Int = 8
		public static let cellSize: CGFloat = 34
		public static let gridHeight: CGFloat = 238
		public static let symbolSize: CGFloat = 16
		public static let segmentHeight: CGFloat = 28
		public static let segmentInset: CGFloat = 3
	}

	/// The Arx mark in the middle of a pane with no page (DEV-829). It's solid where the globe it
	/// replaced was hairline, so it sits a step quieter than secondary text.
	public enum EmptyPage {
		public static let markWidth: CGFloat = 44
		public static let markOpacity: Double = 0.6

		/// The Customizable homepage's corner button and the controls it opens.
		public static let buttonSide: CGFloat = 24
		public static let editorWidth: CGFloat = 360
		public static let editorCornerRadius: CGFloat = 12
		public static let editorInset: CGFloat = 10
	}

	/// A tab whose navigation became a download, with no page of its own to show (DEV-1116).
	public enum DownloadingPage {
		public static let iconSide: CGFloat = 64
		public static let spacing: CGFloat = 18
		public static let progressWidth: CGFloat = 280
		public static let width: CGFloat = 440
	}

	/// Measured from a reference bar: a slim strip at the page's top right.
	/// The find bar (DEV-1272): a search field and Close on floating raised glass, as a folder's
	/// hover preview searches, at the page's top right.
	public enum FindBar {
		/// The field and Close beside it.
		public static let width: CGFloat = 320
		public static let height: CGFloat = ArxFloatingGlass.controlHeight
		public static let inset: CGFloat = 12
		public static let spacing: CGFloat = 8
		public static let cornerRadius: CGFloat = ArxFloatingGlass.controlCornerRadius

		/// The match count's, a point under the field's text.
		public static let countFontSize: CGFloat = ArxFloatingGlass.fontSize - 1
	}

	public enum FloatingPanel {
		public static let cornerRadius: CGFloat = 16
		public static let anchorGap: CGFloat = 8

		/// A movable panel's grab strip along its top edge, and the capsule drawn in it (DEV-1286).
		public static let handleHeight: CGFloat = 20
		public static let handleWidth: CGFloat = 36
		public static let handleThickness: CGFloat = 5
	}

	public enum CreateMenu {
		public static let width: CGFloat = 220
		public static let padding: CGFloat = 8
		public static let rowHeight: CGFloat = 36
		public static let rowHorizontalPadding: CGFloat = 10
		public static let iconWidth: CGFloat = 20
		public static let iconSpacing: CGFloat = 12
		public static let symbolSize: CGFloat = 15
		public static let dividerSpacing: CGFloat = 6
	}

	public enum Sidebar {
		/// Inset of rows, the URL pill, and favorites from the sidebar edges.
		public static let horizontalPadding: CGFloat = 8
		public static let sectionSpacing: CGFloat = 8

		/// Holding a dragged item this close to the sidebar's side pages to the next space.
		public static let dragEdgeWidth: CGFloat = 16
	}

	/// The fixed sidebar row holding the window controls and navigation buttons.
	public enum Toolbar {
		public static let height: CGFloat = 40
		public static let symbolSize: CGFloat = 16
		public static let buttonSize: CGFloat = 28
		public static let buttonCornerRadius: CGFloat = ArxControlShape.cornerRadius(forSide: buttonSize)
		public static let windowControlsWidth: CGFloat = 64
		public static let spacing: CGFloat = 2
		public static let leadingPadding: CGFloat = 12
		public static let trailingPadding: CGFloat = 8

		/// The profile badge's gap after the sidebar toggle, on top of `spacing`.
		public static let profileBadgeGap: CGFloat = 2

		/// The narrowest the profile badge gets, its face and two or three letters, before it hides.
		public static let profileBadgeMinimumWidth: CGFloat = 48
		public static let profileBadgeMaximumWidth: CGFloat = 140
	}

	public enum URLBar {
		/// How long the link button shows its checkmark after copying.
		public static let copiedDuration: Duration = .seconds(1.5)

		/// The sidebar field (DEV-1252).
		public static let height: CGFloat = 36

		/// The Favorites tiles' radius rather than the control rule's, like
		/// the tiles under it (DEV-1252). Shorter bars, as in Little Arx, keep the rule.
		public static let cornerRadius: CGFloat = Favorites.cornerRadius
		public static let fontSize: CGFloat = 13

		/// The line under the address, such as Translation Available (DEV-996).
		public static let secondLineFontSize: CGFloat = 10
		public static let horizontalPadding: CGFloat = 10

		/// The copy-link and site-menu symbols: a solid weight next to the domain rather
		/// than a hairline (DEV-739). Their buttons keep `actionSize`.
		public static let actionSymbolSize: CGFloat = 13
		public static let prominentActionSymbolSize: CGFloat = 15
		public static let actionSymbolWeight: Font.Weight = .semibold

		/// 28-point buttons in its 36-point field (DEV-1252).
		public static let actionSize: CGFloat = 28
		public static let prominentActionSize: CGFloat = 26

		/// With `ARX_INLINE_BUTTONS`: the toolbar's regular weight and secondary color, a point
		/// smaller than its 16-point symbols, as the field is shorter than the toolbar row.
		public static let inlineActionSymbolSize: CGFloat = 15
		public static let inlineProminentActionSymbolSize: CGFloat = 16
		public static let inlineActionSymbolWeight: Font.Weight = .regular

		/// Between two action buttons: their frames overlap so their shapes, inset in them, sit
		/// 2 points apart rather than twice `InlineButton.shapeInset` (DEV-1252).
		public static let inlineActionSpacing: CGFloat = 2 - 2 * InlineButton.shapeInset

		/// The sidebar's radius at its own height, and the control rule's for any other bar.
		public static func cornerRadius(forHeight barHeight: CGFloat) -> CGFloat {
			barHeight == height ? cornerRadius : ArxControlShape.cornerRadius(forSide: barHeight)
		}

		/// A picker at the field's start, such as Little Arx's profile or Page PiP's space: as far
		/// from the field's start as from its top and bottom.
		public static let accessoryInset: CGFloat = 3

		/// The picker's height in a field `barHeight` tall.
		public static func accessoryHeight(forHeight barHeight: CGFloat) -> CGFloat {
			max(barHeight - 2 * accessoryInset, 0)
		}

		/// The picker's corners, concentric with the field's: its radius less the inset.
		public static func accessoryCornerRadius(forHeight barHeight: CGFloat) -> CGFloat {
			max(cornerRadius(forHeight: barHeight) - accessoryInset, 0)
		}
	}

	/// ``ChromeInlineButtonStyle``: a button inside a control or a row, whose shape is black over
	/// what's under it, so it's always a darker shade of the field or row, as the tab rows' close
	/// button's.
	public enum InlineButton {
		/// The hovered shape's black, in light and in dark, where the chrome's lifted fills need more.
		public static let lightFillOpacity: Double = 0.08
		public static let darkFillOpacity: Double = 0.24

		/// Pressed adds this share of the hovered black.
		public static let pressedIncrease: Double = 0.75

		/// Increase Contrast adds this share of the hovered black.
		public static let increasedContrastIncrease: Double = 0.5

		/// How far the shape sits inside the button's frame by default, so it's about the icon's
		/// size while the whole frame takes clicks.
		public static let shapeInset: CGFloat = 2
	}

	/// The flat surface the URL bar and Favorites sit on: a tint of the chrome's text color, as
	/// Arx's other controls tint theirs with the label color, with a hairline rather than glass
	/// (DEV-788).
	public enum ControlSurface {
		/// The resting fill's share of `BrowserTheme.text`.
		public static let restingFillOpacity: Double = 0.055
		public static let hoveredFillOpacity: Double = 0.09
		public static let pressedFillOpacity: Double = 0.13

		/// The hairline around the surface, so it holds its edge on any chrome tint.
		public static let hairlineOpacity: Double = 0.07

		/// The hairline under Increase Contrast, where the edge has to read on its own.
		public static let increasedContrastHairlineOpacity: Double = 0.22
		public static let hairlineWidth: CGFloat = 0.5

		/// The ring an open favorite draws in its site's color, under the keyboard's accent ring.
		public static let selectedRingWidth: CGFloat = 1
	}

	/// Tabs, folders, and the New Tab row.
	public enum Row {
		public static let actionStrokeLength: CGFloat = 11
		public static let actionStrokeWidth: CGFloat = 1.5

		/// Rows, measured in one screenshot (DEV-1310): 36 points tall and
		/// 5 apart, where Arx's were 34 and 2.
		public static let height: CGFloat = 36

		/// A little rounder than the control rule's 0.28 of the height would give: the
		/// row is a deliberate exception to it.
		public static let cornerRadius: CGFloat = 12
		public static let iconSize: CGFloat = 16
		public static let iconSpacing: CGFloat = 8

		/// Between the title and the close button's shape, with `SidebarRowPolish`.
		public static let actionGap: CGFloat = 4

		/// Titles set about 6% wider than they were at 13.
		public static let fontSize: CGFloat = 14
		public static let horizontalPadding: CGFloat = 10
		public static let spacing: CGFloat = 5

		/// Close under the row: a wider one read as a glow around it.
		public static let selectedShadow: BrowserShadow = .init(opacity: 0.12, radius: 1.25, y: 1)

		/// An unloaded tab's icon and title (DEV-873).
		public static let unloadedOpacity: Double = 0.5

		/// A local-network tab's construction-tape border and host:port subtitle (DEV-786).
		public enum LocalTab {
			public static let tapeWidth: CGFloat = 2.5

			/// Each yellow dash, and the black gap after it.
			public static let tapeDash: CGFloat = 6
			public static let subtitleFontSize: CGFloat = 10.5
		}
	}

	public enum Favorites {
		/// Tiles, measured against the rows.
		public static let tileHeight: CGFloat = 44

		/// A full-height tile's radius under the control rule. Tiles draw `ArxControlShape`, so a
		/// tile narrower than it is tall, and a tile morphing into a row, follow their own size.
		public static let cornerRadius: CGFloat = ArxControlShape.cornerRadius(forSide: tileHeight)
		public static let spacing: CGFloat = 8
		public static let emptyDash: [CGFloat] = [4, 3]
	}

	/// The space heading and the hairline between saved and open tabs.
	public enum Section {
		public static let menuButtonSize: CGFloat = 24
		public static let headerHeight: CGFloat = 28
		public static let headerFontSize: CGFloat = 12
		public static let dividerThickness: CGFloat = 1
		public static let dividerOpacity: Double = 0.12
		public static let dividerSpacing: CGFloat = 10
		public static let actionFontSize: CGFloat = 11
		public static let dividerRowHeight: CGFloat = 16
		public static let emptyHintHeight: CGFloat = 28
	}

	public enum SpaceSwitcher {
		public static let height: CGFloat = 36
		public static let symbolSize: CGFloat = 16
		public static let spacing: CGFloat = 8
		public static let buttonSize: CGFloat = 26
		public static let inactiveOpacity: Double = 0.45

		/// A collapsed space: its hit area, and the dot drawn in it.
		public static let dotWidth: CGFloat = 10

		/// A space's icon in the footer picker, a little smaller than the Library and + beside it.
		public static let iconSymbolSize: CGFloat = 12

		/// The widest of those icons, such as `person.2.fill`.
		public static let iconMaximumWidth: CGFloat = 20

		/// Kept at both ends of the picker so an icon or a nudged dot drawn past its cell isn't clipped.
		public static let edgeInset: CGFloat = 4
		public static let dotSize: CGFloat = 5

		/// The footer picker's gaps follow the sidebar's width between these.
		public static let minimumSpacing: CGFloat = 3
		public static let maximumSpacing: CGFloat = 12
	}

	/// The Library, measured from a 2x recording.
	public enum Library {
		public static let railWidth: CGFloat = 112
		public static let railShadowWidth: CGFloat = 28
		public static let railShadowOpacity: Double = 0.055
		public static let railLineOpacity: Double = 0.09
		public static let selectionOpacity: Double = 0.09
		public static let fieldOpacity: Double = 0.05
		public static let labelOpacity: Double = 0.72
		public static let placeholderOpacity: Double = 0.66
		public static let titleOpacity: Double = 0.87
		public static let subtitleOpacity: Double = 0.62
		public static let footerHeight: CGFloat = 48
		public static let fieldHeight: CGFloat = 36
		public static let fieldCornerRadius: CGFloat = ArxControlShape.cornerRadius(forSide: fieldHeight)
		public static let fieldFontSize: CGFloat = 14
		public static let fieldSymbolWidth: CGFloat = 16
		public static let fieldLeadingPadding: CGFloat = 13
		public static let fieldIconSpacing: CGFloat = 15
		public static let menuLeadingPadding: CGFloat = 10
		public static let menuIconSpacing: CGFloat = 5
		public static let menuTrailingPadding: CGFloat = 11
		public static let menuSymbolWidth: CGFloat = 14
		public static let headerSpacing: CGFloat = 3.5

		/// Above and on both sides of the search row.
		public static let headerInset: CGFloat = 10

		/// Keeps the window controls centred on the search field while the Library shows.
		public static let windowControlsDrop: CGFloat = headerInset + fieldHeight / 2 - Toolbar.height / 2
		public static let headerBottomPadding: CGFloat = 6

		/// The filter chips under the search row, and the chips in a filter pane.
		public static let filterChipHeight: CGFloat = 24
		public static let choiceChipHeight: CGFloat = 30
		public static let chipOpacity: Double = 0.06
		public static let chipHoverOpacity: Double = 0.11
		public static let chipPressedOpacity: Double = 0.17
		public static let filterPaneCornerRadius: CGFloat = 14

		/// Narrower than this, a panel's Filter button drops its title.
		public static let filterTitleMinimumWidth: CGFloat = 260
		public static let tileFontSize: CGFloat = 11

		/// How much the sidebar widens at least, and the width it reaches at its default size.
		public static let minimumExpansion: CGFloat = 77
		public static let minimumWidth: CGFloat = 416
		public static let tileWidth: CGFloat = 96
		public static let tileHeight: CGFloat = 80
		public static let tileSpacing: CGFloat = 20
		public static let tileCornerRadius: CGFloat = 14
		public static let symbolSize: CGFloat = 24
		public static let labelSpacing: CGFloat = 8
		public static let fontSize: CGFloat = 12
		public static let groupInset: CGFloat = 12
		public static let groupTopPadding: CGFloat = 12
		public static let rowHeight: CGFloat = 56
		public static let rowFontSize: CGFloat = 14
		public static let rowIconSize: CGFloat = 24
		public static let rowIconSpacing: CGFloat = 10

		/// How far the spaces drift while they fade out.
		public static let spacesTravel: CGFloat = 16

		/// How small the spaces get, anchored at their leading edge, by the time they've faded out.
		public static let spacesHiddenScale: CGFloat = 0.95
		public static let transitionDuration: Double = 0.24
		public static let columnWidth: CGFloat = 240
		public static let columnSpacing: CGFloat = 24
		public static let columnVerticalPadding: CGFloat = 48
		public static let columnHeaderHeight: CGFloat = 32
		public static let columnFooterHeight: CGFloat = 32
	}

	/// ⌃Tab's recent-tab switcher (DEV-544): the command bar's rows, in a narrower card.
	public enum TabSwitcher {
		public static let width: CGFloat = 420
		public static let cornerRadius: CGFloat = 16
		public static let padding: CGFloat = 8
		public static let rowHeight: CGFloat = 44
		public static let rowSpacing: CGFloat = 2
		public static let rowHorizontalPadding: CGFloat = 10
		public static let iconTileSize: CGFloat = 26

		/// Rows shown before the rest scroll.
		public static let visibleRows: Int = 9
	}

	public enum CommandBar {
		/// The palette's width in a roomy window: three quarters of the earlier 764 points (DEV-803).
		public static let width: CGFloat = 573

		/// The palette never takes more than this share of a narrow window.
		public static let maximumWidthFraction: CGFloat = 0.55

		/// The palette's top edge, as a fraction of the window height.
		public static let topFraction: CGFloat = 0.22
		public static let margin: CGFloat = 16

		/// The Raised look's corners (DEV-1277).
		public static let cornerRadius: CGFloat = 24

		/// The bezel's band: the panel's content sits this far in from its edge.
		public static let contentInset: CGFloat = Raised.bezelWidth
		public static let inputHeight: CGFloat = 60
		public static let inputFontSize: CGFloat = 20

		/// Between the input row's icon, field, "Ask an agent ⇥" hint and close button.
		public static let inputSpacing: CGFloat = 12

		/// The search field's icon slot (DEV-1334): every icon, a magnifier, a favicon, a bang's or a
		/// command's, is centred and fitted in this square, so the text starts at one x whatever is
		/// shown. The rows' icon column is the same square.
		public static let fieldIconSlot: CGFloat = 23

		/// The palette's highlight. A row is this and `rowSpacing` tall: rows touch, each holding
		/// half the gap above and below its highlight (DEV-1289; Figma's Command Raised Row, 52 in 54).
		public static let rowHeight: CGFloat = 52

		/// The address field's and the launcher's rows.
		public static let rowCornerRadius: CGFloat = 8

		/// The palette's rows, concentric with its corners: they sit `contentInset` and
		/// `resultsPadding` in from its edge.
		public static let paletteRowCornerRadius: CGFloat = cornerRadius - contentInset - resultsPadding
		public static let rowFontSize: CGFloat = 14
		public static let rowSpacing: CGFloat = 2
		public static let resultsPadding: CGFloat = 8

		/// Above the palette's first row, below the divider.
		public static let resultsTopPadding: CGFloat = 16
		public static let rowHorizontalPadding: CGFloat = 10

		/// Under the divider, so the palette is 476 points tall with its content inset.
		public static let maximumResultsHeight: CGFloat = 407
		public static let borderWidth: CGFloat = 1
		public static let shadow: BrowserShadow = .init(opacity: 0.40, radius: 30, y: 12)

		/// The address bar opened in place: slimmer than the palette, and only just wider than the field.
		public enum URLField {
			public static let minimumWidth: CGFloat = 340

			/// It grows with a long address up to here.
			public static let maximumWidth: CGFloat = 718

			/// Everything in the panel beside the text, but for the "Ask an agent ⇥" hint, which adds
			/// its own width while it shows (DEV-954).
			public static let textChromeWidth: CGFloat = 110
			public static let outset: CGFloat = 6
			public static let cornerRadius: CGFloat = 12
			public static let inputHeight: CGFloat = 46
			public static let inputFontSize: CGFloat = 14
			public static let inputHorizontalPadding: CGFloat = 14
			public static let rowHeight: CGFloat = 46
			public static let rowSpacing: CGFloat = 4
			public static let resultsPadding: CGFloat = 9
			public static let rowHorizontalPadding: CGFloat = 10
			public static let iconTileSize: CGFloat = 24
			public static let iconTileCornerRadius: CGFloat = ArxControlShape.cornerRadius(forSide: iconTileSize)
			public static let chipHeight: CGFloat = 24
			public static let chipHorizontalPadding: CGFloat = 10
			public static let keycapHeight: CGFloat = 22
		}

		/// The "Ask an agent ⇥" hint at the input's trailing edge (DEV-751).
		public enum KeyHint {
			public static let height: CGFloat = 26
			public static let fontSize: CGFloat = 13
			public static let spacing: CGFloat = 7
			public static let horizontalPadding: CGFloat = 9

			/// The key cap sits closer to the edge than the text does to the other one.
			public static let trailingPadding: CGFloat = 5
			public static let keySize: CGFloat = 18
			public static let keyFontSize: CGFloat = 10
			public static let keyStroke: CGFloat = 1

			/// Room either side of a key cap with more than one symbol, such as ⌘K.
			public static let wideKeyPadding: CGFloat = 4
		}

		/// The Raised look (DEV-1277): a glass panel in a physical bezel, with Actions ⌘K floating
		/// over its bottom-right corner instead of a footer.
		public enum Raised {
			/// The bezel's lighter band between its outer and inner edges.
			public static let bezelWidth: CGFloat = 4

			/// Actions ⌘K and the open actions sit this far in from the panel's bottom-right
			/// corner: concentric with its 24-point corners, near enough for 36-point raised glass.
			/// Inside the bezel that's 8 points from the glass the rows sit on, and the highlight
			/// the arrows move stops as far above the button (DEV-1318,
			/// `ArxListLayout.floatingReserve`).
			public static let floatingInset: CGFloat = 12
			public static let floatingHeight: CGFloat = 36

			/// The shadow the floating glass casts over the results: 48/8 at 0.25 in Figma.
			public static let floatingShadow: BrowserShadow = .init(opacity: 0.25, radius: 24, y: 8)

			/// How much of the raised glass's fill shows over its chrome backing.
			public static let glassFillOpacity: Double = 0.2

			/// The key caps beside Actions, as the reference draws ⌘ K.
			public static let keycapSize: CGFloat = 18
			public static let keycapSpacing: CGFloat = 3
			public static let labelSpacing: CGFloat = 8
		}

		/// ⌘K's actions (DEV-810), Raised since DEV-1277: the actions' search field takes the
		/// Actions button's place and the list floats above it, drawn as the destination
		/// picker's glass tile.
		public enum Actions {
			public static let width: CGFloat = 240
			public static let maximumHeight: CGFloat = LittleArx.SpacePicker.maximumHeight
			public static let searchHeight: CGFloat = Raised.floatingHeight

			/// Between the list and the search field.
			public static let spacing: CGFloat = 8
			public static let rowHeight: CGFloat = 40
			public static let rowSpacing: CGFloat = 2

			/// The glyph's square and the glyph inside it.
			public static let tileSize: CGFloat = 26
			public static let glyphSize: CGFloat = 13

			/// The list's glass tile: rows sit `listInset` in, concentric with its corners.
			public static let listInset: CGFloat = 4
			public static let cornerRadius: CGFloat = 14
			public static let keycapHeight: CGFloat = 20
		}
	}

	/// The revealed sidebar reads as its own panel over a full-width page.
	public enum FloatingSidebar {
		public static let inset: CGFloat = 6
		public static let cornerRadius: CGFloat = 12
		public static let borderWidth: CGFloat = 1
		public static let shadow: BrowserShadow = .init(opacity: 0.45, radius: 20, y: 4)
	}

	/// A split pane's navigation row.
	public enum PaneHeader {
		public static let height: CGFloat = 30

		/// The developer header over a local page stands a little taller (DEV-786).
		public static let developerHeight: CGFloat = 36
		public static let symbolSize: CGFloat = 12
		public static let hostFontSize: CGFloat = 13
		public static let horizontalPadding: CGFloat = 4
	}

	public enum Peek {
		public static let controlsSpacing: CGFloat = 10
		public static let insetFraction: CGFloat = 0.05
		public static let minimumInset: CGFloat = 24
		public static let cornerRadius: CGFloat = 12
		public static let shadow: BrowserShadow = .init(opacity: 0.30, radius: 40, y: 16)

		/// The page behind an open Peek recedes by this much.
		public static let backgroundScale: CGFloat = 0.96

		/// The page behind an open Peek dims to this opacity, so the Peek reads as the focus
		/// (DEV-1224). Only the page dims: the Peek is drawn over it, not inside it (DEV-1173).
		public static let backgroundOpacity: Double = 0.55

		/// Inside its source pane, the card keeps this share of the width free on each side.
		public static let paneInsetFraction: CGFloat = 0.07

		/// How small the card starts when it grows out of a clicked link.
		public static let originScale: CGFloat = 0.4

		/// The pane's side margins never get narrower than the buttons beside the card.
		public static var minimumPaneInset: CGFloat { Control.size + controlsSpacing + 8 }

		/// The card's frame, buttons included, inside the pane it was opened from.
		///
		/// The page stays centered on the pane and keeps the pane's full height, so it
		/// stands a little proud of the receding page; the buttons sit in the right margin.
		public static func frame(inPane pane: CGRect) -> CGRect {
			let proportionalInset = (pane.width * paneInsetFraction).rounded()
			let inset = min(max(minimumPaneInset, proportionalInset), pane.width / 4)
			let controls = Control.size + controlsSpacing
			return CGRect(
				x: pane.minX + inset,
				y: pane.minY,
				width: max(0, pane.width - 2 * inset + controls),
				height: pane.height
			)
		}

		/// The Arx buttons beside the card (DEV-1224).
		public enum Control {
			public static let size: CGFloat = 36
			public static let spacing: CGFloat = 10
			public static let symbolSize: CGFloat = 13
			public static let shadow: BrowserShadow = .init(opacity: 0.25, radius: 6, y: 2)
			public static let hintDelay: Duration = .milliseconds(500)
			public static let hintSpacing: CGFloat = 8
		}

		/// The card's distance from each window edge.
		public static func inset(in size: CGSize) -> CGSize {
			.init(
				width: max(minimumInset, (size.width * insetFraction).rounded()),
				height: max(minimumInset, (size.height * insetFraction).rounded())
			)
		}
	}

	public enum LittleArx {
		public static let cornerRadius: CGFloat = 12
		public static let toolbarHeight: CGFloat = 44
		public static let addressHeight: CGFloat = 30

		/// The narrowest the header's URL bar gets; everything in it, the profile picker
		/// included, fits there (DEV-1153).
		public static let addressMinimumWidth: CGFloat = 140

		/// Between the window's edges and the page card, at the sides and bottom.
		public static let pageInset: CGFloat = 1

		/// Concentric with the window's corners.
		public static let pageCornerRadius: CGFloat = cornerRadius - pageInset

		/// The searchable list behind the "Open in" button.
		public enum SpacePicker {
			public static let width: CGFloat = 200
			public static let maximumHeight: CGFloat = 322
			public static let searchHeight: CGFloat = 38
			public static let rowHeight: CGFloat = 37
			public static let tileSize: CGFloat = 22
			public static let cornerRadius: CGFloat = 10
		}

		/// The Runway: the panel at the pointer that asks which profile a link from another app
		/// opens in (DEV-858). Its controls are the AI chat's and Settings' raised glass.
		public enum Runway {
			/// The regular Runway's panel.
			public static let regularWidth: CGFloat = 300

			/// The compact Runway, which has no panel.
			public static let compactWidth: CGFloat = 240

			/// The regular panel's corner radius and padding, and the gap between its parts.
			public static let panelCornerRadius: CGFloat = FloatingPanel.cornerRadius
			public static let panelPadding: CGFloat = 8
			public static let spacing: CGFloat = 8

			/// The search field and Close, as a header bar's raised controls.
			public static let controlHeight: CGFloat = 36

			/// A profile's row: the inset squircle inside the glass tile.
			public static let rowHeight: CGFloat = 40
			public static let rowSpacing: CGFloat = 2

			/// From a row's leading edge to its space's icon, and the icon's square.
			public static let rowLeadingInset: CGFloat = 6
			public static let rowIconSize: CGFloat = 26

			/// Between the icon and the profile's name.
			public static let rowIconSpacing: CGFloat = 6

			/// A row's ⌘1–⌘9 badge: as far from the row's trailing edge as from its top and bottom,
			/// and wide enough for any of the nine, so the badges line up.
			public static let shortcutHeight: CGFloat = 18
			public static let shortcutTextWidth: CGFloat = 16
			public static let shortcutCornerRadius: CGFloat = 4.75
			public static let shortcutInset: CGFloat = (rowHeight - shortcutHeight) / 2

			/// The compact Runway's Close, smaller than the search field beside it, and the gap
			/// between them. The regular Runway's Close keeps the controls' height.
			public static let compactCloseSize: CGFloat = 32
			public static let compactControlSpacing: CGFloat = 6

			/// The gap between the glass tile's edge and a row, and the tile's corner radius:
			/// concentric with the rows' inset squircles, as a raised group's tile is with its items.
			public static let tileInset: CGFloat = 4
			public static let tileCornerRadius: CGFloat = ArxRaisedShape.cornerRadius(forSide: rowHeight + 2 * tileInset)

			/// Rows the tile shows before it scrolls.
			public static let visibleRows: Int = 6

			/// Profiles ⌘1–⌘9 open.
			public static let numberedRows: Int = 9

			/// Room around the Runway for its shadow inside the borderless panel.
			public static let shadowInset: CGFloat = 24
		}

		/// The command-only panel that opens before a page exists.
		public enum Launcher {
			public static let width: CGFloat = 490
			public static let panelPadding: CGFloat = 8
			public static let inputHeight: CGFloat = 63
			public static let rowHeight: CGFloat = 46
			public static let rowSpacing: CGFloat = 4
			public static let resultsPadding: CGFloat = 10
			public static let rowHorizontalPadding: CGFloat = 10
			public static let visibleRows: CGFloat = 5
			public static let closeButtonSize: CGFloat = 24
			public static let borderWidth: CGFloat = 1
		}
	}

	/// Opacities applied to `BrowserTheme` colors for control states.
	public enum State {
		public static let pressedOpacity: Double = 0.7
		public static let secondaryOpacity: Double = 0.52
		public static let disabledOpacity: Double = 0.35

		/// How much of a dimmed color's transparency Increase Contrast keeps. Dimmed text then
		/// clears 4.5:1 and dimmed icons 3:1, while selected and unselected stay apart.
		public static let increasedContrastDimming: Double = 0.45

		/// The opacity for dimmed text or icons at the system's contrast setting.
		public static func opacity(
			_ opacity: Double,
			contrast: ColorSchemeContrast
		) -> Double {
			guard contrast == .increased else { return opacity }
			return 1 - (1 - opacity) * increasedContrastDimming
		}
	}
}

/// A black drop shadow, described once so cards and rows stay consistent.
public struct BrowserShadow: Equatable, Sendable {
	public static let none: Self = .init(opacity: 0, radius: 0, y: 0)

	public var opacity: Double
	public var radius: CGFloat
	public var y: CGFloat

	public init(
		opacity: Double,
		radius: CGFloat,
		y: CGFloat
	) {
		self.opacity = opacity
		self.radius = radius
		self.y = y
	}
}

extension View {
	public func browserShadow(_ shadow: BrowserShadow) -> some View {
		self.shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
	}

	/// Lifts page content off the tinted window: continuous corners, a hairline, and a soft shadow.
	///
	/// The shadow is cast by a background shape so it also works under hosted AppKit content.
	/// A homepage that paints no ground of its own makes the card see-through
	/// (`BrowserPageSeeThroughKey`), so the window's background shows through it.
	public func browserPageCard(cornerRadius: CGFloat = BrowserMetrics.PageCard.cornerRadius) -> some View {
		modifier(BrowserPageCard(cornerRadius: cornerRadius))
	}

}

/// Whether a page card's content lets the window's background through: the homepage with motes
/// or a bare grid on it, and no ground of its own.
public struct BrowserPageSeeThroughKey: PreferenceKey {
	public static let defaultValue: Bool = false

	public static func reduce(
		value: inout Bool,
		nextValue: () -> Bool
	) {
		value = value || nextValue()
	}
}

extension EnvironmentValues {
	/// How solid the page's own ground is inside a page card: 1, or
	/// `BrowserMetrics.PageCard.seeThroughOpacity` while the card is see-through.
	@Entry
	public var browserPageFillOpacity: Double = 1

	/// Set on a window for a see-through page card's ground to follow a swipe between spaces,
	/// as `browserChromeReveal` is on its background (DEV-1310).
	@Entry
	public var browserPageReveal: BrowserChromeReveal? = nil
}

/// The page's own ground inside a page card: the page color of the space shown, as solid as
/// the card is.
///
/// While the card is see-through and a swipe has the sidebar between two spaces
/// (`browserPageReveal`), it turns from one space's page color to the next as far as the
/// sidebar has gone, in step with the window's background behind it (DEV-1310). It used to
/// stay the selected space's until the slide landed, a patch of the old theme on the new.
public struct BrowserPageGround: View {
	private let fixedOpacity: Double?

	@Environment(\.browserPageFillOpacity)
	private var environmentOpacity

	@Environment(\.browserPageReveal)
	private var chrome

	@Environment(\.browserChromeTransitionKey)
	private var selectedSpace

	/// - Parameters:
	///   - opacity: How solid it is; nil reads `browserPageFillOpacity`.
	public init(opacity: Double? = nil) {
		self.fixedOpacity = opacity
	}

	public var body: some View {
		let opacity: Double = fixedOpacity ?? environmentOpacity
		Rectangle()
			.fill(BrowserTheme.page)
			.overlay {
				// Under a page there's nothing to see of it, so only a see-through card follows.
				if opacity < 1, let chrome {
					BrowserPageRevealLayers(chrome: chrome, selectedSpace: selectedSpace)
				}
			}
			.compositingGroup()
			.opacity(opacity)
	}
}

/// The page color of the spaces the sidebar stands between: the earlier one whole, unless it's
/// the selected space, whose color is under these already, and the later one over it as far as
/// the sidebar has gone. It reads the swipe itself, so a frame of one runs this body alone.
private struct BrowserPageRevealLayers: View {
	private let chrome: BrowserChromeReveal
	private let selectedSpace: UUID?

	fileprivate init(
		chrome: BrowserChromeReveal,
		selectedSpace: UUID?
	) {
		self.chrome = chrome
		self.selectedSpace = selectedSpace
	}

	fileprivate var body: some View {
		let reveal: SidebarSpaceReveal = chrome.reveal
		ZStack {
			if let lower = reveal.lower, lower != selectedSpace {
				ground(of: lower)
			}
			if let upper = reveal.upper {
				ground(of: upper).opacity(reveal.fraction)
			}
		}
		.allowsHitTesting(false)
	}

	private func ground(of space: UUID) -> some View {
		Rectangle()
			.fill(BrowserTheme.page)
			.modifier(SidebarPageAppearance(override: chrome.appearance(space)))
	}
}

private struct BrowserPageCard: ViewModifier {
	private let cornerRadius: CGFloat

	@State
	private var isSeeThrough: Bool = false

	fileprivate init(cornerRadius: CGFloat) {
		self.cornerRadius = cornerRadius
	}

	fileprivate func body(content: Content) -> some View {
		let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
		let opacity: Double = isSeeThrough ? BrowserMetrics.PageCard.seeThroughOpacity : 1
		content
			.environment(\.browserPageFillOpacity, opacity)
			.onPreferenceChange(BrowserPageSeeThroughKey.self) { isSeeThrough = $0 }
			.background(BrowserPageGround(opacity: opacity))
			.clipShape(shape)
			.overlay {
				shape
					.strokeBorder(BrowserTheme.pageBorder, lineWidth: BrowserMetrics.PageCard.borderWidth)
					.allowsHitTesting(false)
			}
			.background {
				// A see-through card casts no shadow: it would show through the card itself.
				if !isSeeThrough {
					shape
						.fill(BrowserTheme.page)
						.browserShadow(BrowserMetrics.PageCard.shadow)
				}
			}
	}
}
