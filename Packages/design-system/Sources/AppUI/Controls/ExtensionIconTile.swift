import AppKit
import ImageIO
import SwiftUI

/// An extension's icon on a quiet tile, or its first letter when it has none to show: the site
/// menu's Extensions row and Settings' extension list draw the same tile (DEV-824).
public struct ExtensionIconTile: View {
	private let name: String
	private let icon: Data?
	private let side: CGFloat

	/// - Parameters:
	///   - name: The extension's name, whose first letter stands in for a missing icon.
	///   - icon: The icon's encoded bytes, as the engine's icon path holds them.
	///   - side: The tile's side in points; the icon fills five-eighths of it.
	public init(
		name: String,
		icon: Data?,
		side: CGFloat = 32
	) {
		self.name = name
		self.icon = icon
		self.side = side
	}

	public var body: some View {
		Group {
			if let image = icon.flatMap(ExtensionIconImage.image) {
				Image(nsImage: image)
					.resizable()
					.interpolation(.high)
					.aspectRatio(contentMode: .fit)
					.frame(width: iconSide, height: iconSide)
			} else {
				Text(ExtensionIconImage.initial(name))
					.font(.system(size: (side * 13 / 32).rounded(), weight: .semibold, design: .rounded))
			}
		}
		.frame(width: side, height: side)
		.background(.quaternary, in: ArxControlShape())
	}

	private var iconSide: CGFloat {
		(side * 5 / 8).rounded()
	}
}

/// Decodes extension icons once per set of bytes, within bounds.
public enum ExtensionIconImage {
	/// Icons larger than this aren't drawn; manifest icons are small PNGs.
	public static let maximumBytes: Int = 512 * 1024

	/// The longest side of a decoded icon in pixels: a 64-point icon on a 2x display.
	internal static let maximumPixels: Int = 128

	/// Decoded icons by their bytes, so redraws don't decode again.
	@MainActor
	private static let cache: NSCache<NSData, NSImage> = .init()

	/// The letter a tile shows when the extension has no icon.
	public static func initial(_ name: String) -> String {
		name.first.map { String($0).uppercased() } ?? "?"
	}

	@MainActor
	public static func image(_ data: Data) -> NSImage? {
		let key = data as NSData
		if let cached = cache.object(forKey: key) { return cached }

		guard let image = decode(data) else { return nil }

		cache.setObject(image, forKey: key)
		return image
	}

	/// Bounded decode: an icon of at most 4096 pixels a side, drawn from a thumbnail of at most
	/// ``maximumPixels``, sized in points for a 2x display.
	public static func decode(_ data: Data) -> NSImage? {
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceShouldCacheImmediately: true,
			kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
		]
		guard
			!data.isEmpty,
			data.count <= maximumBytes,
			let source = CGImageSourceCreateWithData(data as CFData, nil),
			CGImageSourceGetCount(source) >= 1,
			let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			let width = properties[kCGImagePropertyPixelWidth] as? Int,
			let height = properties[kCGImagePropertyPixelHeight] as? Int,
			(1...4096).contains(width),
			(1...4096).contains(height),
			let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
		else { return nil }

		return .init(
			cgImage: thumbnail,
			size: .init(width: CGFloat(thumbnail.width) / 2, height: CGFloat(thumbnail.height) / 2)
		)
	}
}
