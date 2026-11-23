import BrowserCaptureClient
import BrowserCore
import CoreGraphics
import CustomDump
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// DEV-757: the device capture's frame, drawn around the captured page.
internal struct PageCaptureDeviceFrameTests {
	@Test(arguments: [false, true])
	internal func thePageKeepsItsPixelsInsideTheDeviceOnTheGradient(_ isPortrait: Bool) throws {
		let page = try Self.page(width: isPortrait ? 180 : 400, height: isPortrait ? 390 : 260)
		let style = DeviceCaptureStyle(isPortrait: isPortrait, gradient: 0.2)
		let framed = try PageCaptureCodec.frame(page, in: style)
		let layout = DeviceCaptureLayout(
			screen: .init(width: page.width, height: page.height),
			isPortrait: isPortrait
		)

		expectNoDifference(framed.width, Int(layout.canvas.width.rounded(.down)))
		expectNoDifference(framed.height, Int(layout.canvas.height.rounded(.down)))
		let decoded = try PageCaptureCodec.decode(framed)

		// The page's centre is its own colour, the top-leading quadrant's red.
		let inside = try Self.color(
			decoded,
			x: Int(layout.screen.minX) + page.width / 4,
			y: Int(layout.screen.minY) + page.height / 4
		)
		expectNoDifference(inside, [255, 0, 0])

		// The canvas's corner is the gradient's first colour.
		let corner = try Self.color(decoded, x: 1, y: 1)
		let start = style.gradientColors.start
		#expect(abs(Double(corner[0]) - start.red * 255) < 12)
		#expect(abs(Double(corner[1]) - start.green * 255) < 12)
		#expect(abs(Double(corner[2]) - start.blue * 255) < 12)
	}

	@Test
	internal func aFrameThatWouldPassTheLimitsIsScaledDown() throws {
		let page = try Self.page(width: 400, height: 260)
		let limits = PageCaptureLimits(maximumDimension: 300)
		let framed = try PageCaptureCodec.frame(page, in: .default, limits: limits)
		#expect(framed.width <= 300 && framed.height <= 300)
		#expect(framed.width > 200)
	}

	/// DEV-1172: a whole page past the viewport limits saves as it is and frames scaled down.
	@Test
	internal func aWholePageTallerThanAViewportSavesAndFrames() throws {
		let page = try Self.page(width: 40, height: 9_000)
		#expect(throws: PageCaptureFailure.limitExceeded) { try PageCaptureCodec.decode(page) }

		let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let png = directory.appending(path: "page.png")
		try PageCaptureCodec.write(page, as: .png, to: png)
		expectNoDifference(try Data(contentsOf: png), page.png)
		let jpeg = directory.appending(path: "page.jpg")
		try PageCaptureCodec.write(page, as: .jpeg(quality: 0.8), to: jpeg)
		#expect(FileManager.default.fileExists(atPath: jpeg.path))
		let half = try PageCaptureCodec.encode(page, scale: 0.5, as: .png)
		#expect(half.width == 20 && half.height == 4_500)

		let framed = try PageCaptureCodec.frame(page, in: .default)
		#expect(framed.height <= 8_192)
		#expect(framed.height > framed.width)
	}

	/// Writes the framed captures, a window and a phone in light and dark, when
	/// `ARX_DESIGN_SNAPSHOTS` names a directory.
	@Test(
		.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil),
		arguments: [false, true]
	)
	internal func snapshots(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		for isPortrait in [false, true] {
			let page = try Self.page(width: isPortrait ? 390 : 1280, height: isPortrait ? 844 : 800, sketchedIn: dark)
			let style = DeviceCaptureStyle(isPortrait: isPortrait, gradient: 0.62, isDark: dark)
			let framed = try PageCaptureCodec.frame(page, in: style)
			let name = "device-capture-\(isPortrait ? "portrait" : "window")-\(dark ? "dark" : "light").png"
			try framed.png.write(to: directory.appending(path: name))
		}
	}

	/// A page in four coloured quadrants, or with `sketchedIn`, a page of a few bars: dark with
	/// light bars when it's true, light with dark bars when it's false.
	private static func page(
		width: Int,
		height: Int,
		sketchedIn dark: Bool? = nil
	) throws -> PageCaptureImage {
		var bytes: [UInt8] = []
		bytes.reserveCapacity(width * height * 4)
		for y in 0..<height {
			for x in 0..<width {
				let pixel: [UInt8]
				if let dark {
					let background: [UInt8] = dark ? [38, 38, 42] : [250, 250, 250]
					let ink: [UInt8] = dark ? [200, 200, 205] : [60, 60, 66]
					let row = y * 20 / height
					let isBar = [2, 5, 7, 9].contains(row) && x > width / 12 && x < width * (row == 2 ? 6 : 10) / 12
					pixel = isBar ? ink : background
				} else {
					let quadrants: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255]]
					pixel = quadrants[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)]
				}
				bytes += pixel + [255]
			}
		}
		let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
		let image = try #require(CGImage(
			width: width,
			height: height,
			bitsPerComponent: 8,
			bitsPerPixel: 32,
			bytesPerRow: width * 4,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
			provider: provider,
			decode: nil,
			shouldInterpolate: false,
			intent: .defaultIntent
		))
		let data = NSMutableData()
		let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
		CGImageDestinationAddImage(destination, image, nil)
		#expect(CGImageDestinationFinalize(destination))
		return .init(png: data as Data, width: width, height: height)
	}

	/// The RGB of one pixel, counted from the top-leading corner.
	private static func color(
		_ image: CGImage,
		x: Int,
		y: Int
	) throws -> [UInt8] {
		var bytes = [UInt8](repeating: 0, count: 4)
		try bytes.withUnsafeMutableBytes { storage in
			let context = try #require(CGContext(
				data: storage.baseAddress,
				width: 1,
				height: 1,
				bitsPerComponent: 8,
				bytesPerRow: 4,
				space: CGColorSpace(name: CGColorSpace.sRGB)!,
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
			))
			context.draw(image, in: .init(
				x: -x,
				y: -(image.height - 1 - y),
				width: image.width,
				height: image.height
			))
		}
		return Array(bytes.prefix(3))
	}
}
