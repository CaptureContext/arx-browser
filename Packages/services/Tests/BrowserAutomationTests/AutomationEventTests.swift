import BrowserCore
import CustomDump
import Foundation
import Testing
@testable import BrowserMCPServer

/// `arx://events` (DEV-924).
internal struct AutomationEventTests {
	private let tab: UUID = .init()
	private let time: Date = .init(timeIntervalSince1970: 100)

	@Test
	internal func navigationLoadsErrorsAndPromptsBecomeEvents() {
		let start = AutomationChangeDigest(
			tabs: [tab: "1"],
			signals: [tab: .init(address: "a", state: .ready)]
		)
		let loading = AutomationChangeDigest(
			tabs: [tab: "2"],
			signals: [tab: .init(address: "b", state: .loading)]
		)
		let failed = AutomationChangeDigest(
			tabs: [tab: "3"],
			signals: [tab: .init(address: "b", state: .failed, errorCode: -105)]
		)
		let asking = AutomationChangeDigest(
			tabs: [tab: "3"],
			downloads: "d",
			signals: [tab: .init(address: "b", state: .failed, errorCode: -105, dialog: .permission)]
		)

		let first = AutomationEvent.changes(from: start, to: loading, firstSequence: 1, time: time)
		expectNoDifference(first.map(\.kind), [.navigated, .loadStarted])
		expectNoDifference(first.map(\.sequence), [1, 2])
		expectNoDifference(first.map(\.revision), ["2", "2"])

		let second = AutomationEvent.changes(from: loading, to: failed, firstSequence: 3, time: time)
		expectNoDifference(second.map(\.kind), [.pageError])
		expectNoDifference(second.first?.errorCode, -105)

		let third = AutomationEvent.changes(from: failed, to: asking, firstSequence: 4, time: time)
		expectNoDifference(third.map(\.kind), [.permissionPrompt, .downloadsChanged])
		expectNoDifference(AutomationEvent.changes(from: asking, to: asking, firstSequence: 6, time: time), [])
	}

	@Test
	internal func aChangeBetweenTwoLooksIsStillAnEvent() {
		let before = AutomationChangeDigest(tabs: [tab: "1"], signals: [tab: .init(address: "a", state: .ready)])
		let reloaded = AutomationChangeDigest(tabs: [tab: "2"], signals: [tab: .init(address: "a", state: .ready)])
		expectNoDifference(
			AutomationEvent.changes(from: before, to: reloaded, firstSequence: 1, time: time).map(\.kind),
			[.tabChanged]
		)
	}

	@Test
	internal func grantedTabsComingAndGoingAreEvents() {
		let other = UUID()
		let before = AutomationChangeDigest(tabs: [tab: "1"])
		let after = AutomationChangeDigest(tabs: [other: "1"])
		let kinds = AutomationEvent.changes(from: before, to: after, firstSequence: 1, time: time)
			.map { [$0.kind.rawValue, $0.tabID?.uuidString ?? ""] }
		expectNoDifference(Set(kinds), [["tabClosed", tab.uuidString], ["tabOpened", other.uuidString]])
	}

	@Test
	internal func eventsAddressesAndNotices() {
		expectNoDifference(AutomationResources.Address(AutomationResources.eventsURI), .events(after: 0))
		expectNoDifference(AutomationResources.Address("arx://events?after=12"), .events(after: 12))
		#expect(AutomationResources.Address("arx://events?after=x") == nil)

		let previous = AutomationChangeDigest(tabs: [tab: "1"], signals: [tab: .init(address: "a")])
		let current = AutomationChangeDigest(tabs: [tab: "2"], signals: [tab: .init(address: "b")])
		expectNoDifference(
			AutomationResources.notices(from: previous, to: current, subscriptions: [AutomationResources.eventsURI]),
			[.updated(AutomationResources.eventsURI)]
		)
		expectNoDifference(AutomationResources.notices(from: previous, to: current, subscriptions: []), [])
	}

	@Test
	internal func readsShowOnlyWhatTheGrantStillCovers() {
		let other = UUID()
		let events: [AutomationEvent] = [
			.init(sequence: 1, kind: .navigated, tabID: tab, time: time),
			.init(sequence: 2, kind: .navigated, tabID: other, time: time),
			.init(sequence: 3, kind: .tabClosed, tabID: other, time: time),
			.init(sequence: 4, kind: .downloadsChanged, time: time),
		]
		let digest = AutomationChangeDigest(tabs: [tab: "1"])
		expectNoDifference(AutomationResources.visibleEvents(events, after: 0, digest: digest).map(\.sequence), [1, 3])
		expectNoDifference(AutomationResources.visibleEvents(events, after: 1, digest: digest).map(\.sequence), [3])
		let downloads = AutomationChangeDigest(tabs: [tab: "1"], downloads: "d")
		expectNoDifference(AutomationResources.visibleEvents(events, after: 3, digest: downloads).map(\.sequence), [4])
	}

	@Test
	internal func olderDigestsWithoutSignalsStillDecode() throws {
		// UUID-keyed dictionaries encode as arrays of alternating keys and values.
		let data = Data(#"{"tabs":[]}"#.utf8)
		expectNoDifference(try JSONDecoder().decode(AutomationChangeDigest.self, from: data), .init())
	}
}
