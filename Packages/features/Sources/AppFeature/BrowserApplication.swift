import AppKit
import AppUI
import AppUpdaterClient
import BrowserCore
import ChromiumEngine
import DiagnosticsClient
import _Dependencies

public enum BrowserApplication {
	/// The process's first step. Chromium's allocator registers its zone only while the main
	/// thread is the only one, and installing dependencies or touching Foundation can start
	/// dispatch's worker threads, so `Application.run()` calls this before anything else.
	/// A failure has already been written to standard error.
	@MainActor
	public static func prepareAllocator() {
		#if DEBUG
		ChromiumRuntime.reportBootstrapEntryForSmoke()
		#endif
		guard ChromiumRuntime.prepareHostAllocator() else { exit(1) }
	}

	@MainActor
	public static func main() {
		LaunchSignposts.processStarted()
		#if DEBUG
		if let code = CloudKitProbe.runIfRequested(arguments: CommandLine.arguments) {
			exit(code)
		}
		#endif
		// Prepared in prepareAllocator(); this checks the zone is still the one it registered.
		guard ChromiumRuntime.prepareHostAllocator() else { exit(1) }
		let environment = ProcessInfo.processInfo.environment
		let headlessConfiguration: HeadlessConfiguration?
		do throws(HeadlessFailure) {
			headlessConfiguration = try HeadlessConfiguration.parse(arguments: CommandLine.arguments)
		} catch {
			HeadlessOutput.emit(error)
			exit(error.exitCode)
		}
		if let headlessConfiguration {
			exit(runHeadless(headlessConfiguration, environment: environment))
		}

		do {
			let mockKeychainForTesting: Bool
			let validatedFixtureProfile: URL?
			#if DEBUG
			let routingFixture = try RoutingSmokeFixture.load(
				environment: environment,
				arguments: CommandLine.arguments,
				application: Bundle.main.bundleURL
			)
			let retirementFixture = try ProfileRetirementSmoke.load(
				environment: environment,
				arguments: CommandLine.arguments,
				application: Bundle.main.bundleURL
			)
			let externalConsentFixture = try ExternalConsentFixture.load(
				environment: environment,
				arguments: CommandLine.arguments,
				application: Bundle.main.bundleURL
			)
			let extensionSettingsFixture = try ExtensionSettingsSmokeFixture.load(
				environment: environment,
				arguments: CommandLine.arguments,
				application: Bundle.main.bundleURL
			)
			validatedFixtureProfile = externalConsentFixture?.profile ?? extensionSettingsFixture?.profile
			try routingFixture?.seedWorkspace()
			try retirementFixture?.seedWorkspace()
			try extensionSettingsFixture?.seedWorkspace()
			if ProfileReleaseSmoke.isRequested(environment: environment) {
				try ProfileReleaseSmoke.seedWorkspace(environment: environment)
			}
			mockKeychainForTesting = routingFixture != nil
			|| retirementFixture != nil
			|| externalConsentFixture != nil
			|| extensionSettingsFixture != nil
			#else
			guard
				environment["ARX_EXTERNAL_CONSENT_FIXTURE_ROOT"] == nil,
				!CommandLine.arguments.contains("--arx-external-consent-smoke-root")
			else { throw LaunchError.unsupportedFixture }

			mockKeychainForTesting = false
			validatedFixtureProfile = nil
			#endif

			guard
				let executable = Bundle.main.executableURL,
				let frameworks = Bundle.main.privateFrameworksURL
			else { throw LaunchError.missingBundle }

			// Chromium must register BrowserCrApplication before AppKit creates its singleton.
			let runtime = try ChromiumRuntime(
				frameworkExecutable: frameworks
					.appendingPathComponent("Arx Framework.framework/Arx Framework")
			)
			let profile = validatedFixtureProfile
			?? environment["ARX_ENGINE_PROFILE"].map(URL.init(fileURLWithPath:))
			?? ArxEdition.current.applicationSupport(home: .homeDirectory).appending(path: "Browser", directoryHint: .isDirectory)
			let canonicalProfile = profile.standardizedFileURL.resolvingSymlinksInPath()
			let window = try BrowserWindow(
				runtime: runtime,
				environment: environment,
				profileDirectory: canonicalProfile
			)

			// Main-thread stalls and MetricKit's hang reports, for Report a Problem (DEV-1010).
			let hangMonitoring = HangMonitoring.start(environment: environment)

			// A run that doesn't reach the end of this function didn't quit (DEV-1018).
			let ledger = CleanQuitLedger.begin(profile: canonicalProfile).ledger

			#if DEBUG
			window.configureRoutingSmoke(routingFixture)
			window.configureRetirementSmoke(retirementFixture)
			window.configureExtensionSettingsSmoke(extensionSettingsFixture)
			#endif

			let result = try {
				defer {
					window.stopCapabilities()
					hangMonitoring.watchdog.stop()
				}

				return try runtime.run(
					executable: executable,
					profileDirectory: window.runtimeProfileDirectory,
					mockKeychainForTesting: mockKeychainForTesting,
					enableExtensions: true,
					profileRetirement: window.profileRetirementConfiguration
				) { _ in
					window.open()
				}
			}()

			// Chromium has stopped. An update that installs on quit waits for the engine's
			// helpers to exit first, so Sparkle never replaces the app under one of them.
			@Dependency(\.appUpdater)
			var updater

			updater.prepareForTermination()
			ledger.end()

			#if DEBUG
			if result == 0, !window.failed {
				try routingFixture?.recordCleanExit()
				try retirementFixture?.recordCleanExit()
				try extensionSettingsFixture?.recordCleanExit()
			}
			#endif
			exit(window.failed ? 1 : result)
		} catch {
			// Startup failing is reported here, not as an unclean exit.
			CleanQuitLedger.current?.end()
			FileHandle.standardError.write(Data("Arx startup failed: \(error)\n".utf8))
			let interactiveFailure: Bool
			#if DEBUG
			interactiveFailure = environment["ARX_ENGINE_SMOKE_TITLE"] == nil
			&& !RoutingSmokeFixture.isRequested(
				environment: environment,
				arguments: CommandLine.arguments
			)
			&& !ProfileRetirementSmoke.isRequested(
				environment: environment,
				arguments: CommandLine.arguments
			)
			&& !ExtensionSettingsSmokeFixture.isRequested(
				environment: environment,
				arguments: CommandLine.arguments
			)
			&& !ExternalConsentFixture.isRequested(
				environment: environment,
				arguments: CommandLine.arguments
			)
			#else
			interactiveFailure = environment["ARX_ENGINE_SMOKE_TITLE"] == nil
			&& environment["ARX_EXTERNAL_CONSENT_FIXTURE_ROOT"] == nil
			&& !CommandLine.arguments.contains("--arx-external-consent-smoke-root")
			#endif
			if interactiveFailure {
				let alert = NSAlert()
				alert.messageText = String.localized(.appUI.startup.failed)
				alert.informativeText = WorkspaceFailurePresentation.message(for: error)
				alert.runModal()
			}
			exit(1)
		}
	}
}

extension BrowserApplication {
	/// `Arx --headless`: the same composition and MCP boundary as an interactive
	/// run, in a transparent host with an isolated or explicitly locked profile.
	/// Protocol events go to stdout; Chromium and Arx diagnostics go to stderr.
	@MainActor
	private static func runHeadless(
		_ configuration: HeadlessConfiguration,
		environment: [String: String]
	) -> Int32 {
		// Read before anything slow: the launcher may exit during startup.
		let launcher = getppid()

		// A launcher that went away closes stdout; report through errors, not SIGPIPE.
		signal(SIGPIPE, SIG_IGN)
		let profile: HeadlessProfile
		do throws(HeadlessFailure) {
			// Before the profile lock and the engine, so a run without a session leaves
			// nothing behind (DEV-596).
			try HeadlessLoginSession.check()
			profile = try HeadlessProfile(persistent: configuration.profile)
		} catch {
			HeadlessOutput.emit(error)
			return error.exitCode
		}
		defer { profile.finish() }

		// Names the phase a slow start is in, on stderr and as `startupSlow`.
		let startup = HeadlessStartup()
		startup.watch()

		do throws(HeadlessFailure) {
			guard
				let executable = Bundle.main.executableURL,
				let frameworks = Bundle.main.privateFrameworksURL,
				let runtime = try? ChromiumRuntime(
					frameworkExecutable: frameworks.appendingPathComponent("Arx Framework.framework/Arx Framework")
				)
			else { throw .startupFailed }
			guard
				runtime.supportsUnattendedRuns,
				(try? runtime.configureUnattended()) != nil
			else { throw .engineUnavailable }

			// A teardown Chromium has to force-exit still reports `stopped` first.
			let shutdown = HeadlessShutdown()
			if runtime.supportsUnattendedShutdown {
				try? runtime.configureUnattendedShutdown(deadline: HeadlessShutdown.deadline) { code in
					shutdown.expired(exitCode: code, exitsItself: true)
				}
			}

			// A display is optional (DEV-865): without one the host goes off-screen
			// and the engine renders at the fixed fallback scale.
			let display = HeadlessDisplay.current()
			setenv(HeadlessDisplay.environmentKey, display.environmentValue, 1)
			FileHandle.standardError.write(Data(
				"ARX_HEADLESS_DISPLAY screen=\(display.hasScreen) scale=\(display.environmentValue)\n".utf8
			))

			let run = HeadlessRun(
				configuration: configuration,
				profile: profile,
				display: display,
				phases: startup,
				lifetime: .current(parent: launcher),
				shutdown: shutdown,
				temporaryGrantWindow: environment["ARX_HEADLESS_GRANT_WINDOW_FOR_TESTING"].flatMap(TimeInterval.init)
			)
			var headlessEnvironment = environment
			headlessEnvironment["ARX_ENGINE_SMOKE_TITLE"] = nil
			let window: BrowserWindow
			do {
				window = try BrowserWindow(
					runtime: runtime,
					environment: headlessEnvironment,
					profileDirectory: profile.profileDirectory,
					headless: run
				)
			} catch {
				throw .startupFailed
			}
			try profile.rejectLiveBrowser(in: [profile.profileDirectory, window.runtimeProfileDirectory])

			let result: Int32
			do {
				defer { window.stopCapabilities() }
				result = try runtime.run(
					executable: executable,
					profileDirectory: window.runtimeProfileDirectory,
					// A disposable profile never needs the login Keychain, so CI never sees
					// its authorization prompt. Persistent profiles keep their real keys.
					mockKeychainForTesting: !profile.isPersistent,
					enableExtensions: true,
					profileRetirement: window.profileRetirementConfiguration
				) { _ in
					startup.enter(.window)
					window.open()
				}
			} catch {
				throw .startupFailed
			}

			let runSucceeded = result == 0 && !window.failed
			let code: Int32 = run.exitCode != 0
			? run.exitCode
			: (runSucceeded ? 0 : HeadlessFailure.startupFailed.exitCode)
			shutdown.finish(exitCode: code, suppressedDialogs: run.suppressedDialogs)
			return code
		} catch {
			HeadlessOutput.emit(error)
			return error.exitCode
		}
	}
}

private enum LaunchError: Error {
	case missingBundle
	case unsupportedFixture
}
