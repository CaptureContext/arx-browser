import SwiftUI

/// Arx's own drawings of symbols, from the Figma icon set, for the places that show them in
/// place of the SF Symbol of the same name (DEV-1251). They're drawn in a 20-point square for a
/// 13-point symbol and scale with `pointSize` as a symbol does with its font.
public struct FigmaSymbol: View {
	public enum Name: Sendable {
		/// Copy Link: Figma's `link`, two round hooks with a dash between them, for SF Symbols' `link`.
		case link

		/// The site menu: Figma's `slider.horizontal.2.square`.
		case siteMenu

		/// Hide Element (DEV-1298): Figma's `scope`, a ring with four ticks, node 128:344.
		case scope

		/// Capture Page (DEV-1333): viewfinder corners with three lines, two full and a short one,
		/// for SF Symbols' `text.viewfinder`. Figma's `Icon/text.viewfinder`, node 329:66.
		case textViewfinder
	}

	private let name: Name
	private let pointSize: CGFloat

	public init(
		_ name: Name,
		pointSize: CGFloat
	) {
		self.name = name
		self.pointSize = pointSize
	}

	public var body: some View {
		image
			.renderingMode(.template)
			.resizable()
			.interpolation(.high)
			.scaledToFit()
			.frame(width: side, height: side)
			.accessibilityHidden(true)
	}

	private var image: Image {
		switch name {
		case .link: Image("glyph.link", bundle: .module)
		case .siteMenu: Image("glyph.siteMenu", bundle: .module)
		case .scope: Image("glyph.scope", bundle: .module)
		case .textViewfinder: Image("glyph.textViewfinder", bundle: .module)
		}
	}

	/// The drawing's square: 20 points for a 13-point symbol, as in Figma.
	private var side: CGFloat {
		(pointSize * 20 / 13).rounded()
	}
}
