#if DEBUG
import CustomDump
import Foundation
import Testing

@testable import AppFeature

@Suite(.dependencies)
internal struct MediaSmokeTests {
	@Test
	internal func parsesOnlyBoundedOrdinaryFixtureState() async throws {
		let state = try MediaSmokePageState(title: title())
		#expect(state.fixtureCase == "normal" && state.playing && state.requests == 1)

		for invalid in [
			"Arx media loading",
			title(fixtureCase: "private"),
			title(count: -1),
			title(count: 101),
			String(repeating: "x", count: 2049),
		] {
			#expect(throws: (any Error).self) { try MediaSmokePageState(title: invalid) }
		}
	}

	/// DEV-1177: what a timeout needs from the page, bounded, and absent from older titles.
	@Test
	internal func readsThePageAndVideoStatesForATimeout() async throws {
		let waiting = try MediaSmokePageState(
			title: title(ready: false, playing: false, starts: 0, trustedStarts: 0, diagnostics: (visibility: "hidden", videoReady: 0, network: 2, reports: 97))
		)
		#expect(waiting.visibility == "hidden")
		#expect(waiting.videoReady == 0)
		#expect(waiting.network == 2)
		#expect(waiting.reports == 97)

		let older = try MediaSmokePageState(title: title())
		#expect(older.visibility == nil && older.videoReady == nil && older.network == nil && older.reports == nil)

		for invalid in [
			(visibility: "prerender", videoReady: 0, network: 0, reports: 0),
			(visibility: "visible", videoReady: 5, network: 0, reports: 0),
			(visibility: "visible", videoReady: 0, network: 4, reports: 0),
			(visibility: "visible", videoReady: 0, network: 0, reports: -1),
		] {
			#expect(throws: (any Error).self) { try MediaSmokePageState(title: title(diagnostics: invalid)) }
		}
	}

	@Test
	internal func requiresExactlyOneTrustedStartBeforePlayback() async throws {
		let waiting = try MediaSmokePageState(title: title(playing: false, starts: 0, trustedStarts: 0))
		#expect(waiting.ready && !waiting.playing && waiting.starts == 0)

		for invalid in [
			title(starts: 0, trustedStarts: 0),
			title(ready: false),
			title(starts: 2, trustedStarts: 2),
			title(starts: 1, trustedStarts: 0),
			title(starts: -1, trustedStarts: -1),
		] {
			#expect(throws: (any Error).self) { try MediaSmokePageState(title: invalid) }
		}
	}

	@Test
	internal func inputRequiresExactFixtureURLAndBoundedButtonGeometry() async throws {
		let url = URL(string: "http://127.0.0.1:12345/media/normal.html")!
		let bounds = CGRect(x: 0, y: 0, width: 640, height: 420)
		let flippedPoint = try MediaSmokeInput.startPoint(
			currentURL: url,
			expectedURL: url,
			bounds: bounds,
			isFlipped: true
		)
		let unflippedPoint = try MediaSmokeInput.startPoint(
			currentURL: url,
			expectedURL: url,
			bounds: bounds,
			isFlipped: false
		)
		expectNoDifference(flippedPoint, CGPoint(x: 116, y: 308))
		expectNoDifference(unflippedPoint, CGPoint(x: 116, y: 112))

		for current in [
			nil,
			URL(string: "http://127.0.0.1:12345/media/second.html"),
			URL(string: "http://127.0.0.1:12346/media/normal.html"),
		] {
			#expect(throws: MediaSmokeFailure.self) {
				try MediaSmokeInput.startPoint(
					currentURL: current,
					expectedURL: url,
					bounds: bounds,
					isFlipped: false
				)
			}
		}

		for value in [
			"https://127.0.0.1:12345/media/normal.html",
			"http://localhost:12345/media/normal.html",
			"http://127.0.0.1:12345/media/normal.html?query=1",
			"http://127.0.0.1:12345/media/normal.html#start",
			"http://user@127.0.0.1:12345/media/normal.html",
			"http://127.0.0.1:12345/nested/media/normal.html",
			"http://127.0.0.1:12345/media/unknown.html",
			"http://127.0.0.1:12345/media/normal.txt",
		] {
			let invalid = URL(string: value)!
			#expect(throws: MediaSmokeFailure.self) {
				try MediaSmokeInput.startPoint(
					currentURL: invalid,
					expectedURL: invalid,
					bounds: bounds,
					isFlipped: false
				)
			}
		}

		for invalid in [
			CGRect.zero,
			CGRect(x: 1, y: 0, width: 640, height: 420),
			CGRect(x: 0, y: 0, width: 479, height: 420),
			CGRect(x: 0, y: 0, width: 640, height: 329),
			CGRect(x: 0, y: 0, width: 640, height: CGFloat.infinity),
			CGRect(x: 0, y: 0, width: 640, height: 2049),
		] {
			#expect(throws: MediaSmokeFailure.self) {
				try MediaSmokeInput.startPoint(
					currentURL: url,
					expectedURL: url,
					bounds: invalid,
					isFlipped: false
				)
			}
		}
	}

	@Test
	internal func requiresExactOwnedProfileMarkerAndLoopbackOrigin() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-smoke-" + UUID().uuidString)
		let profile = root.appendingPathComponent("profile")
		try FileManager.default.createDirectory(
			at: root,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(
			at: profile,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		let base = URL(string: "http://127.0.0.1:12345/index.html")!
		#expect(throws: MediaSmokeFailure.self) { try MediaSmokeFixture.validate(root: root, profile: profile, baseURL: base) }
		let marker = root.appendingPathComponent(".arx-media-smoke")
		try Data(MediaSmokeFixture.sentinel.utf8).write(to: marker)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
		try MediaSmokeFixture.validate(root: root, profile: profile, baseURL: base)
		for invalid in [
			"https://127.0.0.1:12345/index.html",
			"http://localhost:12345/index.html",
			"http://127.0.0.1:12345/index.html?q=1",
			"http://127.0.0.1:12345/other.html",
		] {
			#expect(throws: MediaSmokeFailure.self) {
				try MediaSmokeFixture.validate(root: root, profile: profile, baseURL: URL(string: invalid)!)
			}
		}
		try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
		#expect(throws: MediaSmokeFailure.self) { try MediaSmokeFixture.validate(root: root, profile: profile, baseURL: base) }
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
		try FileManager.default.removeItem(at: profile)
		try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: root)
		#expect(throws: MediaSmokeFailure.self) { try MediaSmokeFixture.validate(root: root, profile: profile, baseURL: base) }
	}

	private func title(
		fixtureCase: String = "normal",
		count: Int = 1,
		ready: Bool = true,
		playing: Bool = true,
		starts: Int = 1,
		trustedStarts: Int = 1,
		diagnostics: (visibility: String, videoReady: Int, network: Int, reports: Int)? = nil
	) -> String {
		let extra = diagnostics.map { diagnostics in
			#""visibility": "\#(diagnostics.visibility)", "videoReady": \#(diagnostics.videoReady), "network": \#(diagnostics.network), "reports": \#(diagnostics.reports),"#
		} ?? ""
		return """
		Arx media {
			\(extra)
			"case": "\(fixtureCase)",
			"ready": \(ready),
			"starts": \(starts),
			"trustedStarts": \(trustedStarts),
			"playing": \(playing),
			"pip": false,
			"loads": 1,
			"plays": \(count),
			"pauses": 0,
			"entered": 0,
			"left": 0,
			"requests": 1,
			"active": false,
			"activeAtRequest": true,
			"entryReason": "useraction",
			"error": null
		}
		"""
	}
}
#endif
