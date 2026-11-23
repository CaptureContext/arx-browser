import BrowserCore
import BrowserWorkspaceClient
import ConcurrencyExtras
import CustomDump
import Foundation
import MainFeature
import SettingsFeature
import Testing
import WorkspaceSync
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// Delete from This Mac Only or Remove from iCloud, and the marks, Remove Here Too and Keep on what
/// another Mac removed (DEV-1336). WorkspaceSyncTests' `ICloudRemovalTests` prove what each does
/// across Macs.
@MainActor
@Suite
internal struct ICloudRemovalFeatureTests {
	private func device(
		_ id: Int,
		name: String,
		isThisMac: Bool = false,
		lastSeen: Date
	) -> SyncDevice {
		.init(id: UUID(id), name: name, lastSeen: lastSeen, categories: [.organization], isThisMac: isThisMac)
	}

	@Test
	internal func theWindowsAskOnlyWhileAnotherMacSyncsAndSeeWhoRemovedWhat() {
		let now: Date = .init()
		let here: SyncDevice = device(1, name: "MacBook Air", isThisMac: true, lastSeen: now)
		let other: SyncDevice = device(2, name: "Mac Studio", lastSeen: now)
		let removedAt: Date = now.addingTimeInterval(-60)
		let deletesAt: Date = removedAt.addingTimeInterval(30 * 24 * 60 * 60)
		let spaceID: UUID = UUID(10)

		let alone: ICloudRemoval = ICloudRemovalStatus.removal(
			from: .init(isEnabled: true, categories: [.organization: .synced], devices: [here]),
			now: now
		)
		expectNoDifference(alone, .init())

		let paired: ICloudRemoval = ICloudRemovalStatus.removal(
			from: .init(
				isEnabled: true,
				categories: [.organization: .synced],
				devices: [here, other],
				deletionMarks: [spaceID: .init(deviceID: other.id, removedAt: removedAt, deletesAt: deletesAt)]
			),
			now: now
		)
		expectNoDifference(
			paired,
			.init(
				asksWhere: true,
				marked: [spaceID: .init(deviceName: "Mac Studio", removedAt: removedAt, deletesAt: deletesAt)]
			)
		)

		// Profiles and spaces off here: nothing asks.
		let off: ICloudRemoval = ICloudRemovalStatus.removal(
			from: .init(isEnabled: true, categories: [.organization: .off], devices: [here, other]),
			now: now
		)
		#expect(!off.asksWhere)
	}

	@Test
	internal func eitherChoiceInTheSidebarRemovesTheSpace() async {
		let organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let space: Space = organization.spaces[1]
		for keepingElsewhere in [true, false] {
			let store = TestStore(
				initialState: MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
			) {
				MainFeature()
			}
			store.exhaustivity = .off(showSkippedAssertions: false)

			await store.send(.ui(.removeSpace(space.id, keepingElsewhere: keepingElsewhere)))
			await store.receive(\.delegate.changeOrganization, .removeSpace(space.id))
			await store.finish()
		}
	}

	@Test
	internal func settingsRemovesWhicheverIsChosen() async {
		let organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let space: Space = organization.spaces[1]
		for keepsElsewhere in [true, false] {
			let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
				$0.defaultBrowser = .unavailable
			}
			store.exhaustivity = .off(showSkippedAssertions: false)

			await store.send(.ui(.editOrganization(.init(kind: .removeSpace(space.id), name: space.name, keepsElsewhere: keepsElsewhere))))
			await store.send(.ui(.submitOrganizationEditor))
			await store.receive(\.delegate.changeOrganization, .removeSpace(space.id))
			await store.finish()
		}
	}

	@Test
	internal func keepInAWindowGoesToICloudSyncWithEverythingInTheSpace() async {
		let organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let space: Space = organization.spaces[1]
		let kept: LockIsolated<[Set<UUID>]> = .init([])
		var sync: WorkspaceSyncClient = .unavailable
		sync.isAvailable = { true }
		sync.keep = { ids in kept.withValue { $0.append(ids) } }
		let store = TestStore(
			initialState: AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		) {
			AppFeature()
		} withDependencies: {
			$0.workspaceSync = sync
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.ui(.keepMarkedSpace(space.id))))
		await store.receive(\.main.delegate.keepMarked)
		await store.finish()
		expectNoDifference(kept.value, [organization.itemsCovered(by: space.id.rawValue)])
	}

	@Test
	internal func settingsKeepGoesToICloudSync() async {
		let kept: LockIsolated<[Set<UUID>]> = .init([])
		var sync: WorkspaceSyncClient = .unavailable
		sync.isAvailable = { true }
		sync.keep = { ids in kept.withValue { $0.append(ids) } }
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
			$0.defaultBrowser = .unavailable
			$0.workspaceSync = sync
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.keepMarked([UUID(10), UUID(11)])))
		await store.finish()
		expectNoDifference(kept.value, [[UUID(10), UUID(11)]])
	}

	@Test
	internal func theRemovalSheetStartsOnTheSafeChoice() {
		#expect(OrganizationEditor(kind: .removeSpace(.init(rawValue: UUID(10))), name: "Work").keepsElsewhere)
	}

	@Test
	internal func keepCoversEverythingInTheSpace() {
		let organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let space: Space = organization.spaces[0]
		let covered: Set<UUID> = organization.itemsCovered(by: space.id.rawValue)
		#expect(covered.contains(space.id.rawValue))
		for case let .tab(id) in space.savedItems {
			#expect(covered.contains(id.rawValue))
		}
		let profile: Profile = organization.profiles[0]
		let all: Set<UUID> = organization.itemsCovered(by: profile.id.rawValue)
		#expect(all.isSuperset(of: covered))
		#expect(all.isSuperset(of: profile.favorites.map(\.rawValue)))
	}
}
