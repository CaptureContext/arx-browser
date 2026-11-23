import BrowserCore
import BrowserEngineClient
import BrowserHistoryClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import MigrationAssistant
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-841: the first launch's provisional Default profile, settled when onboarding ends.
@Suite(.dependencies)
@MainActor
internal struct ProvisionalProfileTests {
	private nonisolated static let provisional = ProvisionalProfile(
		profileID: .init(rawValue: UUID(0)),
		spaceID: .init(rawValue: UUID(1))
	)
	private nonisolated static let sourceProfile = MigrationSourceProfile(id: "Default", name: "Work")
	private nonisolated static let sourceSpace = MigrationSourceSpace(id: "Default/s1", name: "Home", profile: sourceProfile)

	@Test
	internal func withoutAnImportDefaultStaysAndStopsBeingProvisional() async {
		let (store, document) = makeStore()

		await store.send(.presentOnboardingIfNeeded).finish()
		await store.send(.onboarding(.ui(.dismiss))).finish()

		expectNoDifference(store.workspace, Self.provisional.organization)
		expectNoDifference(store.onboardingProgress.provisionalProfile, nil)
		#expect(store.onboardingProgress.introductionDismissed)
		#expect(persisted(store, document).onboarding.provisionalProfile == nil)
	}

	@Test
	internal func anImportIntoDefaultKeepsIt() async {
		let (store, _) = makeStore()

		await store.send(.presentOnboardingIfNeeded).finish()

		// The current-space layout: no route, so everything lands in Default's space.
		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch(route: nil))))).finish()
		await store.send(.onboarding(.ui(.skipSetup))).finish()

		#expect(store.workspace.profiles.map(\.id) == [Self.provisional.profileID])
		#expect(!store.workspace.tabs.isEmpty)
		expectNoDifference(store.onboardingProgress.provisionalProfile, nil)
		expectNoDifference(store.main.sidebar.spaceID, Self.provisional.spaceID)
	}

	@Test
	internal func anImportWithItsOwnProfilesRemovesAnUntouchedDefault() async throws {
		let (store, _) = makeStore()

		await store.send(.presentOnboardingIfNeeded).finish()
		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch(route: .newProfile))))).finish()
		let imported = try #require(store.migrationLedger.createdProfiles["Default"])
		await store.send(.onboarding(.ui(.skipSetup))).finish()

		expectNoDifference(store.workspace.profiles.map(\.id), [imported])
		#expect(store.workspace.spaces.allSatisfy { $0.profileID == imported })
		#expect(!store.workspace.spaces.ids.contains(Self.provisional.spaceID))
		// The engine's original profile directory keeps its owner's identity.
		expectNoDifference(store.workspace.legacyProfileID, Self.provisional.profileID)
		expectNoDifference(store.onboardingProgress.provisionalProfile, nil)

		// The main window and Settings point at what's left.
		#expect(store.main.sidebar.organization == store.workspace)
		#expect(store.workspace.spaces[id: store.main.sidebar.spaceID]?.profileID == imported)
		expectNoDifference(store.settings.selectedProfileID, imported)
		#expect(store.windowIsOpen)
	}

	@Test
	internal func aDefaultWithATabIsKept() async throws {
		let (store, document) = makeStore()

		await store.send(.presentOnboardingIfNeeded).finish()
		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch(route: .newProfile))))).finish()
		await store.send(.event(.saveSucceeded(store.workspace, persisted(store, document)))).finish()

		// The current-space import of one more item adds a tab to Default.
		var touching = batch(route: nil)
		touching.items[0].key.sourceItemID = "b"
		touching.items[0].profile = nil
		touching.items[0].space = nil
		await store.send(.migrationWorkspace(.request(.commit(UUID(902), touching)))).finish()
		await store.send(.onboarding(.ui(.skipSetup))).finish()

		#expect(store.workspace.profiles.ids.contains(Self.provisional.profileID))
		#expect(store.workspace.spaces.ids.contains(Self.provisional.spaceID))
		expectNoDifference(store.onboardingProgress.provisionalProfile, nil)
	}

	@Test
	internal func aDefaultWithHistoryIsKept() async {
		let (store, _) = makeStore(dependencies: { dependencies in
			dependencies.browserHistory = .init(load: { profile in
				guard profile == Self.provisional.profileID
				else { return .init(snapshot: .init(profileID: profile)) }

				return .init(snapshot: .init(
					profileID: profile,
					entries: [.init(
						id: UUID(70),
						url: URL(string: "https://example.org")!,
						title: "Example",
						lastVisited: Date(timeIntervalSince1970: 10)
					)]
				))
			})
		})

		await store.send(.presentOnboardingIfNeeded).finish()
		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch(route: .newProfile))))).finish()
		await store.send(.onboarding(.ui(.skipSetup))).finish()

		#expect(store.workspace.profiles.ids.contains(Self.provisional.profileID))
		#expect(store.workspace.profiles.count == 2)
		expectNoDifference(store.onboardingProgress.provisionalProfile, nil)
	}

	@Test
	internal func aDefaultWithSavedPasswordsIsKept() async {
		let (store, _) = makeStore(dependencies: { dependencies in
			dependencies.browserEngine.savedPasswordsAreAvailable = { true }
			dependencies.browserEngine.savedPasswords = { _ throws(BrowserSavedPasswordFailure) in
				.init(passwords: [.init(id: 1, site: "example.org", origin: "https://example.org", username: "me")])
			}
		})

		await store.send(.presentOnboardingIfNeeded).finish()
		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch(route: .newProfile))))).finish()
		await store.send(.onboarding(.ui(.skipSetup))).finish()

		#expect(store.workspace.profiles.ids.contains(Self.provisional.profileID))
		expectNoDifference(store.onboardingProgress.provisionalProfile, nil)
	}

	@Test
	internal func aRelaunchPartwayThroughOnboardingStillRemovesDefault() async throws {
		let (first, firstDocument) = makeStore()
		await first.send(.presentOnboardingIfNeeded).finish()
		await first.send(.migrationWorkspace(.request(.commit(UUID(901), batch(route: .newProfile))))).finish()
		let imported = try #require(first.migrationLedger.createdProfiles["Default"])

		// Quit with onboarding open: the saved preferences carry the provisional profile.
		let saved = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONEncoder().encode(persisted(first, firstDocument))
		)
		expectNoDifference(saved.onboarding.provisionalProfile, Self.provisional)
		#expect(!saved.onboarding.introductionDismissed)

		let (relaunched, _) = makeStore(organization: first.workspace, preferences: saved)
		await relaunched.send(.presentOnboardingIfNeeded).finish()
		#expect(relaunched.onboarding != nil)
		// Closing the window ends onboarding too; it lands in the imported space.
		await relaunched.send(.ui(.closeOnboarding)).finish()

		expectNoDifference(relaunched.workspace.profiles.map(\.id), [imported])
		#expect(relaunched.workspace.spaces[id: relaunched.main.sidebar.spaceID]?.profileID == imported)
		expectNoDifference(relaunched.onboardingProgress.provisionalProfile, nil)
		#expect(relaunched.windowIsOpen)
	}

	@Test
	internal func aDownloadFolderChosenInSettingsKeepsDefault() async {
		let (store, _) = makeStore(dependencies: { dependencies in
			dependencies.browserEngine.changeDownloadSettings = { _, folder, asks throws(ProfileDataFailure) in
				.init(
					directory: folder ?? URL(filePath: "/Users/me/Downloads"),
					asksWhereToSave: asks,
					defaultDirectory: URL(filePath: "/Users/me/Downloads")
				)
			}
		})

		await store.send(.presentOnboardingIfNeeded).finish()
		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch(route: .newProfile))))).finish()
		await store.send(.settings(.ui(.chooseDownloadFolder(
			Self.provisional.profileID,
			URL(filePath: "/Users/me/Elsewhere")
		)))).finish()
		expectNoDifference(store.onboardingProgress.provisionalProfile, nil)
		await store.send(.onboarding(.ui(.skipSetup))).finish()

		#expect(store.workspace.profiles.ids.contains(Self.provisional.profileID))
		#expect(store.workspace.spaces.ids.contains(Self.provisional.spaceID))
	}

	@Test
	internal func aRoutingFallbackToDefaultKeepsIt() async {
		let (store, _) = makeStore()

		await store.send(.presentOnboardingIfNeeded).finish()
		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch(route: .newProfile))))).finish()

		// Air Traffic Control lives in the preferences, outside the workspace.
		await store.send(.settings(.ui(.routing(.fallbackChanged(.init(scope: .profile(Self.provisional.profileID)))))))
		expectNoDifference(store.onboardingProgress.provisionalProfile, nil)
		await store.send(.onboarding(.ui(.skipSetup))).finish()

		#expect(store.workspace.profiles.ids.contains(Self.provisional.profileID))
		#expect(store.workspace.spaces.ids.contains(Self.provisional.spaceID))
	}

	@Test
	internal func aChatInDefaultKeepsIt() async {
		let (store, _) = makeStore()

		await store.send(.presentOnboardingIfNeeded).finish()
		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch(route: .newProfile))))).finish()

		// Preparing a profile's chats is what reducers do for it; it doesn't count.
		await store.send(.chat(.prepare(Self.provisional.profileID)))
		expectNoDifference(store.onboardingProgress.provisionalProfile, Self.provisional)

		// Chats are saved in the conversation store, outside the workspace and history.
		// The chat panel sends its actions through its surface, as AppChatPanel scopes them.
		await store.send(.chats(.element(
			id: Self.provisional.profileID,
			action: .surfaces(.element(id: .window(store.main.id), action: .ui(.draftChanged("Hello"))))
		)))
		expectNoDifference(store.onboardingProgress.provisionalProfile, nil)
		await store.send(.onboarding(.ui(.skipSetup))).finish()

		#expect(store.workspace.profiles.ids.contains(Self.provisional.profileID))
	}

	@Test
	internal func anyActivityOutsideOnboardingKeepsDefault() async {
		let (store, _) = makeStore()

		await store.send(.presentOnboardingIfNeeded).finish()
		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch(route: .newProfile))))).finish()

		// Onboarding's own commands don't count.
		await store.send(.ui(.command(.onboarding, .application)))
		expectNoDifference(store.onboardingProgress.provisionalProfile, Self.provisional)
		await store.send(.ui(.newWindow))
		expectNoDifference(store.onboardingProgress.provisionalProfile, nil)
		await store.send(.onboarding(.ui(.skipSetup))).finish()

		#expect(store.workspace.profiles.ids.contains(Self.provisional.profileID))
	}

	@Test
	internal func onlyActivityOutsideOnboardingCounts() {
		#expect(AppFeature.Action.ui(.openSettings).isActivityOutsideOnboarding)
		#expect(AppFeature.Action.ui(.openLittleArx()).isActivityOutsideOnboarding)
		#expect(AppFeature.Action.ui(.routeURLs([URL(string: "https://example.org")!])).isActivityOutsideOnboarding)
		#expect(AppFeature.Action.ui(.command(.newTab, .application)).isActivityOutsideOnboarding)
		#expect(!AppFeature.Action.ui(.command(.closeTab, .onboarding)).isActivityOutsideOnboarding)
		#expect(!AppFeature.Action.ui(.closeOnboarding).isActivityOutsideOnboarding)
		#expect(!AppFeature.Action.ui(.openImport).isActivityOutsideOnboarding)
		#expect(!AppFeature.Action.ui(.windowBecameKey).isActivityOutsideOnboarding)
		#expect(!AppFeature.Action.event(.applicationBecameActive).isActivityOutsideOnboarding)
		#expect(!AppFeature.Action.onboarding(.ui(.skipSetup)).isActivityOutsideOnboarding)
		#expect(!AppFeature.Action.automation(.ui(.connectAgent(.claude))).isActivityOutsideOnboarding)
		#expect(!AppFeature.Action.presentOnboardingIfNeeded.isActivityOutsideOnboarding)
	}

	@Test
	internal func aCheckThatHangsReleasesTheWindowAndKeepsDefault() async throws {
		let (store, _) = makeStore(dependencies: { dependencies in
			dependencies.provisionalProfileTimeout = .milliseconds(50)

			// Answers late and ignores cancellation, like a continuation-backed engine call.
			dependencies.browserHistory = .init(load: { profile in
				await withCheckedContinuation { continuation in
					DispatchQueue.global().asyncAfter(deadline: .now() + 1) { continuation.resume() }
				}
				return .init(snapshot: .init(profileID: profile))
			})
		})

		await store.send(.presentOnboardingIfNeeded).finish()
		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch(route: .newProfile))))).finish()
		let settling = store.send(.onboarding(.ui(.skipSetup)))
		#expect(!store.windowIsOpen)

		// The timeout settles while the check is still running.
		await waitWhile { !store.windowIsOpen }
		#expect(store.windowIsOpen)
		expectNoDifference(store.onboardingProgress.provisionalProfile, nil)

		// The check's late "untouched" answer changes nothing.
		await settling.finish()
		#expect(store.workspace.profiles.ids.contains(Self.provisional.profileID))
		#expect(store.windowIsOpen)
	}

	@Test
	internal func aLaunchAfterAnUnsettledOnboardingRemovesDefault() async throws {
		let (first, firstDocument) = makeStore()
		await first.send(.presentOnboardingIfNeeded).finish()
		await first.send(.migrationWorkspace(.request(.commit(UUID(901), batch(route: .newProfile))))).finish()
		let imported = try #require(first.migrationLedger.createdProfiles["Default"])

		// Onboarding ended and saved, then Arx quit before its checks answered.
		var saved = persisted(first, firstDocument)
		saved.onboarding.introductionDismissed = true
		let (relaunched, relaunchedDocument) = makeStore(organization: first.workspace, preferences: saved)
		await relaunched.send(.presentOnboardingIfNeeded).finish()

		#expect(relaunched.onboarding == nil)
		expectNoDifference(relaunched.workspace.profiles.map(\.id), [imported])
		#expect(relaunched.workspace.spaces[id: relaunched.main.sidebar.spaceID]?.profileID == imported)
		expectNoDifference(persisted(relaunched, relaunchedDocument).onboarding.provisionalProfile, nil)
	}

	@Test
	internal func pristineOnlyWhileUntouched() {
		let provisional = Self.provisional
		let ledger = MigrationLedger()
		#expect(provisional.isPristine(in: provisional.organization, ledger: ledger))

		var renamed = provisional.organization
		renamed.profiles[id: provisional.profileID]?.name = "Mine"
		#expect(!provisional.isPristine(in: renamed, ledger: ledger))

		var configured = provisional.organization
		configured.profiles[id: provisional.profileID]?.showsFullURL = true
		#expect(!provisional.isPristine(in: configured, ledger: ledger))

		var secondSpace = provisional.organization
		secondSpace.spaces.append(.init(id: .init(rawValue: UUID(9)), profileID: provisional.profileID, name: "More"))
		#expect(!provisional.isPristine(in: secondSpace, ledger: ledger))

		var imported = MigrationLedger()
		imported.importedItems[provisional.spaceID.rawValue.uuidString] = ["item"]
		#expect(!provisional.isPristine(in: provisional.organization, ledger: imported))
	}

	// MARK: - Fixtures

	private func batch(route: MigrationRoute?) -> MigrationBatch {
		.init(
			planID: .init(rawValue: UUID(900)),
			destination: .init(
				profileID: Self.provisional.profileID,
				spaceID: Self.provisional.spaceID,
				defaultRoute: route
			),
			sourceName: "Arc",
			category: .bookmarks,
			items: [
				.init(
					key: .init(sourceID: .init(rawValue: "arc"), category: .bookmarks, sourceItemID: "a"),
					title: "Swift",
					url: URL(string: "https://swift.org")!,
					space: Self.sourceSpace,
					profile: Self.sourceProfile
				),
			]
		)
	}

	private func makeStore(
		organization: BrowserOrganization = Self.provisional.organization,
		preferences: BrowserPreferences? = nil,
		configure: (inout AppFeature.State) -> Void = { _ in },
		dependencies: @escaping (inout DependencyValues) -> Void = { _ in }
	) -> (StoreOf<AppFeature>, WorkspaceDocument) {
		var firstLaunch = BrowserPreferences()
		firstLaunch.onboarding.provisionalProfile = Self.provisional
		let document = WorkspaceDocument.unsaved(preferences ?? firstLaunch)
		var state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State.launching(
				main: .init(organization: organization, spaceID: organization.spaces[0].id),
				preferences: preferences ?? firstLaunch
			)
		}
		configure(&state)
		let ids = LockIsolated(1_000)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.continuousClock = ImmediateClock()
			$0.uuid = .init {
				ids.withValue { $0 += 1 }
				return UUID(ids.value)
			}
			$0.browserEngine.prepareProfile = { _ in }
			dependencies(&$0)
		}
		return (store, document)
	}

	/// What a save would write now, read through the store's own document.
	private func persisted(
		_ store: StoreOf<AppFeature>,
		_ document: WorkspaceDocument
	) -> BrowserPreferences {
		withDependencies {
			$0.workspaceDocument = document
		} operation: {
			store.persistedPreferences
		}
	}
}
