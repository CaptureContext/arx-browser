import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes PNGs of the header bar (DEV-782, DEV-790, DEV-797) for visual self-review,
/// when `ARX_DESIGN_SNAPSHOTS` names a directory: Close and Back squircles, with and without a
/// subtitle and text controls, a pane's bar with its icon tile, its search collapsed, expanded and
/// holding a query, a narrow bar whose title truncates before its controls, a modal scrolled
/// under the bar, and a bar over a translucent surface at rest and scrolled (DEV-806).
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct ArxHeaderBarSnapshotTests {
	private enum State: String, CaseIterable {
		case normal
		case hover
		case pressed
		case disabled
		case focused
		case selected

		internal var override: ArxControlStateOverride {
			switch self {
			case .normal, .disabled, .selected: .init()
			case .hover: .init(isHovered: true)
			case .pressed: .init(isPressed: true)
			case .focused: .init(isFocused: true)
			}
		}
	}

	@Test(arguments: [false, true])
	internal func headerBars(dark: Bool) throws {
		let view = VStack(alignment: .leading, spacing: 12) {
			ArxHeaderBar(.close {}, title: "Local assistants (MCP)", subtitle: "Advanced")
				.frame(width: 520)
				.background(ArxModalMetrics.background)

			ArxHeaderBar(.back {}, title: "AI Commands", subtitle: "Assistant")
				.frame(width: 520)
				.background(ArxModalMetrics.background)

			ArxHeaderBar(.close {}, title: "Extensions", subtitle: "Personal") {
				Button("Install Package…") {}
					.buttonStyle(.arxRaised(.capsule))
				Button("Refresh") {}
					.buttonStyle(.arxRaised(.capsule))
				ArxHeaderSearch("Search", query: .constant(""))
			}
			.frame(width: 520)
			.background(ArxModalMetrics.background)

			// The Extensions sheet's bar at its own width (DEV-872): its actions as icons, so the
			// title and profile never truncate, then with Refresh hovered and its tooltip showing.
			ArxHeaderBar(.close {}, title: "Extensions", subtitle: "Work") {
				ArxIconActionGroup(Self.extensionActions)
			}
			.frame(width: 760)
			.background(ArxModalMetrics.background)

			ArxHeaderBar(.close {}, title: "Extensions", subtitle: "Work") {
				ArxIconActionGroup(Self.extensionActions, tooltip: "arrow.clockwise")
			}
			.frame(width: 760)
			.background(ArxModalMetrics.background)
			.padding(.bottom, 30)
			.zIndex(1)

			ArxHeaderBar(.close {}, title: "Search Shortcuts", subtitle: "General") {
				ArxHeaderSearch("Search built-in bangs", query: .constant(""), isExpanded: true)
			}
			.frame(width: 520)
			.background(ArxModalMetrics.background)

			ArxHeaderBar(.close {}, title: "Search Shortcuts", subtitle: "General") {
				ArxHeaderSearch("Search built-in bangs", query: .constant("youtube"))
			}
			.frame(width: 520)
			.background(ArxModalMetrics.background)

			// A pane's own bar: no leading button, its icon tile, title and description.
			ArxHeaderBar(
				.none,
				icon: ArxHeaderBarIcon(systemImage: "command", tint: .gray),
				title: "Shortcuts",
				subtitle: "Keyboard shortcuts for commands.",
				height: 52
			) {
				ArxHeaderSearch("Search shortcuts", query: .constant(""))
			}
			.frame(width: 680)
			.background(ArxModalMetrics.background)

			ArxHeaderBar(
				.none,
				icon: ArxHeaderBarIcon(systemImage: "command", tint: .gray),
				title: "Shortcuts",
				subtitle: "Keyboard shortcuts for commands.",
				height: 52
			) {
				ArxHeaderSearch("Search shortcuts", query: .constant("tab"))
			}
			.frame(width: 680)
			.background(ArxModalMetrics.background)

			// Too narrow for everything: the title truncates, the controls keep their size.
			ArxHeaderBar(.close {}, title: "A Very Long Modal Title That Cannot Fit", subtitle: "Profiles › Work") {
				Button("Import") {}
					.buttonStyle(.arxRaised(.capsule))
				ArxHeaderSearch("Search passwords", query: .constant("git"), width: 160)
			}
			.frame(width: 380)
			.background(ArxModalMetrics.background)

		}
		.padding(20)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()
		try write(view, name: "arx-header-bars", dark: dark)
	}

	/// Every raised control in every state, at a header bar's height (DEV-797): the squircle icon
	/// button, a text control, a grouped pair, the segmented control and the search button.
	@Test(arguments: [false, true])
	internal func raisedControls(dark: Bool) throws {
		let view = VStack(alignment: .leading, spacing: 12) {
			ForEach(State.allCases, id: \.self) { state in
				HStack(spacing: 8) {
					Text(state.rawValue)
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.frame(width: 60, alignment: .leading)
					Button {} label: { Image(systemName: "xmark").font(.system(size: 14, weight: .medium)) }
						.buttonStyle(.arxRaised(.square, isSelected: state == .selected))
					Button {} label: { Image(systemName: "chevron.left").font(.system(size: 14, weight: .medium)) }
						.buttonStyle(.arxRaised(.square, isSelected: state == .selected))
					Button("Refresh") {}
						.buttonStyle(.arxRaised(.capsule, isSelected: state == .selected))
					ArxRaisedGroup {
						Button {} label: { Image(systemName: "ellipsis") }
							.buttonStyle(.arxRaised(.item, isSelected: state == .selected, isSquare: true))
						Button {} label: { Image(systemName: "xmark") }
							.buttonStyle(.arxRaised(.item, isSquare: true))
					}
					ArxSegmentedControl(Self.segments, selection: state == .selected ? 2 : 0) { _ in }
					ArxHeaderSearch("Search", query: .constant(""))

					// The chat composer's + at its own size (DEV-798, DEV-806).
					Button {} label: { Image(systemName: "plus") }
						.buttonStyle(.arxRaised(size: .regular, isSelected: state == .selected))
				}
				.disabled(state == .disabled)
				.arxControlState(state.override)
			}

			// A hovered segment's tooltip hangs under it.
			ArxSegmentedControl(Self.segments, selection: 0, tooltip: 1) { _ in }
				.padding(.bottom, 30)

			// The expanded search field, empty and with a query.
			HStack(spacing: 8) {
				ArxHeaderSearch("Search", query: .constant(""), width: 220, isExpanded: true)
				ArxHeaderSearch("Search", query: .constant("tab"), width: 220)
			}
		}
		.controlSize(.regular)
		.arxRaisedControlHeight(ArxHeaderBarMetrics.controlHeight)
		.padding(20)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()
		try write(view, name: "arx-raised-controls", dark: dark)
	}

	/// The chat panel's controls at its own size: the chats list switcher with a tooltip.
	@Test(arguments: [false, true])
	internal func panelControls(dark: Bool) throws {
		let view = HStack(spacing: 8) {
			Button {} label: { Image(systemName: "chevron.left") }
				.buttonStyle(.arxRaised(.square))
			Button {} label: { Image(systemName: "plus").fontWeight(.medium) }
				.buttonStyle(.arxRaised(.square))
			Text(verbatim: "Chats")
				.font(.system(size: 15, weight: .bold))
			Spacer(minLength: 0)
			ArxSegmentedControl(Self.segments, selection: 0, tooltip: 2) { _ in }
		}
		.controlSize(.large)
		.padding(12)
		.padding(.bottom, 30)
		.frame(width: 380)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()
		try write(view, name: "arx-panel-controls", dark: dark)
	}

	/// Text segments (DEV-1308), as Send Feedback's kinds: the selection kept filled, and a tooltip
	/// only on the segment with a hint, shown here.
	@Test(arguments: [false, true])
	internal func textSegments(dark: Bool) throws {
		let segments: [ArxSegment<Int>] = [
			ArxSegment(0, title: "Bug Report"),
			ArxSegment(1, title: "Feature Request"),
			ArxSegment(2, title: "Vulnerability", hint: "Marked urgent and kept private until fixed"),
			ArxSegment(3, title: "Other"),
		]
		let view = VStack(alignment: .leading, spacing: 16) {
			ArxSegmentedControl(segments, selection: 0) { _ in }
			ArxSegmentedControl(segments, selection: 2, tooltip: 2) { _ in }
		}
		.padding(24)
		.padding(.bottom, 40)
		.frame(width: 480, alignment: .leading)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()
		try write(view, name: "arx-text-segments", dark: dark)
	}

	private static let extensionActions: [ArxIconAction] = [
		ArxIconAction("Load Unpacked…", systemImage: "folder.badge.plus") {},
		ArxIconAction("Chrome Web Store", systemImage: "bag") {},
		ArxIconAction("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {},
		ArxIconAction("Install Package…", systemImage: "shippingbox", isEnabled: false) {},
		ArxIconAction("Refresh", systemImage: "arrow.clockwise") {},
	]

	private static let segments: [ArxSegment<Int>] = [
		ArxSegment(0, title: "All", systemImage: "tray"),
		ArxSegment(1, title: "Unread", systemImage: "envelope.badge"),
		ArxSegment(2, title: "Archived", systemImage: "archivebox"),
	]

	/// A modal scrolled under its bar: content runs edge to edge beneath it, under the system's
	/// soft edge, which offscreen drawing leaves out (DEV-807).
	@Test(arguments: [false, true], [false, true])
	internal func modalScaffold(
		scrolled: Bool,
		dark: Bool
	) throws {
		let view = ArxModalScaffold {
			ArxHeaderBar(.close {}, title: "Search Shortcuts", subtitle: "General") {
				ArxHeaderSearch("Search built-in bangs", query: .constant(""))
			}
		} content: {
			VStack(alignment: .leading, spacing: 10) {
				ForEach(0..<30) { index in
					Text(verbatim: "Row \(index + 1): a line of text that scrolls under the bar")
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(10)
						.background(.primary.opacity(0.05), in: ArxControlShape())
				}
			}
		}
		.frame(width: 480, height: 360)
		try write(view, name: "arx-modal-scaffold\(scrolled ? "-scrolled" : "")", dark: dark, scrollBy: scrolled ? 80 : nil)
	}

	/// A bar over a translucent surface, as the chat panel's and the Library's (DEV-806): with no
	/// background of its own, content runs under it to whatever lies behind (DEV-807).
	@Test(arguments: [false, true], [false, true])
	internal func translucentScrollBar(
		scrolled: Bool,
		dark: Bool
	) throws {
		let view = ScrollView {
			VStack(alignment: .leading, spacing: 8) {
				ForEach(0..<30) { index in
					Text(verbatim: "Chat \(index + 1): the latest answer, under the bar")
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(10)
						.background { ArxRaisedTile(cornerRadius: 12) }
				}
			}
			.padding(.horizontal, 12)
		}
		.arxScrollBar(background: nil) {
			HStack(spacing: 8) {
				Button {} label: { Image(systemName: "chevron.left") }
					.buttonStyle(.arxRaised(.square))
				Text(verbatim: "Chats")
					.font(.system(size: 15, weight: .bold))
				Spacer(minLength: 0)
				ArxSegmentedControl(Self.segments, selection: 0) { _ in }
			}
			.controlSize(.large)
			.padding(12)
		}
		.background(
			LinearGradient(
				colors: [.purple.opacity(0.35), .orange.opacity(0.35)],
				startPoint: .top,
				endPoint: .bottom
			)
		)
		.frame(width: 380, height: 320)
		try write(view, name: "arx-translucent-bar\(scrolled ? "-scrolled" : "")", dark: dark, scrollBy: scrolled ? 60 : nil)
	}

	private func write(
		_ view: some View,
		name: String,
		dark: Bool,
		scrollBy offset: CGFloat? = nil
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
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
		if let offset, let scrollView = Self.scrollViews(in: host).first {
			scrollView.contentView.scroll(to: .init(x: 0, y: offset))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			for _ in 0..<6 {
				host.layoutSubtreeIfNeeded()
				RunLoop.main.run(until: .now.addingTimeInterval(0.05))
			}
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}

	private static func scrollViews(in view: NSView) -> [NSScrollView] {
		(view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollViews(in: $0) }
	}
}
