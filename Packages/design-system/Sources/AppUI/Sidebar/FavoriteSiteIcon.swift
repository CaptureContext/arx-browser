import AppKit
import ImageIO
import SwiftUI

public struct BrowserSiteIconLoader: Sendable {
	/// An icon on screen: a missing one may be fetched from its site.
	public let icons: @MainActor @Sendable (SidebarItem.SiteIcon) -> AsyncStream<Data?>

	/// An icon mounted off screen: only what's already on this Mac, never fetched.
	public let cachedIcons: @MainActor @Sendable (SidebarItem.SiteIcon) -> AsyncStream<Data?>

	public init(
		icons: @escaping @MainActor @Sendable (SidebarItem.SiteIcon) -> AsyncStream<Data?> = { _ in
			.init { $0.finish() }
		},
		cachedIcons: (@MainActor @Sendable (SidebarItem.SiteIcon) -> AsyncStream<Data?>)? = nil
	) {
		self.icons = icons
		self.cachedIcons = cachedIcons ?? icons
	}
}

extension EnvironmentValues {
	@Entry
	public var browserSiteIcons: BrowserSiteIconLoader = .init()

	/// Whether the site icons here are on screen, so one Arx has no copy of may be fetched from
	/// its site. Views mounted but hidden (a neighbouring space, the closed Library, a hidden
	/// sidebar) read only the icons already on this Mac until they show. Set it with
	/// ``SwiftUI/View/siteIconsShown(_:)``, which keeps an ancestor's `false`.
	@Entry
	public var siteIconsShown: Bool = true
}

extension View {
	/// Marks the site icons inside as on screen or not. Hidden inside a hidden view stays hidden.
	public func siteIconsShown(_ isShown: Bool) -> some View {
		modifier(SiteIconsShown(isShown: isShown))
	}
}

private struct SiteIconsShown: ViewModifier {
	private let isShown: Bool

	@Environment(\.siteIconsShown)
	private var isInheritedShown

	fileprivate init(isShown: Bool) {
		self.isShown = isShown
	}

	fileprivate func body(content: Content) -> some View {
		content.environment(\.siteIconsShown, isInheritedShown && isShown)
	}
}

internal struct FavoriteSiteIcon: View {
	private let key: SidebarItem.SiteIcon?
	private let fallback: String
	private let tint: SidebarTint
	private let size: CGFloat
	private let fallbackSize: CGFloat
	private let fallbackWeight: Font.Weight
	private let showsPlaceholder: Bool

	@Environment(\.browserSiteIcons)
	private var loader

	@Environment(\.siteIconsShown)
	private var isShown

	@Environment(\.siteColors)
	private var siteColors

	@SwiftUI.State
	private var loaded: Loaded?

	internal init(
		key: SidebarItem.SiteIcon?,
		fallback: String,
		tint: SidebarTint,
		size: CGFloat = 17,
		fallbackSize: CGFloat = 17,
		fallbackWeight: Font.Weight = .semibold,
		showsPlaceholder: Bool = false
	) {
		self.key = key
		self.fallback = fallback
		self.tint = tint
		self.size = size
		self.fallbackSize = fallbackSize
		self.fallbackWeight = fallbackWeight
		self.showsPlaceholder = showsPlaceholder
		self._loaded = .init(initialValue: nil)
	}

	internal var body: some View {
		Group {
			switch Content(
				image: loaded?.image,
				key: key,
				fallback: fallback,
				showsPlaceholder: showsPlaceholder
			) {
			case let .image(image):
				Image(nsImage: image)
					.resizable()
					.interpolation(.high)
					.scaledToFit()
					.frame(width: size, height: size)

			case let .glyph(glyph):
				TourSiteGlyphView(glyph: glyph, size: size)

			case .assistant:
				ProfileSmiley()
					.frame(width: fallbackSize - 1, height: fallbackSize - 1)
					.foregroundStyle(BrowserTheme.text.opacity(0.85))

			case .placeholder:
				SiteIconPlaceholder(size: size)

			case let .symbol(symbol):
				Image(systemName: symbol)
					.font(.system(size: fallbackSize, weight: fallbackWeight))
					.foregroundStyle(tint.color)
			}
		}
		.accessibilityHidden(true)

		// Coming on screen asks again, now allowed to fetch; the icon shown so far stays.
		.task(id: Request(key: key, isShown: isShown)) {
			if let current = loaded, key.map(current.key.isSameSite) != true {
				loaded = nil
			}
			guard let key else { return }
			var isLoading = true
			let icons = isShown ? loader.icons(key) : loader.cachedIcons(key)
			for await data in icons {
				guard !Task.isCancelled else { return }
				let cgImage = data.flatMap(Self.cgImage)
				let image = cgImage.map(Self.image)

				// The stream opens with nil while it looks the icon up, which says nothing about this page.
				defer { isLoading = false }
				if image == nil, isLoading, loaded != nil { continue }
				loaded = image.map { .init(key: key, image: $0) }
				if let cgImage {
					siteColors.store(FaviconPalette.dominantColor(of: cgImage), for: .init(key))
				}
			}
		}
	}

	/// Validate dimensions before decoding; previews can inject their own loader.
	internal static func image(_ data: Data) -> NSImage? {
		cgImage(data).map(image)
	}

	private static func image(_ cgImage: CGImage) -> NSImage {
		.init(cgImage: cgImage, size: .init(width: cgImage.width, height: cgImage.height))
	}

	internal static func cgImage(_ data: Data) -> CGImage? {
		guard
			!data.isEmpty,
			data.count <= 65_536,
			let source = CGImageSourceCreateWithData(data as CFData, nil),
			CGImageSourceGetType(source) as String? == "public.png",
			CGImageSourceGetCount(source) == 1,
			let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			let width = properties[kCGImagePropertyPixelWidth] as? Int,
			let height = properties[kCGImagePropertyPixelHeight] as? Int,
			(1...32).contains(width),
			(1...32).contains(height),
			let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
		else { return nil }

		return image
	}

	/// What the icon shows. A site tab with no live or stored icon shows the placeholder
	/// instead of the generic globe, when its view asks for one (DEV-809).
	internal enum Content {
		case image(NSImage)
		case glyph(TourSiteGlyph)
		case assistant
		case placeholder
		case symbol(String)

		internal init(
			image: NSImage?,
			key: SidebarItem.SiteIcon?,
			fallback: String,
			showsPlaceholder: Bool
		) {
			if let image {
				self = .image(image)

			} else if let glyph = TourSiteGlyph(symbol: fallback) {
				self = .glyph(glyph)

			} else if fallback == SidebarItem.assistantSymbol {
				self = .assistant

			} else if showsPlaceholder, key != nil, fallback == SidebarItem.siteSymbol {
				self = .placeholder

			} else {
				self = .symbol(fallback)
			}
		}

		internal var kind: Kind {
			switch self {
			case .image: .image
			case .glyph: .glyph
			case .assistant: .assistant
			case .placeholder: .placeholder
			case .symbol: .symbol
			}
		}

		internal enum Kind: Equatable {
			case image
			case glyph
			case assistant
			case placeholder
			case symbol
		}
	}

	private struct Request: Equatable {
		internal let key: SidebarItem.SiteIcon?
		internal let isShown: Bool

		internal init(
			key: SidebarItem.SiteIcon?,
			isShown: Bool
		) {
			self.key = key
			self.isShown = isShown
		}
	}

	private struct Loaded {
		internal let key: SidebarItem.SiteIcon
		internal let image: NSImage

		internal init(
			key: SidebarItem.SiteIcon,
			image: NSImage
		) {
			self.key = key
			self.image = image
		}
	}
}

/// A softly lit translucent squircle where a site's icon goes when it has none (DEV-809).
internal struct SiteIconPlaceholder: View {
	private let size: CGFloat

	@Environment(\.colorScheme)
	private var colorScheme

	internal init(size: CGFloat) {
		self.size = size
	}

	internal var body: some View {
		let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
		let opacity = colorScheme == .dark ? 0.27 : 0.16
		shape
			.fill(
				LinearGradient(
					colors: [
						BrowserTheme.text.opacity(opacity + 0.05),
						BrowserTheme.text.opacity(opacity - 0.03),
					],
					startPoint: .top,
					endPoint: .bottom
				)
			)
			.overlay {
				shape.strokeBorder(BrowserTheme.text.opacity(0.06), lineWidth: 0.5)
			}
			.frame(width: size, height: size)
	}
}
