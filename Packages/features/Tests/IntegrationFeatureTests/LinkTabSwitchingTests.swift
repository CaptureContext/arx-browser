import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-952: a tab a link opens stays behind the page by default, right after it in the sidebar;
/// Settings › General › Tabs brings it forward instead, and ⇧⌘-click does the opposite.
@Suite(.dependencies)
@MainActor
internal struct LinkTabSwitchingTests {
	private let document: WorkspaceDocument = .unsaved()
	private let child: BrowserCore.Tab.ID = .init(rawValue: UUID(90))

	// MARK: - The setting

	@Test
	internal func theSettingIsOffByDefaultAndSurvivesSaving() async throws {
		#expect(!BrowserPreferences().switchesToLinkTabs)
		#expect(!BrowserPreferences().general.switchesToLinkTabs)
		var preferences = BrowserPreferences()
		preferences.general.switchesToLinkTabs = true
		let data = try JSONEncoder().encode(preferences)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: data).switchesToLinkTabs)

		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		values.removeValue(forKey: "switchesToLinkTabs")
		let older = try JSONSerialization.data(withJSONObject: values)
		#expect(try !JSONDecoder().decode(BrowserPreferences.self, from: older).switchesToLinkTabs)
	}

	@Test
	internal func theToggleSavesTheSetting() async throws {
		let store = store(state())

		await store.send(.settings(.ui(.switchesToLinkTabs(true))))
		#expect(store.state.settings.general.switchesToLinkTabs)
		#expect(document.preferences.switchesToLinkTabs)

		await store.send(.settings(.ui(.switchesToLinkTabs(false))))
		#expect(!document.preferences.switchesToLinkTabs)
	}

	// MARK: - ⌘-click, middle-click and ⇧⌘-click

	/// Chromium makes a background tab of ⌘-click and middle-click, and a foreground one of
	/// the same with Shift or of a page's own new tab (`target=_blank`).
	@Test(arguments: [
		// disposition, Shift held, setting on, comes forward
		(BrowserNewContents.Disposition.backgroundTab, false, false, false),
		(.foregroundTab, true, false, true),
		(.foregroundTab, false, false, true),
		(.backgroundTab, false, true, true),
		(.foregroundTab, true, true, false),
		(.foregroundTab, false, true, true),
	])
	internal func aClickedLinksTabComesForwardAsTheSettingAndShiftSay(
		disposition: BrowserNewContents.Disposition,
		shiftHeld: Bool,
		switches: Bool,
		comesForward: Bool
	) async throws {
		let state = state()
		state.settings.$general.withLock { $0.switchesToLinkTabs = switches }
		let opener = state.workspace.tabs[0].id
		let other = state.workspace.tabs[1].id
		let store = store(state)

		await store.send(.event(.browserNewContents(offer(disposition, from: opener), shiftHeld: shiftHeld)))
		await store.skipReceivedActions()

		#expect(store.state.workspace.tabs.ids.contains(child))
		if comesForward {
			expectNoDifference(store.state.main.viewer.item.tab?.id, child)

			// Right below its opener, as a background tab (DEV-1243).
			expectNoDifference(store.state.workspace.spaces[0].unpinnedTabs, [opener, child, other])
		} else {
			expectNoDifference(store.state.main.viewer.item.tab?.id, opener)
			expectNoDifference(store.state.main.sidebar.selectedTab?.id, opener)
			expectNoDifference(store.state.workspace.spaces[0].unpinnedTabs, [opener, child, other])
		}
	}

	/// Each goes directly after its opener, so the newest is nearest it (DEV-1325).
	@Test
	internal func eachBackgroundLinkTabGoesDirectlyAfterItsOpener() async throws {
		let state = state()
		let opener = state.workspace.tabs[0].id
		let other = state.workspace.tabs[1].id
		let second = BrowserCore.Tab.ID(rawValue: UUID(91))
		let store = store(state, children: [child, second])

		await store.send(.event(.browserNewContents(offer(.backgroundTab, from: opener))))
		await store.send(.event(.browserNewContents(offer(.backgroundTab, from: opener, id: second))))
		await store.skipReceivedActions()

		expectNoDifference(store.state.workspace.spaces[0].unpinnedTabs, [opener, second, child, other])
		expectNoDifference(store.state.main.viewer.item.tab?.id, opener)
	}

	/// Nothing is shown in a headless run, so the setting doesn't apply: Chromium's choice stands.
	@Test
	internal func headlessRunsKeepChromiumsChoice() async throws {
		var state = state()
		state.settings.$general.withLock { $0.switchesToLinkTabs = true }
		state.automation.isUnattended = true
		let opener = state.workspace.tabs[0].id
		let store = store(state)

		await store.send(.event(.browserNewContents(offer(.backgroundTab, from: opener))))
		await store.skipReceivedActions()

		expectNoDifference(store.state.main.viewer.item.tab?.id, opener)
		#expect(store.state.workspace.tabs.ids.contains(child))
		#expect(state.linkTabDisposition(.foregroundTab, shiftHeld: true) == .foregroundTab)
	}

	@Test
	internal func popupsAndWindowsKeepTheirDisposition() {
		let state = state()
		state.settings.$general.withLock { $0.switchesToLinkTabs = true }
		for shiftHeld in [false, true] {
			#expect(state.linkTabDisposition(.window, shiftHeld: shiftHeld) == .window)
			#expect(state.linkTabDisposition(.popup, shiftHeld: shiftHeld) == .popup)
		}
	}

	// MARK: - Open in New Tab from the link menu

	@Test
	internal func openInNewTabStaysBehindThePageByDefault() throws {
		let state = state()
		let placement = try #require(placement(in: state))
		let url = URL(string: "https://x.com/linked")!

		let action = try #require(state.linkOpenAction(url, route: .newTab, placement: placement, origin: nil))

		let request = try #require(action[case: \.openLinkInBackgroundTab])
		expectNoDifference(request.0, url)
		expectNoDifference(request.opener, state.workspace.tabs[0].id)
		expectNoDifference(request.windowID, state.main.id)
	}

	@Test
	internal func openInNewTabComesForwardWhenTheSettingSaysSo() throws {
		let state = state()
		state.settings.$general.withLock { $0.switchesToLinkTabs = true }
		let placement = try #require(placement(in: state))
		let url = URL(string: "https://x.com/linked")!

		let action = try #require(state.linkOpenAction(url, route: .newTab, placement: placement, origin: nil))

		let opened = try #require(action[case: \.main.ui.openInNewTab])
		expectNoDifference(opened, url)
	}

	@Test
	internal func aBackgroundLinkTabGoesAfterItsOpenerAndLoadsWithoutBeingShown() async throws {
		let state = state()
		let opener = state.workspace.tabs[0].id
		let other = state.workspace.tabs[1].id
		let url = URL(string: "https://x.com/linked")!
		let opened = LockIsolated<[BrowserCore.Tab]>([])
		let store = store(state) {
			$0.uuid = .constant(UUID(80))
			$0.browserEngine.open = { tab in opened.withValue { $0.append(tab) } }
		}

		await store.send(.openLinkInBackgroundTab(url, opener: opener, windowID: state.main.id))
		await store.skipReceivedActions()
		await store.finish()

		let id = BrowserCore.Tab.ID(rawValue: UUID(80))
		expectNoDifference(store.state.workspace.spaces[0].unpinnedTabs, [opener, id, other])
		expectNoDifference(store.state.main.sidebar.organization.spaces[0].unpinnedTabs, [opener, id, other])
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, opener)
		expectNoDifference(store.state.main.viewer.item.tab?.id, opener)
		expectNoDifference(opened.value.map(\.id), [id])
		expectNoDifference(opened.value.first?.restoration.url, url)
		expectNoDifference(opened.value.first?.profileID, state.workspace.tabs[0].profileID)
	}

	@Test
	internal func aBackgroundLinkTabNeedsAnOrdinaryWindowAndAWebAddress() async throws {
		let state = state()
		let opener = state.workspace.tabs[0].id
		let store = store(state)
		let tabs = state.workspace.tabs

		await store.send(.openLinkInBackgroundTab(URL(string: "file:///etc/hosts")!, opener: opener, windowID: state.main.id))
		await store.send(.openLinkInBackgroundTab(URL(string: "https://x.com/")!, opener: opener, windowID: UUID(999)))
		await store.send(.openLinkInBackgroundTab(
			URL(string: "https://x.com/")!,
			opener: .init(rawValue: UUID(998)),
			windowID: state.main.id
		))

		expectNoDifference(store.state.workspace.tabs, tabs)
	}

	// MARK: - Fixture

	private func state() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		state.main.viewer.item = .init(tab: organization.tabs[0], generation: 4)
		return state
	}

	private func placement(in state: AppFeature.State) -> LinkContextPlacement? {
		state.nativeContentPlacement(
			tabID: state.workspace.tabs[0].id,
			profileID: state.workspace.tabs[0].profileID,
			isPrivate: false
		)
	}

	private func offer(
		_ disposition: BrowserNewContents.Disposition,
		from opener: BrowserCore.Tab.ID,
		id: BrowserCore.Tab.ID? = nil
	) -> BrowserNewContents {
		.init(
			sourceTabID: opener,
			sourceSessionRevision: 3,
			sourceDocumentRevision: 7,
			tab: .init(
				id: id ?? child,
				profileID: .init(rawValue: UUID(0)),
				restoration: .init(title: "Linked", url: URL(string: "https://child.example/")!)
			),
			disposition: disposition
		)
	}

	private func store(
		_ state: AppFeature.State,
		children: Set<BrowserCore.Tab.ID>? = nil,
		dependencies: (inout DependencyValues) -> Void = { _ in }
	) -> TestStoreOf<AppFeature> {
		let source = state.workspace.tabs[0].id
		let children = children ?? [child]
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { id in
				if id == source { return .init(navigation: .init(), revision: 3, documentRevision: 7) }
				return children.contains(id) ? .init(navigation: .init(), revision: 1) : nil
			}
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			dependencies(&$0)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}
