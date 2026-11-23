import AppUI
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import Testing
import ViewerFeature
import _ComposableArchitecture
import _TestSupport

/// DEV-692: Split View groups of up to four tabs, built by drops, shown as one sidebar row and
/// managed from the group's context menu.
@Suite(.dependencies)
@MainActor
internal struct SplitGroupTests {
	@Test
	internal func droppingATabOnAnotherFormsAGroupAndShowsBoth() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2)], .split(item(1)), space))))
		await store.receive(\.synchronize)
		await store.receive(\.viewer.layout)
		await store.skipReceivedActions()

		let group = try #require(store.state.sidebar.organization.splits.first)
		expectNoDifference(group.tabIDs, [tab(1), tab(2)])
		expectNoDifference(group.fractions, [0.5, 0.5])
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(2)])
		expectNoDifference(store.state.viewer.item.tab?.id, tab(2))

		// The sidebar shows the pair as one row with a segment for each.
		let row = try #require(store.state.sidebar.openTabs.first { $0.split != nil })
		expectNoDifference(row.split?.memberIDs, [item(1), item(2)])
		expectNoDifference(store.state.sidebar.openTabs.count, 4)
		await store.finish()
	}

	@Test
	internal func groupsGrowToFourAndRefuseAFifthOrALackOfRoom() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2)], .split(item(1)), space))))
		await store.send(.sidebar(.ui(.moveItems([item(3), item(4)], .split(item(1)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.first?.tabIDs, [tab(1), tab(2), tab(3), tab(4)])
		expectNoDifference(store.state.viewer.panes.count, 4)

		let before = store.state.sidebar.organization
		await store.send(.sidebar(.ui(.moveItems([item(5)], .split(item(1)), space))))
		expectNoDifference(store.state.sidebar.organization, before)
		expectNoDifference(store.state.sidebar.message, SplitDropRefusal.full.message)

		// A window with room for two panes side by side refuses a third.
		let narrow = makeStore { $0.viewer.capacity = .init(horizontal: 2, vertical: 1) }
		await narrow.send(.sidebar(.ui(.moveItems([item(2)], .split(item(1)), space))))
		await narrow.send(.sidebar(.ui(.moveItems([item(3)], .split(item(2)), space))))
		await narrow.skipReceivedActions()
		expectNoDifference(narrow.state.sidebar.organization.splits.first?.tabIDs, [tab(1), tab(2)])
		expectNoDifference(narrow.state.sidebar.message, SplitDropRefusal.tooNarrow.message)
		await store.finish()
		await narrow.finish()
	}

	@Test
	internal func droppingIntoThePageAddsAPaneOnThatSide() async throws {
		let store = makeStore()
		await store.send(.ui(.dropTabInViewer(tab(3), .leading)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(3), tab(1)])
		expectNoDifference(store.state.sidebar.organization.splits.first?.tabIDs, [tab(3), tab(1)])

		await store.send(.ui(.dropTabInViewer(tab(4), .bottom)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.orientation, .vertical)
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(3), tab(1), tab(4)])
		let group = try #require(store.state.sidebar.organization.splits.first)
		expectNoDifference(group.tabIDs, [tab(3), tab(1), tab(4)])
		expectNoDifference(group.orientation, .vertical)
		expectNoDifference(group.fractions, SplitLayout.equal(3))

		// A tab already shown, or a full split, is refused.
		expectNoDifference(store.state.viewerDropRefusal(tab(1), edge: .trailing), .unavailable)
		await store.send(.ui(.dropTabInViewer(tab(5), .trailing)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewerDropRefusal(tab(2), edge: .trailing), .full)
		await store.finish()
	}

	@Test
	internal func selectingAnotherTabLeavesTheGroupAndSelectingAMemberRestoresIt() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2)], .split(item(1)), space))))
		await store.skipReceivedActions()

		await store.send(.sidebar(.ui(.sidebar(.select(item(3))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(3)])
		expectNoDifference(store.state.sidebar.organization.splits.first?.tabIDs, [tab(1), tab(2)])

		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.focus(group: groupID(store), tab: tab(2).rawValue))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(2)])
		expectNoDifference(store.state.viewer.item.tab?.id, tab(2))
		await store.finish()
	}

	@Test
	internal func resizingAndTurningAreSavedOnTheGroup() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2), item(3)], .split(item(1)), space))))
		await store.skipReceivedActions()

		// Only the end of a drag reaches the group.
		await store.send(.viewer(.ui(.resize([0.5, 0.25, 0.25]))))
		expectNoDifference(store.state.sidebar.organization.splits.first?.fractions, SplitLayout.equal(3))
		await store.send(.viewer(.ui(.resizeEnded)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.first?.fractions, [0.5, 0.25, 0.25])

		await store.send(.viewer(.ui(.equalize)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.first?.fractions, SplitLayout.equal(3))

		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.toggleOrientation(groupID(store)))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.first?.orientation, .vertical)
		expectNoDifference(store.state.viewer.orientation, .vertical)

		// Turning back is refused when the window can't fit three panes side by side.
		await store.send(.viewer(.ui(.capacityChanged(.init(horizontal: 2, vertical: 4)))))
		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.toggleOrientation(groupID(store)))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.first?.orientation, .vertical)
		expectNoDifference(store.state.sidebar.message, SplitDropRefusal.tooNarrow.message)
		await store.finish()
	}

	@Test
	internal func separatingAndClosingPanesTakeTabsOut() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2), item(3)], .split(item(1)), space))))
		await store.skipReceivedActions()
		let group = groupID(store)

		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.separate(group: group, tab: tab(3).rawValue))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.first?.tabIDs, [tab(1), tab(2)])
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(2)])

		let pane = try #require(store.state.viewer.panes.first { $0.item.tab?.id == tab(2) })
		await store.send(.viewer(.ui(.closePane(pane.id))))
		await store.skipReceivedActions()
		#expect(store.state.sidebar.organization.splits.isEmpty)
		expectNoDifference(store.state.sidebar.openTabs.count, 5)

		await store.send(.sidebar(.ui(.moveItems([item(4)], .split(item(5)), space))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.separateAll(groupID(store)))))))
		await store.skipReceivedActions()
		#expect(store.state.sidebar.organization.splits.isEmpty)
		expectNoDifference(store.state.viewer.panes.count, 1)
		await store.finish()
	}

	@Test
	internal func draggingAMemberElsewhereTakesItOutButMovingTheWholeGroupKeepsIt() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2), item(3)], .split(item(1)), space))))
		await store.skipReceivedActions()

		await store.send(.sidebar(.ui(.moveItems([item(1), item(2), item(3)], .unpinnedRoot, space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.first?.tabIDs, [tab(1), tab(2), tab(3)])

		await store.send(.sidebar(.ui(.moveItems([item(2)], .before(item(5)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.first?.tabIDs, [tab(1), tab(3)])
		await store.finish()
	}

	@Test
	internal func renameIconDuplicateAndTabOptions() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2)], .split(item(1)), space))))
		await store.skipReceivedActions()
		let group = groupID(store)

		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.rename(group, "Research"))))))
		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.changeIcon(group, "book.fill"))))))
		await store.skipReceivedActions()
		let named = try #require(store.state.sidebar.organization.splits.first)
		expectNoDifference(named.title, "Research")
		expectNoDifference(named.icon, "book.fill")
		expectNoDifference(store.state.sidebar.openTabs.first { $0.split != nil }?.split?.title, "Research")

		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.duplicate(group))))))
		await store.skipReceivedActions()
		let splits = store.state.sidebar.organization.splits
		expectNoDifference(splits.count, 2)
		let copy = try #require(splits.last)
		expectNoDifference(copy.title, "Research")
		expectNoDifference(copy.tabIDs.count, 2)
		#expect(Set(copy.tabIDs).isDisjoint(with: [tab(1), tab(2)]))
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, copy.tabIDs)

		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.toggleMute(tab: tab(1).rawValue))))))
		await store.receive(\.delegate.toggleMute)

		let tabCount = store.state.sidebar.organization.tabs.count
		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.duplicateTab(tab(2).rawValue))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.tabs.count, tabCount + 1)
		await store.finish()
	}

	@Test
	internal func addTabOpensAnEmptyPaneBesideTheGroup() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2)], .split(item(1)), space))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.sidebar(.select(item(4))))))
		await store.skipReceivedActions()

		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.addTab(groupID(store)))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(2), nil])
		#expect(store.state.commandBar.isPresented)
		expectNoDifference(store.state.commandBarEmptyPaneID, store.state.viewer.panes.last?.id)
		await store.finish()
	}

	@Test
	internal func automationOpensASplitOfUpToFourInTheChosenOrientation() async throws {
		let store = makeStore()
		await store.send(.ui(.openSplit([tab(4), tab(2), tab(5)], .vertical)))
		await store.skipReceivedActions()
		let group = try #require(store.state.sidebar.organization.splits.first)
		expectNoDifference(group.tabIDs, [tab(4), tab(2), tab(5)])
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(4), tab(2), tab(5)])
		expectNoDifference(store.state.viewer.orientation, .vertical)
		await store.finish()
	}

	@Test
	internal func focusOtherPaneReachesEveryPane() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2), item(3)], .split(item(1)), space))))
		await store.skipReceivedActions()
		var visited: [BrowserCore.Tab.ID?] = []
		for _ in 0 ..< 3 {
			await store.send(.ui(.paneCommand(.focusOtherPane, store.state.viewer.activePaneID)))
			await store.skipReceivedActions()
			visited.append(store.state.viewer.item.tab?.id)
		}
		expectNoDifference(Set(visited.compactMap { $0 }), [tab(1), tab(2), tab(3)])
		await store.finish()
	}

	@Test
	internal func aMoveThatFailsKeepsTheGroup() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2)], .split(item(1)), space))))
		await store.skipReceivedActions()
		let before = store.state.sidebar.organization.splits

		// No such folder: the move is refused, and the tab stays in its split.
		await store.send(.sidebar(.ui(.moveItems([item(2)], .inside(.folder(UUID(77))), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits, before)
		await store.finish()
	}

	@Test
	internal func aGroupLayoutLeavesOutTabsShownInAnotherWindow() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2), item(3)], .split(item(1)), space))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.sidebar(.select(item(4))))))
		await store.skipReceivedActions()

		var state = store.state
		state.viewer.tabsShownElsewhere = [tab(2)]
		let other = makeStore(uuidStart: 500) { $0 = state }
		await other.send(.sidebar(.ui(.sidebar(.splitGroup(.focus(group: groupID(other), tab: tab(1).rawValue))))))
		await other.skipReceivedActions()
		expectNoDifference(other.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(3)])

		// Showing part of a group never changes its members, nor does resizing what's shown.
		expectNoDifference(other.state.sidebar.organization.splits.first?.tabIDs, [tab(1), tab(2), tab(3)])
		await other.send(.viewer(.ui(.resize([0.25, 0.75]))))
		await other.send(.viewer(.ui(.resizeEnded)))
		await other.skipReceivedActions()
		expectNoDifference(other.state.sidebar.organization.splits.first?.tabIDs, [tab(1), tab(2), tab(3)])

		// A tab another window shows can't be dropped into this page either.
		var elsewhere = other.state
		elsewhere.viewer.tabsShownElsewhere = [tab(5)]
		expectNoDifference(elsewhere.viewerDropRefusal(tab(5), edge: .trailing), .unavailable)
		await store.finish()
		await other.finish()
	}

	@Test
	internal func separatingAMiddleTabKeepsTheOthersTogether() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2), item(3)], .split(item(1)), space))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.separate(group: groupID(store), tab: tab(2).rawValue))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.first?.tabIDs, [tab(1), tab(3)])
		expectNoDifference(store.state.sidebar.space.unpinnedTabs.prefix(3), [tab(1), tab(3), tab(2)])

		// The separated tab now shows alone; closing a middle pane later leaves the rest grouped.
		await store.send(.sidebar(.ui(.moveItems([item(4)], .split(item(1)), space))))
		await store.skipReceivedActions()
		let middle = try #require(store.state.viewer.panes.first { $0.item.tab?.id == tab(3) })
		await store.send(.viewer(.ui(.closePane(middle.id))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.first?.tabIDs, [tab(1), tab(4)])
		await store.finish()
	}

	@Test
	internal func undoingAGroupAlsoUndoesItsPanes() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2)], .split(item(1)), space))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.undo)))
		await store.skipReceivedActions()
		#expect(store.state.sidebar.organization.splits.isEmpty)
		expectNoDifference(store.state.viewer.panes.count, 1)
		await store.finish()
	}

	@Test
	internal func addingATabFromAnotherGroupKeepsTheShownGroup() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(4), item(5)], .split(item(3)), space))))
		await store.send(.sidebar(.ui(.moveItems([item(2)], .split(item(1)), space))))
		await store.skipReceivedActions()
		let shown = try #require(store.state.sidebar.organization.split(containing: tab(1)))

		// Split with tab 3, which belongs to the other group.
		await store.send(.viewer(.split(store.state.sidebar.organization.tabs[id: tab(3)])))
		await store.skipReceivedActions()
		let grown = try #require(store.state.sidebar.organization.splits[id: shown.id])
		expectNoDifference(grown.tabIDs, [tab(1), tab(2), tab(3)])
		expectNoDifference(store.state.sidebar.organization.split(containing: tab(4))?.tabIDs, [tab(4), tab(5)])
		await store.finish()
	}

	@Test
	internal func membersShownElsewhereCountTowardFour() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2), item(3), item(4)], .split(item(1)), space))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.sidebar(.select(item(5))))))
		await store.skipReceivedActions()
		var state = store.state
		state.viewer.tabsShownElsewhere = [tab(4)]
		let other = makeStore(uuidStart: 500) { $0 = state }
		await other.send(.sidebar(.ui(.sidebar(.splitGroup(.focus(group: groupID(other), tab: tab(1).rawValue))))))
		await other.skipReceivedActions()
		expectNoDifference(other.state.viewer.panes.count, 3)
		expectNoDifference(other.state.viewerDropRefusal(tab(5), edge: .trailing), .full)
		await store.finish()
		await other.finish()
	}

	@Test
	internal func showingATabWhereAMemberWasLeavesTheGroupAlone() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2)], .split(item(1)), space))))
		await store.skipReceivedActions()

		// As focusing a tab from automation or media does: a show into the active pane.
		let tab3 = try #require(store.state.sidebar.organization.tabs[id: tab(3)])
		await store.send(.viewer(.show(tab3, in: store.state.viewer.activePaneID)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.first?.tabIDs, [tab(1), tab(2)])
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(3)])
		await store.finish()
	}

	@Test
	internal func anEmptyPaneTakesAGroupedTabInsteadOfShowingItsGroup() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(4)], .split(item(3)), space))))
		await store.send(.sidebar(.ui(.moveItems([item(2)], .split(item(1)), space))))
		await store.skipReceivedActions()
		let shown = try #require(store.state.sidebar.organization.split(containing: tab(1)))
		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.addTab(shown.id.rawValue))))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.sidebar(.select(item(3))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(2), tab(3)])
		expectNoDifference(store.state.sidebar.organization.split(containing: tab(1))?.tabIDs, [tab(1), tab(2), tab(3)])
		await store.finish()
	}

	@Test
	internal func undoingAPageDropUndoesItsGroup() async throws {
		let store = makeStore()
		await store.send(.ui(.dropTabInViewer(tab(2), .trailing)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.first?.tabIDs, [tab(1), tab(2)])
		await store.send(.sidebar(.ui(.undo)))
		await store.skipReceivedActions()
		#expect(store.state.sidebar.organization.splits.isEmpty)
		expectNoDifference(store.state.viewer.panes.count, 1)
		await store.finish()
	}

	@Test
	internal func oneVisibleMemberStillCountsTheRestShownElsewhere() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2), item(3), item(4)], .split(item(1)), space))))
		await store.send(.sidebar(.ui(.sidebar(.select(item(5))))))
		await store.skipReceivedActions()
		var state = store.state
		state.viewer.tabsShownElsewhere = [tab(2), tab(3), tab(4)]
		let other = makeStore(uuidStart: 500) { $0 = state }
		await other.send(.sidebar(.ui(.sidebar(.splitGroup(.focus(group: groupID(other), tab: tab(1).rawValue))))))
		await other.skipReceivedActions()
		expectNoDifference(other.state.viewer.panes.map { $0.item.tab?.id }, [tab(1)])
		expectNoDifference(other.state.hiddenSplitMemberCount, 3)
		#expect(!other.state.canAddSplitPane)
		expectNoDifference(other.state.viewerDropRefusal(tab(5), edge: .trailing), .full)
		await store.finish()
		await other.finish()
	}

	@Test
	internal func splittingWithATabFromAnOffscreenGroupKeepsBothPanes() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(3)], .split(item(2)), space))))
		await store.send(.sidebar(.ui(.sidebar(.select(item(1))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1)])

		await store.send(.viewer(.split(store.state.sidebar.organization.tabs[id: tab(2)])))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(2)])
		expectNoDifference(store.state.sidebar.organization.split(containing: tab(1))?.tabIDs, [tab(1), tab(2)])
		await store.finish()
	}

	@Test
	internal func automationReplacesAnEmptyPaneLayout() async throws {
		let store = makeStore()
		await store.send(.ui(.splitTab(nil)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), nil])
		await store.send(.ui(.openSplit([tab(2), tab(3)], .vertical)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(2), tab(3)])
		expectNoDifference(store.state.viewer.orientation, .vertical)
		expectNoDifference(store.state.sidebar.organization.split(containing: tab(2))?.tabIDs, [tab(2), tab(3)])
		await store.finish()
	}

	@Test
	internal func closingTheActiveMemberOfAPairShowsTheOther() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2)], .split(item(1)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.item.tab?.id, tab(2))
		await store.send(.sidebar(.event(.closeApproved(tab(2), reset: false))))
		await store.skipReceivedActions()
		#expect(store.state.sidebar.organization.splits.isEmpty)
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1)])
		await store.finish()
	}

	@Test
	internal func undoingADragOutRestoresTheMember() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2), item(3)], .split(item(1)), space))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.moveItems([item(2)], .before(item(5)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.first?.tabIDs, [tab(1), tab(3)])
		await store.send(.sidebar(.ui(.undo)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.message, nil)
		expectNoDifference(store.state.sidebar.organization.splits.first?.tabIDs, [tab(1), tab(2), tab(3)])
		await store.finish()
	}

	@Test
	internal func splittingWithAMemberOfALargerGroupKeepsTheRestGrouped() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(3), item(4)], .split(item(2)), space))))
		await store.send(.sidebar(.ui(.sidebar(.select(item(1))))))
		await store.skipReceivedActions()
		await store.send(.viewer(.split(store.state.sidebar.organization.tabs[id: tab(2)])))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.split(containing: tab(1))?.tabIDs, [tab(1), tab(2)])
		expectNoDifference(store.state.sidebar.organization.split(containing: tab(3))?.tabIDs, [tab(3), tab(4)])
		await store.finish()
	}

	/// DEV-793: a chat opened in its own tab joins another tab's page like an ordinary tab.
	@Test
	internal func droppingAChatTabIntoAnotherTabsPageSplitsThem() async throws {
		let store = makeStore()
		await store.send(.ui(.openChatTab(.init(conversationID: UUID(7)), title: "Chat")))
		await store.skipReceivedActions()
		let chat = try #require(store.state.sidebar.organization.tabs.first { $0.isChat })

		await store.send(.sidebar(.ui(.sidebar(.select(item(2))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewerDropRefusal(chat.id, edge: .trailing), nil)

		await store.send(.ui(.dropTabInViewer(chat.id, .trailing)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(2), chat.id])
		expectNoDifference(store.state.sidebar.organization.splits.first?.tabIDs, [tab(2), chat.id])
		await store.finish()
	}

	/// DEV-793: Open in Tab puts the chat where the page was; dropping the chat on that page's
	/// edge splits it with the page it opened over.
	@Test(arguments: SplitDropEdge.allCases)
	internal func droppingAChatOnItsOwnPageSplitsItWithThePageItOpenedOver(edge: SplitDropEdge) async throws {
		let store = makeStore()
		await store.send(.ui(.openChatTab(.init(conversationID: UUID(7)), title: "Chat")))
		await store.skipReceivedActions()
		let chat = try #require(store.state.sidebar.organization.tabs.first { $0.isChat })
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [chat.id])
		expectNoDifference(store.state.viewerDropRefusal(chat.id, edge: edge), nil)

		await store.send(.ui(.dropTabInViewer(chat.id, edge)))
		await store.skipReceivedActions()
		let expected = edge == .leading || edge == .top ? [chat.id, tab(1)] : [tab(1), chat.id]
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, expected)
		let group = try #require(store.state.sidebar.organization.splits.first)
		expectNoDifference(group.tabIDs, expected)
		expectNoDifference(group.orientation, edge.isHorizontal ? .horizontal : .vertical)

		// The chat was in use, so it stays the active, selected tab wherever its pane goes.
		expectNoDifference(store.state.viewer.item.tab?.id, chat.id)
		expectNoDifference(store.state.sidebar.selectedTab?.id, chat.id)
		await store.finish()
	}

	/// An ordinary tab shown alone, or a chat whose page has closed, still can't drop on itself.
	@Test
	internal func aTabShownAloneCantDropOnItsOwnPage() async throws {
		let store = makeStore()
		expectNoDifference(store.state.viewerDropRefusal(tab(1), edge: .trailing), .unavailable)

		await store.send(.ui(.openChatTab(.init(conversationID: UUID(7)), title: "Chat")))
		await store.skipReceivedActions()
		let chat = try #require(store.state.sidebar.organization.tabs.first { $0.isChat })
		await store.send(.sidebar(.ui(.sidebar(.close(item(1))))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.sidebar(.select(.tab(chat.id.rawValue))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [chat.id])
		expectNoDifference(store.state.viewerDropRefusal(chat.id, edge: .trailing), .unavailable)
		await store.finish()
	}

	// MARK: - A pressed tab dropped into the page (DEV-994)

	/// The press selects the tab, so the page shows it alone; dropping it on a side of the page
	/// splits it with the tab selected before the press, with the dragged tab active.
	@Test(arguments: SplitDropEdge.allCases)
	internal func aPressedTabDroppedIntoThePageSplitsWithTheTabSelectedBefore(edge: SplitDropEdge) async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.sidebar(.selectOnPress(item(3))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(3)])
		expectNoDifference(store.state.viewerDropRefusal(tab(3), edge: edge), nil)

		await store.send(.ui(.dropTabInViewer(tab(3), edge)))
		await store.skipReceivedActions()
		let expected = edge == .leading || edge == .top ? [tab(3), tab(1)] : [tab(1), tab(3)]
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, expected)
		let group = try #require(store.state.sidebar.organization.splits.first)
		expectNoDifference(group.tabIDs, expected)
		expectNoDifference(group.orientation, edge.isHorizontal ? .horizontal : .vertical)
		expectNoDifference(store.state.viewer.item.tab?.id, tab(3))
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(3))
		await store.finish()
	}

	/// A press whose click completed, another selection, or a drag that ended elsewhere is over: the
	/// tab it selected, shown alone, can't drop on its own page, as before.
	@Test(arguments: ["click", "select", "move", "favorite"])
	internal func aPressThatEndedAnotherWayLeavesNothingToSplitWith(how: String) async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.sidebar(.selectOnPress(item(3))))))
		await store.skipReceivedActions()
		switch how {
		case "click":
			await store.send(.sidebar(.ui(.sidebar(.pressCompleted(item(3))))))
		case "select":
			await store.send(.sidebar(.ui(.sidebar(.select(item(2))))))
			await store.skipReceivedActions()
			await store.send(.sidebar(.ui(.sidebar(.select(item(3))))))
		case "move":
			await store.send(.sidebar(.ui(.sidebar(.move(item(3), .after(item(5)))))))
		default:
			await store.send(.sidebar(.ui(.moveItems([item(3)], .favoritesRoot, space))))
		}
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.viewerDropRefusal(tab(3), edge: .trailing), .unavailable)
		await store.send(.ui(.dropTabInViewer(tab(3), .trailing)))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.organization.splits.isEmpty)
		await store.finish()
	}

	/// Only the press's own drag pairs: once it has started, however it ended, a later drag of
	/// the same tab, or a drag of another, finds nothing to split with.
	@Test(arguments: [false, true])
	internal func onlyThePressesOwnDragPairs(otherTab: Bool) async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.sidebar(.selectOnPress(item(3))))))
		await store.skipReceivedActions()
		await store.send(.ui(.tabDragStarted(tab(3))))
		expectNoDifference(store.state.viewerDropRefusal(tab(3), edge: .trailing), nil)

		await store.send(.ui(.tabDragStarted(otherTab ? tab(4) : tab(3))))
		expectNoDifference(store.state.viewerDropRefusal(tab(3), edge: .trailing), .unavailable)
		await store.send(.ui(.dropTabInViewer(tab(3), .trailing)))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.organization.splits.isEmpty)
		await store.finish()
	}

	/// The usual drops still work after a press: another tab dragged into the page adds a pane
	/// beside the pressed one, and a press on the tab already selected records nothing.
	@Test
	internal func otherDropsAreUnchangedByAPress() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.sidebar(.selectOnPress(item(3))))))
		await store.skipReceivedActions()
		await store.send(.ui(.dropTabInViewer(tab(4), .trailing)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(3), tab(4)])

		let again = makeStore()
		await again.send(.sidebar(.ui(.sidebar(.selectOnPress(item(1))))))
		await again.skipReceivedActions()

		// Nothing to split with: the press didn't change the selection.
		expectNoDifference(again.state.viewerDropRefusal(tab(1), edge: .trailing), .unavailable)
		await store.finish()
		await again.finish()
	}

	/// Pressed while the page shows a group, the tab joins that group on the side it was dropped,
	/// as a drop on that page did before the press switched it.
	@Test
	internal func aPressedTabJoinsTheGroupThePageShowed() async throws {
		let store = makeStore()
		await store.send(.ui(.dropTabInViewer(tab(2), .trailing)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(2)])

		await store.send(.sidebar(.ui(.sidebar(.selectOnPress(item(3))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(3)])
		await store.send(.ui(.dropTabInViewer(tab(3), .trailing)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(2), tab(3)])
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(2), tab(3)]])
		expectNoDifference(store.state.viewer.item.tab?.id, tab(3))
		await store.finish()
	}

	/// Pressed while the page shows a pinned tab, an open tab dropped there is pinned beside it, and
	/// the two make a pinned split (DEV-1006).
	@Test
	internal func aPressedTabSharesThePageWithAPinnedTab() async throws {
		let store = makeStore { state in
			state.sidebar.organization.spaces[id: space]?.unpinnedTabs.removeAll { $0 == tab(5) }
			state.sidebar.organization.spaces[id: space]?.savedItems = [.tab(tab(5))]
			state.sidebar.organization.tabs[id: tab(5)]?.savedDestination = .init(
				title: "Tab 5",
				url: URL(string: "https://capturecontext.dev/5")!
			)
			state.sidebar.organization.spaces[id: space]?.selectedTabID = tab(5)
			state.viewer.panes = [.init(id: UUID(999), item: .init(tab: state.sidebar.organization.tabs[id: tab(5)]))]
		}
		await store.send(.sidebar(.ui(.sidebar(.selectOnPress(item(3))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewerDropRefusal(tab(3), edge: .leading), nil)
		await store.send(.ui(.dropTabInViewer(tab(3), .leading)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(3), tab(5)])
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(3), tab(5)]])
		expectNoDifference(store.state.sidebar.organization.location(of: tab(3)), .pinned(space, folder: nil))
		expectNoDifference(store.state.viewer.item.tab?.id, tab(3))
		await store.finish()
	}

	/// A pinned tab and an open one can share the page without a group. A tab pressed there takes
	/// the open tab's pane, and dropped on the page it joins both, grouped with the open tab, the
	/// one in its own list (DEV-1006).
	@Test
	internal func aPressedTabJoinsAPageSharedWithAPinnedTab() async throws {
		let store = makeStore { state in
			state.sidebar.organization.spaces[id: space]?.unpinnedTabs.removeAll { $0 == tab(5) }
			state.sidebar.organization.spaces[id: space]?.savedItems = [.tab(tab(5))]
			state.sidebar.organization.tabs[id: tab(5)]?.savedDestination = .init(
				title: "Tab 5",
				url: URL(string: "https://capturecontext.dev/5")!
			)
			let pinned = state.sidebar.organization.tabs[id: tab(5)]
			let open = state.sidebar.organization.tabs[id: tab(1)]
			state.viewer.panes = [
				.init(id: UUID(998), item: .init(tab: pinned)),
				.init(id: UUID(999), item: .init(tab: open)),
			]
			state.viewer.fractions = SplitLayout.equal(2)
		}
		await store.send(.sidebar(.ui(.sidebar(.selectOnPress(item(3))))))
		await store.skipReceivedActions()
		await store.send(.ui(.dropTabInViewer(tab(3), .trailing)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(5), tab(1), tab(3)])
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(3)]])
		await store.finish()
	}

	/// A chat tab pressed while another page shows splits with that page, not the one the chat
	/// first opened over.
	@Test
	internal func aPressOutranksTheChatsOlderPage() async throws {
		let store = makeStore()
		await store.send(.ui(.openChatTab(.init(conversationID: UUID(7)), title: "Chat")))
		await store.skipReceivedActions()
		let chat = try #require(store.state.sidebar.organization.tabs.first { $0.isChat })
		await store.send(.sidebar(.ui(.sidebar(.select(item(2))))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.sidebar(.selectOnPress(.tab(chat.id.rawValue))))))
		await store.skipReceivedActions()
		await store.send(.ui(.dropTabInViewer(chat.id, .trailing)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(2), chat.id])
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(2), chat.id]])
		await store.finish()
	}

	// MARK: - Fixture

	private var space: Space.ID { .init(rawValue: UUID(1)) }

	private func tab(_ index: Int) -> BrowserCore.Tab.ID { .init(rawValue: UUID(100 + index)) }

	private func item(_ index: Int) -> SidebarItem.ID { .tab(tab(index).rawValue) }

	private func groupID(_ store: TestStoreOf<MainFeature>) -> UUID {
		store.state.sidebar.organization.splits.first?.id.rawValue ?? UUID(0)
	}

	/// `uuidStart` keeps a second store's new identities clear of ones copied from the first.
	private func makeStore(
		uuidStart: Int = 0,
		_ configure: (inout MainFeature.State) -> Void = { _ in }
	) -> TestStoreOf<MainFeature> {
		let profile = Profile.ID(rawValue: UUID(0))
		let tabs: [BrowserCore.Tab] = (1 ... 5).map { index in
			.init(
				id: tab(index),
				profileID: profile,
				restoration: .init(title: "Tab \(index)", url: URL(string: "https://capturecontext.dev/\(index)")!)
			)
		}
		let organization = BrowserOrganization(
			profiles: [.init(id: profile, name: "Default")],
			spaces: [.init(
				id: space,
				profileID: profile,
				name: "Work",
				unpinnedTabs: tabs.map(\.id),
				selectedTabID: tabs[0].id
			)],
			tabs: tabs
		)
		var state = MainFeature.State(organization: organization, spaceID: space)

		// Away from the incrementing identities new panes and groups receive.
		state.viewer.panes = [.init(id: UUID(999), item: .init(tab: tabs[0]))]
		state.viewer.activePaneID = UUID(999)
		configure(&state)
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			let next = LockIsolated(uuidStart)
			$0.uuid = .init {
				next.withValue { value in
					defer { value += 1 }
					return UUID(value)
				}
			}
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.close = { _ in }
			$0.date = .constant(Date(timeIntervalSince1970: 0))
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}
