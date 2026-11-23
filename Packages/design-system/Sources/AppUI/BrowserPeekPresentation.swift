import AppKit
import SwiftUI

// MARK: - Receding page

extension EnvironmentValues {
	/// The pane a Peek was opened from. It shrinks back a little and dims (DEV-1224).
	@Entry
	public var browserRecedingPaneID: UUID? = nil
}

extension View {
	/// Scales this pane back and dims it while a Peek opened from it is visible, and restores it
	/// on close.
	public func browserRecedesBehindPeek(paneID: UUID) -> some View {
		modifier(BrowserPeekRecede(paneID: paneID))
	}

	/// Reports this pane's unscaled frame, so a Peek opened from it covers only this pane.
	///
	/// Apply it after `browserRecedesBehindPeek(paneID:)`: the frame sits beside the
	/// scaled page rather than inside it, so the card does not shrink with the page.
	public func browserPeekPaneBounds(_ paneID: UUID) -> some View {
		background {
			Color.clear.anchorPreference(
				key: BrowserPeekPaneBoundsKey.self,
				value: .bounds
			) { [paneID: $0] }
		}
	}
}

/// Every viewer pane's frame in the window, by pane ID.
public struct BrowserPeekPaneBoundsKey: PreferenceKey {
	public static let defaultValue: [UUID: Anchor<CGRect>] = [:]

	public static func reduce(
		value: inout [UUID: Anchor<CGRect>],
		nextValue: () -> [UUID: Anchor<CGRect>]
	) {
		value.merge(nextValue()) { _, new in new }
	}
}

private struct BrowserPeekRecede: ViewModifier {
	private let paneID: UUID

	@Environment(\.browserRecedingPaneID)
	private var recedingPaneID

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	fileprivate init(paneID: UUID) {
		self.paneID = paneID
	}

	fileprivate func body(content: Content) -> some View {
		let recedes = recedingPaneID == paneID
		content
			.scaleEffect(recedes && !reduceMotion ? BrowserMetrics.Peek.backgroundScale : 1)

			// Dimming isn't motion: it stays under Reduce Motion, as a crossfade.
			.opacity(recedes ? BrowserMetrics.Peek.backgroundOpacity : 1)
			.animation(reduceMotion ? BrowserPeekMotion.fade : BrowserPeekMotion.open, value: recedes)
	}
}

// MARK: - Reveal

public enum BrowserPeekMotion {
	public static let open: Animation = .spring(duration: 0.34, bounce: 0.1)
	public static let close: Animation = .spring(duration: 0.26, bounce: 0)
	public static let fade: Animation = .easeOut(duration: 0.15)
}

extension AnyTransition {
	/// A Peek grows out of `anchor` (the clicked link, in the card's unit space) and shrinks back into it.
	///
	/// Without an anchor the card appears and disappears at once, as it did before links reported
	/// a position. Reduced motion keeps the anchor's meaning out of it and only crossfades.
	public static func browserPeekReveal(
		anchor: UnitPoint?,
		reduceMotion: Bool
	) -> AnyTransition {
		guard let anchor else { return .identity }
		if reduceMotion { return .opacity.animation(BrowserPeekMotion.fade) }

		return .asymmetric(
			insertion: .modifier(
				active: BrowserPeekRevealEffect(progress: 0, anchor: anchor),
				identity: BrowserPeekRevealEffect(progress: 1, anchor: anchor)
			)
			.animation(BrowserPeekMotion.open),
			removal: .modifier(
				active: BrowserPeekRevealEffect(progress: 0, anchor: anchor),
				identity: BrowserPeekRevealEffect(progress: 1, anchor: anchor)
			)
			.animation(BrowserPeekMotion.close)
		)
	}
}

private struct BrowserPeekRevealEffect: ViewModifier {
	private let progress: CGFloat
	private let anchor: UnitPoint

	// Built by a transition outside the main actor, as the memberwise initializer was.
	fileprivate nonisolated init(
		progress: CGFloat,
		anchor: UnitPoint
	) {
		self.progress = progress
		self.anchor = anchor
	}

	fileprivate func body(content: Content) -> some View {
		let scale = BrowserMetrics.Peek.originScale + (1 - BrowserMetrics.Peek.originScale) * progress
		content
			.scaleEffect(scale, anchor: anchor)

			// The card is solid well before it reaches full size.
			.opacity(min(1, progress * 2.5))
	}
}

// MARK: - Screen points

/// Converts screen points into the coordinate space of the view it backs (top-left origin).
@MainActor
public final class BrowserScreenPointConverter {
	fileprivate weak var view: NSView?

	public init() {}

	public func localPoint(fromScreen point: CGPoint) -> CGPoint? {
		guard let view, let window = view.window else { return nil }
		return view.convert(window.convertPoint(fromScreen: point), from: nil)
	}
}

/// A transparent view that lets `converter` map screen points into its frame.
public struct BrowserScreenPointProbe: NSViewRepresentable {
	private let converter: BrowserScreenPointConverter

	public init(converter: BrowserScreenPointConverter) {
		self.converter = converter
	}

	public func makeNSView(context: Context) -> NSView {
		let view = ProbeView()
		converter.view = view
		return view
	}

	public func updateNSView(
		_ view: NSView,
		context: Context
	) {
		converter.view = view
	}

	private final class ProbeView: NSView {
		fileprivate override var isFlipped: Bool { true }

		fileprivate override func hitTest(_ point: NSPoint) -> NSView? { nil }
	}
}

// MARK: - Controls

/// Peek's buttons, with a hint beside them on hover. Arx buttons (DEV-743, DEV-1224): a filled
/// rounded square with continuous corners and no stroke, lighter when hovered and darker when
/// pressed, on a solid backing so they read over any page.
public struct BrowserPeekControlStyle: ButtonStyle {
	private let hint: String

	public init(hint: String) {
		self.hint = hint
	}

	public func makeBody(configuration: Configuration) -> some View {
		BrowserPeekControl(configuration: configuration, hint: hint)
	}
}

private struct BrowserPeekControl: View {
	private typealias Metrics = BrowserMetrics.Peek.Control

	private let configuration: ButtonStyleConfiguration
	private let hint: String

	@Environment(\.isEnabled)
	private var isEnabled

	@Environment(\.isFocused)
	private var isFocused

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@Environment(\.arxControlStateOverride)
	private var stateOverride

	@SwiftUI.State
	private var isHovered: Bool

	@SwiftUI.State
	private var showsHint: Bool

	@SwiftUI.State
	private var showsFocusRing: Bool

	fileprivate init(
		configuration: ButtonStyleConfiguration,
		hint: String
	) {
		self.configuration = configuration
		self.hint = hint
		self._isHovered = .init(initialValue: false)
		self._showsHint = .init(initialValue: false)
		self._showsFocusRing = .init(initialValue: false)
	}

	fileprivate var body: some View {
		let hovered: Bool = isEnabled && (stateOverride.isHovered ?? isHovered)
		let pressed: Bool = isEnabled && (stateOverride.isPressed ?? configuration.isPressed)
		let focused: Bool = isEnabled && (stateOverride.isFocused ?? (isFocused && showsFocusRing))
		configuration.label
			.font(.system(size: Metrics.symbolSize, weight: .semibold))
			.foregroundStyle(.primary)
			.frame(width: Metrics.size, height: Metrics.size)
			.background(ArxControlPalette.subtleFill(hovered: hovered, pressed: pressed), in: ArxControlShape())
			.background(BrowserTheme.page, in: ArxControlShape())
			.overlay {
				if focused {
					ArxControlShape()
						.inset(by: -ArxControlPalette.focusRingWidth / 2 - 1)
						.stroke(ArxControlPalette.focusRing, lineWidth: ArxControlPalette.focusRingWidth)
				}
			}
			.browserShadow(Metrics.shadow)
			.contentShape(.focusEffect, ArxControlShape())
			.contentShape(ArxControlShape())
			.opacity(isEnabled ? 1 : ArxControlPalette.disabledOpacity)
			.animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
			.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
			.overlay(alignment: .trailing) {
				if showsHint {
					BrowserPeekHint(text: hint)
						.alignmentGuide(.trailing) { $0[.trailing] + Metrics.size + Metrics.hintSpacing }
						.transition(.opacity)
				}
			}
			.onHover { isHovered = $0 }
			.arxKeyboardFocusRing(isFocused: isFocused, showsRing: $showsFocusRing)
			.task(id: isHovered) {
				guard isHovered else {
					showsHint = false
					return
				}
				try? await Task.sleep(for: Metrics.hintDelay)
				guard !Task.isCancelled else { return }
				withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { showsHint = true }
			}
	}
}

private struct BrowserPeekHint: View {
	private let text: String

	fileprivate init(text: String) {
		self.text = text
	}

	fileprivate var body: some View {
		Text(text)
			.font(.system(size: 11, weight: .medium))
			.foregroundStyle(.white)
			.lineLimit(1)
			.fixedSize()
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(.black.opacity(0.82), in: .capsule)
			.overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
			.browserShadow(.init(opacity: 0.25, radius: 6, y: 2))
			.allowsHitTesting(false)
			.accessibilityHidden(true)
	}
}
