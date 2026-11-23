import SwiftUI

/// A split pane header's copy-link and site-menu buttons (DEV-995), shown while the pane shows a
/// page, as the sidebar's address bar shows its own. The site menu acts on the selected pane, so
/// opening it from another pane selects that pane first.
public struct PaneHeaderActions: View {
	public let url: URL
	public let isActive: Bool

	/// Selects this pane.
	public let onActivate: () -> Void
	public let onCopy: () -> Void

	/// The pane's reading mode, when its page has an article to show (DEV-1028).
	public let readingMode: ReadingModeIndicator?

	@Environment(\.siteMenu)
	private var siteMenu

	@SwiftUI.State
	private var showsSiteMenu: Bool

	/// Counts copies, so each one restarts the link button's confirmation.
	@SwiftUI.State
	private var copyConfirmations: Int

	@SwiftUI.State
	private var isShowingCopied: Bool

	public init(
		url: URL,
		isActive: Bool,
		onActivate: @escaping () -> Void,
		onCopy: @escaping () -> Void,
		readingMode: ReadingModeIndicator? = nil
	) {
		self.url = url
		self.isActive = isActive
		self.onActivate = onActivate
		self.onCopy = onCopy
		self.readingMode = readingMode
		self._showsSiteMenu = .init(initialValue: false)
		self._copyConfirmations = .init(initialValue: 0)
		self._isShowingCopied = .init(initialValue: false)
	}

	public var body: some View {
		HStack(spacing: 2) {
			if let readingMode {
				Button {
					if !isActive { onActivate() }
					readingMode.toggle()
				} label: {
					Image(systemName: readingMode.symbol)
						.foregroundStyle(readingMode.isReading ? AnyShapeStyle(BrowserTheme.accent) : AnyShapeStyle(.foreground))
				}
				.help(readingMode.title)
				.accessibilityLabel(readingMode.title)
				.accessibilityAddTraits(readingMode.isReading ? .isSelected : [])
			}
			Button {
				onCopy()
				copyConfirmations += 1
			} label: {
				// A check confirms the copy, as the sidebar's link button does.
				if isShowingCopied {
					Image(systemName: "checkmark")
				} else {
					FigmaSymbol(.link, pointSize: BrowserMetrics.PaneHeader.symbolSize)
				}
			}
			.help(String.localized(.appUI.url.copy))
			.accessibilityLabel(String.localized(.appUI.url.copy))
			Button {
				if !isActive { onActivate() }
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
		}
		.onChange(of: url) { showsSiteMenu = false }
		.task(id: copyConfirmations) {
			guard copyConfirmations > 0 else { return }
			isShowingCopied = true
			do {
				try await Task.sleep(for: BrowserMetrics.URLBar.copiedDuration)
			} catch {
				return
			}
			isShowingCopied = false
		}
		.onChange(of: showsSiteMenu) { _, isShown in
			siteMenu?.send(isShown ? .opened : .closed)
		}
	}
}
