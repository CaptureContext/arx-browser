import AppFeature
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func privateCloseRechecksTabsCreatedDuringSuspendedApproval() async throws {
		let organization = privateCloseFixture()
		let windowID = UUID(20)
		let newTabID = BrowserCore.Tab.ID(rawValue: UUID(100))
		let initial = privateCloseState(organization, windowID: windowID)
		let started = AsyncStream.makeStream(of: Void.self)
		let resume = AsyncStream.makeStream(of: Void.self)
		var approvals: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		var released: [Profile.ID] = []
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserEngine.open = { _ in }
			$0.browserEngine.permitsClosing = { id in
				approvals.append(id)
				if approvals.count == 1 {
					started.continuation.yield()
					for await _ in resume.stream { break }
				}
				return id != newTabID
			}
			$0.browserEngine.close = { closed.append($0) }
			$0.browserEngine.releasePrivateProfile = { released.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.requestClosePrivateWindow(windowID)))
		for await _ in started.stream { break }

		// A late organization update still must not widen the set authorized by the pending approval.
		var updated = organization
		updated.tabs.append(.init(
			id: newTabID,
			profileID: organization.profiles[0].id,
			restoration: .init(
				title: "New private page",
				url: URL(string: "https://private.example/new")!
			)
		))
		updated.spaces[0].unpinnedTabs.append(newTabID)
		await store.send(.windows(.element(id: windowID, action: .reconcile(updated))))
		#expect(store.state.windows[id: windowID]?.sidebar.organization.tabs.ids.contains(newTabID) == true)
		resume.continuation.yield()
		await store.receive(\.event.privateWindowCloseDecision)
		await store.receive(\.ui.requestClosePrivateWindow)
		await store.receive(\.event.privateWindowCloseDecision)
		await store.finish()
		#expect(store.state.windows[id: windowID] != nil)
		#expect(approvals.contains(newTabID))
		expectNoDifference(closed, [])
		expectNoDifference(released, [])
		#expect(store.state.privateWindowCloseRequests.isEmpty)
		#expect(store.state.windows[id: windowID]?.isClosing == false)
	}

	@Test
	internal func latePrivateCloseDecisionsCannotFinishOrCancelANewerAttempt() async throws {
		let organization = privateCloseFixture()
		let windowID = UUID(20)
		let initial = privateCloseState(organization, windowID: windowID)
		let started = AsyncStream.makeStream(of: Void.self)
		let resume = AsyncStream.makeStream(of: Void.self)
		var suspend = false
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.permitsClosing = { _ in
				if suspend {
					started.continuation.yield()
					for await _ in resume.stream { break }
				}
				return false
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.requestClosePrivateWindow(windowID)))
		let old = try #require(store.state.privateWindowCloseRequests[windowID])
		await store.receive(\.event.privateWindowCloseDecision)
		await store.send(.event(.privateWindowCloseDecision(windowID, old, true)))
		#expect(store.state.windows[id: windowID]?.isClosing == false)
		#expect(store.state.privateWindowCloseRequests.isEmpty)
		suspend = true
		await store.send(.ui(.requestClosePrivateWindow(windowID)))
		let current = try #require(store.state.privateWindowCloseRequests[windowID])
		#expect(current.token != old.token)
		for await _ in started.stream { break }
		await store.send(.event(.privateWindowCloseDecision(windowID, old, true)))
		await store.send(.event(.privateWindowCloseDecision(windowID, old, false)))
		#expect(store.state.windows[id: windowID]?.isClosing == true)
		expectNoDifference(store.state.privateWindowCloseRequests[windowID], current)
		resume.continuation.yield()
		await store.receive(\.event.privateWindowCloseDecision)
		await store.finish()
		expectNoDifference(closed, [])
		#expect(store.state.windows[id: windowID] != nil)
		#expect(store.state.privateWindowCloseRequests.isEmpty)
	}

	@Test
	internal func privateHostCloseAfterPeekReleaseUsesNativeApprovalBeforeReleasingProfile() async throws {
		let organization = privateCloseFixture()
		let windowID = UUID(20)
		let peekID = UUID(21)
		var initial = privateCloseState(organization, windowID: windowID)
		let window = try #require(initial.windows[id: windowID])

		// Exercises the generic close route emitted by a completed Peek handoff, defensively for private hosts.
		initial.peeks.append(.init(
			id: peekID,
			source: .init(
				windowID: windowID,
				paneID: window.viewer.activePaneID,
				tabID: nil,
				spaceID: organization.spaces[0].id,
				profileID: organization.profiles[0].id,
				identity: "Private"
			),
			tab: organization.tabs[0],
			isTemporary: false
		))
		initial.peeks[id: peekID]?.phase = .releasing
		initial.peekTransitions[peekID] = .dismiss
		initial.closingPeekHosts.insert(windowID)
		var approved = false
		var attempts: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		var released: [Profile.ID] = []
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.permitsClosing = {
				attempts.append($0)
				return approved
			}
			$0.browserEngine.close = { closed.append($0) }
			$0.browserEngine.releasePrivateProfile = { released.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.event(.peekReleased(peekID)))
		await store.receive(\.ui.closeAdditionalWindow)
		await store.receive(\.ui.requestClosePrivateWindow)
		await store.receive(\.event.privateWindowCloseDecision)
		await store.finish()
		#expect(store.state.windows[id: windowID] != nil)
		expectNoDifference(attempts, [organization.tabs[0].id])
		expectNoDifference(closed, [])
		expectNoDifference(released, [])
		approved = true
		await store.send(.ui(.closeAdditionalWindow(windowID)))
		await store.receive(\.ui.requestClosePrivateWindow)
		await store.receive(\.event.privateWindowCloseDecision)
		await store.finish()
		#expect(store.state.windows[id: windowID] == nil)
		expectNoDifference(closed, organization.tabs.map(\.id))
		expectNoDifference(released, organization.profiles.map(\.id))
		#expect(store.state.privateWindowCloseRequests.isEmpty)
	}

	@Test
	internal func privatePopupContextSurvivesOpenerCloseUntilTheLastEmptyHostCloses() async throws {
		let organization = privateCloseFixture()
		let openerID = UUID(20)
		let childID = UUID(21)
		var state = privateCloseState(organization, windowID: openerID)
		let empty = BrowserOrganization(
			profiles: Array(organization.profiles),
			spaces: [.init(
				id: .init(rawValue: UUID(40)),
				profileID: organization.profiles[0].id,
				name: "Private child"
			)]
		)
		state.windows.append(.init(
			organization: empty,
			spaceID: empty.spaces[0].id,
			isPrivate: true,
			id: childID
		))
		var released: [Profile.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { closed.append($0) }
			$0.browserEngine.releasePrivateProfile = { released.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.requestClosePrivateWindow(openerID)))
		await store.receive(\.event.privateWindowCloseDecision)
		await store.finish()
		#expect(store.state.windows[id: openerID] == nil)
		#expect(store.state.windows[id: childID] != nil)
		expectNoDifference(closed, organization.tabs.map(\.id))
		#expect(released.isEmpty)
		await store.send(.ui(.requestClosePrivateWindow(childID)))
		await store.receive(\.event.privateWindowCloseDecision)
		await store.finish()
		expectNoDifference(released, organization.profiles.map(\.id))
		#expect(store.state.windows.isEmpty)
	}

	private func privateCloseState(
		_ organization: BrowserOrganization,
		windowID: UUID
	) -> AppFeature.State {
		let durable = fixture()
		var state = AppFeature.State(main: .init(organization: durable, spaceID: durable.spaces[0].id))
		state.windows.append(.init(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: true,
			id: windowID
		))
		return state
	}

	private func privateCloseFixture() -> BrowserOrganization {
		let profile = Profile.ID(rawValue: UUID(30))
		let space = Space.ID(rawValue: UUID(31))
		let tabs: [BrowserCore.Tab] = [32, 33].map { id in
			.init(
				id: .init(rawValue: UUID(id)),
				profileID: profile,
				restoration: .init(
					title: "Private page",
					url: URL(string: "https://private.example/\(id)")!
				)
			)
		}
		return .init(
			profiles: [.init(id: profile, name: "Private")],
			spaces: [
				.init(
					id: space,
					profileID: profile,
					name: "Private",
					unpinnedTabs: tabs.map(\.id),
					selectedTabID: tabs[0].id
				),
			],
			tabs: tabs
		)
	}
}
