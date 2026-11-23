import BrowserCore
import BrowserExtensionsClient
import CustomDump
import Foundation
import MigrationAssistant
import Testing
import _ComposableArchitecture
import _TestSupport
@testable import MigrationAssistantFeature

/// Store extensions an import brought from Arc (DEV-845), installed one at a time after the
/// user reviews each. The extensions client and the receiving profiles are replaced; nothing
/// is downloaded or installed.
@Suite(.dependencies)
@MainActor
internal struct ExtensionImportFeatureTests {
	private let work: MigrationSourceProfile = .init(id: "Profile 1", name: "Work")
	private let personal: MigrationSourceProfile = .init(id: "Default", name: "Personal")
	private let workProfile: Profile = .init(id: .init(rawValue: UUID(1)), name: "Work")
	private let destination: MigrationDestination = .init(
		profileID: .init(rawValue: UUID(1)),
		spaceID: .init(rawValue: UUID(2)),
		defaultRoute: .newProfile
	)

	private static let calm = "aaaabbbbccccddddeeeeffffgggghhhh"
	private static let reader = "eeeeffffgggghhhhiiiijjjjkkkkllll"
	private static let tool = "bbbbccccddddeeeeffffgggghhhhiiii"
	private static let notes = "ccccddddeeeeffffgggghhhhiiiijjjj"

	private var report: MigrationReport {
		.init(
			planID: .init(rawValue: UUID(9)),
			outcome: .completed,
			categories: [
				.init(
					category: .extensions,
					status: .committed,
					issues: [
						issue(.init(id: Self.calm, name: "Ad Calm", fromWebStore: true, profile: work)),
						issue(.init(id: Self.tool, name: "My Tool", fromWebStore: false, profile: work)),
						issue(.init(id: Self.reader, name: "Reader", fromWebStore: true, profile: work)),
						issue(.init(id: Self.notes, name: "Notes", fromWebStore: true, profile: personal)),
					]
				),
			]
		)
	}

	private func issue(_ value: MigrationIssue.Extension) -> MigrationIssue {
		.init(sourceItemID: (value.profile?.id ?? "") + "/" + value.id, category: .extensions, reason: .reinstallManually(value))
	}

	private func inventory(_ installed: [String] = []) -> BrowserExtensionInventory {
		.init(
			id: UUID(7),
			profileID: workProfile.id,
			revision: 3,
			extensions: installed.map { .init(id: $0, name: $0, version: "1", state: .enabled) }
		)
	}

	private func prompt(_ id: String) -> BrowserExtensionInstallPrompt {
		.init(
			id: UUID(id == Self.calm ? 20 : 21),
			profileID: workProfile.id,
			inventoryID: UUID(7),
			revision: 3,
			candidate: .init(
				extensionID: id,
				name: id,
				version: "1",
				packageSHA256: "hash",
				sourceBasename: "Chrome Web Store",
				isUpdate: false,
				requiredPermissions: .init(),
				optionalPermissions: .init(),
				warnings: []
			)
		)
	}

	private final class Calls: @unchecked Sendable {
		internal var prepared: [String] = []
		internal var resolved: [(String, Bool)] = []
		internal var cancelled: [String] = []
	}

	private func extensions(
		_ calls: Calls,
		installed: [String] = [],
		available: Bool = true
	) -> BrowserExtensionsClient {
		.init(
			isAvailable: true,
			installationAvailability: { true },
			inspect: { _ in self.inventory(installed) },
			resolveInstallation: { prompt, accept in
				calls.resolved.append((prompt.candidate.extensionID, accept))
				return self.inventory([prompt.candidate.extensionID])
			},
			cancelInstallation: { calls.cancelled.append($0.candidate.extensionID) },
			webstoreImportAvailability: { available },
			prepareWebstoreImport: { request in
				calls.prepared.append(request.extensionID)
				return self.prompt(request.extensionID)
			}
		)
	}

	/// Work went to an Arx profile; Personal has none.
	private func receivingProfile() -> @Sendable (String, MigrationDestination) async -> Profile? {
		{ [workProfile] id, _ in id == "Profile 1" ? workProfile : nil }
	}

	private func id(
		_ profile: MigrationSourceProfile,
		_ extensionID: String
	) -> String {
		profile.id + "/" + extensionID
	}

	@Test
	internal func storeExtensionsInstallOneAtATimeAfterTheUsersReview() async {
		let calls: Calls = .init()
		let store = TestStore(initialState: ExtensionImportFeature.State(destination: destination, report: report)) {
			ExtensionImportFeature()
		} withDependencies: {
			$0.browserExtensions = extensions(calls)
			$0.migrationAssistant.receivingProfile = receivingProfile()
		}
		#expect(store.state.hasInstallableExtensions)

		await store.send(.start) {
			$0.phase = .installing
			$0.items[id: id(work, Self.tool)]?.outcome = .reinstallManually
		}
		#expect(store.state.position?.index == 1)
		#expect(store.state.position?.count == 3)
		await store.receive(\.event.prepared) {
			$0.items[id: id(work, Self.calm)]?.profileName = "Work"
			$0.prompt = prompt(Self.calm)
		}
		#expect(store.state.isRunning)

		await store.send(.ui(.respond(prompt(Self.calm), true))) {
			$0.prompt = nil
			$0.isResolving = true
		}
		await store.receive(\.event.resolved) {
			$0.isResolving = false
			$0.items[id: id(work, Self.calm)]?.outcome = .installed
		}
		await store.receive(\.event.prepared) {
			$0.items[id: id(work, Self.reader)]?.profileName = "Work"
			$0.prompt = prompt(Self.reader)
		}

		await store.send(.ui(.respond(prompt(Self.reader), false))) {
			$0.prompt = nil
			$0.isResolving = true
		}
		await store.receive(\.event.resolved) {
			$0.isResolving = false
			$0.items[id: id(work, Self.reader)]?.outcome = .declined
		}

		// Personal has no Arx profile, so its extension has nowhere to go.
		await store.receive(\.event.prepared) {
			$0.items[id: id(personal, Self.notes)]?.outcome = .failed(.missingProfile)
			$0.phase = .finished
		}
		await store.receive(\.delegate.finished)

		#expect(calls.prepared == [Self.calm, Self.reader])
		expectNoDifference(calls.resolved.map(\.0), [Self.calm, Self.reader])
		expectNoDifference(calls.resolved.map(\.1), [true, false])
		#expect(store.state.count(.installed) == 1)
		#expect(!store.state.isRunning)
	}

	@Test
	internal func anExtensionTheProfileHasIsNotOfferedAgain() async {
		let calls: Calls = .init()
		var state = ExtensionImportFeature.State(destination: destination, report: report)
		state.items.removeAll { $0.extension.id != Self.calm }
		let store = TestStore(initialState: state) {
			ExtensionImportFeature()
		} withDependencies: {
			$0.browserExtensions = extensions(calls, installed: [Self.calm])
			$0.migrationAssistant.receivingProfile = receivingProfile()
		}

		await store.send(.start) { $0.phase = .installing }
		await store.receive(\.event.prepared) {
			$0.items[id: id(work, Self.calm)]?.profileName = "Work"
			$0.items[id: id(work, Self.calm)]?.outcome = .alreadyInstalled
			$0.phase = .finished
		}
		await store.receive(\.delegate.finished)
		#expect(calls.prepared.isEmpty)
	}

	@Test
	internal func anEngineWithoutStoreInstallsReportsEachAsFailed() async {
		let calls: Calls = .init()
		var state = ExtensionImportFeature.State(destination: destination, report: report)
		state.items.removeAll { $0.extension.id != Self.calm }
		let store = TestStore(initialState: state) {
			ExtensionImportFeature()
		} withDependencies: {
			$0.browserExtensions = extensions(calls, available: false)
			$0.migrationAssistant.receivingProfile = receivingProfile()
		}

		await store.send(.start) { $0.phase = .installing }
		await store.receive(\.event.prepared) {
			$0.items[id: id(work, Self.calm)]?.outcome = .failed(.unavailable)
			$0.phase = .finished
		}
		await store.receive(\.delegate.finished)
	}

	@Test
	internal func skipAllDeclinesTheReviewAndSkipsTheRest() async {
		let calls: Calls = .init()
		let store = TestStore(initialState: ExtensionImportFeature.State(destination: destination, report: report)) {
			ExtensionImportFeature()
		} withDependencies: {
			$0.browserExtensions = extensions(calls)
			$0.migrationAssistant.receivingProfile = receivingProfile()
		}

		await store.send(.start) {
			$0.phase = .installing
			$0.items[id: id(work, Self.tool)]?.outcome = .reinstallManually
		}
		await store.receive(\.event.prepared) {
			$0.items[id: id(work, Self.calm)]?.profileName = "Work"
			$0.prompt = prompt(Self.calm)
		}
		await store.send(.ui(.skipAll)) {
			$0.prompt = nil
			$0.items[id: id(work, Self.calm)]?.outcome = .declined
			$0.items[id: id(work, Self.reader)]?.outcome = .skipped
			$0.items[id: id(personal, Self.notes)]?.outcome = .skipped
			$0.phase = .finished
		}
		await store.receive(\.delegate.finished)
		await store.finish()
		expectNoDifference(calls.resolved.map(\.0), [Self.calm])
		expectNoDifference(calls.resolved.map(\.1), [false])
	}

	/// A package that's still downloading can be skipped with the rest: nothing waits for it.
	@Test
	internal func skipAllWorksWhileAPackageDownloads() async {
		var state = ExtensionImportFeature.State(destination: destination, report: report)
		state.items.removeAll { $0.extension.id != Self.calm }
		let store = TestStore(initialState: state) {
			ExtensionImportFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in self.inventory() },
				webstoreImportAvailability: { true },
				prepareWebstoreImport: { _ in
					try await Task.sleep(for: .seconds(600))
					throw BrowserExtensionsClient.Failure.timeout
				}
			)
			$0.migrationAssistant.receivingProfile = receivingProfile()
		}

		await store.send(.start) { $0.phase = .installing }
		await store.send(.ui(.skipAll)) {
			$0.items[id: id(work, Self.calm)]?.outcome = .skipped
			$0.phase = .finished
		}
		await store.receive(\.delegate.finished)
		await store.finish()
	}

	@Test
	internal func customizeCanImportExtensionsAloneAndWaitsForThemBeforeRetrying() {
		let source: MigrationSource = .init(
			id: .init(rawValue: "arc"),
			kind: .externalBrowser,
			name: "Arc",
			categories: [.extensions],
			preservesOrganization: true
		)
		var state = MigrationAssistantFeature.State(
			destination: destination,
			phase: .previewing,
			sources: [source],
			selectedSourceID: source.id,
			selectedCategories: [.extensions]
		)
		state.preview = .init(
			sourceID: source.id,
			snapshotID: "s",
			destination: destination,
			categories: [.init(category: .extensions, issues: report.categories[0].issues)]
		)
		#expect(state.canImport)

		state.phase = .finished
		state.plan = .init(
			id: .init(rawValue: UUID(9)),
			sourceID: source.id,
			snapshotID: "s",
			destination: destination,
			categories: [.extensions]
		)
		state.report = .init(
			planID: .init(rawValue: UUID(9)),
			outcome: .failed,
			categories: [.init(category: .extensions, status: .failed)]
		)
		#expect(state.canRetry)
		state.extensionImport = .init(destination: destination, report: report)
		state.extensionImport?.phase = .installing
		#expect(!state.canRetry)
		#expect(!state.canDismiss)
	}

	@Test
	internal func aStaleAnswerIsIgnored() async {
		let calls: Calls = .init()
		var state = ExtensionImportFeature.State(destination: destination, report: report)
		state.phase = .installing
		state.prompt = prompt(Self.calm)
		let store = TestStore(initialState: state) {
			ExtensionImportFeature()
		} withDependencies: {
			$0.browserExtensions = extensions(calls)
		}

		await store.send(.ui(.respond(prompt(Self.reader), true)))
		#expect(calls.resolved.isEmpty)
	}

	// MARK: - In Customize

	@Test
	internal func customizeInstallsStoreExtensionsBeforeItCanClose() async {
		let calls: Calls = .init()
		let planID: MigrationPlan.ID = .init(rawValue: UUID(9))
		let source: MigrationSource = .init(
			id: .init(rawValue: "arc"),
			kind: .externalBrowser,
			name: "Arc",
			categories: [.extensions],
			preservesOrganization: true
		)
		var state = MigrationAssistantFeature.State(
			destination: destination,
			phase: .importing,
			sources: [source],
			selectedSourceID: source.id,
			selectedCategories: [.extensions]
		)
		state.plan = .init(
			id: planID,
			sourceID: source.id,
			snapshotID: "s",
			destination: destination,
			categories: [.extensions]
		)
		var report = self.report
		report.categories[0].issues.removeAll { issue in
			guard case let .reinstallManually(value) = issue.reason else { return true }
			return value.id != Self.calm
		}
		let store = TestStore(initialState: state) {
			MigrationAssistantFeature()
		} withDependencies: {
			$0.browserExtensions = extensions(calls)
			$0.migrationAssistant.receivingProfile = receivingProfile()
		}
		store.exhaustivity = .off

		await store.send(.event(.execution(.finished(report))))
		await store.receive(\.extensionImport.start)
		await store.receive(\.extensionImport.event.prepared)
		#expect(store.state.extensionImport?.prompt == prompt(Self.calm))
		#expect(!store.state.canDismiss)

		await store.send(.ui(.done))
		await store.send(.extensionImport(.ui(.respond(prompt(Self.calm), true))))
		await store.receive(\.extensionImport.event.resolved)
		await store.receive(\.extensionImport.delegate.finished)
		#expect(store.state.extensionImport?.items.first?.outcome == .installed)
		#expect(store.state.canDismiss)
		#expect(calls.resolved.map(\.1) == [true])
	}

	// MARK: - Install All (DEV-1300)

	/// Install All on the first review installs it and every one after it without showing their
	/// reviews; the one with nowhere to go fails without a press, and the series finishes.
	@Test
	internal func installAllInstallsTheRestWithoutShowingTheirReviews() async {
		let calls: Calls = .init()
		let store = TestStore(initialState: ExtensionImportFeature.State(destination: destination, report: report, sourceName: "Arc")) {
			ExtensionImportFeature()
		} withDependencies: {
			$0.browserExtensions = extensions(calls)
			$0.migrationAssistant.receivingProfile = receivingProfile()
		}

		await store.send(.start) {
			$0.phase = .installing
			$0.items[id: id(work, Self.tool)]?.outcome = .reinstallManually
		}
		await store.receive(\.event.prepared) {
			$0.items[id: id(work, Self.calm)]?.profileName = "Work"
			$0.prompt = prompt(Self.calm)
		}

		// Offered from the first review: three store extensions are left.
		#expect(store.state.offersAcceptAll)
		#expect(store.state.remainingCount == 3)

		await store.send(.ui(.acceptAll)) {
			$0.acceptsAll = true
			$0.prompt = nil
			$0.isResolving = true
		}
		#expect(!store.state.offersAcceptAll)
		await store.receive(\.event.resolved) {
			$0.isResolving = false
			$0.items[id: id(work, Self.calm)]?.outcome = .installed
		}

		// Reader's review arrives and is accepted at once, never shown.
		await store.receive(\.event.prepared) {
			$0.items[id: id(work, Self.reader)]?.profileName = "Work"
			$0.isResolving = true
		}
		await store.receive(\.event.resolved) {
			$0.isResolving = false
			$0.items[id: id(work, Self.reader)]?.outcome = .installed
		}
		await store.receive(\.event.prepared) {
			$0.items[id: id(personal, Self.notes)]?.outcome = .failed(.missingProfile)
			$0.phase = .finished
		}
		await store.receive(\.delegate.finished)

		expectNoDifference(calls.resolved.map(\.0), [Self.calm, Self.reader])
		expectNoDifference(calls.resolved.map(\.1), [true, true])
		#expect(store.state.count(.installed) == 2)
		#expect(store.state.count(.failed(.missingProfile)) == 1)
	}

	/// An install that fails after Install All is counted and the series goes on: no failure
	/// waits for a press of its own.
	@Test
	internal func aFailedInstallDoesNotStopInstallAll() async {
		let calls: Calls = .init()
		var client = extensions(calls)
		client.resolveInstallation = { prompt, accept in
			calls.resolved.append((prompt.candidate.extensionID, accept))
			if prompt.candidate.extensionID == Self.calm { throw BrowserExtensionsClient.Failure.blockedByPolicy }
			return self.inventory([prompt.candidate.extensionID])
		}
		var state = ExtensionImportFeature.State(destination: destination, report: report)
		state.items.removeAll { $0.extension.profile?.id != work.id }
		let store = TestStore(initialState: state) {
			ExtensionImportFeature()
		} withDependencies: { [client] in
			$0.browserExtensions = client
			$0.migrationAssistant.receivingProfile = receivingProfile()
		}

		await store.send(.start) {
			$0.phase = .installing
			$0.items[id: id(work, Self.tool)]?.outcome = .reinstallManually
		}
		await store.receive(\.event.prepared) {
			$0.items[id: id(work, Self.calm)]?.profileName = "Work"
			$0.prompt = prompt(Self.calm)
		}
		await store.send(.ui(.acceptAll)) {
			$0.acceptsAll = true
			$0.prompt = nil
			$0.isResolving = true
		}
		await store.receive(\.event.resolved) {
			$0.isResolving = false
			$0.items[id: id(work, Self.calm)]?.outcome = .failed(.blockedByPolicy)
		}
		await store.receive(\.event.prepared) {
			$0.items[id: id(work, Self.reader)]?.profileName = "Work"
			$0.isResolving = true
		}
		await store.receive(\.event.resolved) {
			$0.isResolving = false
			$0.items[id: id(work, Self.reader)]?.outcome = .installed
			$0.phase = .finished
		}
		await store.receive(\.delegate.finished)
		#expect(store.state.prompt == nil)
	}

	/// Without Install All, a failed install moves on to the next review by itself.
	@Test
	internal func aFailedInstallMovesOnOneAtATime() async {
		let calls: Calls = .init()
		var client = extensions(calls)
		client.resolveInstallation = { prompt, accept in
			calls.resolved.append((prompt.candidate.extensionID, accept))
			throw BrowserExtensionsClient.Failure.unavailable
		}
		var state = ExtensionImportFeature.State(destination: destination, report: report)
		state.items.removeAll { $0.extension.profile?.id != work.id }
		let store = TestStore(initialState: state) {
			ExtensionImportFeature()
		} withDependencies: { [client] in
			$0.browserExtensions = client
			$0.migrationAssistant.receivingProfile = receivingProfile()
		}

		await store.send(.start) {
			$0.phase = .installing
			$0.items[id: id(work, Self.tool)]?.outcome = .reinstallManually
		}
		await store.receive(\.event.prepared) {
			$0.items[id: id(work, Self.calm)]?.profileName = "Work"
			$0.prompt = prompt(Self.calm)
		}
		await store.send(.ui(.respond(prompt(Self.calm), true))) {
			$0.prompt = nil
			$0.isResolving = true
		}
		await store.receive(\.event.resolved) {
			$0.isResolving = false
			$0.items[id: id(work, Self.calm)]?.outcome = .failed(.unavailable)
		}

		// The next review shows straight away; nothing asks about the failure.
		await store.receive(\.event.prepared) {
			$0.items[id: id(work, Self.reader)]?.profileName = "Work"
			$0.prompt = prompt(Self.reader)
		}

		// One left: Install All would be Install, so it's not offered.
		#expect(!store.state.offersAcceptAll)
		await store.send(.ui(.skipAll)) {
			$0.prompt = nil
			$0.items[id: id(work, Self.reader)]?.outcome = .declined
			$0.phase = .finished
		}
		await store.receive(\.delegate.finished)
	}

	/// Install All while the next package is still downloading accepts its review when it
	/// arrives.
	@Test
	internal func installAllWhileAPackageDownloadsAcceptsItWhenItArrives() async {
		let calls: Calls = .init()
		var state = ExtensionImportFeature.State(destination: destination, report: report)
		state.items.removeAll { $0.extension.profile?.id != work.id }
		state.phase = .installing
		state.items[id: id(work, Self.tool)]?.outcome = .reinstallManually
		let store = TestStore(initialState: state) {
			ExtensionImportFeature()
		} withDependencies: {
			$0.browserExtensions = extensions(calls)
			$0.migrationAssistant.receivingProfile = receivingProfile()
		}

		await store.send(.ui(.acceptAll)) { $0.acceptsAll = true }
		await store.send(.event(.prepared(id(work, Self.calm), .review(prompt(Self.calm), profileName: "Work")))) {
			$0.items[id: id(work, Self.calm)]?.profileName = "Work"
			$0.isResolving = true
		}
		await store.receive(\.event.resolved) {
			$0.isResolving = false
			$0.items[id: id(work, Self.calm)]?.outcome = .installed
		}
		await store.receive(\.event.prepared) {
			$0.items[id: id(work, Self.reader)]?.profileName = "Work"
			$0.isResolving = true
		}
		await store.receive(\.event.resolved) {
			$0.isResolving = false
			$0.items[id: id(work, Self.reader)]?.outcome = .installed
			$0.phase = .finished
		}
		await store.receive(\.delegate.finished)
		expectNoDifference(calls.resolved.map(\.1), [true, true])
	}

	@Test
	internal func theReviewSaysWhereEachOneGoes() {
		#expect(
			ExtensionImportReview.detail(publisher: "Raymond Hill", position: (2, 3), sourceName: "Chrome", profileName: "Personal")
			== "Raymond Hill · 2 of 3 from Chrome · into Personal"
		)
		#expect(
			ExtensionImportReview.detail(publisher: nil, position: (1, 2), sourceName: nil, profileName: "Work")
			== "1 of 2 · into Work"
		)
	}
}
