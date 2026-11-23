import AppKit
import BrowserCore
import CustomDump
import Foundation
import Testing

@testable import AppFeature

@Suite(.dependencies, .timeLimit(.minutes(3)))
internal struct HeadlessConfigurationTests {
	@Test
	internal func interactiveLaunchIsNotHeadless() throws {
		#expect(try HeadlessConfiguration.parse(arguments: ["Arx"]) == nil)
		#expect(try HeadlessConfiguration.parse(arguments: ["Arx", "-psn_0_42"]) == nil)
	}

	@Test
	internal func defaultsAreIsolatedReadOnlyAndUnbounded() throws {
		let configuration = try #require(try HeadlessConfiguration.parse(arguments: ["Arx", "--headless"]))
		#expect(configuration.profile == nil)
		#expect(configuration.viewport == NSSize(width: 1280, height: 800))
		#expect(configuration.timeout == nil)
		#expect(configuration.grants == [.read])
		#expect(configuration.configurationFile == nil)
	}

	@Test
	internal func explicitOptionsAreParsed() throws {
		let configuration = try #require(try HeadlessConfiguration.parse(arguments: [
			"Arx", "--headless", "--profile", "/tmp/arx-profile", "--viewport", "800x600",
			"--timeout", "60", "--allow", "read,screenshots,content,manage",
			"--mcp-configuration", "/tmp/arx-mcp.json", "--url", "http://127.0.0.1:8080/",
			"-NSDocumentRevisionsDebugMode", "YES",
		]))
		#expect(configuration.profile?.path == "/tmp/arx-profile")
		#expect(configuration.viewport == NSSize(width: 800, height: 600))
		#expect(configuration.timeout == .seconds(60))
		#expect(configuration.grants == [.read, .screenshots, .content, .manage])
		#expect(configuration.configurationFile?.path == "/tmp/arx-mcp.json")
		#expect(configuration.initialURL?.absoluteString == "http://127.0.0.1:8080/")
	}

	@Test(arguments: [
		["--headless", "--viewport", "100x100"],
		["--headless", "--viewport", "800"],
		["--headless", "--timeout", "5"],
		["--headless", "--timeout", "86401"],
		["--headless", "--timeout", "0"],
		["--headless", "--timeout", "1.5"],
		["--headless", "--timeout", "forever"],
		["--headless", "--allow", "screenshots"],
		["--headless", "--allow", "read,root"],
		["--headless", "--profile", "relative/path"],
		["--headless", "--url", "file:///etc/hosts"],
		["--headless", "--unknown", "1"],
		["--headless", "--timeout"],
		["--headless", "--timeout", "60", "--timeout", "90"],
	])
	internal func invalidOptionsAreUsageErrors(_ options: [String]) {
		#expect {
			_ = try HeadlessConfiguration.parse(arguments: ["Arx"] + options)
		} throws: { error in
			guard case .usage = error as? HeadlessFailure else { return false }
			return true
		}
	}

	@Test(arguments: [10, 300, 86_400])
	internal func timeoutIsAnOptionalCap(_ seconds: Int) throws {
		let configuration = try #require(try HeadlessConfiguration.parse(arguments: [
			"Arx", "--headless", "--timeout", String(seconds),
		]))
		#expect(configuration.timeout == .seconds(seconds))
	}

	@Test
	internal func manageLastsForTheRunOrUntilItsTimeout() {
		let deadline = Date(timeIntervalSince1970: 3_700)
		#expect(HeadlessRun.manageGrantExpiry(grants: [.read], deadline: nil) == nil)
		#expect(HeadlessRun.manageGrantExpiry(grants: [.read], deadline: deadline) == nil)
		#expect(HeadlessRun.manageGrantExpiry(grants: [.read, .manage], deadline: nil) == .distantFuture)
		#expect(HeadlessRun.manageGrantExpiry(grants: [.read, .manage], deadline: deadline) == deadline)
	}

	@Test
	internal func failuresHaveStableCodesAndExitStatuses() {
		let failures: [HeadlessFailure] = [
			.usage(""),
			.engineUnavailable,
			.automationUnavailable,
			.startupFailed,
			.loginSessionUnavailable,
			.profileInUse,
			.profileUnavailable,
			.timedOut,
			.shutdownHung,
		]
		expectNoDifference(
			failures.map { "\($0.code)=\($0.exitCode)" },
			[
				"usage=64",
				"engineUnavailable=69",
				"automationUnavailable=69",
				"startupFailed=70",
				"startupFailed=70",
				"profileInUse=73",
				"profileUnavailable=73",
				"timedOut=75",
				"shutdownHung=2",
			]
		)
	}

	@Test
	internal func rendererFailuresAreReportedOncePerFailure() async throws {
		let crashed = BrowserCore.Tab.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
		let healthy = BrowserCore.Tab.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
		func snapshot(_ errorCode: Int?) -> BrowserSessionSnapshot {
			.init(navigation: .init(errorCode: errorCode), revision: 1)
		}

		let first = HeadlessRun.rendererFailures(
			[crashed: snapshot(BrowserNavigation.Failure.rendererStoppedCode), healthy: snapshot(-105)],
			previouslyFailed: []
		)
		expectNoDifference(first.failed, [crashed])
		expectNoDifference(first.reported, [crashed])

		let unchanged = HeadlessRun.rendererFailures(
			[crashed: snapshot(BrowserNavigation.Failure.rendererStoppedCode)],
			previouslyFailed: first.failed
		)
		expectNoDifference(unchanged.reported, [])

		let recovered = HeadlessRun.rendererFailures([crashed: snapshot(nil)], previouslyFailed: unchanged.failed)
		expectNoDifference(recovered.failed, [])

		let again = HeadlessRun.rendererFailures(
			[crashed: snapshot(BrowserNavigation.Failure.rendererStoppedCode)],
			previouslyFailed: recovered.failed
		)
		expectNoDifference(again.reported, [crashed])
	}

	@Test
	internal func cancelledAuthenticationIsReportedOncePerDocument() {
		let challenged = BrowserCore.Tab.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
		let healthy = BrowserCore.Tab.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
		func snapshot(_ cancelled: Bool) -> BrowserSessionSnapshot {
			.init(navigation: .init(authenticationCancelled: cancelled), revision: 1)
		}

		let first = HeadlessRun.authenticationRequirements(
			[challenged: snapshot(true), healthy: snapshot(false)],
			previouslyRequired: []
		)
		expectNoDifference(first.reported, [challenged])

		let unchanged = HeadlessRun.authenticationRequirements(
			[challenged: snapshot(true)],
			previouslyRequired: first.failed
		)
		expectNoDifference(unchanged.reported, [])

		let navigated = HeadlessRun.authenticationRequirements([challenged: snapshot(false)], previouslyRequired: unchanged.failed)
		expectNoDifference(navigated.failed, [])

		let again = HeadlessRun.authenticationRequirements([challenged: snapshot(true)], previouslyRequired: navigated.failed)
		expectNoDifference(again.reported, [challenged])
	}

	@Test
	internal func refusedSignInPromptsAreReportedOncePerDocument() {
		let prompted = BrowserCore.Tab.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
		let healthy = BrowserCore.Tab.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
		func snapshot(_ prompts: BrowserNavigation.SignInPrompts) -> BrowserSessionSnapshot {
			.init(navigation: .init(cancelledSignInPrompts: prompts), revision: 1)
		}

		let first = HeadlessRun.signInRequirements(
			[prompted: snapshot(.webAuthentication), healthy: snapshot([])],
			previouslyRequired: []
		)
		expectNoDifference(first.reported, [prompted])

		// A second kind of prompt in the same document is not a new event.
		let unchanged = HeadlessRun.signInRequirements(
			[prompted: snapshot([.webAuthentication, .federatedSignIn])],
			previouslyRequired: first.failed
		)
		expectNoDifference(unchanged.reported, [])

		let navigated = HeadlessRun.signInRequirements([prompted: snapshot([])], previouslyRequired: unchanged.failed)
		expectNoDifference(navigated.failed, [])

		let again = HeadlessRun.signInRequirements([prompted: snapshot(.federatedSignIn)], previouslyRequired: navigated.failed)
		expectNoDifference(again.reported, [prompted])
		expectNoDifference(HeadlessRun.promptNames([.federatedSignIn, .webAuthentication]), ["webAuthentication", "federatedSignIn"])
	}

	@Test
	internal func refusedSignInPromptsRequireUserAction() {
		#expect(!BrowserNavigation().requiresUserAction)
		#expect(BrowserNavigation(authenticationCancelled: true).requiresUserAction)
		#expect(BrowserNavigation(cancelledSignInPrompts: .webAuthentication).requiresUserAction)
		#expect(BrowserNavigation(cancelledSignInPrompts: .federatedSignIn).requiresUserAction)
	}

	@Test
	internal func normalShutdownReportsStoppedOnce() {
		let exits = ExitCodes()
		let shutdown = HeadlessShutdown(deadline: .seconds(60), exit: { exits.append($0) })
		shutdown.begin(suppressedDialogs: 2)
		#expect(shutdown.finish(exitCode: 0, suppressedDialogs: 2))
		#expect(!shutdown.finish(exitCode: 0, suppressedDialogs: 2))
		// Chromium's watchdog after a reported stop changes nothing.
		shutdown.expired(exitCode: 2, exitsItself: true)
		#expect(exits.values.isEmpty)
	}

	@Test
	internal func expiredShutdownReportsBeforeExitAndSuppressesTheLateStop() {
		let exits = ExitCodes()
		let shutdown = HeadlessShutdown(deadline: .seconds(60), exit: { exits.append($0) })
		shutdown.begin(suppressedDialogs: 0)
		shutdown.expired(exitCode: 2, exitsItself: true)
		#expect(exits.values.isEmpty)
		#expect(!shutdown.finish(exitCode: 0, suppressedDialogs: 0))
	}

	@Test
	internal func hungShutdownIsForcedByItsOwnWatchdog() async throws {
		let exits = ExitCodes()
		let shutdown = HeadlessShutdown(
			deadline: .milliseconds(100),
			grace: .milliseconds(100),
			slow: .milliseconds(50),
			exit: { exits.append($0) }
		)
		shutdown.begin(suppressedDialogs: 0)

		// However long a loaded machine takes to run the watchdog; the suite's limit catches none.
		while exits.values.isEmpty {
			try await Task.sleep(for: .milliseconds(20))
		}
		expectNoDifference(exits.values, [HeadlessFailure.shutdownHung.exitCode])
		#expect(!shutdown.finish(exitCode: 0, suppressedDialogs: 0))
	}

	@Test
	internal func persistentProfileIsExclusive() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arx-headless-test-" + UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let first = try HeadlessProfile(persistent: directory)
		#expect(first.isPersistent)
		#expect(throws: HeadlessFailure.profileInUse) { _ = try HeadlessProfile(persistent: directory) }
		first.finish()
		let second = try HeadlessProfile(persistent: directory)
		second.finish()
		#expect(FileManager.default.fileExists(atPath: directory.path))
	}

	@Test
	internal func liveChromiumLockRejectsTheProfile() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arx-headless-test-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		var host = [CChar](repeating: 0, count: 256)
		gethostname(&host, host.count)
		let hostName = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
		let link = directory.appendingPathComponent("SingletonLock").path
		try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: hostName + "-\(getpid())")
		#expect(HeadlessProfile.hasLiveSingleton(in: directory))
		#expect(throws: HeadlessFailure.profileInUse) { _ = try HeadlessProfile(persistent: directory) }

		try FileManager.default.removeItem(atPath: link)
		try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: hostName + "-999999")
		#expect(!HeadlessProfile.hasLiveSingleton(in: directory))
	}

	@Test
	internal func isolatedProfileIsPrivateAndRemoved() throws {
		let profile = try HeadlessProfile(persistent: nil)
		let attributes = try FileManager.default.attributesOfItem(atPath: profile.runDirectory.path)
		#expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
		#expect(profile.profileDirectory.path.hasPrefix(profile.runDirectory.path))
		profile.finish()
		#expect(!FileManager.default.fileExists(atPath: profile.runDirectory.path))
	}
}

@Suite(.dependencies, .timeLimit(.minutes(3)))
@MainActor
internal struct HeadlessLifetimeTests {
	@Test
	internal func launchdIsNotALauncher() {
		#expect(HeadlessLifetime.watchedParent(1) == nil)
		#expect(HeadlessLifetime.watchedParent(0) == nil)
		#expect(HeadlessLifetime.watchedParent(4242) == 4242)
	}

	@Test
	internal func onlyPipesAndSocketsAreWatchedForEndOfInput() throws {
		let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
		defer { close(null) }
		#expect(!HeadlessLifetime.watchesInput(null))

		var pipeDescriptors: [Int32] = [0, 0]
		#expect(pipe(&pipeDescriptors) == 0)
		defer { pipeDescriptors.forEach { close($0) } }
		#expect(HeadlessLifetime.watchesInput(pipeDescriptors[0]))

		var socketDescriptors: [Int32] = [0, 0]
		#expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &socketDescriptors) == 0)
		defer { socketDescriptors.forEach { close($0) } }
		#expect(HeadlessLifetime.watchesInput(socketDescriptors[0]))

		let file = FileManager.default.temporaryDirectory.appendingPathComponent("arx-lifetime-" + UUID().uuidString)
		try Data().write(to: file)
		defer { try? FileManager.default.removeItem(at: file) }
		let regular = open(file.path, O_RDONLY | O_CLOEXEC)
		defer { close(regular) }
		#expect(!HeadlessLifetime.watchesInput(regular))
		#expect(!HeadlessLifetime.watchesInput(-1))
	}

	@Test
	internal func inputIsIgnoredUntilItCloses() async throws {
		var descriptors: [Int32] = [0, 0]
		#expect(pipe(&descriptors) == 0)
		defer { close(descriptors[0]) }
		let lifetime = HeadlessLifetime(parent: nil, input: descriptors[0])
		var endings: [HeadlessLifetime.Ending] = []
		lifetime.start { endings.append($0) }

		#expect(write(descriptors[1], "keep running\n", 13) == 13)
		try await Task.sleep(for: .milliseconds(200))
		expectNoDifference(endings, [])

		close(descriptors[1])
		try await eventually { !endings.isEmpty }
		try await Task.sleep(for: .milliseconds(100))
		expectNoDifference(endings, [.inputClosed])
	}

	@Test
	internal func launcherExitEndsTheRun() async throws {
		let launcher = Process()
		launcher.executableURL = URL(fileURLWithPath: "/bin/sleep")
		launcher.arguments = ["600"]
		try launcher.run()
		defer { if launcher.isRunning { launcher.terminate() } }

		let lifetime = HeadlessLifetime(parent: launcher.processIdentifier, input: nil)
		var endings: [HeadlessLifetime.Ending] = []
		lifetime.start { endings.append($0) }
		try await Task.sleep(for: .milliseconds(200))
		expectNoDifference(endings, [])

		launcher.terminate()
		try await eventually { !endings.isEmpty }
		expectNoDifference(endings, [.parentExited])
	}

	@Test
	internal func aLauncherThatAlreadyExitedEndsTheRunAtOnce() async throws {
		let launcher = Process()
		launcher.executableURL = URL(fileURLWithPath: "/usr/bin/true")
		try launcher.run()
		launcher.waitUntilExit()

		let lifetime = HeadlessLifetime(parent: launcher.processIdentifier, input: nil)
		var endings: [HeadlessLifetime.Ending] = []
		lifetime.start { endings.append($0) }
		expectNoDifference(endings, [.parentExited])
	}

	@Test
	internal func launcherChainLeadersAreWatchedBesideTheParent() {
		typealias Leader = HeadlessLifetime.Leader

		// npx → node → Arx: npx leads the group, the agent's shell leads the session.
		expectNoDifference(
			HeadlessLifetime.watchedLeaders(process: 30, parent: 20, group: 10, session: 5),
			[Leader(kind: .group, pid: 10), Leader(kind: .session, pid: 5)]
		)

		// A launcher started with setsid leads both; it is watched once.
		expectNoDifference(
			HeadlessLifetime.watchedLeaders(process: 30, parent: 20, group: 10, session: 10),
			[Leader(kind: .group, pid: 10)]
		)

		// The direct parent is already watched as the parent.
		expectNoDifference(
			HeadlessLifetime.watchedLeaders(process: 30, parent: 20, group: 20, session: 5),
			[Leader(kind: .session, pid: 5)]
		)

		// A run that leads its own group and session, or one under launchd, watches no leader.
		expectNoDifference(HeadlessLifetime.watchedLeaders(process: 30, parent: 20, group: 30, session: 30), [])
		expectNoDifference(HeadlessLifetime.watchedLeaders(process: 30, parent: 1, group: 1, session: 1), [])
		expectNoDifference(HeadlessLifetime.watchedLeaders(process: 30, parent: 20, group: -1, session: 0), [])
	}

	@Test
	internal func onlyALiveLeaderStillLeads() throws {
		#expect(HeadlessLifetime.stillLeads(.init(kind: .session, pid: getsid(0))))
		#expect(HeadlessLifetime.stillLeads(.init(kind: .group, pid: getpgrp())))
		#expect(HeadlessLifetime.stillLeads(.init(kind: .group, pid: getpid())) == (getpgrp() == getpid()))

		let exited = Process()
		exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
		try exited.run()
		exited.waitUntilExit()
		#expect(!HeadlessLifetime.stillLeads(.init(kind: .group, pid: exited.processIdentifier)))
		#expect(!HeadlessLifetime.stillLeads(.init(kind: .session, pid: exited.processIdentifier)))
	}

	@Test
	internal func outerLauncherExitEndsTheRunWhileTheParentLives() async throws {
		// Both stand-ins outlive any test run; a loaded full run took 40 s, past an earlier 30 s sleep.
		let parent = Process()
		parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
		parent.arguments = ["600"]
		try parent.run()
		defer { if parent.isRunning { parent.terminate() } }
		let outer = Process()
		outer.executableURL = URL(fileURLWithPath: "/bin/sleep")
		outer.arguments = ["600"]
		try outer.run()
		defer { if outer.isRunning { outer.terminate() } }

		let lifetime = HeadlessLifetime(
			parent: parent.processIdentifier,
			leaders: [.init(kind: .group, pid: outer.processIdentifier)],
			input: nil
		)
		var endings: [HeadlessLifetime.Ending] = []
		lifetime.start { endings.append($0) }
		try await Task.sleep(for: .milliseconds(200))
		expectNoDifference(endings, [])

		outer.terminate()
		try await eventually { !endings.isEmpty }
		try await Task.sleep(for: .milliseconds(100))
		expectNoDifference(endings, [.launcherExited])
		#expect(parent.isRunning)
	}

	@Test
	internal func aLeaderThatAlreadyExitedEndsTheRunAtOnce() async throws {
		let outer = Process()
		outer.executableURL = URL(fileURLWithPath: "/usr/bin/true")
		try outer.run()
		outer.waitUntilExit()

		let lifetime = HeadlessLifetime(parent: nil, leaders: [.init(kind: .session, pid: outer.processIdentifier)], input: nil)
		var endings: [HeadlessLifetime.Ending] = []
		lifetime.start { endings.append($0) }
		expectNoDifference(endings, [.launcherExited])
	}

	@Test
	internal func cancelledLifetimeNeverEnds() async throws {
		var descriptors: [Int32] = [0, 0]
		#expect(pipe(&descriptors) == 0)
		defer { close(descriptors[0]) }
		let lifetime = HeadlessLifetime(parent: nil, input: descriptors[0])
		var endings: [HeadlessLifetime.Ending] = []
		lifetime.start { endings.append($0) }
		lifetime.cancel()
		close(descriptors[1])
		try await Task.sleep(for: .milliseconds(200))
		expectNoDifference(endings, [])
	}

	/// Waits for an ending however long the system takes to deliver it: a process exit or an
	/// end of input under load can take seconds. The suite's time limit catches one that never
	/// comes; no wall-clock bound here can tell a slow machine from a missing event.
	private func eventually(_ condition: @MainActor () -> Bool) async throws {
		while !condition() {
			try await Task.sleep(for: .milliseconds(20))
		}
	}
}

private final class ExitCodes: @unchecked Sendable {
	private let lock = NSLock()
	private var codes: [Int32] = []

	var values: [Int32] { lock.withLock { codes } }

	func append(_ code: Int32) {
		lock.withLock { codes.append(code) }
	}
}
