import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import Testing
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct FindInPageTests {
	private func store(sent: LockIsolated<[BrowserEngineClient.Command]>) -> StoreOf<ViewerItemFeature> {
		let organization = IntegrationFeatureTests().fixture()
		return Store(initialState: ViewerItemFeature.State(tab: organization.tabs[0])) { ViewerItemFeature() } withDependencies: {
			$0.browserEngine.command = { _, command in sent.withValue { $0.append(command) } }
		}
	}

	@Test
	internal func typingSearchesAndSteppingMovesThroughMatches() async {
		let sent = LockIsolated<[BrowserEngineClient.Command]>([])
		let store = store(sent: sent)

		await store.send(.ui(.findPresented)).finish()
		expectNoDifference(store.findQuery, "")
		#expect(sent.value.isEmpty)

		// Stepping with nothing typed has nothing to search for.
		await store.send(.ui(.findStepped(forward: true))).finish()
		#expect(sent.value.isEmpty)

		await store.send(.ui(.findChanged("arx"))).finish()
		await store.send(.ui(.findStepped(forward: true))).finish()
		await store.send(.ui(.findStepped(forward: false))).finish()
		expectNoDifference(sent.value, [
			.find("arx", forward: true, newSession: true),
			.find("arx", forward: true, newSession: false),
			.find("arx", forward: false, newSession: false),
		])
	}

	@Test
	internal func clearingOrClosingStopsTheSearch() async {
		let sent = LockIsolated<[BrowserEngineClient.Command]>([])
		let store = store(sent: sent)
		await store.send(.ui(.findPresented)).finish()
		await store.send(.ui(.findChanged("a"))).finish()
		await store.send(.ui(.findChanged(""))).finish()
		await store.send(.ui(.findDismissed)).finish()
		#expect(store.findQuery == nil)
		expectNoDifference(sent.value, [.find("a", forward: true, newSession: true), .stopFind, .stopFind])
	}

	/// DEV-1297: closing the bar ends its field's editing, and SwiftUI writes the field's text back
	/// as it goes. That late write must not open the bar again.
	@Test
	internal func theFieldsLastWriteAfterClosingKeepsTheBarClosed() async {
		let sent = LockIsolated<[BrowserEngineClient.Command]>([])
		let store = store(sent: sent)
		await store.send(.ui(.findPresented)).finish()
		await store.send(.ui(.findChanged("arx"))).finish()
		await store.send(.ui(.findDismissed)).finish()
		await store.send(.ui(.findChanged("arx"))).finish()
		#expect(store.findQuery == nil)
		expectNoDifference(sent.value, [.find("arx", forward: true, newSession: true), .stopFind])
	}

	@Test
	internal func stepWithTheBarClosedOpensIt() async {
		let sent = LockIsolated<[BrowserEngineClient.Command]>([])
		let store = store(sent: sent)
		await store.send(.ui(.findStepped(forward: true))).finish()
		expectNoDifference(store.findQuery, "")
		#expect(sent.value.isEmpty)
	}


	@Test
	internal func copiedSelectionWaitsForFindWithoutOpeningTheBar() async throws {
		let sent = LockIsolated<[BrowserEngineClient.Command]>([])
		let store = store(sent: sent)
		await store.send(.ui(.findSeeded("selected words"))).finish()
		#expect(store.findQuery == nil)
		expectNoDifference(store.findSeed, "selected words")
		#expect(sent.value.isEmpty)
		await store.send(.ui(.findPresented)).finish()
		expectNoDifference(store.findQuery, "selected words")
		expectNoDifference(sent.value, [.find("selected words", forward: true, newSession: true)])
	}

	@Test
	internal func findNextUsesTheCopiedSelectionWhenTheBarWasClosed() async throws {
		let sent = LockIsolated<[BrowserEngineClient.Command]>([])
		let store = store(sent: sent)
		await store.send(.ui(.findSeeded("selected words"))).finish()
		await store.send(.ui(.findStepped(forward: false))).finish()
		expectNoDifference(store.findQuery, "selected words")
		#expect(store.findSeed == nil)
		expectNoDifference(sent.value, [.find("selected words", forward: false, newSession: true)])
	}

	@Test
	internal func copiedSelectionUpdatesAnAlreadyOpenFindBar() async throws {
		let sent = LockIsolated<[BrowserEngineClient.Command]>([])
		let store = store(sent: sent)
		await store.send(.ui(.findPresented)).finish()
		await store.send(.ui(.findSeeded("selected words"))).finish()
		expectNoDifference(store.findQuery, "selected words")
		expectNoDifference(sent.value, [.find("selected words", forward: true, newSession: true)])
	}

	/// DEV-1222: ⌘F on a bar that's already open, after focus went to the page, the URL bar or the
	/// sidebar, asks for the field again, which selects its text, and keeps the query and the search.
	@Test
	internal func findOnAnOpenBarFocusesItsFieldAgainAndKeepsTheSearch() async {
		let tab = IntegrationFeatureTests().fixture().tabs[0]
		let sent = LockIsolated<[BrowserEngineClient.Command]>([])
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab)) { ViewerItemFeature() } withDependencies: {
			$0.browserEngine.command = { _, command in sent.withValue { $0.append(command) } }
		}

		await store.send(.ui(.findPresented)) {
			$0.findQuery = ""
			$0.findFocusRequests = 1
		}
		await store.send(.ui(.findChanged("arx"))) { $0.findQuery = "arx" }
		await store.receive(\.ui.command)
		await store.send(.ui(.findPresented)) { $0.findFocusRequests = 2 }
		await store.send(.ui(.findPresented)) { $0.findFocusRequests = 3 }
		await store.finish()

		// The query stays, and the open bar doesn't search again.
		expectNoDifference(sent.value, [.find("arx", forward: true, newSession: true)])
	}

	/// DEV-1222: a seeded query (Use Selection for Find) still fills a bar opened with ⌘F, which takes
	/// focus once; stepping and closing don't ask for focus.
	@Test
	internal func onlyFindAsksForTheField() async {
		let tab = IntegrationFeatureTests().fixture().tabs[0]
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab)) { ViewerItemFeature() } withDependencies: {
			$0.browserEngine.command = { _, _ in }
		}

		await store.send(.ui(.findSeeded("words"))) { $0.findSeed = "words" }
		await store.send(.ui(.findPresented)) {
			$0.findQuery = "words"
			$0.findFocusRequests = 1
		}
		await store.receive(\.ui.findChanged) { $0.findSeed = nil }
		await store.receive(\.ui.command)
		await store.send(.ui(.findStepped(forward: true)))
		await store.receive(\.ui.command)
		await store.send(.ui(.findDismissed)) { $0.findQuery = nil }
		await store.receive(\.ui.command)
	}

	@Test
	internal func findCommandsMapToThePagesActions() {
		#expect(BrowserCommand.findInPage.findAction != nil)
		#expect(BrowserCommand.findNext.findAction != nil)
		#expect(BrowserCommand.findPrevious.findAction != nil)
		#expect(BrowserCommand.reload.findAction == nil)
	}
}
