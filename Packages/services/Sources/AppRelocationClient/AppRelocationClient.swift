import Foundation
import _Dependencies

/// Moves Arx into Applications when it runs from the release disk image or a translocated copy.
///
/// The closures are the operating-system operations; `relocate(_:)` holds the decisions,
/// so tests drive every case with doubles.
public struct AppRelocationClient: Sendable {
	/// Where the running app bundle is.
	public var bundleURL: @MainActor @Sendable () -> URL

	/// The original location of a translocated bundle, or `nil` when it can't be resolved.
	public var originalURL: @MainActor @Sendable (URL) -> URL?

	/// The mount point of the disk image holding this path, or `nil` when it isn't on one.
	public var diskImageVolume: @MainActor @Sendable (URL) -> URL?

	/// The user's own `~/Applications`, created when needed by `install`.
	public var userApplicationsDirectory: @MainActor @Sendable () -> URL

	public var isWritable: @MainActor @Sendable (URL) -> Bool

	public var fileExists: @MainActor @Sendable (URL) -> Bool

	/// Brings a running copy at this location to the front. Returns `false` when none is running.
	public var activateRunningCopy: @MainActor @Sendable (URL) -> Bool

	public var isPromptSuppressed: @MainActor @Sendable () -> Bool

	public var suppressPrompt: @MainActor @Sendable () -> Void

	/// Asks "Move Arx to Applications?".
	public var prompt: @MainActor @Sendable () -> PromptAnswer

	/// Moves any existing copy to the Trash, then copies the bundle in with its signature intact.
	/// Throws `Failure.authorizationDeclined` when the administrator prompt is cancelled.
	public var install: @MainActor @Sendable (Installation) throws -> Void

	/// Launches the installed copy once this process exits, ejecting the disk image first.
	public var relaunch: @MainActor @Sendable (_ destination: URL, _ diskImageVolume: URL?) throws -> Void

	/// Moves the copy Arx was opened from to the Trash once it's installed elsewhere.
	/// Used only when that copy isn't on a disk image, such as one in Downloads; failures are ignored.
	public var trashOriginal: @MainActor @Sendable (URL) -> Void

	/// Explains a failed move. Arx keeps running from where it is.
	public var reportFailure: @MainActor @Sendable (Error) -> Void

	public init(
		bundleURL: @escaping @MainActor @Sendable () -> URL = { Bundle.main.bundleURL },
		originalURL: @escaping @MainActor @Sendable (URL) -> URL? = { _ in nil },
		diskImageVolume: @escaping @MainActor @Sendable (URL) -> URL? = { _ in nil },
		userApplicationsDirectory: @escaping @MainActor @Sendable () -> URL = {
			URL.homeDirectory.appending(path: "Applications", directoryHint: .isDirectory)
		},
		isWritable: @escaping @MainActor @Sendable (URL) -> Bool = { _ in false },
		fileExists: @escaping @MainActor @Sendable (URL) -> Bool = { _ in false },
		activateRunningCopy: @escaping @MainActor @Sendable (URL) -> Bool = { _ in false },
		isPromptSuppressed: @escaping @MainActor @Sendable () -> Bool = { true },
		suppressPrompt: @escaping @MainActor @Sendable () -> Void = {},
		prompt: @escaping @MainActor @Sendable () -> PromptAnswer = { .notNow },
		install: @escaping @MainActor @Sendable (Installation) throws -> Void = { _ in
			throw Failure.unavailable
		},
		relaunch: @escaping @MainActor @Sendable (URL, URL?) throws -> Void = { _, _ in
			throw Failure.unavailable
		},
		trashOriginal: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
		reportFailure: @escaping @MainActor @Sendable (Error) -> Void = { _ in }
	) {
		self.bundleURL = bundleURL
		self.originalURL = originalURL
		self.diskImageVolume = diskImageVolume
		self.userApplicationsDirectory = userApplicationsDirectory
		self.isWritable = isWritable
		self.fileExists = fileExists
		self.activateRunningCopy = activateRunningCopy
		self.isPromptSuppressed = isPromptSuppressed
		self.suppressPrompt = suppressPrompt
		self.prompt = prompt
		self.install = install
		self.relaunch = relaunch
		self.trashOriginal = trashOriginal
		self.reportFailure = reportFailure
	}
}

// MARK: - Types

extension AppRelocationClient {
	public enum PromptAnswer: Equatable, Sendable {
		case move
		case notNow
		case neverAsk
	}

	public struct Installation: Equatable, Sendable {
		public var source: URL
		public var destination: URL

		/// Whether the copy needs an administrator password.
		public var privileged: Bool

		public init(
			source: URL,
			destination: URL,
			privileged: Bool
		) {
			self.source = source
			self.destination = destination
			self.privileged = privileged
		}
	}

	public enum Outcome: Equatable, Sendable {
		/// Arx isn't on a disk image or translocated, or relocation is switched off.
		case notNeeded

		/// The person chose not to move Arx now, or earlier chose not to be asked again.
		case declined

		/// A copy at the destination is already running and was brought to the front.
		case activatedRunningCopy(URL)

		/// Arx was installed here and relaunches from it once this process quits.
		case moved(URL)

		/// The move failed and Arx keeps running from where it is.
		case failed
	}

	public enum Failure: Error, Equatable, LocalizedError {
		case unavailable
		case authorizationDeclined
		case copyFailed(String)
		case relaunchFailed(String)

		public var errorDescription: String? {
			switch self {
			case .unavailable:
				"Moving Arx isn't available here."

			case .authorizationDeclined:
				"An administrator password is needed to move Arx to Applications."

			case let .copyFailed(reason):
				"Arx couldn't be copied to Applications. \(reason)"

			case let .relaunchFailed(reason):
				"Arx was copied but couldn't be opened from Applications. \(reason)"
			}
		}
	}

	/// Whether this launch may relocate at all.
	///
	/// Automated runs never move the app: test runs, smoke fixtures (which always set
	/// `ARX_ENGINE_PROFILE` or pass `--arx-…` options) and headless runs. Debug builds
	/// are skipped by the launcher at compile time.
	public static func isEnabled(
		environment: [String: String],
		arguments: [String]
	) -> Bool {
		let automationKeys: [String] = [
			"ARX_SKIP_RELOCATION",
			"ARX_ENGINE_PROFILE",
			"XCTestConfigurationFilePath",
			"XCTestBundlePath",
			"XCTestSessionIdentifier",
		]
		guard automationKeys.allSatisfy({ environment[$0] == nil })
		else { return false }

		return !arguments.dropFirst().contains { argument in
			argument == "--headless" || argument.hasPrefix("--arx-")
		}
	}

	public static func isTranslocated(_ url: URL) -> Bool {
		url.path(percentEncoded: false).contains("/AppTranslocation/")
	}
}

// MARK: - Decisions

extension AppRelocationClient {
	public static let systemApplicationsDirectory: URL = URL(
		filePath: "/Applications",
		directoryHint: .isDirectory
	)

	/// Moves Arx to Applications when it should, and reports what happened.
	///
	/// - Parameters:
	///   - askFirst: Whether a copy that isn't on a disk image asks before moving.
	///     A retry from the app menu has already been asked for, so it passes `false`.
	@MainActor
	public func relocate(askFirst: Bool = true) -> Outcome {
		let bundle: URL = bundleURL()
		let translocated: Bool = Self.isTranslocated(bundle)
		let original: URL = translocated ? (originalURL(bundle) ?? bundle) : bundle
		let volume: URL? = diskImageVolume(original)
		guard volume != nil || translocated
		else { return .notNeeded }

		let name: String = original.lastPathComponent
		let system: URL = Self.systemApplicationsDirectory.appending(path: name, directoryHint: .isDirectory)
		let user: URL = userApplicationsDirectory().appending(path: name, directoryHint: .isDirectory)

		// A quarantined copy already in Applications is translocated too; it's where it belongs.
		let parent: URL = original.deletingLastPathComponent().standardizedFileURL
		let isInApplications: Bool = [system, user].contains { destination in
			destination.deletingLastPathComponent().standardizedFileURL == parent
		}
		guard volume != nil || !isInApplications
		else { return .notNeeded }

		// From a disk image Arx moves without asking; from anywhere else it asks.
		if volume == nil, askFirst {
			guard !isPromptSuppressed()
			else { return .declined }

			switch prompt() {
			case .move: break
			case .notNow: return .declined
			case .neverAsk:
				suppressPrompt()
				return .declined
			}
		}

		for destination in [system, user] where fileExists(destination) {
			if activateRunningCopy(destination) {
				return .activatedRunningCopy(destination)
			}
		}

		do {
			let destination: URL = try install(from: bundle, system: system, user: user)
			try relaunch(destination, volume)

			// Moving, not copying: the copy in Downloads goes once the new one is in place.
			if volume == nil, !Self.isTranslocated(original) {
				trashOriginal(original)
			}
			return .moved(destination)
		} catch {
			reportFailure(error)
			return .failed
		}
	}

	/// Installs into `/Applications`, asking for an administrator password when it isn't
	/// writable, and falls back to `~/Applications` when that prompt is declined.
	@MainActor
	private func install(
		from source: URL,
		system: URL,
		user: URL
	) throws -> URL {
		let privileged: Bool =
			!isWritable(Self.systemApplicationsDirectory)
			|| (fileExists(system) && !isWritable(system))

		do {
			try install(.init(source: source, destination: system, privileged: privileged))
			return system
		} catch Failure.authorizationDeclined {
			try install(.init(source: source, destination: user, privileged: false))
			return user
		}
	}
}

// MARK: - Dependency

extension AppRelocationClient: DependencyKey {
	public static var liveValue: Self { .live }
	public static var testValue: Self { .init() }
	public static var previewValue: Self { .init() }
}

extension DependencyValues {
	public var appRelocation: AppRelocationClient {
		get { self[AppRelocationClient.self] }
		set { self[AppRelocationClient.self] = newValue }
	}
}
