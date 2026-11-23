import BrowserCore
import BrowserEngineClient
import ChromiumEngine

extension ChromiumBrowserEngine {
	internal func retirementSnapshot() async throws -> ProfileRetirementSnapshot {
		do {
			return Self.retirementSnapshot(try await runtime.profileRetirementSnapshot())
		} catch {
			throw Self.retirementFailure(error)
		}
	}

	internal func retireProfile(
		_ request: ProfileRetirementRequest,
		authorize: @escaping @MainActor @Sendable () -> Bool
	) async throws -> ProfileRetirementSnapshot {
		try Task.checkCancellation()
		guard authorize(), runtime.supportsProfileRetirement
		else { throw ProfileRetirementFailure.unavailable }
		guard
			!retirementOperations.contains(request.profileID),
			!pageProfiles.values.contains(request.profileID)
		else { throw ProfileRetirementFailure.busy }

		let pendingRequestID = retirementRequests[request.profileID]
		guard pendingRequestID == nil || pendingRequestID == request.requestID
		else { throw ProfileRetirementFailure.stale }

		// Hold admission closed through callback delivery. Native independently
		// checks pages, pending preparation, private ownership and downloads.
		retiringProfiles.insert(request.profileID)
		retirementRequests[request.profileID] = request.requestID
		retirementOperations.insert(request.profileID)
		defer { retirementOperations.remove(request.profileID) }
		do {
			let nativeSnapshot = try await runtime.retireProfile(
				request.profileID.chromiumProfile(legacy: legacyProfileID),
				requestID: request.requestID,
				expectedRevision: request.expectedRevision,
				authorize: authorize
			)
			let snapshot = Self.retirementSnapshot(nativeSnapshot)
			guard snapshot.acknowledges(request)
			else { throw ProfileRetirementFailure.io }
			return snapshot
		} catch {
			// A lost/error receipt cannot prove retirement did not become durable.
			// Persisted app intent must reconcile after restart before re-admission.
			throw Self.retirementFailure(error)
		}
	}

	internal static func retirementSnapshot(
		_ snapshot: ChromiumProfileRetirementSnapshot
	) -> ProfileRetirementSnapshot {
		.init(
			revision: snapshot.revision,
			isDurable: snapshot.isDurable,
			records: snapshot.records.map { record in
				let state: ProfileRetirementRecord.State = switch record.state {
				case .active: .active
				case .awaitingStartup: .awaitingStartup
				case .quarantinePending: .quarantinePending
				case .restartRequired: .restartRequired
				case .verificationPending: .verificationPending
				case .erased: .erased
				case .blocked: .blocked
				}
				return .init(
					profileID: .init(rawValue: ProfileStorageAliases.shared.profileID(forStorage: record.profileID)),
					requestID: record.requestID,
					state: state
				)
			}
		)
	}

	internal static func retirementFailure(_ error: any Error) -> ProfileRetirementFailure {
		if let error = error as? ProfileRetirementFailure { return error }
		guard let native = error as? ChromiumProfileRetirementFailure
		else { return .unavailable }
		return switch native {
		case .unavailable: .unavailable
		case .busy: .busy
		case .stale: .stale
		case .invalid: .invalid
		case .corrupt: .corrupt
		case .ownershipChanged: .ownershipChanged
		case .limit: .limit
		case .io: .io
		}
	}
}
