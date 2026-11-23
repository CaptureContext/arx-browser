#if DEBUG
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture
import _MCP

/// Public-envelope oracle and owned delayed-subresource fixture. No script or page
/// action is executed by the tool; fixture setup alone navigates and releases HTTP.
internal enum AutomationWaitSmoke {
	internal enum Reply {
		case observation(Observation)
		case failure(AutomationFailure)
	}

	internal struct Observation: Equatable, Decodable {
		internal let targetID: UUID
		internal let profileID: UUID
		internal let expectedRevision: String
		internal let observedRevision: String
		internal let sessionRevision: UInt64
		internal let documentRevision: UInt64
		internal let errorCode: Int?

		internal init(from decoder: any Decoder) throws {
			let values = try decoder.container(keyedBy: CodingKeys.self)
			let errorCode = try values.decodeIfPresent(Int.self, forKey: .errorCode)
			let status = try values.decode(AutomationWaitResult.Status.self, forKey: .status)
			let expectedStatus: AutomationWaitResult.Status = errorCode == nil ? .stopped : .stoppedWithError
			let condition = try values.decode(AutomationWaitRequest.Condition.self, forKey: .condition)

			guard
				try values.decode(String.self, forKey: .kind) == "wait",
				condition == .loadingStopped,
				try values.decode(Bool.self, forKey: .historical),
				try !values.decode(Bool.self, forKey: .navigationCompleted),
				status == expectedStatus,
				let sessionRevision = try UInt64(values.decode(String.self, forKey: .sessionRevision)),
				let documentRevision = try UInt64(values.decode(String.self, forKey: .documentRevision)),
				documentRevision > 0
			else { throw AutomationSmokeFailure.invalidResponse }

			self.targetID = try values.decode(UUID.self, forKey: .targetID)
			self.profileID = try values.decode(UUID.self, forKey: .profileID)
			self.expectedRevision = try values.decode(String.self, forKey: .expectedRevision)
			self.observedRevision = try values.decode(String.self, forKey: .observedRevision)
			self.sessionRevision = sessionRevision
			self.documentRevision = documentRevision
			self.errorCode = errorCode
		}

		private enum CodingKeys: String, CodingKey {
			case kind, condition, status, historical, navigationCompleted, errorCode
			case targetID, profileID, expectedRevision, observedRevision, sessionRevision, documentRevision
		}
	}

	internal static func decode(_ result: CallTool.Result) throws -> Reply {
		guard try JSONEncoder().encode(result).count <= 262_144
		else { throw AutomationSmokeFailure.invalidResponse }

		if result.isError == true {
			guard case let .failure(failure) = try AutomationSmokeResponse.decode(result)
			else { throw AutomationSmokeFailure.invalidResponse }

			return .failure(failure)
		}

		guard
			result.isError == false,
			result.content.count == 1,
			case let .text(text, _, _) = result.content[0],
			let structured = result.structuredContent,
			try JSONDecoder().decode(Value.self, from: Data(text.utf8)) == structured
		else { throw AutomationSmokeFailure.invalidResponse }

		let envelope = try JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
		guard envelope.untrustedData else { throw AutomationSmokeFailure.invalidResponse }

		return .observation(envelope.result)
	}

	internal static func verify(
		_ reply: Reply,
		request: AutomationWaitRequest,
		profileID: Profile.ID
	) throws -> Observation {
		guard
			case let .observation(observation) = reply,
			observation.targetID == request.targetID,
			observation.profileID == profileID.rawValue,
			observation.expectedRevision == request.expectedRevision,
			observation.observedRevision.utf8.count == 64,
			observation.observedRevision.allSatisfy(\.isHexDigit)
		else { throw AutomationSmokeFailure.waitMismatch }

		return observation
	}

	internal static func isCommittedLoading(
		_ snapshot: BrowserSessionSnapshot?,
		viewer: BrowserNavigation,
		url: URL
	) -> Bool {
		guard let snapshot, let epoch = snapshot.documentRevision, epoch > 0
		else { return false }

		let navigation = snapshot.navigation
		return navigation.url == url
		&& navigation.title == "Arx wait committed"
		&& navigation.isLoading
		&& navigation.errorCode == nil
		&& navigation.history.contains(where: { $0.isCurrent && $0.url == url })
		&& viewer == navigation
	}

	@MainActor
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		session: AutomationSmokeSession,
		source: BrowserCore.Tab,
		paneID: UUID,
		baseURL: URL
	) async throws {
		let directory = baseURL.deletingLastPathComponent()
		let pageURL = directory.appendingPathComponent("wait/main")
		let releaseURL = directory.appendingPathComponent("wait/release")
		let connection = URLSession(configuration: .ephemeral)
		defer { connection.invalidateAndCancel() }

		do {
			store.send(.main(.viewer(.command(.navigate(pageURL), in: paneID, tabID: source.id))))

			// Restoration intentionally remains at the last completed load while the image is held.
			try await until {
				isCommittedLoading(
					engine.client.snapshot(source.id),
					viewer: store.main.viewer.item.navigation,
					url: pageURL
				)
			}
			print("ARX_MCP_WAIT_PHASE_COMMITTED_LOADING")

			let first = try await loadingItem(session, source: source, url: pageURL)
			let timeout = AutomationWaitRequest(
				targetID: source.id.rawValue,
				expectedRevision: first.revision,
				timeoutMilliseconds: 50
			)
			guard
				case .failure(.timedOut) = try await session.waitPage(timeout),
				engine.client.snapshot(source.id)?.navigation.isLoading == true
			else { throw AutomationSmokeFailure.waitMismatch }
			print("ARX_MCP_WAIT_PHASE_TIMEOUT_VERIFIED")

			let item = try await loadingItem(session, source: source, url: pageURL)
			let request = AutomationWaitRequest(
				targetID: source.id.rawValue,
				expectedRevision: item.revision,
				timeoutMilliseconds: 5000
			)
			guard
				let original = engine.client.snapshot(source.id),
				let epoch = original.documentRevision
			else { throw AutomationSmokeFailure.missingSource }

			let focusedWindow = store.focusedWindowID
			let activePane = store.main.viewer.activePaneID
			let task = Task { try await session.waitPage(request) }
			defer { task.cancel() }
			try await until {
				store.automation.pending.values.contains {
					guard case let .wait(pending) = $0.request.operation else { return false }

					return pending == request
					&& $0.executing
					&& $0.waitTarget?.documentRevision == epoch
					&& $0.snapshots[source.id]?.navigation.isLoading == true
				}
			}
			print("ARX_MCP_WAIT_PHASE_PENDING_OBSERVATION")
			try await release(connection, url: releaseURL)

			let observed = try verify(
				await task.value,
				request: request,
				profileID: source.profileID
			)
			guard
				observed.documentRevision == epoch,
				observed.sessionRevision > original.revision,
				observed.observedRevision != request.expectedRevision,
				observed.errorCode == nil,
				engine.client.snapshot(source.id)?.documentRevision == epoch,
				engine.client.snapshot(source.id)?.navigation.url == pageURL,
				engine.client.snapshot(source.id)?.navigation.isLoading == false,
				store.focusedWindowID == focusedWindow,
				store.main.viewer.activePaneID == activePane
			else { throw AutomationSmokeFailure.waitMismatch }

			try await until {
				store.workspace.tabs[id: source.id]?.restoration.url == pageURL
			}
			print("ARX_MCP_WAIT_PHASE_STOPPED_VERIFIED")

			// Reusing the original inventory revision cannot silently observe a replacement.
			let replacement = directory.appendingPathComponent("mcp-next.html")
			store.send(.main(.viewer(.command(.navigate(replacement), in: paneID, tabID: source.id))))
			try await until {
				guard let snapshot = engine.client.snapshot(source.id) else { return false }

				return snapshot.navigation.url == replacement
				&& !snapshot.navigation.isLoading
				&& snapshot.documentRevision != epoch
			}
			guard case .failure(.staleTarget) = try await session.waitPage(request)
			else { throw AutomationSmokeFailure.waitMismatch }
			print("ARX_MCP_WAIT_PHASE_STALE_TARGET_VERIFIED")

		} catch {
			// Even failed assertions release the controlled image before normal fixture cleanup.
			try? await release(connection, url: releaseURL)
			throw error
		}
	}

	@MainActor
	private static func loadingItem(
		_ session: AutomationSmokeSession,
		source: BrowserCore.Tab,
		url: URL
	) async throws -> AutomationInventoryItem {
		guard
			case let .inventory(inventory) = try await session.inventory(),
			inventory.nextCursor == nil,
			inventory.items.count == 1,
			let item = inventory.items.first,
			item.id == source.id.rawValue,
			item.profileID == source.profileID.rawValue,
			item.kind == .tab,
			item.sessionState == .loading,
			item.url == AutomationAccess.sanitizedURL(url)
		else { throw AutomationSmokeFailure.inventoryMismatch }

		return item
	}

	private static func release(
		_ connection: URLSession,
		url: URL
	) async throws {
		var request = URLRequest(url: url)
		request.timeoutInterval = 2
		let (bytes, response) = try await connection.data(for: request)

		guard
			(response as? HTTPURLResponse)?.statusCode == 200,
			bytes == Data("released".utf8)
		else { throw AutomationSmokeFailure.waitMismatch }
	}

	@MainActor
	private static func until(_ ready: () -> Bool) async throws {
		for _ in 0..<100 {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(50))
		}
		throw AutomationSmokeFailure.timedOut
	}

	private struct Envelope: Decodable {
		internal let untrustedData: Bool
		internal let result: Observation

		internal init(
			untrustedData: Bool,
			result: Observation
		) {
			self.untrustedData = untrustedData
			self.result = result
		}
	}
}
#endif
