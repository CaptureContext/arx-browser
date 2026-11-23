import BrowserCore
import ChromiumEngine

/// Dark pages (DEV-1020): Blink's forced darkening for sites without a dark look of their own.
///
/// The engine keeps one configuration. A page gets it as it's created, before its first site
/// loads: the default for new pages starts their blank document dark, and the page's own setting
/// carries its profile's sites. A change goes to every open page.
extension ChromiumBrowserEngine {
	internal func setDarkPages(_ configuration: DarkPagesConfiguration) {
		guard runtime.supportsDarkPages, configuration != darkPages else { return }

		let wasActive = darkPages.isActive
		darkPages = configuration
		if configuration.isActive != wasActive {
			runtime.setDefaultDarkPages(enabled: configuration.isActive)
		}
		for id in openPageIDs {
			applyDarkPages(to: id)
		}
	}

	/// Gives the tab's page the current configuration with its profile's sites.
	internal func applyDarkPages(to id: Tab.ID) {
		guard
			runtime.supportsDarkPages,
			let page = chromiumPage(id),
			let profile = pageProfiles[id]
		else { return }

		runtime.setDarkPages(
			page,
			enabled: darkPages.isActive,
			offSites: darkPages.offSites(for: profile)
		)
	}
}
