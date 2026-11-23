import CoreGraphics
import Foundation

/// How the developer header's device capture frames a page (DEV-757): as a phone in portrait,
/// or as a window, on a gradient background. Arx draws the frame and the gradient itself.
public struct DeviceCaptureStyle: Codable, Equatable, Hashable, Sendable {
	/// Capture in Portrait Mode: a phone-shaped slice of the visible page, framed as a phone.
	public var isPortrait: Bool

	/// The background's place on the slider, from 0 to 1, which picks its hue.
	public var gradient: Double

	/// A dark device and a deeper background, for a page captured in dark mode.
	public var isDark: Bool

	public init(
		isPortrait: Bool = false,
		gradient: Double = 0.6,
		isDark: Bool = false
	) {
		self.isPortrait = isPortrait
		self.gradient = min(max(gradient.isFinite ? gradient : 0.6, 0), 1)
		self.isDark = isDark
	}

	/// What the popover starts with.
	public static let `default`: Self = .init()

	/// A phone's screen, width to height.
	public static let portraitAspectRatio: Double = 9 / 19.5

	/// The part of `viewport` Portrait Mode captures: its full height, centred, as wide as a
	/// phone's screen of that height, or the whole viewport when it's narrower than that.
	public static func portraitRegion(in viewport: PageCaptureRegion) -> PageCaptureRegion {
		let width = min(viewport.width, viewport.height * portraitAspectRatio)
		return .init(
			x: viewport.x + (viewport.width - width) / 2,
			y: viewport.y,
			width: width,
			height: viewport.height
		)
	}

	/// The background's two colours, top-leading to bottom-trailing, as sRGB components.
	public var gradientColors: (start: DeviceCaptureColor, end: DeviceCaptureColor) {
		let brightness: Double = isDark ? 0.62 : 0.96
		return (
			.init(hue: gradient, saturation: 0.52, brightness: brightness),
			.init(hue: (gradient + 0.09).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: brightness * 0.78)
		)
	}

	/// The device's body.
	public var deviceColor: DeviceCaptureColor {
		isDark
		? .init(red: 0.11, green: 0.11, blue: 0.12)
		: .init(red: 0.9, green: 0.9, blue: 0.92)
	}

	/// The window's title bar dots and the phone's camera.
	public var detailColor: DeviceCaptureColor {
		isDark
		? .init(red: 0.3, green: 0.3, blue: 0.32)
		: .init(red: 0.72, green: 0.72, blue: 0.75)
	}
}

/// An sRGB colour with components from 0 to 1.
public struct DeviceCaptureColor: Equatable, Sendable {
	public var red: Double
	public var green: Double
	public var blue: Double

	public init(
		red: Double,
		green: Double,
		blue: Double
	) {
		self.red = red
		self.green = green
		self.blue = blue
	}

	public init(
		hue: Double,
		saturation: Double,
		brightness: Double
	) {
		let sector = (hue - hue.rounded(.down)) * 6
		let index = Int(sector.rounded(.down)) % 6
		let fraction = sector - sector.rounded(.down)
		let low = brightness * (1 - saturation)
		let falling = brightness * (1 - saturation * fraction)
		let rising = brightness * (1 - saturation * (1 - fraction))
		let components: (Double, Double, Double) = switch index {
		case 0: (brightness, rising, low)
		case 1: (falling, brightness, low)
		case 2: (low, brightness, rising)
		case 3: (low, falling, brightness)
		case 4: (rising, low, brightness)
		default: (brightness, low, falling)
		}
		self.init(red: components.0, green: components.1, blue: components.2)
	}
}

/// Where a device capture's parts go, for a screen of a given size: the same layout for the
/// rendered image and the popover's preview. Origins are top-leading.
public struct DeviceCaptureLayout: Equatable, Sendable {
	/// The whole image: the gradient.
	public var canvas: CGSize

	/// The device's body.
	public var device: CGRect
	public var deviceCornerRadius: Double

	/// Where the page goes.
	public var screen: CGRect
	public var screenCornerRadius: Double

	/// The phone's camera, or the window's three title bar dots.
	public var details: [CGRect]

	public init(
		screen size: CGSize,
		isPortrait: Bool
	) {
		let width = max(Double(size.width), 1)
		let height = max(Double(size.height), 1)
		if isPortrait {
			let bezel = width * 0.035
			let device = CGSize(width: width + bezel * 2, height: height + bezel * 2)
			let margin = max(device.width, device.height) * 0.14
			self.canvas = .init(width: device.width + margin * 2, height: device.height + margin * 2)
			self.device = .init(x: margin, y: margin, width: device.width, height: device.height)
			self.deviceCornerRadius = device.width * 0.13
			self.screen = .init(x: margin + bezel, y: margin + bezel, width: width, height: height)
			self.screenCornerRadius = max(self.deviceCornerRadius - bezel, 0)
			let camera = bezel * 0.9
			self.details = [.init(
				x: margin + device.width / 2 - camera * 2,
				y: margin + bezel + camera * 0.8,
				width: camera * 4,
				height: camera * 1.3
			)]
		} else {
			let border = max(width * 0.006, 2)
			let titleBar = max(width * 0.032, 18)
			let device = CGSize(width: width + border * 2, height: height + titleBar + border)
			let margin = max(device.width, device.height) * 0.08
			self.canvas = .init(width: device.width + margin * 2, height: device.height + margin * 2)
			self.device = .init(x: margin, y: margin, width: device.width, height: device.height)
			self.deviceCornerRadius = titleBar * 0.6
			self.screen = .init(x: margin + border, y: margin + titleBar, width: width, height: height)
			self.screenCornerRadius = max(self.deviceCornerRadius - border, 0)
			let dot = titleBar * 0.36
			self.details = (0..<3).map { index in
				.init(
					x: margin + titleBar * 0.5 + Double(index) * dot * 1.7,
					y: margin + (titleBar - dot) / 2,
					width: dot,
					height: dot
				)
			}
		}
	}

	/// The same layout with every length multiplied by `factor`.
	public func scaled(by factor: Double) -> Self {
		func scale(_ rect: CGRect) -> CGRect {
			.init(
				x: rect.minX * factor,
				y: rect.minY * factor,
				width: rect.width * factor,
				height: rect.height * factor
			)
		}
		var layout = self
		layout.canvas = .init(width: canvas.width * factor, height: canvas.height * factor)
		layout.device = scale(device)
		layout.deviceCornerRadius = deviceCornerRadius * factor
		layout.screen = scale(screen)
		layout.screenCornerRadius = screenCornerRadius * factor
		layout.details = details.map(scale)
		return layout
	}
}

/// The `ARX_DEVICE_CAPTURE` feature flag (DEV-757): the developer header's Capture button
/// opens the device capture popover instead of its menu. Off by default. The environment first,
/// then user defaults, as the other `ARX_*` feature flags read; `1`, `true` or `yes` turns it on.
public enum DeviceCaptureFeatureFlag {
	public static let name: String = FeatureFlag.deviceCapture.name

	public static func isOn(
		environment: [String: String],
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.deviceCapture.isOn(environment: environment, defaults: defaults)
	}
}
