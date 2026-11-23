import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CommandBarFeature
import Foundation
import ViewerItemFeature
import _ComposableArchitecture

@Reducer
public struct LittleArxFeature {
	@ObservableState
	public struct State: Equatable, Identifiable {
		public let id: UUID
		public var captureAvailable: Bool
		public var downloadsAvailable: Bool
		public var mediaAvailable: Bool

		/// The page's video can be presented in Media PiP now, which the app keeps current, for
		/// Present Media in Picture in Picture (DEV-1106).
		public var canPresentMedia: Bool = false
		public var developerModeEnabled: Bool

		/// The `ARX_READING_MODE` feature flag, read at launch (DEV-1028).
		public var readingModeEnabled: Bool

		/// Whether Hide Element is offered (DEV-1298): its feature flag with content blocking on,
		/// which the app keeps current.
		public var canHideElements: Bool = false
		public var spaceID: Space.ID
		public var isCommandOnly: Bool
		public var tab: BrowserCore.Tab
		public var viewer: ViewerItemFeature.State
		public var commandBar: CommandBarFeature.State
		public var commandBarContext: CommandBarContext?

		/// Pages the launcher offers before anything is typed, frozen when the window opens and
		/// rebuilt when its profile picker chooses another profile (DEV-1331).
		public var launcherSuggestions: [CommandBarFeature.Entry]

		/// The launcher's profile list, while it's open over the bar (DEV-1331).
		public var profilePicker: ProfilePicker?

		/// The profiles the launcher's picker offers, in the workspace's order: those with a space
		/// to open in (DEV-1331). Set by AppFeature when the launcher opens; a private Little Arx
		/// has none.
		public var launcherProfileIDs: [Profile.ID]
		public var peekID: UUID?

		/// The Little Arx whose page opened this one as a new tab or popup (DEV-855). It
		/// takes focus back when this one closes while focused.
		public var openerWindowID: UUID?
		public var pendingDestination: Space.ID?
		public var isSwitchingProfile: Bool
		public var isPromoting: Bool

		/// The window is Page PiP (DEV-1112): the same page, with Page PiP's header and window
		/// behaviour, until Return to Tab turns it back into Little Arx.
		public var isPictureInPicture: Bool = false
		public var isClosing: Bool
		public var closeRequest: CloseRequest?

		/// A private Little Arx (DEV-1323): its page runs in a private profile of its own, which
		/// AppFeature prepares for it and releases when it closes. It never joins the workspace, so
		/// the window can't move to a space, change profile or reach the archive, and its commands
		/// are a private window's. Internal for now: only the member number's sign-in opens one
		/// (offering it to people is DEV-1329).
		public var isPrivate: Bool = false
		public var error: String?

		/// Where a tab dropped outside every window asked the window to open, in screen
		/// coordinates (DEV-793). Without it the window opens in the middle of the screen.
		public var origin: CGPoint?

		/// What the window's space shows: its overrides over the app-wide appearance.
		@SharedReader
		public var chromeAppearance: ChromeAppearance

		/// Bindings shown beside commands, shared with Settings.
		@SharedReader
		public var keyboardShortcuts: [ShortcutBinding]

		/// Words that find commands, set in Settings.
		@SharedReader
		public var commandAliases: [CommandAlias]

		/// Proxy link rules, set in Settings: the proxy link commands need one that matches the
		/// page's site (DEV-1262).
		@SharedReader
		public var proxyLinkRules: [ProxyLinkRule]

		public init(
			id: UUID,
			spaceID: Space.ID,
			tab: BrowserCore.Tab,
			isCommandOnly: Bool = false,
			bangs: BangCatalog = .empty,
			captureAvailable: Bool = false,
			downloadsAvailable: Bool = false,
			mediaAvailable: Bool = false,
			launcherSuggestions: [CommandBarFeature.Entry] = [],
			launcherProfileIDs: [Profile.ID] = [],
			developerModeEnabled: Bool = false,
			readingModeEnabled: Bool = ReadingMode.isOn,
			origin: CGPoint? = nil
		) {
			self.id = id
			self.captureAvailable = captureAvailable
			self.downloadsAvailable = downloadsAvailable
			self.mediaAvailable = mediaAvailable
			self.isCommandOnly = isCommandOnly
			self.spaceID = spaceID
			self.tab = tab
			self.viewer = .init()
			self.pendingDestination = nil
			self.isSwitchingProfile = false
			self.isPromoting = false
			self.isClosing = false
			self.closeRequest = nil
			self.error = nil
			self.origin = origin
			self.commandBar = .init(bangs: bangs)
			self.commandBarContext = nil
			self.launcherSuggestions = launcherSuggestions
			self.profilePicker = nil
			self.launcherProfileIDs = launcherProfileIDs
			self.peekID = nil
			self.openerWindowID = nil
			self.developerModeEnabled = developerModeEnabled
			self.readingModeEnabled = readingModeEnabled
			self._keyboardShortcuts = SharedReader(.keyboardShortcuts)
			self._commandAliases = SharedReader(.commandAliases)
			self._proxyLinkRules = SharedReader(.proxyLinkRules)
			self._chromeAppearance = SharedReader(.chromeAppearance(space: spaceID))
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case viewer(ViewerItemFeature.Action)
		case commandBar(CommandBarFeature.Action)
		case changeProfile(Profile.ID, Space.ID)
		case dispatchCommand(BrowserCommand, source: CommandBarContext? = nil)
		case navigateFromCommandBar(URL, CommandBarContext)

		/// The launcher's page will open in this profile, in this space (DEV-1331): AppFeature's
		/// answer to `delegate(.launcherProfileRequested)`, with that profile's suggestions and
		/// search engine. The bar lists them in place of the previous profile's.
		case useLauncherProfile(LauncherProfile)

		/// Arx archives the window because it sat unused (DEV-1138): the page is asked as for a
		/// close, and nothing is asked again if anything changed meanwhile.
		case autoArchive
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case task
			case lostFocus
			case selectProfile(Profile.ID)
			case openCommand(CommandBarFeature.Mode)
			case copyURL
			case close
			case confirmPromotion
			case cancelPromotion
			case promote(Space.ID, Profile.ID)

			/// Turns the window into Page PiP, or back into Little Arx (DEV-1112).
			case setPictureInPicture(Bool)

			/// The launcher's profile picker (DEV-1331): its button or ⌘I opens or closes the list.
			case profilePickerToggled
			case profilePickerQueryChanged(String)
			case profilePickerHighlighted(String?)

			/// Esc in the list: closes it and leaves the bar open.
			case profilePickerDismissed
			case launcherProfileSelected(Profile.ID)
		}

		@CasePathable
		public enum Event: Sendable {
			case closeDecision(CloseRequest, Bool)
			case profileChangeDecision(Profile.ID, Space.ID, Bool)
			case profileChanged(BrowserCore.Tab, Space.ID)
			case promotionFailed(String)

			/// The page called `window.close()`; Blink has already run its before-unload (DEV-855).
			case pageClosed
		}

		@CasePathable
		public enum Delegate: Sendable {
			case command(BrowserCommand, source: CommandBarContext? = nil)
			case close
			case closePeekHost(UUID)
			case closeApproved(CloseRequest)
			case selectProfile(Profile.ID)
			case promote(Space.ID)
			case copyURL(URL)

			/// Open in Peek from ⌘K's panel (DEV-810), over this window's page.
			case openInPeek(URL)

			/// The command bar opened a typed address in this window's tab (DEV-1015).
			case typedAddressOpened(URL, BrowserCore.Tab.ID)

			/// An `arx://settings/…` or `chrome://settings/…` address typed in the bar (DEV-1189):
			/// Settings at its place, for this window's profile.
			case openSettingsAddress(SettingsAddress)

			/// Another app's link typed in the bar (DEV-1189): the app macOS assigns opens it.
			case openAppLink(URL)

			/// The page asked to stay, or the window changed while it was asked, so the automatic
			/// archive (DEV-1138) didn't happen.
			case autoArchiveRefused

			/// The launcher's profile picker chose another profile (DEV-1331); AppFeature answers
			/// with `useLauncherProfile`.
			case launcherProfileRequested(Profile.ID)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.uuid)
	private var uuid

	public init() {}

	/// Asks the page whether it may close: its before-unload may keep it open.
	private func askToClose(
		_ state: inout State,
		isAutomatic: Bool = false
	) -> Effect<Action> {
		state.isClosing = true
		let request = CloseRequest(id: uuid(), window: state, isAutomatic: isAutomatic)
		state.closeRequest = request

		return .run { [engine] send in
			let permitted = await engine.permitsClosing(request.tabID)
			guard !Task.isCancelled else { return }
			await send(.event(.closeDecision(request, permitted)))
		}
	}

	public var body: some ReducerOf<Self> {
		Pullback(\.viewer) { state, action in
			if state.peekID != nil, case .ui = action { return .none }
			return ViewerItemFeature()
				._reduce(into: &state.viewer, action: action)
				.map(Action.viewer)
		}

		Scope(state: \.commandBar, action: \.commandBar) { CommandBarFeature() }

		Pullback(\.ui.task) { state in
			guard state.peekID == nil else { return .none }
			guard state.isCommandOnly else { return .send(.viewer(.show(state.tab))) }
			return .send(.ui(.openCommand(.newTab)))
		}

		Pullback(\.commandBar.ui.dismissed) { state in
			if !state.commandBar.isPresented { state.invalidateCommandBar() }
			return .none
		}

		// ⌘K's actions and the profile list share the bar's bottom edge: one at a time (DEV-1331).
		Pullback(\.commandBar.ui.actionsToggled) { state in
			state.profilePicker = nil
			return .none
		}

		Pullback(\.ui.profilePickerToggled) { state in
			guard state.profilePicker == nil else {
				state.profilePicker = nil
				return .none
			}
			guard state.offersProfilePicker else { return .none }

			state.profilePicker = .init(selectedID: state.tab.profileID)
			guard state.commandBar.actionPanel != nil else { return .none }

			return .send(.commandBar(.ui(.actionsDismissed)))
		}

		Pullback(\.ui.profilePickerQueryChanged) { state, query in
			state.profilePicker?.query = query
			return .none
		}

		Pullback(\.ui.profilePickerHighlighted) { state, id in
			state.profilePicker?.selectedID = id.flatMap(UUID.init(uuidString:)).map(Profile.ID.init(rawValue:))
			return .none
		}

		Pullback(\.ui.profilePickerDismissed) { state in
			state.profilePicker = nil
			state.commandBar.inputRefocusRequest += 1
			return .none
		}

		Pullback(\.ui.launcherProfileSelected) { state, profileID in
			guard state.profilePicker != nil else { return .none }

			state.profilePicker = nil
			state.commandBar.inputRefocusRequest += 1
			guard state.offersProfilePicker, profileID != state.tab.profileID else { return .none }

			return .send(.delegate(.launcherProfileRequested(profileID)))
		}

		Pullback(\.useLauncherProfile) { state, profile in
			guard state.offersProfilePicker, !state.isPrivate else { return .none }

			// The launcher has no page yet: its tab only names the profile the page will open in.
			state.tab = BrowserCore.Tab(
				id: state.tab.id,
				profileID: profile.profileID,
				restoration: state.tab.restoration
			)
			state.spaceID = profile.spaceID
			state.$chromeAppearance = SharedReader(.chromeAppearance(space: profile.spaceID))
			state.launcherSuggestions = profile.suggestions
			state.profilePicker = nil
			state.commandBar.searchEngine = profile.searchEngine
			guard state.commandBar.isPresented else { return .none }

			// The same text, listed again from the chosen profile only.
			let mode = state.commandBar.mode
			let query = state.commandBar.query
			state.commandBarContext = .init(window: state, mode: mode)
			state.commandBar.bangIconProfileID = profile.profileID
			return .send(.commandBar(.present(mode, query, state.commandCandidates)))
		}

		Pullback(\.commandBar.delegate.dismissed) { state in
			state.isCommandOnly ? .send(.delegate(.close)) : .none
		}

		Pullback(\.ui.lostFocus) { state in
			guard state.isCommandOnly else { return .none }
			state.invalidateCommandBar()
			return .send(.delegate(.close))
		}

		Pullback(\.ui.selectProfile) { state, profileID in
			guard state.peekID == nil, !state.isPrivate, profileID != state.tab.profileID
			else { return .none }

			return .send(.delegate(.selectProfile(profileID)))
		}

		Pullback(\.changeProfile) { state, value in
			guard
				state.peekID == nil,
				!state.isSwitchingProfile,
				!state.isClosing,
				!state.isPromoting
			else { return .none }
			let (profileID, spaceID) = value
			guard profileID != state.tab.profileID else { return .none }
			state.invalidateCommandBar()
			state.isSwitchingProfile = true
			let tabID = state.tab.id

			return .run { [engine] send in
				let permitted = await engine.permitsClosing(tabID)
				await send(.event(.profileChangeDecision(profileID, spaceID, permitted)))
			}
		}

		Pullback(\.event.profileChangeDecision) { state, value in
			let (profileID, spaceID, permitted) = value
			guard permitted else {
				state.isSwitchingProfile = false
				return .none
			}

			let previousID = state.tab.id
			let tab = BrowserCore.Tab(
				id: .init(rawValue: uuid()),
				profileID: profileID,
				restoration: .init(
					title: state.viewer.navigation.title,
					url: state.viewer.navigation.url ?? state.tab.restoration.url
				)
			)
			return .concatenate(
				.send(.viewer(.suspend)),
				.run { [engine] send in
					await engine.close(previousID)
					await send(.event(.profileChanged(tab, spaceID)))
				}
			)
		}

		Pullback(\.event.profileChanged) { state, value in
			let (tab, spaceID) = value
			state.tab = tab
			state.spaceID = spaceID
			state.$chromeAppearance = SharedReader(.chromeAppearance(space: spaceID))
			state.error = nil
			state.isSwitchingProfile = false
			return .send(.viewer(.show(tab)))
		}

		Pullback(\.ui.setPictureInPicture) { state, isPictureInPicture in
			guard
				state.isPictureInPicture != isPictureInPicture,
				!state.isCommandOnly,
				!state.isPromoting,
				!state.isSwitchingProfile,
				!state.isClosing,
				state.peekID == nil
			else { return .none }

			state.isPictureInPicture = isPictureInPicture

			// A bar open as the window changes shape closes; floating, its address opens one over its
			// URL bar (DEV-1124).
			guard isPictureInPicture, state.commandBar.isPresented else { return .none }

			return .send(.commandBar(.ui(.dismissed)))
		}

		Pullback(\.ui.copyURL) { state in

			// Over an open bar, Copy URL copies the highlighted result's address (DEV-810).
			if state.commandBarContext != nil, state.commandBar.offersCopyURL {
				return .send(.commandBar(.ui(.actionRequested(CommandBarFeature.State.copyURLActionID))))
			}
			guard let url = state.viewer.navigation.url else { return .none }

			return .send(.delegate(.copyURL(url)))
		}

		Pullback(\.ui.openCommand) { state, mode in
			guard
				state.peekID == nil,
				!state.isClosing,
				!state.isPromoting,
				!state.isSwitchingProfile
			else { return .none }
			state.commandBarContext = .init(window: state, mode: mode)

			// Little Arx has no tabs or history of its own to act on; Peek needs a page under it.
			state.commandBar.actionAvailability = .init(
				opensNewTabs: false,
				opensPeek: !state.isCommandOnly,
				opensLittleArx: false,
				removesHistory: false
			)
			state.commandBar.useShortcuts(state.keyboardShortcuts)

			// Bangs show the tab's profile's stored site icons (DEV-1311).
			state.commandBar.bangIconProfileID = state.tab.profileID
			let query: String = mode == .currentTab
			? state.viewer.navigation.url?.absoluteString ?? ""
			: ""

			return .send(.commandBar(.present(
				mode,
				query,
				state.commandCandidates
			)))
		}

		Pullback(\.commandBar.delegate.execute) { state, value in
			guard
				let context = state.commandBarContext,
				context.presentationID == value.presentationID
			else { return .none }

			state.commandBarContext = nil
			guard context.matches(state, execution: value) else { return .none }
			var intent = value.entry.intent
			if case let .open(url) = intent, FeatureFlag.schemeAddresses.isOn(), let address = SettingsAddress(url) {
				// `chrome://downloads` and the like run Arx's command for them (DEV-1189).
				guard case let .command(command) = address else {
					// The launcher has nothing left to show once Settings opens: it closes.
					guard state.isCommandOnly else { return .send(.delegate(.openSettingsAddress(address))) }
					state.invalidateCommandBar()
					return .merge(.send(.delegate(.openSettingsAddress(address))), .send(.delegate(.close)))
				}
				intent = .command(command)
			}
			if case let .open(url) = intent, FeatureFlag.schemeAddresses.isOn(), TypedSchemeAddress.opensInApp(url) {
				// Another app's link opens in that app (DEV-1189); the page stays as it is.
				guard state.isCommandOnly else { return .send(.delegate(.openAppLink(url))) }
				state.invalidateCommandBar()
				return .merge(.send(.delegate(.openAppLink(url))), .send(.delegate(.close)))
			}
			switch intent {
			case let .command(command):
				guard command.isEnabled(in: state.commandContext) else { return .none }
				return .send(.delegate(.command(command, source: context)))

			case let .open(url):
				// History counts a typed address's visit as typed (DEV-1015).
				let typed: Effect<Action> = value.isTypedAddress
				? .send(.delegate(.typedAddressOpened(url, state.tab.id)))
				: .none
				return .merge(.send(.navigateFromCommandBar(url, context)), typed)

			case let .openInPeek(url):
				guard !state.isCommandOnly else { return .none }
				return .send(.delegate(.openInPeek(url)))

			case let .copyURL(url):
				// The launcher has nothing left to show once its bar is done: it closes, as for Esc.
				guard state.isCommandOnly else { return .send(.delegate(.copyURL(url))) }
				state.invalidateCommandBar()
				return .merge(.send(.delegate(.copyURL(url))), .send(.delegate(.close)))

			default:
				return .none
			}
		}

		Pullback(\.navigateFromCommandBar) { state, value in
			let (url, source) = value
			guard source.matches(state) else { return .none }
			if state.isCommandOnly {
				state.isCommandOnly = false
				state.tab.restoration.url = url
				return ViewerItemFeature()
					._reduce(into: &state.viewer, action: .show(state.tab))
					.map(Action.viewer)
			}

			return ViewerItemFeature()
				._reduce(into: &state.viewer, action: .ui(.command(.navigate(url))))
				.map(Action.viewer)
		}

		Pullback(\.dispatchCommand) { state, value in
			let (command, source) = value
			guard
				source == nil || source?.matches(state) == true,
				command.isEnabled(in: state.commandContext)
			else { return .none }

			let action: Action
			switch command {
			case .newTab:
				action = .ui(.openCommand(.newTab))

			case .address:
				action = .ui(.openCommand(.currentTab))

			case .commandBar where state.commandBar.isPresented:
				// ⌘K over an open bar shows or hides the highlighted result's actions (DEV-810).
				action = .commandBar(.ui(.actionsToggled))

			case .commandBar:
				action = .ui(.openCommand(.commands))

			case .closeTab:
				action = .ui(.close)

			case .copyURL:
				action = .ui(.copyURL)

			case .goBack, .goForward, .reload, .clearCacheAndReload, .reloadBypassingCache,
				.zoomIn, .zoomOut, .actualSize, .developerTools, .inspectElement, .javaScriptConsole, .stopLoading:
				guard let engineCommand = command.engineCommand else { return .none }
				action = .viewer(.ui(.command(engineCommand)))

			case .findInPage, .findNext, .findPrevious:
				guard let find = command.findAction else { return .none }
				action = .viewer(.ui(find))

			case .readingMode:
				guard let reader = command.readerAction else { return .none }
				action = .viewer(.ui(reader))

			default:
				return .none
			}


			return LittleArxFeature()._reduce(into: &state, action: action)
		}

		Pullback(\.viewer.delegate.navigation) { state, value in
			let (id, navigation) = value
			guard
				id == state.tab.id,
				!navigation.isLoading,
				navigation.errorCode == nil
			else { return .none }
			if let url = navigation.url { state.tab.restoration.url = url }
			if !navigation.title.isEmpty { state.tab.restoration.title = navigation.title }
			return .none
		}

		Pullback(\.ui.close) { state in
			if let peekID = state.peekID { return .send(.delegate(.closePeekHost(peekID))) }

			guard
				!state.isClosing,
				!state.isPromoting,
				!state.isSwitchingProfile
			else { return .none }
			state.invalidateCommandBar()
			return askToClose(&state)
		}

		Pullback(\.autoArchive) { state in
			guard
				state.peekID == nil,
				!state.isCommandOnly,
				!state.isClosing,
				!state.isPromoting,
				!state.isSwitchingProfile,
				state.pendingDestination == nil
			else { return .send(.delegate(.autoArchiveRefused)) }

			state.invalidateCommandBar()
			return askToClose(&state, isAutomatic: true)
		}

		// The page's own before-unload already ran: close without asking it again.
		Pullback(\.event.pageClosed) { state in
			guard
				state.peekID == nil,
				!state.isCommandOnly,
				!state.isClosing,
				!state.isPromoting,
				!state.isSwitchingProfile
			else { return .none }
			state.invalidateCommandBar()
			state.isClosing = true
			let request = CloseRequest(id: uuid(), window: state)
			state.closeRequest = request
			return .send(.delegate(.closeApproved(request)))
		}

		Pullback(\.event.closeDecision) { state, value in
			let (request, proceed) = value
			guard state.isClosing, state.closeRequest == request else { return .none }

			// An automatic archive is never asked again: the window stays and its clock restarts.
			if request.isAutomatic, !proceed || !request.matches(state) {
				state.isClosing = false
				state.closeRequest = nil
				return .send(.delegate(.autoArchiveRefused))
			}
			guard proceed, request.matches(state) else {
				// The page let it close, but the window showed its tab again meanwhile, as one
				// does just after it opens. The same tab is asked again rather than the close
				// being dropped (DEV-965).
				if
					proceed,
					state.peekID == nil,
					request.tabID == state.tab.id,
					request.profileID == state.tab.profileID
				{
					return askToClose(&state)
				}
				state.isClosing = false
				state.closeRequest = nil
				return .none
			}

			return .send(.delegate(.closeApproved(request)))
		}

		Pullback(\.ui.promote) { state, value in
			guard
				state.peekID == nil,
				!state.isPrivate,
				!state.isPromoting,
				!state.isClosing,
				!state.isSwitchingProfile
			else { return .none }
			state.invalidateCommandBar()
			let (destination, profile) = value
			if profile != state.tab.profileID {
				state.pendingDestination = destination
				return .none
			}
			state.isPromoting = true

			return .send(.delegate(.promote(destination)))
		}

		Pullback(\.ui.confirmPromotion) { state in
			guard
				state.peekID == nil,
				!state.isPrivate,
				let destination = state.pendingDestination
			else { return .none }

			state.invalidateCommandBar()
			state.pendingDestination = nil
			state.isPromoting = true

			return .send(.delegate(.promote(destination)))
		}

		Pullback(\.ui.cancelPromotion) { state in
			state.pendingDestination = nil
			return .none
		}

		Pullback(\.event.promotionFailed) { state, error in
			state.isPromoting = false
			state.error = error.isEmpty ? nil : error
			return .none
		}
	}
}
