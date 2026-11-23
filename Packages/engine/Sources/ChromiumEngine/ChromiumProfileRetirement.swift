import ChromiumBridge
import Foundation

/// Persist this identity alongside the workspace before opting into native retirement.
/// A new identity each launch cannot adopt an existing retirement ledger.
public struct ChromiumProfileRetirementConfiguration: Equatable, Sendable {
	public let installationID: UUID
	public let legacyProfileID: UUID

	public init(
		installationID: UUID,
		legacyProfileID: UUID
	) {
		self.installationID = installationID
		self.legacyProfileID = legacyProfileID
	}
}

public enum ChromiumProfileRetirementFailure: Error, Equatable, Sendable {
	case unavailable
	case busy
	case stale
	case invalid
	case corrupt
	case ownershipChanged
	case limit
	case io
}

public struct ChromiumProfileRetirementSnapshot: Equatable, Sendable {
	public struct Record: Equatable, Sendable {
		public enum State: UInt32, Equatable, Sendable {
			case active = 0
			case awaitingStartup = 1
			case quarantinePending = 2
			case restartRequired = 3
			case verificationPending = 4
			case erased = 5
			case blocked = 6
		}

		public let profileID: UUID
		public let requestID: UUID?
		public let isLegacy: Bool
		public let state: State

		internal init(
			profileID: UUID,
			requestID: UUID?,
			isLegacy: Bool,
			state: State
		) {
			self.profileID = profileID
			self.requestID = requestID
			self.isLegacy = isLegacy
			self.state = state
		}
	}

	public let revision: UInt64
	public let isDurable: Bool
	public let records: [Record]

	internal init(
		revision: UInt64,
		isDurable: Bool,
		records: [Record]
	) {
		self.revision = revision
		self.isDurable = isDurable
		self.records = records
	}

	internal init(native: ArxProfileRetirementSnapshot) throws {
		guard
			native.record_count <= 128,
			native.record_count == 0 || native.records != nil
		else { throw ChromiumProfileRetirementFailure.invalid }
		var records: [Record] = []
		var profiles: Set<UUID> = []
		var requests: Set<UUID> = []
		for index in 0..<native.record_count {
			guard
				let value = native.records?[index],
				let profile = Self.uuid(value.profile_id),
				profiles.insert(profile).inserted,
				let state = Record.State(rawValue: value.progress.rawValue)
			else { throw ChromiumProfileRetirementFailure.invalid }

			let request: UUID?
			if state == .active {
				guard let bytes = value.request_id, bytes.pointee == 0
				else { throw ChromiumProfileRetirementFailure.invalid }
				request = nil

			} else {
				request = Self.uuid(value.request_id)
				guard let request, requests.insert(request).inserted
				else { throw ChromiumProfileRetirementFailure.invalid }
			}
			records.append(
				.init(
					profileID: profile,
					requestID: request,
					isLegacy: value.legacy_storage,
					state: state
				)
			)
		}
		self.init(
			revision: native.revision,
			isDurable: native.durable,
			records: records
		)
	}

	private static func uuid(_ bytes: UnsafePointer<CChar>?) -> UUID? {
		guard let bytes else { return nil }
		let count = strnlen(bytes, 37)
		guard count == 36 else { return nil }
		let string = String(cString: bytes)
		guard let value = UUID(uuidString: string), value.uuidString.lowercased() == string
		else { return nil }
		return value
	}
}

@MainActor
internal final class ChromiumProfileRetirement {
	private let api: ArxEngineAPI
	private var nextRequest: UInt64 = 1
	private var requests: [UInt64: CheckedContinuation<ChromiumProfileRetirementSnapshot, any Error>] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal var isAvailable: Bool { api.profile_retirement_available?() == true }

	internal func snapshot() async throws -> ChromiumProfileRetirementSnapshot {
		try Task.checkCancellation()
		guard let inspect = api.inspect_profile_retirement
		else { throw ChromiumProfileRetirementFailure.unavailable }
		return try await perform { inspect($0) }
	}

	internal func retire(
		profileID: UUID?,
		requestID: UUID,
		expectedRevision: UInt64,
		authorize: @escaping @MainActor @Sendable () -> Bool
	) async throws -> ChromiumProfileRetirementSnapshot {
		try Task.checkCancellation()
		guard isAvailable, let queue = api.queue_profile_retirement
		else { throw ChromiumProfileRetirementFailure.unavailable }
		guard expectedRevision > 0
		else { throw ChromiumProfileRetirementFailure.stale }

		// Retirement is irreversible once durable. Cancellation after dispatch must
		// not discard its receipt; the caller reconciles it with persisted intent.
		return try await perform { id in
			guard authorize(), !Task.isCancelled else {
				complete(id, status: ARX_RETIREMENT_INVALID, native: nil)
				return
			}
			queue(
				profileID?.uuidString.lowercased() ?? "",
				profileID == nil,
				requestID.uuidString.lowercased(),
				expectedRevision,
				id
			)
		}
	}

	internal func complete(
		_ id: UInt64,
		status: ArxProfileRetirementStatus,
		native: ArxProfileRetirementSnapshot?
	) {
		guard let continuation = requests.removeValue(forKey: id)
		else { return }
		do {
			guard let native else { throw ChromiumProfileRetirementFailure(status: status) }
			let snapshot = try ChromiumProfileRetirementSnapshot(native: native)
			let succeeded = status == ARX_RETIREMENT_OK
			|| status == ARX_RETIREMENT_PENDING
			|| status == ARX_RETIREMENT_VERIFIED

			guard succeeded
			else { throw ChromiumProfileRetirementFailure(status: status) }
			continuation.resume(returning: snapshot)
		} catch {
			continuation.resume(throwing: error)
		}
	}

	internal func stop() {
		let pending = requests.values
		requests.removeAll()
		for request in pending { request.resume(throwing: ChromiumProfileRetirementFailure.unavailable) }
	}

	private func perform(
		_ dispatch: (UInt64) -> Void
	) async throws -> ChromiumProfileRetirementSnapshot {
		guard requests.count < 16, nextRequest < UInt64.max
		else { throw ChromiumProfileRetirementFailure.busy }
		let id = nextRequest
		nextRequest += 1
		return try await withCheckedThrowingContinuation { continuation in
			requests[id] = continuation
			dispatch(id)
		}
	}
}

extension ChromiumProfileRetirementFailure {
	internal init(status: ArxProfileRetirementStatus) {
		self = switch status {
		case ARX_RETIREMENT_BUSY: .busy
		case ARX_RETIREMENT_STALE, ARX_RETIREMENT_RETIRED: .stale
		case ARX_RETIREMENT_CORRUPT: .corrupt
		case ARX_RETIREMENT_OWNERSHIP_CHANGED: .ownershipChanged
		case ARX_RETIREMENT_LIMIT: .limit
		case ARX_RETIREMENT_IO: .io
		case ARX_RETIREMENT_INVALID, ARX_RETIREMENT_NOT_REGISTERED: .invalid
		default: .unavailable
		}
	}
}
