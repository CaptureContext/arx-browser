import BrowserWorkspaceClient
import Foundation
import MainFeature
import WorkspaceSync
import _ComposableArchitecture

/// Keeps ``ICloudRemoval`` current from iCloud sync's status (DEV-1336), for every window's Delete
/// Space and the marks on spaces, and for Settings › Profiles: whether removing a synced profile or
/// space asks where, and what another Mac removed from iCloud. A window's Keep goes to iCloud sync.
@Reducer
internal struct ICloudRemovalStatus {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	private enum Cancellation: Hashable { case status }

	@Dependency(\.workspaceSync)
	private var sync

	@Dependency(\.date)
	private var date

	internal var body: some ReducerOf<Self> {
		Pullback(\.main.ui.task) { _ in
			guard sync.isAvailable() else { return .none }

			return .run { [sync, date] _ in
				@Shared(.iCloudRemoval)
				var removal

				for await status in await sync.statusUpdates() {
					let value: ICloudRemoval = Self.removal(from: status, now: date.now)
					guard value != removal else { continue }

					$removal.withLock { $0 = value }
				}
			}
			.cancellable(id: Cancellation.status, cancelInFlight: true)
		}

		Pullback(\.main.delegate.keepMarked) { _, ids in
			keep(ids)
		}

		Pullback(\.windows) { _, action in
			guard case let .element(_, .delegate(.keepMarked(ids))) = action else { return .none }

			return keep(ids)
		}
	}

	private func keep(_ ids: Set<UUID>) -> Effect<Action> {
		guard sync.isAvailable() else { return .none }

		return .run { [sync] _ in await sync.keep(ids) }
	}

	/// What the windows and Settings need of `status`.
	internal static func removal(
		from status: WorkspaceSyncStatus,
		now: Date
	) -> ICloudRemoval {
		.init(
			asksWhere: status.asksWhereToRemove(now: now),
			marked: status.deletionMarks.mapValues { mark in
				DeletionMark(
					deviceName: status.deviceName(mark.deviceID),
					removedAt: mark.removedAt,
					deletesAt: mark.deletesAt
				)
			}
		)
	}
}
