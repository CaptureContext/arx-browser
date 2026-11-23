import AppKit
import AppUI
import BrowserCore
import DownloadsFeature
import Foundation
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

/// Writes offscreen PNGs of the Downloads panel's header (DEV-770): no filter, two profile
/// filters, the filter pane open, and two filters in a narrow panel, light and dark, when
/// `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(.dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct DownloadsHeaderSnapshotTests {
	private let profiles: IdentifiedArrayOf<Profile> = [
		.init(id: .init(rawValue: UUID()), name: "maximkrouk"),
		.init(id: .init(rawValue: UUID()), name: "Work"),
		.init(id: .init(rawValue: UUID()), name: "Home"),
		.init(id: .init(rawValue: UUID()), name: "pointfree"),
	]

	@Test(arguments: [false, true])
	internal func header(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let picked: Set<Profile.ID> = [profiles[1].id, profiles[3].id]
		let view = HStack(alignment: .top, spacing: 16) {
			panel(width: 320, profileFilter: [], isPaneOpen: false)
			panel(width: 320, profileFilter: picked, isPaneOpen: false)
			panel(width: 320, profileFilter: picked, isPaneOpen: true)
			panel(width: 230, profileFilter: Set(profiles.ids), isPaneOpen: false)
		}
		.padding(16)
		.background { BrowserChromeBackground(textured: true) }
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
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "downloads-header-\(dark ? "dark" : "light").png"))
		window.close()
	}

	private func panel(
		width: CGFloat,
		profileFilter: Set<Profile.ID>,
		isPaneOpen: Bool
	) -> some View {
		let download = BrowserDownload(
			id: .init(profileID: profiles[1].id, guid: "report"),
			profileName: "Work",
			filename: "report.pdf",
			status: .cancelled,
			startedAt: Date(timeIntervalSince1970: 100)
		)
		let state = DownloadsFeature.State(
			profileID: profiles[0].id,
			queue: .init(downloads: [download]),
			filter: profileFilter.isEmpty ? .currentProfile : .allProfiles,
			profileFilter: profileFilter,
			isFilterPanePresented: isPaneOpen
		)
		let store: StoreOf<DownloadsFeature> = .init(initialState: state) { EmptyReducer() }
		return DownloadsPanelView(store: store, profiles: profiles)
			.padding(.top, BrowserMetrics.Library.headerInset)
			.frame(width: width, height: 330, alignment: .top)
			.background(BrowserTheme.sidebar)
			.clipShape(.rect(cornerRadius: 10, style: .continuous))
	}
}
