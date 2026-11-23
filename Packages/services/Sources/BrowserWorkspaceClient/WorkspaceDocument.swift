import BrowserCore
import Dependencies
import Foundation

/// The one in-memory copy of the workspace file that every writer edits.
///
/// AppFeature mirrors the organization into it; ``WorkspacePreferenceKey`` edits preference domains.
/// The document never decides when to write: AppFeature listens to ``changes()`` and saves on its
/// own schedule, reading ``preferences`` at the flush boundary. ``flush()`` writes the latest whole
/// snapshot right away, for `$shared.save()`.
public final class WorkspaceDocument: @unchecked Sendable {
	/// The organization and preferences as one value, so listeners compare both sides of an edit.
	public struct Snapshot: Equatable, Sendable {
		public var organization: BrowserOrganization?
		public var preferences: BrowserPreferences

		public init(
			organization: BrowserOrganization?,
			preferences: BrowserPreferences
		) {
			self.organization = organization
			self.preferences = preferences
		}
	}

	public typealias Listener = @Sendable (_ old: Snapshot, _ new: Snapshot) -> Void

	private struct Storage {
		internal var snapshot: Snapshot
		internal var listeners: [UUID: (origin: AnyHashable?, listener: Listener)]
		internal var changeContinuations: [UUID: AsyncStream<Void>.Continuation]
	}

	private let client: BrowserWorkspaceClient
	private let lock: NSLock = .init()
	private var _storage: Storage

	public init(
		client: BrowserWorkspaceClient,
		organization: BrowserOrganization?,
		preferences: BrowserPreferences
	) {
		self.client = client
		self._storage = .init(
			snapshot: .init(organization: organization, preferences: preferences),
			listeners: [:],
			changeContinuations: [:]
		)
	}

	// MARK: - Reading

	public var snapshot: Snapshot {
		withStorage { $0.snapshot }
	}

	public var preferences: BrowserPreferences {
		withStorage { $0.snapshot.preferences }
	}

	public var organization: BrowserOrganization? {
		withStorage { $0.snapshot.organization }
	}

	// MARK: - Writing

	/// Replaces the organization. AppFeature owns it and saves it itself, so this never yields to ``changes()``.
	public func update(organization: BrowserOrganization) {
		apply(origin: nil, requestsSave: false) { $0.organization = organization }
	}

	/// Replaces the organization and preferences together, as a migration commit does, so no listener
	/// sees one without the other. The caller saves the result, so this never yields to ``changes()``.
	public func update(
		organization: BrowserOrganization,
		preferences: BrowserPreferences
	) {
		apply(origin: nil, requestsSave: false) { snapshot in
			snapshot.organization = organization
			snapshot.preferences = preferences
		}
	}

	/// Edits preferences in place.
	///
	/// - Parameters:
	///   - origin: The editing key's identity. That key isn't told about its own edit.
	///   - requestsSave: Whether ``changes()`` yields, so AppFeature saves the edit.
	///     Pass `false` when the caller saves the snapshot itself.
	public func updatePreferences(
		origin: AnyHashable? = nil,
		requestsSave: Bool = true,
		_ edit: (inout BrowserPreferences) -> Void
	) {
		apply(origin: origin, requestsSave: requestsSave) { edit(&$0.preferences) }
	}

	/// Writes the latest snapshot now. Does nothing until the document has an organization.
	public func flush() async throws {
		// The snapshot and its ticket are taken together, so a later edit always gets a later ticket.
		let (snapshot, ticket) = withStorage { storage in
			(storage.snapshot, client.reserveSaveTicket())
		}
		guard let organization = snapshot.organization else { return }

		_ = try await client.save(organization, preferences: snapshot.preferences, ticket: ticket)
	}

	/// Reads the SQLite store again after iCloud sync wrote to it (DEV-977); see
	/// ``BrowserWorkspaceClient/reloadDatabase()``. The caller publishes the result with
	/// ``update(organization:preferences:)``.
	public func reloadDatabase(
		accepting: (BrowserOrganization) throws -> Void = { _ in }
	) throws -> BrowserWorkspaceClient.Recovery? {
		try client.reloadDatabase(accepting: accepting)
	}

	/// Records that this Mac opened these spaces, pinned tabs and Favorites, so a deletion another Mac
	/// synced spares them (DEV-980); see ``BrowserWorkspaceClient/recordUse(of:)``.
	public func recordUse(of ids: Set<UUID>) throws {
		try client.recordUse(of: ids)
	}

	/// "Delete from This Mac Only" (DEV-1336); see ``BrowserWorkspaceClient/keepRemovalOnThisMac(_:)``.
	public func keepRemovalOnThisMac(_ ids: Set<UUID>) {
		client.keepRemovalOnThisMac(ids)
	}

	/// The preferences the client last saved or loaded. An edit made through a shared key differs
	/// from them at once, before AppFeature hears of it.
	public var savedPreferences: BrowserPreferences {
		client.savedPreferences
	}

	// MARK: - Observation

	/// Calls `listener` after every change, except edits made with the listener's own `origin`.
	public func observe(
		origin: AnyHashable?,
		_ listener: @escaping Listener
	) -> @Sendable () -> Void {
		let id: UUID = .init()
		withStorage { $0.listeners[id] = (origin, listener) }
		return { [weak self] in
			self?.withStorage { _ = $0.listeners.removeValue(forKey: id) }
		}
	}

	/// Yields once per preference edit that asks to be saved. Bursts collapse into one pending element.
	public func changes() -> AsyncStream<Void> {
		let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
		let id: UUID = .init()
		withStorage { $0.changeContinuations[id] = continuation }
		continuation.onTermination = { [weak self] _ in
			self?.withStorage { _ = $0.changeContinuations.removeValue(forKey: id) }
		}
		return stream
	}

	// MARK: - Private

	private func withStorage<R>(_ body: (inout Storage) throws -> R) rethrows -> R {
		try lock.withLock { try body(&_storage) }
	}

	private func apply(
		origin: AnyHashable?,
		requestsSave: Bool,
		_ edit: (inout Snapshot) -> Void
	) {
		typealias Change = (
			old: Snapshot,
			new: Snapshot,
			listeners: [(origin: AnyHashable?, listener: Listener)],
			continuations: [AsyncStream<Void>.Continuation]
		)

		let change: Change? = withStorage { storage in
			let old = storage.snapshot
			edit(&storage.snapshot)
			guard storage.snapshot != old else { return nil }

			return (
				old,
				storage.snapshot,
				Array(storage.listeners.values),
				requestsSave ? Array(storage.changeContinuations.values) : []
			)
		}
		guard let change else { return }

		// Listeners run outside the lock, so they may read the document.
		for (listenerOrigin, listener) in change.listeners where origin == nil || listenerOrigin != origin {
			listener(change.old, change.new)
		}
		for continuation in change.continuations {
			continuation.yield()
		}
	}
}

// MARK: - Dependency

extension WorkspaceDocument: TestDependencyKey {
	/// A document that never writes: without an organization, ``flush()`` returns before touching the client.
	///
	/// The app replaces it at launch with `prepareDependencies`, before any state reads a key.
	public static var testValue: WorkspaceDocument {
		.init(
			client: .init(file: URL(filePath: "/dev/null/arx-unset-workspace.json")),
			organization: nil,
			preferences: .init()
		)
	}
}

extension DependencyValues {
	public var workspaceDocument: WorkspaceDocument {
		get { self[WorkspaceDocument.self] }
		set { self[WorkspaceDocument.self] = newValue }
	}
}
