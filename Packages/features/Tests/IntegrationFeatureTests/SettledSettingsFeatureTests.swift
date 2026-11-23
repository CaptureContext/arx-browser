import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-646: automatic archiving, restoring windows and the app-wide feedback switches.
@Suite(.dependencies)
@MainActor
internal struct SettledSettingsFeatureTests {
	private static let now = Date(timeIntervalSince1970: 10 * 86_400)

	private static func tab(
		_ id: Int,
		profile: Profile.ID,
		pinned: Bool = false
	) -> BrowserCore.Tab {
		.init(
			id: .init(rawValue: UUID(id)),
			profileID: profile,
			savedDestination: pinned ? .init(title: "Pin", url: URL(string: "https://capturecontext.dev/pin")!) : nil,
			restoration: .init(title: "Page \(id)", url: URL(string: "https://capturecontext.dev/\(id)")!)
		)
	}

	/// One profile with a selected tab (10), two old tabs (11, 12), a recent one (13),
	/// one never seen (14), a pinned tab (15) and a Favorite (16).
	private static func organization(interval: TabArchiveInterval?) -> BrowserOrganization {
		let profile = Profile.ID(rawValue: UUID(1))
		let tabs = (10...16).map { tab($0, profile: profile, pinned: $0 >= 15) }
		return .init(
			profiles: [.init(id: profile, name: "Work", favorites: [tabs[6].id], tabArchiveInterval: interval)],
			spaces: [.init(
				id: .init(rawValue: UUID(2)),
				profileID: profile,
				name: "Work",
				savedItems: [.tab(tabs[5].id)],
				unpinnedTabs: tabs[0...4].map(\.id),
				selectedTabID: tabs[0].id
			)],
			tabs: tabs
		)
	}

	private static let viewed: [BrowserCore.Tab.ID: Date] = [
		.init(rawValue: UUID(10)): now.addingTimeInterval(-3 * 86_400),
		.init(rawValue: UUID(11)): now.addingTimeInterval(-2 * 86_400),
		.init(rawValue: UUID(12)): now.addingTimeInterval(-86_400),
		.init(rawValue: UUID(13)): now.addingTimeInterval(-3_600),
		.init(rawValue: UUID(15)): now.addingTimeInterval(-9 * 86_400),
		.init(rawValue: UUID(16)): now.addingTimeInterval(-9 * 86_400),
	]

	private func store(
		interval: TabArchiveInterval?,
		viewed: [BrowserCore.Tab.ID: Date] = Self.viewed,
		keptLoadedSites: [String]? = nil,
		prepare: (inout AppFeature.State) -> Void = { _ in }
	) -> (TestStoreOf<AppFeature>, LockIsolated<[BrowserCore.Tab.ID]>) {
		var organization = Self.organization(interval: interval)
		organization.profiles[0].keptLoadedSites = keptLoadedSites
		let document = WorkspaceDocument.unsaved(.init(tabsLastViewed: viewed))
		var state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		state.archivesInactiveTabs = true
		prepare(&state)
		let closed = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.date.now = Self.now
			$0.uuid = .incrementing
			$0.browserEngine.permitsClosing = { $0 != .init(rawValue: UUID(12)) }
			$0.browserEngine.close = { id in closed.withValue { $0.append(id) } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return (store, closed)
	}

	@Test
	internal func unviewedUnpinnedTabsPastTheIntervalAreArchived() async {
		let (store, closed) = store(interval: .day)

		await store.send(.archiveInactiveTabs)

		// 10 is selected, 13 is recent, 14 starts its clock now, 15 and 16 are pinned.
		await store.receive(\.main.archiveInactiveTabs, [.init(rawValue: UUID(11)), .init(rawValue: UUID(12))])
		await store.finish()
		await store.skipReceivedActions(strict: false)

		// 12's page asked to stay open, so only 11 moved to the Archive.
		expectNoDifference(closed.value, [.init(rawValue: UUID(11))])
		expectNoDifference(store.state.main.sidebar.organization.archive.map(\.tab.id), [.init(rawValue: UUID(11))])
		expectNoDifference(
			store.state.main.sidebar.organization.spaces[0].unpinnedTabs,
			[10, 12, 13, 14].map { .init(rawValue: UUID($0)) }
		)
		#expect(store.state.main.sidebar.organization.tabs[id: .init(rawValue: UUID(15))] != nil)
		#expect(store.state.main.sidebar.organization.tabs[id: .init(rawValue: UUID(16))] != nil)

		// 12's page kept it open: its clock starts over, so it isn't asked again for a day.
		expectNoDifference(store.state.tabsLastViewed[.init(rawValue: UUID(12))], Self.now)

		// Pinned tabs and Favorites aren't tracked, and new tabs start now. The selected tab was
		// stamped as it came on screen.
		let viewed = store.state.tabsLastViewed
		expectNoDifference(viewed[.init(rawValue: UUID(10))], Self.now)
		expectNoDifference(viewed[.init(rawValue: UUID(14))], Self.now)
		expectNoDifference(viewed[.init(rawValue: UUID(13))], Self.viewed[.init(rawValue: UUID(13))])
		#expect(viewed[.init(rawValue: UUID(15))] == nil)
		#expect(viewed[.init(rawValue: UUID(16))] == nil)
	}

	@Test
	internal func aTabViewedWhileItsPageWasAskedStaysOpen() async {
		var viewed = Self.viewed

		// 11 was viewed after the sweep picked it, while its page was being asked.
		viewed[.init(rawValue: UUID(11))] = Self.now
		let (store, closed) = store(interval: .day, viewed: viewed)
		let entries = Self.organization(interval: .day).archiveEntries(
			for: [.init(rawValue: UUID(11))],
			closedAt: Self.now,
			groupID: UUID(500),
			uuid: { UUID(501) }
		)

		await store.send(.main(.event(.inactiveArchivePermitted(entries, refused: []))))
		await store.receive(\.main.event.archiveFailed)
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(closed.value, [])
		#expect(store.state.main.sidebar.organization.archive.isEmpty)
	}

	@Test
	internal func aClosedMainWindowsPanesArentOnScreen() {
		let organization = Self.organization(interval: .day)
		var state = withDependencies {
			$0.workspaceDocument = .unsaved()
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		state.main.viewer.item.tab = organization.tabs[id: .init(rawValue: UUID(11))]
		state.windowIsOpen = true
		#expect(state.tabsOnScreen.contains(.init(rawValue: UUID(11))))

		state.windowIsOpen = false
		#expect(!state.tabsOnScreen.contains(.init(rawValue: UUID(11))))
	}

	@Test
	internal func aLongerIntervalKeepsThem() async {
		let (store, closed) = store(interval: .week)

		await store.send(.archiveInactiveTabs)
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(closed.value, [])
		#expect(store.state.main.sidebar.organization.archive.isEmpty)
	}

	/// DEV-1326: a profile that never chose archives after six hours: 11 (two days), 12 (a day,
	/// whose page asks to stay) are due, 13 (an hour) isn't.
	@Test
	internal func noChoiceArchivesAfterSixHours() async {
		let (store, closed) = store(interval: nil)

		await store.send(.archiveInactiveTabs)
		await store.receive(\.main.archiveInactiveTabs, [.init(rawValue: UUID(11)), .init(rawValue: UUID(12))])
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(closed.value, [.init(rawValue: UUID(11))])
		expectNoDifference(store.state.main.sidebar.organization.archive.map(\.tab.id), [.init(rawValue: UUID(11))])
	}

	/// DEV-1326: a hidden tab in use stays, however long since it was viewed: 11 plays media, 12
	/// floats in Picture in Picture. Their clocks start over, so they wait a whole interval once
	/// they stop.
	@Test
	internal func hiddenTabsPlayingMediaOrInPictureInPictureStay() async {
		let profile = Profile.ID(rawValue: UUID(1))
		let (store, closed) = store(interval: nil) { state in
			state.tabsMakingSound = .init(playing: [.init(rawValue: UUID(11))])
			state.media.snapshot = .init(revision: 1, sources: [.init(
				id: .init(tabID: .init(rawValue: UUID(12)), profileID: profile, generation: 1),
				revision: 1,
				title: "Video",
				site: nil,
				hasVideo: true,
				playback: .paused,
				isInPictureInPicture: true
			)])
		}

		await store.send(.archiveInactiveTabs)
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(closed.value, [])
		#expect(store.state.main.sidebar.organization.archive.isEmpty)
		expectNoDifference(store.state.tabsLastViewed[.init(rawValue: UUID(11))], Self.now)
		expectNoDifference(store.state.tabsLastViewed[.init(rawValue: UUID(12))], Self.now)
	}

	/// DEV-1326: media that plays and stops between two sweeps starts the tab's clock over as it
	/// starts and as it stops, so the next sweep keeps the tab.
	@Test
	internal func mediaPlayedBetweenSweepsStartsTheClockOver() async {
		let (store, closed) = store(interval: nil) { state in
			state.media.isObserving = true
		}
		let observation = store.state.media.observationID
		let later = Self.now.addingTimeInterval(60)

		await store.send(.media(.event(.changed(.init(revision: 1, sources: [Self.playing(11)]), observationID: observation))))
		#expect(store.state.tabsMakingSound.playing.contains(.init(rawValue: UUID(11))))
		store.dependencies.date.now = later
		await store.send(.media(.event(.changed(.init(revision: 2, sources: []), observationID: observation))))
		expectNoDifference(store.state.tabsLastViewed[.init(rawValue: UUID(11))], later)

		await store.send(.archiveInactiveTabs)
		await store.receive(\.main.archiveInactiveTabs, [.init(rawValue: UUID(12))])
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(closed.value, [])
	}

	/// DEV-1326: a tab in a call stays too.
	@Test
	internal func hiddenTabsInACallStay() async {
		let (store, closed) = store(interval: .day) { state in
			state.tabsMakingSound = .init(inCall: [.init(rawValue: UUID(11))])
		}

		await store.send(.archiveInactiveTabs)
		await store.receive(\.main.archiveInactiveTabs, [.init(rawValue: UUID(12))])
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(closed.value, [])
	}

	/// DEV-1326: tabs on a site the profile keeps loaded (DEV-932) aren't archived either.
	@Test
	internal func tabsOnKeptLoadedSitesStay() async {
		let (store, closed) = store(interval: nil, keptLoadedSites: ["capturecontext.dev"])

		await store.send(.archiveInactiveTabs)
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(closed.value, [])
		#expect(store.state.main.sidebar.organization.archive.isEmpty)
	}

	private static func playing(_ tab: Int) -> BrowserMediaSource {
		.init(
			id: .init(tabID: .init(rawValue: UUID(tab)), profileID: .init(rawValue: UUID(1)), generation: 1),
			revision: 1,
			title: "Song",
			site: nil,
			playback: .playing
		)
	}

	@Test
	internal func neverArchivesNothingAndForgetsWhatItTracked() async {
		let (store, closed) = store(interval: .never)

		await store.send(.archiveInactiveTabs)
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(closed.value, [])
		#expect(store.state.main.sidebar.organization.archive.isEmpty)
		#expect(store.state.tabsLastViewed.isEmpty)
	}

	@Test
	internal func turningItOnStartsEveryClockNow() async {
		let (store, closed) = store(interval: .twelveHours, viewed: [:])

		await store.send(.archiveInactiveTabs)
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(closed.value, [])
		expectNoDifference(
			Set(store.state.tabsLastViewed.keys),
			Set((10...14).map { .init(rawValue: UUID($0)) })
		)
		#expect(store.state.tabsLastViewed.values.allSatisfy { $0 == Self.now })
	}

	@Test
	internal func turningRestorationOffOpensOneWindow() {
		let organization = IntegrationFeatureTests().fixture()
		let space = organization.spaces[0].id
		let main = MainFeature.State(organization: organization, spaceID: space)
		let presentations: [BrowserWindowPresentation] = [
			.init(id: main.id, activeSpaceID: space, spaces: [], sidebarWidth: 320),
			.init(id: UUID(901), activeSpaceID: space, spaces: [], sidebarWidth: 400),
		]

		let restored = withDependencies {
			$0.workspaceDocument = .unsaved(.init(windowPresentations: presentations, lastSidebarWidth: 350))
		} operation: {
			AppFeature.State(main: main)
		}
		expectNoDifference(restored.windows.map(\.id), [UUID(901)])
		expectNoDifference(restored.main.sidebarWidth, 320)

		let fresh = withDependencies {
			$0.workspaceDocument = .unsaved(.init(
				windowPresentations: presentations,
				lastSidebarWidth: 350,
				restoresWindowsAtStartup: false
			))
		} operation: {
			AppFeature.State(main: main)
		}
		#expect(fresh.windows.isEmpty)
		// New windows still start at the width last chosen.
		expectNoDifference(fresh.main.sidebarWidth, 350)
	}

	@Test
	internal func settingsSwitchesChangeTheAppWidePreferences() async {
		let organization = IntegrationFeatureTests().fixture()
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.ui(.restoresWindowsAtStartup(false))))
		await store.send(.settings(.ui(.hapticsEnabled(false))))
		await store.send(.settings(.ui(.soundsEnabled(true))))
		await store.send(.settings(.ui(.hoverPreviewsEnabled(false))))
		await store.send(.settings(.ui(.hoverPreviewSources(.init(folders: false, mail: true, recentPages: false)))))

		#expect(!store.state.settings.general.restoresWindowsAtStartup)
		#expect(!store.state.settings.general.hapticsEnabled)
		#expect(store.state.settings.general.soundsEnabled)
		#expect(!document.preferences.restoresWindowsAtStartup)
		#expect(!document.preferences.hapticsEnabled)
		#expect(document.preferences.soundsEnabled)
		#expect(!store.state.settings.general.hoverPreviewsEnabled)
		#expect(!document.preferences.hoverPreviewsEnabled)
		expectNoDifference(store.state.settings.general.hoverPreviewSources, .init(folders: false, mail: true, recentPages: false))
		expectNoDifference(document.preferences.hoverPreviewSources, .init(folders: false, mail: true, recentPages: false))
	}
}
