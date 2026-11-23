import SwiftUI

public struct SidebarCreateItem: Identifiable {
	public var title: String
	public var symbol: String
	public var shortcut: String?
	public var isEnabled: Bool
	public var action: () -> Void

	public init(
		title: String,
		symbol: String,
		shortcut: String? = nil,
		isEnabled: Bool = true,
		action: @escaping () -> Void
	) {
		self.title = title
		self.symbol = symbol
		self.shortcut = shortcut
		self.isEnabled = isEnabled
		self.action = action
	}

	public var id: String { title }
}

/// The switcher's plus, which turns into a cross while its menu is open.
public struct SidebarCreateButton: View {
	private let help: String
	private let sections: [[SidebarCreateItem]]

	@SwiftUI.State
	private var isOpen: Bool

	/// Clicking the cross first dismisses the panel, and that same click must not reopen it.
	@SwiftUI.State
	private var closedAt: Date

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	public init(
		help: String,
		sections: [[SidebarCreateItem]]
	) {
		self.help = help
		self.sections = sections
		self._isOpen = .init(initialValue: false)
		self._closedAt = .init(initialValue: .distantPast)
	}

	public var body: some View {
		Button {
			if Date.now.timeIntervalSince(closedAt) > 0.3 { isOpen = true }
		} label: {
			Image(systemName: "plus")
				.rotationEffect(.degrees(isOpen ? 45 : 0))
				.animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isOpen)
				.frame(width: BrowserMetrics.SpaceSwitcher.buttonSize, height: BrowserMetrics.SpaceSwitcher.buttonSize)
				.contentShape(.rect)
		}

		// The footer's quiet tile, held while the menu is open (DEV-788).
		.buttonStyle(SidebarFooterButtonStyle(isActive: isOpen))
		.help(help)
		.accessibilityLabel(help)
		.onChange(of: isOpen) { _, open in
			if !open { closedAt = .now }
		}
		.floatingPanel(isPresented: $isOpen) {
			SidebarCreateMenu(sections: sections) { isOpen = false }
		}
	}
}

private struct SidebarCreateMenu: View {
	private let sections: [[SidebarCreateItem]]
	private let dismiss: () -> Void

	fileprivate init(
		sections: [[SidebarCreateItem]],
		dismiss: @escaping () -> Void
	) {
		self.sections = sections
		self.dismiss = dismiss
	}

	fileprivate var body: some View {
		VStack(spacing: 0) {
			ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
				if index > 0 {
					Rectangle()
						.fill(BrowserTheme.divider.opacity(BrowserMetrics.Section.dividerOpacity))
						.frame(height: BrowserMetrics.Section.dividerThickness)
						.padding(.vertical, BrowserMetrics.CreateMenu.dividerSpacing)
						.padding(.horizontal, BrowserMetrics.CreateMenu.rowHorizontalPadding)
				}
				ForEach(section) { item in
					SidebarCreateRow(item: item, dismiss: dismiss)
				}
			}
		}
		.padding(BrowserMetrics.CreateMenu.padding)
		.frame(width: BrowserMetrics.CreateMenu.width)
	}
}

private struct SidebarCreateRow: View {
	private let item: SidebarCreateItem
	private let dismiss: () -> Void

	@SwiftUI.State
	private var isHovered: Bool

	fileprivate init(
		item: SidebarCreateItem,
		dismiss: @escaping () -> Void
	) {
		self.item = item
		self.dismiss = dismiss
		self._isHovered = .init(initialValue: false)
	}

	fileprivate var body: some View {
		Button {
			dismiss()
			item.action()
		} label: {
			HStack(spacing: BrowserMetrics.CreateMenu.iconSpacing) {
				Image(systemName: item.symbol)
					.font(.system(size: BrowserMetrics.CreateMenu.symbolSize, weight: .medium))
					.frame(width: BrowserMetrics.CreateMenu.iconWidth)
				Text(item.title)
					.font(.system(size: BrowserMetrics.Library.rowFontSize, weight: .medium))
				Spacer(minLength: 8)
				if let shortcut = item.shortcut {
					Text(shortcut)
						.font(.system(size: 12, weight: .medium))
						.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.subtitleOpacity))
				}
			}
			.foregroundStyle(
				BrowserTheme.text.opacity(item.isEnabled ? 1 : BrowserMetrics.State.disabledOpacity)
			)
			.padding(.horizontal, BrowserMetrics.CreateMenu.rowHorizontalPadding)
			.frame(height: BrowserMetrics.CreateMenu.rowHeight)
			.background(
				isHovered && item.isEnabled
				? BrowserTheme.libraryTint.opacity(BrowserMetrics.Library.selectionOpacity)
				: .clear,
				in: ArxControlShape()
			)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.focusEffectDisabled()
		.disabled(!item.isEnabled)
		.onHover { isHovered = $0 }
	}
}
