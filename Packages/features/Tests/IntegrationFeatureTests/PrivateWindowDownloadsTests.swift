import AppFeature
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	/// DEV-729. A private window's downloads follow the ordinary profile it was opened from,
	/// including a private window opened from another private window.
	@Test
	func privateWindowsAreOpenedFromTheFocusedWindowsProfile() async throws {
		let durable = fixture()
		let opener = durable.spaces[0].profileID
		let state = AppFeature.State(main: .init(organization: durable, spaceID: durable.spaces[0].id))
		let prepared = LockIsolated<[Profile.ID?]>([])
		let ordinary = LockIsolated<[Profile.ID]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.prepareProfile = { profile in ordinary.withValue { $0.append(profile) } }
			$0.browserEngine.preparePrivateProfile = { _, opener in

				// The opener is prepared first, or native can't link the downloads.
				#expect(opener.map { ordinary.value.contains($0) } ?? true)
				prepared.withValue { $0.append(opener) }
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.newPrivateWindow))
		await store.receive(\.event.privateWindowReady)
		let firstWindow = try #require(store.state.windows.last)
		#expect(firstWindow.isPrivate && store.state.focusedWindowID == firstWindow.id)

		// From the private window, the new one follows the same ordinary profile.
		await store.send(.ui(.newPrivateWindow))
		await store.receive(\.event.privateWindowReady)
		await store.skipReceivedActions()

		expectNoDifference(prepared.value, [opener, opener])
		expectNoDifference(ordinary.value, [opener, opener])
		let privateProfiles = store.state.windows.filter(\.isPrivate).map(\.sidebar.space.profileID)
		#expect(privateProfiles.count == 2)
		#expect(privateProfiles.allSatisfy { store.state.privateProfileOpeners[$0] == opener })
		// DEV-956: each window shows the extensions of the opener its context belongs to.
		#expect(store.state.windows.filter(\.isPrivate).allSatisfy { $0.privateOpenerProfileID == opener })
	}

	/// DEV-956. An opener that couldn't be prepared isn't the context's parent, so the window
	/// shows none of its extensions, though new private windows still follow that profile.
	@Test
	func aPrivateWindowWhoseOpenerFailedShowsNoOpenersExtensions() async throws {
		let durable = fixture()
		let opener = durable.spaces[0].profileID
		let state = AppFeature.State(main: .init(organization: durable, spaceID: durable.spaces[0].id))
		let prepared = LockIsolated<[Profile.ID?]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.prepareProfile = { _ in throw CancellationError() }
			$0.browserEngine.preparePrivateProfile = { _, opener in prepared.withValue { $0.append(opener) } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.newPrivateWindow))
		await store.receive(\.event.privateWindowReady)
		await store.skipReceivedActions()

		expectNoDifference(prepared.value, [nil])
		let window = try #require(store.state.windows.last)
		#expect(window.isPrivate && window.privateOpenerProfileID == nil)
		#expect(store.state.privateProfileOpeners[window.sidebar.space.profileID] == opener)
	}

	/// DEV-889. A private window belongs to the profile it was opened from, and runs that
	/// profile's extensions allowed there. With no window focused, as in a headless run, it
	/// still belongs to one: the main window's.
	@Test
	func privateWindowsBelongToTheMainWindowsProfileWithNothingFocused() async throws {
		let durable = fixture()
		let mainProfile = durable.spaces[0].profileID
		var state = AppFeature.State(main: .init(organization: durable, spaceID: durable.spaces[0].id))
		state.focusedWindowID = nil
		let prepared = LockIsolated<[Profile.ID?]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.preparePrivateProfile = { _, opener in prepared.withValue { $0.append(opener) } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.newPrivateWindow))
		await store.receive(\.event.privateWindowReady)
		await store.skipReceivedActions()

		expectNoDifference(prepared.value, [mainProfile])
		let window = try #require(store.state.windows.last)
		#expect(store.state.privateProfileOpeners[window.sidebar.space.profileID] == mainProfile)
	}
}
