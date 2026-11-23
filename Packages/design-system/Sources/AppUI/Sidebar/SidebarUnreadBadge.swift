import BrowserCore
import SwiftUI

/// What a tab's page has unread (DEV-907): a count in a small capsule, or a dot. Rows show it
/// where the close button appears on hover; Favorite tiles at their top trailing corner.
internal struct SidebarUnreadBadge: View {
	private let badge: UnreadBadge

	internal init(_ badge: UnreadBadge) {
		self.badge = badge
	}

	internal var body: some View {
		Group {
			switch badge {
			case .none:
				EmptyView()

			case .dot:
				Circle()
					.fill(BrowserTheme.accent)
					.frame(width: 7, height: 7)

			case let .count(count):
				Text(verbatim: count > UnreadBadge.maximumCount ? "\(UnreadBadge.maximumCount)+" : "\(count)")
					.font(.system(size: 10, weight: .semibold).monospacedDigit())
					.foregroundStyle(BrowserTheme.onAccent)
					.lineLimit(1)
					.padding(.horizontal, 5)
					.frame(minWidth: 16, minHeight: 16)
					.background(BrowserTheme.accent, in: Capsule())
			}
		}
		.allowsHitTesting(false)
		.accessibilityLabel(accessibilityLabel)
	}

	private var accessibilityLabel: String {
		switch badge {
		case .none: ""
		case .dot: String.localized(.appUI.sidebar.unreadDot)
		case let .count(count): String.localized(.appUI.sidebar.unreadCount(count))
		}
	}
}
