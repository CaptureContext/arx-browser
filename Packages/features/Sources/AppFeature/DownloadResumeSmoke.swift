#if DEBUG
import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import CryptoKit
import Foundation

/// DEV-892: pause a download, quit, relaunch and resume it. `Scripts/core/download_smoke.py`
/// launches the signed app twice after the main smoke, with `ARX_DOWNLOAD_RESUME_SMOKE` set to
/// `pause` and then `resume`, and checks that the second launch asked the server for a range.
@MainActor
internal enum DownloadResumeSmoke {
	internal struct Failure: LocalizedError {
		internal var errorDescription: String?

		internal init(_ message: String) {
			self.errorDescription = "Download resume smoke: " + message
		}
	}

	internal static func run(
		phase: String,
		engine: BrowserEngineClient,
		downloads: BrowserDownloadsClient,
		organization: BrowserOrganization,
		baseURL: URL,
		environment: [String: String]
	) async throws {
		guard
			baseURL.scheme == "http",
			baseURL.host == "127.0.0.1",
			let space = organization.spaces.first,
			let bytes = environment["ARX_DOWNLOAD_SMOKE_SLOW_BYTES"].flatMap(Int.init),
			let hash = environment["ARX_DOWNLOAD_SMOKE_SLOW_SHA256"]
		else { throw Failure("missing controlled fixture configuration") }

		step("configure")
		try await downloads.configure(organization)
		step("prepare-profile")

		// Profiles load on demand (DEV-880): the app loads one before opening its pages, and its
		// download history lives in it, so both launches load it first (DEV-965).
		try await engine.prepareProfile(space.profileID)
		step(phase)
		switch phase {
		case "pause":
			var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
			components.path = "/downloads/resumable"
			components.queryItems = [.init(name: "smoke", value: "resume")]
			let tab = Tab(
				id: .init(rawValue: UUID()),
				profileID: space.profileID,
				restoration: .init(title: "Download resume smoke", url: components.url!)
			)
			var organization = organization
			organization.tabs.append(tab)
			if let index = organization.spaces.index(id: space.id) {
				organization.spaces[index].unpinnedTabs.append(tab.id)
			}
			try await downloads.configure(organization)
			step("open")
			try await engine.open(tab)
			step("running")
			let running = try await wait(downloads) { $0.status == .inProgress && $0.receivedBytes > 0 && $0.canPause }
			try downloads.setPaused(running.id, true)
			_ = try await wait(downloads) { $0.isPaused }

			// Chromium writes its download history on its own database thread; give it a moment.
			try await Task.sleep(for: .seconds(2))
			engine.close(tab.id)
			print("ARX_DOWNLOAD_RESUME_SMOKE_PAUSED")

		case "resume":
			// Quitting interrupted the paused transfer; Chromium offers to resume it from disk.
			let interrupted = try await wait(downloads, seconds: 60) { $0.canResume }
			guard interrupted.receivedBytes > 0, interrupted.receivedBytes < bytes
			else { throw Failure("the relaunched download kept no partial bytes") }

			try downloads.setPaused(interrupted.id, false)
			let complete = try await wait(downloads, seconds: 60) { $0.status == .complete }
			guard
				complete.canOpen,
				let target = complete.target,
				let data = try? Data(contentsOf: target),
				data.count == bytes,
				SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash
			else { throw Failure("the resumed file doesn't match the fixture") }
			print("ARX_DOWNLOAD_RESUME_SMOKE_SUCCESS")

		default:
			throw Failure("unknown phase")
		}
	}

	/// Names the step this launch is on, so a launch that hangs says where (DEV-965).
	private static func step(_ name: String) {
		FileHandle.standardError.write(Data("ARX_DOWNLOAD_RESUME_STEP \(name)\n".utf8))
	}

	/// The fixture's resumable download, once `predicate` holds.
	private static func wait(
		_ downloads: BrowserDownloadsClient,
		seconds: Int = 30,
		until predicate: (BrowserDownload) -> Bool
	) async throws -> BrowserDownload {
		let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
		while ContinuousClock.now < deadline {
			let record = downloads.snapshot().downloads.first { $0.url?.path() == "/downloads/resumable" }
			if let record, predicate(record) { return record }
			try await Task.sleep(for: .milliseconds(100))
		}

		// Every download this launch sees, so a resume that never offers itself says why (DEV-966).
		let queue = downloads.snapshot()
		FileHandle.standardError.write(Data(
			"ARX_DOWNLOAD_RESUME_SEEN count=\(queue.downloads.count) private=\(queue.privateDownloads.count)\n".utf8
		))
		for download in queue.downloads {
			FileHandle.standardError.write(Data((describe(download) + "\n").utf8))
		}
		throw Failure("timed out waiting for the resumable download")
	}

	/// One download's state on one line, without its address or file name.
	internal static func describe(_ download: BrowserDownload) -> String {
		"ARX_DOWNLOAD_RESUME_SEEN path=\(download.url?.path() ?? "-") status=\(download.status.rawValue)"
			+ " reason=\(download.interruptReason) paused=\(download.isPaused) canResume=\(download.canResume)"
			+ " canPause=\(download.canPause) received=\(download.receivedBytes) total=\(download.totalBytes)"
			+ " dangerous=\(download.isDangerous) missing=\(download.isMissing)"
	}
}
#endif
