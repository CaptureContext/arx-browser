import AppKit
import AppUI
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import LittleArxFeature
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// The link status (DEV-1111): what a click on a hovered link will do, with every modifier
/// combination, from every kind of page, as Settings and routing decide it.
@Suite(.dependencies)
@MainActor
internal struct LinkStatusTests {
	private static let link = URL(string: "https://github.com/emilkowalski/skills/tree/main/skills/apple-design")!

	private func state(preferences: BrowserPreferences = .init()) -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = withDependencies {
			$0.workspaceDocument = .unsaved(preferences)
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		state.main.sidebar.select(organization.spaces[0].unpinnedTabs[0])
		state.main.viewer.item.tab = organization.tabs[id: organization.spaces[0].unpinnedTabs[0]]
		return state
	}

	private func hovered(
		_ tab: BrowserCore.Tab,
		url: URL = link,
		isPrivate: Bool = false,
		isCrossSite: Bool = false,
		target: BrowserHoveredLink.Target = .mainFrame
	) -> BrowserHoveredLink {
		.init(tabID: tab.id, profileID: tab.profileID, isPrivate: isPrivate, url: url, isCrossSite: isCrossSite, target: target)
	}

	private func outcomes(
		_ state: AppFeature.State,
		_ link: BrowserHoveredLink,
		opensInWebKit: Bool = false
	) -> [String: LinkClickOutcome] {
		let keys: [(String, NSEvent.ModifierFlags)] = [
			("click", []),
			("⌘", [.command]),
			("⇧⌘", [.shift, .command]),
			("⇧", [.shift]),
			("⌥", [.option]),
			("⌥⌘", [.option, .command]),
			("⇧⌥⌘", [.shift, .option, .command]),
			("⇧⌥", [.shift, .option]),
			("⌃", [.control]),
		]
		return Dictionary(uniqueKeysWithValues: keys.map { name, modifiers in
			(name, state.linkClickOutcome(for: link, modifiers: modifiers, opensInWebKit: opensInWebKit))
		})
	}

	// MARK: - Chromium's choice

	@Test
	internal func modifierKeysMakeChromiumsChoice() {
		expectNoDifference(LinkClickDisposition([]), .currentTab)
		expectNoDifference(LinkClickDisposition([.command]), .backgroundTab)
		expectNoDifference(LinkClickDisposition([.shift, .command]), .foregroundTab)
		expectNoDifference(LinkClickDisposition([.option, .command]), .backgroundTab)
		expectNoDifference(LinkClickDisposition([.shift]), .window)
		expectNoDifference(LinkClickDisposition([.shift, .option]), .window)
		expectNoDifference(LinkClickDisposition([.option]), .download)
		expectNoDifference(LinkClickDisposition([.control, .command]), .contextMenu)

		// Caps Lock, Fn and the like change nothing.
		expectNoDifference(LinkClickDisposition([.capsLock, .function]), .currentTab)
	}

	// MARK: - From a window's pane

	@Test
	internal func aWindowPaneFollowsTheDefaultSettings() throws {
		let current = state()
		let tab = try #require(current.main.viewer.item.tab)
		expectNoDifference(outcomes(current, hovered(tab)), [
			"click": .follow,
			"⌘": .backgroundTab,
			"⇧⌘": .foregroundTab,
			"⇧": .peek,
			"⌥": .download,
			"⌥⌘": .littleArx,
			"⇧⌥⌘": .foregroundTab,
			"⇧⌥": .peek,
			"⌃": .follow,
		])
	}

	@Test
	internal func aWindowPaneFollowsChangedSettings() throws {
		let current = state(preferences: .init(
			shiftClickLinkAction: .newWindow,
			littleArxLinkBinding: .shiftOptionCommand,
			switchesToLinkTabs: true
		))
		let tab = try #require(current.main.viewer.item.tab)
		expectNoDifference(outcomes(current, hovered(tab)), [
			"click": .follow,
			// Settings bring link tabs forward, and Shift sends them back (DEV-952).
			"⌘": .foregroundTab,
			"⇧⌘": .backgroundTab,
			"⇧": .newWindow,
			"⌥": .download,
			"⌥⌘": .foregroundTab,
			"⇧⌥⌘": .littleArx,
			"⇧⌥": .newWindow,
			"⌃": .follow,
		])

		let off = state(preferences: .init(littleArxLinkBinding: .off))
		let offTab = try #require(off.main.viewer.item.tab)
		expectNoDifference(off.linkClickOutcome(for: hovered(offTab), modifiers: [.option, .command]), .backgroundTab)
	}

	// MARK: - Routing

	@Test
	internal func aPlainClickOnALinkToAnotherSiteSaysWhereRoutingSendsIt() throws {
		// Favorites send links to other sites to Peek by default (DEV-727).
		var favorite = state()
		let tab = try #require(favorite.main.viewer.item.tab)
		let spaceID = favorite.workspace.spaces[0].id
		favorite.workspace.spaces[id: spaceID]!.unpinnedTabs.removeAll { $0 == tab.id }
		favorite.workspace.profiles[0].favorites.append(tab.id)
		expectNoDifference(favorite.linkClickOutcome(for: hovered(tab, isCrossSite: true), modifiers: []), .peek)

		// The status follows where Settings send a Favorite's links and a Shift-click (DEV-1239).
		let expected: [(CrossSiteLinkAction, ShiftClickLinkAction, LinkClickOutcome, LinkClickOutcome)] = [
			(.littleArx, .littleArx, .littleArx, .littleArx),
			(.newTab, .newTab, .backgroundTab, .backgroundTab),
			(.currentTab, .newWindow, .follow, .newWindow),
		]
		for (favorites, shift, click, shiftClick) in expected {
			var chosen = favorite
			chosen.settings.$linkClicks.withLock {
				$0.crossSiteLinkFromFavorites = favorites
				$0.shiftClickLinkAction = shift
			}
			let link = hovered(tab, isCrossSite: true)
			expectNoDifference(chosen.linkClickOutcome(for: link, modifiers: []), click, "\(favorites)")
			expectNoDifference(chosen.linkClickOutcome(for: link, modifiers: [.shift]), shiftClick, "\(shift)")
		}

		// The same site stays in the tab.
		expectNoDifference(favorite.linkClickOutcome(for: hovered(tab, isCrossSite: false), modifiers: []), .follow)

		// A site Settings move to WebKit goes there first, as BrowserWindow decides it.
		expectNoDifference(
			favorite.linkClickOutcome(for: hovered(tab, isCrossSite: true), modifiers: [], opensInWebKit: true),
			.webKit
		)

		// A `_blank` link is the page's own new tab, which goes where the Favorite's setting says,
		// whatever its site (DEV-1312): Peek or Little Arx, or a tab in front for the others.
		// A frame's link, or one whose target is unknown, promises nothing but its address
		// (DEV-1118).
		// The settings are shared, so the loop above left its last choice: back to Peek.
		favorite.settings.$linkClicks.withLock { $0.crossSiteLinkFromFavorites = .peek }
		let crossSite = hovered(tab, isCrossSite: true, target: .newContext)
		expectNoDifference(favorite.linkClickOutcome(for: crossSite, modifiers: []), .peek)
		expectNoDifference(favorite.linkClickOutcome(for: crossSite, modifiers: [], opensInWebKit: true), .peek)
		expectNoDifference(
			favorite.linkClickOutcome(for: hovered(tab, isCrossSite: false, target: .newContext), modifiers: []),
			.peek
		)
		for (choice, outcome) in [
			(CrossSiteLinkAction.littleArx, LinkClickOutcome.littleArx),
			(.newTab, .foregroundTab),
			(.currentTab, .foregroundTab),
		] {
			var chosen = favorite
			chosen.settings.$linkClicks.withLock { $0.crossSiteLinkFromFavorites = choice }
			expectNoDifference(chosen.linkClickOutcome(for: crossSite, modifiers: []), outcome, "\(choice)")
		}

		// The keys still make their own choice.
		expectNoDifference(favorite.linkClickOutcome(for: crossSite, modifiers: [.command]), .backgroundTab)
		for target in [BrowserHoveredLink.Target.subframe, .unknown] {
			let link = hovered(tab, isCrossSite: true, target: target)
			expectNoDifference(favorite.linkClickOutcome(for: link, modifiers: []), .follow, "\(target)")
			expectNoDifference(favorite.linkClickOutcome(for: link, modifiers: [], opensInWebKit: true), .follow, "\(target)")
		}

		// Unpinned tabs follow links to other sites.
		let unpinned = state()
		let unpinnedTab = try #require(unpinned.main.viewer.item.tab)
		expectNoDifference(unpinned.linkClickOutcome(for: hovered(unpinnedTab, isCrossSite: true), modifiers: []), .follow)
	}

	@Test
	internal func aLinkForAnotherAppNamesTheAppRoutingHandsItTo() throws {
		var preferences = BrowserPreferences()
		preferences.routing.appLinks = .init(handlers: [
			AppLinkHandler(id: UUID(1), name: "Claude", scheme: "claude"),
		])
		let current = state(preferences: preferences)
		let tab = try #require(current.main.viewer.item.tab)
		let app = URL(string: "claude://login/callback?code=1")!
		expectNoDifference(current.linkClickOutcome(for: hovered(tab, url: app), modifiers: []), .app("Claude"))
		expectNoDifference(current.linkClickOutcome(for: hovered(tab, url: app), modifiers: [.command]), .app("Claude"))

		// The app or script the handling picks, not the handler's own name.
		var chosen = BrowserPreferences()
		chosen.routing.appLinks = .init(handlers: [
			AppLinkHandler(
				id: UUID(1),
				name: "Claude",
				scheme: "claude",
				defaultHandling: .openApp(.init(path: "/Applications/Claude Beta.app", name: "Claude Beta"))
			),
			AppLinkHandler(id: UUID(2), name: "Linear", scheme: "linear", defaultHandling: .runScript("open -a Linear \"$1\"")),
		])
		let routed = state(preferences: chosen)
		let routedTab = try #require(routed.main.viewer.item.tab)
		expectNoDifference(routed.linkClickOutcome(for: hovered(routedTab, url: app), modifiers: []), .app("Claude Beta"))
		expectNoDifference(
			routed.linkClickOutcome(for: hovered(routedTab, url: URL(string: "linear://issue/DEV-1")!), modifiers: []),
			.script("Linear")
		)

		// No handler: Chrome's own dialog, so the status shows only the address.
		let other = URL(string: "zoommtg://join?id=1")!
		expectNoDifference(current.linkClickOutcome(for: hovered(tab, url: other), modifiers: []), .follow)
	}

	// MARK: - Peek, Little Arx and private windows

	@Test
	internal func littleArxKeepsItsLinksInLittleArx() throws {
		var current = state()
		let page = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: current.workspace.profiles[0].id,
			restoration: .init(title: "Figma", url: URL(string: "https://figma.example/file")!)
		)
		var little = LittleArxFeature.State(id: UUID(82), spaceID: current.main.sidebar.spaceID, tab: page)
		little.viewer.tab = page
		current.littleWindows.append(little)

		expectNoDifference(outcomes(current, hovered(page)), [
			"click": .follow,
			"⌘": .newLittleArx,
			"⇧⌘": .newLittleArx,
			"⇧": .peek,
			"⌥": .download,
			"⌥⌘": .littleArx,
			"⇧⌥⌘": .newLittleArx,
			"⇧⌥": .peek,
			"⌃": .follow,
		])
	}

	@Test
	internal func peekKeepsChromiumsChoiceAndOpensNoPeekInsideItself() throws {
		var current = state()
		let page = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: current.workspace.profiles[0].id,
			restoration: .init(title: "Preview", url: URL(string: "https://preview.example/")!)
		)
		current.peeks.append(.init(
			id: UUID(81),
			source: .init(
				windowID: current.main.id,
				paneID: current.main.viewer.activePaneID,
				tabID: current.main.viewer.item.tab?.id,
				spaceID: current.main.sidebar.spaceID,
				profileID: page.profileID,
				identity: "Fixture"
			),
			tab: page,
			isTemporary: true
		))
		current.peeks[id: UUID(81)]?.viewer = .init(tab: page)

		expectNoDifference(outcomes(current, hovered(page)), [
			"click": .follow,
			"⌘": .backgroundTab,
			// A tab in front from Peek opens in a window of its own.
			"⇧⌘": .newWindow,
			"⇧": .newWindow,
			"⌥": .download,
			"⌥⌘": .littleArx,
			"⇧⌥⌘": .newWindow,
			"⇧⌥": .newWindow,
			"⌃": .follow,
		])
	}

	@Test
	internal func aPagesOwnNewTabOpensWhereEachKindOfPagePutsIt() throws {
		// A window's pane: in front, whatever Settings say about link tabs (DEV-952).
		let pane = state(preferences: .init(switchesToLinkTabs: true))
		let paneTab = try #require(pane.main.viewer.item.tab)
		expectNoDifference(pane.linkClickOutcome(for: hovered(paneTab, target: .newContext), modifiers: []), .foregroundTab)
		expectNoDifference(
			pane.linkClickOutcome(for: hovered(paneTab, isPrivate: true, target: .newContext), modifiers: []),
			.foregroundTab
		)

		// Little Arx: a new Little Arx (DEV-855).
		var little = state()
		let page = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: little.workspace.profiles[0].id,
			restoration: .init(title: "Figma", url: URL(string: "https://figma.example/file")!)
		)
		var window = LittleArxFeature.State(id: UUID(82), spaceID: little.main.sidebar.spaceID, tab: page)
		window.viewer.tab = page
		little.littleWindows.append(window)
		expectNoDifference(little.linkClickOutcome(for: hovered(page, target: .newContext), modifiers: []), .newLittleArx)
	}

	@Test
	internal func privateWindowsKeepChromiumsChoice() throws {
		let current = state(preferences: .init(switchesToLinkTabs: true))
		let tab = try #require(current.main.viewer.item.tab)
		expectNoDifference(outcomes(current, hovered(tab, isPrivate: true, isCrossSite: true)), [
			"click": .follow,
			"⌘": .backgroundTab,
			"⇧⌘": .foregroundTab,
			"⇧": .privateWindow,
			"⌥": .download,
			"⌥⌘": .backgroundTab,
			"⇧⌥⌘": .foregroundTab,
			"⇧⌥": .privateWindow,
			"⌃": .follow,
		])
	}

	// MARK: - Words

	@Test
	internal func everyOutcomeHasItsOwnWords() {
		let words: [(LinkClickOutcome, String?, String?)] = [
			(.follow, nil, nil),
			(.backgroundTab, "Open", "in a new tab behind this one"),
			(.foregroundTab, "Open", "in a new tab and go to it"),
			(.newWindow, "Open", "in a new window"),
			(.privateWindow, "Open", "in a new private window"),
			(.peek, "Open", "in Peek"),
			(.littleArx, "Open", "in Little Arx"),
			(.newLittleArx, "Open", "in a new Little Arx"),
			(.download, "Download", nil),
			(.app("Claude"), "Open", "in Claude"),
			(.script("Claude"), "Open", "with your Claude script"),
			(.webKit, "Open", "in WebKit"),
		]
		for (outcome, verb, action) in words {
			let status = LinkStatus(url: Self.link, outcome: outcome)
			expectNoDifference(status.verb, verb, "\(outcome)")
			expectNoDifference(status.action, action, "\(outcome)")
			expectNoDifference(status.address, "github.com/emilkowalski/skills/tree/main/skills/apple-design")
		}
		let actions = words.compactMap(\.2)
		expectNoDifference(Set(actions).count, actions.count)
	}

	@Test
	internal func theAddressLeavesOutOnlyHTTPS() {
		expectNoDifference(LinkStatus.address(URL(string: "https://example.com/")!), "example.com")
		expectNoDifference(LinkStatus.address(URL(string: "https://example.com/?q=1")!), "example.com/?q=1")
		expectNoDifference(LinkStatus.address(URL(string: "https://example.com/#top")!), "example.com/#top")
		expectNoDifference(LinkStatus.address(URL(string: "https://example.com/a/")!), "example.com/a/")
		expectNoDifference(LinkStatus.address(URL(string: "http://example.com/")!), "http://example.com/")
		expectNoDifference(LinkStatus.address(URL(string: "mailto:max@example.com")!), "mailto:max@example.com")
	}

	// MARK: - Placement

	@Test
	internal func theStatusSitsAtTheBottomLeftAndMovesAwayFromThePointer() {
		let page = CGRect(x: 100, y: 50, width: 800, height: 600)
		let size = CGSize(width: 200, height: LinkStatusToastMetrics.height)
		let inset = LinkStatusToastMetrics.edgeInset
		let leading = CGRect(x: 100 + inset, y: 50 + inset, width: 200, height: size.height)
		let trailing = CGRect(x: 900 - inset - 200, y: 50 + inset, width: 200, height: size.height)

		expectNoDifference(LinkStatusPresenter.frame(size: size, in: page, pointer: .init(x: 500, y: 400)), leading)
		expectNoDifference(LinkStatusPresenter.frame(size: size, in: page, pointer: .init(x: 150, y: 60)), trailing)

		// Right at its edge counts as over it.
		expectNoDifference(LinkStatusPresenter.frame(size: size, in: page, pointer: .init(x: leading.maxX + 2, y: 60)), trailing)

		// A status two thirds of the page wide covers the pointer at both corners: it goes beside
		// the pointer on the side with more room, narrowed to fit.
		let wide = CGSize(width: 533, height: size.height)
		expectNoDifference(
			LinkStatusPresenter.frame(size: wide, in: page, pointer: .init(x: 520, y: 60)),
			CGRect(x: 100 + inset, y: 50 + inset, width: 520 - inset - (100 + inset), height: size.height)
		)
		expectNoDifference(
			LinkStatusPresenter.frame(size: wide, in: page, pointer: .init(x: 400, y: 60)),
			CGRect(x: 400 + inset, y: 50 + inset, width: 900 - inset - (400 + inset), height: size.height)
		)
	}

	// MARK: - Setting

	@Test
	internal func theSettingIsOnByDefaultAndForAgents() throws {
		#expect(BrowserPreferences().showsLinkStatus)
		var object = try #require(
			JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserPreferences(showsLinkStatus: false))) as? [String: Any]
		)
		expectNoDifference(object["showsLinkStatus"] as? Bool, false)
		object.removeValue(forKey: "showsLinkStatus")
		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONSerialization.data(withJSONObject: object))
		#expect(decoded.showsLinkStatus)

		expectNoDifference(AutomationPreferenceKey.showsLinkStatus.schema, .boolean)
		expectNoDifference(SettingsAnchor.linkStatus.toggle, .showsLinkStatus)

		// Settings' search finds the row only while the feature flag shows it.
		let entry = try #require(SettingsCategory.searchIndex.first { $0.destination == .row(.links, .linkStatus) })
		#expect(!entry.isAvailable(.init(linkStatus: false, darkPages: true)))
		#expect(entry.isAvailable(.init(linkStatus: true)))
	}

	@Test
	internal func theFeatureFlagIsOnUntilTurnedOff() {
		let defaults = UserDefaults(suiteName: "LinkStatusTests-\(UUID())")!

		// On by default (DEV-1143).
		#expect(LinkStatusFeatureFlag.isOn(environment: [:], defaults: defaults))
		#expect(LinkStatusFeatureFlag.isOn(environment: ["ARX_LINK_STATUS": "1"], defaults: defaults))
		#expect(!LinkStatusFeatureFlag.isOn(environment: ["ARX_LINK_STATUS": "0"], defaults: defaults))
	}

	/// DEV-1111: the presenter hides a status narrower than its words. The panel's own hosting
	/// view is sized by the presenter and reports no size, and measuring it made every status
	/// zero wide, so none ever showed. A status measures as wide as its words.
	@Test
	internal func aStatusMeasuresAsWideAsItsWords() throws {
		let url = try #require(URL(string: "https://en.wikipedia.org/wiki/Computing"))
		let panel = LinkStatusPanel()

		let address = LinkStatus(url: url, outcome: .follow)
		let natural = panel.naturalWidth(for: address)
		#expect(natural > panel.minimumWidth(for: address))
		#expect(natural >= LinkStatusToastMetrics.minimumBesidePointer)

		// Its words widen it, and a longer address does too.
		let peek = LinkStatus(url: url, outcome: .peek)
		#expect(panel.naturalWidth(for: peek) > natural)
		#expect(panel.minimumWidth(for: peek) > panel.minimumWidth(for: address))
		let longer = LinkStatus(url: url.appending(path: "History_of_computing_hardware"), outcome: .follow)
		#expect(panel.naturalWidth(for: longer) > natural)
	}
}
