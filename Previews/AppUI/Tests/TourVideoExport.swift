import AVFoundation
import AppKit
import AppUI
import CoreVideo
import Foundation
import SwiftUI
import Testing

/// Renders a tour demo frame by frame, offscreen, into an H.264 video.
///
/// Each frame is ``TourDemoScene`` at a fixed time drawn by `ImageRenderer` over the window
/// background, so the video shows exactly what the onboarding page plays. Nothing needs a
/// window, a display or user interaction.
@MainActor
internal struct TourVideoExporter {
	/// Pixels per point: 2 gives 1280 × 720 for the 640 × 360 canvas.
	internal var scale: CGFloat
	internal var frameRate: Int32

	internal init(
		scale: CGFloat = 2,
		frameRate: Int32 = 30
	) {
		self.scale = scale
		self.frameRate = frameRate
	}

	internal var pixelSize: CGSize {
		.init(
			width: (TourDemo.canvasSize.width * scale).rounded(),
			height: (TourDemo.canvasSize.height * scale).rounded()
		)
	}

	/// Writes one loop of `demo` to `url`, replacing a file that's there.
	internal func export(
		_ demo: TourDemo,
		colorScheme: ColorScheme,
		to url: URL
	) async throws {
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		if FileManager.default.fileExists(atPath: url.path) {
			try FileManager.default.removeItem(at: url)
		}

		let width: Int = Int(pixelSize.width)
		let height: Int = Int(pixelSize.height)
		let writer: AVAssetWriter = try .init(outputURL: url, fileType: .mp4)
		let input: AVAssetWriterInput = .init(
			mediaType: .video,
			outputSettings: [
				AVVideoCodecKey: AVVideoCodecType.h264,
				AVVideoWidthKey: width,
				AVVideoHeightKey: height,
			]
		)
		guard writer.canAdd(input) else { throw TourVideoExportError.cannotAddInput }

		let receiver: AVAssetWriterInput.PixelBufferReceiver = writer.inputPixelBufferReceiver(
			for: input,
			pixelBufferAttributes: nil
		)
		try writer.start()
		writer.startSession(atSourceTime: .zero)

		let frameCount: Int = Int((demo.duration * Double(frameRate)).rounded())
		for frame in 0..<frameCount {
			let time: TimeInterval = Double(frame) / Double(frameRate)
			let buffer: CVReadOnlyPixelBuffer = try pixelBuffer(for: demo, at: time, colorScheme: colorScheme)
			let presentationTime: CMTime = .init(value: CMTimeValue(frame), timescale: frameRate)
			try await receiver.append(buffer, with: presentationTime)
		}

		receiver.finish()
		writer.endSession(atSourceTime: .init(value: CMTimeValue(frameCount), timescale: frameRate))
		await writer.finishWriting()
		guard writer.status == .completed else { throw writer.error ?? TourVideoExportError.writerFailed }
	}

	/// One frame as an image, for checks that don't need a video.
	internal func image(
		for demo: TourDemo,
		at time: TimeInterval,
		colorScheme: ColorScheme
	) throws -> CGImage {
		let renderer: ImageRenderer = .init(content: frame(demo, at: time, colorScheme: colorScheme))
		renderer.scale = scale
		renderer.proposedSize = .init(TourDemo.canvasSize)

		var image: CGImage?
		appearance(colorScheme).performAsCurrentDrawingAppearance {
			image = renderer.cgImage
		}
		guard let image else { throw TourVideoExportError.renderFailed }

		return image
	}

	private func frame(
		_ demo: TourDemo,
		at time: TimeInterval,
		colorScheme: ColorScheme
	) -> some View {
		ZStack(alignment: .topLeading) {
			Color(nsColor: .windowBackgroundColor)
			TourDemoScene(demo: demo, time: time)
		}
		.frame(width: TourDemo.canvasSize.width, height: TourDemo.canvasSize.height)
		.environment(\.colorScheme, colorScheme)
	}

	private func pixelBuffer(
		for demo: TourDemo,
		at time: TimeInterval,
		colorScheme: ColorScheme
	) throws -> CVReadOnlyPixelBuffer {
		let image: CGImage = try image(for: demo, at: time, colorScheme: colorScheme)

		var buffer: CVPixelBuffer?
		CVPixelBufferCreate(
			nil,
			Int(pixelSize.width),
			Int(pixelSize.height),
			kCVPixelFormatType_32BGRA,
			nil,
			&buffer
		)
		guard let buffer else { throw TourVideoExportError.renderFailed }

		try Self.draw(image, into: buffer)
		return .init(unsafeBuffer: buffer)
	}

	/// Outside the main actor, so the buffer stays free to send to the writer afterwards.
	private nonisolated static func draw(
		_ image: CGImage,
		into buffer: CVPixelBuffer
	) throws {
		CVPixelBufferLockBaseAddress(buffer, [])
		defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

		guard
			let context = CGContext(
				data: CVPixelBufferGetBaseAddress(buffer),
				width: CVPixelBufferGetWidth(buffer),
				height: CVPixelBufferGetHeight(buffer),
				bitsPerComponent: 8,
				bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
				space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
			)
		else { throw TourVideoExportError.renderFailed }

		context.draw(
			image,
			in: .init(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
		)
	}

	private func appearance(_ colorScheme: ColorScheme) -> NSAppearance {
		NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
	}
}

internal enum TourVideoExportError: Error {
	case cannotAddInput
	case writerFailed
	case renderFailed
}

/// The repository's `build` folder, found from this file's path.
internal enum TourVideoOutput {
	/// Set by `make tour-videos`; with `xcodebuild test`, pass `TEST_RUNNER_ARX_TOUR_VIDEOS=<dir>`.
	static var directory: URL? {
		ProcessInfo.processInfo.environment["ARX_TOUR_VIDEOS"].map { path in
			URL(fileURLWithPath: path, isDirectory: true)
		}
	}

	static var scratch: URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appending(path: "build/Tests/tour-video-export", directoryHint: .isDirectory)
	}
}

/// Exports every demo in light and dark for the website: `make tour-videos`.
@MainActor
@Suite(.enabled(if: TourVideoOutput.directory != nil))
internal struct TourVideoExportTests {
	@Test(arguments: TourDemo.allCases)
	func export(_ demo: TourDemo) async throws {
		let directory: URL = try #require(TourVideoOutput.directory)
		let exporter: TourVideoExporter = .init()

		for (colorScheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
			let url: URL = directory.appending(path: "\(demo.fileName)-\(suffix).mp4")
			try await exporter.export(demo, colorScheme: colorScheme, to: url)

			let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
			#expect((attributes[.size] as? Int ?? 0) > 0)
		}
	}
}

@MainActor
@Suite
internal struct TourDemoRenderingTests {
	/// One demo goes through the whole export and comes out as a non-empty video of one loop.
	@Test
	func exportWritesOneLoopOfVideo() async throws {
		let demo: TourDemo = .peek
		let exporter: TourVideoExporter = .init(scale: 1, frameRate: 30)
		let url: URL = TourVideoOutput.scratch.appending(path: "\(demo.fileName)-light.mp4")
		defer { try? FileManager.default.removeItem(at: url) }

		try await exporter.export(demo, colorScheme: .light, to: url)

		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		#expect((attributes[.size] as? Int ?? 0) > 10_000)

		let asset: AVURLAsset = .init(url: url)
		let duration: CMTime = try await asset.load(.duration)
		#expect(abs(duration.seconds - demo.duration) < 0.05)

		let track: AVAssetTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
		let size: CGSize = try await track.load(.naturalSize)
		#expect(size == TourDemo.canvasSize)
		let frameRate: Float = try await track.load(.nominalFrameRate)
		#expect(abs(frameRate - 30) < 0.5)
	}

	/// Every demo moves: its key frame differs from its first frame, light differs from dark,
	/// and the loop wraps.
	@Test(arguments: TourDemo.allCases)
	func demosAnimateAndFollowTheAppearance(_ demo: TourDemo) throws {
		let exporter: TourVideoExporter = .init(scale: 1)
		let start: Data? = try png(exporter.image(for: demo, at: 0, colorScheme: .light))
		let key: Data? = try png(exporter.image(for: demo, at: demo.keyFrame, colorScheme: .light))
		let dark: Data? = try png(exporter.image(for: demo, at: demo.keyFrame, colorScheme: .dark))

		// Whole seconds, so the wrap is exact.
		let second: Data? = try png(exporter.image(for: demo, at: 4, colorScheme: .light))
		let again: Data? = try png(exporter.image(for: demo, at: 4 + demo.duration, colorScheme: .light))

		#expect(start != nil)
		#expect(start != key)
		#expect(key != dark)
		// The loop wraps: a frame one loop later is the same frame.
		#expect(second == again)
	}

	private func png(_ image: CGImage) -> Data? {
		NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
	}
}
