#if DEBUG
import AppKit
import BrowserCore
import BrowserMediaClient
import BrowserSurfaceClient
import ChromiumBrowserEngine
import CoreGraphics
import Foundation
import SwiftUI
import _ComposableArchitecture

/// DEV-848's window smoke: automatic Picture in Picture on a tab switch, over a full-screen
/// window, back on return, and in the video's shape. DEV-852 adds hard throws toward each edge,
/// the time labels at the times that used to cut them off, and a re-snap after a display change.
/// DEV-1246 checks that Arx losing focus with its window on screen floats nothing. DEV-1322
/// checks that the fixture app's full-screen Space taking the display from the window's OS
/// workspace floats nothing while the window isn't full screen, and floats the video once the
/// window is.
///
/// DEV-852's checks reach the engine through in-process notifications that ArxPiP's motion
/// controller answers only under the smoke runner's `ARX_MEDIA_SMOKE_ROOT`
/// (`arx_pip_window_motion.h`).
///
/// The full-screen step (DEV-962) floats PiP over **another app's** full-screen window: the
/// runner's fixture app (`Scripts/fixtures/FullScreenHostFixture.swift`, named by
/// `ARX_MEDIA_SMOKE_FULL_SCREEN_HOST`) takes a window of its own full screen, as Safari or Xcode
/// would. A full-screen window of Arx's own doesn't show the bug users hit. The step needs a
/// display that gives a full-screen window a Space of its own, with windows that join every
/// Space shown over it. A probe window of the smoke's own, a non-activating panel that joins
/// every Space, tells: when it can't float over the full-screen window either, the step reports
/// `ARX_AUTOMATIC_PIP_FULL_SCREEN_SKIPPED` (no full-screen Spaces) instead of failing. When the
/// probe floats, the PiP window must too.
///
/// It uses disposable pages, a separate store and its own windows, and never changes the
/// user's workspace. The only other app it touches is that fixture app, which quits when the
/// step ends. Arx stops being the active app twice, through `NSApp.deactivate()` and when the
/// fixture app comes forward (twice), and takes the front back straight after each. The window
/// goes in and out of macOS full screen once, on a Space of its own.
@MainActor
internal enum AutomaticPictureInPictureSmoke {
	internal static func run(
		engine: ChromiumBrowserEngine,
		baseURL: URL,
		profileID: Profile.ID
	) async throws {
		let root = baseURL.deletingLastPathComponent()
		let videoURL = root.appending(path: "media/automatic.html")
		let spareURL = root.appending(path: "media/manual-only.html")
		let portraitURL = root.appending(path: "media/portrait.html")
		func tab(
			_ title: String,
			_ url: URL
		) -> BrowserCore.Tab {
			.init(id: .init(rawValue: UUID()), profileID: profileID, restoration: .init(title: title, url: url))
		}
		let video = tab("Owned landscape video", videoURL)
		let spare = tab("Owned spare page", spareURL)
		let portrait = tab("Owned portrait video", portraitURL)
		let space = Space(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			name: "Owned automatic PiP acceptance",
			unpinnedTabs: [video.id, spare.id, portrait.id],
			selectedTabID: video.id
		)
		let organization = BrowserOrganization(
			profiles: [.init(id: profileID, name: "Owned automatic PiP acceptance")],
			spaces: [space],
			tabs: [video, spare, portrait]
		)
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: space.id))
		initial.main.viewer.item.tab = video
		let client = try engine.media()
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine = engine.client
			$0.browserSurface = engine.surface
			$0.browserMedia = client
		}

		guard
			let screen = NSScreen.main,
			screen.visibleFrame.width >= 700,
			screen.visibleFrame.height >= 500
		else { throw Failure.invalidFixture }

		let previousWindow = NSApp.keyWindow
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 640, height: 420),
			styleMask: [.titled, .resizable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.collectionBehavior = [.fullScreenPrimary]
		window.title = "Arx owned automatic PiP acceptance"
		let host = NSHostingView(rootView: Host(store: store, surface: engine.surface))
		window.contentView = host
		window.setFrameOrigin(.init(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40))
		var fullScreenHost: FullScreenHost?
		var spacesProbe: NSWindow?
		var phase = "opening"

		// What BrowserWindow reports for the app's own store: Arx leaving the front, and whether
		// the window is on the display (DEV-1246).
		let resign = NotificationCenter.default.addObserver(
			forName: NSApplication.didResignActiveNotification,
			object: nil,
			queue: .main
		) { _ in
			MainActor.assumeIsolated {
				_ = store.send(.event(.browserActivityChanged(isActive: false)))
			}
		}
		let reportDisplay: @MainActor () -> Void = {
			let onDisplay: Set<UUID> = BrowserWindow.isOnDisplay(window) ? [store.main.id] : []
			if store.windowsOnDisplay != onDisplay { store.send(.event(.windowsOnDisplayChanged(onDisplay))) }
		}
		let displayChanges: [(NotificationCenter, Notification.Name)] = [
			(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
			(.default, NSWindow.didChangeOcclusionStateNotification),
			(.default, NSWindow.didMiniaturizeNotification),
			(.default, NSWindow.didDeminiaturizeNotification),
			(.default, NSWindow.didEnterFullScreenNotification),
			(.default, NSWindow.didExitFullScreenNotification),
		]
		let displayObservers = displayChanges.map { center, name in
			(center, center.addObserver(forName: name, object: nil, queue: .main) { _ in
				MainActor.assumeIsolated { reportDisplay() }
			})
		}

		// The window's full-screen transitions, as BrowserWindow's delegate reports them (DEV-991).
		let transitions: [(Notification.Name, Bool)] = [
			(NSWindow.willEnterFullScreenNotification, true),
			(NSWindow.didEnterFullScreenNotification, false),
			(NSWindow.willExitFullScreenNotification, true),
			(NSWindow.didExitFullScreenNotification, false),
		]
		let transitionObservers = transitions.map { name, isTransitioning in
			NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
				MainActor.assumeIsolated {
					_ = store.send(.event(.windowFullScreenTransition(store.main.id, isTransitioning: isTransitioning)))
				}
			}
		}

		defer {
			if phase != "complete" {
				let source = store.media.visibleSources.first { $0.id.tabID == video.id }
				let fields: [String] = [
					"phase=\(phase)",
					"appActive=\(NSApp.isActive)",
					"source=\(source != nil)",
					"pip=\(String(describing: source?.isInPictureInPicture))",
					"playback=\(String(describing: source?.playback))",
					"visible=\(String(describing: source.flatMap { store.mediaSourceVisibility[$0.id] }))",
					"owed=\(store.media.automaticEntry.owed.count)",
					"failures=\(store.media.automaticEntry.failures.values.reduce(0, +))",
					"pending=\(store.media.pending != nil)",
					"pipWindow=\(String(describing: pictureInPictureWindow().map { describe($0) }))",
				]
				FileHandle.standardError.write(Data(("ARX_AUTOMATIC_PIP_DIAGNOSTIC " + fields.joined(separator: " ") + "\n").utf8))
			}
			NotificationCenter.default.removeObserver(resign)
			for (center, observer) in displayObservers { center.removeObserver(observer) }
			for observer in transitionObservers { NotificationCenter.default.removeObserver(observer) }
			spacesProbe?.close()
			fullScreenHost?.quit()
			store.send(.media(.ui(.dismissed)))
			store.send(.main(.viewer(.suspend)))
			window.contentView = nil
			window.close()
			engine.client.close(video.id)
			engine.client.close(spare.id)
			engine.client.close(portrait.id)
			NSApp.activate(ignoringOtherApps: true)
			previousWindow?.makeKeyAndOrderFront(nil)
		}

		try await engine.client.open(video)
		try await engine.client.open(spare)
		try await engine.client.open(portrait)
		NSApp.activate()
		window.makeKeyAndOrderFront(nil)
		reportDisplay()
		store.send(.configureMedia)

		phase = "landscape-playing"
		try await start(video, url: videoURL, in: window, host: host, store: store, engine: engine)
		let source = try require(store.media.visibleSources.first { $0.id.tabID == video.id })

		// 1. Arx stops being the active app with its window still on screen: the video keeps
		// playing in place (DEV-1246). The window floats for the step, so another app's windows
		// can't cover it.
		phase = "focus-loss"
		window.level = .floating
		try await resignActive()
		try await wait { !store.media.automaticEntry.isApplicationActive }
		let floatedForFocusLoss = try await becomes(within: 3) {
			isFloating(source.id, store: store) || pictureInPictureWindow() != nil
			|| store.media.automaticEntry.owed[source.id] != nil
		}
		guard !floatedForFocusLoss else { throw Failure.unexpectedState }
		guard
			store.windowsOnDisplay == [store.main.id],
			try evidence(engine: engine, tab: video.id, url: videoURL)?.pip == false,
			store.media.failure == nil
		else { throw Failure.unexpectedState }
		print("ARX_AUTOMATIC_PIP_FOCUS_LOSS_STAYS_SUCCESS")

		// 2. Back in Arx with the video's window key.
		phase = "reactivation"
		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)
		try await wait { NSApp.isActive && window.isKeyWindow }
		window.level = .normal
		store.send(.event(.browserActivityChanged(isActive: true)))
		try await wait { store.media.automaticEntry.isApplicationActive }

		// 3. Another tab takes its place: it floats, in the video's shape. Right after the
		// return, so the video may still be folding back onto the page (DEV-1213). Each step from
		// the switch to the window, so a timeout names the one that stalled.
		phase = "tab-switch"
		store.send(.main(.viewer(.show(spare, in: store.main.viewer.activePaneID))))
		let tabSwitch = { (step: String) in
			"step=\(step) " + automaticState(video: video, url: videoURL, store: store, engine: engine)
		}
		try await wait(state: { tabSwitch("tab-shown") }) {
			store.main.viewer.item.tab?.id == spare.id
		}
		try await wait(state: { tabSwitch("visibility") }) {
			currentSource(of: video, store: store).map { source in
				store.mediaSourceVisibility[source.id] == false && store.media.automaticEntry.hidden.contains(source.id)
			} ?? false
		}
		try await wait(state: { tabSwitch("request") }) {
			guard let source = currentSource(of: video, store: store) else { return false }

			return store.media.automaticEntry.owed[source.id] != nil
			|| store.media.pending?.request.sourceID == source.id
			|| store.media.automaticAttempts.contains(source.id)
			|| source.isInPictureInPicture
		}
		try await wait(state: { tabSwitch("engine-answer") }) {
			currentSource(of: video, store: store).map { isFloating($0.id, store: store) } ?? false
		}
		try await wait(state: { tabSwitch("window") }) {
			pictureInPictureWindow() != nil
		}
		print("ARX_AUTOMATIC_PIP_TAB_SWITCH_SUCCESS")
		phase = "landscape-aspect"
		try await expectShape(width: 160, height: 90)
		print("ARX_AUTOMATIC_PIP_LANDSCAPE_ASPECT_SUCCESS")

		// 4. DEV-852: hard throws stay on screen and end at a corner; the time labels never cut
		// off; a display change puts the window back at its corner.
		phase = "fling"
		try await flingToEachEdge()
		print("ARX_AUTOMATIC_PIP_FLING_SUCCESS")
		phase = "time-labels"
		try timeLabelsFit()
		print("ARX_AUTOMATIC_PIP_TIME_LABELS_SUCCESS")
		phase = "display-change"
		try await resnapsOnDisplayChange()
		print("ARX_AUTOMATIC_PIP_DISPLAY_CHANGE_SUCCESS")

		// 5. The runner's fixture app takes a window full screen, as Safari or Xcode would, and
		// its Space takes the display from the window's OS workspace. Skipped where the display
		// gives full-screen windows no Space for others to join; see the type's notes.
		phase = "os-workspace-windowed"

		// The video's tab shows again first, so only the OS workspace switch could float it.
		store.send(.main(.viewer(.show(video, in: store.main.viewer.activePaneID))))
		try await wait {
			store.main.viewer.item.tab?.id == video.id
			&& store.mediaSourceVisibility[source.id] == true
			&& !isFloating(source.id, store: store)
		}
		try await wait { try evidence(engine: engine, tab: video.id, url: videoURL)?.pip == false }

		// Only a playing video floats. Coming back from PiP sometimes leaves it paused: noted, and
		// started again, so this step tests the OS workspace and not that return.
		let playsAfterReturn = try await becomes(within: 3) {
			(try? evidence(engine: engine, tab: video.id, url: videoURL))??.playing == true
			&& currentSource(of: video, store: store)?.playback == .playing
		}
		if !playsAfterReturn {
			print("ARX_AUTOMATIC_PIP_RETURN_PAUSED")
			try await start(video, url: videoURL, in: window, host: host, store: store, engine: engine)
		}
		let probe = makeSpacesProbe(on: screen)
		spacesProbe = probe
		let fixture = try FullScreenHost.launch()
		fullScreenHost = fixture
		let enteredFullScreen = try await becomes(within: 30) { fixture.window != nil }
		let cover = fixture.window ?? 0
		var hasFullScreenSpaces = false
		if enteredFullScreen {
			// Let the Space transition finish before reading the window list.
			try await Task.sleep(for: .seconds(1.5))
			hasFullScreenSpaces = try await becomes(within: 5) { floats(probe, over: cover) }
		}
		if hasFullScreenSpaces {
			// The fixture's full-screen Space took the display from the window's OS workspace,
			// but the window isn't full screen: the video keeps playing in place (DEV-1322).
			let floatedForTheSpace = try await becomes(within: 3) {
				isFloating(source.id, store: store) || pictureInPictureWindow() != nil
				|| store.media.automaticEntry.owed[source.id] != nil
			}
			guard
				!floatedForTheSpace,
				!window.isOnActiveSpace,
				store.windowsOnDisplay == [store.main.id]
			else {
				FileHandle.standardError.write(Data((
					"ARX_AUTOMATIC_PIP_OS_WORKSPACE_WINDOWED_FAILURE floated=\(floatedForTheSpace) "
					+ "onDisplay=\(String(describing: store.windowsOnDisplay)) activeSpace=\(window.isOnActiveSpace) "
					+ automaticState(video: video, url: videoURL, store: store, engine: engine) + "\n"
				).utf8))
				throw Failure.unexpectedState
			}
			print("ARX_AUTOMATIC_PIP_OS_WORKSPACE_WINDOWED_STAYS_SUCCESS")

			// 6. Over another app's full-screen window (DEV-962): another tab takes the video's
			// place while the fixture's full screen is in front, and the video floats over it.
			phase = "full-screen"
			store.send(.main(.viewer(.show(spare, in: store.main.viewer.activePaneID))))
			try await wait { isFloating(source.id, store: store) }

			// On screen in front of the full-screen window, by the window server's own list.
			// AppKit's `isOnActiveSpace` is only reported. Required: PiP stays on the screen the
			// user is on.
			let floatsOverFullScreen = try await becomes(within: 15) {
				pictureInPictureWindow().map { floats($0, over: cover) } ?? false
			}
			guard floatsOverFullScreen else {
				let floating = PictureInPictureWindow.visible()
				let fields: [String] = [
					"onScreen=\(floating.map(isOnScreen) ?? false)",
					"occlusionVisible=\(floating?.occlusionState.contains(.visible) ?? false)",
					"above=\(floating.map { isAbove($0.windowNumber, cover) } ?? false)",
					"activeSpace=\(floating?.isOnActiveSpace ?? false)",
					"appActive=\(NSApp.isActive)",
					"window=\(floating.map(describe) ?? "none")",
				]
				FileHandle.standardError.write(Data(
					("ARX_AUTOMATIC_PIP_FULL_SCREEN_FAILURE " + fields.joined(separator: " ") + "\n").utf8
				))
				throw Failure.unexpectedState
			}
			print("ARX_AUTOMATIC_PIP_FULL_SCREEN_SUCCESS")
		} else {
			let fields: [String] = [
				"fullScreen=\(enteredFullScreen)",
				"probeOnScreen=\(isOnScreen(probe))",
				"probeActiveSpace=\(probe.isOnActiveSpace)",
				"probeAbove=\(isAbove(probe.windowNumber, cover))",
				"separateSpaces=\(NSScreen.screensHaveSeparateSpaces)",
			]
			FileHandle.standardError.write(Data(
				("ARX_AUTOMATIC_PIP_FULL_SCREEN_SPACES " + fields.joined(separator: " ") + "\n").utf8
			))
			print(osWorkspaceWindowedSkippedMarker)
			print(fullScreenSkippedMarker)
		}
		probe.close()
		spacesProbe = nil

		// The fixture app quits, and macOS leaves its full-screen Space.
		fixture.quit()
		fullScreenHost = nil
		try await Task.sleep(for: .seconds(1.5))
		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)
		try await wait { NSApp.isActive && window.isKeyWindow }

		// The fixture app took the front, which the store heard; Arx is back, as BrowserWindow
		// reports when one of its windows becomes key.
		store.send(.event(.browserActivityChanged(isActive: true)))

		// 7. Back on the video's tab, on screen: its PiP folds away.
		phase = "tab-return"
		store.send(.main(.viewer(.show(video, in: store.main.viewer.activePaneID))))
		try await wait {
			store.main.viewer.item.tab?.id == video.id
			&& store.mediaSourceVisibility[source.id] == true
			&& !isFloating(source.id, store: store)
		}
		print("ARX_AUTOMATIC_PIP_TAB_RETURN_SUCCESS")

		// 8. The window full screen (DEV-1322): the fixture's full-screen Space taking the display
		// from the window's own floats the video, and coming back folds it away.
		if hasFullScreenSpaces {
			phase = "os-workspace-full-screen"
			try await floatsWhenItsFullScreenSpaceLeaves(
				source.id,
				video: video,
				url: videoURL,
				window: window,
				host: host,
				store: store,
				engine: engine,
				fixture: { fullScreenHost = $0 }
			)
			print("ARX_AUTOMATIC_PIP_OS_WORKSPACE_FULL_SCREEN_SUCCESS")
		} else {
			print(osWorkspaceFullScreenSkippedMarker)
		}

		// 9. A portrait video floats in its own shape.
		phase = "portrait-playing"
		store.send(.main(.viewer(.show(portrait, in: store.main.viewer.activePaneID))))
		try await start(portrait, url: portraitURL, in: window, host: host, store: store, engine: engine)
		let portraitSource = try require(store.media.visibleSources.first { $0.id.tabID == portrait.id })
		phase = "portrait-switch"
		store.send(.main(.viewer(.show(spare, in: store.main.viewer.activePaneID))))
		try await wait { isFloating(portraitSource.id, store: store) }
		phase = "portrait-aspect"
		try await expectShape(width: 90, height: 160)
		print("ARX_AUTOMATIC_PIP_PORTRAIT_ASPECT_SUCCESS")
		store.send(.main(.viewer(.show(portrait, in: store.main.viewer.activePaneID))))
		try await wait { !isFloating(portraitSource.id, store: store) }

		phase = "complete"
		print("ARX_AUTOMATIC_PIP_SMOKE_SUCCESS")
	}

	// MARK: - Steps

	/// Makes Arx stop being the active app. `deactivate()` alone can leave it active under
	/// cooperative activation, so Arx then yields to Finder, which is always running, and asks
	/// it to come forward. Only the active app changes; no other app's window is touched.
	private static func resignActive() async throws {
		NSApp.deactivate()
		for _ in 0..<40 where NSApp.isActive {
			try await Task.sleep(for: .milliseconds(50))
		}
		if !NSApp.isActive { return }

		guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
		else { throw Failure.invalidFixture }

		NSApp.yieldActivation(to: finder)
		finder.activate()
		try await wait { !NSApp.isActive }
	}

	private static func start(
		_ tab: BrowserCore.Tab,
		url: URL,
		in window: NSWindow,
		host: NSView,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine
	) async throws {
		try await wait {
			let ready = try evidence(engine: engine, tab: tab.id, url: url)?.ready == true
			return ready
			&& store.main.viewer.item.tab?.id == tab.id
			&& engine.isAttached(tab.id)
			&& window.occlusionState.contains(.visible)
		}
		try clickStart(window: window, host: host, currentURL: engine.client.snapshot(tab.id)?.navigation.url, url: url)
		try await wait {
			guard
				let state = try evidence(engine: engine, tab: tab.id, url: url),
				let source = store.media.visibleSources.first(where: { $0.id.tabID == tab.id })
			else { return false }

			return state.playing
			&& source.playback == .playing
			&& store.mediaSourceVisibility[source.id] == true
		}
	}

	/// The PiP window's content takes the video's aspect ratio, within 1%.
	private static func expectShape(
		width: CGFloat,
		height: CGFloat
	) async throws {
		let expected = width / height
		var measured: CGFloat = 0
		do {
			try await wait {
				guard let floating = pictureInPictureWindow() else { return false }

				let size = floating.contentLayoutRect.size
				guard size.height > 0 else { return false }

				measured = size.width / size.height
				return abs(measured - expected) / expected < 0.01
			}
		} catch {
			FileHandle.standardError.write(Data(
				"ARX_AUTOMATIC_PIP_ASPECT_MISMATCH expected=\(expected) measured=\(measured)\n".utf8
			))
			throw error
		}
	}

	/// Takes `window` full screen with the video showing and playing, lets the fixture app's
	/// full-screen Space take the display from the window's, and requires the video to float;
	/// then brings Arx back, requires it to fold away, and leaves full screen (DEV-1322).
	private static func floatsWhenItsFullScreenSpaceLeaves(
		_ id: BrowserMediaSource.ID,
		video: BrowserCore.Tab,
		url: URL,
		window: NSWindow,
		host: NSView,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		fixture keep: (FullScreenHost?) -> Void
	) async throws {
		// Only a playing video floats; the return can leave it paused, as in step 5.
		let plays = try await becomes(within: 3) {
			(try? evidence(engine: engine, tab: video.id, url: url))??.playing == true
			&& currentSource(of: video, store: store)?.playback == .playing
		}
		if !plays {
			print("ARX_AUTOMATIC_PIP_RETURN_PAUSED")
			try await start(video, url: url, in: window, host: host, store: store, engine: engine)
		}

		window.toggleFullScreen(nil)
		try await wait {
			window.styleMask.contains(.fullScreen)
			&& store.fullScreenTransitionWindows.isEmpty
			&& store.windowsOnDisplay == [store.main.id]
			&& store.mediaSourceVisibility[id] == true
			&& !isFloating(id, store: store)
		}

		let fixture = try FullScreenHost.launch()
		keep(fixture)
		try await wait(seconds: 30) { fixture.window != nil }
		let floated = try await becomes(within: 15) {
			!(store.windowsOnDisplay ?? []).contains(store.main.id)
			&& isFloating(id, store: store)
		}
		guard floated else {
			FileHandle.standardError.write(Data((
				"ARX_AUTOMATIC_PIP_OS_WORKSPACE_FULL_SCREEN_FAILURE onDisplay=\(String(describing: store.windowsOnDisplay)) "
				+ "activeSpace=\(window.isOnActiveSpace) fullScreen=\(window.styleMask.contains(.fullScreen)) "
				+ automaticState(video: video, url: url, store: store, engine: engine) + "\n"
			).utf8))
			throw Failure.unexpectedState
		}

		// The fixture app quits, and macOS leaves its full-screen Space for the window's.
		fixture.quit()
		keep(nil)
		try await Task.sleep(for: .seconds(1.5))
		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)
		try await wait { NSApp.isActive && window.isKeyWindow && window.isOnActiveSpace }
		store.send(.event(.browserActivityChanged(isActive: true)))
		try await wait {
			store.mediaSourceVisibility[id] == true
			&& !isFloating(id, store: store)
		}

		window.toggleFullScreen(nil)
		try await wait {
			!window.styleMask.contains(.fullScreen)
			&& store.fullScreenTransitionWindows.isEmpty
			&& store.mediaSourceVisibility[id] == true
			&& !isFloating(id, store: store)
		}
	}

	// MARK: - Reading state

	private static func isFloating(
		_ id: BrowserMediaSource.ID,
		store: StoreOf<AppFeature>
	) -> Bool {
		store.media.visibleSources.contains { $0.id == id && $0.isInPictureInPicture }
		&& store.media.pending == nil
	}

	/// What the full-screen step prints in place of its success marker on a display without
	/// full-screen Spaces; `Scripts/core/media_smoke.py` accepts it.
	private static let fullScreenSkippedMarker: String = "ARX_AUTOMATIC_PIP_FULL_SCREEN_SKIPPED reason=no-full-screen-spaces"

	/// Without full-screen Spaces the fixture's window only covers Arx's on the same OS workspace,
	/// which floats nothing either way (DEV-1246), so both OS workspace steps are skipped with it.
	private static let osWorkspaceWindowedSkippedMarker: String = "ARX_AUTOMATIC_PIP_OS_WORKSPACE_WINDOWED_SKIPPED reason=no-full-screen-spaces"
	private static let osWorkspaceFullScreenSkippedMarker: String = "ARX_AUTOMATIC_PIP_OS_WORKSPACE_FULL_SCREEN_SKIPPED reason=no-full-screen-spaces"

	/// A small window of the smoke's own that joins every Space, full-screen ones included, at
	/// the floating level, as the engine's PiP window does. Shown before the cover goes full
	/// screen, as the PiP window is, at the top centre of the screen, clear of the PiP corners.
	private static func makeSpacesProbe(on screen: NSScreen) -> NSWindow {
		let size = NSSize(width: 120, height: 68)
		let visible = screen.visibleFrame
		let probe = NSPanel(
			contentRect: .init(
				origin: .init(x: visible.midX - size.width / 2, y: visible.maxY - restingInset - size.height),
				size: size
			),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		probe.isReleasedWhenClosed = false
		probe.title = "Arx owned full-screen Spaces probe"
		probe.level = .floating
		probe.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
		probe.backgroundColor = .black
		probe.isOpaque = true
		probe.orderFrontRegardless()
		return probe
	}

	/// On screen in front of the window numbered `cover`, by the window server's own list.
	private static func floats(
		_ window: NSWindow,
		over cover: Int
	) -> Bool {
		window.isVisible
		&& window.occlusionState.contains(.visible)
		&& isAbove(window.windowNumber, cover)
	}

	private static func pictureInPictureWindow() -> NSWindow? {
		guard
			let window = PictureInPictureWindow.visible(),
			PictureInPictureWindow.joinsEverySpace(window)
		else { return nil }

		return window
	}

	// MARK: - Motion and time labels (DEV-852)

	/// Asks ArxPiP's motion controller for one of the smoke's checks; see the type's notes.
	private static func ask(
		_ name: String,
		_ window: NSWindow,
		_ info: [String: Any] = [:]
	) -> NSMutableDictionary {
		let reply = NSMutableDictionary()
		var userInfo = info
		userInfo["reply"] = reply
		NotificationCenter.default.post(name: .init(name), object: window, userInfo: userInfo)
		return reply
	}

	/// A 20,000-point-a-second throw toward each edge, released in the middle of the window's
	/// screen. The window is on a screen in every sampled frame (inside the visible frame when
	/// there's one display) and comes to rest at a corner 16 points inside a screen's visible
	/// frame; on its own screen, at the edge it was thrown toward. A neighbouring display may
	/// take a sideways throw.
	private static func flingToEachEdge() async throws {
		let flings: [(edge: NSRectEdge, x: CGFloat, y: CGFloat)] = [
			(.maxX, 20_000, 0),
			(.minX, -20_000, 0),
			(.maxY, 0, 20_000),
			(.minY, 0, -20_000),
		]
		for fling in flings {
			let window = try require(pictureInPictureWindow())
			let screen = try require(window.screen)
			let visible = screen.visibleFrame
			window.setFrameOrigin(.init(
				x: visible.midX - window.frame.width / 2,
				y: visible.midY - window.frame.height / 2
			))
			let reply = ask("ArxPiPSmokeRelease", window, ["x": fling.x, "y": fling.y])
			guard reply["handled"] as? Bool == true else { throw Failure.engineHookMissing }

			let single = NSScreen.screens.count == 1
			var leftScreen = false
			var last = window.frame
			var stillSince = ContinuousClock.now
			let start = ContinuousClock.now
			while ContinuousClock.now < start.advanced(by: .seconds(5)) {
				try await Task.sleep(for: .milliseconds(8))
				let frame = window.frame
				if window.screen == nil || (single && !visible.insetBy(dx: -1, dy: -1).contains(frame)) {
					leftScreen = true
				}
				if frame != last {
					last = frame
					stillSince = .now
				} else if ContinuousClock.now - stillSince > .milliseconds(400) {
					break
				}
			}
			let rest = window.frame
			let restScreen = NSScreen.screens.first { $0.visibleFrame.contains(NSPoint(x: rest.midX, y: rest.midY)) }
			let atCorner = restScreen.map { isAtCorner(rest, of: $0.visibleFrame) } ?? false
			let atEdge = restScreen?.visibleFrame != visible || isAt(fling.edge, rest, of: visible)
			guard !leftScreen, atCorner, atEdge else {
				FileHandle.standardError.write(Data((
					"ARX_AUTOMATIC_PIP_FLING_FAILURE edge=\(fling.edge.rawValue) leftScreen=\(leftScreen) "
					+ "atCorner=\(atCorner) atEdge=\(atEdge) rest=\(describe(window))\n"
				).utf8))
				throw Failure.unexpectedState
			}
		}
	}

	private static let restingInset: CGFloat = 16

	private static func isAtCorner(
		_ frame: NSRect,
		of visible: NSRect
	) -> Bool {
		(isAt(.minX, frame, of: visible) || isAt(.maxX, frame, of: visible))
		&& (isAt(.minY, frame, of: visible) || isAt(.maxY, frame, of: visible))
	}

	private static func isAt(
		_ edge: NSRectEdge,
		_ frame: NSRect,
		of visible: NSRect
	) -> Bool {
		switch edge {
		case .minX: abs(frame.minX - (visible.minX + restingInset)) < 1
		case .maxX: abs(frame.maxX - (visible.maxX - restingInset)) < 1
		case .minY: abs(frame.minY - (visible.minY + restingInset)) < 1
		case .maxY: abs(frame.maxY - (visible.maxY - restingInset)) < 1
		@unknown default: false
		}
	}

	/// The elapsed and duration labels show their whole text as the time grows a digit: 0:09
	/// to 0:10, 9:59 to 10:00 and 59:59 to 1:00:00, and with no duration yet. Each pair is shown
	/// in turn, as playback would, then the real position again.
	private static func timeLabelsFit() throws {
		let window = try require(pictureInPictureWindow())
		let cases: [[[Double]]] = [
			[[9, 30], [10, 30]],
			[[599, 900], [600, 900]],
			[[3599, 7200], [3600, 7200]],
			[[9, 0], [10, 0]],
		]
		for times in cases {
			let reply = ask("ArxPiPSmokeTimeLabels", window, ["times": times])
			guard let fits = reply["fits"] as? Bool else { throw Failure.engineHookMissing }
			guard fits else {
				FileHandle.standardError.write(Data("ARX_AUTOMATIC_PIP_TIME_LABELS_TRUNCATED times=\(times)\n".utf8))
				throw Failure.unexpectedState
			}
		}
	}

	/// A display change, simulated by posting AppKit's screen-parameters notification after the
	/// window was moved off its corner, puts it back at the same corner of the same display.
	/// Unplugging, rearranging and resolution changes need a second display and are checked by
	/// hand.
	private static func resnapsOnDisplayChange() async throws {
		let window = try require(pictureInPictureWindow())
		let before = ask("ArxPiPSmokeRest", window)
		guard
			let display = before["display"] as? Int64,
			let corner = before["corner"] as? Int,
			corner >= 0
		else { throw Failure.engineHookMissing }

		let rest = window.frame
		window.setFrameOrigin(.init(x: rest.minX - 120, y: rest.minY + 90))
		NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
		try await wait(seconds: 5) {
			abs(window.frame.minX - rest.minX) < 1 && abs(window.frame.minY - rest.minY) < 1
		}
		let after = ask("ArxPiPSmokeRest", window)
		guard after["display"] as? Int64 == display, after["corner"] as? Int == corner else {
			throw Failure.unexpectedState
		}
	}

	private static func describe(_ window: NSWindow) -> String {
		let frame = window.frame
		return "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))"
		+ "/space=\(window.isOnActiveSpace)/behavior=\(window.collectionBehavior.rawValue)"
		+ "/level=\(window.level.rawValue)/style=\(window.styleMask.rawValue)/canHide=\(window.canHide)"
		+ "/parent=\(window.parent != nil)/visible=\(window.isVisible)"
	}

	private static func isOnScreen(_ window: NSWindow) -> Bool {
		let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
		return list.contains { $0[kCGWindowNumber as String] as? Int == window.windowNumber }
	}

	/// Whether window `upper` is in front of window `lower` in the on-screen window list, front to
	/// back. Window numbers are the window server's, so `lower` may be another app's.
	private static func isAbove(
		_ upper: Int,
		_ lower: Int
	) -> Bool {
		guard
			let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
		else { return false }

		let numbers = list.compactMap { $0[kCGWindowNumber as String] as? Int }
		guard
			let upperIndex = numbers.firstIndex(of: upper),
			let lowerIndex = numbers.firstIndex(of: lower)
		else { return false }

		return upperIndex < lowerIndex
	}

	private static func evidence(
		engine: ChromiumBrowserEngine,
		tab: BrowserCore.Tab.ID,
		url: URL
	) throws -> Evidence? {
		guard
			let navigation = engine.client.snapshot(tab)?.navigation,
			navigation.url == url,
			navigation.errorCode == nil,
			navigation.title.hasPrefix("Arx media {")
		else { return nil }

		return try Evidence(title: navigation.title)
	}

	private static func clickStart(
		window: NSWindow,
		host: NSView,
		currentURL: URL?,
		url: URL
	) throws {
		guard
			window.contentView === host,
			window.isVisible,
			window.isKeyWindow,
			window.windowNumber > 0
		else { throw Failure.invalidFixture }

		let point = try MediaSmokeInput.startPoint(
			currentURL: currentURL,
			expectedURL: url,
			bounds: host.bounds,
			isFlipped: host.isFlipped
		)
		let timestamp = ProcessInfo.processInfo.systemUptime
		for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
			guard
				let event = NSEvent.mouseEvent(
					with: type,
					location: host.convert(point, to: nil),
					modifierFlags: [],
					timestamp: timestamp + Double(index) * 0.001,
					windowNumber: window.windowNumber,
					context: nil,
					eventNumber: index + 1,
					clickCount: 1,
					pressure: index == 0 ? 1 : 0
				)
			else { throw Failure.invalidFixture }

			window.sendEvent(event)
		}
	}

	private static func require<Value>(_ value: Value?) throws -> Value {
		guard let value else { throw Failure.unexpectedState }
		return value
	}

	/// The video's source now: its generation may change while the smoke runs.
	private static func currentSource(
		of tab: BrowserCore.Tab,
		store: StoreOf<AppFeature>
	) -> BrowserMediaSource? {
		store.media.visibleSources.first { $0.id.tabID == tab.id }
	}

	/// What the store, the engine's snapshot, the page and the window say of the video's
	/// automatic entry, for a timeout (DEV-1213).
	private static func automaticState(
		video: BrowserCore.Tab,
		url: URL,
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine
	) -> String {
		guard let source = currentSource(of: video, store: store) else { return "source=none" }

		let entry = store.media.automaticEntry
		let id = source.id
		let page = try? evidence(engine: engine, tab: video.id, url: url)
		let pending = store.media.pending.map { "\($0.request.action)(\($0.request.sourceID == id ? "video" : "other"))" } ?? "none"
		return [
			"shownTab=\(store.main.viewer.item.tab?.id == video.id ? "video" : "other")",
			"visible=\(store.mediaSourceVisibility[id].map(String.init) ?? "nil")",
			"shown=\(entry.shown.contains(id)) hidden=\(entry.hidden.contains(id))",
			"owed=\(entry.owed[id].map { "\($0)" } ?? "nil") failures=\(entry.failures[id] ?? 0)",
			"attempted=\(store.media.automaticAttempts.contains(id)) pending=\(pending)",
			"awaitingInline=\(entry.awaitingInline.contains(id)) landing=\(entry.landing.contains(id))",
			"returns=\(entry.returns.contains(id)) active=\(entry.isApplicationActive)",
			"snapshot=(pip=\(source.isInPictureInPicture) playback=\(source.playback) revision=\(source.revision) generation=\(id.generation))",
			"page=\(page.map { "(pip=\($0.pip) playing=\($0.playing))" } ?? "unreadable")",
			"pipWindow=\(pictureInPictureWindow().map { describe($0) } ?? "none")",
		].joined(separator: " ")
	}

	private static func wait(
		seconds: Int = 15,
		file: StaticString = #fileID,
		line: Int = #line,
		function: StaticString = #function,
		state: () -> String = { "condition still false" },
		_ condition: () throws -> Bool
	) async throws {
		let start = ContinuousClock.now
		let deadline = start.advanced(by: .seconds(seconds))
		while ContinuousClock.now < deadline {
			try Task.checkCancellation()
			if try condition() { return }
			try await Task.sleep(for: .milliseconds(25))
		}
		throw SmokeDiagnostics.timeout(
			site: "\(file):\(line) \(function)",
			since: start,
			state: state()
		)
	}

	/// Whether `condition` holds within `seconds`. Unlike `wait`, running out is an answer, not
	/// a time out.
	private static func becomes(
		within seconds: Int,
		_ condition: () -> Bool
	) async throws -> Bool {
		let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
		while ContinuousClock.now < deadline {
			try Task.checkCancellation()
			if condition() { return true }
			try await Task.sleep(for: .milliseconds(25))
		}
		return condition()
	}

	private struct Host: View {
		internal let store: StoreOf<AppFeature>
		internal let surface: BrowserSurfaceClient

		internal var body: some View {
			Group {
				if let tab = store.main.viewer.item.tab {
					BrowserSurface(tabID: tab.id, client: surface)
				}
			}
			.frame(width: 640, height: 420)
			.environment(\.browserSurfaceVisibilityObserver, .init { report in
				store.send(.event(.mediaSurfaceVisibility(store.main.id, report)))
			})
		}
	}

	private struct Evidence: Decodable {
		internal let ready: Bool
		internal let playing: Bool
		internal let pip: Bool

		internal init(title: String) throws {
			guard title.utf8.count <= 2048, title.hasPrefix("Arx media ")
			else { throw Failure.invalidFixture }

			let payload = Data(title.dropFirst("Arx media ".count).utf8)
			self = try JSONDecoder().decode(Self.self, from: payload)
		}
	}

	private enum Failure: Error {
		case invalidFixture
		case unexpectedState

		/// The engine predates DEV-852's smoke checks, or ARX_MEDIA_SMOKE_ROOT didn't reach it.
		case engineHookMissing
	}

	/// The runner's fixture app with one window in full screen (DEV-962); see the type's notes.
	/// It quits when its standard input closes, so it never outlives the smoke.
	private final class FullScreenHost {
		private let process: Process
		private let input: Pipe
		private let reader: FileHandle
		private let output: Output

		private init(
			process: Process,
			input: Pipe,
			reader: FileHandle,
			output: Output
		) {
			self.process = process
			self.input = input
			self.reader = reader
			self.output = output
		}

		/// The full-screen window's number, once the fixture app reports it.
		internal var window: Int? { output.window }

		internal static func launch() throws -> FullScreenHost {
			guard let path = ProcessInfo.processInfo.environment["ARX_MEDIA_SMOKE_FULL_SCREEN_HOST"]
			else { throw Failure.invalidFixture }

			let process = Process()
			process.executableURL = URL(fileURLWithPath: path)
			process.arguments = ["120"]
			let input = Pipe()
			let pipe = Pipe()
			let output = Output()
			process.standardInput = input
			process.standardOutput = pipe
			pipe.fileHandleForReading.readabilityHandler = { handle in
				let data = handle.availableData

				// End of file: the fixture app quit. A handler left in place would be called
				// again and again.
				guard !data.isEmpty else {
					handle.readabilityHandler = nil
					return
				}
				output.append(data)
			}
			try process.run()
			return .init(process: process, input: input, reader: pipe.fileHandleForReading, output: output)
		}

		internal func quit() {
			reader.readabilityHandler = nil
			try? reader.close()
			try? input.fileHandleForWriting.close()
			if process.isRunning {
				process.terminate()
			}
		}

		/// The fixture app's standard output, read off the main thread.
		private final class Output: @unchecked Sendable {
			private static let prefix: String = "ARX_FULL_SCREEN_HOST_READY window="
			private let lock: NSLock = .init()
			private var text: String = ""

			internal func append(_ data: Data) {
				lock.withLock { text += String(decoding: data, as: UTF8.self) }
			}

			internal var window: Int? {
				lock.withLock {
					text.split(separator: "\n")
						.first { $0.hasPrefix(Self.prefix) }
						.flatMap { Int($0.dropFirst(Self.prefix.count)) }
				}
			}
		}
	}
}
#endif
