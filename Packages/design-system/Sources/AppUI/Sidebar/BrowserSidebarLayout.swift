import AppKit
import BrowserCore
import SwiftUI

/// Keeps one sidebar mounted while switching between docked and edge-hover presentation.
public struct BrowserSidebarLayout<Sidebar: View, Page: View>: View {
	private let isPinned: Bool
	private let isSuspended: Bool
	private let keepsSidebarRevealed: Bool
	private let libraryFillsWindow: Bool
	private let chromeIsTranslucent: Bool
	private let onWidthCommitted: (Double) -> Void
	private let sidebar: Sidebar
	private let page: Page

	/// Read through a binding so per-frame swipe progress re-renders this layout, not its owner.
	@Binding
	private var libraryProgress: CGFloat

	@Environment(\.sidebarInteraction)
	private var interaction

	/// The window side the sidebar sits on (DEV-913). Everything else mirrors.
	@Environment(\.sidebarEdge)
	private var edge

	@SwiftUI.State
	private var width: CGFloat

	@SwiftUI.State
	private var availableWidth: CGFloat

	@SwiftUI.State
	private var resizeOrigin: CGFloat?

	@SwiftUI.State
	private var resizeHovered: Bool

	@SwiftUI.State
	private var hoverRequested: Bool

	@SwiftUI.State
	private var isHoverRevealed: Bool

	/// Hover tracking ended during a drag; the reveal is decided when the drag finishes.
	@SwiftUI.State
	private var isAwaitingDragEnd: Bool

	/// A hover preview opened from the floating sidebar keeps it on screen while the pointer is in the preview.
	@SwiftUI.State
	private var isPreviewOpen: Bool

	/// The window is in full screen or entering it (DEV-912).
	@SwiftUI.State
	private var isFullScreen: Bool

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	public init(
		isPinned: Bool,
		isSuspended: Bool = false,
		keepsSidebarRevealed: Bool = false,
		libraryProgress: Binding<CGFloat> = .constant(0),
		libraryFillsWindow: Bool = false,
		chromeIsTranslucent: Bool = false,
		width: Double = BrowserSidebarWidth.standard,
		onWidthCommitted: @escaping (Double) -> Void = { _ in },
		@ViewBuilder sidebar: () -> Sidebar,
		@ViewBuilder page: () -> Page
	) {
		self.isPinned = isPinned
		self.isSuspended = isSuspended
		self.keepsSidebarRevealed = keepsSidebarRevealed
		self._libraryProgress = libraryProgress
		self.libraryFillsWindow = libraryFillsWindow
		self.chromeIsTranslucent = chromeIsTranslucent
		self.onWidthCommitted = onWidthCommitted
		self._width = .init(initialValue: width)
		self.sidebar = sidebar()
		self.page = page()
		self._hoverRequested = .init(initialValue: false)
		self._isHoverRevealed = .init(initialValue: false)
		self._isPreviewOpen = .init(initialValue: false)
		self._isFullScreen = .init(initialValue: false)
		self._isAwaitingDragEnd = .init(initialValue: false)
		self._availableWidth = .init(initialValue: 1120)
		self._resizeOrigin = .init(initialValue: nil)
		self._resizeHovered = .init(initialValue: false)
	}

	public var body: some View {
		ZStack(alignment: edge == .leading ? .leading : .trailing) {
			HStack(spacing: 0) {
				if edge == .leading { Color.clear.frame(width: isPinned ? pageInset : 0) }
				page

					// Slides out under the Spaces overview rather than squeezing a live page to nothing.
					.offset(x: direction * (isPinned ? currentWidth - pageInset : 0))

					// Once the overview covers it, the empty page stops moving (DEV-1248).
					.transformEnvironment(\.emptyPageMotionPaused) { $0 = $0 || isPageCovered }
				if edge == .trailing { Color.clear.frame(width: isPinned ? pageInset : 0) }
			}

			sidebar

				// A hidden sidebar's rows stay mounted off the window's edge.
				.siteIconsShown(isVisible)
				.environment(\.sidebarWidths, .init(base: width, expanded: expandedWidth))
				.environment(\.browserWindowIsFullScreen, isFullScreen)
				.onPreferenceChange(SidebarHoverPreviewOpen.self) { isPreviewOpen = $0 }
				.frame(width: currentWidth)
				.frame(maxHeight: .infinity)
				.background {
					// Docked over a translucent window's chrome (DEV-1286), the sidebar is that
					// chrome: a second layer would make it more solid than the window around it.
					// Floating over the page, it stays solid.
					if !isPinned || !chromeIsTranslucent { BrowserChromeBackground(textured: true) }
					if !isPinned { BrowserTheme.floatingSidebarOverlay }
				}
				.clipShape(.rect(cornerRadius: isPinned ? 0 : floating.cornerRadius, style: .continuous))
				.overlay {
					if !isPinned {
						RoundedRectangle(cornerRadius: floating.cornerRadius, style: .continuous)
							.strokeBorder(BrowserTheme.pageBorder, lineWidth: floating.borderWidth)
							.allowsHitTesting(false)
					}
				}
				.browserShadow(isPinned ? .none : floating.shadow)
				.padding(.vertical, isPinned ? 0 : floating.inset)
				.offset(x: direction * (isVisible ? (isPinned ? 0 : floating.inset) : -currentWidth - 24))
				.allowsHitTesting(isVisible && !isSuspended)

				// A hidden sidebar is moved out past its window edge, with its next space over the page.
				.environment(\.sidebarAcceptsDrops, isVisible && !isSuspended)
				.disabled(!isVisible || isSuspended)
				.accessibilityHidden(!isVisible || isSuspended)

			if isVisible, !isSuspended, libraryProgress == 0 {
				resizeHandle
					.offset(x: direction * (width + (isPinned ? 0 : floating.inset) - 6))
			}
		}
		.clipped()
		.background {
			BrowserFullScreenObserver { isFullScreen in
				guard self.isFullScreen != isFullScreen else { return }

				// macOS's own transition takes about half a second; the inset moves with it.
				withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
					self.isFullScreen = isFullScreen
				}
			}
		}
		.contentShape(.rect)
		.onContinuousHover(perform: pointerMoved)
		.onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
			availableWidth = $0
			clampWidth()
		}
		.task(id: [hoverRequested, isPreviewOpen]) { await hoverRequestChanged() }
		.task(id: isAwaitingDragEnd) { await awaitDragEnd() }
		.onChange(of: isPinned) { _, _ in resetHover() }
		.onChange(of: isSuspended) { _, _ in
			if !keepsSidebarRevealed { resetHover() }
		}
		.animation(reduceMotion ? nil : .smooth(duration: 0.24), value: isPinned)
		.animation(
			reduceMotion ? nil : .smooth(duration: BrowserMetrics.Library.transitionDuration),
			value: libraryFillsWindow
		)
		.animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isHoverRevealed)
	}

	/// The Library needs room for its rail, but never takes the page's minimum width.
	private var expandedWidth: CGFloat {
		libraryFillsWindow ? availableWidth : panelWidth
	}

	private var panelWidth: CGFloat {
		let wanted = max(width + BrowserMetrics.Library.minimumExpansion, BrowserMetrics.Library.minimumWidth)
		return min(wanted, max(width, availableWidth - 360))
	}

	private var currentWidth: CGFloat {
		width + (expandedWidth - width) * libraryProgress
	}

	private var pageInset: CGFloat {
		min(currentWidth, panelWidth)
	}

	/// The Spaces overview has opened over the whole window and is in view: a floating sidebar
	/// that slid away, as the pointer leaves or the command bar opens, uncovers the page.
	internal static func isPageCovered(
		libraryFillsWindow: Bool,
		libraryProgress: CGFloat,
		isSidebarVisible: Bool
	) -> Bool {
		isSidebarVisible && libraryFillsWindow && libraryProgress >= 1
	}

	private var isPageCovered: Bool {
		Self.isPageCovered(
			libraryFillsWindow: libraryFillsWindow,
			libraryProgress: libraryProgress,
			isSidebarVisible: isVisible
		)
	}

	private var floating: BrowserMetrics.FloatingSidebar.Type { BrowserMetrics.FloatingSidebar.self }

	/// 1 when the sidebar is on the left, -1 on the right: offsets away from its edge flip.
	private var direction: CGFloat { edge == .leading ? 1 : -1 }

	private var isVisible: Bool {
		isPinned || (isHoverRevealed && (!isSuspended || keepsSidebarRevealed))
	}

	private var resizeHandle: some View {
		Capsule(style: .continuous)
			.fill(BrowserTheme.accent.opacity(resizeHovered || resizeOrigin != nil ? 0.65 : 0))
			.frame(width: 2)
			.padding(.vertical, 24)
			.frame(width: 6)
			.contentShape(.rect)
			.onHover(perform: resizeHoverChanged)
			.gesture(resizeGesture)
			.onTapGesture(count: 2) {
				width = BrowserSidebarWidth.standard
				clampWidth()
				onWidthCommitted(width)
			}
			.accessibilityLabel(String.localized(.appUI.sidebar.width))
			.accessibilityValue(String.localized(.appUI.sidebar.widthValue(Int(width))))
			.accessibilityAdjustableAction { direction in
				width += direction == .increment ? 20 : -20
				clampWidth()
				onWidthCommitted(width)
			}
			.help(String.localized(.appUI.sidebar.resizeHelp))
	}

	private var resizeGesture: some Gesture {
		DragGesture(minimumDistance: 0, coordinateSpace: .global)
			.onChanged(resizeChanged)
			.onEnded { _ in
				resizeOrigin = nil
				onWidthCommitted(width)
			}
	}

	private func resizeChanged(_ value: DragGesture.Value) {
		if resizeOrigin == nil { resizeOrigin = width }
		width = (resizeOrigin ?? width) + direction * value.translation.width
		clampWidth()
	}

	private func clampWidth() {
		let range = BrowserSidebarWidth.range
		let upperBound = min(range.upperBound, max(range.lowerBound, availableWidth - 360))
		width = min(max(width, range.lowerBound), upperBound)
	}

	private func resizeHoverChanged(_ hovered: Bool) {
		resizeHovered = hovered
		if hovered {
			NSCursor.resizeLeftRight.set()
		} else {
			NSCursor.arrow.set()
		}
	}

	private func pointerMoved(_ phase: HoverPhase) {
		guard !isPinned, !isSuspended, resizeOrigin == nil else { return }
		switch phase {
		case let .active(location):
			isAwaitingDragEnd = false

			// Measured from the sidebar's own edge of the window.
			let x = edge == .leading ? location.x : availableWidth - location.x
			hoverRequested = revealRegion.contains(x: x, isRevealed: isHoverRevealed)

		case .ended:
			// A drag out of a Library page (a tab from a Spaces column) can end hover tracking mid-drag,
			// with the pointer still over the page: decide once the button is up.
			if libraryProgress > 0, NSEvent.pressedMouseButtons != 0 {
				isAwaitingDragEnd = true
				return
			}
			hoverRequested = false
		}
	}

	/// Hides the sidebar after a drag that ended hover tracking, unless the pointer came back over the window.
	private func awaitDragEnd() async {
		guard isAwaitingDragEnd else { return }
		do {
			while NSEvent.pressedMouseButtons != 0 {
				try await Task.sleep(for: .milliseconds(50))
			}

			// A release inside the window delivers a hover event, which settles it first.
			try await Task.sleep(for: .milliseconds(100))
		} catch {
			return
		}
		guard isAwaitingDragEnd else { return }
		isAwaitingDragEnd = false
		hoverRequested = false
	}

	/// What keeps the floating sidebar on screen: the whole visible sidebar, the Library and its page included.
	private var revealRegion: SidebarRevealRegion {
		.init(visibleWidth: currentWidth, inset: floating.inset)
	}

	private func hoverRequestChanged() async {
		let requested = hoverRequested || isPreviewOpen
		do {
			// Debounce edge crossings and allow a brief excursion outside the revealed sidebar.
			try await Task.sleep(for: requested ? interaction.edgeRevealDelay : interaction.edgeHideDelay)
		} catch {
			// A new pointer event or removal of this view cancels the pending transition.
			return
		}
		guard !Task.isCancelled, !isPinned, !isSuspended else { return }
		isHoverRevealed = requested
	}

	private func resetHover() {
		isAwaitingDragEnd = false
		hoverRequested = false
		isHoverRevealed = false
	}
}

/// Where the pointer reveals a collapsed sidebar, and where it keeps it revealed.
///
/// While revealed, the region spans the sidebar as drawn: when the Library opens, that includes its rail and
/// page, and with the Spaces page that's the whole window. Leaving it, by more than `margin`, hides the sidebar.
internal struct SidebarRevealRegion: Equatable {
	/// The width of the edge strip that reveals the sidebar.
	internal static let edgeWidth: CGFloat = 8

	/// The slack beyond the sidebar's edge before the pointer counts as having left.
	internal static let margin: CGFloat = 12

	/// The sidebar's width as drawn, the Library's expansion included.
	internal var visibleWidth: CGFloat

	/// The floating sidebar's gap to the window edge.
	internal var inset: CGFloat

	internal init(
		visibleWidth: CGFloat,
		inset: CGFloat
	) {
		self.visibleWidth = visibleWidth
		self.inset = inset
	}

	/// The trailing edge, from the window's leading edge, of the area that keeps the sidebar revealed.
	internal var keepWidth: CGFloat {
		inset + visibleWidth + Self.margin
	}

	internal func contains(
		x: CGFloat,
		isRevealed: Bool
	) -> Bool {
		x <= (isRevealed ? keepWidth : Self.edgeWidth)
	}
}

extension EnvironmentValues {
	/// The window side the sidebar sits on, from Settings › Appearance (DEV-913).
	@Entry
	public var sidebarEdge: HorizontalEdge = .leading
}
