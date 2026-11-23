import AppUpdaterClient
import Foundation
import Testing
import _TestSupport

/// Stable and Beta channels, and What's New after an update (DEV-888).
internal struct UpdateChannelTests {
	private static let stable: String = "https://github.com/example/arx/releases/latest/download/appcast.xml"
	private static let beta: String = "https://github.com/example/arx/releases/download/beta-feed/appcast-beta.xml"

	private static func configuration(
		betaFeedURL: String? = beta,
		buildChannel: AppUpdaterClient.Channel = .stable
	) -> AppUpdaterClient.Configuration {
		.init(
			feedURL: stable,
			publicKey: "key",
			isDebugBuild: false,
			isAutomatedRun: false,
			isSigned: true,
			betaFeedURL: betaFeedURL,
			buildChannel: buildChannel
		)
	}

	// MARK: - Feeds

	@Test
	internal func eachChannelReadsItsOwnFeed() {
		let configuration = Self.configuration()
		#expect(configuration.offersBeta)
		#expect(configuration.feed(for: .stable)?.absoluteString == Self.stable)
		#expect(configuration.feed(for: .beta)?.absoluteString == Self.beta)
	}

	@Test
	internal func aBuildWithoutABetaFeedOnlyOffersStable() {
		for value in [nil, "", "  ", "http://example.com/appcast.xml", "https://github.com/ARX_RELEASES_OWNER/ARX_RELEASES_REPOSITORY/x.xml", Self.stable] {
			let configuration = Self.configuration(betaFeedURL: value)
			#expect(!configuration.offersBeta, "\(String(describing: value))")
			#expect(configuration.feed(for: .beta)?.absoluteString == Self.stable)
		}
	}

	@Test
	internal func infoPlistKeysConfigureTheChannel() {
		let configuration: AppUpdaterClient.Configuration = .init(
			info: [
				"SUFeedURL": Self.stable,
				"SUPublicEDKey": "key",
				"ArxBetaFeedURL": Self.beta,
				"ArxUpdateChannel": " Beta ",
			],
			isDebugBuild: false,
			isAutomatedRun: false,
			isSigned: true
		)
		#expect(configuration.betaFeed?.absoluteString == Self.beta)
		#expect(configuration.buildChannel == .beta)

		let unknown: AppUpdaterClient.Configuration = .init(
			info: ["ArxUpdateChannel": "nightly"],
			isDebugBuild: false,
			isAutomatedRun: false,
			isSigned: true
		)
		#expect(unknown.buildChannel == .stable)
	}

	@Test
	internal func theChosenChannelWinsOverTheBuildsOwn() {
		#expect(AppUpdaterClient.Channel.resolve(stored: nil, buildDefault: .beta, offersBeta: true) == .beta)
		#expect(AppUpdaterClient.Channel.resolve(stored: "stable", buildDefault: .beta, offersBeta: true) == .stable)
		#expect(AppUpdaterClient.Channel.resolve(stored: "beta", buildDefault: .stable, offersBeta: true) == .beta)
		#expect(AppUpdaterClient.Channel.resolve(stored: "garbage", buildDefault: .stable, offersBeta: true) == .stable)
		// No beta feed: Stable whatever was chosen before.
		#expect(AppUpdaterClient.Channel.resolve(stored: "beta", buildDefault: .beta, offersBeta: false) == .stable)
	}

	@Test
	internal func switchingBackToStableNeverDowngrades() {
		// On Beta at build 12; the newest stable release is build 10.
		#expect(!AppUpdaterClient.isUpgrade(candidate: "10", current: "12"))
		// The next stable release past the beta installs.
		#expect(AppUpdaterClient.isUpgrade(candidate: "13", current: "12"))
	}

	// MARK: - What's New

	private static let notes: AppUpdaterClient.ReleaseNotes = .init(
		version: "0.3.0",
		build: "12",
		notes: "- Faster tab switching\n- Update channels",
		fullNotesURL: URL(string: "https://manual.arx.capturecontext.dev/help/release-notes#030")
	)

	@Test
	internal func theFirstLaunchOfANewerBuildShowsItsNotes() {
		let whatsNew = AppUpdaterClient.whatsNew(
			currentVersion: "0.3.0",
			currentBuild: "12",
			lastLaunchedBuild: "11",
			pending: Self.notes
		)
		#expect(
			whatsNew == .init(
				version: "0.3.0",
				build: "12",
				notes: "- Faster tab switching\n- Update channels",
				fullNotesURL: URL(string: "https://manual.arx.capturecontext.dev/help/release-notes#030")!
			)
		)
	}

	@Test
	internal func aFirstInstallARelaunchOrADowngradeShowNothing() {
		#expect(AppUpdaterClient.whatsNew(currentVersion: "0.3.0", currentBuild: "12", lastLaunchedBuild: nil, pending: Self.notes) == nil)
		#expect(AppUpdaterClient.whatsNew(currentVersion: "0.3.0", currentBuild: "12", lastLaunchedBuild: "12", pending: Self.notes) == nil)
		#expect(AppUpdaterClient.whatsNew(currentVersion: "0.3.0", currentBuild: "12", lastLaunchedBuild: "13", pending: Self.notes) == nil)
	}

	@Test
	internal func anUpdateWithoutMatchingNotesStillLinksTheManual() {
		let whatsNew = AppUpdaterClient.whatsNew(
			currentVersion: "0.4.0",
			currentBuild: "14",
			lastLaunchedBuild: "12",
			pending: Self.notes
		)
		#expect(whatsNew?.notes == nil)
		#expect(whatsNew?.fullNotesURL == AppUpdaterClient.releaseNotesPage)
	}

	@Test
	internal func longNotesAreCutAtALineBreak() {
		let line: String = String(repeating: "x", count: 100)
		let long: String = Array(repeating: line, count: 20).joined(separator: "\n")
		var notes = Self.notes
		notes.notes = long
		let whatsNew = AppUpdaterClient.whatsNew(
			currentVersion: "0.3.0",
			currentBuild: "12",
			lastLaunchedBuild: "11",
			pending: notes
		)
		let shown: String = whatsNew?.notes ?? ""
		#expect(shown.count <= AppUpdaterClient.whatsNewNotesLimit + 2)
		#expect(shown.hasSuffix("\n…"))
		#expect(shown.dropLast(2).split(separator: "\n").allSatisfy { $0.count == 100 })
	}

	@Test
	internal func htmlNotesBecomePlainText() {
		let html = "<h2>Arx 0.3.0</h2><ul><li>Tabs &amp; spaces</li><li>Update channels</li></ul><p>Thanks!</p>"
		#expect(
			AppUpdaterClient.releaseNotesText(html, format: "html")
				== "Arx 0.3.0\n• Tabs & spaces\n• Update channels\nThanks!"
		)
		#expect(AppUpdaterClient.releaseNotesText("- One\n- Two", format: "markdown") == "- One\n- Two")
		#expect(AppUpdaterClient.releaseNotesText("  ", format: "plain-text") == nil)
		#expect(AppUpdaterClient.releaseNotesText(nil, format: nil) == nil)
	}

	@Test
	internal func theLaunchRecordShowsWhatsNewOnceAndKeepsNewerNotes() {
		let storage: LockIsolated<[String: Data]> = .init([:])
		let strings: LockIsolated<[String: String]> = .init([:])
		let record: AppUpdaterClient.LaunchRecord = .init(
			load: { key in storage.value[key] },
			loadString: { key in strings.value[key] },
			save: { key, value in storage.withValue { $0[key] = value } },
			saveString: { key, value in strings.withValue { $0[key] = value } }
		)

		// First install: nothing to show, the build is recorded.
		#expect(record.launch(version: "0.2.0", build: "11") == nil)
		#expect(strings.value[AppUpdaterClient.LaunchRecord.lastLaunchedBuildKey] == "11")

		// Sparkle found build 12 and it installed.
		record.remember(Self.notes)
		#expect(record.launch(version: "0.3.0", build: "12")?.notes == "- Faster tab switching\n- Update channels")
		#expect(storage.value[AppUpdaterClient.LaunchRecord.pendingReleaseNotesKey] == nil)

		// The next launch of the same build shows nothing.
		#expect(record.launch(version: "0.3.0", build: "12") == nil)

		// Notes for a build that hasn't installed yet survive a launch.
		var newer = Self.notes
		newer.build = "13"
		record.remember(newer)
		#expect(record.launch(version: "0.3.0", build: "12") == nil)
		#expect(storage.value[AppUpdaterClient.LaunchRecord.pendingReleaseNotesKey] != nil)
	}
}
