import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// DEV-1289: the lists a highlight moves through, rendered live (real scroll views, not the static
/// demo drawing) with the highlight on the first row and then moved to the last, as the arrow keys
/// move it. With `ARX_DESIGN_SNAPSHOTS` naming a directory, writes one sheet per list in light and
/// dark: the command bar's results (twelve, one and two of them, the last in Page PiP's narrow
/// address field), ⌘K's actions, the Runway's profiles, a folder card's tabs and ⌃Tab's switcher.
/// The twelve results also show a row in the middle reached by the arrows, beside Actions ⌘K
/// (DEV-1318).
@MainActor
@Suite(.serialized, .renderTurn)
internal struct ListRuleSnapshotTests {
	@Test(
		.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil),
		arguments: [false, true]
	)
	internal func lists(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let appearance = dark ? "dark" : "light"

		try sheet(
			[
				try commandBar(dark: dark, results: Self.results(12), style: .palette, width: 573),
				try commandBar(dark: dark, results: Self.results(1), style: .palette, width: 573),
				try commandBar(dark: dark, results: Self.results(2), style: .urlField, width: 340),
			],
			dark: dark,
			to: directory.appending(path: "list-command-bar-\(appearance).png")
		)
		try sheet([try actions(dark: dark)], dark: dark, to: directory.appending(path: "list-actions-\(appearance).png"))
		try sheet([try runway(dark: dark)], dark: dark, to: directory.appending(path: "list-runway-\(appearance).png"))
		try sheet([try folder(dark: dark)], dark: dark, to: directory.appending(path: "list-folder-\(appearance).png"))
		try sheet([try tabSwitcher(dark: dark)], dark: dark, to: directory.appending(path: "list-tab-switcher-\(appearance).png"))
	}

	// MARK: - Lists

	/// The bar with the first result highlighted, then, in a list that scrolls, one in the middle
	/// the arrows reach beside Actions ⌘K, then the last.
	private func commandBar(
		dark: Bool,
		results: [CommandBarResult],
		style: CommandBarStyle,
		width: CGFloat
	) throws -> [NSBitmapImageRep] {
		var selected: String? = results.first?.id
		let host = LiveHost(dark: dark) {
			CommandBar(
				query: .constant("cap"),
				selectedID: Binding(get: { selected }, set: { selected = $0 }),
				results: results,
				style: style,
				onShowActions: {},
				maximumResultsHeight: style == .palette ? nil : 240,
				onSelect: { _ in },
				onDismiss: {}
			)
			.listScrolling(CommandBarListScrolling(pointerLocation: nil))
			.frame(width: width)
			.padding(24)
			.background(Color.gray.opacity(0.35))
		}
		let top = try host.capture()
		var captures = [top]
		if results.count > 7 {
			selected = results[6].id
			host.render()
			captures.append(try host.capture())
		}
		selected = results.last?.id
		host.render()
		return captures + [try host.capture()]
	}

	private func actions(dark: Bool) throws -> [NSBitmapImageRep] {
		let actions: [CommandBarActionItem] = [
			.init(id: "open", title: "Open", symbol: "arrow.up.right.square", shortcut: "↩"),
			.init(id: "peek", title: "Open in Peek", symbol: "eye", shortcut: "⇧↩"),
			.init(id: "little", title: "Open in Little Arx", symbol: "macwindow", shortcut: "⌥⌘↩"),
			.init(id: "split", title: "Open in Split View", symbol: "rectangle.split.2x1"),
			.init(id: "copy", title: "Copy URL", symbol: "link", shortcut: "⇧⌘C"),
			.init(id: "markdown", title: "Copy as Markdown", symbol: "text.quote"),
			.init(id: "pin", title: "Pin Tab", symbol: "pin"),
			.init(id: "close", title: "Close Tab", symbol: "xmark", shortcut: "⌃X", isDestructive: true),
		]
		var selected: String? = actions.first?.id
		let host = LiveHost(dark: dark) {
			CommandBarActionsPanel(
				.init(
					title: "CaptureContext",
					query: .constant(""),
					selectedID: Binding(get: { selected }, set: { selected = $0 }),
					actions: actions,
					onSelect: { _ in },
					onDismiss: {}
				),
				maximumHeight: 240
			)
			.padding(24)
			.background(Color.gray.opacity(0.35))
		}
		let top = try host.capture()
		selected = actions.last?.id
		host.render()
		return [top, try host.capture()]
	}

	private func runway(dark: Bool) throws -> [NSBitmapImageRep] {
		let options: [RunwayOption] = (1...9).map {
			RunwayOption(id: Profile.ID(rawValue: UUID(listRule: $0)), name: "Profile \($0)", spaceName: "Space \($0)")
		}
		var selected: Profile.ID? = options.first?.id
		let host = LiveHost(dark: dark) {
			RunwayFixture(options: options, selectedID: selected)
				.padding(24)
				.background(Color.gray.opacity(0.35))
		}
		let top = try host.capture()
		selected = options.last?.id
		host.render()
		return [top, try host.capture()]
	}

	private func folder(dark: Bool) throws -> [NSBitmapImageRep] {
		let ids: [UUID] = (1...14).map { UUID(listRule: $0) }
		let folder = SidebarItem(
			id: .folder(UUID(listRule: 100)),
			title: "Research",
			children: ids.prefix(8).map { .init(id: .tab($0), title: "Tab \($0.uuidString.suffix(2))", symbol: "doc.text") }
			+ [
				.init(id: .folder(UUID(listRule: 101)), title: "Papers", children: ids.dropFirst(8).map {
					.init(id: .tab($0), title: "Paper \($0.uuidString.suffix(2))", symbol: "book")
				}),
			]
		)
		let previews = SidebarHoverPreviews(tabs: { _ in
			Dictionary(uniqueKeysWithValues: ids.map {
				($0, SidebarTabPreview(title: "Tab", url: URL(string: "https://example.com/\($0.uuidString.suffix(2))")!))
			})
		})
		var selection: UUID? = ids.first
		let host = LiveHost(dark: dark) {
			SidebarFolderPreviewList(
				folder: folder,
				previews: previews,
				search: .init(selection: selection, isEngaged: true),
				send: { _ in }
			)
			.padding(24)
			.background(Color.gray.opacity(0.35))
		}
		let top = try host.capture()
		selection = ids.last
		host.render()
		return [top, try host.capture()]
	}

	/// ⌃Tab's switcher with more tabs than it shows: the first highlighted, then the last.
	private func tabSwitcher(dark: Bool) throws -> [NSBitmapImageRep] {
		let rows: [TabSwitcherRow] = (1...12).map {
			.init(id: UUID(listRule: 200 + $0), title: "Tab \($0)", spaceName: $0.isMultiple(of: 3) ? "Personal" : nil, siteIcon: nil)
		}
		var selected = 0
		let host = LiveHost(dark: dark) {
			TabSwitcherView(rows: rows, selectedIndex: selected)
				.padding(24)
				.background(Color.gray.opacity(0.35))
		}
		let top = try host.capture()
		selected = rows.count - 1
		host.render()
		return [top, try host.capture()]
	}

	// MARK: - Fixture

	private static func results(_ count: Int) -> [CommandBarResult] {
		(0..<count).map {
			.init(
				id: "r\($0)",
				title: "Result \($0 + 1)",
				subtitle: "https://example.com/\($0 + 1)",
				actionTitle: "Open URL",
				symbol: "globe"
			)
		}
	}

	/// Rows of renders, top state beside end state, on one sheet.
	private func sheet(
		_ rows: [[NSBitmapImageRep]],
		dark: Bool,
		to file: URL
	) throws {
		let gap: CGFloat = 16
		let width = rows.map { $0.reduce(0) { $0 + $1.size.width } + gap * CGFloat($0.count + 1) }.max() ?? 0
		let height = rows.reduce(gap) { $0 + ($1.map(\.size.height).max() ?? 0) + gap }
		let image = NSImage(size: .init(width: width, height: height))
		image.lockFocus()
		(dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
		NSRect(origin: .zero, size: image.size).fill()
		var y = height - gap
		for row in rows {
			let rowHeight = row.map(\.size.height).max() ?? 0
			var x = gap
			for rep in row {
				rep.draw(in: .init(x: x, y: y - rep.size.height, width: rep.size.width, height: rep.size.height))
				x += rep.size.width + gap
			}
			y -= rowHeight + gap
		}
		image.unlockFocus()
		let tiff = try #require(image.tiffRepresentation)
		let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
		try data.write(to: file)
	}
}

/// The Runway's compact list with its own query and focus.
private struct RunwayFixture: View {
	let options: [RunwayOption]
	let selectedID: Profile.ID?

	@FocusState
	private var isSearching: Bool

	var body: some View {
		RunwayView(
			appearance: .compact,
			url: URL(string: "https://capturecontext.dev")!,
			options: options,
			selectedID: selectedID,
			query: .constant(""),
			isSearching: $isSearching,
			onOpen: { _ in },
			onDrop: {}
		)
	}
}

/// A view hosted live in a window far off every screen, so its scroll views lay out and scroll as
/// they do on screen, then drawn into a bitmap.
@MainActor
private final class LiveHost {
	private let content: () -> AnyView
	private let host: NSHostingView<AnyView>
	private let window: NSWindow

	init(
		dark: Bool,
		@ViewBuilder _ content: @escaping () -> some View
	) {
		self.content = { AnyView(content()) }
		self.host = NSHostingView(rootView: AnyView(EmptyView()))
		self.window = NSWindow(
			contentRect: .init(x: -10_000, y: -10_000, width: 800, height: 800),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.appearance = window.appearance
		window.contentView = host
		render()
	}

	func render() {
		host.rootView = AnyView(content().fixedSize())
		settle()
		host.frame = .init(origin: .zero, size: host.fittingSize)
		window.setContentSize(host.frame.size)
		settle()
	}

	func capture() throws -> NSBitmapImageRep {
		settle()
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		return representation
	}

	private func settle() {
		for _ in 0..<8 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
	}

	isolated deinit {
		window.close()
	}
}

extension UUID {
	fileprivate init(listRule value: Int) {
		self.init(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
	}
}
