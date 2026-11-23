import BrowserCore
import CustomDump
import Foundation
import MigrationAssistant
import MigrationAssistantFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct MigrationAssistantFeatureTests {
	private let sourceID: MigrationSource.ID = .init(rawValue: "fixture:default")
	private let destination: MigrationDestination = .init(
		profileID: .init(rawValue: UUID(1)),
		spaceID: .init(rawValue: UUID(2))
	)
	private let planID: MigrationPlan.ID = .init(rawValue: UUID(0))

	private var source: MigrationSource {
		.init(
			id: sourceID,
			kind: .externalBrowser,
			name: "Fixture Browser",
			categories: [.bookmarks, .openTabs]
		)
	}

	private var preview: MigrationPreview {
		.init(
			sourceID: sourceID,
			snapshotID: "snapshot-1",
			destination: destination,
			categories: [
				.init(
					category: .bookmarks,
					items: [
						.init(
							key: key(.bookmarks, "b1"),
							title: "Swift",
							url: URL(string: "https://swift.org")!
						),
					],
					issues: [.init(sourceItemID: "b3", category: .bookmarks, reason: .invalidURL)]
				),
				.init(
					category: .openTabs,
					items: [
						.init(
							key: key(.openTabs, "t1"),
							title: "News",
							url: URL(string: "https://news.example.org")!
						),
					]
				),
			]
		)
	}

	private var plan: MigrationPlan { .init(id: planID, preview: preview) }

	// MARK: - Full Disk Access

	private var safari: MigrationSource {
		.init(
			id: .safari,
			kind: .externalBrowser,
			name: "Safari",
			categories: [.favorites, .bookmarks, .openTabs, .history],
			requiresFullDiskAccess: true
		)
	}

	@Test
	internal func safariAsksForFullDiskAccessAndShowsItsCategoriesOnceAllowed() async {
		let answers: LockIsolated<[Bool]> = .init([false, true])
		let opened: LockIsolated<Int> = .init(0)
		let initial = MigrationAssistantFeature.State(
			destination: destination,
			phase: .selecting,
			sources: [source, safari],
			selectedSourceID: source.id,
			selectedCategories: Set(source.categories)
		)
		let store = TestStore(initialState: initial) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.fullDiskAccess = .init(
				isGranted: { answers.withValue { $0.removeFirst() } },
				openSettings: { opened.withValue { $0 += 1 } }
			)
		}

		await store.send(.ui(.selectSource(safari.id))) {
			$0.selectedSourceID = .safari
			$0.selectedCategories = [.favorites, .bookmarks, .openTabs, .history]
		}
		await store.receive(\.event.fullDiskAccessChecked) { $0.fullDiskAccess = .denied }
		#expect(store.state.needsFullDiskAccess)
		#expect(!store.state.canInspect)
		// Review is refused while access is missing.
		await store.send(.ui(.inspect))

		await store.send(.ui(.allowFullDiskAccess))
		#expect(opened.value == 1)

		await store.send(.event(.applicationBecameActive))
		await store.receive(\.event.fullDiskAccessChecked) { $0.fullDiskAccess = .granted }
		#expect(!store.state.needsFullDiskAccess)
		#expect(store.state.canInspect)

		// Once granted, nothing is checked again and Settings isn't offered.
		await store.send(.event(.applicationBecameActive))
		await store.send(.ui(.allowFullDiskAccess))
		#expect(opened.value == 1)
		#expect(answers.value.isEmpty)
	}

	@Test
	internal func otherSourcesNeverCheckFullDiskAccess() async {
		let initial = MigrationAssistantFeature.State(
			destination: destination,
			phase: .selecting,
			sources: [source, safari],
			selectedSourceID: source.id,
			selectedCategories: Set(source.categories)
		)
		let store = TestStore(initialState: initial) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.fullDiskAccess = .init(isGranted: { Issue.record("Checked access"); return false })
		}

		await store.send(.event(.applicationBecameActive))
		await store.send(.ui(.allowFullDiskAccess))
		#expect(!store.state.needsFullDiskAccess)
	}

	// MARK: - Profile mapping (DEV-842)

	private var organized: MigrationSource {
		.init(
			id: .init(rawValue: "organized"),
			kind: .externalBrowser,
			name: "Arc",
			categories: [.bookmarks, .openTabs],
			preservesOrganization: true
		)
	}

	private var profiles: [MigrationSourceProfile] {
		[.init(id: "Default", name: "Personal"), .init(id: "Profile 1", name: "Work")]
	}

	private var otherProfile: MigrationAssistantFeature.SpaceOption {
		.init(
			profileID: .init(rawValue: UUID(7)),
			profileName: "Research",
			spaceID: .init(rawValue: UUID(8)),
			spaceName: "Reading"
		)
	}

	@Test
	internal func eachSourceProfileGoesToANewProfileByDefaultAndCanBeRenamed() async {
		var organizedPreview = preview
		organizedPreview.sourceID = organized.id
		organizedPreview.profiles = profiles
		let read = organizedPreview
		let inspected = LockIsolated<[MigrationDestination]>([])
		let executed = LockIsolated<[MigrationPlan]>([])
		let initial = MigrationAssistantFeature.State(
			destination: destination,
			spaceOptions: [otherProfile],
			phase: .selecting,
			sources: [source, organized],
			selectedSourceID: source.id,
			selectedCategories: Set(source.categories)
		)
		let store = TestStore(initialState: initial) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.uuid = .constant(UUID(0))
			$0.migrationAssistant.inspect = { _, _, destination in
				inspected.withValue { $0.append(destination) }
				return read
			}
			$0.migrationAssistant.execute = { plan in
				executed.withValue { $0.append(plan) }
				return AsyncThrowingStream { $0.finish() }
			}
		}

		await store.send(.ui(.selectSource(organized.id))) {
			$0.selectedSourceID = self.organized.id
			$0.mapsToNewProfiles = true
		}
		await store.send(.ui(.inspect)) { $0.phase = .inspecting }
		await store.receive(\.event.inspected) {
			$0.phase = .previewing
			$0.preview = read
			$0.mappings = [
				.init(id: "Default", sourceName: "Personal"),
				.init(id: "Profile 1", sourceName: "Work"),
			]
		}
		#expect(inspected.value.first?.defaultRoute == .newProfile)
		#expect(store.state.profileOptions.map(\.id) == [destination.profileID, otherProfile.profileID])

		// A rename changes no counts, so it doesn't read the source again.
		await store.send(.ui(.renameProfile("Default", "Home"))) {
			$0.mappings[id: "Default"]?.newName = "Home"
		}
		#expect(inspected.value.count == 1)

		// An existing profile changes what was already imported, so it's read again.
		await store.send(.ui(.mapProfile("Profile 1", otherProfile.profileID))) {
			$0.mappings[id: "Profile 1"]?.profileID = self.otherProfile.profileID
			$0.phase = .inspecting
		}
		await store.receive(\.event.inspected) { $0.phase = .previewing }
		#expect(inspected.value.last?.profileRoutes == [
			"Default": .newProfile(name: "Home"),
			"Profile 1": .existingProfile(otherProfile.profileID),
		])

		// A mapped profile's new name stays for switching back, but can't be edited meanwhile.
		await store.send(.ui(.renameProfile("Profile 1", "Job")))

		// Only profiles the host offers.
		await store.send(.ui(.mapProfile("Profile 1", .init(rawValue: UUID(99)))))
		await store.send(.ui(.mapProfile("Unknown", nil)))

		await store.send(.ui(.renameProfile("Default", "Home Life"))) {
			$0.mappings[id: "Default"]?.newName = "Home Life"
		}
		var plan = MigrationPlan(id: planID, preview: read)
		plan.destination.defaultRoute = .newProfile
		plan.destination.profileRoutes = [
			"Default": .newProfile(name: "Home Life"),
			"Profile 1": .existingProfile(otherProfile.profileID),
		]
		await store.send(.ui(.startImport)) {
			$0.phase = .importing
			$0.plan = plan
		}
		await store.finish()
		expectNoDifference(executed.value, [plan])
	}

	/// Onboarding after iCloud (DEV-1220): iCloud brought the profiles, spaces and bookmarks,
	/// so only what it doesn't sync is selected and read, and nothing goes into a new profile.
	@Test
	internal func aCategoryLimitSelectsAndReadsOnlyItsKindsIntoExistingProfiles() async {
		var organizedPreview = preview
		organizedPreview.sourceID = organized.id
		organizedPreview.profiles = profiles
		let read = organizedPreview
		let inspected = LockIsolated<[(categories: [MigrationCategory], destination: MigrationDestination)]>([])
		let initial = MigrationAssistantFeature.State(
			destination: destination,
			spaceOptions: [otherProfile],
			// The onboarding page's own choice, which may still hold what iCloud syncs.
			mapsToNewProfiles: true,
			phase: .selecting,
			sources: [source, organized],
			selectedSourceID: source.id,
			selectedCategories: [.bookmarks, .openTabs],
			categoryLimit: [.openTabs, .history, .extensions],
			allowsNewProfiles: false
		)
		#expect(initial.selectedCategories == [.openTabs])
		#expect(!initial.mapsToNewProfiles)
		#expect(initial.offeredCategories == [.openTabs])

		let store = TestStore(initialState: initial) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.migrationAssistant.inspect = { _, categories, destination in
				inspected.withValue { $0.append((categories, destination)) }
				return read
			}
		}

		// Another browser selects only the kinds within the limit, and keeps its profiles out
		// of new Arx profiles.
		await store.send(.ui(.selectSource(organized.id))) {
			$0.selectedSourceID = self.organized.id
		}
		#expect(store.state.offeredCategories == [.openTabs])
		// Passwords and sign-ins stay offered.
		#expect(store.state.offersCredentials)
		await store.send(.ui(.toggleCategory(.bookmarks)))

		await store.send(.ui(.inspect)) { $0.phase = .inspecting }

		// The profiles it read go into the current one, which is read again so the review says so.
		await store.receive(\.event.inspected) {
			$0.preview = read
			$0.mappings = [
				.init(id: "Default", sourceName: "Personal", profileID: self.destination.profileID),
				.init(id: "Profile 1", sourceName: "Work", profileID: self.destination.profileID),
			]
		}
		await store.receive(\.event.inspected) { $0.phase = .previewing }
		#expect(inspected.value.map(\.categories) == [[.openTabs], [.openTabs]])
		#expect(inspected.value.allSatisfy { $0.destination.defaultRoute != .newProfile })

		// A new profile isn't offered; an existing one is.
		await store.send(.ui(.mapProfile("Default", nil)))
		await store.send(.ui(.mapProfile("Profile 1", otherProfile.profileID))) {
			$0.mappings[id: "Profile 1"]?.profileID = self.otherProfile.profileID
			$0.phase = .inspecting
		}
		await store.receive(\.event.inspected) { $0.phase = .previewing }
		#expect(inspected.value.last?.categories == [.openTabs])
		#expect(inspected.value.last?.destination.profileRoutes == [
			"Default": .existingProfile(destination.profileID),
			"Profile 1": .existingProfile(otherProfile.profileID),
		])
	}

	@Test
	internal func mappingsSurviveGoingBackAndAnotherSourceStartsOver() async {
		var organizedPreview = preview
		organizedPreview.sourceID = organized.id
		organizedPreview.profiles = profiles
		let read = organizedPreview
		let initial = MigrationAssistantFeature.State(
			destination: destination,
			mappings: [.init(id: "Default", sourceName: "Personal", profileID: destination.profileID)],
			mapsToNewProfiles: true,
			phase: .previewing,
			sources: [source, organized],
			selectedSourceID: organized.id,
			selectedCategories: Set(organized.categories),
			preview: read
		)
		let store = TestStore(initialState: initial) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.migrationAssistant.inspect = { _, _, _ in read }
		}

		await store.send(.ui(.back)) {
			$0.phase = .selecting
			$0.preview = nil
		}
		await store.send(.ui(.inspect)) { $0.phase = .inspecting }
		await store.receive(\.event.inspected) {
			$0.phase = .previewing
			$0.preview = read

			// The earlier choice stays; a profile seen for the first time goes to a new one.
			$0.mappings.append(.init(id: "Profile 1", sourceName: "Work"))
		}

		await store.send(.ui(.back)) {
			$0.phase = .selecting
			$0.preview = nil
		}
		await store.send(.ui(.selectSource(source.id))) {
			$0.selectedSourceID = self.source.id
			$0.mapsToNewProfiles = false
			$0.mappings = []
		}
	}

	@Test
	internal func sourcesWithoutProfilesGoIntoTheCurrentSpace() async {
		var withProfiles = preview
		withProfiles.profiles = profiles
		let read = withProfiles
		let initial = MigrationAssistantFeature.State(
			destination: destination,
			phase: .selecting,
			sources: [source],
			selectedSourceID: source.id,
			selectedCategories: Set(source.categories)
		)
		let store = TestStore(initialState: initial) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.migrationAssistant.inspect = { _, _, _ in read }
		}

		await store.send(.ui(.inspect)) { $0.phase = .inspecting }
		await store.receive(\.event.inspected) {
			$0.phase = .previewing
			$0.preview = read
		}
		#expect(!store.state.offersMapping)
		#expect(store.state.mappings.isEmpty)
		#expect(store.state.resolvedDestination == destination)
	}

	@Test
	internal func aProfileMappedToTheCurrentProfileWhenSpacesArentKept() async {
		var organizedPreview = preview
		organizedPreview.sourceID = organized.id
		organizedPreview.profiles = profiles
		let read = organizedPreview
		let inspected = LockIsolated<[MigrationDestination]>([])
		let initial = MigrationAssistantFeature.State(
			destination: destination,
			mapsToNewProfiles: false,
			phase: .selecting,
			sources: [organized],
			selectedSourceID: organized.id,
			selectedCategories: Set(organized.categories)
		)
		let store = TestStore(initialState: initial) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.migrationAssistant.inspect = { _, _, destination in
				inspected.withValue { $0.append(destination) }
				return read
			}
		}

		await store.send(.ui(.inspect)) { $0.phase = .inspecting }

		// The first read went to the current space; the mapping sends each profile into new
		// spaces of the current profile, so the review is read again for that.
		await store.receive(\.event.inspected) {
			$0.preview = read
			$0.mappings = [
				.init(id: "Default", sourceName: "Personal", profileID: self.destination.profileID),
				.init(id: "Profile 1", sourceName: "Work", profileID: self.destination.profileID),
			]
		}
		await store.receive(\.event.inspected) { $0.phase = .previewing }
		#expect(store.state.resolvedDestination?.defaultRoute == nil)
		expectNoDifference(inspected.value.map(\.profileRoutes), [
			[:],
			[
				"Default": .existingProfile(destination.profileID),
				"Profile 1": .existingProfile(destination.profileID),
			],
		])
	}

	@Test
	internal func aChosenFileJoinsTheSourcesAndIsSelected() async {
		let file = URL(fileURLWithPath: "/tmp/Archive.json")
		var added = source
		added.id = .init(rawValue: "file")
		added.categories = [.bookmarks, .preferences]
		let store = TestStore(initialState: MigrationAssistantFeature.State(destination: destination, phase: .selecting)) {
			MigrationAssistantFeature()
		} withDependencies: { [added] in
			$0.migrationAssistant.addFile = { _ in added }
		}

		await store.send(.ui(.fileChosen(file)))
		await store.receive(\.event.fileAdded) {
			$0.sources = [added]
			$0.selectedSourceID = added.id
			$0.selectedCategories = [.bookmarks, .preferences]
		}
	}

	@Test(arguments: [
		(MigrationFailure.unsupportedVersion(2), MigrationAssistantFeature.Problem.newerFile),
		(.fileTooLarge, .fileTooLarge),
		(.invalidFile, .unreadableFile),
	])
	internal func aFileThatCantBeUsedSaysWhy(
		failure: MigrationFailure,
		problem: MigrationAssistantFeature.Problem
	) async {
		let store = TestStore(initialState: MigrationAssistantFeature.State(destination: destination, phase: .selecting)) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.migrationAssistant.addFile = { _ in throw failure }
		}

		await store.send(.ui(.fileChosen(URL(fileURLWithPath: "/tmp/x"))))
		await store.receive(\.event.fileFailed) { $0.problem = problem }
	}

	@Test
	internal func discoveryWithoutAdaptersShowsNoSourcesAndCannotInspect() async {
		let store = TestStore(initialState: MigrationAssistantFeature.State(destination: destination)) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.migrationAssistant = .init()
		}

		await store.send(.ui(.task)) { $0.phase = .discovering }
		await store.receive(\.event.discovered) { $0.phase = .selecting }
		#expect(!store.state.canInspect)
		await store.send(.ui(.inspect))
		await store.send(.ui(.dismiss))
		await store.receive(\.delegate.dismissed)
	}

	@Test
	internal func selectionPreviewImportAndDone() async {
		var bookmarks = preview
		bookmarks.categories.removeLast()
		let bookmarksOnly = bookmarks
		let bookmarksPlan = MigrationPlan(id: planID, preview: bookmarksOnly)
		let progress = MigrationProgress(
			planID: planID,
			category: .bookmarks,
			completedCategories: 0,
			totalCategories: 1
		)
		let report = MigrationReport(
			planID: planID,
			outcome: .completed,
			categories: [.init(category: .bookmarks, status: .committed, imported: [key(.bookmarks, "b1")])]
		)
		let executed = LockIsolated<[MigrationPlan]>([])
		let store = TestStore(initialState: MigrationAssistantFeature.State(destination: destination)) {
			MigrationAssistantFeature()
		} withDependencies: { [source] in
			$0.uuid = .constant(UUID(0))
			$0.migrationAssistant.discover = { [source] }
			$0.migrationAssistant.inspect = { _, categories, _ in
				expectNoDifference(categories, [.bookmarks])
				return bookmarksOnly
			}
			$0.migrationAssistant.execute = { plan in
				executed.withValue { $0.append(plan) }
				return AsyncThrowingStream { continuation in
					continuation.yield(.progress(progress))
					continuation.yield(.finished(report))
					continuation.finish()
				}
			}
		}

		await store.send(.ui(.task)) { $0.phase = .discovering }
		await store.receive(\.event.discovered) {
			$0.phase = .selecting
			$0.sources = [self.source]
			$0.selectedSourceID = self.sourceID
			$0.selectedCategories = [.bookmarks, .openTabs]
		}
		await store.send(.ui(.toggleCategory(.openTabs))) { $0.selectedCategories = [.bookmarks] }
		await store.send(.ui(.inspect)) { $0.phase = .inspecting }
		await store.receive(\.event.inspected) {
			$0.phase = .previewing
			$0.preview = bookmarksOnly
		}
		await store.send(.ui(.startImport)) {
			$0.phase = .importing
			$0.plan = bookmarksPlan
		}
		await store.receive(\.event.execution) { $0.progress = progress }
		await store.receive(\.event.execution) {
			$0.phase = .finished
			$0.report = report
		}
		#expect(!store.state.canRetry)
		await store.send(.ui(.done))
		await store.receive(\.delegate.finished)
		expectNoDifference(executed.value, [bookmarksPlan])
	}

	@Test
	internal func cancellationKeepsConsumingUntilTheCancelledReportThenRetryReusesThePlan() async {
		let (stream, continuation) = AsyncThrowingStream<MigrationEvent, any Error>.makeStream()
		let cancelledReport = MigrationReport(
			planID: planID,
			outcome: .cancelled,
			categories: [
				.init(category: .bookmarks, status: .committed, imported: [key(.bookmarks, "b1")]),
				.init(category: .openTabs, status: .notStarted),
			]
		)
		let streams = LockIsolated([stream])
		let executed = LockIsolated<[MigrationPlan.ID]>([])
		let cancelled = LockIsolated<[MigrationPlan.ID]>([])
		let store = TestStore(initialState: previewing()) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.uuid = .constant(UUID(0))
			$0.migrationAssistant.execute = { plan in
				executed.withValue { $0.append(plan.id) }
				return streams.withValue { $0.removeFirst() }
			}

			// The service stops at the next category boundary and still reports.
			$0.migrationAssistant.cancel = { id in
				cancelled.withValue { $0.append(id) }
				continuation.yield(.finished(cancelledReport))
				continuation.finish()
			}
		}

		await store.send(.ui(.startImport)) {
			$0.phase = .importing
			$0.plan = self.plan
		}
		#expect(!store.state.canDismiss)
		await store.send(.ui(.dismiss))
		await store.send(.ui(.cancel)) { $0.phase = .cancelling }
		await store.receive(\.event.execution) {
			$0.phase = .finished
			$0.report = cancelledReport
		}
		expectNoDifference(cancelled.value, [planID])
		#expect(store.state.canRetry)

		// Retry runs the same plan; the service skips already committed keys.
		let completed = MigrationReport(
			planID: planID,
			outcome: .completed,
			categories: [
				.init(category: .bookmarks, status: .committed, alreadyImported: [key(.bookmarks, "b1")]),
				.init(category: .openTabs, status: .committed, imported: [key(.openTabs, "t1")]),
			]
		)
		streams.setValue([
			AsyncThrowingStream {
				$0.yield(.finished(completed))
				$0.finish()
			},
		])
		await store.send(.ui(.retry)) {
			$0.phase = .importing
			$0.report = nil
		}
		await store.receive(\.event.execution) {
			$0.phase = .finished
			$0.report = completed
		}
		expectNoDifference(executed.value, [planID, planID])
	}

	@Test
	internal func partialSuccessOffersRetryAndIgnoresStaleRunEvents() async {
		let partial = MigrationReport(
			planID: planID,
			outcome: .partiallyCompleted,
			categories: [
				.init(category: .bookmarks, status: .committed, imported: [key(.bookmarks, "b1")]),
				.init(
					category: .openTabs,
					status: .failed,
					issues: [.init(sourceItemID: nil, category: .openTabs, reason: .commitFailed("Disk full"))]
				),
			]
		)
		let store = TestStore(initialState: previewing()) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.uuid = .constant(UUID(0))
			$0.migrationAssistant.execute = { _ in
				AsyncThrowingStream {
					$0.yield(.finished(partial))
					$0.finish()
				}
			}
		}

		await store.send(.ui(.startImport)) {
			$0.phase = .importing
			$0.plan = self.plan
		}
		await store.receive(\.event.execution) {
			$0.phase = .finished
			$0.report = partial
		}
		expectNoDifference(store.state.report?.retryableCategories, [.openTabs])
		#expect(store.state.canRetry)

		// A late event from another plan never replaces the result.
		let stale = MigrationReport(
			planID: .init(rawValue: UUID(9)),
			outcome: .failed,
			categories: []
		)
		await store.send(.event(.execution(.finished(stale))))
	}

	@Test
	internal func invalidDataAndChangedSourcesReturnToSelection() async {
		let store = TestStore(initialState: previewing()) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.uuid = .constant(UUID(0))
			$0.migrationAssistant.execute = { _ in
				AsyncThrowingStream { $0.finish(throwing: MigrationFailure.sourceChanged) }
			}
			$0.migrationAssistant.inspect = { _, _, _ in throw MigrationFailure.unreadableSource("corrupt") }
		}

		await store.send(.ui(.startImport)) {
			$0.phase = .importing
			$0.plan = self.plan
		}
		await store.receive(\.event.executionFailed) {
			$0.phase = .selecting
			$0.preview = nil
			$0.plan = nil
			$0.problem = .sourceChanged
		}

		await store.send(.ui(.inspect)) {
			$0.phase = .inspecting
			$0.problem = nil
		}
		await store.receive(\.event.inspectionFailed) {
			$0.phase = .selecting
			$0.problem = .inspectionFailed
		}

		await store.send(.event(.inspectionFailed(.invalidDestination)))
		var missing = MigrationAssistantFeature.State(destination: nil)
		missing.phase = .selecting
		missing.sources = [source]
		missing.selectedSourceID = sourceID
		missing.selectedCategories = [.bookmarks]
		#expect(!missing.canInspect)
	}

	@Test
	internal func emptyPreviewCannotStartAnImport() async {
		var state = previewing()
		state.preview?.categories = [.init(category: .bookmarks, alreadyImported: [key(.bookmarks, "b1")])]
		let store = TestStore(initialState: state) {
			MigrationAssistantFeature()
		}

		#expect(!store.state.canImport)
		await store.send(.ui(.startImport))
		await store.send(.ui(.back)) {
			$0.phase = .selecting
			$0.preview = nil
		}
	}

	private func previewing() -> MigrationAssistantFeature.State {
		.init(
			destination: destination,
			phase: .previewing,
			sources: [source],
			selectedSourceID: sourceID,
			selectedCategories: [.bookmarks, .openTabs],
			preview: preview
		)
	}

	private func key(
		_ category: MigrationCategory,
		_ id: String
	) -> MigrationItemKey {
		.init(sourceID: sourceID, category: category, sourceItemID: id)
	}
}
