import AppFeature
import AppUI
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func sidebarLinkSelectionUsesClickedMembershipAndSelectedTabOrder() async throws {
		let first = UUID(3)
		let second = UUID(4)
		let selection: [SidebarItem.ID] = [.tab(second), .folder(UUID(10)), .tab(first), .tab(second)]
		let selected = SidebarItem(id: .tab(first), title: "First", moveSelection: selection)
		let unselected = SidebarItem(id: .tab(UUID(5)), title: "Other", moveSelection: selection)
		let folder = SidebarItem(id: .folder(UUID(10)), title: "Folder", moveSelection: selection)
		expectNoDifference(selected.linkTabIDs, [second, first])
		expectNoDifference(unselected.linkTabIDs, [UUID(5)])
		expectNoDifference(folder.linkTabIDs, [])
	}

	@Test
	internal func sidebarMultiCopyUsesLiveURLsAndReportsFailureWithoutChangingSelection() async throws {
		var organization = fixture()
		try organization.move(.tab(organization.tabs[0].id.rawValue), to: .savedRoot, in: organization.spaces[0].id)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let first = organization.tabs[0]
		let second = organization.tabs[1]
		state.main.sidebar.moveSelection = [.tab(second.id.rawValue), .tab(first.id.rawValue)]
		state.main.viewer.item = .init(
			tab: first,
			navigation: .init(
				url: URL(string: "https://first.example/current?utm_source=test#fragment")!,
				title: "First [page]"
			)
		)
		state.main.viewer.panes.append(.init(
			id: UUID(20),
			item: .init(
				tab: second,
				navigation: .init(
					url: URL(string: "https://second.example/a?keep=yes&utm_medium=test")!,
					title: "第二"
				)
			)
		))
		let ids = try #require(state.main.sidebar.tabItem(first.id)).linkTabIDs
		let items = state.sidebarLinkItems(in: state.main.id, tabIDs: ids)
		var copied: [String] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.linkSharing.copy = {
				copied.append($0)
				return false
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.copyLinks(.markdownOriginal, items: items, sourceWindowID: state.main.id)))
		await store.receive(\.event.linkActionFinished)
		expectNoDifference(
			copied,
			[
				"[第二](<https://second.example/a?keep=yes&utm_medium=test>)"
				+ "\n[First \\[page\\]](<https://first.example/current?utm_source=test#fragment>)",
			]
		)
		expectNoDifference(store.state.linkActionFeedback?.status, .copyFailed)
		expectNoDifference(store.state.linkActionFeedback?.windowID, state.main.id)
		expectNoDifference(store.state.main, state.main)
		expectNoDifference(store.state.workspace, organization)
		expectNoDifference(
			state.sidebarLinkItems(in: state.main.id, tabIDs: [first.id.rawValue], saved: true),
			[.init(title: first.savedDestination!.title, url: first.savedDestination!.url)]
		)
		expectNoDifference(
			LinkTransformer.copy(items, mode: .clean).text,
			"https://second.example/a?keep=yes\nhttps://first.example/current#fragment"
		)
	}

	@Test
	internal func sidebarLinkSelectionDeduplicatesIdentitiesWithoutDroppingEqualURLs() async throws {
		let organization = fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let ids = [organization.tabs[1].id.rawValue, organization.tabs[0].id.rawValue, organization.tabs[1].id.rawValue]
		let items = state.sidebarLinkItems(in: state.main.id, tabIDs: ids)
		expectNoDifference(items.count, 2)
		expectNoDifference(
			LinkTransformer.copy(items, mode: .original).text,
			"https://capturecontext.dev\nhttps://capturecontext.dev"
		)
	}

	@Test(arguments: ["missing", "otherSpace", "otherProfile", "unplaced", "reassignedSpace"])
	internal func staleSidebarLinkSelectionNeverCopiesPartialOrForeignItems(change: String) async throws {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let ids = organization.tabs.map(\.id.rawValue)
		let second = organization.tabs[1].id
		switch change {
		case "missing":
			state.workspace.tabs.removeAll { $0.id == second }
			state.workspace.spaces[0].unpinnedTabs.removeAll { $0 == second }

		case "otherSpace":
			try state.workspace.move(.tab(second.rawValue), to: .unpinnedRoot, in: organization.spaces[1].id)

		case "otherProfile":
			state.workspace.tabs[1] = .init(
				id: second,
				profileID: .init(rawValue: UUID(80)),
				restoration: organization.tabs[1].restoration
			)

		case "unplaced":
			state.workspace.spaces[0].unpinnedTabs.removeAll { $0 == second }

		default:
			state.workspace.spaces[0] = .init(
				id: organization.spaces[0].id,
				profileID: .init(rawValue: UUID(80)),
				name: "Reassigned",
				unpinnedTabs: organization.tabs.map(\.id)
			)
		}
		let items = state.sidebarLinkItems(in: state.main.id, tabIDs: ids)
		expectNoDifference(items, [])
		let store = TestStore(initialState: state) { AppFeature() }
		await store.send(.ui(.copyLinks(.original, items: items, sourceWindowID: state.main.id)))
		await store.send(.ui(.shareProxyLinks(items: items, sourceWindowID: state.main.id)))
		await store.finish()
	}

	@Test
	internal func sidebarLinksResolveFavoriteOwnersAndBorrowedPeekBeforeSuppressedPane() async throws {
		var organization = fixture()
		let first = organization.tabs[0].id
		try organization.move(.tab(first.rawValue), to: .favoritesRoot, in: organization.spaces[0].id)
		let tab = organization.tabs[0]
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[1].id))
		var owner = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id, id: UUID(30))
		owner.viewer.item = .init(
			tab: tab,
			navigation: .init(url: URL(string: "https://owner.example/current")!, title: "Owner")
		)
		state.windows.append(owner)
		expectNoDifference(state.sidebarLinkItems(in: state.main.id, tabIDs: [first.rawValue]), [
			.init(title: "Owner", url: URL(string: "https://owner.example/current")!),
		])
		var hiddenMain = state
		hiddenMain.windowIsOpen = false
		hiddenMain.main.viewer.item = .init(
			tab: tab,
			navigation: .init(url: URL(string: "https://stale.example")!, title: "Stale")
		)
		let source = MainFeature.State(organization: organization, spaceID: organization.spaces[1].id, id: UUID(31))
		hiddenMain.windows.append(source)
		expectNoDifference(hiddenMain.sidebarLinkItems(in: source.id, tabIDs: [first.rawValue]).first?.title, "Owner")
		var peek = PeekFeature.State(
			id: UUID(40),
			source: .init(
				windowID: owner.id,
				paneID: owner.viewer.activePaneID,
				tabID: first,
				spaceID: owner.sidebar.spaceID,
				profileID: tab.profileID,
				identity: "Borrowed"
			),
			tab: tab,
			isTemporary: false
		)
		peek.viewer.navigation = .init(url: URL(string: "https://peek.example/current")!, title: "Peek")
		state.peeks.append(peek)
		expectNoDifference(state.sidebarLinkItems(in: owner.id, tabIDs: [first.rawValue]), [
			.init(title: "Peek", url: URL(string: "https://peek.example/current")!),
		])
		expectNoDifference(state.sidebarLinkItems(in: state.main.id, tabIDs: [first.rawValue], saved: true), [
			.init(title: tab.savedDestination!.title, url: tab.savedDestination!.url),
		])
	}

	@Test
	internal func sidebarLinkTargetsRemainWindowScopedAndPrivateSnapshotsStayLocal() async throws {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let tab = organization.tabs[0]
		state.main.viewer.item = .init(
			tab: tab,
			navigation: .init(url: URL(string: "https://ordinary.example")!, title: "Ordinary")
		)
		var privateWindow = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: true,
			id: UUID(50)
		)
		privateWindow.viewer.item = .init(
			tab: tab,
			navigation: .init(url: URL(string: "https://private.example")!, title: "Private")
		)
		state.windows.append(privateWindow)
		state.focusedWindowID = privateWindow.id
		expectNoDifference(state.sidebarLinkItems(in: state.main.id, tabIDs: [tab.id.rawValue]).first?.title, "Ordinary")
		expectNoDifference(state.sidebarLinkItems(in: privateWindow.id, tabIDs: [tab.id.rawValue]).first?.title, "Private")
		state.windows[id: privateWindow.id]?.viewer.item = .init()
		expectNoDifference(
			state.sidebarLinkItems(in: privateWindow.id, tabIDs: [tab.id.rawValue]).first?.url,
			tab.restoration.url
		)
		state.main.viewer.item = .init()
		state.windows[id: privateWindow.id]?.viewer.item = privateWindow.viewer.item
		expectNoDifference(
			state.sidebarLinkItems(in: state.main.id, tabIDs: [tab.id.rawValue]).first?.url,
			tab.restoration.url
		)
		expectNoDifference(state.sidebarLinkItems(in: UUID(99), tabIDs: [tab.id.rawValue]), [])
		state.windowIsOpen = false
		expectNoDifference(state.sidebarLinkItems(in: state.main.id, tabIDs: [tab.id.rawValue]), [])
		state.windows[id: privateWindow.id]?.isClosing = true
		expectNoDifference(state.sidebarLinkItems(in: privateWindow.id, tabIDs: [tab.id.rawValue]), [])
	}

	@Test
	internal func selectedSidebarLinksShareInOrderButPaneCommandsStaySinglePage() async throws {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let first = organization.tabs[0]
		let second = organization.tabs[1]
		state.main.sidebar.moveSelection = [.tab(second.id.rawValue), .tab(first.id.rawValue)]
		state.main.viewer.item = .init(
			tab: first,
			navigation: .init(url: URL(string: "https://x.com/first")!, title: "First")
		)
		state.main.viewer.panes.append(.init(
			id: UUID(20),
			item: .init(
				tab: second,
				navigation: .init(url: URL(string: "https://x.com/second")!, title: "Second")
			)
		))
		state.settings.$proxyLinkRules.withLock { $0 = [
			.init(
				id: UUID(60),
				name: "Test proxy",
				sourceHosts: ["x.com"],
				destinationTemplate: "https://proxy.example{path}{query}{fragment}"
			),
		] }
		var shared: [[URL]] = []
		var copied: [String] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.linkSharing.share = { urls, _ in
				shared.append(urls)
				return .cancelled
			}
			$0.linkSharing.copy = {
				copied.append($0)
				return true
			}
		}
		let ids = try #require(state.main.sidebar.tabItem(first.id)).linkTabIDs
		let items = state.sidebarLinkItems(in: state.main.id, tabIDs: ids)
		await store.send(.ui(.shareProxyLinks(items: items, sourceWindowID: state.main.id))).finish()
		expectNoDifference(
			shared,
			[[URL(string: "https://proxy.example/second")!, URL(string: "https://proxy.example/first")!]]
		)
		expectNoDifference(store.linkActionFeedback?.status, .share(.cancelled))
		await store.send(.ui(.command(.copyURL, .window(state.main.id, paneID: UUID(20))))).finish()
		expectNoDifference(copied, ["https://x.com/second"])
		expectNoDifference(store.main.sidebar.moveSelection, state.main.sidebar.moveSelection)
		expectNoDifference(store.workspace, organization)
		expectNoDifference(state.linkItems(in: state.main.id).count, 1)
	}
}
