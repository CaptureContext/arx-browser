import BrowserCore
import Testing

/// DEV-824 follow-up: a tile draws the action's default icon when one covers its size, as the
/// toolbar shows it, else the manifest's; the engine's single `iconPath` stays the fallback.
internal struct BrowserExtensionIconTests {
	@Test
	internal func theSmallestCoveringActionIconWinsThenTheManifests() {
		let item = BrowserExtension(
			id: "a",
			name: "Alpha",
			version: "1",
			state: .enabled,
			iconPath: "/x/32.png",
			icons: [16: "/x/16.png", 48: "/x/48.png", 128: "/x/128.png"],
			actionIcons: [16: "/x/action/16.png", 64: "/x/action/64.png"]
		)

		#expect(item.iconPath(pixels: 16) == "/x/action/16.png")
		#expect(item.iconPath(pixels: 40) == "/x/action/64.png")
		#expect(item.iconPath(pixels: 64) == "/x/action/64.png")
		// No action icon covers it: the manifest's covering one, not a smaller action icon.
		#expect(item.iconPath(pixels: 100) == "/x/128.png")
	}

	@Test
	internal func aSmallActionIconYieldsToACoveringManifestIcon() {
		let item = BrowserExtension(
			id: "a",
			name: "Alpha",
			version: "1",
			state: .enabled,
			icons: [16: "/x/16.png", 48: "/x/48.png"],
			actionIcons: [16: "/x/action/16.png", 32: "/x/action/32.png"]
		)

		#expect(item.iconPath(pixels: 32) == "/x/action/32.png")
		#expect(item.iconPath(pixels: 40) == "/x/48.png")
	}

	@Test
	internal func withNothingCoveringTheLargestIconIsDrawn() {
		let item = BrowserExtension(
			id: "a",
			name: "Alpha",
			version: "1",
			state: .enabled,
			iconPath: "/x/32.png",
			icons: [16: "/x/16.png", 32: "/x/32.png"],
			actionIcons: [19: "/x/action/19.png", 38: "/x/action/38.png"]
		)

		#expect(item.iconPath(pixels: 64) == "/x/action/38.png")
	}

	@Test
	internal func anEngineReportingOnlyOnePathKeepsIt() {
		let older = BrowserExtension(id: "a", name: "Alpha", version: "1", state: .enabled, iconPath: "/x/32.png")
		let bare = BrowserExtension(id: "b", name: "Beta", version: "1", state: .enabled)

		#expect(older.iconPath(pixels: 40) == "/x/32.png")
		#expect(bare.iconPath(pixels: 40) == nil)
	}
}
