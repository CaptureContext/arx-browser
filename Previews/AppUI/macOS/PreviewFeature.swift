import AppKit
import AppUI
import BrowserCore
import _ComposableArchitecture

@Reducer
internal struct PreviewFeature {
	@ObservableState
	internal struct State: Equatable {
		internal var organization: BrowserOrganization
		internal var spaceID: Space.ID
		internal var commandIsPresented: Bool
		internal var query: String
		internal var sidebarIsVisible: Bool
		internal var collapsedSpaces: Set<Space.ID>
		internal var undo: [BrowserOrganization]
		internal var message: String?

		internal init(
			organization: BrowserOrganization = PreviewFixture.organization,
			spaceID: Space.ID = PreviewFixture.id(1),
			commandIsPresented: Bool = false,
			query: String = "",
			sidebarIsVisible: Bool = true,
			collapsedSpaces: Set<Space.ID> = [],
			undo: [BrowserOrganization] = [],
			message: String? = nil
		) {
			self.organization = organization
			self.spaceID = spaceID
			self.commandIsPresented = commandIsPresented
			self.query = query
			self.sidebarIsVisible = sidebarIsVisible
			self.collapsedSpaces = collapsedSpaces
			self.undo = undo
			self.message = message
		}
	}

	@CasePathable
	internal enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		internal enum UI: Sendable {
			case sidebar(SidebarAction)
			case commandOpened
			case commandDismissed
			case queryChanged(String)
			case commandSelected(String)
			case spaceSelected(Space.ID)
			case tabsDroppedOnSpace([SidebarItem.ID], Space.ID)
			case copyURL
			case undo
			case reset
		}

		@CasePathable
		internal enum Event: Sendable {}

		@CasePathable
		internal enum Delegate: Sendable {}

		@CasePathable
		internal enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.uuid)
	private var uuid

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.commandOpened) { state in
			state.query = ""
			state.commandIsPresented = true
			return .none
		}

		Pullback(\.ui.commandDismissed) { state in
			state.commandIsPresented = false
			return .none
		}

		Pullback(\.ui.queryChanged) { state, query in
			state.query = query
			return .none
		}

		Pullback(\.ui.sidebar.openCommandBar) { _ in .send(.ui(.commandOpened)) }

		Pullback(\.ui.sidebar.newTab) { _ in .send(.ui(.commandOpened)) }

		Pullback(\.ui.sidebar.toggleSidebar) { state in
			state.sidebarIsVisible.toggle()
			return .none
		}

		Pullback(\.ui.sidebar.toggleSpace) { state in
			if !state.collapsedSpaces.insert(state.spaceID).inserted {
				state.collapsedSpaces.remove(state.spaceID)
			}
			return .none
		}

		Pullback(\.ui.sidebar.select) { state, id in
			guard case let .tab(uuid) = id else { return .none }
			state.select(.init(rawValue: uuid))
			return .none
		}

		Pullback(\.ui.sidebar.toggle) { state, id in
			guard
				case let .folder(uuid) = id,
				let index = state.organization.folders.firstIndex(where: { $0.id.rawValue == uuid })
			else { return .none }
			state.organization.folders[index].isExpanded.toggle()
			return .none
		}

		Pullback(\.ui.sidebar.rename) { state, value in
			let (id, name) = value
			state.edit { organization in
				switch id {
				case let .folder(uuid):
					if let index = organization.folders.firstIndex(where: { $0.id.rawValue == uuid }) {
						organization.folders[index].name = name
					}

				case let .tab(uuid):
					if let index = organization.tabs.firstIndex(where: { $0.id.rawValue == uuid }) {
						organization.tabs[index].customTitle = name
						if organization.tabs[index].savedDestination != nil {
							organization.tabs[index].savedDestination?.title = name
						}
					}
				}
			}
			return .none
		}

		Pullback(\.ui.sidebar.move) { state, value in
			let (id, target) = value
			let spaceID = state.spaceID
			state.edit { try $0.move(id, to: target, in: spaceID) }
			return .none
		}

		Pullback(\.ui.sidebar.ungroupFolder) { state, id in
			guard case let .folder(uuid) = id else { return .none }
			state.edit { try $0.ungroupFolder(.init(rawValue: uuid)) }
			return .none
		}

		Pullback(\.ui.sidebar.deleteFolder) { state, id in
			guard case let .folder(uuid) = id else { return .none }
			state.edit { try $0.deleteFolder(.init(rawValue: uuid)) }
			return .none
		}

		Pullback(\.ui.sidebar.openFolder) { state, value in
			let (id, includingDescendants) = value
			guard case let .folder(uuid) = id else { return .none }
			let tabs = state.organization.tabs(
				in: .init(rawValue: uuid),
				includingDescendants: includingDescendants
			)
			if let first = tabs.first { state.select(first) }
			return .none
		}

		Pullback(\.ui.sidebar.updateSavedURL) { state, id in
			guard case let .tab(uuid) = id else { return .none }
			state.edit { try $0.updateSavedURL(.init(rawValue: uuid)) }
			return .none
		}

		Pullback(\.ui.sidebar.newFolder) { state, parent in
			state.collapsedSpaces.remove(state.spaceID)
			let folderID = Folder.ID(rawValue: uuid())
			let spaceID = state.spaceID
			state.edit { organization in
				let folder: Folder = .init(
					id: folderID,
					spaceID: spaceID,
					name: String.localized(.appUI.sidebar.newFolder)
				)
				organization.folders.append(folder)
				let parentIndex = parent.flatMap { parent -> Int? in
					guard case let .folder(id) = parent else { return nil }
					return organization.folders.firstIndex { $0.id.rawValue == id }
				}
				if let parentIndex {
					organization.folders[parentIndex].children.append(.folder(folderID))
					organization.folders[parentIndex].isExpanded = true
				} else if let index = organization.spaces.index(id: spaceID) {
					organization.spaces[index].savedItems.append(.folder(folderID))
				}
			}
			return .none
		}

		Pullback(\.ui.sidebar.reset) { state, id in
			guard case let .tab(uuid) = id else { return .none }
			state.edit { $0.resetPinnedTab(.init(rawValue: uuid)) }
			return .none
		}

		Pullback(\.ui.sidebar.removePin) { state, id in
			guard
				case let .tab(uuid) = id,
				let tab = state.organization.tabs.first(where: { $0.id.rawValue == uuid }),
				tab.savedDestination != nil
			else { return .none }
			state.edit { $0.removeTab(tab.id) }
			return .none
		}

		Pullback(\.ui.sidebar.close) { state, id in
			guard
				case let .tab(uuid) = id,
				let tab = state.organization.tabs.first(where: { $0.id.rawValue == uuid }),
				tab.savedDestination == nil
			else { return .none }
			state.edit { $0.removeTab(tab.id) }
			return .none
		}

		Pullback(\.ui.tabsDroppedOnSpace) { state, value in
			let (ids, destination) = value
			state.edit { organization in
				for id in ids {
					try organization.moveTab(id, toSpace: destination)
				}
			}
			if state.message == nil { state.selectSpace(destination) }
			return .none
		}

		Pullback(\.ui.spaceSelected) { state, id in
			state.selectSpace(id)
			return .none
		}

		Pullback(\.ui.undo) { state in
			if let previous = state.undo.popLast() {
				state.organization = previous
				state.message = nil
			}
			return .none
		}

		Pullback(\.ui.reset) { state in
			state = .init()
			return .none
		}

		Pullback(\.ui.copyURL) { state in
			guard let url = state.selectedTab?.restoration.url else { return .none }
			return .run { _ in
				await MainActor.run {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(url.absoluteString, forType: .string)
				}
			}
		}

		Pullback(\.ui.commandSelected) { state, id in
			state.commandIsPresented = false
			if id == "new-folder" { return .send(.ui(.sidebar(.newFolder(nil)))) }
			if id == "toggle-sidebar" { return .send(.ui(.sidebar(.toggleSidebar))) }
			if id == "undo" { return .send(.ui(.undo)) }
			if id.hasPrefix("folder:"), let raw = UUID(uuidString: String(id.dropFirst(7))) {
				state.reveal(.init(rawValue: raw))
				state.sidebarIsVisible = true
				return .none
			}
			if id.hasPrefix("space:"), let raw = UUID(uuidString: String(id.dropFirst(6))) {
				state.selectSpace(.init(rawValue: raw))
				return .none
			}
			if let raw = UUID(uuidString: id) {
				state.select(.init(rawValue: raw))
				return .none
			}
			guard id == "open-url", let url = state.proposedURL else { return .none }
			let tabID = BrowserCore.Tab.ID(rawValue: uuid())
			let spaceID = state.spaceID
			state.edit { organization in
				guard let index = organization.spaces.index(id: spaceID)
				else { return }
				let tab: BrowserCore.Tab = .init(
					id: tabID,
					profileID: organization.spaces[index].profileID,
					restoration: .init(
						title: url.host() ?? String.localized(.appUI.sidebar.newTab),
						url: url
					)
				)
				organization.tabs.append(tab)
				organization.spaces[index].unpinnedTabs.append(tabID)
				organization.spaces[index].selectedTabID = tabID
			}
			return .none
		}
	}
}
