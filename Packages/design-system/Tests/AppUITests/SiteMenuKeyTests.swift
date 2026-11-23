import AppUI
import BrowserCore
import Testing

/// The site menu's keys and pop-ups (DEV-1333): two rows of four, switches that say whether they're
/// on, and pop-ups that show the value the site gets with "Default (…)" only in the open menu.
@Suite
internal struct SiteMenuKeyTests {
	@Test
	internal func aMainWindowShowsTwoRowsOfFour() {
		let menu = Self.menu(.mainWindow)
		#expect(menu.keyRows.map { $0.map(\.id) } == [
			[.share, .captureRegion, .capturePage, .hideElement],
			[.pagePictureInPicture, .readingMode, .webKit, .darkPage],
		])
	}

	@Test
	internal func floatingWindowsLeaveOutTheKeysTheyDontShow() {
		#expect(Self.menu(.littleArx).keys.map(\.id) == [
			.share, .captureRegion, .capturePage, .pagePictureInPicture, .readingMode, .webKit,
		])
		#expect(Self.menu(.pagePictureInPicture).keys.map(\.id) == [.share])
	}

	@Test
	internal func readerStaysHiddenBehindItsFlag() {
		var menu = Self.menu(.mainWindow)
		menu.canRead = nil
		#expect(!menu.keys.contains { $0.id == .readingMode })
	}

	@Test
	internal func switchesSayWhetherTheyreOn() throws {
		var menu = Self.menu(.mainWindow)
		menu.webKit = .init(isListed: false, isShown: false)
		menu.darkPage = true
		#expect(try #require(menu.keys.first { $0.id == .webKit }).isOn == false)
		#expect(try #require(menu.keys.first { $0.id == .darkPage }).isOn == true)

		// A page that moved to WebKit from the fallback prompt is in WebKit, though not listed.
		menu.webKit = .init(isListed: false, isShown: true)
		menu.darkPage = false
		#expect(try #require(menu.keys.first { $0.id == .webKit }).isOn == true)
		#expect(try #require(menu.keys.first { $0.id == .darkPage }).isOn == false)

		// Actions aren't switches.
		#expect(menu.keys.filter { $0.isOn != nil }.map(\.id) == [.webKit, .darkPage])
	}

	@Test
	internal func keysThePageCantTakeAreDimmedInPlace() throws {
		var menu = Self.menu(.mainWindow)
		menu.canRead = false
		menu.canCapture = false
		menu.webKit = nil
		menu.darkPage = nil
		menu.hiddenElements = nil
		#expect(menu.keys.count == 8)
		#expect(menu.keys.filter(\.isEnabled).map(\.id) == [.share, .pagePictureInPicture])

		// Hide Element waits for blocking to be on for the site.
		menu = Self.menu(.mainWindow)
		menu.canHideElement = false
		#expect(try #require(menu.keys.first { $0.id == .hideElement }).isEnabled == false)

		// A switch waits while a change applies.
		menu = Self.menu(.mainWindow)
		menu.isApplying = true
		#expect(try #require(menu.keys.first { $0.id == .darkPage }).isEnabled == false)
	}

	@Test
	internal func aDefaultChoiceShowsWhatItGivesAndChecksDefault() {
		let choice = SiteMenu.Permission(permission: .camera, setting: nil, defaultSetting: .ask).choice
		#expect(choice.effective == .ask)
		#expect(choice.isDefault)
		#expect(choice.entries == [
			.init(value: nil, isChecked: true),
			.init(value: .allow, isChecked: false),
			.init(value: .block, isChecked: false),
			.init(value: .ask, isChecked: false),
		])
	}

	@Test
	internal func aStoredChoiceShowsAndChecksItself() {
		let choice = SiteMenu.Permission(permission: .popups, setting: .allow, defaultSetting: .block).choice
		#expect(choice.effective == .allow)
		#expect(!choice.isDefault)
		#expect(choice.entries.filter(\.isChecked).map(\.value) == [.allow])

		// A stored value equal to the default is still the site's own: Ask is checked, not Default.
		let same = SiteMenu.Permission(permission: .camera, setting: .ask, defaultSetting: .ask).choice
		#expect(same.effective == .ask)
		#expect(same.entries.filter(\.isChecked).map(\.value) == [.ask])
	}

	@Test
	internal func unreadBadgesChooseTheSameWay() {
		let inherits = SiteMenu.UnreadBadges(site: nil, inherited: .show).choice
		#expect(inherits.effective == .show)
		#expect(inherits.entries.first == .init(value: nil, isChecked: true))
		#expect(inherits.options == [.show, .hide])

		let hides = SiteMenu.UnreadBadges(site: .hide, inherited: .show).choice
		#expect(hides.effective == .hide)
		#expect(hides.entries.filter(\.isChecked).map(\.value) == [.hide])
	}

	private static func menu(_ host: SiteMenu.Host) -> SiteMenu {
		SiteMenu(
			hostWindow: host,
			host: "capturecontext.dev",
			connection: .secure,
			canRead: true,
			webKit: .init(isListed: false, isShown: false),
			darkPage: true,
			hiddenElements: []
		)
	}
}
