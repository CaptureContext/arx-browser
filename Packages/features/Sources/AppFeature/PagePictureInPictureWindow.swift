import AppKit
import AppUI
import BrowserCore
import BrowserSurfaceClient
import CommandBarFeature
import SwiftUI
import _ComposableArchitecture

/// Page PiP's floating window (DEV-950, DEV-1105): Little Arx's window around a tab's live page,
/// with Return to Tab where the window's buttons would be. It floats over other apps and
/// full-screen apps, joins every macOS desktop Space as video PiP does, and rests at a screen
/// corner 16 points inside its visible frame. Dragging its header moves it; let go, it's thrown
/// to the nearest corner where its velocity carries it (``PagePictureInPictureMotion``). It
/// takes clicks and the keyboard without bringing Arx's other windows forward.
@MainActor
internal final class PagePictureInPicturePanel: NSPanel, PagePictureInPictureMoving {
	/// The header and a page of at least 300 × 156: the header's controls, Return to Tab, Back,
	/// Forward and the URL bar with its profile and actions, need 258 points.
	internal static let minimumSize: NSSize = .init(
		width: 300,
		height: 156 + BrowserMetrics.LittleArx.toolbarHeight + BrowserMetrics.LittleArx.pageInset
	)
	internal static let defaultSize: NSSize = .init(
		width: 480,
		height: 300 + BrowserMetrics.LittleArx.toolbarHeight + BrowserMetrics.LittleArx.pageInset
	)

	/// Little Arx's window corners, concentric with its page's.
	internal static let cornerRadius: CGFloat = BrowserMetrics.LittleArx.cornerRadius

	/// Its window identifier, which the app menu's commands skip: it holds a page, not a
	/// browser window.
	internal static let identifier: String = "page-picture-in-picture"

	/// Page PiP follows the person onto every Space, other apps' full-screen ones included, as
	/// video PiP does (DEV-852). Little Arx takes it while it's Page PiP (DEV-1112), and only then
	/// (DEV-1227).
	internal static let collectionBehavior: NSWindow.CollectionBehavior = [
		.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications,
	]

	/// The site whose size the window remembers.
	internal let siteKey: String?

	/// Drags, throws and settles the window at its corners.
	internal private(set) var pictureInPictureMover: PagePictureInPictureMover?

	/// A drag from the header's controls moves the window too, as Little Arx's does (DEV-1247).
	private var controlDrag = WindowControlDrag()

	internal init(
		contentSize: NSSize,
		on screen: NSScreen?,
		siteKey: String?,
		corner: PagePictureInPictureMotion.Corner = PagePictureInPictureMotion.rememberedCorner()
	) {
		self.siteKey = siteKey
		let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .init(x: 0, y: 0, width: 1280, height: 800)
		let size = Self.fitted(contentSize, in: visible)
		super.init(
			contentRect: .init(
				origin: PagePictureInPictureMotion.origin(of: corner, size: size, in: visible),
				size: size
			),
			styleMask: [.borderless, .resizable, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		self.isReleasedWhenClosed = false
		self.isFloatingPanel = true
		self.hidesOnDeactivate = false
		self.becomesKeyOnlyIfNeeded = false
		self.level = .floating
		self.collectionBehavior = Self.collectionBehavior
		self.minSize = Self.minimumSize
		self.isOpaque = false
		self.backgroundColor = .clear
		self.hasShadow = true
		self.isMovableByWindowBackground = false
		self.animationBehavior = .utilityWindow
		self.pictureInPictureMover = .init(window: self, corner: corner)
	}

	internal override var canBecomeKey: Bool { true }
	internal override var canBecomeMain: Bool { false }

	internal override func sendEvent(_ event: NSEvent) {
		let handles = controlDrag.filter(
			event,
			in: self,
			header: .init(height: BrowserMetrics.LittleArx.toolbarHeight),
			send: { super.sendEvent($0) },
			move: { [pictureInPictureMover] event, start in pictureInPictureMover?.track(event, from: start) }
		)
		if handles { super.sendEvent(event) }
	}

	internal override func close() {
		pictureInPictureMover?.invalidate()
		pictureInPictureMover = nil
		super.close()
	}

	/// Shows `content` in the window, with the window's minimum size as its own. A plain hosting
	/// view publishes its content's minimum instead, which is only the header's: a resize could
	/// then shrink the window to its header and the page to nothing.
	internal func show(_ content: some View) {
		contentView = BrowserHostingView(rootView: content, minimumSize: Self.minimumSize)
	}

	/// The size within the screen: at least the minimum, at most 80% of each side.
	internal static func fitted(
		_ size: NSSize,
		in visible: NSRect
	) -> NSSize {
		.init(
			width: min(max(size.width, minimumSize.width), max(minimumSize.width, visible.width * 0.8)),
			height: min(max(size.height, minimumSize.height), max(minimumSize.height, visible.height * 0.8))
		)
	}
}

/// Page PiP's window content, reading the store for the floating tab.
internal struct PagePictureInPictureContent: View {
	internal let store: StoreOf<AppFeature>
	internal let tabID: BrowserCore.Tab.ID
	internal let windowID: UUID
	internal let surface: BrowserSurfaceClient

	internal var body: some View {
		let navigation = store.pagePictureInPicture?.navigation ?? .init()
		let commandBar = store.pagePictureInPictureCommandBar
		PagePictureInPictureView(
			tabID: tabID,
			surface: surface,
			url: navigation.url,
			isLoading: navigation.isLoading,
			profiles: store.state.pagePictureInPictureProfiles(),
			onSelectProfile: { store.send(.ui(.pagePictureInPictureSelectProfile($0))) },
			// The tab's space instead of its profile, where it has one (DEV-1184).
			spaces: PagePictureInPictureSpacesFeatureFlag.isOn() ? store.state.pagePictureInPictureSpaces() : nil,
			onSelectSpace: { store.send(.ui(.pagePictureInPictureMoveToSpace($0))) },
			onReturnToTab: { store.send(.ui(.closePagePictureInPicture(focusesTab: true))) },
			onBack: navigation.canGoBack ? { store.send(.ui(.pagePictureInPictureBack)) } : nil,
			onForward: navigation.canGoForward ? { store.send(.ui(.pagePictureInPictureForward)) } : nil,
			// Its address edits as the main window's (DEV-1124).
			onActivate: PagePictureInPictureAddressFeatureFlag.isOn()
			? { store.send(.ui(.editPagePictureInPictureAddress)) }
			: nil,
			onCopy: { store.send(.ui(.copyPagePictureInPictureURL)) },
			// The agent indicator, its Stop, and the link toast stay with the page.
			notice: pageNotices(store: store, windowID: windowID).content(tabID),
			// The page's media visibility follows it, so automatic PiP doesn't take a floating
			// video for a hidden one. Reported for the window it left, which Arx keeps.
			onVisibility: { store.send(.event(.mediaSurfaceVisibility(windowID, $0))) }
		)

		// Over the URL bar, as the main window edits its address.
		.commandBarPresentation(
			isPresented: commandBar.isPresented,
			anchoredToURL: true,
			urlFieldText: commandBar.query,
			urlFieldShowsAgentHint: commandBar.showsAgentHint,
			onDismiss: { store.send(.pagePictureInPictureCommandBar(.ui(.dismissed))) }
		) { maximumHeight in
			CommandBarView(
				store: store.scope(state: \.pagePictureInPictureCommandBar, action: \.pagePictureInPictureCommandBar),
				style: .urlField,
				maximumResultsHeight: maximumHeight
			)
		}

		// Moving the tab to another profile's space asks over the page first (DEV-1184).
		.profileMoveConfirmationOverlay(
			store.state.pagePictureInPictureProfileMoveConfirmation(),
			onCancel: { store.send(.ui(.cancelPagePictureInPictureSpaceMove)) },
			onConfirm: { store.send(.ui(.confirmPagePictureInPictureSpaceMove)) }
		)
		.browserChromeAppearance(store.settings.chromeAppearance)

		// The profile's Show Full URL, as Little Arx's address shows it.
		.environment(\.showsFullURL, profile?.showsWholeURL ?? false)
	}

	/// The profile the tab's page belongs to, as Little Arx's profile picker shows it: a space's
	/// tab, a private window's, Little Arx's or a Peek's.
	private var profile: BrowserCore.Profile? {
		let window = windowID == store.main.id ? store.main : store.windows[id: windowID]
		let tab = store.workspace.tabs[id: tabID]
		?? window?.sidebar.organization.tabs[id: tabID]
		?? store.littleWindows.first { $0.tab.id == tabID }?.tab
		?? store.peeks.first { $0.tab.id == tabID }?.tab
		guard let profileID = tab?.profileID else { return nil }

		return store.workspace.profiles[id: profileID]
		?? window?.sidebar.organization.profiles[id: profileID]
	}
}

/// What Page PiP's window shows (DEV-1105): Little Arx's window, its header with Return to Tab
/// where the window's buttons would be, Back and Forward, the space picker (DEV-1184) or Little
/// Arx's profile picker, and no "Open in", above the page in Little Arx's card. The header is outside the page, which keeps
/// every click.
internal struct PagePictureInPictureView: View {
	internal let tabID: BrowserCore.Tab.ID
	internal let surface: BrowserSurfaceClient
	internal let url: URL?
	internal let isLoading: Bool
	internal let profiles: (options: [LittleWindowProfilePicker.Option], current: BrowserCore.Profile.ID?)
	internal let onSelectProfile: (BrowserCore.Profile.ID) -> Void

	/// The space picker in the profile picker's place (DEV-1184); `nil` keeps the profile picker:
	/// with the feature flag off, or for a page that has no space.
	internal var spaces: (options: [PagePictureInPictureSpacePicker.Option], current: Space.ID?)? = nil
	internal var onSelectSpace: (Space.ID) -> Void = { _ in }
	internal let onReturnToTab: () -> Void
	internal let onBack: (() -> Void)?
	internal let onForward: (() -> Void)?

	/// Edits the address on a click (DEV-1124); `nil` while the feature flag is off.
	internal var onActivate: (() -> Void)? = nil
	internal let onCopy: () -> Void
	internal let notice: AnyView?
	internal let onVisibility: @MainActor @Sendable (BrowserSurfaceVisibility) -> Void

	internal var body: some View {
		ZStack {
			BrowserChromeBackground(textured: true)
			VStack(spacing: 0) {
				PagePictureInPictureHeader(
					url: url,
					isLoading: isLoading,
					onReturnToTab: onReturnToTab,
					onBack: onBack,
					onForward: onForward,
					onActivate: onActivate,
					onCopy: onCopy,
					profilePicker: {
						if let spaces {
							PagePictureInPictureSpacePicker(
								options: spaces.options,
								currentID: spaces.current,
								onSelect: onSelectSpace
							)
						} else {
							LittleWindowProfilePicker(
								options: profiles.options,
								currentID: profiles.current,
								onSelect: onSelectProfile
							)
						}
					},
					dragArea: { PagePictureInPictureDragArea() }
				)
				ZStack(alignment: .top) {
					BrowserSurface(tabID: tabID, client: surface)
					if let notice {
						notice
					}
				}

				// A card on the chrome, as Little Arx's page.
				.browserPageCard(cornerRadius: BrowserMetrics.LittleArx.pageCornerRadius)
				.padding([.horizontal, .bottom], BrowserMetrics.LittleArx.pageInset)
			}
		}
		.clipShape(.rect(cornerRadius: PagePictureInPicturePanel.cornerRadius, style: .continuous))
		.environment(\.browserSurfaceVisibilityObserver, .init(report: onVisibility))
		.ignoresSafeArea()
	}
}

/// Where a drag moves Page PiP's window and throws it to a corner.
internal struct PagePictureInPictureDragArea: NSViewRepresentable {
	internal func makeNSView(context: Context) -> DragView { DragView() }

	internal func updateNSView(
		_ view: DragView,
		context: Context
	) {}

	internal final class DragView: NSView {
		internal override var mouseDownCanMoveWindow: Bool { false }

		internal override func mouseDown(with event: NSEvent) {
			(window as? any PagePictureInPictureMoving)?.pictureInPictureMover?.track(event)
		}
	}
}

/// What a tab shows while its page floats in Page PiP (DEV-950).
internal struct PagePictureInPicturePlaceholder: View {
	internal let onBackToTab: () -> Void

	internal var body: some View {
		VStack(spacing: 12) {
			Image(systemName: "pip")
				.font(.system(size: 36, weight: .regular))
				.foregroundStyle(BrowserTheme.secondary)
				.accessibilityHidden(true)
			Text(localized: .appUI.pagePicture.playing)
				.font(.system(size: 15, weight: .semibold))
				.foregroundStyle(BrowserTheme.text)
			Button(String.localized(.appUI.pagePicture.backToTab), action: onBackToTab)
				.buttonStyle(.arxRaised(size: .regular))
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(BrowserTheme.page)
		.accessibilityElement(children: .contain)
	}
}

/// Page PiP's sizes per site, kept on this Mac (DEV-950).
internal enum PagePictureInPictureSizes {
	private static let key: String = "ArxPagePictureInPictureSizes"

	internal static func size(
		for site: String?,
		defaults: UserDefaults = .standard
	) -> NSSize? {
		guard
			let site,
			let sizes = defaults.dictionary(forKey: key) as? [String: [Double]],
			let size = sizes[site],
			size.count == 2
		else { return nil }

		return .init(width: size[0], height: size[1])
	}

	internal static func remember(
		_ size: NSSize,
		for site: String?,
		defaults: UserDefaults = .standard
	) {
		guard let site else { return }
		var sizes = defaults.dictionary(forKey: key) as? [String: [Double]] ?? [:]
		sizes[site] = [Double(size.width), Double(size.height)]
		defaults.set(sizes, forKey: key)
	}
}
