import BrowserCore
import CoreGraphics
import Foundation

extension PageCaptureCodec {
	/// Whether every sampled pixel in `region` of the frame's image is black or
	/// transparent, which is how the engine leaves protected media it can't read.
	public static func isBlank(
		_ frame: PageCaptureFrame,
		in region: PageCaptureRegion
	) -> Bool {
		guard
			let pixels = try? frame.pixels(in: region),
			let image = try? decode(frame.image, limits: frame.request.limits),
			let cropped = image.cropping(to: .init(
				x: pixels.x,
				y: pixels.y,
				width: pixels.width,
				height: pixels.height
			))
		else { return false }

		return isBlank(cropped)
	}

	/// Samples a small grid of `image`; a tolerance absorbs color-space rounding.
	public static func isBlank(
		_ image: CGImage,
		tolerance: UInt8 = 12
	) -> Bool {
		let side = 16
		var bytes = [UInt8](repeating: 0, count: side * side * 4)
		let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
			guard
				let context = CGContext(
					data: buffer.baseAddress,
					width: side,
					height: side,
					bitsPerComponent: 8,
					bytesPerRow: side * 4,
					space: CGColorSpace(name: CGColorSpace.sRGB)!,
					bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
				)
			else { return false }

			context.interpolationQuality = .none
			context.draw(image, in: .init(x: 0, y: 0, width: side, height: side))
			return true
		}
		guard drawn else { return false }

		for offset in stride(from: 0, to: bytes.count, by: 4) {
			let isTransparent = bytes[offset + 3] <= tolerance
			let isBlack = bytes[offset] <= tolerance
			&& bytes[offset + 1] <= tolerance
			&& bytes[offset + 2] <= tolerance
			if !isTransparent, !isBlack { return false }
		}
		return true
	}
}
