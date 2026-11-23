import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import LittleArxFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-931: Little Arx opens on the macOS desktop Space where the link was clicked. Arx opens a
/// new one, and never brings one on another Space forward on its own.
extension IntegrationFeatureTests {
	@Test
	internal func aLinkFromAnotherAppOpensANewLittleArxBesideOneOnAnotherDesktopSpace() async throws {
		var state = desktopSpaceFixture()
		let existing = try #require(state.littleWindows.first)
		state.littleWindowsOnOtherDesktopSpaces = [existing.id]
		let url = URL(string: "https://slack.example/link")!
		let ids = LockIsolated(20)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .init {
				ids.withValue {
					defer { $0 += 1 }
					return UUID($0)
				}
			}
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.routeURLs([url])))
		await store.send(.event(.routingReady))
		await store.receive(\.event.routedSessionReady)
		await store.finish()

		// A second window for the link, with the keyboard; the first is neither reused nor moved.
		expectNoDifference(store.state.littleWindows.count, 2)
		let opened = try #require(store.state.littleWindows.last)
		expectNoDifference(opened.tab.restoration.url, url)
		expectNoDifference(store.state.focusedWindowID, opened.id)
		expectNoDifference(store.state.littleWindows[id: existing.id], existing)
		expectNoDifference(store.state.littleWindowsOnOtherDesktopSpaces, [existing.id])
	}

	@Test
	internal func aPopupClosingOnThisDesktopSpaceHandsTheKeyboardToItsOpener() async throws {
		let state = desktopSpaceFixture(popup: true)
		let focused = try await closePopup(in: state)
		expectNoDifference(focused, Self.desktopSpaceOpenerID)
	}

	@Test
	internal func aPopupClosingLeavesAnOpenerOnAnotherDesktopSpaceWhereItIs() async throws {
		var state = desktopSpaceFixture(popup: true)
		state.littleWindowsOnOtherDesktopSpaces = [Self.desktopSpaceOpenerID]
		let focused = try await closePopup(in: state)

		// Nothing is brought forward, so the active Space stays as it is.
		#expect(focused == nil)
	}

	@Test
	internal func desktopSpaceReportsKeepOnlyOpenLittleArxWindows() async throws {
		var state = desktopSpaceFixture(popup: true)
		let unknown = UUID(99)
		_ = LittleArxWindows()._reduce(
			into: &state,
			action: .event(.desktopSpaceChanged(littleWindowsElsewhere: [Self.desktopSpaceOpenerID, unknown]))
		)
		expectNoDifference(state.littleWindowsOnOtherDesktopSpaces, [Self.desktopSpaceOpenerID])

		_ = LittleArxWindows()._reduce(into: &state, action: .event(.desktopSpaceChanged(littleWindowsElsewhere: [])))
		expectNoDifference(state.littleWindowsOnOtherDesktopSpaces, [])
	}

	private static let desktopSpaceOpenerID = UUID(40)
	private static let desktopSpacePopupID = UUID(50)

	/// One Little Arx, plus a focused popup it opened when `popup` is true.
	private func desktopSpaceFixture(popup: Bool = false) -> AppFeature.State {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let profileID = organization.profiles[0].id
		let page = BrowserCore.Tab(
			id: .init(rawValue: UUID(41)),
			profileID: profileID,
			restoration: .init(title: "Figma", url: URL(string: "https://figma.example/file")!)
		)
		var opener = LittleArxFeature.State(id: Self.desktopSpaceOpenerID, spaceID: organization.spaces[0].id, tab: page)
		opener.viewer = .init(tab: page, generation: 1)
		state.littleWindows.append(opener)
		state.focusedWindowID = opener.id
		guard popup else { return state }

		let child = BrowserCore.Tab(
			id: .init(rawValue: UUID(51)),
			profileID: profileID,
			restoration: .init(title: "Sign in", url: URL(string: "https://accounts.example/sign-in")!)
		)
		var little = LittleArxFeature.State(id: Self.desktopSpacePopupID, spaceID: organization.spaces[0].id, tab: child)
		little.openerWindowID = opener.id
		little.viewer = .init(tab: child, generation: 1)
		state.littleWindows.append(little)
		state.focusedWindowID = little.id
		return state
	}

	/// Closes the popup through Little Arx's own approval and returns the window focused after.
	private func closePopup(in state: AppFeature.State) async throws -> UUID? {
		var state = state
		let popup = try #require(state.littleWindows[id: Self.desktopSpacePopupID])
		let child = TestStore(initialState: popup) { LittleArxFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.permitsClosing = { _ in true }
		}
		child.exhaustivity = .off(showSkippedAssertions: false)
		await child.send(.ui(.close))
		await child.receive(\.event.closeDecision)
		await child.receive(\.delegate.closeApproved)
		await child.finish()
		let request = try #require(child.state.closeRequest)
		state.littleWindows[id: popup.id] = child.state

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_000)
			$0.browserEngine.close = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.littleWindows(.element(id: popup.id, action: .delegate(.closeApproved(request)))))
		await store.skipReceivedActions()
		#expect(store.state.littleWindows[id: popup.id] == nil)
		#expect(store.state.littleWindows[id: Self.desktopSpaceOpenerID] != nil)
		return store.state.focusedWindowID
	}
}
