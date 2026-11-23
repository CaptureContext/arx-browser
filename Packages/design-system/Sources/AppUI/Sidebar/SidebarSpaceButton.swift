import SwiftUI

/// Accepts tab drops and reveals its space after a stationary drag hover.
public struct SidebarSpaceButton<Menu: View>: View {
	private let spaceID: UUID?
	private let name: String
	private let symbol: String
	private let isSelected: Bool
	private let isCollapsed: Bool
	private let width: CGFloat?
	private let nudge: CGFloat
	private let deletionHint: String?
	private let onSelect: () -> Void
	private let onDropTabs: ([SidebarItem.ID]) -> Void
	private let menu: Menu

	@Environment(\.sidebarAcceptsDrops)
	private var acceptsDrops

	@Environment(\.sidebarInteraction)
	private var interaction

	@Environment(\.sidebarSpaceSlide)
	private var slide

	@Environment(\.colorSchemeContrast)
	private var contrast

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@SwiftUI.State
	private var isDragTargeted: Bool

	/// - Parameters:
	///   - spaceID: The button's space. In a pager's footer a click then slides the
	///     sidebar to it first, and `onSelect` is only called where the sidebar can't (DEV-1310).
	///   - deletionHint: Why the space is marked for deletion (DEV-1336), which shows a warning
	///     badge and this as its hint; `nil` when it isn't.
	public init(
		spaceID: UUID? = nil,
		name: String,
		symbol: String,
		isSelected: Bool,
		isCollapsed: Bool = false,
		width: CGFloat? = nil,
		nudge: CGFloat = 0,
		deletionHint: String? = nil,
		onSelect: @escaping () -> Void,
		onDropTabs: @escaping ([SidebarItem.ID]) -> Void,
		@ViewBuilder menu: () -> Menu
	) {
		self.spaceID = spaceID
		self.name = name
		self.symbol = symbol
		self.isSelected = isSelected
		self.isCollapsed = isCollapsed
		self.width = width
		self.nudge = nudge
		self.deletionHint = deletionHint
		self.onSelect = onSelect
		self.onDropTabs = onDropTabs
		self.menu = menu()
		self._isDragTargeted = .init(initialValue: false)
	}

	public var body: some View {
		Button(action: select) {
			// Both stay in place, centered on one point: a dot morphs into the icon and back
			// with a scale and a crossfade, so nothing slides and nothing is left behind.
			ZStack {
				Circle()
					.frame(width: BrowserMetrics.SpaceSwitcher.dotSize, height: BrowserMetrics.SpaceSwitcher.dotSize)
					.scaleEffect(isCollapsed || reduceMotion ? 1 : 2.4)
					.opacity(isCollapsed ? 1 : 0)
				SpaceIconImage(rawValue: symbol)
					.font(.system(size: BrowserMetrics.SpaceSwitcher.iconSymbolSize, weight: .medium))

					// Among dots the icon is wider than its cell and draws over the gaps.
					.fixedSize()
					.scaleEffect(isCollapsed && !reduceMotion ? 0.4 : 1)
					.opacity(isCollapsed ? 0 : 1)
			}

			// Drawn aside to clear a neighbouring icon; the button itself stays in its cell.
			.offset(x: nudge)
				.frame(
					// A picker cell includes its share of the gaps, so neighbouring buttons meet.
					width: width ?? (isCollapsed ? BrowserMetrics.SpaceSwitcher.dotWidth : BrowserMetrics.SpaceSwitcher.buttonSize),
					height: BrowserMetrics.SpaceSwitcher.buttonSize
				)
				.foregroundStyle(BrowserTheme.text)
				.opacity(
					isSelected || isDragTargeted
					? 1
					: BrowserMetrics.State.opacity(BrowserMetrics.SpaceSwitcher.inactiveOpacity, contrast: contrast)
				)
				.contentShape(.rect)
		}

		// The quiet tile on hover and press, or the accent while a tab is dragged over it.
		.buttonStyle(SidebarFooterButtonStyle(highlight: isDragTargeted ? AnyShapeStyle(BrowserTheme.accent.opacity(0.3)) : nil))
		.focusEffectDisabled()
		.contextMenu { menu }
		.accessibilityLabel(String.localized(.appUI.sidebar.space(name)))
		.accessibilityAddTraits(isSelected ? .isSelected : [])
		.sidebarDropArea(isEnabled: acceptsDrops) { area in
			area
				.dropDestination(for: SidebarTransfer.self) { transfers, _ in
					isDragTargeted = false
					let tabs = SidebarTransfer.orderedIDs(transfers)
					if !tabs.isEmpty { onDropTabs(tabs) }
				}

				// Local drag IDs are optional outside the source container. Validate the typed payload on drop.
				.dropConfiguration { _ in .init(operation: .move) }
				.onDropSessionUpdated { session in
					switch session.phase {
					case .entering, .active: isDragTargeted = true
					default: isDragTargeted = false
					}
				}
		}
		.task(id: isDragTargeted) {
			guard isDragTargeted, !isSelected else { return }
			do {
				try await Task.sleep(for: interaction.spaceHoverDelay)
			} catch {
				return
			}
			guard !Task.isCancelled, isDragTargeted else { return }
			onSelect()
		}
	}
}

extension SidebarSpaceButton {
	/// Slides the sidebar to the space where it can, and selects it otherwise.
	private func select() {
		if let spaceID, slide?(spaceID) == true { return }
		onSelect()
	}
}

extension SidebarSpaceButton where Menu == EmptyView {
	public init(
		spaceID: UUID? = nil,
		name: String,
		symbol: String,
		isSelected: Bool,
		isCollapsed: Bool = false,
		width: CGFloat? = nil,
		nudge: CGFloat = 0,
		onSelect: @escaping () -> Void,
		onDropTabs: @escaping ([SidebarItem.ID]) -> Void
	) {
		self.init(
			spaceID: spaceID,
			name: name,
			symbol: symbol,
			isSelected: isSelected,
			isCollapsed: isCollapsed,
			width: width,
			nudge: nudge,
			onSelect: onSelect,
			onDropTabs: onDropTabs
		) {
			EmptyView()
		}
	}
}
