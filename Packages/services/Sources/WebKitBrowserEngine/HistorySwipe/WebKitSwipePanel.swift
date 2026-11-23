import AppKit
import QuartzCore

/// The swipe indicator on a WebKit page, the same as Chromium's
/// (`Packages/engine/Native/gestures/panel.mm`), ported to AppKit (DEV-1203).
///
/// Vertically centred in the page view and inset from the swiped edge. Until armed it is a glass
/// circle with an arrow inside a ring that fills with progress; a closed ring turns the circle
/// solid. Armed, the circle stays solid and a raised glass list of the history opens beside it
/// (DEV-1276): up to five rows, each with the page's icon, title and host. The selected row is
/// always level with the arrow: near either end of the history the list moves, and in between it
/// holds still while the rows scroll through it. Back's list hangs down from the arrow, nearest
/// entry on top; forward's mirrors it and rises from the arrow, nearest entry at the bottom, so
/// down is back and up is forward in both (DEV-1292). A nonactivating, noninteractive child window: it
/// never takes the source's responder. The toolbar history menus remain the keyboard and
/// VoiceOver route.
@MainActor
internal final class WebKitSwipePanel {
	/// One history entry in the list.
	internal struct Row: Equatable {
		internal var title: String
		internal var host: String

		/// The page's favicon; a globe stands in without one.
		internal var icon: NSImage?

		internal init(
			title: String,
			host: String,
			icon: NSImage? = nil
		) {
			self.title = title
			self.host = host
			self.icon = icon
		}
	}

	private weak var source: NSView?
	private let direction: WebKitSwipeDirection
	private var panel: NSPanel?
	private var pill: NSGlassEffectView?
	private var pillContent: NSView?

	/// The ready circle's solid fill, under the arrow.
	private var fill: NSView?
	private var arrow: NSImageView?
	private var ring: CAShapeLayer?

	/// The history list: a shadowed tile holding glass, whose content clips the full-length
	/// column of rows that scrolls behind it.
	private var tile: NSView?
	private var tileGlass: NSGlassEffectView?
	private var tileContent: NSView?
	private var column: NSView?
	private var rowViews: [NSView] = []
	private var highlights: [NSView] = []

	/// Frosted backings so glass stays legible over busy pages: the circle's, then the list's.
	private var frosts: [NSView] = []
	private var rows: [Row] = []
	private var progress: Double = 0
	private var armed: Bool = false
	private var selected: Int = 0

	internal init(
		source: NSView,
		direction: WebKitSwipeDirection
	) {
		self.source = source
		self.direction = direction

		guard let window = source.window, !source.bounds.isEmpty else { return }

		let frame: NSRect = window.convertToScreen(source.convert(source.bounds, to: nil))
		let panel: NSPanel = .init(
			contentRect: frame,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.isReleasedWhenClosed = false
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.ignoresMouseEvents = true
		panel.hidesOnDeactivate = true
		panel.appearance = window.effectiveAppearance
		panel.setAccessibilityLabel(direction == .back ? "Back" : "Forward")

		let content: NSView = .init(frame: NSRect(origin: .zero, size: frame.size))
		content.wantsLayer = true
		panel.contentView = content

		let ring: CAShapeLayer = .init()
		ring.fillColor = NSColor.clear.cgColor
		ring.lineWidth = Metrics.stroke
		ring.lineCap = .round
		ring.strokeEnd = 0
		content.layer?.addSublayer(ring)
		self.ring = ring

		let (pill, inner) = Self.glass(radius: Metrics.circle / 2)
		self.frosts.append(Self.addFrost(to: inner))
		pill.setAccessibilityElement(true)
		pill.setAccessibilityRole(.image)

		let arrow: NSImageView = .init(
			image: NSImage(
				systemSymbolName: direction == .back ? "arrow.left" : "arrow.right",
				accessibilityDescription: nil
			) ?? NSImage()
		)
		arrow.symbolConfiguration = .init(pointSize: 15, weight: .semibold)

		let fill: NSView = .init(frame: .zero)
		fill.wantsLayer = true
		fill.alphaValue = 0

		inner.addSubview(fill)
		inner.addSubview(arrow)
		content.addSubview(pill)

		// The list's shadow lives on a plain layer around the glass, which clips.
		let tile: NSView = .init(frame: .zero)
		tile.wantsLayer = true
		tile.layer?.masksToBounds = false
		tile.layer?.shadowColor = NSColor.black.cgColor
		tile.layer?.shadowOpacity = 0.25
		tile.layer?.shadowRadius = 24
		tile.layer?.shadowOffset = CGSize(width: 0, height: -8)
		tile.alphaValue = 0
		tile.setAccessibilityElement(true)
		tile.setAccessibilityRole(.list)
		tile.setAccessibilityLabel(panel.accessibilityLabel())
		let (tileGlass, tileContent) = Self.glass(radius: Metrics.listRadius)
		tileContent.wantsLayer = true
		tileContent.layer?.cornerRadius = Metrics.listRadius
		tileContent.layer?.masksToBounds = true
		tileContent.layer?.borderWidth = 0.5
		self.frosts.append(Self.addFrost(to: tileContent))
		let column: NSView = .init(frame: .zero)
		tileContent.addSubview(column)
		tile.addSubview(tileGlass)
		content.addSubview(tile)

		self.panel = panel
		self.pill = pill
		self.pillContent = inner
		self.arrow = arrow
		self.fill = fill
		self.tile = tile
		self.tileGlass = tileGlass
		self.tileContent = tileContent
		self.column = column

		window.addChildWindow(panel, ordered: .above)
		self.layout(animated: false)
	}

	isolated deinit {
		self.dismiss()
	}

	internal var isVisible: Bool { self.panel?.isVisible ?? false }

	internal var isArmed: Bool { self.isVisible && self.armed }

	/// The ring has closed: release goes one step, before the list opens.
	internal var isFilled: Bool { !self.armed && self.progress >= 1 }

	/// The circle's frame in the panel, which covers the source view.
	internal var indicatorFrame: NSRect { self.pill?.frame ?? .zero }

	/// The history list's frame in the panel; it shows only while armed.
	internal var listFrame: NSRect { self.tile?.frame ?? .zero }

	/// Whether the history list shows.
	internal var isListVisible: Bool { (self.tile?.alphaValue ?? 0) > 0 }

	/// The selected row's frame in the panel.
	internal var selectedRowFrame: NSRect {
		guard
			let tileContent,
			self.rowViews.indices.contains(self.selected)
		else { return .zero }

		let row: NSView = self.rowViews[self.selected]
		return tileContent.convert(row.convert(row.bounds, to: tileContent), to: self.panel?.contentView)
	}

	/// The panel's frame on screen.
	internal var panelFrame: NSRect { self.panel?.frame ?? .zero }

	/// Nearest first. Empty shows the arrow alone.
	internal func setEntries(_ rows: [Row]) {
		self.rows = rows
		self.buildRows()
		self.layout(animated: false)
	}

	internal func update(
		progress: Double,
		armed: Bool,
		selected: Int
	) {
		guard self.panel != nil else { return }

		let arming: Bool = armed != self.armed
		let moved: Bool = armed && self.armed && selected != self.selected
		let wasFilled: Bool = self.isFilled
		self.progress = progress.isFinite ? min(max(progress, 0), 1) : 0
		self.armed = armed
		self.selected = self.rows.isEmpty ? 0 : min(max(selected, 0), self.rows.count - 1)
		let filling: Bool = self.isFilled != wasFilled

		// Filling commits the one-step navigation; opening the list and each step through it follow.
		if (filling && self.isFilled) || (arming && armed) || moved {
			NSHapticFeedbackManager.defaultPerformer.perform(
				moved ? .generic : .alignment,
				performanceTime: .now
			)
		}
		self.layout(animated: arming || moved || filling)
	}

	internal func dismiss() {
		if let panel {
			panel.parent?.removeChildWindow(panel)
			panel.orderOut(nil)
			panel.close()
		}
		self.panel = nil
		self.pill = nil
		self.pillContent = nil
		self.fill = nil
		self.arrow = nil
		self.ring = nil
		self.tile = nil
		self.tileGlass = nil
		self.tileContent = nil
		self.column = nil
		self.rowViews = []
		self.highlights = []
		self.frosts = []
		self.armed = false
	}

	/// Where an entry sits in the column, counted from the top: back's list runs down from the
	/// nearest entry, forward's runs up from it (DEV-1292).
	internal static func slot(
		of index: Int,
		count: Int,
		direction: WebKitSwipeDirection
	) -> Int {
		direction == .back ? index : count - 1 - index
	}

	/// The topmost of the shown slots: two above the selected slot, clamped to the ends.
	internal static func windowStart(
		selected: Int,
		count: Int
	) -> Int {
		guard count > Metrics.maxRows else { return 0 }
		return min(max(selected - Metrics.maxRows / 2, 0), count - Metrics.maxRows)
	}

	/// One row per entry in a column as tall as the whole history; the tile shows at most five of
	/// them and the column slides behind it.
	private func buildRows() {
		guard let column else { return }

		for row in self.rowViews {
			row.removeFromSuperview()
		}
		self.rowViews = []
		self.highlights = []

		let width: CGFloat = Metrics.listWidth - 2 * Metrics.listPadding
		let textX: CGFloat = Metrics.rowLeading + Metrics.iconTile + Metrics.iconGap
		let textWidth: CGFloat = width - textX - Metrics.rowTrailing

		for entry in self.rows {
			let row: NSView = .init(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.rowHeight))
			row.setAccessibilityElement(true)
			row.setAccessibilityRole(.row)

			let highlight: NSView = .init(frame: row.bounds)
			highlight.wantsLayer = true
			highlight.layer?.cornerRadius = Metrics.rowRadius
			highlight.layer?.borderWidth = 0.5
			highlight.alphaValue = 0
			row.addSubview(highlight)

			let icon: NSImageView = .init(
				image: entry.icon
				?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
				?? NSImage()
			)
			icon.imageScaling = .scaleProportionallyUpOrDown
			if entry.icon == nil {
				icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
				icon.contentTintColor = Self.chromeText(alpha: 0.52)
			}
			icon.frame = NSRect(
				x: Metrics.rowLeading + (Metrics.iconTile - Metrics.icon) / 2,
				y: (Metrics.rowHeight - Metrics.icon) / 2,
				width: Metrics.icon,
				height: Metrics.icon
			)
			row.addSubview(icon)

			let title: NSTextField = Self.label(size: 13, weight: .medium, color: Self.chromeText(alpha: 0.85))
			title.stringValue = entry.title
			title.frame = NSRect(x: textX, y: Metrics.rowHeight / 2 - 1.5, width: textWidth, height: 16)
			row.addSubview(title)

			let host: NSTextField = Self.label(size: 11, weight: .regular, color: Self.chromeText(alpha: 0.52))
			host.stringValue = entry.host
			host.frame = NSRect(x: textX, y: Metrics.rowHeight / 2 - 14.5, width: textWidth, height: 13)
			row.addSubview(host)

			row.setAccessibilityLabel(entry.title)
			column.addSubview(row)
			self.rowViews.append(row)
			self.highlights.append(highlight)
		}
	}

	private func layout(animated: Bool) {
		guard
			self.source != nil,
			let panel,
			let content = panel.contentView,
			let pill,
			let pillContent,
			let fill,
			let arrow,
			let ring,
			let tile,
			let tileGlass,
			let tileContent,
			let column,
			let pillFrost = self.frosts.first,
			let listFrost = self.frosts.last
		else { return }

		let bounds: NSRect = content.bounds
		let back: Bool = self.direction == .back

		// Always at the view's vertical centre, whatever the pointer's height.
		let cy: CGFloat = bounds.midY
		let cx: CGFloat = back
		? bounds.minX + Metrics.inset + Metrics.ring / 2
		: bounds.maxX - Metrics.inset - Metrics.ring / 2
		let dark: Bool = Self.isDark(panel.effectiveAppearance)
		let armed: Bool = self.armed

		let circleFrame: NSRect = .init(
			x: cx - Metrics.circle / 2,
			y: cy - Metrics.circle / 2,
			width: Metrics.circle,
			height: Metrics.circle
		)
		let circleBounds: NSRect = .init(x: 0, y: 0, width: Metrics.circle, height: Metrics.circle)
		let arrowFrame: NSRect = .init(
			x: (Metrics.circle - Metrics.arrow) / 2,
			y: (Metrics.circle - Metrics.arrow) / 2,
			width: Metrics.arrow,
			height: Metrics.arrow
		)

		// The list: at most five rows, the selected one level with the arrow. The window of shown
		// slots starts two above the selected slot, clamped to the ends, so the tile moves near the
		// ends and holds still in between. Forward's slots run bottom up.
		let count: Int = self.rows.count
		let direction: WebKitSwipeDirection = self.direction
		let shown: Int = min(count, Metrics.maxRows)
		let selectedSlot: Int = Self.slot(of: self.selected, count: count, direction: direction)
		let start: Int = Self.windowStart(selected: selectedSlot, count: count)
		let height: CGFloat = shown > 0
		? 2 * Metrics.listPadding + CGFloat(shown) * Metrics.rowPitch - Metrics.rowSpacing
		: 0
		let columnHeight: CGFloat = count > 0 ? CGFloat(count) * Metrics.rowPitch - Metrics.rowSpacing : 0
		let above: CGFloat = Metrics.listPadding
		+ CGFloat(selectedSlot - start) * Metrics.rowPitch
		+ Metrics.rowHeight / 2
		let tileX: CGFloat = back
		? cx + Metrics.ring / 2 + Metrics.listGap
		: cx - Metrics.ring / 2 - Metrics.listGap - Metrics.listWidth
		let tileFrame: NSRect = .init(x: tileX, y: cy + above - height, width: Metrics.listWidth, height: height)
		let tileBounds: NSRect = .init(x: 0, y: 0, width: Metrics.listWidth, height: height)
		let columnFrame: NSRect = .init(
			x: Metrics.listPadding,
			y: height - Metrics.listPadding - columnHeight + CGFloat(start) * Metrics.rowPitch,
			width: Metrics.listWidth - 2 * Metrics.listPadding,
			height: columnHeight
		)
		let list: Bool = armed && shown > 0
		let selected: Int = self.selected
		let rowViews: [NSView] = self.rowViews
		let highlights: [NSView] = self.highlights

		// Ready and armed share the solid circle: release now navigates.
		let solid: Bool = armed || self.isFilled
		let ink: NSColor = solid ? Self.capsuleText : .labelColor
		let progress: Double = self.progress

		let placeList: () -> Void = {
			tile.frame = tileFrame
			tileGlass.frame = tileBounds
			tileContent.frame = tileBounds
			listFrost.frame = tileBounds
			column.frame = columnFrame
			for (index, row) in rowViews.enumerated() {
				let slot: Int = Self.slot(of: index, count: count, direction: direction)
				row.frame = NSRect(
					x: 0,
					y: columnHeight - CGFloat(slot) * Metrics.rowPitch - Metrics.rowHeight,
					width: columnFrame.width,
					height: Metrics.rowHeight
				)
			}
		}

		// A list that isn't showing yet appears where it belongs, then fades in.
		if tile.alphaValue == 0 {
			Self.run(animated: false, placeList)
		}

		Self.run(animated: animated) {
			pill.frame = circleFrame
			pillContent.frame = circleBounds
			arrow.frame = arrowFrame
			fill.frame = circleBounds
			pillFrost.frame = circleBounds
			fill.alphaValue = solid ? 1 : 0
			pill.cornerRadius = Metrics.circle / 2
			pill.alphaValue = armed ? 1 : min(max(progress / 0.2, 0), 1)
			placeList()
			tile.alphaValue = list ? 1 : 0
			for (index, highlight) in highlights.enumerated() {
				highlight.alphaValue = list && index == selected ? 1 : 0
			}
		}

		CATransaction.begin()
		CATransaction.setDisableActions(true)
		arrow.contentTintColor = ink
		fill.layer?.cornerRadius = Metrics.circle / 2
		pillFrost.layer?.cornerRadius = Metrics.circle / 2
		listFrost.layer?.cornerRadius = Metrics.listRadius
		tile.layer?.shadowPath = CGPath(
			roundedRect: tileBounds,
			cornerWidth: Metrics.listRadius,
			cornerHeight: Metrics.listRadius,
			transform: nil
		)
		panel.effectiveAppearance.performAsCurrentDrawingAppearance {
			fill.layer?.backgroundColor = Self.capsuleFill.cgColor
			for frost in self.frosts {
				frost.layer?.backgroundColor = Self.frost.cgColor
			}
			tileContent.layer?.borderColor = Self.hairline.cgColor
			for highlight in highlights {
				highlight.layer?.backgroundColor = Self.selectedFill.cgColor
				highlight.layer?.borderColor = Self.selectedEdge.cgColor
			}
		}
		pill.setAccessibilityLabel(panel.accessibilityLabel())
		for (index, row) in rowViews.enumerated() {
			row.setAccessibilitySelected(list && index == selected)
		}
		ring.isHidden = solid
		ring.frame = NSRect(
			x: cx - Metrics.ring / 2,
			y: cy - Metrics.ring / 2,
			width: Metrics.ring,
			height: Metrics.ring
		)

		// Starts at the top and runs toward the swiped edge's far side.
		let path: CGMutablePath = .init()
		path.addArc(
			center: CGPoint(x: Metrics.ring / 2, y: Metrics.ring / 2),
			radius: (Metrics.ring - Metrics.stroke) / 2,
			startAngle: .pi / 2,
			endAngle: .pi / 2 + (back ? -2 : 2) * .pi,
			clockwise: back
		)
		ring.path = path
		ring.strokeColor = NSColor(white: dark ? 0.92 : 0.15, alpha: 0.9).cgColor
		ring.strokeEnd = progress
		CATransaction.commit()
	}
}

extension WebKitSwipePanel {
	/// The geometry of `panel.mm`, point for point.
	internal enum Metrics {
		internal static let ring: CGFloat = 44
		internal static let circle: CGFloat = 36
		internal static let stroke: CGFloat = 2.5
		internal static let inset: CGFloat = 16
		internal static let arrow: CGFloat = 16

		/// The history list (DEV-1276): the Destination Picker's raised glass tile.
		internal static let listGap: CGFloat = 8
		internal static let listWidth: CGFloat = 260
		internal static let listPadding: CGFloat = 4
		internal static let listRadius: CGFloat = 14
		internal static let rowHeight: CGFloat = 40
		internal static let rowSpacing: CGFloat = 2
		internal static let rowPitch: CGFloat = rowHeight + rowSpacing
		internal static let rowRadius: CGFloat = 10
		internal static let rowLeading: CGFloat = 6
		internal static let rowTrailing: CGFloat = 10.5
		internal static let iconTile: CGFloat = 26
		internal static let icon: CGFloat = 16
		internal static let iconGap: CGFloat = 6
		internal static let maxRows: Int = 5
	}

	private static func isDark(_ appearance: NSAppearance) -> Bool {
		appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
	}

	private static func dynamic(
		light: NSColor,
		dark: NSColor
	) -> NSColor {
		NSColor(name: nil) { appearance in
			isDark(appearance) ? dark : light
		}
	}

	/// The ready circle inverts the page's appearance: light on dark, dark on light.
	private static var capsuleFill: NSColor {
		dynamic(light: NSColor(white: 0.12, alpha: 1), dark: NSColor(white: 0.93, alpha: 1))
	}

	private static var capsuleText: NSColor {
		dynamic(light: .white, dark: .black)
	}

	/// Under glass: enough of the page's own background to keep text legible.
	private static var frost: NSColor {
		dynamic(light: NSColor(white: 1, alpha: 0.82), dark: NSColor(white: 0.08, alpha: 0.72))
	}

	/// Arx's chrome text, as the Destination Picker's rows use it.
	private static func chromeText(alpha: CGFloat) -> NSColor {
		dynamic(
			light: NSColor(srgbRed: 39 / 255, green: 34 / 255, blue: 57 / 255, alpha: alpha),
			dark: NSColor(srgbRed: 227 / 255, green: 224 / 255, blue: 245 / 255, alpha: alpha)
		)
	}

	private static var selectedFill: NSColor {
		dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 0, alpha: 0.3))
	}

	private static var selectedEdge: NSColor {
		dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 0, alpha: 0.25))
	}

	private static var hairline: NSColor {
		dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.06))
	}

	private static func addFrost(to inner: NSView) -> NSView {
		let frost: NSView = .init(frame: inner.bounds)
		frost.wantsLayer = true
		inner.addSubview(frost, positioned: .below, relativeTo: nil)
		return frost
	}

	private static func run(
		animated: Bool,
		_ changes: () -> Void
	) {
		guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			changes()
			CATransaction.commit()
			return
		}

		withoutActuallyEscaping(changes) { changes in
			NSAnimationContext.runAnimationGroup { context in
				context.duration = 0.22
				context.allowsImplicitAnimation = true
				context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
				changes()
			}
		}
	}

	/// A glass view and the content view its subviews go in.
	private static func glass(radius: CGFloat) -> (NSGlassEffectView, NSView) {
		let glass: NSGlassEffectView = .init(frame: .zero)
		glass.cornerRadius = radius
		let content: NSView = .init(frame: .zero)
		glass.contentView = content
		glass.wantsLayer = true
		return (glass, content)
	}

	private static func label(
		size: CGFloat,
		weight: NSFont.Weight,
		color: NSColor
	) -> NSTextField {
		let label: NSTextField = .init(labelWithString: "")
		label.font = .systemFont(ofSize: size, weight: weight)
		label.textColor = color
		label.lineBreakMode = .byTruncatingTail
		label.maximumNumberOfLines = 1
		return label
	}
}
