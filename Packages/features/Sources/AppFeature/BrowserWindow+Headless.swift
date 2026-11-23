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
	// MARK: - Headless

	internal func startHeadlessRun() {
		guard let headless else { return }
		headless.start(
			store: store,
			dialogs: { [runtime] in runtime.unattendedDialogCount },
			stop: { [weak self] _ in self?.stopHeadlessRun() }
		)

		// Page views resize asynchronously after the host changes size.
		Task { @MainActor [weak self] in
			while let self, !isQuitting {
				fitHeadlessViewport()
				let snapshotPairs = store.workspace.tabs.compactMap { tab in
					engine.client.snapshot(tab.id).map { (tab.id, $0) }
				}
				headless.observePages(Dictionary(uniqueKeysWithValues: snapshotPairs))
				do {
					try await Task.sleep(for: .milliseconds(250))
				} catch {
					return
				}
			}
		}
	}

	/// The same native shutdown as Quit, without before-unload or download prompts:
	/// nobody can answer them, and the run's own client is revoked first.
	private func stopHeadlessRun() {
		guard !isQuitting else { return }
		isQuitting = true
		let clients = store.automationPreferences.clients
		if let client = clients.first(where: { $0.name == HeadlessRun.clientName }) {
			store.send(.automation(.ui(.revokeClient(client.id))))
		}
		capabilities.stop()
		Task { [self] in
			await flushHeadlessSaves()
			await automationHost.stop()
			engine.closeAll()
			runtime.requestQuit()
		}
	}

	/// A run can be stopped right after a change, before its coalesced workspace save or its
	/// throttled history write: every stop writes them first, waiting a bounded time (DEV-865).
	private func flushHeadlessSaves() async {
		let workspace = store.send(.flushWorkspaceSave)
		let history = history
		let finished = await HeadlessShutdown.finish(within: HeadlessShutdown.saveDeadline) {
			await workspace.finish()
			await history.flush()
		}
		if !finished { FileHandle.standardError.write(Data("ARX_HEADLESS_SAVE_TIMEOUT\n".utf8)) }
	}

	/// A transparent, click-through host. It stays ordered in so Chromium keeps
	/// rendering; occlusion is ignored natively for unattended runs. It sits on the
	/// main screen, or off every screen when the Mac has none (DEV-865).
	internal func createHeadlessWindow(_ window: NSWindow) {
		guard let headless else { return }
		window.identifier = LinkSharingClient.windowIdentifier(for: store.main.id)
		self.window = window
		window.styleMask = [.borderless]
		window.contentMinSize = NSSize(width: 1, height: 1)
		window.alphaValue = 0
		window.ignoresMouseEvents = true
		window.hasShadow = false
		window.isExcludedFromWindowsMenu = true
		window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
		window.contentView = BrowserHostingView(
			rootView: AppMainView(
				store: store,
				surface: pageSurface,
				engine: pageRouter.client,
				siteIcons: viewSiteIcons,
				previewClients: previewClients
			),
			minimumSize: NSSize(width: 1, height: 1)
		)
		window.setContentSize(headless.configuration.viewport)
		window.setFrameOrigin(headless.display.origin)
		window.orderFront(nil)
	}

	/// Grows or shrinks the host until the focused page view is exactly the viewport.
	internal func fitHeadlessViewport() {
		guard
			let headless,
			let window,
			let id = store.main.viewer.item.tab?.id,
			let view = engine.hostView(id),
			view.window === window
		else { return }

		let target = headless.configuration.viewport
		let size = view.bounds.size
		guard size.width > 0, size.height > 0, size != target else { return }

		let content = window.contentRect(forFrameRect: window.frame).size
		window.setContentSize(NSSize(
			width: max(1, content.width + target.width - size.width),
			height: max(1, content.height + target.height - size.height)
		))
		window.setFrameOrigin(headless.display.origin)
	}
}
