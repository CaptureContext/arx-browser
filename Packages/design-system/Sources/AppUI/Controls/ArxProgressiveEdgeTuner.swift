import AppKit
import SwiftUI

/// The progressive edge's standard look (DEV-808), shared by every bar that uses
/// ``ArxProgressiveEdge/Style/standard``, so ``ArxProgressiveEdgeTuner`` can change it live. The
/// sidebar's own style is fixed. It starts at the standard values and keeps what the tuner sets
/// in Arx's defaults, under `ARX_SCROLL_EDGE_TUNING`, read only while the tuner is on.
@MainActor
@Observable
internal final class ArxProgressiveEdgeTuning {
	internal static let shared: ArxProgressiveEdgeTuning = .init()

	private static let defaultsKey: String = "ARX_SCROLL_EDGE_TUNING"

	/// The strongest blur, at the top, in points.
	internal var radius: CGFloat = ArxProgressiveEdge.Style.standard.radius { didSet { save() } }

	/// The share of the height, from the top, at full strength; below it both ease out.
	internal var plateau: CGFloat = ArxProgressiveEdge.Style.standard.plateau { didSet { save() } }

	/// The veil's opacity at the top.
	internal var veilTop: CGFloat = ArxProgressiveEdge.Style.standard.veilTop { didSet { save() } }

	/// The veil's opacity where the plateau ends.
	internal var veilPlateau: CGFloat = ArxProgressiveEdge.Style.standard.veilPlateau { didSet { save() } }

	/// The veil's opacity three quarters of the way down.
	internal var veilLate: CGFloat = ArxProgressiveEdge.Style.standard.veilLate { didSet { save() } }

	/// The veil's darkness over a translucent surface, such as the chat panel or the Library,
	/// which has no background of its own to veil with.
	internal var translucentVeil: CGFloat = ArxProgressiveEdge.Style.standard.translucentVeil { didSet { save() } }

	private var isLoading: Bool = false

	/// The values as the standard style draws them.
	internal var style: ArxProgressiveEdge.Style {
		.init(
			radius: radius,
			plateau: plateau,
			veilTop: veilTop,
			veilPlateau: veilPlateau,
			veilLate: veilLate,
			translucentVeil: translucentVeil
		)
	}

	internal init() {}

	/// Starts from the values the tuner kept last time.
	internal func load() {
		guard let saved = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Double]
		else { return }

		isLoading = true
		defer { isLoading = false }
		for (key, path) in Self.fields {
			if let value = saved[key] { self[keyPath: path] = value }
		}
	}

	/// Back to the built-in values.
	internal func reset() {
		let standard = Self()
		for (_, path) in Self.fields {
			self[keyPath: path] = standard[keyPath: path]
		}
	}

	/// The values, one per line, to paste back.
	internal var summary: String {
		Self.fields
			.map { key, path in "\(key): \(Self.format(self[keyPath: path]))" }
			.joined(separator: "\n")
	}

	internal static func format(_ value: CGFloat) -> String {
		String(format: "%.2f", Double(value))
	}

	private static let fields: [(String, ReferenceWritableKeyPath<ArxProgressiveEdgeTuning, CGFloat>)] = [
		("radius", \.radius),
		("plateau", \.plateau),
		("veilTop", \.veilTop),
		("veilPlateau", \.veilPlateau),
		("veilLate", \.veilLate),
		("translucentVeil", \.translucentVeil),
	]

	private func save() {
		guard !isLoading, self === Self.shared else { return }
		var values: [String: Double] = [:]
		for (key, path) in Self.fields {
			values[key] = Double(self[keyPath: path])
		}
		UserDefaults.standard.set(values, forKey: Self.defaultsKey)
	}
}

/// A floating panel to adjust the progressive edge live (DEV-808), with each value shown, a
/// button to copy them all and one to reset them. `ARX_SCROLL_EDGE_TUNER=1` opens it the first
/// time a bar with the edge appears. A tool for finding the values, not a setting.
internal enum ArxProgressiveEdgeTuner {
	@MainActor
	private static var panel: NSPanel?

	@MainActor
	internal static func show() {
		if let panel {
			panel.orderFront(nil)
			return
		}
		ArxProgressiveEdgeTuning.shared.load()
		let panel = NSPanel(
			contentRect: .init(x: 0, y: 0, width: 320, height: 380),
			styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.title = "Scroll Edge Tuner"
		panel.isFloatingPanel = true
		panel.level = .floating
		panel.hidesOnDeactivate = false
		panel.isReleasedWhenClosed = false
		panel.contentView = NSHostingView(rootView: Panel(tuning: .shared))

		// Beside the window in use, on its screen, rather than on the main display.
		let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
		if let window, let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
			let x = min(window.frame.maxX + 12, screen.maxX - panel.frame.width)
			let y = min(window.frame.maxY, screen.maxY)
			panel.setFrameTopLeftPoint(.init(x: max(x, screen.minX), y: y))
		}
		panel.orderFront(nil)
		self.panel = panel
	}

	private struct Panel: View {
		@Bindable
		internal var tuning: ArxProgressiveEdgeTuning

		@SwiftUI.State
		private var copied: Bool = false

		internal var body: some View {
			VStack(alignment: .leading, spacing: 10) {
				row("Blur radius", value: $tuning.radius, in: 0...30, step: 0.5)
				row("Plateau", value: $tuning.plateau, in: 0...1, step: 0.01)
				Divider()
				row("Veil at top", value: $tuning.veilTop, in: 0...1, step: 0.01)
				row("Veil at plateau", value: $tuning.veilPlateau, in: 0...1, step: 0.01)
				row("Veil at 3/4", value: $tuning.veilLate, in: 0...1, step: 0.01)
				row("Translucent veil", value: $tuning.translucentVeil, in: 0...1, step: 0.01)
				Divider()
				HStack {
					Button(copied ? "Copied" : "Copy values") {
						NSPasteboard.general.clearContents()
						NSPasteboard.general.setString(tuning.summary, forType: .string)
						copied = true
					}
					Spacer()
					Button("Reset") { tuning.reset() }
				}
			}
			.padding(14)
			.frame(width: 320)
			.onChange(of: tuning.summary) { copied = false }
		}

		private func row(
			_ title: String,
			value: Binding<CGFloat>,
			in range: ClosedRange<CGFloat>,
			step: CGFloat
		) -> some View {
			VStack(alignment: .leading, spacing: 2) {
				HStack {
					Text(verbatim: title)
					Spacer()
					Text(verbatim: ArxProgressiveEdgeTuning.format(value.wrappedValue))
						.monospacedDigit()
						.foregroundStyle(.secondary)
				}
				Slider(value: value, in: range, step: step)
					.controlSize(.small)
			}
		}
	}
}
