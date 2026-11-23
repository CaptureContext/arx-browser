import AppUI
import BrowserCore
import CommandBarFeature

extension LittleArxFeature.State {
	public var commandContext: BrowserCommandContext {
		.init(
			host: .little,
			hasTab: !isCommandOnly,
			// A private Little Arx (DEV-1323): no command that keeps or moves its page.
			isPrivate: isPrivate,
			isBusy: isPromoting || isSwitchingProfile || peekID != nil,
			isClosing: isClosing,
			canGoBack: viewer.navigation.canGoBack,
			canGoForward: viewer.navigation.canGoForward,
			isLoading: viewer.navigation.isLoading,
			canSavePage: viewer.navigation.showsWebPage,
			captureAvailable: captureAvailable,
			downloadsAvailable: downloadsAvailable,
			mediaAvailable: mediaAvailable,
			canPresentMedia: canPresentMedia,
			developerModeEnabled: developerModeEnabled,
			readingModeEnabled: readingModeEnabled,
			isReading: viewer.reader != nil,
			usesWebKit: viewer.navigation.engine == .webKit,
			canHideElements: canHideElements,
			// The page's address, as the proxy link commands copy it (DEV-1262).
			canProxyLink: !isCommandOnly
				&& LinkTransformer.proxies(viewer.navigation.url ?? tab.restoration.url, rules: proxyLinkRules)
		)
	}

	internal var commandCandidates: [CommandBarFeature.Entry] {
		let commands = CommandBarFeature.Entry.commands(
			in: commandContext,
			bindings: keyboardShortcuts,
			aliases: commandAliases
		)
		return isCommandOnly ? launcherSuggestions + commands : commands
	}
}
