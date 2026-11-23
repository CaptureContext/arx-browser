#if DEBUG
import BrowserCaptureClient
import BrowserCore
import CoreGraphics
import Foundation

internal enum CaptureSmokePixels {
	internal struct Patch: Decodable, Sendable {
		internal var x: Double
		internal var y: Double
		internal var red: Int
		internal var green: Int
		internal var blue: Int

		internal init(
			x: Double,
			y: Double,
			red: Int,
			green: Int,
			blue: Int
		) {
			self.x = x
			self.y = y
			self.red = red
			self.green = green
			self.blue = blue
		}
	}

	internal static func verify(
		_ frame: PageCaptureFrame,
		patches: [Patch]
	) throws {
		let image = try PageCaptureCodec.decode(frame.image, limits: frame.request.limits)

		for patch in patches {
			let position = try pixelPosition(frame, x: patch.x, y: patch.y)
			try expect(image, x: position.x, y: position.y, patch: patch)
		}
	}

	internal static func sample(
		_ frame: PageCaptureFrame,
		x: Double,
		y: Double
	) throws -> [UInt8] {
		let position = try pixelPosition(frame, x: x, y: y)
		let image = try PageCaptureCodec.decode(frame.image, limits: frame.request.limits)
		return try pixel(image, x: position.x, y: position.y)
	}

	internal static func expect(
		_ image: CGImage,
		x: Int,
		y: Int,
		patch: Patch
	) throws {
		let actual = try pixel(image, x: x, y: y)
		let expected = [patch.red, patch.green, patch.blue]

		// An 8-bit sRGB → Display P3 → sRGB round trip maps pure green to
		// [3, 255, 0] on macOS. Keep this bounded allowance separate from alpha.
		let colorsMatch = zip(actual.prefix(3), expected).allSatisfy {
			abs(Int($0.0) - $0.1) <= 3
		}

		guard colorsMatch, actual[3] == 255 else {
			throw CaptureSmokeFailure("pixel at \(x),\(y) was \(actual), expected \(expected + [255])")
		}
	}

	internal static func expectSamePixels(
		_ first: PageCaptureImage,
		_ second: PageCaptureImage
	) throws {
		guard first.width == second.width, first.height == second.height
		else { throw CaptureSmokeFailure("frozen crop dimensions changed") }

		let firstPixels = try normalizedPixels(PageCaptureCodec.decode(first))
		let secondPixels = try normalizedPixels(PageCaptureCodec.decode(second))

		guard firstPixels == secondPixels
		else { throw CaptureSmokeFailure("frozen crop pixels changed") }
	}

	private static func normalizedPixels(_ image: CGImage) throws -> [UInt8] {
		guard let space = CGColorSpace(name: CGColorSpace.sRGB)
		else { throw CaptureSmokeFailure("cannot normalize frozen crop") }

		var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
		try rgba.withUnsafeMutableBytes { bytes in
			let context = CGContext(
				data: bytes.baseAddress,
				width: image.width,
				height: image.height,
				bitsPerComponent: 8,
				bytesPerRow: image.width * 4,
				space: space,
				bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
			)
			guard let context
			else { throw CaptureSmokeFailure("cannot normalize frozen crop") }

			context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
		}

		return rgba
	}

	private static func pixelPosition(
		_ frame: PageCaptureFrame,
		x: Double,
		y: Double
	) throws -> (x: Int, y: Int) {
		try frame.validate()

		guard
			x.isFinite, y.isFinite,
			x >= 0, y >= 0,
			x < frame.viewportWidth, y < frame.viewportHeight
		else { throw CaptureSmokeFailure("fixture sample lies outside the viewport") }

		return (
			Int(floor(x * Double(frame.image.width) / frame.viewportWidth)),
			Int(floor(y * Double(frame.image.height) / frame.viewportHeight))
		)
	}

	private static func pixel(
		_ image: CGImage,
		x: Int,
		y: Int
	) throws -> [UInt8] {
		guard
			x >= 0, y >= 0,
			x < image.width, y < image.height,
			let sample = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
			let space = CGColorSpace(name: CGColorSpace.sRGB)
		else { throw CaptureSmokeFailure("cannot sample decoded pixel") }

		var rgba = [UInt8](repeating: 0, count: 4)
		try rgba.withUnsafeMutableBytes { bytes in
			let context = CGContext(
				data: bytes.baseAddress,
				width: 1,
				height: 1,
				bitsPerComponent: 8,
				bytesPerRow: 4,
				space: space,
				bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
			)
			guard let context
			else { throw CaptureSmokeFailure("cannot normalize captured pixel to sRGB") }

			context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
		}

		return rgba
	}
}
#endif
