import AppKit
import BrowserCore
import Darwin
import Foundation
import _ComposableArchitecture

/// Drives one unattended run: it creates the run's own MCP client with the grants
/// named on the command line, publishes readiness, and stops on SIGTERM/SIGINT, when
/// its launcher goes away (see `HeadlessLifetime`), or at the optional `--timeout`
/// deadline. It never approves anything beyond those grants.
@MainActor
internal final class HeadlessRun {
	internal enum StopReason: String {
		case signal
		case timeout
		case failure
		case parentExited
		case launcherExited
		case inputClosed
	}

	internal static let clientName: String = "Arx headless run"

	internal let configuration: HeadlessConfiguration
	internal let profile: HeadlessProfile

	/// The host's place and the pages' device scale, fixed at startup (DEV-865).
	internal let display: HeadlessDisplay

	/// The way to `ready`, for `startupSlow` diagnostics.
	internal let phases: HeadlessStartup
	internal let lifetime: HeadlessLifetime
	internal let shutdown: HeadlessShutdown

	/// Test-only: a shorter temporary mutation grant window, in seconds.
	internal let temporaryGrantWindow: TimeInterval?

	/// When the run's grants end: its `--timeout` deadline, or nil until it is stopped.
	internal private(set) var grantsExpireAt: Date?
	internal private(set) var exitCode: Int32 = 0
	internal private(set) var suppressedDialogs: UInt64 = 0
	private var signals: [DispatchSourceSignal] = []
	private var deadline: Task<Void, Never>?
	private var startup: Task<Void, Never>?
	private var stopping: Bool = false
	private var failedRenderers: Set<BrowserCore.Tab.ID> = []
	private var cancelledAuthentications: Set<BrowserCore.Tab.ID> = []
	private var refusedSignIns: Set<BrowserCore.Tab.ID> = []
	private var stop: @MainActor (StopReason) -> Void = { _ in }

	internal init(
		configuration: HeadlessConfiguration,
		profile: HeadlessProfile,
		display: HeadlessDisplay,
		phases: HeadlessStartup = .init(),
		lifetime: HeadlessLifetime,
		shutdown: HeadlessShutdown = .init(),
		temporaryGrantWindow: TimeInterval? = nil
	) {
		self.configuration = configuration
		self.profile = profile
		self.display = display
		self.phases = phases
		self.lifetime = lifetime
		self.shutdown = shutdown
		self.temporaryGrantWindow = temporaryGrantWindow
	}

	/// The run's own `manage` expiry: its deadline, or unbounded without `--timeout`.
	/// Revoking the client at stop ends it either way.
	internal nonisolated static func manageGrantExpiry(
		grants: Set<HeadlessConfiguration.Grant>,
		deadline: Date?
	) -> Date? {
		guard grants.contains(.manage) else { return nil }
		return deadline ?? .distantFuture
	}

	/// Whole profiles, so every space of the run's profiles is granted, including spaces that
	/// appear while the run lasts (DEV-865), with their folders, tabs and Favorites.
	internal nonisolated static func scopes(for organization: BrowserOrganization) -> [AutomationScope] {
		organization.profiles.map { .profile($0.id) }
	}

	internal var configurationFile: URL {
		configuration.configurationFile ?? profile.runDirectory.appendingPathComponent("mcp.json")
	}

	internal func start(
		store: StoreOf<AppFeature>,
		dialogs: @escaping @MainActor () -> UInt64,
		stop: @escaping @MainActor (StopReason) -> Void
	) {
		self.stop = { [weak self] reason in
			guard let self, !stopping else { return }
			stopping = true
			phases.enter(.stopping)
			suppressedDialogs = dialogs()
			deadline?.cancel()
			startup?.cancel()
			lifetime.cancel()
			for source in signals { source.cancel() }
			HeadlessOutput.emit("stopping", ["reason": reason.rawValue])

			// From here on the run always ends with `stopped`, or a diagnostic
			// and `stopped` if shutdown hangs.
			shutdown.begin(suppressedDialogs: suppressedDialogs)
			stop(reason)
		}
		installSignals()
		if let timeout = configuration.timeout {
			grantsExpireAt = Date().addingTimeInterval(Double(timeout.components.seconds))
			deadline = Task { [weak self] in
				do {
					try await Task.sleep(for: timeout)
				} catch {
					return
				}
				guard let self else { return }
				fail(.timedOut)
			}
		}
		lifetime.start { [weak self] ending in
			switch ending {
			case .parentExited: self?.stop(.parentExited)
			case .launcherExited: self?.stop(.launcherExited)
			case .inputClosed: self?.stop(.inputClosed)
			}
		}
		startup = Task { [weak self] in
			guard let self else { return }
			do throws(HeadlessFailure) {
				try await prepareAutomation(store: store)
			} catch {
				fail(error)
			}
		}
	}

	internal func requestStop() { stop(.signal) }

	/// Emits `rendererFailed` once each time a page's renderer dies,
	/// `authenticationRequired` once each time a document's HTTP authentication
	/// challenge is cancelled because nobody can answer it, and
	/// `userActionRequired` once each time a document's WebAuthn or FedCM sign-in
	/// prompt is refused for the same reason. A reload or navigation that
	/// recovers the page rearms the event.
	internal func observePages(_ snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]) {
		guard !stopping else { return }

		let renderers = Self.rendererFailures(snapshots, previouslyFailed: failedRenderers)
		failedRenderers = renderers.failed
		for id in renderers.reported {
			HeadlessOutput.emit("rendererFailed", ["tabID": id.rawValue.uuidString])
		}

		let authentications = Self.authenticationRequirements(
			snapshots,
			previouslyRequired: cancelledAuthentications
		)
		cancelledAuthentications = authentications.failed
		for id in authentications.reported {
			HeadlessOutput.emit("authenticationRequired", ["tabID": id.rawValue.uuidString])
		}

		let signIns = Self.signInRequirements(snapshots, previouslyRequired: refusedSignIns)
		refusedSignIns = signIns.failed
		for id in signIns.reported {
			let prompts = snapshots[id]?.navigation.cancelledSignInPrompts ?? []
			HeadlessOutput.emit("userActionRequired", [
				"tabID": id.rawValue.uuidString,
				"prompts": Self.promptNames(prompts),
			])
		}
	}

	/// Pages whose current document had a sign-in prompt refused, and the newly
	/// affected ones in a stable order.
	internal nonisolated static func signInRequirements(
		_ snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		previouslyRequired: Set<BrowserCore.Tab.ID>
	) -> (failed: Set<BrowserCore.Tab.ID>, reported: [BrowserCore.Tab.ID]) {
		newly(
			snapshots,
			previously: previouslyRequired,
			where: { !$0.navigation.cancelledSignInPrompts.isEmpty }
		)
	}

	/// Stable protocol names for refused sign-in prompts.
	internal nonisolated static func promptNames(_ prompts: BrowserNavigation.SignInPrompts) -> [String] {
		[
			(BrowserNavigation.SignInPrompts.webAuthentication, "webAuthentication"),
			(.federatedSignIn, "federatedSignIn"),
		].compactMap { prompt, name in prompts.contains(prompt) ? name : nil }
	}

	/// Pages whose renderer is currently gone, and the newly failed ones in a stable order.
	internal nonisolated static func rendererFailures(
		_ snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		previouslyFailed: Set<BrowserCore.Tab.ID>
	) -> (failed: Set<BrowserCore.Tab.ID>, reported: [BrowserCore.Tab.ID]) {
		newly(
			snapshots,
			previously: previouslyFailed,
			where: { $0.navigation.failure == .rendererStopped }
		)
	}

	/// Pages whose current document had an authentication challenge cancelled,
	/// and the newly affected ones in a stable order.
	internal nonisolated static func authenticationRequirements(
		_ snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		previouslyRequired: Set<BrowserCore.Tab.ID>
	) -> (failed: Set<BrowserCore.Tab.ID>, reported: [BrowserCore.Tab.ID]) {
		newly(
			snapshots,
			previously: previouslyRequired,
			where: { $0.navigation.authenticationCancelled }
		)
	}

	private nonisolated static func newly(
		_ snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		previously: Set<BrowserCore.Tab.ID>,
		where condition: (BrowserSessionSnapshot) -> Bool
	) -> (failed: Set<BrowserCore.Tab.ID>, reported: [BrowserCore.Tab.ID]) {
		let failed = Set(snapshots.compactMap { id, snapshot in
			condition(snapshot) ? id : nil
		})
		let reported = failed
			.subtracting(previously)
			.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
		return (failed, reported)
	}

	private func fail(_ failure: HeadlessFailure) {
		guard !stopping else { return }
		exitCode = failure.exitCode
		HeadlessOutput.emit(failure)
		stop(failure == .timedOut ? .timeout : .failure)
	}

	private func installSignals() {
		for number in [SIGTERM, SIGINT] {
			signal(number, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
			source.setEventHandler { [weak self] in
				MainActor.assumeIsolated { self?.stop(.signal) }
			}
			source.resume()
			signals.append(source)
		}
	}

	private func prepareAutomation(store: StoreOf<AppFeature>) async throws(HeadlessFailure) {
		phases.enter(.automation)
		store.send(.automation(.ui(.unattended)))
		if let temporaryGrantWindow {
			store.send(.automation(.ui(.temporaryGrantWindow(temporaryGrantWindow))))
		}

		// A crashed persistent run cannot reuse its stale credential; remove it first.
		for stale in store.automationPreferences.clients where stale.name == Self.clientName {
			store.send(.automation(.ui(.revokeClient(stale.id))))
		}
		store.send(.automation(.ui(.enabled(true))))
		try await wait(.automationUnavailable) { store.automation.socketPath != nil }

		store.send(.automation(.ui(.clientName(Self.clientName))))
		store.send(.automation(.ui(.addClient)))
		try await wait(.automationUnavailable) {
			store.automation.configuration != nil
			&& store.automationPreferences.clients.contains { $0.name == Self.clientName }
		}
		guard
			var client = store.automationPreferences.clients.first(where: { $0.name == Self.clientName }),
			let json = store.automation.configuration
		else { throw .automationUnavailable }
		store.send(.automation(.ui(.dismissConfiguration)))
		store.send(.automation(.ui(.unattendedClient(client.id))))

		let grants = configuration.grants
		client.scopes = Self.scopes(for: store.workspace)
		client.allowsRead = grants.contains(.read)
		client.allowsScreenshots = grants.contains(.screenshots)
		client.allowsPageContent = grants.contains(.content)
		client.allowsPageInteraction = grants.contains(.interaction)
		client.allowsManagement = grants.contains(.manage)

		// The command line is the run's approval. Only this client may hold it past
		// the interactive 15-minute window: for the whole run, or until --timeout.
		let manageExpiry = Self.manageGrantExpiry(grants: grants, deadline: grantsExpireAt)
		client.mutationGrantUntil = manageExpiry
		store.send(.automation(.ui(.updateClient(client))))
		let id = client.id
		try await wait(.automationUnavailable) {
			let updated = store.automationPreferences.clients.first(where: { $0.id == id })
			return updated?.allowsRead == grants.contains(.read)
				&& updated?.scopes.isEmpty == false
				&& updated?.mutationGrantUntil == manageExpiry
		}

		try writeConfiguration(json)

		// A persistent profile may hold a sign-in privacy lock from an interactive
		// session. Only a person can end it, so every request is refused meanwhile.
		if store.state.automationPrivacyIsLocked {
			HeadlessOutput.emit("diagnostic", ["code": "authenticationProtected"])
		}
		phases.enter(.ready)
		HeadlessOutput.emit("ready", [
			"version": 1,
			"pid": Int(getpid()),
			"configuration": configurationFile.path,
			"profile": [
				"mode": profile.isPersistent ? "persistent" : "isolated",
				"path": profile.profileDirectory.path,
			],
			"viewport": ["width": Int(configuration.viewport.width), "height": Int(configuration.viewport.height)],
			// Additive since DEV-865: capture pixels are the viewport times this, for the whole run.
			"deviceScale": Double(display.deviceScale),
			"grants": grants.map(\.rawValue).sorted(),
			// Additive since DEV-598: nil (JSON null) when the run has no --timeout.
			"grantsExpireAt": grantsExpireAt.map { $0.ISO8601Format() } ?? NSNull(),
			"timeoutSeconds": configuration.timeout.map { Int($0.components.seconds) } ?? NSNull(),
		])
	}

	/// The credential file is created exclusively with mode 0600. It is the only
	/// file a headless run writes outside its profile; captures go to the MCP client.
	private func writeConfiguration(_ json: String) throws(HeadlessFailure) {
		let descriptor = open(configurationFile.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
		guard descriptor >= 0 else { throw .profileUnavailable }
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		do {
			try handle.write(contentsOf: Data((json + "\n").utf8))
		} catch {
			throw .profileUnavailable
		}
	}

	private func wait(
		_ failure: HeadlessFailure,
		timeout: Duration = .seconds(15),
		until condition: @MainActor () -> Bool
	) async throws(HeadlessFailure) {
		let clock = ContinuousClock()
		let end = clock.now.advanced(by: timeout)
		while !condition() {
			guard clock.now < end, !Task.isCancelled else { throw failure }
			do {
				try await Task.sleep(for: .milliseconds(50))
			} catch {
				throw failure
			}
		}
	}
}
