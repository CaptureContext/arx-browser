import BrowserCore
import _ComposableArchitecture

extension AppFeature.State {
	/// Developer mode is one app-wide preference. Every window's command context
	/// reads the same value, including windows created after it changed, and so do the
	/// `ARX_DEVICE_CAPTURE` (DEV-757), `ARX_HIDE_ELEMENT` (DEV-1019) and `ARX_TRANSLATE`
	/// (DEV-1122) feature flags. The
	/// extension manager receives it as an action so that turning it off also
	/// withdraws an open folder picker.
	internal mutating func reconcileDeveloperMode() -> Effect<AppFeature.Action> {
		let isEnabled = settings.general.developerModeEnabled
		let showsHeader = isEnabled && settings.general.developerHeaderEnabled
		let deviceCapture = deviceCaptureEnabled
		if main.developerModeEnabled != isEnabled { main.developerModeEnabled = isEnabled }
		if main.showsDeveloperHeader != showsHeader { main.showsDeveloperHeader = showsHeader }
		if main.deviceCaptureEnabled != deviceCapture { main.deviceCaptureEnabled = deviceCapture }
		for id in windows.ids where windows[id: id]?.developerModeEnabled != isEnabled {
			windows[id: id]?.developerModeEnabled = isEnabled
		}
		for id in windows.ids where windows[id: id]?.showsDeveloperHeader != showsHeader {
			windows[id: id]?.showsDeveloperHeader = showsHeader
		}
		for id in windows.ids where windows[id: id]?.deviceCaptureEnabled != deviceCapture {
			windows[id: id]?.deviceCaptureEnabled = deviceCapture
		}
		let hideElement = hideElementEnabled
		if main.siteMenu.hideElementEnabled != hideElement { main.siteMenu.hideElementEnabled = hideElement }
		for id in windows.ids where windows[id: id]?.siteMenu.hideElementEnabled != hideElement {
			windows[id: id]?.siteMenu.hideElementEnabled = hideElement
		}
		for id in floatingSiteMenus.ids where floatingSiteMenus[id: id]?.siteMenu.hideElementEnabled != hideElement {
			floatingSiteMenus[id: id]?.siteMenu.hideElementEnabled = hideElement
		}
		let translates = translationFeatureFlag
		if main.pageTranslationEnabled != translates { main.pageTranslationEnabled = translates }
		for id in windows.ids where windows[id: id]?.pageTranslationEnabled != translates {
			windows[id: id]?.pageTranslationEnabled = translates
		}
		for id in littleWindows.ids where littleWindows[id: id]?.developerModeEnabled != isEnabled {
			littleWindows[id: id]?.developerModeEnabled = isEnabled
		}

		guard settings.extensions.developerModeEnabled != isEnabled
		else { return .none }

		return .send(.settings(.extensions(.configureDeveloperMode(isEnabled))))
	}
}
