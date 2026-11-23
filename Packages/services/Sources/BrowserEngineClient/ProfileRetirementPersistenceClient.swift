import BrowserCore
import Foundation
import _Dependencies

/// Small synchronous durable writes precede native dispatch on the main actor.
public struct ProfileRetirementPersistenceClient: Sendable {
	public var record: @MainActor @Sendable (ProfileRetirementIntent) throws -> Void
	public var acknowledge: @MainActor @Sendable (UUID) throws -> Void
	public var authorize: @MainActor @Sendable (UUID) -> Bool

	public init(
		record: @escaping @MainActor @Sendable (ProfileRetirementIntent) throws -> Void = { _ in
			throw ProfileRetirementFailure.unavailable
		},
		acknowledge: @escaping @MainActor @Sendable (UUID) throws -> Void = { _ in
			throw ProfileRetirementFailure.unavailable
		},
		authorize: @escaping @MainActor @Sendable (UUID) -> Bool = { _ in false }
	) {
		self.record = record
		self.acknowledge = acknowledge
		self.authorize = authorize
	}
}

extension ProfileRetirementPersistenceClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init() }
}

extension DependencyValues {
	public var profileRetirementPersistence: ProfileRetirementPersistenceClient {
		get { self[ProfileRetirementPersistenceClient.self] }
		set { self[ProfileRetirementPersistenceClient.self] = newValue }
	}
}
