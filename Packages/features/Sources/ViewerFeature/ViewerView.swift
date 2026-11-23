import AppUI
import BrowserCore
import BrowserSurfaceClient
import SwiftUI
import ViewerItemFeature
import _ComposableArchitecture

public struct ViewerView: View {
	public let store: StoreOf<ViewerFeature>
	private let surface: BrowserSurfaceClient
	private let onOpenEmptyPane: (UUID) -> Void

	/// A pane header's address was clicked: the command bar edits that pane's address (DEV-993).
	private let onEditAddress: (UUID) -> Void

	/// A pane header's link button was clicked: that pane's address is copied (DEV-995).
	private let onCopyURL: (UUID) -> Void
	private let draggedTabID: UUID?
	private let dropRefusal: (UUID, SplitDropEdge) -> SplitDropRefusal?
	private let onDropTab: (UUID, SplitDropEdge) -> Void

	/// Local development pages show the developer header (DEV-733).
	private let showsDeveloperHeader: Bool

	/// The developer header's device capture style, with its feature flag on (DEV-757).
	private let deviceCapture: DeviceCaptureStyle?
	private let onDeveloperHeader: (DeveloperHeaderAction, UUID) -> Void

	/// Off while Peek is open over the window: then a click selects no pane, as it focuses no page.
	@Environment(\.browserSurfaceIsInteractive)
	private var isInteractive

	/// Off while the window's chrome is disabled, as under the command bar: a click there
	/// dismisses it and selects no pane.
	@Environment(\.isEnabled)
	private var isEnabled

	/// Divider drags stay here; the store receives the shares once, when the drag ends.
	@SwiftUI.State
	private var dragFractions: [Double]?

	public init(
		store: StoreOf<ViewerFeature>,
		surface: BrowserSurfaceClient,
		draggedTabID: UUID? = nil,
		dropRefusal: @escaping (UUID, SplitDropEdge) -> SplitDropRefusal? = { _, _ in .unavailable },
		onDropTab: @escaping (UUID, SplitDropEdge) -> Void = { _, _ in },
		onOpenEmptyPane: @escaping (UUID) -> Void = { _ in },
		onEditAddress: @escaping (UUID) -> Void = { _ in },
		onCopyURL: @escaping (UUID) -> Void = { _ in },
		showsDeveloperHeader: Bool = false,
		deviceCapture: DeviceCaptureStyle? = nil,
		onDeveloperHeader: @escaping (DeveloperHeaderAction, UUID) -> Void = { _, _ in }
	) {
		self.store = store
		self.surface = surface
		self.draggedTabID = draggedTabID
		self.dropRefusal = dropRefusal
		self.onDropTab = onDropTab
		self.onOpenEmptyPane = onOpenEmptyPane
		self.onEditAddress = onEditAddress
		self.onCopyURL = onCopyURL
		self.showsDeveloperHeader = showsDeveloperHeader
		self.deviceCapture = deviceCapture
		self.onDeveloperHeader = onDeveloperHeader
		self._dragFractions = .init(initialValue: nil)
	}

	private var fractions: [Double] {
		guard let dragFractions, dragFractions.count == store.panes.count else { return store.fractions }
		return dragFractions
	}

	public var body: some View {
		GeometryReader { geometry in
			paneStack(size: geometry.size)
		}
		.coordinateSpace(name: "split-view")
		.overlay {
			SplitDropZones(
				draggedTabID: draggedTabID,
				refusal: dropRefusal,
				onDrop: onDropTab
			)
		}
		.onGeometryChange(for: ViewerFeature.Capacity.self) { geometry in
			.init(size: geometry.size)
		} action: { capacity in
			store.send(.ui(.capacityChanged(capacity)))
		}
		.onChange(of: store.activePaneID) { _, id in

			// A pane in reading mode gives the keyboard to its reader instead (DEV-1028).
			guard let item = store.panes[id: id]?.item, item.reader == nil, let tabID = item.tab?.id else { return }
			surface.focus(tabID)
		}
	}

	private func paneStack(size: CGSize) -> some View {
		let horizontal = store.orientation == .horizontal
		let length = horizontal ? size.width : size.height
		let extents = SplitLayout.extents(fractions, length: length)
		let isSplit = store.isSplit
		let layout: AnyLayout = horizontal
		? AnyLayout(HStackLayout(spacing: 0))
		: AnyLayout(VStackLayout(spacing: 0))
		let panes = Array(store.scope(state: \.panes, action: \.panes).enumerated())
		return layout {
			ForEach(panes, id: \.element.id) { index, pane in
				if index > 0 { divider(after: index - 1, length: length, horizontal: horizontal) }
				let extent: CGFloat? = isSplit ? extents[safe: index].map { CGFloat($0) } : nil
				paneView(pane)
					.frame(
						width: horizontal ? extent : nil,
						height: horizontal ? nil : extent
					)
			}
		}
	}

	private func paneView(_ pane: StoreOf<ViewerPaneFeature>) -> some View {
		let showsHeader = showsDeveloperHeader && LocalDevelopment.isLocal(pane.item.navigation.url)
		return VStack(spacing: 0) {
			if showsHeader {
				DeveloperHeader(
					url: pane.item.navigation.url,
					isActive: store.activePaneID == pane.id,
					send: { onDeveloperHeader($0, pane.id) },
					onClose: store.isSplit ? { store.send(.ui(.closePane(pane.id))) } : nil,
					deviceCapture: deviceCapture
				)
			} else if store.isSplit {
				paneHeader(pane)
			}
			ViewerItemView(
				store: pane.scope(state: \.item, action: \.item),
				surface: surface,
				onFocus: {
					guard store.activePaneID != pane.id else { return }
					store.send(.ui(.focus(pane.id)))
				},
				isFocused: store.activePaneID == pane.id,
				showsLoading: false,
				squaresTopCorners: showsHeader
			)
		}

		// A click anywhere in a pane selects it, the page's included, and still reaches what's
		// under the pointer (DEV-993).
		.background {
			if store.isSplit, isInteractive, isEnabled {
				PaneClickMonitor {
					guard store.activePaneID != pane.id else { return }
					store.send(.ui(.focus(pane.id)))
				}
			}
		}
		.browserPageCard()

		// In the margin above the card, centred on it.
		.overlay(alignment: .top) {
			BrowserLoadingLine(isLoading: pane.item.navigation.isLoading)
				.offset(y: -(BrowserMetrics.PageCard.inset + BrowserMetrics.LoadingLine.height) / 2)
		}
		.overlay {
			if store.isSplit, store.activePaneID == pane.id {
				RoundedRectangle(cornerRadius: BrowserMetrics.PageCard.cornerRadius, style: .continuous)
					.strokeBorder(BrowserTheme.accent, lineWidth: 1.5)
					.allowsHitTesting(false)
			}
		}
		.commandBarPaneAnchor(isActive: store.isSplit && store.activePaneID == pane.id)
		.browserRecedesBehindPeek(paneID: pane.id)
		.browserPeekPaneBounds(pane.id)
	}

	private func paneHeader(_ pane: StoreOf<ViewerPaneFeature>) -> some View {
		let navigation = pane.item.navigation
		let generation = pane.item.generation
		let tabID = pane.item.tab?.id
		let selectHistory: (Int) -> Void = { entryID in
			guard let tabID else { return }
			pane.send(.item(.ui(.selectHistory(
				tabID: tabID,
				generation: generation,
				history: navigation.history,
				entryID: entryID
			))))
		}

		// Equal flexible sides keep the host centered in the pane.
		return HStack(spacing: 0) {
			HStack(spacing: 2) {
				BrowserHistoryControl(
					navigation: navigation,
					direction: .back,
					navigate: { pane.send(.item(.ui(.command(.back)))) },
					select: selectHistory
				)
				BrowserHistoryControl(
					navigation: navigation,
					direction: .forward,
					navigate: { pane.send(.item(.ui(.command(.forward)))) },
					select: selectHistory
				)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			paneTitle(pane)
				.layoutPriority(1)
			HStack(spacing: 2) {
				// As in the sidebar's address bar, shown whenever the pane shows a page (DEV-995).
				if pane.item.tab != nil, let url = pane.item.navigation.url {
					PaneHeaderActions(
						url: url,
						isActive: store.activePaneID == pane.id,
						onActivate: { store.send(.ui(.focus(pane.id))) },
						onCopy: { onCopyURL(pane.id) },
						// The pane's own reading mode (DEV-1028).
						readingMode: pane.item.isReadable || pane.item.reader != nil
						? .init(isReading: pane.item.reader != nil) { pane.send(.item(.ui(.readerToggled))) }
						: nil
					)
				}
				Button { store.send(.ui(.closePane(pane.id))) } label: { Image(systemName: "xmark") }
					.help(String.localized(.appUI.split.closePane))
					.accessibilityLabel(String.localized(.appUI.split.closePane))
			}
			.frame(maxWidth: .infinity, alignment: .trailing)
		}
		.buttonStyle(BrowserToolbarButtonStyle())
		.font(.system(size: BrowserMetrics.PaneHeader.symbolSize, weight: .medium))
		.foregroundStyle(BrowserTheme.secondary)
		.padding(.horizontal, BrowserMetrics.PaneHeader.horizontalPadding)
		.frame(height: BrowserMetrics.PaneHeader.height)
	}

	private func paneTitle(_ pane: StoreOf<ViewerPaneFeature>) -> some View {
		let isEmpty = pane.item.tab == nil
		let url = pane.item.navigation.url
		return Button {
			store.send(.ui(.focus(pane.id)))

			// As the sidebar's address does: an empty pane asks for a page, a page's address opens
			// the command bar on it (DEV-993).
			if isEmpty {
				onOpenEmptyPane(pane.id)
			} else {
				onEditAddress(pane.id)
			}
		} label: {
			Group {
				// The whole address without its scheme, the host always shown (DEV-993).
				if !isEmpty, let url {
					PaneAddress(url: url)
				} else {
					Text(isEmpty ? String.localized(.appUI.url.search) : pane.item.navigation.title)
						.lineLimit(1)
				}
			}
			.font(.system(size: BrowserMetrics.PaneHeader.hostFontSize))
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(store.activePaneID == pane.id ? .isSelected : [])
	}

	private func divider(
		after index: Int,
		length: CGFloat,
		horizontal: Bool
	) -> some View {
		let extents = SplitLayout.extents(fractions, length: length)
		let share = fractions[safe: index] ?? 0
		return Rectangle()
			.fill(.clear)
			.contentShape(.rect)
			.frame(
				width: horizontal ? SplitLayout.dividerLength : nil,
				height: horizontal ? nil : SplitLayout.dividerLength
			)
			.pointerStyle(horizontal ? .columnResize : .rowResize)
			.gesture(
				DragGesture(minimumDistance: 1, coordinateSpace: .named("split-view"))
					.onChanged { value in
						guard length > SplitLayout.dividerLength else { return }

						let delta = horizontal ? value.translation.width : value.translation.height
						dragFractions = SplitLayout.resize(store.fractions, divider: index, by: delta, length: length)
					}
					.onEnded { _ in
						if let dragFractions { store.send(.ui(.resize(dragFractions))) }
						dragFractions = nil
						store.send(.ui(.resizeEnded))
					}
			)
			.onTapGesture(count: 2) {
				store.send(.ui(.equalize))
				store.send(.ui(.resizeEnded))
			}
			.accessibilityElement()
			.accessibilityLabel(String.localized(.appUI.split.divider))
			.accessibilityValue(Text(share, format: .percent.precision(.fractionLength(0))))
			.accessibilityHint(String.localized(.appUI.split.dividerHint))
			.accessibilityAdjustableAction { direction in
				let step = (extents.reduce(0, +)) * 0.05
				let delta = direction == .increment ? step : -step
				store.send(.ui(.resize(SplitLayout.resize(store.fractions, divider: index, by: delta, length: length))))
				store.send(.ui(.resizeEnded))
			}
	}
}

extension Array {
	fileprivate subscript(safe index: Int) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}
