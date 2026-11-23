import AppFeature
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func littleArxInvocationsAreIndependentAndDoNotOpenTheMainWindow() async throws {
		let organization = fixture()
		let ids = LockIsolated([UUID(20), UUID(21), UUID(22), UUID(23)])
		let store = TestStore(initialState: AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			),
			windowIsOpen: false
		)) { AppFeature() } withDependencies: {
			$0.uuid = .init { ids.withValue { $0.removeFirst() } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.openLittleArx()))
		await store.send(.ui(.openLittleArx()))
		expectNoDifference(store.state.littleWindows.count, 2)
		#expect(store.state.littleWindows[0].tab.id != store.state.littleWindows[1].tab.id)
		#expect(!store.state.windowIsOpen)
		expectNoDifference(store.state.workspace, organization)
	}

	@Test
	internal func sameProfilePromotionKeepsTheNativeSessionIdentity() async throws {
		let organization = fixture()
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(21)),
			profileID: organization.profiles[0].id,
			restoration: .init(
				title: "Temporary",
				url: URL(string: "https://capturecontext.dev/temporary")!
			)
		)
		var initial = AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))

		initial.littleWindows.append(.init(
			id: UUID(20),
			spaceID: organization.spaces[0].id,
			tab: tab
		))
		var released: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
			$0.browserSurface.release = { released.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.littleWindows(.element(
			id: UUID(20),
			action: .ui(.promote(organization.spaces[0].id, tab.profileID))
		)))
		await store.receive(\.event.littlePromotionReady)
		await store.receive(\.event.littlePromotionReleased)
		await store.finish()
		#expect(store.state.littleWindows.isEmpty)
		#expect(store.state.workspace.tabs.contains(tab))
		expectNoDifference(released, [tab.id])
		expectNoDifference(closed, [])
	}

	@Test
	internal func failedLittleArxPromotionKeepsItsTemporaryWindow() async throws {
		let organization = fixture()
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(21)),
			profileID: organization.profiles[0].id,
			restoration: .init(
				title: "Temporary",
				url: URL(string: "https://capturecontext.dev/temporary")!
			)
		)
		var initial = AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))

		initial.littleWindows.append(.init(
			id: UUID(20),
			spaceID: organization.spaces[0].id,
			tab: tab
		))
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in throw BrowserEngineClient.Failure.unavailable }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.littleWindows(.element(
			id: UUID(20),
			action: .ui(.promote(organization.spaces[0].id, tab.profileID))
		)))
		await store.receive(\.event.littlePromotionFailed)
		await store.finish()
		expectNoDifference(store.state.workspace, organization)
		expectNoDifference(store.state.littleWindows.count, 1)
	}
}

extension IntegrationFeatureTests {
	/// DEV-728: a closed Little Arx page joins its space's Tab Archive, so Recently Closed
	/// reopens it, without touching any organization tab.
	@Test
	internal func closedLittleArxPageGoesToTheTabArchive() async throws {
		let organization = fixture()
		let space = organization.spaces[0]
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(21)),
			profileID: space.profileID,
			restoration: .init(title: "Little", url: URL(string: "https://capturecontext.dev/little")!)
		)
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: space.id))
		var other = MainFeature.State(organization: organization, spaceID: space.id, id: UUID(50))
		other.archive.profileID = space.profileID
		other.archive.isPresented = true
		initial.windows.append(other)
		var little = LittleArxFeature.State(id: UUID(20), spaceID: space.id, tab: tab)
		little.viewer.navigation = .init(url: URL(string: "https://capturecontext.dev/later")!, title: "Later")
		initial.littleWindows.append(little)
		let closed = LockIsolated<[BrowserCore.Tab.ID]>([])
		let ids = LockIsolated((30...40).map { UUID($0) })
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .init { ids.withValue { $0.removeFirst() } }
			$0.date.now = Date(timeIntervalSince1970: 500)
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { id in closed.withValue { $0.append(id) } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.littleWindows(.element(id: UUID(20), action: .ui(.close))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.littleWindows.isEmpty)
		expectNoDifference(closed.value, [tab.id])
		expectNoDifference(store.state.workspace.tabs, organization.tabs)
		expectNoDifference(store.state.workspace.spaces, organization.spaces)
		let entry = try #require(store.state.workspace.archive.last)
		expectNoDifference(entry.tab.id, tab.id)
		expectNoDifference(entry.tab.restoration.url, URL(string: "https://capturecontext.dev/later")!)
		expectNoDifference(entry.tab.restoration.title, "Later")
		expectNoDifference(entry.originalSpaceID, space.id)
		expectNoDifference(entry.closedAt, Date(timeIntervalSince1970: 500))
		expectNoDifference(store.state.main.sidebar.organization.archive, store.state.workspace.archive)

		// An open Tab Archive in another window lists the page at once.
		expectNoDifference(store.state.windows[id: UUID(50)]?.archive.entries.map(\.id), [entry.id])
	}

	@Test
	internal func closedLittleArxLauncherAndBlankPagesLeaveNoArchive() async throws {
		let organization = fixture()
		let space = organization.spaces[0]
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: space.id))
		initial.littleWindows.append(.init(
			id: UUID(20),
			spaceID: space.id,
			tab: .init(
				id: .init(rawValue: UUID(21)),
				profileID: space.profileID,
				restoration: .init(title: "Blank", url: URL(string: "about:blank")!)
			)
		))
		initial.littleWindows.append(.init(
			id: UUID(22),
			spaceID: space.id,
			tab: .init(
				id: .init(rawValue: UUID(23)),
				profileID: space.profileID,
				restoration: .init(title: "Launcher", url: URL(string: "https://capturecontext.dev")!)
			),
			isCommandOnly: true
		))
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 500)
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.littleWindows(.element(id: UUID(20), action: .ui(.close))))
		await store.send(.littleWindows(.element(id: UUID(22), action: .delegate(.close))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.littleWindows.isEmpty)
		expectNoDifference(store.state.workspace, organization)
	}

	@Test(arguments: [true, false])
	internal func littleArxFocusLossOnlyClosesCommandWindows(commandOnly: Bool) async {
		let organization = fixture()
		let store = TestStore(initialState: LittleArxFeature.State(
			id: UUID(20),
			spaceID: organization.spaces[0].id,
			tab: organization.tabs[0],
			isCommandOnly: commandOnly
		)) { LittleArxFeature() }

		await store.send(.ui(.lostFocus))
		if commandOnly { await store.receive(\.delegate.close) }
		await store.finish()
	}

	@Test(arguments: [true, false])
	internal func littleArxProfileSwitchUsesNewSessionAndHonorsBeforeUnload(permitted: Bool) async throws {
		let organization = fixture()
		let previous = organization.tabs[0]
		let profileID = Profile.ID(rawValue: UUID(30))
		let spaceID = Space.ID(rawValue: UUID(31))
		let newID = BrowserCore.Tab.ID(rawValue: UUID(32))
		var operations: [String] = []
		var opened: [BrowserCore.Tab] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: LittleArxFeature.State(
			id: UUID(20),
			spaceID: organization.spaces[0].id,
			tab: previous
		)) { LittleArxFeature() } withDependencies: {
			$0.uuid = .constant(newID.rawValue)
			$0.browserEngine.permitsClosing = { _ in permitted }
			$0.browserEngine.close = {
				closed.append($0)
				operations.append("close")
			}
			$0.browserEngine.open = {
				opened.append($0)
				operations.append("open")
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.changeProfile(profileID, spaceID))
		await store.receive(\.event.profileChangeDecision)
		if permitted {
			await store.receive(\.event.profileChanged)
			await store.receive(\.viewer.show)
		}
		await store.finish()

		#expect(!store.state.isSwitchingProfile)
		if permitted {
			let tab = try #require(opened.first)
			expectNoDifference(tab.id, newID)
			expectNoDifference(tab.profileID, profileID)
			expectNoDifference(tab.restoration.url, previous.restoration.url)
			expectNoDifference(store.state.spaceID, spaceID)
			expectNoDifference(closed, [previous.id])
			expectNoDifference(operations, ["close", "open"])

		} else {
			expectNoDifference(store.state.tab, previous)
			expectNoDifference(store.state.spaceID, organization.spaces[0].id)
			#expect(opened.isEmpty && closed.isEmpty)
		}
	}
}
