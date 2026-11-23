import AppFeature
import AppUI
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// The tab menu's bulk actions, each one Undo Organization Change (DEV-883).
extension IntegrationFeatureTests {
	@Test
	internal func closeOtherTabsArchivesTheRestAsOneUndo() async throws {
		let organization = bulkFixture()
		let open = organization.spaces[0].unpinnedTabs
		var closed: [BrowserCore.Tab.ID] = []
		let store = bulkStore(organization) { closed.append($0) }

		await store.send(.sidebar(.ui(.sidebar(.closeOtherTabs(.tab(open[1].rawValue))))))
		await store.receive(\.event.bulkCloseApproved)
		await store.receive(\.event.bulkCloseFinished)
		await store.finish()

		expectNoDifference(closed, [open[0], open[2], open[3]])
		expectNoDifference(store.state.sidebar.space.unpinnedTabs, [open[1]])
		expectNoDifference(store.state.sidebar.organization.archive.map(\.tab.id), [open[0], open[2], open[3]])

		// One group, so Reopen Last Closed Tab brings them back together.
		#expect(Set(store.state.sidebar.organization.archive.map(\.groupID)).count == 1)

		await store.send(.sidebar(.ui(.undo)))
		expectNoDifference(store.state.sidebar.organization, organization)
	}

	@Test
	internal func closeOtherTabsKeepsTheWholeSelection() async throws {
		let organization = bulkFixture()
		let open = organization.spaces[0].unpinnedTabs
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.sidebar.moveSelection = [.tab(open[3].rawValue), .tab(open[0].rawValue)]
		let store = bulkStore(state: state) { _ in }

		await store.send(.sidebar(.ui(.sidebar(.closeOtherTabs(.tab(open[0].rawValue))))))
		await store.receive(\.event.bulkCloseFinished)
		await store.finish()

		expectNoDifference(store.state.sidebar.space.unpinnedTabs, [open[0], open[3]])
	}

	@Test
	internal func closeTabsBelowClosesOnlyTheOpenTabsAfterTheRow() async throws {
		let organization = bulkFixture()
		let open = organization.spaces[0].unpinnedTabs
		var closed: [BrowserCore.Tab.ID] = []
		let store = bulkStore(organization) { closed.append($0) }

		await store.send(.sidebar(.ui(.sidebar(.closeTabsBelow(.tab(open[1].rawValue))))))
		await store.receive(\.event.bulkCloseFinished)
		await store.finish()

		expectNoDifference(closed, [open[2], open[3]])
		expectNoDifference(store.state.sidebar.space.unpinnedTabs, [open[0], open[1]])
		#expect(store.state.sidebar.organization.tabs[id: organization.pinnedID] != nil)

		await store.send(.sidebar(.ui(.undo)))
		expectNoDifference(store.state.sidebar.organization, organization)
	}

	@Test
	internal func closeTabsUnloadsPinnedTabsAndArchivesOpenOnes() async throws {
		var organization = bulkFixture()
		let open = organization.spaces[0].unpinnedTabs
		let pinned = organization.pinnedID
		organization.tabs[id: pinned]?.restoration = .init(title: "Elsewhere", url: URL(string: "https://elsewhere.example")!)
		var closed: [BrowserCore.Tab.ID] = []
		let store = bulkStore(organization) { closed.append($0) }

		await store.send(.sidebar(.ui(.sidebar(.closeTabs([.tab(open[2].rawValue), .tab(pinned.rawValue)])))))
		await store.receive(\.event.bulkCloseFinished)
		await store.finish()

		expectNoDifference(closed, [open[2], pinned])
		expectNoDifference(store.state.sidebar.space.unpinnedTabs, [open[0], open[1], open[3]])
		let reset = try #require(store.state.sidebar.organization.tabs[id: pinned])
		expectNoDifference(reset.restoration.url, reset.savedDestination?.url)

		await store.send(.sidebar(.ui(.undo)))
		expectNoDifference(store.state.sidebar.organization, organization)
	}

	@Test
	internal func archiveTabsLeavesPinnedTabsAlone() async throws {
		let organization = bulkFixture()
		let open = organization.spaces[0].unpinnedTabs
		var closed: [BrowserCore.Tab.ID] = []
		let store = bulkStore(organization) { closed.append($0) }

		await store.send(.sidebar(.ui(.sidebar(.archiveTabs([.tab(organization.pinnedID.rawValue), .tab(open[0].rawValue)])))))
		await store.receive(\.event.bulkCloseFinished)
		await store.finish()

		expectNoDifference(closed, [open[0]])
		expectNoDifference(store.state.sidebar.organization.archive.map(\.tab.id), [open[0]])
	}

	@Test
	internal func aPageThatRefusesKeepsEveryTabOfTheBulkClose() async throws {
		let organization = bulkFixture()
		let open = organization.spaces[0].unpinnedTabs
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.permitsClosing = { $0 != open[2] }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.ui(.sidebar(.closeTabsBelow(.tab(open[0].rawValue))))))
		await store.receive(\.event.archiveFailed)
		await store.finish()

		expectNoDifference(closed, [])
		expectNoDifference(store.state.sidebar.organization, organization)
		#expect(!store.state.archive.isWorking)
	}

	@Test
	internal func duplicatePinAndUnpinAreOneUndoEach() async throws {
		let organization = bulkFixture()
		let open = organization.spaces[0].unpinnedTabs
		let pinned = organization.pinnedID
		let store = bulkStore(organization) { _ in }

		await store.send(.sidebar(.ui(.sidebar(.duplicateTabs([.tab(open[1].rawValue), .tab(open[0].rawValue)])))))

		// Each copy is listed below the tab it copies (DEV-1310), so they're found by being new.
		let copies = store.state.sidebar.space.unpinnedTabs.filter { !open.contains($0) }
		#expect(copies.count == 2)
		expectNoDifference(
			copies.compactMap { store.state.sidebar.organization.tabs[id: $0]?.restoration },
			[open[0], open[1]].compactMap { organization.tabs[id: $0]?.restoration }
		)
		await store.send(.sidebar(.ui(.undo)))
		expectNoDifference(store.state.sidebar.organization, organization)

		await store.send(.sidebar(.ui(.sidebar(.setPinned([.tab(open[2].rawValue), .tab(open[3].rawValue)], true)))))
		expectNoDifference(store.state.sidebar.space.savedItems, [.tab(pinned), .tab(open[2]), .tab(open[3])])
		expectNoDifference(store.state.sidebar.space.unpinnedTabs, [open[0], open[1]])
		await store.send(.sidebar(.ui(.undo)))
		expectNoDifference(store.state.sidebar.organization, organization)

		await store.send(.sidebar(.ui(.sidebar(.setPinned([.tab(pinned.rawValue), .tab(open[0].rawValue)], false)))))
		expectNoDifference(store.state.sidebar.space.savedItems, [])
		#expect(store.state.sidebar.space.unpinnedTabs.contains(pinned))
		await store.send(.sidebar(.ui(.undo)))
		expectNoDifference(store.state.sidebar.organization, organization)
	}

	/// DEV-1310: a duplicate is listed right below the open tab it copies, and a pinned tab's is
	/// the first open tab. Both used to go to the end of the list.
	@Test
	internal func aDuplicateIsListedBelowItsSourceAndAPinnedTabsFirst() async throws {
		let organization = bulkFixture()
		let open = organization.spaces[0].unpinnedTabs
		let pinned = BrowserCore.Tab.ID(rawValue: UUID(7))
		let store = TestStore(initialState: MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.cloneNavigation = { _, _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.ui(.sidebar(.duplicateTabs([.tab(open[1].rawValue)])))))
		await store.finish()
		let afterOpen = store.state.sidebar.organization.spaces[0].unpinnedTabs
		let copy = try #require(afterOpen.first { !open.contains($0) })
		expectNoDifference(afterOpen, Array(open[...1]) + [copy] + Array(open[2...]))

		await store.send(.sidebar(.ui(.sidebar(.duplicateTabs([.tab(pinned.rawValue)])))))
		await store.finish()
		let afterPinned = store.state.sidebar.organization.spaces[0].unpinnedTabs
		expectNoDifference(Array(afterPinned.dropFirst()), afterOpen)
		#expect(!afterOpen.contains(afterPinned[0]))
		expectNoDifference(store.state.sidebar.organization.tabs[id: afterPinned[0]]?.restoration.url, URL(string: "https://saved.example")!)

		// ⌘D on the selected tab: the copy is below it and selected.
		let selected = try #require(store.state.sidebar.selectedTab?.id)
		await store.send(.ui(.duplicateTab))
		await store.finish()
		let afterCommand = store.state.sidebar.organization.spaces[0].unpinnedTabs
		let copied = try #require(store.state.sidebar.selectedTab?.id)
		#expect(copied != selected)
		if let position = afterCommand.firstIndex(of: selected) {
			expectNoDifference(afterCommand[position + 1], copied)
		} else {
			expectNoDifference(afterCommand.first, copied)
		}
	}

	/// DEV-878: a duplicate's first page takes its tab's back/forward history.
	@Test
	internal func duplicatesTakeTheirTabsHistory() async throws {
		let organization = bulkFixture()
		let open = organization.spaces[0].unpinnedTabs
		let cloned = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = TestStore(initialState: MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.cloneNavigation = { source, _ in cloned.withValue { $0.append(source.id) } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.ui(.sidebar(.duplicateTabs([.tab(open[2].rawValue), .tab(open[0].rawValue)])))))
		await store.send(.ui(.duplicateTab))
		await store.finish()

		expectNoDifference(cloned.value, [open[0], open[2], open[0]])

		// ⌘D, the menu and the command bar duplicate through the pane command.
		var shown = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		shown.viewer.item.tab = organization.tabs[id: open[1]]
		let paneID = shown.viewer.activePaneID
		let command = TestStore(initialState: shown) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.cloneNavigation = { source, _ in cloned.withValue { $0.append(source.id) } }
		}
		command.exhaustivity = .off(showSkippedAssertions: false)
		await command.send(.ui(.paneCommand(.duplicateTab, paneID)))
		await command.finish()
		expectNoDifference(cloned.value.last, open[1])
	}

	@Test
	internal func aSelectedRowCountsTheSelectionForItsBulkMenu() async throws {
		let organization = bulkFixture()
		let open = organization.spaces[0].unpinnedTabs
		var sidebar = SidebarFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		sidebar.moveSelection = [.tab(open[0].rawValue), .tab(organization.pinnedID.rawValue), .tab(open[2].rawValue)]

		let selected = try #require(sidebar.tabItem(open[0]))
		expectNoDifference(selected.selection, .init(
			tabIDs: sidebar.moveSelection,
			openTabCount: 2,
			savedTabCount: 1
		))
		#expect(sidebar.tabItem(open[1])?.selection == nil)

		sidebar.moveSelection = [.tab(open[0].rawValue)]
		#expect(sidebar.tabItem(open[0])?.selection == nil)
		#expect(String.localized(.appUI.sidebar.closeTabs(1)) == "Close 1 Tab")
		#expect(String.localized(.appUI.sidebar.closeTabs(3)) == "Close 3 Tabs")
	}

	@Test
	internal func moveToWindowSendsTheTabsToThatWindowsSpaceAndShowsTheFirst() async throws {
		let organization = bulkFixture()
		let open = organization.spaces[0].unpinnedTabs
		let other = UUID(900)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.windows.append(.init(organization: organization, spaceID: organization.spaces[1].id, id: other))
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		expectNoDifference(store.state.sidebarWindowTargets(from: state.main.id).map(\.id), [other])
		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(open[1].rawValue)], other))))))
		await store.finish()
		await store.skipReceivedActions()

		expectNoDifference(store.state.main.sidebar.spaceID, organization.spaces[0].id)

		expectNoDifference(store.state.workspace.spaces[1].unpinnedTabs, [open[1]])
		#expect(!store.state.workspace.spaces[0].unpinnedTabs.contains(open[1]))
		expectNoDifference(store.state.windows[id: other]?.sidebar.selectedTab?.id, open[1])
		expectNoDifference(store.state.focusedWindowID, other)

		// Showing the tab over there leaves this window's undo, which brings it back.
		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions()
		#expect(store.state.workspace.spaces[0].unpinnedTabs.contains(open[1]))
		#expect(!store.state.workspace.spaces[1].unpinnedTabs.contains(open[1]))
	}

	@Test
	internal func openInNewWindowShowsTheTabThereAndAnotherHere() async throws {
		let organization = bulkFixture()
		let open = organization.spaces[0].unpinnedTabs
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.sidebar.select(open[0])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(900))
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(open[0].rawValue)], nil))))))
		await store.finish()
		await store.skipReceivedActions()

		expectNoDifference(store.state.main.sidebar.selectedTab?.id, open[1])
		let window = try #require(store.state.windows[id: UUID(900)])
		expectNoDifference(window.sidebar.spaceID, organization.spaces[0].id)
		expectNoDifference(window.sidebar.selectedTab?.id, open[0])
	}

	/// A headless run shows no window, so Move to Window opens none and hands nothing over.
	@Test
	internal func aHeadlessRunNeitherOpensNorFillsAWindow() async throws {
		let organization = bulkFixture()
		let open = organization.spaces[0].unpinnedTabs
		let other = UUID(900)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.sidebar.select(open[0])
		state.automation.isUnattended = true
		state.windows.append(.init(organization: organization, spaceID: organization.spaces[1].id, id: other))
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(open[0].rawValue)], nil))))))
		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(open[0].rawValue)], other))))))
		await store.finish()
		await store.skipReceivedActions()

		expectNoDifference(store.state.windows.ids, [other])
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, open[0])
		expectNoDifference(store.state.workspace.spaces[0].unpinnedTabs, open)
	}

	/// A move another window refuses, because it shows one of the tabs, leaves this window's
	/// selection and panes as they were.
	@Test
	internal func aRefusedWindowMoveLeavesThisWindowAsItWas() async throws {
		let organization = bulkFixture()
		let open = organization.spaces[0].unpinnedTabs
		let other = UUID(900)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.sidebar.select(open[0])
		var window = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id, id: other)
		window.viewer.item.tab = organization.tabs[id: open[1]]
		state.windows.append(window)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(open[0].rawValue), .tab(open[1].rawValue)], nil))))))
		await store.finish()
		await store.skipReceivedActions()

		expectNoDifference(store.state.main.sidebar.selectedTab?.id, open[0])
		#expect(store.state.windows.count == 1)
	}

	@Test
	internal func moveToWindowListsOnlyWindowsOfTheSameProfile() async throws {
		var organization = bulkFixture()
		let otherProfile = Profile.ID(rawValue: UUID(80))
		let otherSpace = Space.ID(rawValue: UUID(81))
		organization.profiles.append(.init(id: otherProfile, name: "Other"))
		organization.spaces.append(.init(id: otherSpace, profileID: otherProfile, name: "Elsewhere"))
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.windows.append(.init(organization: organization, spaceID: organization.spaces[1].id, id: UUID(900)))
		state.windows.append(.init(organization: organization, spaceID: otherSpace, id: UUID(901)))
		state.windows.append(.init(organization: organization, spaceID: organization.spaces[0].id, isPrivate: true, id: UUID(902)))

		expectNoDifference(state.sidebarWindowTargets(from: state.main.id).map(\.id), [UUID(900)])
		expectNoDifference(state.sidebarWindowTargets(from: UUID(902)), [])
	}

	/// Four open tabs and one pinned tab in the first space.
	private func bulkFixture() -> BrowserOrganization {
		var organization = fixture()
		let profile = organization.profiles[0].id
		let extra: [BrowserCore.Tab] = [5, 6].map {
			.init(
				id: .init(rawValue: UUID($0)),
				profileID: profile,
				restoration: .init(title: "Page \($0)", url: URL(string: "https://example.com/\($0)")!)
			)
		}
		organization.tabs.append(contentsOf: extra)
		organization.spaces[0].unpinnedTabs.append(contentsOf: extra.map(\.id))
		let pinned = BrowserCore.Tab(
			id: .init(rawValue: UUID(7)),
			profileID: profile,
			savedDestination: .init(title: "Saved", url: URL(string: "https://saved.example")!),
			restoration: .init(title: "Saved", url: URL(string: "https://saved.example")!)
		)
		organization.tabs.append(pinned)
		organization.spaces[0].savedItems = [.tab(pinned.id)]
		return organization
	}

	private func bulkStore(
		_ organization: BrowserOrganization,
		close: @escaping @MainActor @Sendable (BrowserCore.Tab.ID) -> Void
	) -> TestStoreOf<MainFeature> {
		bulkStore(state: .init(organization: organization, spaceID: organization.spaces[0].id), close: close)
	}

	private func bulkStore(
		state: MainFeature.State,
		close: @escaping @MainActor @Sendable (BrowserCore.Tab.ID) -> Void
	) -> TestStoreOf<MainFeature> {
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { close($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}

extension BrowserOrganization {
	fileprivate var pinnedID: BrowserCore.Tab.ID { .init(rawValue: UUID(7)) }
}
