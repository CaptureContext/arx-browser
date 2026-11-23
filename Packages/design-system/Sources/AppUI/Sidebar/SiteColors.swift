import CoreGraphics
import Observation
import SwiftUI

/// A color as three 0–1 components, so tables and tests can compare it exactly.
public struct SiteRGB: Hashable, Sendable {
	public var red: Double
	public var green: Double
	public var blue: Double

	public init(
		red: Double,
		green: Double,
		blue: Double
	) {
		self.red = red
		self.green = green
		self.blue = blue
	}

	/// From `0xRRGGBB`.
	public init(hex: UInt32) {
		self.init(
			red: Double((hex >> 16) & 0xFF) / 255,
			green: Double((hex >> 8) & 0xFF) / 255,
			blue: Double(hex & 0xFF) / 255
		)
	}

	public var color: Color { Color(red: red, green: green, blue: blue) }
}

/// A site's brand color as it highlights the site's tiles.
public enum SiteBrandColor: Hashable, Sendable {
	case solid(SiteRGB)

	/// For brands that are black on light backgrounds and white on dark ones.
	case adaptive(light: SiteRGB, dark: SiteRGB)

	/// For brands that are several colors at once, such as Google's.
	case gradient([SiteRGB])
}

/// Well-known sites' brand colors. Add a site by adding a line to `entries`.
public enum SiteBrandTable {
	internal struct Entry: Sendable {
		internal let domains: [String]
		internal let color: SiteBrandColor

		internal init(
			_ domains: [String],
			_ color: SiteBrandColor
		) {
			self.domains = domains
			self.color = color
		}
	}

	private static let black: SiteRGB = .init(hex: 0x1F2328)
	private static let white: SiteRGB = .init(hex: 0xFFFFFF)
	private static let monochrome: SiteBrandColor = .adaptive(light: black, dark: white)
	private static let google: SiteBrandColor = .gradient([
		.init(hex: 0x4285F4),
		.init(hex: 0xEA4335),
		.init(hex: 0xFBBC05),
		.init(hex: 0x34A853),
	])

	/// More specific domains first: `mail.google.com` wins over `google.com` by matching longer.
	internal static let entries: [Entry] = [
		.init(["youtube.com", "youtu.be", "music.youtube.com"], .solid(.init(hex: 0xFF0000))),
		.init(["google.com", "mail.google.com", "gmail.com", "workspace.google.com"], google),
		.init(["docs.google.com"], .solid(.init(hex: 0x4285F4))),
		.init(["drive.google.com"], google),
		.init(["calendar.google.com"], .solid(.init(hex: 0x4285F4))),
		.init(["meet.google.com"], .solid(.init(hex: 0x00897B))),
		.init(["maps.google.com"], .solid(.init(hex: 0x34A853))),
		.init(["github.com", "gist.github.com"], monochrome),
		.init(["figma.com"], .gradient([
			.init(hex: 0xF24E1E),
			.init(hex: 0xA259FF),
			.init(hex: 0x1ABCFE),
			.init(hex: 0x0ACF83),
		])),
		.init(["spotify.com", "open.spotify.com"], .solid(.init(hex: 0x1DB954))),
		.init(["x.com", "twitter.com"], monochrome),
		.init(["slack.com", "app.slack.com"], .gradient([
			.init(hex: 0x36C5F0),
			.init(hex: 0x2EB67D),
			.init(hex: 0xECB22E),
			.init(hex: 0xE01E5A),
		])),
		.init(["notion.so", "notion.com"], monochrome),
		.init(["linear.app"], .solid(.init(hex: 0x5E6AD2))),
		.init(["telegram.org", "web.telegram.org", "t.me"], .solid(.init(hex: 0x26A5E4))),
		.init(["icloud.com"], .solid(.init(hex: 0x3693F3))),
		.init(["apple.com"], monochrome),
		.init(["discord.com"], .solid(.init(hex: 0x5865F2))),
		.init(["reddit.com"], .solid(.init(hex: 0xFF4500))),
		.init(["netflix.com"], .solid(.init(hex: 0xE50914))),
		.init(["amazon.com"], .solid(.init(hex: 0xFF9900))),
		.init(["chatgpt.com", "openai.com"], monochrome),
		.init(["claude.ai", "anthropic.com"], .solid(.init(hex: 0xD97757))),
		.init(["whatsapp.com", "web.whatsapp.com"], .solid(.init(hex: 0x25D366))),
		.init(["instagram.com"], .gradient([
			.init(hex: 0xFEDA75),
			.init(hex: 0xFA7E1E),
			.init(hex: 0xD62976),
			.init(hex: 0x962FBF),
			.init(hex: 0x4F5BD5),
		])),
		.init(["facebook.com", "messenger.com"], .solid(.init(hex: 0x0866FF))),
		.init(["linkedin.com"], .solid(.init(hex: 0x0A66C2))),
		.init(["twitch.tv"], .solid(.init(hex: 0x9146FF))),
		.init(["dropbox.com"], .solid(.init(hex: 0x0061FF))),
		.init(["trello.com", "atlassian.net", "atlassian.com"], .solid(.init(hex: 0x0052CC))),
		.init(["perplexity.ai"], .solid(.init(hex: 0x20808D))),
		.init(["vercel.com"], monochrome),
		.init(["stackoverflow.com"], .solid(.init(hex: 0xF48024))),
		.init(["wikipedia.org"], monochrome),
		.init(["duckduckgo.com"], .solid(.init(hex: 0xDE5833))),
		.init(["zoom.us"], .solid(.init(hex: 0x0B5CFF))),
		.init(["pinterest.com"], .solid(.init(hex: 0xE60023))),
		.init(["medium.com"], monochrome),
		.init(["arc.net"], .solid(.init(hex: 0x3139FB))),
	]

	/// The brand color for a host or any of its parent domains, matching the longest domain.
	public static func color(forHost host: String?) -> SiteBrandColor? {
		guard var host = host?.lowercased(), !host.isEmpty else { return nil }
		if host.hasSuffix(".") { host.removeLast() }
		var best: (length: Int, color: SiteBrandColor)?
		for entry in entries {
			for domain in entry.domains where host == domain || host.hasSuffix("." + domain) {
				if domain.count > best?.length ?? 0 { best = (domain.count, entry.color) }
			}
		}
		return best?.color
	}
}

/// Where a tile's highlight color comes from: the brand table, then the favicon, then the accent.
public enum SiteHighlight: Hashable, Sendable {
	case brand(SiteBrandColor)
	case favicon(SiteRGB)
	case accent

	public static func resolve(
		host: String?,
		favicon: SiteRGB?
	) -> Self {
		if let brand = SiteBrandTable.color(forHost: host) { return .brand(brand) }
		if let favicon { return .favicon(favicon) }
		return .accent
	}

	/// The colors to draw, light first for adaptive brands.
	internal func colors(scheme: ColorScheme) -> [Color] {
		switch self {
		case let .brand(.solid(rgb)), let .favicon(rgb):
			[rgb.color]
		case let .brand(.adaptive(light, dark)):
			[(scheme == .dark ? dark : light).color]
		case let .brand(.gradient(colors)):
			colors.map(\.color)
		case .accent:
			// Plain colors are Arx's own accent; `style` draws the appearance's.
			[Color.resource(.browser.accent)]
		}
	}

	/// A stroke or fill in the site's color, sweeping around the shape when there are several.
	internal func style(scheme: ColorScheme) -> AnyShapeStyle {
		if case .accent = self { return AnyShapeStyle(BrowserTheme.accent) }
		let colors = colors(scheme: scheme)
		guard colors.count > 1 else { return AnyShapeStyle(colors[0]) }
		return AnyShapeStyle(AngularGradient(colors: colors + [colors[0]], center: .center))
	}
}

/// Finds a favicon's most common saturated color.
public enum FaviconPalette {
	/// `nil` when the icon is all grays, black, white or transparent, so the accent shows instead.
	public static func dominantColor(of image: CGImage) -> SiteRGB? {
		let width = min(image.width, 64)
		let height = min(image.height, 64)
		guard width > 0, height > 0 else { return nil }
		var pixels = [UInt8](repeating: 0, count: width * height * 4)
		let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
			guard let context = CGContext(
				data: buffer.baseAddress,
				width: width,
				height: height,
				bitsPerComponent: 8,
				bytesPerRow: width * 4,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			) else { return false }
			context.interpolationQuality = .none
			context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
			return true
		}
		guard drawn else { return nil }

		// Twelve hue buckets; each pixel counts by how opaque and saturated it is.
		var weights = [Double](repeating: 0, count: 12)
		var sums = [SiteRGB](repeating: .init(red: 0, green: 0, blue: 0), count: 12)
		for index in stride(from: 0, to: pixels.count, by: 4) {
			let alpha = Double(pixels[index + 3]) / 255
			guard alpha > 0.5 else { continue }
			let red = Double(pixels[index]) / 255 / alpha
			let green = Double(pixels[index + 1]) / 255 / alpha
			let blue = Double(pixels[index + 2]) / 255 / alpha
			let maximum = max(red, green, blue)
			let minimum = min(red, green, blue)
			let chroma = maximum - minimum

			// Grays, near-black and near-white say nothing about the brand.
			guard chroma > 0.2, maximum > 0.2 else { continue }
			let bucket = hueBucket(red: red, green: green, blue: blue, maximum: maximum, chroma: chroma)
			let weight = alpha * chroma
			weights[bucket] += weight
			sums[bucket].red += red * weight
			sums[bucket].green += green * weight
			sums[bucket].blue += blue * weight
		}
		guard
			let best = weights.indices.max(by: { weights[$0] < weights[$1] }),
			weights[best] > 0
		else { return nil }
		let weight = weights[best]
		return .init(
			red: min(1, sums[best].red / weight),
			green: min(1, sums[best].green / weight),
			blue: min(1, sums[best].blue / weight)
		)
	}

	private static func hueBucket(
		red: Double,
		green: Double,
		blue: Double,
		maximum: Double,
		chroma: Double
	) -> Int {
		var hue: Double
		if maximum == red {
			hue = (green - blue) / chroma
		} else if maximum == green {
			hue = (blue - red) / chroma + 2
		} else {
			hue = (red - green) / chroma + 4
		}
		hue = (hue * 60).truncatingRemainder(dividingBy: 360)
		if hue < 0 { hue += 360 }
		return min(11, Int(hue / 30))
	}
}

/// Favicon colors as icons load, per profile so nothing a profile loads shows in another.
@MainActor
@Observable
public final class SiteColorCache {
	public struct Key: Hashable, Sendable {
		public let profileID: UUID
		public let host: String

		public init(
			profileID: UUID,
			host: String
		) {
			self.profileID = profileID
			self.host = host
		}

		public init?(_ icon: SidebarItem.SiteIcon?) {
			guard let icon, let host = icon.pageURL.host?.lowercased() else { return nil }
			self.init(profileID: icon.profileID, host: host)
		}
	}

	public nonisolated static let shared: SiteColorCache = .init()

	private var colors: [Key: SiteRGB] = [:]

	public nonisolated init() {}

	public func color(for key: Key?) -> SiteRGB? {
		key.flatMap { colors[$0] }
	}

	public func store(
		_ color: SiteRGB?,
		for key: Key?
	) {
		guard let key, colors[key] != color else { return }
		colors[key] = color
	}

	/// A tile's highlight: the brand table, then this favicon's color, then the accent.
	public func highlight(for icon: SidebarItem.SiteIcon?) -> SiteHighlight {
		.resolve(host: icon?.pageURL.host, favicon: color(for: Key(icon)))
	}
}

extension EnvironmentValues {
	@Entry
	public var siteColors: SiteColorCache = .shared
}
