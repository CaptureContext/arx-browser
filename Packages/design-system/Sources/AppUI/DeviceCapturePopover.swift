import BrowserCore
import SwiftUI

/// The developer header's capture popover, with the `ARX_DEVICE_CAPTURE` feature flag on
/// (DEV-757): a preview of the framed shot, Capture in Portrait Mode, a slider for the
/// background's hue, then Capture, and the plain captures the header's menu offers otherwise.
public struct DeviceCapturePopover: View {
	public let send: (DeveloperHeaderAction) -> Void

	@Environment(\.colorScheme)
	private var colorScheme

	@SwiftUI.State
	private var isPortrait: Bool

	@SwiftUI.State
	private var gradient: Double

	public init(
		style: DeviceCaptureStyle,
		send: @escaping (DeveloperHeaderAction) -> Void
	) {
		self.send = send
		self._isPortrait = .init(initialValue: style.isPortrait)
		self._gradient = .init(initialValue: style.gradient)
	}

	/// The style Capture takes: the page's appearance picks the device's.
	private var style: DeviceCaptureStyle {
		.init(isPortrait: isPortrait, gradient: gradient, isDark: colorScheme == .dark)
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			DeviceCapturePreview(style: style)
				.frame(height: 132)
				.accessibilityLabel(Text(localized: .appUI.developer.deviceCapturePreview))

			Toggle(String.localized(.appUI.developer.deviceCapturePortrait), isOn: $isPortrait)
				.toggleStyle(.switch)
				.controlSize(.small)

			VStack(alignment: .leading, spacing: 6) {
				Text(localized: .appUI.developer.deviceCaptureBackground)
					.font(.callout)
					.foregroundStyle(.secondary)
				Slider(value: $gradient, in: 0...1)
					.controlSize(.small)
					.accessibilityLabel(Text(localized: .appUI.developer.deviceCaptureBackground))
				Capsule()
					.fill(LinearGradient(colors: Self.hues, startPoint: .leading, endPoint: .trailing))
					.frame(height: 4)
					.accessibilityHidden(true)
			}

			Button(String.localized(.appUI.developer.headerCapture)) { send(.captureDevice(style)) }
				.buttonStyle(.arx(.primary, size: .regular))
				.keyboardShortcut(.defaultAction)
				.frame(maxWidth: .infinity)

			HStack(spacing: 8) {
				Button(String.localized(.appUI.developer.deviceCapturePlain)) { send(.captureViewport) }
				Button(String.localized(.appUI.siteMenu.captureRegion)) { send(.captureRegion) }
			}
			.buttonStyle(.arx(.secondary, size: .small))
			.frame(maxWidth: .infinity)
		}
		.padding(14)
		.frame(width: 264)
	}

	/// The slider's legend: the background's hue at each place.
	private static let hues: [Color] = stride(from: 0.0, through: 1.0, by: 0.125).map { place in
		Color(DeviceCaptureStyle(gradient: place).gradientColors.start)
	}
}

/// A small picture of what Capture makes: the device on its gradient, a page sketched inside.
public struct DeviceCapturePreview: View {
	public let style: DeviceCaptureStyle

	public init(style: DeviceCaptureStyle) {
		self.style = style
	}

	public var body: some View {
		GeometryReader { geometry in
			let screen: CGSize = style.isPortrait ? .init(width: 90, height: 195) : .init(width: 320, height: 200)
			let full: DeviceCaptureLayout = .init(screen: screen, isPortrait: style.isPortrait)
			let factor = min(
				geometry.size.width / full.canvas.width,
				geometry.size.height / full.canvas.height
			)
			let layout = full.scaled(by: factor)
			let (start, end) = style.gradientColors
			ZStack(alignment: .topLeading) {
				LinearGradient(
					colors: [Color(start), Color(end)],
					startPoint: .topLeading,
					endPoint: .bottomTrailing
				)
				RoundedRectangle(cornerRadius: layout.deviceCornerRadius, style: .continuous)
					.fill(Color(style.deviceColor))
					.shadow(color: .black.opacity(style.isDark ? 0.45 : 0.28), radius: 4, y: 2)
					.frame(width: layout.device.width, height: layout.device.height)
					.offset(x: layout.device.minX, y: layout.device.minY)
				SketchedPage(isDark: style.isDark)
					.clipShape(RoundedRectangle(cornerRadius: layout.screenCornerRadius, style: .continuous))
					.frame(width: layout.screen.width, height: layout.screen.height)
					.offset(x: layout.screen.minX, y: layout.screen.minY)
				ForEach(Array(layout.details.enumerated()), id: \.offset) { _, detail in
					Capsule()
						.fill(Color(style.detailColor))
						.frame(width: detail.width, height: detail.height)
						.offset(x: detail.minX, y: detail.minY)
				}
			}
			.frame(width: layout.canvas.width, height: layout.canvas.height, alignment: .topLeading)
			.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
			.frame(width: geometry.size.width, height: geometry.size.height)
		}
	}
}

/// A page in a few strokes, so the preview reads as a screenshot without showing one.
private struct SketchedPage: View {
	internal let isDark: Bool

	internal var body: some View {
		GeometryReader { geometry in
			let unit = geometry.size.width / 12
			VStack(alignment: .leading, spacing: unit * 0.6) {
				RoundedRectangle(cornerRadius: unit * 0.3)
					.frame(width: unit * 5, height: unit * 0.9)
				RoundedRectangle(cornerRadius: unit * 0.3)
					.frame(height: unit * 3)
					.opacity(0.5)
				ForEach(0..<3, id: \.self) { line in
					RoundedRectangle(cornerRadius: unit * 0.2)
						.frame(width: unit * (line == 2 ? 6 : 9.5), height: unit * 0.5)
						.opacity(0.35)
				}
			}
			.foregroundStyle(isDark ? Color.white.opacity(0.7) : Color.black.opacity(0.55))
			.padding(unit)
			.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
			.background(isDark ? Color(white: 0.16) : Color(white: 0.98))
		}
	}
}

extension Color {
	fileprivate init(_ color: DeviceCaptureColor) {
		self.init(.sRGB, red: color.red, green: color.green, blue: color.blue)
	}
}
