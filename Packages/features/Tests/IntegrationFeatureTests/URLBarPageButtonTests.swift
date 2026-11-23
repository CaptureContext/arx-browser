import BrowserCore
import Clocks
import CustomDump
import Foundation
import PageReaderClient
import Testing
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

/// DEV-1254: the sidebar URL bar's one page button, chosen per page and changed only once the
/// page has settled.
@Suite(.dependencies)
@MainActor
internal struct URLBarPageButtonTests {
	private static let story: URL = URL(string: "https://news.example/2026/11/story")!
	private static let feed: URL = URL(string: "https://news.example/2026/11")!

	// MARK: - Rule

	/// A page with an article offers reading mode, lit while it's read.
	@Test
	internal func aReadablePageOffersReadingMode() async throws {
		expectNoDifference(
			URLBarPageButton.next(after: nil, .init(isReadable: true)),
			.readingMode(isReading: false)
		)
		expectNoDifference(
			URLBarPageButton.next(after: .readingMode(isReading: false), .init(isReading: true, isReadable: true)),
			.readingMode(isReading: true)
		)
	}

	/// A pinned extension takes the slot from reading mode's offer, but not from reading mode
	/// that's open: that one is the way back.
	@Test
	internal func aPinnedExtensionTakesTheSlotUnlessThePageIsRead() async throws {
		expectNoDifference(
			URLBarPageButton.next(after: nil, .init(isReadable: true, pinnedExtensionID: "pin")),
			.pinnedExtension("pin")
		)
		expectNoDifference(
			URLBarPageButton.next(after: nil, .init(isReadable: true, isSettled: false, pinnedExtensionID: "pin")),
			.pinnedExtension("pin")
		)
		expectNoDifference(
			URLBarPageButton.next(after: .pinnedExtension("pin"), .init(isReading: true, pinnedExtensionID: "pin")),
			.readingMode(isReading: true)
		)
	}

	/// While the next page loads, a slot that had a button keeps its room, and an empty one
	/// stays empty: the slot changes once, when the page settles.
	@Test
	internal func aLoadingPageHoldsTheSlotUntilItSettles() async throws {
		let loading = URLBarPageButton.Signals(isSettled: false)
		expectNoDifference(URLBarPageButton.next(after: .readingMode(isReading: false), loading), .reserved)
		expectNoDifference(URLBarPageButton.next(after: .reserved, loading), .reserved)
		expectNoDifference(URLBarPageButton.next(after: nil, loading), nil)
	}

	/// A settled page with nothing to offer leaves no slot.
	@Test
	internal func aSettledPageWithNothingToOfferLeavesNoSlot() async throws {
		expectNoDifference(URLBarPageButton.next(after: .reserved, .init()), nil)
		expectNoDifference(URLBarPageButton.next(after: .readingMode(isReading: false), .init()), nil)
		expectNoDifference(URLBarPageButton.next(after: nil, .init()), nil)
	}

	// MARK: - Feature

	/// From an article to a page without one: reading mode's room is held while the page loads
	/// and is checked, and goes once the check answers. Nothing moves at the commit.
	@Test
	internal func anotherPageKeepsTheRoomUntilItsCheckAnswers() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let clock = TestClock<Duration>()
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = .init(url: Self.story, title: "Story", isLoading: false)
		initial.isReadable = true
		initial.readabilityChecked = Self.story.absoluteString
		initial.readabilityAnswered = Self.story.absoluteString
		initial.urlBarPageButton = .readingMode(isReading: false)
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		} withDependencies: {
			$0.continuousClock = clock
			$0.pageReader.isEnabled = { true }
			$0.pageReader.isReadable = { _ in false }
		}
		store.exhaustivity = .off

		await store.send(.event(.navigation(tab.id, 1, .init(url: Self.feed, isLoading: true)))) {
			$0.urlBarPageButton = .reserved
		}
		await store.send(.event(.navigation(tab.id, 1, .init(url: Self.feed, title: "Feed", isLoading: true))))
		#expect(store.state.urlBarPageButton == .reserved)

		// Loaded, and waiting for the check.
		await store.send(.event(.navigation(tab.id, 1, .init(url: Self.feed, title: "Feed", isLoading: false))))
		#expect(store.state.urlBarPageButton == .reserved)

		await clock.advance(by: ViewerItemFeature.readabilityDelay)
		await store.receive(\.event.readabilityChecked) {
			$0.urlBarPageButton = nil
		}
	}

	/// From an article to another: the button's room stays through the load, and the button
	/// comes back once the new page's check answers.
	@Test
	internal func anotherArticleBringsReadingModeBackInTheSameRoom() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let clock = TestClock<Duration>()
		let next = URL(string: "https://news.example/2026/11/next")!
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = .init(url: Self.story, title: "Story", isLoading: false)
		initial.isReadable = true
		initial.readabilityChecked = Self.story.absoluteString
		initial.readabilityAnswered = Self.story.absoluteString
		initial.urlBarPageButton = .readingMode(isReading: false)
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		} withDependencies: {
			$0.continuousClock = clock
			$0.pageReader.isEnabled = { true }
			$0.pageReader.isReadable = { _ in true }
		}
		store.exhaustivity = .off

		await store.send(.event(.navigation(tab.id, 1, .init(url: next, isLoading: true)))) {
			$0.urlBarPageButton = .reserved
		}
		await store.send(.event(.navigation(tab.id, 1, .init(url: next, title: "Next", isLoading: false))))
		#expect(store.state.urlBarPageButton == .reserved)

		await clock.advance(by: ViewerItemFeature.readabilityDelay)
		await store.receive(\.event.readabilityChecked) {
			$0.urlBarPageButton = .readingMode(isReading: false)
		}
	}

	/// A page that gets no article check, such as one that failed, settles as soon as it loads.
	@Test
	internal func aPageWithoutACheckSettlesWhenItLoads() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = .init(url: Self.story, title: "Story", isLoading: false)
		initial.isReadable = true
		initial.readabilityChecked = Self.story.absoluteString
		initial.readabilityAnswered = Self.story.absoluteString
		initial.urlBarPageButton = .readingMode(isReading: false)
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		} withDependencies: {
			$0.pageReader.isEnabled = { true }
		}
		store.exhaustivity = .off

		let local = URL(fileURLWithPath: "/tmp/notes.txt")
		await store.send(.event(.navigation(tab.id, 1, .init(url: local, isLoading: true)))) {
			$0.urlBarPageButton = .reserved
		}
		await store.send(.event(.navigation(tab.id, 1, .init(url: local, title: "notes.txt", isLoading: false)))) {
			$0.urlBarPageButton = nil
		}
	}
}
