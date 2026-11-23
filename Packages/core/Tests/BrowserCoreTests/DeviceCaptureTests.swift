import BrowserCore
import CoreGraphics
import CustomDump
import Foundation
import Testing

/// DEV-757: the developer header's device capture.
internal struct DeviceCaptureTests {
	@Test
	internal func portraitTakesACentredPhoneSliceOfAWideViewport() {
		let region = DeviceCaptureStyle.portraitRegion(in: .init(x: 0, y: 0, width: 1200, height: 780))
		expectNoDifference(region.height, 780)
		#expect(abs(region.width - 360) < 0.001)
		#expect(abs(region.x - 420) < 0.001)
		expectNoDifference(region.y, 0)
	}

	@Test
	internal func portraitKeepsAViewportAlreadyNarrowerThanAPhone() {
		let viewport = PageCaptureRegion(x: 0, y: 0, width: 300, height: 900)
		expectNoDifference(DeviceCaptureStyle.portraitRegion(in: viewport), viewport)
	}

	@Test(arguments: [-1.0, 2.0, .nan])
	internal func theSliderStaysBetweenItsEnds(_ value: Double) {
		let gradient = DeviceCaptureStyle(gradient: value).gradient
		#expect((0...1).contains(gradient))
	}

	@Test(arguments: [false, true])
	internal func theScreenSitsInsideTheDeviceInsideTheCanvas(_ isPortrait: Bool) {
		let size: CGSize = isPortrait ? .init(width: 360, height: 780) : .init(width: 1200, height: 780)
		let layout = DeviceCaptureLayout(screen: size, isPortrait: isPortrait)
		let canvas = CGRect(origin: .zero, size: layout.canvas)
		expectNoDifference(layout.screen.size, size)
		#expect(canvas.contains(layout.device))
		#expect(layout.device.contains(layout.screen))
		#expect(layout.screenCornerRadius <= layout.deviceCornerRadius)
		// A phone has its camera, a window its three title bar dots.
		expectNoDifference(layout.details.count, isPortrait ? 1 : 3)

		let half = layout.scaled(by: 0.5)
		#expect(abs(half.canvas.width - layout.canvas.width / 2) < 0.001)
		#expect(abs(half.screen.minX - layout.screen.minX / 2) < 0.001)
	}

	@Test
	internal func darkStylesHaveADarkDeviceAndADeeperBackground() {
		let light = DeviceCaptureStyle(gradient: 0.3, isDark: false)
		let dark = DeviceCaptureStyle(gradient: 0.3, isDark: true)
		#expect(dark.deviceColor.red < light.deviceColor.red)
		#expect(
			dark.gradientColors.start.red + dark.gradientColors.start.green + dark.gradientColors.start.blue
			< light.gradientColors.start.red + light.gradientColors.start.green + light.gradientColors.start.blue
		)
	}

	@Test
	internal func theFeatureFlagIsOnUnlessTurnedOff() throws {
		let suite = "DeviceCaptureTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		// On by default (DEV-1143).
		#expect(DeviceCaptureFeatureFlag.isOn(environment: [:], defaults: defaults))
		#expect(DeviceCaptureFeatureFlag.isOn(environment: ["ARX_DEVICE_CAPTURE": "1"], defaults: defaults))
		#expect(DeviceCaptureFeatureFlag.isOn(environment: ["ARX_DEVICE_CAPTURE": "YES"], defaults: defaults))
		#expect(!DeviceCaptureFeatureFlag.isOn(environment: ["ARX_DEVICE_CAPTURE": "0"], defaults: defaults))

		defaults.set("0", forKey: "ARX_DEVICE_CAPTURE")
		#expect(!DeviceCaptureFeatureFlag.isOn(environment: [:], defaults: defaults))
		// The environment wins over user defaults.
		#expect(DeviceCaptureFeatureFlag.isOn(environment: ["ARX_DEVICE_CAPTURE": "yes"], defaults: defaults))
	}
}
