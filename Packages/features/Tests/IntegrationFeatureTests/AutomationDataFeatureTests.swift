import BrowserAutomationClient
import BrowserCore
import BrowserDownloadsClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct AutomationDataFeatureTests {
	@Test
	func historyAndDownloadsStayWithinWholeProfileGrants() throws {
		let state = Self.state()
		let client = state.automationPreferences.clients[0]
		guard case let .success(history) = state.automationData(.init(kind: .history), client: client) else {
			Issue.record("History read failed")
			return
		}

		// Only the granted profile's history, with the query string removed.
		expectNoDifference(history.items.map(\.title), ["Work page"])
		expectNoDifference(history.items.first?.url, "https://capturecontext.dev/work")

		guard case let .success(downloads) = state.automationData(.init(kind: .downloads), client: client) else {
			Issue.record("Downloads read failed")
			return
		}
		expectNoDifference(downloads.items.map(\.title), ["work.zip"])

		var unclassed = client
		unclassed.capabilities.remove(.history)
		expectNoDifference(state.automationData(.init(kind: .history), client: unclassed), .failure(.denied))

		// A space grant doesn't reach profile-wide history.
		var spaceOnly = client
		spaceOnly.scopes = [.space(Self.first, profileID: Self.work)]
		guard case let .success(narrow) = state.automationData(.init(kind: .history), client: spaceOnly) else {
			Issue.record("History read failed")
			return
		}
		#expect(narrow.items.isEmpty)
	}

	@Test
	func dataPagesNeverMixTwoVersionsOfTheList() throws {
		var state = Self.state()
		let client = state.automationPreferences.clients[0]
		state.history.snapshots[Self.work]?.entries.append(
			.init(id: UUID(1100), url: URL(string: "https://capturecontext.dev/older")!, title: "Older", lastVisited: Date(timeIntervalSince1970: 1))
		)
		guard case let .success(first) = state.automationData(.init(kind: .history, limit: 1), client: client) else {
			Issue.record("History read failed")
			return
		}
		let cursor = try #require(first.nextCursor)
		guard case let .success(second) = state.automationData(.init(kind: .history, cursor: cursor, limit: 1), client: client) else {
			Issue.record("Second page failed")
			return
		}
		expectNoDifference(second.items.map(\.title), ["Older"])

		state.history.snapshots[Self.work]?.entries.append(
			.init(id: UUID(1101), url: URL(string: "https://capturecontext.dev/new")!, title: "New", lastVisited: Date(timeIntervalSince1970: 500))
		)
		expectNoDifference(
			state.automationData(.init(kind: .history, cursor: cursor, limit: 1), client: client),
			.failure(.staleCursor)
		)
	}

	/// Engine batch 8's app smoke: a list read while a download runs still goes to the client once
	/// its bytes move, but not once the grant no longer covers what it carries.
	@Test
	func aDataPageLeavesOnceReadThoughItsDownloadsMoveOn() throws {
		var state = Self.state()
		let client = state.automationPreferences.clients[0]
		let read = AutomationDataRequest(kind: .downloads)
		guard case let .success(page) = state.automationData(read, client: client) else {
			Issue.record("Downloads read failed")
			return
		}
		let request = AutomationRequest(id: UUID(93), clientID: client.id, sessionID: UUID(81), operation: .data(read))
		expectNoDifference(state.automationResponseValidation(request, result: .data(page), snapshots: [:]), nil)

		// The running download moves on after the read: its bytes, and with them its revision.
		let index = try #require(state.downloads.queue.downloads.firstIndex { $0.id == Self.workDownload })
		state.downloads.queue.downloads[index].receivedBytes = 4_096
		state.downloads.queue.downloads[index].totalBytes = 8_192
		guard case let .success(moved) = state.automationData(read, client: client) else {
			Issue.record("Downloads read failed")
			return
		}
		#expect(moved != page)
		expectNoDifference(state.automationResponseValidation(request, result: .data(page), snapshots: [:]), nil)

		// An item the client may not read now, or one that's gone, still holds the page back.
		var forged = page
		forged.items[0].profileID = Self.home.rawValue
		expectNoDifference(state.automationResponseValidation(request, result: .data(forged), snapshots: [:]), .staleTarget)
		var other = page
		other.request = .init(kind: .history)
		expectNoDifference(state.automationResponseValidation(request, result: .data(other), snapshots: [:]), .staleTarget)
		state.downloads.queue.downloads.remove(at: index)
		expectNoDifference(state.automationResponseValidation(request, result: .data(page), snapshots: [:]), .staleTarget)

		// A narrower grant keeps no profile-wide downloads.
		state = Self.state()
		state.automationPreferences.clients[0].scopes = [.space(Self.first, profileID: Self.work)]
		expectNoDifference(state.automationResponseValidation(request, result: .data(page), snapshots: [:]), .staleTarget)
	}

	@Test
	func linksUseTheUsersRulesAndShortcuts() {
		let state = Self.state()
		state.settings.$searchShortcuts.withLock { $0 = [
			.init(name: "Wiki", keyword: "w", template: "https://en.wikipedia.org/wiki/Special:Search?search={query}"),
		] }
		let clean = state.automationLink(.init(kind: .clean, url: URL(string: "https://capturecontext.dev/?utm_source=x&id=1")!))
		expectNoDifference(clean.map(\.url), .success("https://capturecontext.dev/?id=1"))
		let bang = state.automationLink(.init(kind: .bang, query: "!w swift"))
		expectNoDifference(bang.map(\.url), .success("https://en.wikipedia.org/wiki/Special:Search?search=swift"))
		expectNoDifference(state.automationLink(.init(kind: .bang, query: "!nope x")).map(\.url), .failure(.routeUnresolved))
	}

	@Test
	func linksResolveBundledBangsAfterTheUsersShortcuts() async throws {
		var state = Self.state()
		state.settings.$searchShortcuts.withLock { $0 = [
			.init(name: "Wiki", keyword: "w", template: "https://en.wikipedia.org/wiki/Special:Search?search={query}"),
			.init(name: "Off", keyword: "ddg", template: "https://off.example/?q={query}", isEnabled: false),
		] }
		expectNoDifference(state.automationLink(.init(kind: .bang, query: "!mdn fetch")).map(\.url), .failure(.routeUnresolved))

		state.settings.bangs = try await BangCatalog.bundled()
		expectNoDifference(
			state.automationLink(.init(kind: .bang, query: "!mdn fetch api")).map(\.url),
			.success("https://developer.mozilla.org/search?q=fetch%20api")
		)
		expectNoDifference(
			state.automationLink(.init(kind: .bang, query: "g swift")).map(\.url),
			.success("https://www.google.com/search?q=swift")
		)

		// The user's shortcut wins a clash, and a disabled one still owns its keyword.
		expectNoDifference(
			state.automationLink(.init(kind: .bang, query: "!w swift")).map(\.url),
			.success("https://en.wikipedia.org/wiki/Special:Search?search=swift")
		)
		expectNoDifference(state.automationLink(.init(kind: .bang, query: "!ddg swift")).map(\.url), .failure(.routeUnresolved))
	}

	@Test
	func archiveRestoreNeedsADestinationWhenItsSpaceIsGoneAndNeverRunsTwice() async throws {
		var state = Self.state()

		// The archived tab's space was deleted.
		state.workspace.archive = [Self.archived(space: Space.ID(rawValue: UUID(1099)))]
		state.main.sidebar.organization = state.workspace
		let client = state.automationPreferences.clients[0]
		let entry = try #require(state.automationDataItems(.archive, client: client).first)

		let (store, responses) = Self.store(state)
		await store.send(.automation(.event(.host(.request(Self.restore(entry, id: 84, operation: 83))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(responses.value.last, .failure(.routeUnresolved))

		let space = try #require(
			AutomationInventoryBuilder.items(client: client, organization: state.workspace, snapshots: [:])
				.first { $0.id == Self.first.rawValue }
		)
		await store.send(.automation(.event(.host(.request(Self.restore(entry, id: 85, operation: 86, destination: space))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.archive.isEmpty)
		let restored = store.state.workspace.spaces[id: Self.first]?.unpinnedTabs.count
		expectNoDifference(restored, 2)
		guard case .command = responses.value.last else {
			Issue.record("Restore did not commit: \(String(describing: responses.value.last))")
			return
		}

		// Retrying with a new operation finds nothing to restore.
		await store.send(.automation(.event(.host(.request(Self.restore(entry, id: 87, operation: 88, destination: space))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.spaces[id: Self.first]?.unpinnedTabs.count, 2)
		expectNoDifference(responses.value.last, .failure(.denied))
	}

	@Test
	func cancellingADownloadWaitsForApproval() async throws {
		var state = Self.state()
		state.automationPreferences.clients[0].approvalPolicy = .alwaysAsk
		let client = state.automationPreferences.clients[0]
		let item = try #require(state.automationDataItems(.downloads, client: client).first)
		var cancelled: [BrowserDownload.ID] = []
		let (store, responses) = Self.store(state) {
			$0.browserDownloads.cancel = { cancelled.append($0) }
		}
		let request = AutomationRequest(
			id: UUID(84),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .command(.init(
				operationID: UUID(83),
				action: .cancelDownload,
				targetID: item.id,
				expectedRevision: item.revision
			))
		)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.automation.pending[request.id]?.awaitingApproval == true)
		#expect(cancelled.isEmpty)

		await store.send(.automation(.ui(.approve(request.id))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(cancelled, [Self.workDownload])
		guard case .command = responses.value.last else {
			Issue.record("Cancel did not commit: \(String(describing: responses.value.last))")
			return
		}
	}

	@Test
	func anApprovalDuringLaunchOnboardingWaitsForTheMainWindow() async throws {
		var state = Self.state()
		state.automationPreferences.clients[0].approvalPolicy = .alwaysAsk
		let client = state.automationPreferences.clients[0]
		let item = try #require(state.automationDataItems(.downloads, client: client).first)

		// DEV-838: launch onboarding holds the main window back.
		state.windowIsOpen = false
		state.mainWindowWaitsForOnboarding = true
		state.onboarding = .init(destination: .init(
			profileID: state.main.sidebar.space.profileID,
			spaceID: state.main.sidebar.spaceID
		))
		let (store, _) = Self.store(state)
		let request = AutomationRequest(
			id: UUID(84),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .command(.init(
				operationID: UUID(83),
				action: .cancelDownload,
				targetID: item.id,
				expectedRevision: item.revision
			))
		)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		// The approval waits in the held window; onboarding comes forward instead.
		#expect(store.state.automation.pending[request.id]?.awaitingApproval == true)
		#expect(!store.state.windowIsOpen)
		#expect(store.state.onboardingFocusRequest == 1)
	}

	@Test
	func startingADownloadAsksEveryTimeEvenUnderATemporaryGrant() async throws {
		var state = Self.state()
		state.automationPreferences.clients[0].approvalPolicy = .alwaysAsk
		state.automationPreferences.clients[0].mutationGrantUntil = Date(timeIntervalSince1970: 130)
		let client = state.automationPreferences.clients[0]
		let started = LockIsolated<[Profile.ID]>([])
		let initial = state.downloads.queue
		let ledger = LockIsolated(initial)
		let (store, responses) = Self.store(state) {
			$0.browserDownloads.snapshot = { ledger.value }
			$0.browserDownloads.start = { profileID, url in
				started.withValue { $0.append(profileID) }
				#expect(url == Self.fileURL)
				ledger.withValue { $0.downloads.insert(Self.newDownload, at: 0) }
				return Self.newDownload.id
			}
		}
		let request = try Self.start(state: state, id: 90, operation: 91)
		#expect(store.state.automation.mutationGrantIsActive(for: client, now: Date(timeIntervalSince1970: 100)))

		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.automation.pending[request.id]?.awaitingApproval == true)
		#expect(started.value.isEmpty)

		await store.send(.automation(.ui(.approve(request.id))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(started.value, [Self.work])
		let result = AutomationResult.command(.init(
			operationID: UUID(91),
			status: .acceptedLoading,
			targetID: Self.newDownload.id.automationID
		))
		expectNoDifference(responses.value.last, result)

		// The new transfer reached state with the result, so a list and the gate see it.
		#expect(store.state.downloads.queue.downloads.contains { $0.id == Self.newDownload.id })
		expectNoDifference(store.state.automationResponseValidation(request, result: result, snapshots: [:]), nil)

		// A receipt naming another profile's download, or none, never leaves Arx.
		let foreign = AutomationResult.command(.init(
			operationID: UUID(91),
			status: .acceptedLoading,
			targetID: BrowserDownload.ID(profileID: Self.home, guid: "home-guid").automationID
		))
		expectNoDifference(store.state.automationResponseValidation(request, result: foreign, snapshots: [:]), .denied)
		let empty = AutomationResult.command(.init(operationID: UUID(91), status: .acceptedLoading))
		expectNoDifference(store.state.automationResponseValidation(request, result: empty, snapshots: [:]), .denied)
	}

	@Test
	func aStandingPolicyStartsADownloadWithoutAsking() async throws {
		let state = Self.state()
		let started = LockIsolated(0)
		let (store, responses) = Self.store(state) {
			$0.browserDownloads.start = { _, _ in
				started.withValue { $0 += 1 }
				return Self.newDownload.id
			}
		}
		await store.send(.automation(.event(.host(.request(try Self.start(state: state, id: 90, operation: 91))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(started.value, 1)
		guard case .command = responses.value.last else {
			Issue.record("Start did not answer: \(String(describing: responses.value.last))")
			return
		}
	}

	@Test
	func startingADownloadNeedsTheDownloadsClassAndAWholeProfileGrant() async throws {
		var unclassed = Self.state()
		unclassed.automationPreferences.clients[0].capabilities.remove(.downloads)
		var spaceOnly = Self.state()
		spaceOnly.automationPreferences.clients[0].scopes = [.space(Self.first, profileID: Self.work)]

		for state in [unclassed, spaceOnly] {
			let started = LockIsolated(0)
			let (store, responses) = Self.store(state) {
				$0.browserDownloads.start = { _, _ in
					started.withValue { $0 += 1 }
					return Self.newDownload.id
				}
			}

			// The space-only grant lists no profile item, so the work profile's revision comes from a full grant.
			await store.send(.automation(.event(.host(.request(try Self.start(state: Self.state(), id: 90, operation: 91))))))
			await store.finish()
			await store.skipReceivedActions(strict: false)
			expectNoDifference(started.value, 0)
			expectNoDifference(responses.value.last, .failure(.denied))
		}
	}

	@Test
	func startFailuresAnswerWithoutADownload() async throws {
		let cases: [(BrowserDownloadsClient.Failure, AutomationFailure)] = [
			(.startTimedOut, .timedOut),
			(.couldNotStart, .engineFailed),
			(.unavailable, .unsupported),
		]
		for (thrown, expected) in cases {
			let state = Self.state()
			let (store, responses) = Self.store(state) {
				$0.browserDownloads.start = { _, _ in throw thrown }
			}
			await store.send(.automation(.event(.host(.request(try Self.start(state: state, id: 90, operation: 91))))))
			await store.finish()
			await store.skipReceivedActions(strict: false)
			expectNoDifference(responses.value.last, .failure(expected))
		}
	}

	@Test
	func downloadRequestsReadTheLedgerInsteadOfAStaleQueue() async throws {
		var state = Self.state()
		let current = state.downloads.queue

		// Nothing observes the queue, so state still holds an older, empty copy.
		state.downloads.queue = .init()
		let client = state.automationPreferences.clients[0]
		let (store, responses) = Self.store(state) {
			$0.browserDownloads.snapshot = { current }
		}
		let request = AutomationRequest(
			id: UUID(92),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .data(.init(kind: .downloads))
		)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		guard case let .data(page) = responses.value.last else {
			Issue.record("List did not answer: \(String(describing: responses.value.last))")
			return
		}
		expectNoDifference(page.items.map(\.title), ["work.zip"])
	}

	// MARK: - Fixture

	nonisolated static let work: Profile.ID = .init(rawValue: UUID(1000))
	static let home: Profile.ID = .init(rawValue: UUID(1001))
	static let first: Space.ID = .init(rawValue: UUID(1002))
	static let elsewhere: Space.ID = .init(rawValue: UUID(1003))
	static let tab: BrowserCore.Tab.ID = .init(rawValue: UUID(1004))
	static let workDownload: BrowserDownload.ID = .init(profileID: work, guid: "work-guid")
	nonisolated static let fileURL: URL = URL(string: "https://capturecontext.dev/file.zip")!
	nonisolated static let newDownload: BrowserDownload = .init(
		id: .init(profileID: work, guid: "new-guid"),
		profileName: "Work",
		url: fileURL,
		filename: "file.zip",
		status: .inProgress,
		startedAt: Date(timeIntervalSince1970: 99)
	)

	static func start(
		state: AppFeature.State,
		id: Int,
		operation: Int
	) throws -> AutomationRequest {
		let client = state.automationPreferences.clients[0]
		let profile = try #require(
			AutomationInventoryBuilder.items(client: client, organization: state.workspace, snapshots: [:])
				.first { $0.id == work.rawValue && $0.kind == .profile }
		)
		return .init(
			id: UUID(id),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .command(.init(
				operationID: UUID(operation),
				action: .startDownload,
				targetID: profile.id,
				expectedRevision: profile.revision,
				url: fileURL
			))
		)
	}

	static func archived(space: Space.ID) -> ArchivedTab {
		.init(
			id: .init(rawValue: UUID(1050)),
			groupID: UUID(1051),
			closedAt: Date(timeIntervalSince1970: 50),
			originalSpaceID: space,
			originalSpaceName: "Gone",
			originalIndex: 0,
			tab: .init(
				id: .init(rawValue: UUID(1052)),
				profileID: work,
				restoration: .init(title: "Archived", url: URL(string: "https://capturecontext.dev/archived")!)
			)
		)
	}

	static func state() -> AppFeature.State {
		let organization = BrowserOrganization(
			profiles: [.init(id: work, name: "Work"), .init(id: home, name: "Home")],
			spaces: [
				.init(id: first, profileID: work, name: "First", unpinnedTabs: [tab]),
				.init(id: elsewhere, profileID: home, name: "Elsewhere"),
			],
			tabs: [.init(id: tab, profileID: work, restoration: .init(title: "Page", url: URL(string: "https://capturecontext.dev/")!))]
		)
		let client = AutomationClient(
			id: UUID(80),
			name: "Agent",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: [.profile(work)],
			capabilities: [.read, .organize, .history, .downloads],
			approvalPolicy: .never,
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: first),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.windowIsOpen = true
		state.automation.sessions[UUID(81)] = client.id
		state.history.snapshots = [
			work: .init(profileID: work, entries: [
				.init(id: UUID(1010), url: URL(string: "https://capturecontext.dev/work?token=secret")!, title: "Work page", lastVisited: Date(timeIntervalSince1970: 100)),
			]),
			home: .init(profileID: home, entries: [
				.init(id: UUID(1011), url: URL(string: "https://capturecontext.dev/home")!, title: "Home page", lastVisited: Date(timeIntervalSince1970: 200)),
			]),
		]
		state.downloads.queue = .init(downloads: [
			.init(id: workDownload, profileName: "Work", filename: "work.zip", status: .inProgress, startedAt: Date(timeIntervalSince1970: 10)),
			.init(id: .init(profileID: home, guid: "home-guid"), profileName: "Home", filename: "home.zip", status: .complete, startedAt: Date(timeIntervalSince1970: 20)),
			.init(id: .init(profileID: work, guid: "private-guid"), profileName: "Work", filename: "private.zip", status: .complete, startedAt: Date(timeIntervalSince1970: 30), isPrivate: true),
		])
		return state
	}

	static func restore(
		_ entry: AutomationDataItem,
		id: Int,
		operation: Int,
		destination: AutomationInventoryItem? = nil
	) -> AutomationRequest {
		.init(
			id: UUID(id),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .command(.init(
				operationID: UUID(operation),
				action: .restoreArchived,
				targetID: entry.id,
				expectedRevision: entry.revision,
				destinationID: destination?.id,
				destinationRevision: destination?.revision
			))
		)
	}

	static func store(
		_ state: AppFeature.State,
		dependencies: (inout DependencyValues) -> Void = { _ in }
	) -> (TestStoreOf<AppFeature>, LockIsolated<[AutomationResult]>) {
		let responses = LockIsolated<[AutomationResult]>([])
		let queue = state.downloads.queue
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.withValue { $0.append(value) } }
			$0.automationControl.authorize = { _ in true }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { _ in }
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.openAuthorized = { _, _ in }
			$0.browserEngine.events = { _ in AsyncStream { $0.finish() } }
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.continuousClock = ImmediateClock()
			$0.browserDownloads.snapshot = { queue }
			dependencies(&$0)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return (store, responses)
	}
}
