import AppFeature
import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserExtensionsClient
import BrowserWorkspaceClient
import CommandBarFeature
import CustomDump
@testable import MainFeature
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@MainActor
@Suite(.dependencies, .serialized)
internal struct SiteMenuFeatureTests {
	private static let origin = "https://capturecontext.dev"

	@Test
	internal func openingReadsThePagesPermissionsAndTheProfilesEnabledExtensions() async throws {
		let engine = SiteMenuEngineDouble()
		let (store, organization) = makeStore(engine)

		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		let menu = try #require(store.state.siteMenu.menu)
		expectNoDifference(menu.host, "capturecontext.dev")
		expectNoDifference(menu.connection, .secure)
		expectNoDifference(menu.profileName, organization.profiles[0].name)
		expectNoDifference(menu.extensions?.map(\.name), ["Beta", "Zeta"])

		// DEV-824: the manifest icon's bytes when the engine names one; Zeta keeps its letter.
		expectNoDifference(menu.extensions?.map(\.icon), [Data("beta icon".utf8), nil])
		expectNoDifference(menu.permissions?.first { $0.permission == .camera }?.setting, .allow)
		expectNoDifference(menu.permissions?.first { $0.permission == .microphone }?.setting, nil)
		expectNoDifference(menu.permissions?.first { $0.permission == .microphone }?.defaultSetting, .block)
		expectNoDifference(menu.permissions?.first { $0.permission == .popups }?.defaultSetting, .block)
		expectNoDifference(menu.zoom, 1.25)
		#expect(menu.canClearSiteData && menu.canOpenSettings && !menu.isLoading)
		expectNoDifference(engine.listed, [organization.profiles[0].id])
	}

	/// DEV-824 follow-up: an icon an extension set for the page wins over its icon file, as on
	/// its toolbar button; the others keep their file or letter.
	@Test
	internal func aTileDrawsTheIconItsExtensionSetForThePage() async throws {
		let engine = SiteMenuEngineDouble()
		engine.actionIcons = ["z": Data("zeta set icon".utf8)]
		let reads = LockIsolated<[String]>([])
		let (store, organization) = makeStore(
			engine,
			extensions: .init(isAvailable: true, inspect: { id in
				.init(id: UUID(80), profileID: id, revision: 1, extensions: [
					.init(id: "z", name: "Zeta", version: "1", state: .enabled, iconPath: "/extensions/z/icon.png"),
					.init(
						id: "b",
						name: "Beta",
						version: "1",
						state: .enabled,
						iconPath: "/extensions/b/32.png",
						icons: [32: "/extensions/b/32.png", 128: "/extensions/b/128.png"],
						actionIcons: [16: "/extensions/b/action/16.png"]
					),
					// A component: its icon path names nothing on disk, so it brings its bytes.
					.init(
						id: "u",
						name: "uBlock",
						version: "1",
						state: .enabled,
						iconPath: "/resources/u/icon.png",
						bundledIcon: Data("bundled".utf8)
					),
				])
			}, icon: { path in
				reads.withValue { $0.append(path) }
				return path.hasPrefix("/resources/") ? nil : Data(path.utf8)
			})
		)

		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		let menu = try #require(store.state.siteMenu.menu)
		expectNoDifference(menu.extensions?.map(\.name), ["Beta", "uBlock", "Zeta"])

		// Beta set none: its manifest icon that covers the tile's 40 pixels.
		expectNoDifference(
			menu.extensions?.map(\.icon),
			[Data("/extensions/b/128.png".utf8), Data("bundled".utf8), Data("zeta set icon".utf8)]
		)
		expectNoDifference(reads.value, ["/extensions/b/128.png", "/resources/u/icon.png"])
		let tabID = try #require(organization.tabs.first?.id)
		expectNoDifference(engine.actionIconReads.map(\.tabID), [tabID, tabID, tabID])
		expectNoDifference(engine.actionIconReads.map(\.extensionID), ["b", "u", "z"])
		expectNoDifference(engine.actionIconReads.map(\.scale), [2, 2, 2])
	}

	/// DEV-1314: a component with no toolbar action and no options page (Chromium's PDF Viewer)
	/// has no tile, since a click could only open Settings. A component with an action or
	/// options (uBlock Origin) and an ordinary extension without either keep theirs.
	@Test
	internal func aComponentWithNothingToOpenHasNoTile() async throws {
		let engine = SiteMenuEngineDouble()
		let (store, _) = makeStore(
			engine,
			extensions: .init(isAvailable: true, inspect: { id in
				.init(id: UUID(81), profileID: id, revision: 1, extensions: [
					.init(id: "p", name: "Chromium PDF Viewer", version: "1", manifestVersion: 2, location: 5, state: .enabled),
					.init(
						id: "u",
						name: "uBlock Origin",
						version: "1",
						manifestVersion: 2,
						location: 10,
						state: .enabled,
						canOpenOptions: true,
						actionIcons: [16: "/resources/u/16.png"]
					),
					.init(
						id: "c",
						name: "Component Action",
						version: "1",
						location: 5,
						state: .enabled,
						actionIcons: [16: "/resources/c/16.png"]
					),
					.init(id: "z", name: "Zeta", version: "1", state: .enabled),
				])
			})
		)

		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		let menu = try #require(store.state.siteMenu.menu)
		expectNoDifference(menu.extensions?.map(\.name), ["Component Action", "uBlock Origin", "Zeta"])
	}

	/// Codex: a change that finishes after the menu moved to another tab built its tiles with
	/// the old page's set icons; the menu reads its own tab's instead, also after its own read
	/// lost to that change.
	@Test
	internal func tilesBuiltForAnotherTabAreReadAgainForThisOne() async throws {
		let engine = SiteMenuEngineDouble()
		engine.actionIcons = ["b": Data("beta set icon".utf8)]
		let (store, organization) = makeStore(engine)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)
		let profileID = try #require(store.state.siteMenu.context?.extensionsProfileID)
		let tabID = try #require(organization.tabs.first?.id)

		// This tab's own read lost to the change still running: the row hides.
		await store.send(.siteMenu(.event(.extensionsLoaded(profileID, tabID, nil))))
		#expect(store.state.siteMenu.menu?.extensions == nil)
		let reads = engine.actionIconReads.count

		await store.send(.siteMenu(.event(.extensionsLoaded(
			profileID,
			BrowserCore.Tab.ID(rawValue: UUID(999)),
			[.init(id: "x", name: "Stale", icon: Data("other tab".utf8))]
		))))
		await settle(store)

		let menu = try #require(store.state.siteMenu.menu)
		expectNoDifference(menu.extensions?.map(\.name), ["Beta", "Zeta"])
		expectNoDifference(menu.extensions?.first?.icon, Data("beta set icon".utf8))
		#expect(engine.actionIconReads.count > reads)
		#expect(engine.actionIconReads.dropFirst(reads).allSatisfy { $0.tabID == tabID })
	}

	@Test
	internal func allowInPrivateWindowsChangesTheExtensionsSwitch() async throws {
		let manager = SiteMenuExtensionsDouble()
		let (store, _) = makeStore(SiteMenuEngineDouble(), extensions: manager.client)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)
		let tiles = try #require(store.state.siteMenu.menu?.extensions)

		// DEV-889: off by default, and a browser component has no switch.
		#expect(tiles.allSatisfy { $0.canAllowInPrivate == ($0.id == "b") && !$0.allowedInPrivate })

		await store.send(.ui(.siteMenu(.setExtensionAllowedInPrivate("u", true))))
		await store.send(.ui(.siteMenu(.setExtensionAllowedInPrivate("b", false))))
		#expect(manager.actions.isEmpty)
		await store.send(.ui(.siteMenu(.setExtensionAllowedInPrivate("b", true))))
		await settle(store)
		expectNoDifference(manager.actions, [.init(id: "b", action: .allowInPrivate)])
		#expect(store.state.siteMenu.menu?.extensions?.first { $0.id == "b" }?.allowedInPrivate == true)
		#expect(store.state.siteMenu.menu?.notice == nil)

		await store.send(.ui(.siteMenu(.setExtensionAllowedInPrivate("b", false))))
		await settle(store)
		expectNoDifference(manager.actions.last, .init(id: "b", action: .disallowInPrivate))
		#expect(store.state.siteMenu.menu?.extensions?.first { $0.id == "b" }?.allowedInPrivate == false)
	}

	@Test
	internal func turnOffAndRemoveChangeTheExtensionAndTellSettings() async throws {
		let manager = SiteMenuExtensionsDouble()
		let (store, organization) = makeStore(SiteMenuEngineDouble(), extensions: manager.client)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)
		let tiles = try #require(store.state.siteMenu.menu?.extensions)
		expectNoDifference(tiles.map(\.name), ["Beta", "Uno"])

		// A browser component can't be turned off or removed.
		#expect(tiles.allSatisfy { $0.canTurnOff == ($0.id == "b") && $0.canRemove == ($0.id == "b") })

		await store.send(.ui(.siteMenu(.turnOffExtension("u"))))
		await store.send(.ui(.siteMenu(.turnOffExtension("b"))))
		await settle(store)
		expectNoDifference(manager.actions, [.init(id: "b", action: .disable)])
		expectNoDifference(store.state.siteMenu.menu?.extensions?.map(\.name), ["Uno"])

		manager.enable("b")
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)
		await store.send(.ui(.siteMenu(.requestExtensionRemoval("b"))))
		expectNoDifference(store.state.siteMenu.menu?.removingExtension?.name, "Beta")
		await store.send(.ui(.siteMenu(.cancelExtensionRemoval)))
		expectNoDifference(store.state.siteMenu.menu?.removingExtension, nil)
		#expect(manager.actions.count == 1)

		await store.send(.ui(.siteMenu(.requestExtensionRemoval("b"))))
		await store.send(.ui(.siteMenu(.confirmExtensionRemoval)))
		await settle(store)
		expectNoDifference(manager.actions.last, .init(id: "b", action: .remove))
		expectNoDifference(store.state.siteMenu.menu?.extensions?.map(\.name), ["Uno"])
		#expect(store.state.siteMenu.menu?.notice == nil)
		_ = organization
	}

	/// DEV-1210. A tile marks a store update waiting for review, its menu's Review Update… leaves
	/// for the Extensions sheet, and removing the extension here drops the mark.
	@Test
	internal func aTileMarksAnUpdateWaitingForReviewUntilTheExtensionGoes() async throws {
		let manager = SiteMenuExtensionsDouble()
		let (store, organization) = makeStore(SiteMenuEngineDouble(), extensions: manager.client)
		let profileID = organization.tabs[0].profileID

		@Shared(.extensionUpdateReviews)
		var reviews

		$reviews.withLock {
			$0.offered(.init(profileID: profileID, extensionID: "b", installedVersion: "1", version: "2", permissions: ["tabs"]))
		}

		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)
		let tiles = try #require(store.state.siteMenu.menu?.extensions)
		expectNoDifference(tiles.filter(\.needsUpdateReview).map(\.id), ["b"])

		await store.send(.ui(.siteMenu(.reviewExtensionUpdate("b"))))
		await store.receive(\.delegate.reviewExtensionUpdate)

		// A tile without a waiting update has nothing to review.
		await store.send(.ui(.siteMenu(.reviewExtensionUpdate("u"))))

		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)
		await store.send(.ui(.siteMenu(.requestExtensionRemoval("b"))))
		await store.send(.ui(.siteMenu(.confirmExtensionRemoval)))
		await settle(store)
		#expect(reviews.pending.isEmpty)
	}

	@Test
	internal func contentBlockingTurnsOffForThisSiteAndBackOn() async throws {
		let engine = SiteMenuEngineDouble()
		engine.settings.contentBlockingIsAvailable = true
		engine.settings.contentBlockingOff = ["https://other.example"]
		let (store, _) = makeStore(engine)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)
		expectNoDifference(store.state.siteMenu.menu?.blocksContent, true)

		// Already on: nothing reaches the engine.
		await store.send(.ui(.siteMenu(.setContentBlocking(true))))
		await store.send(.ui(.siteMenu(.setContentBlocking(false))))
		await settle(store)
		expectNoDifference(store.state.siteMenu.menu?.blocksContent, false)
		await store.send(.ui(.siteMenu(.setContentBlocking(true))))
		await settle(store)

		expectNoDifference(engine.edits, [
			.setContentBlocking(origin: Self.origin, isOn: false),
			.setContentBlocking(origin: Self.origin, isOn: true),
		])
		expectNoDifference(store.state.siteMenu.menu?.blocksContent, true)
	}

	@Test
	internal func contentBlockingRowNeedsTheEngineAndTheSetting() async throws {
		let engine = SiteMenuEngineDouble()
		let (store, _) = makeStore(engine)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		// An engine without the Ads setting shows no row.
		expectNoDifference(store.state.siteMenu.menu?.blocksContent, nil)

		engine.settings.contentBlockingIsAvailable = true

		@Shared(.general)
		var general

		$general.withLock { $0.blocksContent = false }
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		// Content blocking off in Settings: no row, and nothing reaches the engine.
		expectNoDifference(store.state.siteMenu.menu?.blocksContent, nil)
		await store.send(.ui(.siteMenu(.setContentBlocking(false))))
		await settle(store)
		#expect(engine.edits.isEmpty)
		$general.withLock { $0.blocksContent = true }
	}

	// MARK: - Hide Element (DEV-1019)

	@Test
	internal func hiddenElementsListTheSitesOwnAndShowBringsOneBack() async throws {
		let engine = SiteMenuEngineDouble()
		engine.hidingAvailable = true
		engine.hidden = .init(sites: [
			"capturecontext.dev": ["capturecontext.dev##.ad", "capturecontext.dev,shop.example##div.banner"],
			"shop.example": ["capturecontext.dev,shop.example##div.banner"],
			"other.example": ["other.example##.ad"],
		])
		let (store, organization) = makeStore(engine)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		expectNoDifference(store.state.siteMenu.menu?.hiddenElements, [
			.init(id: "capturecontext.dev##.ad", selector: ".ad"),
			.init(id: "capturecontext.dev,shop.example##div.banner", selector: "div.banner"),
		])
		expectNoDifference(engine.hiddenReads, [organization.tabs[0].id])

		// Only a filter the menu lists reaches the engine. The page reloads once uBlock lists
		// the site without it, after its filters reload.
		engine.readsUntilShown = 2
		await store.send(.ui(.siteMenu(.showHiddenElement("other.example##.ad"))))
		#expect(engine.shown.isEmpty)
		await store.send(.ui(.siteMenu(.showHiddenElement("capturecontext.dev##.ad"))))
		await settle(store)

		// The read when the menu opened, two that still listed it, and the one without it;
		// then that tab's page reloads, wherever the window has moved on to.
		expectNoDifference(engine.hiddenReads.count, 4)
		expectNoDifference(engine.reloaded, [organization.tabs[0].id])
		expectNoDifference(engine.shown.map(\.filter), ["capturecontext.dev##.ad"])
		expectNoDifference(engine.shown.map(\.tabID), [organization.tabs[0].id])
		expectNoDifference(store.state.siteMenu.menu?.hiddenElements?.map(\.selector), ["div.banner"])

		// A page the person moved on from in that tab while Show waited isn't reloaded.
		engine.document = 7
		engine.navigatesWhileShowing = true
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)
		await store.send(.ui(.siteMenu(.showHiddenElement("capturecontext.dev,shop.example##div.banner"))))
		await settle(store)
		expectNoDifference(engine.reloaded.count, 1)
		engine.navigatesWhileShowing = false
		engine.hidden?.sites["capturecontext.dev"] = ["capturecontext.dev,shop.example##div.banner"]
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		// An engine that refuses keeps the row and reloads nothing.
		engine.showSucceeds = false
		await store.send(.ui(.siteMenu(.showHiddenElement("capturecontext.dev,shop.example##div.banner"))))
		await settle(store)
		expectNoDifference(store.state.siteMenu.menu?.hiddenElements?.count, 1)
		expectNoDifference(engine.reloaded.count, 1)

		await store.send(.ui(.siteMenu(.hideElement)))
		await store.receive(\.delegate.command, .hideElement)
	}

	@Test(arguments: [false, true])
	internal func hiddenElementsAndHideElementFollowTheirFeatureFlag(isOn: Bool) async throws {
		let engine = SiteMenuEngineDouble()
		engine.hidingAvailable = true
		engine.hidden = .init(sites: ["capturecontext.dev": ["capturecontext.dev##.ad"]])
		let (store, _) = makeStore(engine, hideElementEnabled: isOn)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		// `ARX_HIDE_ELEMENT` off: no section, no Hide Element… and nothing read; the window's
		// commands don't offer it either.
		expectNoDifference(
			store.state.siteMenu.menu?.hiddenElements,
			isOn ? [.init(id: "capturecontext.dev##.ad", selector: ".ad")] : nil
		)
		expectNoDifference(engine.hiddenReads.count, isOn ? 1 : 0)
		expectNoDifference(store.state.commandContext.canHideElements, isOn)
	}

	@Test
	internal func hiddenElementsNeedTheEngineContentBlockingAndAnOrdinaryWindow() async throws {
		let engine = SiteMenuEngineDouble()
		let (store, _) = makeStore(engine)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		// An engine without Hide Element shows no section and reads nothing.
		expectNoDifference(store.state.siteMenu.menu?.hiddenElements, nil)
		#expect(engine.hiddenReads.isEmpty)
		await store.send(.ui(.siteMenu(.hideElement)))
		await settle(store)

		engine.hidingAvailable = true

		@Shared(.general)
		var general

		$general.withLock { $0.blocksContent = false }
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)
		expectNoDifference(store.state.siteMenu.menu?.hiddenElements, nil)
		#expect(engine.hiddenReads.isEmpty)
		$general.withLock { $0.blocksContent = true }

		// A site with nothing hidden still offers Hide Element….
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)
		expectNoDifference(store.state.siteMenu.menu?.hiddenElements, [])
		#expect(store.state.siteMenu.menu?.canHideElement == true)

		// Not on a site with blocking off: uBlock wouldn't apply what's picked there.
		engine.settings.contentBlockingIsAvailable = true
		engine.settings.contentBlockingOff = [Self.origin]
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)
		#expect(store.state.siteMenu.menu?.canHideElement == false)
		await store.send(.ui(.siteMenu(.hideElement)))
		await settle(store)

		let (privateStore, _) = makeStore(engine, isPrivate: true)
		await privateStore.send(.ui(.siteMenu(.opened)))
		await settle(privateStore)
		expectNoDifference(privateStore.state.siteMenu.menu?.hiddenElements, nil)

		// The two ordinary opens with the engine and content blocking on read; the private one doesn't.
		expectNoDifference(engine.hiddenReads.count, 2)
	}

	@Test
	internal func permissionAndZoomChangesGoToTheEngineForThisSiteOnly() async throws {
		let engine = SiteMenuEngineDouble()
		let (store, _) = makeStore(engine)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		await store.send(.ui(.siteMenu(.setPermission(.microphone, .allow))))
		await settle(store)
		await store.send(.ui(.siteMenu(.setPermission(.camera, nil))))
		await settle(store)

		// Pop-ups take no ask; nothing reaches the engine.
		await store.send(.ui(.siteMenu(.setPermission(.popups, .ask))))
		await store.send(.ui(.siteMenu(.resetZoom)))
		await settle(store)

		expectNoDifference(engine.edits, [
			.setPermission(origin: Self.origin, .microphone, .allow),
			.setPermission(origin: Self.origin, .camera, nil),
			.setZoom(host: "capturecontext.dev", factor: nil),
		])
		expectNoDifference(store.state.siteMenu.menu?.permissions?.first { $0.permission == .microphone }?.setting, .allow)
		expectNoDifference(store.state.siteMenu.menu?.permissions?.first { $0.permission == .camera }?.setting, nil)
		expectNoDifference(store.state.siteMenu.menu?.zoom, nil)
	}

	@Test
	internal func clearingShowsTheSiteFirstAndClearsOnlyWhenConfirmed() async throws {
		let engine = SiteMenuEngineDouble()
		let (store, _) = makeStore(engine)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		await store.send(.ui(.siteMenu(.requestClear(.cookies))))
		await settle(store)
		expectNoDifference(store.state.siteMenu.clearing, .confirming(.cookies, domain: "capturecontext.dev"))
		await store.send(.ui(.siteMenu(.cancelClear)))
		expectNoDifference(store.state.siteMenu.clearing, nil)
		expectNoDifference(engine.cleared.count, 0)

		await store.send(.ui(.siteMenu(.requestClear(.cache))))
		await settle(store)
		await store.send(.ui(.siteMenu(.confirmClear)))
		await settle(store)
		expectNoDifference(store.state.siteMenu.clearing, .cleared(.cache, domain: "capturecontext.dev", isComplete: true))
		expectNoDifference(engine.cleared.map(\.kinds), [[.cache]])
		expectNoDifference(engine.cleared.map(\.url), [URL(string: Self.origin)!])

		engine.failed = [.cookies]
		await store.send(.ui(.siteMenu(.requestClear(.cookies))))
		await settle(store)
		await store.send(.ui(.siteMenu(.confirmClear)))
		await settle(store)
		expectNoDifference(store.state.siteMenu.clearing, .cleared(.cookies, domain: "capturecontext.dev", isComplete: false))

		engine.failure = .busy
		await store.send(.ui(.siteMenu(.requestClear(.cookies))))
		await settle(store)
		await store.send(.ui(.siteMenu(.confirmClear)))
		await settle(store)
		expectNoDifference(store.state.siteMenu.clearing, .failed(.cookies))
	}

	/// DEV-1142: a clear tells the app, which forgets hover cards' site details for that profile.
	@Test
	internal func aSiteDataClearReachesTheApp() async throws {
		let engine = SiteMenuEngineDouble()
		let (store, organization) = makeStore(engine)
		let profileID = organization.tabs[0].profileID
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		await store.send(.ui(.siteMenu(.requestClear(.cookies))))
		await settle(store)
		await store.send(.ui(.siteMenu(.confirmClear)))
		await store.receive(\.siteMenu.delegate.clearedSiteData, profileID)
		await store.receive(\.delegate.clearedSiteData, profileID)
		await settle(store)
	}

	@Test
	internal func closingDropsAnUnansweredQuestion() async throws {
		let engine = SiteMenuEngineDouble()
		let (store, _) = makeStore(engine)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)
		await store.send(.ui(.siteMenu(.requestClear(.cookies))))
		await settle(store)

		await store.send(.ui(.siteMenu(.closed)))
		expectNoDifference(store.state.siteMenu.clearing, nil)
		#expect(!store.state.siteMenu.isOpen)
		await store.send(.ui(.siteMenu(.confirmClear)))
		await settle(store)
		expectNoDifference(engine.cleared.count, 0)
	}

	@Test
	internal func privateWindowsOfferOnlySharingAndCapture() async throws {
		let engine = SiteMenuEngineDouble()
		let (store, _) = makeStore(engine, isPrivate: true)

		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)
		let menu = try #require(store.state.siteMenu.menu)
		#expect(menu.extensions == nil && menu.permissions == nil)
		#expect(!menu.canClearSiteData && !menu.canOpenSettings)

		await store.send(.ui(.siteMenu(.requestClear(.cookies))))
		await store.send(.ui(.siteMenu(.manageExtensions)))
		await store.send(.ui(.siteMenu(.setPermission(.camera, .block))))
		await settle(store)
		#expect(engine.listed.isEmpty && engine.edits.isEmpty && engine.scoped.isEmpty)
	}

	/// DEV-956: a private window shows the extensions its opener allows there, which run for
	/// its page, and names the ones that can't run in private windows; nothing else changes.
	@Test
	internal func privateWindowsShowTheirOpenersExtensionsAllowedThere() async throws {
		let engine = SiteMenuEngineDouble()
		engine.actionsAvailable = true
		let opener = Profile.ID(rawValue: UUID(70))
		var inspected: [Profile.ID] = []
		let extensions = BrowserExtensionsClient(isAvailable: true, inspect: { id in
			inspected.append(id)
			return .init(id: UUID(81), profileID: id, revision: 1, extensions: [
				.init(id: "b", name: "Beta", version: "1", state: .enabled,
				      allowedInPrivate: true, canAllowInPrivate: true),
				.init(id: "z", name: "Zeta", version: "1", state: .enabled, canAllowInPrivate: true),
				.init(id: "s", name: "Split", version: "1", state: .enabled,
				      allowedInPrivate: true, canAllowInPrivate: true, canRunInPrivate: false),
				// A component allowed there, as uBlock Origin is, runs no action: no tile.
				.init(id: "u", name: "Uno", version: "2", manifestVersion: 2, location: 5, state: .enabled,
				      allowedInPrivate: true),
			])
		})
		let (store, organization) = makeStore(engine, isPrivate: true, opener: opener, extensions: extensions)

		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		let menu = try #require(store.state.siteMenu.menu)
		expectNoDifference(inspected, [opener])
		expectNoDifference(menu.extensions?.map(\.name), ["Beta"])
		expectNoDifference(menu.unavailableInPrivate, ["Split"])
		#expect(menu.extensionsArePrivate && menu.permissions == nil && !menu.canOpenSettings)

		await store.send(.ui(.siteMenu(.runExtension("b", screenPoint: CGPoint(x: 40, y: 700)))))

		// Not allowed in private windows, and can't run there: never runs.
		await store.send(.ui(.siteMenu(.runExtension("z", screenPoint: .zero))))
		await store.send(.ui(.siteMenu(.runExtension("s", screenPoint: .zero))))
		await settle(store)
		expectNoDifference(engine.ran.map(\.tabID), [organization.tabs[0].id])
		expectNoDifference(engine.ran.map(\.extensionID), ["b"])
		#expect(engine.listed.isEmpty)
	}

	@Test
	internal func actionsLeaveForShareCaptureSettingsAndTheWebStore() async throws {
		let engine = SiteMenuEngineDouble()
		let (store, organization) = makeStore(engine)
		let profileID = organization.profiles[0].id
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		await store.send(.ui(.siteMenu(.share)))
		await store.receive(\.delegate.shareURL)
		await store.send(.ui(.siteMenu(.captureRegion)))
		await store.receive(\.delegate.command)
		await store.send(.ui(.siteMenu(.manageExtensions)))
		await store.receive(\.delegate.manageExtensions)
		await store.send(.ui(.siteMenu(.allSiteSettings)))
		await store.receive(\.delegate.openSiteSettings)

		// DEV-1317: the store opens in a new Little Arx of the page's profile, which the app
		// makes; the window itself gets no tab.
		let tabs = store.state.sidebar.organization.tabs.count
		await store.send(.ui(.siteMenu(.addExtension)))
		await store.receive(\.delegate.openWebstore, profileID)
		await settle(store)
		expectNoDifference(store.state.sidebar.organization.tabs.count, tabs)
	}

	@Test
	internal func wideAndManagedRulesDecideTheRows() throws {
		let origin = "https://www.example.com"
		let settings = SiteSettings(
			defaults: [
				.init(permission: .camera, setting: .ask),
				.init(permission: .location, setting: .block, isManaged: true),
			],
			exceptions: [
				.init(origin: "https://[*.]example.com", permission: .camera, setting: .block, isManaged: true),
				.init(origin: origin, permission: .camera, setting: .allow),
				.init(origin: "[*.]example.com", permission: .microphone, setting: .allow),
				.init(origin: "https://www.example.com:8443", permission: .clipboard, setting: .allow),
				.init(origin: "http://www.example.com", permission: .notifications, setting: .allow),
			]
		)
		let camera = settings.menuRow(.camera, origin: origin)
		#expect(camera.isManaged && camera.setting == nil && camera.effective == .block)
		let microphone = settings.menuRow(.microphone, origin: origin)
		#expect(!microphone.isManaged && microphone.setting == nil && microphone.effective == .allow)
		#expect(settings.menuRow(.location, origin: origin).isManaged)
		#expect(settings.menuRow(.clipboard, origin: origin).setting == nil)
		#expect(settings.menuRow(.notifications, origin: origin).setting == nil)
		#expect(settings.menuRow(.notifications, origin: "http://www.example.com").setting == .allow)

		// Default names what removing the site's own setting gives: the wider rule.
		let wide = SiteSettings(
			defaults: [.init(permission: .camera, setting: .ask), .init(permission: .microphone, setting: .block, isManaged: true)],
			exceptions: [
				.init(origin: "[*.]example.com", permission: .camera, setting: .allow),
				.init(origin: origin, permission: .camera, setting: .block),
				.init(origin: origin, permission: .microphone, setting: .allow),
			]
		)
		let own = wide.menuRow(.camera, origin: origin)
		#expect(own.setting == .block && own.defaultSetting == .allow)
		// A managed default wins over the user's own Allow, and shows what applies.
		let managed = wide.menuRow(.microphone, origin: origin)
		#expect(managed.isManaged && managed.setting == nil && managed.effective == .block)
	}

	@Test
	internal func aLongAddressKeepsItsSiteAndAFailedLoadIsntSecure() throws {
		let long = URL(string: "https://capturecontext.dev/a?q=" + String(repeating: "x", count: 4_000))!
		var context = SiteMenuFeature.Context(url: long, profileID: .init(rawValue: UUID(0)))
		expectNoDifference(context.origin, "https://capturecontext.dev")
		expectNoDifference(context.zoomHost, "capturecontext.dev")
		expectNoDifference(context.connection, .secure)
		context.loadFailed = true
		expectNoDifference(context.connection, .notSecure)
	}

	@Test
	internal func aLateScopeReplyNeverClearsAnotherPage() async throws {
		let engine = SiteMenuEngineDouble()
		let (store, _) = makeStore(engine)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)
		await store.send(.ui(.siteMenu(.requestClear(.cookies))))
		let request = store.state.siteMenu.clearRequest
		await store.send(.ui(.siteMenu(.closed)))
		await store.send(.ui(.siteMenu(.opened)))
		await store.send(.ui(.siteMenu(.requestClear(.cookies))))
		await store.send(.siteMenu(.event(.scoped(request: request, .cookies, .success("old.example")))))
		#expect(store.state.siteMenu.clearing != .confirming(.cookies, domain: "old.example"))
		await settle(store)
		expectNoDifference(store.state.siteMenu.clearing, .confirming(.cookies, domain: "capturecontext.dev"))
	}

	@Test
	internal func arxExtensionsIsTheExtensionsCommand() {
		expectNoDifference(CommandBarFeature.State.internalCommand("arx://extensions"), .extensions)
		expectNoDifference(CommandBarFeature.State.internalCommand(" ARX://Extensions/ "), .extensions)
		expectNoDifference(CommandBarFeature.State.internalCommand("arx://extensions?id=a"), nil)
		expectNoDifference(CommandBarFeature.State.internalCommand("arx://settings"), nil)
		expectNoDifference(CommandBarFeature.State.internalCommand("https://extensions"), nil)
		#expect(BrowserCommand.extensions.isEnabled(in: .init(host: .main)))
		#expect(!BrowserCommand.extensions.isEnabled(in: .init(host: .main, isPrivate: true)))
		#expect(!BrowserCommand.extensions.isEnabled(in: .init(host: .little)))
	}

	@Test
	internal func manageExtensionsOpensSettingsAtTheProfilesExtensions() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let profileID = organization.profiles[0].id
		let inventory = BrowserExtensionInventory(id: UUID(70), profileID: profileID, revision: 1, extensions: [])
		let store = Store(initialState: AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))) {
			AppFeature()
		} withDependencies: {
			$0.browserExtensions = .init(isAvailable: true, inspect: { _ in inventory })
		}

		await store.send(.main(.delegate(.manageExtensions(profileID)))).finish()
		#expect(store.settingsIsOpen)
		expectNoDifference(store.settings.category, .profiles)
		expectNoDifference(store.settings.selectedProfileID, profileID)
		#expect(store.settings.extensions.isPresented)

		await store.send(.ui(.closeSettings)).finish()
		await store.send(.main(.delegate(.openSiteSettings(profileID)))).finish()
		#expect(store.settingsIsOpen)
		expectNoDifference(store.settings.siteSettings?.profileID, profileID)

		// A profile the workspace doesn't have opens nothing.
		await store.send(.ui(.closeSettings)).finish()
		await store.send(.ui(.openExtensions(.init(rawValue: UUID(99))))).finish()
		#expect(!store.settingsIsOpen)
	}

	/// DEV-801: the store is a command, found by its name or by what it's for.
	@Test
	internal func chromeWebStoreCommandIsListedAndOpensTheStoreInTheWindowsProfile() async throws {
		#expect(BrowserCommand.chromeWebStore.isEnabled(in: .init(host: .main)))
		#expect(!BrowserCommand.chromeWebStore.isEnabled(in: .init(host: .main, isPrivate: true)))
		#expect(!BrowserCommand.chromeWebStore.isEnabled(in: .init(host: .little)))

		let entry = CommandBarFeature.Entry.command(.chromeWebStore, bindings: [])
		expectNoDifference(entry.presentation.title, "Chrome Web Store")
		expectNoDifference(entry.presentation.subtitle, "Get extensions")
		expectNoDifference(CommandBarFeature.Entry.command(.extensions, bindings: []).presentation.subtitle, "")

		let organization = IntegrationFeatureTests().fixture()
		let space = organization.spaces[0]
		var state = AppFeature.State(main: .init(organization: organization, spaceID: space.id))
		state.routingInbox.isReady = true
		let store = Store(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		let commands = store.main.commandCandidates
		#expect(commands.contains { $0.intent == .command(.chromeWebStore) })

		// DEV-1317: in a new Little Arx of the window's profile, which takes focus, not a tab.
		let tabs = store.workspace.tabs.count
		await store.send(.ui(.command(.chromeWebStore, .window(store.main.id, paneID: nil)))).finish()
		let opened = try #require(store.littleWindows.last)
		expectNoDifference(opened.tab.restoration.url, BrowserWebstoreInstallRequest.storeURL)
		expectNoDifference(opened.tab.profileID, space.profileID)
		expectNoDifference(opened.spaceID, space.id)
		expectNoDifference(store.focusedWindowID, opened.id)
		expectNoDifference(store.workspace.tabs.count, tabs)
	}

	@Test
	internal func anExtensionsTileRunsItsActionForThePageAtTheTile() async throws {
		let engine = SiteMenuEngineDouble()
		engine.actionsAvailable = true
		let (store, organization) = makeStore(engine)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		await store.send(.ui(.siteMenu(.runExtension("b", screenPoint: CGPoint(x: 40, y: 700)))))
		await settle(store)

		expectNoDifference(engine.ran.map(\.tabID), [organization.tabs[0].id])
		expectNoDifference(engine.ran.map(\.extensionID), ["b"])
		expectNoDifference(engine.ran.map(\.point), [CGPoint(x: 40, y: 700)])

		// A disabled or unlisted extension never runs.
		await store.send(.ui(.siteMenu(.runExtension("a", screenPoint: .zero))))
		await settle(store)
		expectNoDifference(engine.ran.count, 1)
	}

	/// The panel dismisses itself before it sends the tile's click, so the menu has closed by
	/// the time the action runs. The click still runs once, for its page, at the tile.
	@Test
	internal func aTileClickedAsTheMenuClosesStillRunsOnceAtTheTile() async throws {
		let engine = SiteMenuEngineDouble()
		engine.actionsAvailable = true
		let (store, organization) = makeStore(engine)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		await store.send(.ui(.siteMenu(.closed)))
		await store.send(.ui(.siteMenu(.runExtension("b", screenPoint: CGPoint(x: 12, y: 340)))))
		await settle(store)

		expectNoDifference(engine.ran.map(\.tabID), [organization.tabs[0].id])
		expectNoDifference(engine.ran.map(\.point), [CGPoint(x: 12, y: 340)])
	}

	/// The action runs in an effect after the click. Closing the menu in the same turn doesn't
	/// cancel it, and nothing runs twice.
	@Test
	internal func closingTheMenuRightAfterAClickDoesNotCancelTheAction() async throws {
		let engine = SiteMenuEngineDouble()
		engine.actionsAvailable = true
		let (store, organization) = makeStore(engine)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		await store.send(.ui(.siteMenu(.runExtension("b", screenPoint: CGPoint(x: 40, y: 700)))))
		await store.send(.ui(.siteMenu(.closed)))
		await settle(store)

		expectNoDifference(engine.ran.map(\.tabID), [organization.tabs[0].id])
		expectNoDifference(engine.ran.map(\.extensionID), ["b"])
		expectNoDifference(engine.ran.map(\.point), [CGPoint(x: 40, y: 700)])
		#expect(!store.state.siteMenu.isOpen)
	}

	@Test(arguments: [nil, BrowserExtensionActionFailure.refused, .invalid, .unavailable])
	internal func aTileTheEngineCantRunOpensTheExtensionsSheetOnIt(
		_ failure: BrowserExtensionActionFailure?
	) async throws {
		let engine = SiteMenuEngineDouble()

		// nil: an engine without ABI48.
		engine.actionsAvailable = failure != nil
		engine.actionFailure = failure
		let (store, organization) = makeStore(engine)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		await store.send(.ui(.siteMenu(.runExtension("b", screenPoint: .zero))))
		await store.receive(\.delegate.showExtension)
		expectNoDifference(engine.ran.count, 0)
		_ = organization
	}

	@Test
	internal func aTileDoesNothingOnceThePageIsNoLongerShown() async throws {
		let engine = SiteMenuEngineDouble()
		engine.actionsAvailable = true
		let (store, organization) = makeStore(engine)
		await store.send(.ui(.siteMenu(.opened)))
		await settle(store)

		// Another tab is shown now; the menu still describes the first.
		var state = store.state
		state.viewer.item.tab = organization.tabs[1]
		let moved = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.browserEngine = engine.client
		}
		moved.exhaustivity = .off(showSkippedAssertions: false)
		await moved.send(.ui(.siteMenu(.runExtension("b", screenPoint: .zero))))
		await moved.finish()
		expectNoDifference(engine.ran.count, 0)
	}

	/// Runs every effect and applies what they sent, which a non-exhaustive store leaves queued.
	private func settle(_ store: TestStoreOf<MainFeature>) async {
		await store.finish()
		await store.skipReceivedActions(strict: false)
	}

	private func makeStore(
		_ engine: SiteMenuEngineDouble,
		isPrivate: Bool = false,
		opener: Profile.ID? = nil,
		extensions: BrowserExtensionsClient? = nil,
		hideElementEnabled: Bool = true
	) -> (TestStoreOf<MainFeature>, BrowserOrganization) {
		let organization = IntegrationFeatureTests().fixture()
		var state = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: isPrivate,
			captureAvailable: true
		)
		state.viewer.item.tab = organization.tabs[0]
		state.privateOpenerProfileID = opener
		state.siteMenu.hideElementEnabled = hideElementEnabled
		let store = TestStore(initialState: state) {
			MainFeature()
		} withDependencies: {
			$0.uuid = .incrementing
			$0.continuousClock = ImmediateClock()
			$0.browserEngine = engine.client
			$0.browserExtensions = .init(isAvailable: true, inspect: { id in
				.init(id: UUID(80), profileID: id, revision: 1, extensions: [
					.init(id: "z", name: "Zeta", version: "1", state: .enabled),
					.init(id: "a", name: "Alpha", version: "1", state: .disabled),
					.init(id: "b", name: "Beta", version: "1", state: .enabled, iconPath: "/extensions/b/icon.png"),
				])
			}, icon: { path in
				path == "/extensions/b/icon.png" ? Data("beta icon".utf8) : nil
			})
			if let extensions { $0.browserExtensions = extensions }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return (store, organization)
	}
}

@MainActor
private final class SiteMenuEngineDouble {
	var settings = SiteSettings(
		defaults: [
			.init(permission: .camera, setting: .ask),
			.init(permission: .microphone, setting: .block),
			.init(permission: .popups, setting: .block),
		],
		exceptions: [
			.init(origin: "https://capturecontext.dev", permission: .camera, setting: .allow),
			.init(origin: "https://other.example", permission: .microphone, setting: .allow),
		],
		zoom: [.init(host: "capturecontext.dev", factor: 1.25)]
	)
	var listed: [Profile.ID] = []
	var edits: [SiteSettingsEdit] = []
	var scoped: [URL] = []
	var cleared: [(url: URL, kinds: Set<BrowsingDataKind>)] = []
	var failed: Set<BrowsingDataKind> = []
	var failure: ProfileDataFailure?
	var actionsAvailable = false

	/// DEV-824 follow-up: icons extensions set for the page, by extension.
	var actionIcons: [String: Data] = [:]
	var actionIconReads: [(tabID: BrowserCore.Tab.ID, extensionID: String, scale: Float)] = []
	var actionFailure: BrowserExtensionActionFailure?
	var ran: [(tabID: BrowserCore.Tab.ID, extensionID: String, point: CGPoint)] = []

	/// DEV-1019.
	var hidingAvailable = false
	var hidden: BrowserHiddenElements? = .init()
	var hiddenReads: [BrowserCore.Tab.ID] = []
	var shown: [(tabID: BrowserCore.Tab.ID, filter: String)] = []
	var showSucceeds = true

	/// How many reads still list a shown filter before uBlock's filters reload.
	var readsUntilShown = 0
	var reloaded: [BrowserCore.Tab.ID] = []

	/// The page's document, as the engine numbers it; nil keeps the snapshot nil.
	var document: UInt64?

	/// A page that changes document while Show waits.
	var navigatesWhileShowing = false
	var pendingShow: (filter: String, reads: Int)?

	var client: BrowserEngineClient {
		var client = BrowserEngineClient(status: { .ready })
		client.elementHidingIsAvailable = { [self] in hidingAvailable }
		client.command = { [self] tabID, command in
			if command == .reload { reloaded.append(tabID) }
		}
		client.snapshot = { [self] _ in
			document.map { .init(navigation: .init(url: URL(string: "https://capturecontext.dev")!), revision: 1, documentRevision: $0) }
		}
		client.extensionActionIcon = { [self] tabID, extensionID, scale in
			actionIconReads.append((tabID, extensionID, scale))
			return actionIcons[extensionID]
		}
		client.hiddenElements = { [self] tabID in
			hiddenReads.append(tabID)
			if let pending = pendingShow {
				if pending.reads == 0 {
					let remaining = hidden?.sites.mapValues { $0.filter { $0 != pending.filter } } ?? [:]
					hidden?.sites = remaining
					pendingShow = nil
				} else {
					pendingShow = (pending.filter, pending.reads - 1)
				}
			}
			return hidden
		}
		client.showHiddenElement = { [self] tabID, filter in
			shown.append((tabID, filter))
			guard showSucceeds else { return false }
			if navigatesWhileShowing, let current = document {
				// The snapshot taken with Show sees the page before; the next read, after.
				Task { @MainActor in self.document = current + 1 }
			}

			// uBlock lists the site again without it once its filters reload, a few reads later.
			pendingShow = (filter, readsUntilShown)
			return true
		}
		client.siteSettings = { [self] id throws(SiteSettingsFailure) in
			listed.append(id)
			return settings
		}
		client.changeSiteSettings = { [self] _, edit throws(SiteSettingsFailure) in
			edits.append(edit)
			switch edit {
			case let .setPermission(origin?, permission, setting):
				var exceptions = settings.exceptions.filter { !($0.origin == origin && $0.permission == permission) }
				if let setting { exceptions.append(.init(origin: origin, permission: permission, setting: setting)) }
				settings = .init(defaults: settings.defaults, exceptions: exceptions, zoom: settings.zoom)
			case let .setZoom(host?, nil):
				settings = .init(defaults: settings.defaults, exceptions: settings.exceptions, zoom: settings.zoom.filter { $0.host != host })
			case let .setContentBlocking(origin, isOn):
				settings.contentBlockingOff.removeAll { $0 == origin }
				if !isOn { settings.contentBlockingOff.append(origin) }
			default:
				break
			}
			return settings
		}
		client.extensionActionsAreAvailable = { [self] in actionsAvailable }
		client.runExtensionAction = { [self] tabID, extensionID, point throws(BrowserExtensionActionFailure) in
			if let actionFailure { throw actionFailure }
			ran.append((tabID, extensionID, point))
			return .popup
		}
		client.siteDataIsAvailable = { true }
		client.siteDataScope = { [self] _, url throws(ProfileDataFailure) in
			scoped.append(url)
			return url.host()!
		}
		client.clearSiteData = { [self] _, url, kinds throws(ProfileDataFailure) in
			cleared.append((url, kinds))
			if let failure { throw failure }
			return failed
		}
		return client
	}
}

/// Two enabled extensions: Beta the person installed, Uno a browser component (DEV-891).
@MainActor
private final class SiteMenuExtensionsDouble {
	struct Change: Equatable {
		var id: String
		var action: BrowserExtensionAction
	}

	var actions: [Change] = []
	private var revision: UInt64 = 1
	private var beta: BrowserExtension? = SiteMenuExtensionsDouble.beta(enabled: true)

	static func beta(enabled: Bool, allowedInPrivate: Bool = false) -> BrowserExtension {
		.init(
			id: "b", name: "Beta", version: "1", state: enabled ? .enabled : .disabled,
			disableReasons: enabled ? [] : [.userAction],
			canEnable: !enabled, canDisable: enabled, canRemove: true,
			allowedInPrivate: allowedInPrivate, canAllowInPrivate: true
		)
	}

	func enable(_ id: String) {
		beta = Self.beta(enabled: true)
		revision += 1
	}

	private func inventory(_ profileID: Profile.ID) -> BrowserExtensionInventory {
		.init(id: UUID(Int(revision) + 90), profileID: profileID, revision: revision, extensions: [
			// A toolbar action, as uBlock Origin has: a component with nothing to open has no tile.
			.init(id: "u", name: "Uno", version: "1", location: 5, state: .enabled, actionIcons: [16: "/resources/u/16.png"]),
		] + (beta.map { [$0] } ?? []))
	}

	var client: BrowserExtensionsClient {
		.init(
			isAvailable: true,
			inspect: { [self] id in inventory(id) },
			manage: { [self] request in
				actions.append(.init(id: request.extensionID, action: request.action))
				switch request.action {
				case .disable: beta = Self.beta(enabled: false)
				case .remove: beta = nil
				case .allowInPrivate: beta = Self.beta(enabled: true, allowedInPrivate: true)
				case .disallowInPrivate: beta = Self.beta(enabled: true, allowedInPrivate: false)
				default: break
				}
				revision += 1
				return inventory(request.profileID)
			}
		)
	}
}
