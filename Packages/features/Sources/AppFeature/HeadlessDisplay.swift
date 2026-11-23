import AppKit
import Foundation
import _ComposableArchitecture

/// The screens AppKit reports, main screen first. Empty on a Mac whose only
/// display went away, which a headless run must survive (DEV-865).
public struct ScreensClient: Sendable {
	public struct Screen: Equatable, Sendable {
		public var frame: CGRect
		public var backingScale: CGFloat

		public init(
			frame: CGRect,
			backingScale: CGFloat
		) {
			self.frame = frame
			self.backingScale = backingScale
		}
	}

	public var screens: @MainActor @Sendable () -> [Screen]

	public init(screens: @escaping @MainActor @Sendable () -> [Screen]) {
		self.screens = screens
	}
}

extension ScreensClient: DependencyKey {
	public static var liveValue: Self {
		.init(screens: {
			let main = NSScreen.main
			let ordered = [main].compactMap(\.self) + NSScreen.screens.filter { $0 !== main }
			return ordered.map { .init(frame: $0.frame, backingScale: $0.backingScaleFactor) }
		})
	}

	public static var testValue: Self {
		.init(screens: unimplemented("ScreensClient.screens", placeholder: []))
	}
}

extension DependencyValues {
	public var screens: ScreensClient {
		get { self[ScreensClient.self] }
		set { self[ScreensClient.self] = newValue }
	}
}

/// Where an unattended run's transparent host sits and the device scale its pages
/// render at. Both are fixed when the run starts, so captures keep their pixel size
/// while a Screen Sharing display comes and goes (DEV-865).
internal struct HeadlessDisplay: Equatable, Sendable {
	/// The host's frame origin in screen coordinates.
	internal var origin: CGPoint

	/// Chromium's device scale for the run; capture pixels are the viewport times this.
	internal var deviceScale: CGFloat

	/// Whether a screen, physical or virtual, was there at startup.
	internal var hasScreen: Bool

	/// The scale without a screen: what a Retina Mac reports.
	internal static let fallbackScale: CGFloat = 2

	/// Far from any screen a display could later add, so the host never lands on one.
	internal static let offscreenOrigin: CGPoint = .init(x: -16_000, y: -16_000)

	/// Scales Chromium is asked to force; anything else falls back.
	internal static let scales: ClosedRange<CGFloat> = 1 ... 4

	/// Read by the engine bridge in unattended runs only, as `--force-device-scale-factor`.
	internal static let environmentKey: String = "ARX_UNATTENDED_DEVICE_SCALE"

	internal init(
		origin: CGPoint,
		deviceScale: CGFloat,
		hasScreen: Bool
	) {
		self.origin = origin
		self.deviceScale = deviceScale
		self.hasScreen = hasScreen
	}

	/// On the main screen, physical or virtual, at its origin and scale. Without
	/// one, off every screen at the fixed fallback scale.
	internal init(screens: [ScreensClient.Screen]) {
		guard let screen = screens.first else {
			self.init(
				origin: Self.offscreenOrigin,
				deviceScale: Self.fallbackScale,
				hasScreen: false
			)
			return
		}

		let scale = screen.backingScale
		self.init(
			origin: screen.frame.origin,
			deviceScale: scale.isFinite && Self.scales.contains(scale) ? scale : Self.fallbackScale,
			hasScreen: true
		)
	}

	@MainActor
	internal static func current() -> Self {
		@Dependency(\.screens)
		var screens

		return .init(screens: screens.screens())
	}

	/// The value for `environmentKey`: the shortest decimal that reads back exactly.
	internal var environmentValue: String {
		deviceScale.rounded() == deviceScale
		? String(Int(deviceScale))
		: String(Double(deviceScale))
	}
}
