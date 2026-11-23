import Foundation
import Testing

@testable import BrowserCore

/// DEV-966: a quit loses private transfers still in progress, paused ones too; ordinary ones and
/// finished private ones aren't counted.
internal struct DownloadQuitTests {
	@Test
	internal func privateTransfersInProgressAreLostOnQuit() {
		let profile = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
		func download(
			_ guid: String,
			status: BrowserDownload.Status,
			isPrivate: Bool,
			isPaused: Bool = false
		) -> BrowserDownload {
			.init(
				id: .init(profileID: profile, guid: guid),
				profileName: "Personal",
				filename: "\(guid).zip",
				status: status,
				startedAt: Date(timeIntervalSince1970: 100),
				isPrivate: isPrivate,
				isPaused: isPaused
			)
		}
		let queue = DownloadQueue(
			downloads: [download("ordinary", status: .inProgress, isPrivate: false)],
			privateDownloads: [
				download("running", status: .inProgress, isPrivate: true),
				download("paused", status: .inProgress, isPrivate: true, isPaused: true),
				download("done", status: .complete, isPrivate: true),
			]
		)
		#expect(queue.activeCount == 3)
		#expect(queue.lostOnQuitCount == 2)
	}
}
