import SwiftUI

internal struct SidebarFolderIcon: View {
	private let isExpanded: Bool

	/// Collapsed, with its selected tab showing beneath it: the closed folder holds "•••", as in
	/// the design (DEV-1110).
	private let isPartlyRevealed: Bool

	/// Drawn in `BrowserTheme.onAccent` over an accent fill, such as a folder about to take a drop.
	private let isOnAccent: Bool

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@Environment(\.browserAccentIsEnabled)
	private var accentIsEnabled

	@Environment(\.colorScheme)
	private var colorScheme

	/// The folder (`SidebarRowPolish`): a light body in a heavier accent outline, with the
	/// "•••" in the accent.
	@Environment(\.sidebarRowPolish)
	private var isPolished

	internal init(
		isExpanded: Bool,
		isPartlyRevealed: Bool = false,
		isOnAccent: Bool = false
	) {
		self.isExpanded = isExpanded
		self.isPartlyRevealed = isPartlyRevealed
		self.isOnAccent = isOnAccent
	}

	internal var body: some View {
		Group {
			if polishes {
				PolishedFolderIcon(
					state: polishedState,
					paper: paperFill,
					back: backStripFill,
					outline: outline
				)
				.transition(.opacity)
				.id(polishedState)
			} else {
				plainIcon
			}
		}
		.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isExpanded)
		.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsEllipsis)
		.accessibilityHidden(true)
	}

	/// The folder before `SidebarRowPolish`, and over an accent fill.
	private var plainIcon: some View {
		ZStack {
			Image(systemName: "folder.fill")
				.font(.system(size: 17))
				.foregroundStyle(isOnAccent ? AnyShapeStyle(BrowserTheme.onAccent.opacity(0.3)) : AnyShapeStyle(BrowserTheme.accent.opacity(0.65)))
				.overlay {
					Image(systemName: "folder")
						.font(.system(size: 17))
						.foregroundStyle(plainOutline)
				}
			FolderFlap(openAmount: isExpanded ? 1 : 0)
				.fill(isOnAccent ? AnyShapeStyle(BrowserTheme.onAccent.opacity(0.3)) : AnyShapeStyle(BrowserTheme.accent))
				.overlay {
					FolderFlap(openAmount: isExpanded ? 1 : 0)
						.stroke(plainOutline, lineWidth: 1.2)
				}
				.frame(width: 19, height: 16)
			if showsEllipsis {
				Image(systemName: "ellipsis")
					.font(.system(size: 9, weight: .heavy))
					.foregroundStyle(.white)

					// The middle of the closed flap, below its top edge.
					.offset(y: 2.5)
					.transition(.opacity)
			}
		}
	}

	private var showsEllipsis: Bool { isPartlyRevealed && !isExpanded }

	/// Over an accent fill the folder keeps its plain look either way.
	private var polishes: Bool { isPolished && !isOnAccent }

	private var polishedState: PolishedFolderIcon.State {
		if isExpanded { return .open }
		return isPartlyRevealed ? .collapsedWithSelection : .closed
	}

	/// The polished folder's front: near white with a breath of the accent on light chrome,
	/// and the accent sunk toward black on dark, so the pale outline stands out of it.
	private var paperFill: AnyShapeStyle {
		colorScheme == .dark
		? AnyShapeStyle(BrowserTheme.accent.mixed(with: .black, by: 0.45))
		: AnyShapeStyle(BrowserTheme.accent.mixed(with: .white, by: 0.9))
	}

	/// The strip of the folder's back above its front, and the open folder's back: the accent paled
	/// halfway, between the outline and the front.
	private var backStripFill: AnyShapeStyle {
		colorScheme == .dark
		? AnyShapeStyle(BrowserTheme.accent.mixed(with: .black, by: 0.1))
		: AnyShapeStyle(BrowserTheme.accent.mixed(with: .white, by: 0.5))
	}

	/// The polished folder's one stroke, opaque so nothing shows twice where its lines meet.
	private var outline: AnyShapeStyle {
		guard accentIsEnabled else { return AnyShapeStyle(BrowserTheme.folderOutline) }

		return colorScheme == .dark
		? AnyShapeStyle(BrowserTheme.accent.mixed(with: .white, by: 0.7))
		: AnyShapeStyle(BrowserTheme.accent)
	}

	/// The folder's lines: the accent itself on light chrome and the accent paled almost to white
	/// on dark, as Arx's own outline is to its accent (DEV-1117).
	private var plainOutline: AnyShapeStyle {
		if isOnAccent { return AnyShapeStyle(BrowserTheme.onAccent) }
		guard accentIsEnabled else { return AnyShapeStyle(BrowserTheme.folderOutline.opacity(0.85)) }

		return colorScheme == .dark
		? AnyShapeStyle(BrowserTheme.accent.mixed(with: .white, by: 0.85).opacity(0.85))
		: AnyShapeStyle(BrowserTheme.accent.opacity(0.85))
	}
}

private struct FolderFlap: Shape {
	internal var openAmount: Double

	internal init(openAmount: Double) {
		self.openAmount = openAmount
	}

	internal var animatableData: Double {
		get { openAmount }
		set { openAmount = newValue }
	}

	internal func path(in rect: CGRect) -> Path {
		let open: CGFloat = openAmount
		let left: CGFloat = rect.minX + 1 + 2 * open
		let right: CGFloat = rect.maxX - 1 + 2 * open
		let top: CGFloat = rect.minY + 4 + 3 * open
		let bottom: CGFloat = rect.maxY - 1
		return Path { path in
			path.move(to: .init(
				x: left + 1,
				y: top
			))
			path.addLine(to: .init(
				x: right - 1,
				y: top - 2 * open
			))
			path.addQuadCurve(
				to: .init(
					x: right,
					y: top + 1 - 2 * open
				),
				control: .init(
					x: right + 1,
					y: top - 2 * open
				)
			)
			path.addLine(to: .init(
				x: rect.maxX - 2,
				y: bottom - 1
			))
			path.addQuadCurve(
				to: .init(
					x: rect.maxX - 3,
					y: bottom
				),
				control: .init(
					x: rect.maxX - 2,
					y: bottom
				)
			)
			path.addLine(to: .init(
				x: 3,
				y: bottom
			))
			path.addQuadCurve(
				to: .init(
					x: 2,
					y: bottom - 1
				),
				control: .init(
					x: 2,
					y: bottom
				)
			)
			path.addLine(to: .init(
				x: left,
				y: top + 1
			))
			path.addQuadCurve(
				to: .init(
					x: left + 1,
					y: top
				),
				control: .init(
					x: left,
					y: top
				)
			)
			path.closeSubpath()
		}
	}
}
