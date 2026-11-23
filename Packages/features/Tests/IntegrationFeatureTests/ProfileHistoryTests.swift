import AppFeature
import BrowserCore
import BrowserEngineClient
import BrowserHistoryClient
import CommandBarFeature
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test(arguments: [false, true])
	internal func historyRecordsSuccessfulOrdinaryWindowsAndDeduplicatesObservation(_ additional: Bool) async throws {
		var state = historyFixture()
		let profile = state.workspace.profiles[0].id
		let tab = state.workspace.tabs[0]
		let windowID = UUID(70)
		if additional {
			state.windows.append(.init(
				organization: state.workspace,
				spaceID: state.main.sidebar.spaceID,
				id: windowID
			))
		}
		let recorded = LockIsolated<[URL]>([])
		let url = URL(string: "https://visited.example/path?q=exact#fragment")!
		let entry = historyEntry(10, url: url)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init(
				record: { id, visit in
					let url = visit.url
					recorded.withValue { $0.append(url) }
					return .init(snapshot: .init(profileID: id, entries: [entry], revision: 1))
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let navigation = MainFeature.Action.viewer(.item(.delegate(.navigation(tab.id, .init(url: url, title: "Visited")))))
		let action = additional
		? AppFeature.Action.windows(.element(id: windowID, action: navigation))
		: .main(navigation)
		await store.send(action)
		await store.receive(\.history.received)
		await store.finish()
		expectNoDifference(recorded.value, [url])
		expectNoDifference(store.state.main.browsingHistory[profile]?.entries, [entry])
		if additional {
			expectNoDifference(store.state.windows[id: windowID]?.browsingHistory[profile]?.entries, [entry])
		}
		await store.send(action)
		await store.finish()
		expectNoDifference(recorded.value, [url])
	}

	@Test
	internal func historyExcludesPrivateProvisionalFailedCredentialAndTemporaryNavigation() async throws {
		var state = historyFixture()
		let tab = state.workspace.tabs[0]
		let privateID = UUID(70)
		state.windows.append(.init(
			organization: state.workspace,
			spaceID: state.main.sidebar.spaceID,
			isPrivate: true,
			id: privateID
		))
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init(
				record: { id, _ in
					Issue.record("Excluded navigation reached persistent history")
					return .init(snapshot: .init(profileID: id))
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let privateNavigation = BrowserNavigation(url: URL(string: "https://private.example")!)
		await store.send(.windows(.element(
			id: privateID,
			action: .viewer(.item(.delegate(.navigation(tab.id, privateNavigation))))
		)))
		for navigation in [
			BrowserNavigation(url: URL(string: "https://loading.example")!, isLoading: true),
			.init(url: URL(string: "https://failed.example")!, errorCode: -1),
			.init(url: URL(string: "file:///tmp/example")!),
			.init(url: URL(string: "https://user:password@capturecontext.dev")!),
		] {
			await store.send(.main(.viewer(.item(.delegate(.navigation(tab.id, navigation))))))
		}
		let temporaryNavigation = BrowserNavigation(url: URL(string: "https://temporary.example")!)
		await store.send(.main(.viewer(.item(.delegate(.navigation(.init(rawValue: UUID(99)), temporaryNavigation))))))
		await store.finish()
		#expect(store.state.history.snapshots.values.allSatisfy { $0.entries.isEmpty })
		#expect(store.state.windows[id: privateID]?.browsingHistory.isEmpty == true)
	}

	/// DEV-728: a Little Arx page is an ordinary page of its profile.
	@Test
	internal func historyRecordsLittleArxPagesEvenUnderAPeek() async throws {
		var state = historyFixture()
		let profile = state.workspace.profiles[0].id
		let little = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: profile,
			restoration: .init(title: "Little", url: URL(string: "https://little.example")!)
		)
		state.littleWindows.append(.init(id: UUID(81), spaceID: state.main.sidebar.spaceID, tab: little))
		var peekHost = LittleArxFeature.State(
			id: UUID(82),
			spaceID: state.main.sidebar.spaceID,
			tab: .init(
				id: .init(rawValue: UUID(83)),
				profileID: profile,
				restoration: .init(title: "Peek", url: URL(string: "https://peek.example")!)
			)
		)
		peekHost.peekID = UUID(84)
		state.littleWindows.append(peekHost)
		let recorded = LockIsolated<[URL]>([])
		let url = URL(string: "https://little.example/visited")!
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init(
				record: { id, visit in
					let url = visit.url
					recorded.withValue { $0.append(url) }
					return .init(snapshot: .init(profileID: id, entries: [], revision: 1))
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.littleWindows(.element(
			id: UUID(81),
			action: .viewer(.delegate(.navigation(little.id, .init(url: url, title: "Visited"))))
		)))
		await store.receive(\.history.received)

		// The source page under a Peek keeps recording; the Peek's own viewer reports
		// through `.peeks`, which history never reads.
		let source = URL(string: "https://peek.example/next")!
		await store.send(.littleWindows(.element(
			id: UUID(82),
			action: .viewer(.delegate(.navigation(peekHost.tab.id, .init(url: source))))
		)))
		await store.receive(\.history.received)
		await store.finish()
		expectNoDifference(recorded.value, [url, source])
	}

	@Test
	internal func historyCandidatesRemainFrozenWhileProfileIndexChanges() async throws {
		var state = historyFixture()
		let profile = state.workspace.profiles[0].id
		let first = historyEntry(10, url: URL(string: "https://first.example")!)
		state.history.snapshots[profile] = .init(profileID: profile, entries: [first], revision: 1)
		state.main.browsingHistory = state.history.snapshots
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.main(.ui(.openCommand(.newTab))))
		await store.receive(\.main.commandBar.present)
		let captured = store.state.main.commandBar.entries
		let capturedHistory = captured.first { $0.presentation.id.hasPrefix("history-") }
		#expect(capturedHistory?.presentation.title == first.title)
		#expect(capturedHistory?.presentation.subtitle == first.url.absoluteString)
		let second = historyEntry(11, url: URL(string: "https://next.example")!)
		await store.send(.history(.received(
			.init(snapshot: .init(profileID: profile, entries: [second, first], revision: 2)),
			epoch: 0
		)))
		expectNoDifference(store.state.main.commandBar.entries, captured)
		#expect(store.state.main.commandCandidates.contains(where: { $0.presentation.title == second.title }))
		await store.send(.history(.received(.init(snapshot: .init(profileID: profile, entries: [], revision: 1)), epoch: 0)))
		expectNoDifference(store.state.history.snapshots[profile]?.entries, [second, first])
	}

	@Test
	internal func historySelectionKeepsExactURLAndCapturedPaneAfterFocusChanges() async throws {
		let organization = fixture()
		let profile = organization.profiles[0].id
		let entry = historyEntry(10, url: URL(string: "https://history.example/a%2Fb?q=first&q=second#fragment")!)
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let source = state.viewer.activePaneID
		state.viewer.item.tab = organization.tabs[0]
		state.viewer.panes.append(.init(id: UUID(80), item: .init(tab: organization.tabs[1])))
		state.viewer.activePaneID = UUID(80)
		state.browsingHistory[profile] = .init(profileID: profile, entries: [entry])
		let calls = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = Store(initialState: state) { MainFeature() } withDependencies: {
			$0.browserEngine.command = { id, command in
				calls.withValue { $0.append(id) }
				expectNoDifference(command, .navigate(entry.url))
			}
		}
		await store.send(.ui(.paneCommand(.address, source))).finish()
		await store.send(.commandBar(.ui(.queryChanged("history.example")))).finish()
		let resultID = try #require(
			store.commandBar.entries.first { if case .openHistory = $0.intent { true } else { false } }?.presentation.id
		)
		await store.send(.commandBar(.ui(.selected(resultID)))).finish()
		expectNoDifference(calls.value, [organization.tabs[0].id])
		expectNoDifference(store.sidebar.organization, organization)
		expectNoDifference(store.viewer.activePaneID, UUID(80))
	}

	@Test
	internal func historyCandidatesStayProfileScopedAtTheRetentionLimit() {
		var state = historyFixture().main
		let profile = state.sidebar.space.profileID
		let other = Profile.ID(rawValue: UUID(90))
		state.browsingHistory[profile] = .init(
			profileID: profile,
			entries: (0..<BrowsingHistorySnapshot.limit).map {
				historyEntry($0 + 100, url: URL(string: "https://history.example/\($0)")!)
			}
		)
		state.browsingHistory[other] = .init(
			profileID: other,
			entries: [historyEntry(99, url: URL(string: "https://other.example")!)]
		)
		let entries = state.commandCandidates.filter { $0.presentation.id.hasPrefix("history-") }
		#expect(entries.count == BrowsingHistorySnapshot.limit)
		#expect(Set(entries.map(\.presentation.id)).count == BrowsingHistorySnapshot.limit)
		#expect(entries.allSatisfy {
			guard case let .openHistory(value) = $0.intent else { return false }
			return value.profileID == profile && value.spaceID == state.sidebar.spaceID
		})
	}

	@Test
	internal func removingProfilePurgesHistoryAndRejectsLateLoad() async throws {
		var state = historyFixture()
		let removed = Profile.ID(rawValue: UUID(90))
		let entry = historyEntry(10, url: URL(string: "https://removed.example")!)
		state.workspace.profiles.append(.init(id: removed, name: "Removed"))
		state.main.sidebar.organization = state.workspace
		state.history.knownProfiles.insert(removed)
		state.history.snapshots[removed] = .init(profileID: removed, entries: [entry])
		state.main.browsingHistory = state.history.snapshots
		let calls = LockIsolated<[Profile.ID]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserHistory = .init(remove: { id in calls.withValue { $0.append(id) } })
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.settings(.delegate(.changeOrganization(.removeProfile(removed)))))
		await store.receive(\.history.removed)
		await store.finish()
		await store.send(.history(.received(.init(snapshot: .init(profileID: removed, entries: [entry])), epoch: 0)))
		expectNoDifference(calls.value, [removed])
		#expect(store.state.history.snapshots[removed] == nil)
		#expect(store.state.main.browsingHistory[removed] == nil)
	}

	@Test(arguments: ["cleared", "space", "profile"])
	internal func staleHistorySelectionsCannotChangeDestinationContext(_ reason: String) async throws {
		var organization = fixture()
		let profile = organization.profiles[0].id
		let other = Profile.ID(rawValue: UUID(80))
		organization.profiles.append(.init(id: other, name: "Other"))
		let entry = historyEntry(10, url: URL(string: "https://history.example")!)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.history.snapshots[profile] = .init(profileID: profile, entries: [entry], revision: 1)
		state.main.browsingHistory = state.history.snapshots
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		let resultID = try #require(
			store.main.commandBar.entries.first { if case .openHistory = $0.intent { true } else { false } }?.presentation.id
		)
		switch reason {
		case "cleared":
			await store.send(.history(.received(
				.init(snapshot: .init(profileID: profile, entries: [], revision: 2)),
				epoch: 0
			))).finish()

		case "space":
			await store.send(.main(.sidebar(.ui(.spaceSelected(organization.spaces[1].id))))).finish()

		default:
			await store.send(.settings(.delegate(.changeOrganization(.updateSpace(
				organization.spaces[0].id,
				profileID: other,
				name: organization.spaces[0].name,
				icon: .stack
			))))).finish()
		}
		let previous = store.workspace
		await store.send(.main(.commandBar(.ui(.selected(resultID))))).finish()
		expectNoDifference(store.workspace, previous)
	}

	@Test(arguments: [false, true])
	internal func clearingHistoryNeedsConfirmationAndRejectsOlderLoadResponses(_ visitDuringClear: Bool) async throws {
		var state = historyFixture()
		let profile = state.workspace.profiles[0].id
		let entry = historyEntry(10, url: URL(string: "https://history.example")!)
		let snapshot = BrowsingHistorySnapshot(profileID: profile, entries: [entry], revision: 1)
		state.history.snapshots[profile] = snapshot
		state.main.browsingHistory = state.history.snapshots
		let (gate, continuation) = AsyncStream<Void>.makeStream()
		let clears = LockIsolated<[Profile.ID]>([])
		let next = historyEntry(11, url: URL(string: "https://after-clear.example")!)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init(
				record: { id, visit in
					let url = visit.url
					#expect(url == next.url)
					return .init(snapshot: .init(profileID: id, entries: [next], revision: 3))
				},
				clear: { id in
					clears.withValue { $0.append(id) }
					for await _ in gate { break }
					return .init(snapshot: .init(profileID: id, revision: 2))
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.settings(.ui(.requestClearHistory(profile))))
		expectNoDifference(clears.value, [])
		await store.send(.settings(.ui(.cancelClearHistory)))
		expectNoDifference(store.state.history.snapshots[profile], snapshot)
		await store.send(.settings(.ui(.requestClearHistory(profile))))
		await store.send(.settings(.ui(.confirmClearHistory)))
		await store.receive(\.settings.delegate.clearHistory)
		#expect(store.state.main.browsingHistory[profile]?.entries.isEmpty == true)
		await store.send(.history(.received(.init(snapshot: snapshot), epoch: 0)))
		#expect(store.state.main.browsingHistory[profile]?.entries.isEmpty == true)
		if visitDuringClear {
			let navigation = BrowserNavigation(url: next.url, title: next.title)
			await store.send(.main(.viewer(.item(.delegate(.navigation(state.workspace.tabs[0].id, navigation))))))
		}
		continuation.yield(())
		continuation.finish()
		await store.receive(\.history.received)
		if visitDuringClear { await store.receive(\.history.received) }
		await store.finish()
		expectNoDifference(store.state.history.snapshots[profile]?.entries, visitDuringClear ? [next] : [])
		expectNoDifference(clears.value, [profile])
		#expect(store.state.history.pendingClear.isEmpty)
		#expect(store.state.settings.historyStatus[profile]?.isWorking == false)
	}

	@Test
	internal func rangedClearDropsOnlyRecentEntriesAtOnceAndInTheStore() async throws {
		var state = historyFixture()
		let profile = state.workspace.profiles[0].id
		let old = historyEntry(10, url: URL(string: "https://old.example")!)
		let recent = historyEntry(90, url: URL(string: "https://recent.example")!)
		state.history.snapshots[profile] = .init(profileID: profile, entries: [recent, old], revision: 1)
		let since = Date(timeIntervalSince1970: 50)
		let cleared = LockIsolated<[Date]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init(clearSince: { id, date in
				cleared.withValue { $0.append(date) }
				return .init(snapshot: .init(profileID: id, entries: [old], revision: 2))
			})
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.settings(.delegate(.clearHistorySince(profile, since))))

		// The visible list updates before the store answers.
		expectNoDifference(store.state.history.snapshots[profile]?.entries, [old])
		expectNoDifference(store.state.main.browsingHistory[profile]?.entries, [old])
		await store.receive(\.history.received)
		await store.finish()
		expectNoDifference(cleared.value, [since])
		#expect(store.state.history.snapshots[profile]?.revision == 2)
	}

	@Test
	internal func historyAnotherMacSyncedIsTakenInForKnownProfilesAndShown() async throws {
		var state = historyFixture()
		let profile = state.workspace.profiles[0].id
		let mine = historyEntry(10, url: URL(string: "https://mine.example")!)
		let theirs = historyEntry(20, url: URL(string: "https://theirs.example")!)
		state.history.snapshots[profile] = .init(profileID: profile, entries: [mine], revision: 1)
		let asked = LockIsolated<[Set<Profile.ID>]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserHistory = .init(applySynced: { profiles in
				asked.withValue { $0.append(profiles) }
				return [.init(snapshot: .init(profileID: profile, entries: [theirs, mine], revision: 2))]
			})
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.event(.historySyncChanged))
		await store.receive(\.history.syncApplied)
		await store.receive(\.history.received)
		await store.finish()
		expectNoDifference(asked.value, [Set(state.workspace.profiles.map(\.id))])
		expectNoDifference(store.state.main.browsingHistory[profile]?.entries, [theirs, mine])
		#expect(store.state.settings.historyStatus[profile]?.count == 2)
	}

	@Test
	internal func aRangedClearSentWhileSyncedHistoryIsTakenInDropsTheSyncAnswer() async throws {
		var state = historyFixture()
		let profile = state.workspace.profiles[0].id
		let old = historyEntry(10, url: URL(string: "https://old.example")!)
		let recent = historyEntry(90, url: URL(string: "https://recent.example")!)
		state.history.snapshots[profile] = .init(profileID: profile, entries: [recent, old], revision: 1)
		let (gate, open) = AsyncStream<Void>.makeStream()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init(
				clearSince: { id, _ in .init(snapshot: .init(profileID: id, entries: [old], revision: 2)) },
				applySynced: { _ in
					for await _ in gate { break }

					// Read before the clear, though its revision is newer.
					return [.init(snapshot: .init(profileID: profile, entries: [recent, old], revision: 3))]
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.event(.historySyncChanged))
		await store.send(.settings(.delegate(.clearHistorySince(profile, Date(timeIntervalSince1970: 50)))))
		await store.receive(\.history.received)
		open.yield()
		open.finish()
		await store.receive(\.history.syncApplied)
		await store.finish()
		expectNoDifference(store.state.history.snapshots[profile]?.entries, [old])
		expectNoDifference(store.state.main.browsingHistory[profile]?.entries, [old])
	}

	@Test
	internal func historyAlreadySyncedIsTakenInForAProfileThatArrivesLater() async throws {
		var state = historyFixture()
		let profiles: Set<Profile.ID> = Set(state.workspace.profiles.map(\.id))
		state.history.knownProfiles = []
		let asked = LockIsolated<[Set<Profile.ID>]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserHistory = .init(applySynced: { profiles in
				asked.withValue { $0.append(profiles) }
				return []
			})
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.event(.workspaceDocumentChanged))
		await store.send(.event(.workspaceDocumentChanged))
		await store.finish()

		// Once, when the profile first appears.
		expectNoDifference(asked.value, [profiles])
	}

	@Test
	internal func historyWriteFailureKeepsCandidatesAndRetryClearsVisibleError() async throws {
		var state = historyFixture()
		let profile = state.workspace.profiles[0].id
		let entry = historyEntry(10, url: URL(string: "https://history.example")!)
		state.history.snapshots[profile] = .init(profileID: profile, entries: [entry], revision: 1)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init(retry: { id in .init(snapshot: .init(profileID: id, entries: [entry], revision: 2)) })
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.history(.received(
			.init(snapshot: state.history.snapshots[profile]!, failure: .writeFailed),
			epoch: 0
		)))
		#expect(store.state.settings.historyStatus[profile]?.error != nil)
		expectNoDifference(store.state.main.browsingHistory[profile]?.entries, [entry])
		await store.send(.settings(.ui(.retryHistory(profile))))
		await store.receive(\.history.received)
		await store.finish()
		#expect(store.state.settings.historyStatus[profile]?.error == nil)
		expectNoDifference(store.state.history.snapshots[profile]?.entries, [entry])
	}

	private func historyFixture() -> AppFeature.State {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.history.snapshots[organization.profiles[0].id] = .init(profileID: organization.profiles[0].id)
		state.history.knownProfiles = Set(organization.profiles.map(\.id))
		return state
	}

	private func historyEntry(
		_ id: Int,
		url: URL
	) -> BrowsingHistoryEntry {
		.init(
			id: UUID(id),
			url: url,
			title: "History \(id)",
			lastVisited: Date(timeIntervalSince1970: Double(id))
		)
	}
}

extension IntegrationFeatureTests {
	/// DEV-1015: a title update isn't another visit, and an address typed in the command bar
	/// makes its page's visit a typed one, in the tab it opens in, not another tab on the site.
	@Test
	internal func historyCountsNewViewsAndMarksTypedAddresses() async throws {
		let state = historyFixture()
		let tab = state.workspace.tabs[0]
		let other = state.workspace.tabs[1]
		let recorded = LockIsolated<[BrowsingVisit]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init(
				record: { id, visit in
					recorded.withValue { $0.append(visit) }
					return .init(snapshot: .init(profileID: id, revision: recorded.value.count))
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		func navigate(
			_ tabID: BrowserCore.Tab.ID,
			_ address: String,
			_ title: String
		) async {
			let navigation = BrowserNavigation(url: URL(string: address)!, title: title)
			await store.send(.main(.viewer(.item(.delegate(.navigation(tabID, navigation))))))
			await store.finish()
		}

		// The other tab already shows a page.
		await navigate(other.id, "https://elsewhere.example/", "Elsewhere")

		// The window opened a typed address in the first tab.
		await store.send(.main(.delegate(.typedAddressOpened(URL(string: "https://news.ycombinator.com")!, tab.id))))
		await navigate(other.id, "https://news.ycombinator.com/item?id=1", "A story")
		await navigate(tab.id, "https://news.ycombinator.com/", "Hacker News")
		await navigate(tab.id, "https://news.ycombinator.com/", "Hacker News · new")

		expectNoDifference(recorded.value.map(\.isNew), [true, true, true, false])
		expectNoDifference(recorded.value.map(\.isTyped), [false, false, true, false])
		#expect(store.state.history.typedAddresses.isEmpty)
	}

	/// DEV-1015: a background tab's visit, such as an agent's, belongs to the tab's own space,
	/// not the one its window shows.
	@Test
	internal func aVisitBelongsToItsTabsSpace() async throws {
		var state = historyFixture()
		let elsewhere = try #require(state.workspace.spaces.first { $0.id != state.main.sidebar.spaceID })
		let background = BrowserCore.Tab(
			id: .init(rawValue: UUID(60)),
			profileID: elsewhere.profileID,
			restoration: .init(title: "Agent", url: URL(string: "https://agent.example/")!)
		)
		state.workspace.tabs.append(background)
		state.workspace.spaces[id: elsewhere.id]?.unpinnedTabs.append(background.id)
		let recorded = LockIsolated<[BrowsingVisit]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init(
				record: { id, visit in
					recorded.withValue { $0.append(visit) }
					return .init(snapshot: .init(profileID: id, revision: recorded.value.count))
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let navigation = BrowserNavigation(url: URL(string: "https://agent.example/")!, title: "Agent")

		// As AutomationCommands forwards a background tab's navigation.
		await store.send(.main(.viewer(.item(.delegate(.navigation(background.id, navigation))))))
		await store.finish()

		expectNoDifference(recorded.value.map(\.spaceID), [elsewhere.id])
	}
}

extension IntegrationFeatureTests {
	/// DEV-1015: a typed address waits for the tab its window opened it in: a new tab for ⌘T,
	/// the page's own tab for ⌘L, and Little Arx's tab.
	@Test(arguments: ["newTab", "currentTab", "little"])
	internal func aTypedAddressWaitsForTheTabItOpensIn(host: String) async throws {
		let organization = fixture()
		let source = organization.tabs[0]
		let profile = organization.spaces[0].profileID
		let temporary = BrowserCore.Tab(
			id: .init(rawValue: UUID(30)),
			profileID: profile,
			restoration: source.restoration
		)
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = source
		var initial = AppFeature.State(main: main)
		var little = LittleArxFeature.State(id: UUID(31), spaceID: organization.spaces[0].id, tab: temporary)
		little.viewer.tab = temporary
		initial.littleWindows.append(little)
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init()
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.command = { _, _ in }
		}

		if host == "little" {
			await store.send(.littleWindows(.element(id: little.id, action: .ui(.openCommand(.currentTab))))).finish()
			await store.send(.littleWindows(.element(id: little.id, action: .commandBar(.ui(.queryChanged("example.org")))))).finish()
			await store.send(.littleWindows(.element(id: little.id, action: .commandBar(.ui(.selected("destination")))))).finish()
		} else {
			await store.send(.main(.ui(.openCommand(host == "newTab" ? .newTab : .currentTab)))).finish()
			await store.send(.main(.commandBar(.ui(.queryChanged("example.org"))))).finish()
			await store.send(.main(.commandBar(.ui(.selected("destination"))))).finish()
		}

		let expected: BrowserCore.Tab.ID = switch host {
		case "newTab": .init(rawValue: UUID(100))
		case "little": temporary.id
		default: source.id
		}
		let waiting = store.history.typedAddresses[profile] ?? []
		expectNoDifference(waiting.map(\.tabID), [expected])
		expectNoDifference(waiting.map(\.site), ["example.org"])
	}
}
