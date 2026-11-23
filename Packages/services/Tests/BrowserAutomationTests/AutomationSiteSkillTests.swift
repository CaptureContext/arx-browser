import AgentToolsClient
import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _MCP

@testable import BrowserMCPServer

/// The first answer about a page on a site Arx has a skill for names that skill, once per connection.
@Suite(.timeLimit(.minutes(1)))
internal struct AutomationSiteSkillTests {
	private static let revision: String = String(repeating: "a", count: 64)
	private static let later: String = String(repeating: "b", count: 64)

	@Test
	internal func openingASitesPageNamesItsSkillOnce() async throws {
		try await withFixture { calls in
			let sheet = try await calls.call("browser_tabs", arguments: Self.openTab("https://docs.google.com/spreadsheets/d/one/edit"))
			expectNoDifference(Self.siteSkill(in: sheet), "arx-google-sheets")

			// The text copy, which most clients read, carries it too.
			let text = try #require(Self.text(of: sheet))
			let decoded = try JSONDecoder().decode(Value.self, from: Data(text.utf8))
			expectNoDifference(decoded, sheet.structuredContent)
			guard case let .object(fields) = decoded, case let .object(skill)? = fields["siteSkill"] else {
				Issue.record("The text has no siteSkill")
				return
			}
			expectNoDifference(skill["resource"], .string("arx://skills/arx-google-sheets"))

			let another = try await calls.call("browser_tabs", arguments: Self.openTab("https://docs.google.com/spreadsheets/d/two/edit"))
			expectNoDifference(Self.siteSkill(in: another), nil)

			let repository = try await calls.call("browser_tabs", arguments: Self.openTab("https://github.com/owner/repo/pull/1"))
			expectNoDifference(Self.siteSkill(in: repository), "arx-github")

			let elsewhere = try await calls.call("browser_tabs", arguments: Self.openTab("https://example.com/"))
			expectNoDifference(Self.siteSkill(in: elsewhere), nil)
		}
	}

	@Test
	internal func readingATabTheInventoryListedNamesItsSkill() async throws {
		try await withFixture { calls in
			let inventory = try await calls.call("browser_inventory", arguments: [:])
			expectNoDifference(Self.siteSkill(in: inventory), nil)

			let read = try BrowserMCPServer.envelope(Self.reading(Fixture.documentTab), isError: false)

			// Before any read of the page, nothing says the remembered address is still its page.
			let unread = await calls.namingSiteSkill(in: read, tool: "browser_read", arguments: [:])
			expectNoDifference(Self.siteSkill(in: unread), nil)

			// A read at another revision means the tab moved on since the inventory: no guess.
			_ = await calls.gateway.perform(.inspect(.init(targetID: Fixture.documentTab, expectedRevision: Self.later)))
			let moved = await calls.namingSiteSkill(in: read, tool: "browser_read", arguments: [:])
			expectNoDifference(Self.siteSkill(in: moved), nil)

			_ = await calls.gateway.perform(.inspect(.init(targetID: Fixture.documentTab, expectedRevision: Self.revision)))

			// A failed read doesn't use up the skill's one mention.
			let failed = try BrowserMCPServer.envelope(Self.reading(Fixture.documentTab), isError: true)
			let afterFailure = await calls.namingSiteSkill(in: failed, tool: "browser_read", arguments: [:])
			expectNoDifference(Self.siteSkill(in: afterFailure), nil)

			let named = await calls.namingSiteSkill(in: read, tool: "browser_read", arguments: [:])
			expectNoDifference(Self.siteSkill(in: named), "arx-google-docs")

			let again = await calls.namingSiteSkill(in: read, tool: "browser_inspect", arguments: [:])
			expectNoDifference(Self.siteSkill(in: again), nil)
		}
	}

	@Test
	internal func selectingATabNamesItsSkillAtTheRevisionTheInventoryListed() async throws {
		try await withFixture { calls in
			_ = try await calls.call("browser_inventory", arguments: [:])

			// Closing a tab isn't about its page.
			let closed = try await calls.call("browser_tabs", arguments: Self.command("closeTab", Fixture.mailTab.uuidString, Self.revision))
			expectNoDifference(Self.siteSkill(in: closed), nil)

			// Arx accepted another revision: the tab moved on since the inventory, so no guess.
			let moved = try await calls.call("browser_tabs", arguments: Self.command("selectTab", Fixture.mailTab.uuidString, Self.later))
			expectNoDifference(Self.siteSkill(in: moved), nil)

			let selected = try await calls.call("browser_tabs", arguments: Self.command("selectTab", Fixture.documentTab.uuidString, Self.revision))
			expectNoDifference(Self.siteSkill(in: selected), "arx-google-docs")

			// The focused-tab alias resolves to the mail tab at the inventory's revision.
			let focused = try await calls.call(
				"browser_tabs",
				arguments: Self.command("selectTab", AutomationFocusedTab.alias, AutomationFocusedTab.alias)
			)
			expectNoDifference(Self.siteSkill(in: focused), "arx-gmail")
		}
	}

	@Test
	internal func aSiteSkillIsAResource() async throws {
		let gateway = AutomationGateway(path: "/tmp/unused", clientID: UUID(), credential: String(repeating: "0", count: 64))
		let resources = AutomationResources(gateway: gateway)
		let skill = try #require(AgentSiteSkill.named("arx-google-sheets"))

		let content = try await resources.read("arx://skills/arx-google-sheets")
		expectNoDifference(content, .text(skill.text, uri: "arx://skills/arx-google-sheets", mimeType: "text/markdown"))
		#expect(AutomationResources.Address("arx://skills/arx-unknown") == nil)
		await #expect(throws: (any Error).self) {
			try await resources.subscribe("arx://skills/arx-google-sheets")
		}
	}

	/// A step of `browser_run` (DEV-1012) that names a skill uses up its one mention, so the run's
	/// own answer carries it, though the script keeps nothing of the step's answer.
	@Test
	internal func aRunCarriesTheSkillsItsStepsNamed() async throws {
		try await withFixture { calls in
			let run = AutomationRun(calls: calls)
			let sheet = try Self.json(Self.openTab("https://docs.google.com/spreadsheets/d/one/edit"))
			let pull = try Self.json(Self.openTab("https://github.com/owner/repo/pull/1"))
			let code = "call('browser_tabs', \(sheet)); call('browser_tabs', \(pull)); return 'kept nothing';"
			let result = try await run.run(["code": .string(code)])
			guard
				case let .object(fields)? = result.structuredContent,
				case let .array(skills)? = fields["siteSkills"]
			else {
				Issue.record("The run's answer has no siteSkills: \(String(describing: result.structuredContent))")
				return
			}
			let names = skills.compactMap { hint -> String? in
				guard case let .object(skill) = hint else { return nil }
				return skill["name"]?.stringValue
			}
			expectNoDifference(names, ["arx-google-sheets", "arx-github"])

			// Named once per connection, by the run.
			let again = try await calls.call("browser_tabs", arguments: Self.openTab("https://docs.google.com/spreadsheets/d/two/edit"))
			expectNoDifference(Self.siteSkill(in: again), nil)

			// A run whose steps name nothing carries no siteSkills.
			let quiet = try await run.run(["code": .string("return 1;")])
			guard case let .object(quietFields)? = quiet.structuredContent else {
				Issue.record("The run gave no structured answer")
				return
			}
			#expect(quietFields["siteSkills"] == nil)
		}
	}

	// MARK: - Fixture

	private enum Fixture {
		static let documentTab: UUID = .init()
		static let mailTab: UUID = .init()

		static func item(_ id: UUID, _ url: String) -> AutomationInventoryItem {
			.init(
				id: id,
				kind: .tab,
				title: "Untrusted title",
				profileID: UUID(),
				url: url,
				revision: AutomationSiteSkillTests.revision
			)
		}

		static func reply(_ envelope: AutomationIPC.Envelope) -> AutomationIPC.Reply {
			switch envelope.payload {
			case .hello:
				return .hello(UUID())

			case .focusedTab:
				return .focusedTab(.init(tabID: mailTab, revision: AutomationSiteSkillTests.revision))

			case .request(_, .inventory(cursor: _, limit: _)):
				return .result(.inventory(.init(items: [
					item(documentTab, "https://docs.google.com/document/d/abc/edit"),
					item(mailTab, "https://mail.google.com/mail/u/0/"),
				])))

			case let .request(_, .inspect(request)):
				return .result(.inspection(.init(
					request: request,
					source: .init(
						tabID: .init(rawValue: request.targetID),
						profileID: .init(rawValue: UUID()),
						sessionRevision: 1,
						documentRevision: 1,
						scopeID: UUID()
					),
					snapshot: .init(snapshotID: "snapshot", documentID: "document", frameID: "main", domVersion: "1", nodes: [], omissions: [])
				)))

			case let .request(_, .command(command)):
				let opened: UUID? = command.action == .openTab ? UUID() : command.targetID
				return .result(.command(.init(operationID: command.operationID, status: .committed, targetID: opened)))

			default:
				return .acknowledged
			}
		}
	}

	private func withFixture(_ body: (AutomationCalls) async throws -> Void) async throws {
		let socket = LocalAutomationSocket()
		let directory = URL(fileURLWithPath: "/tmp/arx-site-skill-" + UUID().uuidString.prefix(8))
		defer { try? FileManager.default.removeItem(at: directory) }
		let path = try await socket.start(directory: directory) { Fixture.reply($0) }
		let gateway = AutomationGateway(path: path, clientID: UUID(), credential: String(repeating: "0", count: 64))
		try await gateway.initialize()
		do {
			try await body(AutomationCalls(gateway: gateway))
		} catch {
			await gateway.disconnect()
			await socket.stop()
			throw error
		}
		await gateway.disconnect()
		await socket.stop()
	}

	private static func openTab(_ url: String) -> [String: Value] {
		[
			"operationID": .string(UUID().uuidString),
			"action": .string("openTab"),
			"targetID": .string(UUID().uuidString),
			"expectedRevision": .string(revision),
			"url": .string(url),
		]
	}

	private static func command(
		_ action: String,
		_ target: String,
		_ revision: String
	) -> [String: Value] {
		[
			"operationID": .string(UUID().uuidString),
			"action": .string(action),
			"targetID": .string(target),
			"expectedRevision": .string(revision),
		]
	}

	private static func reading(_ tab: UUID) -> [String: Value] {
		[
			"untrustedData": .bool(true),
			"result": .object(["kind": .string("read"), "targetID": .string(tab.uuidString)]),
		]
	}

	private static func json(_ arguments: [String: Value]) throws -> String {
		String(decoding: try JSONEncoder().encode(Value.object(arguments)), as: UTF8.self)
	}

	private static func siteSkill(in response: CallTool.Result) -> String? {
		guard
			case let .object(fields)? = response.structuredContent,
			case let .object(skill)? = fields["siteSkill"]
		else { return nil }

		return skill["name"]?.stringValue
	}

	private static func text(of response: CallTool.Result) -> String? {
		guard case let .text(text, _, _)? = response.content.first
		else { return nil }

		return text
	}
}
