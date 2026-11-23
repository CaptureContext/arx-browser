import SwiftUI

/// How reading mode sets an article (DEV-1028): one of four themes, a text size and a column
/// width, kept for every article.
public struct ReaderAppearance: Equatable, Sendable {
	public enum Theme: String, CaseIterable, Sendable {
		case light
		case sepia
		case gray
		case dark

		public var background: String {
			switch self {
			case .light: "#FFFFFF"
			case .sepia: "#F8F1E3"
			case .gray: "#4A4A4D"
			case .dark: "#1C1C1E"
			}
		}

		public var text: String {
			switch self {
			case .light: "#1D1D1F"
			case .sepia: "#4F3E2C"
			case .gray: "#EDEDEF"
			case .dark: "#E5E5E7"
			}
		}

		public var secondary: String {
			switch self {
			case .light: "#6E6E73"
			case .sepia: "#8A7259"
			case .gray: "#BDBDC2"
			case .dark: "#98989D"
			}
		}

		public var link: String {
			switch self {
			case .light: "#0A66D8"
			case .sepia: "#A0522D"
			case .gray: "#A8CCFF"
			case .dark: "#6FB1FF"
			}
		}

		public var isDark: Bool { self == .gray || self == .dark }

		public var title: String {
			switch self {
			case .light: String.localized(.appUI.reader.themeLight)
			case .sepia: String.localized(.appUI.reader.themeSepia)
			case .gray: String.localized(.appUI.reader.themeGray)
			case .dark: String.localized(.appUI.reader.themeDark)
			}
		}

		internal var swatch: Color {
			Color(hex: background)
		}
	}

	/// Text sizes in points, smallest first.
	public static let textSizes: [Int] = [14, 16, 18, 20, 22, 25, 28]

	/// Column widths in points, narrowest first.
	public static let widths: [Int] = [560, 680, 800, 960]

	public var theme: Theme
	public var textSize: Int
	public var width: Int

	public init(
		theme: Theme = .light,
		textSize: Int = 18,
		width: Int = 680
	) {
		self.theme = theme
		self.textSize = Self.nearest(textSize, in: Self.textSizes)
		self.width = Self.nearest(width, in: Self.widths)
	}

	public var canShrinkText: Bool { textSize > Self.textSizes[0] }
	public var canGrowText: Bool { textSize < Self.textSizes[Self.textSizes.count - 1] }
	public var canNarrow: Bool { width > Self.widths[0] }
	public var canWiden: Bool { width < Self.widths[Self.widths.count - 1] }

	public func steppingText(by step: Int) -> Self {
		var appearance = self
		appearance.textSize = Self.step(textSize, by: step, in: Self.textSizes)
		return appearance
	}

	public func steppingWidth(by step: Int) -> Self {
		var appearance = self
		appearance.width = Self.step(width, by: step, in: Self.widths)
		return appearance
	}

	private static func nearest(
		_ value: Int,
		in values: [Int]
	) -> Int {
		values.min { abs($0 - value) < abs($1 - value) } ?? value
	}

	private static func step(
		_ value: Int,
		by step: Int,
		in values: [Int]
	) -> Int {
		let index = values.firstIndex(of: nearest(value, in: values)) ?? 0
		return values[min(max(index + step, 0), values.count - 1)]
	}
}

extension Color {
	/// A `#RRGGBB` color, as the reader's themes name theirs for its page and its controls alike.
	fileprivate init(hex: String) {
		let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
		self.init(
			.sRGB,
			red: Double((value >> 16) & 0xFF) / 255,
			green: Double((value >> 8) & 0xFF) / 255,
			blue: Double(value & 0xFF) / 255
		)
	}
}
