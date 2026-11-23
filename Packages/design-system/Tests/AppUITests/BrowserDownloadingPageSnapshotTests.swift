import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// DEV-1116: what the Downloading page says about each state of its transfer.
@MainActor
internal struct BrowserDownloadingPageTests {
	@Test
	internal func eachStateHasItsPhase() async throws {
		#expect(BrowserDownloadingPage(filename: "report.pdf", download: nil) { _ in }.phase == .preparing)
		#expect(phase { _ in } == .downloading)
		#expect(phase { $0.filename = ""; $0.receivedBytes = 0 } == .preparing)
		#expect(phase { $0.isPaused = true } == .paused)
		#expect(phase { $0.isDangerous = true } == .blocked)
		#expect(phase { $0.status = .complete } == .downloaded)
		#expect(phase { $0.status = .complete; $0.isMissing = true } == .missing)
		#expect(phase { $0.status = .cancelled } == .cancelled)
		#expect(phase { $0.status = .interrupted } == .failed)
		#expect(phase { $0.status = .interrupted; $0.canResume = true } == .resumable)
		let removed = BrowserDownloadingPage(
			filename: "report.pdf",
			download: BrowserDownloadingPageFixtures.record(),
			isRemoved: true
		) { _ in }
		#expect(removed.phase == .removed)
	}

	@Test
	internal func progressNamesTheBytes() async throws {
		let page = BrowserDownloadingPage(filename: "report.pdf", download: BrowserDownloadingPageFixtures.record()) { _ in }
		let received = ByteCountFormatter.string(fromByteCount: 512_000, countStyle: .file)
		let total = ByteCountFormatter.string(fromByteCount: 2_048_000, countStyle: .file)
		#expect(page.status.contains(received))
		#expect(page.status.contains(total))
	}

	private func phase(_ change: (inout BrowserDownload) -> Void) -> BrowserDownloadingPage.Phase {
		var record = BrowserDownloadingPageFixtures.record()
		change(&record)
		return BrowserDownloadingPage(filename: "report.pdf", download: record) { _ in }.phase
	}
}

/// Writes offscreen PNGs of the Downloading page (DEV-1116) in progress, finished and cancelled,
/// light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct BrowserDownloadingPageSnapshotTests {
	@Test(arguments: [false, true])
	internal func downloadingPage(dark: Bool) throws {
		var finished = BrowserDownloadingPageFixtures.record()
		finished.status = .complete
		finished.receivedBytes = finished.totalBytes
		var cancelled = BrowserDownloadingPageFixtures.record()
		cancelled.status = .cancelled

		let view = VStack(spacing: 16) {
			page(BrowserDownloadingPageFixtures.record())
			page(finished)
			page(cancelled)
		}
		.padding(16)
		.background { BrowserChromeBackground(textured: true) }
		.fixedSize()

		try write(view, dark: dark, name: "downloading-page-\(dark ? "dark" : "light").png")
	}

	private func page(_ record: BrowserDownload) -> some View {
		ZStack {
			BrowserTheme.page
			BrowserDownloadingPage(filename: record.filename, download: record) { _ in }
		}
		.frame(width: 560, height: 340)
		.browserPageCard()
	}

	private func write(
		_ view: some View,
		dark: Bool,
		name: String
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
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: name))
		window.close()
	}
}

private enum BrowserDownloadingPageFixtures {
	static func record() -> BrowserDownload {
		.init(
			id: .init(profileID: .init(rawValue: UUID()), guid: "transfer"),
			profileName: "Personal",
			url: URL(string: "https://files.capturecontext.dev/Quarterly%20report.pdf"),
			filename: "Quarterly report.pdf",
			status: .inProgress,
			receivedBytes: 512_000,
			totalBytes: 2_048_000,
			startedAt: Date(timeIntervalSince1970: 1_000)
		)
	}
}
