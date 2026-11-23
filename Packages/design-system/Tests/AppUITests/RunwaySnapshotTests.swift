import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// The Runway, the picker that asks which profile a link opens in (DEV-858), regular and
/// compact. With `ARX_DESIGN_SNAPSHOTS` naming a directory, writes every state of both in light
/// and dark, and the compact Runway over pages of the other brightness.
@MainActor
@Suite(.renderTurn)
internal struct RunwaySnapshotTests {
	nonisolated private static let url: URL = .init(string: "https://forums.swift.org/t/swift-6-4-released")!

	@Test(arguments: [RunwayAppearance.regular, .compact])
	internal func runwayTakesItsAppearancesWidth(appearance: RunwayAppearance) async throws {
		let size = NSHostingView(rootView: Host(appearance: appearance, state: .default)).fittingSize
		let metrics = BrowserMetrics.LittleArx.Runway.self

		// The host leaves room for the shadow on both sides.
		#expect(size.width - 2 * metrics.shadowInset == (appearance == .regular ? metrics.regularWidth : metrics.compactWidth))
	}

	/// Past six profiles the tile scrolls instead of growing.
	@Test(arguments: [RunwayAppearance.regular, .compact])
	internal func runwayStopsGrowingAtSixRows(appearance: RunwayAppearance) async throws {
		let six = NSHostingView(rootView: Host(appearance: appearance, state: .init(options: Array(Self.many.prefix(6))))).fittingSize
		let nine = NSHostingView(rootView: Host(appearance: appearance, state: .many)).fittingSize
		#expect(nine.height == six.height)
	}

	@Test(
		.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil),
		arguments: [RunwayAppearance.regular, .compact], [false, true]
	)
	internal func states(
		appearance: RunwayAppearance,
		dark: Bool
	) async throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let sheet = HStack(alignment: .top, spacing: 8) {
			ForEach(State.all, id: \.title) { state in
				VStack(alignment: .leading, spacing: 4) {
					Text(verbatim: state.title).font(.caption).foregroundStyle(.secondary)
					Host(appearance: appearance, state: state)
						.background(BrowserTheme.page.opacity(0.6))
				}
			}
		}
		.padding(16)
		.background(Color.gray.opacity(0.3))
		let name = "runway-\(appearance.rawValue)-\(dark ? "dark" : "light").png"
		try write(sheet, dark: dark, to: directory.appending(path: name))
	}

	/// The compact Runway has no panel, so it has to read over any page: light on dark, dark on
	/// light, and across an edge between the two.
	@Test(.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
	internal func compactOnContrastingPages() async throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let sheet = HStack(alignment: .top, spacing: 8) {
			Host(appearance: .compact, state: .default).background(Color.black).environment(\.colorScheme, .light)
			Host(appearance: .compact, state: .hover).background(Self.edge(left: .white, middle: .black)).environment(\.colorScheme, .light)
			Host(appearance: .compact, state: .default).background(Color.white).environment(\.colorScheme, .dark)
			Host(appearance: .compact, state: .hover).background(Self.edge(left: .black, middle: .white)).environment(\.colorScheme, .dark)
		}
		.padding(16)
		.background(Color.gray.opacity(0.3))
		try write(sheet, dark: false, to: directory.appending(path: "runway-compact-contrast.png"))
	}

	private static func edge(
		left: Color,
		middle: Color
	) -> some View {
		GeometryReader { proxy in
			ZStack(alignment: .leading) {
				left
				middle.frame(width: proxy.size.width * 0.36).offset(x: proxy.size.width * 0.38)
			}
		}
	}

	// MARK: - Fixtures

	nonisolated private static func id(_ index: Int) -> Profile.ID {
		.init(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!)
	}

	nonisolated private static let base: [RunwayOption] = [
		.init(id: id(1), name: "Personal", spaceName: "Today", spaceIcon: SpaceIcon.house.rawValue),
		.init(id: id(2), name: "Work", spaceName: "Inbox", spaceIcon: SpaceIcon.briefcase.rawValue),
		.init(id: id(3), name: "Side Project", spaceName: "Arx", spaceIcon: SpaceIcon.code.rawValue),
		.init(id: id(4), name: "School", spaceName: "Reading", spaceIcon: SpaceIcon.book.rawValue),
	]

	nonisolated private static let many: [RunwayOption] = base + [
		.init(id: id(5), name: "Family", spaceName: "Home", spaceIcon: SpaceIcon.heart.rawValue),
		.init(id: id(6), name: "Freelance", spaceName: "Clients"),
		.init(id: id(7), name: "Research", spaceName: "Papers"),
		.init(id: id(8), name: "Gaming", spaceName: "Guides", spaceIcon: SpaceIcon.game.rawValue),
		.init(id: id(9), name: "Garden", spaceName: "Plants", spaceIcon: SpaceIcon.leaf.rawValue),
	]

	/// A state of the Runway, as the Figma page draws it.
	fileprivate struct State {
		var title: String = "Default"
		var options: [RunwayOption] = RunwaySnapshotTests.base
		var selected: Int = 0
		var query: String = ""
		var rows: [Profile.ID: ArxControlStateOverride] = [:]

		static let `default`: Self = .init()
		static let hover: Self = .init(title: "Hover", rows: [id(2): .init(isHovered: true)])
		static let pressed: Self = .init(title: "Pressed", rows: [id(2): .init(isHovered: true, isPressed: true)])
		static let keyboard: Self = .init(title: "Keyboard", selected: 2)
		static let search: Self = .init(title: "Search", options: [base[1]], query: "wo")
		static let empty: Self = .init(title: "No matches", options: [], query: "zz")
		static let many: Self = .init(title: "Many profiles", options: RunwaySnapshotTests.many)
		static let long: Self = .init(
			title: "Long names",
			options: [
				base[0],
				.init(id: id(2), name: "Northwind Traders — Client Engagement Team", spaceName: "Quarterly planning and roadmap review"),
				base[2],
			],
			selected: 1
		)
		static let all: [Self] = [.default, .hover, .pressed, .keyboard, .search, .empty, .many, .long]
	}

	/// The Runway with its own focus, as its owner holds it, and room for its shadow.
	fileprivate struct Host: View {
		let appearance: RunwayAppearance
		let state: State

		@FocusState
		private var isSearching: Bool

		var body: some View {
			RunwayView(
				appearance: appearance,
				url: RunwaySnapshotTests.url,
				options: state.options,
				selectedID: state.options.indices.contains(state.selected) ? state.options[state.selected].id : nil,
				query: .constant(state.query),
				isSearching: $isSearching,
				onOpen: { _ in },
				onDrop: {}
			)
			.rowStates(state.rows)
			.padding(BrowserMetrics.LittleArx.Runway.shadowInset)
		}
	}

	private func write(
		_ view: some View,
		dark: Bool,
		to file: URL
	) throws {
		let host = NSHostingView(rootView: view.fixedSize())
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
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: file)
		window.close()
	}
}
