@testable import AppFeature
import AppUI
import BrowserCaptureClient
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
@testable import CommandBarFeature
import CustomDump
import Foundation
@testable import MainFeature
import PageCaptureFeature
import Testing
import _ComposableArchitecture

/// DEV-795: the shortcuts and menu items Safari and Chrome share that Arx lacked.
@Suite(.dependencies)
@MainActor
internal struct StandardShortcutTests {
	@Test
	internal func theNewCommandsUseTheKeysOtherBrowsersUse() {
		expectNoDifference(BrowserCommand.printPage.shortcut, .init(key: "p"))
		expectNoDifference(BrowserCommand.openFile.shortcut, .init(key: "o"))
		expectNoDifference(BrowserCommand.showHistory.shortcut, .init(key: "y"))
		expectNoDifference(BrowserCommand.viewSource.shortcut, .init(key: "u", modifiers: [.command, .option]))
		expectNoDifference(BrowserCommand.stopLoading.shortcut, .init(key: "."))
		expectNoDifference(BrowserCommand.nextTab.shortcut, .init(key: "]", modifiers: [.command, .shift]))
		expectNoDifference(BrowserCommand.previousTab.shortcut, .init(key: "[", modifiers: [.command, .shift]))
		expectNoDifference(BrowserCommand.selectTab.map(\.shortcut), (1...9).map { .init(key: "\($0)") })
		expectNoDifference(BrowserCommand.selectTab.map(\.tabNumber), (1...9).map { $0 })

		// ⌘S stays Toggle Sidebar and ⇧⌘P stays Open Focused Link in Peek.
		expectNoDifference(BrowserCommand.savePageAs.shortcut, nil)
		expectNoDifference(BrowserCommand.pageSetup.shortcut, nil)
		expectNoDifference(BrowserCommand.toggleSidebar.shortcut, .init(key: "s"))
		expectNoDifference(BrowserCommand.openFocusedLinkInPeek.shortcut, .init(key: "p", modifiers: [.command, .shift]))

		// Page PiP (DEV-950) takes ⌥⌘P, which nothing else uses.
		expectNoDifference(BrowserCommand.pagePictureInPicture.shortcut, .init(key: "p", modifiers: [.command, .option]))
	}

	@Test
	internal func everyDefaultShortcutIsDistinctAndValid() throws {
		let shortcuts = BrowserCommand.allCases.compactMap(\.shortcut)
		expectNoDifference(Set(shortcuts).count, shortcuts.count)
		#expect(shortcuts.allSatisfy { $0.isValid && !$0.isReserved })
		try BrowserPreferences().validateKeyboardShortcuts()
	}

	@Test
	internal func aKeyTheUserAlreadyBoundKeepsItsCommand() throws {
		var preferences = BrowserPreferences()
		preferences.setShortcut(.init(key: "y"), for: .reload)
		try preferences.validateKeyboardShortcuts()

		expectNoDifference(preferences.shortcut(for: .showHistory), nil)
		expectNoDifference(preferences.shortcut(for: .reload), .init(key: "y"))
	}

	@Test
	internal func commandsAreAvailableOnlyWhereTheyWork() {
		let page = BrowserCommandContext(host: .main, hasTab: true, canSavePage: true, tabCount: 3)
		#expect(BrowserCommand.printPage.isEnabled(in: page))
		#expect(BrowserCommand.savePageAs.isEnabled(in: page))
		#expect(BrowserCommand.viewSource.isEnabled(in: page))
		#expect(!BrowserCommand.stopLoading.isEnabled(in: page))
		#expect(BrowserCommand.stopLoading.isEnabled(in: .init(host: .main, hasTab: true, isLoading: true)))

		// Arx's own pages and empty tabs have nothing to print or save.
		let local = BrowserCommandContext(host: .main, hasTab: true)
		#expect(!BrowserCommand.printPage.isEnabled(in: local))
		#expect(!BrowserCommand.savePageAs.isEnabled(in: local))
		#expect(!BrowserCommand.viewSource.isEnabled(in: local))

		// A private page prints and saves too (DEV-816, DEV-971).
		let privatePage = BrowserCommandContext(host: .main, hasTab: true, isPrivate: true, canSavePage: true)
		#expect(BrowserCommand.printPage.isEnabled(in: privatePage))
		#expect(BrowserCommand.savePageAs.isEnabled(in: privatePage))
		#expect(!BrowserCommand.savePageAs.isEnabled(in: .init(host: .main, hasTab: true, isPrivate: true)))
		#expect(!BrowserCommand.showHistory.isEnabled(in: privatePage))

		#expect(BrowserCommand.tab3.isEnabled(in: page))
		#expect(!BrowserCommand.tab4.isEnabled(in: page))
		#expect(BrowserCommand.lastTab.isEnabled(in: page))
		#expect(BrowserCommand.nextTab.isEnabled(in: page))
		#expect(!BrowserCommand.nextTab.isEnabled(in: .init(host: .main, tabCount: 1)))
		#expect(!BrowserCommand.tab1.isEnabled(in: .init(host: .little, hasTab: true, tabCount: 3)))

		// Little Arx keeps ⌘O for Open in Space.
		#expect(BrowserCommand.openFile.isEnabled(in: .init(host: .main)))
		#expect(!BrowserCommand.openFile.isEnabled(in: .init(host: .little, hasTab: true)))
		#expect(BrowserCommand.pageSetup.isEnabled(in: .init(host: .application)))
	}

	@Test
	internal func tabShortcutsSelectInSidebarOrderAndNineIsTheLastTab() async throws {
		var organization = IntegrationFeatureTests().fixture()
		let third = BrowserCore.Tab(
			id: .init(rawValue: UUID(9)),
			profileID: organization.profiles[0].id,
			restoration: .init(title: "Third", url: URL(string: "https://example.com")!)
		)
		organization.tabs.append(third)
		organization.spaces[0].unpinnedTabs.append(third.id)
		let order = organization.tabOrder(in: organization.spaces[0].id)
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		let window = AppFeature.CommandTarget.window(store.state.main.id)

		await store.send(.ui(.command(.lastTab, window)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, order[2])

		await store.send(.ui(.command(.nextTab, window)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, order[0])

		await store.send(.ui(.command(.previousTab, window)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, order[2])

		await store.send(.ui(.command(.tab2, window)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, order[1])
		await store.finish()
	}

	@Test
	internal func openInNewTabAddsAndSelectsTheTab() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let store = TestStore(initialState: MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let source = try #require(URL(string: "view-source:https://capturecontext.dev/"))

		await store.send(.ui(.openInNewTab(source)))
		await store.skipReceivedActions()
		let selected = try #require(store.state.sidebar.selectedTab)
		expectNoDifference(selected.restoration.url, source)

		// Right below the tab it was opened from (DEV-1243).
		expectNoDifference(store.state.sidebar.space.unpinnedTabs, [organization.tabs[0].id, selected.id, organization.tabs[1].id])
		await store.finish()
	}

	@Test
	internal func historyModeListsOnlyHistory() {
		let profile = Profile.ID(rawValue: UUID(0))
		let space = Space.ID(rawValue: UUID(1))
		func history(_ id: Int, _ title: String) -> CommandBarFeature.Entry {
			let url = URL(string: "https://example.com/\(id)")!
			return .init(
				presentation: .init(
					id: "history-\(id)",
					title: title,
					subtitle: url.absoluteString,
					actionTitle: "Open",
					symbol: "clock"
				),
				intent: .openHistory(.init(id: UUID(id), profileID: profile, spaceID: space, url: url))
			)
		}
		let tab = CommandBarFeature.Entry(
			presentation: .init(id: "tab", title: "Swift", subtitle: "", actionTitle: "Switch", symbol: "globe"),
			intent: .selectTab(.init(rawValue: UUID(2)))
		)
		var state = CommandBarFeature.State(
			mode: .history,
			candidates: [tab, history(1, "Swift forums"), history(2, "Rust book")]
		)
		expectNoDifference(state.entries.map(\.presentation.id), ["history-1", "history-2"])

		state.query = "swift"
		expectNoDifference(state.entries.map(\.presentation.id), ["history-1"])
	}

	@Test
	internal func aPageMenuChoiceGoesToTheHostShowingTheTab() {
		let organization = IntegrationFeatureTests().fixture()
		let state = AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))
		let shown = state.main.viewer.item.tab?.id
		if let shown {
			#expect(state.commandTarget(showing: shown) != nil)
		}
		#expect(state.commandTarget(showing: .init(rawValue: UUID(99))) == nil)
	}

	@Test
	internal func historyModeKeepsItsFilterOnThisMacAndSelectsOnlyWhatItLists() {
		let profile = Profile.ID(rawValue: UUID(0))
		let url = URL(string: "https://example.com/docs")!
		let history = CommandBarFeature.Entry(
			presentation: .init(id: "history-1", title: "Docs", subtitle: url.absoluteString, actionTitle: "Open", symbol: "clock"),
			intent: .openHistory(.init(id: UUID(1), profileID: profile, spaceID: .init(rawValue: UUID(2)), url: url))
		)
		let tab = CommandBarFeature.Entry(
			presentation: .init(
				id: "tab",
				title: "Example",
				subtitle: "https://example.com/",
				actionTitle: "Switch",
				symbol: "globe",
				alias: "example"
			),
			intent: .selectTab(.init(rawValue: UUID(3)))
		)
		var state = CommandBarFeature.State(mode: .history, candidates: [tab, history])
		state.suggestsRemotely = true
		state.query = "example"

		expectNoDifference(state.suggestionText, nil)
		expectNoDifference(state.addressMatchID, nil)
		expectNoDifference(state.aliasMatch, nil)
		expectNoDifference(state.entries.map(\.presentation.id), ["history-1"])

		state.mode = .newTab
		expectNoDifference(state.suggestionText, "example")
	}

	@Test
	internal func showHistoryListsPagesOpenTabsAlreadyShow() {
		let organization = IntegrationFeatureTests().fixture()
		let profile = organization.profiles[0].id
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let open = BrowsingHistoryEntry(id: UUID(10), url: organization.tabs[0].restoration.url, title: "Open", lastVisited: .now)
		state.browsingHistory[profile] = .init(profileID: profile, entries: [open])

		expectNoDifference(state.historyCandidates(profileID: profile).count, 0)
		expectNoDifference(
			state.historyCandidates(profileID: profile, excludingOpenTabs: false).map(\.presentation.subtitle),
			[open.url.absoluteString]
		)
	}

	@Test
	internal func pageMenuOffersWhatTheWindowAllowsNow() throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.main.viewer.item.navigation = .init(url: URL(string: "https://capturecontext.dev")!, isLoading: true)

		let context = try #require(state.commandContext(for: .window(state.main.id)))
		#expect(context.isLoading)
		#expect(context.canSavePage)
		let commands = state.pageMenuCommands(showing: organization.tabs[0].id)
		#expect(commands.isSuperset(of: [.reload, .savePageAs, .printPage, .viewSource]))
		#expect(!commands.contains(.goBack))
	}

	@Test
	internal func pageSetupPaperReachesTheExportInPortraitInches() {
		let a4 = CGSize(width: 595, height: 842)
		let portrait = PageLayout(paperSize: a4, isLandscape: false)
		let landscape = PageLayout(paperSize: CGSize(width: 842, height: 595), isLandscape: true)

		expectNoDifference(portrait.paperWidth.map { ($0 * 100).rounded() }, 826)
		expectNoDifference(portrait.paperHeight.map { ($0 * 100).rounded() }, 1169)
		expectNoDifference(landscape.paperWidth, portrait.paperWidth)
		expectNoDifference(landscape.paperHeight, portrait.paperHeight)
		#expect(landscape.isLandscape)
		expectNoDifference(PageLayout(paperSize: .zero, isLandscape: false).paperWidth, nil)
	}

	@Test
	internal func saveAsRefusesAPageThatNavigatedWhileThePanelWasOpen() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let tab = organization.tabs[0]
		state.main.viewer.item.tab = tab
		state.main.viewer.item.navigation = .init(url: URL(string: "https://capturecontext.dev")!)
		let source = try #require(state.captureSource(for: .window(state.main.id)))
		let document = LockIsolated<UInt64>(1)
		let saved = LockIsolated(0)
		let alerts = LockIsolated(0)
		var engine = BrowserEngineClient(status: { .notIntegrated })
		engine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: document.value) }
		engine.savePageIsAvailable = { true }
		engine.savePage = { _, _, _ in saved.withValue { $0 += 1 } }
		var documents = PageDocumentsClient.testValue
		let asked = LockIsolated(0)
		var capture = BrowserCaptureClient()
		capture.pdfIsAvailable = { true }
		capture.pdfAuthorized = { _, _ in throw PageCaptureFailure.unsupportedRendering }
		documents.chooseSaveDestination = { _, _, _ in
			asked.withValue { $0 += 1 }
			document.setValue(2)  // The page navigated meanwhile.
			return (URL(fileURLWithPath: "/tmp/page.mhtml"), .webArchive)
		}
		documents.alert = { _ in alerts.withValue { $0 += 1 } }

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.browserCapture = capture
			$0.pageDocuments = documents
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.savePage(source)))
		await store.finish()

		expectNoDifference(asked.value, 1)
		expectNoDifference(saved.value, 0)
		expectNoDifference(alerts.value, 1)
	}

	@Test
	internal func historyModeHasNoKeywordSearchOrChat() async {
		let document = WorkspaceDocument.unsaved(BrowserPreferences(searchShortcuts: SearchShortcut.fixtures))
		var state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			CommandBarFeature.State(isPresented: true, mode: .newTab)
		}
		state.query = "gh"
		state.isChatAvailable = true

		// A person's "gh" scopes a search outside Show History.
		expectNoDifference(state.pendingShortcutKeyword, "gh")

		state.mode = .history
		expectNoDifference(state.pendingShortcutKeyword, nil)
		expectNoDifference(state.chatPrompt, nil)

		let store = TestStore(initialState: state) { CommandBarFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.tabPressed))
		expectNoDifference(store.state.siteSearchKeyword, nil)
		expectNoDifference(store.state.isPresented, true)
	}

	@Test
	internal func saveAsSavesAPDFDocumentAsItsOwnBytes() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.main.viewer.item.navigation = .init(url: URL(string: "https://capturecontext.dev/paper.pdf")!)
		let source = try #require(state.captureSource(for: .window(state.main.id)))
		let bytes = Data("%PDF-1.7 paper".utf8)
		let offered = LockIsolated<[PageSaveFormat]>([])
		let written = LockIsolated<Data?>(nil)
		let saved = LockIsolated(0)
		var engine = BrowserEngineClient(status: { .notIntegrated })
		engine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 1) }
		engine.savePageIsAvailable = { true }
		engine.savePage = { _, _, _ in saved.withValue { $0 += 1 } }
		var capture = BrowserCaptureClient()
		capture.pdfIsAvailable = { true }
		capture.pdfAuthorized = { request, _ in
			guard request.kind == .source else { throw PageCaptureFailure.unsupportedRendering }
			return .init(request: request, documentID: "paper", data: bytes)
		}
		var documents = PageDocumentsClient.testValue
		documents.chooseSaveDestination = { _, formats, _ in
			offered.setValue(formats)
			return (URL(fileURLWithPath: "/tmp/paper.pdf"), formats[0])
		}
		documents.write = { data, _ in written.setValue(data) }

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.browserCapture = capture
			$0.pageDocuments = documents
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.savePage(source)))

		// Several reads in one effect: allow for a loaded machine.
		await store.finish(timeout: .seconds(30))

		expectNoDifference(offered.value, [.pdf])
		expectNoDifference(written.value, bytes)
		expectNoDifference(saved.value, 0)
	}

	@Test
	internal func pasteAndMatchStyleGivesWayToAUserBinding() {
		var bindings: [ShortcutBinding] = []
		expectNoDifference(bindings.pasteAndMatchStyleShortcut, .pasteAndMatchStyle)

		bindings.setShortcut(.pasteAndMatchStyle, for: .reload)
		expectNoDifference(bindings.pasteAndMatchStyleShortcut, nil)
		expectNoDifference(bindings.shortcut(for: .reload), .pasteAndMatchStyle)
		#expect(!BrowserCommand.allCases.contains { $0.shortcut == .pasteAndMatchStyle })
	}

	@Test
	internal func printShowsItsSheetOnTheWindowItStartedIn() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.main.viewer.item.navigation = .init(url: URL(string: "https://capturecontext.dev")!)
		let source = try #require(state.captureSource(for: .window(state.main.id)))
		expectNoDifference(state.presentationWindowID(for: source), state.main.id)
		let printedIn = LockIsolated<UUID?>(nil)
		var engine = BrowserEngineClient(status: { .notIntegrated })
		engine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 1) }
		var capture = BrowserCaptureClient()
		capture.pdfIsAvailable = { true }
		capture.pdfAuthorized = { request, _ in
			guard request.kind != .source else { throw PageCaptureFailure.unsupportedRendering }
			return .init(request: request, documentID: "page", data: Data("%PDF".utf8))
		}
		var documents = PageDocumentsClient.testValue
		documents.pageLayout = { PageLayout() }
		documents.print = { _, _, windowID in printedIn.setValue(windowID) }

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.browserCapture = capture
			$0.pageDocuments = documents
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.printPage(source)))
		await store.finish()

		expectNoDifference(printedIn.value, state.main.id)
	}

	@Test
	internal func focusedDeveloperToolsKeepsItsPanelNumbers() {
		for command in BrowserCommand.selectTab {
			let shortcut = try? #require(command.shortcut)
			#expect(shortcut.map { BrowserCommands.developerToolsKeys.contains($0) } == true)
		}
	}

	@Test
	internal func saveAsReportsAFailedPDFReadInsteadOfOfferingHTML() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.main.viewer.item.navigation = .init(url: URL(string: "https://capturecontext.dev/big.pdf")!)
		let source = try #require(state.captureSource(for: .window(state.main.id)))
		let asked = LockIsolated(0)
		let alerts = LockIsolated(0)
		var engine = BrowserEngineClient(status: { .notIntegrated })
		engine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 1) }
		engine.savePageIsAvailable = { true }
		var capture = BrowserCaptureClient()
		capture.pdfIsAvailable = { true }
		capture.pdfAuthorized = { _, _ in throw PageCaptureFailure.limitExceeded }
		var documents = PageDocumentsClient.testValue
		documents.chooseSaveDestination = { _, _, _ in
			asked.withValue { $0 += 1 }
			return nil
		}
		documents.alert = { _ in alerts.withValue { $0 += 1 } }

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.browserCapture = capture
			$0.pageDocuments = documents
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.savePage(source)))
		await store.finish()

		expectNoDifference(asked.value, 0)
		expectNoDifference(alerts.value, 1)
	}

	@Test
	internal func saveAsOffersHTMLForAPageStillLoading() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.main.viewer.item.navigation = .init(url: URL(string: "https://capturecontext.dev")!, isLoading: true)
		let source = try #require(state.captureSource(for: .window(state.main.id)))
		let offered = LockIsolated<[PageSaveFormat]>([])
		let saved = LockIsolated<[BrowserSavePageFormat]>([])
		var engine = BrowserEngineClient(status: { .notIntegrated })
		engine.snapshot = { _ in .init(navigation: .init(isLoading: true), revision: 1, documentRevision: 1) }
		engine.savePageIsAvailable = { true }
		engine.savePage = { _, _, format in saved.withValue { $0.append(format) } }
		var capture = BrowserCaptureClient()
		capture.pdfIsAvailable = { true }
		capture.pdfAuthorized = { _, _ in throw PageCaptureFailure.unavailable }
		var documents = PageDocumentsClient.testValue
		documents.chooseSaveDestination = { _, formats, _ in
			offered.setValue(formats)
			return (URL(fileURLWithPath: "/tmp/page.mhtml"), .webArchive)
		}

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.browserCapture = capture
			$0.pageDocuments = documents
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.savePage(source)))
		await store.finish()

		expectNoDifference(offered.value, [.complete, .htmlOnly, .webArchive])
		expectNoDifference(saved.value, [.webArchive])
	}

	/// DEV-819: the engine tells a PDF still loading from its MIME type, so only PDF is offered,
	/// and its own bytes are saved once it has loaded.
	@Test
	internal func saveAsOffersOnlyPDFForAPDFStillLoadingAndSavesItsBytes() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.main.viewer.item.navigation = .init(url: URL(string: "https://capturecontext.dev/a.pdf")!, isLoading: true)
		let source = try #require(state.captureSource(for: .window(state.main.id)))
		let loading = LockIsolated(true)
		let offered = LockIsolated<[PageSaveFormat]>([])
		let written = LockIsolated<[Data]>([])
		let reads = LockIsolated(0)
		let alerts = LockIsolated(0)
		var engine = BrowserEngineClient(status: { .notIntegrated })
		engine.snapshot = { _ in .init(navigation: .init(isLoading: loading.value), revision: 1, documentRevision: 1) }
		engine.savePageIsAvailable = { true }
		engine.documentType = { _ in .pdf }
		engine.savePage = { _, _, _ in Issue.record("A PDF never saves as a web page") }
		var capture = BrowserCaptureClient()
		capture.pdfIsAvailable = { true }
		capture.pdfAuthorized = { request, _ in
			let attempt = reads.withValue { $0 += 1; return $0 }

			// The engine can't read a loading page; it finishes loading after the second try.
			guard attempt > 2 else {
				if attempt == 2 { loading.setValue(false) }
				throw PageCaptureFailure.unavailable
			}
			return .init(request: request, documentID: "document", data: Data("%PDF-1.7".utf8))
		}
		var documents = PageDocumentsClient.testValue
		documents.chooseSaveDestination = { _, formats, _ in
			offered.setValue(formats)
			return (URL(fileURLWithPath: "/tmp/a.pdf"), .pdf)
		}
		documents.write = { data, _ in written.withValue { $0.append(data) } }
		documents.alert = { _ in alerts.withValue { $0 += 1 } }

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.browserCapture = capture
			$0.pageDocuments = documents

			// ImmediateClock yields many times per sleep, which a loaded test run starves.
			$0.continuousClock = NoWaitClock()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.savePage(source)))
		await store.finish(timeout: .seconds(60))

		expectNoDifference(offered.value, [.pdf])
		expectNoDifference(written.value, [Data("%PDF-1.7".utf8)])
		expectNoDifference(reads.value, 3)
		expectNoDifference(alerts.value, 0)
	}

	/// DEV-965: the PDF viewer can hand over a loaded PDF's bytes a moment after the load ends;
	/// Save Page As keeps reading for a while rather than failing on the first read after it.
	@Test
	internal func saveAsWaitsForAPDFsBytesAMomentAfterItLoads() async throws {
		// Loading ends at the second read, and the bytes come four reads after that.
		let save = try await Self.saveLoadingPDF(loadingEndsAt: 2, bytesAt: 6)

		expectNoDifference(save.written, [Data("%PDF-1.7".utf8)])
		expectNoDifference(save.alerts, 0)
	}

	/// DEV-965: under load the PDF viewer took longer than 2 seconds to hand over a loaded PDF's
	/// bytes, and Save Page As failed; the wait after the load is 6 seconds on the clock.
	@Test
	internal func saveAsWaitsSeveralSecondsForAPDFsBytesAfterItLoads() async throws {
		// Loading ends at the second read (0.25 s), and the bytes come 5.5 s after that.
		let save = try await Self.saveLoadingPDF(loadingEndsAt: 2, bytesAt: 24)

		expectNoDifference(save.written, [Data("%PDF-1.7".utf8)])
		expectNoDifference(save.alerts, 0)
		expectNoDifference(save.timePassed, .milliseconds(5_750))
	}

	/// DEV-965: Save Page As stops reading a loaded PDF's bytes 6 seconds after the load ends.
	@Test
	internal func saveAsGivesUpOnAPDFsBytesSixSecondsAfterItLoads() async throws {
		let save = try await Self.saveLoadingPDF(loadingEndsAt: 2, bytesAt: nil)

		expectNoDifference(save.written, [])
		expectNoDifference(save.alerts, 1)

		// The load ends at 0.25 s; the last read is 6 s after that.
		expectNoDifference(save.timePassed, .milliseconds(6_250))
		expectNoDifference(save.reads, 26)
		expectNoDifference(save.errors, Self.reported([.unavailable]))
	}

	/// DEV-819, DEV-965: a PDF that never finishes loading fails after 30 seconds on the clock.
	@Test
	internal func saveAsGivesUpOnAPDFThatNeverLoadsAfterThirtySeconds() async throws {
		let save = try await Self.saveLoadingPDF(loadingEndsAt: nil, bytesAt: nil)

		expectNoDifference(save.written, [])
		expectNoDifference(save.alerts, 1)
		expectNoDifference(save.timePassed, .seconds(30))
		expectNoDifference(save.reads, 121)
	}

	/// DEV-819: the wait for a PDF's bytes ends as soon as the tab shows another document.
	@Test
	internal func saveAsStopsWaitingForAPDFWhenTheTabShowsAnotherDocument() async throws {
		let save = try await Self.saveLoadingPDF(loadingEndsAt: 2, bytesAt: nil, newDocumentAt: 4)

		expectNoDifference(save.written, [])
		expectNoDifference(save.alerts, 1)
		expectNoDifference(save.reads, 4)
		expectNoDifference(save.timePassed, .milliseconds(750))
		expectNoDifference(save.errors, Self.reported([.staleDocument]))
	}

	/// DEV-1059: every navigation update, such as the load ending, makes a PDF read that overlaps
	/// it stale, though the tab shows the same document; Save Page As reads it again.
	@Test
	internal func saveAsReadsAPDFAgainAfterAStaleReadOfTheSameDocument() async throws {
		// The load ends during the second read, which the engine reports as stale.
		let save = try await Self.saveLoadingPDF(loadingEndsAt: 2, bytesAt: 2, failures: [2: .staleDocument])

		expectNoDifference(save.written, [Data("%PDF-1.7".utf8)])
		expectNoDifference(save.alerts, 0)
		expectNoDifference(save.reads, 3)
	}

	/// DEV-1059: a PDF read the engine is too busy for is read again.
	@Test
	internal func saveAsReadsAPDFAgainAfterTheEngineIsBusy() async throws {
		let save = try await Self.saveLoadingPDF(loadingEndsAt: 1, bytesAt: 1, failures: [1: .busy])

		expectNoDifference(save.written, [Data("%PDF-1.7".utf8)])
		expectNoDifference(save.alerts, 0)
		expectNoDifference(save.reads, 2)
	}

	/// DEV-1059: a stale read stops the wait when the tab really shows another document.
	@Test
	internal func saveAsStopsWaitingForAPDFAfterAStaleReadOfAnotherDocument() async throws {
		let save = try await Self.saveLoadingPDF(
			loadingEndsAt: 2,
			bytesAt: nil,
			newDocumentAt: 3,
			failures: [3: .staleDocument]
		)

		expectNoDifference(save.written, [])
		expectNoDifference(save.alerts, 1)
		expectNoDifference(save.reads, 3)
		expectNoDifference(save.errors, Self.reported([.staleDocument]))
	}

	/// DEV-1059: a failure that waiting can't mend alerts at once, and a debug build names it.
	@Test
	internal func saveAsReportsAFailedPDFReadItCantRetryAtOnce() async throws {
		let save = try await Self.saveLoadingPDF(loadingEndsAt: 1, bytesAt: 1, failures: [1: .timedOut])

		expectNoDifference(save.written, [])
		expectNoDifference(save.alerts, 1)
		expectNoDifference(save.reads, 1)
		expectNoDifference(save.errors, Self.reported([.timedOut]))
	}

	/// DEV-819: a web page the engine knows isn't a PDF is never probed for PDF bytes.
	@Test
	internal func saveAsTakesAWebPageByItsTypeWithoutReadingPDF() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.main.viewer.item.navigation = .init(url: URL(string: "https://capturecontext.dev")!, isLoading: true)
		let source = try #require(state.captureSource(for: .window(state.main.id)))
		let offered = LockIsolated<[PageSaveFormat]>([])
		var engine = BrowserEngineClient(status: { .notIntegrated })
		engine.snapshot = { _ in .init(navigation: .init(isLoading: true), revision: 1, documentRevision: 1) }
		engine.savePageIsAvailable = { true }
		engine.documentType = { _ in .web }
		engine.savePage = { _, _, _ in }
		var capture = BrowserCaptureClient()
		capture.pdfIsAvailable = { true }
		capture.pdfAuthorized = { _, _ in
			Issue.record("A web page isn't read as PDF")
			throw PageCaptureFailure.unavailable
		}
		var documents = PageDocumentsClient.testValue
		documents.chooseSaveDestination = { _, formats, _ in
			offered.setValue(formats)
			return nil
		}

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.browserCapture = capture
			$0.pageDocuments = documents
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.savePage(source)))
		await store.finish(timeout: .seconds(30))

		expectNoDifference(offered.value, [.complete, .htmlOnly, .webArchive])
	}

	/// DEV-816, DEV-971: a private window's page menu offers Save Page As and Print.
	@Test
	internal func privatePageMenuOffersSaveAsAndPrint() throws {
		let (state, _) = Self.privateWindow(url: "https://capturecontext.dev")
		let commands = state.pageMenuCommands(showing: state.windows[0].viewer.item.tab!.id)
		#expect(commands.contains(.savePageAs))
		#expect(commands.contains(.printPage))
	}

	/// DEV-816, DEV-971: a private page offers every format, PDF included, and saves with Save
	/// Page as an ordinary one does. The panel is told it's private.
	@Test
	internal func privateSaveAsOffersEveryFormatInAPrivatePanel() async throws {
		let (state, source) = Self.privateWindow(url: "https://capturecontext.dev")
		let offered = LockIsolated<[PageSaveFormat]>([])
		let panelIsPrivate = LockIsolated<Bool?>(nil)
		let saved = LockIsolated<[BrowserSavePageFormat]>([])
		var engine = BrowserEngineClient(status: { .notIntegrated })
		engine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 1) }
		engine.savePageIsAvailable = { true }
		engine.documentType = { _ in .web }
		engine.savePage = { _, _, format in saved.withValue { $0.append(format) } }
		var documents = PageDocumentsClient.testValue
		documents.chooseSaveDestination = { _, formats, isPrivate in
			offered.setValue(formats)
			panelIsPrivate.setValue(isPrivate)
			return (URL(fileURLWithPath: "/tmp/page.html"), .complete)
		}

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.pageDocuments = documents
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.savePage(source)))
		await store.finish()

		expectNoDifference(offered.value, [.complete, .htmlOnly, .webArchive, .pdf])
		expectNoDifference(panelIsPrivate.value, true)
		expectNoDifference(saved.value, [.complete])
	}

	/// DEV-816: an ordinary page's panel isn't private, so it remembers its folder as before.
	@Test
	internal func ordinarySaveAsPanelIsNotPrivate() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.main.viewer.item.navigation = .init(url: URL(string: "https://capturecontext.dev")!)
		let source = try #require(state.captureSource(for: .window(state.main.id)))
		#expect(!state.isPrivate(source))
		let panelIsPrivate = LockIsolated<Bool?>(nil)
		var engine = BrowserEngineClient(status: { .notIntegrated })
		engine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 1) }
		engine.savePageIsAvailable = { true }
		engine.documentType = { _ in .web }
		var documents = PageDocumentsClient.testValue
		documents.chooseSaveDestination = { _, _, isPrivate in
			panelIsPrivate.setValue(isPrivate)
			return nil
		}

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.pageDocuments = documents
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.savePage(source)))
		await store.finish()

		expectNoDifference(panelIsPrivate.value, false)
	}

	/// DEV-971: a PDF document in a private window saves its own bytes, read for the app's
	/// own Save Page As, which may read a private page.
	@Test
	internal func privateSaveAsSavesAPDFDocumentsOwnBytes() async throws {
		let (state, source) = Self.privateWindow(url: "https://capturecontext.dev/a.pdf")
		let requests = LockIsolated<[PagePDFRequest]>([])
		let written = LockIsolated<[Data]>([])
		var engine = BrowserEngineClient(status: { .notIntegrated })
		engine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 1) }
		engine.savePageIsAvailable = { true }
		engine.documentType = { _ in .pdf }
		engine.savePage = { _, _, _ in Issue.record("A PDF never saves as a web page") }
		var capture = BrowserCaptureClient()
		capture.pdfIsAvailable = { true }
		capture.pdfAuthorized = { request, _ in
			requests.withValue { $0.append(request) }
			return .init(request: request, documentID: "document", data: Data("%PDF".utf8))
		}
		var documents = PageDocumentsClient.testValue
		documents.chooseSaveDestination = { _, formats, _ in
			expectNoDifference(formats, [.pdf])
			return (URL(fileURLWithPath: "/tmp/a.pdf"), .pdf)
		}
		documents.write = { data, _ in written.withValue { $0.append(data) } }

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.browserCapture = capture
			$0.pageDocuments = documents
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.savePage(source)))
		await store.finish()

		#expect(requests.value.allSatisfy { $0.kind == .source && $0.allowsPrivate })
		#expect(!requests.value.isEmpty)
		expectNoDifference(written.value, [Data("%PDF".utf8)])
	}

	/// DEV-971: Print reads a private page as PDF for the print panel, which the app's own
	/// requests may do.
	@Test
	internal func privatePrintReadsThePageForThePrintPanel() async throws {
		let (state, source) = Self.privateWindow(url: "https://capturecontext.dev")
		let requests = LockIsolated<[PagePDFRequest]>([])
		let printed = LockIsolated<[Data]>([])
		var engine = BrowserEngineClient(status: { .notIntegrated })
		engine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 1) }
		var capture = BrowserCaptureClient()
		capture.pdfIsAvailable = { true }
		capture.pdfAuthorized = { request, _ in
			requests.withValue { $0.append(request) }
			return .init(request: request, documentID: "document", data: Data("%PDF".utf8))
		}
		var documents = PageDocumentsClient.testValue
		documents.pageLayout = { PageLayout() }
		documents.print = { data, _, _ in printed.withValue { $0.append(data) } }

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.browserCapture = capture
			$0.pageDocuments = documents
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.printPage(source)))
		await store.finish()

		#expect(!requests.value.isEmpty && requests.value.allSatisfy(\.allowsPrivate))
		expectNoDifference(printed.value, [Data("%PDF".utf8)])
	}

	/// A private window, besides the main one, showing `url` in its first tab.
	private static func privateWindow(url: String) -> (AppFeature.State, CaptureSource) {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		var window = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: true,
			id: UUID(816)
		)
		window.viewer.item.tab = organization.tabs[0]
		window.viewer.item.navigation = .init(url: URL(string: url)!)
		state.windows.append(window)
		let source = state.captureSource(for: .window(window.id))!
		#expect(state.isPrivate(source))
		return (state, source)
	}

	/// The errors a debug build hands to `PageDocumentsClient.failed`; a release build has none.
	private static func reported(_ errors: [PageCaptureFailure]) -> [PageCaptureFailure] {
		#if DEBUG
		errors
		#else
		[]
		#endif
	}

	/// What a Save Page As of a loading PDF did, on a clock that doesn't wait.
	private struct LoadingPDFSave {
		var written: [Data]
		var alerts: Int
		var reads: Int
		var timePassed: Duration

		/// The errors behind the alerts, as a debug build reports them; none in a release build.
		var errors: [PageCaptureFailure]
	}

	/// Saves a PDF that is loading as Save Page As starts, reading its bytes every 250 ms of
	/// `NoWaitClock` time. The read numbered `loadingEndsAt` ends the load, `bytesAt` is the first
	/// read that gets the bytes, and from the read numbered `newDocumentAt` on the tab shows
	/// another document. A read numbered in `failures` throws its failure instead.
	private static func saveLoadingPDF(
		loadingEndsAt: Int?,
		bytesAt: Int?,
		newDocumentAt: Int? = nil,
		failures: [Int: PageCaptureFailure] = [:]
	) async throws -> LoadingPDFSave {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.main.viewer.item.navigation = .init(url: URL(string: "https://capturecontext.dev/a.pdf")!, isLoading: true)
		let source = try #require(state.captureSource(for: .window(state.main.id)))
		let loading = LockIsolated(true)
		let document = LockIsolated<UInt64>(1)
		let written = LockIsolated<[Data]>([])
		let reads = LockIsolated(0)
		let alerts = LockIsolated(0)
		let errors = LockIsolated<[PageCaptureFailure]>([])
		let clock = NoWaitClock()
		var engine = BrowserEngineClient(status: { .notIntegrated })
		engine.snapshot = { _ in
			.init(navigation: .init(isLoading: loading.value), revision: 1, documentRevision: document.value)
		}
		engine.savePageIsAvailable = { true }
		engine.documentType = { _ in .pdf }
		engine.savePage = { _, _, _ in Issue.record("A PDF never saves as a web page") }
		var capture = BrowserCaptureClient()
		capture.pdfIsAvailable = { true }
		capture.pdfAuthorized = { request, _ in
			let attempt = reads.withValue { $0 += 1; return $0 }
			if attempt == loadingEndsAt { loading.setValue(false) }
			if attempt == newDocumentAt { document.setValue(2) }
			if let failure = failures[attempt] { throw failure }
			guard let bytesAt, attempt >= bytesAt
			else { throw PageCaptureFailure.unavailable }

			return .init(request: request, documentID: "document", data: Data("%PDF-1.7".utf8))
		}
		var documents = PageDocumentsClient.testValue
		documents.chooseSaveDestination = { _, _, _ in (URL(fileURLWithPath: "/tmp/a.pdf"), .pdf) }
		documents.write = { data, _ in written.withValue { $0.append(data) } }
		documents.alert = { _ in alerts.withValue { $0 += 1 } }
		#if DEBUG
		documents.failed = { error in
			errors.withValue { $0.append(error as? PageCaptureFailure ?? .encodingFailed) }
		}
		#endif

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.browserCapture = capture
			$0.pageDocuments = documents
			$0.continuousClock = clock
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.savePage(source)))
		await store.finish(timeout: .seconds(60))

		return .init(
			written: written.value,
			alerts: alerts.value,
			reads: reads.value,
			timePassed: clock.timePassed,
			errors: errors.value
		)
	}
}
