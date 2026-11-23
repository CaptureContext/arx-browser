import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// DEV-1334: the search field's icon sits in a slot of fixed size, so the field starts at the same
/// x whatever icon the highlighted result gives it: the magnifier, a site's favicon, a bang's icon,
/// a command's symbol, or none.
@MainActor
@Suite(.renderTurn)
internal struct CommandBarFieldIconSlotTests {
	private static let profile: UUID = .init(uuidString: "00000000-0000-0000-0000-000000000001")!

	private static let kinds: [(name: String, result: CommandBarResult?)] = [
		("magnifier", .init(id: "search", title: "cap", subtitle: "Google", actionTitle: "Search", symbol: "magnifyingglass")),
		(
			"favicon",
			.init(
				id: "site",
				title: "CaptureContext",
				subtitle: "capturecontext.dev",
				actionTitle: "Open",
				symbol: "globe",
				siteIcon: .init(profileID: profile, pageURL: URL(string: "https://capturecontext.dev")!)
			)
		),
		(
			"bang",
			.init(
				id: "bang",
				title: "!yt",
				subtitle: "YouTube",
				actionTitle: "Search",
				symbol: "magnifyingglass",
				siteIcon: .init(profileID: profile, pageURL: URL(string: "https://www.youtube.com")!),
				siteIconFetch: .storedOnly
			)
		),
		("command", .init(id: "command", title: "Settings", subtitle: "Command", actionTitle: "Run", symbol: "gearshape.2")),
		("wide symbol", .init(id: "wide", title: "Split", subtitle: "Command", actionTitle: "Run", symbol: "rectangle.split.3x1")),
		("none", nil),
	]

	@Test(arguments: [CommandBarStyle.palette, .launcher, .urlField])
	internal func theFieldStartsAtOneXWhateverTheIcon(_ style: CommandBarStyle) throws {
		var edges: [String: CGFloat] = [:]
		for kind in Self.kinds {
			edges[kind.name] = try fieldLeadingEdge(style: style, result: kind.result)
		}
		let values = Set(edges.values.map { ($0 * 2).rounded() / 2 })
		#expect(values.count == 1, "\(edges)")
	}

	/// The bar with each kind of icon, one under another, when `ARX_DESIGN_SNAPSHOTS` names a
	/// directory; `ARX_SNAPSHOT_SUFFIX` tells a before from an after.
	@Test(arguments: [false, true])
	internal func snapshot(dark: Bool) throws {
		guard let path = ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] else { return }

		let suffix = ProcessInfo.processInfo.environment["ARX_SNAPSHOT_SUFFIX"] ?? "after"
		let view = VStack(alignment: .leading, spacing: 8) {
			ForEach(Array(Self.kinds.enumerated()), id: \.offset) { _, kind in
				CommandBar(
					query: .constant("cap"),
					selectedID: .constant(kind.result?.id),
					results: kind.result.map { [$0] } ?? [],
					style: .palette,
					onSelect: { _ in },
					onDismiss: {}
				)
				.frame(width: 573)
			}
		}
		.environment(\.commandBarIsStatic, true)
		.padding(24)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize()
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
		let name = "command-bar-field-icon-\(suffix)-\(dark ? "dark" : "light").png"
		try data.write(to: URL(fileURLWithPath: path).appending(path: name))
		window.close()
	}

	private func fieldLeadingEdge(
		style: CommandBarStyle,
		result: CommandBarResult?
	) throws -> CGFloat {
		let results = result.map { [$0] } ?? []
		let bar = CommandBar(
			query: .constant("cap"),
			selectedID: .constant(result?.id),
			results: results,
			style: style,
			onSelect: { _ in },
			onDismiss: {}
		)
		.frame(width: 573)
		let host = NSHostingView(rootView: bar)
		host.frame = .init(origin: .zero, size: .init(width: 573, height: 600))
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.03))
		}
		defer { window.close() }
		let field = try #require(Self.field(in: host))
		return field.convert(field.bounds, to: nil).minX
	}

	private static func field(in view: NSView) -> CommandInput.Field? {
		if let field = view as? CommandInput.Field { return field }
		for subview in view.subviews {
			if let field = field(in: subview) { return field }
		}
		return nil
	}
}
