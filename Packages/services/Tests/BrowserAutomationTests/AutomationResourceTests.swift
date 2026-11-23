import BrowserCore
import CustomDump
import Foundation
import Testing
@testable import BrowserMCPServer

internal struct AutomationResourceTests {
	@Test
	internal func addressesRoundTripAndRejectForeignShapes() {
		let id = UUID()
		for address in [AutomationResources.Address.tabs, .tab(id), .snapshot(id)] {
			expectNoDifference(AutomationResources.Address(address.uri), address)
		}
		for uri in ["arx://tab", "arx://tabs/", "arx://tabs/not-a-uuid", "arx://tabs/\(id)/other", "file:///tmp"] {
			#expect(AutomationResources.Address(uri) == nil, "\(uri)")
		}
	}

	@Test
	internal func downloadNoticesNeedTheirSubscription() {
		let previous = AutomationChangeDigest(tabs: [:], downloads: "a")
		let current = AutomationChangeDigest(tabs: [:], downloads: "b")
		expectNoDifference(AutomationResources.notices(from: previous, to: current, subscriptions: []), [])
		expectNoDifference(
			AutomationResources.notices(from: previous, to: current, subscriptions: [AutomationResources.downloadsURI]),
			[.updated(AutomationResources.downloadsURI)]
		)
		expectNoDifference(AutomationResources.Address(AutomationResources.downloadsURI), .downloads)
	}

	@Test
	internal func noticesFollowOnlySubscribedGrantedTabs() {
		let followed = UUID()
		let other = UUID()
		let previous = AutomationChangeDigest(tabs: [followed: "a", other: "b"])
		let subscriptions: Set<String> = [
			AutomationResources.Address.tab(followed).uri,
			AutomationResources.Address.snapshot(followed).uri,
		]

		expectNoDifference(
			AutomationResources.notices(from: previous, to: previous, subscriptions: subscriptions),
			[]
		)

		// Another tab changing tells nobody who only follows `followed`.
		expectNoDifference(
			AutomationResources.notices(
				from: previous,
				to: .init(tabs: [followed: "a", other: "c"]),
				subscriptions: subscriptions
			),
			[]
		)
		expectNoDifference(
			AutomationResources.notices(
				from: previous,
				to: .init(tabs: [followed: "navigated", other: "b"]),
				subscriptions: subscriptions
			),
			[
				.updated(AutomationResources.Address.tab(followed).uri),
				.updated(AutomationResources.Address.snapshot(followed).uri),
			]
		)

		// A tab leaving the grant changes the list as well.
		expectNoDifference(
			AutomationResources.notices(
				from: previous,
				to: .init(tabs: [other: "b"]),
				subscriptions: subscriptions.union([AutomationResources.tabsURI])
			),
			[
				.updated(AutomationResources.tabsURI),
				.updated(AutomationResources.Address.tab(followed).uri),
				.updated(AutomationResources.Address.snapshot(followed).uri),
				.listChanged,
			]
		)
	}
}
