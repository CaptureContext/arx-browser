import BrowserCaptureClient
import BrowserCore
import CoreGraphics
import Foundation
import ImageIO
import PageCaptureFeature
import UniformTypeIdentifiers
import _TestSupport

internal enum PageCaptureFixtures {
	internal static let tabID = Tab.ID(rawValue: UUID(1))

	internal static let source = CaptureSource(
		host: .pane(windowID: UUID(2), paneID: UUID(3)),
		tabID: tabID,
		profileID: .init(rawValue: UUID(4)),
		spaceID: .init(rawValue: UUID(5))
	)

	internal static let request = PageCaptureRequest(tabID: tabID, revision: 7)

	internal static let inspection = PageInspectionSource(
		tabID: tabID,
		profileID: .init(rawValue: UUID(4)),
		sessionRevision: 7,
		documentRevision: 3,
		scopeID: UUID(6)
	)

	/// Colors of the four quadrants, top-left, top-right, bottom-left, bottom-right.
	internal static let quadrants: [[UInt8]] = [
		[255, 0, 0],
		[0, 255, 0],
		[0, 0, 255],
		[255, 255, 255],
	]

	/// A 40 × 40 point viewport at Retina scale: an 80 × 80 pixel image in four colored quadrants.
	internal static func frame(
		mode: PageCaptureMode = .viewport,
		warnings: [PageCaptureWarning] = [],
		pixel: ((Int, Int) -> [UInt8])? = nil
	) throws -> PageCaptureFrame {
		var request = request
		request.mode = mode
		let side = 80
		let image = try png(width: side, height: side) { x, y in
			if let pixel { return pixel(x, y) }
			return quadrants[(y < side / 2 ? 0 : 2) + (x < side / 2 ? 0 : 1)]
		}
		return .init(
			request: request,
			documentID: "document-1",
			image: image,
			viewportWidth: 40,
			viewportHeight: 40,
			deviceScale: 2,
			wasLoading: false,
			warnings: warnings,
			documentGeometry: mode == .fullDocument
			? .init(
				documentRect: .init(x: 0, y: 0, width: 80, height: 80),
				visibleRect: .init(x: 0, y: 0, width: 40, height: 40),
				scrollX: 0,
				scrollY: 0,
				zoomLevel: 0,
				pageScale: 1,
				rasterScale: 1
			)
			: nil
		)
	}

	internal static func png(
		width: Int,
		height: Int,
		pixel: (Int, Int) -> [UInt8]
	) throws -> PageCaptureImage {
		var bytes: [UInt8] = []
		for y in 0..<height {
			for x in 0..<width { bytes += pixel(x, y) + [255] }
		}
		guard
			let provider = CGDataProvider(data: Data(bytes) as CFData),
			let image = CGImage(
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
			)
		else { throw PageCaptureFailure.invalidImage }

		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
		else { throw PageCaptureFailure.encodingFailed }

		CGImageDestinationAddImage(destination, image, nil)
		guard CGImageDestinationFinalize(destination)
		else { throw PageCaptureFailure.encodingFailed }
		return .init(png: data as Data, width: width, height: height)
	}

	/// The RGB of one pixel of a decoded PNG.
	internal static func color(
		of image: PageCaptureImage,
		x: Int,
		y: Int
	) throws -> [UInt8] {
		let decoded = try PageCaptureCodec.decode(image)
		var bytes = [UInt8](repeating: 0, count: 4)
		let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
			guard
				let context = CGContext(
					data: buffer.baseAddress,
					width: 1,
					height: 1,
					bitsPerComponent: 8,
					bytesPerRow: 4,
					space: CGColorSpace(name: CGColorSpace.sRGB)!,
					bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
				)
			else { return false }

			context.draw(decoded, in: .init(
				x: -x,
				y: -(decoded.height - 1 - y),
				width: decoded.width,
				height: decoded.height
			))
			return true
		}
		guard drawn else { throw PageCaptureFailure.invalidImage }
		return Array(bytes.prefix(3))
	}

	internal static func node(
		_ index: Int,
		parent: Int? = nil,
		role: String = "paragraph",
		_ x: Double,
		_ y: Double,
		_ width: Double,
		_ height: Double
	) -> PageInspectionNode {
		.init(index: index, parent: parent, role: role, bounds: .init(x: x, y: y, width: width, height: height))
	}

	internal static func snapshot(
		_ nodes: [PageInspectionNode],
		windowStart: Int = 0,
		total: Int? = nil
	) -> PageInspectionSnapshot {
		.init(
			snapshotID: "snapshot",
			documentID: "document-1",
			frameID: "frame",
			domVersion: "1",
			nodes: nodes,
			omissions: [],
			windowStart: windowStart,
			totalNodes: total
		)
	}

	internal static func state(
		mode: PageCaptureFeature.Mode = .area,
		phase: PageCaptureFeature.Phase = .preparing
	) -> PageCaptureFeature.State {
		.init(
			id: UUID(9),
			source: source,
			title: "Page",
			mode: mode,
			sourceGeneration: 0,
			phase: phase,
			request: request,
			inspection: inspection,
			viewport: .init(x: 0, y: 0, width: 40, height: 40)
		)
	}
}
