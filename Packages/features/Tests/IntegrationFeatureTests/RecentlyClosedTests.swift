import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-908: Archive ▸ Recently Closed and Reopen Closed Window.
@Suite(.dependencies)
@MainActor
internal struct RecentlyClosedTests {
	@Test
	internal func aClosedWindowOpensAgainInItsSpaceWithItsTab() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[1].id)
		let tab = state.workspace.tabs[2]
		state.windows[id: windowID]?.viewer.item.tab = tab
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.closeAdditionalWindow(windowID)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.recentlyClosedWindows, [.init(
			id: windowID,
			spaceID: state.workspace.spaces[1].id,
			tabID: tab.id,
			isMain: false
		)])
		#expect(store.state.windows[id: windowID] == nil)
		let context = try #require(store.state.commandContext(for: .window(state.main.id)))
		#expect(BrowserCommand.reopenClosedWindow.isEnabled(in: context))

		await store.send(.ui(.command(.reopenClosedWindow, .window(state.main.id))))
		await store.skipReceivedActions()

		let reopened = try #require(store.state.windows.last)
		expectNoDifference(reopened.sidebar.spaceID, state.workspace.spaces[1].id)
		#expect(store.state.recentlyClosedWindows.isEmpty)
		expectNoDifference(store.state.focusedWindowID, reopened.id)
	}

	@Test
	internal func privateWindowsAreNotKept() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.windows.append(.init(
			organization: state.workspace,
			spaceID: state.workspace.spaces[0].id,
			isPrivate: true,
			id: windowID
		))
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.closeAdditionalWindow(windowID)))
		await store.skipReceivedActions()
		#expect(store.state.recentlyClosedWindows.isEmpty)
	}

	@Test
	internal func theMainWindowReopensAsItself() async throws {
		let state = fixture()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.closeWindow))
		await store.skipReceivedActions()
		#expect(!store.state.windowIsOpen)
		expectNoDifference(store.state.recentlyClosedWindows.map(\.isMain), [true])

		await store.send(.ui(.reopenClosedWindow(nil)))
		await store.skipReceivedActions()
		#expect(store.state.windowIsOpen)
		#expect(store.state.windows.isEmpty)
		#expect(store.state.recentlyClosedWindows.isEmpty)
	}

	@Test
	internal func onlyTheNewestTenWindowsAreKept() async throws {
		var state = fixture()
		for index in 0..<12 {
			let id = UUID(100 + index)
			state.appendBrowserWindow(id, spaceID: state.workspace.spaces[0].id)
		}
		let ids = state.windows.ids
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		for id in ids { await store.send(.ui(.closeAdditionalWindow(id))) }
		await store.skipReceivedActions()

		expectNoDifference(store.state.recentlyClosedWindows.map(\.id), Array(ids.suffix(10)))
	}

	@Test
	internal func aWindowWhoseSpaceIsGoneCannotReopen() async throws {
		var state = fixture()
		state.recentlyClosedWindows = [.init(
			id: UUID(50),
			spaceID: .init(rawValue: UUID(404)),
			tabID: nil,
			isMain: false
		)]
		#expect(state.reopenableClosedWindow(nil) == nil)
		let context = try #require(state.commandContext(for: .window(state.main.id)))
		#expect(!BrowserCommand.reopenClosedWindow.isEnabled(in: context))
	}

	@Test
	internal func recentlyClosedTabsAreTheFrontProfilesNewestArchivedTabs() async throws {
		var state = fixture()
		let profileID = state.workspace.profiles[0].id
		state.workspace.archive = (0..<20).map { index in
			ArchivedTab(
				id: .init(rawValue: UUID(200 + index)),
				groupID: UUID(300 + index),
				closedAt: Date(timeIntervalSince1970: TimeInterval(index)),
				originalSpaceID: state.workspace.spaces[0].id,
				originalSpaceName: "Work",
				originalIndex: 0,
				tab: .init(
					id: .init(rawValue: UUID(400 + index)),
					profileID: index == 19 ? .init(rawValue: UUID(999)) : profileID,
					restoration: .init(title: "Page \(index)", url: URL(string: "https://example.com/\(index)")!)
				)
			)
		}

		let tabs = state.recentlyClosedTabs()
		#expect(tabs.count == 15)
		expectNoDifference(tabs.first?.tab.restoration.title, "Page 18")
		#expect(tabs.allSatisfy { $0.tab.profileID == profileID })
	}

	@Test
	internal func choosingAClosedTabRestoresItInTheFrontWindow() async throws {
		let state = fixture()
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		let id = ArchivedTab.ID(rawValue: UUID(200))

		await store.send(.ui(.reopenArchivedTab(id)))
		await store.receive(\.main.ui.reopenArchivedTab)
	}

	private func fixture() -> AppFeature.State {
		var organization = IntegrationFeatureTests().fixture()
		let third = BrowserCore.Tab(
			id: .init(rawValue: UUID(5)),
			profileID: organization.profiles[0].id,
			restoration: .init(title: "Notes", url: URL(string: "https://notes.example")!)
		)
		organization.tabs.append(third)
		organization.spaces[1].unpinnedTabs = [third.id]
		var state = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		state.main.viewer.item.tab = organization.tabs[0]
		state.focusedWindowID = state.main.id
		return state
	}
}
