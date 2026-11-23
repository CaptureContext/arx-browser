import BrowserCore
import CustomDump
import Foundation
import SQLite3
import Testing
@testable import MigrationAssistant

/// DEV-897 and DEV-919's Arc mapping: each Arc space's colors become an Arx appearance, and
/// Favorites and pinned tabs bring their icons from Arc's `Favicons` database. Fixtures are
/// made up in the shapes other importers read; no real Arc data is read.
internal struct ArcAppearanceAndIconsTests {
	private static func color(
		_ red: Double,
		_ green: Double,
		_ blue: Double
	) -> String {
		#"{"red": \#(red), "green": \#(green), "blue": \#(blue), "alpha": 1, "colorSpace": "extendedSRGB"}"#
	}

	/// A gradient theme: a palette with a mid tone, and three base colors under Arc's
	/// nested `background` keys.
	private static let gradientTheme: String = """
	{
		"primaryColorPalette": {"midTone": \(color(0.95, 0.35, 0.2)), "shadedDark": \(color(0.2, 0.1, 0.1))},
		"background": {"single": {"_0": {"style": {"color": {"_0": {"blendedGradient": {"_0": {
			"baseColors": [\(color(0.95, 0.35, 0.2)), {"color": \(color(0.2, 0.4, 0.95))}, \(color(0.3, 0.8, 0.4)), \(color(1, 1, 1))],
			"wheel": {"angle": 12}
		}}}}}}}},
		"colorScheme": "dark"
	}
	"""

	private static func sidebar(
		theme: String,
		secondTheme: String = "null"
	) -> String {
		"""
		{"sidebar": {"containers": [{"global": {}}, {
			"topAppsContainerIDs": [{"default": true}, "top"],
			"spaces": ["s1", {
				"id": "s1", "title": "Home", "profile": {"default": true},
				"customInfo": {"iconType": {"icon": "🏠"}, "windowTheme": \(theme)},
				"containerIDs": ["pinned", "s1-pinned"]
			}, "s2", {
				"id": "s2", "title": "Plain", "profile": {"default": true},
				"customInfo": {"windowTheme": \(secondTheme)},
				"containerIDs": ["pinned", "s2-pinned"]
			}],
			"items": [
				"top", {"id": "top", "data": {"itemContainer": {}}, "childrenIds": ["fav"]},
				"fav", {"id": "fav", "data": {"tab": {"savedTitle": "Mail", "savedURL": "https://mail.example.org/inbox"}}, "childrenIds": []},
				"s1-pinned", {"id": "s1-pinned", "data": {"itemContainer": {}}, "childrenIds": ["pin", "other"]},
				"pin", {"id": "pin", "data": {"tab": {"savedTitle": "Swift", "savedURL": "https://swift.org/documentation#top"}}, "childrenIds": []},
				"other", {"id": "other", "data": {"tab": {"savedTitle": "None", "savedURL": "https://none.example.org/"}}, "childrenIds": []},
				"s2-pinned", {"id": "s2-pinned", "data": {"itemContainer": {}}, "childrenIds": []}
			]
		}]}}
		"""
	}

	// MARK: - Colors

	@Test
	internal func aGradientThemeBecomesATintWithStopsAndItsScheme() async throws {
		let snapshot = try ArcSidebar.snapshot(sidebar: Data(Self.sidebar(theme: Self.gradientTheme).utf8), localState: nil)
		let spaces = snapshot.records.filter { $0.kind == .space }.compactMap(\.space)
		let home = try #require(spaces.first { $0.name == "Home" }?.appearance)

		let midTone = ChromeTint(approximating: .init(red: 0.95, green: 0.35, blue: 0.2))
		#expect(home.tintHue == midTone.hue)
		#expect(home.tintIntensity == midTone.intensity)
		#expect(home.theme == .dark)
		// The second and third base colors, at Arx's default angle; a fourth doesn't fit.
		let gradient = try #require(home.gradient)
		expectNoDifference(gradient.stops, [
			ChromeTint(approximating: .init(red: 0.2, green: 0.4, blue: 0.95)),
			ChromeTint(approximating: .init(red: 0.3, green: 0.8, blue: 0.4)),
		])
		#expect(gradient.angle == ChromeGradient.defaultAngle)
		// A space without a theme keeps Arx's look.
		#expect(spaces.first { $0.name == "Plain" }?.appearance == nil)
	}

	@Test
	internal func aSingleColorThemeHasNoGradientAndFollowsTheApp() async throws {
		let theme = #"{"primaryColorPalette": {"midTone": \#(Self.color(0.4, 0.5, 0.9))}}"#
		let appearance = try #require(ArcSpaceTheme.appearance(try JSONSerialization.jsonObject(with: Data(theme.utf8))))
		#expect(appearance.gradient == nil)
		#expect(appearance.theme == nil)
		#expect(appearance.tintHue.map { abs($0 - 230) < 15 } == true)

		// Without a palette, the first color found stands in; without any, nothing.
		let nested = #"{"x": {"y": [\#(Self.color(0.1, 0.8, 0.2))]}, "isDark": false}"#
		let fallback = try #require(ArcSpaceTheme.appearance(try JSONSerialization.jsonObject(with: Data(nested.utf8))))
		#expect(fallback.tintHue.map { abs($0 - 125) < 15 } == true)
		#expect(fallback.theme == .light)
		#expect(ArcSpaceTheme.appearance(["red": "high"]) == nil)
		#expect(ArcSpaceTheme.appearance(["red": true, "green": 0, "blue": 0]) == nil)
	}

	@Test(arguments: [
		// Pure colors land on their own hue at full intensity.
		(1.0, 0.0, 0.0, 0.0, 1.0),
		(0.0, 1.0, 0.0, 120.0, 1.0),
		(0.0, 0.0, 1.0, 240.0, 1.0),
		// Grey has no color.
		(0.5, 0.5, 0.5, ChromeTint.default.hue, 0.0),
	])
	internal func colorsMapOntoHueAndIntensity(
		red: Double,
		green: Double,
		blue: Double,
		hue: Double,
		intensity: Double
	) async throws {
		let tint = ChromeTint(approximating: .init(red: red, green: green, blue: blue))
		let difference = abs(tint.hue - hue).truncatingRemainder(dividingBy: 360)
		#expect(min(difference, 360 - difference) < 0.5)
		#expect(abs(tint.intensity - intensity) < 0.001)
	}

	@Test
	internal func theConversionErrorStaysSmallAroundTheWheel() async throws {
		// The tint's own palette turns towards the source color: their chroma directions agree.
		for hue in stride(from: 0.0, to: 360, by: 15) {
			let source = Self.rgb(hue: hue, saturation: 0.7, brightness: 0.9)
			let tint = ChromeTint(approximating: source)
			let back = Self.rgb(hue: tint.hue, saturation: 0.7, brightness: 0.9)
			#expect(abs(source.red - back.red) < 0.02 && abs(source.green - back.green) < 0.02 && abs(source.blue - back.blue) < 0.02, "\(hue)")
			#expect(abs(tint.intensity - 0.7) < 0.001)
		}
	}

	private static func rgb(
		hue: Double,
		saturation: Double,
		brightness: Double
	) -> ChromePalette.RGB {
		let sector = (hue / 60).truncatingRemainder(dividingBy: 6)
		let fraction = sector - sector.rounded(.down)
		let p = brightness * (1 - saturation)
		let q = brightness * (1 - saturation * fraction)
		let t = brightness * (1 - saturation * (1 - fraction))
		let (r, g, b): (Double, Double, Double) = switch Int(sector) {
		case 0: (brightness, t, p)
		case 1: (q, brightness, p)
		case 2: (p, brightness, t)
		case 3: (p, q, brightness)
		case 4: (t, p, brightness)
		default: (brightness, p, q)
		}
		return .init(red: r, green: g, blue: b)
	}

	// MARK: - Icons

	private static func png(_ width: Int) -> Data {
		Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data([UInt8(width)])
	}

	private static func writeFavicons(to url: URL) throws {
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let database = try SQLiteDatabase(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
		func blob(_ data: Data) -> String { "X'" + data.map { String(format: "%02x", $0) }.joined() + "'" }
		try database.execute(
			"""
			CREATE TABLE favicons (id INTEGER PRIMARY KEY, url LONGVARCHAR NOT NULL, icon_type INTEGER DEFAULT 1);
			CREATE TABLE favicon_bitmaps (
				id INTEGER PRIMARY KEY, icon_id INTEGER NOT NULL, last_updated INTEGER DEFAULT 0,
				image_data BLOB, width INTEGER DEFAULT 0, height INTEGER DEFAULT 0
			);
			CREATE TABLE icon_mapping (id INTEGER PRIMARY KEY, page_url LONGVARCHAR NOT NULL, icon_id INTEGER);
			INSERT INTO favicons VALUES (1, 'https://mail.example.org/favicon.ico', 1), (2, 'https://swift.org/favicon.ico', 1),
				(3, 'https://swift.org/touch.png', 4), (4, 'https://none.example.org/broken.ico', 1);
			INSERT INTO favicon_bitmaps (icon_id, image_data, width) VALUES
				(1, \(blob(png(16))), 16), (1, \(blob(png(32))), 32), (1, \(blob(png(64))), 64),
				(2, \(blob(png(16))), 16), (3, \(blob(png(180))), 180), (4, X'47494638', 16);
			INSERT INTO icon_mapping (page_url, icon_id) VALUES
				('https://mail.example.org/inbox', 1), ('https://swift.org/', 2), ('https://swift.org/', 3),
				('https://none.example.org/', 4);
			"""
		)
	}

	@Test
	internal func favoritesAndPinnedTabsBringTheirIcons() async throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "arx-arc-\(UUID().uuidString)", directoryHint: .isDirectory)
		defer { try? FileManager.default.removeItem(at: root) }

		try FileManager.default.createDirectory(at: root.appending(path: "User Data"), withIntermediateDirectories: true)
		try Data(Self.sidebar(theme: Self.gradientTheme).utf8).write(to: root.appending(path: "StorableSidebar.json"))
		try Data(#"{"profile": {"info_cache": {"Default": {"name": "Personal"}}}}"#.utf8)
			.write(to: root.appending(path: "User Data/Local State"))
		try Self.writeFavicons(to: root.appending(path: "User Data/Default/Favicons"))

		let adapter = try #require(MigrationBrowserSources.arc(root))
		let snapshot = try await adapter.snapshot()
		let icons = Dictionary(uniqueKeysWithValues: snapshot.records.filter { $0.kind == .tab }.map { ($0.sourceItemID, $0.icon) })

		// The page's own icon at the smallest width of at least 32.
		#expect(icons["fav"] == Self.png(32))
		// No mapping for the page itself: the origin's front page, its favicon, not a touch icon.
		#expect(icons["pin"] == Self.png(16))
		// Something that isn't a PNG is left out.
		#expect(icons["other"] == .some(nil))

		// Icons don't change what the review compares.
		var withoutIcons = snapshot
		withoutIcons.records = withoutIcons.records.map { record in
			var record = record
			record.icon = nil
			return record
		}
		#expect(MigrationBrowserSources.snapshotID(withoutIcons.records) == MigrationBrowserSources.snapshotID(snapshot.records))
		// Validation keeps the icon for the destination.
		let record = try #require(snapshot.records.first { $0.sourceItemID == "fav" })
		let item = try record.validated(from: adapter.source.id).get()
		#expect(item.icon == Self.png(32))
	}
}
