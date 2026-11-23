import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumDownloadStartTests {
	@Test
	internal func startedReplyReturnsTheNativeGUID() async throws {
		let fixture = Fixture()
		defer { fixture.runtime.finish() }

		let task = Task { try await fixture.runtime.startDownload(profileKey: "", url: Fixture.url) }
		let request = await fixture.nextRequest()
		#expect(request.key == "")
		#expect(request.url == Fixture.url.absoluteString)

		fixture.runtime.completeDownloadStart(
			request.id,
			status: ARX_DOWNLOAD_START_STARTED,
			guid: "native-guid",
			interruptReason: 0
		)
		#expect(try await task.value == "native-guid")
	}

	@Test(arguments: [
		(ARX_DOWNLOAD_START_FAILED, Int32(20), ChromiumDownloadStartFailure.failed(interruptReason: 20)),
		(ARX_DOWNLOAD_START_TIMEOUT, Int32(0), ChromiumDownloadStartFailure.timedOut),
		(ARX_DOWNLOAD_START_UNAVAILABLE, Int32(0), ChromiumDownloadStartFailure.unavailable),
		// A STARTED reply without a GUID names no item.
		(ARX_DOWNLOAD_START_STARTED, Int32(0), ChromiumDownloadStartFailure.unavailable),
	])
	internal func failedRepliesThrow(
		status: ArxDownloadStartStatus,
		reason: Int32,
		failure: ChromiumDownloadStartFailure
	) async throws {
		let fixture = Fixture()
		defer { fixture.runtime.finish() }

		let task = Task { try await fixture.runtime.startDownload(profileKey: "profile", url: Fixture.url) }
		let request = await fixture.nextRequest()
		fixture.runtime.completeDownloadStart(request.id, status: status, guid: nil, interruptReason: reason)
		await #expect(throws: failure) { try await task.value }
	}

	@Test
	internal func refusedStartFailsWithoutAReply() async throws {
		let fixture = Fixture()
		defer { fixture.runtime.finish() }

		Fixture.accepts = false
		await #expect(throws: ChromiumDownloadStartFailure.unavailable) {
			try await fixture.runtime.startDownload(profileKey: "profile", url: Fixture.url)
		}
	}

	@Test(arguments: [
		"file:///tmp/a.txt",
		"https://user:secret@example.com/a.txt",
		"data:text/plain,hello",
	])
	internal func invalidURLsNeverReachNative(_ raw: String) async throws {
		let fixture = Fixture()
		defer { fixture.runtime.finish() }

		let url = try #require(URL(string: raw))
		await #expect(throws: ChromiumError.invalidURL) {
			try await fixture.runtime.startDownload(profileKey: "profile", url: url)
		}
		#expect(Fixture.pending.isEmpty)
	}

	@Test
	internal func missingBridgeAndStoppedRuntimeAreUnavailable() async throws {
		let fixture = Fixture(startDownload: false)
		#expect(!fixture.runtime.supportsStartingDownloads)
		await #expect(throws: ChromiumDownloadStartFailure.unavailable) {
			try await fixture.runtime.startDownload(profileKey: "profile", url: Fixture.url)
		}
		fixture.runtime.finish()

		let stopped = Fixture()
		stopped.runtime.finish()
		await #expect(throws: ChromiumDownloadStartFailure.unavailable) {
			try await stopped.runtime.startDownload(profileKey: "profile", url: Fixture.url)
		}
		#expect(Fixture.pending.isEmpty)
	}

	@Test
	internal func shutdownAnswersPendingStarts() async throws {
		let fixture = Fixture()
		let task = Task { try await fixture.runtime.startDownload(profileKey: "profile", url: Fixture.url) }
		_ = await fixture.nextRequest()
		fixture.runtime.finish()
		await #expect(throws: ChromiumDownloadStartFailure.unavailable) { try await task.value }
	}
}

@MainActor
private struct Fixture {
	fileprivate struct Request {
		fileprivate var id: UInt64
		fileprivate var key: String
		fileprivate var url: String
	}

	fileprivate static let url: URL = URL(string: "https://capturecontext.dev/file.zip")!
	fileprivate static var pending: [Request] = []
	fileprivate static var accepts: Bool = true
	fileprivate let runtime: ChromiumRuntime

	fileprivate init(startDownload: Bool = true) {
		Self.pending = []
		Self.accepts = true
		var api = ArxEngineAPI()
		if startDownload {
			api.start_download = { request, key, url in
				MainActor.assumeIsolated {
					guard Fixture.accepts, let key, let url else { return false }

					Fixture.pending.append(.init(id: request, key: String(cString: key), url: String(cString: url)))
					return true
				}
			}
		}
		self.runtime = .init(api: api)
		runtime.didBecomeReady()
	}

	fileprivate func nextRequest() async -> Request {
		while Self.pending.isEmpty { await Task.yield() }
		return Self.pending.removeFirst()
	}
}
