import BrowserCore
import BrowserExtensionsClient
import DefaultBrowserClient
import Foundation
import MigrationAssistant
import MigrationAssistantFeature
@testable import OnboardingFeature
import OutsideAgentsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// The "Make it yours" page over fixture browsers. No real Arc or Chrome profile is read.
@Suite(.dependencies)
@MainActor
internal struct OnboardingImportTests {
	// MARK: - Discovery

	@Test
	internal func discoveryPreselectsTheDefaultBrowserAndInspectsItOnce() async {
		let service: ImportServiceDouble = .init()
		let store = makeStore(service: service, defaultBrowser: Fixtures.arcIdentifier)

		await store.send(.ui(.task)) {
			$0.phase = .discovering
		}
		await store.receive(\.event.discovered) {
			$0.phase = .choosing
			$0.sources = [Fixtures.arc, Fixtures.chrome]
			$0.unsupportedBrowsers = [Fixtures.safari]
			$0.defaultBrowserIdentifier = Fixtures.arcIdentifier
			$0.selectedSourceID = Fixtures.arc.id
			$0.selectedCategories = [.favorites, .bookmarks, .openTabs]
			$0.keepsSpaces = true
			$0.inspecting = Fixtures.arcKeepingSpaces
		}
		await store.receive(\.event.inspected) {
			$0.inspecting = nil
			$0.previews = [Fixtures.arcKeepingSpaces: Fixtures.arcPreview(keepsSpaces: true)]
		}

		#expect(
			service.inspections.value == [
				.init(
					sourceID: Fixtures.arc.id,
					categories: [.favorites, .bookmarks, .openTabs],
					destination: Fixtures.destination(keepsSpaces: true)
				),
			]
		)
		#expect(store.state.canImport)

		// Appearing again never looks for browsers or reads them again.
		await store.send(.ui(.task))
		#expect(service.inspections.value.count == 1)
	}

	@Test
	internal func anUnsupportedDefaultFallsBackToTheMostRecentlyUsedBrowser() async {
		let service: ImportServiceDouble = .init()
		let store = makeStore(service: service, defaultBrowser: Fixtures.safari.applicationIdentifier)
		store.exhaustivity = .off

		await store.send(.ui(.task))
		await store.receive(\.event.discovered)
		#expect(store.state.selectedSourceID == Fixtures.chrome.id)
		await store.receive(\.event.inspected)
	}

	@Test
	internal func preferredSourceUsesTheDefaultThenRecentUseThenDiscoveryOrder() {
		let undated: [MigrationSource] = [Fixtures.arc, Fixtures.chrome].map { source in
			var source = source
			source.lastUsed = nil
			return source
		}

		#expect(
			OnboardingImport.preferredSource(
				in: [Fixtures.arc, Fixtures.chrome],
				defaultBrowserIdentifier: Fixtures.arcIdentifier
			) == Fixtures.arc
		)
		#expect(
			OnboardingImport.preferredSource(
				in: [Fixtures.arc, Fixtures.chrome],
				defaultBrowserIdentifier: nil
			) == Fixtures.chrome
		)
		#expect(
			OnboardingImport.preferredSource(
				in: undated,
				defaultBrowserIdentifier: "com.apple.Safari"
			) == undated[0]
		)
		#expect(OnboardingImport.preferredSource(in: [], defaultBrowserIdentifier: nil) == nil)
	}

	@Test
	internal func noBrowsersLeavesNothingToBring() async {
		let service: ImportServiceDouble = .init(sources: [])
		let store = makeStore(service: service)

		await store.send(.ui(.task)) {
			$0.phase = .discovering
		}
		await store.receive(\.event.discovered) {
			$0.phase = .choosing
			$0.unsupportedBrowsers = [Fixtures.safari]
		}
		#expect(!store.state.canImport)
		#expect(service.inspections.value.isEmpty)
	}

	// MARK: - Full Disk Access

	@Test
	internal func safariAsksForFullDiskAccessThenReadsItWhenArxComesBack() async {
		let service: ImportServiceDouble = .init(sources: [Fixtures.arc, Fixtures.chrome, Fixtures.safariSource])
		let answers: LockIsolated<[Bool]> = .init([false, true])
		let opened: LockIsolated<Int> = .init(0)
		var state = choosingArc()
		state.sources = [Fixtures.arc, Fixtures.chrome, Fixtures.safariSource]
		state.unsupportedBrowsers = []
		let store = makeStore(service: service, initialState: state) {
			$0.fullDiskAccess = .init(
				isGranted: { answers.withValue { $0.removeFirst() } },
				openSettings: { opened.withValue { $0 += 1 } }
			)
		}

		await store.send(.ui(.selectSource(Fixtures.safariSource.id))) {
			$0.selectedSourceID = .safari
			$0.selectedCategories = [.favorites, .bookmarks, .openTabs, .history]
		}
		await store.receive(\.event.fullDiskAccessChecked) { $0.fullDiskAccess = .denied }

		// Nothing in Safari is read without access.
		#expect(service.inspections.value.count == 0)
		#expect(store.state.needsFullDiskAccess)
		#expect(!store.state.canImport)

		await store.send(.ui(.allowFullDiskAccess))
		#expect(opened.value == 1)

		await store.send(.event(.applicationBecameActive))
		await store.receive(\.event.fullDiskAccessChecked) {
			$0.fullDiskAccess = .granted
			$0.inspecting = Fixtures.safariKeepingSpaces
		}
		await store.receive(\.event.inspected) {
			$0.inspecting = nil
			$0.previews[Fixtures.safariKeepingSpaces] = Fixtures.preview(
				source: Fixtures.safariSource,
				categories: [.favorites, .bookmarks, .openTabs, .history],
				destination: Fixtures.destination(keepsSpaces: true)
			)
		}
		#expect(store.state.canImport)

		// Granted stays granted: coming back again checks nothing.
		await store.send(.event(.applicationBecameActive))
		#expect(answers.value.isEmpty)
	}

	@Test
	internal func theOpenAssistantChecksAccessForThePage() async {
		let service: ImportServiceDouble = .init(sources: [Fixtures.arc, Fixtures.safariSource])
		var state = choosingArc()
		state.sources = [Fixtures.arc, Fixtures.safariSource]
		state.selectedSourceID = .safari
		state.selectedCategories = Set(Fixtures.safariSource.categories)
		state.previews = [:]
		state.fullDiskAccess = .denied
		let store = makeStore(service: service, initialState: state) {
			$0.fullDiskAccess = .constant(true)
		}
		store.exhaustivity = .off

		await store.send(.ui(.customize))
		#expect(store.state.migration?.fullDiskAccess == .denied)
		await store.send(.event(.applicationBecameActive))
		await store.receive(\.migration.event.applicationBecameActive)
		await store.receive(\.migration.event.fullDiskAccessChecked)
		#expect(store.state.migration?.fullDiskAccess == .granted)

		// Closing the assistant keeps what it learned, and the page reads Safari.
		await store.send(.migration(.ui(.dismiss)))
		await store.receive(\.migration.delegate.dismissed)
		#expect(store.state.migration == nil)
		#expect(store.state.fullDiskAccess == .granted)
		await store.receive(\.event.inspected)
		#expect(service.inspections.value.map(\.sourceID) == [.safari])
	}

	// MARK: - Choosing
	// MARK: - Choosing

	@Test
	internal func categoriesSwitchWithoutInspectingAgainAndBrowsersAreReadOnceEach() async {
		let service: ImportServiceDouble = .init()
		let store = makeStore(service: service, initialState: choosingArc())

		await store.send(.ui(.toggleCategory(.openTabs))) {
			$0.selectedCategories = [.favorites, .bookmarks]
		}
		#expect(store.state.plannedCategories == [.favorites, .bookmarks])
		await store.send(.ui(.toggleCategory(.openTabs))) {
			$0.selectedCategories = [.favorites, .bookmarks, .openTabs]
		}

		// A category the browser doesn't have can't be switched on.
		await store.send(.ui(.toggleCategory(.history)))

		await store.send(.ui(.selectSource(Fixtures.chrome.id))) {
			$0.selectedSourceID = Fixtures.chrome.id
			$0.selectedCategories = [.bookmarks]
			$0.inspecting = Fixtures.chromeKeepingSpaces
		}
		await store.receive(\.event.inspected) {
			$0.inspecting = nil
			$0.previews[Fixtures.chromeKeepingSpaces] = Fixtures.chromePreview
		}

		// Back to Arc uses what was already read.
		await store.send(.ui(.selectSource(Fixtures.arc.id))) {
			$0.selectedSourceID = Fixtures.arc.id
			$0.selectedCategories = [.favorites, .bookmarks, .openTabs]
		}
		#expect(service.inspections.value.map(\.sourceID) == [Fixtures.chrome.id])
	}

	@Test
	internal func keepItsSpacesInspectsOncePerChoice() async {
		let service: ImportServiceDouble = .init()
		let store = makeStore(service: service, initialState: choosingArc())

		await store.send(.ui(.setKeepsSpaces(false))) {
			$0.keepsSpaces = false
			$0.inspecting = Fixtures.arcIntoOneList
		}
		await store.receive(\.event.inspected) {
			$0.inspecting = nil
			$0.previews[Fixtures.arcIntoOneList] = Fixtures.arcPreview(keepsSpaces: false)
		}
		await store.send(.ui(.setKeepsSpaces(true))) {
			$0.keepsSpaces = true
		}
		await store.send(.ui(.setKeepsSpaces(false))) {
			$0.keepsSpaces = false
		}

		// Off, everything goes into the current space; on, into profiles like Arc's.
		#expect(service.inspections.value.map(\.destination) == [Fixtures.destination(keepsSpaces: false)])
		#expect(store.state.destination(for: Fixtures.arcKeepingSpaces) == Fixtures.destination(keepsSpaces: true))
	}

	@Test
	internal func aFailedInspectionIsRetriedByChoosingTheBrowserAgain() async {
		let service: ImportServiceDouble = .init()
		service.inspectionFailure.setValue(.unreadableSource("fixture"))
		let store = makeStore(service: service, initialState: choosingArc(previews: [:]))

		await store.send(.ui(.selectSource(Fixtures.arc.id))) {
			$0.inspecting = Fixtures.arcKeepingSpaces
		}
		await store.receive(\.event.inspectionFailed) {
			$0.inspecting = nil
			$0.problem = .inspectionFailed
		}
		#expect(!store.state.canImport)

		service.inspectionFailure.setValue(nil)
		await store.send(.ui(.selectSource(Fixtures.arc.id))) {
			$0.inspecting = Fixtures.arcKeepingSpaces
			$0.problem = nil
		}
		await store.receive(\.event.inspected) {
			$0.inspecting = nil
			$0.previews = [Fixtures.arcKeepingSpaces: Fixtures.arcPreview(keepsSpaces: true)]
		}
	}

	// MARK: - Importing

	@Test
	internal func bringRunsTheSwitchedOnCategoriesWithThrottledProgressAndFinishesTheStep() async {
		let service: ImportServiceDouble = .init()
		let clock: LockIsolated<TimeInterval> = .init(0)
		let store = makeStore(service: service, initialState: choosingArc()) {
			// Each progress update reads the time once, 60 ms after the last.
			$0.date = .init {
				defer { clock.withValue { $0 += 0.06 } }
				return Date(timeIntervalSince1970: clock.value)
			}
		}

		await store.send(.ui(.toggleCategory(.openTabs))) {
			$0.selectedCategories = [.favorites, .bookmarks]
		}
		await store.send(.ui(.bring)) {
			$0.phase = .importing
			$0.plan = Fixtures.plan(categories: [.favorites, .bookmarks])
		}
		#expect(!store.state.canClose)

		let run = await service.run(0)
		run.yield(.progress(Fixtures.progress(0)))
		await store.receive(\.event.execution) {
			$0.progress = Fixtures.progress(0)
		}

		// 60 ms after the last update: dropped. 120 ms: shown.
		run.yield(.progress(Fixtures.progress(1)))
		run.yield(.progress(Fixtures.progress(1)))
		await store.receive(\.event.execution) {
			$0.progress = Fixtures.progress(1)
		}

		run.yield(.finished(Fixtures.report(.completed)))
		await store.receive(\.event.execution) {
			$0.phase = .finished
			$0.progress = nil
			$0.report = Fixtures.report(.completed)
			$0.previews = [:]
		}
		await store.receive(\.delegate.completed)
		run.finish()
		await store.finish()
		#expect(store.state.isCompleted)
		#expect(store.state.canClose)
	}

	/// DEV-845: Arc's store extensions install after the import, each after the user's
	/// review, and the step finishes only once they're done.
	@Test
	internal func storeExtensionsInstallBeforeTheStepFinishes() async {
		let service: ImportServiceDouble = .init()
		let work: MigrationSourceProfile = .init(id: "Profile 1", name: "Work")
		let profile: Profile = .init(id: .init(rawValue: UUID(10)), name: "Work")
		let extensionID = "aaaabbbbccccddddeeeeffffgggghhhh"
		let inventory: BrowserExtensionInventory = .init(id: UUID(30), profileID: profile.id, revision: 1, extensions: [])
		let prompt: BrowserExtensionInstallPrompt = .init(
			id: UUID(31),
			profileID: profile.id,
			inventoryID: inventory.id,
			revision: 1,
			candidate: .init(
				extensionID: extensionID,
				name: "Ad Calm",
				version: "1",
				packageSHA256: "hash",
				sourceBasename: "Chrome Web Store",
				isUpdate: false,
				requiredPermissions: .init(),
				optionalPermissions: .init(),
				warnings: []
			)
		)
		var report = Fixtures.report(.completed)
		report.categories.append(
			.init(
				category: .extensions,
				status: .committed,
				issues: [
					.init(
						sourceItemID: "Profile 1/" + extensionID,
						category: .extensions,
						reason: .reinstallManually(.init(id: extensionID, name: "Ad Calm", fromWebStore: true, profile: work))
					),
					.init(
						sourceItemID: "Profile 1/tool",
						category: .extensions,
						reason: .reinstallManually(.init(id: "tool", name: "My Tool", fromWebStore: false, profile: work))
					),
				]
			)
		)
		var state = choosingArc()
		state.phase = .importing
		state.plan = Fixtures.plan(categories: [.favorites, .extensions])
		let resolved: LockIsolated<[Bool]> = .init([])
		let store = makeStore(service: service, initialState: state) {
			$0.migrationAssistant.receivingProfile = { id, _ in id == "Profile 1" ? profile : nil }
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in inventory },
				resolveInstallation: { _, accept in
					resolved.withValue { $0.append(accept) }
					return inventory
				},
				webstoreImportAvailability: { true },
				prepareWebstoreImport: { _ in prompt }
			)
		}
		store.exhaustivity = .off

		await store.send(.event(.execution(.finished(report))))
		await store.receive(\.extensionImport.start)
		await store.receive(\.extensionImport.event.prepared)
		#expect(store.state.extensionImport?.prompt == prompt)
		#expect(!store.state.isCompleted)
		#expect(!store.state.canClose)
		#expect(
			store.state.summary.content == .finished(
				.init(
					browserName: "Arc",
					outcome: .completed,
					importedCount: 0,
					reinstalls: ["My Tool"],
					extensions: .init(position: 1, total: 1)
				)
			)
		)

		await store.send(.extensionImport(.ui(.respond(prompt, true))))
		await store.receive(\.extensionImport.event.resolved)
		await store.receive(\.extensionImport.delegate.finished)
		await store.receive(\.delegate.completed)
		#expect(store.state.isCompleted)
		#expect(store.state.canClose)
		#expect(resolved.value == [true])
		#expect(
			store.state.summary.content == .finished(
				.init(
					browserName: "Arc",
					outcome: .completed,
					importedCount: 0,
					reinstalls: ["My Tool"],
					extensions: .init(total: 1, installed: 1)
				)
			)
		)
	}

	@Test
	internal func throttleAdmitsAtMostTenUpdatesASecond() {
		var throttle: OnboardingImportProgressThrottle = .init()
		let admitted: Int = (0..<100).count { index in
			throttle.admits(Date(timeIntervalSince1970: Double(index) * 0.01))
		}

		#expect(admitted == 10)
	}

	@Test
	internal func cancelAsksTheServiceToStopAndKeepsWhatCameOver() async {
		let service: ImportServiceDouble = .init()
		let store = makeStore(service: service, initialState: choosingArc())

		await store.send(.ui(.bring)) {
			$0.phase = .importing
			$0.plan = Fixtures.plan(categories: [.favorites, .bookmarks, .openTabs])
		}
		await store.send(.ui(.cancel)) {
			$0.phase = .cancelling
		}
		#expect(!store.state.canClose)
		await service.waitForCancel()
		#expect(service.cancelled.value == [Fixtures.planID])

		let run = await service.run(0)
		run.yield(.finished(Fixtures.report(.cancelled)))
		await store.receive(\.event.execution) {
			$0.phase = .finished
			$0.report = Fixtures.report(.cancelled)
			$0.previews = [:]
		}
		run.finish()
		await store.finish()
		#expect(store.state.canRetry)
		#expect(!store.state.isCompleted)
	}

	@Test(arguments: [MigrationReport.Outcome.partiallyCompleted, .failed])
	internal func aPartialOrFailedResultOffersRetryWithTheSamePlan(
		outcome: MigrationReport.Outcome
	) async {
		let service: ImportServiceDouble = .init()
		let store = makeStore(service: service, initialState: choosingArc())

		await store.send(.ui(.bring)) {
			$0.phase = .importing
			$0.plan = Fixtures.plan(categories: [.favorites, .bookmarks, .openTabs])
		}
		let first = await service.run(0)
		first.yield(.finished(Fixtures.report(outcome)))
		await store.receive(\.event.execution) {
			$0.phase = .finished
			$0.report = Fixtures.report(outcome)
			$0.previews = [:]
		}
		first.finish()
		#expect(store.state.canRetry)

		await store.send(.ui(.retry)) {
			$0.phase = .importing
			$0.report = nil
		}
		let second = await service.run(1)
		second.yield(.finished(Fixtures.report(.completed)))
		await store.receive(\.event.execution) {
			$0.phase = .finished
			$0.report = Fixtures.report(.completed)
		}
		await store.receive(\.delegate.completed)
		second.finish()
		await store.finish()

		#expect(service.plans.value == [store.state.plan, store.state.plan])
		// A completed run has nothing left to retry.
		await store.send(.ui(.retry))
	}

	@Test
	internal func aChangedSourceIsReadAgainBeforeImporting() async {
		let service: ImportServiceDouble = .init()
		let store = makeStore(service: service, initialState: choosingArc())

		await store.send(.ui(.bring)) {
			$0.phase = .importing
			$0.plan = Fixtures.plan(categories: [.favorites, .bookmarks, .openTabs])
		}
		let run = await service.run(0)
		run.finish(throwing: MigrationFailure.sourceChanged)
		await store.receive(\.event.executionFailed) {
			$0.phase = .choosing
			$0.plan = nil
			$0.previews = [:]
			$0.inspecting = Fixtures.arcKeepingSpaces
			$0.problem = .sourceChanged
		}
		await store.receive(\.event.inspected) {
			$0.inspecting = nil
			$0.previews = [Fixtures.arcKeepingSpaces: Fixtures.arcPreview(keepsSpaces: true)]
		}
	}

	// MARK: - Customize

	@Test
	internal func customizeOpensTheFullAssistantWithTheSameChoices() async {
		let service: ImportServiceDouble = .init()
		var state = choosingArc()
		state.selectedCategories = [.bookmarks]
		state.keepsSpaces = false
		let store = makeStore(service: service, initialState: state)

		await store.send(.ui(.customize)) {
			$0.migration = .init(
				destination: Fixtures.destination(keepsSpaces: false),
				mapsToNewProfiles: false,
				phase: .selecting,
				sources: [Fixtures.arc, Fixtures.chrome],
				selectedSourceID: Fixtures.arc.id,
				selectedCategories: [.bookmarks]
			)
		}

		// The assistant's run comes back to the page, where Try Again reruns its plan.
		await store.send(.migration(.delegate(.finished(Fixtures.report(.partiallyCompleted))))) {
			$0.migration = nil
			$0.phase = .finished
			$0.report = Fixtures.report(.partiallyCompleted)
			$0.previews = [:]
		}
		#expect(service.inspections.value.isEmpty)
	}

	@Test
	internal func passwordsOpenCustomizeWithTheKindOn() async {
		let service: ImportServiceDouble = .init()
		let store = makeStore(service: service, initialState: choosingArc())

		await store.send(.ui(.setUpPasswords))
		await store.receive(\.ui.customize) {
			$0.migration = .init(
				destination: Fixtures.destination(keepsSpaces: false),
				mapsToNewProfiles: true,
				phase: .selecting,
				sources: [Fixtures.arc, Fixtures.chrome],
				selectedSourceID: Fixtures.arc.id,
				selectedCategories: [.favorites, .bookmarks, .openTabs]
			)
		}
		await store.receive(\.migration.ui.toggleCredentials) {
			$0.migration?.credentials = .init(sourceID: Fixtures.arc.id, sourceName: "Arc")
		}
		await store.receive(\.migration.credentials.load)

		// The test client knows no browser and has no engine writer: a CSV per profile.
		await store.receive(\.migration.credentials.event.loaded) {
			$0.migration?.credentials?.phase = .configuring
			$0.migration?.credentials?.mode = .csv(.unsupported)
		}
		#expect(service.inspections.value.isEmpty)
	}

	@Test
	internal func thePageListsPasswordsForBrowsers() {
		let state = choosingArc()
		guard case let .choosing(choosing) = state.summary.content else {
			Issue.record("Not choosing")
			return
		}

		#expect(choosing.offersPasswords)
		#expect(!choosing.unavailable.contains(.passwords))
	}

	// MARK: - In the flow

	@Test
	internal func startFreshMovesOnWithoutRecordingTheStep() async {
		var state = OnboardingFeature.State(
			completedSteps: [.welcome, .tour],
			destination: Fixtures.destination(keepsSpaces: false)
		)
		state.page = .migration(choosingArc())
		let store = TestStore(initialState: state) { OnboardingFeature() }

		await store.send(.ui(.skip)) {
			$0.index = 3
			$0.page = .outsideAgents(.init())
		}
		#expect(store.state.completedSteps == [.welcome, .tour])
	}

	@Test
	internal func aCompletedImportRecordsTheMigrationStepAndStaysForContinue() async {
		let service: ImportServiceDouble = .init()
		var state = OnboardingFeature.State(
			completedSteps: [.welcome, .tour],
			destination: Fixtures.destination(keepsSpaces: false)
		)
		state.page = .migration(choosingArc())
		let store = TestStore(initialState: state) {
			OnboardingFeature()
		} withDependencies: {
			$0.migrationAssistant = service.client
			$0.uuid = .incrementing
			$0.date = .constant(Date(timeIntervalSince1970: 0))
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.page(.migration(.ui(.bring))))
		#expect(!store.state.canClose)
		// Moving on is refused while the import runs.
		await store.send(.ui(.continueSetup))
		#expect(store.state.step == .migration)

		let run = await service.run(0)
		run.yield(.finished(Fixtures.report(.completed)))
		await store.receive(\.page.migration.delegate.completed)
		await store.receive(\.delegate.stepCompleted, .migration) {
			$0.completedSteps = [.welcome, .tour, .migration]
		}
		run.finish()
		#expect(store.state.step == .migration)

		await store.send(.ui(.continueSetup))
		#expect(store.state.step == .outsideAgents)
	}

	// MARK: - After iCloud (DEV-1215)

	@Test
	internal func afterICloudOnlyWhatICloudDoesntSyncIsOffered() async {
		let service: ImportServiceDouble = .init()
		var state: OnboardingImport.State = choosingArc()
		state.workspaceCameFromICloud = true
		let store = makeStore(service: service, initialState: state)
		store.exhaustivity = .off

		// Open tabs, history and extensions don't sync.
		#expect(state.offeredCategories(of: Fixtures.arc) == [.openTabs])
		#expect(state.offeredCategories(of: Fixtures.safariSource) == [.openTabs, .history])
		// What iCloud brought isn't imported again, and its spaces aren't made twice.
		#expect(!store.state.plannedCategories.contains(.favorites))
		#expect(!store.state.plannedCategories.contains(.bookmarks))
		// Switches for what iCloud syncs do nothing.
		await store.send(.ui(.toggleCategory(.favorites)))
		#expect(store.state.selectedCategories == [.favorites, .bookmarks, .openTabs])
		await store.send(.ui(.setKeepsSpaces(false)))
		#expect(store.state.keepsSpaces)

		await store.send(.ui(.selectSource(Fixtures.chrome.id)))
		#expect(store.state.selectedCategories.isEmpty)
		#expect(!store.state.keepsSpaces)
	}

	/// Customize… and Passwords' Set Up… open the assistant with the same limit (DEV-1220).
	@Test
	internal func afterICloudCustomizeOffersOnlyWhatICloudDoesntSync() async {
		let service: ImportServiceDouble = .init()
		var state: OnboardingImport.State = choosingArc()
		state.workspaceCameFromICloud = true
		let store = makeStore(service: service, initialState: state)
		store.exhaustivity = .off

		await store.send(.ui(.customize))
		let migration = try? #require(store.state.migration)
		#expect(migration?.categoryLimit == MigrationCategory.outsideICloud)
		#expect(migration?.allowsNewProfiles == false)
		#expect(migration?.mapsToNewProfiles == false)
		#expect(migration?.selectedCategories == [.openTabs])
		#expect(migration?.offeredCategories == [.openTabs])
	}

	// MARK: - Helpers

	private func makeStore(
		service: ImportServiceDouble,
		defaultBrowser: String? = nil,
		initialState: OnboardingImport.State? = nil,
		dependencies: (inout DependencyValues) -> Void = { _ in }
	) -> TestStoreOf<OnboardingImport> {
		TestStore(initialState: initialState ?? .init(destination: Fixtures.destination(keepsSpaces: false))) {
			OnboardingImport()
		} withDependencies: {
			$0.migrationAssistant = service.client
			$0.defaultBrowser = .init(
				isAvailable: { true },
				isDefault: { _ in false },
				currentBrowserName: { nil },
				requestDefault: { _ in },
				currentBrowserIdentifier: { defaultBrowser }
			)
			$0.uuid = .incrementing
			$0.date = .constant(Date(timeIntervalSince1970: 0))
			dependencies(&$0)
		}
	}

	/// The page after discovery chose Arc, keeping its spaces, and read it.
	private func choosingArc(
		previews: [OnboardingImport.Choice: MigrationPreview] = [
			Fixtures.arcKeepingSpaces: Fixtures.arcPreview(keepsSpaces: true),
		]
	) -> OnboardingImport.State {
		.init(
			destination: Fixtures.destination(keepsSpaces: false),
			phase: .choosing,
			sources: [Fixtures.arc, Fixtures.chrome],
			unsupportedBrowsers: [Fixtures.safari],
			defaultBrowserIdentifier: Fixtures.arcIdentifier,
			selectedSourceID: Fixtures.arc.id,
			selectedCategories: [.favorites, .bookmarks, .openTabs],
			keepsSpaces: true,
			previews: previews
		)
	}
}

// MARK: - Fixtures

private enum Fixtures {
	internal static let arcIdentifier: String = "company.thebrowser.Browser"
	internal static let planID: MigrationPlan.ID = .init(rawValue: UUID(0))

	internal static let arc: MigrationSource = .init(
		id: .init(rawValue: "arc"),
		kind: .externalBrowser,
		name: "Arc",
		categories: [.favorites, .bookmarks, .openTabs],
		preservesOrganization: true,
		applicationIdentifier: arcIdentifier,
		lastUsed: Date(timeIntervalSince1970: 1_000)
	)

	internal static let chrome: MigrationSource = .init(
		id: .init(rawValue: "chrome"),
		kind: .externalBrowser,
		name: "Google Chrome",
		categories: [.bookmarks],
		preservesOrganization: true,
		applicationIdentifier: "com.google.Chrome",
		lastUsed: Date(timeIntervalSince1970: 2_000)
	)

	internal static let safari: MigrationUnsupportedBrowser = .init(
		id: "safari",
		name: "Safari",
		applicationIdentifier: "com.apple.Safari"
	)

	internal static let safariSource: MigrationSource = .init(
		id: .safari,
		kind: .externalBrowser,
		name: "Safari",
		categories: [.favorites, .bookmarks, .openTabs, .history],
		preservesOrganization: true,
		applicationIdentifier: "com.apple.Safari",
		requiresFullDiskAccess: true
	)

	internal static let arcKeepingSpaces: OnboardingImport.Choice = .init(sourceID: arc.id, keepsSpaces: true)
	internal static let safariKeepingSpaces: OnboardingImport.Choice = .init(sourceID: safariSource.id, keepsSpaces: true)
	internal static let arcIntoOneList: OnboardingImport.Choice = .init(sourceID: arc.id, keepsSpaces: false)
	internal static let chromeKeepingSpaces: OnboardingImport.Choice = .init(sourceID: chrome.id, keepsSpaces: true)

	internal static func destination(keepsSpaces: Bool) -> MigrationDestination {
		.init(
			profileID: .init(rawValue: UUID(10)),
			spaceID: .init(rawValue: UUID(11)),
			defaultRoute: keepsSpaces ? .newProfile : nil
		)
	}

	internal static func preview(
		source: MigrationSource,
		categories: [MigrationCategory],
		destination: MigrationDestination
	) -> MigrationPreview {
		.init(
			sourceID: source.id,
			snapshotID: "\(source.id.rawValue)-snapshot",
			destination: destination,
			categories: categories.map { category in
				.init(
					category: category,
					items: (0..<2).map { index in
						.init(
							key: .init(sourceID: source.id, category: category, sourceItemID: "\(category)-\(index)"),
							title: "Item \(index)",
							url: URL(string: "https://example.com/\(category)/\(index)")
						)
					}
				)
			}
		)
	}

	internal static func arcPreview(keepsSpaces: Bool) -> MigrationPreview {
		preview(
			source: arc,
			categories: [.favorites, .bookmarks, .openTabs],
			destination: destination(keepsSpaces: keepsSpaces)
		)
	}

	internal static var chromePreview: MigrationPreview {
		preview(
			source: chrome,
			categories: [.bookmarks],
			destination: destination(keepsSpaces: true)
		)
	}

	internal static func plan(categories: [MigrationCategory]) -> MigrationPlan {
		.init(
			id: planID,
			sourceID: arc.id,
			snapshotID: "arc-snapshot",
			destination: destination(keepsSpaces: true),
			categories: categories
		)
	}

	internal static func progress(_ completed: Int) -> MigrationProgress {
		.init(
			planID: planID,
			category: .favorites,
			completedCategories: completed,
			totalCategories: 2
		)
	}

	internal static func report(_ outcome: MigrationReport.Outcome) -> MigrationReport {
		let status: MigrationReport.Category.Status = switch outcome {
		case .completed, .partiallyCompleted: .committed
		case .failed: .failed
		case .cancelled: .notStarted
		}
		var categories: [MigrationReport.Category] = [.init(category: .favorites, status: status)]
		if outcome == .partiallyCompleted {
			categories.append(.init(category: .bookmarks, status: .failed))
		}
		return .init(planID: planID, outcome: outcome, categories: categories)
	}
}

// MARK: - Service double

private struct Inspection: Equatable, Sendable {
	internal var sourceID: MigrationSource.ID
	internal var categories: [MigrationCategory]
	internal var destination: MigrationDestination
}

/// A migration service over fixture browsers. Each run's stream is driven by the test.
private final class ImportServiceDouble: Sendable {
	internal let sources: [MigrationSource]
	internal let inspections: LockIsolated<[Inspection]> = .init([])
	internal let inspectionFailure: LockIsolated<MigrationFailure?> = .init(nil)
	internal let plans: LockIsolated<[MigrationPlan]> = .init([])
	internal let cancelled: LockIsolated<[MigrationPlan.ID]> = .init([])
	private let runs: LockIsolated<[AsyncThrowingStream<MigrationEvent, any Error>.Continuation]> = .init([])

	internal init(sources: [MigrationSource] = [Fixtures.arc, Fixtures.chrome]) {
		self.sources = sources
	}

	internal var client: MigrationAssistantClient {
		.init(
			discover: { [sources] in sources },
			inspect: { [self] sourceID, categories, destination in
				inspections.withValue {
					$0.append(.init(sourceID: sourceID, categories: categories, destination: destination))
				}
				if let failure = inspectionFailure.value { throw failure }

				guard let source = sources.first(where: { $0.id == sourceID })
				else { throw MigrationFailure.unknownSource }

				return Fixtures.preview(source: source, categories: categories, destination: destination)
			},
			execute: { [self] plan in
				plans.withValue { $0.append(plan) }
				let (stream, continuation) = AsyncThrowingStream<MigrationEvent, any Error>.makeStream()
				runs.withValue { $0.append(continuation) }
				return stream
			},
			cancel: { [self] id in
				cancelled.withValue { $0.append(id) }
			},
			unsupportedBrowsers: { [Fixtures.safari] }
		)
	}

	/// The stream of the run started `index`-th, once the effect has started it.
	internal func run(_ index: Int) async -> AsyncThrowingStream<MigrationEvent, any Error>.Continuation {
		while runs.value.count <= index {
			await Task.yield()
		}
		return runs.value[index]
	}

	internal func waitForCancel() async {
		while cancelled.value.isEmpty {
			await Task.yield()
		}
	}
}
