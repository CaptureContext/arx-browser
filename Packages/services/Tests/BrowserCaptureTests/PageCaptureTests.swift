import BrowserCaptureClient
import BrowserCore
import CoreGraphics
import CustomDump
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import _TestSupport

internal struct PageCaptureTests {
	@Test
	internal func documentImageExtentAndCropRemainIndependentOfViewportAndNegativeOverflow() throws {
		var frame = try fixture()
		frame.request.mode = .fullDocument
		frame.viewportWidth = 0.5
		frame.viewportHeight = 0.5
		frame.documentGeometry = .init(
			documentRect: .init(x: -10, y: -20, width: 2, height: 2),
			visibleRect: .init(x: 0, y: 0, width: 1, height: 1),
			scrollX: 0.25,
			scrollY: 1.25,
			zoomLevel: 0.5,
			pageScale: 1,
			rasterScale: 1
		)
		try frame.validate()
		expectNoDifference(
			try frame.pixels(in: .init(x: 1, y: 1, width: 1, height: 1)),
			.init(x: 1, y: 1, width: 1, height: 1)
		)
		#expect(frame.viewportWidth == 0.5 && frame.documentGeometry?.documentRect.x == -10)
		var invalid = frame
		invalid.documentGeometry?.rasterScale = 2
		#expect(throws: PageCaptureFailure.invalidImage) { try invalid.validate() }
		invalid = frame
		invalid.documentGeometry?.documentRect.width = 3
		#expect(throws: PageCaptureFailure.invalidImage) { try invalid.validate() }
		invalid = frame
		invalid.request.mode = .viewport
		#expect(throws: PageCaptureFailure.invalidImage) { try invalid.validate() }
	}

	@Test
	internal func fractionalCoordinatesUseMeasuredPixelsAndRoundOutward() async throws {
		var frame = try fixture()
		frame.viewportWidth = 1.6
		frame.viewportHeight = 1.6
		frame.deviceScale = 2
		expectNoDifference(
			try frame.pixels(in: .init(x: 0.2, y: 0.8, width: 0.6, height: 0.6)),
			.init(x: 0, y: 1, width: 1, height: 1)
		)
		#expect(throws: PageCaptureFailure.invalidRegion) {
			try frame.pixels(in: .init(x: -.infinity, y: 0, width: 1, height: 1))
		}
		#expect(throws: PageCaptureFailure.invalidRegion) {
			try frame.pixels(in: .init(x: 1, y: 0, width: 1, height: 1))
		}
	}

	@Test
	internal func pixelBoundariesRemainStableAcrossFractionalScales() async throws {
		for scale in [0.8, 1, 1.1, 1.25, 1.3, 1.5, 1.75, 2, 2.5, 3] {
			var frame = try fixture()
			frame.viewportWidth = 2 / scale
			frame.viewportHeight = 2 / scale
			frame.deviceScale = scale
			expectNoDifference(
				try frame.pixels(in: .init(x: 1 / scale, y: 1 / scale, width: 1 / scale, height: 1 / scale)),
				.init(x: 1, y: 1, width: 1, height: 1)
			)
		}
		var frame = try fixture()
		frame.viewportWidth = 0.3
		expectNoDifference(
			try frame.pixels(in: .init(x: 0.1, y: 0, width: 0.2, height: 1)),
			.init(x: 0, y: 0, width: 2, height: 1)
		)
	}

	@Test
	internal func cropReadsFrozenTopLeftPixelsAndExportsExactDimensions() async throws {
		let frame = try fixture()
		let cropped = try PageCaptureCodec.crop(frame, to: .init(x: 0, y: 0, width: 1, height: 1))
		expectNoDifference(cropped.width, 1)
		expectNoDifference(cropped.height, 1)
		expectNoDifference(try pixel(PageCaptureCodec.decode(cropped)), [255, 0, 0, 255])
		let lower = try PageCaptureCodec.crop(frame, to: .init(x: 0, y: 1, width: 1, height: 1))
		expectNoDifference(try pixel(PageCaptureCodec.decode(lower)), [0, 0, 255, 255])
		expectNoDifference(try PageCaptureCodec.encode(frame.image, as: .png), frame.image.png)
	}

	@Test
	internal func jpegFlattensTransparencyOntoWhiteAndValidatesQuality() async throws {
		let transparent = try PageCaptureCodec.crop(fixture(), to: .init(x: 1, y: 1, width: 1, height: 1))
		expectNoDifference(try pixel(PageCaptureCodec.decode(transparent)), [0, 0, 0, 0])
		let jpeg = try PageCaptureCodec.encode(transparent, as: .jpeg(quality: 1))
		let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
		expectNoDifference(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
		let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
		let rgba = try pixel(image)
		#expect(rgba.prefix(3).allSatisfy { $0 >= 250 })
		#expect(throws: PageCaptureFailure.invalidFormat) {
			try PageCaptureCodec.encode(transparent, as: .jpeg(quality: .nan))
		}
	}

	/// DEV-1172: a whole page takes up to 16384 pixels a side and 3072 × 16384 in all.
	@Test
	internal func wholePageLimitsTakeTheLargestTexture() async throws {
		try PageCaptureLimits.wholePage.validate(width: 3_072, height: 16_384)
		#expect(throws: PageCaptureFailure.limitExceeded) {
			try PageCaptureLimits.wholePage.validate(width: 1, height: 16_385)
		}
		#expect(throws: PageCaptureFailure.limitExceeded) {
			try PageCaptureLimits.wholePage.validate(width: 3_073, height: 16_384)
		}
		#expect(throws: PageCaptureFailure.invalidImage) {
			try PageCaptureLimits(maximumDimension: 16_385).validate(width: 1, height: 1)
		}
	}

	@Test
	internal func limitsRejectOverflowAndMetadataMismatchBeforeDecode() async throws {
		#expect(throws: PageCaptureFailure.limitExceeded) {
			try PageCaptureLimits().validate(width: .max, height: .max)
		}
		#expect(throws: PageCaptureFailure.limitExceeded) {
			try PageCaptureLimits().validate(width: 8_192, height: 8_192)
		}
		#expect(throws: PageCaptureFailure.invalidImage) {
			try PageCaptureLimits(maximumPixels: .max).validate(width: 1, height: 1)
		}
		var frame = try fixture()
		frame.viewportWidth = .leastNonzeroMagnitude
		#expect(throws: PageCaptureFailure.invalidImage) { try frame.validate() }
		var image = try fixture().image
		image.width = 1
		#expect(throws: PageCaptureFailure.invalidImage) { try PageCaptureCodec.decode(image) }
		image.png = Data([0, 1, 2, 3])
		#expect(throws: PageCaptureFailure.invalidImage) { try PageCaptureCodec.decode(image) }
	}

	@Test
	internal func saveIsAtomicAndDoesNotReplaceOriginalOnEncodingFailure() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let destination = directory.appendingPathComponent("image.jpg")
		let old = Data("existing image".utf8)
		try old.write(to: destination)
		let image = try fixture().image
		#expect(throws: PageCaptureFailure.invalidFormat) {
			try PageCaptureCodec.write(image, as: .jpeg(quality: -1), to: destination)
		}
		expectNoDifference(try Data(contentsOf: destination), old)
		#expect(throws: PageCaptureFailure.invalidFormat) {
			try PageCaptureCodec.write(image, as: .png, to: destination)
		}
		let png = directory.appendingPathComponent("image.png")
		try old.write(to: png)
		try PageCaptureCodec.write(image, as: .png, to: png)
		expectNoDifference(try Data(contentsOf: png), image.png)
		let unicodeFilename = PageCaptureCodec.filename(title: String(repeating: "🌍", count: 160), format: .png)
		let unicode = directory.appendingPathComponent(unicodeFilename)
		try PageCaptureCodec.write(image, as: .png, to: unicode)
		expectNoDifference(try Data(contentsOf: unicode), image.png)
		#expect(throws: (any Error).self) {
			try PageCaptureCodec.write(image, as: .png, to: directory.appendingPathComponent("missing/image.png"))
		}
		#expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("missing/image.png").path))
	}

	@Test
	internal func filenamesPreserveUnicodeAndAvoidUnsafeOrAmbiguousExtensions() async throws {
		let title = "  ../My:page/" + String(repeating: "🌍", count: 160)
		let filename = PageCaptureCodec.filename(title: title, format: .png)
		#expect(!filename.hasPrefix("."))
		#expect(!filename.contains("/"))
		#expect(!filename.contains(":"))
		#expect(filename.utf8.count <= 204)
		#expect(filename.hasSuffix(".png"))
		expectNoDifference(PageCaptureCodec.filename(title: "..\n", format: .jpeg(quality: 0.9)), "-.jpg")
	}

	private func fixture() throws -> PageCaptureFrame {
		let data = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 0, 0, 0, 0])
		let provider = try #require(CGDataProvider(data: data as CFData))
		let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
		let image = try #require(CGImage(
			width: 2,
			height: 2,
			bitsPerComponent: 8,
			bitsPerPixel: 32,
			bytesPerRow: 8,
			space: space,
			bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
			provider: provider,
			decode: nil,
			shouldInterpolate: false,
			intent: .defaultIntent
		))
		let encoded = NSMutableData()
		let destination = try #require(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
		CGImageDestinationAddImage(destination, image, nil)
		#expect(CGImageDestinationFinalize(destination))
		return .init(
			request: .init(tabID: .init(rawValue: UUID(1)), revision: 7),
			documentID: "document-1",
			image: .init(png: encoded as Data, width: 2, height: 2),
			viewportWidth: 2,
			viewportHeight: 2,
			deviceScale: 1,
			wasLoading: false
		)
	}

	private func pixel(_ image: CGImage) throws -> [UInt8] {
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
			context.draw(image, in: .init(x: 0, y: 0, width: 1, height: 1))
		}
		return bytes
	}
}
