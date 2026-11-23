import BrowserCore
import CoreGraphics
import Foundation

extension PageCaptureCodec {
	/// The captured page in a device on a gradient (DEV-757): a phone in portrait, else a
	/// window. Drawn here, from `DeviceCaptureLayout`; nothing comes from another app. The
	/// whole image is scaled down when it would pass `limits`.
	public static func frame(
		_ image: PageCaptureImage,
		in style: DeviceCaptureStyle,
		limits: PageCaptureLimits = .init()
	) throws -> PageCaptureImage {
		// The page met the capture's own limits, a whole page's at most (DEV-1172); `limits`
		// bounds the framed image.
		let page = try decode(image, limits: .captured)
		let full: DeviceCaptureLayout = .init(
			screen: .init(width: page.width, height: page.height),
			isPortrait: style.isPortrait
		)
		let layout = full.scaled(by: fittingScale(for: full.canvas, limits: limits))
		let width = max(1, Int(layout.canvas.width.rounded(.down)))
		let height = max(1, Int(layout.canvas.height.rounded(.down)))
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

		// Top-leading coordinates, as the layout gives them.
		context.translateBy(x: 0, y: Double(height))
		context.scaleBy(x: 1, y: -1)
		context.interpolationQuality = .high

		drawGradient(style, size: layout.canvas, in: context, space: space)
		drawDevice(style, layout: layout, in: context)
		drawPage(page, layout: layout, in: context)
		context.setFillColor(cgColor(style.detailColor))
		for detail in layout.details {
			context.addPath(CGPath(
				roundedRect: detail,
				cornerWidth: detail.height / 2,
				cornerHeight: detail.height / 2,
				transform: nil
			))
		}
		context.fillPath()

		guard let framed = context.makeImage()
		else { throw PageCaptureFailure.encodingFailed }

		let data = try encode(framed, as: .png)
		try limits.validate(width: framed.width, height: framed.height, encodedBytes: data.count)
		return .init(png: data, width: framed.width, height: framed.height)
	}

	/// At most 1: what keeps `canvas` within the limits' dimension and pixel count.
	internal static func fittingScale(
		for canvas: CGSize,
		limits: PageCaptureLimits
	) -> Double {
		let longest = max(Double(canvas.width), Double(canvas.height), 1)
		let pixels = max(Double(canvas.width) * Double(canvas.height), 1)
		return min(
			1,
			Double(limits.maximumDimension) / longest,
			(Double(limits.maximumPixels) / pixels).squareRoot()
		)
	}

	private static func drawGradient(
		_ style: DeviceCaptureStyle,
		size: CGSize,
		in context: CGContext,
		space: CGColorSpace
	) {
		let (start, end) = style.gradientColors
		let colors = [cgColor(start), cgColor(end)] as CFArray
		guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])
		else { return }

		context.drawLinearGradient(
			gradient,
			start: .zero,
			end: .init(x: size.width, y: size.height),
			options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
		)
	}

	private static func drawDevice(
		_ style: DeviceCaptureStyle,
		layout: DeviceCaptureLayout,
		in context: CGContext
	) {
		let body = CGPath(
			roundedRect: layout.device,
			cornerWidth: layout.deviceCornerRadius,
			cornerHeight: layout.deviceCornerRadius,
			transform: nil
		)
		let lift = layout.device.height * 0.02
		context.saveGState()

		// The context is flipped, so a positive offset falls downwards on the image.
		context.setShadow(
			offset: .init(width: 0, height: lift * 0.5),
			blur: lift * 2,
			color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: style.isDark ? 0.45 : 0.28)
		)
		context.setFillColor(cgColor(style.deviceColor))
		context.addPath(body)
		context.fillPath()
		context.restoreGState()
	}

	private static func drawPage(
		_ page: CGImage,
		layout: DeviceCaptureLayout,
		in context: CGContext
	) {
		let screen = layout.screen
		context.saveGState()
		context.addPath(CGPath(
			roundedRect: screen,
			cornerWidth: layout.screenCornerRadius,
			cornerHeight: layout.screenCornerRadius,
			transform: nil
		))
		context.clip()

		// Undo the flip for the page itself, which CoreGraphics draws bottom-up.
		context.translateBy(x: screen.minX, y: screen.maxY)
		context.scaleBy(x: 1, y: -1)
		context.draw(page, in: .init(origin: .zero, size: screen.size))
		context.restoreGState()
	}

	private static func cgColor(_ color: DeviceCaptureColor) -> CGColor {
		CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
	}
}
