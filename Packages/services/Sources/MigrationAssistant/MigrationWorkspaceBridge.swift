import BrowserCore
import Foundation
import _Dependencies

/// Lets the import, which runs off the main actor, read and change the workspace
/// that AppFeature owns. AppFeature serves `requests` and answers each one.
public final class MigrationWorkspaceBridge: Sendable {
	public static let shared: MigrationWorkspaceBridge = .init()

	public enum Request: Sendable {
		case state(UUID)
		case commit(UUID, MigrationBatch)
	}

	public let requests: AsyncStream<Request>

	private let continuation: AsyncStream<Request>.Continuation
	private let pending: Pending = .init()

	/// `finished` makes a bridge nobody serves, whose requests fail at once.
	public init(finished: Bool = false) {
		(self.requests, self.continuation) = AsyncStream.makeStream(of: Request.self)
		if finished { continuation.finish() }
	}

	public var writer: MigrationDestinationWriter {
		.init(
			state: { [self] in
				let reply = try await send { .state($0) }
				guard case let .state(state) = reply
				else { throw MigrationFailure.invalidDestination }
				return state
			},
			commit: { [self] batch in
				_ = try await send { .commit($0, batch) }
			}
		)
	}

	public func answer(
		_ id: UUID,
		state: MigrationDestinationState
	) async {
		await pending.resume(id, with: .success(.state(state)))
	}

	public func answerCommitted(_ id: UUID) async {
		await pending.resume(id, with: .success(.committed))
	}

	public func fail(
		_ id: UUID,
		message: String
	) async {
		await pending.resume(id, with: .failure(BridgeFailure(message: message)))
	}

	private func send(_ request: (UUID) -> Request) async throws -> Reply {
		let id = UUID()
		let request = request(id)
		return try await withCheckedThrowingContinuation { reply in
			Task { [pending, continuation] in
				await pending.store(reply, for: id)
				if case .terminated = continuation.yield(request) {
					await pending.resume(id, with: .failure(MigrationFailure.invalidDestination))
				}
			}
		}
	}

	private enum Reply: Sendable {
		case state(MigrationDestinationState)
		case committed
	}

	private struct BridgeFailure: LocalizedError {
		internal let message: String

		internal init(message: String) {
			self.message = message
		}

		internal var errorDescription: String? { message }
	}

	private actor Pending {
		private var replies: [UUID: CheckedContinuation<Reply, any Error>] = [:]

		internal func store(
			_ reply: CheckedContinuation<Reply, any Error>,
			for id: UUID
		) {
			replies[id] = reply
		}

		internal func resume(
			_ id: UUID,
			with result: Result<Reply, any Error>
		) {
			replies.removeValue(forKey: id)?.resume(with: result)
		}
	}
}

extension MigrationWorkspaceBridge: DependencyKey {
	public static var liveValue: MigrationWorkspaceBridge { .shared }
	public static var testValue: MigrationWorkspaceBridge { .init(finished: true) }
	public static var previewValue: MigrationWorkspaceBridge { .init(finished: true) }
}

extension DependencyValues {
	public var migrationWorkspace: MigrationWorkspaceBridge {
		get { self[MigrationWorkspaceBridge.self] }
		set { self[MigrationWorkspaceBridge.self] = newValue }
	}
}
