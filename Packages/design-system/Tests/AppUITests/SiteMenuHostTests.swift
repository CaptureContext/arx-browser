import AppUI
import BrowserCore
import CoreGraphics
import Testing

/// Which items the site menu shows in each window that opens it (DEV-1257): all of them in a main
/// window, and in Little Arx and Page PiP everything that makes sense in a floating window.
@Suite
internal struct SiteMenuHostTests {
	@Test
	internal func aMainWindowShowsEveryItem() {
		#expect(SiteMenu.Host.mainWindow.items == SiteMenu.Item.allCases)
	}

	@Test
	internal func littleArxLeavesOutWhatActsOnAMainWindow() {
		#expect(SiteMenu.Host.littleArx.items == [
			.share, .captureViewport, .captureRegion, .pagePictureInPicture, .readingMode,
			.extensions, .addExtension, .manageExtensions, .permissions, .contentBlocking, .zoom,
			.devices, .hiddenElements, .webKit, .clearSiteData, .allSiteSettings,
		])
	}

	@Test
	internal func pagePictureInPictureLeavesOutWhatAFloatingPageCantTake() {
		#expect(SiteMenu.Host.pagePictureInPicture.items == [
			.share, .extensions, .addExtension, .manageExtensions, .permissions, .contentBlocking,
			.zoom, .devices, .hiddenElements, .clearSiteData, .allSiteSettings,
		])
	}

	@Test
	internal func theMenuAsksItsWindow() {
		let menu = SiteMenu(hostWindow: .pagePictureInPicture, host: "capturecontext.dev", connection: .secure)
		#expect(menu.shows(.share))
		#expect(!menu.shows(.captureRegion))
		#expect(SiteMenu(host: "capturecontext.dev", connection: .secure).hostWindow == .mainWindow)
	}

	@Test(arguments: [
		(SiteMenuAction.share, SiteMenu.Item.share),
		(.captureViewport, .captureViewport),
		(.captureRegion, .captureRegion),
		(.pagePictureInPicture, .pagePictureInPicture),
		(.readingMode, .readingMode),
		(.runExtension("a", screenPoint: .zero), .extensions),
		(.turnOffExtension("a"), .extensions),
		(.addExtension, .addExtension),
		(.manageExtensions, .manageExtensions),
		(.showExtension("a"), .manageExtensions),
		(.setPermission(.camera, .allow), .permissions),
		(.setContentBlocking(false), .contentBlocking),
		(.resetZoom, .zoom),
		(.translate(true), .translation),
		(.setNeverTranslate(true), .translation),
		(.forgetDevice("d"), .devices),
		(.showHiddenElement("f"), .hiddenElements),
		(.hideElement, .hideElement),
		(.setWebKit(true), .webKit),
		(.setDarkPage(false), .darkPage),
		(.requestClear(.cookies), .clearSiteData),
		(.allSiteSettings, .allSiteSettings),
	])
	internal func anActionComesFromItsItem(
		_ action: SiteMenuAction,
		_ item: SiteMenu.Item
	) {
		#expect(SiteMenu.Item(action) == item)
	}

	@Test(arguments: [
		SiteMenuAction.opened, .closed, .confirmClear, .cancelClear, .confirmExtensionRemoval,
		.cancelExtensionRemoval, .dismissNotice,
	])
	internal func answersAndOpeningBelongToNoItem(_ action: SiteMenuAction) {
		#expect(SiteMenu.Item(action) == nil)
	}
}
