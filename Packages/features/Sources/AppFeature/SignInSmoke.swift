#if DEBUG
import AppKit
import BrowserCore
import ChromiumBrowserEngine
import Darwin
import Foundation
import _ComposableArchitecture
import _MCP

/// Trusted sign-in handoff acceptance. Runs only with `ARX_SIGN_IN_SMOKE=1`, a
/// disposable `ARX_ENGINE_PROFILE` and the runner's loopback login fixture.
///
/// This driver plays the user: it presses the trusted Arx controls and types the
/// fixture secrets with native key events. `ARX_SIGN_IN_SMOKE_DRIVER` selects how
/// controls are pressed: `store` (the default) sends the actions the buttons send;
/// `interface` finds the panel's buttons by accessibility identifier and presses
/// them through NSAccessibility, so a missing, hidden or disabled control fails
/// the run. Controls that must be gone (approving or confirming an ended
/// handoff) are asserted absent instead of sent. Two assistants
/// connect through the bundled `ArxMCP` helper. Every reply they receive is
/// appended to the runner's transcript, which the runner scans for the secrets.
/// The secrets are never printed and never passed to an assistant.
@MainActor
internal final class SignInSmoke {
	internal enum Failure: String, Error {
		case invalidFixture
		case setupFailed
		case unexpectedReply
		case leakedState
		case nativeInput
		case interfaceControl
		case timedOut
	}

	/// How the driver presses the trusted sign-in controls.
	internal enum Driver: String, Sendable {
		case store
		case interface
	}

	private struct Secrets {
		internal let password: String
		internal let wrongPassword: String
		internal let otp: String

		internal init(
			password: String,
			wrongPassword: String,
			otp: String
		) {
			self.password = password
			self.wrongPassword = wrongPassword
			self.otp = otp
		}
	}

	private let store: StoreOf<AppFeature>
	private let engine: ChromiumBrowserEngine
	private let driver: Driver
	private var interfacePresses: Int = 0
	private let windowProvider: @MainActor () -> NSWindow?
	private var window: NSWindow!
	private let secrets: Secrets
	private let transcript: FileHandle
	private let loginURL: URL
	private let elsewhereURL: URL
	private let frameOrigin: String
	private let origin: String
	private var sessions: [AutomationSmokeSession] = []
	private var phase: String = "setup"
	private var tab: BrowserCore.Tab!

	internal static func start(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		window: @escaping @MainActor () -> NSWindow?,
		environment: [String: String]
	) throws -> SignInSmoke? {
		guard environment["ARX_SIGN_IN_SMOKE"] == "1"
		else { return nil }

		guard
			environment["ARX_ENGINE_PROFILE"] != nil,
			let raw = environment["ARX_ENGINE_URL"],
			let loginURL = URL(string: raw),
			loginURL.scheme == "http",
			loginURL.host() == "127.0.0.1",
			let port = loginURL.port,
			loginURL.path() == "/login.html",
			let password = environment["ARX_SIGN_IN_SMOKE_SECRET"],
			let wrongPassword = environment["ARX_SIGN_IN_SMOKE_WRONG_SECRET"],
			let otp = environment["ARX_SIGN_IN_SMOKE_OTP"],
			[password, wrongPassword, otp].allSatisfy({ $0.count >= 12 && $0.allSatisfy(Self.typeable) }),
			let path = environment["ARX_SIGN_IN_SMOKE_TRANSCRIPT"],
			path.hasPrefix("/"),
			let driver = Driver(rawValue: environment["ARX_SIGN_IN_SMOKE_DRIVER"] ?? Driver.store.rawValue)
		else { throw Failure.invalidFixture }

		if driver == .interface { AutomationSignInView.buildsAccessibilityElements = true }

		// The runner owns the directory; this file must be new.
		let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
		guard descriptor >= 0
		else { throw Failure.invalidFixture }

		return .init(
			store: store,
			engine: engine,
			driver: driver,
			window: window,
			secrets: .init(password: password, wrongPassword: wrongPassword, otp: otp),
			transcript: .init(fileDescriptor: descriptor, closeOnDealloc: true),
			loginURL: loginURL,
			port: port
		)
	}

	private init(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		driver: Driver,
		window: @escaping @MainActor () -> NSWindow?,
		secrets: Secrets,
		transcript: FileHandle,
		loginURL: URL,
		port: Int
	) {
		self.store = store
		self.engine = engine
		self.driver = driver
		self.windowProvider = window
		self.secrets = secrets
		self.transcript = transcript
		self.loginURL = loginURL
		self.elsewhereURL = URL(string: "http://localhost:\(port)/elsewhere.html")!
		self.frameOrigin = "http://localhost:\(port)"
		self.origin = "http://127.0.0.1:\(port)"
	}

	internal func run() async throws {
		do {
			try await exercise()
			await closeSessions()
			await store.send(.automation(.ui(.enabled(false)))).finish()
			if driver == .interface {
				guard interfacePresses > 0
				else { throw Failure.interfaceControl }

				emit("ARX_SIGN_IN_INTERFACE_CONTROLS_PRESSED")
			}
			emit("ARX_SIGN_IN_SMOKE_SUCCESS")
		} catch {
			emit("ARX_SIGN_IN_SMOKE_FAILED phase=\(phase) reason=\((error as? Failure)?.rawValue ?? "helper")")
			await closeSessions()
			throw error
		}
	}

	// MARK: - Phases

	private func exercise() async throws {
		try await wait { self.title == "Arx sign-in fixture ready" && self.windowProvider() != nil }
		guard let tab = store.main.viewer.item.tab, let window = windowProvider()
		else { throw Failure.setupFailed }

		self.window = window

		self.tab = tab
		store.send(.automation(.ui(.enabled(true))))
		try await wait { self.store.automation.socketPath != nil }

		var assistant = try await connect(name: "Sign-in assistant", signIn: true)
		let second = try await connect(name: "Second assistant", signIn: false)

		phase = "binding"
		try await expectUntrustedPage(assistant)
		let item = try await inventoryItem(assistant)
		try await expectFailure(assistant, signIn(.begin, revision: item.revision, origin: frameOrigin), "staleTarget")
		try await expectFailure(assistant, signIn(.begin, revision: String(repeating: "a", count: 64), origin: origin), "staleTarget")
		let secondItem = try await inventoryItem(second)
		try await expectFailure(second, signIn(.begin, revision: secondItem.revision, origin: origin), "denied")
		var credentialShaped = signIn(.begin, revision: item.revision, origin: origin)
		credentialShaped.arguments["password"] = .string("never-sent")
		try await expectRejectedArguments(assistant, credentialShaped)
		emit("ARX_SIGN_IN_PHASE_BINDING")

		phase = "cancelledConsent"
		let cancelled = UUID()
		try await expectStatus(assistant, signIn(.begin, id: cancelled, revision: item.revision, origin: origin), "approvalRequired")
		try await expectFailure(second, signIn(.status, id: cancelled), "denied")
		try await press(.cancel, operation: cancelled)
		try await expectStatus(assistant, signIn(.status, id: cancelled), "cancelled")
		try await requireUnlocked(assistant)
		emit("ARX_SIGN_IN_PHASE_CANCELLED_CONSENT")

		phase = "originSwap"
		let swapped = UUID()
		let beforeSwap = try await inventoryItem(assistant)
		try await expectStatus(assistant, signIn(.begin, id: swapped, revision: beforeSwap.revision, origin: origin), "approvalRequired")
		try await engine.client.command(tab.id, .navigate(elsewhereURL))
		try await wait { self.title == "Arx sign-in elsewhere" }
		try await wait { self.signInRecord(swapped)?.status == .cancelled }
		try await pressEnded(.approve, operation: swapped)
		try await expectStatus(assistant, signIn(.status, id: swapped), "cancelled")
		try await requireUnlocked(assistant)
		try await engine.client.command(tab.id, .navigate(loginURL))
		try await waitForSettledPage("Arx sign-in fixture ready")
		emit("ARX_SIGN_IN_PHASE_ORIGIN_SWAP")

		phase = "expiredGrant"
		let expired = UUID()
		let beforeGrant = try await inventoryItem(assistant)
		try await expectStatus(assistant, signIn(.begin, id: expired, revision: beforeGrant.revision, origin: origin), "approvalRequired")
		guard var client = store.automationPreferences.clients.first(where: { $0.name == "Sign-in assistant" })
		else { throw Failure.setupFailed }

		let grant = client.grantRevision
		await store.send(.automation(.ui(.updateClient(client)))).finish()
		try await wait { self.signInRecord(expired)?.status == .cancelled }
		client = store.automationPreferences.clients.first(where: { $0.id == client.id }) ?? client
		guard client.grantRevision != grant
		else { throw Failure.setupFailed }

		try await pressEnded(.approve, operation: expired)
		assistant = try await reconnect(assistant, name: "Sign-in assistant")
		try await expectFailure(assistant, signIn(.status, id: expired), "denied")
		try await requireUnlocked(assistant)
		emit("ARX_SIGN_IN_PHASE_EXPIRED_GRANT")

		phase = "handoff"
		try await handoff(assistant: assistant, second: second)

		phase = "fresh"
		let fresh = try await connect(name: "Reauthorized assistant", signIn: true)
		let signedIn = try await inventoryItem(fresh)
		guard signedIn.title == "Arx sign-in fixture signed in"
		else { throw Failure.unexpectedReply }

		let inspect = Call("browser_inspect", [
			"targetID": .string(tab.id.rawValue.uuidString),
			"expectedRevision": .string(signedIn.revision),
		])
		try await expectKind(fresh, inspect, "inspection")
		emit("ARX_SIGN_IN_PHASE_FRESH_AUTHORIZATION")

		phase = "userNavigation"
		try await engine.client.command(tab.id, .navigate(loginURL))
		try await waitForSettledPage("Arx sign-in fixture ready")
		let navigated = UUID()
		let beforeNavigation = try await inventoryItem(fresh)
		try await expectStatus(fresh, signIn(.begin, id: navigated, revision: beforeNavigation.revision, origin: origin), "approvalRequired")
		try await press(.approve, operation: navigated)
		try await wait { self.signInRecord(navigated)?.status == .userActionRequired }
		try await engine.client.command(tab.id, .navigate(elsewhereURL))
		try await wait { self.signInRecord(navigated)?.status == .cancelled }
		try await expectStatus(fresh, signIn(.status, id: navigated), "cancelled")
		try await expectFailure(fresh, .init("browser_inventory", ["limit": .int(10)]), "authenticationProtected")
		try await pressEnded(.confirm, operation: navigated)
		guard signInRecord(navigated)?.status == .cancelled, store.state.automationPrivacyIsLocked
		else { throw Failure.leakedState }

		try await resume()
		emit("ARX_SIGN_IN_PHASE_USER_NAVIGATION")
	}

	private func handoff(
		assistant: AutomationSmokeSession,
		second: AutomationSmokeSession
	) async throws {
		let operation = UUID()
		let item = try await inventoryItem(assistant)
		try await expectStatus(assistant, signIn(.begin, id: operation, revision: item.revision, origin: origin), "approvalRequired")
		try await press(.approve, operation: operation)
		guard store.state.automationPrivacyIsLocked
		else { throw Failure.leakedState }

		try await wait { self.signInRecord(operation)?.status == .userActionRequired }
		try await expectProtected([assistant, second], revision: item.revision)
		try await expectStatus(assistant, signIn(.status, id: operation), "userActionRequired")
		try await expectFailure(second, signIn(.status, id: operation), "denied")
		emit("ARX_SIGN_IN_PHASE_PROTECTED")

		// Failed login: the site rejects the wrong password; Arx claims nothing.
		try await focusPage()
		try type(secrets.wrongPassword)
		try press(.return)
		try await wait { self.title == "Arx sign-in fixture failed" }
		try await expectStatus(assistant, signIn(.status, id: operation), "userActionRequired")
		emit("ARX_SIGN_IN_PHASE_FAILED_LOGIN")

		// Reveal the password, so it is visible text, and type the real one.
		try press(.tab)
		try press(.space)
		try await wait { self.title == "Arx sign-in fixture revealed" }
		try type(secrets.password)
		try await wait { self.title == "Arx sign-in typing " + self.secrets.password }
		try await expectProtected([assistant, second], revision: item.revision)
		try press(.return)
		try await wait { self.title == "Arx sign-in fixture otp" }

		// Site MFA is the user's step too.
		try type(secrets.otp)
		try await wait { self.title == "Arx sign-in otp " + self.secrets.otp }
		try await expectProtected([assistant, second], revision: item.revision)
		try press(.return)
		try await wait { self.title == "Arx sign-in fixture signed in" }
		try await expectStatus(assistant, signIn(.status, id: operation), "userActionRequired")
		emit("ARX_SIGN_IN_PHASE_REVEALED_AND_MFA")

		try await press(.confirm, operation: operation)
		try await expectStatus(assistant, signIn(.status, id: operation), "userConfirmed")
		try await expectProtected([assistant, second], revision: item.revision)
		emit("ARX_SIGN_IN_PHASE_USER_CONFIRMED")

		guard let requester = store.automationPreferences.clients.first(where: { $0.name == "Sign-in assistant" })
		else { throw Failure.setupFailed }

		try await resume(keeping: [requester.id])
		for session in [assistant, second] {
			do {
				let result = try await record(session, .init("browser_inventory", ["limit": .int(10)]))
				guard result.isError == true
				else { throw Failure.leakedState }
			} catch Failure.leakedState {
				throw Failure.leakedState
			} catch {
				// A revoked session may also be disconnected by the app.
			}
		}
		guard
			let kept = store.automationPreferences.clients.first(where: { $0.id == requester.id }),
			kept.grantRevision != requester.grantRevision,
			kept.scopes == requester.scopes,
			kept.mutationGrantUntil == requester.mutationGrantUntil
		else { throw Failure.leakedState }

		let restored = try await reconnect(assistant, name: "Sign-in assistant")
		try await requireUnlocked(restored)
		emit("ARX_SIGN_IN_PHASE_RESUMED_WITHOUT_OLD_GRANTS")
	}

	// MARK: - Assertions

	private func expectUntrustedPage(_ session: AutomationSmokeSession) async throws {
		let item = try await inventoryItem(session)
		let result = try await record(session, .init("browser_inspect", [
			"targetID": .string(tab.id.rawValue.uuidString),
			"expectedRevision": .string(item.revision),
		]))
		let payload = try Self.payload(result)
		let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
		guard
			result.isError != true,
			payload["kind"] as? String == "inspection",
			text.contains("ARX-INJECTION"),
			let omissions = payload["omissions"] as? [String],
			omissions.contains("formValues"),
			omissions.contains("passwordSubtrees")
		else { throw Failure.unexpectedReply }
	}

	/// Every observation and action from every client, including a new sign-in.
	private func expectProtected(
		_ sessions: [AutomationSmokeSession],
		revision: String
	) async throws {
		let target: Value = .string(tab.id.rawValue.uuidString)
		let reference: [String: Value] = [
			"targetID": target,
			"expectedRevision": .string(revision),
			"snapshotID": .string("s1"),
			"reference": .string("r1"),
		]
		for session in sessions {
			let calls: [Call] = [
				.init("browser_inventory", ["limit": .int(100)]),
				.init("browser_inspect", ["targetID": target, "expectedRevision": .string(revision)]),
				.init("browser_capture", ["targetID": target, "expectedRevision": .string(revision), "mode": .string("viewport")]),
				.init("browser_wait", [
					"targetID": target, "expectedRevision": .string(revision),
					"condition": .string("loadingStopped"), "timeoutMilliseconds": .int(100),
				]),
				.init("browser_click", reference.merging(["operationID": .string(UUID().uuidString)]) { $1 }),
				.init("browser_replace_text", reference.merging(["operationID": .string(UUID().uuidString), "value": .string("x")]) { $1 }),
				.init("browser_keypress", reference.merging(["operationID": .string(UUID().uuidString), "key": .string("x")]) { $1 }),
				.init("browser_scroll", reference.merging([
					"operationID": .string(UUID().uuidString), "axis": .string("vertical"), "deltaCSSPixels": .double(10),
				]) { $1 }),
				.init("browser_command", [
					"operationID": .string(UUID().uuidString), "action": .string("reload"),
					"targetID": target, "expectedRevision": .string(revision),
				]),
				signIn(.begin, revision: revision, origin: origin),
			]
			for call in calls {
				try await expectFailure(session, call, "authenticationProtected")
			}
		}
	}

	private func requireUnlocked(_ session: AutomationSmokeSession) async throws {
		guard !store.state.automationPrivacyIsLocked
		else { throw Failure.leakedState }

		_ = try await inventoryItem(session)
	}

	private func expectStatus(
		_ session: AutomationSmokeSession,
		_ call: Call,
		_ status: String
	) async throws {
		let payload = try Self.payload(try await record(session, call))
		guard payload["kind"] as? String == "signIn", payload["status"] as? String == status else {
			emit(
				"ARX_SIGN_IN_UNEXPECTED phase=\(phase) expected=\(status) kind=\(payload["kind"] ?? "nil") "
				+ "code=\(payload["code"] ?? payload["status"] ?? "nil")"
			)
			throw Failure.unexpectedReply
		}
	}

	/// `code == nil` accepts any bounded error reply.
	private func expectFailure(
		_ session: AutomationSmokeSession,
		_ call: Call,
		_ code: String?
	) async throws {
		let result = try await record(session, call)
		let payload = (try? Self.payload(result)) ?? [:]
		guard result.isError == true, code == nil || payload["code"] as? String == code else {
			emit(
				"ARX_SIGN_IN_UNEXPECTED phase=\(phase) tool=\(call.name) expected=\(code ?? "error") "
				+ "code=\(payload["code"] ?? payload["kind"] ?? "nil")"
			)
			throw Failure.unexpectedReply
		}
	}

	/// The helper rejects schema violations as a JSON-RPC error before Arx sees the call.
	private func expectRejectedArguments(
		_ session: AutomationSmokeSession,
		_ call: Call
	) async throws {
		do {
			let result = try await session.rawCall(call.name, arguments: call.arguments)
			try append(result)
			emit("ARX_SIGN_IN_UNEXPECTED phase=\(phase) tool=\(call.name) expected=invalidParams")
			throw Failure.unexpectedReply
		} catch Failure.unexpectedReply {
			throw Failure.unexpectedReply
		} catch {
			try transcript.write(contentsOf: Data("{\"rejected\":\"invalidParams\"}\n".utf8))
		}
	}

	private func expectKind(
		_ session: AutomationSmokeSession,
		_ call: Call,
		_ kind: String
	) async throws {
		let result = try await record(session, call)
		guard result.isError != true, try Self.payload(result)["kind"] as? String == kind
		else { throw Failure.unexpectedReply }
	}

	// MARK: - Assistants

	private struct Call {
		internal let name: String
		internal var arguments: [String: Value]

		internal init(
			_ name: String,
			_ arguments: [String: Value]
		) {
			self.name = name
			self.arguments = arguments
		}
	}

	private struct Item {
		internal let revision: String
		internal let title: String?

		internal init(
			revision: String,
			title: String?
		) {
			self.revision = revision
			self.title = title
		}
	}

	private func signIn(
		_ action: AutomationSignInRequest.Action,
		id: UUID = UUID(),
		revision: String? = nil,
		origin: String? = nil
	) -> Call {
		var arguments: [String: Value] = [
			"operationID": .string(id.uuidString),
			"action": .string(action.rawValue),
		]
		if action == .begin {
			arguments["targetID"] = .string(tab.id.rawValue.uuidString)
			arguments["expectedRevision"] = revision.map(Value.string)
			arguments["origin"] = origin.map(Value.string)
		}
		return .init("browser_sign_in", arguments)
	}

	private func inventoryItem(_ session: AutomationSmokeSession) async throws -> Item {
		let result = try await record(session, .init("browser_inventory", ["limit": .int(100)]))
		let payload = (try? Self.payload(result)) ?? [:]
		guard
			let items = payload["items"] as? [[String: Any]],
			let item = items.first(where: { $0["id"] as? String == tab.id.rawValue.uuidString }),
			let revision = item["revision"] as? String
		else {
			emit(
				"ARX_SIGN_IN_UNEXPECTED phase=\(phase) tool=browser_inventory error=\(result.isError ?? false) "
				+ "kind=\(payload["kind"] ?? "nil") code=\(payload["code"] ?? "nil") "
				+ "items=\((payload["items"] as? [Any])?.count ?? -1)"
			)
			throw Failure.unexpectedReply
		}

		return .init(revision: revision, title: item["title"] as? String)
	}

	/// Appends the exact encoded reply, including image data, before it is inspected.
	private func record(
		_ session: AutomationSmokeSession,
		_ call: Call
	) async throws -> CallTool.Result {
		let result: CallTool.Result
		do {
			result = try await session.rawCall(call.name, arguments: call.arguments)
		} catch {
			emit("ARX_SIGN_IN_HELPER_ERROR phase=\(phase) tool=\(call.name)")
			throw error
		}
		try append(result)
		return result
	}

	private func append(_ result: CallTool.Result) throws {
		var line = try JSONEncoder().encode(result)
		line.append(0x0A)
		try transcript.write(contentsOf: line)
	}

	private func connect(
		name: String,
		signIn: Bool
	) async throws -> AutomationSmokeSession {
		store.send(.automation(.ui(.clientName(name))))
		store.send(.automation(.ui(.addClient)))
		try await wait {
			self.store.automation.configuration != nil
			&& self.store.automationPreferences.clients.contains { $0.name == name }
		}
		guard
			var client = store.automationPreferences.clients.first(where: { $0.name == name }),
			let json = store.automation.configuration,
			let socket = store.automation.socketPath
		else { throw Failure.setupFailed }

		store.send(.automation(.ui(.dismissConfiguration)))
		client.scopes = [.space(store.main.sidebar.spaceID, profileID: tab.profileID)]
		client.allowsRead = true
		client.allowsScreenshots = true
		client.allowsPageContent = true
		client.allowsPageInteraction = true
		client.allowsSignIn = signIn
		await store.send(.automation(.ui(.updateClient(client)))).finish()
		let id = client.id
		try await wait {
			self.store.automationPreferences.clients.first(where: { $0.id == id })?.allowsRead == true
		}
		let configuration = try AutomationSmokeConfiguration(json: json, helper: helper, socket: socket, client: client)
		configurations[name] = configuration
		return try await open(configuration)
	}

	private var configurations: [String: AutomationSmokeConfiguration] = [:]

	private var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ArxMCP") }

	private func reconnect(
		_ session: AutomationSmokeSession,
		name: String
	) async throws -> AutomationSmokeSession {
		_ = await session.close()
		guard let configuration = configurations[name]
		else { throw Failure.setupFailed }

		return try await open(configuration)
	}

	private func open(_ configuration: AutomationSmokeConfiguration) async throws -> AutomationSmokeSession {
		let session = try AutomationSmokeSession(helper: helper, configuration: configuration)
		sessions.append(session)
		try await session.connect(grantedBy: store.automationPreferences)
		return session
	}

	private func closeSessions() async {
		for session in sessions { _ = await session.close() }
		sessions.removeAll()
	}

	/// Ends the lock with exactly `kept` selected, through the same driver as every other control.
	private func resume(keeping kept: Set<UUID> = []) async throws {
		for id in store.automation.signIn.keptClientIDs.symmetricDifference(kept) {
			try await toggleKept(id)
		}
		try await press(.resume, operation: nil)
		try await wait { !self.store.state.automationPrivacyIsLocked }
		guard
			Set(store.automationPreferences.clients.map(\.id)) == kept,
			store.automation.sessions.isEmpty
		else { throw Failure.leakedState }
	}

	private func toggleKept(_ id: UUID) async throws {
		let keeps = !store.automation.signIn.keptClientIDs.contains(id)
		switch driver {
		case .store:
			store.send(.automation(.signIn(.ui(.keepClient(id, keeps)))))

		case .interface:
			let identifier = AutomationSignInView.Control.keepIdentifier(id)
			var element: AccessibilityObject?
			do {
				try await wait {
					element = self.accessibilityElement(identifier)
					return element?.flag("isAccessibilityEnabled") == true
				}
			} catch {
				emit("ARX_SIGN_IN_UNEXPECTED phase=\(phase) control=\(identifier) found=\(element != nil)")
				throw Failure.interfaceControl
			}
			guard element?.flag("accessibilityPerformPress") == true
			else { throw Failure.interfaceControl }

			interfacePresses += 1
		}
		try await wait { self.store.automation.signIn.keptClientIDs.contains(id) == keeps }
	}

	// MARK: - The user

	/// Presses a trusted control the user can see for `operation`.
	private func press(
		_ control: AutomationSignInView.Control,
		operation: UUID?
	) async throws {
		switch driver {
		case .store:
			store.send(.automation(.signIn(.ui(try Self.action(control, operation: operation)))))

		case .interface:
			if let operation {
				// The panel shows the active handoff; it must be this one.
				guard store.automation.signIn.records.values.first(where: \.isActive)?.request.operationID == operation
				else { throw Failure.interfaceControl }
			}
			var element: AccessibilityObject?
			do {
				try await wait {
					element = self.accessibilityElement(control.rawValue)
					return element?.flag("isAccessibilityEnabled") == true
				}
			} catch {
				emit("ARX_SIGN_IN_UNEXPECTED phase=\(phase) control=\(control.rawValue) found=\(element != nil)")
				throw Failure.interfaceControl
			}
			guard element?.flag("accessibilityPerformPress") == true
			else { throw Failure.interfaceControl }

			interfacePresses += 1
		}
	}

	/// An ended handoff: the store driver sends the stale action, which must be
	/// ignored; the interface driver requires that the control is gone.
	private func pressEnded(
		_ control: AutomationSignInView.Control,
		operation: UUID
	) async throws {
		switch driver {
		case .store:
			store.send(.automation(.signIn(.ui(try Self.action(control, operation: operation)))))

		case .interface:
			do {
				try await wait { self.accessibilityElement(control.rawValue) == nil }
			} catch {
				emit("ARX_SIGN_IN_UNEXPECTED phase=\(phase) control=\(control.rawValue) expected=absent")
				throw Failure.leakedState
			}
		}
	}

	private static func action(
		_ control: AutomationSignInView.Control,
		operation: UUID?
	) throws -> AutomationSignInAction.UI {
		switch (control, operation) {
		case let (.approve, operation?): return .approve(operation)
		case let (.confirm, operation?): return .confirm(operation)
		case let (.cancel, operation?): return .cancel(operation)
		case (.resume, nil): return .resume
		default: throw Failure.interfaceControl
		}
	}

	/// Walks the window's accessibility tree, as an assistive client sees it.
	private func accessibilityElement(_ identifier: String) -> AccessibilityObject? {
		var pending: [Any] = [window as Any]
		var visited: Set<ObjectIdentifier> = []
		while let candidate = pending.popLast() {
			guard
				let object = candidate as? NSObject,
				visited.insert(ObjectIdentifier(object)).inserted
			else { continue }

			if let view = object as? NSView {
				pending.append(contentsOf: view.subviews)
			}
			let element = AccessibilityObject(object: object)
			if element.string("accessibilityIdentifier") == identifier {
				return element.flag("isAccessibilityElement") == true ? element : nil
			}
			pending.append(contentsOf: element.children)
		}
		return nil
	}

	/// An object in the accessibility tree. SwiftUI's elements implement the
	/// NSAccessibility methods without declaring `NSAccessibilityProtocol`, so a
	/// Swift cast misses them; the methods are called by selector instead, as the
	/// accessibility runtime calls them.
	private struct AccessibilityObject {
		internal let object: NSObject

		internal init(object: NSObject) {
			self.object = object
		}

		internal var children: [Any] {
			value("accessibilityChildren") as? [Any] ?? []
		}

		internal func string(_ name: String) -> String? {
			value(name) as? String
		}

		/// Calls a method that takes no arguments and returns `BOOL`.
		internal func flag(_ name: String) -> Bool? {
			let selector = Selector(name)
			guard object.responds(to: selector)
			else { return nil }

			typealias Method = @convention(c) (NSObject, Selector) -> Bool
			return unsafeBitCast(object.method(for: selector), to: Method.self)(object, selector)
		}

		private func value(_ name: String) -> Any? {
			guard object.responds(to: Selector(name))
			else { return nil }

			return object.value(forKey: name)
		}
	}

	private func focusPage() async throws {
		NSApplication.shared.activate()
		window.makeKeyAndOrderFront(nil)
		engine.surface.focus(tab.id)
		do {
			try await wait {
				guard
					self.window.isKeyWindow,
					let view = self.engine.hostView(self.tab.id),
					let responder = self.window.firstResponder as? NSView
				else { return false }

				return responder === view || responder.isDescendant(of: view)
			}
		} catch {
			emit(
				"ARX_SIGN_IN_UNEXPECTED phase=\(phase) focus "
				+ "active=\(NSApplication.shared.isActive) key=\(window.isKeyWindow)"
			)
			throw error
		}
	}

	private enum Key {
		case `return`
		case tab
		case space

		internal var code: UInt16 {
			switch self {
			case .return: 36
			case .tab: 48
			case .space: 49
			}
		}

		internal var characters: String {
			switch self {
			case .return: "\r"
			case .tab: "\t"
			case .space: " "
			}
		}
	}

	private func press(_ key: Key) throws {
		try send(characters: key.characters, code: key.code)
	}

	private func type(_ text: String) throws {
		for character in text {
			guard let code = Self.keyCodes[character]
			else { throw Failure.nativeInput }

			try send(characters: String(character), code: code)
		}
	}

	private func send(
		characters: String,
		code: UInt16
	) throws {
		for type in [NSEvent.EventType.keyDown, .keyUp] {
			guard let event = NSEvent.keyEvent(
				with: type,
				location: .zero,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				characters: characters,
				charactersIgnoringModifiers: characters,
				isARepeat: false,
				keyCode: code
			)
			else { throw Failure.nativeInput }

			window.sendEvent(event)
		}
	}

	private static func typeable(_ character: Character) -> Bool { keyCodes[character] != nil }

	/// ANSI virtual key codes for the fixture's lowercase alphanumeric secrets.
	private static let keyCodes: [Character: UInt16] = [
		"a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
		"b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
		"3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
		"u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
	]

	// MARK: - Helpers

	private var title: String? {
		guard let id = tab?.id ?? store.main.viewer.item.tab?.id
		else { return nil }

		return engine.client.snapshot(id)?.navigation.title
	}

	/// Waits until the page has finished loading and the workspace has recorded it.
	/// The title arrives while the document still loads; the revision an assistant
	/// reads before then changes with the load's end, so a sign-in bound to it would
	/// fail as `staleTarget`.
	private func waitForSettledPage(_ expected: String) async throws {
		try await wait {
			guard let navigation = self.engine.client.snapshot(self.tab.id)?.navigation
			else { return false }

			return navigation.title == expected
			&& !navigation.isLoading
			&& self.store.workspace.tabs[id: self.tab.id]?.restoration.title == expected
		}
	}

	private func signInRecord(_ id: UUID) -> AutomationSignInState.Record? { store.automation.signIn.records[id] }

	private static func payload(_ result: CallTool.Result) throws -> [String: Any] {
		let data = try JSONEncoder().encode(result.structuredContent)
		guard
			let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
			object["untrustedData"] as? Bool == true,
			let payload = object["result"] as? [String: Any]
		else { throw Failure.unexpectedReply }

		return payload
	}

	private func emit(_ line: String) {
		FileHandle.standardOutput.write(Data((line + "\n").utf8))
	}

	private func wait(
		timeout: Duration = .seconds(20),
		_ condition: @MainActor () -> Bool
	) async throws {
		let end = ContinuousClock.now.advanced(by: timeout)
		while !condition() {
			guard ContinuousClock.now < end
			else { throw Failure.timedOut }

			try await Task.sleep(for: .milliseconds(50))
		}
	}
}
#endif
