import Foundation

/// The look of the Arx identity card at the top of Settings › Arx. The case order is the
/// cycle order, so adding or removing a style is one case here plus its face in AppUI.
/// Presentation only: it changes nothing else in the browser.
public enum IdentityCardStyle: String, Codable, CaseIterable, Hashable, Sendable {
	case holographicFoil
	case liquidGlass
	case smokedGlass
	case prismGlass
	case spaceTint
	case graphite
	case titanium
	case obsidianGold
	case carbon
	case sunsetGrain
	case memberPass

	/// The style the cycle button moves to, wrapping from the last back to the first.
	public var next: Self {
		let styles = Self.allCases
		let index = styles.firstIndex(of: self) ?? styles.startIndex
		let nextIndex = styles.index(after: index)
		return nextIndex == styles.endIndex ? styles[styles.startIndex] : styles[nextIndex]
	}
}
