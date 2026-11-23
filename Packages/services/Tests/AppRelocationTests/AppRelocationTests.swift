import AppRelocationClient
import CustomDump
import Foundation
import Testing
import _TestSupport

@MainActor
internal struct AppRelocationTests {
	private static let diskImage: URL = URL(filePath: "/Volumes/Arx", directoryHint: .isDirectory)
	private static let onDiskImage: URL = diskImage.appending(path: "Arx.app", directoryHint: .isDirectory)
	private static let translocated: URL = URL(
		filePath: "/private/var/folders/xy/T/AppTranslocation/5A1B/d/Arx.app",
		directoryHint: .isDirectory
	)
	private static let downloads: URL = URL(filePath: "/Users/me/Downloads/Arx.app", directoryHint: .isDirectory)
	private static let system: URL = URL(filePath: "/Applications/Arx.app", directoryHint: .isDirectory)
	private static let userDirectory: URL = URL(filePath: "/Users/me/Applications", directoryHint: .isDirectory)
	private static let user: URL = userDirectory.appending(path: "Arx.app", directoryHint: .isDirectory)

	// MARK: - Where Arx runs

	@Test
	internal func movesFromDiskImageWithoutAskingAndEjectsIt() {
		let world: World = .init(bundle: Self.onDiskImage)
		world.diskImages = [Self.onDiskImage: Self.diskImage]

		#expect(world.client.relocate() == .moved(Self.system))
		#expect(world.prompts == 0)
		expectNoDifference(world.installations, [.init(source: Self.onDiskImage, destination: Self.system, privileged: false)])
		#expect(world.relaunches.count == 1)
		#expect(world.relaunches.first?.destination == Self.system)
		#expect(world.relaunches.first?.volume == Self.diskImage)
	}

	@Test
	internal func translocatedFromDiskImageUsesTheOriginalVolume() {
		let world: World = .init(bundle: Self.translocated)
		world.originals = [Self.translocated: Self.onDiskImage]
		world.diskImages = [Self.onDiskImage: Self.diskImage]

		#expect(world.client.relocate() == .moved(Self.system))
		#expect(world.prompts == 0)
		#expect(world.installations.first?.source == Self.translocated)
		#expect(world.relaunches.first?.volume == Self.diskImage)
	}

	@Test
	internal func translocatedFromDownloadsAsksBeforeMoving() {
		let world: World = .init(bundle: Self.translocated)
		world.originals = [Self.translocated: Self.downloads]
		world.answer = .move

		#expect(world.client.relocate() == .moved(Self.system))
		#expect(world.prompts == 1)
		#expect(world.relaunches.first?.volume == nil)
		#expect(world.trashed == [Self.downloads])
	}

	@Test
	internal func diskImageCopyIsNeverTrashed() {
		let world: World = .init(bundle: Self.translocated)
		world.originals = [Self.translocated: Self.onDiskImage]
		world.diskImages = [Self.onDiskImage: Self.diskImage]

		#expect(world.client.relocate() == .moved(Self.system))
		#expect(world.trashed.isEmpty)
	}

	@Test
	internal func unresolvedTranslocationIsNeverTrashed() {
		let world: World = .init(bundle: Self.translocated)
		world.answer = .move

		#expect(world.client.relocate() == .moved(Self.system))
		#expect(world.trashed.isEmpty)
	}

	@Test
	internal func translocatedCopyAlreadyInApplicationsStays() {
		for original in [Self.system, Self.user] {
			let world: World = .init(bundle: Self.translocated)
			world.originals = [Self.translocated: original]
			world.answer = .move

			#expect(world.client.relocate() == .notNeeded)
			#expect(world.prompts == 0)
			#expect(world.installations.isEmpty)
			#expect(world.trashed.isEmpty)
		}
	}

	@Test
	internal func failedMoveKeepsTheOriginal() {
		let world: World = .init(bundle: Self.translocated)
		world.originals = [Self.translocated: Self.downloads]
		world.answer = .move
		world.installFailures = [Self.system: .copyFailed("Disk full.")]

		#expect(world.client.relocate() == .failed)
		#expect(world.trashed.isEmpty)
	}

	@Test
	internal func notNowKeepsRunningAndAsksNextTime() {
		let world: World = .init(bundle: Self.translocated)
		world.answer = .notNow

		#expect(world.client.relocate() == .declined)
		#expect(world.installations.isEmpty)
		#expect(!world.suppressed)
	}

	@Test
	internal func dontAskAgainIsRemembered() {
		let world: World = .init(bundle: Self.translocated)
		world.answer = .neverAsk

		#expect(world.client.relocate() == .declined)
		#expect(world.suppressed)
		#expect(world.client.relocate() == .declined)
		#expect(world.prompts == 1)
		#expect(world.installations.isEmpty)
	}

	@Test
	internal func retryFromTheMenuDoesNotAskAgain() {
		let world: World = .init(bundle: Self.translocated)
		world.suppressed = true

		#expect(world.client.relocate(askFirst: false) == .moved(Self.system))
		#expect(world.prompts == 0)
	}

	@Test
	internal func alreadyInApplicationsOrElsewhereStays() {
		for bundle in [Self.system, Self.user, Self.downloads] {
			let world: World = .init(bundle: bundle)

			#expect(world.client.relocate() == .notNeeded)
			#expect(world.prompts == 0)
			#expect(world.installations.isEmpty)
		}
	}

	// MARK: - Existing copies

	@Test
	internal func olderCopyIsReplacedByTheInstallStep() {
		let world: World = .init(bundle: Self.onDiskImage)
		world.diskImages = [Self.onDiskImage: Self.diskImage]
		world.existing = [Self.system]
		world.writable = [AppRelocationClient.systemApplicationsDirectory, Self.system]

		#expect(world.client.relocate() == .moved(Self.system))
		expectNoDifference(world.installations, [.init(source: Self.onDiskImage, destination: Self.system, privileged: false)])
	}

	@Test
	internal func olderCopyOwnedByAnotherUserNeedsAnAdministrator() {
		let world: World = .init(bundle: Self.onDiskImage)
		world.diskImages = [Self.onDiskImage: Self.diskImage]
		world.existing = [Self.system]
		world.writable = [AppRelocationClient.systemApplicationsDirectory]

		#expect(world.client.relocate() == .moved(Self.system))
		#expect(world.installations.first?.privileged == true)
	}

	@Test
	internal func runningCopyIsBroughtForwardWithoutReplacingIt() {
		for running in [Self.system, Self.user] {
			let world: World = .init(bundle: Self.onDiskImage)
			world.diskImages = [Self.onDiskImage: Self.diskImage]
			world.existing = [running]
			world.running = [running]

			#expect(world.client.relocate() == .activatedRunningCopy(running))
			#expect(world.installations.isEmpty)
			#expect(world.relaunches.isEmpty)
		}
	}

	// MARK: - Destination

	@Test
	internal func unwritableApplicationsAsksForAnAdministrator() {
		let world: World = .init(bundle: Self.onDiskImage)
		world.diskImages = [Self.onDiskImage: Self.diskImage]
		world.writable = []

		#expect(world.client.relocate() == .moved(Self.system))
		expectNoDifference(world.installations, [.init(source: Self.onDiskImage, destination: Self.system, privileged: true)])
	}

	@Test
	internal func declinedAdministratorPromptFallsBackToUserApplications() {
		let world: World = .init(bundle: Self.onDiskImage)
		world.diskImages = [Self.onDiskImage: Self.diskImage]
		world.writable = []
		world.installFailures = [Self.system: .authorizationDeclined]

		#expect(world.client.relocate() == .moved(Self.user))
		expectNoDifference(world.installations, [
			.init(source: Self.onDiskImage, destination: Self.system, privileged: true),
			.init(source: Self.onDiskImage, destination: Self.user, privileged: false),
		])
		#expect(world.relaunches.first?.destination == Self.user)
		#expect(world.failures.isEmpty)
	}

	// MARK: - Failures

	@Test
	internal func failedCopyKeepsRunningAndExplains() {
		let world: World = .init(bundle: Self.onDiskImage)
		world.diskImages = [Self.onDiskImage: Self.diskImage]
		world.installFailures = [Self.system: .copyFailed("Disk full.")]

		#expect(world.client.relocate() == .failed)
		#expect(world.relaunches.isEmpty)
		#expect(world.failures == [.copyFailed("Disk full.")])
	}

	@Test
	internal func failedFallbackCopyKeepsRunningAndExplains() {
		let world: World = .init(bundle: Self.onDiskImage)
		world.diskImages = [Self.onDiskImage: Self.diskImage]
		world.writable = []
		world.installFailures = [
			Self.system: .authorizationDeclined,
			Self.user: .copyFailed("Read-only."),
		]

		#expect(world.client.relocate() == .failed)
		#expect(world.failures == [.copyFailed("Read-only.")])
	}

	@Test
	internal func failedRelaunchKeepsRunningAndExplains() {
		let world: World = .init(bundle: Self.onDiskImage)
		world.diskImages = [Self.onDiskImage: Self.diskImage]
		world.relaunchFailure = .relaunchFailed("No shell.")

		#expect(world.client.relocate() == .failed)
		#expect(world.failures == [.relaunchFailed("No shell.")])
	}

	// MARK: - When it runs

	@Test
	internal func automatedAndOptedOutLaunchesNeverRelocate() {
		let arguments: [String] = ["/Applications/Arx.app/Contents/MacOS/Arx"]
		#expect(AppRelocationClient.isEnabled(environment: [:], arguments: arguments))

		for key in [
			"ARX_SKIP_RELOCATION",
			"ARX_ENGINE_PROFILE",
			"XCTestConfigurationFilePath",
			"XCTestBundlePath",
			"XCTestSessionIdentifier",
		] {
			#expect(!AppRelocationClient.isEnabled(environment: [key: "1"], arguments: arguments), "\(key)")
		}
		#expect(!AppRelocationClient.isEnabled(environment: [:], arguments: arguments + ["--headless"]))
		#expect(!AppRelocationClient.isEnabled(environment: [:], arguments: arguments + ["--arx-external-consent-smoke-root", "/tmp/x"]))
		#expect(AppRelocationClient.isEnabled(environment: [:], arguments: ["--headless"]))
	}

	@Test
	internal func translocationIsRecognizedByPath() {
		#expect(AppRelocationClient.isTranslocated(Self.translocated))
		#expect(!AppRelocationClient.isTranslocated(Self.downloads))
	}
}

// MARK: - Doubles

/// A file system and person for the client's closures, recording what it was asked to do.
@MainActor
private final class World {
	internal struct Relaunch: Equatable {
		internal var destination: URL
		internal var volume: URL?
	}

	internal var bundle: URL
	internal var originals: [URL: URL] = [:]
	internal var diskImages: [URL: URL] = [:]
	internal var writable: Set<URL> = [AppRelocationClient.systemApplicationsDirectory]
	internal var existing: Set<URL> = []
	internal var running: Set<URL> = []
	internal var answer: AppRelocationClient.PromptAnswer = .notNow
	internal var suppressed: Bool = false
	internal var installFailures: [URL: AppRelocationClient.Failure] = [:]
	internal var relaunchFailure: AppRelocationClient.Failure?

	internal var prompts: Int = 0
	internal var installations: [AppRelocationClient.Installation] = []
	internal var relaunches: [Relaunch] = []
	internal var failures: [AppRelocationClient.Failure] = []
	internal var trashed: [URL] = []

	internal init(bundle: URL) {
		self.bundle = bundle
	}

	internal var client: AppRelocationClient {
		.init(
			bundleURL: { self.bundle },
			originalURL: { self.originals[$0] },
			diskImageVolume: { self.diskImages[$0] },
			userApplicationsDirectory: { AppRelocationTests.userApplicationsDirectory },
			isWritable: { self.writable.contains($0) },
			fileExists: { self.existing.contains($0) },
			activateRunningCopy: { self.running.contains($0) },
			isPromptSuppressed: { self.suppressed },
			suppressPrompt: { self.suppressed = true },
			prompt: {
				self.prompts += 1
				return self.answer
			},
			install: { installation in
				self.installations.append(installation)
				if let failure = self.installFailures[installation.destination] {
					throw failure
				}
			},
			relaunch: { destination, volume in
				self.relaunches.append(.init(destination: destination, volume: volume))
				if let failure = self.relaunchFailure {
					throw failure
				}
			},
			trashOriginal: { self.trashed.append($0) },
			reportFailure: { error in
				self.failures.append(error as? AppRelocationClient.Failure ?? .unavailable)
			}
		)
	}
}

extension AppRelocationTests {
	fileprivate static var userApplicationsDirectory: URL { userDirectory }
}
