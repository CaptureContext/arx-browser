import AppUI
import BrowserCore
import Foundation
import PeekFeature
import Testing
import _TestSupport

/// DEV-1224: while a Peek is open, the tab it came from shows the peeked site in the sidebar.
internal struct PeekSourceBadgeTests {
	private let sourceTab: BrowserCore.Tab.ID = .init(rawValue: UUID(1224))
	private let profile: Profile.ID = .init(rawValue: UUID(1))

	private func peek(
		sourceTab: BrowserCore.Tab.ID?,
		phase: PeekFeature.Phase = .idle
	) -> PeekFeature.State {
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(1225)),
			profileID: profile,
			restoration: .init(title: "Peeked", url: URL(string: "https://www.youtube.com/watch?v=1")!)
		)
		return .init(
			id: UUID(1226),
			source: .init(
				windowID: UUID(1227),
				paneID: UUID(1228),
				tabID: sourceTab,
				spaceID: .init(rawValue: UUID(1229)),
				profileID: profile,
				identity: "Default"
			),
			tab: tab,
			isTemporary: true,
			phase: phase
		)
	}

	@Test
	internal func theSourceTabShowsTheRestoredSiteUntilThePageReports() {
		let badge = peek(sourceTab: sourceTab).peekedTab
		#expect(badge == .init(
			tabID: sourceTab.rawValue,
			siteIcon: .init(profileID: profile.rawValue, pageURL: URL(string: "https://www.youtube.com/watch?v=1")!),
			title: "Peeked"
		))
	}

	@Test
	internal func itFollowsThePeekedPagesNavigation() {
		var state = peek(sourceTab: sourceTab)
		state.viewer.navigation.url = URL(string: "https://mail.google.com/mail/u/0")!
		state.viewer.navigation.title = "Inbox"

		let badge = state.peekedTab
		#expect(badge?.siteIcon?.pageURL.host() == "mail.google.com")
		#expect(badge?.title == "Inbox")
	}

	@Test(arguments: [PeekFeature.Phase.promoting, .releasing])
	internal func aPeekLeavingForATabOrLittleArxShowsNoBadge(_ phase: PeekFeature.Phase) {
		#expect(peek(sourceTab: sourceTab, phase: phase).peekedTab == nil)
	}

	@Test
	internal func aPeekNotOpenedFromATabShowsNoBadge() {
		#expect(peek(sourceTab: nil).peekedTab == nil)
	}
}
