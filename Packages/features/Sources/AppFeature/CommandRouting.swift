import BrowserCore
import BrowserEngineClient
import CommandBarFeature
import Foundation
import LittleArxFeature
import MainFeature
import PeekFeature
import ViewerFeature
import ViewerItemFeature
import _ComposableArchitecture

extension AppFeature {
	/// A command-bar action keeps its originating window even if focus moves before dispatch.
	public enum CommandTarget: Equatable, Sendable {
		case application
		case window(UUID, paneID: UUID? = nil)
		case settings
		case onboarding
		case downloads

		/// Window ▸ Task Manager (DEV-898).
		case taskManager
		case peek(UUID)
	}
}

extension AppFeature.State {
	internal func commandTarget(in id: UUID) -> AppFeature.CommandTarget {
		if let peek = peeks.first(where: { $0.source.windowID == id }) { return .peek(peek.id) }
		return .window(id, paneID: commandPaneID(in: id))
	}

	internal func commandPaneID(in id: UUID) -> UUID? {
		if id == main.id, windowIsOpen { return main.viewer.activePaneID }
		return windows[id: id]?.viewer.activePaneID
	}

	internal func commandContext(for target: AppFeature.CommandTarget) -> BrowserCommandContext? {
		guard !shouldQuit, !checkingQuit else { return nil }

		func available(_ value: BrowserCommandContext?) -> BrowserCommandContext? {
			guard var value else { return nil }
			value.captureAvailable = captureAvailable
			value.downloadsAvailable = downloadsReady
			value.mediaAvailable = media.isAvailable
			value.developerModeEnabled = settings.general.developerModeEnabled
			value.mainWindowIsHeld = mainWindowWaitsForOnboarding
			value.canReopenClosedWindow = canReopenClosedWindow
			return value
		}

		switch target {
		case .application:
			return available(.init(host: .application))

		case .downloads:
			return available(.init(host: .downloads))

		case .taskManager:
			return available(.init(host: .taskManager))

		case .settings:
			return available(.init(host: .settings))

		case .onboarding:
			return onboarding == nil ? nil : available(.init(host: .onboarding))

		case let .peek(id):
			guard let peek = peeks[id: id] else { return nil }
			return .init(
				host: .peek,
				hasTab: true,
				isSaved: !peek.isTemporary,
				isBusy: peek.phase != .idle,
				canGoBack: peek.viewer.navigation.canGoBack,
				canGoForward: peek.viewer.navigation.canGoForward,
				isLoading: peek.viewer.navigation.isLoading,
				canSavePage: peek.viewer.navigation.showsWebPage,
				captureAvailable: captureAvailable,
				downloadsAvailable: downloadsReady,
				mediaAvailable: media.isAvailable,
				canPresentMedia: presentableMedia(of: peek.tab.id) != nil,
				developerModeEnabled: settings.general.developerModeEnabled,
				isReading: peek.viewer.reader != nil,
				usesWebKit: peek.viewer.navigation.engine == .webKit,
				// Content blocking keeps what Hide Element hides (DEV-1298).
				canHideElements: hideElementEnabled && settings.general.blocksContent,
				// The page's address, as the proxy link commands copy it (DEV-1262).
				canProxyLink: LinkTransformer.proxies(
					peek.viewer.navigation.url ?? peek.tab.restoration.url,
					rules: settings.proxyLinkRules
				)
			)

		case let .window(id, paneID):
			guard !peeks.contains(where: { $0.source.windowID == id }) else { return nil }

			// Browser windows build their own context; Reopen Closed Window is the app's (DEV-908).
			func reopening(_ value: BrowserCommandContext?) -> BrowserCommandContext? {
				guard var value else { return nil }
				value.canReopenClosedWindow = canReopenClosedWindow

				// Hide Element is uBlock's picker, so it needs content blocking on, and its feature
				// flag while the picker is proven (DEV-1019).
				value.canHideElements = hideElementEnabled && settings.general.blocksContent
				return value
			}
			if id == main.id, windowIsOpen {
				if let paneID { return reopening(main.commandContext(in: paneID)) }
				return reopening(main.commandContext)
			}
			if let window = windows[id: id] {
				if let paneID { return reopening(window.commandContext(in: paneID)) }
				return reopening(window.commandContext)
			}
			guard paneID == nil, var little = littleWindows[id: id]?.commandContext else { return nil }

			// Content blocking keeps what Hide Element hides (DEV-1298).
			little.canHideElements = hideElementEnabled && settings.general.blocksContent
			return available(little)
		}
	}
}

@Reducer
internal struct CommandRouting {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	internal init() {}

	/// Hide Element on `target`'s page (DEV-1298): Arx's own mode where its feature flag is on and
	/// the engine has it, outlined in the mode's red, else uBlock's picker (DEV-1019). Again on a
	/// page in the mode, it's Done.
	private func hideElement(
		on target: AppFeature.CommandTarget,
		state: inout AppFeature.State
	) -> Effect<AppFeature.Action> {
		guard
			let page = state.hideElementPage(for: target),
			!page.isPrivate,
			let tab = page.item.tab
		else { return .none }

		if state.hideElementSessions[id: tab.id] != nil {
			return .send(.hideElementSessions(.element(id: tab.id, action: .ui(.done))))
		}

		let ownMode = state.elementPickerEnabled && MainActor.assumeIsolated { [engine] in engine.elementPickerIsAvailable() }
		guard
			ownMode,
			let url = page.item.navigation.url ?? Optional(tab.restoration.url),
			let host = url.host(),
			["http", "https"].contains(url.scheme?.lowercased())
		else {
			return .run { [engine] _ in _ = await engine.startElementPicker(tab.id) }
		}

		// uBlock names an IPv6 site with its brackets, as the site menu does.
		let site = host.contains(":") ? "[\(host.lowercased())]" : host.lowercased()
		state.hideElementSessions.append(.init(id: tab.id, site: site))
		let red = ChromeAccent.Preset.red.accent.rgb
		return .send(.hideElementSessions(.element(id: tab.id, action: .start(red))))
	}

	internal var body: some ReducerOf<Self> {
		Pullback(\.hideElementSessions) { state, action in
			switch action {
			case let .element(id, .delegate(.ended)):
				state.hideElementSessions.remove(id: id)
				return .none

			case let .element(id, .delegate(.unavailable)):
				// A page Arx's mode can't run on, such as a site with blocking off, gets uBlock's
				// picker, which refuses as before where nothing picked would apply.
				state.hideElementSessions.remove(id: id)
				return .run { [engine] _ in _ = await engine.startElementPicker(id) }

			default:
				return .none
			}
		}

		Pullback(\.main.delegate.command) { state, command in
			.send(.ui(.command(command, .window(state.main.id, paneID: state.main.viewer.activePaneID))))
		}

		Pullback(\.main.delegate.commandFromPane) { state, value in
			let (command, paneID, origin) = value
			let source = origin.map(AppFeature.CommandSource.main)
			return .send(.ui(.command(command, .window(state.main.id, paneID: paneID), source: source)))
		}

		Pullback(\.main.delegate.deviceCaptureFromPane) { state, value in
			let (style, paneID) = value
			return .send(.ui(.captureDevice(.window(state.main.id, paneID: paneID), style)))
		}

		Pullback(\.windows) { state, action in
			switch action {
			case let .element(id, .delegate(.command(command))):
				return .send(.ui(.command(command, .window(id, paneID: state.commandPaneID(in: id)))))

			case let .element(id, .delegate(.commandFromPane(command, paneID, origin))):
				let source = origin.map(AppFeature.CommandSource.main)
				return .send(.ui(.command(command, .window(id, paneID: paneID), source: source)))

			case let .element(id, .delegate(.deviceCaptureFromPane(style, paneID))):
				return .send(.ui(.captureDevice(.window(id, paneID: paneID), style)))

			default:
				return .none
			}
		}

		Pullback(\.littleWindows) { _, action in
			guard case let .element(id, .delegate(.command(command, origin))) = action
			else { return .none }

			let source = origin.map(AppFeature.CommandSource.little)
			return .send(.ui(.command(command, .window(id), source: source)))
		}

		Pullback(\.event.focusedLinkRead) { state, link in
			@Dependency(\.browserEngine)
			var engine

			// Reducers run on the main actor; the engine's snapshot is main-actor state.
			let source = MainActor.assumeIsolated { engine.snapshot(link.sourceTabID) }
			guard let action = state.focusedLinkPeekAction(for: link, source: source) else { return .none }
			return .send(action)
		}

		Pullback(\.ui.tabSwitcher) { state, value in
			let (action, windowID) = value
			let isOpen = windowID == state.main.id ? state.windowIsOpen : state.windows[id: windowID] != nil
			guard isOpen, !state.shouldQuit else { return .none }
			return state.send(.ui(.tabSwitcher(action)), to: windowID)
		}

		Pullback(\.ui.command) { state, value in
			let (command, target, source) = value
			guard source == nil || source?.matches(state, target: target) == true else { return .none }

			// While Page PiP's address is being edited, ⌘K and Copy URL act on its bar (DEV-1124).
			if let action = state.pagePictureInPictureAddressBarAction(for: command, target: target) {
				return .send(.pagePictureInPictureCommandBar(action))
			}

			// While Page PiP is key, ⌘1–9 move its tab to that space (DEV-1184).
			if let action = state.pagePictureInPictureSpaceShortcut(for: command, target: target) {
				return .send(action)
			}
			guard let context = state.commandContext(for: target), command.isEnabled(in: context)
			else { return .none }

			switch command {
			case .openFocusedLinkInPeek:
				guard let tabID = state.focusedLinkSourceTab(for: target) else { return .none }
				return .run { [engine] send in
					guard let link = await engine.focusedLink(tabID) else { return }
					await send(.event(.focusedLinkRead(link)))
				}

			case .routeCurrentURL:
				guard let candidate = state.routePreviewCandidate(for: target) else { return .none }
				return .send(.routePreview(.ui(.present(candidate))))

			case .captureViewport, .captureRegion:
				guard let source = state.captureSource(for: target) else { return .none }
				return .send(.ui(.capturePage(target, source: source, region: command == .captureRegion)))

			case .reopenClosedWindow:
				return .send(.ui(.reopenClosedWindow(nil)))

			case .media:
				let source: UUID? = switch target {
				case let .window(id, _): id
				case let .peek(id): state.peeks[id: id]?.source.windowID
				default: nil
				}
				return .send(.ui(.openMediaLibrary(source)))

			case .closeWindow:
				switch target {
				case .settings: return .send(.ui(.closeSettings))
				case .onboarding: return .send(.ui(.closeOnboarding))
				case .downloads: return .send(.downloads(.ui(.dismissed)))
				case .taskManager: return .send(.taskManager(.ui(.dismissed)))
				case let .peek(id):
					guard let host = state.peeks[id: id]?.source.windowID else { return .none }

					// Pages with unsaved input are asked first (DEV-1107).
					return .send(.ui(.requestCloseWindow(host)))
				case let .window(id, _):
					if state.littleWindows[id: id] != nil {
						return .send(.littleWindows(.element(id: id, action: .ui(.close))))
					}
					return .send(.ui(.requestCloseWindow(id)))
				case .application: return .none
				}

			case .closeTab where target == .settings:
				return .send(.ui(.closeSettings))

			case .closeTab where target == .onboarding:
				return .send(.ui(.closeOnboarding))

			case .closeTab where target == .downloads:
				return .send(.downloads(.ui(.dismissed)))

			case .closeTab where target == .taskManager:
				return .send(.taskManager(.ui(.dismissed)))

			case .downloads:
				let source: UUID? = switch target {
				case let .window(id, _): id
				case let .peek(id): state.peeks[id: id]?.source.windowID
				default: nil
				}
				return .send(.ui(.openDownloads(source)))

			case .settings:
				return .send(.ui(.openSettings))

			case .taskManager:
				return .send(.taskManager(.ui(.present)))

			case .sendFeedback:
				return .send(.ui(.sendFeedback(state.feedbackHost(for: target))))

			case .extensions:
				guard case let .window(id, _) = target, let profileID = state.windowProfileID(id)
				else { return .none }
				return .send(.ui(.openExtensions(profileID)))

			case .chromeWebStore:
				guard case let .window(id, _) = target, let profileID = state.windowProfileID(id)
				else { return .none }
				return .send(.openWebstore(profileID))

			case .onboarding:
				return .send(.ui(.openOnboarding))

			case .newWindow:
				return .send(.ui(.newWindow))

			case .newPrivateWindow:
				return .send(.ui(.newPrivateWindow))

			case .littleArx:
				let space: Space.ID? = switch target {
				case let .window(id, _) where id == state.main.id:
					state.main.sidebar.spaceID

				case let .window(id, _):
					state.windows[id: id]?.sidebar.spaceID ?? state.littleWindows[id: id]?.spaceID

				case let .peek(id):
					state.peeks[id: id]?.source.spaceID

				default:
					nil
				}
				return .send(.ui(.openLittleArx(space)))

			case .quit:
				return .send(.ui(.confirmQuit))

			case .pageSetup:
				return .send(.ui(.pageSetup))

			case .pagePictureInPicture:
				// Little Arx turns itself into Page PiP, and back (DEV-1112).
				if case let .window(id, _) = target, let little = state.littleWindows[id: id] {
					guard !little.isCommandOnly, little.viewer.tab?.isChat != true else { return .none }

					let entering = !little.isPictureInPicture

					// A page can't fill the screen and float at once.
					if entering, state.pageFullScreen?.windowID == id { state.pageFullScreen = nil }
					return .send(.littleWindows(.element(id: id, action: .ui(.setPictureInPicture(entering)))))
				}
				guard let tabID = state.pagePictureInPictureTab(for: target) else { return .none }

				// The command brings a floating page back, and floats any other.
				let floats = state.pagePictureInPicture?.tabID == tabID
				return .send(.ui(floats ? .closePagePictureInPicture(focusesTab: true) : .openPagePictureInPicture(tabID)))

			case .mediaPictureInPicture:
				guard
					let tabID = state.mediaPictureInPictureTab(for: target),
					let source = state.presentableMedia(of: tabID)
				else { return .none }

				return .send(.media(.ui(.perform(source.id, .enterPictureInPicture))))

			case .darkPage:
				guard let change = state.toggleDarkPage(for: target) else { return .none }
				return .send(.settings(.delegate(.changeOrganization(change))))

			case .castTab:
				guard let request = state.castTab(for: target) else { return .none }
				return .send(.cast(.open(request.tabID, windowID: request.windowID)))

			// Hide Element (DEV-1019) on the page of the pane, Peek or Little Arx it came from, from the
			// menu, its keys, the command bar or the site menu alike: Arx's own mode, where its
			// feature flag is on and the engine has it (DEV-1201, DEV-1298), else uBlock's picker.
			// Again on a page in the mode, it's Done.
			case .hideElement:
				return hideElement(on: target, state: &state)

			case .printPage, .savePageAs:
				guard let source = state.captureSource(for: target) else { return .none }
				return .send(.ui(command == .printPage ? .printPage(source) : .savePage(source)))

			case .openFile:
				guard case let .window(id, _) = target else { return .none }
				return .send(.ui(.openFile(id)))

			default:
				break
			}

			if case let .peek(id) = target {
				guard let peek = state.peeks[id: id] else { return .none }

				let navigation = peek.viewer.navigation
				let item = LinkCopyItem(
					title: navigation.title.isEmpty ? peek.tab.displayTitle : navigation.title,
					url: navigation.url ?? peek.tab.restoration.url
				)
				if let mode = command.linkMode {
					return .send(.ui(.copyLinks(mode, items: [item], sourceWindowID: peek.source.windowID)))
				}
				if command == .shareProxyLink {
					return .send(.ui(.shareProxyLinks(items: [item], sourceWindowID: peek.source.windowID)))
				}
				if command == .sharePage {
					return .send(.sharePage(item, sourceWindowID: peek.source.windowID))
				}

				let action: PeekFeature.Action
				switch command {
				case .address:
					action = .ui(.focusLocation)

				case .closeTab:
					action = .ui(.close)

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
				return .send(.peeks(.element(id: id, action: action)))
			}

			let id: UUID
			let paneID: UUID?
			if case let .window(windowID, originPaneID) = target {
				id = windowID
				paneID = originPaneID ?? state.commandPaneID(in: windowID)
			} else {
				guard [.newTab, .address, .commandBar].contains(command) else { return .none }

				// These open the main window, which launch onboarding holds back (DEV-838).
				guard !state.mainWindowWaitsForOnboarding else {
					state.bringOnboardingForward()
					return .none
				}

				return .concatenate(
					.send(.ui(.openWindow)),
					.send(.ui(.command(command, .window(state.main.id))))
				)
			}

			// Over an open command bar, Copy URL copies the highlighted result's address (DEV-810).
			if command == .copyURL, let action = state.commandBarCopiesURL(in: id) {
				return .send(action)
			}

			// Link items are captured from the originating host, never a later focused host.
			if let mode = command.linkMode {
				guard let item = state.linkItems(in: id, paneID: paneID).first else { return .none }
				return .send(.ui(.copyLinks(mode, items: [item], sourceWindowID: id, sourcePaneID: paneID)))
			}
			if command == .shareProxyLink {
				guard let item = state.linkItems(in: id, paneID: paneID).first else { return .none }
				return .send(.ui(.shareProxyLinks(items: [item], sourceWindowID: id, sourcePaneID: paneID)))
			}

			// Share… shares the page's own address with its title (DEV-818).
			if command == .sharePage {
				guard let item = state.linkItems(in: id, paneID: paneID).first else { return .none }
				return .send(.sharePage(item, sourceWindowID: id))
			}

			if case let .little(origin) = source {
				return .send(.littleWindows(.element(id: id, action: .dispatchCommand(command, source: origin))))
			}
			if case let .main(origin) = source, let paneID {
				let action = MainFeature.Action.dispatchCommand(command, paneID, source: origin)
				return id == state.main.id ? .send(.main(action)) : .send(.windows(.element(id: id, action: action)))
			}

			if state.littleWindows[id: id] != nil {
				switch command {
				case .newTab:
					return .send(.littleWindows(.element(id: id, action: .ui(.openCommand(.newTab)))))

				case .address:
					return .send(.littleWindows(.element(id: id, action: .ui(.openCommand(.currentTab)))))

				case .commandBar:
					// Over an open bar, ⌘K shows or hides the highlighted result's actions (DEV-810).
					let action: LittleArxFeature.Action = state.littleWindows[id: id]?.commandBar.isPresented == true
					? .commandBar(.ui(.actionsToggled))
					: .ui(.openCommand(.commands))
					return .send(.littleWindows(.element(id: id, action: action)))

				case .closeTab:
					return .send(.littleWindows(.element(id: id, action: .ui(.close))))

				case .copyURL:
					return .send(.littleWindows(.element(id: id, action: .ui(.copyURL))))

				case .goBack, .goForward, .reload, .clearCacheAndReload, .reloadBypassingCache,
					.zoomIn, .zoomOut, .actualSize, .developerTools, .inspectElement, .javaScriptConsole, .stopLoading:
					guard let engineCommand = command.engineCommand else { return .none }
					return .send(.littleWindows(.element(id: id, action: .viewer(.ui(.command(engineCommand))))))

				case .findInPage, .findNext, .findPrevious:
					guard let find = command.findAction else { return .none }
					return .send(.littleWindows(.element(id: id, action: .viewer(.ui(find)))))

				case .readingMode:
					guard let reader = command.readerAction else { return .none }
					return .send(.littleWindows(.element(id: id, action: .viewer(.ui(reader)))))

				default:
					return .none
				}
			}

			guard let paneID else { return .none }

			// Translate Page acts on the pane's tab in the app, where translations live (DEV-904).
			// Private windows translate with the `ARX_TRANSLATE` feature flag (DEV-996).
			if command == .translatePage {
				let window = id == state.main.id ? state.main : state.windows[id: id]
				guard
					let window,
					!window.isPrivate || state.translationFeatureFlag,
					let tab = window.viewer.panes[id: paneID]?.item.tab ?? window.viewer.item.tab
				else { return .none }

				return .send(.translation(.toggle(tab.id)))
			}

			let action: MainFeature.Action
			switch command {
			case .newTab, .address, .commandBar, .closeTab, .copyURL, .duplicateTab, .pinTab,
				.archiveSelectedTabs, .findInPage, .findNext, .findPrevious, .goBack, .goForward, .reload,
				.clearCacheAndReload, .reloadBypassingCache, .zoomIn, .zoomOut, .actualSize, .developerTools,
				.inspectElement, .javaScriptConsole, .newSplit, .focusOtherPane,
				.closePane, .swapPanes, .toggleSplitOrientation, .stopLoading, .viewSource, .readingMode:
				action = .ui(.paneCommand(command, paneID))

			case .openArchive:
				action = .ui(.openArchive)

			case .reopenLastClosedTab:
				action = .ui(.reopenLastClosedTab)

			case .newFolder:
				action = .sidebar(.ui(.sidebar(.newFolder(nil))))

			case .undoOrganization:
				action = .sidebar(.ui(.undo))

			case .toggleSidebar:
				// Over a page in full screen, ⌘S shows the sidebar beside it instead (DEV-991).
				guard state.pageFullScreen?.windowID != id else { return .none }

				action = .sidebar(.ui(.sidebar(.toggleSidebar)))

			default:
				let window = id == state.main.id ? state.main : state.windows[id: id]
				guard let organization = window?.organizationAction(for: command) else { return .none }
				action = organization
			}
			return id == state.main.id ? .send(.main(action)) : .send(.windows(.element(id: id, action: action)))
		}
	}
}

extension BrowserCommand {
	fileprivate var linkMode: LinkCopyMode? {
		switch self {
		case .copyURL: .original
		case .copyCleanLink: .clean
		case .copyMarkdownOriginal: .markdownOriginal
		case .copyProxyLink: .proxy
		case .copyMarkdownProxy: .markdownProxy
		default: nil
		}
	}
}

extension AppFeature.State {
	/// Copy URL for a window whose command bar is open on a result that offers it: the bar runs
	/// the result's Copy URL instead of copying the page under it (DEV-810).
	internal func commandBarCopiesURL(in windowID: UUID) -> AppFeature.Action? {
		let copy: CommandBarFeature.Action = .ui(.actionRequested(CommandBarFeature.State.copyURLActionID))
		if let little = littleWindows[id: windowID] {
			guard little.commandBarContext != nil, little.commandBar.offersCopyURL else { return nil }
			return .littleWindows(.element(id: windowID, action: .commandBar(copy)))
		}
		guard
			let window = window(windowID),
			window.commandBarContext != nil,
			window.commandBar.offersCopyURL
		else { return nil }

		return windowID == main.id
		? .main(.commandBar(copy))
		: .windows(.element(id: windowID, action: .commandBar(copy)))
	}
}

// MARK: - Use Selection for Find

extension AppFeature.State {
	/// Only actual page targets accept a selection copied by Chromium. Native Settings
	/// fields and DevTools keep their own responder-chain find behavior.
	/// The page Hide Element acts on (DEV-1298): the pane's, Peek's or Little Arx's, with whether
	/// it's in a private window, where Arx doesn't hide elements.
	internal func hideElementPage(for target: AppFeature.CommandTarget) -> (item: ViewerItemFeature.State, isPrivate: Bool)? {
		switch target {
		case let .peek(id):
			guard let peek = peeks[id: id] else { return nil }
			let window = peek.source.windowID == main.id ? main : windows[id: peek.source.windowID]
			return (peek.viewer, window?.isPrivate ?? false)

		case let .window(id, paneID):
			// Little Arx never opens on a private window.
			if let little = littleWindows[id: id] { return (little.viewer, false) }
			guard let window = id == main.id ? main : windows[id: id] else { return nil }
			guard let item = window.viewer.panes[id: paneID ?? window.viewer.activePaneID]?.item else { return nil }
			return (item, window.isPrivate)

		default:
			return nil
		}
	}

	internal func findSelectionItem(in target: AppFeature.CommandTarget) -> ViewerItemFeature.State? {
		guard let context = commandContext(for: target), BrowserCommand.findInPage.isEnabled(in: context)
		else { return nil }
		switch target {
		case let .peek(id): return peeks[id: id]?.viewer
		case let .window(id, paneID):
			if let little = littleWindows[id: id] { return little.viewer }
			guard let window = id == main.id ? main : windows[id: id] else { return nil }
			return window.viewer.panes[id: paneID ?? window.viewer.activePaneID]?.item
		default: return nil
		}
	}

	internal func findSelectionAction(
		_ text: String,
		in target: AppFeature.CommandTarget,
		from captured: ViewerItemFeature.State
	) -> AppFeature.Action? {
		guard
			let item = findSelectionItem(in: target),
			item.tab?.id == captured.tab?.id,
			item.generation == captured.generation,
			item.navigation.url == captured.navigation.url,
			item.findQuery == captured.findQuery
		else { return nil }
		let action = ViewerItemFeature.Action.ui(.findSeeded(text))
		switch target {
		case let .peek(id): return .peeks(.element(id: id, action: .viewer(action)))
		case let .window(id, paneID):
			if littleWindows[id: id] != nil { return .littleWindows(.element(id: id, action: .viewer(action))) }
			guard let window = id == main.id ? main : windows[id: id] else { return nil }
			let viewer = ViewerFeature.Action.panes(.element(id: paneID ?? window.viewer.activePaneID, action: .item(action)))
			return id == main.id ? .main(.viewer(viewer)) : .windows(.element(id: id, action: .viewer(viewer)))
		default: return nil
		}
	}
}
