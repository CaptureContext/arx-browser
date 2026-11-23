import AppKit
import AppUI
import BrowserEngineClient
import SwiftUI

/// An extension's action popup in a small window of its own (DEV-1316), as Settings' sheets look:
/// the window's own background, a header with the raised Close tile and the extension's name, and
/// the popup's page under it at the size the page asks for. Dragging the header moves it.
///
/// The engine places it where the popover's arrow would have pointed, as a child window of the
/// window it was opened from, so it stays above that window (clicking the page or the sidebar
/// doesn't send it behind), moves with it between OS workspaces and into full screen, and goes
/// when Arx hides. The engine shows it, gives it the keyboard, keeps it the page's size and closes
/// it: on Close, on Escape the page doesn't take, on the extension's `window.close()`, with the
/// page it was opened for, and on losing focus as ``closing`` says.
///
/// Above its window it would cover what that window shows in its content, so it steps aside,
/// faded out and passing clicks through, while the window shows its command bar (``stepsAside``,
/// set by `BrowserWindow`) or a sheet.
@MainActor
internal final class ExtensionPopupPanel: NSPanel {
	/// How a popup's window answers losing focus. It stays open (Max's reference
	/// for DEV-1316): clicking the page behind it, a file chooser, a sign-in sheet or switching
	/// to another app for a moment doesn't close it. The engine also takes `.unlessMoved` (closes
	/// unless the person moved it) and `.onFocusLoss` (Chrome's popup).
	internal static let closing: BrowserExtensionPopupWindows.Closing = .staysOpen

	/// Its window identifier, which the app menu's commands skip: it holds an extension's popup,
	/// not a browser window.
	internal static let identifier: String = "extension-popup"

	/// The header's height, above the popup's page.
	internal static let headerHeight: CGFloat = ArxHeaderBarMetrics.height

	/// The windows the engine asks for.
	internal static var windows: BrowserExtensionPopupWindows {
		.init(
			closing: closing,
			makeWindow: { view, title, icon, size in
				ExtensionPopupPanel(page: view, title: title, icon: icon, size: size)
			},
			resizeWindow: { window, size in (window as? ExtensionPopupPanel)?.resize(page: size) }
		)
	}

	internal init(
		page: NSView,
		title: String,
		icon: Data?,
		size: CGSize
	) {
		let frame = NSRect(x: 0, y: 0, width: size.width, height: size.height + Self.headerHeight)
		super.init(
			contentRect: frame,
			styleMask: [.titled, .closable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		self.title = title
		self.identifier = .init(Self.identifier)
		self.titleVisibility = .hidden
		self.titlebarAppearsTransparent = true
		self.isReleasedWhenClosed = false
		self.hidesOnDeactivate = false
		self.becomesKeyOnlyIfNeeded = false
		self.isExcludedFromWindowsMenu = true
		self.animationBehavior = .utilityWindow
		self.backgroundColor = .windowBackgroundColor
		self.collectionBehavior = [.fullScreenAuxiliary]
		for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
			standardWindowButton(button)?.isHidden = true
		}

		let container = NSView(frame: frame)
		page.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
		page.autoresizingMask = [.width, .height]
		container.addSubview(page)

		let header = NSHostingView(rootView: ExtensionPopupHeader(title: title, icon: icon) { [weak self] in
			self?.performClose(nil)
		})
		header.sizingOptions = []

		// The header sits under the window's transparent title bar, whose height a hosting view
		// would take as a top safe-area inset and lay the row out below: the row then centred in
		// the band's lower part and touched the page (Max's first look). The band is all the
		// header's own, as for Arx's floating panels.
		header.safeAreaRegions = []
		header.frame = NSRect(x: 0, y: size.height, width: size.width, height: Self.headerHeight)
		header.autoresizingMask = [.width, .minYMargin]
		container.addSubview(header)
		contentView = container

		for name in [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
			sheetObservers.append(NotificationCenter.default.addObserver(
				forName: name,
				object: nil,
				queue: .main
			) { [weak self] notification in
				let window = notification.object as? NSWindow
				MainActor.assumeIsolated { self?.parentSheetChanged(window) }
			})
		}
	}

	/// Whether the window it was opened from shows its command bar, which the popup would cover.
	internal var stepsAside: Bool = false {
		didSet { updateStepAside() }
	}

	/// Whether it's faded out of the way now.
	internal private(set) var isSteppedAside: Bool = false

	private var sheetObservers: [any NSObjectProtocol] = []

	internal override func close() {
		for observer in sheetObservers { NotificationCenter.default.removeObserver(observer) }
		sheetObservers = []
		super.close()
	}

	private func parentSheetChanged(_ window: NSWindow?) {
		guard let window, window === parent else { return }

		updateStepAside()
	}

	/// Faded out and passing clicks through while its window shows the command bar or a sheet, so
	/// it never covers them; back as soon as they go.
	private func updateStepAside() {
		let aside = stepsAside || parent?.attachedSheet != nil
		guard aside != isSteppedAside else { return }

		isSteppedAside = aside
		alphaValue = aside ? 0 : 1
		ignoresMouseEvents = aside
		if aside, isKeyWindow { parent?.makeKey() }
	}

	internal override var canBecomeKey: Bool { true }
	internal override var canBecomeMain: Bool { false }

	/// Makes the page `size` points, keeping the window's top-left corner.
	internal func resize(page size: CGSize) {
		let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
		setContentSize(NSSize(width: size.width, height: size.height + Self.headerHeight))
		setFrameTopLeftPoint(topLeft)
	}
}

/// A Settings sheet's header for an extension's popup: the raised Close tile, the extension's own
/// icon, as its site menu tile draws it (its letter when it has none), then its name, in the order
/// every Arx header bar has. The window is where an extension may ask for passwords or payment
/// details, so the icon and name say whose window it is; they come from the engine, and the page
/// inside can't change them. The icon is decorative: the name already says it.
///
/// Close doesn't answer Escape here: the page gets Escape first, and the engine closes the popup on
/// one it doesn't take, as Chrome does.
internal struct ExtensionPopupHeader: View {
	let title: String
	let icon: Data?
	let close: () -> Void

	var body: some View {
		HStack(spacing: ArxHeaderBarMetrics.spacing) {
			ArxHeaderIconButton(String.localized(.appUI.common.close), systemImage: "xmark", action: close)
			ExtensionIconTile(name: title, icon: icon, side: ArxHeaderBarMetrics.iconSize)
				.accessibilityHidden(true)
			Text(verbatim: title)
				.font(ArxHeaderBarMetrics.titleFont)
				.lineLimit(1)
				.truncationMode(.tail)
				.accessibilityAddTraits(.isHeader)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
		.controlSize(.regular)
		.arxRaisedControlHeight(ArxHeaderBarMetrics.controlHeight)
		.padding(.horizontal, ArxHeaderBarMetrics.horizontalPadding)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background {
			// The header moves the window, as Little Arx's does.
			Color.clear
				.contentShape(.rect)
				.gesture(WindowDragGesture())
		}
		.background(ArxModalMetrics.background)
	}
}
