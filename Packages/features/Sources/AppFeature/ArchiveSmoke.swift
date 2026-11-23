#if DEBUG
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import _ComposableArchitecture

/// Exercises archive transactions with fresh profiles inside the owned app-smoke process.
@MainActor
internal enum ArchiveSmoke {
	internal static func run(
		engine: BrowserEngineClient,
		baseURL: URL,
		profileDirectory: URL,
		fixtureRoot: URL
	) async throws {
		// The app runner already prepares this private, symlink-checked disposable root.
		try MediaSmokeFixture.validate(
			root: fixtureRoot,
			profile: profileDirectory,
			baseURL: baseURL
		)
		let sourceProfile = Profile.ID(rawValue: UUID())
		let destinationProfile = Profile.ID(rawValue: UUID())
		let sourceSpace = Space.ID(rawValue: UUID())
		let destinationSpace = Space.ID(rawValue: UUID())
		let identityURL = baseURL.deletingLastPathComponent().appendingPathComponent("identity.html")
		let observation = StagingObservation(destination: destinationProfile)
		defer {
			observation.store?.send(.viewer(.suspend))
			for id in observation.ownedIDs {
				engine.close(id)
			}
		}

		try await engine.prepareProfile(sourceProfile)
		try await engine.prepareProfile(destinationProfile)
		let storageSeeds: [(Profile.ID, String)] = [
			(sourceProfile, "archive-source"),
			(destinationProfile, "archive-destination"),
		]
		for (profile, identity) in storageSeeds {
			let seed = BrowserCore.Tab(
				id: .init(rawValue: UUID()),
				profileID: profile,
				restoration: .init(
					title: "Archive storage fixture",
					url: identityURL.appending(queryItems: [.init(name: "set", value: identity)])
				)
			)
			observation.ownedIDs.insert(seed.id)
			try await engine.open(seed)
			try await wait("Profile storage seed did not load") {
				loaded(seed, identity: identity, engine: engine)
			}
			engine.close(seed.id)
		}

		let tabs: [BrowserCore.Tab] = (1...3).map { index in
			.init(
				id: .init(rawValue: UUID()),
				profileID: sourceProfile,
				restoration: .init(
					title: "Archive source \(index)",
					url: identityURL.appending(queryItems: [.init(name: "phase", value: "archive-\(index)")])
				)
			)
		}
		for tab in tabs {
			observation.ownedIDs.insert(tab.id)
			try await engine.open(tab)
			try await wait("Source profile page did not load") {
				loaded(tab, identity: "archive-source", engine: engine)
			}
		}

		let organization = BrowserOrganization(
			profiles: [
				.init(id: sourceProfile, name: "Archive source fixture"),
				.init(id: destinationProfile, name: "Archive destination fixture"),
			],
			spaces: [
				.init(
					id: sourceSpace,
					profileID: sourceProfile,
					name: "Archive source",
					unpinnedTabs: tabs.map(\.id),
					selectedTabID: tabs[2].id
				),
				.init(id: destinationSpace, profileID: destinationProfile, name: "Archive destination"),
			],
			tabs: tabs
		)
		var initial = MainFeature.State(organization: organization, spaceID: sourceSpace)
		initial.viewer.item.tab = tabs[2]
		initial.sidebar.moveSelection = [.tab(tabs[1].id.rawValue), .tab(tabs[0].id.rawValue)]

		// MainFeature emits persistence delegates; this isolated store has no AppFeature parent or file client.
		let store = Store(initialState: initial) { MainFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.browserEngine.open = { tab in
				observation.ownedIDs.insert(tab.id)
				observation.record(tab)
				try await engine.open(tab)
				observation.validateRetainedArchive(for: tab)
			}
		}
		observation.store = store
		store.send(.ui(.paneCommand(.archiveSelectedTabs, initial.viewer.activePaneID)))
		try await wait("Selected archive close did not commit") {
			!store.archive.isWorking
			&& store.sidebar.organization.archive.map(\.tab.id) == tabs.prefix(2).map(\.id)
			&& tabs.prefix(2).allSatisfy { engine.snapshot($0.id) == nil }
		}
		guard
			store.sidebar.organization.tabs.map(\.id) == [tabs[2].id],
			store.sidebar.selectedTab?.id == tabs[2].id,
			loaded(tabs[2], identity: "archive-source", engine: engine)
		else { throw Failure("Archive closed an unselected page") }
		print("ARX_ARCHIVE_SELECTED_SMOKE_SUCCESS")

		let entries = store.sidebar.organization.archive
		observation.expectedArchiveIDs = Set(entries.map(\.id))
		store.send(.ui(.openArchive))
		store.send(.archive(.ui(.restoreGroup(
			entries[0].groupID,
			.init(spaceID: destinationSpace, profileID: destinationProfile)
		))))
		guard
			let confirmation = store.archive.restorationConfirmation,
			confirmation.destination.profileID == destinationProfile,
			observation.stagedIDs.isEmpty,
			store.sidebar.organization.archive == entries
		else { throw Failure("Cross-profile restoration did not await explicit confirmation") }

		store.send(.archive(.ui(.restoreConfirmed(confirmation))))
		try await wait("Cross-profile archive restoration did not commit") {
			!store.archive.isWorking && store.sidebar.organization.archive.isEmpty
		}
		let restored = store.sidebar.organization.tabs.filter { $0.profileID == destinationProfile }
		guard
			restored.count == 2,
			restored.map(\.restoration.url) == tabs.prefix(2).map(\.restoration.url),
			Set(restored.map(\.id)).isDisjoint(with: tabs.map(\.id)),
			Set(observation.stagedIDs) == Set(restored.map(\.id)),
			observation.retainedArchiveDuringStaging,
			store.sidebar.spaceID == destinationSpace,
			store.sidebar.selectedTab?.id == restored.first?.id
		else { throw Failure("Archive restoration changed identity, order or transaction boundaries") }

		try await wait("Restored pages did not use the destination profile storage") {
			restored.allSatisfy { loaded($0, identity: "archive-destination", engine: engine) }
			&& loaded(tabs[2], identity: "archive-source", engine: engine)
		}
		guard tabs.prefix(2).allSatisfy({ engine.snapshot($0.id) == nil })
		else { throw Failure("Restoration reused a closed source session") }
		try store.sidebar.organization.validate()
		print("ARX_ARCHIVE_CROSS_PROFILE_SMOKE_SUCCESS")
	}

	private static func loaded(
		_ tab: BrowserCore.Tab,
		identity: String,
		engine: BrowserEngineClient
	) -> Bool {
		guard let navigation = engine.snapshot(tab.id)?.navigation else { return false }
		return !navigation.isLoading
		&& navigation.errorCode == nil
		&& navigation.url == tab.restoration.url
		&& navigation.title == "\(identity)|\(identity)"
	}

	private static func wait(
		_ failure: String,
		until ready: () -> Bool
	) async throws {
		for _ in 0..<150 {
			if ready() {
				return
			}

			try await Task.sleep(for: .milliseconds(100))
		}

		throw Failure(failure)
	}

	private struct Failure: LocalizedError {
		internal let errorDescription: String?

		internal init(_ description: String) {
			self.errorDescription = "Archive smoke: " + description
		}
	}

	@MainActor
	private final class StagingObservation {
		internal weak var store: StoreOf<MainFeature>?
		internal let destination: Profile.ID
		internal var ownedIDs: Set<BrowserCore.Tab.ID>
		internal var expectedArchiveIDs: Set<ArchivedTab.ID>
		internal var stagedIDs: [BrowserCore.Tab.ID]
		internal var retainedArchiveDuringStaging: Bool

		internal init(destination: Profile.ID) {
			self.store = nil
			self.destination = destination
			self.ownedIDs = []
			self.expectedArchiveIDs = []
			self.stagedIDs = []
			self.retainedArchiveDuringStaging = true
		}

		internal func record(_ tab: BrowserCore.Tab) {
			guard tab.profileID == destination else { return }
			stagedIDs.append(tab.id)
			validateRetainedArchive(for: tab)
		}

		internal func validateRetainedArchive(for tab: BrowserCore.Tab) {
			guard tab.profileID == destination else { return }
			let archiveIDs = Set(store?.sidebar.organization.archive.map(\.id) ?? [])
			retainedArchiveDuringStaging = retainedArchiveDuringStaging
			&& !expectedArchiveIDs.isEmpty
			&& archiveIDs == expectedArchiveIDs
		}
	}
}
#endif
