import Foundation
import _Dependencies

/// Checks for, downloads and installs new versions of Arx from GitHub Releases through Sparkle.
///
/// The updater only runs in a signed release build with a real feed and public key; everywhere
/// else ``start`` reports why it's off and nothing reaches Sparkle. Reducers drive the closures,
/// so tests replace them with doubles.
public struct AppUpdaterClient: Sendable {
	/// Starts the updater once and streams its state, then a quit request when a downloaded
	/// update asks to relaunch. A build that can't update yields one unavailable status and ends.
	public var start: @MainActor @Sendable () -> AsyncStream<Event>

	/// Checks for updates now, showing Sparkle's window. Does nothing while a check runs.
	public var checkForUpdates: @MainActor @Sendable () -> Void

	/// Whether Sparkle checks for updates in the background, once a day.
	public var setAutomaticallyChecks: @MainActor @Sendable (Bool) -> Void

	/// Whether Sparkle downloads an update it finds and installs it when Arx quits.
	public var setAutomaticallyDownloads: @MainActor @Sendable (Bool) -> Void

	/// Called once Chromium has stopped and before the process exits. In a build that updates,
	/// it waits for Arx's engine helpers to exit, so Sparkle never replaces the app while one of
	/// them still runs from it.
	public var prepareForTermination: @MainActor @Sendable () -> Void

	/// The quit a relaunch request started didn't happen: a page or download kept Arx open.
	/// Sparkle's Ready to Install window closes, checks stay off, and the update installs at the
	/// next quit, which Settings offers as Quit and Install.
	public var quitCancelled: @MainActor @Sendable () -> Void

	/// Switches between the Stable and Beta channels and checks the new channel's feed soon.
	/// Never downgrades: an installed build newer than the channel's newest release stays.
	public var setChannel: @MainActor @Sendable (Channel) -> Void

	public init(
		start: @escaping @MainActor @Sendable () -> AsyncStream<Event>,
		checkForUpdates: @escaping @MainActor @Sendable () -> Void,
		setAutomaticallyChecks: @escaping @MainActor @Sendable (Bool) -> Void,
		setAutomaticallyDownloads: @escaping @MainActor @Sendable (Bool) -> Void,
		prepareForTermination: @escaping @MainActor @Sendable () -> Void,
		quitCancelled: @escaping @MainActor @Sendable () -> Void = {},
		setChannel: @escaping @MainActor @Sendable (Channel) -> Void = { _ in }
	) {
		self.start = start
		self.checkForUpdates = checkForUpdates
		self.setAutomaticallyChecks = setAutomaticallyChecks
		self.setAutomaticallyDownloads = setAutomaticallyDownloads
		self.prepareForTermination = prepareForTermination
		self.quitCancelled = quitCancelled
		self.setChannel = setChannel
	}
}

// MARK: - Types

extension AppUpdaterClient {
	public enum Event: Equatable, Sendable {
		case status(Status)

		/// A downloaded update asked to relaunch. Arx quits through its usual quit path instead,
		/// so pages, downloads and the workspace close as they always do, and Sparkle installs the
		/// update once the process has exited.
		case quitRequested

		/// The first start after Arx was updated: what changed in the build now running. Sent
		/// once per launch, and only in a build that updates.
		case whatsNew(WhatsNew)
	}

	/// What Settings and the app menu show.
	public struct Status: Equatable, Sendable {
		public var availability: Availability

		/// Whether Check for Updates… may start a check now.
		public var canCheck: Bool

		/// Whether a check, download or install is under way.
		public var isChecking: Bool

		public var automaticallyChecks: Bool
		public var automaticallyDownloads: Bool

		/// When Sparkle last checked, by itself or when asked.
		public var lastCheck: Date?

		/// A downloaded update installs the next time Arx quits.
		public var isReadyToInstall: Bool

		/// The channel updates come from.
		public var channel: Channel

		/// Whether this build has a beta feed, so Settings offers the channel choice.
		public var offersBeta: Bool

		public init(
			availability: Availability,
			canCheck: Bool = false,
			isChecking: Bool = false,
			automaticallyChecks: Bool = false,
			automaticallyDownloads: Bool = false,
			lastCheck: Date? = nil,
			isReadyToInstall: Bool = false,
			channel: Channel = .stable,
			offersBeta: Bool = false
		) {
			self.availability = availability
			self.canCheck = canCheck
			self.isChecking = isChecking
			self.automaticallyChecks = automaticallyChecks
			self.automaticallyDownloads = automaticallyDownloads
			self.lastCheck = lastCheck
			self.isReadyToInstall = isReadyToInstall
			self.channel = channel
			self.offersBeta = offersBeta
		}

		public static func unavailable(_ reason: Availability.Reason) -> Self {
			.init(availability: .unavailable(reason))
		}

		public var isAvailable: Bool {
			availability == .available
		}
	}

	public enum Availability: Equatable, Sendable {
		case available
		case unavailable(Reason)

		public enum Reason: Equatable, Sendable {
			/// A Debug build. Only release builds update.
			case debugBuild

			/// A test, smoke or headless run, or `ARX_SKIP_UPDATES` is set.
			case automatedRun

			/// The app has no Developer ID or Apple Development signature, such as an unsigned CI build.
			case unsigned

			/// `SUFeedURL` is empty, isn't HTTPS, or still names the placeholder repository.
			case missingFeed

			/// `SUPublicEDKey` is empty, so Sparkle couldn't verify an update.
			case missingPublicKey

			/// Sparkle refused to start; its message is kept for diagnostics.
			case failedToStart(String)
		}
	}
}

// MARK: - Configuration

extension AppUpdaterClient {
	/// The `Info.plist` keys and build facts that decide whether this build may update.
	public struct Configuration: Equatable, Sendable {
		/// Part of the default `ARX_UPDATE_FEED_URL`, which stays until the public repository exists.
		public static let placeholderMarker: String = "ARX_RELEASES_REPOSITORY"

		public static let feedURLKey: String = "SUFeedURL"
		public static let publicKeyKey: String = "SUPublicEDKey"

		public var feedURL: String?
		public var publicKey: String?
		public var isDebugBuild: Bool
		public var isAutomatedRun: Bool
		public var isSigned: Bool

		/// `ArxBetaFeedURL`: the feed the Beta channel reads. Empty in builds without one.
		public var betaFeedURL: String?

		/// `ArxUpdateChannel`: the channel this build was released on, used until the person
		/// picks one in Settings.
		public var buildChannel: Channel

		public init(
			feedURL: String?,
			publicKey: String?,
			isDebugBuild: Bool,
			isAutomatedRun: Bool,
			isSigned: Bool,
			betaFeedURL: String? = nil,
			buildChannel: Channel = .stable
		) {
			self.feedURL = feedURL
			self.publicKey = publicKey
			self.isDebugBuild = isDebugBuild
			self.isAutomatedRun = isAutomatedRun
			self.isSigned = isSigned
			self.betaFeedURL = betaFeedURL
			self.buildChannel = buildChannel
		}

		/// Reads the feed and key from an `Info.plist` dictionary.
		public init(
			info: [String: Any],
			isDebugBuild: Bool,
			isAutomatedRun: Bool,
			isSigned: Bool
		) {
			self.init(
				feedURL: info[Self.feedURLKey] as? String,
				publicKey: info[Self.publicKeyKey] as? String,
				isDebugBuild: isDebugBuild,
				isAutomatedRun: isAutomatedRun,
				isSigned: isSigned,
				betaFeedURL: info[Self.betaFeedURLKey] as? String,
				buildChannel: (info[Self.channelKey] as? String)
					.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
					.flatMap(Channel.init(rawValue:)) ?? .stable
			)
		}

		/// Whether the updater may start, or the first reason it may not.
		public var availability: Availability {
			if isDebugBuild { return .unavailable(.debugBuild) }
			if isAutomatedRun { return .unavailable(.automatedRun) }
			if !isSigned { return .unavailable(.unsigned) }
			if Self.feed(from: feedURL) == nil { return .unavailable(.missingFeed) }
			if Self.trimmed(publicKey) == nil { return .unavailable(.missingPublicKey) }
			return .available
		}

		/// An HTTPS feed that isn't the placeholder.
		internal static func feed(from value: String?) -> URL? {
			guard
				let value = trimmed(value),
				!value.contains(placeholderMarker),
				let url = URL(string: value),
				url.scheme?.lowercased() == "https",
				url.host() != nil
			else { return nil }

			return url
		}

		private static func trimmed(_ value: String?) -> String? {
			guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
			else { return nil }

			return value
		}
	}

	/// Whether this launch is automated: test runs (XCTest keys), smoke fixtures (which set
	/// `ARX_ENGINE_PROFILE` or pass `--arx-…` options), headless runs, and runs with
	/// `ARX_SKIP_UPDATES`. Those never check for updates.
	public static func isAutomatedRun(
		environment: [String: String],
		arguments: [String]
	) -> Bool {
		let automationKeys: [String] = [
			"ARX_SKIP_UPDATES",
			"ARX_ENGINE_PROFILE",
			"XCTestConfigurationFilePath",
			"XCTestBundlePath",
			"XCTestSessionIdentifier",
		]
		guard automationKeys.allSatisfy({ environment[$0] == nil })
		else { return true }

		return arguments.dropFirst().contains { argument in
			argument == "--headless" || argument.hasPrefix("--arx-")
		}
	}
}

// MARK: - Versions

extension AppUpdaterClient {
	/// Whether a release is newer than this build, comparing build numbers (`CFBundleVersion`)
	/// numerically part by part. Arx never installs an older or equal build: Chromium profiles
	/// and Arx's own data only migrate forward.
	public static func isUpgrade(
		candidate: String,
		current: String
	) -> Bool {
		guard
			let candidate = numericParts(candidate),
			let current = numericParts(current)
		else { return false }

		let count: Int = max(candidate.count, current.count)
		for index in 0..<count {
			let left: Int = index < candidate.count ? candidate[index] : 0
			let right: Int = index < current.count ? current[index] : 0
			if left != right { return left > right }
		}
		return false
	}

	private static func numericParts(_ version: String) -> [Int]? {
		let parts: [Substring] = version
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.split(separator: ".", omittingEmptySubsequences: false)
		guard !parts.isEmpty
		else { return nil }

		var numbers: [Int] = []
		for part in parts {
			guard let number = Int(part), number >= 0
			else { return nil }

			numbers.append(number)
		}
		return numbers
	}
}

// MARK: - Dependency

extension AppUpdaterClient: DependencyKey {
	public static var liveValue: Self { .live }

	/// Tests must supply their own client, so an unexpected call fails the test.
	public static var testValue: Self {
		.init(
			start: unimplemented("AppUpdaterClient.start", placeholder: .finished),
			checkForUpdates: unimplemented("AppUpdaterClient.checkForUpdates"),
			setAutomaticallyChecks: unimplemented("AppUpdaterClient.setAutomaticallyChecks"),
			setAutomaticallyDownloads: unimplemented("AppUpdaterClient.setAutomaticallyDownloads"),
			prepareForTermination: unimplemented("AppUpdaterClient.prepareForTermination"),
			quitCancelled: unimplemented("AppUpdaterClient.quitCancelled"),
			setChannel: unimplemented("AppUpdaterClient.setChannel")
		)
	}

	/// Previews show a configured updater that checked an hour ago and never touches Sparkle.
	public static var previewValue: Self {
		.init(
			start: {
				AsyncStream { continuation in
					continuation.yield(
						.status(
							.init(
								availability: .available,
								canCheck: true,
								automaticallyChecks: true,
								lastCheck: Date(timeIntervalSinceNow: -3600),
								offersBeta: true
							)
						)
					)
				}
			},
			checkForUpdates: {},
			setAutomaticallyChecks: { _ in },
			setAutomaticallyDownloads: { _ in },
			prepareForTermination: {}
		)
	}

	/// A client for builds and runs that never update.
	public static func unavailable(_ reason: Availability.Reason) -> Self {
		.init(
			start: {
				AsyncStream { continuation in
					continuation.yield(.status(.unavailable(reason)))
					continuation.finish()
				}
			},
			checkForUpdates: {},
			setAutomaticallyChecks: { _ in },
			setAutomaticallyDownloads: { _ in },
			prepareForTermination: {}
		)
	}
}

extension AsyncStream {
	fileprivate static var finished: Self {
		AsyncStream { $0.finish() }
	}
}

extension DependencyValues {
	public var appUpdater: AppUpdaterClient {
		get { self[AppUpdaterClient.self] }
		set { self[AppUpdaterClient.self] = newValue }
	}
}
