import Foundation
import os

/// Where this Mac keeps each profile's website data, when it isn't under the profile's own ID
/// (DEV-1216). A profile merged into iCloud's keeps this Mac's cookies and storage: the kept profile's
/// ID becomes an alias for the merged one's storage, never a copy.
///
/// The workspace store publishes the aliases each time it reads the organization, before the app
/// sees its profiles, and the engines read them when they name a profile's storage. One process-wide
/// value, since Chromium's and WebKit's storage are process-wide too.
public final class ProfileStorageAliases: Sendable {
	public static let shared: ProfileStorageAliases = .init()

	private struct State {
		var aliases: [UUID: UUID] = [:]
		var observers: [UUID: @Sendable ([UUID: UUID]) -> Void] = [:]
	}

	private let state: OSAllocatedUnfairLock<State> = .init(initialState: .init())

	public init() {}

	/// Each aliased profile's storage ID.
	public var aliases: [UUID: UUID] {
		state.withLock(\.aliases)
	}

	/// The ID `profile`'s website data is kept under on this Mac: its own, unless it's an alias.
	public func storageID(for profile: UUID) -> UUID {
		state.withLock { $0.aliases[profile] } ?? profile
	}

	/// The profile whose website data is kept under `storageID`: the profile aliased to it, else the
	/// one with that ID.
	public func profileID(forStorage storageID: UUID) -> UUID {
		state.withLock { state in
			state.aliases.first { $0.value == storageID }?.key
		} ?? storageID
	}

	/// Replaces every alias, telling the observers when anything changed.
	public func set(_ aliases: [UUID: UUID]) {
		let observers: [@Sendable ([UUID: UUID]) -> Void]? = state.withLock { state in
			let aliases: [UUID: UUID] = aliases.filter { $0.key != $0.value }
			guard state.aliases != aliases else { return nil }

			state.aliases = aliases
			return Array(state.observers.values)
		}
		for observer in observers ?? [] {
			observer(aliases)
		}
	}

	/// Calls `observer` with the aliases now and after every change, until the returned token is
	/// released with ``removeObserver(_:)``.
	@discardableResult
	public func observe(_ observer: @escaping @Sendable ([UUID: UUID]) -> Void) -> UUID {
		let id: UUID = .init()
		let current: [UUID: UUID] = state.withLock { state in
			state.observers[id] = observer
			return state.aliases
		}
		observer(current)
		return id
	}

	public func removeObserver(_ id: UUID) {
		_ = state.withLock { $0.observers.removeValue(forKey: id) }
	}
}
