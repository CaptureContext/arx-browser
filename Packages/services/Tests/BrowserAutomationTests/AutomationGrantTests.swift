import BrowserAutomationClient
import BrowserCore
import BrowserMCPServer
import CustomDump
import Foundation
import Testing

@MainActor
internal struct AutomationGrantTests {
	@Test(.timeLimit(.minutes(1)))
	internal func grantChangesReachTheSessionWithoutDisconnecting() async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-mcp-grants-" + UUID().uuidString.prefix(8))
		defer { try? FileManager.default.removeItem(at: directory) }

		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		let authority = Authority(.init(isEnabled: true, clients: [client]))
		let host = BrowserAutomationHost(directory: directory)
		host.configure(
			preferences: { authority.preferences },
			receive: { _ in },
			focusedTab: { client in
				authority.focused.flatMap { client.allowsFocusedTab ? $0 : nil }
			}
		)
		let path = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: client.id,
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(),
			payload: .hello
		)
		guard case let .hello(epoch) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Handshake failed")
			await host.stop()
			return
		}
		envelope.epoch = epoch

		func exchange(_ payload: AutomationIPC.Payload) async throws -> AutomationIPC.Reply {
			envelope.payload = payload
			return try await LocalAutomationSocket.exchange(path: path, envelope: envelope)
		}

		guard case let .grants(initial) = try await exchange(.grants) else {
			Issue.record("Grant poll failed")
			await host.stop()
			return
		}
		expectNoDifference(initial, .init(capabilities: [.read]))
		guard case .failure(.denied) = try await exchange(.focusedTab) else {
			Issue.record("The focused-tab alias resolved without the opt-in")
			await host.stop()
			return
		}

		authority.preferences.clients[0].capabilities.insert(.organize)
		authority.preferences.clients[0].approvalPolicy = .destructiveOnly
		authority.preferences.clients[0].allowsFocusedTab = true
		authority.preferences.clients[0].grantRevision = UUID()
		guard case let .grants(changed) = try await exchange(.grants) else {
			Issue.record("The session ended on a grant change")
			await host.stop()
			return
		}
		expectNoDifference(
			changed,
			.init(capabilities: [.read, .organize], approvalPolicy: .destructiveOnly, allowsFocusedTab: true)
		)

		guard case .failure(.notReady) = try await exchange(.focusedTab) else {
			Issue.record("A missing focused tab was not reported")
			await host.stop()
			return
		}
		let tab = AutomationFocusedTab(tabID: UUID(), revision: String(repeating: "f", count: 64))
		authority.focused = tab
		guard case let .focusedTab(resolved) = try await exchange(.focusedTab) else {
			Issue.record("The focused-tab alias did not resolve")
			await host.stop()
			return
		}
		expectNoDifference(resolved, tab)

		// Revocation still ends the session immediately.
		host.revoke(client.id)
		guard case .failure(.staleSession) = try await exchange(.grants) else {
			Issue.record("A revoked session kept polling grants")
			await host.stop()
			return
		}
		await host.stop()
	}

	@Test
	internal func toolListFollowsCapabilityClasses() {
		expectNoDifference(
			AutomationTools.definitions(for: .init(capabilities: [.read])).map(\.name),
			[
				"browser_inventory", "browser_spaces", "browser_profiles", "browser_windows", "browser_archive",
				"browser_wait", "browser_links", "browser_batch", "browser_run",
			]
		)
		expectNoDifference(
			AutomationTools.definitions(for: .init(capabilities: [.read, .pageContent, .interact])).map(\.name),
			[
				"browser_inventory",
				"browser_spaces",
				"browser_profiles",
				"browser_windows",
				"browser_archive",
				"browser_inspect",
				"browser_click",
				"browser_wait",
				"browser_replace_text",
				"browser_select_value",
				"browser_keypress",
				"browser_scroll",
				"browser_hover",
				"browser_drag",
				"browser_type",
				"browser_set_checked",
				"browser_dialog",
				"browser_media",
				"browser_read",
				"browser_find",
				"browser_find_in_page",
				"browser_pdf",
				"browser_links",
				"browser_batch",
				"browser_run",
			]
		)

		// Without read, nothing is listed, whatever else is granted.
		#expect(AutomationTools.definitions(for: .init(capabilities: [.organize, .interact])).isEmpty)

		let everything = AutomationGrantSummary(capabilities: AutomationCapability.allCases)
		expectNoDifference(
			AutomationTools.definitions(for: everything).map(\.name),
			AutomationTools.definitions.map(\.name)
		)
		for tool in AutomationTools.definitions {
			#expect(AutomationTools.requiredCapabilities(forTool: tool.name) != nil, "\(tool.name)")
			#expect(tool.description?.contains("focusedTab") == false, "\(tool.name)")
		}

		var focused = everything
		focused.allowsFocusedTab = true
		let described = AutomationTools.definitions(for: focused).filter { $0.description?.contains("focusedTab") == true }

		// browser_command keeps the alias for existing callers but is no longer listed.
		expectNoDifference(Set(described.map(\.name)), AutomationTools.focusedTabTools.subtracting(["browser_command"]))
	}

	@Test
	internal func toolClassesMatchTheClassesArxEnforces() throws {
		let revision = String(repeating: "a", count: 64)
		let operations: [String: AutomationOperation] = [
			"browser_inventory": .inventory(cursor: nil, limit: 1),
			"browser_command": .command(.init(
				operationID: UUID(),
				action: .reload,
				targetID: UUID(),
				expectedRevision: revision
			)),
			"browser_capture": .capture(AutomationCaptureTests.result().request),
			"browser_inspect": .inspect(AutomationInspectionTests.result().request),
			"browser_wait": .wait(AutomationWaitTests.result().request),
		]
		for (name, operation) in operations {
			expectNoDifference(
				AutomationTools.requiredCapabilities(forTool: name),
				operation.requiredCapabilities,
				"\(name)"
			)
		}
	}
}

@MainActor
private final class Authority {
	internal var preferences: AutomationPreferences
	internal var focused: AutomationFocusedTab?

	internal init(_ preferences: AutomationPreferences) {
		self.preferences = preferences
		self.focused = nil
	}
}
