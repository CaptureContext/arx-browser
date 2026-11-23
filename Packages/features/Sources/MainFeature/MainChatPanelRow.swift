import AppKit
import AppUI
import BrowserCore
import SwiftUI

/// The page beside the chat panel, with the panel's leading edge as its resize handle (DEV-761).
///
/// Dragging the edge sets the panel's width within ``BrowserChatWidth/range``, and never so wide
/// that the page gets narrower than ``minimumPageWidth``. Double-clicking it goes back to the
/// standard width. The width is committed when the drag ends, so the window saves it once.
internal struct MainChatPanelRow<Page: View, Panel: View>: View {
	internal static var minimumPageWidth: CGFloat { 360 }

	private let isOpen: Bool
	private let width: Double
	private let onWidthCommitted: (Double) -> Void
	private let page: Page
	private let panel: Panel

	@SwiftUI.State
	private var dragWidth: Double?

	@SwiftUI.State
	private var dragOrigin: Double?

	@SwiftUI.State
	private var availableWidth: CGFloat

	@SwiftUI.State
	private var isHandleHovered: Bool

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	internal init(
		isOpen: Bool,
		width: Double,
		onWidthCommitted: @escaping (Double) -> Void,
		@ViewBuilder page: () -> Page,
		@ViewBuilder panel: () -> Panel
	) {
		self.isOpen = isOpen
		self.width = width
		self.onWidthCommitted = onWidthCommitted
		self.page = page()
		self.panel = panel()
		self._dragWidth = .init(initialValue: nil)
		self._dragOrigin = .init(initialValue: nil)
		self._availableWidth = .init(initialValue: 0)
		self._isHandleHovered = .init(initialValue: false)
	}

	internal var body: some View {
		HStack(spacing: BrowserMetrics.PageCard.inset) {
			page
			if isOpen {
				panel
					.frame(width: shownWidth)
					.overlay(alignment: .leading) { handle }
					.transition(.move(edge: .trailing).combined(with: .opacity))
			}
		}
		.onGeometryChange(for: CGFloat.self, of: \.size.width) { availableWidth = $0 }
		.animation(reduceMotion ? nil : .smooth(duration: 0.25), value: isOpen)
	}

	/// The width the panel takes now: the drag's, or the saved one, fitted to the window.
	private var shownWidth: CGFloat {
		clamped(dragWidth ?? width)
	}

	private func clamped(_ value: Double) -> CGFloat {
		let range = BrowserChatWidth.range
		let fitting: Double = availableWidth > 0
		? max(range.lowerBound, Double(availableWidth - Self.minimumPageWidth))
		: range.upperBound
		return CGFloat(min(max(value, range.lowerBound), min(range.upperBound, fitting)))
	}

	private var handle: some View {
		Capsule(style: .continuous)
			.fill(BrowserTheme.accent.opacity(isHandleHovered || dragOrigin != nil ? 0.65 : 0))
			.frame(width: 2)
			.padding(.vertical, 24)
			.frame(width: 8)
			.contentShape(.rect)

			// Half over the gap between the page and the panel, so the edge is easy to catch.
			.offset(x: -BrowserMetrics.PageCard.inset / 2)
			.onHover(perform: hoverChanged)
			.gesture(resizeGesture)
			.onTapGesture(count: 2) {
				dragWidth = nil
				onWidthCommitted(BrowserChatWidth.standard)
			}
			.accessibilityElement()
			.accessibilityLabel(String.localized(.appUI.chat.width))
			.accessibilityValue(String.localized(.appUI.sidebar.widthValue(Int(shownWidth))))
			.accessibilityAdjustableAction { direction in
				onWidthCommitted(Double(shownWidth) + (direction == .increment ? 20 : -20))
			}
			.help(String.localized(.appUI.chat.resizeHelp))
	}

	private var resizeGesture: some Gesture {
		DragGesture(minimumDistance: 0, coordinateSpace: .global)
			.onChanged { value in
				let origin: Double = dragOrigin ?? Double(shownWidth)
				dragOrigin = origin

				// The panel is on the trailing side: dragging its edge left makes it wider.
				dragWidth = Double(clamped(origin - value.translation.width))
			}
			.onEnded { _ in
				let committed: Double = dragWidth ?? width
				dragOrigin = nil
				onWidthCommitted(committed)
				dragWidth = nil
			}
	}

	private func hoverChanged(_ hovered: Bool) {
		isHandleHovered = hovered
		if hovered {
			NSCursor.resizeLeftRight.set()
		} else {
			NSCursor.arrow.set()
		}
	}
}
