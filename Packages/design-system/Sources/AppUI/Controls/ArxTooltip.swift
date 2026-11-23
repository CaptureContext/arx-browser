import SwiftUI

/// A hovered icon's small tooltip (DEV-797): the title on an opaque
/// squircle with a soft shadow, hung under the icon. ``ArxSegmentedControl`` and
/// ``ArxIconActionGroup`` draw it.
internal struct ArxTooltip: View {
	internal static let height: CGFloat = 22

	/// How far below a raised control's bottom edge the tooltip's center sits, as an overlay
	/// aligned to the control's bottom edge: its top a little under the control.
	internal static let offset: CGFloat = height + ArxRaisedPalette.inset + 5

	internal let title: String

	internal init(_ title: String) {
		self.title = title
	}

	internal var body: some View {
		let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
		Text(verbatim: title)
			.font(.system(size: 11, weight: .medium))
			.foregroundStyle(BrowserTheme.text)
			.lineLimit(1)
			.fixedSize()
			.padding(.horizontal, 8)
			.frame(height: Self.height)
			.background {
				shape
					.fill(ArxRaisedPalette.tooltipFill)
					.shadow(color: ArxRaisedPalette.shadow, radius: 6, y: 2)
					.overlay { shape.strokeBorder(ArxRaisedPalette.hairline, lineWidth: 0.5) }
			}
			.allowsHitTesting(false)
			.accessibilityHidden(true)
	}

	/// The end items' tooltips line up with the row's edge, so they never reach past it; the
	/// others center under their item.
	internal static func alignment(
		index: Int,
		count: Int
	) -> Alignment {
		if count > 1, index == 0 {
			.bottomLeading
		} else if count > 1, index == count - 1 {
			.bottomTrailing
		} else {
			.bottom
		}
	}
}

extension View {
	/// Shows `hovered`'s tooltip after a short wait, so sweeping across a row of icons doesn't
	/// flash them; moving to the next icon while one shows swaps it at once.
	internal func arxTooltipTiming<ID: Hashable>(
		hovered: ID?,
		tooltip: Binding<ID?>
	) -> some View {
		modifier(ArxTooltipTiming(hovered: hovered, tooltip: tooltip))
	}
}

private struct ArxTooltipTiming<ID: Hashable>: ViewModifier {
	internal let hovered: ID?

	@Binding
	internal var tooltip: ID?

	@SwiftUI.State
	private var delay: Task<Void, Never>?

	internal func body(content: Content) -> some View {
		content
			.onChange(of: hovered) { _, hovered in
				delay?.cancel()
				guard let hovered else {
					tooltip = nil
					return
				}

				if tooltip != nil {
					tooltip = hovered
					return
				}
				delay = Task { @MainActor in
					try? await Task.sleep(for: .milliseconds(350))
					guard !Task.isCancelled
					else { return }

					tooltip = hovered
				}
			}
			.onDisappear { delay?.cancel() }
			.animation(.easeOut(duration: 0.12), value: tooltip)
	}
}

/// One action of an ``ArxIconActionGroup``: an icon, with its title as the tooltip and what
/// VoiceOver reads.
public struct ArxIconAction: Identifiable {
	public let id: String
	public let title: String
	public let systemImage: String
	public let isEnabled: Bool
	public let action: () -> Void

	/// `id` defaults to `systemImage`; pass one when two actions share an icon.
	public init(
		_ title: String,
		systemImage: String,
		id: String? = nil,
		isEnabled: Bool = true,
		action: @escaping () -> Void
	) {
		self.id = id ?? systemImage
		self.title = title
		self.systemImage = systemImage
		self.isEnabled = isEnabled
		self.action = action
	}
}

/// A bar's actions as icons in one glassy squircle (DEV-872): hovering an
/// icon shows its title in a small tooltip under it, as ``ArxSegmentedControl``'s segments do.
/// Use it where labelled buttons would crowd a header bar's title.
///
/// The tooltip hangs below the bar over whatever's there, so give the row holding it a `zIndex`
/// above the views under it.
///
/// ```swift
/// ArxIconActionGroup([
///     ArxIconAction("Install Package…", systemImage: "shippingbox") { install() },
///     ArxIconAction("Refresh", systemImage: "arrow.clockwise") { refresh() },
/// ])
/// ```
public struct ArxIconActionGroup: View {
	private let actions: [ArxIconAction]

	@SwiftUI.State
	private var hovered: String?

	@SwiftUI.State
	private var tooltip: String?

	public init(_ actions: [ArxIconAction]) {
		self.init(actions, tooltip: nil)
	}

	/// `tooltip` shows that action's tooltip from the start, as a snapshot does.
	internal init(
		_ actions: [ArxIconAction],
		tooltip: String?
	) {
		self.actions = actions
		self._tooltip = .init(initialValue: tooltip)
	}

	public var body: some View {
		if !actions.isEmpty {
			ArxRaisedGroup {
				ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
					Button(action: action.action) {
						Image(systemName: action.systemImage)
					}
					.buttonStyle(.arxRaised(.item, isSquare: true))
					.focusEffectDisabled()
					.disabled(!action.isEnabled)
					.accessibilityLabel(Text(verbatim: action.title))

					// A disabled button still names itself on hover, so the reason it's there reads.
					.onHover { isHovering in
						if isHovering {
							hovered = action.id
						} else if hovered == action.id {
							hovered = nil
						}
					}
					.overlay(alignment: ArxTooltip.alignment(index: index, count: actions.count)) {
						if tooltip == action.id {
							ArxTooltip(action.title)
								.offset(y: ArxTooltip.offset)
								.transition(.opacity)
						}
					}
				}
			}
			.arxTooltipTiming(hovered: hovered, tooltip: $tooltip)
		}
	}
}
