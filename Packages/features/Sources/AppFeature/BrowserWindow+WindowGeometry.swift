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
	internal func forgetWindowGeometry(_ id: UUID, window: NSWindow) {
		if geometrySends[id] != nil { rememberWindowGeometry(window) }
		normalWindowFrames[id] = nil
		geometryReadyWindows.remove(id)
		fullScreenTransitions.remove(id)
		pendingFullScreenWindows.removeAll { $0 === window }
		if restoringFullScreenWindowID == id { restoringFullScreenWindowID = nil }
		Task { @MainActor [weak self] in self?.restoreNextFullScreenWindow() }
	}

	internal func browserWindowID(_ window: NSWindow) -> UUID? {
		if window === self.window { return store.main.id }
		return additionalWindows.first { $0.value === window }?.key
	}

	internal func placeBrowserWindow(_ window: NSWindow, id: UUID) {
		let saved = store.windowLayout.windowPresentations.first { $0.id == id }?.geometry
		let displays = NSScreen.screens.compactMap { screen -> BrowserWindowGeometry.Display? in
			guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
			else { return nil }
			return .init(id: number.uint32Value, visibleFrame: screen.visibleFrame)
		}
		if
			store.settings.general.restoresWindowsAtStartup,
			let saved,
			let frame = saved.restoredFrame(on: displays, minimumSize: window.minSize)
		{
			window.setFrame(frame, display: false)
		} else if let front = NSApplication.shared.orderedWindows.first(where: {
			$0 !== window && $0.isVisible && !$0.isMiniaturized
			&& browserWindowID($0) != nil && !$0.styleMask.contains(.fullScreen)
		}) {
			_ = window.cascadeTopLeft(from: .init(x: front.frame.minX, y: front.frame.maxY))
		} else {
			window.center()
		}
		normalWindowFrames[id] = window.frame
		geometryReadyWindows.insert(id)
		if saved?.isFullScreen == true, store.settings.general.restoresWindowsAtStartup {
			fullScreenTransitions.insert(id)
			pendingFullScreenWindows.append(window)
			Task { @MainActor [weak self] in
				await Task.yield()
				self?.restoreNextFullScreenWindow()
			}
		} else {
			rememberWindowGeometry(window)
		}
	}

	private func restoreNextFullScreenWindow() {
		guard restoringFullScreenWindowID == nil, !pendingFullScreenWindows.isEmpty else { return }
		let next = pendingFullScreenWindows.removeFirst()
		guard next.isVisible, let id = browserWindowID(next) else {
			if let id = browserWindowID(next) { fullScreenTransitions.remove(id) }
			restoreNextFullScreenWindow()
			return
		}
		restoringFullScreenWindowID = id
		next.toggleFullScreen(nil)
	}

	private func rememberWindowGeometry(_ window: NSWindow) {
		guard let id = browserWindowID(window) else { return }
		geometrySends.removeValue(forKey: id)?.cancel()
		guard
			headless == nil,
			geometryReadyWindows.contains(id),
			!fullScreenTransitions.contains(id)
		else { return }
		let fullScreen = window.styleMask.contains(.fullScreen)
		if !fullScreen { normalWindowFrames[id] = window.frame }
		let display = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
		store.send(.event(.windowGeometryChanged(id, .init(
			frame: normalWindowFrames[id] ?? window.frame,
			displayID: display?.uint32Value,
			// Full screen entered only for a page isn't the window's to restore (DEV-949).
			isFullScreen: fullScreen && !pageFullScreenWindows.isFullScreenForPage(id)
		))))
	}

	/// Moves and resizes arrive for every frame of a drag or an animated resize (DEV-881). The
	/// store hears about the frame once: when a live resize ends, or when moves settle.
	private func scheduleWindowGeometry(_ window: NSWindow) {
		guard let id = browserWindowID(window) else { return }
		geometrySends.removeValue(forKey: id)?.cancel()
		guard !window.inLiveResize else { return }
		geometrySends[id] = Task { @MainActor [weak self, weak window] in
			try? await Task.sleep(for: .milliseconds(300))
			guard !Task.isCancelled, let self, let window else { return }
			self.rememberWindowGeometry(window)
		}
	}

	internal func windowDidMove(_ notification: Notification) {
		guard let window = notification.object as? NSWindow else { return }
		scheduleWindowGeometry(window)
	}

	internal func windowDidResize(_ notification: Notification) {
		guard let window = notification.object as? NSWindow else { return }
		scheduleWindowGeometry(window)
	}

	internal func windowDidEndLiveResize(_ notification: Notification) {
		guard let window = notification.object as? NSWindow else { return }
		rememberWindowGeometry(window)
	}

	internal func windowDidChangeScreen(_ notification: Notification) {
		guard let window = notification.object as? NSWindow else { return }
		rememberWindowGeometry(window)
	}

	internal func windowWillEnterFullScreen(_ notification: Notification) {
		reportFullScreenTransition(notification.object, isTransitioning: true)
		guard let window = notification.object as? NSWindow, let id = browserWindowID(window)
		else { return }
		normalWindowFrames[id] = window.frame
		fullScreenTransitions.insert(id)
	}

	internal func windowDidEnterFullScreen(_ notification: Notification) {
		reportFullScreenTransition(notification.object, isTransitioning: false)
		if littleFullScreenTransitionEnded(notification.object) { return }
		guard let window = notification.object as? NSWindow, let id = browserWindowID(window)
		else { return }
		fullScreenTransitions.remove(id)
		rememberWindowGeometry(window)
		if restoringFullScreenWindowID == id { restoringFullScreenWindowID = nil }
		restoreNextFullScreenWindow()
		renderPageFullScreen()
	}

	internal func windowWillExitFullScreen(_ notification: Notification) {
		reportFullScreenTransition(notification.object, isTransitioning: true)

		// Little Arx leaving its Space under a page takes the page out too (DEV-949).
		if
			let panel = notification.object as? LittleArxPanel,
			let id = littleWindows.first(where: { $0.value === panel })?.key
		{
			if store.pageFullScreen?.windowID == id { store.send(.ui(.exitPageFullScreen)) }
			return
		}
		guard let window = notification.object as? NSWindow, let id = browserWindowID(window)
		else { return }
		fullScreenTransitions.insert(id)

		// Leaving macOS full screen under a page in full screen takes the page out too, as
		// in Chrome (DEV-949). Arx's own exit comes after the page has left.
		if store.pageFullScreen?.windowID == id {
			pageFullScreenWindows.windowLeftFullScreen(id)
			store.send(.ui(.exitPageFullScreen))
		}
	}

	internal func windowDidExitFullScreen(_ notification: Notification) {
		reportFullScreenTransition(notification.object, isTransitioning: false)
		if littleFullScreenTransitionEnded(notification.object) { return }
		guard let window = notification.object as? NSWindow, let id = browserWindowID(window)
		else { return }
		fullScreenTransitions.remove(id)
		rememberWindowGeometry(window)
		renderPageFullScreen()
	}

	internal func windowDidFailToExitFullScreen(_ window: NSWindow) {
		reportFullScreenTransition(window, isTransitioning: false)
		if littleFullScreenTransitionEnded(window) { return }
		guard let id = browserWindowID(window) else { return }
		fullScreenTransitions.remove(id)
		rememberWindowGeometry(window)
		renderPageFullScreen()
	}

	/// Tells the store a browser or Little Arx window began or ended a macOS full-screen
	/// transition, during which its pages can read as covered (DEV-991).
	private func reportFullScreenTransition(
		_ object: Any?,
		isTransitioning: Bool
	) {
		guard let window = object as? NSWindow else { return }
		let id = browserWindowID(window) ?? littleWindows.first { $0.value === window }?.key
		guard let id else { return }

		store.send(.event(.windowFullScreenTransition(id, isTransitioning: isTransitioning)))
	}

	/// A Little Arx panel's page full-screen transition ended or failed (DEV-949): the panel
	/// becomes itself again when it's out of full screen, and page full screen is reconciled.
	/// A panel that couldn't enter ends the page's full screen rather than trying again.
	private func littleFullScreenTransitionEnded(
		_ object: Any?,
		failedToEnter: Bool = false
	) -> Bool {
		guard let panel = object as? LittleArxPanel else { return false }
		panel.pageFullScreenTransitionEnded()
		let id = littleWindows.first { $0.value === panel }?.key
		if failedToEnter, let id, store.pageFullScreen?.windowID == id {
			store.send(.ui(.exitPageFullScreen))
		} else {
			renderPageFullScreen()
		}
		return true
	}

	internal func windowDidFailToEnterFullScreen(_ window: NSWindow) {
		reportFullScreenTransition(window, isTransitioning: false)
		if littleFullScreenTransitionEnded(window, failedToEnter: true) { return }
		if let id = browserWindowID(window) {
			fullScreenTransitions.remove(id)
			if restoringFullScreenWindowID == id { restoringFullScreenWindowID = nil }
			rememberWindowGeometry(window)
		}
		restoreNextFullScreenWindow()
		renderPageFullScreen()
	}
}
