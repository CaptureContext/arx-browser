#if DEBUG
import BrowserCore
import Foundation
import _ComposableArchitecture
import _MCP

/// Starts, lists and cancels a real Chromium download through the bundled MCP helper,
/// in the disposable profile whose download folder the runner owns.
@MainActor
internal enum AutomationDownloadSmoke {
	internal static func run(
		store: StoreOf<AppFeature>,
		session: () throws -> AutomationSmokeSession,
		client: AutomationClient,
		profileID: Profile.ID,
		url: URL
	) async throws {
		var granted = client
		granted.scopes += [.profile(profileID)]
		granted.capabilities.remove(.downloads)

		// A temporary grant covers other mutations; a download must still ask.
		granted.mutationGrantUntil = Date().addingTimeInterval(90)
		granted.approvalPolicy = .alwaysAsk
		await store.send(.automation(.ui(.updateClient(granted)))).finish()
		try await wait("sessions closed after the grant change") { store.automation.sessions.isEmpty }

		// Without the downloads class the tool isn't listed, and a direct call is denied.
		let unclassed = try session()
		try await unclassed.connect(grantedBy: store.automationPreferences)
		let profile = try await profileItem(profileID, in: unclassed)
		let before = store.downloads.queue
		let refused = try await unclassed.downloads(start(profile, url: url))
		guard refused == .failure(.denied), store.automation.pending.isEmpty
		else { throw AutomationSmokeMismatch(.authorizationFailed, check: "mcpDownload.unclassedStart", expected: "denied", actual: "\(refused)") }
		guard await unclassed.close() else { throw AutomationSmokeFailure.helperFailed }

		granted.capabilities.insert(.downloads)
		await store.send(.automation(.ui(.updateClient(granted)))).finish()
		try await wait("sessions closed after granting downloads") { store.automation.sessions.isEmpty }
		let session = try session()
		try await session.connect(grantedBy: store.automationPreferences)
		let current = try await profileItem(profileID, in: session)
		let operationID = UUID()
		let pending = Task { try await session.downloads(start(current, url: url, operationID: operationID)) }
		try await wait("startDownload awaiting approval") {
			store.automation.pending.values.contains { pending in
				guard case let .command(command) = pending.request.operation else { return false }
				return command.operationID == operationID && pending.awaitingApproval
			}
		}
		guard store.downloads.queue.downloads.count == before.downloads.count
		else { throw AutomationSmokeMismatch(.authorizationFailed, check: "mcpDownload.startedBeforeApproval", expected: "no new download", actual: "\(store.downloads.queue.downloads.count)") }
		guard
			let requestID = store.automation.pending.first(where: { $0.value.awaitingApproval })?.key
		else { throw AutomationSmokeFailure.setupFailed }

		store.send(.automation(.ui(.approve(requestID))))
		let started = try await pending.value
		guard
			case let .command(result) = started,
			result.operationID == operationID,
			result.status == .acceptedLoading,
			let downloadID = result.targetID
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDownload.start", expected: "acceptedLoading with a download", actual: "\(started)") }
		print("ARX_MCP_DOWNLOAD_PHASE_STARTED")

		let listed = try await session.downloads(["action": .string("list")])
		guard
			case let .data(page) = listed,
			let item = page.items.first(where: { $0.id == downloadID }),
			item.profileID == profileID.rawValue,
			item.status == BrowserDownload.Status.inProgress.rawValue,
			item.url?.hasPrefix(url.absoluteString.components(separatedBy: "?")[0]) == true
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDownload.list", expected: "the started download in progress", actual: "\(listed)") }
		print("ARX_MCP_DOWNLOAD_PHASE_LISTED")

		// The temporary grant covers cancelling, so it runs without asking.
		let cancelled = try await session.downloads([
			"action": .string("cancelDownload"),
			"operationID": .string(UUID().uuidString),
			"targetID": .string(item.id.uuidString),
			"expectedRevision": .string(item.revision),
		])
		guard case let .command(cancel) = cancelled, cancel.status == .committed
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDownload.cancel", expected: "committed", actual: "\(cancelled)") }

		var final: AutomationDataItem?
		try await wait("cancelled download listed") {
			guard
				case let .data(page) = try? await session.downloads(["action": .string("list")]),
				let item = page.items.first(where: { $0.id == downloadID })
			else { return false }

			final = item
			return item.status == BrowserDownload.Status.cancelled.rawValue
		}
		guard final?.receivedBytes.map({ $0 < 8 * 1024 * 1024 }) != false
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDownload.cancelled", expected: "a partial transfer", actual: "\(String(describing: final))") }
		guard await session.close() else { throw AutomationSmokeFailure.helperFailed }

		print("ARX_MCP_DOWNLOAD_NATIVE_SMOKE_SUCCESS")
	}

	private static func start(
		_ profile: AutomationInventoryItem,
		url: URL,
		operationID: UUID = UUID()
	) -> [String: Value] {
		[
			"action": .string("startDownload"),
			"operationID": .string(operationID.uuidString),
			"targetID": .string(profile.id.uuidString),
			"expectedRevision": .string(profile.revision),
			"url": .string(url.absoluteString),
		]
	}

	private static func profileItem(
		_ profileID: Profile.ID,
		in session: AutomationSmokeSession
	) async throws -> AutomationInventoryItem {
		guard
			case let .inventory(inventory) = try await session.inventory(),
			let item = inventory.items.first(where: { $0.kind == .profile && $0.id == profileID.rawValue })
		else { throw AutomationSmokeMismatch(.invalidResponse, check: "mcpDownload.profileItem", expected: "the granted profile", actual: "missing") }

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
			else { throw SmokeDiagnostics.timeout(site: "AutomationDownloadSmoke.\(site)", since: start, state: "") }

			try await Task.sleep(for: .milliseconds(50))
		}
	}
}

extension AutomationSmokeSession {
	/// Calls `browser_downloads`; a list decodes as data, anything else as the other tools do.
	internal func downloads(_ arguments: [String: Value]) async throws -> AutomationResult {
		let result = try await rawCall("browser_downloads", arguments: arguments)
		guard
			result.isError != true,
			let structured = result.structuredContent,
			let envelope = try? JSONDecoder().decode(
				DownloadsEnvelope.self,
				from: JSONEncoder().encode(structured)
			),
			envelope.untrustedData,
			envelope.result.kind == AutomationDataRequest.Kind.downloads.rawValue
		else { return try AutomationSmokeResponse.decode(result) }

		return .data(.init(
			request: .init(kind: .downloads),
			items: envelope.result.items,
			nextCursor: envelope.result.nextCursor
		))
	}

	private struct DownloadsEnvelope: Decodable {
		fileprivate let untrustedData: Bool
		fileprivate let result: Page
	}

	private struct Page: Decodable {
		fileprivate let kind: String
		fileprivate let items: [AutomationDataItem]
		fileprivate let nextCursor: String?
	}
}
#endif
