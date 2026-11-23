import BrowserCore
import Foundation
import Testing

internal struct PageZoomTests {
	@Test
	internal func stepsThroughChromesLevels() async throws {
		#expect(PageZoom.zoomIn.factor(from: 1) == 1.1)
		#expect(PageZoom.zoomOut.factor(from: 1) == 0.9)
		#expect(PageZoom.zoomIn.factor(from: 0.9) == 1)
		// Chromium's 133% and 140% are steps too.
		#expect(PageZoom.zoomIn.factor(from: 1.25) == 1.33)
		#expect(PageZoom.zoomIn.factor(from: 1.33) == 1.4)
		#expect(PageZoom.zoomOut.factor(from: 1.5) == 1.4)
		#expect(PageZoom.actualSize.factor(from: 2) == nil)
	}

	@Test
	internal func aLevelBetweenPresetsStepsToTheNextPreset() async throws {
		#expect(PageZoom.zoomIn.factor(from: 1.2) == 1.25)
		#expect(PageZoom.zoomOut.factor(from: 1.2) == 1.1)
		// Chromium's 1/3 and 2/3 are Settings' 0.33 and 0.67.
		#expect(PageZoom.zoomIn.factor(from: 1.0 / 3) == 0.5)
		#expect(PageZoom.zoomOut.factor(from: 2.0 / 3) == 0.5)
	}

	@Test
	internal func aCustomDefaultIsOneOfTheSteps() async throws {
		#expect(PageZoom.zoomIn.factor(from: 1.1, default: 1.2) == 1.2)
		#expect(PageZoom.zoomIn.factor(from: 1.2, default: 1.2) == 1.25)
		#expect(PageZoom.zoomOut.factor(from: 1.25, default: 1.2) == 1.2)
		// A preset default adds nothing.
		#expect(PageZoom.zoomIn.factor(from: 1, default: 1.1) == 1.1)
	}

	@Test
	internal func theEndsStayPut() async throws {
		#expect(PageZoom.zoomIn.factor(from: 5) == 5)
		#expect(PageZoom.zoomOut.factor(from: 0.25) == 0.25)
	}

	@Test
	internal func percentRounds() async throws {
		#expect(PageZoom.percent(1) == 100)
		#expect(PageZoom.percent(2.0 / 3) == 67)
		#expect(PageZoom.percent(1.1) == 110)
	}

	@Test
	internal func zoomCommandsUseChromesKeysAndNeedATab() async throws {
		#expect(BrowserCommand.zoomIn.shortcut == .init(key: "="))
		#expect(BrowserCommand.zoomOut.shortcut == .init(key: "-"))
		#expect(BrowserCommand.actualSize.shortcut == .init(key: "0"))
		for command in [BrowserCommand.zoomIn, .zoomOut, .actualSize] {
			let shortcut = try #require(command.shortcut)
			#expect(shortcut.isValid && !shortcut.isReserved)
			#expect(BrowserCommand.allCases.filter { $0.shortcut == shortcut } == [command])
			#expect(command.defaultShortcutYieldsToUserBindings)
			#expect(command.isEnabled(in: .init(host: .main, hasTab: true)))
			#expect(command.isEnabled(in: .init(host: .main, hasTab: true, isPrivate: true)))
			#expect(command.isEnabled(in: .init(host: .peek, hasTab: true)))
			#expect(command.isEnabled(in: .init(host: .little, hasTab: true)))
			#expect(!command.isEnabled(in: .init(host: .main)))
			#expect(!command.isEnabled(in: .init(host: .main, hasTab: true, isBusy: true)))
		}
		#expect(BrowserCommand.zoomIn.pageZoom == .zoomIn)
		#expect(BrowserCommand.reload.pageZoom == nil)
	}
}
