import Foundation
import Security
import _Sparkle

extension AppUpdaterClient {
	/// Sparkle's standard updater and windows, when this build may update; ``unavailable(_:)``
	/// with the reason otherwise, so Debug, unsigned and automated runs never reach Sparkle.
	public static var live: Self {
		let configuration: Configuration = .init(
			info: Bundle.main.infoDictionary ?? [:],
			isDebugBuild: isDebugBuild,
			isAutomatedRun: isAutomatedRun(
				environment: ProcessInfo.processInfo.environment,
				arguments: CommandLine.arguments
			),
			isSigned: LiveSignature.hasTeamIdentifier()
		)
		if case let .unavailable(reason) = configuration.availability {
			return .unavailable(reason)
		}

		return .init(
			start: { LiveUpdater.shared.start(configuration) },
			checkForUpdates: { LiveUpdater.shared.checkForUpdates() },
			setAutomaticallyChecks: { LiveUpdater.shared.setAutomaticallyChecks($0) },
			setAutomaticallyDownloads: { LiveUpdater.shared.setAutomaticallyDownloads($0) },
			prepareForTermination: { LiveUpdater.shared.prepareForTermination() },
			quitCancelled: { LiveUpdater.shared.quitCancelled() },
			setChannel: { LiveUpdater.shared.setChannel($0) }
		)
	}

	private static var isDebugBuild: Bool {
		#if DEBUG
		return true
		#else
		return false
		#endif
	}
}

// MARK: - Updater

/// Owns Sparkle's controller for the life of the app. Created on the first start.
@MainActor
private final class LiveUpdater: NSObject, SPUUpdaterDelegate {
	internal static let shared: LiveUpdater = .init()

	/// How long quitting waits for engine helpers before letting Sparkle install anyway.
	private static let helperDeadline: Duration = .seconds(10)

	private var controller: SPUStandardUpdaterController?
	private var continuations: [UUID: AsyncStream<AppUpdaterClient.Event>.Continuation] = [:]
	private var observations: [NSKeyValueObservation] = []
	private var failure: AppUpdaterClient.Availability.Reason?
	private var installsOnQuit: Bool = false {
		didSet { if installsOnQuit != oldValue { publish() } }
	}

	/// Sparkle's go-ahead for a relaunch, kept while Arx's own quit runs. It's never invoked:
	/// Sparkle would terminate Arx itself. The update installs once the process exits.
	private var postponedRelaunch: (() -> Void)?

	/// A quit for Install and Relaunch was cancelled and Sparkle's window closed. Sparkle has no
	/// way to end that session and keep the staged update, so its session stays open until Arx
	/// quits: Check for Updates… is off and Settings offers Quit and Install instead.
	private var isWaitingForQuit: Bool = false

	/// The build's feeds and channel, from the first start.
	private var configuration: AppUpdaterClient.Configuration?

	/// The channel Sparkle's feed comes from (DEV-888).
	private var channel: AppUpdaterClient.Channel = .stable

	private let record: AppUpdaterClient.LaunchRecord = .standard

	/// This launch's What's New, until the first stream has been sent it.
	private var whatsNew: AppUpdaterClient.WhatsNew?

	internal func start(_ configuration: AppUpdaterClient.Configuration) -> AsyncStream<AppUpdaterClient.Event> {
		if self.configuration == nil {
			self.configuration = configuration
			let stored: String? = UserDefaults.standard.string(forKey: AppUpdaterClient.Channel.preferenceKey)
			channel = .resolve(
				stored: stored,
				buildDefault: configuration.buildChannel,
				offersBeta: configuration.offersBeta
			)

			// A beta install keeps Beta after the Beta feed brings it a stable build, whose own
			// default is Stable: the first channel is kept as if it had been chosen.
			if stored == nil, configuration.offersBeta {
				UserDefaults.standard.set(channel.rawValue, forKey: AppUpdaterClient.Channel.preferenceKey)
			}
			let info: [String: Any] = Bundle.main.infoDictionary ?? [:]
			whatsNew = record.launch(
				version: info["CFBundleShortVersionString"] as? String ?? "",
				build: info["CFBundleVersion"] as? String ?? ""
			)
		}
		startIfNeeded()
		let id: UUID = .init()
		let (stream, continuation) = AsyncStream<AppUpdaterClient.Event>.makeStream()
		continuation.yield(.status(status))
		if let whatsNew {
			continuation.yield(.whatsNew(whatsNew))
			self.whatsNew = nil
		}
		continuations[id] = continuation
		continuation.onTermination = { _ in
			Task { @MainActor in LiveUpdater.shared.continuations[id] = nil }
		}
		return stream
	}

	internal func checkForUpdates() {
		guard let updater = controller?.updater, updater.canCheckForUpdates
		else { return }

		updater.checkForUpdates()
	}

	internal func setAutomaticallyChecks(_ isEnabled: Bool) {
		controller?.updater.automaticallyChecksForUpdates = isEnabled
		publish()
	}

	internal func setAutomaticallyDownloads(_ isEnabled: Bool) {
		guard let updater = controller?.updater, updater.allowsAutomaticUpdates
		else { return }

		updater.automaticallyDownloadsUpdates = isEnabled
		publish()
	}

	/// Always waits in a configured build: any update Sparkle has extracted installs once Arx
	/// exits, whichever window or setting staged it. Helpers have usually exited already.
	internal func prepareForTermination() {
		let bundle: URL = Bundle.main.bundleURL
		AppUpdaterClient.waitForHelpers(deadline: Self.helperDeadline) {
			BundleHelpers.running(in: bundle)
		}
	}

	internal func setChannel(_ channel: AppUpdaterClient.Channel) {
		guard
			let configuration,
			configuration.offersBeta || channel == .stable,
			channel != self.channel
		else { return }

		self.channel = channel
		UserDefaults.standard.set(channel.rawValue, forKey: AppUpdaterClient.Channel.preferenceKey)

		// The next scheduled check reads the new channel's feed; Check Now does at once.
		controller?.updater.resetUpdateCycleAfterShortDelay()
		publish()
	}

	internal func quitCancelled() {
		guard postponedRelaunch != nil
		else { return }

		// The window's Install and Relaunch button has done its part and would stay inert.
		// The update stays staged and installs at the next quit.
		controller?.userDriver.dismissUpdateInstallation()
		isWaitingForQuit = true
		publish()
	}

	private func startIfNeeded() {
		guard controller == nil, failure == nil
		else { return }

		let controller: SPUStandardUpdaterController = .init(
			startingUpdater: false,
			updaterDelegate: self,
			userDriverDelegate: nil
		)
		do {
			// Starting the updater directly, rather than through the controller, keeps a
			// misconfigured build from showing Sparkle's error alert at launch.
			try controller.updater.start()
		} catch {
			failure = .failedToStart(error.localizedDescription)
			return
		}

		self.controller = controller
		let updater: SPUUpdater = controller.updater
		observations = [
			updater.observe(\.canCheckForUpdates) { _, _ in
				Task { @MainActor in LiveUpdater.shared.publish() }
			},
			updater.observe(\.sessionInProgress) { _, _ in
				Task { @MainActor in LiveUpdater.shared.publish() }
			},
			updater.observe(\.lastUpdateCheckDate) { _, _ in
				Task { @MainActor in LiveUpdater.shared.publish() }
			},
			updater.observe(\.automaticallyChecksForUpdates) { _, _ in
				Task { @MainActor in LiveUpdater.shared.publish() }
			},
			updater.observe(\.automaticallyDownloadsUpdates) { _, _ in
				Task { @MainActor in LiveUpdater.shared.publish() }
			},
		]
	}

	private var status: AppUpdaterClient.Status {
		if let failure { return .unavailable(failure) }
		guard let updater = controller?.updater
		else { return .unavailable(.failedToStart("Sparkle didn't start")) }

		return .init(
			availability: .available,
			canCheck: updater.canCheckForUpdates && !isWaitingForQuit,
			isChecking: updater.sessionInProgress,
			automaticallyChecks: updater.automaticallyChecksForUpdates,
			automaticallyDownloads: updater.allowsAutomaticUpdates && updater.automaticallyDownloadsUpdates,
			lastCheck: updater.lastUpdateCheckDate,
			isReadyToInstall: installsOnQuit,
			channel: channel,
			offersBeta: configuration?.offersBeta == true
		)
	}

	private func publish() {
		send(.status(status))
	}

	private func send(_ event: AppUpdaterClient.Event) {
		for continuation in continuations.values {
			continuation.yield(event)
		}
	}

	// MARK: SPUUpdaterDelegate

	/// The chosen channel's feed. `SUFeedURL` stays the Stable feed in `Info.plist`.
	internal func feedURLString(for updater: SPUUpdater) -> String? {
		configuration?.feed(for: channel)?.absoluteString
	}

	/// Keeps the release notes of the update found, for What's New after it installs.
	internal func updater(
		_ updater: SPUUpdater,
		didFindValidUpdate item: SUAppcastItem
	) {
		record.remember(
			.init(
				version: item.displayVersionString,
				build: item.versionString,
				notes: AppUpdaterClient.releaseNotesText(item.itemDescription, format: item.itemDescriptionFormat),
				fullNotesURL: item.fullReleaseNotesURL
			)
		)
	}

	/// Never an older or equal build, whatever the feed lists.
	internal func updater(
		_ updater: SPUUpdater,
		shouldProceedWithUpdate updateItem: SUAppcastItem,
		updateCheck: SPUUpdateCheck
	) throws {
		let current: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
		guard AppUpdaterClient.isUpgrade(candidate: updateItem.versionString, current: current) else {
			throw NSError(
				domain: "dev.capturecontext.arx.updates",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Arx only installs newer versions."]
			)
		}
	}

	/// Install and Relaunch quits through Arx's own quit path; Sparkle installs once Arx has exited.
	internal func updater(
		_ updater: SPUUpdater,
		shouldPostponeRelaunchForUpdate item: SUAppcastItem,
		untilInvokingBlock installHandler: @escaping () -> Void
	) -> Bool {
		postponedRelaunch = installHandler
		installsOnQuit = true
		send(.quitRequested)
		return true
	}

	/// An automatically downloaded update installs when Arx quits. Sparkle keeps scheduling checks.
	internal func updater(
		_ updater: SPUUpdater,
		willInstallUpdateOnQuit item: SUAppcastItem,
		immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
	) -> Bool {
		installsOnQuit = true
		return false
	}

	internal func updater(
		_ updater: SPUUpdater,
		userDidMake choice: SPUUserUpdateChoice,
		forUpdate updateItem: SUAppcastItem,
		state: SPUUserUpdateState
	) {
		switch (choice, state.stage) {
		case (.dismiss, .installing):
			// A dismissed update that's already installing still installs when Arx quits.
			installsOnQuit = true

		case (.skip, _), (.dismiss, _):
			// Skipped, or dismissed before installing began: nothing installs at quit.
			installsOnQuit = false

		default:
			break
		}
	}


	internal func updater(
		_ updater: SPUUpdater,
		didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
		error: (any Error)?
	) {
		// A cycle that failed, or whose installation was cancelled, leaves nothing staged.
		// "No update" is how a later check ends and says nothing about a staged one.
		if let error = error as? NSError, error.code != Int(SUError.noUpdateError.rawValue) {
			installsOnQuit = false
		}
		publish()
	}
}

// MARK: - Signature

private enum LiveSignature {
	/// Whether the running app is signed with a team identity. Ad-hoc and unsigned builds,
	/// such as CI's, aren't, and Sparkle couldn't install an update over them safely.
	internal static func hasTeamIdentifier() -> Bool {
		var code: SecCode?
		guard SecCodeCopySelf([], &code) == errSecSuccess, let code
		else { return false }

		var staticCode: SecStaticCode?
		guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
		else { return false }

		var information: CFDictionary?
		guard
			SecCodeCopySigningInformation(
				staticCode,
				SecCSFlags(rawValue: kSecCSSigningInformation),
				&information
			) == errSecSuccess,
			let information = information as? [String: Any]
		else { return false }

		guard let team = information[kSecCodeInfoTeamIdentifier as String] as? String
		else { return false }

		return !team.isEmpty
	}
}
