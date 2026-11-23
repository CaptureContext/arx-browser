import AppUI
import BrowserCore
import BrowserSurfaceClient
import SwiftUI
import _ComposableArchitecture

public struct ViewerItemView: View {
	public let store: StoreOf<ViewerItemFeature>
	private let surface: BrowserSurfaceClient
	private let onFocus: @MainActor () -> Void
	private let isFocused: Bool

	/// Hosts with their own load indicator turn off the in-page spinner.
	private let showsLoading: Bool

	/// A header sits right above the page, which meets it squarely (DEV-786).
	private let squaresTopCorners: Bool

	@Environment(\.browserPageOverlay)
	private var pageOverlay

	@Environment(\.browserPageNotice)
	private var pageNotice

	@Environment(\.suppressedBrowserTabs)
	private var suppressedTabs

	@Environment(\.browserChatTab)
	private var chatTab

	@Environment(\.browserTabPlaceholder)
	private var tabPlaceholder

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	/// Off while Peek is open over the window: the reader then leaves the keyboard alone.
	@Environment(\.browserSurfaceIsInteractive)
	private var isInteractive

	/// Off while the window's chrome is disabled, as under the command bar.
	@Environment(\.isEnabled)
	private var isEnabled

	public init(
		store: StoreOf<ViewerItemFeature>,
		surface: BrowserSurfaceClient,
		onFocus: @escaping @MainActor () -> Void = {},
		isFocused: Bool = true,
		showsLoading: Bool = true,
		squaresTopCorners: Bool = false
	) {
		self.store = store
		self.surface = surface
		self.onFocus = onFocus
		self.isFocused = isFocused
		self.showsLoading = showsLoading
		self.squaresTopCorners = squaresTopCorners
	}

	public var body: some View {
		ZStack {
			BrowserPageGround()
			if let tab = store.tab, tab.isChat {
				if let chatTab {
					chatTab.content(tab)
				}
			} else if let tab = store.tab {
				BrowserSurface(
					tabID: tab.id,
					client: surface,
					onFocus: onFocus,
					// Reading mode holds the keyboard while it covers the page (DEV-1028).
					isFocused: isFocused && store.reader == nil
				)
			} else {
				BrowserEmptyPage()
			}

			// A page lent to another window, such as Page PiP's (DEV-950), says where it is.
			if let tab = store.tab, suppressedTabs.contains(tab.id), let placeholder = tabPlaceholder?.content(tab.id) {
				placeholder
			}

			// A navigation that became a download, in a tab with no page of its own (DEV-1116).
			if let shown = store.navigation.download {
				BrowserDownloadingPage(
					filename: shown.filename,
					download: store.download ?? store.removedDownload.flatMap { $0.id == shown.id ? $0 : nil },
					isRemoved: store.download == nil && store.removedDownloadID == shown.id,
					message: store.downloadMessage
				) { action in
					store.send(.ui(.download(action)))
				}
				.background(BrowserTheme.page)
			}
			if store.navigation.download == nil, let failure = store.failure {
				VStack(spacing: 12) {
					Text(failure).textSelection(.enabled)
					if case let .localServerExpectsHTTP(httpURL) = store.navigation.failure {
						Button(String.localized(.appUI.viewer.openUnencrypted(httpURL.absoluteString))) {
							store.send(.ui(.openPlainHTTP))
						}
					}
					Button { store.send(.ui(.retry)) } label: { Image(systemName: "arrow.clockwise") }
						.help(String.localized(.appUI.viewer.retry))
				}
				.padding(20)
				.background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
			}

			// Reading mode covers the page without touching it (DEV-1028): closing it shows the
			// page as it was, scrolled where it was, with nothing reloaded.
			if let reader = store.reader, let tab = store.tab {
				ReaderOverlay(
					phase: reader,
					// As the page would, only while nothing else holds the keyboard over it, such
					// as the Find bar: closing it gives the keyboard back to the article.
					isFocused: isFocused && isInteractive && isEnabled && store.findQuery == nil,
					find: store.readerFind,
					onFind: { store.send(.ui(.readerFound(serial: $0, $1))) },
					onOpenLink: { store.send(.ui(.readerLinkOpened($0))) },
					onClose: { store.send(.ui(.readerClosed)) }
				)
				.transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
				.onDisappear {
					// Give the keyboard back to the page under it, unless something else holds it,
					// such as the Find bar that closed it.
					if store.tab?.id == tab.id, store.findQuery == nil, isFocused, isInteractive, isEnabled {
						surface.focus(tab.id)
					}
				}
			}

			// DEV-1009: Reload ends the page's renderer first (the engine does it for any reload
			// of a page that stopped answering).
			if store.asksAboutHang {
				UnresponsivePageCard(
					onWait: { store.send(.ui(.waitForPage)) },
					onReload: { store.send(.ui(.command(.reload))) }
				)
			}

			// In reading mode, Find searches the article (DEV-1066), below the reader's controls.
			if let query = store.findQuery {
				let searchesReader = store.reader != nil
				FindInPageBar(
					query: query,
					result: searchesReader ? store.readerFindResult : store.navigation.findResult,
					focusRequest: store.findFocusRequests,
					onChange: { store.send(.ui(.findChanged($0))) },
					onStep: { store.send(.ui(.findStepped(forward: $0))) },
					onDismiss: {
						store.send(.ui(.findDismissed))

						// The article takes the keyboard back itself once the bar has gone.
						if !searchesReader, let id = store.tab?.id { surface.focus(id) }
					}
				)
				.padding(BrowserMetrics.FindBar.inset)
				.padding(.top, searchesReader ? BrowserMetrics.FindBar.height + BrowserMetrics.FindBar.spacing : 0)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
			}
			if let percent = store.zoomBadge {
				ZoomBadge(percent: percent)
					.padding(BrowserMetrics.FindBar.inset)
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
					.allowsHitTesting(false)
					.transition(.opacity)
			}
			if showsLoading, store.navigation.isLoading {
				VStack {
					ProgressView()
						.controlSize(.small)
						.padding(10)
					Spacer()
				}
				.allowsHitTesting(false)
			}

			// A page lent to Peek shows its overlay there, not behind it.
			if let tab = store.tab, !suppressedTabs.contains(tab.id), let overlay = pageOverlay?.content(tab.id) {
				overlay
					.onDisappear {
						// Give the keyboard back to the page the overlay took it from.
						if store.tab?.id == tab.id, isFocused { surface.focus(tab.id) }
					}
			}
			if let tab = store.tab, !suppressedTabs.contains(tab.id), let notice = pageNotice?.content(tab.id) {
				notice
			}
		}
		.animation(.easeOut(duration: 0.2), value: store.zoomBadge == nil)
		.animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.24), value: store.reader == nil)
		.clipShape(BrowserMetrics.PageCard.viewportShape(squaresTopCorners: squaresTopCorners))
	}
}

/// The page's zoom, shown briefly at the top of the page after Zoom In, Zoom Out or
/// Actual Size (DEV-726).
private struct ZoomBadge: View {
	internal let percent: Int

	internal var body: some View {
		Label(String.localized(.appUI.viewer.zoomBadge(percent)), systemImage: "magnifyingglass")
			.font(.callout.monospacedDigit())
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
			.background(.regularMaterial, in: .capsule)
			.accessibilityElement(children: .combine)
			.accessibilityAddTraits(.updatesFrequently)
	}
}

/// What a chat tab shows in its pane (DEV-761). The app supplies the profile's chat; without it
/// a chat tab's pane stays empty.
public struct BrowserChatTabContent {
	public let content: @MainActor (BrowserCore.Tab) -> AnyView

	public init(content: @escaping @MainActor (BrowserCore.Tab) -> AnyView) {
		self.content = content
	}
}

extension EnvironmentValues {
	@Entry
	public var browserChatTab: BrowserChatTabContent? = nil
}
