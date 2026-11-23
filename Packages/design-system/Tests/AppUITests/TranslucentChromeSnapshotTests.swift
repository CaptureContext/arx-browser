import AppKit
@testable import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

/// Writes offscreen PNGs of the translucent chrome (DEV-1286) at low, middle and high intensity,
/// light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory. A real desktop can't be drawn
/// offscreen, and the behind-window blur draws a flat fill there, so each window sits over a busy
/// striped backdrop blurred and washed as `.underWindowBackground` roughly does instead; the
/// strip on top shows the backdrop unblurred.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: SidebarChromeSnapshot.directory != nil)
)
internal struct TranslucentChromeSnapshotTests {
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func theChromeAtThreeIntensities(_ appearance: NSAppearance.Name) throws {
		try SidebarChromeSnapshot.write(
			Self.windows(isDark: appearance == .darkAqua),
			size: .init(width: 1_260, height: 420),
			appearance: appearance,
			name: "translucent-chrome"
		)
	}

	private static let samples: [(title: String, intensity: Double)] = [
		("Low, 0.05", 0.05),
		("Middle, 0.3", 0.3),
		("High, 0.6", 0.6),
	]

	private static func windows(isDark: Bool) -> some View {
		HStack(spacing: 20) {
			ForEach(samples, id: \.title) { sample in
				VStack(alignment: .leading, spacing: 6) {
					Text(verbatim: "\(sample.title): opacity \(String(format: "%.2f", opacity(sample.intensity)))")
						.font(.headline)
					window(intensity: sample.intensity, isDark: isDark)
				}
			}
		}
		.padding(20)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.background(Color(nsColor: .windowBackgroundColor))
	}

	private static func opacity(_ intensity: Double) -> Double {
		TranslucentChrome.opacity(
			intensity: intensity,
			isEnabled: true,
			reduceTransparency: false,
			increaseContrast: false
		)
	}

	private static func window(
		intensity: Double,
		isDark: Bool
	) -> some View {
		ZStack {
			// The desktop behind the window, as the behind-window blur shows it.
			backdrop
				.blur(radius: 20, opaque: true)
				.overlay { Color(nsColor: .underPageBackgroundColor).opacity(isDark ? 0.55 : 0.5) }
			BrowserChromeBackground(textured: true, isTranslucent: true)
			HStack(spacing: 0) {
				sidebar
					.frame(width: 150)
				Text(verbatim: "The page stays solid")
					.font(.system(size: 13))
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.browserPageCard()
					.padding([.vertical, .trailing], 8)
			}
		}
		.environment(\.browserChromeTint, .init(hue: 240, intensity: intensity))

		// Offscreen, the real blur draws a flat fill over the stand-in desktop.
		.environment(\.browserChromeBlursBehindWindow, false)
		.frame(width: 390, height: 300)
		.clipShape(.rect(cornerRadius: 12, style: .continuous))
		.overlay(alignment: .top) {
			backdrop
				.frame(height: 14)
				.clipShape(.rect(cornerRadius: 12, style: .continuous))
				.offset(y: -22)
		}
		.padding(.top, 22)
	}

	private static var sidebar: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text(verbatim: "Arx")
				.font(.system(size: 13, weight: .semibold))
			ForEach(["Inbox", "Calendar", "Design review", "Release notes", "Linear"], id: \.self) { title in
				Label {
					Text(verbatim: title)
				} icon: {
					Image(systemName: "globe")
				}
				.font(.system(size: 13))
			}
			Spacer()
			Text(verbatim: "Today")
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
		}
		.padding(14)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}

	/// Broad diagonal stripes and a few large circles, so the blur keeps their colors apart.
	private static var backdrop: some View {
		Canvas { context, size in
			let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .black, .white]
			let band: CGFloat = 70
			var x: CGFloat = -size.height
			var index = 0
			while x < size.width + size.height {
				var path = Path()
				path.move(to: .init(x: x, y: 0))
				path.addLine(to: .init(x: x + band, y: 0))
				path.addLine(to: .init(x: x + band + size.height, y: size.height))
				path.addLine(to: .init(x: x + size.height, y: size.height))
				path.closeSubpath()
				context.fill(path, with: .color(colors[index % colors.count]))
				x += band
				index += 1
			}
			for (center, color) in [(CGPoint(x: 80, y: 90), Color.white), (.init(x: 260, y: 200), .black), (.init(x: 330, y: 60), .yellow)] {
				context.fill(
					Path(ellipseIn: .init(x: center.x - 70, y: center.y - 70, width: 140, height: 140)),
					with: .color(color)
				)
			}
		}
	}
}
