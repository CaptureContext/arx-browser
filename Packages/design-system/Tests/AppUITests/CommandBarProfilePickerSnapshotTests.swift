import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of Little Arx's launcher with its profile picker (DEV-1331): before (no
/// picker), the picker beside Actions ⌘K, its list open, ⌘K's actions open, and an empty bar, light
/// and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct CommandBarProfilePickerSnapshotTests {
	private let results: [CommandBarResult] = [
		.init(id: "a", title: "CloudKit - Records", subtitle: "icloud.developer.apple.com/dashboard", actionTitle: "Open URL", symbol: "clock.arrow.circlepath"),
		.init(id: "b", title: "Arx Manual", subtitle: "manual.arx.capturecontext.dev", actionTitle: "Open URL", symbol: "clock.arrow.circlepath"),
		.init(id: "c", title: "CaptureContext", subtitle: "capturecontext.dev", actionTitle: "Open URL", symbol: "globe"),
		.init(id: "d", title: "Linear", subtitle: "linear.app", actionTitle: "Open URL", symbol: "star"),
		.init(id: "e", title: "GitHub", subtitle: "github.com", actionTitle: "Open URL", symbol: "star"),
	]

	private let profiles: [CommandBarActionItem] = [
		.init(id: "personal", title: "Personal", symbol: "checkmark"),
		.init(id: "work", title: "Work", symbol: "person.crop.circle"),
		.init(id: "school", title: "School", symbol: "person.crop.circle"),
	]

	private let actions: [CommandBarActionItem] = [
		.init(id: "primary", title: "Open", symbol: "arrow.up.right", shortcut: "↩"),
		.init(id: "copy", title: "Copy URL", symbol: "link", shortcut: "⇧⌘C"),
	]

	private enum Picker {
		case none
		case closed
		case open
	}

	@Test(arguments: [false, true])
	internal func launcher(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = VStack(alignment: .leading, spacing: 24) {
			bar(results: results, picker: .none)
			bar(results: results, picker: .closed)
			bar(results: results, picker: .open)
			bar(results: results, picker: .closed, actionsOpen: true)
			bar(results: [], picker: .closed)
		}
		.environment(\.commandBarIsStatic, true)
		.padding(32)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()

		try write(view, dark: dark, to: directory.appending(path: "little-arx-profile-picker-\(dark ? "dark" : "light").png"))
	}

	private func bar(
		results: [CommandBarResult],
		picker: Picker,
		actionsOpen: Bool = false
	) -> some View {
		CommandBar(
			query: .constant(""),
			selectedID: .constant(results.first?.id),
			results: results,
			style: .launcher,
			onShowActions: {},
			actionsPanel: actionsOpen ? content(title: "CloudKit - Records", selected: "primary", items: actions) : nil,
			profilePicker: profilePicker(picker),
			onClose: {},
			onSelect: { _ in },
			onDismiss: {}
		)
		.frame(width: BrowserMetrics.LittleArx.Launcher.width)
	}

	private func profilePicker(_ picker: Picker) -> CommandBarProfilePickerContent? {
		switch picker {
		case .none: nil
		case .closed: .init(title: "Personal", key: "⌘I", onToggle: {})
		case .open:
			.init(
				title: "Personal",
				key: "⌘I",
				onToggle: {},
				panel: content(title: "Personal", selected: "work", items: profiles, placeholder: "Search profiles…")
			)
		}
	}

	private func content(
		title: String,
		selected: String?,
		items: [CommandBarActionItem],
		placeholder: String? = nil
	) -> CommandBarActionsContent {
		.init(
			title: title,
			query: .constant(""),
			selectedID: .constant(selected),
			actions: items,
			onSelect: { _ in },
			onDismiss: {},
			searchPlaceholder: placeholder
		)
	}

	private func write(
		_ view: some View,
		dark: Bool,
		to url: URL
	) throws {
		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = host.appearance
		window.contentView = host
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: url)
		window.close()
	}
}

@Suite
internal struct CommandBarFloatingButtonTests {
	@Test
	internal func shortensLongTitles() {
		#expect(CommandBarFloatingButton.shortened("Personal") == "Personal")
		let long = String(repeating: "Work ", count: 10)
		let shortened = CommandBarFloatingButton.shortened(long)
		#expect(shortened.count <= CommandBarFloatingButton.titleLimit)
		#expect(shortened.hasSuffix("…"))
	}
}
