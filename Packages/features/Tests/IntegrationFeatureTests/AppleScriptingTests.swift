import BrowserCore
import CustomDump
import Foundation
import MainFeature
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-909: what Arx's AppleScript dictionary shows and does.
@Suite(.dependencies)
@MainActor
internal struct AppleScriptingTests {
	@Test
	internal func scriptsSeeOrdinaryTabsSpacesAndWindowsFrontFirst() async throws {
		var state = fixture()
		state.windows.append(.init(organization: state.workspace, spaceID: state.workspace.spaces[1].id, isPrivate: true, id: UUID(90)))
		state.appendBrowserWindow(UUID(91), spaceID: state.workspace.spaces[1].id)
		state.focusedWindowID = UUID(91)

		let snapshot = AppleScriptBridge.snapshot(of: state)
		expectNoDifference(snapshot.windows.map(\.id), [UUID(91).uuidString, state.main.id.uuidString])
		expectNoDifference(snapshot.windows.map(\.spaceName), ["Personal", "Work"])
		expectNoDifference(snapshot.spaces.map(\.name), ["Work", "Personal"])
		expectNoDifference(snapshot.profiles.map(\.name), ["Default"])
		expectNoDifference(snapshot.tabs.count, 2)
		let first = try #require(snapshot.tabs.first)
		#expect(first.isActive)
		#expect(!first.isPinned)
		expectNoDifference(first.spaceName, "Work")
		expectNoDifference(first.address, "https://capturecontext.dev")
		#expect(snapshot.tabs.last?.isActive == false)

		// A loaded tab's live address wins over the one it saved.
		let live = AppleScriptBridge.snapshot(of: state) { id in
			id == state.workspace.tabs[1].id ? URL(string: "https://capturecontext.dev/later") : nil
		}
		expectNoDifference(live.tabs.last?.address, "https://capturecontext.dev/later")
	}

	@Test
	internal func closeArchivesFromTheTabsProfileWindow() async throws {
		let state = fixture()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_000)
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.scriptTab(state.workspace.tabs[1].id, .close)))
		await store.receive(\.main.ui.archiveSelectedTabs)
	}

	@Test
	internal func closeWorksWithoutAWindowOnTheTabsProfile() async throws {
		var state = fixture()
		let other = Profile.ID(rawValue: UUID(40))
		state.workspace.profiles.append(.init(id: other, name: "Work"))
		let space = Space(id: .init(rawValue: UUID(41)), profileID: other, name: "Client")
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(42)),
			profileID: other,
			restoration: .init(title: "Client", url: URL(string: "https://client.example")!)
		)
		state.workspace.spaces.append(space)
		state.workspace.tabs.append(tab)
		state.workspace.spaces[id: space.id]?.unpinnedTabs = [tab.id]
		state.main = .init(organization: state.workspace, spaceID: state.workspace.spaces[0].id)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_000)
			$0.browserEngine.snapshot = { _ in nil }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.scriptTab(tab.id, .close)))
		await store.receive(\.main.sidebar.ui.spaceSelected)
		await store.receive(\.main.ui.archiveSelectedTabs)
	}

	@Test
	internal func showUsesTheTabsOwnPresentation() async throws {
		let state = fixture()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.scriptTab(state.workspace.tabs[1].id, .show)))
		await store.receive(\.event.pageActivationRequested)
	}

	@Test
	internal func reloadAsksTheEngine() async throws {
		let state = fixture()
		let reloaded = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.command = { id, command in
				if command == .reload { reloaded.withValue { $0.append(id) } }
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.scriptTab(state.workspace.tabs[0].id, .reload)))
		await store.finish()
		expectNoDifference(reloaded.value, [state.workspace.tabs[0].id])
	}

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		return state
	}
}

/// DEV-909: `execute` runs JavaScript only behind developer mode's switch.
@Suite(.dependencies)
@MainActor
internal struct AppleScriptJavaScriptTests {
	@Test
	internal func javaScriptIsOffUntilBothSwitchesAreOn() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let tab = organization.tabs[0].id
		state.settings.$general.withLock {
			$0.developerModeEnabled = false
			$0.appleScriptJavaScriptEnabled = false
		}
		#expect(AppleScriptBridge.javaScriptRefusal(for: tab, in: state)?.contains("off") == true)

		state.settings.$general.withLock { $0.appleScriptJavaScriptEnabled = true }
		#expect(AppleScriptBridge.javaScriptRefusal(for: tab, in: state) != nil)

		state.settings.$general.withLock { $0.developerModeEnabled = true }
		#expect(AppleScriptBridge.javaScriptRefusal(for: tab, in: state) == nil)

		// A tab Arx doesn't list (a private window's, or a closed one) never runs it.
		#expect(AppleScriptBridge.javaScriptRefusal(for: .init(rawValue: UUID(404)), in: state) != nil)
		state.settings.$general.withLock {
			$0.developerModeEnabled = false
			$0.appleScriptJavaScriptEnabled = false
		}
	}

	@Test
	internal func resultsStayWithinTheEnginesLimit() async throws {
		#expect(AppleScriptBridge.resultLimit == 262_144)
	}

	@Test
	internal func theSwitchNeedsDeveloperMode() async throws {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		store.state.$general.withLock {
			$0.developerModeEnabled = false
			$0.appleScriptJavaScriptEnabled = false
		}

		await store.send(.ui(.appleScriptJavaScriptEnabled(true)))
		#expect(!store.state.general.appleScriptJavaScriptEnabled)

		store.state.$general.withLock { $0.developerModeEnabled = true }
		await store.send(.ui(.appleScriptJavaScriptEnabled(true)))
		#expect(store.state.general.appleScriptJavaScriptEnabled)
		store.state.$general.withLock {
			$0.developerModeEnabled = false
			$0.appleScriptJavaScriptEnabled = false
		}
	}
}
