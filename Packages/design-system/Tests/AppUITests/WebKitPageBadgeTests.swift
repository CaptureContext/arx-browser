@testable import AppUI
import Testing

/// The WebKit badge's shape (DEV-1242): the compass on a backing a point wider on every side,
/// whose continuous corners are a quarter of its side.
internal struct WebKitPageBadgeTests {
	@Test
	internal func theBackingIsAPointWiderThanTheCompassOnEverySide() {
		#expect(WebKitPageBadge.backingSize == WebKitPageBadge.compassSize + 2)
	}

	@Test
	internal func theBackingsCornersAreAQuarterOfItsSide() {
		#expect(WebKitPageBadge.backingCornerRadius == WebKitPageBadge.backingSize / 4)
	}

	@Test
	internal func itLandsOnWholePoints() {
		for value in [WebKitPageBadge.compassSize, WebKitPageBadge.backingInset, WebKitPageBadge.offset] {
			#expect(value == value.rounded())
		}
	}
}
