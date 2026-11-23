import AppUI
import Testing

/// Open in WebKit's switch (DEV-1188): on while the page shows in WebKit, listed or not.
internal struct SiteMenuWebKitTests {
	@Test
	internal func theSwitchFollowsTheListAndThePagesEngine() {
		// Netflix off the list that moved to WebKit when its video failed.
		#expect(SiteMenu.WebKit(isListed: false, isShown: true, playsVideoOnlyInWebKit: true).isOn)
		#expect(SiteMenu.WebKit(isListed: true, isShown: true).isOn)
		// A listed site's page still in Chromium.
		#expect(SiteMenu.WebKit(isListed: true, isShown: false).isOn)
		#expect(!SiteMenu.WebKit(isListed: false, isShown: false, playsVideoOnlyInWebKit: true).isOn)
	}
}
