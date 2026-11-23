import AppUpdaterClient
import Foundation
import Testing
import _TestSupport

internal struct AppUpdaterTests {
	private static let feed: String = "https://github.com/example/arx/releases/latest/download/appcast.xml"
	private static let key: String = "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="

	private static func configuration(
		feedURL: String? = feed,
		publicKey: String? = key,
		isDebugBuild: Bool = false,
		isAutomatedRun: Bool = false,
		isSigned: Bool = true
	) -> AppUpdaterClient.Configuration {
		.init(
			feedURL: feedURL,
			publicKey: publicKey,
			isDebugBuild: isDebugBuild,
			isAutomatedRun: isAutomatedRun,
			isSigned: isSigned
		)
	}

	// MARK: - Configuration

	@Test
	internal func aSignedReleaseWithFeedAndKeyMayUpdate() {
		#expect(Self.configuration().availability == .available)
	}

	@Test
	internal func emptyValuesTurnUpdatesOff() {
		#expect(Self.configuration(feedURL: nil).availability == .unavailable(.missingFeed))
		#expect(Self.configuration(feedURL: "").availability == .unavailable(.missingFeed))
		#expect(Self.configuration(feedURL: "  ").availability == .unavailable(.missingFeed))
		#expect(Self.configuration(publicKey: nil).availability == .unavailable(.missingPublicKey))
		#expect(Self.configuration(publicKey: "").availability == .unavailable(.missingPublicKey))
		#expect(Self.configuration(publicKey: " \n").availability == .unavailable(.missingPublicKey))
	}

	@Test
	internal func thePlaceholderFeedTurnsUpdatesOff() {
		let placeholder: String = "https://github.com/ARX_RELEASES_OWNER/ARX_RELEASES_REPOSITORY/releases/latest/download/appcast.xml"

		#expect(Self.configuration(feedURL: placeholder).availability == .unavailable(.missingFeed))
	}

	@Test
	internal func onlyHTTPSFeedsCount() {
		let insecure: String = "http://github.com/example/arx/releases/latest/download/appcast.xml"

		#expect(Self.configuration(feedURL: insecure).availability == .unavailable(.missingFeed))
		#expect(Self.configuration(feedURL: "appcast.xml").availability == .unavailable(.missingFeed))
	}

	@Test
	internal func debugAutomatedAndUnsignedBuildsNeverUpdate() {
		#expect(Self.configuration(isDebugBuild: true).availability == .unavailable(.debugBuild))
		#expect(Self.configuration(isAutomatedRun: true).availability == .unavailable(.automatedRun))
		#expect(Self.configuration(isSigned: false).availability == .unavailable(.unsigned))
		// The build itself is reported before the feed.
		#expect(Self.configuration(feedURL: nil, isDebugBuild: true).availability == .unavailable(.debugBuild))
	}

	@Test
	internal func readsBothKeysFromTheInfoDictionary() {
		let info: [String: Any] = [
			AppUpdaterClient.Configuration.feedURLKey: Self.feed,
			AppUpdaterClient.Configuration.publicKeyKey: Self.key,
		]
		let configuration: AppUpdaterClient.Configuration = .init(
			info: info,
			isDebugBuild: false,
			isAutomatedRun: false,
			isSigned: true
		)

		#expect(configuration.feedURL == Self.feed)
		#expect(configuration.publicKey == Self.key)
		#expect(configuration.availability == .available)
	}

	@Test
	internal func automatedLaunchesAreRecognized() {
		#expect(!AppUpdaterClient.isAutomatedRun(environment: [:], arguments: ["Arx"]))
		#expect(AppUpdaterClient.isAutomatedRun(environment: ["ARX_SKIP_UPDATES": "1"], arguments: ["Arx"]))
		#expect(AppUpdaterClient.isAutomatedRun(environment: ["ARX_ENGINE_PROFILE": "/tmp/p"], arguments: ["Arx"]))
		#expect(AppUpdaterClient.isAutomatedRun(environment: ["XCTestBundlePath": "x"], arguments: ["Arx"]))
		#expect(AppUpdaterClient.isAutomatedRun(environment: [:], arguments: ["Arx", "--headless"]))
		#expect(AppUpdaterClient.isAutomatedRun(environment: [:], arguments: ["Arx", "--arx-smoke"]))
	}

	// MARK: - Versions

	@Test
	internal func onlyHigherBuildNumbersAreUpgrades() {
		#expect(AppUpdaterClient.isUpgrade(candidate: "4", current: "3"))
		#expect(AppUpdaterClient.isUpgrade(candidate: "10", current: "9"))
		#expect(AppUpdaterClient.isUpgrade(candidate: "3.1", current: "3"))
		#expect(!AppUpdaterClient.isUpgrade(candidate: "3", current: "3"))
		#expect(!AppUpdaterClient.isUpgrade(candidate: "3.0", current: "3"))
		#expect(!AppUpdaterClient.isUpgrade(candidate: "2", current: "3"))
		#expect(!AppUpdaterClient.isUpgrade(candidate: "9", current: "10"))
	}

	@Test
	internal func unreadableVersionsAreNeverUpgrades() {
		#expect(!AppUpdaterClient.isUpgrade(candidate: "", current: "3"))
		#expect(!AppUpdaterClient.isUpgrade(candidate: "4b", current: "3"))
		#expect(!AppUpdaterClient.isUpgrade(candidate: "4", current: ""))
		#expect(!AppUpdaterClient.isUpgrade(candidate: "-4", current: "3"))
	}

	// MARK: - Helpers

	@Test
	internal func waitsUntilHelpersExit() {
		var remaining: Int = 3
		var naps: Int = 0
		let finished: Bool = AppUpdaterClient.waitForHelpers(
			deadline: .seconds(1),
			interval: .milliseconds(100),
			sleep: { _ in
				naps += 1
				remaining -= 1
			},
			running: { remaining }
		)

		#expect(finished)
		#expect(naps == 3)
	}

	@Test
	internal func stopsWaitingAtTheDeadline() {
		var naps: Int = 0
		let finished: Bool = AppUpdaterClient.waitForHelpers(
			deadline: .milliseconds(500),
			interval: .milliseconds(100),
			sleep: { _ in naps += 1 },
			running: { 1 }
		)

		#expect(!finished)
		#expect(naps == 5)
	}
}
