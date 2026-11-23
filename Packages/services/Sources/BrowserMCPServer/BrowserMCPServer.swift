import BrowserAutomationClient
import BrowserCore
import Darwin
import Foundation
import Synchronization
import _MCP

public enum BrowserMCPServer {
	public static let protocolVersion: String = "2025-11-25"

	public static func run(
		environment: [String: String] = ProcessInfo.processInfo.environment
	) async {
		signal(SIGPIPE, SIG_IGN)
		guard
			let path = environment["ARX_MCP_SOCKET"],
			path.utf8.count < 104,
			let id = environment["ARX_MCP_CLIENT_ID"].flatMap(UUID.init(uuidString:)),
			let credential = environment["ARX_MCP_CREDENTIAL"],
			credential.utf8.count == 64
		else {
			FileHandle.standardError.write(
				Data("Arx MCP configuration is missing or invalid. Create a client in Arx Settings.\n".utf8)
			)
			return
		}
		let gateway = AutomationGateway(
			path: path,
			clientID: id,
			credential: credential
		)
		let server = Server(
			name: "arx",
			version: "0.1.0",
			instructions: AutomationTools.instructions,
			capabilities: .init(
				resources: .init(subscribe: true, listChanged: true),
				tools: .init(listChanged: true)
			),
			configuration: .strict
		)
		let calls = AutomationCalls(gateway: gateway)
		let run = AutomationRun(calls: calls)
		let resources = AutomationResources(gateway: gateway)
		let listing = AutomationToolListing()
		let client = ClientName()
		await server.withMethodHandler(ListTools.self) { parameters in
			guard parameters.cursor == nil
			else { throw MCPError.invalidParams("Tool cursor is not supported") }
			return .init(tools: AutomationTools.definitions(for: await gateway.grants, listing: await listing.listing))
		}
		await server.withMethodHandler(CallTool.self) { [weak server] parameters in

			// Listing more tools changes only this connection's listing: nothing waits on Arx.
			if parameters.name == AutomationTools.moreToolsName {
				let answer = try await listing.moreTools(parameters.arguments ?? [:], grants: await gateway.grants)
				if answer.changed {
					try? await server?.notify(ToolListChangedNotification.message())
				}
				return answer.result
			}

			let token = parameters._meta?.progressToken
			let notifier = server
			let progress = Progress(token: token) { notification in
				try? await notifier?.notify(notification)
			}
			let wait = AutomationGateway.UserWait(
				limit: userWaitLimit(client: client.name.withLock { $0 }, hearsProgress: token != nil),
				call: callIdentity(parameters.name, arguments: parameters.arguments ?? [:]),
				progress: { await progress.send($0) }
			)
			let arguments = parameters.arguments ?? [:]
			return try await AutomationGateway.$userWait.withValue(wait) {
				// browser_run's steps are tool calls, each waiting for the user as a single call would.
				if parameters.name == "browser_run" { return try await run.run(arguments) }
				return try await calls.call(parameters.name, arguments: arguments)
			}
		}
		await resources.register(on: server)
		await gateway.onGrantsChanged { [weak server] _ in
			try? await server?.notify(ToolListChangedNotification.message())
			await resources.grantsChanged()
		}
		await gateway.onHeartbeat {
			await resources.poll()
		}
		do {
			try await server.start(transport: BoundedStdioTransport()) { info, _ in
				client.name.withLock { $0 = info.name }
				await listing.choose(client: info.name, environment: environment)
				do {
					try await gateway.initialize()
				} catch {
					let reason = (error as? AutomationFailure)?.rawValue
					?? AutomationFailure.appUnavailable.rawValue
					throw MCPError.internalError("Arx connection failed: " + reason)
				}
			}
			await server.waitUntilCompleted()
		} catch {
			FileHandle.standardError.write(Data("Arx MCP connection ended.\n".utf8))
		}
		await gateway.disconnect()
		await server.stop()
	}

	/// How long a call waits for the user before it says so (DEV-1024). Claude Code shows a
	/// call's progress lines and lets it run on, so it waits up to 10 minutes and hears what Arx
	/// asks at once. Other clients end calls sooner (Codex at 60 seconds) and get the question
	/// back in 15 seconds, to pass it to their user and call again.
	internal static func userWaitLimit(
		client: String?,
		hearsProgress: Bool
	) -> Duration {
		let isClaude = client?.lowercased().contains("claude") == true
		return hearsProgress && isClaude ? .seconds(600) : .seconds(15)
	}

	/// A tool call as the same call again would make it: its name and sorted arguments.
	internal static func callIdentity(
		_ name: String,
		arguments: [String: Value]
	) -> String? {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		guard let data = try? encoder.encode(Value.object(arguments)) else { return nil }
		return name + " " + String(decoding: data, as: UTF8.self)
	}

	/// The name the client gave when it connected.
	private final class ClientName: Sendable {
		internal let name: Mutex<String?> = .init(nil)
	}

	/// Sends a call's progress lines when its client asked for them, numbered in order.
	private actor Progress {
		private let token: ProgressToken?
		private let notify: @Sendable (Message<ProgressNotification>) async -> Void
		private var count: Int = 0

		internal init(
			token: ProgressToken?,
			notify: @escaping @Sendable (Message<ProgressNotification>) async -> Void
		) {
			self.token = token
			self.notify = notify
		}

		internal func send(_ message: String) async {
			guard let token else { return }
			count += 1
			await notify(ProgressNotification.message(.init(
				progressToken: token,
				progress: Double(count),
				message: message
			)))
		}
	}

	/// A result checked against its own delivery bounds; an oversized or invalid one becomes a failure.
	internal static func validated(_ result: AutomationResult) -> AutomationResult {
		do {
			switch result {
			case let .wait(wait): try wait.validate()
			case let .inspection(inspection): try inspection.validate()
			case let .capture(capture): try capture.validate()
			case let .pdf(pdf): try pdf.validate()
			case let .media(media): try media.validate()
			case let .script(script): try script.validate()
			case let .logs(logs): try logs.validate()
			default: break
			}
			return result

		} catch {
			return .failure(error as? AutomationFailure ?? .invalidRequest)
		}
	}

	/// Whether a result ends a batch: an explicit failure, or a receipt that reports one.
	internal static func isFailure(_ result: AutomationResult) -> Bool {
		switch result {
		case .failure: true
		case let .click(receipt): receipt.failure != nil
		case let .form(receipt): receipt.failure != nil
		case let .scroll(receipt): receipt.failure != nil
		case let .command(command): command.status == .cancelled
		default: false
		}
	}

	internal static func toolResult(
		_ result: AutomationResult,
		focusedTab: UUID? = nil,
		extra: [String: Value] = [:]
	) throws -> CallTool.Result {
		let result = validated(result)
		var fields: [String: Value] = extra
		fields["untrustedData"] = .bool(true)
		fields["result"] = try payload(result)
		if let focusedTab {
			fields["focusedTab"] = .string(focusedTab.uuidString)
		}
		var images: [AutomationCaptureImage] = []
		if case let .capture(capture) = result {
			images.append(capture.image)
		}
		var resources: [Resource.Content] = []
		if case let .pdf(pdf) = result, let data = pdf.data {
			resources.append(.binary(data, uri: "arx://pdf/" + pdf.digest, mimeType: "application/pdf"))
		}
		let response = try envelope(fields, images: images, resources: resources, isError: isFailure(result))
		guard fits(response) else {
			// Extra observation data is optional; the action's own result never is.
			if !extra.isEmpty {
				return try toolResult(
					result,
					focusedTab: focusedTab,
					extra: ["snapshot": .null, "snapshotUnavailable": .string(AutomationFailure.limitExceeded.rawValue)]
				)
			}
			return try toolResult(.failure(.limitExceeded))
		}
		return response
	}

	internal static func envelope(
		_ fields: [String: Value],
		images: [AutomationCaptureImage] = [],
		resources: [Resource.Content] = [],
		isError: Bool
	) throws -> CallTool.Result {
		let value: Value = .object(fields)
		let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
		var content: [Tool.Content] = [.text(text: text, annotations: nil, _meta: nil)]
		for image in images {
			content.append(.image(
				data: image.data.base64EncodedString(),
				mimeType: image.format.mimeType,
				annotations: nil,
				_meta: nil
			))
		}
		for resource in resources {
			content.append(.resource(resource: resource))
		}
		return CallTool.Result(
			content: content,
			structuredContent: Optional(value),
			isError: isError
		)
	}

	/// The same answer with `added` beside its `result`, or `nil` when that no longer fits.
	internal static func adding(
		_ added: [String: Value],
		to response: CallTool.Result
	) throws -> CallTool.Result? {
		guard
			case var .object(fields)? = response.structuredContent,
			case .text? = response.content.first
		else { return nil }

		fields.merge(added) { $1 }
		let value: Value = .object(fields)
		var content: [Tool.Content] = response.content
		content[0] = .text(
			text: String(decoding: try JSONEncoder().encode(value), as: UTF8.self),
			annotations: nil,
			_meta: nil
		)
		let result = CallTool.Result(
			content: content,
			structuredContent: Optional(value),
			isError: response.isError
		)
		return fits(result) ? result : nil
	}

	/// The image appears once; reserve space for the bounded JSON-RPC ID and envelope.
	/// A response carrying images gets the image frame budget.
	internal static func fits(_ response: CallTool.Result) -> Bool {
		guard let encoded = try? JSONEncoder().encode(response) else { return false }
		let carriesImages = response.content.contains { content in
			switch content {
			case .image, .resource: true
			default: false
			}
		}
		let limit = carriesImages ? AutomationIPC.maximumImageResponseBytes : AutomationIPC.maximumResponseBytes
		return encoded.count <= limit - 1024
	}

	internal static func payload(_ result: AutomationResult) throws -> Value {
		switch result {
		case let .signIn(value):
			return .object([
				"kind": .string("signIn"),
				"operationID": .string(value.operationID.uuidString),
				"status": .string(value.status.rawValue),
			])

		case let .wait(wait):
			return .object([
				"kind": .string("wait"),
				"targetID": .string(wait.request.targetID.uuidString),
				"profileID": .string(wait.source.target.profileID.rawValue.uuidString),
				"condition": .string(wait.request.condition.rawValue),
				"status": .string(wait.status.rawValue),
				"expectedRevision": .string(wait.request.expectedRevision),
				"observedRevision": .string(wait.observedRevision),
				"sessionRevision": .string(String(wait.sessionRevision)),
				"documentRevision": .string(String(wait.source.target.documentRevision)),
				"errorCode": wait.errorCode.map(Value.int) ?? .null,
				"historical": .bool(true),
				"navigationCompleted": .bool(false),
			])

		case let .scroll(receipt):
			return .object([
				"kind": .string("scroll"),
				"operationID": .string(receipt.operationID.uuidString),
				"disposition": .string(receipt.disposition.rawValue),
				"failure": receipt.failure.map { .string($0.rawValue) } ?? .null,
				"navigationCompleted": .bool(false),
			])

		case let .form(receipt):
			return .object([
				"kind": .string("form"),
				"operationID": .string(receipt.operationID.uuidString),
				"disposition": .string(receipt.disposition.rawValue),
				"failure": receipt.failure.map { .string($0.rawValue) } ?? .null,
				"navigationCompleted": .bool(false),
			])

		case let .click(receipt):
			return .object([
				"kind": .string("click"),
				"operationID": .string(receipt.operationID.uuidString),
				"disposition": .string(receipt.disposition.rawValue),
				"failure": receipt.failure.map { .string($0.rawValue) } ?? .null,
				"navigationCompleted": .bool(false),
			])

		case let .inspection(inspection):
			let snapshot = inspection.snapshot
			return .object([
				"kind": .string("inspection"),
				"targetID": .string(inspection.request.targetID.uuidString),
				"expectedRevision": .string(inspection.request.expectedRevision),
				"profileID": .string(inspection.source.profileID.rawValue.uuidString),
				"sessionRevision": .string(String(inspection.source.sessionRevision)),
				"documentRevision": .string(String(inspection.source.documentRevision)),
				"snapshotID": .string(snapshot.snapshotID),
				"documentID": .string(snapshot.documentID),
				"frameID": .string(snapshot.frameID),
				"domVersion": .string(snapshot.domVersion),
				"historical": .bool(true),
				"referencesAuthorizeActions": .bool(false),
				"nodes": try Value(encoding: snapshot.nodes),
				"omissions": try Value(encoding: snapshot.omissions),
			])

		case let .capture(capture):
			return .object([
				"kind": .string("capture"),
				"targetID": .string(capture.request.targetID.uuidString),
				"expectedRevision": .string(capture.request.expectedRevision),
				"sessionRevision": .string(String(capture.sessionRevision)),
				"documentRevision": .string(String(capture.documentRevision)),
				"profileID": .string(capture.profileID.rawValue.uuidString),
				"documentID": .string(capture.documentID),
				"snapshotID": .string(capture.snapshotID.uuidString),
				"mode": .string(capture.request.mode.rawValue),
				"region": try capture.request.region.map { try Value(encoding: $0) } ?? .null,
				"width": .int(capture.image.width),
				"height": .int(capture.image.height),
				"format": .string(capture.image.format.rawValue),
				"offscreen": .bool(capture.request.offscreen),
				"elementRegion": try capture.elementRegion.map { try Value(encoding: $0) } ?? .null,
				"scale": .double(capture.request.scale),
				"quality": capture.request.quality.map(Value.double) ?? .null,
				"documentGeometry": try capture.documentGeometry.map { try Value(encoding: $0) } ?? .null,
				"viewportWidth": .double(capture.viewportWidth),
				"viewportHeight": .double(capture.viewportHeight),
				"deviceScale": .double(capture.deviceScale),
				"wasLoading": .bool(capture.wasLoading),
				"save": capture.save.map { save in
					switch save {
					case let .saved(fileName): .object(["status": .string("saved"), "fileName": .string(fileName)])
					case .declined: .object(["status": .string("declined")])
					}
				} ?? .null,
				"warnings": .array([.string("protectedMediaMayBeMissing")]),
			])

		case let .inventory(inventory):
			return .object([
				"kind": .string("inventory"),
				"items": try Value(encoding: inventory.items),
				"nextCursor": inventory.nextCursor.map(Value.string) ?? .null,
				"presentations": try Value(encoding: inventory.presentations),
			])

		case let .command(command):
			return .object([
				"kind": .string("command"),
				"operationID": .string(command.operationID.uuidString),
				"status": .string(command.status.rawValue),
				"targetID": command.targetID.map { .string($0.uuidString) } ?? .null,
				"presentation": try command.presentation.map { try Value(encoding: $0) } ?? .null,
				"route": try command.route.map { try Value(encoding: $0) } ?? .null,
			])

		case let .data(page):
			return .object([
				"kind": .string(page.request.kind.rawValue),
				"items": try Value(encoding: page.items),
				"nextCursor": page.nextCursor.map(Value.string) ?? .null,
			])

		case let .link(link):
			return .object([
				"kind": .string("link"),
				"mode": .string(link.request.kind.rawValue),
				"url": .string(link.url),
				"outcome": .string(link.outcome),
			])

		case let .pdf(pdf):
			return .object([
				"kind": .string("pdf"),
				"action": .string(pdf.request.kind.rawValue),
				"targetID": .string(pdf.request.targetID.uuidString),
				"profileID": .string(pdf.profileID.rawValue.uuidString),
				"documentRevision": .string(String(pdf.documentRevision)),
				"documentID": .string(pdf.documentID),
				"digest": .string(pdf.digest),
				"pageCount": .int(pdf.pageCount),
				"totalBytes": .int(pdf.totalBytes),
				"offset": .int(pdf.request.offset),
				"text": pdf.text.map(Value.string) ?? .null,
				"nextOffset": pdf.nextOffset.map(Value.int) ?? .null,
			])

		case let .findInPage(find):
			return .object([
				"kind": .string("findInPage"),
				"targetID": .string(find.targetID.uuidString),
				"matches": find.matches.map(Value.int) ?? .null,
				"active": find.active.map(Value.int) ?? .null,
				"stopped": .bool(find.stopped),
			])

		case let .media(media):
			return try AutomationTools.mediaPayload(media)

		case let .settings(settings):
			return try AutomationTools.settingsPayload(settings)

		case let .script(script):
			return AutomationTools.scriptPayload(script)

		case let .logs(logs):
			return AutomationTools.logsPayload(logs)

		case let .passwordSignIn(value):
			guard case var .object(fields) = AutomationTools.passwordSignInPayload(value)
			else { throw AutomationFailure.invalidRequest }

			fields["kind"] = .string("passwordSignIn")
			return .object(fields)

		case let .dialog(dialog):
			// The prompt answer is never echoed; page text is marked untrusted.
			var value: [String: Value] = [
				"kind": .string("dialog"),
				"targetID": .string(dialog.targetID.uuidString),
				"answered": .bool(dialog.answered),
			]
			if let operationID = dialog.operationID { value["operationID"] = .string(operationID.uuidString) }
			if let failure = dialog.failure { value["failure"] = .string(failure.rawValue) }
			if let page = dialog.dialog {
				var description: [String: Value] = [
					"token": .string(page.token),
					"type": .string(page.kind.rawValue),
					"message": .string(page.message),
				]
				if let prompt = page.defaultPrompt { description["defaultPrompt"] = .string(prompt) }
				if let origin = page.origin { description["origin"] = .string(origin) }
				value["dialog"] = .object(description)
			} else {
				value["dialog"] = .null
			}
			return .object(value)

		case let .load(load):
			return .object([
				"kind": .string("load"),
				"targetID": .string(load.targetID.uuidString),
				"status": .string(load.status.rawValue),
			])

		case let .batch(approval):
			return .object([
				"kind": .string("batchApproval"),
				"batchID": .string(approval.batchID.uuidString),
				"approvedSteps": .int(approval.approvedSteps),
			])

		case let .failure(error):
			guard let message = error.message
			else { return .object(["kind": .string("error"), "code": .string(error.rawValue)]) }

			var value: [String: Value] = [
				"kind": .string("error"),
				"code": .string(error.rawValue),
				"message": .string(message),
			]

			// What Arx asks, said the way its own prompt names the request (DEV-1024).
			if error == .waitingForUser, let wait = AutomationGateway.userWait?.note.wait.withLock({ $0 }) {
				value["asking"] = .string(wait.question)
			}
			return .object(value)
		}
	}

}
