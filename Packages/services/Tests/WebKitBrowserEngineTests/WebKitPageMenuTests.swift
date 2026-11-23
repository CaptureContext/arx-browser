import AppKit
import BrowserCore
import Foundation
import Testing

@testable import WebKitBrowserEngine

/// DEV-1199: Arx's page menu in WebKit's context menu.
@Suite
@MainActor
internal struct WebKitPageMenuTests {
	private let tabID: Tab.ID = .init(rawValue: UUID())

	private final class Choices {
		var chosen: [(Tab.ID, BrowserCommand)] = []
	}

	private func menu(
		_ commands: Set<BrowserCommand> = WebKitPageMenu.allCommands,
		choices: Choices = .init()
	) -> WebKitPageMenu {
		.init(
			commands: { _ in commands },
			title: { "\($0)" },
			exitFullScreenTitle: "exitFullScreen",
			choose: { tabID, command in choices.chosen.append((tabID, command)) }
		)
	}

	/// WebKit's menu with items of these identifiers; nil is a separator.
	private func webKitMenu(_ identifiers: [String?]) -> NSMenu {
		let menu = NSMenu()
		for identifier in identifiers {
			guard let identifier else {
				menu.addItem(.separator())
				continue
			}
			let item = NSMenuItem(title: "webKit.\(identifier.replacingOccurrences(of: "WKMenuItemIdentifier", with: ""))", action: nil, keyEquivalent: "")
			item.identifier = .init(identifier)
			menu.addItem(item)
		}
		return menu
	}

	private func titles(_ menu: NSMenu) -> [String] {
		menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
	}

	@Test
	internal func thePagesBackgroundGetsArxsPageMenuInPlaceOfWebKitsNavigation() {
		let menu = webKitMenu([
			"WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward", "WKMenuItemIdentifierReload",
			nil, "WKMenuItemIdentifierInspectElement",
		])

		self.menu().adjust(menu, for: tabID, exitFullScreen: nil)

		#expect(titles(menu) == [
			"goBack", "goForward", "reload",
			"—", "savePageAs", "printPage", "sharePage",
			"—", "viewSource",
			"—", "webKit.InspectElement",
		])
	}

	@Test
	internal func onlyWhatTheHostCanDoNowIsShown() {
		// Netflix's player: WebKit offers Back and Reload; there's nowhere forward to go.
		let menu = webKitMenu(["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierReload"])

		self.menu([.goBack, .reload, .printPage]).adjust(menu, for: tabID, exitFullScreen: nil)

		#expect(titles(menu) == ["goBack", "reload", "—", "printPage"])
	}

	@Test
	internal func castAndTranslateNeverShow() {
		#expect(!WebKitPageMenu.allCommands.contains(.castTab))
		#expect(!WebKitPageMenu.allCommands.contains(.translatePage))
		let menu = webKitMenu(["WKMenuItemIdentifierReload"])

		self.menu(Set(BrowserCommand.allCases)).adjust(menu, for: tabID, exitFullScreen: nil)

		#expect(!titles(menu).contains("castTab"))
		#expect(!titles(menu).contains("translatePage"))
	}

	@Test
	internal func linkImageAndSelectionMenusStayWebKits() {
		let menus = [
			["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierCopyLink"],
			["WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierCopyImage"],
			["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierSearchWeb"],
			// A link on a page WebKit would otherwise give Back and Reload.
			["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierReload"],
		]
		for identifiers in menus {
			let menu = webKitMenu(identifiers)
			let before = titles(menu)

			self.menu().adjust(menu, for: tabID, exitFullScreen: nil)

			#expect(titles(menu) == before)
		}
	}

	@Test
	internal func aVideosMenuKeepsItsItemsAndGetsThePageMenuBeforeInspect() {
		let menu = webKitMenu([
			"WKMenuItemIdentifierShowHideMediaControls", "WKMenuItemIdentifierToggleFullScreen",
			nil, "WKMenuItemIdentifierInspectElement",
		])

		self.menu([.goBack, .reload, .viewSource]).adjust(menu, for: tabID, exitFullScreen: {})

		// WebKit's own Exit Full Screen for the video stands; Arx doesn't add a second.
		#expect(titles(menu) == [
			"webKit.ShowHideMediaControls", "webKit.ToggleFullScreen",
			"—", "goBack", "reload", "—", "viewSource",
			"—", "webKit.InspectElement",
		])
	}

	@Test
	internal func exitFullScreenLeadsWhileThePageIsInFullScreen() {
		let menu = webKitMenu(["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierReload"])
		var exited = 0

		self.menu([.goBack, .reload]).adjust(menu, for: tabID, exitFullScreen: { exited += 1 })

		#expect(titles(menu) == ["exitFullScreen", "—", "goBack", "reload"])
		let item = menu.items[0]
		_ = (item.target as? NSObject)?.perform(item.action, with: item)
		#expect(exited == 1)
	}

	@Test
	internal func choosingAnItemSendsItsCommandForTheTab() throws {
		let choices = Choices()
		let menu = webKitMenu(["WKMenuItemIdentifierReload"])
		self.menu(choices: choices).adjust(menu, for: tabID, exitFullScreen: nil)

		let print = try #require(menu.items.first { $0.title == "printPage" })
		_ = (print.target as? NSObject)?.perform(print.action, with: print)

		#expect(choices.chosen.map(\.0) == [tabID])
		#expect(choices.chosen.map(\.1) == [.printPage])
	}

	@Test
	internal func noCommandsLeavesWebKitsMenuWithoutItsNavigation() {
		let menu = webKitMenu(["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierReload", nil, "WKMenuItemIdentifierInspectElement"])

		self.menu([]).adjust(menu, for: tabID, exitFullScreen: nil)

		// Nothing the host can carry out: WebKit's menu stays as it was.
		#expect(titles(menu) == ["webKit.GoBack", "webKit.Reload", "—", "webKit.InspectElement"])
	}

	@Test
	internal func inspectElementFollowsDeveloperModeOnEveryPage() {
		let pages = WebKitPages()
		let profile: Profile.ID = .init(rawValue: UUID())
		func tab() -> Tab {
			.init(id: .init(rawValue: UUID()), profileID: profile, restoration: .init(title: "", url: URL(string: "https://www.netflix.com")!))
		}
		let before = pages.make(tab(), isPrivate: true, returnsToChromium: false)
		#expect(!before.webView.isInspectable)

		pages.isInspectable = true
		let after = pages.make(tab(), isPrivate: true, returnsToChromium: false)
		#expect(before.webView.isInspectable)
		#expect(after.webView.isInspectable)

		pages.isInspectable = false
		#expect(!before.webView.isInspectable)
		#expect(!after.webView.isInspectable)
		pages.close(before.tabID)
		pages.close(after.tabID)
	}

	@Test
	internal func aPagesMenuIsThePagesSetsCurrentOne() {
		let pages = WebKitPages()
		let tab = Tab(
			id: .init(rawValue: UUID()),
			profileID: .init(rawValue: UUID()),
			restoration: .init(title: "", url: URL(string: "https://www.netflix.com")!)
		)
		let page = pages.make(tab, isPrivate: true, returnsToChromium: false)
		#expect(page.pageMenu?() == nil)

		pages.pageMenu = menu()
		#expect(page.pageMenu?() != nil)
		#expect(page.webView is WebKitPageView)
		pages.close(tab.id)
		#expect(page.pageMenu == nil)
	}

	@Test
	internal func aWebArchivesMainResourceIsTheDocumentTheServerSent() throws {
		let html = Data("<html>hi</html>".utf8)
		let archive = try PropertyListSerialization.data(
			fromPropertyList: ["WebMainResource": ["WebResourceData": html, "WebResourceURL": "https://example.com/"]],
			format: .binary,
			options: 0
		)

		#expect(try WebKitPage.mainResource(of: archive) == html)
		#expect(throws: (any Error).self) { try WebKitPage.mainResource(of: Data("nope".utf8)) }
	}
}
