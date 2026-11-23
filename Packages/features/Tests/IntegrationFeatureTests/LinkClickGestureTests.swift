import AppKit
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct LinkClickGestureTests {
	private static let link = URL(string: "https://child.example/")!
	private static let pointer = CGPoint(x: 640, y: 360)

	private func state(preferences: BrowserPreferences = .init()) -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()

		// Each call gets its own document, so states with different preferences don't share one.
		var state = withDependencies {
			$0.workspaceDocument = .unsaved(preferences)
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		state.main.sidebar.select(organization.spaces[0].unpinnedTabs[0])
		state.main.viewer.item.tab = organization.tabs[id: organization.spaces[0].unpinnedTabs[0]]
		return state
	}

	private func offer(
		_ state: AppFeature.State,
		disposition: BrowserNewContents.Disposition,
		url: URL = link,
		isPrivate: Bool = false
	) -> BrowserNewContents {
		let source = state.main.viewer.item.tab!
		return .init(
			sourceTabID: source.id,
			sourceSessionRevision: 3,
			sourceDocumentRevision: 7,
			tab: .init(
				id: .init(rawValue: UUID(90)),
				profileID: source.profileID,
				restoration: .init(title: "Child", url: url)
			),
			disposition: disposition,
			isPrivate: isPrivate
		)
	}

	private func action(
		_ state: AppFeature.State,
		_ offer: BrowserNewContents,
		modifiers: NSEvent.ModifierFlags = [],
		revision: UInt64 = 3,
		pointer: CGPoint? = LinkClickGestureTests.pointer
	) -> AppFeature.Action? {
		let profileID = offer.tab.profileID
		return withDependencies {
			$0.browserEngine.snapshot = { _ in
				.init(navigation: .init(), revision: revision, documentRevision: 7, nativeProfileID: profileID)
			}
		} operation: {
			@Dependency(\.browserEngine)
			var engine

			return state.linkClickAction(for: offer, modifiers: modifiers, pointer: pointer, engine: engine)
		}
	}

	@Test
	internal func shiftClickOpensPeekAndCanKeepChromiumsWindow() throws {
		let current = state()
		let routed = try #require(action(current, offer(current, disposition: .window)))
		guard case let .ui(.peekURLFromSource(url, source, origin)) = routed else {
			Issue.record("Expected Peek, got \(routed)")
			return
		}
		expectNoDifference(url, Self.link)
		expectNoDifference(source.windowID, current.main.id)
		expectNoDifference(origin, Self.pointer)

		let off = state(preferences: .init(shiftClickLinkAction: .newWindow))
		#expect(action(off, offer(off, disposition: .window)) == nil)
	}

	/// DEV-1239: Settings choose where a Shift-click opens a link.
	@Test
	internal func shiftClickCanOpenLittleArxOrANewTab() throws {
		let little = state(preferences: .init(shiftClickLinkAction: .littleArx))
		let routed = try #require(action(little, offer(little, disposition: .window), modifiers: [.shift]))
		guard case let .ui(.openLittleArx(space, url)) = routed else {
			Issue.record("Expected Little Arx, got \(routed)")
			return
		}
		expectNoDifference(space, little.main.sidebar.spaceID)
		expectNoDifference(url, Self.link)

		let tab = state(preferences: .init(shiftClickLinkAction: .newTab))
		let opener = try #require(tab.main.viewer.item.tab?.id)
		let behind = try #require(action(tab, offer(tab, disposition: .window), modifiers: [.shift]))
		guard case let .openLinkInBackgroundTab(tabURL, tabOpener, windowID) = behind else {
			Issue.record("Expected a tab behind the page, got \(behind)")
			return
		}
		expectNoDifference(tabURL, Self.link)
		expectNoDifference(tabOpener, opener)
		expectNoDifference(windowID, tab.main.id)

		// Settings bring link tabs forward (DEV-952).
		let forward = state(preferences: .init(shiftClickLinkAction: .newTab, switchesToLinkTabs: true))
		let front = try #require(action(forward, offer(forward, disposition: .window), modifiers: [.shift]))
		guard case .main(.ui(.openInNewTab(Self.link))) = front else {
			Issue.record("Expected a tab in front, got \(front)")
			return
		}
	}

	/// Return on a focused link activates it with the keys held, so Blink sends Shift-Return
	/// as the same new-window request as a Shift-click. Without a pointer, Peek opens from
	/// the pane rather than from a point.
	@Test
	internal func shiftReturnOnAFocusedLinkOpensPeekWithoutAPointer() throws {
		let current = state()
		let routed = try #require(action(current, offer(current, disposition: .window), modifiers: [.shift], pointer: nil))
		guard case let .ui(.peekURLFromSource(url, source, origin)) = routed else {
			Issue.record("Expected Peek, got \(routed)")
			return
		}
		expectNoDifference(url, Self.link)
		expectNoDifference(source.windowID, current.main.id)
		#expect(origin == nil)
	}

	@Test
	internal func keyActivationsOpenPeekFromThePaneAndClicksFromThePointer() throws {
		let key = try #require(NSEvent.keyEvent(
			with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0,
			context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
		))
		let click = try #require(NSEvent.mouseEvent(
			with: .leftMouseUp, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0,
			context: nil, eventNumber: 0, clickCount: 1, pressure: 0
		))
		#expect(Optional(key).linkActivationPointer == nil)
		#expect(Optional(click).linkActivationPointer != nil)
		#expect(NSEvent?.none.linkActivationPointer != nil)
	}

	@Test
	internal func optionCommandClickOpensLittleArxInTheSourceSpace() throws {
		let current = state()
		for disposition in [BrowserNewContents.Disposition.backgroundTab, .foregroundTab] {
			let routed = try #require(action(current, offer(current, disposition: disposition), modifiers: [.option, .command]))
			guard case let .ui(.openLittleArx(space, url)) = routed else {
				Issue.record("Expected Little Arx, got \(routed)")
				return
			}
			expectNoDifference(space, current.main.sidebar.spaceID)
			expectNoDifference(url, Self.link)
		}
	}

	@Test
	internal func ordinaryCommandClicksKeepOpeningTabs() {
		let current = state()
		let tab = offer(current, disposition: .backgroundTab)
		#expect(action(current, tab) == nil)
		#expect(action(current, tab, modifiers: [.command]) == nil)
		#expect(action(current, tab, modifiers: [.shift, .command]) == nil)
		#expect(action(current, tab, modifiers: [.shift, .option, .command]) == nil)
		#expect(action(current, tab, modifiers: [.control, .option, .command]) == nil)
	}

	@Test
	internal func theBindingCanChangeOrBeOff() {
		let changed = state(preferences: .init(littleArxLinkBinding: .shiftOptionCommand))
		let tab = offer(changed, disposition: .foregroundTab)
		#expect(action(changed, tab, modifiers: [.shift, .option, .command]) != nil)
		#expect(action(changed, tab, modifiers: [.option, .command]) == nil)

		let off = state(preferences: .init(littleArxLinkBinding: .off))
		#expect(action(off, offer(off, disposition: .backgroundTab), modifiers: [.option, .command]) == nil)
	}

	@Test
	internal func popupsPrivatePagesStaleSourcesAndOtherSchemesAreLeftAlone() {
		let current = state()
		#expect(action(current, offer(current, disposition: .popup), modifiers: [.option, .command]) == nil)
		#expect(action(current, offer(current, disposition: .window, isPrivate: true)) == nil)
		#expect(action(current, offer(current, disposition: .window), revision: 4) == nil)
		#expect(action(current, offer(current, disposition: .window, url: URL(string: "about:blank")!)) == nil)
		#expect(action(current, offer(current, disposition: .window, url: URL(string: "file:///etc/hosts")!)) == nil)
	}

	@Test
	internal func olderPreferencesGetTheDefaults() throws {
		var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserPreferences())) as? [String: Any])
		object.removeValue(forKey: "shiftClickLinkAction")
		object.removeValue(forKey: "littleArxLinkBinding")
		object.removeValue(forKey: "forceClickLinkAction")

		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONSerialization.data(withJSONObject: object))

		expectNoDifference(decoded.shiftClickLinkAction, .peek)
		expectNoDifference(decoded.littleArxLinkBinding, .optionCommand)
		expectNoDifference(decoded.forceClickLinkAction, .peek)
	}

	/// DEV-1239: the switches saved before each gesture chose where it opens keep what they did.
	/// On was Peek; off was Chromium's window for a Shift-click and the tab itself for a Favorite.
	@Test(arguments: [
		(true, true, false, ShiftClickLinkAction.peek, CrossSiteLinkAction.peek, CrossSiteLinkAction.currentTab),
		(false, false, true, ShiftClickLinkAction.newWindow, CrossSiteLinkAction.currentTab, CrossSiteLinkAction.peek),
		(false, true, true, ShiftClickLinkAction.newWindow, CrossSiteLinkAction.peek, CrossSiteLinkAction.peek),
	])
	internal func switchesSavedByAnOlderArxKeepTheirBehavior(
		shiftPeek: Bool,
		favoritesPeek: Bool,
		pinnedPeek: Bool,
		shift: ShiftClickLinkAction,
		favorites: CrossSiteLinkAction,
		pinned: CrossSiteLinkAction
	) throws {
		var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserPreferences())) as? [String: Any])
		object.removeValue(forKey: "shiftClickLinkAction")
		object.removeValue(forKey: "crossSiteLinkFromFavorites")
		object.removeValue(forKey: "crossSiteLinkFromPinnedTabs")
		object["shiftClickPeekEnabled"] = shiftPeek
		object["crossSitePeekFromFavorites"] = favoritesPeek
		object["crossSitePeekFromPinnedTabs"] = pinnedPeek
		object["forceClickLinkAction"] = "off"

		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONSerialization.data(withJSONObject: object))

		expectNoDifference(decoded.shiftClickLinkAction, shift)
		expectNoDifference(decoded.crossSiteLinkFromFavorites, favorites)
		expectNoDifference(decoded.crossSiteLinkFromPinnedTabs, pinned)
		expectNoDifference(decoded.forceClickLinkAction, .off)
	}

	/// A choice made since wins over a switch an older Arx left in the same file.
	@Test
	internal func aSavedChoiceWinsOverAnOlderSwitch() throws {
		var object = try #require(
			JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserPreferences(
				shiftClickLinkAction: .newTab,
				crossSiteLinkFromFavorites: .littleArx,
				crossSiteLinkFromPinnedTabs: .newTab
			))) as? [String: Any]
		)
		#expect(object["shiftClickPeekEnabled"] == nil)
		#expect(object["crossSitePeekFromFavorites"] == nil)
		#expect(object["crossSitePeekFromPinnedTabs"] == nil)
		object["shiftClickPeekEnabled"] = false
		object["crossSitePeekFromFavorites"] = false
		object["crossSitePeekFromPinnedTabs"] = true

		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONSerialization.data(withJSONObject: object))

		expectNoDifference(decoded.shiftClickLinkAction, .newTab)
		expectNoDifference(decoded.crossSiteLinkFromFavorites, .littleArx)
		expectNoDifference(decoded.crossSiteLinkFromPinnedTabs, .newTab)
	}

	private func forceClick(
		_ state: AppFeature.State,
		url: URL = link,
		isPrivate: Bool = false,
		revision: UInt64 = 3,
		documentRevision: UInt64 = 7
	) -> AppFeature.Action? {
		let source = state.main.viewer.item.tab!
		let click = BrowserLinkForceClick(
			sourceTabID: source.id,
			profileID: source.profileID,
			sourceSessionRevision: 3,
			sourceDocumentRevision: documentRevision,
			url: url,
			isPrivate: isPrivate
		)
		return withDependencies {
			$0.browserEngine.snapshot = { _ in
				.init(navigation: .init(), revision: revision, documentRevision: 7, nativeProfileID: source.profileID)
			}
		} operation: {
			@Dependency(\.browserEngine)
			var engine

			return state.linkForceClickAction(for: click, pointer: Self.pointer, engine: engine)
		}
	}

	@Test
	internal func forceClickOpensPeekByDefault() throws {
		let current = state()
		let routed = try #require(forceClick(current))
		guard case let .ui(.peekURLFromSource(url, source, origin)) = routed else {
			Issue.record("Expected Peek, got \(routed)")
			return
		}
		expectNoDifference(url, Self.link)
		expectNoDifference(source.windowID, current.main.id)
		expectNoDifference(origin, Self.pointer)
	}

	@Test
	internal func forceClickCanOpenLittleArxOrBeOff() throws {
		let little = state(preferences: .init(forceClickLinkAction: .littleArx))
		let routed = try #require(forceClick(little))
		guard case let .ui(.openLittleArx(space, url)) = routed else {
			Issue.record("Expected Little Arx, got \(routed)")
			return
		}
		expectNoDifference(space, little.main.sidebar.spaceID)
		expectNoDifference(url, Self.link)

		let off = state(preferences: .init(forceClickLinkAction: .off))
		#expect(forceClick(off) == nil)
	}

	/// DEV-1239.
	@Test
	internal func forceClickCanOpenANewTab() throws {
		let tab = state(preferences: .init(forceClickLinkAction: .newTab))
		let opener = try #require(tab.main.viewer.item.tab?.id)
		let routed = try #require(forceClick(tab))
		guard case let .openLinkInBackgroundTab(url, tabOpener, windowID) = routed else {
			Issue.record("Expected a tab behind the page, got \(routed)")
			return
		}
		expectNoDifference(url, Self.link)
		expectNoDifference(tabOpener, opener)
		expectNoDifference(windowID, tab.main.id)
	}

	@Test
	internal func forceClickLeavesPrivateStaleAndOtherSchemesToChromium() {
		let current = state()
		#expect(forceClick(current, isPrivate: true) == nil)
		#expect(forceClick(current, revision: 4) == nil)
		#expect(forceClick(current, documentRevision: 8) == nil)
		#expect(forceClick(current, url: URL(string: "file:///etc/hosts")!) == nil)
	}

	private func takeForceClick(
		_ state: AppFeature.State,
		isPrivate: Bool = false
	) -> (taken: Bool, sent: [AppFeature.Action], feedback: Int) {
		let source = state.main.viewer.item.tab!
		let click = BrowserLinkForceClick(
			sourceTabID: source.id,
			profileID: source.profileID,
			sourceSessionRevision: 3,
			sourceDocumentRevision: 7,
			url: Self.link,
			isPrivate: isPrivate
		)
		var sent: [AppFeature.Action] = []
		var feedback = 0
		let taken = withDependencies {
			$0.browserEngine.snapshot = { _ in
				.init(navigation: .init(), revision: 3, documentRevision: 7, nativeProfileID: source.profileID)
			}
			$0.linkActivationFeedback.perform = { feedback += 1 }
		} operation: {
			@Dependency(\.browserEngine)
			var engine

			return state.takeLinkForceClick(click, pointer: Self.pointer, engine: engine) { sent.append($0) }
		}
		return (taken, sent, feedback)
	}

	@Test
	internal func forceClickStaysSilentWithHapticsOff() {
		let silent = takeForceClick(state(preferences: .init(hapticsEnabled: false)))
		#expect(silent.taken)
		expectNoDifference(silent.sent.count, 1)
		expectNoDifference(silent.feedback, 0)
	}

	@Test
	internal func forceClickPlaysOneHapticOnlyWhenArxTakesTheLink() {
		let peek = takeForceClick(state())
		#expect(peek.taken)
		expectNoDifference(peek.sent.count, 1)
		expectNoDifference(peek.feedback, 1)

		let little = takeForceClick(state(preferences: .init(forceClickLinkAction: .littleArx)))
		#expect(little.taken)
		expectNoDifference(little.feedback, 1)

		for ignored in [
			takeForceClick(state(preferences: .init(forceClickLinkAction: .off))),
			takeForceClick(state(), isPrivate: true),
		] {
			#expect(!ignored.taken)
			#expect(ignored.sent.isEmpty)
			expectNoDifference(ignored.feedback, 0)
		}
	}

	// MARK: - Links to other sites (DEV-727)

	private enum SourceKind { case favorite, pinned, unpinned }

	/// The viewed tab, moved to a Favorite or a space's pinned tabs when asked.
	private func state(
		_ kind: SourceKind,
		preferences: BrowserPreferences = .init()
	) -> AppFeature.State {
		var state = state(preferences: preferences)
		let tabID = state.main.viewer.item.tab!.id
		let spaceID = state.workspace.spaces[0].id
		switch kind {
		case .favorite:
			state.workspace.spaces[id: spaceID]!.unpinnedTabs.removeAll { $0 == tabID }
			state.workspace.profiles[0].favorites.append(tabID)
		case .pinned:
			state.workspace.spaces[id: spaceID]!.unpinnedTabs.removeAll { $0 == tabID }
			state.workspace.spaces[id: spaceID]!.savedItems.append(.tab(tabID))
		case .unpinned:
			break
		}
		return state
	}

	private func crossSite(
		_ state: AppFeature.State,
		revision: UInt64 = 3,
		documentRevision: UInt64 = 7
	) -> AppFeature.Action? {
		let source = state.main.viewer.item.tab!
		let link = BrowserCrossSiteLink(
			sourceTabID: source.id,
			profileID: source.profileID,
			sourceSessionRevision: 3,
			sourceDocumentRevision: 7,
			url: Self.link
		)
		return withDependencies {
			$0.browserEngine.snapshot = { _ in
				.init(
					navigation: .init(),
					revision: revision,
					documentRevision: documentRevision,
					nativeProfileID: source.profileID
				)
			}
		} operation: {
			@Dependency(\.browserEngine)
			var engine

			return state.crossSiteLinkAction(for: link, pointer: Self.pointer, engine: engine)
		}
	}

	@Test
	internal func crossSiteLinksFromFavoritesOpenPeekByDefault() throws {
		let current = state(.favorite)
		let routed = try #require(crossSite(current))
		guard case let .ui(.peekURLFromSource(url, source, origin)) = routed else {
			Issue.record("Expected Peek, got \(routed)")
			return
		}
		expectNoDifference(url, Self.link)
		expectNoDifference(source.windowID, current.main.id)
		expectNoDifference(origin, Self.pointer)

		#expect(crossSite(state(.favorite, preferences: .init(crossSiteLinkFromFavorites: .currentTab))) == nil)
	}

	/// DEV-1239.
	@Test
	internal func crossSiteLinksFromFavoritesCanOpenLittleArxOrANewTab() throws {
		let little = state(.favorite, preferences: .init(crossSiteLinkFromFavorites: .littleArx))
		let routed = try #require(crossSite(little))
		guard case let .ui(.openLittleArx(space, url)) = routed else {
			Issue.record("Expected Little Arx, got \(routed)")
			return
		}
		expectNoDifference(space, little.main.sidebar.spaceID)
		expectNoDifference(url, Self.link)

		let tab = state(.favorite, preferences: .init(crossSiteLinkFromFavorites: .newTab))
		let opener = try #require(tab.main.viewer.item.tab?.id)
		let behind = try #require(crossSite(tab))
		guard case let .openLinkInBackgroundTab(tabURL, tabOpener, _) = behind else {
			Issue.record("Expected a tab behind the Favorite, got \(behind)")
			return
		}
		expectNoDifference(tabURL, Self.link)
		expectNoDifference(tabOpener, opener)

		// Each kind has its own choice: the one for Favorites leaves pinned tabs alone.
		#expect(crossSite(state(.pinned, preferences: .init(crossSiteLinkFromFavorites: .newTab))) == nil)
	}

	@Test
	internal func crossSiteLinksFromPinnedTabsOpenPeekOnlyWhenTurnedOn() {
		#expect(crossSite(state(.pinned)) == nil)
		let peek = crossSite(state(.pinned, preferences: .init(crossSiteLinkFromPinnedTabs: .peek)))
		guard case .ui(.peekURLFromSource(Self.link, _, origin: _))? = peek else {
			Issue.record("Expected Peek, got \(String(describing: peek))")
			return
		}

		// DEV-1239: pinned tabs choose among the same places as Favorites.
		let little = crossSite(state(.pinned, preferences: .init(crossSiteLinkFromPinnedTabs: .littleArx)))
		guard case .ui(.openLittleArx(_, Self.link))? = little else {
			Issue.record("Expected Little Arx, got \(String(describing: little))")
			return
		}
		let tab = crossSite(state(.pinned, preferences: .init(crossSiteLinkFromPinnedTabs: .newTab)))
		guard case .openLinkInBackgroundTab(Self.link, _, _)? = tab else {
			Issue.record("Expected a tab behind the pinned tab, got \(String(describing: tab))")
			return
		}

		// And theirs leaves Favorites alone.
		let favorite = crossSite(state(.favorite, preferences: .init(crossSiteLinkFromPinnedTabs: .newTab)))
		guard case .ui(.peekURLFromSource)? = favorite else {
			Issue.record("Expected Peek from the Favorite, got \(String(describing: favorite))")
			return
		}
	}

	@Test
	internal func crossSiteLinksFromUnpinnedTabsAndStaleDocumentsNavigate() {
		let everything = BrowserPreferences(crossSiteLinkFromFavorites: .peek, crossSiteLinkFromPinnedTabs: .peek)
		#expect(crossSite(state(.unpinned, preferences: everything)) == nil)
		#expect(crossSite(state(.favorite), revision: 4) == nil)
		#expect(crossSite(state(.favorite), documentRevision: 8) == nil)
	}

	@Test
	internal func crossSitePeekSettingsDefaultWhenMissing() throws {
		var object = try #require(
			JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserPreferences(
				crossSiteLinkFromFavorites: .currentTab,
				crossSiteLinkFromPinnedTabs: .peek
			))) as? [String: Any]
		)
		object.removeValue(forKey: "crossSiteLinkFromFavorites")
		object.removeValue(forKey: "crossSiteLinkFromPinnedTabs")
		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: object)
		)
		expectNoDifference(decoded.crossSiteLinkFromFavorites, .peek)
		expectNoDifference(decoded.crossSiteLinkFromPinnedTabs, .currentTab)
	}
}
