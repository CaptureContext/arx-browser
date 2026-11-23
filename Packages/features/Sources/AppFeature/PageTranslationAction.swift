import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import PageTranslationClient
import SettingsFeature
import _ComposableArchitecture

@CasePathable
public enum PageTranslationAction: Sendable {
	/// Translate Page, or Show Original when the page is translated.
	case toggle(BrowserCore.Tab.ID)
	case start(BrowserCore.Tab.ID, automatic: Bool)

	/// Choose Another Language: translates into `target`, from the original (DEV-996).
	case translateInto(BrowserCore.Tab.ID, target: String)
	case showOriginal(BrowserCore.Tab.ID)

	/// The tab's original text is back: Show Original's restore, or a translation's restore-first,
	/// ran to the end.
	case restored(BrowserCore.Tab.ID)
	case detected(BrowserCore.Tab.ID, source: String)
	case progressed(BrowserCore.Tab.ID)
	case stopped(BrowserCore.Tab.ID, PageTranslationProblem?)

	/// The language of the page the tab loaded (DEV-996).
	case languageRead(BrowserCore.Tab.ID, PageLanguage)

	/// Whether the page can be translated with the settings as they are now (DEV-996).
	case availabilityRead(BrowserCore.Tab.ID, PageLanguage)
	case languagesLoaded(TranslationLanguages)

	/// The URL bar's popover, for this tab (DEV-996).
	case offer(BrowserCore.Tab.ID, PageTranslationOfferAction)

	/// Turns the `ARX_TRANSLATE` feature flag on or off for this run, as tests do (DEV-996).
	case featureFlag(Bool)
}
