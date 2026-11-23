import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func savedOnlySelectionDoesNotArchiveTheUnrelatedActiveTab() async throws {
		var organization = fixture()
		let active = organization.tabs[0]
		let saved = organization.tabs[1]
		try organization.move(.tab(saved.id.rawValue), to: .savedRoot, in: organization.spaces[0].id)
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.viewer.item.tab = active
		state.sidebar.moveSelection = [.tab(saved.id.rawValue)]
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.browserEngine.close = { closed.append($0) }
		}

		#expect(!BrowserCommand.archiveSelectedTabs.isEnabled(in: store.state.commandContext))
		await store.send(.ui(.paneCommand(.archiveSelectedTabs, state.viewer.activePaneID)))
		await store.send(.ui(.archiveSelectedTabs([])))
		await store.finish()
		expectNoDifference(closed, [])
	}

	@Test
	internal func selectedArchiveCancellationPreservesTheWholeSelection() async throws {
		let organization = fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.sidebar.moveSelection = organization.tabs.reversed().map { .tab($0.id.rawValue) }
		var closed: [BrowserCore.Tab.ID] = []
		var requested: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.permitsClosing = { id in
				requested.append(id)
				return id != organization.tabs[1].id
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.archiveSelectedTabs([])))
		await store.receive(\.event.archiveFailed)
		await store.finish()

		expectNoDifference(requested, organization.tabs.map(\.id))
		expectNoDifference(closed, [])
		expectNoDifference(store.state.sidebar.organization, organization)
		expectNoDifference(store.state.sidebar.moveSelection, state.sidebar.moveSelection)
	}

	@Test
	internal func archiveCommandUsesSelectedUnpinnedTabsBeforeTheActivePin() async throws {
		var organization = fixture()
		let selected = Array(organization.tabs)
		var pin = selected[0]
		pin = .init(
			id: .init(rawValue: UUID(30)),
			profileID: pin.profileID,
			savedDestination: .init(title: "Saved", url: pin.restoration.url),
			restoration: pin.restoration
		)
		organization.tabs.append(pin)
		organization.spaces[0].savedItems.append(.tab(pin.id))
		organization.spaces[0].selectedTabID = pin.id
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.viewer.item.tab = pin
		state.sidebar.moveSelection = [.tab(selected[1].id.rawValue), .tab(pin.id.rawValue), .tab(selected[0].id.rawValue)]
		let paneID = state.viewer.activePaneID
		var requested: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.permitsClosing = { id in
				requested.append(id)
				return true
			}
			$0.browserEngine.close = { id in
				closed.append(id)
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		#expect(BrowserCommand.archiveSelectedTabs.isEnabled(in: store.state.commandContext))
		await store.send(.ui(.paneCommand(.archiveSelectedTabs, paneID)))
		await store.receive(\.ui.archiveSelectedTabs)
		await store.receive(\.event.archiveApproved)
		expectNoDifference(store.state.sidebar.organization, organization)
		await store.receive(\.event.archiveClosed)
		await store.finish()

		expectNoDifference(requested, selected.map(\.id))
		expectNoDifference(closed, selected.map(\.id))
		expectNoDifference(store.state.sidebar.organization.archive.map(\.tab), selected)
		expectNoDifference(store.state.sidebar.organization.tabs, [pin])
		expectNoDifference(store.state.sidebar.moveSelection, [.tab(pin.id.rawValue)])
	}
}
