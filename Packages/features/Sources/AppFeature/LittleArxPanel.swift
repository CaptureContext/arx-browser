import AppKit
import AppUI
import BrowserCore

@MainActor
internal final class LittleArxPanel: NSPanel, PagePictureInPictureMoving {
	private var commandOnly: Bool

	/// Little Arx's frame and the page's site while the window is Page PiP (DEV-1112).
	private var pictureInPictureRestoration: PictureInPictureRestoration?

	/// Page PiP asked for while page full screen was still ending, with the page's site: it
	/// starts once the transition ends.
	private var pendingPictureInPicture: String??

	/// Moves the window as Page PiP while it is one.
	internal private(set) var pictureInPictureMover: PagePictureInPictureMover?

	/// What page full screen changed, put back when it ends (DEV-949).
	private var pageFullScreenRestoration: PageFullScreenRestoration?

	/// A page full-screen transition the panel started hasn't ended yet.
	private var isPageFullScreenTransitioning: Bool = false

	/// A drag from the header's controls moves the window, as Page PiP's does (DEV-1247).
	private var controlDrag = WindowControlDrag()

	/// Never activates Arx. Activating would raise its other windows and leave a
	/// full-screen app's Space, and this panel takes the keyboard without it.
	private static let browserStyle: NSWindow.StyleMask = [
		.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel,
	]
	private static let commandStyle: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]

	/// Little Arx as a browser window stays on the Space it opened on, as a document window does,
	/// and moves only when the person drags it to another Space or moves it with Mission Control
	/// or Stage Manager (DEV-1227). A window above the normal level is transient unless it says
	/// otherwise, and transient windows float onto whatever Space is active, so it says `managed`.
	/// `fullScreenAuxiliary` lets one that opened over another app's full-screen window stay there.
	internal static let windowBehavior: NSWindow.CollectionBehavior = [
		.managed, .participatesInCycle, .fullScreenAuxiliary,
	]

	/// The launcher bar opens wherever the person is when they call it, as Spotlight does, other
	/// apps' full-screen Spaces included.
	internal static let launcherBehavior: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

	private static func behavior(commandOnly: Bool) -> NSWindow.CollectionBehavior {
		commandOnly ? launcherBehavior : windowBehavior
	}

	internal init(
		commandOnly: Bool = false,
		launcherPosition: LittleArxLauncherPosition = .topRight,
		origin: CGPoint? = nil
	) {
		self.commandOnly = commandOnly
		let anchor = origin ?? NSEvent.mouseLocation
		let screen = NSScreen.screens.first { $0.frame.contains(anchor) }
			?? NSScreen.main
		let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
		let size = NSSize(
			width: min(commandOnly ? Self.launcherWidth : 800, visible.width - 40),
			height: commandOnly ? 138 : min(620, visible.height - 60)
		)

		super.init(
			contentRect: commandOnly
			? Self.launcherFrame(position: launcherPosition, size: size, visible: visible)
			: origin.map { Self.droppedFrame(at: $0, size: size, visible: visible) } ?? .init(
				x: visible.midX - size.width / 2,
				y: visible.midY - size.height / 2,
				width: size.width,
				height: size.height
			),
			styleMask: commandOnly ? Self.commandStyle : Self.browserStyle,
			backing: .buffered,
			defer: false
		)

		self.isReleasedWhenClosed = false
		self.isFloatingPanel = true
		self.hidesOnDeactivate = false
		self.becomesKeyOnlyIfNeeded = false
		self.level = .floating
		self.collectionBehavior = Self.behavior(commandOnly: commandOnly)
		self.contentMinSize = self.minimumBrowserContentSize
		self.isOpaque = false
		self.backgroundColor = .clear
		self.titleVisibility = .hidden
		self.titlebarAppearsTransparent = true

		// The launcher bar can be dragged by its background (DEV-1335); it stays on screen.
		launcherMoveObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.didMoveNotification,
			object: self,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.keepLauncherOnScreen() }
		}
	}

	/// Watches the launcher bar's moves, to keep it on screen (DEV-1335).
	private var launcherMoveObserver: NSObjectProtocol?

	/// A dragged launcher bar stays wholly inside its screen's usable area (DEV-1335). It's where
	/// the person put it only while this bar is open: the next one opens at `launcherFrame` again,
	/// as every bar does. A Little Arx showing a page moves as it always has.
	private func keepLauncherOnScreen() {
		guard commandOnly, let visible = screen?.visibleFrame else { return }

		let clamped = Self.launcherFrameOnScreen(frame, visible: visible)
		guard clamped != frame else { return }
		setFrame(clamped, display: true, animate: false)
	}

	/// `frame` moved the least way to lie wholly inside `visible`; a bar larger than it keeps its
	/// top-left corner inside.
	internal static func launcherFrameOnScreen(
		_ frame: NSRect,
		visible: NSRect
	) -> NSRect {
		let x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
		let top = max(min(frame.maxY, visible.maxY), min(visible.maxY, visible.minY + frame.height))
		return .init(x: x, y: top - frame.height, width: frame.width, height: frame.height)
	}

	/// Where the bar opens, inside the screen's usable area. It grows downward from
	/// its top edge as results appear, so `center` only places the top of the bar.
	internal static func launcherFrame(
		position: LittleArxLauncherPosition,
		size: NSSize,
		visible: NSRect,
		margin: CGFloat = 12
	) -> NSRect {
		let x: CGFloat
		switch position {
		case .topRight: x = visible.maxX - size.width - margin
		case .topLeft: x = visible.minX + margin
		case .topCenter, .center: x = visible.midX - size.width / 2
		}
		let y = position == .center
		? visible.midY
		: visible.maxY - size.height - margin
		return .init(x: x, y: y, width: size.width, height: size.height)
	}

	/// Where a tab dropped outside every window opens (DEV-793): its toolbar under the pointer,
	/// centered on it, and the whole window inside the screen's usable area.
	internal static func droppedFrame(
		at point: CGPoint,
		size: NSSize,
		visible: NSRect,
		toolbarInset: CGFloat = 20
	) -> NSRect {
		let x = min(max(point.x - size.width / 2, visible.minX), max(visible.minX, visible.maxX - size.width))
		let top = min(max(point.y + toolbarInset, visible.minY + size.height), visible.maxY)
		return .init(x: x, y: top - size.height, width: size.width, height: size.height)
	}

	private static var launcherWidth: CGFloat {
		BrowserMetrics.LittleArx.Launcher.width + 2 * BrowserMetrics.LittleArx.Launcher.panelPadding
	}

	internal var minimumBrowserContentSize: NSSize {
		commandOnly ? BrowserWindowSize.commandMinimum : BrowserWindowSize.littleMinimum
	}

	internal func updatePresentation(commandOnly: Bool) {
		guard self.commandOnly != commandOnly else { return }
		self.commandOnly = commandOnly
		styleMask = commandOnly ? Self.commandStyle : Self.browserStyle

		// The launcher becoming a window stops following the person from Space to Space. Page PiP
		// and page full screen keep theirs until they end, and put this one back then.
		if !isPictureInPicture, !isPageFullScreen {
			collectionBehavior = Self.behavior(commandOnly: commandOnly)
		}
		titleVisibility = .hidden
		titlebarAppearsTransparent = true
		contentMinSize = minimumBrowserContentSize
		(contentView as? any BrowserWindowContent)?.setMinimumSize(minimumBrowserContentSize)

		guard !commandOnly else { return }
		let available = screen?.visibleFrame ?? frame
		resizeContent(to: .init(
			width: min(800, available.width - 40),
			height: min(620, available.height - 60)
		))
	}

	internal func fitCommandBar(height: CGFloat) {
		guard commandOnly, height > 0 else { return }
		resizeContent(to: .init(width: frame.width, height: ceil(height)))
	}

	private func resizeContent(to size: NSSize) {
		let frameSize = frameRect(forContentRect: .init(origin: .zero, size: size)).size
		guard frame.size != frameSize else { return }
		let available = screen?.visibleFrame ?? frame

		// Stays on screen when a bar in a corner expands into a browser window.
		let destination = NSRect(
			x: max(available.minX, min(frame.midX - frameSize.width / 2, available.maxX - frameSize.width)),
			y: max(available.minY, frame.maxY - frameSize.height),
			width: frameSize.width,
			height: frameSize.height
		)
		setFrame(destination, display: true, animate: false)
		invalidateShadow()
	}

	internal override var canBecomeKey: Bool { true }

	internal override func sendEvent(_ event: NSEvent) {
		let header = WindowControlDrag.Header(
			height: BrowserMetrics.LittleArx.toolbarHeight,
			isHidden: commandOnly || isPageFullScreen || isPageFullScreenTransitioning
		)
		let handles = controlDrag.filter(
			event,
			in: self,
			header: header,
			send: { super.sendEvent($0) },
			move: { event, start in

				// As Page PiP it moves and settles at a corner; otherwise it follows the mouse.
				if let mover = pictureInPictureMover {
					mover.track(event, from: start)
				} else {
					WindowControlDrag.follow(self, from: start)
				}
			}
		)
		if handles { super.sendEvent(event) }
	}

	internal override func close() {
		// Closing it as Page PiP keeps the size for the site, as Page PiP's own window does.
		if let restoration = pictureInPictureRestoration {
			PagePictureInPictureSizes.remember(frame.size, for: restoration.siteKey)
		}
		pictureInPictureMover?.invalidate()
		pictureInPictureMover = nil
		if let launcherMoveObserver { NotificationCenter.default.removeObserver(launcherMoveObserver) }
		launcherMoveObserver = nil
		super.close()
	}
}

// MARK: - Page PiP

extension LittleArxPanel {
	fileprivate struct PictureInPictureRestoration {
		internal let frame: NSRect
		internal let siteKey: String?
	}

	/// Whether the window is Page PiP now (DEV-1112).
	internal var isPictureInPicture: Bool { pictureInPictureRestoration != nil }

	/// Turns the window into Page PiP or back into Little Arx (DEV-1112), keeping its page view
	/// and the engine's page: only the window changes. As Page PiP it's borderless, on every
	/// Space and over full-screen apps, at the corner Page PiP last rested at and the size it last
	/// had for the site; back in Little Arx it takes its own frame again.
	internal func updatePictureInPicture(
		_ isPictureInPicture: Bool,
		siteKey: String?
	) {
		pendingPictureInPicture = nil
		if isPictureInPicture, pictureInPictureRestoration == nil {
			guard !commandOnly else { return }
			guard !isPageFullScreen, !isPageFullScreenTransitioning else {
				pendingPictureInPicture = .some(siteKey)
				return
			}

			// Automatic PiP floats a call whose minimised window left the screen (DEV-1246).
			if isMiniaturized { deminiaturize(nil) }
			pictureInPictureRestoration = .init(frame: frame, siteKey: siteKey)
			styleMask = [.borderless, .resizable, .nonactivatingPanel]
			collectionBehavior = PagePictureInPicturePanel.collectionBehavior
			setMinimumContentSize(PagePictureInPicturePanel.minimumSize)
			let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
			let size = PagePictureInPicturePanel.fitted(
				PagePictureInPictureSizes.size(for: siteKey) ?? PagePictureInPicturePanel.defaultSize,
				in: visible
			)
			let corner = PagePictureInPictureMotion.rememberedCorner()
			setFrame(
				.init(origin: PagePictureInPictureMotion.origin(of: corner, size: size, in: visible), size: size),
				display: true
			)
			hasShadow = true
			invalidateShadow()
			pictureInPictureMover = .init(window: self, corner: corner)
			if !isVisible { orderFrontRegardless() }

		} else if !isPictureInPicture, let restoration = pictureInPictureRestoration {
			PagePictureInPictureSizes.remember(frame.size, for: restoration.siteKey)
			pictureInPictureMover?.invalidate()
			pictureInPictureMover = nil
			pictureInPictureRestoration = nil
			styleMask = Self.browserStyle
			titleVisibility = .hidden
			titlebarAppearsTransparent = true

			// Back in Little Arx, it stays on the Space it's on now (DEV-1227).
			collectionBehavior = Self.windowBehavior
			setMinimumContentSize(minimumBrowserContentSize)
			setFrame(restoration.frame, display: true)
			invalidateShadow()
		}
	}

	private func setMinimumContentSize(_ size: NSSize) {
		contentMinSize = size
		(contentView as? any BrowserWindowContent)?.setMinimumSize(size)
	}
}

// MARK: - Page full screen

extension LittleArxPanel {
	fileprivate struct PageFullScreenRestoration {
		internal let level: NSWindow.Level
		internal let collectionBehavior: NSWindow.CollectionBehavior
	}

	/// DEV-949. Whether a page in HTML full screen has (or is taking) the panel's own macOS
	/// full-screen Space.
	internal var isPageFullScreen: Bool { pageFullScreenRestoration != nil }

	/// Gives the panel a macOS full-screen Space of its own, as a browser window gets, with only
	/// its page. That brings Arx forward and switches Spaces: for its duration the panel is a
	/// full-screen primary window at the normal level. It stays non-activating, since AppKit
	/// doesn't carry that style's change to the window server for a live panel, and a panel
	/// already takes the keyboard without activating Arx. Waits while a transition is in
	/// progress; the panel's delegate reports its end (`pageFullScreenTransitionEnded`).
	internal func enterPageFullScreen() {
		guard
			!commandOnly,
			// Page PiP floats instead (DEV-1112).
			pictureInPictureRestoration == nil,
			pageFullScreenRestoration == nil,
			!isPageFullScreenTransitioning,
			!styleMask.contains(.fullScreen)
		else { return }

		pageFullScreenRestoration = .init(
			level: level,
			collectionBehavior: collectionBehavior
		)
		collectionBehavior = [.managed, .fullScreenPrimary]
		level = .normal
		NSApplication.shared.activate(ignoringOtherApps: true)
		makeKeyAndOrderFront(nil)
		isPageFullScreenTransitioning = true
		toggleFullScreen(nil)
	}

	/// Leaves the panel's full-screen Space; it becomes the panel it was once the exit ends.
	internal func exitPageFullScreen() {
		guard pageFullScreenRestoration != nil, !isPageFullScreenTransitioning else { return }
		guard styleMask.contains(.fullScreen) else { return restorePageFullScreen() }

		isPageFullScreenTransitioning = true
		toggleFullScreen(nil)
	}

	/// The panel's delegate saw a full-screen transition end, or fail. Out of full screen, the
	/// panel is put back as it was.
	internal func pageFullScreenTransitionEnded() {
		isPageFullScreenTransitioning = false
		if pageFullScreenRestoration != nil, !styleMask.contains(.fullScreen) { restorePageFullScreen() }

		// Page PiP asked for while full screen ended starts now (DEV-1112).
		if let siteKey = pendingPictureInPicture, !isPageFullScreen {
			updatePictureInPicture(true, siteKey: siteKey)
		}
	}

	private func restorePageFullScreen() {
		guard let restoration = pageFullScreenRestoration else { return }

		pageFullScreenRestoration = nil
		collectionBehavior = restoration.collectionBehavior
		level = restoration.level
		invalidateShadow()
	}
}
