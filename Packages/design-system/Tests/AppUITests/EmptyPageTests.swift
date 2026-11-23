@testable import AppUI
import BrowserCore
import Foundation
import Metal
import Testing

internal struct EmptyPageTests {
	/// The homepage Max set as Arx's default (20 Nov).
	@Test
	internal func theDefaultIsTheCaptureContextHomepage() {
		let style: EmptyPageStyle = .captureContext

		#expect(style.logo.placement == .centered)
		#expect(style.logo.centered.scale == 1.5)
		#expect(style.logo.centered.opacity == 0.5)
		#expect(style.logo.centered.blend == .normal)
		#expect(style.logo.glass && style.logo.hologram)
		#expect(style.cursor == .init(shape: .regular))
		#expect(style.effect == .none)
		#expect(style.guide == .hints)
		#expect(style.background == .dust)
	}

	/// The default homepage leaves the system pointer alone (DEV-1287): it sets no pointer style, so
	/// AppKit shows the arrow, and the pointing hand or I-beam over a control. A customized homepage
	/// still draws the shape it chose.
	@MainActor
	@Test
	internal func theDefaultHomepageKeepsTheSystemPointer() {
		for preset in EmptyPageStyle.presets {
			#expect(EmptyPageCursor.pointerStyle(preset.style.cursor, colorScheme: .light) == nil, "\(preset.id)")
		}
		#expect(EmptyPageCursor.pointerStyle(EmptyPageStyle.Stored().style.cursor, colorScheme: .dark) == nil)

		let circle: EmptyPageStyle.Cursor = .init(shape: .circle)
		#expect(EmptyPageCursor.pointerStyle(circle, colorScheme: .light) != nil)
	}

	@Test
	internal func aSavedStyleReadsBackAsItWasSaved() throws {
		var style: EmptyPageStyle = .captureContext
		style.background = .sky
		style.sky.clouds = false
		style.logo.placement = .watermark
		style.logo.watermark.blend = .softLight
		style.guidePosition = .bottomLeft
		style.effect = .inkTrail
		style.ink.coloring = .rainbow

		let stored: EmptyPageStyle.Stored = .init(style)
		let read = try #require(EmptyPageStyle.Stored(rawValue: stored.rawValue))

		#expect(read.style == style)
		#expect(read == stored)
	}

	@Test
	internal func anUnreadableStyleFallsBackToTheDefault() {
		#expect(EmptyPageStyle.Stored(rawValue: "") == nil)
		#expect(EmptyPageStyle.Stored(rawValue: #"{"logo":1}"#) == nil)
		#expect(EmptyPageStyle.Stored().style == .captureContext)
	}

	@Test
	internal func hintsRollOnByThemselves() {
		let cursor: EmptyPageHintCursor = .init()
		let duration: Double = EmptyPageHints.duration

		#expect(cursor.position(at: 0, count: 5).index == 0)
		#expect(cursor.position(at: duration * 0.5, count: 5) == (0, 0.5))
		#expect(cursor.position(at: duration * 2.25, count: 5) == (2, 0.25))
		#expect(cursor.position(at: duration * 6, count: 5).index == 1)
	}

	/// ← and → step through the tips, wrap at either end, and give the new tip a whole turn.
	@Test
	internal func arrowsStepThroughHintsAndWrap() {
		let duration: Double = EmptyPageHints.duration
		var cursor: EmptyPageHintCursor = .init()

		cursor.step(by: 1, at: duration * 0.9, count: 3)
		#expect(cursor.position(at: duration * 0.9, count: 3) == (1, 0))
		#expect(cursor.position(at: duration * 1.4, count: 3).index == 1)

		cursor.step(by: -1, at: duration * 1.4, count: 3)
		cursor.step(by: -1, at: duration * 1.4, count: 3)
		#expect(cursor.position(at: duration * 1.4, count: 3).index == 2)

		cursor.step(by: 1, at: duration * 1.5, count: 3)
		#expect(cursor.position(at: duration * 1.5, count: 3).index == 0)
	}

	/// A tip names the person's own keys, and goes when its command has none.
	@Test
	internal func hintsUseThePersonsShortcuts() {
		let folderKeys: KeyboardShortcut = .init(key: "n", modifiers: [.command, .shift])
		let defaults: [String] = EmptyPageHints.texts(bindings: [])
		let rebound: [String] = EmptyPageHints.texts(bindings: [
			.init(command: .newTab, shortcut: .init(key: "y", modifiers: [.command, .option])),
			.init(command: .reopenLastClosedTab, shortcut: nil),
			.init(command: .newFolder, shortcut: folderKeys),
		])

		// New Folder has no keys by default, so its tip waits until it has some.
		#expect(defaults.count == EmptyPageHints.all.count - 1)
		#expect(defaults.first == String.localized(.appUI.emptyPage.hintNewTab("⌘T")))
		#expect(!defaults.contains(String.localized(.appUI.emptyPage.hintFolder(folderKeys.display))))
		#expect(rebound.first == String.localized(.appUI.emptyPage.hintNewTab("⌥⌘Y")))
		#expect(!rebound.contains(String.localized(.appUI.emptyPage.hintReopen("⇧⌘T"))))
		#expect(rebound.contains(String.localized(.appUI.emptyPage.hintFolder("⇧⌘N"))))
	}

	/// SwiftPM compiles the homepage's Metal into AppUI's bundle; every function it calls is there.
	@Test
	internal func theShadersAreInAppUIsMetalLibrary() throws {
		let device = try #require(MTLCreateSystemDefaultDevice())
		let url = try #require(EmptyPageShaders.libraryURL)
		let library = try device.makeLibrary(URL: url)
		let names: Set<String> = [
			"emptyPageSparkles", "emptyPageHologram", "emptyPageGlass", "emptyPageMagnet", "emptyPagePond",
			"emptyPageWarp", "emptyPageFilm", "emptyPageSilk", "emptyPageTopography", "emptyPageSky", "emptyPageInk",
		]

		#expect(names.isSubset(of: Set(library.functionNames)))
	}

	@Test
	internal func customizationIsOffByDefault() {
		#expect(FeatureFlag.customizableHomepage.isOnByDefault == false)
		#expect(EmptyPageCustomization.featureFlag == "ARX_CUSTOMIZABLE_HOMEPAGE")
	}
}
