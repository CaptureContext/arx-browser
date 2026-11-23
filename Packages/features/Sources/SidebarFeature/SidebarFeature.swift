import AppUI
import BrowserCore
import _ComposableArchitecture

/// A notice for the window, such as a refused move. Every one written gets a new `id`.
public struct SidebarNotice: Equatable, Sendable {
	public let id: Int
	public let text: String

	public init(
		id: Int,
		text: String
	) {
		self.id = id
		self.text = text
	}
}

@Reducer
public struct SidebarFeature {
	@ObservableState
	public struct State: Equatable {
		public var organization: BrowserOrganization
		public var spaceID: Space.ID
		public var sidebarIsVisible: Bool
		public var collapsedSpaces: Set<Space.ID>

		/// What ⌘Z takes back in this window, newest last (DEV-1030).
		public var undo: [OrganizationUndo]

		/// The notice the window shows as a toast, with an ID that's new for every message
		/// written, even the same text again, so it gets its full time (DEV-777).
		public private(set) var notice: SidebarNotice?
		private var lastNoticeID: Int
		public var moveSelection: [SidebarItem.ID]
		public var transferUndos: [OrganizationMove]

		/// `ARX_WINDOW_UNDO` (DEV-1030): a step takes back only what it changed, so the window's
		/// history outlasts changes made elsewhere. Off, a step restores the workspace it started
		/// from, and a change from outside the window clears the history.
		public var windowUndo: Bool

		/// Tabs whose sound differs from `defaultTabAudio`: playing, muted or turned down. The app
		/// keeps it from its media state (DEV-800).
		public var tabAudio: [BrowserCore.Tab.ID: SidebarItem.Audio]

		/// The sound of every other tab, or nil where the window can't mute tabs (DEV-800).
		public var defaultTabAudio: SidebarItem.Audio?

		/// Tabs whose page Arx unloaded to free memory; their rows look unloaded. The app keeps
		/// it from its tab unloading (DEV-873).
		public var unloadedTabs: Set<BrowserCore.Tab.ID>

		/// Tabs whose page shows in WebKit; their icons carry a mark. The app keeps it from the
		/// page engines (DEV-877).
		public var webKitTabs: Set<BrowserCore.Tab.ID>

		/// Tabs an MCP client is acting on, kept by the app from its automation state (DEV-899).
		public var tabAgents: [BrowserCore.Tab.ID: SidebarItem.Agent]

		/// What live pages last reported unread, from their title or the Badging API (DEV-907).
		/// Other tabs read their saved title. The app keeps it.
		public var unreadBadges: [BrowserCore.Tab.ID: UnreadBadge]

		/// The browser default for unread badges, from Settings (DEV-907, DEV-1258).
		public var showsUnreadBadges: Bool

		/// The sites' and tabs' own unread badges choices (DEV-1258). Profiles' are in the
		/// organization. The app keeps it.
		public var unreadBadgeOverrides: UnreadBadgeOverrides

		/// The open tabs this window shows while windows are independent (DEV-822). The app keeps
		/// it from which window each open tab is in.
		public var openTabFilter: OpenTabFilter

		/// Counts choices of the space already shown, from the switcher or a shortcut, which change
		/// no selection: the sidebar leaves the Create a Space page for it (DEV-1126).
		public var spaceReselections: Int = 0

		/// How many times each pin or Favorite was reset to its saved page, which shakes its row
		/// (DEV-1225). Empty with `ARX_PIN_RESET_SHAKE` off.
		public var resetPulses: [SidebarItem.ID: Int] = [:]

		/// The `ARX_PIN_RESET_SHAKE` feature flag, read when the window opens (DEV-1225).
		public var shakesResetPins: Bool = PinResetShakeFeatureFlag.isOn()

		/// The tab whose icon picker is open, from Change Icon… (DEV-1251).
		public var iconPickerTabID: BrowserCore.Tab.ID?

		public init(
			organization: BrowserOrganization,
			spaceID: Space.ID,
			sidebarIsVisible: Bool = true,
			collapsedSpaces: Set<Space.ID> = [],
			undo: [OrganizationUndo] = [],
			message: String? = nil,
			moveSelection: [SidebarItem.ID] = [],
			transferUndos: [OrganizationMove] = [],
			tabAudio: [BrowserCore.Tab.ID: SidebarItem.Audio] = [:],
			defaultTabAudio: SidebarItem.Audio? = nil,
			unloadedTabs: Set<BrowserCore.Tab.ID> = [],
			webKitTabs: Set<BrowserCore.Tab.ID> = [],
			tabAgents: [BrowserCore.Tab.ID: SidebarItem.Agent] = [:],
			unreadBadges: [BrowserCore.Tab.ID: UnreadBadge] = [:],
			showsUnreadBadges: Bool = true,
			unreadBadgeOverrides: UnreadBadgeOverrides = .init(),
			windowUndo: Bool = WindowUndoFeatureFlag.atLaunch
		) {
			self.organization = organization
			self.spaceID = spaceID
			self.sidebarIsVisible = sidebarIsVisible
			self.collapsedSpaces = collapsedSpaces
			self.undo = undo
			self.notice = nil
			self.lastNoticeID = 0
			self.moveSelection = moveSelection
			self.transferUndos = transferUndos
			self.windowUndo = windowUndo
			self.tabAudio = tabAudio
			self.defaultTabAudio = defaultTabAudio
			self.unloadedTabs = unloadedTabs
			self.webKitTabs = webKitTabs
			self.tabAgents = tabAgents
			self.unreadBadges = unreadBadges
			self.showsUnreadBadges = showsUnreadBadges
			self.unreadBadgeOverrides = unreadBadgeOverrides
			self.openTabFilter = .all
			self.message = message
		}

		/// The notice's text. Writing it, even the same text again, shows a new notice.
		public var message: String? {
			get { notice?.text }
			set {
				guard let newValue else {
					notice = nil
					return
				}

				lastNoticeID += 1
				notice = .init(id: lastNoticeID, text: newValue)
			}
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case sidebar(SidebarAction)
			case spaceSelected(Space.ID)
			case newSpace

			/// The Create a Space page past the last space (DEV-1109): a space with this name,
			/// profile and theme.
			case createSpace(name: String, profileID: Profile.ID, appearance: AppearanceOverride?)
			case createProfile(String)
			case selectProfile(Profile.ID)
			case tabsDroppedOnSpace([SidebarItem.ID], Space.ID)
			case move(SidebarItem.ID, SidebarDropTarget, Space.ID)
			case moveItems([SidebarItem.ID], SidebarDropTarget?, Space.ID)
			case undo
		}

		@CasePathable
		public enum Event: Sendable {
			case closeApproved(
				BrowserCore.Tab.ID,
				reset: Bool,
				expectedLocation: BrowserOrganization.TabLocation? = nil
			)
		}

		@CasePathable
		public enum Delegate: Sendable {
			case openCommandBar
			case openFolder(Folder.ID, includingDescendants: Bool)
			case deleteFolder(Folder.ID)
			case resetTab(BrowserCore.Tab.ID)
			case requestClose(BrowserCore.Tab.ID, reset: Bool)
			case transferTabs([SidebarItem.ID], SidebarDropTarget?, Space.ID)
			case chooseMoveDestination([SidebarItem.ID])
			case reverseTransfer(OrganizationMove)

			/// Open tabs another window keeps were dropped into this window's open tabs or tab
			/// groups; this window takes them (DEV-822).
			case takeOpenTabsFromOtherWindows([BrowserCore.Tab.ID])

			/// ⌘Z took this step back, or found it can't be (DEV-1030). The window shows the step's
			/// space again, and the app drops the step from every other window and, for Move to
			/// Window or Open in New Window, gives the tabs back to the window they left (DEV-1156).
			case undid(OrganizationUndo)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.uuid)
	private var uuid

	@Dependency(\.date)
	private var date

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.sidebar.openCommandBar) { _ in .send(.delegate(.openCommandBar)) }

		Pullback(\.ui.sidebar.newTab) { _ in .send(.delegate(.openCommandBar)) }

		Pullback(\.ui.sidebar.toggleSidebar) { state in
			state.sidebarIsVisible.toggle()
			return .none
		}

		Pullback(\.ui.sidebar.toggleSpace) { state in
			let result = state.collapsedSpaces.insert(state.spaceID)
			if !result.inserted { state.collapsedSpaces.remove(state.spaceID) }

			return .none
		}

		Pullback(\.ui.sidebar.select) { state, id in
			guard case let .tab(uuid) = id else { return .none }
			state.select(.init(rawValue: uuid))
			return .none
		}

		// A press selects as a click does; the window also remembers what it showed (DEV-994).
		Pullback(\.ui.sidebar.selectOnPress) { state, id in
			guard case let .tab(uuid) = id else { return .none }
			state.select(.init(rawValue: uuid))
			return .none
		}

		Pullback(\.ui.sidebar.toggle) { state, id in
			guard case let .folder(uuid) = id else { return .none }

			if let index = state.organization.tabGroups.index(id: .init(rawValue: uuid)) {
				state.organization.tabGroups[index].isExpanded.toggle()
				return .none
			}
			guard let index = state.organization.folders.firstIndex(where: { $0.id.rawValue == uuid })
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
					organization.tabGroups[id: .init(rawValue: uuid)]?.name = name

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

		Pullback(\.ui.sidebar.changeIcon) { state, id in
			guard
				case let .tab(uuid) = id,
				case let tabID = BrowserCore.Tab.ID(rawValue: uuid),
				state.organization.tabs[id: tabID] != nil
			else { return .none }

			state.iconPickerTabID = tabID
			return .none
		}

		Pullback(\.ui.sidebar.dismissIconPicker) { state in
			state.iconPickerTabID = nil
			return .none
		}

		// The icon is the tab's own: moves keep it, closing or archiving drops it, and ⌘Z puts back
		// the one it had (DEV-1251).
		Pullback(\.ui.sidebar.setIcon) { state, value in
			let (id, icon) = value
			state.iconPickerTabID = nil
			guard case let .tab(uuid) = id else { return .none }

			let tabID = BrowserCore.Tab.ID(rawValue: uuid)
			guard
				let tab = state.organization.tabs[id: tabID],
				tab.icon != icon
			else { return .none }

			state.edit { organization in
				organization.tabs[id: tabID]?.icon = icon
			}
			return .none
		}

		Pullback(\.ui.move) { state, value in
			let (id, target, destination) = value

			// Dropping onto a tab joins it in Split View, which MainFeature handles.
			if case .split = target { return .none }
			if case .folder = id { return .send(.delegate(.transferTabs([id], target, destination))) }
			if state.requiresProfileTransfer([id], to: destination) {
				return .send(.delegate(.transferTabs([id], state.tabGroupFreeTarget(target), destination)))
			}
			let wasOpen = Set(state.organization.spaces.flatMap(\.unpinnedTabs))
			let moved = state.edit { try $0.move(id, to: target, in: destination) }

			// A row from another window's sidebar dropped into a tab group here (DEV-822). A
			// refused move leaves it with that window.
			guard
				moved,
				case let .tab(uuid) = id,
				case let tab = BrowserCore.Tab.ID(rawValue: uuid),
				wasOpen.contains(tab),
				!state.openTabFilter.shows(tab),
				state.organization.spaces.contains(where: { $0.unpinnedTabs.contains(tab) })
			else { return .none }

			return .send(.delegate(.takeOpenTabsFromOtherWindows([tab])))
		}

		Pullback(\.ui.moveItems) { state, value in
			let (ids, target, destination) = value
			if case .split = target { return .none }
			if state.isTabGroupMove(ids, to: target), let target {
				return .send(.ui(.move(ids[0], target, destination)))
			}
			return .send(.delegate(.transferTabs(ids, state.tabGroupFreeTarget(target), destination)))
		}

		Pullback(\.ui.sidebar.moveItems) { state, value in
			let (ids, target) = value
			if case .split = target { return .none }
			if state.isTabGroupMove(ids, to: target) {
				return .send(.ui(.move(ids[0], target, state.spaceID)))
			}
			return .send(.delegate(.transferTabs(ids, state.tabGroupFreeTarget(target), state.spaceID)))
		}

		Pullback(\.ui.sidebar.groupTabs) { state, ids in
			let open = state.windowOpenTabs
			let requested = Set(ids.compactMap { id -> BrowserCore.Tab.ID? in
				guard case let .tab(uuid) = id else { return nil }
				return .init(rawValue: uuid)
			})

			// A Split View row stands for all its tabs.
			let members = open.filter { tab in
				requested.contains(tab)
				|| state.organization.splits.contains { $0.tabIDs.contains(tab) && !requested.isDisjoint(with: $0.tabIDs) }
			}
			guard !members.isEmpty else { return .none }

			let id = TabGroup.ID(rawValue: uuid())
			let spaceID = state.spaceID
			state.edit { organization in
				try organization.groupTabs(
					members,
					in: spaceID,
					id: id,
					name: String.localized(.appUI.sidebar.newTabGroup)
				)
			}
			state.moveSelection = []
			return .none
		}

		// A group split across independent windows: each acts on the part it shows (DEV-1160).
		Pullback(\.ui.sidebar.ungroupTabGroup) { state, id in
			guard case let .folder(uuid) = id else { return .none }
			let groupID = TabGroup.ID(rawValue: uuid)
			let members = state.windowTabGroupMembers(groupID)
			state.edit { $0.ungroupTabs(groupID, members: members) }
			return .none
		}

		Pullback(\.ui.sidebar.pinTabGroup) { state, id in
			guard case let .folder(rawID) = id else { return .none }
			let groupID = TabGroup.ID(rawValue: rawID)
			let folderID = Folder.ID(rawValue: uuid())
			let members = state.windowTabGroupMembers(groupID)
			state.edit { try $0.pinTabGroup(groupID, as: folderID, members: members) }
			return .none
		}

		Pullback(\.ui.sidebar.chooseMoveDestination) { state, id in
			let ids: [SidebarItem.ID]
			if let id {
				ids = state.moveSelection.contains(id) ? state.moveSelection : [id]
			} else if state.moveSelection.isEmpty {
				ids = state.selectedTab.map { [.tab($0.id.rawValue)] } ?? []
			} else {
				ids = state.moveSelection
			}
			return ids.isEmpty ? .none : .send(.delegate(.chooseMoveDestination(ids)))
		}

		Pullback(\.ui.sidebar.toggleMoveSelection) { state, id in
			if let index = state.moveSelection.firstIndex(of: id) {
				state.moveSelection.remove(at: index)
			} else {
				state.moveSelection.append(id)
			}
			return .none
		}

		Pullback(\.ui.sidebar.clearMoveSelection) { state in
			state.moveSelection = []
			return .none
		}

		Pullback(\.ui.sidebar.move) { state, value in
			.send(.ui(.move(value.0, value.1, state.spaceID)))
		}

		Pullback(\.ui.sidebar.splitGroup.chooseMoveDestination) { state, id in
			guard let group = state.organization.splits[id: .init(rawValue: id)] else { return .none }
			let ids = state.organization.listMembers(of: group).map { SidebarItem.ID.tab($0.rawValue) }
			return ids.isEmpty ? .none : .send(.delegate(.chooseMoveDestination(ids)))
		}

		Pullback(\.ui.sidebar.splitGroup.rename) { state, value in
			let (id, title) = value
			state.edit { organization in
				organization.splits[id: .init(rawValue: id)]?.title = title
			}
			return .none
		}

		Pullback(\.ui.sidebar.splitGroup.changeIcon) { state, value in
			let (id, icon) = value
			state.edit { organization in
				organization.splits[id: .init(rawValue: id)]?.icon = icon
			}
			return .none
		}

		Pullback(\.ui.sidebar.newFolder) { state, parent in
			state.collapsedSpaces.remove(state.spaceID)
			let folderID = Folder.ID(rawValue: uuid())
			let spaceID = state.spaceID
			state.edit { organization in
				organization.folders.append(.init(
					id: folderID,
					spaceID: spaceID,
					name: String.localized(.appUI.sidebar.newFolder)
				))
				if
					case let .folder(id) = parent,
					let index = organization.folders.firstIndex(where: { $0.id.rawValue == id })
				{
					organization.folders[index].children.append(.folder(folderID))
					organization.folders[index].isExpanded = true
				} else if let index = organization.spaces.index(id: spaceID) {
					organization.spaces[index].savedItems.append(.folder(folderID))
				}
			}
			return .none
		}

		Pullback(\.ui.sidebar.ungroupFolder) { state, id in
			guard case let .folder(uuid) = id else { return .none }
			state.edit { try $0.ungroupFolder(.init(rawValue: uuid)) }
			return .none
		}

		Pullback(\.ui.sidebar.deleteFolder) { _, id in
			guard case let .folder(uuid) = id else { return .none }
			return .send(.delegate(.deleteFolder(.init(rawValue: uuid))))
		}

		Pullback(\.ui.sidebar.openFolder) { _, value in
			let (id, includingDescendants) = value
			guard case let .folder(uuid) = id else { return .none }
			return .send(.delegate(.openFolder(
				.init(rawValue: uuid),
				includingDescendants: includingDescendants
			)))
		}

		Pullback(\.ui.sidebar.updateSavedURL) { state, id in
			guard case let .tab(uuid) = id else { return .none }
			state.edit { try $0.updateSavedURL(.init(rawValue: uuid)) }
			return .none
		}

		Pullback(\.ui.sidebar.reset) { _, id in
			guard case let .tab(uuid) = id else { return .none }

			return .send(.delegate(.requestClose(.init(rawValue: uuid), reset: true)))
		}

		Pullback(\.ui.sidebar.removePin) { _, id in
			guard case let .tab(uuid) = id else { return .none }

			return .send(.delegate(.requestClose(.init(rawValue: uuid), reset: false)))
		}

		Pullback(\.ui.sidebar.close) { _, id in
			guard case let .tab(uuid) = id else { return .none }

			return .send(.delegate(.requestClose(.init(rawValue: uuid), reset: false)))
		}

		Pullback(\.event.closeApproved) { state, value in
			let (id, reset, expectedLocation) = value
			guard expectedLocation == nil || state.organization.location(of: id) == expectedLocation
			else { return .none }
			state.commitTabClose(id, reset: reset)
			if reset {
				state.noteReset(id)
			}
			return reset ? .send(.delegate(.resetTab(id))) : .none
		}

		Pullback(\.ui.tabsDroppedOnSpace) { _, value in
			.send(.delegate(.transferTabs(value.0, nil, value.1)))
		}

		Pullback(\.ui.createProfile) { state, rawName in
			let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !name.isEmpty else { return .none }
			let profileID = Profile.ID(rawValue: uuid())
			let spaceID = Space.ID(rawValue: uuid())
			state.edit {
				$0.profiles.append(.init(
					id: profileID,
					name: name
				))
				$0.spaces.append(.init(
					id: spaceID,
					profileID: profileID,
					name: name
				))
			}
			state.selectSpace(spaceID)
			return .none
		}

		Pullback(\.ui.selectProfile) { state, id in
			if let space = state.organization.spaces.first(where: { $0.profileID == id }) {
				state.selectSpace(space.id)
			}
			return .none
		}

		Pullback(\.ui.newSpace) { state in
			let id = Space.ID(rawValue: uuid())
			let profileID = state.space.profileID
			state.edit {
				$0.spaces.append(.init(
					id: id,
					profileID: profileID,
					name: String.localized(.appUI.sidebar.newSpace)
				))
			}
			state.selectSpace(id)
			return .none
		}

		// After the other spaces, where the Create a Space page stood, and shown (DEV-1109).
		Pullback(\.ui.createSpace) { state, value in
			let (typed, profileID, appearance) = value
			let name: String = typed.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !name.isEmpty, state.organization.profiles.ids.contains(profileID) else { return .none }

			let id = Space.ID(rawValue: uuid())
			state.edit {
				$0.spaces.append(.init(
					id: id,
					profileID: profileID,
					name: name,
					// A theme left as the profile's is none of the space's own.
					appearance: appearance == AppearanceOverride() ? nil : appearance
				))
			}
			state.selectSpace(id)
			return .none
		}

		Pullback(\.ui.spaceSelected) { state, id in
			if id == state.spaceID { state.spaceReselections &+= 1 }
			state.selectSpace(id)
			return .none
		}

		Pullback(\.ui.undo) { state in
			if let transferUndo = state.transferUndo(for: state.undo.last) {
				return .send(.delegate(.reverseTransfer(transferUndo)))
			}
			guard state.windowUndo else {
				guard let step = state.undo.popLast() else { return .none }

				state.organization = step.before
				state.message = nil
				return .send(.delegate(.undid(step)))
			}

			// The newest step with something left to take back. One with nothing left, such as a
			// close ⇧⌘T already reopened, or one whose time is up, is passed over (DEV-1030).
			while let open = state.undo.last {
				// A move to another profile, reached past steps with nothing left, still goes back
				// only by its own reverse, which asks each page first.
				if let transferUndo = state.transferUndo(for: open) {
					return .send(.delegate(.reverseTransfer(transferUndo)))
				}
				state.undo.removeLast()
				let step = open.sealed(with: state.organization)
				if step.expiresAt != nil, !step.isAvailable(at: date.now) { continue }

				let reverted: BrowserOrganization?
				do {
					reverted = try step.after.flatMap { try state.organization.reverting($0, to: step.before) }
				} catch {
					state.message = String.localized(.appUI.sidebar.undoUnavailable)
					return .send(.delegate(.undid(step)))
				}

				// Only tabs this brings back go back to their windows; one open already stays where
				// it went since.
				let wasOpen = Set(state.organization.spaces.flatMap(\.unpinnedTabs))

				// Only tabs still where a window move put them go back to their window; one moved on
				// since stays where it went.
				let stillMoved = step.windowMove?.tabs.filter { tab in
					state.organization.location(of: tab) == step.after?.location(of: tab)
				}
				let changed = state.takeBack(step, to: reverted ?? state.organization)
				guard changed || step.windowMove != nil else { continue }

				var undone = step
				undone.openTabOwners = step.openTabOwners.filter { !wasOpen.contains($0.key) }
				if let stillMoved { undone.windowMove?.tabs = stillMoved }
				state.message = switch step.author {
				case .person: nil
				case let .agent(name): String.localized(.appUI.sidebar.undidAgentChange(name))
				}
				return .send(.delegate(.undid(undone)))
			}
			return .none
		}

	}
}
