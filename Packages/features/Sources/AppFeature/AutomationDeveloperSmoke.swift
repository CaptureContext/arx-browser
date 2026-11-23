#if DEBUG
import BrowserCore
import Foundation
import _ComposableArchitecture
import _MCP

/// Runs the developer tier against real Chromium through the bundled MCP helper
/// (DEV-668): refused without developer mode, logs kept and read with cookie
/// values and query tokens redacted, and an approved script in the developer
/// world that reads no cookie, password, card value or stored credential.
@MainActor
internal enum AutomationDeveloperSmoke {
	internal static func run(
		store: StoreOf<AppFeature>,
		session: () throws -> AutomationSmokeSession,
		client: AutomationClient,
		tab: BrowserCore.Tab,
		page: URL,
		navigate: (URL) -> Void,
		pageLoaded: @escaping @MainActor () -> Bool,
		restore: () async throws -> Void
	) async throws {
		let secrets = (ProcessInfo.processInfo.environment["ARX_DEVELOPER_SMOKE_SECRETS"] ?? "")
			.split(separator: ",")
			.map(String.init)
		guard secrets.count == 4, secrets.allSatisfy({ $0.utf8.count >= 16 })
		else { throw AutomationSmokeFailure.setupFailed }

		store.send(.settings(.ui(.developerModeEnabled(false))))
		var granted = client
		granted.capabilities.formUnion([.script, .devtools, .signIn])
		granted.approvalPolicy = .alwaysAsk

		// A temporary grant covers other mutations; a script must still ask.
		granted.mutationGrantUntil = Date().addingTimeInterval(90)
		await store.send(.automation(.ui(.updateClient(granted)))).finish()
		try await wait("sessions closed after the grant change") { store.automation.sessions.isEmpty }

		// Without developer mode, the tier refuses before anything reaches the page.
		let refusedSession = try session()
		try await refusedSession.connect(grantedBy: store.automationPreferences)
		let before = try await item(tab, in: refusedSession)
		let refused = try await call(refusedSession, "browser_evaluate", evaluate(before, script: "return 1"), secrets)
		guard
			refused["kind"]?.stringValue == "error",
			refused["code"]?.stringValue == AutomationFailure.developerModeRequired.rawValue,
			store.automation.pending.isEmpty
		else {
			throw AutomationSmokeMismatch(
				.authorizationFailed,
				check: "mcpDeveloper.developerModeOff",
				expected: "developerModeRequired",
				actual: "\(refused)"
			)
		}
		guard await refusedSession.close() else { throw AutomationSmokeFailure.helperFailed }

		store.send(.settings(.ui(.developerModeEnabled(true))))
		try await wait("developer mode on") { store.settings.general.developerModeEnabled }
		let session = try session()
		try await session.connect(grantedBy: store.automationPreferences)
		let start = try await call(session, "browser_logs", logs(.start, tab: tab), secrets)
		guard start["capturing"]?.boolValue == true
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDeveloper.logsStart", expected: "capturing", actual: "\(start)") }

		navigate(page)
		try await wait("developer fixture loaded", pageLoaded)

		// The page's own fetch carries a token; the log keeps the request, never the token.
		var network: [[String: Value]] = []
		try await wait("developer fixture request logged") {
			guard
				let read = try? await call(session, "browser_logs", logs(.network, tab: tab), secrets),
				let entries = read["entries"]?.arrayValue?.compactMap(\.objectValue)
			else { return false }

			network = entries
			return entries.contains { $0["url"]?.stringValue?.contains("/developer/api?") == true }
		}
		let request = network.first { $0["url"]?.stringValue?.contains("/developer/api?") == true }
		guard
			let url = request?["url"]?.stringValue,
			url.contains("token=redacted"),
			url.contains("page=2"),
			request?["status"]?.intValue == 200,
			network.allSatisfy({ $0["headers"] == nil && $0["cookies"] == nil && $0["body"] == nil })
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDeveloper.networkLog", expected: "a redacted api request", actual: "\(network)") }
		print("ARX_MCP_DEVELOPER_PHASE_NETWORK")

		// The page logs its readable cookie; the log replaces the value.
		let console = try await call(session, "browser_logs", logs(.console, tab: tab), secrets)
		let message = console["entries"]?.arrayValue?
			.compactMap { $0.objectValue?["message"]?.stringValue }
			.first { $0.contains("arx-developer-console") }
		guard let message, message.contains("[redacted]")
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDeveloper.consoleLog", expected: "a redacted console message", actual: "\(console)") }
		print("ARX_MCP_DEVELOPER_PHASE_CONSOLE")

		let current = try await item(tab, in: session)
		let operationID = UUID()
		let script = """
		const password = document.querySelector('#password');
		const card = document.querySelector('#card');
		const before = password.value;
		password.type = 'text';
		let formData;
		try { new FormData(document.querySelector('#login')); formData = 'allowed'; } catch (error) { formData = error.name; }
		const credentials = await navigator.credentials.get({ password: true }).then(() => 'allowed', error => error.name);
		return {
			title: document.title,
			cookie: document.cookie,
			cookieStore: window.cookieStore == null,
			password: before,
			passwordAfterTypeChange: password.value,
			card: card.value,
			user: document.querySelector('#user').value,
			echo: document.body.dataset.echo,
			formData,
			credentials,
			pageVariable: typeof window.arxPageSecret,
		};
		"""
		let pending = Task {
			try await call(session, "browser_evaluate", evaluate(current, script: script, operationID: operationID), secrets)
		}
		try await approve(operationID, store: store)
		let evaluated = try await pending.value
		let value = evaluated["value"]?.objectValue
		let expected: [String: String] = [
			"title": "Arx developer",
			"cookie": "",
			"password": "",
			"passwordAfterTypeChange": "",
			"card": "",
			"user": "fixture-user",
			"echo": "[redacted]",
			"formData": "SecurityError",
			"credentials": "SecurityError",
			"pageVariable": "undefined",
		]
		let matches = expected.allSatisfy { key, expected in value?[key]?.stringValue == expected }
		guard
			evaluated["outcome"]?.stringValue == "value",
			matches,
			value?["cookieStore"]?.boolValue == true
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDeveloper.script", expected: "\(expected)", actual: "\(evaluated)") }
		print("ARX_MCP_DEVELOPER_PHASE_SCRIPT")

		let syntaxID = UUID()
		let syntaxTask = Task {
			try await call(
				session,
				"browser_evaluate",
				evaluate(try await item(tab, in: session), script: "return (", operationID: syntaxID),
				secrets
			)
		}
		try await approve(syntaxID, store: store)
		let syntax = try await syntaxTask.value
		guard
			syntax["outcome"]?.stringValue == "syntaxError",
			syntax["error"]?.objectValue?["name"]?.stringValue == "SyntaxError"
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDeveloper.syntax", expected: "syntaxError", actual: "\(syntax)") }

		// DEV-708: password sign-in through the helper. This disposable profile has
		// no saved password (the app smoke never writes one with the real Keychain),
		// so the reply is an outcome, before any approval, and nothing more.
		let signInItem = try await item(tab, in: session)
		var origin = URLComponents(url: page, resolvingAgainstBaseURL: false)
		origin?.path = ""
		origin?.query = nil
		let signIn = try await call(session, "browser_password_sign_in", [
			"operationID": .string(UUID().uuidString),
			"targetID": .string(signInItem.id.uuidString),
			"expectedRevision": .string(signInItem.revision),
			"origin": .string(origin?.string ?? ""),
		], secrets)
		guard
			signIn["outcome"]?.stringValue == "failed",
			signIn["reason"]?.stringValue == "noSavedPassword",
			Set(signIn.keys).isSubset(of: ["kind", "operationID", "outcome", "reason"]),
			store.automation.pending.isEmpty
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDeveloper.passwordSignIn", expected: "failed noSavedPassword", actual: "\(signIn)") }
		print("ARX_MCP_PASSWORD_SIGN_IN_PHASE_NO_SAVED_PASSWORD")

		let stopped = try await call(session, "browser_logs", logs(.stop, tab: tab), secrets)
		let afterStop = try await call(session, "browser_logs", logs(.console, tab: tab), secrets)
		guard
			stopped["capturing"]?.boolValue == false,
			afterStop["capturing"]?.boolValue == false,
			afterStop["entries"]?.arrayValue?.isEmpty == true
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDeveloper.logsStop", expected: "no log after stop", actual: "\(afterStop)") }
		guard await session.close() else { throw AutomationSmokeFailure.helperFailed }

		store.send(.settings(.ui(.developerModeEnabled(false))))

		// Later phases expect the tab where the organization phase left it.
		try await restore()
		print("ARX_MCP_DEVELOPER_NATIVE_SMOKE_SUCCESS")
	}

	private static func approve(
		_ operationID: UUID,
		store: StoreOf<AppFeature>
	) async throws {
		try await wait("script awaiting approval") {
			store.automation.pending.values.contains { pending in
				guard case let .script(request) = pending.request.operation else { return false }
				return request.operationID == operationID && pending.awaitingApproval
			}
		}
		guard let requestID = store.automation.pending.first(where: { $0.value.awaitingApproval })?.key
		else { throw AutomationSmokeFailure.setupFailed }

		store.send(.automation(.ui(.approve(requestID))))
	}

	private static func evaluate(
		_ item: AutomationInventoryItem,
		script: String,
		operationID: UUID = UUID()
	) -> [String: Value] {
		[
			"operationID": .string(operationID.uuidString),
			"targetID": .string(item.id.uuidString),
			"expectedRevision": .string(item.revision),
			"script": .string(script),
		]
	}

	private static func logs(
		_ action: AutomationLogRequest.Action,
		tab: BrowserCore.Tab
	) -> [String: Value] {
		["action": .string(action.rawValue), "targetID": .string(tab.id.rawValue.uuidString)]
	}

	/// The reply's result object. No byte of any reply may carry a fixture secret.
	private static func call(
		_ session: AutomationSmokeSession,
		_ tool: String,
		_ arguments: [String: Value],
		_ secrets: [String]
	) async throws -> [String: Value] {
		let reply = try await session.rawCall(tool, arguments: arguments)
		guard let structured = reply.structuredContent
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDeveloper.\(tool)", expected: "structured content", actual: "none") }

		let data = try JSONEncoder().encode(structured)
		let text = String(decoding: data, as: UTF8.self)
		if let leaked = secrets.first(where: text.contains) {
			throw AutomationSmokeMismatch(
				.invalidResponse,
				check: "mcpDeveloper.\(tool).redaction",
				expected: "no fixture secret",
				actual: "contains \(leaked.prefix(10))…"
			)
		}
		guard
			structured.objectValue?["untrustedData"]?.boolValue == true,
			let result = structured.objectValue?["result"]?.objectValue
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDeveloper.\(tool)", expected: "an untrusted result", actual: text) }

		return result
	}

	private static func item(
		_ tab: BrowserCore.Tab,
		in session: AutomationSmokeSession
	) async throws -> AutomationInventoryItem {
		guard
			case let .inventory(inventory) = try await session.inventory(),
			let item = inventory.items.first(where: { $0.kind == .tab && $0.id == tab.id.rawValue })
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDeveloper.item", expected: "the granted tab", actual: "missing") }

		return item
	}

	private static func wait(
		_ site: String,
		timeout: Duration = .seconds(10),
		_ condition: @MainActor () async -> Bool
	) async throws {
		let start = ContinuousClock.now
		while !(await condition()) {
			guard ContinuousClock.now - start < timeout
			else { throw SmokeDiagnostics.timeout(site: "AutomationDeveloperSmoke.\(site)", since: start, state: "") }

			try await Task.sleep(for: .milliseconds(100))
		}
	}
}
#endif
