import BrowserCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PageCaptureCodec {
	public static func decode(
		_ image: PageCaptureImage,
		limits: PageCaptureLimits = .init()
	) throws -> CGImage {
		try limits.validate(
			width: image.width,
			height: image.height,
			encodedBytes: image.png.count
		)
		guard
			let source = CGImageSourceCreateWithData(image.png as CFData, nil),
			CGImageSourceGetType(source) as String? == UTType.png.identifier,
			CGImageSourceGetCount(source) == 1,
			let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			let width = metadata[kCGImagePropertyPixelWidth] as? Int,
			let height = metadata[kCGImagePropertyPixelHeight] as? Int,
			width == image.width,
			height == image.height,
			(metadata[kCGImagePropertyOrientation] as? Int ?? 1) == 1
		else { throw PageCaptureFailure.invalidImage }

		try limits.validate(width: width, height: height)
		let options: CFDictionary = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
		guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, options)
		else { throw PageCaptureFailure.invalidImage }

		return decoded
	}

	public static func crop(
		_ frame: PageCaptureFrame,
		to region: PageCaptureRegion
	) throws -> PageCaptureImage {
		let pixels = try frame.pixels(in: region)
		let image = try decode(frame.image, limits: frame.request.limits)
		let rect: CGRect = .init(
			x: pixels.x,
			y: pixels.y,
			width: pixels.width,
			height: pixels.height
		)
		guard let cropped = image.cropping(to: rect)
		else { throw PageCaptureFailure.invalidRegion }

		let data = try encode(cropped, as: .png)
		try frame.request.limits.validate(
			width: cropped.width,
			height: cropped.height,
			encodedBytes: data.count
		)
		return .init(png: data, width: cropped.width, height: cropped.height)
	}

	/// Downscales `image` by `scale` (at most 1) and encodes it as `format`.
	/// A scale of 1 keeps every pixel; only the encoding changes.
	public static func encode(
		_ image: PageCaptureImage,
		scale: Double,
		as format: PageCaptureFormat
	) throws -> (data: Data, width: Int, height: Int) {
		guard scale.isFinite, scale > 0, scale <= 1
		else { throw PageCaptureFailure.invalidFormat }

		if scale == 1 {
			return (try encode(image, as: format), image.width, image.height)
		}

		let decoded = try decode(image, limits: .captured)
		let width = max(1, Int((Double(decoded.width) * scale).rounded()))
		let height = max(1, Int((Double(decoded.height) * scale).rounded()))
		guard
			let space = CGColorSpace(name: CGColorSpace.sRGB),
			let context = CGContext(
				data: nil,
				width: width,
				height: height,
				bitsPerComponent: 8,
				bytesPerRow: 0,
				space: space,
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			)
		else { throw PageCaptureFailure.encodingFailed }

		context.interpolationQuality = .high
		context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
		guard let scaled = context.makeImage() else { throw PageCaptureFailure.encodingFailed }
		return (try encode(scaled, as: format), width, height)
	}

	public static func encode(
		_ image: PageCaptureImage,
		as format: PageCaptureFormat
	) throws -> Data {
		if case .png = format {
			_ = try decode(image, limits: .captured)
			return image.png
		}
		return try encode(decode(image, limits: .captured), as: format)
	}

	public static func filename(
		title: String,
		format: PageCaptureFormat
	) -> String {
		let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
		let value = title.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
		var stem = ""
		for character in trimmed.precomposedStringWithCanonicalMapping {
			let candidate = stem + String(character)
			guard candidate.utf8.count <= 200 else { break }
			stem = candidate
		}
		return (stem.isEmpty ? "Page Capture" : stem) + "." + format.fileExtension
	}

	public static func write(
		_ image: PageCaptureImage,
		as format: PageCaptureFormat,
		to destination: URL
	) throws {
		let suffix = destination.pathExtension.lowercased()
		let isJPEGAlias: Bool = suffix == "jpeg" && format.fileExtension == "jpg"
		guard
			destination.isFileURL,
			suffix == format.fileExtension || isJPEGAlias
		else { throw PageCaptureFailure.invalidFormat }

		let data = try encode(image, as: format)
		try Task.checkCancellation()
		try data.write(to: destination, options: .atomic)
	}

	internal static func encode(
		_ original: CGImage,
		as format: PageCaptureFormat
	) throws -> Data {
		var image = original
		var properties: [CFString: Any] = [:]
		let type: UTType
		switch format {
		case .png:
			type = .png

		case let .jpeg(quality):
			guard quality.isFinite, (0...1).contains(quality)
			else { throw PageCaptureFailure.invalidFormat }

			type = .jpeg
			properties[kCGImageDestinationLossyCompressionQuality] = quality
			guard
				let space = CGColorSpace(name: CGColorSpace.sRGB),
				let context = CGContext(
					data: nil,
					width: image.width,
					height: image.height,
					bitsPerComponent: 8,
					bytesPerRow: 0,
					space: space,
					bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
				)
			else { throw PageCaptureFailure.encodingFailed }

			let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
			context.setFillColor(CGColor(gray: 1, alpha: 1))
			context.fill(bounds)
			context.draw(image, in: bounds)
			guard let opaque = context.makeImage() else { throw PageCaptureFailure.encodingFailed }
			image = opaque
		}
		let data: NSMutableData = .init()
		guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
		else { throw PageCaptureFailure.encodingFailed }

		CGImageDestinationAddImage(destination, image, properties as CFDictionary)
		guard CGImageDestinationFinalize(destination)
		else { throw PageCaptureFailure.encodingFailed }
		return data as Data
	}
}

extension PageCaptureLimits {
	/// What an image that already came out of a capture is decoded within: the largest limits
	/// any capture may ask for, past a whole page's defaults (DEV-1172). The capture itself held
	/// the image to its own.
	internal static let captured: Self = .init(
		maximumDimension: 16_384,
		maximumPixels: 67_108_864,
		maximumEncodedBytes: 67_108_864,
		timeoutMilliseconds: 30_000
	)
}
