import AppKit
import AppUI
import BrowserAutomationClient
import BrowserCaptureClient
import BrowserCore
import BrowserEngineClient
import BrowserMediaClient
import BrowserPageInspectionClient
import BrowserPagePreviewClient
import BrowserPageWaitClient
import BrowserDownloadsClient
import BrowserSiteIconClient
import BrowserSurfaceClient
import BrowserHistoryClient
import HistoryDatabase
import PageTextIndexClient
import BrowserWorkspaceClient
import CoreServices.AE
import ChromiumBrowserEngine
import ChromiumEngine
import DownloadsFeature
import FairPlayBridge
import MainFeature
import MigrationAssistant
import MigrationAssistantFeature
import OnboardingFeature
import OSLog
import SettingsFeature
import SwiftUI
import TaskManagerFeature
import WebKitBrowserEngine
import WorkspaceSync
import _ComposableArchitecture

extension BrowserWindow {
	// MARK: - Packaged runtime validation

	/// A fast local navigation can finish before SwiftUI attaches and sizes the native view.
	internal func checkSmokeReadiness(remaining: Int) {
		let navigation = store.main.viewer.item.navigation
		let hasLoadedFixture = navigation.title == environment["ARX_ENGINE_SMOKE_TITLE"]
		&& !navigation.isLoading
		&& navigation.errorCode == nil

		if let id = store.main.viewer.item.tab?.id, hasLoadedFixture, engine.isAttached(id) {
			do {
				if try advanceSmokeLifecycle() {
					finishSmokeValidation()
					return
				}
			} catch {
				reportSmokeFailure("Window reopening failed: \(error)")
				return
			}
		}

		guard remaining > 0 else {
			reportSmokeFailure("The expected loaded page was not attached: \(navigation)")
			return
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
			self?.checkSmokeReadiness(remaining: remaining - 1)
		}
	}

	#if DEBUG
	/// DEV-892: one launch of the pause, relaunch and resume smoke.
	internal func startDownloadResumeSmoke(_ phase: String) {
		Task { @MainActor [self] in
			do {
				guard let rawURL = environment["ARX_ENGINE_URL"], let baseURL = URL(string: rawURL)
				else { throw DownloadResumeSmoke.Failure("missing fixture URL") }

				try await DownloadResumeSmoke.run(
					phase: phase,
					engine: engine.client,
					downloads: downloads,
					organization: store.workspace,
					baseURL: baseURL,
					environment: environment
				)
			} catch {
				failed = true
				FileHandle.standardError.write(Data("Arx download resume smoke failed: \(error.localizedDescription)\n".utf8))
			}

			// Arx's quit never shows Chromium's "Wait for download" alert (DEV-966). An engine built
			// without that overlay still would, so the smoke answers any modal alert rather than
			// hang, and prints a marker the smoke script fails on (DEV-965). The alert would run
			// modally inside this main-actor job, so a main-actor task couldn't reach it; a run loop
			// timer in the common modes fires inside the modal loop.
			if phase == "pause" {
				let started = Date()
				let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
					let isDone: Bool = MainActor.assumeIsolated {
						guard NSApp.modalWindow != nil else { return Date().timeIntervalSince(started) > 10 }

						FileHandle.standardError.write(Data("ARX_DOWNLOAD_RESUME_QUIT_ALERT exit\n".utf8))
						NSApp.stopModal(withCode: .alertSecondButtonReturn)
						return true
					}
					if isDone { timer.invalidate() }
				}
				RunLoop.main.add(timer, forMode: .common)
			}
			runtime.requestQuit()
		}
	}

	internal func startSiteIconRestartSmoke() {
		Task { @MainActor [self] in
			do {
				guard
					environment["ARX_SITE_ICONS_RESTART"] == "1",
					let root = environment["ARX_SITE_ICONS_SMOKE_ROOT"],
					let rawURL = environment["ARX_ENGINE_URL"],
					let baseURL = URL(string: rawURL)
				else { throw SiteIconSmoke.Failure.invalidFixture }

				try await SiteIconRestartSmoke.run(
					client: siteIcons,
					organization: store.workspace,
					root: URL(filePath: root),
					profileDirectory: profileDirectory,
					baseURL: baseURL,
					iconOrigin: try SiteIconSmoke.IconOrigin(environment: environment),
					prepareProfile: { [engine] in try await engine.client.prepareProfile($0) }
				)
			} catch {
				failed = true

				// The error says which step failed (DEV-965).
				FileHandle.standardError.write(Data("Arx site icon restart smoke failed: \(error)\n".utf8))
			}
			runtime.requestQuit()
		}
	}
	#endif

	private func finishSmokeValidation() {
		Task { @MainActor [weak self] in
			guard let self else { return }

			smokeStage = "validateProfileIsolation"
			do {
				try await validateProfileIsolation()
				smokeStage = "validateHistoryNavigation"
				try await validateHistoryNavigation()
				smokeStage = "validateSplitPresentation"
				try await validateSplitPresentation()
				smokeStage = "validatePageDropSplit"
				try await validatePageDropSplit()
				#if DEBUG
				smokeStage = "PageDropTargetsSmoke"
				try await PageDropTargetsSmoke.run(store: store, window: window)
				#endif
				smokeStage = "validateTabTearOff"
				try await validateTabTearOff()
				smokeStage = "validatePeekPresentation"
				try await validatePeekPresentation()
				smokeStage = "validateMenuShortcuts"
				try await validateMenuShortcuts()
				smokeStage = "validateAuxiliaryWindows"
				try await validateAuxiliaryWindows()
				smokeStage = "validateRendererRecovery"
				try await validateRendererRecovery()
				smokeStage = "validateCapture"
				try await validateCapture()
				#if DEBUG
				guard
					let raw = environment["ARX_ENGINE_URL"],
					let baseURL = URL(string: raw)
				else { throw BrowserLaunchError.invalidWorkspace }

				smokeStage = "RoutingProfilePickerSmoke"
				try await RoutingProfilePickerSmoke.run(
					store: store,
					baseURL: baseURL,
					mainWindow: window,
					panel: { [weak self] in self?.profilePicker?.panel },
					render: { [weak self] in self?.render() }
				)
				smokeStage = "ProfileHistorySmoke"
				try await ProfileHistorySmoke.run(store: store, engine: engine, baseURL: baseURL)
				smokeStage = "TabMoveSmoke"
				try await TabMoveSmoke.run(store: store, engine: engine)
				smokeStage = "SharedFavoriteSmoke"
				try await SharedFavoriteSmoke.run(store: store, engine: engine)
				smokeStage = "IndependentWindowSmoke"
				try await IndependentWindowSmoke.run(store: store, engine: engine, baseURL: baseURL)
				guard let fixtureRoot = environment["ARX_MCP_SMOKE_ROOT"]
				else { throw BrowserLaunchError.invalidWorkspace }

				let fixtureDirectory = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
				smokeStage = "ArchiveSmoke"
				try await ArchiveSmoke.run(
					engine: engine.client,
					baseURL: baseURL,
					profileDirectory: profileDirectory,
					fixtureRoot: fixtureDirectory
				)
				smokeStage = "BangSearchSmoke"
				try await BangSearchSmoke.run(
					store: store,
					engine: engine,
					baseURL: baseURL,
					profileDirectory: profileDirectory,
					fixtureRoot: fixtureDirectory
				)
				smokeStage = "AutomationSmoke"
				try await AutomationSmoke.run(
					store: store,
					engine: engine,
					baseURL: baseURL,
					profileDirectory: profileDirectory,
					fixtureRoot: fixtureDirectory
				)
				guard let profileID = store.workspace.profiles.first?.id
				else { throw BrowserLaunchError.invalidWorkspace }
				smokeStage = "SiteIconSmoke"
				try await SiteIconSmoke.run(
					engine: engine,
					runtime: runtime,
					client: siteIcons,
					organization: store.workspace,
					baseURL: baseURL,
					profileDirectory: profileDirectory,
					environment: environment
				)
				smokeStage = "HoverPreviewSmoke"
				try await HoverPreviewSmoke.run(store: store, clients: previewClients, baseURL: baseURL)
				smokeStage = "MediaSmoke"
				try await MediaSmoke.run(
					engine: engine,
					runtime: runtime,
					profileID: profileID,
					baseURL: baseURL,
					profileDirectory: profileDirectory,
					environment: environment
				)

				// DEV-991: page full screen in the app's own window, its sidebar and its media.
				smokeStage = "PageFullScreenSmoke.browserWindow"
				guard let window else { throw BrowserLaunchError.invalidWorkspace }

				try await PageFullScreenSmoke.runInBrowserWindow(
					store: store,
					engine: engine,
					window: window,
					baseURL: baseURL
				)

				// DEV-877, overnight only: protected media offers WebKit, and the page moves.
				if environment["ARX_WEBKIT_FALLBACK_SMOKE"] == "1" {
					smokeStage = "WebKitFallbackSmoke"
					try await WebKitFallbackSmoke.run(
						store: store,
						engine: pageRouter.client,
						pageEngines: pageRouter.pageEngines,
						window: window,
						baseURL: baseURL
					)
				}

				// DEV-1203, overnight only: Arx's own back and forward swipe on a WebKit page.
				if environment["ARX_WEBKIT_SWIPE_SMOKE"] == "1" {
					smokeStage = "WebKitSwipeSmoke"
					try await WebKitSwipeSmoke.run(
						store: store,
						engine: pageRouter.client,
						pageEngines: pageRouter.pageEngines,
						pages: pageRouter.pages,
						window: window,
						baseURL: baseURL
					)
				}
				#endif
				smokeStage = "validateDownloads"
				try await validateDownloads()
				#if DEBUG
				// DEV-996: Translation Available, translating and Show Original, in an ordinary
				// window and a private one, with the feature flag on by default (DEV-1143).
				smokeStage = "TranslationSmoke"
				try await TranslationSmoke.run(store: store, engine: pageRouter.client, baseURL: baseURL)

				// DEV-987: a local file opened with Arx goes to a new Little Arx, never a Chromium
				// window. Last, so the Little Arx it opens and closes can't touch a later stage.
				smokeStage = "LocalFileSmoke"
				try await LocalFileSmoke.run(
					store: store,
					littleWindow: { [weak self] id in self?.littleWindows[id] }
				)
				#endif
			} catch {
				reportSmokeFailure("Auxiliary runtime validation failed at \(smokeStage): \(error)")
				return
			}

			print("ARX_APP_SMOKE_SUCCESS")
			fflush(stdout)
			store.send(.ui(.quit))
		}
	}

	private func reportSmokeFailure(_ message: String) {
		failed = true
		FileHandle.standardError.write(Data("Arx smoke failed: \(message)\n".utf8))
		store.send(.ui(.quit))
	}

	/// Send real reopen Apple events through AppKit, including the formerly crashing route.
	private func advanceSmokeLifecycle() throws -> Bool {
		switch smokePhase {
		case 0:
			smokeWindow = window
			smokePhase = 1
			try sendSmokeReopen()

		case 1 where reopenCount == 1:
			guard window === smokeWindow else { throw BrowserLaunchError.unexpectedReopenWindow }
			window?.miniaturize(nil)
			smokePhase = 2
			try sendSmokeReopen()

		case 2 where reopenCount == 2 && window?.isMiniaturized == false:
			guard window === smokeWindow else { throw BrowserLaunchError.unexpectedReopenWindow }
			window?.performClose(nil)
			guard
				window == nil,
				!store.windowIsOpen
			else { throw BrowserLaunchError.unexpectedReopenWindow }
			smokePhase = 3
			try sendSmokeReopen()

		case 3 where reopenCount == 3:
			guard window != nil, window !== smokeWindow, store.windowIsOpen else {
				throw BrowserLaunchError.unexpectedReopenWindow
			}
			smokePhase = 4
			store.send(.ui(.newWindow))
			render()

		case 4:
			guard
				let additional = additionalWindows.values.first,
				additional !== window,
				additionalWindows.count == 1,
				!store.shouldQuit
			else { throw BrowserLaunchError.unexpectedReopenWindow }
			additional.performClose(nil)
			guard
				additionalWindows.isEmpty,
				store.windows.isEmpty,
				window != nil
			else { throw BrowserLaunchError.unexpectedReopenWindow }
			print("ARX_APP_REOPEN_SMOKE_SUCCESS")
			return true

		default: break
		}
		return false
	}

	// MARK: - Runtime validation steps

	private func validateDownloads() async throws {
		#if DEBUG
		guard let raw = environment["ARX_ENGINE_URL"], let base = URL(string: raw)
		else { throw BrowserLaunchError.invalidWorkspace }

		try await DownloadSmoke.run(
			engine: engine.client,
			downloads: downloads,
			organization: store.workspace,
			baseURL: base,
			metadataFile: downloadsFile,
			environment: environment
		)
		#endif
	}

	private func validateCapture() async throws {
		#if DEBUG
		guard
			let raw = environment["ARX_ENGINE_URL"],
			let base = URL(string: raw),
			let profileID = store.workspace.profiles.first?.id
		else { throw BrowserLaunchError.invalidWorkspace }

		try await CaptureSmoke.run(
			engine: engine,
			profileID: profileID,
			baseURL: base,
			environment: environment
		)
		#endif
	}

	private func validateProfileIsolation() async throws {
		let workProfile = UUID()
		let personalProfile = UUID()
		let workPage = try await runtime.makePage(profile: workProfile)
		let personalPage = try await runtime.makePage(profile: personalProfile)
		let secondWorkPage = try await runtime.makePage(profile: workProfile)
		defer {
			workPage.close()
			personalPage.close()
			secondWorkPage.close()
		}

		try await visitIdentityPage(
			workPage,
			setting: "work",
			expecting: "work|work",
			phase: "ordinary-work-write"
		)
		try await visitIdentityPage(
			personalPage,
			setting: "",
			expecting: "empty|empty",
			phase: "ordinary-personal-empty"
		)
		try await visitIdentityPage(
			personalPage,
			setting: "personal",
			expecting: "personal|personal",
			phase: "ordinary-personal-write"
		)
		try await visitIdentityPage(
			secondWorkPage,
			setting: "",
			expecting: "work|work",
			phase: "ordinary-work-shared"
		)

		guard await runtime.permitsClosing(secondWorkPage)
		else { throw BrowserLaunchError.profileIsolationFailed("ordinary-work-close-denied") }
		guard personalPage.navigation.history.count >= 2
		else { throw BrowserLaunchError.profileIsolationFailed("ordinary-personal-history-missing") }

		let privateProfile = UUID()
		try runtime.preparePrivateProfile(privateProfile)
		let privatePage = try await runtime.makePage(profile: privateProfile)
		try await visitIdentityPage(
			privatePage,
			setting: "",
			expecting: "empty|empty",
			phase: "private-empty"
		)
		try await visitIdentityPage(
			privatePage,
			setting: "private",
			expecting: "private|private",
			phase: "private-write"
		)
		privatePage.close()
		runtime.releasePrivateProfile(privateProfile)

		// Reusing the identity must still produce a fresh off-the-record context.
		try runtime.preparePrivateProfile(privateProfile)
		let freshPrivatePage = try await runtime.makePage(profile: privateProfile)
		try await visitIdentityPage(
			freshPrivatePage,
			setting: "",
			expecting: "empty|empty",
			phase: "private-recreated-empty"
		)
		freshPrivatePage.close()
		runtime.releasePrivateProfile(privateProfile)
		try await visitIdentityPage(
			secondWorkPage,
			setting: "",
			expecting: "work|work",
			phase: "ordinary-after-private-recreate"
		)

		guard let raw = environment["ARX_ENGINE_URL"], let base = URL(string: raw)
		else { throw BrowserLaunchError.invalidWorkspace }
		try workPage.navigate(to: base.deletingLastPathComponent().appendingPathComponent("cache.html"))
		try await waitForSmokeTitle("Cache 1", in: workPage)
		try workPage.clearCacheAndReload()
		try await waitForSmokeTitle("Cache 2", in: workPage)
		try await visitIdentityPage(
			workPage,
			setting: "",
			expecting: "work|work",
			phase: "ordinary-after-cache-clear"
		)
		print("ARX_CACHE_RELOAD_SMOKE_SUCCESS")
		print("ARX_PRIVATE_PROFILE_SMOKE_SUCCESS")
		print("ARX_PROFILE_ISOLATION_SMOKE_SUCCESS")
	}

	private func validateHistoryNavigation() async throws {
		guard
			let raw = environment["ARX_ENGINE_URL"],
			let base = URL(string: raw),
			let profileID = store.main.sidebar.organization.profiles.first?.id
		else { throw BrowserLaunchError.invalidWorkspace }

		let client = engine.client
		let first = base.appending(queryItems: [.init(name: "history", value: "first")])
		let second = base.appending(queryItems: [.init(name: "history", value: "second")])
		let third = base.appending(queryItems: [.init(name: "history", value: "third")])
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			restoration: .init(title: "History smoke", url: first)
		)
		defer { client.close(tab.id) }
		try await client.open(tab)
		_ = try await waitForHistoryURL(first, tabID: tab.id)
		try await client.command(tab.id, .navigate(second))
		_ = try await waitForHistoryURL(second, tabID: tab.id)
		try await client.command(tab.id, .navigate(third))
		let snapshot = try await waitForHistoryURL(third, tabID: tab.id)
		guard let entry = snapshot.navigation.entries(in: .back).first(where: { $0.url == first })
		else { throw BrowserLaunchError.historyValidationFailed("Earlier entry is missing") }
		try await client.commandAuthorized(tab.id, snapshot.revision, .historyEntry(entry.id)) { true }
		let restored = try await waitForHistoryURL(first, tabID: tab.id)
		guard restored.navigation.entries(in: .forward).map(\.url) == [second, third] else {
			throw BrowserLaunchError.historyValidationFailed("Direct entry navigation did not preserve forward history")
		}
		do {
			try await client.commandAuthorized(tab.id, snapshot.revision, .forward) { true }
			throw BrowserLaunchError.historyValidationFailed("A stale native revision was accepted")
		} catch AutomationFailure.staleTarget {}
		guard client.snapshot(tab.id)?.navigation.url == first
		else { throw BrowserLaunchError.historyValidationFailed("Stale selection changed the current page") }
		print("ARX_HISTORY_SMOKE_SUCCESS")
	}

	private func validateSplitPresentation() async throws {
		guard
			let window,
			let original = store.main.viewer.item.tab,
			let originalURL = store.main.viewer.item.navigation.url
		else { throw BrowserLaunchError.invalidWorkspace }

		let firstPaneID = store.main.viewer.activePaneID
		let secondURL = originalURL.appending(queryItems: [.init(name: "split", value: "second")])
		store.send(.main(.ui(.splitURL(secondURL))))
		try await waitForSplitPresentation("Both Chromium panes must mount") {
			store.main.viewer.panes.count == 2
			&& store.main.viewer.panes.allSatisfy { pane in
				pane.item.tab.map { engine.isAttached($0.id) } == true
			}
		}
		guard
			let second = store.main.viewer.panes.first(where: { $0.id != firstPaneID }),
			let secondTab = second.item.tab
		else { throw BrowserLaunchError.splitValidationFailed("The second pane is missing") }

		_ = try await waitForHistoryURL(secondURL, tabID: secondTab.id)

		// Capture each actual Chromium responder, then verify the pane action restores it.
		engine.surface.focus(original.id)
		guard let firstResponder = window.firstResponder as? NSView
		else { throw BrowserLaunchError.splitValidationFailed("The first native responder is missing") }
		engine.surface.focus(secondTab.id)
		guard
			let secondResponder = window.firstResponder as? NSView,
			secondResponder !== firstResponder
		else { throw BrowserLaunchError.splitValidationFailed("Panes share a native responder") }

		// A navigation may replace a page's render view; its contents view stays.
		guard
			let firstContents = firstResponder.superview,
			let secondContents = secondResponder.superview
		else { throw BrowserLaunchError.splitValidationFailed("A native responder has no contents view") }

		store.send(.main(.viewer(.ui(.focus(firstPaneID)))))
		try await waitForSplitPresentation("Pane focus must reach the first Chromium view") {
			window.firstResponder === firstResponder
		}
		store.send(.main(.viewer(.ui(.focus(second.id)))))
		try await waitForSplitPresentation("Pane focus must reach the second Chromium view") {
			window.firstResponder === secondResponder
		}

		// DEV-993: a click in the first pane's page, while the second is selected, selects the first.
		let center = firstContents.convert(
			NSPoint(x: firstContents.bounds.midX, y: firstContents.bounds.midY),
			to: nil
		)
		for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
			guard
				let event = NSEvent.mouseEvent(
					with: type,
					location: center,
					modifierFlags: [],
					timestamp: ProcessInfo.processInfo.systemUptime,
					windowNumber: window.windowNumber,
					context: nil,
					eventNumber: 0,
					clickCount: 1,
					pressure: type == .leftMouseDown ? 1 : 0
				)
			else { throw BrowserLaunchError.splitValidationFailed("A click event couldn't be made") }

			NSApp.postEvent(event, atStart: false)
		}
		try await waitForSplitPresentation("A click in the first pane's page must select that pane") {
			store.main.viewer.activePaneID == firstPaneID
		}

		let navigatedURL = originalURL.appending(queryItems: [.init(name: "split", value: "navigated")])
		store.send(.main(.viewer(.command(.navigate(navigatedURL), in: second.id, tabID: secondTab.id))))
		store.send(.main(.viewer(.ui(.focus(firstPaneID)))))
		_ = try await waitForHistoryURL(navigatedURL, tabID: secondTab.id)
		try await waitForSplitPresentation("Background navigation must retain its pane and leave focus alone") {
			store.main.viewer.panes[id: second.id]?.item.navigation.url == navigatedURL
			&& store.main.viewer.panes[id: firstPaneID]?.item.navigation.url == originalURL
			&& window.firstResponder === firstResponder
		}

		store.send(.main(.viewer(.ui(.toggleOrientation))))
		store.send(.main(.viewer(.ui(.resize([0.65, 0.35])))))
		store.send(.main(.viewer(.ui(.resizeEnded))))
		try await waitForSplitPresentation("Vertical resizing must keep both native views attached") {
			window.contentView?.layoutSubtreeIfNeeded()
			return engine.isAttached(original.id)
			&& engine.isAttached(secondTab.id)
			&& firstContents.bounds.height > secondContents.bounds.height
		}
		store.send(.main(.viewer(.ui(.closePane(second.id)))))
		try await waitForSplitPresentation("Closing a pane must retain its tab and session") {
			store.main.viewer.panes.count == 1
			&& store.main.viewer.item.tab?.id == original.id
			&& engine.isAttached(original.id)
			&& !engine.isAttached(secondTab.id)
			&& engine.client.snapshot(secondTab.id)?.navigation.url == navigatedURL
			&& store.workspace.tabs.ids.contains(secondTab.id)
		}
		print("ARX_SPLIT_SMOKE_SUCCESS")
	}

	/// DEV-793: the page's drop zones, and the drops they send, for an ordinary tab and a chat tab.
	private func validatePageDropSplit() async throws {
		guard
			let window,
			let original = store.main.viewer.item.tab,
			store.main.viewer.panes.count == 1
		else { throw BrowserLaunchError.invalidWorkspace }

		// The page's diagonals cut it into a triangle per edge: wherever the pointer is, it picks
		// one, and a point near a top corner a quarter across still joins at the top.
		let size = window.contentView?.bounds.size ?? .zero
		guard
			size.width > 0,
			SplitDropEdge(point: .init(x: size.width * 0.25, y: size.height * 0.05), size: size) == .top,
			SplitDropEdge(point: .init(x: size.width * 0.05, y: size.height * 0.25), size: size) == .leading,
			SplitDropEdge(point: .init(x: size.width * 0.95, y: size.height * 0.75), size: size) == .trailing,
			SplitDropEdge(point: .init(x: size.width * 0.5, y: size.height * 0.9), size: size) == .bottom
		else { throw BrowserLaunchError.splitValidationFailed("The page's drop triangles don't pick their edges") }

		// An ordinary tab dropped on the leading edge: the earlier split phase left its second
		// tab open and unshown.
		guard let other = store.main.sidebar.space.unpinnedTabs.first(where: { id in
			id != original.id && store.main.sidebar.organization.tabs[id: id]?.isChat == false
		}) else { throw BrowserLaunchError.splitValidationFailed("No second tab to drop on the page") }
		guard store.main.viewerDropRefusal(other, edge: .leading) == nil
		else { throw BrowserLaunchError.splitValidationFailed("The page refuses an ordinary tab") }

		store.send(.main(.ui(.dropTabInViewer(other, .leading))))
		try await waitForSplitPresentation("A tab dropped on the leading edge must become the first pane") {
			store.main.viewer.panes.map { $0.item.tab?.id } == [other, original.id]
			&& store.main.sidebar.organization.split(containing: other)?.tabIDs == [other, original.id]
			&& engine.isAttached(other)
			&& engine.isAttached(original.id)
		}
		guard let otherPane = store.main.viewer.panes.first(where: { $0.item.tab?.id == other })
		else { throw BrowserLaunchError.splitValidationFailed("The dropped pane is missing") }
		store.send(.main(.viewer(.ui(.closePane(otherPane.id)))))
		try await waitForSplitPresentation("Closing the dropped pane must leave the original") {
			store.main.viewer.panes.count == 1 && store.main.viewer.item.tab?.id == original.id
		}

		// Open in Tab puts a chat where the page was; dropping the chat on that page's trailing
		// edge splits it with the page it opened over.
		store.send(.main(.ui(.openChatTab(.init(conversationID: nil), title: "Page Drop Chat"))))
		try await waitForSplitPresentation("Open in Tab must show a chat tab") {
			store.main.viewer.item.tab?.isChat == true
		}
		guard let chat = store.main.viewer.item.tab?.id
		else { throw BrowserLaunchError.splitValidationFailed("The chat tab is missing") }
		guard store.main.viewerDropRefusal(chat, edge: .trailing) == nil
		else { throw BrowserLaunchError.splitValidationFailed("The chat's own page refuses it") }

		store.send(.main(.ui(.dropTabInViewer(chat, .trailing))))
		try await waitForSplitPresentation("A chat dropped on its page's trailing edge must split with that page") {
			store.main.viewer.panes.map { $0.item.tab?.id } == [original.id, chat]
			&& store.main.sidebar.organization.split(containing: chat)?.tabIDs == [original.id, chat]
			&& engine.isAttached(original.id)
			&& !engine.isAttached(chat)
		}
		guard let chatPane = store.main.viewer.panes.first(where: { $0.item.tab?.id == chat })
		else { throw BrowserLaunchError.splitValidationFailed("The chat pane is missing") }
		store.send(.main(.viewer(.ui(.closePane(chatPane.id)))))
		try await waitForSplitPresentation("Closing the chat pane must leave the original") {
			store.main.viewer.panes.count == 1 && store.main.viewer.item.tab?.id == original.id
		}

		// The same chat tab, dropped from the sidebar on another tab's leading edge.
		guard store.main.viewerDropRefusal(chat, edge: .leading) == nil
		else { throw BrowserLaunchError.splitValidationFailed("Another tab's page refuses a chat tab") }
		store.send(.main(.ui(.dropTabInViewer(chat, .leading))))
		try await waitForSplitPresentation("A chat tab dropped on the leading edge must become the first pane") {
			store.main.viewer.panes.map { $0.item.tab?.id } == [chat, original.id]
			&& store.main.sidebar.organization.split(containing: chat)?.tabIDs == [chat, original.id]
			&& engine.isAttached(original.id)
		}

		store.send(.main(.sidebar(.ui(.sidebar(.close(.tab(chat.rawValue)))))))
		try await waitForSplitPresentation("Closing the chat tab must leave one pane") {
			store.main.viewer.panes.count == 1 && store.main.sidebar.organization.tabs[id: chat] == nil
		}

		// Closing the chat may select a neighbor; the phases after this one start on the original.
		store.send(.main(.sidebar(.ui(.sidebar(.select(.tab(original.id.rawValue)))))))
		try await waitForSplitPresentation("The original tab must show alone again") {
			store.main.viewer.panes.map { $0.item.tab?.id } == [original.id] && engine.isAttached(original.id)
		}
		print("ARX_PAGE_DROP_SPLIT_SMOKE_SUCCESS")
	}

	/// DEV-793: a sidebar tab and a chat tab dropped outside every window move into Little Arx at
	/// the drop point, with the page still open. Drives the drop action through the store; the
	/// view sends it only when the drag ends outside every Arx window.
	private func validateTabTearOff() async throws {
		guard
			let original = store.main.viewer.item.tab,
			let originalURL = store.main.viewer.item.navigation.url,
			let visible = (window?.screen ?? NSScreen.main)?.visibleFrame
		else { throw BrowserLaunchError.invalidWorkspace }

		let point = CGPoint(x: visible.midX, y: visible.midY)
		let pageURL = originalURL.appending(queryItems: [.init(name: "tear-off", value: "page")])
		store.send(.main(.ui(.openInNewTab(pageURL))))
		try await waitForSplitPresentation("A new tab must open for the tear-off") {
			store.main.sidebar.organization.tabs.contains { $0.restoration.url == pageURL }
		}
		guard let page = store.main.sidebar.organization.tabs.first(where: { $0.restoration.url == pageURL })
		else { throw BrowserLaunchError.splitValidationFailed("The tear-off tab is missing") }

		try await tearOff(page.id, at: point, expectsPage: true)
		store.send(.main(.sidebar(.ui(.sidebar(.select(.tab(original.id.rawValue)))))))

		// A chat tab moves the same way, and Little Arx shows its chat.
		store.send(.main(.ui(.openChatTab(.init(conversationID: nil), title: "Tear Off Chat"))))
		try await waitForSplitPresentation("Open in Tab must show a chat tab") {
			store.main.viewer.item.tab?.isChat == true
		}
		guard let chat = store.main.viewer.item.tab?.id
		else { throw BrowserLaunchError.splitValidationFailed("The chat tab is missing") }

		try await tearOff(chat, at: point, expectsPage: false)
		store.send(.main(.sidebar(.ui(.sidebar(.select(.tab(original.id.rawValue)))))))
		try await waitForSplitPresentation("The original tab must show alone again") {
			store.main.viewer.panes.map { $0.item.tab?.id } == [original.id] && engine.isAttached(original.id)
		}
		print("ARX_TAB_TEAR_OFF_SMOKE_SUCCESS")
	}

	/// Drops `tabID` outside the windows at `point` and checks the Little Arx window it opens,
	/// then closes that window.
	private func tearOff(
		_ tabID: BrowserCore.Tab.ID,
		at point: CGPoint,
		expectsPage: Bool
	) async throws {
		let profileID = store.main.sidebar.organization.tabs[id: tabID]?.profileID
		store.send(.main(.ui(.dropTabOutsideWindows(tabID, point))))
		try await waitForSplitPresentation("A tab dropped outside the windows must open in Little Arx at the drop point") {
			guard
				let little = store.littleWindows.first(where: { $0.tab.id == tabID }),
				let panel = littleWindows[little.id]
			else { return false }

			return panel.isVisible
			&& panel.frame.contains(point)
			&& little.tab.profileID == profileID
			&& !store.workspace.tabs.ids.contains(tabID)
			&& !store.main.sidebar.organization.tabs.ids.contains(tabID)
			&& (!expectsPage || (engine.isAttached(tabID) && engine.client.snapshot(tabID) != nil))
		}
		guard let little = store.littleWindows.first(where: { $0.tab.id == tabID })
		else { throw BrowserLaunchError.splitValidationFailed("The Little Arx window is missing") }

		store.send(.littleWindows(.element(id: little.id, action: .ui(.close))))
		do {
			try await waitForSplitPresentation("The torn-off Little Arx window must close") {
				store.littleWindows[id: little.id] == nil && littleWindows[little.id] == nil
			}
		} catch {
			// Which half stayed: the window's state (a close still waiting on the page, or one it
			// dropped) or its panel (DEV-965).
			let state = store.littleWindows[id: little.id]
			let fields: [String] = [
				"page=\(expectsPage)",
				"inStore=\(state != nil)",
				"panel=\(littleWindows[little.id] != nil)",
				"closing=\(String(describing: state?.isClosing))",
				"request=\(state?.closeRequest != nil)",
				"generation=\(String(describing: state?.viewer.generation))->\(little.viewer.generation)",
				"promoting=\(String(describing: state?.isPromoting))",
			]
			FileHandle.standardError.write(Data(
				("ARX_TAB_TEAR_OFF_CLOSE_DIAGNOSTIC " + fields.joined(separator: " ") + "\n").utf8
			))
			throw error
		}
	}

	private func validatePeekPresentation() async throws {
		guard
			let originalWindow = window,
			let original = store.main.viewer.item.tab,
			let originalURL = store.main.viewer.item.navigation.url
		else { throw BrowserLaunchError.invalidWorkspace }

		let paneID = store.main.viewer.activePaneID
		let previewURL = originalURL.appending(queryItems: [.init(name: "peek", value: "temporary")])
		store.send(.ui(.peekURL(previewURL, sourceWindowID: store.main.id, sourcePaneID: paneID)))
		try await waitForSplitPresentation("Peek must mount its own Chromium surface") {
			store.peeks.first.map { engine.isAttached($0.tab.id) } == true
		}
		guard let peek = store.peeks.first else { throw BrowserLaunchError.invalidWorkspace }
		_ = try await waitForHistoryURL(previewURL, tabID: peek.tab.id)
		guard
			engine.client.snapshot(original.id)?.navigation.url == originalURL,
			store.main.viewer.item.tab?.id == original.id,
			!store.workspace.tabs.ids.contains(peek.tab.id)
		else { throw BrowserLaunchError.peekValidationFailed("Preview changed the underlying tab") }

		guard
			!windowShouldClose(originalWindow),
			originalWindow.isVisible,
			window === originalWindow
		else { throw BrowserLaunchError.peekValidationFailed("Native close bypassed the preview close decision") }

		try await waitForSplitPresentation("Accepted Peek host close must remove the native window") {
			!store.windowIsOpen
			&& window == nil
			&& !originalWindow.isVisible
			&& store.peeks.isEmpty
			&& engine.client.snapshot(peek.tab.id) == nil
		}
		guard engine.client.snapshot(original.id)?.navigation.url == originalURL else {
			throw BrowserLaunchError.peekValidationFailed("Closing the preview host lost its retained browsing session")
		}

		store.send(.ui(.openWindow))
		try await waitForSplitPresentation("Reopened host must remount the original browsing session") {
			window != nil
			&& engine.isAttached(original.id)
			&& store.main.viewer.item.tab?.id == original.id
		}
		print("ARX_PEEK_SMOKE_SUCCESS")
	}

	private func waitForSplitPresentation(
		_ failure: String,
		until ready: () -> Bool
	) async throws {
		for _ in 0..<50 {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(100))
		}
		throw BrowserLaunchError.splitValidationFailed(failure)
	}

	private func waitForHistoryURL(
		_ url: URL,
		tabID: BrowserCore.Tab.ID
	) async throws -> BrowserSessionSnapshot {
		for _ in 0..<100 {
			if let snapshot = engine.client.snapshot(tabID), Self.hasFinished(snapshot, at: url) {
				return snapshot
			}
			try await Task.sleep(for: .milliseconds(100))
		}
		throw BrowserLaunchError.historyValidationFailed("History navigation did not finish")
	}

	private func waitForRestoredPage(
		_ before: BrowserNavigation,
		tabID: BrowserCore.Tab.ID
	) async throws {
		for _ in 0..<100 {
			if
				let navigation = engine.client.snapshot(tabID)?.navigation,
				navigation.title == before.title,
				navigation.colors == before.colors
			{ return }

			try await Task.sleep(for: .milliseconds(100))
		}
		throw BrowserLaunchError.historyValidationFailed("The page didn't come back as it was")
	}

	private static func hasFinished(
		_ snapshot: BrowserSessionSnapshot,
		at url: URL
	) -> Bool {
		snapshot.navigation.url == url
		&& !snapshot.navigation.isLoading
		&& snapshot.navigation.errorCode == nil
		&& snapshot.navigation.history.contains(where: { $0.isCurrent && $0.url == url })
	}

	private func waitForSmokeTitle(
		_ title: String,
		in page: ChromiumPage
	) async throws {
		for _ in 0..<100 {
			if page.navigation.title == title, !page.navigation.isLoading { return }
			try await Task.sleep(for: .milliseconds(100))
		}
		throw BrowserLaunchError.profileIsolationFailed(
			"cache-title-timeout loading=\(page.navigation.isLoading) "
			+ "error=\(String(describing: page.navigation.errorCode))"
		)
	}

	private func visitIdentityPage(
		_ page: ChromiumPage,
		setting identity: String,
		expecting title: String,
		phase: String
	) async throws {
		guard
			let raw = environment["ARX_ENGINE_URL"],
			let base = URL(string: raw)
		else { throw BrowserLaunchError.invalidWorkspace }

		// The phase's name makes the address its own, so the page left by an earlier phase, with
		// the same title, is never taken for this one (DEV-1133).
		let url = base.deletingLastPathComponent()
			.appendingPathComponent("identity.html")
			.appending(queryItems: [.init(name: "set", value: identity), .init(name: "phase", value: phase)])
		print("ARX_PROFILE_IDENTITY_PHASE \(phase) started")
		fflush(stdout)
		try page.navigate(to: url)

		var wait = IdentityPhaseWait(url: url, title: title)
		let start = ContinuousClock.now
		waiting: while true {
			let verdict = wait.observe(
				url: page.navigation.url,
				title: page.navigation.title,
				isLoading: page.navigation.isLoading,
				at: start.duration(to: .now)
			)
			switch verdict {
			case .passed:
				print("ARX_PROFILE_IDENTITY_PHASE \(phase) passed")
				fflush(stdout)
				return

			case .failed:
				break waiting

			case .waiting:
				try await Task.sleep(for: .milliseconds(100))
			}
		}

		// Only known disposable fixture sentinels may appear in failure output.
		let sentinels = ["empty|empty", "work|work", "personal|personal", "private|private"]
		let observed = sentinels.contains(page.navigation.title) ? page.navigation.title : "unexpected"
		throw BrowserLaunchError.profileIsolationFailed(
			"phase=\(phase) expected=\(title) observed=\(observed) "
			+ "loading=\(page.navigation.isLoading) urlMatches=\(page.navigation.url == url) "
			+ "error=\(String(describing: page.navigation.errorCode)) history=\(page.navigation.history.count)"
		)
	}

	private func validateMenuShortcuts() async throws {
		guard let menu = NSApplication.shared.mainMenu, NSApplication.shared.helpMenu != nil
		else { throw BrowserLaunchError.shortcutValidationFailed("menu is missing") }

		// Commands can sit in nested submenus (Edit › Find).
		func menuItems(in menu: NSMenu) -> [NSMenuItem] {
			menu.items.flatMap { item in
				[item] + (item.submenu.map { menuItems(in: $0) } ?? [])
			}
		}

		let items = menuItems(in: menu)
		let leftOut = BrowserCommand.leftOutOfMenu(in: store.state)
		for command in BrowserCommand.allCases where !leftOut.contains(command) {
			let shortcut = store.settings.keyboardShortcuts.shortcut(for: command)
			guard
				let item = items.first(where: { ($0.representedObject as? String) == command.rawValue }),
				item.keyEquivalent == (shortcut?.menuKeyEquivalent ?? ""),
				item.keyEquivalentModifierMask == (shortcut?.modifiers.appKit ?? [])
			else { throw BrowserLaunchError.shortcutValidationFailed("command binding differs: \(command.rawValue)") }
		}

		let event = NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: [.command, .option],
			timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: window?.windowNumber ?? 0,
			context: nil,
			characters: "å",
			charactersIgnoringModifiers: "å",
			isARepeat: false,
			keyCode: 0
		)
		guard
			let event,
			BrowserCommands(store: store).performKeyEquivalent(with: event)
		else { throw BrowserLaunchError.shortcutValidationFailed("Option key equivalent was not handled") }

		for _ in 0..<50 {
			if store.littleWindows.first?.commandBar.isPresented == true { break }
			try await Task.sleep(for: .milliseconds(100))
		}
		guard
			let little = store.littleWindows.first,
			little.isCommandOnly,
			little.viewer.tab == nil
		else { throw BrowserLaunchError.shortcutValidationFailed("Little Arx did not open command-only") }

		store.send(.littleWindows(.element(id: little.id, action: .commandBar(.ui(.dismissed)))))
		for _ in 0..<50 {
			if store.littleWindows.isEmpty { break }
			try await Task.sleep(for: .milliseconds(100))
		}
		guard store.littleWindows.isEmpty
		else { throw BrowserLaunchError.shortcutValidationFailed("Little Arx did not dismiss") }

		print("ARX_SHORTCUTS_SMOKE_SUCCESS")
	}

	private func validateAuxiliaryWindows() async throws {
		store.send(.ui(.openSettings))
		render()
		let originalSettings = settingsWindow

		store.send(.ui(.openSettings))
		render()
		guard originalSettings != nil, settingsWindow === originalSettings
		else { throw BrowserLaunchError.unexpectedReopenWindow }

		settingsWindow?.performClose(nil)
		guard !store.settingsIsOpen
		else { throw BrowserLaunchError.unexpectedReopenWindow }

		guard let raw = environment["ARX_ENGINE_URL"], let url = URL(string: raw)
		else { throw BrowserLaunchError.invalidWorkspace }

		let destination = store.main.sidebar.spaceID
		store.send(.ui(.openLittleArx(destination, url)))
		render()

		guard let little = store.littleWindows.first
		else { throw BrowserLaunchError.unexpectedReopenWindow }

		for _ in 0..<100 {
			if isLittleSmokePageReady(windowID: little.id, tabID: little.tab.id) { break }
			try await Task.sleep(for: .milliseconds(100))
		}

		guard isLittleSmokePageReady(windowID: little.id, tabID: little.tab.id)
		else { throw BrowserLaunchError.unexpectedReopenWindow }

		// Share belongs to its source host even when another browser panel is key.
		guard
			let window,
			let panel = littleWindows[little.id],
			LinkSharingClient.presentationWindow(for: store.main.id) === window,
			LinkSharingClient.presentationWindow(for: little.id) === panel,
			LinkSharingClient.presentationWindow(for: nil) == nil,
			LinkSharingClient.presentationWindow(for: UUID()) == nil
		else { throw BrowserLaunchError.unexpectedReopenWindow }

		#if DEBUG
		guard
			let mainSource = store.state.peekSource(
				windowID: store.main.id,
				paneID: store.main.viewer.activePaneID
			),
			let littleSource = store.state.peekSource(windowID: little.id, paneID: little.id)
		else { throw BrowserLaunchError.unexpectedReopenWindow }

		if ExternalConsentSmoke.requested {
			guard
				let sourceTab = mainSource.tabID,
				let view = engine.contentHostFixtureView(sourceTab),
				let originalURL = engine.client.snapshot(sourceTab)?.navigation.url
			else { throw BrowserLaunchError.invalidWorkspace }

			let originalTabs = Set(store.workspace.tabs.map(\.id))
			smokeStage = "validateAuxiliaryWindows.ExternalConsentSmoke"
			try await ExternalConsentSmoke.run(
				view: view,
				window: window,
				baseURL: url,
				navigate: { url in
					store.send(.main(.viewer(.command(
						.navigate(url),
						in: mainSource.paneID,
						tabID: sourceTab
					))))
				},
				isLoaded: { title in
					guard let navigation = engine.client.snapshot(sourceTab)?.navigation else { return false }
					return navigation.title == title && !navigation.isLoading && navigation.errorCode == nil
				},
				tabsUnchanged: { Set(store.workspace.tabs.map(\.id)) == originalTabs }
			)
			smokeStage = "validateAuxiliaryWindows.PublishedBlankChildSmoke"
			try await PublishedBlankChildSmoke.run(
				store: store,
				engine: engine,
				source: sourceTab,
				window: window,
				baseURL: url,
				privateWindow: { [weak self] id in self?.additionalWindows[id] }
			)
			try await engine.client.command(sourceTab, .navigate(originalURL))
			_ = try await waitForHistoryURL(originalURL, tabID: sourceTab)
		}

		// ABI48 (DEV-815, DEV-819): the link menu's items and Save Page As on a loading PDF.
		smokeStage = "validateAuxiliaryWindows.PageMenusSmoke"
		try await PageMenusSmoke.run(
			store: store,
			engine: engine,
			capture: capabilities.capture,
			source: mainSource,
			window: window,
			baseURL: url
		)

		smokeStage = "validateAuxiliaryWindows.PeekEscapeSmoke"
		try await PeekEscapeSmoke.run(
			store: store,
			engine: engine,
			source: mainSource,
			window: window,
			baseURL: url
		)
		smokeStage = "validateAuxiliaryWindows.PeekEscapeSmoke"
		try await PeekEscapeSmoke.run(
			store: store,
			engine: engine,
			source: littleSource,
			window: panel,
			baseURL: url
		)

		// ABI62 (DEV-1264, DEV-1073): ⌘K and ⌘Z give way to a page that uses them.
		if
			let sourceTab = mainSource.tabID,
			let before = engine.client.snapshot(sourceTab)?.navigation,
			let originalURL = before.url
		{
			smokeStage = "validateAuxiliaryWindows.SiteShortcutsSmoke"
			try await SiteShortcutsSmoke.run(
				store: store,
				engine: engine,
				source: sourceTab,
				window: window,
				baseURL: url
			)
			try await engine.client.command(sourceTab, .navigate(originalURL))
			_ = try await waitForHistoryURL(originalURL, tabID: sourceTab)

			// The page reports its colors after it paints, later than its load: the next stage
			// takes this tab's navigation as its baseline, so it must be the page as it was.
			try await waitForRestoredPage(before, tabID: sourceTab)
		}
		smokeStage = "validateAuxiliaryWindows.NativeContentsSmoke"
		try await NativeContentsSmoke.run(
			store: store,
			engine: engine,
			source: mainSource,
			window: window,
			baseURL: url
		)
		smokeStage = "validateAuxiliaryWindows.NativeContentsSmoke"
		try await NativeContentsSmoke.run(
			store: store,
			engine: engine,
			source: littleSource,
			window: panel,
			baseURL: url
		)
		smokeStage = "validateAuxiliaryWindows.NativeContentsSmoke.shiftClick"
		try await NativeContentsSmoke.shiftClick(
			store: store,
			engine: engine,
			source: mainSource,
			window: window,
			baseURL: url
		)
		smokeStage = "validateAuxiliaryWindows.NativeContentsSmoke.keyboardLinks"
		try await NativeContentsSmoke.keyboardLinks(
			store: store,
			engine: engine,
			source: mainSource,
			window: window,
			baseURL: url
		)
		smokeStage = "validateAuxiliaryWindows.NativeContentsSmoke.focusedLinkCommand"
		try await NativeContentsSmoke.focusedLinkCommand(
			store: store,
			engine: engine,
			source: mainSource,
			window: window,
			baseURL: url
		)
		smokeStage = "validateAuxiliaryWindows.NativeContentsSmoke.private"
		try await NativeContentsSmoke.runPrivate(
			store: store,
			engine: engine,
			baseURL: url,
			window: { [weak self] id in self?.additionalWindows[id] }
		)
		smokeStage = "validateAuxiliaryWindows.LittlePeekSmoke"
		try await LittlePeekSmoke.run(
			store: store,
			engine: engine,
			windowID: little.id,
			littleWindow: panel,
			mainWindow: window,
			baseURL: url
		)

		// ABI49 (DEV-855): a sign-in popup from Little Arx stays in Little Arx and closes itself.
		smokeStage = "validateAuxiliaryWindows.LittlePopupSmoke"
		try await LittlePopupSmoke.run(
			store: store,
			engine: engine,
			windowID: little.id,
			littleWindow: panel,
			baseURL: url
		)

		// DEV-1186: a sign-in popup from the main window opens in Little Arx, not a new window.
		smokeStage = "validateAuxiliaryWindows.LittlePopupSmoke.fromWindow"
		try await LittlePopupSmoke.runFromWindow(
			store: store,
			engine: engine,
			windowID: mainSource.windowID,
			window: window,
			baseURL: url
		)

		// DEV-1312: a Favorite's page-opened tab goes to Peek, keeping its opener.
		smokeStage = "validateAuxiliaryWindows.LittlePopupSmoke.fromFavorite"
		try await LittlePopupSmoke.runFromFavorite(
			store: store,
			engine: engine,
			windowID: mainSource.windowID,
			window: window,
			baseURL: url
		)

		// ABI50 (DEV-857): a sign-in's redirect to an app link goes to its handler's script.
		smokeStage = "validateAuxiliaryWindows.AppLinkSmoke"
		try await AppLinkSmoke.run(
			store: store,
			engine: engine,
			windowID: little.id,
			baseURL: url
		)

		// DEV-862: a handler opens its links with an app chosen by path, and says when it's gone.
		smokeStage = "validateAuxiliaryWindows.AppLinkAppSmoke"
		try await AppLinkSmoke.runChosenApp(
			store: store,
			engine: engine,
			windowID: little.id,
			baseURL: url
		)

		// DEV-1259: a link no handler takes gets Arx's prompt for the app macOS opens, never
		// Chrome's dialog.
		smokeStage = "validateAuxiliaryWindows.AppLinkOpenSmoke"
		try await AppLinkSmoke.runUnconfigured(
			store: store,
			engine: engine,
			windowID: little.id,
			baseURL: url
		)

		// DEV-1323: the member number's sign-in in a private Little Arx takes the server's 303 to
		// its scheme after a cross-site form post, with no prompt.
		smokeStage = "validateAuxiliaryWindows.MemberSignInSmoke"
		try await MemberSignInSmoke.run(store: store, baseURL: url)

		// DEV-1284: Send Feedback's card on the main window keeps its draft and closes when sent;
		// asked from Settings, it's on the Settings window (DEV-1308).
		smokeStage = "validateAuxiliaryWindows.SendFeedbackSmoke"
		try await SendFeedbackSmoke.run(store: store, window: window) { [weak self] in
			self?.store.send(.ui(.openSettings))
			self?.render()
			return self?.settingsWindow
		}
		#endif

		// Its own stage, so a failure here isn't reported as the app link phase before it (DEV-1078).
		smokeStage = "validateAuxiliaryWindows.LittlePromotion"
		store.send(.littleWindows(.element(
			id: little.id,
			action: .ui(.promote(destination, little.tab.profileID))
		)))

		for _ in 0..<100 {
			let isPromoted = store.littleWindows.isEmpty
			&& store.main.viewer.item.tab?.id == little.tab.id
			&& engine.isAttached(little.tab.id)
			&& LinkSharingClient.presentationWindow(for: little.id) == nil

			if isPromoted {
				print("ARX_LITTLE_PROMOTION_SMOKE_SUCCESS")
				return
			}

			try await Task.sleep(for: .milliseconds(100))
		}

		// Which check failed, never a page's address or title.
		let remaining = store.littleWindows[id: little.id]
		let report = "ARX_LITTLE_PROMOTION_TIMEOUT"
		+ " littleWindows=\(store.littleWindows.count)"
		+ " promoting=\(remaining?.isPromoting ?? false)"
		+ " pendingDestination=\(remaining?.pendingDestination != nil)"
		+ " error=\(remaining?.error.map { "\"\($0)\"" } ?? "nil")"
		+ " selected=\(store.main.sidebar.selectedTab?.id == little.tab.id)"
		+ " viewer=\(store.main.viewer.item.tab?.id == little.tab.id)"
		+ " attached=\(engine.isAttached(little.tab.id))"
		+ " sharing=\(LinkSharingClient.presentationWindow(for: little.id) != nil)"
		+ " windowOpen=\(store.windowIsOpen)"
		+ " focused=\(store.focusedWindowID == store.main.id)"
		+ " unsaved=\(store.unsavedOrganization != nil)"
		+ " saveError=\(store.persistenceError != nil)\n"
		FileHandle.standardError.write(Data(report.utf8))
		throw BrowserLaunchError.unexpectedReopenWindow
	}

	private func isLittleSmokePageReady(
		windowID: UUID,
		tabID: BrowserCore.Tab.ID
	) -> Bool {
		guard let navigation = store.littleWindows[id: windowID]?.viewer.navigation
		else { return false }

		return navigation.title == environment["ARX_ENGINE_SMOKE_TITLE"]
		&& !navigation.isLoading
		&& navigation.errorCode == nil
		&& engine.isAttached(tabID)
	}

	private func validateRendererRecovery() async throws {
		guard let tab = store.main.viewer.item.tab
		else { throw BrowserLaunchError.invalidWorkspace }

		guard let requestPath = environment["ARX_ENGINE_SMOKE_CRASH_REQUEST"]
		else { throw BrowserLaunchError.invalidWorkspace }

		// The smoke runner owns this process and terminates only its renderer children.
		try Data().write(to: URL(fileURLWithPath: requestPath))

		for _ in 0..<100 {
			if store.main.viewer.item.navigation.failure == .rendererStopped { break }
			try await Task.sleep(for: .milliseconds(100))
		}

		guard store.main.viewer.item.navigation.failure == .rendererStopped
		else { throw BrowserLaunchError.rendererFailureNotReported }

		store.send(.main(.viewer(.item(.ui(.retry)))))
		for _ in 0..<100 {
			let navigation = store.main.viewer.item.navigation
			let isRecovered = navigation.title == environment["ARX_ENGINE_SMOKE_TITLE"]
			&& !navigation.isLoading
			&& navigation.errorCode == nil
			&& engine.isAttached(tab.id)

			if isRecovered {
				print("ARX_RENDERER_RECOVERY_SMOKE_SUCCESS")
				return
			}

			try await Task.sleep(for: .milliseconds(100))
		}

		throw BrowserLaunchError.rendererRecoveryFailed
	}

	private func sendSmokeReopen() throws {
		let event = NSAppleEventDescriptor(
			eventClass: AEEventClass(kCoreEventClass),
			eventID: AEEventID(kAEReopenApplication),
			targetDescriptor: .currentProcess(),
			returnID: AEReturnID(kAutoGenerateReturnID),
			transactionID: AETransactionID(kAnyTransactionID)
		)
		_ = try event.sendEvent(options: .noReply, timeout: 5)
	}
}
