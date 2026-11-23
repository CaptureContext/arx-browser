import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Writes offscreen PNGs of the site permission prompts (DEV-963): notifications, camera and
/// microphone, location with Allow Once and its accuracy, an upgrade to precise location, and
/// clipboard from an embedded frame,
/// one by one and side by side, in light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct PagePromptSnapshotTests {
	private struct Prompt {
		var name: String
		var site: String
		var embedder: String?
		var permissions: [SitePermission]
		var offersAllowOnce: Bool = false
		var accuracies: [PagePermissionPromptCard<SiteTile>.Accuracy] = []
		var tile: SiteTile
	}

	private static let prompts: [Prompt] = [
		.init(
			name: "notifications",
			site: "github.com",
			permissions: [.notifications],
			tile: .init(letter: "G", color: .init(red: 0.14, green: 0.16, blue: 0.18))
		),
		.init(
			name: "camera-microphone",
			site: "meet.example.com",
			permissions: [.camera, .microphone],
			offersAllowOnce: true,
			tile: .init(letter: "M", color: .init(red: 0.0, green: 0.53, blue: 0.4))
		),
		.init(
			name: "location",
			site: "maps.example.com",
			permissions: [.location],
			offersAllowOnce: true,
			accuracies: [.approximate, .precise],
			tile: .init(letter: "M", color: .init(red: 0.85, green: 0.3, blue: 0.2))
		),
		.init(
			name: "location-precise",
			site: "maps.example.com",
			permissions: [.location],
			accuracies: [.precise],
			tile: .init(letter: "M", color: .init(red: 0.85, green: 0.3, blue: 0.2))
		),
		.init(
			name: "clipboard",
			site: "docs.example.com",
			embedder: "notes.example.org",
			permissions: [.clipboard],
			tile: .init(letter: "D", color: .init(red: 0.2, green: 0.4, blue: 0.9))
		),
	]

	@Test(arguments: [false, true])
	internal func prompts(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let appearance = dark ? "dark" : "light"
		for prompt in Self.prompts {
			try write(
				Self.card(prompt).padding(16).background(Color.gray.opacity(0.3)),
				dark: dark,
				to: directory.appending(path: "page-prompt-\(prompt.name)-\(appearance).png")
			)
		}
		let family = HStack(alignment: .top, spacing: 16) {
			ForEach(Self.prompts, id: \.name) { prompt in
				Self.card(prompt)
			}
		}
		.padding(16)
		.background(Color.gray.opacity(0.3))
		try write(family, dark: dark, to: directory.appending(path: "page-prompts-\(appearance).png"))
	}

	private static func card(_ prompt: Prompt) -> some View {
		PagePermissionPromptCard(
			site: prompt.site,
			embedder: prompt.embedder,
			permissions: prompt.permissions,
			offersAllowOnce: prompt.offersAllowOnce,
			accuracies: prompt.accuracies,
			accuracy: .constant(.approximate),
			isArmed: true,
			icon: { prompt.tile },
			onCancel: {},
			onBlock: {},
			onAllowOnce: {},
			onAllow: {}
		)
		.background(ArxModalMetrics.background)
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

/// A site's letter tile, standing in for its favicon.
private struct SiteTile: View {
	var letter: String
	var color: Color

	var body: some View {
		color.overlay {
			Text(letter)
				.font(.system(size: 28, weight: .bold, design: .rounded))
				.foregroundStyle(.white)
		}
	}
}
