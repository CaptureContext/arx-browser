@testable import AppFeature
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import Testing
import ViewerFeature
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct SplitPresentationTests {
	@Test
	internal func restoredPaneRejectsNavigationFromItsPreviousObservation() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let tab = organization.tabs[0]
		var initial = ViewerFeature.State(item: .init(tab: tab, generation: 1))
		initial.spaceID = organization.spaces[0].id
		let paneID = initial.activePaneID
		let original = try #require(initial.currentPresentation)
		let other = BrowserSpacePresentation(
			id: organization.spaces[1].id,
			panes: [.init(id: UUID(90), tabID: nil)],
			activePaneID: UUID(90)
		)
		initial.apply(other, tabs: organization.tabs)
		initial.apply(original, tabs: organization.tabs)
		let store = TestStore(initialState: initial) { ViewerFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		await store.send(.resume)
		await store.receive(\.panes) {
			$0.item.generation = 4
			$0.item.isObserving = true
			$0.observationGeneration = 4
		}
		let restored = store.state
		await store.send(.panes(.element(
			id: paneID,
			action: .item(.event(.navigation(tab.id, 1, .init(title: "Obsolete document"))))
		)))
		expectNoDifference(store.state, restored)
		let current = BrowserNavigation(title: "Current document")
		await store.send(.panes(.element(
			id: paneID,
			action: .item(.event(.navigation(tab.id, restored.item.generation, current)))
		))) {
			$0.item.navigation = current
		}
		await store.receive(\.panes)
		await store.finish()
	}

	@Test
	internal func repeatedSplitRestorationRetainsEveryPreviousObservationGeneration() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = ViewerFeature.State(item: .init(tab: organization.tabs[0], generation: 5))
		let firstID = state.activePaneID
		let secondID = UUID(91)
		state.panes.append(.init(id: secondID, item: .init(tab: organization.tabs[1], generation: 9)))
		state.spaceID = organization.spaces[0].id
		let original = try #require(state.currentPresentation)
		let other = BrowserSpacePresentation(
			id: organization.spaces[1].id,
			panes: [.init(id: UUID(90), tabID: nil)],
			activePaneID: UUID(90)
		)
		for expected in [11, 13, 15] {
			let left = state.apply(other, tabs: organization.tabs)
			let returned = state.apply(original, tabs: organization.tabs)
			#expect(left)
			#expect(returned)
			expectNoDifference(state.observationGeneration, expected)
			expectNoDifference(state.panes.map(\.item.generation), [expected, expected])
		}
		let store = TestStore(initialState: state) { ViewerFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.resume)
		await store.receive(\.panes)
		await store.receive(\.panes)
		expectNoDifference(Set(store.state.panes.map(\.item.generation)), [16, 17])
		let restored = store.state
		for (id, tab, generation) in [(firstID, organization.tabs[0], 5), (secondID, organization.tabs[1], 9)] {
			await store.send(.panes(.element(
				id: id,
				action: .item(.event(.navigation(tab.id, generation, .init(title: "Obsolete"))))
			)))
		}
		expectNoDifference(store.state, restored)
		await store.finish()
	}

	@Test
	internal func observationGenerationExhaustionCannotRestoreOrStartAnotherObservation() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = ViewerFeature.State(item: .init(tab: organization.tabs[0], generation: Int.max))
		state.spaceID = organization.spaces[0].id
		let presentation = try #require(state.currentPresentation)
		let unchanged = state
		let applied = state.apply(presentation, tabs: organization.tabs)
		#expect(!applied)
		expectNoDifference(state, unchanged)
		let store = TestStore(initialState: state) { ViewerFeature() }
		await store.send(.item(.show(organization.tabs[1])))
		await store.send(.suspend)
		await store.receive(\.panes) { $0.item.tab = nil }
		await store.send(.panes(.element(
			id: state.activePaneID,
			action: .item(.event(.navigation(organization.tabs[0].id, Int.max, .init(title: "Obsolete"))))
		)))
		await store.send(.item(.show(nil)))
		await store.finish()
	}

	@Test
	internal func exhaustedItemCanBeClearedWithoutAcceptingQueuedEvents() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let source = organization.tabs[0]
		let store = TestStore(initialState: ViewerItemFeature.State(tab: source, generation: Int.max)) {
			ViewerItemFeature()
		}
		await store.send(.show(organization.tabs[1]))
		await store.send(.show(nil)) { $0.tab = nil }
		await store.send(.event(.navigation(source.id, Int.max, .init(title: "Obsolete"))))
		await store.send(.suspend)
		await store.finish()
	}

	@Test(arguments: [1, 2])
	internal func restoringNearExhaustionReservesEveryPaneBeforeReplacingLayout(_ count: Int) async throws {
		let organization = IntegrationFeatureTests().fixture()
		let panes = Array(organization.tabs.prefix(count).enumerated()).map { index, tab in
			BrowserPanePlacement(id: UUID(90 + index), tabID: tab.id)
		}
		let presentation = BrowserSpacePresentation(
			id: organization.spaces[0].id,
			panes: panes,
			activePaneID: panes[0].id
		)
		var insufficient = ViewerFeature.State(item: .init(generation: Int.max - count))
		let unchanged = insufficient
		let refused = insufficient.apply(presentation, tabs: organization.tabs)
		#expect(!refused)
		expectNoDifference(insufficient, unchanged)

		var sufficient = ViewerFeature.State(item: .init(generation: Int.max - count - 1))
		let admitted = sufficient.apply(presentation, tabs: organization.tabs)
		#expect(admitted)
		var opened: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: sufficient) { ViewerFeature() } withDependencies: {
			$0.browserEngine.open = { opened.append($0.id) }
			$0.browserEngine.events = { _ in .finished }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.resume)
		for _ in panes { await store.receive(\.panes) }
		await store.finish()
		expectNoDifference(Set(opened), Set(panes.compactMap(\.tabID)))
		expectNoDifference(store.state.observationGeneration, Int.max)
		expectNoDifference(Set(store.state.panes.map(\.item.generation)).count, count)
	}

	@Test
	internal func restartRestoresPaneIdentitiesFocusAndSizeWithoutDuplicatingHosts() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let mainID = UUID(0)
		let firstID = UUID(31)
		let secondID = UUID(32)
		let layout = BrowserSpacePresentation(
			id: organization.spaces[0].id,
			panes: [
				.init(id: firstID, tabID: organization.tabs[0].id),
				.init(id: secondID, tabID: organization.tabs[1].id),
			],
			activePaneID: secondID,
			orientation: .vertical,
			fractions: [0.65, 0.35]
		)
		let preferences = BrowserPreferences(windowPresentations: [
			.init(id: mainID, activeSpaceID: layout.id, spaces: [layout]),
			.init(id: UUID(40), activeSpaceID: layout.id, spaces: [layout]),
		])
		let encoded = try JSONEncoder().encode(preferences)
		let restored = try JSONDecoder().decode(BrowserPreferences.self, from: encoded)
		let state = AppFeature.State.launching(
			main: .init(organization: organization, spaceID: layout.id, id: mainID),
			preferences: restored
		)
		expectNoDifference(state.main.viewer.currentPresentation, layout)
		expectNoDifference(state.main.sidebar.selectedTab?.id, organization.tabs[1].id)
		expectNoDifference(state.windows[id: UUID(40)]?.viewer.panes.compactMap { $0.item.tab?.id }, [])
		#expect(state.main.viewer.preservesPresentation)
	}

	@Test
	internal func missingAndMovedTabsCollapseGracefullyAndLegacyPreferencesStillDecode() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let layout = BrowserSpacePresentation(
			id: organization.spaces[1].id,
			panes: [
				.init(id: UUID(31), tabID: organization.tabs[0].id),
				.init(id: UUID(32), tabID: .init(rawValue: UUID(99))),
			],
			activePaneID: UUID(32),
			fractions: [.infinity, 0.5]
		)
		let valid = try #require(layout.sanitized(in: organization))
		expectNoDifference(valid.panes, [.init(id: UUID(31), tabID: nil)])
		expectNoDifference(valid.activePaneID, UUID(31))
		expectNoDifference(valid.fractions, [1])
		let data = try JSONEncoder().encode(BrowserPreferences())
		var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		object.removeValue(forKey: "windowPresentations")
		let legacy = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: object)
		)
		expectNoDifference(legacy.windowPresentations, [])
	}

	@Test
	internal func closeRequestPreservesSavedLayoutUntilWindowIsRemoved() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let id = UUID(40)
		let layout = BrowserSpacePresentation(
			id: organization.spaces[0].id,
			panes: [.init(id: UUID(31), tabID: organization.tabs[0].id)],
			activePaneID: UUID(31)
		)
		let preferences = BrowserPreferences(windowPresentations: [
			.init(id: id, activeSpaceID: layout.id, spaces: [layout]),
		])
		let initial = AppFeature.State.launching(
			main: .init(organization: organization, spaceID: layout.id),
			preferences: preferences
		)
		let persistence = TestStore(initialState: initial) { WindowPresentationPersistence() }

		// A beforeunload decision can keep the window alive after this request.
		await persistence.send(.ui(.closeAdditionalWindow(id)))
		await persistence.send(.event(.additionalWindowClosed(id)))
		expectNoDifference(persistence.state.windowLayout.windowPresentations, preferences.windowPresentations)
		await persistence.finish()

		let store = TestStore(initialState: initial) { AppFeature() }
		await store.send(.ui(.closeAdditionalWindow(id))) {
			let closed = try #require($0.windows[id: id])
			$0.windows.remove(id: id)

			// Shared state: the close event runs inside this send.
			$0.$windowLayout.withLock { $0.windowPresentations = [] }

			// Reopen Closed Window can bring it back (DEV-908).
			$0.recentlyClosedWindows = [.init(
				id: id,
				spaceID: closed.sidebar.spaceID,
				tabID: closed.viewer.item.tab?.id,
				isMain: false
			)]
			$0.main.canReopenClosedWindow = true
		}
		await store.receive(\.event.additionalWindowClosed) {
			$0.unsavedOrganization = organization
		}
		await store.receive(\.delegate.save)
		await store.finish()
	}

	@Test
	internal func resizePersistsOnlyAtEndAndPrivatePresentationNeverSaves() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = organization.tabs[0]

		// An empty second pane: a split to resize, with no second tab to make a group of.
		main.viewer.panes.append(.init(id: UUID(20)))
		main.viewer.fractions = [0.5, 0.5]
		main.viewer.preservesPresentation = true
		let store = TestStore(initialState: AppFeature.State(main: main)) { AppFeature() }
		await store.send(.main(.viewer(.ui(.resize([0.7, 0.3]))))) { $0.main.viewer.fractions = [0.7, 0.3] }
		expectNoDifference(store.state.windowLayout.windowPresentations, [])
		await store.send(.main(.viewer(.ui(.resizeEnded)))) {
			// Shared state: the presentation change runs inside this send.
			let presentations = $0.main.viewer.allPresentations
			$0.$windowLayout.withLock {
				$0.windowPresentations = [
					.init(
						id: main.id,
						activeSpaceID: main.sidebar.spaceID,
						spaces: presentations,
						sidebarWidth: main.sidebarWidth,
						chatWidth: main.chatWidth
					),
				]
			}
		}
		await store.receive(\.main.delegate.presentationChanged) {
			$0.unsavedOrganization = organization
		}
		await store.receive(\.delegate.save)
		await store.finish()

		var privateOrganization = organization
		privateOrganization.spaces[0].selectedTabID = nil
		var state = AppFeature.State(main: .init(
			organization: privateOrganization,
			spaceID: privateOrganization.spaces[0].id
		))
		let id = UUID(50)
		state.windows.append(.init(
			organization: privateOrganization,
			spaceID: privateOrganization.spaces[0].id,
			isPrivate: true,
			id: id
		))
		let saved = state.windowLayout.windowPresentations
		let privateStore = TestStore(initialState: state) { AppFeature() }
		await privateStore.send(.windows(.element(id: id, action: .delegate(.presentationChanged))))
		expectNoDifference(privateStore.state.windowLayout.windowPresentations, saved)
		await privateStore.finish()
	}

	@Test
	internal func switchingSpacesStoresOriginalLayoutAndRejectsSupersededRestore() async throws {
		var organization = IntegrationFeatureTests().fixture()
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(99)),
			profileID: organization.spaces[1].profileID,
			restoration: .init(title: "Other space", url: URL(string: "https://other.example")!)
		)
		organization.tabs.append(tab)
		organization.spaces[1].unpinnedTabs.append(tab.id)
		var initial = ViewerFeature.State(item: .init(tab: organization.tabs[0]))
		initial.spaceID = organization.spaces[0].id
		initial.requestedSpaceID = organization.spaces[1].id
		initial.preservesPresentation = true
		initial.panes.append(.init(id: UUID(32), item: .init(tab: organization.tabs[1])))
		initial.orientation = .vertical
		initial.fractions = [0.65, 0.35]
		let outgoing = try #require(initial.currentPresentation)
		let destination = organization.spaces[1].id
		let store = TestStore(initialState: initial) { ViewerFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		await store.send(.selectSpace(organization.spaces[0].id, organization, selected: organization.tabs[0]))
		await store.send(.selectSpace(destination, organization, selected: tab)) {
			$0.presentations = [outgoing]
			$0.panes = [
				.init(
					id: destination.rawValue,
					item: .init(
						tab: tab,
						navigation: .init(url: tab.restoration.url, title: tab.restoration.title),
						generation: 1
					)
				),
			]
			$0.observationGeneration = 1
			$0.activePaneID = destination.rawValue
			$0.spaceID = destination
			$0.orientation = .horizontal
			$0.fractions = [1]
		}
		await store.receive(\.resume)
		await store.receive(\.panes) {
			$0.item.generation = 2
			$0.item.isObserving = true
			$0.observationGeneration = 2
		}
		await store.finish()
		expectNoDifference(store.state.presentations.first, outgoing)
	}

	@Test
	internal func programmaticPresentationChangesSpaceAndRestoresItsPreviousSplit() async throws {
		var organization = IntegrationFeatureTests().fixture()
		let otherTab = BrowserCore.Tab(
			id: .init(rawValue: UUID(99)),
			profileID: organization.spaces[1].profileID,
			restoration: .init(title: "Other", url: URL(string: "https://other.example")!)
		)
		organization.tabs.append(otherTab)
		organization.spaces[1].unpinnedTabs.append(otherTab.id)
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = organization.tabs[0]
		main.viewer.panes.append(.init(id: UUID(32), item: .init(tab: organization.tabs[1])))
		main.viewer.orientation = .vertical
		main.viewer.fractions = [0.65, 0.35]
		main.viewer.preservesPresentation = true
		let original = main.viewer.currentPresentation
		let store = Store(initialState: AppFeature.State(main: main)) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		await store.send(.main(.present(otherTab.id, in: main.viewer.activePaneID))).finish()
		expectNoDifference(store.main.sidebar.spaceID, organization.spaces[1].id)
		expectNoDifference(store.main.viewer.panes.compactMap { $0.item.tab?.id }, [otherTab.id])
		await store.send(.main(.sidebar(.ui(.spaceSelected(organization.spaces[0].id))))).finish()
		expectNoDifference(store.main.viewer.currentPresentation, original)
		let before = store.state
		await store.send(.main(.present(otherTab.id, in: UUID(100)))).finish()
		expectNoDifference(store.state, before)
	}

	@Test
	internal func reopeningWindowDoesNotReclaimTabHostedElsewhere() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = organization.tabs[0]
		main.viewer.panes.append(.init(id: UUID(32), item: .init(tab: organization.tabs[1])))
		main.viewer.preservesPresentation = true
		var initial = AppFeature.State(main: main, windowIsOpen: false)
		var other = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id, id: UUID(40))
		other.viewer.item.tab = organization.tabs[0]
		initial.windows.append(other)
		var opened: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { opened.append($0.id) }
			$0.browserEngine.events = { _ in .finished }
		}
		await store.send(.ui(.openWindow)).finish()
		expectNoDifference(store.main.viewer.panes.compactMap { $0.item.tab?.id }, [organization.tabs[1].id])
		expectNoDifference(store.windows[id: UUID(40)]?.viewer.item.tab?.id, organization.tabs[0].id)
		expectNoDifference(opened, [organization.tabs[1].id])
	}
}
