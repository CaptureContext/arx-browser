@testable import AppUI
import BrowserCore
import CoreGraphics
import Foundation
import Testing

/// DEV-753: the Library icon's spring states.
internal struct SidebarLibraryButtonTests {
	@Test
	internal func hoverLiftsAndTiltsTheIcon() {
		let motion = SidebarLibraryIconMotion(isHovered: true, isPressed: false, reducesMotion: false)
		#expect(motion.lift < 0)
		#expect(motion.tilt != 0)
		#expect(motion.scale == 1)
	}

	@Test
	internal func pressDipsTheIcon() {
		let motion = SidebarLibraryIconMotion(isHovered: true, isPressed: true, reducesMotion: false)
		#expect(motion.scale < 1)
		#expect(motion.lift == 0)
	}

	@Test(arguments: [(false, false), (true, false), (true, true)])
	internal func reduceMotionKeepsTheIconStill(
		isHovered: Bool,
		isPressed: Bool
	) {
		let motion = SidebarLibraryIconMotion(isHovered: isHovered, isPressed: isPressed, reducesMotion: true)
		#expect(motion == SidebarLibraryIconMotion(isHovered: false, isPressed: false, reducesMotion: false))
	}
}

/// DEV-758: the recent downloads the Library button fans out.
internal struct SidebarRecentDownloadsTests {
	private static let profile: Profile.ID = .init(rawValue: UUID())

	private static func download(
		_ name: String,
		minutesAgo: Double,
		status: BrowserDownload.Status = .complete,
		isMissing: Bool = false
	) -> BrowserDownload {
		.init(
			id: .init(profileID: profile, guid: name),
			profileName: "Work",
			target: URL(filePath: "/tmp/\(name)"),
			filename: name,
			status: status,
			startedAt: Date(timeIntervalSince1970: 10_000 - minutesAgo * 60),
			isMissing: isMissing
		)
	}

	@Test
	internal func onlyOpenableFilesShowNewestFirst() {
		let downloads = [
			Self.download("old.pdf", minutesAgo: 30),
			Self.download("new.png", minutesAgo: 2),
			Self.download("partial.zip", minutesAgo: 1, status: .inProgress),
			Self.download("moved.dmg", minutesAgo: 3, isMissing: true),
		]
		#expect(SidebarRecentDownloads.recent(downloads).map(\.filename) == ["new.png", "old.pdf"])
	}

	@Test
	internal func atMostFiveFanOut() {
		let downloads = (0..<8).map { Self.download("file-\($0).txt", minutesAgo: Double($0)) }
		#expect(SidebarRecentDownloads.recent(downloads).map(\.filename) == (0..<5).map { "file-\($0).txt" })
	}

	@Test
	internal func theRowsSitAboveTheButtonInLineWithIt() {
		let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
		let button = CGRect(x: 14, y: 10, width: 28, height: 28)
		let size = CGSize(width: 256, height: 200)
		let origin = SidebarHoverPanelPlacement.origin(of: size, above: button, within: screen, gap: 8)
		#expect(origin == .init(x: 14, y: button.maxY + 8))
		// Near the screen's top, it stays on screen.
		let high = CGRect(x: 14, y: 850, width: 28, height: 28)
		#expect(SidebarHoverPanelPlacement.origin(of: size, above: high, within: screen, gap: 8).y == CGFloat(900 - 8 - 200))
	}

	@Test
	internal func theAgeReadsAsMinutesAgo() {
		let now = Date(timeIntervalSince1970: 10_000)
		#expect(SidebarRecentDownloadRow.age(of: now.addingTimeInterval(-300), now: now) == "5 minutes ago")
	}
}
