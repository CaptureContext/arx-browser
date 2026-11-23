import BrowserAutomationClient
import BrowserCore
import BrowserMCPServer
import CustomDump
import Foundation
import Testing
import _MCP

@MainActor
internal struct MCPInteropTests {
	@Test(.enabled(if: ProcessInfo.processInfo.environment["ARX_MCP_TEST_HELPER"] != nil), .timeLimit(.minutes(1)))
	internal func swiftSDKClientUsesRealHelperAndAuthenticatedIPC() async throws {
		let fixture = try await Fixture.start()
		let process = Process()
		let input = Pipe()
		let output = Pipe()
		let errors = Pipe()
		process.executableURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_MCP_TEST_HELPER"]))
		process.environment = fixture.environment
		process.standardInput = input
		process.standardOutput = output
		process.standardError = errors
		try process.run()
		let client = Client(name: "Untrusted fixture label", version: "1.0")
		do {
			let initialized = try await client.connect(transport: StdioTransport(
				input: .init(rawValue: output.fileHandleForReading.fileDescriptor),
				output: .init(rawValue: input.fileHandleForWriting.fileDescriptor)
			))
			#expect(initialized.protocolVersion == "2025-11-25")
			let tools = try await client.listTools()
			let expectedTools = [
				"browser_inventory",
				"browser_tabs",
				"browser_folders",
				"browser_hosts",
				"browser_spaces",
				"browser_profiles",
				"browser_windows",
				"browser_archive",
				"browser_downloads",
				"browser_capture",
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
				"browser_sign_in",
				"browser_read",
				"browser_find",
				"browser_find_in_page",
				"browser_pdf",
				// History needs a class this fixture client doesn't hold.
				"browser_links",
				"browser_batch",
				"browser_run",
				"browser_settings",
				"browser_password_sign_in",
			]
			#expect(tools.tools.map(\.name) == expectedTools)
			let result = try await client.callTool(name: "browser_inventory", arguments: ["limit": .int(1)])
			#expect(result.isError == false)
			guard case let .text(text, _, _) = result.content.first else {
				Issue.record("Inventory omitted text result")
				throw AutomationFailure.invalidRequest
			}
			#expect(text.contains("untrustedData"))
			#expect(!text.contains("Excluded"))
			#expect(!text.contains("synthetic-private"))
			let inventoryRequest: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_inventory",
				arguments: ["limit": .int(100)]
			)
			let inventory = try await inventoryRequest.value
			guard
				case let .object(root) = inventory.structuredContent,
				case let .object(page) = root["result"],
				case let .array(items) = page["items"]
			else { throw AutomationFailure.invalidRequest }
			let objects: [[String: Value]] = items.compactMap {
				guard case let .object(object) = $0 else { return nil }
				return object
			}
			guard
				let tab = objects.first(where: { $0["kind"] == .string("tab") }),
				case let .string(target) = tab["id"],
				case let .string(revision) = tab["revision"]
			else { throw AutomationFailure.invalidRequest }
			let captureRequest: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_capture",
				arguments: [
					"targetID": .string(target),
					"expectedRevision": .string(revision),
					"mode": .string("viewport"),
				]
			)
			let captured = try await captureRequest.value
			#expect(captured.isError == false)
			guard
				captured.content.count == 2,
				case let .image(encoded, mimeType, _, _) = captured.content[1]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(Data(base64Encoded: encoded), AutomationCaptureTests.result().image.data)
			expectNoDifference(mimeType, "image/png")
			#expect(try JSONEncoder().encode(captured).count < AutomationIPC.maximumResponseBytes)

			let inspectionRequest: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_inspect",
				arguments: ["targetID": .string(target), "expectedRevision": .string(revision)]
			)
			let inspected = try await inspectionRequest.value
			#expect(inspected.isError == false)
			guard
				case let .object(envelope) = inspected.structuredContent,
				case let .object(snapshot) = envelope["result"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(snapshot["kind"], .string("inspection"))
			expectNoDifference(snapshot["historical"], .bool(true))
			expectNoDifference(snapshot["expectedRevision"], .string(revision))
			expectNoDifference(snapshot["referencesAuthorizeActions"], .bool(false))
			expectNoDifference(snapshot["scopeID"], nil)
			#expect(try JSONEncoder().encode(inspected).count < AutomationIPC.maximumResponseBytes)

			let waitRequest: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_wait",
				arguments: [
					"targetID": .string(target),
					"expectedRevision": .string(revision),
					"condition": .string("loadingStopped"),
				]
			)
			let waited = try await waitRequest.value
			guard
				case let .object(waitEnvelope) = waited.structuredContent,
				case let .object(waitMetadata) = waitEnvelope["result"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(waitMetadata["kind"], .string("wait"))
			expectNoDifference(waitMetadata["status"], .string("stopped"))
			expectNoDifference(waitMetadata["historical"], .bool(true))
			expectNoDifference(waitMetadata["navigationCompleted"], .bool(false))
			expectNoDifference(waitMetadata["documentRevision"], .string(String(UInt64.max)))

			let denied = try await client.callTool(
				name: "browser_command",
				arguments: [
					"operationID": .string(UUID().uuidString),
					"action": .string("reload"),
					"targetID": .string(UUID().uuidString),
					"expectedRevision": .string(String(repeating: "a", count: 64)),
				]
			)
			#expect(denied.isError == true)
			for action in ["moveFolder", "closeTab"] {
				var arguments: [String: Value] = [
					"operationID": .string(UUID().uuidString),
					"action": .string(action),
					"targetID": .string(UUID().uuidString),
					"expectedRevision": .string(String(repeating: "a", count: 64)),
				]
				if action == "moveFolder" {
					arguments["destinationID"] = .string(UUID().uuidString)
					arguments["destinationRevision"] = .string(String(repeating: "b", count: 64))
				}
				let reply = try await client.callTool(name: "browser_command", arguments: arguments)

				// A denied app response proves the helper forwarded the supported action;
				// an unavailable action would throw invalidParams before IPC delivery.
				#expect(reply.isError == true)
				guard case let .text(text, _, _) = reply.content.first else {
					Issue.record("Command omitted its authorization result")
					throw AutomationFailure.invalidRequest
				}
				let result = try JSONDecoder().decode(Value.self, from: Data(text.utf8))
				expectNoDifference(result, .object([
					"untrustedData": .bool(true),
					"result": .object(["kind": .string("error"), "code": .string("denied")]),
				]))
			}

			guard
				let command = tools.tools.first(where: { $0.name == "browser_tabs" }),
				case let .object(commandSchema) = command.inputSchema,
				case let .object(commandProperties) = commandSchema["properties"],
				case let .object(route) = commandProperties["route"]
			else {
				Issue.record("browser_command omits route")
				throw AutomationFailure.invalidRequest
			}
			expectNoDifference(route["type"], .string("boolean"))

			// Routing is resolved in Arx, so the helper forwards the opt-in and the read-only host denies it.
			let routed = try await client.callTool(
				name: "browser_command",
				arguments: [
					"operationID": .string(UUID().uuidString),
					"action": .string("openTab"),
					"targetID": .string(UUID().uuidString),
					"expectedRevision": .string(String(repeating: "a", count: 64)),
					"url": .string("https://capturecontext.dev/"),
					"route": .bool(true),
				]
			)
			#expect(routed.isError == true)
			guard case let .text(routedText, _, _) = routed.content.first else {
				Issue.record("Routed command omitted its authorization result")
				throw AutomationFailure.invalidRequest
			}
			expectNoDifference(
				try JSONDecoder().decode(Value.self, from: Data(routedText.utf8)),
				.object([
					"untrustedData": .bool(true),
					"result": .object(["kind": .string("error"), "code": .string("denied")]),
				])
			)

			for tool in ["browser_replace_text", "browser_select_value"] {
				let call: RequestContext<CallTool.Result> = try await client.callTool(
					name: tool,
					arguments: [
						"operationID": .string(UUID().uuidString),
						"targetID": .string(target),
						"expectedRevision": .string(revision),
						"snapshotID": .string("snapshot"),
						"reference": .string("opaque"),
						"value": .string("Private SDK fixture value"),
					]
				)
				let reply = try await call.value
				expectNoDifference(reply.isError, true)
				let encoded = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
				#expect(encoded.contains("denied"))
				#expect(!encoded.contains("Private SDK fixture value"))
			}

			let keypress: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_keypress",
				arguments: [
					"operationID": .string(UUID().uuidString),
					"targetID": .string(target),
					"expectedRevision": .string(revision),
					"snapshotID": .string("snapshot"),
					"reference": .string("opaque"),
					"key": .string("ArrowLeft"),
				]
			)
			let keypressReply = try await keypress.value
			expectNoDifference(keypressReply.isError, true)
			let keypressEncoded = String(decoding: try JSONEncoder().encode(keypressReply), as: UTF8.self)
			#expect(keypressEncoded.contains("denied"))
			#expect(!keypressEncoded.contains("ArrowLeft"))

			let scroll: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_scroll",
				arguments: [
					"operationID": .string(UUID().uuidString),
					"targetID": .string(target),
					"expectedRevision": .string(revision),
					"snapshotID": .string("snapshot"),
					"reference": .string("opaque"),
					"axis": .string("vertical"),
					"deltaCSSPixels": .double(120.5),
				]
			)
			let scrollReply = try await scroll.value
			expectNoDifference(scrollReply.isError, true)
			let scrollEncoded = String(decoding: try JSONEncoder().encode(scrollReply), as: UTF8.self)
			#expect(scrollEncoded.contains("denied"))
			#expect(!scrollEncoded.contains("deltaCSSPixels"))

			let hover: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_hover",
				arguments: [
					"operationID": .string(UUID().uuidString),
					"targetID": .string(target),
					"expectedRevision": .string(revision),
					"snapshotID": .string("snapshot"),
					"x": .double(11.25),
					"y": .double(22.5),
				]
			)
			let hoverReply = try await hover.value
			expectNoDifference(hoverReply.isError, true)
			let hoverEncoded = String(decoding: try JSONEncoder().encode(hoverReply), as: UTF8.self)
			#expect(hoverEncoded.contains("denied"))
			#expect(!hoverEncoded.contains("11.25"))

			let typed: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_type",
				arguments: [
					"operationID": .string(UUID().uuidString),
					"targetID": .string(target),
					"expectedRevision": .string(revision),
					"snapshotID": .string("snapshot"),
					"reference": .string("opaque"),
					"text": .string("Private typed text"),
				]
			)
			let typedReply = try await typed.value
			expectNoDifference(typedReply.isError, true)
			let typedEncoded = String(decoding: try JSONEncoder().encode(typedReply), as: UTF8.self)
			#expect(typedEncoded.contains("denied"))
			#expect(!typedEncoded.contains("Private typed text"))

			let signIn: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_sign_in",
				arguments: [
					"operationID": .string(UUID().uuidString),
					"action": .string("begin"),
					"targetID": .string(target),
					"expectedRevision": .string(revision),
					"origin": .string("https://capturecontext.dev"),
				]
			)
			let signInReply = try await signIn.value
			expectNoDifference(signInReply.isError, true)
			#expect(String(decoding: try JSONEncoder().encode(signInReply), as: UTF8.self).contains("denied"))

			await client.disconnect()
			try input.fileHandleForWriting.close()
			try await wait(process)
			#expect(process.terminationStatus == 0)
			#expect(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
			await fixture.stop()
		} catch {
			await client.disconnect()
			if process.isRunning { process.terminate() }
			await fixture.stop()
			throw error
		}
	}

	@Test(.enabled(if: ProcessInfo.processInfo.environment["ARX_MCP_TEST_HELPER"] != nil), .timeLimit(.minutes(1)))
	internal func swiftSDKClientFollowsGrantChangesAndFocusedTab() async throws {
		let fixture = try await Fixture.start()
		let process = Process()
		let input = Pipe()
		let output = Pipe()
		process.executableURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_MCP_TEST_HELPER"]))
		process.environment = fixture.environment
		process.standardInput = input
		process.standardOutput = output
		process.standardError = Pipe()
		try process.run()
		let client = Client(name: "Grant fixture", version: "1.0")
		let (changes, changed) = AsyncStream<Void>.makeStream()
		await client.onNotification(ToolListChangedNotification.self) { _ in changed.yield() }
		do {
			let initialized = try await client.connect(transport: StdioTransport(
				input: .init(rawValue: output.fileHandleForReading.fileDescriptor),
				output: .init(rawValue: input.fileHandleForWriting.fileDescriptor)
			))
			expectNoDifference(initialized.capabilities.tools?.listChanged, true)
			let before = try await client.listTools().tools
			#expect(before.contains { $0.name == "browser_tabs" })
			let inspect = try #require(before.first { $0.name == "browser_inspect" })
			#expect(inspect.description?.contains("focusedTab") == true)

			// The focused-tab alias resolves in Arx and the result names the tab used.
			let focusedRequest: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_inspect",
				arguments: ["targetID": .string("focused"), "expectedRevision": .string("focused")]
			)
			let focused = try await focusedRequest.value
			#expect(focused.isError == false)
			guard
				case let .object(envelope) = focused.structuredContent,
				case let .string(focusedTab) = envelope["focusedTab"],
				case let .object(snapshot) = envelope["result"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(snapshot["targetID"], .string(focusedTab))

			_ = try await client.callTool(
				name: "browser_inventory",
				arguments: ["limit": .int(Fixture.grantChangeTrigger)]
			)
			var iterator = changes.makeAsyncIterator()
			_ = await iterator.next()
			let after = try await client.listTools().tools
			#expect(!after.contains { $0.name == "browser_tabs" })
			#expect(after.contains { $0.name == "browser_inspect" })

			// The session survived the change: reads keep working without reconnecting.
			let inventory = try await client.callTool(name: "browser_inventory", arguments: ["limit": .int(1)])
			#expect(inventory.isError == false)

			await client.disconnect()
			try input.fileHandleForWriting.close()
			try await wait(process)
			#expect(process.terminationStatus == 0)
			await fixture.stop()
		} catch {
			await client.disconnect()
			if process.isRunning { process.terminate() }
			await fixture.stop()
			throw error
		}
	}

	@Test(.enabled(if: ProcessInfo.processInfo.environment["ARX_MCP_TEST_HELPER"] != nil), .timeLimit(.minutes(1)))
	internal func claudeCodeStartsWithTheCoreToolsAndAddsGroups() async throws {
		let fixture = try await Fixture.start()
		let process = Process()
		let input = Pipe()
		let output = Pipe()
		process.executableURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_MCP_TEST_HELPER"]))
		process.environment = fixture.environment
		process.standardInput = input
		process.standardOutput = output
		process.standardError = Pipe()
		try process.run()

		// Claude Code's own clientInfo name, which picks the core listing (DEV-1021).
		let client = Client(name: "claude-code", version: "2")
		let (changes, changed) = AsyncStream<Void>.makeStream()
		await client.onNotification(ToolListChangedNotification.self) { _ in changed.yield() }
		do {
			_ = try await client.connect(transport: StdioTransport(
				input: .init(rawValue: output.fileHandleForReading.fileDescriptor),
				output: .init(rawValue: input.fileHandleForWriting.fileDescriptor)
			))
			let before = try await client.listTools().tools.map(\.name)
			#expect(before.contains("browser_inspect"))
			#expect(before.contains(AutomationTools.moreToolsName))
			#expect(!before.contains("browser_find"))
			#expect(!before.contains("browser_spaces"))

			let request: RequestContext<CallTool.Result> = try await client.callTool(
				name: AutomationTools.moreToolsName,
				arguments: ["groups": .array([.string("find"), .string("history")])]
			)
			let answer = try await request.value
			#expect(answer.isError == false)
			guard
				case let .object(envelope) = answer.structuredContent,
				case let .object(result) = envelope["result"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(result["added"], Value.array([.string("browser_find"), .string("browser_find_in_page")]))

			// The fixture client has no history class.
			expectNoDifference(result["notGranted"], Value.array([.string("history")]))

			var iterator = changes.makeAsyncIterator()
			_ = await iterator.next()
			let after = try await client.listTools().tools.map(\.name)
			#expect(after.contains("browser_find"))
			#expect(!after.contains("browser_history"))

			await client.disconnect()
			try input.fileHandleForWriting.close()
			try await wait(process)
			#expect(process.terminationStatus == 0)
			await fixture.stop()
		} catch {
			await client.disconnect()
			if process.isRunning { process.terminate() }
			await fixture.stop()
			throw error
		}
	}

	@Test(.enabled(if: ProcessInfo.processInfo.environment["ARX_MCP_TEST_HELPER"] != nil), .timeLimit(.minutes(1)))
	internal func swiftSDKClientBatchesObservesAndSubscribes() async throws {
		let fixture = try await Fixture.start()
		let process = Process()
		let input = Pipe()
		let output = Pipe()
		process.executableURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_MCP_TEST_HELPER"]))
		process.environment = fixture.environment
		process.standardInput = input
		process.standardOutput = output
		process.standardError = Pipe()
		try process.run()
		let client = Client(name: "Round-trip fixture", version: "1.0")
		let (updates, updated) = AsyncStream<String>.makeStream()
		await client.onNotification(ResourceUpdatedNotification.self) { message in updated.yield(message.params.uri) }
		do {
			let initialized = try await client.connect(transport: StdioTransport(
				input: .init(rawValue: output.fileHandleForReading.fileDescriptor),
				output: .init(rawValue: input.fileHandleForWriting.fileDescriptor)
			))
			expectNoDifference(initialized.capabilities.resources?.subscribe, true)

			func call(
				_ name: String,
				_ arguments: [String: Value]
			) async throws -> [String: Value] {
				let request: RequestContext<CallTool.Result> = try await client.callTool(name: name, arguments: arguments)
				guard case let .object(envelope) = try await request.value.structuredContent
				else { throw AutomationFailure.invalidRequest }
				return envelope
			}

			let spaces = try await call("browser_spaces", [:])
			guard
				case let .object(spaceList) = spaces["result"],
				case let .array(spaceItems) = spaceList["items"]
			else { throw AutomationFailure.invalidRequest }

			// Only the granted space is listed.
			expectNoDifference(spaceItems.count, 1)

			// With no overrides, a space shows the user's app-wide appearance, not the built-in
			// default, and follows the system theme.
			guard
				case let .object(space) = spaceItems.first,
				case let .object(resolved) = space["resolvedAppearance"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(resolved["theme"], Value.string("system"))

			// JSON may carry a whole number as an integer.
			let hue: Double? = switch resolved["tintHue"] {
			case let .int(value)?: Double(value)
			case let .double(value)?: value
			default: nil
			}
			expectNoDifference(hue, Fixture.chromeAppearance.tint.hue)
			#expect(hue != ChromeTint.default.hue)
			let profiles = try await call("browser_profiles", [:])
			guard
				case let .object(profileList) = profiles["result"],
				case let .array(profileItems) = profileList["items"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(profileItems.count, 1)
			guard
				case let .object(profile) = profileItems.first,
				case let .object(profileAppearance) = profile["resolvedAppearance"]
			else { throw AutomationFailure.invalidRequest }
			let profileHue: Double? = switch profileAppearance["tintHue"] {
			case let .int(value)?: Double(value)
			case let .double(value)?: value
			default: nil
			}
			expectNoDifference(profileHue, Fixture.chromeAppearance.tint.hue)

			let focused = try await call("browser_inspect", ["targetID": .string("focused"), "expectedRevision": .string("focused")])
			guard
				case let .string(tab) = focused["focusedTab"],
				case let .object(snapshot) = focused["result"],
				case let .string(snapshotID) = snapshot["snapshotID"],
				case let .string(revision) = snapshot["expectedRevision"]
			else { throw AutomationFailure.invalidRequest }

			// Paged inspection: every page comes from the same DOM version until the cursor runs out.
			var pagedNodes: [Value] = []
			var page = try await call("browser_inspect", ["targetID": .string(tab), "expectedRevision": .string(revision), "load": .bool(true)])
			var firstCursor: String?
			while true {
				guard
					case let .object(result) = page["result"],
					case let .array(nodes) = result["nodes"]
				else { throw AutomationFailure.invalidRequest }
				expectNoDifference(result["domVersion"], .string("4"))
				pagedNodes += nodes
				guard case let .string(next) = result["nextCursor"] else { break }
				firstCursor = firstCursor ?? next
				page = try await call("browser_inspect", ["cursor": .string(next)])
			}
			expectNoDifference(pagedNodes.count, AutomationInspectionTests.pagedResult().snapshot.nodes.count)

			// Opt-in values travel to Arx; the coverage list says values are included.
			let valued = try await call("browser_inspect", [
				"targetID": .string(tab), "expectedRevision": .string(revision), "formValues": .bool(true), "limit": .int(5),
			])
			guard
				case let .object(valuedResult) = valued["result"],
				case let .array(valuedOmissions) = valuedResult["omissions"]
			else { throw AutomationFailure.invalidRequest }
			#expect(!valuedOmissions.contains(.string("formValues")))
			#expect(valuedOmissions.contains(.string("passwordSubtrees")))

			let read = try await call("browser_read", ["targetID": .string(tab), "expectedRevision": .string(revision)])
			guard
				case let .object(readResult) = read["result"],
				case let .string(markdown) = readResult["text"]
			else { throw AutomationFailure.invalidRequest }
			#expect(markdown.hasPrefix("## Arx reading fixture\n\nWelcome to the Café menu\n\n- Item 0\n"))
			#expect(!markdown.contains("Skip me"))

			let found = try await call("browser_find", ["targetID": .string(tab), "expectedRevision": .string(revision), "query": .string("cafe")])
			guard
				case let .object(findResult) = found["result"],
				case let .array(matches) = findResult["matches"],
				case let .object(match) = matches.first
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(findResult["totalMatches"], .int(1))
			expectNoDifference(match["reference"], .string("menu-link"))

			// Captures: JPEG with scale, and an image above the old 256 KiB frame.
			let jpeg: RequestContext<CallTool.Result> = try await client.callTool(name: "browser_capture", arguments: [
				"targetID": .string(tab), "expectedRevision": .string(revision), "mode": .string("viewport"),
				"format": .string("jpeg"), "scale": .double(0.5),
			])
			let jpegResult = try await jpeg.value
			guard case let .image(_, jpegType, _, _) = jpegResult.content.last
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(jpegType, "image/jpeg")
			let large: RequestContext<CallTool.Result> = try await client.callTool(name: "browser_capture", arguments: [
				"targetID": .string(tab), "expectedRevision": .string(revision), "mode": .string("region"),
				"region": .object(["x": .int(0), "y": .int(0), "width": .int(1), "height": .int(1)]),
			])
			let largeResult = try await large.value
			guard case let .image(largeData, _, _, _) = largeResult.content.last
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(Data(base64Encoded: largeData)?.count, AutomationCaptureTests.largeImageBytes)

			// PDF export arrives as an application/pdf resource; PDF text continues by cursor.
			let exported: RequestContext<CallTool.Result> = try await client.callTool(name: "browser_pdf", arguments: [
				"targetID": .string(tab), "expectedRevision": .string(revision), "action": .string("export"),
			])
			guard case let .resource(resource, _, _) = try await exported.value.content.last
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(resource.mimeType, "application/pdf")
			let pdfText = try await call("browser_pdf", [
				"targetID": .string(tab), "expectedRevision": .string(revision), "action": .string("text"), "limit": .int(1024),
			])
			guard case let .string(pdfCursor) = pdfText["nextCursor"]
			else { throw AutomationFailure.invalidRequest }
			let pdfRest = try await call("browser_pdf", ["cursor": .string(pdfCursor)])
			guard case let .object(pdfRestResult) = pdfRest["result"]
			else { throw AutomationFailure.invalidRequest }
			#expect(pdfRestResult["offset"] != .int(0))

			let highlighted = try await call("browser_find_in_page", [
				"targetID": .string(tab), "expectedRevision": .string(revision), "text": .string("needle"),
			])
			guard case let .object(highlight) = highlighted["result"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(highlight["matches"], .int(3))

			let media = try await call("browser_media", ["action": .string("list")])
			guard
				case let .object(mediaList) = media["result"],
				case let .array(sessions) = mediaList["sessions"],
				case let .object(session) = sessions.first,
				case let .string(token) = session["token"]
			else { throw AutomationFailure.invalidRequest }
			let paused = try await call("browser_media", [
				"action": .string("pause"),
				"targetID": .string(tab),
				"expectedRevision": .string(revision),
				"operationID": .string(UUID().uuidString),
				"token": .string(token),
			])
			guard case let .object(pause) = paused["result"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(pause["performed"], .bool(true))
			let seeked = try await call("browser_media", [
				"action": .string("seek"),
				"targetID": .string(tab),
				"expectedRevision": .string(revision),
				"operationID": .string(UUID().uuidString),
				"token": .string(token),
				"seconds": .double(1.5),
			])
			guard case let .object(seek) = seeked["result"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(seek["performed"], .bool(true))
			let muted = try await call("browser_media", [
				"action": .string("mute"),
				"targetID": .string(tab),
				"expectedRevision": .string(revision),
				"operationID": .string(UUID().uuidString),
			])
			guard case let .object(mute) = muted["result"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(mute["performed"], .bool(true))

			// The fixture's grant has no profile item, so the start names a made-up profile; the host answers it.
			let download = try await call("browser_downloads", [
				"action": .string("startDownload"),
				"targetID": .string(UUID().uuidString),
				"expectedRevision": .string(revision),
				"operationID": .string(UUID().uuidString),
				"url": .string("https://capturecontext.dev/file.zip"),
			])
			guard case let .object(started) = download["result"]
			else { throw AutomationFailure.invalidRequest }
			let settingsCall = try await call("browser_settings", ["action": .string("read"), "section": .string("preferences")])
			guard case let .object(settingsRead) = settingsCall["result"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(settingsRead["kind"], Value.string("settings"))
			expectNoDifference(settingsRead["section"], Value.string("preferences"))
			let changed = try await call("browser_settings", [
				"action": .string("setPreferences"),
				"operationID": .string(UUID().uuidString),
				"expectedRevision": .string(String(repeating: "a", count: 64)),
				"values": .object(["warnsBeforeQuitting": .bool(false)]),
			])
			guard case let .object(settingsChange) = changed["result"]
			else { throw AutomationFailure.invalidRequest }
			#expect(settingsChange["operationID"] != nil)
			// A protected key never reaches Arx; the helper answers it with the reason.
			let protected = try await call("browser_settings", [
				"action": .string("setPreferences"),
				"operationID": .string(UUID().uuidString),
				"expectedRevision": .string(String(repeating: "a", count: 64)),
				"values": .object(["developerModeEnabled": .bool(true)]),
			])
			guard case let .object(refused) = protected["result"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(refused["code"], Value.string("protectedSetting"))
			expectNoDifference(started["status"], .string("acceptedLoading"))
			expectNoDifference(started["targetID"], .string(Fixture.startedDownload.uuidString))
			let positionCall = try await call("browser_media", ["action": .string("position"), "targetID": .string(tab)])
			guard
				case let .object(positionResult) = positionCall["result"],
				case let .object(mediaPosition) = positionResult["position"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(mediaPosition["position"], Value.double(0.5))
			expectNoDifference(mediaPosition["isMuted"], Value.bool(false))

			// Act and observe: the fixture denies the click, and the fresh snapshot of the same document still comes back.
			let observed = try await call("browser_click", [
				"operationID": .string(UUID().uuidString),
				"targetID": .string(tab),
				"expectedRevision": .string(revision),
				"snapshotID": .string(snapshotID),
				"reference": .string("opaque"),
				"returnSnapshot": .bool(true),
			])
			guard case let .object(fresh) = observed["snapshot"] else {
				Issue.record("Act-and-observe omitted the snapshot")
				throw AutomationFailure.invalidRequest
			}
			expectNoDifference(fresh["kind"], .string("inspection"))

			// Batch partial failure: the read runs, the denied click stops the batch and the reload never runs.
			let batch = try await call("browser_batch", ["steps": .array([
				.object(["tool": .string("browser_wait"), "arguments": .object([
					"targetID": .string(tab), "expectedRevision": .string(revision), "condition": .string("loadingStopped"),
				])]),
				.object(["tool": .string("browser_click"), "arguments": .object([
					"operationID": .string(UUID().uuidString), "targetID": .string(tab), "expectedRevision": .string(revision),
					"snapshotID": .string(snapshotID), "reference": .string("opaque"),
				])]),
				.object(["tool": .string("browser_tabs"), "arguments": .object([
					"operationID": .string(UUID().uuidString), "action": .string("reload"),
					"targetID": .string(tab), "expectedRevision": .string(revision),
				])]),
			])])
			guard
				case let .object(batchResult) = batch["result"],
				case let .array(steps) = batchResult["steps"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(batchResult["completed"], .int(1))
			expectNoDifference(batchResult["stoppedAt"], .int(1))
			expectNoDifference(steps.count, 2)

			// Subscriptions: an ungranted tab is unknown, and a navigation in the granted one is reported.
			await #expect(throws: (any Error).self) {
				try await client.subscribeToResource(uri: "arx://tabs/\(UUID().uuidString)")
			}
			let uri = "arx://tabs/" + tab
			try await client.subscribeToResource(uri: uri)
			_ = try await call("browser_inventory", ["limit": .int(Fixture.navigationTrigger)])
			var iterator = updates.makeAsyncIterator()
			let first = await iterator.next()
			expectNoDifference(first, uri)

			// The navigation left the document, so act-and-observe says so instead of returning the new page.
			let moved = try await call("browser_click", [
				"operationID": .string(UUID().uuidString),
				"targetID": .string(tab),
				"expectedRevision": .string(revision),
				"snapshotID": .string(snapshotID),
				"reference": .string("opaque"),
				"returnSnapshot": .bool(true),
			])
			expectNoDifference(moved["snapshotUnavailable"], .string("documentChanged"))

			// The document changed, so a cursor cut from the old one can't continue.
			let stale = try await call("browser_inspect", ["cursor": .string(try #require(firstCursor))])
			guard case let .object(staleResult) = stale["result"]
			else { throw AutomationFailure.invalidRequest }
			expectNoDifference(staleResult["code"], .string("staleCursor"))

			await client.disconnect()
			try input.fileHandleForWriting.close()
			try await wait(process)
			#expect(process.terminationStatus == 0)
			await fixture.stop()
		} catch {
			await client.disconnect()
			if process.isRunning { process.terminate() }
			await fixture.stop()
			throw error
		}
	}

	@Test(.enabled(if: ProcessInfo.processInfo.environment["ARX_MCP_TEST_PYTHON"] != nil), .timeLimit(.minutes(1)))
	internal func pythonSDKClientUsesRealHelperAndIndependentProtocolImplementation() async throws {
		let fixture = try await Fixture.start()
		let process = Process()
		let output = Pipe()
		let errors = Pipe()
		process.executableURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_MCP_TEST_PYTHON"]))
		process.arguments = [try #require(ProcessInfo.processInfo.environment["ARX_MCP_TEST_SCRIPT"])]
		let testEnvironment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("ARX_MCP_TEST_") }
		process.environment = fixture.environment.merging(testEnvironment, uniquingKeysWith: { _, new in new })
		process.standardOutput = output
		process.standardError = errors
		try process.run()
		do {
			try await wait(process)
			#expect(process.terminationStatus == 0)
			let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
			#expect(printed == "Python MCP fixture passed\n")
			#expect(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
			await fixture.stop()
		} catch {
			if process.isRunning { process.terminate() }
			await fixture.stop()
			throw error
		}
	}

	private func wait(_ process: Process) async throws {
		let deadline = ContinuousClock.now + .seconds(20)
		while process.isRunning {
			guard ContinuousClock.now < deadline else {
				process.terminate()
				throw AutomationFailure.timedOut
			}
			try await Task.sleep(for: .milliseconds(20))
		}
	}

	@MainActor
	private final class Preferences {
		internal var value: AutomationPreferences

		/// Bumped to stand in for a navigation in a granted tab.
		internal var generation: Int
		internal var documentID: String

		internal init(_ value: AutomationPreferences) {
			self.value = value
			self.generation = 0
			self.documentID = "document"
		}
	}

	@MainActor
	private struct Fixture {
		/// The user's app-wide appearance: not the built-in default.
		internal static let chromeAppearance: ChromeAppearance = .init(tint: .init(hue: 30, intensity: 0.6))

		/// An inventory limit the fixture treats as the user removing the organize class.
		internal static let grantChangeTrigger: Int = 77

		/// An inventory limit the fixture treats as a navigation to a new document in the granted tab.
		internal static let navigationTrigger: Int = 78

		/// An inventory limit the fixture treats as the user removing the read class, with a navigation.
		internal static let revocationTrigger: Int = 79

		/// The download the fixture host reports for any startDownload.
		internal static let startedDownload: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000670")!

		internal var host: BrowserAutomationHost
		internal var directory: URL
		internal var environment: [String: String]

		internal static func start() async throws -> Self {
			let directory = URL(fileURLWithPath: "/tmp/arx-mcp-interop-" + UUID().uuidString.prefix(8))
			var organization = BrowserAutomationTests.organization()
			organization.tabs[0].restoration.url = URL(string: "https://capturecontext.dev/path?synthetic-private=1#fragment")!
			var client = BrowserAutomationTests.client(organization)
			client.capabilities = [.read, .screenshots, .pageContent, .interact, .organize, .browserAdmin, .downloads, .signIn]
			client.allowsFocusedTab = true
			let preferences = Preferences(.init(isEnabled: true, clients: [client]))
			let items = AutomationInventoryBuilder.items(client: client, organization: organization, snapshots: [:])
			let host = BrowserAutomationHost(directory: directory)
			func isCurrentTab(
				_ targetID: UUID,
				_ revision: String
			) -> Bool {
				items.contains { $0.kind == .tab && $0.id == targetID && $0.revision == revision }
			}

			host.configure(
				preferences: { preferences.value },
				receive: { [weak host] event in
					guard case let .request(request) = event else { return }
					let result: AutomationResult
					switch request.operation {
					case .inventory(_, Self.grantChangeTrigger):
						// The fixture's stand-in for the user editing the grant in Settings.
						preferences.value.clients[0].capabilities.remove(.organize)
						preferences.value.clients[0].grantRevision = UUID()
						result = .inventory(.init(items: []))

					case .inventory(_, Self.navigationTrigger):
						preferences.generation += 1
						preferences.documentID = "document-\(preferences.generation)"
						result = .inventory(.init(items: []))

					case .inventory(_, Self.revocationTrigger):
						preferences.generation += 1
						preferences.value.clients[0].capabilities.remove(.read)
						preferences.value.clients[0].grantRevision = UUID()
						result = .inventory(.init(items: []))

					case let .inventory(cursor, limit):
						do {
							var page = try AutomationInventoryBuilder.page(items, cursor: cursor, limit: limit)
							page.profiles = [.init(id: organization.profiles[0].id.rawValue, name: "Fixture")]
							page.chromeAppearance = Self.chromeAppearance
							result = .inventory(page)
						} catch {
							result = .failure(error as? AutomationFailure ?? .invalidRequest)
						}

					case let .capture(capture):
						if isCurrentTab(capture.targetID, capture.expectedRevision) {
							result = .capture(AutomationCaptureTests.result(request: capture))
						} else {
							result = .failure(.denied)
						}

					case let .inspect(inspection):
						if isCurrentTab(inspection.targetID, inspection.expectedRevision) {
							// Act and observe reads the original small snapshot; paged reads get native windows.
							var value = inspection.isPlain && inspection.maximumNodes == 256
							? AutomationInspectionTests.result()
							: AutomationInspectionTests.pagedResult().window(inspection)
							value.request = inspection
							value.snapshot.documentID = preferences.documentID
							result = .inspection(value)
						} else {
							result = .failure(.denied)
						}

					case let .wait(wait):
						if isCurrentTab(wait.targetID, wait.expectedRevision) {
							var value = AutomationWaitTests.result()
							value.request = wait
							value.source.target.tabID = .init(rawValue: wait.targetID)
							result = .wait(value)
						} else {
							result = .failure(.denied)
						}

					case let .batch(plan):
						result = .batch(.init(
							batchID: plan.batchID,
							approvedSteps: plan.steps.filter { $0.mutationID != nil }.count
						))

					case let .load(load):
						result = .load(.init(targetID: load.targetID, status: .alreadyLoaded))

					case let .pdf(pdf):
						result = .pdf(AutomationPDFTests.result(pdf))

					case let .findInPage(find):
						result = .findInPage(.init(targetID: find.targetID, matches: 3, active: 1, stopped: find.stop))

					case let .dialog(dialog):
						result = .dialog(.init(targetID: dialog.targetID))

					case let .media(media) where media.isControl:
						result = .media(.init(action: media.action, operationID: media.operationID, performed: true))

					case let .media(media) where media.action == .position:
						result = .media(.init(action: .position, position: .init(
							targetID: media.targetID ?? UUID(),
							token: "7.2",
							isMuted: false,
							position: 0.5,
							duration: 2,
							playbackRate: 1
						)))

					case .media:
						result = .media(.init(action: .list, sessions: items.filter { $0.kind == .tab }.prefix(1).map {
							.init(
								targetID: $0.id,
								token: "7.2",
								title: "Fixture video",
								playback: .playing,
								hasVideo: true,
								isInPictureInPicture: false,
								actions: [.pause, .enterPictureInPicture]
							)
						}))

					case let .command(command) where command.action == .startDownload:
						result = .command(.init(
							operationID: command.operationID,
							status: .acceptedLoading,
							targetID: Self.startedDownload
						))

					case let .settings(settings):
						result = .settings(.init(
							section: settings.section,
							revision: String(repeating: "a", count: 64),
							preferences: [.init(key: .warnsBeforeQuitting, value: .bool(false))],
							operationID: settings.change?.operationID
						))

					case .command, .click, .form, .scroll, .signIn, .data, .link, .script, .logs, .passwordSignIn:
						result = .failure(.denied)
					}
					host?.respond(request.id, result: result)
				},
				authorizeResponse: { _, _ in nil },
				focusedTab: { client in
					guard
						client.allowsFocusedTab,
						let tab = items.first(where: { $0.kind == .tab })
					else { return nil }

					return .init(tabID: tab.id, revision: tab.revision)
				},
				changes: { client in
					guard client.allowsRead else { return nil }
					let tabs = items.filter { $0.kind == .tab }.map { ($0.id, $0.revision + "#\(preferences.generation)") }
					return .init(tabs: Dictionary(uniqueKeysWithValues: tabs))
				}
			)
			let path = try await host.enable()
			return .init(
				host: host,
				directory: directory,
				environment: [
					"ARX_MCP_SOCKET": path,
					"ARX_MCP_CLIENT_ID": client.id.uuidString,
					"ARX_MCP_CREDENTIAL": String(repeating: "0", count: 64),
				]
			)
		}

		internal func stop() async {
			await host.stop()
			try? FileManager.default.removeItem(at: directory)
		}
	}
}
