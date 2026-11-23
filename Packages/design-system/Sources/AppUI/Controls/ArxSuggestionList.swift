import AppKit
import SwiftUI

/// One choice in Arx's suggestion dropdown: a title with an optional leading symbol.
public struct ArxSuggestion<ID: Hashable>: Identifiable {
	public var id: ID
	public var title: String
	public var symbol: String?

	public init(
		id: ID,
		title: String,
		symbol: String? = nil
	) {
		self.id = id
		self.title = title
		self.symbol = symbol
	}
}

/// Arx's suggestion dropdown: a floating, rounded list on the regular material, the one URL
/// templates complete placeholders with. The highlighted row has the library's selection fill.
///
/// It only draws the list. `ArxDropdown` and `TemplateField` float it under their anchor and
/// move the highlight with the arrow keys.
public struct ArxSuggestionList<ID: Hashable>: View {
	private let suggestions: [ArxSuggestion<ID>]
	private let highlighted: ID?
	private let checked: ID?
	private let minWidth: CGFloat
	private let select: (ArxSuggestion<ID>) -> Void

	/// `checked` marks the current choice, as a dropdown does; `minWidth` lets the list match its
	/// anchor's width.
	public init(
		_ suggestions: [ArxSuggestion<ID>],
		highlighted: ID?,
		checked: ID? = nil,
		minWidth: CGFloat = BrowserMetrics.CreateMenu.width,
		select: @escaping (ArxSuggestion<ID>) -> Void
	) {
		self.suggestions = suggestions
		self.highlighted = highlighted
		self.checked = checked
		self.minWidth = minWidth
		self.select = select
	}

	public var body: some View {
		VStack(spacing: 0) {
			ForEach(suggestions) { suggestion in
				row(suggestion)
			}
		}
		.padding(BrowserMetrics.CreateMenu.padding)
		.frame(minWidth: minWidth)
		.fixedSize()
		.background(
			.regularMaterial,
			in: .rect(cornerRadius: BrowserMetrics.FloatingPanel.cornerRadius, style: .continuous)
		)
		.overlay {
			RoundedRectangle(cornerRadius: BrowserMetrics.FloatingPanel.cornerRadius, style: .continuous)
				.strokeBorder(BrowserTheme.pageBorder, lineWidth: BrowserMetrics.PageCard.borderWidth)
		}
	}

	private func row(_ suggestion: ArxSuggestion<ID>) -> some View {
		let isHighlighted = suggestion.id == highlighted
		let hasSymbols = suggestions.contains { $0.symbol != nil } || checked != nil
		return Button { select(suggestion) } label: {
			HStack(spacing: BrowserMetrics.CreateMenu.iconSpacing) {
				if hasSymbols {
					Image(systemName: suggestion.id == checked ? "checkmark" : suggestion.symbol ?? "")
						.font(.system(size: BrowserMetrics.CreateMenu.symbolSize, weight: .medium))
						.frame(width: BrowserMetrics.CreateMenu.iconWidth)
						.accessibilityHidden(true)
				}
				Text(suggestion.title)
					.font(.system(size: BrowserMetrics.Library.rowFontSize, weight: .medium))
					.lineLimit(1)
				Spacer(minLength: 0)
			}
			.foregroundStyle(BrowserTheme.text)
			.padding(.horizontal, BrowserMetrics.CreateMenu.rowHorizontalPadding)
			.frame(height: BrowserMetrics.CreateMenu.rowHeight)
			.background(
				isHighlighted
				? BrowserTheme.libraryTint.opacity(BrowserMetrics.Library.selectionOpacity)
				: .clear,
				in: ArxControlShape()
			)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.focusEffectDisabled()
		.accessibilityAddTraits(isHighlighted || suggestion.id == checked ? .isSelected : [])
	}
}

/// The window an `ArxSuggestionList` floats in. Never key, so typing stays in the field, or the
/// window, that opened it.
@MainActor
internal final class ArxSuggestionPanel {
	private let window: NSPanel
	private let parent: NSWindow
	private var host: NSHostingView<AnyView>?

	internal init(parent: NSWindow) {
		self.parent = parent
		window = NSPanel(
			contentRect: .zero,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		window.isOpaque = false
		window.backgroundColor = .clear
		window.hasShadow = true
		window.appearance = parent.effectiveAppearance
		window.isReleasedWhenClosed = false
		window.becomesKeyOnlyIfNeeded = true
	}

	internal var isVisible: Bool {
		window.isVisible
	}

	/// Shows `content` under `anchor`, a rectangle in screen coordinates, aligned to its leading
	/// edge. It opens above the anchor when there's no room below on the anchor's screen.
	internal func show(
		_ content: some View,
		below anchor: CGRect
	) {
		let root = AnyView(content)
		if let host {
			host.rootView = root
		} else {
			let host = NSHostingView(rootView: root)
			host.safeAreaRegions = []
			window.contentView = host
			self.host = host
		}
		window.appearance = parent.effectiveAppearance
		let size = host?.fittingSize ?? .zero
		let gap = BrowserMetrics.FloatingPanel.anchorGap
		var frame: CGRect = .init(
			x: anchor.minX,
			y: anchor.minY - gap - size.height,
			width: size.width,
			height: size.height
		)
		if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame, frame.minY < visible.minY {
			frame.origin.y = anchor.maxY + gap
		}
		window.setFrame(frame, display: true)
		if window.parent == nil {
			parent.addChildWindow(window, ordered: .above)
		}
		window.orderFront(nil)
	}

	/// Whether a click in screen coordinates landed on the list.
	internal func contains(_ point: CGPoint) -> Bool {
		window.isVisible && window.frame.contains(point)
	}

	internal func close() {
		window.parent?.removeChildWindow(window)
		window.orderOut(nil)
	}
}
