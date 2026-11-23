import AppKit
@testable import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

/// Writes offscreen PNGs of the space theme editor (DEV-1253), light and dark, for visual review,
/// when `ARX_DESIGN_SNAPSHOTS` names a directory: empty over a profile's colors, one color, three
/// colors with Jeans, and Paper in dark mode.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: SidebarChromeSnapshot.directory != nil)
)
internal struct SpaceThemeEditorSnapshotTests {
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func theEditorInEachState(_ appearance: NSAppearance.Name) throws {
		try SidebarChromeSnapshot.write(
			Self.states,
			size: .init(width: 1_440, height: 540),
			appearance: appearance,
			name: "space-theme-editor"
		)
	}

	/// Textile (DEV-1286) at three of the ring's settings.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func textileAtThreeRingSettings(_ appearance: NSAppearance.Name) throws {
		try SidebarChromeSnapshot.write(
			Self.textileStates,
			size: .init(width: 1_100, height: 540),
			appearance: appearance,
			name: "space-theme-editor-textile"
		)
	}

	private struct Sample {
		internal let title: String
		internal let choices: AppearanceOverride
	}

	private static let profile: ChromeAppearance = .default

	private static let samples: [Sample] = [
		.init(title: "Empty: the profile's colors", choices: .init()),
		.init(
			title: "One color",
			choices: AppearanceOverride().settingThemeColors([.init(hue: 205, intensity: 0.35)], over: profile)
		),
		.init(
			title: "Three colors, Jeans",
			choices: AppearanceOverride(grainIntensity: 0.5)
				.settingThemeDots(.init(angle: 250, distance: 0.55, arrangement: .splitComplementary), over: profile)
				.settingThemeTexture(.jeans)
		),
		.init(
			title: "Dark, Paper",
			choices: AppearanceOverride(theme: .dark, grainIntensity: 0.6)
				.settingThemeDots(.init(angle: 330, distance: 0.7, arrangement: .complementary), over: profile)
				.settingThemeTexture(.paper)
		),
	]

	private static let textileSamples: [Sample] = [0.2, 0.5, 0.9].map { intensity in
		.init(
			title: "Textile, ring at \(Int(intensity * 100))%",
			choices: AppearanceOverride(grainIntensity: intensity)
				.settingThemeColors([.init(hue: 220, intensity: 0.3)], over: profile)
				.settingThemeTexture(.textile)
		)
	}

	private static var states: some View {
		row(samples)
	}

	private static var textileStates: some View {
		row(textileSamples)
	}

	private static func row(_ samples: [Sample]) -> some View {
		HStack(alignment: .top, spacing: 16) {
			ForEach(samples, id: \.title) { sample in
				VStack(alignment: .leading, spacing: 8) {
					Text(verbatim: sample.title)
						.font(.headline)
					SpaceThemeEditor(
						choices: sample.choices,
						inherited: profile,
						onCommit: { _ in },
						onClear: {}
					)
				}
				.padding(14)
				.frame(width: SpaceThemeEditor.width + 28, alignment: .top)
				.background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 12))
			}
		}
		.padding(16)
		.frame(maxHeight: .infinity, alignment: .top)
	}
}

/// The texture tiles the dial cycles through (DEV-1253).
internal struct FilmGrainTextureTests {
	@Test(arguments: ChromeGrain.Texture.allCases)
	internal func eachTileIsStableAndCenteredOnMidGrey(_ texture: ChromeGrain.Texture) {
		let pixels = Self.pixels(texture)
		#expect(pixels.count == FilmGrainTexture.side * FilmGrainTexture.side)
		// Made from fixed seeds: the same every launch, so the chrome never sparkles.
		#expect(pixels == Self.pixels(texture))
		// Around mid-grey, so the soft-light blend lightens and darkens the chrome evenly.
		let mean = Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
		#expect((100 ... 156).contains(mean))
		// And never flat.
		#expect(Set(pixels).count > 16)
	}

	@Test
	internal func textileRunsDiagonallyUpToTheRight() {
		let pixels = FilmGrainTexture.textilePixels()
		let side = FilmGrainTexture.side
		func value(_ x: Int, _ y: Int) -> Double {
			Double(pixels[((y + side) % side) * side + (x + side) % side])
		}

		// Neighbors along a thread (up and to the right) are alike; across it they differ more.
		var along: Double = 0
		var across: Double = 0
		for y in 0 ..< side {
			for x in 0 ..< side {
				along += abs(value(x, y) - value(x + 1, y - 1))
				across += abs(value(x, y) - value(x + 1, y + 1))
			}
		}
		#expect(along * 2 < across)
	}

	@Test
	internal func theTexturesDiffer() {
		let tiles = ChromeGrain.Texture.allCases.map(Self.pixels)
		#expect(Set(tiles).count == tiles.count)
	}

	@Test
	internal func noiseIsTheFilmGrainArxAlwaysDrew() {
		// The xorshift sequence from the original film grain, seeded with 0x415258.
		var seed: UInt32 = 0x415258
		let original: [UInt8] = (0 ..< FilmGrainTexture.side * FilmGrainTexture.side).map { _ in
			seed ^= seed << 13
			seed ^= seed >> 17
			seed ^= seed << 5
			return UInt8(truncatingIfNeeded: seed)
		}
		#expect(FilmGrainTexture.noisePixels() == original)
	}

	private static func pixels(_ texture: ChromeGrain.Texture) -> [UInt8] {
		switch texture {
		case .noise: FilmGrainTexture.noisePixels()
		case .jeans: FilmGrainTexture.jeansPixels()
		case .paper: FilmGrainTexture.paperPixels()
		case .textile: FilmGrainTexture.textilePixels()
		}
	}
}
