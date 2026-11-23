import BrowserCore
import SwiftUI

/// A button in a local page's developer header (DEV-733).
public enum DeveloperHeaderAction: Equatable, Sendable {
	case copyURL
	case captureViewport
	case captureRegion

	/// The device capture popover's Capture (DEV-757).
	case captureDevice(DeviceCaptureStyle)
	case toggleDeveloperTools
	case console
	case network
	case inspectElement
	case split(SplitDropEdge)

	/// The header was clicked: its pane becomes the active one.
	case focus
}

/// A developer header over a local development page (`localhost`, `*.test`…) while
/// developer mode is on: the whole address in monospace with the site menu, then copy,
/// capture, DevTools, Console, Network, Inspect Element and a split menu (DEV-733).
public struct DeveloperHeader: View {
	public let url: URL?
	public let isActive: Bool
	public let send: (DeveloperHeaderAction) -> Void

	/// In a split, the pane's close button ends the header.
	public let onClose: (() -> Void)?

	/// With the `ARX_DEVICE_CAPTURE` feature flag on, the style the device capture popover opens
	/// with; nil keeps the Capture menu (DEV-757).
	public let deviceCapture: DeviceCaptureStyle?

	@Environment(\.siteMenu)
	private var siteMenu

	@SwiftUI.State
	private var showsSiteMenu: Bool

	@SwiftUI.State
	private var showsDeviceCapture: Bool

	public init(
		url: URL?,
		isActive: Bool,
		send: @escaping (DeveloperHeaderAction) -> Void,
		onClose: (() -> Void)? = nil,
		deviceCapture: DeviceCaptureStyle? = nil
	) {
		self.url = url
		self.isActive = isActive
		self.send = send
		self.onClose = onClose
		self.deviceCapture = deviceCapture
		self._showsSiteMenu = .init(initialValue: false)
		self._showsDeviceCapture = .init(initialValue: false)
	}

	public var body: some View {
		HStack(spacing: 2) {
			siteMenuButton
			Text(url?.absoluteString ?? "")
				.font(.system(size: BrowserMetrics.PaneHeader.hostFontSize - 1).monospaced())
				.foregroundStyle(BrowserTheme.text)
				.lineLimit(1)
				.truncationMode(.middle)
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 4)
			Button { send(.copyURL) } label: { FigmaSymbol(.link, pointSize: BrowserMetrics.PaneHeader.symbolSize) }
				.help(String.localized(.appUI.developer.headerCopyURL))
				.accessibilityLabel(String.localized(.appUI.developer.headerCopyURL))
			if let deviceCapture {
				deviceCaptureButton(deviceCapture)
			} else {
				captureMenu
			}
			button(.toggleDeveloperTools, "hammer", .appUI.developer.headerDeveloperTools)
			button(.console, "terminal", .appUI.developer.headerConsole)
			button(.network, "network", .appUI.developer.headerNetwork)
			button(.inspectElement, "scope", .appUI.developer.headerInspect)
			splitMenu
			if let onClose {
				Button(action: onClose) { Image(systemName: "xmark") }
					.help(String.localized(.appUI.split.closePane))
					.accessibilityLabel(String.localized(.appUI.split.closePane))
			}
		}
		.buttonStyle(BrowserToolbarButtonStyle())
		.menuStyle(.button)
		.menuIndicator(.hidden)
		.font(.system(size: BrowserMetrics.PaneHeader.symbolSize, weight: .medium))
		.foregroundStyle(BrowserTheme.secondary)
		.padding(.horizontal, BrowserMetrics.PaneHeader.horizontalPadding)
		.frame(height: BrowserMetrics.PaneHeader.developerHeight)
		.contentShape(.rect)
		.onTapGesture { send(.focus) }
		.accessibilityElement(children: .contain)
		.accessibilityLabel(String.localized(.appUI.developer.headerTitle))
	}

	private func button(
		_ action: DeveloperHeaderAction,
		_ symbol: String,
		_ resource: _XCStringResource
	) -> some View {
		let title = String.localized(resource)
		return Button { send(action) } label: { Image(systemName: symbol) }
			.help(title)
			.accessibilityLabel(title)
	}

	private var siteMenuButton: some View {
		Button {
			if !isActive { send(.focus) }
			showsSiteMenu.toggle()
		} label: {
			FigmaSymbol(.siteMenu, pointSize: BrowserMetrics.PaneHeader.symbolSize)
		}
		.help(String.localized(.appUI.url.siteInformation))
		.accessibilityLabel(String.localized(.appUI.url.siteInformation))
		.popover(isPresented: $showsSiteMenu, arrowEdge: .bottom) {
			if let menu = siteMenu?.menu {
				SiteMenuPanel(menu: menu, send: siteMenu?.send ?? { @MainActor @Sendable _ in }) { showsSiteMenu = false }
			} else {
				ProgressView()
					.controlSize(.small)
					.padding(18)
					.frame(width: 300)
			}
		}
		.onChange(of: url) { showsSiteMenu = false }
		.onChange(of: showsSiteMenu) { _, isShown in
			siteMenu?.send(isShown ? .opened : .closed)
		}
	}

	private var captureMenu: some View {
		Menu {
			Button(String.localized(.appUI.siteMenu.captureViewport)) { send(.captureViewport) }
			Button(String.localized(.appUI.siteMenu.captureRegion)) { send(.captureRegion) }
		} label: {
			Image(systemName: "camera.viewfinder")
		}
		.fixedSize()
		.help(String.localized(.appUI.developer.headerCapture))
		.accessibilityLabel(String.localized(.appUI.developer.headerCapture))
	}

	/// Opens the device capture popover; each of its captures closes it (DEV-757).
	private func deviceCaptureButton(_ style: DeviceCaptureStyle) -> some View {
		Button {
			if !isActive { send(.focus) }
			showsDeviceCapture.toggle()
		} label: {
			Image(systemName: "camera.viewfinder")
		}
		.help(String.localized(.appUI.developer.headerCapture))
		.accessibilityLabel(String.localized(.appUI.developer.headerCapture))
		.popover(isPresented: $showsDeviceCapture, arrowEdge: .bottom) {
			DeviceCapturePopover(style: style) { action in
				showsDeviceCapture = false
				send(action)
			}
		}
		.onChange(of: url) { showsDeviceCapture = false }
	}

	private var splitMenu: some View {
		Menu {
			Button(String.localized(.appUI.developer.headerSplitRight)) { send(.split(.trailing)) }
			Button(String.localized(.appUI.developer.headerSplitLeft)) { send(.split(.leading)) }
			Button(String.localized(.appUI.developer.headerSplitTop)) { send(.split(.top)) }
			Button(String.localized(.appUI.developer.headerSplitBottom)) { send(.split(.bottom)) }
		} label: {
			Image(systemName: "rectangle.split.2x1")
		}
		.fixedSize()
		.help(String.localized(.appUI.developer.headerSplit))
		.accessibilityLabel(String.localized(.appUI.developer.headerSplit))
	}
}
