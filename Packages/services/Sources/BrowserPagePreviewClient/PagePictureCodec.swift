import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decodes and encodes hover card pictures off the main actor (DEV-730).
public enum PagePictureCodec {
	/// Decodes a bounded raster image straight to at most `maximumPixelSize` on its long side.
	/// One-frame images only; anything ImageIO can't identify is refused.
	public static func thumbnail(
		from data: Data,
		maximumPixelSize: Int
	) -> CGImage? {
		guard
			!data.isEmpty,
			let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
			let type = CGImageSourceGetType(source) as String?,
			let identified = UTType(type), identified.conforms(to: .image), !identified.conforms(to: .svg),
			CGImageSourceGetCount(source) >= 1,
			let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			let width = properties[kCGImagePropertyPixelWidth] as? Int,
			let height = properties[kCGImagePropertyPixelHeight] as? Int,
			// A huge canvas would cost far more to decode than a card is worth.
			width > 0, height > 0, width * height <= 40_000_000
		else { return nil }

		let options: CFDictionary = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceShouldCacheImmediately: true,
			kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize),
		] as CFDictionary
		return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
	}

	/// JPEG at card quality, or nil when it would exceed what the store keeps.
	public static func jpeg(
		_ image: CGImage,
		quality: Double = 0.72
	) -> Data? {
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
		else { return nil }
		CGImageDestinationAddImage(destination, image, [
			kCGImageDestinationLossyCompressionQuality: quality,
		] as CFDictionary)
		guard
			CGImageDestinationFinalize(destination),
			data.length > 0, data.length <= BrowserPagePreviewStore.maximumPictureBytes
		else { return nil }
		return data as Data
	}
}
