import BrowserCore
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import MigrationAssistant
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-838: while launch onboarding is open, nothing opens the main window or another browser
/// window; onboarding comes forward instead, and links wait until the main window opens.
@Suite(.dependencies)
@MainActor
internal struct MainWindowHoldTests {
	private nonisolated static let profile = Profile.ID(rawValue: UUID(0))
	private nonisolated static let space = Space.ID(rawValue: UUID(1))

	@Test
	internal func newTabDuringOnboardingBringsOnboardingForward() async {
		let store = makeStore()
		await store.send(.presentOnboardingIfNeeded)
		#expect(store.state.mainWindowWaitsForOnboarding)

		// The menu items are disabled; Close Tab still closes onboarding.
		for target in [AppFeature.CommandTarget.application, .onboarding] {
			let context = store.state.commandContext(for: target)
			for command in BrowserCommand.opensBrowserWindow {
				#expect(context.map(command.isEnabled(in:)) == false, "\(command) in \(target)")
			}
			#expect(context.map(BrowserCommand.settings.isEnabled(in:)) == true)
		}
		#expect(store.state.commandContext(for: .onboarding).map(BrowserCommand.closeTab.isEnabled(in:)) == true)

		let focus = store.state.onboardingFocusRequest

		// ⌘T reached from the keyboard or the command bar anyway.
		await store.send(.ui(.command(.newTab, .onboarding)))
		await store.send(.ui(.openWindow))
		await store.send(.ui(.newWindow))
		await store.send(.ui(.newPrivateWindow))
		await store.send(.ui(.openMediaLibrary(nil)))

		#expect(!store.state.windowIsOpen)
		#expect(store.state.windows.isEmpty)
		#expect(store.state.onboardingFocusRequest > focus)
		expectNoDifference(store.state.workspace.tabs.count, 1)

		await store.send(.ui(.closeOnboarding))
		#expect(store.state.windowIsOpen)
		#expect(!store.state.mainWindowWaitsForOnboarding)
		#expect(store.state.commandContext(for: .application).map(BrowserCommand.newTab.isEnabled(in:)) == true)
	}

	@Test
	internal func aLinkWaitsForOnboardingThenOpens() async {
		let opened = LockIsolated<[URL]>([])
		let store = makeStore(dependencies: { dependencies in
			dependencies.browserEngine.prepareProfile = { _ in }
			dependencies.browserEngine.open = { tab in
				opened.withValue { $0.append(tab.restoration.url) }
			}
		})
		let url = URL(string: "https://example.org/held")!

		await store.send(.event(.routingReady))
		await store.send(.presentOnboardingIfNeeded)
		let focus = store.state.onboardingFocusRequest
		await store.send(.ui(.routeURLs([url]))).finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.routingInbox.requests.map(\.status), [.queued])
		expectNoDifference(opened.value, [])
		#expect(store.state.onboardingFocusRequest > focus)
		#expect(!store.state.windowIsOpen)

		await store.send(.ui(.closeOnboarding)).finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(opened.value, [url])
		#expect(store.state.routingInbox.requests.isEmpty)
	}

	@Test
	internal func littleArxPromotionWaitsForOnboarding() async {
		let littleID = UUID(40)
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(41)),
			profileID: Self.profile,
			restoration: .init(title: "Little", url: URL(string: "https://example.org")!)
		)
		let store = makeStore(configure: { state in
			state.littleWindows.append(.init(id: littleID, spaceID: Self.space, tab: tab))
		})
		await store.send(.presentOnboardingIfNeeded)

		await store.send(.littleWindows(.element(id: littleID, action: .delegate(.promote(Self.space)))))
		await store.receive(\.event.littlePromotionFailed)

		#expect(store.state.littleWindows[id: littleID] != nil)
		#expect(!store.state.windowIsOpen)
		#expect(!store.state.workspace.tabs.ids.contains(tab.id))
	}

	@Test
	internal func aFailedSaveWhileQuittingOpensTheMainWindow() async {
		let store = makeStore(configure: { state in
			state.quitAfterSaving = true
		})
		await store.send(.presentOnboardingIfNeeded)

		// Its error and Retry, Keep Open and Discard controls are in the main window.
		await store.send(.event(.saveFailed("The disk is full.")))

		#expect(store.state.windowIsOpen)
		#expect(!store.state.mainWindowWaitsForOnboarding)
		#expect(store.state.persistenceError != nil)
	}

	@Test
	internal func focusingATabWhileHeldPreparesTheMainWindow() {
		let other = Space.ID(rawValue: UUID(50))
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(51)),
			profileID: Self.profile,
			restoration: .init(title: "Agent", url: URL(string: "https://example.org/agent")!)
		)
		var organization = BrowserOrganization(
			profiles: [.init(id: Self.profile, name: "Default")],
			spaces: [
				.init(id: Self.space, profileID: Self.profile, name: "Default"),
				.init(id: other, profileID: Self.profile, name: "Work", unpinnedTabs: [tab.id], selectedTabID: tab.id),
			],
			tabs: [tab]
		)
		organization.legacyProfileID = Self.profile
		var state = AppFeature.State.launching(
			main: .init(organization: organization, spaceID: Self.space),
			preferences: .init()
		)
		state.windowIsOpen = false
		state.mainWindowWaitsForOnboarding = true
		state.onboarding = .init(destination: .init(profileID: Self.profile, spaceID: Self.space))

		// An agent opening the tab with focus, as MCP does.
		_ = OrdinaryTabPresentation().focus(tab, state: &state)

		#expect(!state.windowIsOpen)
		#expect(state.onboardingFocusRequest == 1)
		// The held window already presents the tab, so it shows once onboarding ends.
		expectNoDifference(state.main.sidebar.spaceID, other)
		expectNoDifference(state.main.sidebar.selectedTab?.id, tab.id)
		expectNoDifference(state.main.viewer.requestedSpaceID, other)
	}

	// MARK: - Fixture

	private func makeStore(
		configure: (inout AppFeature.State) -> Void = { _ in },
		dependencies: @escaping (inout DependencyValues) -> Void = { _ in }
	) -> TestStoreOf<AppFeature> {
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(2)),
			profileID: Self.profile,
			restoration: .init(title: "Example", url: URL(string: "https://capturecontext.dev")!)
		)
		let organization = BrowserOrganization(
			profiles: [.init(id: Self.profile, name: "Default")],
			spaces: [.init(id: Self.space, profileID: Self.profile, name: "Default", unpinnedTabs: [tab.id], selectedTabID: tab.id)],
			tabs: [tab]
		)
		var state = AppFeature.State.launching(
			main: .init(organization: organization, spaceID: Self.space),
			preferences: .init()
		)
		configure(&state)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = ImmediateClock()
			$0.uuid = .incrementing
			dependencies(&$0)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}
