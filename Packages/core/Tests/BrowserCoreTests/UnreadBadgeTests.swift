import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-907: unread counts from page titles and the Badging API.
internal struct UnreadBadgeTests {
	@Test
	internal func titlesReportTheirUnreadCount() {
		expectNoDifference(UnreadBadge(title: "(3) Home / X"), .count(3))
		expectNoDifference(UnreadBadge(title: "(99+) Notifications"), .count(99))
		expectNoDifference(UnreadBadge(title: "[12] Chat"), .count(12))
		expectNoDifference(UnreadBadge(title: "Inbox (5) - someone@example.com - Mail"), .count(5))
		expectNoDifference(UnreadBadge(title: "Inbox (7)"), .count(7))
		expectNoDifference(UnreadBadge(title: "• Slack"), .dot)
		expectNoDifference(UnreadBadge(title: "(0) Home"), .none)
	}

	@Test
	internal func titlesWithoutACountReportNothing() {
		expectNoDifference(UnreadBadge(title: "Home / X"), .none)
		expectNoDifference(UnreadBadge(title: "Swift (programming language) - Wikipedia"), .none)
		expectNoDifference(UnreadBadge(title: "The Beatles (1968) | Album"), .none)
		expectNoDifference(UnreadBadge(title: "(Draft) Notes"), .none)
		expectNoDifference(UnreadBadge(title: "•"), .none)
		expectNoDifference(UnreadBadge(title: ""), .none)
	}

	@Test
	internal func theBadgingAPIReportsADotACountOrNothing() {
		expectNoDifference(UnreadBadge(appBadge: nil), .dot)
		expectNoDifference(UnreadBadge(appBadge: 4), .count(4))
		expectNoDifference(UnreadBadge(appBadge: 0), .none)
	}

	@Test
	internal func aSitesHostDropsWWW() {
		expectNoDifference(Tab.unreadBadgeHost(of: URL(string: "https://www.Example.com/inbox")!), "example.com")
		expectNoDifference(Tab.unreadBadgeHost(of: URL(string: "https://mail.example.com")!), "mail.example.com")
		#expect(Tab.unreadBadgeHost(of: URL(string: "about:blank")!) == nil)
	}
}
