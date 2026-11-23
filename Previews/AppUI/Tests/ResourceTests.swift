import AppKit
import AppUI
import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct ResourceTests {
	@Test
	func generatedLocalizationsLoadFromThePackageBundle() {
		let locale = Locale(identifier: "en")
		expectNoDifference(String.localized(.appUI.sidebar.newTab, locale: locale), "New Tab")
		expectNoDifference(
			String.localized(.appUI.sidebar.widthValue(286), locale: locale),
			"286 points"
		)
		expectNoDifference(
			String.localized(.appUI.command.searchFor("Swift"), locale: locale),
			"Search for “Swift”"
		)
		expectNoDifference(
			String.localized(
				.appUI.command.resultAccessibility("GitHub", "Switch to Tab"),
				locale: locale
			),
			"GitHub, Switch to Tab"
		)
	}

	@Test
	func onboardingStringsLoadForEveryStep() {
		let locale = Locale(identifier: "en")
		expectNoDifference(String.localized(.appUI.onboarding.progress(2, 5), locale: locale), "Step 2 of 5")
		expectNoDifference(String.localized(.appUI.onboarding.getStarted, locale: locale), "Get Started")
		for step in OnboardingStep.allCases {
			#expect(!step.title.isEmpty)
			#expect(!step.headline.isEmpty)
			#expect(!step.message.isEmpty)
		}
	}

	@Test
	func tourStringsLoadForEveryDemo() {
		let locale = Locale(identifier: "en")
		expectNoDifference(String.localized(.appUI.onboarding.tour.note, locale: locale), "A demo on sample data.")
		for demo in TourDemo.allCases {
			for text in [demo.headline, demo.message, demo.accessibilityDescription] {
				#expect(!text.isEmpty)
				#expect(!text.hasPrefix("onboarding."))
			}
		}
	}

	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	@MainActor
	func selectionUsesTranslucentWhite(_ appearance: NSAppearance.Name) throws {
		let selection = try resolved(.browser.selection, appearance: appearance)
		#expect(selection.redComponent > 0.99)
		#expect(selection.greenComponent > 0.99)
		#expect(selection.blueComponent > 0.99)
		#expect(selection.alphaComponent > 0 && selection.alphaComponent < 1)
	}

	@Test
	@MainActor
	func paletteResolvesBothSystemAppearances() throws {
		let lightText = try resolved(.browser.text, appearance: .aqua)
		let darkText = try resolved(.browser.text, appearance: .darkAqua)
		let lightBackground = try resolved(.browser.sidebarTop, appearance: .aqua)
		let darkBackground = try resolved(.browser.sidebarTop, appearance: .darkAqua)
		#expect(lightText.brightnessComponent < 0.3)
		#expect(darkText.brightnessComponent > 0.8)
		#expect(lightBackground.brightnessComponent > 0.8)
		#expect(darkBackground.brightnessComponent < 0.3)
	}

	@Test
	func wordmarkFontRegistersFromThePackageBundle() {
		#expect(ArxWordmark.register())

		let font = ArxWordmark.nsFont(size: 40)
		expectNoDifference(font.familyName, "Arx Wordmark")

		// The default weight resolves to the variable font's named Bold instance.
		expectNoDifference(font.fontName, "ArxWordmark-Bold")
	}

	@Test
	func wordmarkWeightMovesAlongTheVariationAxis() throws {
		let weightAxis = 0x7767_6874
		let light = ArxWordmark.ctFont(size: 40, weight: 300)
		let heavy = ArxWordmark.ctFont(size: 40, weight: 2_000)
		let lightVariation = try #require(CTFontCopyVariation(light) as? [Int: CGFloat])
		let heavyVariation = try #require(CTFontCopyVariation(heavy) as? [Int: CGFloat])
		expectNoDifference(lightVariation[weightAxis], 300)

		// Out-of-range weights clamp to the axis maximum.
		expectNoDifference(heavyVariation[weightAxis], ArxWordmark.weights.upperBound)
	}

	@Test
	func identityCardsDrawTheWordmarkAtItsHeaviestWeight() throws {
		expectNoDifference(ArxWordmark.cardWeight, 1_000)
		let font = ArxWordmark.ctFont(size: 40, weight: ArxWordmark.cardWeight)
		let variation = try #require(CTFontCopyVariation(font) as? [Int: CGFloat])
		expectNoDifference(variation[0x7767_6874], 1_000)
	}

	@MainActor
	private func resolved(
		_ resource: _ColorResource,
		appearance name: NSAppearance.Name
	) throws -> NSColor {
		let appearance = try #require(NSAppearance(named: name))
		var color: NSColor?
		appearance.performAsCurrentDrawingAppearance {
			color = NSColor.resource(resource)?.usingColorSpace(.sRGB)
		}
		return try #require(color)
	}
}
