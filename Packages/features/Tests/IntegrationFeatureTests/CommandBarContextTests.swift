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

extension IntegrationFeatureTests {
	@Test
	internal func commandBarRejectsURLAfterOriginSpaceChangesProfile() async throws {
		var organization = commandContextFixture()
		organization.tabs = []
		organization.spaces[0].unpinnedTabs = []
		organization.spaces[0].selectedTabID = nil
		let source = organization.spaces[0]
		var opened: [BrowserCore.Tab] = []
		let initialState = AppFeature.State(main: .init(organization: organization, spaceID: source.id))
		let store = Store(initialState: initialState) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { opened.append($0) }
			$0.browserEngine.events = { _ in .finished }
		}
		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged("https://private-query.example"))))).finish()
		await store.send(.settings(.delegate(.changeOrganization(.updateSpace(
			source.id,
			profileID: organization.profiles[1].id,
			name: source.name,
			icon: .stack
		))))).finish()
		let before = store.workspace
		await store.send(.main(.commandBar(.ui(.selected("destination"))))).finish()
		expectNoDifference(store.workspace, before)
		expectNoDifference(opened, [])
	}

	@Test(arguments: ["space", "folder", "tab"])
	internal func commandBarRejectsChangedDisplayedDestination(_ destination: String) async throws {
		let organization = commandContextFixture()
		let source = organization.spaces[0].id
		let target = organization.spaces[1].id
		var main = MainFeature.State(organization: organization, spaceID: source)
		main.viewer.item.tab = organization.tabs[0]
		let store = Store(initialState: AppFeature.State(main: main)) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		await store.send(.main(.ui(.openCommand(.commands)))).finish()
		let resultID: String
		switch destination {
		case "space":
			resultID = target.rawValue.uuidString
			await store.send(.main(.commandBar(.ui(.queryChanged(organization.spaces[1].name))))).finish()
			await store.send(.settings(.delegate(.changeOrganization(.updateSpace(
				target,
				profileID: organization.profiles[1].id,
				name: organization.spaces[1].name,
				icon: .stack
			))))).finish()

		default:
			let item: SavedItem
			if destination == "folder" {
				item = .folder(organization.folders[0].id)
				resultID = organization.folders[0].id.rawValue.uuidString
				await store.send(.main(.commandBar(.ui(.queryChanged(organization.folders[0].name))))).finish()
			} else {
				item = .tab(organization.tabs[1].id)
				resultID = organization.tabs[1].id.rawValue.uuidString
				await store.send(.main(.commandBar(.ui(.queryChanged(organization.tabs[1].displayTitle))))).finish()
			}
			let moved = try organization.moving([item], to: .spaceRoot, in: target, newTabID: { .init(rawValue: UUID(90)) })
			await store.send(.event(.organizationChangeApproved(organization, moved.updated, []))).finish()
		}
		#expect(store.main.commandBar.entries.contains { $0.presentation.id == resultID })
		await store.send(.main(.commandBar(.ui(.selected(resultID))))).finish()
		expectNoDifference(store.main.sidebar.spaceID, source)
		expectNoDifference(store.main.sidebar.selectedTab?.id, organization.tabs[0].id)
		expectNoDifference(store.main.viewer.item.tab?.id, organization.tabs[0].id)
		if destination == "folder" { #expect(store.workspace.folders[0].isExpanded == false) }
	}

	@Test(arguments: ["dismiss", "reopen", "page", "generation"])
	internal func queuedCommandBarExecutionCannotOutliveItsPresentationOrSource(_ change: String) async throws {
		let organization = commandContextFixture()
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = organization.tabs[0]
		var delayed: CommandBarFeature.Execution?
		var holdsExecution = true
		var commands: [BrowserEngineClient.Command] = []
		let store = Store(initialState: AppFeature.State(main: main)) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if holdsExecution, case let .main(.commandBar(.delegate(.execute(value)))) = action {
					delayed = value
					return .none
				}
				return AppFeature()._reduce(into: &state, action: action)
			}
		} withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.command = { _, command in commands.append(command) }
		}
		await store.send(.main(.ui(.openCommand(.currentTab)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged("https://queued.example"))))).finish()
		await store.send(.main(.commandBar(.ui(.selected("destination"))))).finish()
		let execution = try #require(delayed)
		switch change {
		case "dismiss": await store.send(.main(.commandBar(.ui(.dismissed)))).finish()
		case "reopen": await store.send(.main(.ui(.openCommand(.currentTab)))).finish()
		default:
			await store.send(.main(.viewer(.item(.show(organization.tabs[change == "page" ? 1 : 0]))))).finish()
		}
		let currentContext = store.main.commandBarContext
		holdsExecution = false
		await store.send(.main(.commandBar(.delegate(.execute(execution))))).finish()
		expectNoDifference(commands, [])
		if change == "reopen" {
			expectNoDifference(store.main.commandBarContext, currentContext)
			#expect(store.main.commandBar.isPresented)
		} else { #expect(store.main.commandBarContext == nil) }
	}

	@Test
	internal func labeledCrossProfileSpaceResultAndQueryEditsRemainUsable() async throws {
		var organization = commandContextFixture()
		organization.spaces[1] = .init(
			id: organization.spaces[1].id,
			profileID: organization.profiles[1].id,
			name: "Personal"
		)
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = organization.tabs[0]
		let store = Store(initialState: AppFeature.State(main: main)) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		await store.send(.main(.ui(.openCommand(.commands)))).finish()
		let context = store.main.commandBarContext
		for query in ["Per", "Personal"] {
			await store.send(.main(.commandBar(.ui(.queryChanged(query))))).finish()
			expectNoDifference(store.main.commandBarContext, context)
		}
		let id = organization.spaces[1].id
		let entry = try #require(store.main.commandBar.entries.first { $0.intent == .selectSpace(id) })
		#expect(entry.presentation.subtitle.contains("Other account"))
		await store.send(.main(.commandBar(.ui(.selected(entry.presentation.id))))).finish()
		expectNoDifference(store.main.sidebar.spaceID, id)
		expectNoDifference(store.main.sidebar.space.profileID, organization.profiles[1].id)
	}

	private func commandContextFixture() -> BrowserOrganization {
		var organization = fixture()
		organization.profiles.append(.init(id: .init(rawValue: UUID(20)), name: "Other account"))
		organization.tabs[1].customTitle = "Unique destination tab"
		let folder = Folder(
			id: .init(rawValue: UUID(30)),
			spaceID: organization.spaces[0].id,
			name: "Unique folder",
			isExpanded: false
		)
		organization.folders = [folder]
		organization.spaces[0].savedItems = [.folder(folder.id)]
		return organization
	}
}
