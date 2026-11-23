import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of onboarding's Sync with iCloud page when `ARX_DESIGN_SNAPSHOTS` names
/// a directory: before sync starts, while it runs, and once iCloud's Arx is here, in light and
/// dark, at the onboarding window's size.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct OnboardingICloudSnapshotTests {
	@Test(arguments: [false, true])
	internal func ready(dark: Bool) throws {
		try write(OnboardingICloudPage(status: .none), name: "icloud-ready", dark: dark)
	}

	@Test(arguments: [false, true])
	internal func syncing(dark: Bool) throws {
		try write(OnboardingICloudPage(status: .syncing(.history)), name: "icloud-syncing", dark: dark)
	}

	@Test(arguments: [false, true])
	internal func adopted(dark: Bool) throws {
		try write(OnboardingICloudPage(status: .adopted), name: "icloud-adopted", dark: dark)
	}

	/// The illustration alone, partway through syncing: a tab on its way to iCloud and the other
	/// Mac half filled in.
	@Test(arguments: [false, true])
	internal func illustrationMidSync(dark: Bool) throws {
		try write(
			OnboardingICloudIllustration(phase: .syncing, frozenElapsed: 1.0)
				.frame(width: 680, height: 250),
			name: "icloud-illustration-mid-sync",
			dark: dark
		)
	}

	private func write(
		_ content: some View,
		name: String,
		dark: Bool
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = content
			.frame(width: 760, height: 540)
			.background(Color(nsColor: .windowBackgroundColor))
		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: .init(width: 760, height: 540))
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
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
