import AppFeature
import BrowserCore
import BrowserEngineClient
import CommandBarFeature
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct CommandBarCollectionTests {
	@Test
	internal func largeCollectionKeepsResultOrderAndFindsATabBeyondTheInitialResults() async throws {
		let fixture = CollectionFixture(catalogCount: 2_048)
		var opened: [BrowserCore.Tab] = []
		let store = makeStore(fixture) { opened.append($0) }

		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		let candidateIDs = store.main.commandBar.candidates.map(\.presentation.id)
		expectNoDifference(Set(candidateIDs).count, candidateIDs.count)
		await store.send(.main(.commandBar(.ui(.queryChanged("Catalog item"))))).finish()
		let firstResults = tabEntries(in: store.main.commandBar)
		expectNoDifference(firstResults.map(\.intent), fixture.catalog.prefix(30).map { .selectTab($0.id) })

		let highlighted = firstResults[12].presentation.id
		await store.send(.main(.commandBar(.ui(.highlighted(highlighted))))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged("catalog ITEM"))))).finish()
		expectNoDifference(store.main.commandBar.selectedID, highlighted)
		expectNoDifference(tabEntries(in: store.main.commandBar), firstResults)

		await store.send(.main(.commandBar(.ui(.dismissed)))).finish()
		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		expectNoDifference(store.main.commandBar.candidates.map(\.presentation.id), candidateIDs)
		await store.send(.main(.commandBar(.ui(.queryChanged("Catalog item"))))).finish()
		expectNoDifference(tabEntries(in: store.main.commandBar), firstResults)

		let last = try #require(fixture.catalog.last)
		await store.send(.main(.commandBar(.ui(.queryChanged(last.displayTitle))))).finish()
		let result = try #require(tabEntries(in: store.main.commandBar).only)
		expectNoDifference(result.intent, .selectTab(last.id))
		await store.send(.main(.commandBar(.ui(.selected(result.presentation.id))))).finish()
		expectNoDifference(opened, [last])
		expectNoDifference(store.main.sidebar.selectedTab?.id, last.id)
		expectNoDifference(store.main.viewer.item.tab?.id, last.id)
		expectNoDifference(store.workspace.tabs, fixture.organization.tabs)
	}

	@Test(arguments: [0, 1, 2])
	internal func duplicateTitlesAndURLsSelectTheExactExistingTab(_ duplicateIndex: Int) async throws {
		let fixture = CollectionFixture()
		var opened: [BrowserCore.Tab] = []
		let store = makeStore(fixture) { opened.append($0) }
		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged("Shared reference"))))).finish()

		let results = tabEntries(in: store.main.commandBar)
		let expected = fixture.duplicates.prefix(3)
		expectNoDifference(results.map(\.intent), expected.map { .selectTab($0.id) })
		expectNoDifference(Set(results.map(\.presentation.id)).count, 3)
		for (index, result) in results.enumerated() {
			let space = fixture.organization.spaces[index == 2 ? 1 : 0]
			expectNoDifference(result.destination, .tab(fixture.work.id, .unpinned(space.id)))
			#expect(result.presentation.subtitle.contains(space.name) == (space.id != store.main.sidebar.spaceID))
			#expect(!result.presentation.subtitle.contains(fixture.work.name))
			#expect(result.presentation.subtitle.contains(fixture.sharedURL.absoluteString))
		}

		let selected = fixture.duplicates[duplicateIndex]
		await store.send(.main(.commandBar(.ui(.selected(results[duplicateIndex].presentation.id))))).finish()
		expectNoDifference(opened, [selected])
		expectNoDifference(store.main.viewer.item.tab, selected)
		expectNoDifference(store.main.sidebar.selectedTab?.id, selected.id)
		let destination = fixture.organization.spaces[duplicateIndex == 2 ? 1 : 0].id
		expectNoDifference(store.main.sidebar.spaceID, destination)
		expectNoDifference(store.workspace.tabs, fixture.organization.tabs)
	}

	@Test
	internal func duplicateInAnotherProfileRequiresTheExplicitLabeledSpaceResult() async throws {
		let fixture = CollectionFixture()
		var opened: [BrowserCore.Tab] = []
		let store = makeStore(fixture) { opened.append($0) }
		await store.send(.main(.ui(.openCommand(.commands)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged("Projects"))))).finish()
		let spaces = store.main.commandBar.entries.filter {
			if case .selectSpace = $0.intent { return true }
			return false
		}
		expectNoDifference(spaces.map(\.intent), [
			.selectSpace(fixture.organization.spaces[0].id),
			.selectSpace(fixture.organization.spaces[2].id)
		])
		expectNoDifference(spaces.map(\.presentation.subtitle), [fixture.work.name, fixture.personal.name])
		#expect(spaces[0].presentation.id != spaces[1].presentation.id)
		expectNoDifference(spaces[1].destination, .space(fixture.personal.id))

		await store.send(.main(.commandBar(.ui(.selected(spaces[1].presentation.id))))).finish()
		expectNoDifference(store.main.sidebar.space.profileID, fixture.personal.id)
		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged("Shared reference"))))).finish()
		let result = try #require(tabEntries(in: store.main.commandBar).only)
		let personalTab = fixture.duplicates[3]
		expectNoDifference(result.intent, .selectTab(personalTab.id))
		expectNoDifference(
			result.destination,
			.tab(fixture.personal.id, .unpinned(fixture.organization.spaces[2].id))
		)
		await store.send(.main(.commandBar(.ui(.selected(result.presentation.id))))).finish()
		expectNoDifference(opened, [personalTab])
		expectNoDifference(store.main.viewer.item.tab, personalTab)
		expectNoDifference(store.workspace.tabs, fixture.organization.tabs)
	}

	@Test
	internal func backgroundOrganizationChangesDoNotReplaceTheHighlightedDuplicate() async throws {
		let fixture = CollectionFixture(catalogCount: 64)
		var opened: [BrowserCore.Tab] = []
		let store = makeStore(fixture) { opened.append($0) }
		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged("Shared reference"))))).finish()
		let result = try #require(tabEntries(in: store.main.commandBar).first {
			$0.intent == .selectTab(fixture.duplicates[1].id)
		})
		await store.send(.main(.commandBar(.ui(.highlighted(result.presentation.id))))).finish()
		let presented = store.main.commandBar

		var changed = fixture.organization
		let newcomer = BrowserCore.Tab(
			id: .init(rawValue: UUID(90)),
			profileID: fixture.work.id,
			restoration: fixture.duplicates[0].restoration
		)
		changed.tabs.insert(newcomer, at: 0)
		changed.spaces[0].unpinnedTabs.insert(newcomer.id, at: 0)
		let catalogIndex = try #require(changed.tabs.index(id: fixture.catalog[0].id))
		changed.tabs[catalogIndex].restoration.title = "Shared reference"
		await store.send(.event(.organizationChangeApproved(fixture.organization, changed, []))).finish()
		expectNoDifference(store.main.commandBar, presented)
		#expect(store.main.commandCandidates.contains { $0.intent == .selectTab(newcomer.id) })

		let selected = try #require(store.main.commandBar.selectedID)
		await store.send(.main(.commandBar(.ui(.selected(selected))))).finish()
		expectNoDifference(opened, [fixture.duplicates[1]])
		expectNoDifference(store.main.viewer.item.tab?.id, fixture.duplicates[1].id)
		expectNoDifference(store.workspace.tabs, changed.tabs)
	}

	@Test(arguments: ["removed", "replaced", "moved"])
	internal func queuedDuplicateSelectionNeverExecutesASubstitute(_ change: String) async throws {
		let fixture = CollectionFixture()
		let selected = fixture.duplicates[1]
		var delayed: CommandBarFeature.Execution?
		var holdsExecution: Bool = true
		var opened: [BrowserCore.Tab] = []
		let store = Store(initialState: fixture.app) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				guard
					holdsExecution,
					case let .main(.commandBar(.delegate(.execute(execution)))) = action
				else { return AppFeature()._reduce(into: &state, action: action) }
				delayed = execution
				return .none
			}
		} withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { opened.append($0) }
			$0.browserEngine.events = { _ in .finished }
		}
		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged("Shared reference"))))).finish()
		let result = try #require(tabEntries(in: store.main.commandBar).first { $0.intent == .selectTab(selected.id) })
		await store.send(.main(.commandBar(.ui(.selected(result.presentation.id))))).finish()
		let execution = try #require(delayed)

		var changed = fixture.organization
		switch change {
		case "moved":
			try changed.moveTab(.tab(selected.id.rawValue), toSpace: changed.spaces[1].id)

		default:
			changed.removeTab(selected.id)
			if change == "replaced" {
				let replacement = BrowserCore.Tab(
					id: .init(rawValue: UUID(90)),
					profileID: selected.profileID,
					restoration: selected.restoration
				)
				changed.tabs.append(replacement)
				changed.spaces[0].unpinnedTabs.append(replacement.id)
			}
		}
		try changed.validate()
		await store.send(.event(.organizationChangeApproved(fixture.organization, changed, []))).finish()
		let before = store.main
		holdsExecution = false
		await store.send(.main(.commandBar(.delegate(.execute(execution))))).finish()
		expectNoDifference(opened, [])
		expectNoDifference(store.main.viewer, before.viewer)
		expectNoDifference(store.main.sidebar, before.sidebar)
		expectNoDifference(store.workspace.tabs, changed.tabs)
	}

	@Test
	internal func selectionFromPreviousQueryDoesNotRunTheNewHighlightedResult() async throws {
		let fixture = CollectionFixture(catalogCount: 1)
		let candidates = fixture.app.main.commandCandidates
		let store = TestStore(initialState: CommandBarFeature.State(
			isPresented: true,
			query: "Shared reference",
			candidates: candidates
		)) { CommandBarFeature() }
		let old = try #require(tabEntries(in: store.state).first)
		let replacement = try #require(candidates.first { $0.intent == .selectTab(fixture.catalog[0].id) })
		await store.send(.ui(.highlighted(old.presentation.id))) {
			$0.selectedID = old.presentation.id
		}

		// The old highlight is gone, so the plain search for the new text leads (DEV-978).
		await store.send(.ui(.queryChanged("Catalog item"))) {
			$0.query = "Catalog item"
			$0.selectedID = "destination"
		}
		#expect(store.state.entries.contains { $0.presentation.id == replacement.presentation.id })
		await store.send(.ui(.selected(old.presentation.id)))
		#expect(store.state.isPresented)
		await store.finish()
	}

	/// DEV-1310: Switch to Space asks the sidebar to slide to the space first. Where it does,
	/// the reducer selects nothing; the sidebar reports the space once its slide lands. (Where
	/// it can't, the space is selected at once, as the test above finds.)
	@Test
	internal func switchToSpaceSlidesTheSidebarBeforeTheSpaceIsSelected() async throws {
		let fixture = CollectionFixture()
		var slides: [Int] = []
		let store = Store(initialState: fixture.app) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.sidebarSpaceSlide = .init { index in
				slides.append(index)
				return true
			}
		}
		let shown = store.main.sidebar.spaceID
		await store.send(.main(.ui(.openCommand(.commands)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged("Projects"))))).finish()
		let space = try #require(store.main.commandBar.entries.first {
			$0.intent == .selectSpace(fixture.organization.spaces[2].id)
		})

		await store.send(.main(.commandBar(.ui(.selected(space.presentation.id))))).finish()
		expectNoDifference(slides, [2])
		expectNoDifference(store.main.sidebar.spaceID, shown)

		// The sidebar's slide has landed.
		await store.send(.main(.sidebar(.ui(.spaceSelected(fixture.organization.spaces[2].id))))).finish()
		expectNoDifference(store.main.sidebar.spaceID, fixture.organization.spaces[2].id)
	}

	private func makeStore(
		_ fixture: CollectionFixture,
		open: @escaping @MainActor @Sendable (BrowserCore.Tab) -> Void
	) -> StoreOf<AppFeature> {
		Store(initialState: fixture.app) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { open($0) }
			$0.browserEngine.events = { _ in .finished }
		}
	}

	private func tabEntries(in state: CommandBarFeature.State) -> [CommandBarFeature.Entry] {
		state.entries.filter {
			if case .selectTab = $0.intent { return true }
			return false
		}
	}
}

internal struct CollectionFixture {
	let work: Profile
	let personal: Profile
	let source: BrowserCore.Tab
	let duplicates: [BrowserCore.Tab]
	let catalog: [BrowserCore.Tab]
	let sharedURL: URL
	let organization: BrowserOrganization

	init(catalogCount: Int = 0) {
		let work = Profile(id: .init(rawValue: UUID(1)), name: "Work account")
		let personal = Profile(id: .init(rawValue: UUID(2)), name: "Personal account")
		let sharedURL = URL(string: "https://reference.example/same-page")!
		let source = BrowserCore.Tab(
			id: .init(rawValue: UUID(100)),
			profileID: work.id,
			restoration: .init(title: "Source page", url: URL(string: "https://source.example")!)
		)
		let duplicates: [BrowserCore.Tab] = (0..<4).map { index in
			.init(
				id: .init(rawValue: UUID(101 + index)),
				profileID: index == 3 ? personal.id : work.id,
				restoration: .init(title: "Shared reference", url: sharedURL)
			)
		}
		let catalog: [BrowserCore.Tab] = (0..<catalogCount).map { index in
			.init(
				id: .init(rawValue: UUID(1_000 + index)),
				profileID: work.id,
				restoration: .init(
					title: "Catalog item \(index)",
					url: URL(string: "https://catalog.example/\(index)")!
				)
			)
		}

		var workTabIDs: [BrowserCore.Tab.ID] = [source.id]
		workTabIDs.append(contentsOf: duplicates.prefix(2).map(\.id))
		workTabIDs.append(contentsOf: catalog.map(\.id))
		let spaces: [Space] = [
			.init(
				id: .init(rawValue: UUID(10)),
				profileID: work.id,
				name: "Projects",
				unpinnedTabs: workTabIDs,
				selectedTabID: source.id
			),
			.init(
				id: .init(rawValue: UUID(11)),
				profileID: work.id,
				name: "Reference",
				unpinnedTabs: [duplicates[2].id],
				selectedTabID: duplicates[2].id
			),
			.init(
				id: .init(rawValue: UUID(12)),
				profileID: personal.id,
				name: "Projects",
				unpinnedTabs: [duplicates[3].id],
				selectedTabID: duplicates[3].id
			)
		]
		var tabs: [BrowserCore.Tab] = [source]
		tabs.append(contentsOf: duplicates)
		tabs.append(contentsOf: catalog)

		self.work = work
		self.personal = personal
		self.source = source
		self.duplicates = duplicates
		self.catalog = catalog
		self.sharedURL = sharedURL
		self.organization = .init(
			profiles: [work, personal],
			spaces: spaces,
			tabs: tabs
		)
	}

	@MainActor
	var app: AppFeature.State {
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = source
		return .init(main: main)
	}
}

private extension Array {
	var only: Element? { count == 1 ? first : nil }
}
