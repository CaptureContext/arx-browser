#if DEBUG
// Bodies are counted only in Debug builds.
import AppKit
@testable import AppUI
import BrowserCore
import Foundation
import Observation
import SwiftUI
import Testing

/// DEV-902: the command bar, the window chrome and Settings hold to render-count ceilings, as the
/// sidebar's rows do in `SidebarRenderCountTests`. Each test hosts the view in a window kept off
/// every screen, makes one ordinary change and counts the bodies it ran.
///
/// A ceiling is today's count. Lower it when a change renders less; never raise it to make a
/// test pass, unless the extra renders are the point of the change and its review says why.
@MainActor
@Suite(
	.serialized,
	.renderTurn,
	.enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to lay out views")
)
internal struct RenderCountTests {
	internal enum Ceiling {
		internal static let commandBarSelectionBodies: Int = 1

		/// The row the selection leaves and the one it reaches, never the rest (DEV-997).
		internal static let commandBarSelectionRows: Int = 2
		internal static let commandBarResultsBodies: Int = 1

		/// Only the row whose result changed.
		internal static let commandBarResultsRows: Int = 1
		internal static let chromeTitleChange: Int = 0
		internal static let chromeURLChange: Int = 1
		internal static let chromeLoadingChange: Int = 1

		/// The background has no inputs, yet runs again when the window's URL or loading state changes.
		internal static let chromeBackgroundOnNavigation: Int = 1
		internal static let settingsToggleSections: Int = 1
		internal static let settingsToggleRows: Int = SettingsModel.toggleCount
		internal static let settingsOtherPaneRows: Int = 0
	}

	// MARK: - Command bar

	@Test
	internal func movingTheSelectionStaysUnderItsCeiling() {
		let model: CommandBarModel = .init()
		let host: RenderHost = .init { CommandBarHarness(model: model) }
		defer { host.close() }

		let counts = host.recording { model.selectedID = "r7" }
		Self.report("command bar, selection", counts)
		#expect(counts["CommandBar.body", default: 0] <= Ceiling.commandBarSelectionBodies, "\(counts)")
		#expect(counts["CommandBar.resultRow", default: 0] <= Ceiling.commandBarSelectionRows, "\(counts)")

		// Holding ↓: each step draws only the two rows it moves between.
		for index in 8..<12 {
			let step = host.recording { model.selectedID = "r\(index)" }
			#expect(step["CommandBar.resultRow", default: 0] <= Ceiling.commandBarSelectionRows, "\(step)")
		}
	}

	@Test
	internal func newResultsStayUnderTheirCeiling() {
		let model: CommandBarModel = .init()
		let host: RenderHost = .init { CommandBarHarness(model: model) }
		defer { host.close() }

		let counts = host.recording {
			model.query = "arx"
			model.results[3].title = "Arx Manual"
		}
		Self.report("command bar, results", counts)
		#expect(counts["CommandBar.body", default: 0] <= Ceiling.commandBarResultsBodies, "\(counts)")
		#expect(counts["CommandBar.resultRow", default: 0] <= Ceiling.commandBarResultsRows, "\(counts)")
	}

	// MARK: - Window chrome

	@Test
	internal func anotherTabsTitleLeavesTheChromeAlone() {
		let model: ChromeModel = .init()
		let host: RenderHost = .init { ChromeHarness(model: model) }
		defer { host.close() }

		let counts = host.recording { model.otherTabTitle = "Renamed" }
		Self.report("chrome, other tab's title", counts)
		#expect(Self.chrome(counts) <= Ceiling.chromeTitleChange, "\(counts)")
	}

	@Test
	internal func aNavigationRendersTheAddressBarOnce() {
		let model: ChromeModel = .init()
		let host: RenderHost = .init { ChromeHarness(model: model) }
		defer { host.close() }

		let counts = host.recording { model.url = URL(string: "https://example.com/next") }
		Self.report("chrome, navigation", counts)
		#expect(counts["URLBar.body", default: 0] <= Ceiling.chromeURLChange, "\(counts)")
		#expect(counts["BrowserHistoryControl.body", default: 0] <= Ceiling.chromeURLChange, "\(counts)")
		#expect(counts["BrowserChromeBackground.body", default: 0] <= Ceiling.chromeBackgroundOnNavigation, "\(counts)")

		let loading = host.recording { model.isLoading = true }
		Self.report("chrome, loading", loading)
		#expect(loading["URLBar.body", default: 0] <= Ceiling.chromeLoadingChange, "\(loading)")
		#expect(loading["BrowserChromeBackground.body", default: 0] <= Ceiling.chromeBackgroundOnNavigation, "\(loading)")
	}

	// MARK: - Settings

	@Test
	internal func aSwitchRendersItsSectionUnderItsCeiling() {
		let model: SettingsModel = .init()
		let host: RenderHost = .init { SettingsHarness(model: model) }
		defer { host.close() }

		let counts = host.recording { model.values[4].toggle() }
		Self.report("settings, one switch", counts)
		#expect(counts["SettingsSection.body", default: 0] <= Ceiling.settingsToggleSections, "\(counts)")
		#expect(
			counts["SettingsToggle.body", default: 0] + counts["SettingsRow.body", default: 0]
				<= Ceiling.settingsToggleRows * 2,
			"\(counts)"
		)
		#expect(counts["SettingsToggle.body", default: 0] <= Ceiling.settingsToggleRows, "\(counts)")
	}

	@Test
	internal func anotherPanesValueLeavesThisPaneAlone() {
		let model: SettingsModel = .init()
		let host: RenderHost = .init { SettingsHarness(model: model) }
		defer { host.close() }

		let counts = host.recording { model.otherPaneValue += 1 }
		Self.report("settings, other pane", counts)
		#expect(counts.values.reduce(0, +) <= Ceiling.settingsOtherPaneRows, "\(counts)")
	}

	// MARK: - Helpers

	private static func chrome(_ counts: [String: Int]) -> Int {
		["URLBar.body", "BrowserHistoryControl.body", "BrowserChromeBackground.body"]
			.reduce(0) { $0 + counts[$1, default: 0] }
	}

	/// Today's counts in the test log, for lowering a ceiling.
	private static func report(
		_ name: String,
		_ counts: [String: Int]
	) {
		let sorted: String = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
		print("render counts (\(name)): \(sorted.isEmpty ? "none" : sorted)")
	}
}

// MARK: - Command bar

@MainActor
@Observable
internal final class CommandBarModel {
	internal nonisolated static let resultCount: Int = 20

	internal var query: String = ""
	internal var selectedID: String? = "r0"
	internal var results: [CommandBarResult] = (0..<resultCount).map { index in
		.init(id: "r\(index)", title: "Result \(index)", subtitle: "https://example.com/\(index)", actionTitle: "Open", symbol: "globe")
	}
}

private struct CommandBarHarness: View {
	internal let model: CommandBarModel

	internal var body: some View {
		CommandBar(
			query: Binding(get: { model.query }, set: { model.query = $0 }),
			selectedID: Binding(get: { model.selectedID }, set: { model.selectedID = $0 }),
			results: model.results,
			onSelect: { _ in },
			onDismiss: {}
		)
		.frame(width: 640, height: 520)
	}
}

// MARK: - Window chrome

@MainActor
@Observable
internal final class ChromeModel {
	internal var url: URL? = URL(string: "https://example.com")
	internal var isLoading: Bool = false
	internal var otherTabTitle: String = "Other"
	internal var navigation: BrowserNavigation = .init()
}

/// The parts of the window chrome above the page: background, history buttons and address bar,
/// and a list that reads another tab's title, as the sidebar does.
private struct ChromeHarness: View {
	internal let model: ChromeModel

	internal var body: some View {
		VStack(spacing: 0) {
			HStack {
				BrowserHistoryControl(navigation: model.navigation, direction: .back, navigate: {}, select: { _ in })
				BrowserHistoryControl(navigation: model.navigation, direction: .forward, navigate: {}, select: { _ in })
				URLBar(url: model.url, isLoading: model.isLoading, onActivate: {}, onCopy: {})
			}
			OtherTab(model: model)
		}
		.frame(width: 900, height: 120)
		.background { BrowserChromeBackground(textured: true) }
	}
}

private struct OtherTab: View {
	internal let model: ChromeModel

	internal var body: some View {
		Text(model.otherTabTitle)
	}
}

// MARK: - Settings

@MainActor
@Observable
internal final class SettingsModel {
	internal nonisolated static let toggleCount: Int = 8

	internal var values: [Bool] = Array(repeating: false, count: toggleCount)
	internal var otherPaneValue: Int = 0
}

private struct SettingsHarness: View {
	internal let model: SettingsModel

	internal var body: some View {
		VStack {
			SettingsSection("General", footer: "Footer") {
				ForEach(0..<SettingsModel.toggleCount, id: \.self) { index in
					SettingsToggle(
						"Setting \(index)",
						detail: "Detail \(index)",
						isOn: Binding(get: { model.values[index] }, set: { model.values[index] = $0 })
					)
				}
			}
			OtherPane(model: model)
		}
		.frame(width: 620, height: 700)
	}
}

private struct OtherPane: View {
	internal let model: SettingsModel

	internal var body: some View {
		Text("\(model.otherPaneValue)")
	}
}

// MARK: - Host

/// A view laid out in a borderless window far off every screen.
@MainActor
private final class RenderHost {
	private let window: NSWindow
	private let host: NSHostingView<AnyView>

	internal init(@ViewBuilder _ content: () -> some View) {
		let size: CGSize = .init(width: 1_000, height: 900)
		host = NSHostingView(rootView: AnyView(content()))
		host.frame = CGRect(origin: .zero, size: size)
		window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		settle()
	}

	internal func recording(_ change: () -> Void) -> [String: Int] {
		RenderTrace.recording {
			change()
			settle()
		}
	}

	internal func close() {
		window.close()
	}

	private func settle() {
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.02))
		}
	}
}
#endif
