import AppFeature
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test(arguments: ["original", "chosen", "reopenLast"])
	internal func archiveRestorationSelectsFreshTabInPreviouslyVisitedSplit(_ route: String) async throws {
		let initial = try archivePresentationFixture(useChosenDestination: route == "chosen")
		let organization = initial.workspace
		let destination = organization.spaces[1].id
		let groupID = try #require(organization.archive.first?.groupID)
		let layout = try #require(initial.main.viewer.presentations.first)
		let archived = organization.archive.map(\.tab)
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		if route == "reopenLast" {
			await store.send(.main(.ui(.reopenLastClosedTab))).finish()
		} else {
			await store.send(.main(.ui(.openArchive))).finish()
			let target = route == "chosen" ? ArchiveDestination(space: organization.spaces[1]) : nil
			await store.send(.main(.archive(.ui(.restoreGroup(groupID, target))))).finish()
		}
		let restored = store.main.sidebar.organization.tabs.filter { tab in !organization.tabs.ids.contains(tab.id) }
		expectNoDifference(restored.map(\.restoration), archived.map(\.restoration))
		let first = try #require(restored.first)
		#expect(Set(restored.map(\.id)).isDisjoint(with: archived.map(\.id)))
		expectNoDifference(store.main.sidebar.spaceID, destination)
		expectNoDifference(store.main.sidebar.selectedTab?.id, first.id)
		expectNoDifference(store.main.viewer.item.tab?.id, first.id)
		var expected = layout
		expected.panes[0].tabID = first.id
		expectNoDifference(store.main.viewer.currentPresentation, expected)
		expectNoDifference(store.main.sidebar.organization.archive, [])
		#expect(store.main.sidebar.organization.tabs[id: layout.panes[0].tabID] != nil)
		try store.main.sidebar.organization.validate()
	}

	@Test
	internal func archiveSynchronizationPreservesSelectionMadeAfterRestoreCommits() async throws {
		let initial = try archivePresentationFixture()
		let previous = initial.workspace
		var next = 100
		let updated = try previous.restoringArchive(previous.archive.map(\.id), uuid: {
			defer { next += 1 }
			return UUID(next)
		})
		let opened = Array(updated.tabs.filter { !previous.tabs.ids.contains($0.id) })
		let selected = previous.tabs[1]
		var delayed: BrowserCore.Tab.ID?
		var holdsSynchronization = true
		let store = Store(initialState: initial) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if holdsSynchronization, case let .main(.synchronizeSelecting(id)) = action {
					delayed = id
					return .none
				}
				return AppFeature()._reduce(into: &state, action: action)
			}
		} withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		await store.send(.main(.event(.archiveRestored(previous, updated, opened)))).finish()
		expectNoDifference(store.main.sidebar.selectedTab?.id, opened.first?.id)
		let pendingID = try #require(delayed)

		// Model a user selection delivered before the restore's queued synchronization.
		await store.send(.main(.present(selected.id, in: initial.main.viewer.activePaneID))).finish()
		holdsSynchronization = false
		await store.send(.main(.synchronizeSelecting(pendingID))).finish()
		expectNoDifference(store.main.sidebar.selectedTab?.id, selected.id)
		expectNoDifference(store.main.viewer.item.tab?.id, selected.id)
		expectNoDifference(store.main.viewer.spaceID, previous.spaces[0].id)
		expectNoDifference(store.main.sidebar.organization.archive, [])
		#expect(opened.allSatisfy { tab in store.main.sidebar.organization.tabs.ids.contains(tab.id) })
	}

	private func archivePresentationFixture(useChosenDestination: Bool = false) throws -> AppFeature.State {
		var organization = fixture()
		let profile = organization.profiles[0].id
		let target = organization.spaces[1].id
		let tabs: [BrowserCore.Tab] = (20...23).map { value in
			.init(
				id: .init(rawValue: UUID(value)),
				profileID: profile,
				restoration: .init(title: "Archive page \(value)", url: URL(string: "https://capturecontext.dev/\(value)")!)
			)
		}
		organization.tabs += tabs
		organization.spaces[1].unpinnedTabs += tabs.prefix(2).map(\.id)
		organization.spaces[useChosenDestination ? 0 : 1].unpinnedTabs += tabs.suffix(2).map(\.id)
		var next = 50
		let entries = organization.archiveEntries(
			for: tabs.suffix(2).map(\.id),
			closedAt: .init(timeIntervalSince1970: 100),
			groupID: UUID(40),
			uuid: {
				defer { next += 1 }
				return UUID(next)
			}
		)
		try organization.archiveClosedTabs(entries)
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = organization.tabs[0]
		main.viewer.preservesPresentation = true
		main.viewer.presentations = [.init(
			id: target,
			panes: [.init(id: UUID(30), tabID: tabs[0].id), .init(id: UUID(31), tabID: tabs[1].id)],
			activePaneID: UUID(30),
			orientation: .vertical,
			fractions: [0.65, 0.35]
		)]
		return .init(main: main)
	}
}
