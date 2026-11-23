import AppUI
import BrowserCore
import BrowserSurfaceClient
import Foundation
import PeekFeature
import SwiftUI
import _ComposableArchitecture

internal struct PeekHostPresentation: ViewModifier {
	internal let store: StoreOf<AppFeature>
	internal let windowID: UUID
	internal let surface: BrowserSurfaceClient

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@SwiftUI.State
	private var screenPoints: BrowserScreenPointConverter = .init()

	internal func body(content: Content) -> some View {
		let peek = store.peeks.first { $0.source.windowID == windowID }
		let window = windowID == store.main.id ? store.main : store.windows[id: windowID]
		let sourcePaneID = store.littleWindows[id: windowID] != nil
		? windowID : window.flatMap { $0.isPrivate ? nil : $0.viewer.activePaneID }
		content
			.environment(\.browserPeekActions, sourcePaneID == nil ? nil : .init { tabID in
				guard let sourcePaneID else { return }
				store.send(.ui(.peekTab(.init(rawValue: tabID), sourceWindowID: windowID, sourcePaneID: sourcePaneID)))
			})

			// Added to what the host suppresses already, such as a page in full screen (DEV-949).
			.transformEnvironment(\.suppressedBrowserTabs) { tabs in
				if let peek, !peek.isTemporary { tabs.insert(peek.tab.id) }
			}
			.environment(\.browserSurfaceIsInteractive, peek == nil)
			.environment(\.browserRecedingPaneID, peek.flatMap { $0.phase == .releasing ? nil : $0.source.paneID })

			// The tab it came from shows the peeked site's favicon in the sidebar (DEV-1224).
			.environment(\.browserPeekedTab, peek?.peekedTab)
			.allowsHitTesting(peek == nil)
			.accessibilityHidden(peek != nil)
			.background { BrowserScreenPointProbe(converter: screenPoints) }
			.overlayPreferenceValue(BrowserPeekPaneBoundsKey.self) { panes in
				GeometryReader { geometry in
					let card = cardFrame(for: peek, panes: panes, in: geometry)
					ZStack(alignment: .topLeading) {
						if peek != nil {
							// Clicking anywhere outside the card dismisses it.
							Color.clear
								.contentShape(.rect)
								.onTapGesture { store.send(.ui(.dismissPeek(windowID: windowID))) }
								.accessibilityHidden(true)
						}
						ForEach(store.scope(state: \.peeks, action: \.peeks)) { child in
							if child.source.windowID == windowID {
								// Positioned rather than offset: the reveal scales the whole positioned
								// view, so its anchor is measured in the overlay, where the click is.
								PeekView(store: child, surface: surface)
									.frame(width: card.width, height: card.height)
									.environment(\.browserSurfaceIsInteractive, true)

									// The find bar's Previous and Next name the keys bound to them (DEV-1297).
									.environment(\.browserShortcuts, store.settings.keyboardShortcuts)
									.position(x: card.midX, y: card.midY)
									.transition(.browserPeekReveal(
										anchor: anchor(for: child.state, card: card, in: geometry.size),
										reduceMotion: reduceMotion
									))
							}
						}
					}
					.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
				}
			}
	}

	/// Over the pane the Peek came from, so the sidebar and other split panes stay visible.
	/// Little Arx has no viewer panes and keeps the window-inset card.
	private func cardFrame(
		for peek: PeekFeature.State?,
		panes: [UUID: Anchor<CGRect>],
		in geometry: GeometryProxy
	) -> CGRect {
		if let anchor = peek.flatMap({ panes[$0.source.paneID] }) {
			return BrowserMetrics.Peek.frame(inPane: geometry[anchor])
		}

		let inset = BrowserMetrics.Peek.inset(in: geometry.size)
		return CGRect(
			x: inset.width,
			y: inset.height,
			width: max(0, geometry.size.width - 2 * inset.width),
			height: max(0, geometry.size.height - 2 * inset.height)
		)
	}

	/// The clicked link in the overlay's unit space, kept on the card so a link in the
	/// pane's margin grows the card from its nearest edge. A promotion keeps the page where it is.
	private func anchor(
		for peek: PeekFeature.State,
		card: CGRect,
		in size: CGSize
	) -> UnitPoint? {
		if case .promote = store.peekTransitions[peek.id] { return nil }
		guard
			size.width > 0, size.height > 0, !card.isEmpty,
			let origin = peek.origin,
			let point = screenPoints.localPoint(fromScreen: origin)
		else { return nil }

		return UnitPoint(
			x: min(max(point.x, card.minX), card.maxX) / size.width,
			y: min(max(point.y, card.minY), card.maxY) / size.height
		)
	}
}
