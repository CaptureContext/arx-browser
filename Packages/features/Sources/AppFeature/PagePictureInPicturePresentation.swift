import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import CommandBarFeature
import Foundation
import MainFeature
import _ComposableArchitecture

/// A tab's live page in a floating window that behaves like Picture in Picture (DEV-950): Page
/// PiP, for sites whose own Picture in Picture doesn't work (DRM video, sites that turn it off,
/// call apps without Document PiP, dashboards and chats).
///
/// The page itself moves into the window, never a copy of it, so protected video keeps playing
/// and clicks and typing reach it. Its tab shows that it's in Picture in Picture, with Return to Tab.
public struct PagePictureInPicture: Equatable {
	public enum Phase: Equatable, Sendable {
		/// The tab's window lets go of the page before the floating window takes it.
		case opening
		case open

		/// The floating window lets go of the page before its tab takes it back. With
		/// `focusesTab`, the tab comes to the front too (Return to Tab).
		case returning(focusesTab: Bool)
	}

	public var tabID: BrowserCore.Tab.ID

	/// The window the page left, which reports its media visibility while it floats.
	public var windowID: UUID
	public var phase: Phase

	/// Another tab asked to float while this one did: it floats once this one is back.
	public var next: BrowserCore.Tab.ID?

	/// The window whose tab menu asked for `next`, which it floats from if no window shows it
	/// (DEV-1105).
	public var nextWindowID: UUID?

	/// The floating page's address, loading and history, for its window's header (DEV-1105).
	public var navigation: BrowserNavigation

	/// The command bar its address opens (DEV-1124): the main window's address editing, over the
	/// floating window's URL bar, for this page alone.
	public var commandBar: CommandBarFeature.State

	/// The bar's presentation whose choice may still open in the page: the one presented here, while
	/// the page floats.
	public var addressPresentation: Int?

	/// The space of another profile the space picker or ⌘1–9 chose (DEV-1184), while the window
	/// asks whether to move the tab there.
	public var spaceMove: Space.ID?

	/// The window's move of the floating tab to another profile, under way (DEV-1184): once it's
	/// done, the tab's replacement in that profile floats in its place.
	public var profileMove: UUID?

	/// The floating tab's replacement in the profile it moved to (DEV-1184), which floats once the
	/// tab itself is gone.
	public var replacement: BrowserCore.Tab.ID?

	public init(
		tabID: BrowserCore.Tab.ID,
		windowID: UUID,
		phase: Phase = .opening,
		next: BrowserCore.Tab.ID? = nil,
		nextWindowID: UUID? = nil,
		navigation: BrowserNavigation = .init(),
		commandBar: CommandBarFeature.State = .init(),
		addressPresentation: Int? = nil,
		spaceMove: Space.ID? = nil,
		profileMove: UUID? = nil,
		replacement: BrowserCore.Tab.ID? = nil
	) {
		self.tabID = tabID
		self.windowID = windowID
		self.phase = phase
		self.next = next
		self.nextWindowID = nextWindowID
		self.navigation = navigation
		self.commandBar = commandBar
		self.addressPresentation = addressPresentation
		self.spaceMove = spaceMove
		self.profileMove = profileMove
		self.replacement = replacement
	}

	/// Whether the floating window should hold the page now.
	public var isFloating: Bool { phase == .open }
}

/// The floating page's address bar (DEV-1124): its command bar, in the floating page's state.
internal struct PagePictureInPictureAddressBar: Reducer {
	internal typealias State = PagePictureInPicture
	internal typealias Action = CommandBarFeature.Action

	internal func reduce(
		into state: inout PagePictureInPicture,
		action: CommandBarFeature.Action
	) -> Effect<CommandBarFeature.Action> {
		CommandBarFeature()._reduce(into: &state.commandBar, action: action)
	}
}

extension AppFeature.State {
	/// Page PiP's command bar, for its view: an empty one while no page floats.
	internal var pagePictureInPictureCommandBar: CommandBarFeature.State {
		pagePictureInPicture?.commandBar ?? .init()
	}
}

/// Opens and closes Page PiP. One page floats at a time; opening another returns the first.
@Reducer
internal struct PagePictureInPicturePresentation {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserSurface)
	private var surface

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.uuid)
	private var uuid

	internal var body: some ReducerOf<Self> {
		CombineReducers {
			presentation
			address
		}

		// Its effects are the floating page's own, cancelled when it ends, and never another bar's.
		.ifLet(\.pagePictureInPicture, action: \.pagePictureInPictureCommandBar) {
			PagePictureInPictureAddressBar()
		}
	}

	/// Editing the floating page's address (DEV-1124), as the main window's URL bar does: a click
	/// on it opens the command bar over it with the address selected, what's chosen opens in the
	/// floating page, and Esc closes it. Either way the page has the keyboard again.
	@ReducerBuilder<State, Action>
	private var address: some ReducerOf<Self> {
		Pullback(\.ui.editPagePictureInPictureAddress) { state in
			guard
				PagePictureInPictureAddressFeatureFlag.isOn(),
				var current = state.pagePictureInPicture,
				current.isFloating,
				!current.commandBar.isPresented
			else { return .none }

			// Only the page's own address: no tabs, history, Peek or Little Arx to open from here. It
			// searches with the page's profile's engine. Like Little Arx's, it doesn't ask the provider
			// for suggestions: nothing would follow the profile's choice while it's open.
			current.commandBar.searchEngine = state.pagePictureInPictureProfile()?.searchEngine ?? .google
			current.commandBar.suggestsRemotely = false
			current.commandBar.bangs = state.settings.bangs
			current.commandBar.actionAvailability = .init(
				opensNewTabs: false,
				opensPeek: false,
				opensLittleArx: false,
				removesHistory: false
			)
			current.commandBar.useShortcuts(state.settings.keyboardShortcuts)

			// Presenting counts one more presentation, the one whose choice opens.
			current.addressPresentation = current.commandBar.focusRequest + 1
			state.pagePictureInPicture = current
			return .send(.pagePictureInPictureCommandBar(.present(
				.currentTab,
				current.navigation.url?.absoluteString ?? "",
				[]
			)))
		}

		Pullback(\.pagePictureInPictureCommandBar.delegate.execute) { state, execution in
			guard
				let current = state.pagePictureInPicture,
				let presentation = current.addressPresentation,
				presentation == execution.presentationID,
				execution.mode == .currentTab
			else { return .none }

			state.pagePictureInPicture?.addressPresentation = nil
			let tabID = current.tabID
			let focus: Effect<Action> = .run { @MainActor [surface] _ in surface.focus(tabID) }
			guard current.isFloating else { return .none }

			switch execution.entry.intent {
			case let .open(url):
				// History counts a typed address's visit as typed (DEV-1015).
				let typed: Effect<Action> = execution.isTypedAddress
				? .send(.event(.pagePictureInPictureTypedAddressOpened(url, tabID)))
				: .none
				return .merge(
					focus,
					.run { [engine] _ in try? await engine.command(tabID, .navigate(url)) },
					typed
				)

			case let .copyURL(url):
				return .merge(focus, .send(.delegate(.copyURL(url))))

			default:
				// Nothing else is the floating page's to do.
				return focus
			}
		}

		Pullback(\.pagePictureInPictureCommandBar.delegate.dismissed) { state in
			guard let current = state.pagePictureInPicture else { return .none }

			state.pagePictureInPicture?.addressPresentation = nil
			guard current.isFloating else { return .none }

			return .run { @MainActor [surface, tabID = current.tabID] _ in surface.focus(tabID) }
		}

	}

	@ReducerBuilder<State, Action>
	private var presentation: some ReducerOf<Self> {
		Pullback(\.ui.openPagePictureInPicture) { state, tabID in

			// A headless run shows no windows (DEV-950).
			guard
				!state.automation.isUnattended,
				state.pagePictureInPicture?.tabID != tabID,
				let windowID = state.pagePictureInPictureSource(of: tabID),
				!state.pagePictureInPictureTabShowsDownload(tabID, engine: engine)
			else { return .none }

			// Only one page floats: the one floating goes back to its tab first.
			if let current = state.pagePictureInPicture {
				guard current.phase == .open else { return .none }
				state.pagePictureInPicture?.phase = .returning(focusesTab: false)
				state.pagePictureInPicture?.next = tabID
				state.pagePictureInPicture?.nextWindowID = nil
				return .none
			}

			// A page can't fill the screen and float at once.
			if state.pageFullScreen?.tabID == tabID { state.pageFullScreen = nil }
			state.pagePictureInPicture = .init(tabID: tabID, windowID: windowID)
			return .run { [surface] send in

				// The window's page view lets go first, so the floating window can take the page.
				await surface.release(tabID)
				await send(.event(.pagePictureInPictureReleased(tabID)))
			}
		}

		Pullback(\.ui.presentTabInPictureInPicture) { state, value in
			let (tabID, windowID) = value

			// Only from an open browser window's menu.
			guard state.isPagePictureInPictureHostOpen(windowID), state.window(windowID) != nil
			else { return .none }

			// A tab a window shows floats from there, as with the command.
			if state.pagePictureInPictureSource(of: tabID) != nil {
				return .send(.ui(.openPagePictureInPicture(tabID)))
			}
			guard
				!state.automation.isUnattended,
				state.pagePictureInPicture?.tabID != tabID,
				let tab = state.pagePictureInPictureBackgroundTab(tabID, in: windowID),
				!state.pagePictureInPictureTabShowsDownload(tabID, engine: engine)
			else { return .none }

			if let current = state.pagePictureInPicture {
				guard current.phase == .open else { return .none }
				state.pagePictureInPicture?.phase = .returning(focusesTab: false)
				state.pagePictureInPicture?.next = tabID
				state.pagePictureInPicture?.nextWindowID = windowID
				return .none
			}

			// No window shows the page, so none lets go of it; it loads if it isn't loaded.
			state.pagePictureInPicture = .init(tabID: tabID, windowID: windowID)
			return .run { [engine] send in
				do {
					try await engine.open(tab)
					await send(.event(.pagePictureInPictureReleased(tabID)))
				} catch {
					await send(.event(.pagePictureInPictureFailed(tabID)))
				}
			}
		}

		Pullback(\.event.pagePictureInPictureFailed) { state, tabID in
			guard state.pagePictureInPicture?.tabID == tabID, state.pagePictureInPicture?.phase == .opening
			else { return .none }

			state.pagePictureInPicture = nil
			return .none
		}

		Pullback(\.event.pagePictureInPictureReleased) { state, tabID in
			guard
				var current = state.pagePictureInPicture,
				current.tabID == tabID,
				current.phase == .opening
			else { return .none }

			current.phase = .open
			state.pagePictureInPicture = current

			// The header follows the page wherever it's shown, so it observes the page itself.
			return .run { [engine] send in
				for await navigation in await engine.events(tabID) {
					await send(.event(.pagePictureInPictureNavigation(tabID, navigation)))
				}
			}
			.cancellable(id: PagePictureInPictureNavigation.cancelID, cancelInFlight: true)
		}

		Pullback(\.event.pagePictureInPictureNavigation) { state, value in
			let (tabID, navigation) = value
			guard state.pagePictureInPicture?.tabID == tabID else { return .none }

			state.pagePictureInPicture?.navigation = navigation

			// The floating window draws only the page, so a page that became a transfer, with
			// nothing of its own left to show, goes back to its tab, which shows the transfer (DEV-1116).
			if navigation.download != nil, state.pagePictureInPicture?.phase == .open {
				state.pagePictureInPicture?.phase = .returning(focusesTab: false)
			}
			return .none
		}

		Pullback(\.ui.pagePictureInPictureBack) { state in
			guard
				let current = state.pagePictureInPicture,
				current.isFloating,
				current.navigation.canGoBack
			else { return .none }

			return .run { [engine, tabID = current.tabID] _ in
				try? await engine.command(tabID, .back)
			}
		}

		Pullback(\.ui.pagePictureInPictureForward) { state in
			guard
				let current = state.pagePictureInPicture,
				current.isFloating,
				current.navigation.canGoForward
			else { return .none }

			return .run { [engine, tabID = current.tabID] _ in
				try? await engine.command(tabID, .forward)
			}
		}

		// Little Arx's picker reopens its page in the chosen profile. A space's tab keeps its
		// page: it goes back to its tab untouched, and a new tab at the same address, in the
		// chosen profile's space, floats in its place (DEV-1105). Little Arx's page, a Peek's and
		// a private window's keep their profile here: Little Arx's switches in Little Arx, whose
		// replacement page this window couldn't follow.
		Pullback(\.ui.pagePictureInPictureSelectProfile) { state, profileID in
			guard
				let current = state.pagePictureInPicture,
				current.isFloating,
				current.next == nil
			else { return .none }

			guard
				!state.littleWindows.contains(where: { $0.tab.id == current.tabID }),
				!state.peeks.contains(where: { $0.tab.id == current.tabID }),
				let source = state.workspace.tabs[id: current.tabID],
				source.profileID != profileID,
				let spaceID = state.pagePictureInPictureSpace(for: profileID, windowID: current.windowID),
				let spaceIndex = state.workspace.spaces.firstIndex(where: { $0.id == spaceID })
			else { return .none }

			let url = current.navigation.url ?? source.restoration.url
			let tab = BrowserCore.Tab(
				id: .init(rawValue: uuid()),
				profileID: profileID,
				restoration: .init(title: current.navigation.title.isEmpty ? source.displayTitle : current.navigation.title, url: url)
			)
			var organization = state.workspace
			organization.tabs.append(tab)
			organization.spaces[spaceIndex].unpinnedTabs.insert(tab.id, at: 0)
			do {
				try organization.validate()
			} catch {
				return .none
			}

			state.publishAdditiveOrganization(organization)

			// The floating page goes back first, then the new one floats from the same window.
			state.pagePictureInPicture?.phase = .returning(focusesTab: false)
			state.pagePictureInPicture?.next = tab.id
			state.pagePictureInPicture?.nextWindowID = current.windowID
			return .send(.delegate(.save(state.workspace)))
		}

		Pullback(\.ui.copyPagePictureInPictureURL) { state in
			guard let url = state.pagePictureInPicture?.navigation.url else { return .none }

			return .send(.delegate(.copyURL(url)))
		}

		Pullback(\.ui.closePagePictureInPicture) { state, focusesTab in
			guard let current = state.pagePictureInPicture else { return .none }

			switch current.phase {
			case .open:
				state.pagePictureInPicture?.phase = .returning(focusesTab: focusesTab)

			case .opening:
				// The floating window never took the page: its tab keeps it.
				state.pagePictureInPicture = nil

			case .returning:
				break
			}
			return .none
		}

		Pullback(\.event.pagePictureInPictureClosed) { state, tabID in
			guard
				let current = state.pagePictureInPicture,
				current.tabID == tabID,
				case let .returning(focusesTab) = current.phase
			else { return .none }

			state.pagePictureInPicture = nil
			if let next = current.next {
				// The next tab floats from the window that shows it, else from the one whose menu
				// asked for it.
				return state.pagePictureInPictureSource(of: next) == nil
				? .send(.ui(.presentTabInPictureInPicture(next, windowID: current.nextWindowID ?? current.windowID)))
				: .send(.ui(.openPagePictureInPicture(next)))
			}
			guard focusesTab else { return .none }

			// Return to Tab: the tab is shown, and its window comes forward with Arx, even when it's
			// the window last in front (the media return's request does that, deminiaturizing too).
			// A Little Arx or Peek page isn't in a space: its own window comes forward.
			let effect: Effect<Action> = if let tab = state.workspace.tabs[id: tabID] {
				OrdinaryTabPresentation().focus(tab, state: &state)
			} else if let window = state.windows.first(where: { $0.sidebar.organization.tabs[id: tabID] != nil }) {
				// A private window's tab is in its own organization: that window selects it.
				.send(.windows(.element(
					id: window.id,
					action: .sidebar(.ui(.sidebar(.select(.tab(tabID.rawValue)))))
				)))
			} else {
				.none
			}
			if let host = state.pagePictureInPictureSource(of: tabID) ?? state.existingWindowID(current.windowID) {
				state.focusedWindowID = host
				state.mediaSourceFocusRequest += 1
			}
			return effect
		}
	}
}

/// Ends Page PiP once its tab is gone (closed, archived or moved to another profile, whose new tab
/// floats next when Page PiP moved it there, DEV-1184), and returns it
/// once the window it floats from closes (DEV-1105), as Return to Tab does without showing the tab:
/// the floating window lets the page go, and the window close's release then unloads it (DEV-1104).
/// Stops following the page's navigation once it ends. Keeps automatic media PiP off the floating
/// page, which is already on screen.
private struct PagePictureInPictureFollowing<Base: Reducer>: Reducer
where Base.State == AppFeature.State, Base.Action == AppFeature.Action {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal let base: Base

	internal func reduce(
		into state: inout State,
		action: Action
	) -> Effect<Action> {
		let floating = state.pagePictureInPicture?.tabID
		var effect = base._reduce(into: &state, action: action)
		if let current = state.pagePictureInPicture {
			if !state.hasPagePictureInPictureTab(current.tabID) {
				state.pagePictureInPicture = nil

				// Moved to another profile from Page PiP (DEV-1184): its replacement floats in its
				// place, from the window that moved it, unless the person took the page back
				// (Return to Tab) or asked for another meanwhile.
				if
					current.isFloating,
					current.next == nil,
					let replacement = current.replacement,
					state.hasPagePictureInPictureTab(replacement)
				{
					effect = .merge(
						effect,
						.send(.ui(.presentTabInPictureInPicture(replacement, windowID: current.windowID)))
					)
				}
			} else if !state.pagePictureInPictureHostExists(current.windowID) {
				switch current.phase {
				case .open:
					state.pagePictureInPicture?.phase = .returning(focusesTab: false)

				case .opening:
					// The floating window never took the page: its tab keeps it.
					state.pagePictureInPicture = nil

				case .returning:
					break
				}
			}
		}

		// Little Arx as Page PiP floats its own page (DEV-1112).
		var floatingNow: Set<BrowserCore.Tab.ID> = state.pagePictureInPicture.map { [$0.tabID] } ?? []
		for little in state.littleWindows where little.isPictureInPicture { floatingNow.insert(little.tab.id) }
		if state.media.tabsFloatingElsewhere != floatingNow { state.media.tabsFloatingElsewhere = floatingNow }
		guard floating != nil, floating != state.pagePictureInPicture?.tabID else { return effect }

		return .merge(effect, .cancel(id: PagePictureInPictureNavigation.cancelID))
	}
}

/// The floating page's navigation observation.
private enum PagePictureInPictureNavigation {
	case cancelID
}

extension Reducer where State == AppFeature.State, Action == AppFeature.Action {
	internal func endingPagePictureInPictureOfClosedTabs() -> some Reducer<State, Action> {
		PagePictureInPictureFollowing(base: self)
	}
}

extension AppFeature.State {
	/// The window a tab's page can float from: one showing it now, as a pane, a Peek or Little Arx.
	internal func pagePictureInPictureSource(of tabID: BrowserCore.Tab.ID) -> UUID? {
		if let peek = peeks.first(where: { $0.tab.id == tabID && $0.viewer.tab?.id == tabID }) {
			return peek.phase == .idle ? peek.source.windowID : nil
		}

		// Little Arx turns into Page PiP itself rather than lending its page (DEV-1112).
		if littleWindows.contains(where: { $0.tab.id == tabID }) { return nil }
		let browserWindows: [MainFeature.State] = (windowIsOpen ? [main] : []) + Array(windows)
		return browserWindows.first { window in
			!window.isClosing && window.viewer.panes.contains { $0.item.tab?.id == tabID }
		}?.id
	}

	/// Whether the tab still exists somewhere Arx keeps pages: a space, a private window's own
	/// organization, Little Arx or a Peek.
	internal func hasPagePictureInPictureTab(_ tabID: BrowserCore.Tab.ID) -> Bool {
		workspace.tabs[id: tabID] != nil
		|| ([main] + Array(windows)).contains { $0.sidebar.organization.tabs[id: tabID] != nil }
		|| littleWindows.contains { $0.tab.id == tabID }
		|| peeks.contains { $0.tab.id == tabID }
	}

	/// The open browser window a tab no window shows belongs to, for an automatic Page PiP
	/// (DEV-1246): the one whose sidebar has it, then one showing its space, else the first open.
	internal func pagePictureInPictureHome(of tabID: BrowserCore.Tab.ID) -> UUID? {
		let browserWindows: [MainFeature.State] = (windowIsOpen ? [main] : []) + Array(windows)
		let open = browserWindows.filter { isPagePictureInPictureHostOpen($0.id) }
		let home = open.first { $0.sidebar.organization.tabs[id: tabID] != nil }
		?? open.first { window in
			switch workspace.location(of: tabID) {
			case let .pinned(spaceID, _), let .unpinned(spaceID): window.sidebar.spaceID == spaceID
			case .favorite, nil: false
			}
		}
		?? open.first
		guard let home, pagePictureInPictureBackgroundTab(tabID, in: home.id) != nil else { return nil }
		return home.id
	}

	/// The window, when it's still open.
	fileprivate func existingWindowID(_ id: UUID) -> UUID? {
		isPagePictureInPictureHostOpen(id) ? id : nil
	}

	/// Whether the window a page floats from is still there. Page PiP lives as long as it does
	/// (DEV-1105); a close the person can still cancel, as a private window's before its pages
	/// agree, doesn't end it.
	internal func pagePictureInPictureHostExists(_ id: UUID) -> Bool {
		if id == main.id { return windowIsOpen }
		return windows[id: id] != nil || littleWindows[id: id] != nil
	}

	/// Whether the window is open and not closing: one a page can float from or present from.
	internal func isPagePictureInPictureHostOpen(_ id: UUID) -> Bool {
		if id == main.id { return windowIsOpen && !main.isClosing }
		if let window = windows[id: id] { return !window.isClosing }
		return littleWindows[id: id] != nil
	}

	/// A tab of `windowID`'s that no window shows, which Page PiP can load and float: a tab in a
	/// space, or in a private window's own organization. A native chat tab has no page.
	internal func pagePictureInPictureBackgroundTab(
		_ tabID: BrowserCore.Tab.ID,
		in windowID: UUID
	) -> BrowserCore.Tab? {
		guard isPagePictureInPictureHostOpen(windowID), let window = window(windowID) else { return nil }

		let tab = window.sidebar.organization.tabs[id: tabID] ?? workspace.tabs[id: tabID]
		return tab?.isChat == true ? nil : tab
	}

	/// Where Page PiP's profile picker opens the page in `profileID` (DEV-1105): the window's
	/// space while it shows that profile, else the profile's first space.
	internal func pagePictureInPictureSpace(
		for profileID: Profile.ID,
		windowID: UUID
	) -> Space.ID? {
		if let host = window(windowID), !host.isPrivate, host.sidebar.space.profileID == profileID {
			return host.sidebar.spaceID
		}
		return workspace.spaces.first { $0.profileID == profileID }?.id
	}

	/// The floating page's profile (DEV-1124): a space's tab's, a private window's, Little Arx's or
	/// a Peek's, as the profile picker finds it.
	internal func pagePictureInPictureProfile() -> Profile? {
		guard let current = pagePictureInPicture else { return nil }

		if let tab = workspace.tabs[id: current.tabID] ?? littleWindows.first(where: { $0.tab.id == current.tabID })?.tab {
			return workspace.profiles[id: tab.profileID]
		}
		if let peek = peeks.first(where: { $0.tab.id == current.tabID }) {
			return workspace.profiles[id: peek.tab.profileID]
			?? window(peek.source.windowID)?.sidebar.organization.profiles[id: peek.tab.profileID]
		}
		guard
			let host = window(current.windowID),
			let tab = host.sidebar.organization.tabs[id: current.tabID]
		else { return nil }

		return host.sidebar.organization.profiles[id: tab.profileID]
	}

	/// What `command` does to Page PiP's address bar while it's open (DEV-1124). With its panel key,
	/// commands target the application; ⌘K and Copy URL act on that bar then, as on a window's, and
	/// the menu offers them as the bar can take them.
	internal func pagePictureInPictureAddressBarAction(
		for command: BrowserCommand,
		target: AppFeature.CommandTarget
	) -> CommandBarFeature.Action? {
		guard target == .application, let bar = pagePictureInPicture?.commandBar, bar.isPresented else { return nil }

		switch command {
		case .commandBar:
			return .ui(.actionsToggled)

		case .copyURL:
			return bar.offersCopyURL ? .ui(.actionRequested(CommandBarFeature.State.copyURLActionID)) : nil

		default:
			return nil
		}
	}

	/// Page PiP's profile picker (DEV-1105): every profile, those with a space to open the page in
	/// enabled. A Peek's page and a private window's stay in their profile.
	internal func pagePictureInPictureProfiles() -> (options: [LittleWindowProfilePicker.Option], current: Profile.ID?) {
		guard let current = pagePictureInPicture else { return ([], nil) }

		if
			!littleWindows.contains(where: { $0.tab.id == current.tabID }),
			!peeks.contains(where: { $0.tab.id == current.tabID }),
			let tab = workspace.tabs[id: current.tabID]
		{
			return (
				workspace.profiles.map { profile in
					.init(
						id: profile.id,
						name: profile.name,
						isEnabled: workspace.spaces.contains { $0.profileID == profile.id }
					)
				},
				tab.profileID
			)
		}

		// A private window's tab, Little Arx's or a Peek's: only its own profile, which it keeps.
		let tab = window(current.windowID)?.sidebar.organization.tabs[id: current.tabID]
		?? littleWindows.first { $0.tab.id == current.tabID }?.tab
		?? peeks.first { $0.tab.id == current.tabID }?.tab
		guard let tab else { return ([], nil) }

		let name = workspace.profiles[id: tab.profileID]?.name
		?? window(current.windowID)?.sidebar.organization.profiles[id: tab.profileID]?.name
		?? ""
		return ([.init(id: tab.profileID, name: name, isEnabled: true)], tab.profileID)
	}

	/// Whether a tab's menu in `windowID` offers Present Tab in Picture in Picture (DEV-1105): it
	/// has a page, isn't floating already, and the run isn't headless. `engine` is the store's.
	internal func canPresentTabInPictureInPicture(
		_ tabID: BrowserCore.Tab.ID,
		in windowID: UUID,
		engine: BrowserEngineClient
	) -> Bool {
		guard
			!automation.isUnattended,
			pagePictureInPicture?.tabID != tabID,
			isPagePictureInPictureHostOpen(windowID),
			window(windowID) != nil,
			!pagePictureInPictureTabShowsDownload(tabID, engine: engine)
		else { return false }

		if let source = pagePictureInPictureSource(of: tabID) {
			return pagePictureInPictureTabIsPage(tabID, in: source)
		}
		return pagePictureInPictureBackgroundTab(tabID, in: windowID) != nil
	}

	private func pagePictureInPictureTabIsPage(
		_ tabID: BrowserCore.Tab.ID,
		in windowID: UUID
	) -> Bool {
		let tab = workspace.tabs[id: tabID] ?? window(windowID)?.sidebar.organization.tabs[id: tabID]
		return tab?.isChat != true
	}

	/// Whether the tab shows the Downloading page: its navigation became a transfer and it has no
	/// page of its own (DEV-1116). The floating window draws only the page, so it would float an
	/// empty one. The engine knows, whether a window shows the tab or not; it's the store's, which
	/// a view outside the reducer can't reach as a dependency.
	internal func pagePictureInPictureTabShowsDownload(
		_ tabID: BrowserCore.Tab.ID,
		engine: BrowserEngineClient
	) -> Bool {
		// Reducers and views run on the main actor; the engine's snapshot is main-actor state.
		return MainActor.assumeIsolated { engine.snapshot(tabID)?.navigation.download } != nil
	}

	/// The tab a command acts on, for Page PiP.
	internal func pagePictureInPictureTab(for target: AppFeature.CommandTarget) -> BrowserCore.Tab.ID? {
		switch target {
		case let .peek(id):
			return peeks[id: id]?.tab.id

		case let .window(id, paneID):
			// A native chat tab has no page to float.
			if let little = littleWindows[id: id] {
				return little.isCommandOnly || little.viewer.tab?.isChat == true ? nil : little.viewer.tab?.id
			}
			guard let window = window(id) else { return nil }
			let pane = paneID ?? window.viewer.activePaneID
			let tab = window.viewer.panes[id: pane]?.item.tab ?? window.viewer.item.tab
			return tab?.isChat == true ? nil : tab?.id

		default:
			return nil
		}
	}
}
