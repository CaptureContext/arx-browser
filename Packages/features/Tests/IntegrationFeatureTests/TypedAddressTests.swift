@testable import AppFeature
import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-1015: which visit takes an address typed in the command bar.
internal struct TypedAddressTests {
	private let profile: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
	private let tab: BrowserCore.Tab.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!)
	private let other: BrowserCore.Tab.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)
	private let now: Date = .init(timeIntervalSince1970: 100)

	private func waiting(_ address: String) -> ProfileHistoryState {
		let url = URL(string: address)!
		return .init(typedAddresses: [profile: [.init(url: url, site: url.host()!, tabID: tab, openedAt: now)]])
	}

	@Test
	internal func aNewViewOfTheSiteInItsTabIsTyped() async throws {
		var state = waiting("https://example.org")

		let otherTab = state.takeTypedAddress(for: URL(string: "https://example.org/a")!, isNew: true, tabID: other, profileID: profile, at: now)
		#expect(!otherTab)
		let redirected = state.takeTypedAddress(for: URL(string: "https://www.example.org/start")!, isNew: true, tabID: tab, profileID: profile, at: now)
		#expect(redirected)
		#expect(state.typedAddresses.isEmpty)
	}

	@Test
	internal func aReloadOfTheTypedPageTakesItWithoutAVisit() async throws {
		var state = waiting("https://example.org")

		// A title update from the page before keeps it waiting.
		let titleUpdate = state.takeTypedAddress(for: URL(string: "https://example.org/previous")!, isNew: false, tabID: tab, profileID: profile, at: now)
		#expect(!titleUpdate)
		expectNoDifference(state.typedAddresses[profile]?.count, 1)

		let reload = state.takeTypedAddress(for: URL(string: "https://EXAMPLE.org/")!, isNew: false, tabID: tab, profileID: profile, at: now)
		#expect(!reload)
		#expect(state.typedAddresses.isEmpty)
		// So a link on the site afterwards isn't typed.
		let link = state.takeTypedAddress(for: URL(string: "https://example.org/link")!, isNew: true, tabID: tab, profileID: profile, at: now)
		#expect(!link)
	}

	@Test
	internal func itWaitsThirtySeconds() async throws {
		var state = waiting("https://example.org")
		let later = now + ProfileHistoryState.typedAddressLifetime + 1

		let expired = state.takeTypedAddress(for: URL(string: "https://example.org/")!, isNew: true, tabID: tab, profileID: profile, at: later)
		#expect(!expired)
		#expect(state.typedAddresses.isEmpty)
	}
}
