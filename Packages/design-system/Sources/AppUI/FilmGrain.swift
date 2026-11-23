import BrowserCore
import CoreGraphics
import Foundation
import SwiftUI

public struct FilmGrainStyle: Equatable, Sendable {
	public var isEnabled: Bool
	public var intensity: Double

	/// Measured in display pixels, so fine grain stays crisp on Retina displays.
	public var size: Double

	/// The surface drawn: film grain, denim, paper (DEV-1253) or textile (DEV-1286).
	public var texture: ChromeGrain.Texture

	public init(
		isEnabled: Bool = true,
		intensity: Double = 0.18,
		size: Double = 1,
		texture: ChromeGrain.Texture = .noise
	) {
		self.isEnabled = isEnabled
		self.intensity = intensity
		self.size = size
		self.texture = texture
	}
}

extension EnvironmentValues {
	@Entry
	public var browserFilmGrain: FilmGrainStyle = .init(isEnabled: false)
}

/// A static, cached texture tile. It never intercepts input or schedules animation frames.
public struct FilmGrain: View {
	private let style: FilmGrainStyle

	@Environment(\.displayScale)
	private var displayScale

	public init(style: FilmGrainStyle) {
		self.style = style
	}

	public var body: some View {
		Group {
			if style.isEnabled, style.intensity > 0 {
				Rectangle()
					.fill(ImagePaint(
						image: Image(decorative: FilmGrainTexture.image(style.texture), scale: 1).interpolation(.none),
						scale: min(max(style.size, 1), 3) / displayScale
					))
					.blendMode(.softLight)
					.opacity(min(max(style.intensity, 0), 1))
			}
		}
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}
}

/// The tiles each texture repeats, made once, in code, from fixed seeds, so they never sparkle when
/// a view updates or another window opens. Each is a 256-pixel grey tile around mid-grey, which the
/// soft-light blend turns into light and shade over the chrome; every pattern wraps at the tile's
/// edges, so the repeat doesn't show.
internal enum FilmGrainTexture {
	internal static let side: Int = 256

	internal static func image(_ texture: ChromeGrain.Texture) -> CGImage {
		switch texture {
		case .noise: noise
		case .jeans: jeans
		case .paper: paper
		case .textile: textile
		}
	}

	private static let noise: CGImage = image(pixels: noisePixels())
	private static let jeans: CGImage = image(pixels: jeansPixels())
	private static let paper: CGImage = image(pixels: paperPixels())
	private static let textile: CGImage = image(pixels: textilePixels())

	/// White noise, as Arx's film grain has always been.
	internal static func noisePixels() -> [UInt8] {
		var random = SeededRandom(seed: 0x415258)
		return (0 ..< side * side).map { _ in UInt8(truncatingIfNeeded: random.next()) }
	}

	/// A 3/1 twill: diagonal ribs where the warp floats over three weft threads, every thread a
	/// little lighter or darker than its neighbors, and a fine grain over it all.
	internal static func jeansPixels() -> [UInt8] {
		var random = SeededRandom(seed: 0x4A45414E)
		let warp = (0 ..< side).map { _ in random.unit() - 0.5 }
		let weft = (0 ..< side).map { _ in random.unit() - 0.5 }
		var pixels: [UInt8] = .init(repeating: 128, count: side * side)
		for y in 0 ..< side {
			for x in 0 ..< side {
				// Threads two pixels wide. The rib runs down to the left, and 256 is a multiple of the
				// 8-pixel repeat, so it wraps.
				let phase = (x / 2 + y / 2) % 4
				let rib: Double = phase == 3 ? -0.6 : (phase == 0 ? 0.4 : 0.15)
				let thread = phase == 3 ? weft[y / 2] : warp[x / 2]
				let value = rib * 0.7 + thread * 0.35 + (random.unit() - 0.5) * 0.4
				pixels[y * side + x] = level(value)
			}
		}
		return pixels
	}

	/// Soft, uneven pulp in two sizes, short fibers lying every way, and a faint tooth.
	internal static func paperPixels() -> [UInt8] {
		var random = SeededRandom(seed: 0x50415045)
		let coarse = ValueNoise(cells: 8, random: &random)
		let fine = ValueNoise(cells: 32, random: &random)
		var values: [Double] = .init(repeating: 0, count: side * side)
		for y in 0 ..< side {
			for x in 0 ..< side {
				let u = Double(x) / Double(side)
				let v = Double(y) / Double(side)
				values[y * side + x] = coarse.value(u, v) * 0.45 + fine.value(u, v) * 0.3
					+ (random.unit() - 0.5) * 0.18
			}
		}
		for _ in 0 ..< 220 {
			// A fiber: a short, slightly curved stroke, lighter or darker than the pulp.
			var x = random.unit() * Double(side)
			var y = random.unit() * Double(side)
			var angle = random.unit() * 2 * .pi
			let length = 6 + Int(random.unit() * 18)
			let shade = random.unit() < 0.5 ? -0.35 : 0.3
			for _ in 0 ..< length {
				let column = (Int(x.rounded(.down)) % side + side) % side
				let row = (Int(y.rounded(.down)) % side + side) % side
				values[row * side + column] += shade
				angle += (random.unit() - 0.5) * 0.3
				x += cos(angle)
				y += sin(angle)
			}
		}
		return values.map(level)
	}

	/// Fine diagonal stripes rising to the right, one thread every four pixels, each thread a little
	/// lighter or darker than the next. Every four pixels along a thread it dips under the crossing
	/// one, which gives the stripes the small checker of a weave, with a fine grain over it all.
	internal static func textilePixels() -> [UInt8] {
		var random = SeededRandom(seed: 0x54455854)

		// 256 is a multiple of the 4-pixel repeat both ways, so the threads wrap at the tile's edges.
		let period = 4
		let threads = (0 ..< side / period).map { _ in random.unit() - 0.5 }
		var pixels: [UInt8] = .init(repeating: 128, count: side * side)
		for y in 0 ..< side {
			for x in 0 ..< side {
				let along = (x + y) % side
				let across = (x - y + side) % side
				let stripe = cos(2 * .pi * Double(along) / Double(period))
				let weave: Double = (across / period) % 2 == 0 ? 0.14 : -0.14
				let thread = threads[along / period]
				let value = stripe * 0.42 + weave * (stripe + 1) / 2 + thread * 0.22
					+ (random.unit() - 0.5) * 0.16
				pixels[y * side + x] = level(value)
			}
		}
		return pixels
	}

	/// A value around zero as a grey level around the middle.
	private static func level(_ value: Double) -> UInt8 {
		UInt8(min(max(128 + value * 110, 0), 255))
	}

	private static func image(pixels: [UInt8]) -> CGImage {
		guard
			let provider = CGDataProvider(data: Data(pixels) as CFData),
			let image = CGImage(
				width: side,
				height: side,
				bitsPerComponent: 8,
				bitsPerPixel: 8,
				bytesPerRow: side,
				space: CGColorSpaceCreateDeviceGray(),
				bitmapInfo: .init(rawValue: 0),
				provider: provider,
				decode: nil,
				shouldInterpolate: false,
				intent: .defaultIntent
			)
		else { preconditionFailure("Unable to allocate a chrome texture") }
		return image
	}
}

/// Xorshift, so every launch draws the same tiles.
private struct SeededRandom {
	private var state: UInt32

	fileprivate init(seed: UInt32) {
		self.state = seed
	}

	fileprivate mutating func next() -> UInt32 {
		state ^= state << 13
		state ^= state >> 17
		state ^= state << 5
		return state
	}

	/// `0 ..< 1`.
	fileprivate mutating func unit() -> Double {
		Double(next()) / (Double(UInt32.max) + 1)
	}
}

/// Smoothly interpolated random values on a lattice that wraps, so the tile repeats seamlessly.
private struct ValueNoise {
	private let cells: Int
	private let lattice: [Double]

	fileprivate init(
		cells: Int,
		random: inout SeededRandom
	) {
		self.cells = cells
		self.lattice = (0 ..< cells * cells).map { _ in random.unit() - 0.5 }
	}

	/// `u` and `v` in `0 ..< 1`.
	fileprivate func value(
		_ u: Double,
		_ v: Double
	) -> Double {
		let x = u * Double(cells)
		let y = v * Double(cells)
		let column = Int(x.rounded(.down))
		let row = Int(y.rounded(.down))
		let tx = smooth(x - Double(column))
		let ty = smooth(y - Double(row))
		func at(
			_ column: Int,
			_ row: Int
		) -> Double {
			lattice[(row % cells) * cells + column % cells]
		}
		let top = at(column, row) * (1 - tx) + at(column + 1, row) * tx
		let bottom = at(column, row + 1) * (1 - tx) + at(column + 1, row + 1) * tx
		return top * (1 - ty) + bottom * ty
	}

	private func smooth(_ t: Double) -> Double {
		t * t * (3 - 2 * t)
	}
}
