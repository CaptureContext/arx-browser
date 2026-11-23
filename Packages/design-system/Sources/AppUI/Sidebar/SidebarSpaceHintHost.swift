import SwiftUI

/// The hint the footer picker asks for: which space, where its cell is and where the footer is.
public struct SidebarSpaceHintRequest {
	public var space: SidebarSpacePickerEntry
	public var item: Anchor<CGRect>
	public var row: Anchor<CGRect>?
}

internal struct SidebarSpaceHintKey: PreferenceKey {
	internal static var defaultValue: SidebarSpaceHintRequest? { nil }

	internal static func reduce(
		value: inout SidebarSpaceHintRequest?,
		nextValue: () -> SidebarSpaceHintRequest?
	) {
		if value == nil { value = nextValue() }
	}
}

/// Where the hint goes: centered over its space, a little above the footer, and shifted
/// sideways as far as needed to stay inside the window, never clipped.
public enum SidebarSpaceHintPlacement {
	/// The room between the hint and the footer's top edge.
	public static let clearance: CGFloat = 8

	/// The closest the hint comes to the window's edges.
	public static let margin: CGFloat = 8

	/// The hint's top-leading corner in the host's coordinates.
	/// - Parameters:
	///   - item: The hovered space's cell.
	///   - row: The footer row the cell sits in.
	///   - container: The host, usually the whole window's content.
	public static func origin(
		hint: CGSize,
		item: CGRect,
		row: CGRect,
		container: CGSize
	) -> CGPoint {
		let maximumX = container.width - margin - hint.width
		let x = max(min(item.midX - hint.width / 2, maximumX), margin)
		let y = max(row.minY - clearance - hint.height, margin)
		return .init(x: x, y: y)
	}
}

extension View {
	/// Places every hint from inside this view, the space picker's and the Library button's,
	/// above this view's frame, so they all keep the same clearance above the footer.
	public func sidebarFooterHintRow() -> some View {
		transformAnchorPreference(key: SidebarSpaceHintKey.self, value: .bounds) { request, row in
			request?.row = row
		}
	}

	/// Draws the footer space picker's hint over this view, outside the sidebar's clipping.
	/// Put it on the window's root.
	public func sidebarSpaceHintHost() -> some View {
		overlayPreferenceValue(SidebarSpaceHintKey.self) { request in
			GeometryReader { proxy in
				SidebarSpaceHintOverlay(request: request, proxy: proxy)
			}
			.allowsHitTesting(false)
		}
	}
}

private struct SidebarSpaceHintOverlay: View {
	internal let request: SidebarSpaceHintRequest?
	internal let proxy: GeometryProxy

	@SwiftUI.State
	private var size: CGSize = .zero

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	internal var body: some View {
		ZStack(alignment: .topLeading) {
			if let request {
				let item = proxy[request.item]
				let origin = SidebarSpaceHintPlacement.origin(
					hint: size,
					item: item,
					row: request.row.map { proxy[$0] } ?? item,
					container: proxy.size
				)
				SidebarSpaceHint(space: request.space)
					.onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
					.offset(x: origin.x, y: origin.y)

					// Hidden until measured, so it never shows in the wrong place first.
					.opacity(size == .zero ? 0 : 1)

					// Once shown, the hint switches spaces and moves without animating. Only showing
					// and hiding it animate.
					.transaction(value: request.space.id) { $0.animation = nil }
					.transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: request != nil)
	}
}

/// The pill above a hovered space: its name, its profile's chip and the keys that switch to it.
public struct SidebarSpaceHint: View {
	private let space: SidebarSpacePickerEntry

	@Environment(\.colorScheme)
	private var colorScheme

	/// Everything the accent resolves from (DEV-1117), so the chip can lighten and fade it as a color.
	@Environment(\.self)
	private var environment

	public init(space: SidebarSpacePickerEntry) {
		self.space = space
	}

	/// The accent, lifted in the dark appearance so the chip and keys stay readable.
	private var tint: Color {
		colorScheme == .dark ? Color(red: 0.76, green: 0.74, blue: 1) : Color(accent)
	}

	private var accent: Color.Resolved {
		BrowserTheme.accent.resolve(in: environment)
	}

	/// The name's color: deep navy on light, near white on dark.
	private var nameColor: Color {
		colorScheme == .dark ? .white.opacity(0.92) : Color(red: 0.11, green: 0.12, blue: 0.3)
	}

	public var body: some View {
		HStack(spacing: Metrics.spacing) {
			Text(space.name)
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(nameColor)
				.lineLimit(1)
				.padding(.horizontal, Metrics.namePadding)
			if let profileName = space.profileName {
				HStack(spacing: 5) {
					ProfileSmiley()
						.frame(width: 13, height: 13)
					Text(profileName)
						.font(.system(size: 12, weight: .semibold))
						.lineLimit(1)
				}
				.foregroundStyle(tint)
				.padding(.horizontal, 9)
				.frame(height: Metrics.chipHeight)
				.background(tint.opacity(colorScheme == .dark ? 0.2 : 0.14), in: ArxControlShape())
			}
			if !space.shortcut.isEmpty {
				HStack(spacing: 4) {
					ForEach(Array(space.shortcut.enumerated()), id: \.offset) { _, key in
						SidebarKeyCap(key, tint: tint)
					}
				}
				.padding(.trailing, 2)
			}
		}
		.fixedSize()

		// The same inset all round, so the chip and the keys sit evenly in the pill.
		.padding(Metrics.inset)

		// The sidebar controls' flat surface, without glass or a rim (DEV-788): it floats over
		// the page, so it starts from the opaque selected-row fill and casts one soft shadow.
		.background {
			ArxControlShape()
				.fill(BrowserTheme.selectedRow)
				.shadow(color: .black.opacity(Metrics.shadowOpacity), radius: Metrics.shadowRadius, y: Metrics.shadowY)
		}
		.modifier(SidebarControlSurface(fill: Color.clear, shape: ArxControlShape()))
		.accessibilityElement(children: .combine)
	}

	private enum Metrics {
		internal static let inset: CGFloat = 5
		internal static let spacing: CGFloat = 6
		internal static let namePadding: CGFloat = 6
		internal static let chipHeight: CGFloat = 24
		internal static let shadowOpacity: Double = 0.1
		internal static let shadowRadius: CGFloat = 8
		internal static let shadowY: CGFloat = 3
	}
}

/// One key of a shortcut, drawn as a small raised, outlined cap.
private struct SidebarKeyCap: View {
	/// The cap's height: its corners follow the control rule.
	private static let height: CGFloat = 21
	private static let keyCornerRadius: CGFloat = ArxControlShape.cornerRadius(forSide: height)

	internal let key: String
	internal let tint: Color

	internal init(
		_ key: String,
		tint: Color
	) {
		self.key = key
		self.tint = tint
	}

	internal var body: some View {
		Text(key)
			.font(.system(size: 11, weight: .bold))
			.foregroundStyle(tint)
			.frame(minWidth: 22, minHeight: Self.height)
			.padding(.horizontal, 2)
			.background(tint.opacity(0.12), in: ArxControlShape())
			.overlay {
				ArxControlShape()
					.strokeBorder(tint.opacity(0.7), lineWidth: 1)
			}

			// The key's thicker bottom edge, so it reads as raised.
			.overlay(alignment: .bottom) {
				UnevenRoundedRectangle(
					bottomLeadingRadius: Self.keyCornerRadius,
					bottomTrailingRadius: Self.keyCornerRadius,
					style: .continuous
				)
				.fill(tint.opacity(0.7))
				.frame(height: 2)
			}
			.padding(.bottom, 1)
	}
}
