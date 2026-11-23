import AppUI
import BrowserCore
import BrowserSurfaceClient
import Foundation
import MainFeature
import _ComposableArchitecture

/// Moving Page PiP's tab between spaces (DEV-1184): its header's space picker, and ⌘1–9 while
/// Page PiP is key, move the floating tab to that space through the window it floats from, as a
/// drag in that window's sidebar does, so the sidebar shows the move and Undo takes it back.
///
/// A space of the tab's own profile takes the tab as it is, and it keeps floating. A space of
/// another profile asks first: the window then reopens the page in that profile, as every move
/// across profiles does, and the new tab floats in place of the old one once the move is done.
@Reducer
internal struct PagePictureInPictureSpaces {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserSurface)
	private var surface

	@Dependency(\.uuid)
	private var uuid

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.pagePictureInPictureMoveToSpace) { state, spaceID in
			guard
				PagePictureInPictureSpacesFeatureFlag.isOn(),
				state.pagePictureInPicture?.spaceMove == nil,
				let move = state.pagePictureInPictureSpaceMove(to: spaceID)
			else { return .none }

			guard !move.crossesProfiles else {
				state.pagePictureInPicture?.spaceMove = spaceID
				return .none
			}
			return perform(move, state: &state)
		}

		Pullback(\.ui.confirmPagePictureInPictureSpaceMove) { state in
			guard let spaceID = state.pagePictureInPicture?.spaceMove else { return .none }

			state.pagePictureInPicture?.spaceMove = nil

			// The tab or its place may have changed while the question showed.
			guard let move = state.pagePictureInPictureSpaceMove(to: spaceID) else {
				return focusPage(state)
			}
			return perform(move, state: &state)
		}

		Pullback(\.ui.cancelPagePictureInPictureSpaceMove) { state in
			guard state.pagePictureInPicture?.spaceMove != nil else { return .none }

			state.pagePictureInPicture?.spaceMove = nil
			return focusPage(state)
		}

		Pullback(\.main.event.movedAcrossProfiles) { state, request in
			follow(request, state: &state)
		}

		Pullback(\.main.event.moveFailed) { state, value in
			moveFailed(value.0, state: &state)
		}

		// A question whose space went meanwhile, deleted in Settings or on another Mac, ends:
		// nothing could move there, and it would keep the picker and ⌘1–9 waiting. Little Arx's
		// question before Open in ends the same way.
		Reduce { state, _ in
			if
				let spaceID = state.pagePictureInPicture?.spaceMove,
				state.workspace.spaces[id: spaceID] == nil
			{
				state.pagePictureInPicture?.spaceMove = nil
			}
			let spaces = state.workspace.spaces
			let stranded = state.littleWindows.filter { little in
				little.pendingDestination.map { spaces[id: $0] == nil } ?? false
			}
			return .merge(stranded.map { .send(.littleWindows(.element(id: $0.id, action: .ui(.cancelPromotion)))) })
		}

		Pullback(\.windows) { state, action in
			switch action {
			case let .element(_, .event(.movedAcrossProfiles(request))):
				return follow(request, state: &state)

			case let .element(_, .event(.moveFailed(id, _))):
				return moveFailed(id, state: &state)

			default:
				return .none
			}
		}
	}

	/// Sends the move to the window the page floats from, which asks nothing more: the question,
	/// if any, was Page PiP's.
	private func perform(
		_ move: AppFeature.State.PagePictureInPictureSpaceMove,
		state: inout State
	) -> Effect<Action> {
		let requestID = uuid()
		if move.crossesProfiles { state.pagePictureInPicture?.profileMove = requestID }
		state.recordPagePictureInPictureAddress(in: move.windowID)
		return state.send(
			.transferConfirmedTabs(requestID, [.tab(move.tabID.rawValue)], nil, move.spaceID),
			to: move.windowID
		)
	}

	/// The window moved the floating tab to another profile: its replacement floats once the tab
	/// itself is gone (`PagePictureInPictureFollowing`).
	private func follow(
		_ request: TabMoveRequest,
		state: inout State
	) -> Effect<Action> {
		guard
			let current = state.pagePictureInPicture,
			current.profileMove == request.id
		else { return .none }

		state.pagePictureInPicture?.profileMove = nil
		state.pagePictureInPicture?.replacement = request.plan.replacements
			.first { $0.source.id == current.tabID }?
			.destination.id
		return .none
	}

	/// The window didn't move the tab, or the page refused to close: it stays where it is, and
	/// keeps floating.
	private func moveFailed(
		_ requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard state.pagePictureInPicture?.profileMove == requestID else { return .none }

		state.pagePictureInPicture?.profileMove = nil
		return focusPage(state)
	}

	/// The floating page takes the keyboard back from the question.
	private func focusPage(_ state: State) -> Effect<Action> {
		guard let current = state.pagePictureInPicture, current.isFloating else { return .none }

		return .run { @MainActor [surface, tabID = current.tabID] _ in surface.focus(tabID) }
	}
}

extension AppFeature.State {
	/// A move of Page PiP's tab to a space (DEV-1184).
	internal struct PagePictureInPictureSpaceMove: Equatable {
		internal var tabID: BrowserCore.Tab.ID

		/// The window the page floats from, which moves the tab.
		internal var windowID: UUID
		internal var spaceID: Space.ID

		/// Whether the space is another profile's, so the page reopens there and the move asks
		/// first.
		internal var crossesProfiles: Bool
	}

	/// How Page PiP's tab would move to `spaceID` (DEV-1184): a space's tab, floating from an
	/// ordinary window that keeps it, to another space. A private window's tab, Little Arx's and a
	/// Peek's have no space to move from, and nothing moves while a move or a switch is under way.
	internal func pagePictureInPictureSpaceMove(to spaceID: Space.ID) -> PagePictureInPictureSpaceMove? {
		guard
			let current = pagePictureInPicture,
			current.isFloating,
			current.next == nil,
			current.profileMove == nil,
			current.replacement == nil,
			!littleWindows.contains(where: { $0.tab.id == current.tabID }),
			!peeks.contains(where: { $0.tab.id == current.tabID }),
			let tab = workspace.tabs[id: current.tabID],
			let space = workspace.spaces[id: spaceID],
			isPagePictureInPictureHostOpen(current.windowID),
			let host = window(current.windowID),
			!host.isPrivate,
			!host.transferInProgress,
			host.sidebar.organization.tabs[id: tab.id] != nil,
			pagePictureInPictureSpaceID() != spaceID
		else { return nil }

		return .init(
			tabID: tab.id,
			windowID: current.windowID,
			spaceID: spaceID,
			crossesProfiles: space.profileID != tab.profileID
		)
	}

	/// Records where the floating page is now as its tab's address, in the window that moves it and
	/// the workspace (DEV-1184). A page no pane shows doesn't report its navigation to its window,
	/// so its tab may still name the address it floated at, and a move to another profile, which
	/// checks the page is where its tab says, would refuse it. A page still loading keeps its tab
	/// as it is.
	fileprivate mutating func recordPagePictureInPictureAddress(in windowID: UUID) {
		guard
			let current = pagePictureInPicture,
			let url = current.navigation.url,
			!current.navigation.isLoading
		else { return }

		func record(in organization: inout BrowserOrganization) {
			guard let tab = organization.tabs[id: current.tabID] else { return }

			let title = current.navigation.title.isEmpty ? tab.restoration.title : current.navigation.title
			organization.tabs[id: current.tabID]?.restoration = .init(title: title, url: url)
		}

		if windowID == main.id {
			record(in: &main.sidebar.organization)
		} else if var window = windows[id: windowID] {
			record(in: &window.sidebar.organization)
			windows[id: windowID] = window
		}
		record(in: &workspace)
	}

	/// The floating tab's space, as Page PiP's space picker shows it (DEV-1184): the space that
	/// keeps it, or for a Favorite, which belongs to its profile, the window's space while it
	/// shows that profile, else the profile's first.
	internal func pagePictureInPictureSpaceID() -> Space.ID? {
		guard let current = pagePictureInPicture else { return nil }

		switch workspace.location(of: current.tabID) {
		case let .unpinned(space), let .pinned(space, _):
			return space

		case let .favorite(profileID):
			// Never another profile's space, whatever the window shows now.
			return floatingSpace(of: profileID, windowID: current.windowID)

		case nil:
			return nil
		}
	}

	/// Page PiP's space picker (DEV-1184): every space in the switcher's order, as their Switch to
	/// Space shortcuts show them, with the tab's own selected. `nil` for a page that has no space
	/// to move between, which keeps the profile picker: a private window's, Little Arx's or a
	/// Peek's.
	internal func pagePictureInPictureSpaces() -> (options: [PagePictureInPictureSpacePicker.Option], current: Space.ID?)? {
		guard
			let current = pagePictureInPicture,
			!littleWindows.contains(where: { $0.tab.id == current.tabID }),
			!peeks.contains(where: { $0.tab.id == current.tabID }),
			let tab = workspace.tabs[id: current.tabID]
		else { return nil }

		return (
			PagePictureInPictureSpacePicker.Option.options(
				spaces: workspace.spaces,
				profiles: workspace.profiles,
				profileID: tab.profileID,
				shortcuts: settings.keyboardShortcuts
			),
			pagePictureInPictureSpaceID()
		)
	}

	/// Page PiP's question before a move to another profile (DEV-1184), while it asks.
	internal func pagePictureInPictureProfileMoveConfirmation() -> ProfileMoveConfirmation.Content? {
		guard
			let spaceID = pagePictureInPicture?.spaceMove,
			let space = workspace.spaces[id: spaceID],
			let profile = workspace.profiles[id: space.profileID]
		else { return nil }

		return .init(subject: .tab, spaceName: space.name, profileName: profile.name)
	}

	/// What a Select Tab command (⌘1–9) does while Page PiP is key (DEV-1184): it moves the
	/// floating tab to the space with that number, the ninth to the ninth space. Page PiP's panel
	/// is key when commands target the application; Little Arx as Page PiP (DEV-1112) opens its
	/// page in that space, as its "Open in" does. `nil` leaves the command to the window, and
	/// while Page PiP edits its address or asks, its keys are the bar's or the question's.
	internal func pagePictureInPictureSpaceShortcut(
		for command: BrowserCommand,
		target: AppFeature.CommandTarget
	) -> AppFeature.Action? {
		guard
			let number = command.tabNumber,
			workspace.spaces.indices.contains(number - 1),
			PagePictureInPictureSpacesFeatureFlag.isOn()
		else { return nil }

		let space = workspace.spaces[number - 1]
		switch target {
		case .application:
			guard
				let current = pagePictureInPicture,
				current.isFloating,
				!current.commandBar.isPresented,
				current.spaceMove == nil,
				pagePictureInPictureSpaces() != nil
			else { return nil }

			return .ui(.pagePictureInPictureMoveToSpace(space.id))

		case let .window(id, _):
			guard
				let little = littleWindows[id: id],
				little.isPictureInPicture,
				little.peekID == nil,
				!little.commandBar.isPresented,
				little.pendingDestination == nil
			else { return nil }

			return .littleWindows(.element(id: id, action: .ui(.promote(space.id, space.profileID))))

		default:
			return nil
		}
	}
}
