#if DEBUG
import BrowserCaptureClient
import BrowserCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import AppFeature

@Suite(.dependencies)
internal struct CaptureSmokePixelsTests {
	@Test
	internal func fixtureSamplerAcceptsQuantizedDisplayP3RoundTrip() throws {
		let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
		let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
		let context = try #require(CGContext(
			data: nil,
			width: 6,
			height: 1,
			bitsPerComponent: 8,
			bytesPerRow: 24,
			space: displayP3,
			bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
		))
		let colors: [[CGFloat]] = [
			[1, 0, 0], [0, 1, 0], [0, 0, 1],
			[1, 1, 0], [1, 0, 1], [0, 1, 1]
		]

		for (index, color) in colors.enumerated() {
			let fill = try #require(CGColor(colorSpace: sRGB, components: color + [1]))
			context.setFillColor(fill)
			context.fill(CGRect(x: index, y: 0, width: 1, height: 1))
		}

		let image = try #require(context.makeImage())

		for (index, color) in colors.enumerated() {
			try CaptureSmokePixels.expect(image, x: index, y: 0, patch: .init(
				x: Double(index),
				y: 0,
				red: Int(color[0] * 255),
				green: Int(color[1] * 255),
				blue: Int(color[2] * 255)
			))
		}
	}

	@Test(arguments: [[UInt8](arrayLiteral: 4, 255, 0, 255), [0, 254, 0, 254]])
	internal func fixtureSamplerRejectsExcessColorErrorAndNonOpaquePixels(bytes: [UInt8]) throws {
		let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
		let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
		let image = try #require(CGImage(
			width: 1,
			height: 1,
			bitsPerComponent: 8,
			bitsPerPixel: 32,
			bytesPerRow: 4,
			space: space,
			bitmapInfo: [.byteOrder32Big, .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
			provider: provider,
			decode: nil,
			shouldInterpolate: false,
			intent: .defaultIntent
		))

		#expect(throws: CaptureSmokeFailure.self) {
			try CaptureSmokePixels.expect(image, x: 0, y: 0, patch: .init(
				x: 0,
				y: 0,
				red: 0,
				green: 255,
				blue: 0
			))
		}
	}

	@Test
	internal func fixtureSamplerUsesTopLeftRowsAndMeasuredFractionalScale() throws {
		let frame = try fixture()
		try CaptureSmokePixels.verify(frame, patches: [
			.init(x: 0.25, y: 0.25, red: 255, green: 0, blue: 0),
			.init(x: 1, y: 0.25, red: 0, green: 255, blue: 0),
			.init(x: 0.25, y: 1, red: 0, green: 0, blue: 255),
			.init(x: 1, y: 1, red: 255, green: 255, blue: 0),
		])
		#expect(try CaptureSmokePixels.sample(frame, x: 0.25, y: 1) == [0, 0, 255, 255])
	}

	@Test
	internal func fixtureSamplerRejectsWrongPixelsAndOutOfViewportSamples() throws {
		let frame = try fixture()
		#expect(throws: CaptureSmokeFailure.self) {
			try CaptureSmokePixels.verify(frame, patches: [.init(x: 0.25, y: 1, red: 255, green: 0, blue: 0)])
		}
		#expect(throws: CaptureSmokeFailure.self) { try CaptureSmokePixels.sample(frame, x: 1.6, y: 0) }
		#expect(throws: CaptureSmokeFailure.self) { try CaptureSmokePixels.sample(frame, x: .nan, y: 0) }
	}

	@Test
	internal func frozenCropComparisonIgnoresMetadataButRequiresEveryPixel() throws {
		let first = try fixture(description: "first").image
		let second = try fixture(description: "second").image
		let changed = try fixture(firstRed: 254, description: "second").image
		#expect(first.png != second.png)

		try CaptureSmokePixels.expectSamePixels(first, second)
		#expect(throws: CaptureSmokeFailure.self) {
			try CaptureSmokePixels.expectSamePixels(first, changed)
		}
	}

	private func fixture(
		firstRed: UInt8 = 255,
		description: String = "fixture"
	) throws -> PageCaptureFrame {
		let bytes = Data([firstRed, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255])
		let provider = try #require(CGDataProvider(data: bytes as CFData))
		let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
		let image = try #require(CGImage(
			width: 2,
			height: 2,
			bitsPerComponent: 8,
			bitsPerPixel: 32,
			bytesPerRow: 8,
			space: space,
			bitmapInfo: [.byteOrder32Big, .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
			provider: provider,
			decode: nil,
			shouldInterpolate: false,
			intent: .defaultIntent
		))
		let png = NSMutableData()
		let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
		CGImageDestinationAddImage(destination, image, [
			kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: description]
		] as CFDictionary)
		#expect(CGImageDestinationFinalize(destination))
		return .init(
			request: .init(tabID: .init(rawValue: UUID()), revision: 1),
			documentID: "smoke-test",
			image: .init(png: png as Data, width: 2, height: 2),
			viewportWidth: 1.6,
			viewportHeight: 1.6,
			deviceScale: 1.25,
			wasLoading: false
		)
	}
}
#endif
