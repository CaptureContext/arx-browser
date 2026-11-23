import AppKit
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// The profile picker at the pointer for links whose route asks (DEV-858).
extension IntegrationFeatureTests {
	@Test(.renderTurn)
	internal func profilePickerListsTheMostRecentProfileFirstAndLoadsNothing() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.store()

		await store.send(.ui(.routeURLs([harness.askURL(1)])))
		await store.receive(\.processRouteQueue)
		await store.finish()

		let picker = try #require(store.state.routingInbox.picker)
		expectNoDifference(picker.options.map(\.id), [harness.work.id, harness.club.id, harness.personal])
		expectNoDifference(picker.options.map(\.spaceID), [harness.workSpace.id, harness.clubSpace.id, harness.personalSpace])
		expectNoDifference(picker.highlightedID, harness.work.id)
		expectNoDifference(picker.url, harness.askURL(1))
		expectNoDifference(store.state.routingInbox.requests.map(\.status), [.choosingProfile])

		// Nothing loads while it asks, and the main window stays where it was.
		expectNoDifference(harness.prepared.value, [])
		expectNoDifference(harness.opened.value, [])
		#expect(store.state.littleWindows.isEmpty)
		expectNoDifference(store.state.focusedWindowID, harness.initialState.focusedWindowID)
		expectNoDifference(store.state.windowIsOpen, harness.initialState.windowIsOpen)
	}

	@Test(.renderTurn)
	internal func profilePickerReturnOpensTheMostRecentProfileInLittleArx() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.store()

		await store.send(.ui(.routeURLs([harness.askURL(1)])))
		await store.receive(\.processRouteQueue)
		await store.send(.profilePicker(.ui(.confirm)))
		await store.receive(\.processRouteQueue)
		await store.receive(\.event.routedSessionReady)
		await store.finish()

		#expect(store.state.routingInbox.picker == nil)
		#expect(store.state.routingInbox.requests.isEmpty)
		expectNoDifference(harness.prepared.value, [harness.work.id])
		expectNoDifference(harness.opened.value.map(\.restoration.url), [harness.askURL(1)])
		expectNoDifference(harness.opened.value.map(\.profileID), [harness.work.id])
		let little = try #require(store.state.littleWindows.first)
		expectNoDifference(little.spaceID, harness.workSpace.id)
		expectNoDifference(store.state.focusedWindowID, little.id)

		// Little Arx pages stay out of the workspace.
		expectNoDifference(store.state.workspace, harness.organization)
	}

	@Test(.renderTurn)
	internal func profilePickerArrowsAndFilterChooseAnotherProfile() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.store()

		await store.send(.ui(.routeURLs([harness.askURL(1)])))
		await store.receive(\.processRouteQueue)
		await store.send(.profilePicker(.ui(.move(1))))
		expectNoDifference(store.state.routingInbox.picker?.highlightedID, harness.club.id)
		await store.send(.profilePicker(.ui(.move(1))))
		await store.send(.profilePicker(.ui(.move(1))))

		// The last stays highlighted at the end of the list.
		expectNoDifference(store.state.routingInbox.picker?.highlightedID, harness.personal)
		await store.send(.profilePicker(.ui(.move(-1))))
		expectNoDifference(store.state.routingInbox.picker?.highlightedID, harness.club.id)

		// Typing filters by profile or space name and highlights the first result.
		await store.send(.profilePicker(.ui(.setQuery("def"))))
		expectNoDifference(store.state.routingInbox.picker?.results.map(\.id), [harness.personal])
		expectNoDifference(store.state.routingInbox.picker?.highlightedID, harness.personal)
		await store.send(.profilePicker(.ui(.setQuery(""))))
		await store.send(.profilePicker(.ui(.move(1))))
		expectNoDifference(store.state.routingInbox.picker?.highlightedID, harness.club.id)

		await store.send(.profilePicker(.ui(.confirm)))
		await store.receive(\.event.routedSessionReady)
		await store.finish()
		expectNoDifference(harness.prepared.value, [harness.club.id])
		expectNoDifference(store.state.littleWindows.map(\.spaceID), [harness.clubSpace.id])
		expectNoDifference(harness.opened.value.map(\.profileID), [harness.club.id])
	}

	/// ⌘1–⌘9 open the link in the result with that number, counted among what the query leaves;
	/// a number past the last result does nothing.
	@Test(.renderTurn)
	internal func profilePickerNumberKeysOpenThatResult() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.store()

		await store.send(.ui(.routeURLs([harness.askURL(1)])))
		await store.receive(\.processRouteQueue)
		await store.send(.profilePicker(.ui(.openNumber(4))))
		#expect(store.state.routingInbox.picker != nil)
		expectNoDifference(harness.prepared.value, [])

		await store.send(.profilePicker(.ui(.setQuery("def"))))
		await store.send(.profilePicker(.ui(.openNumber(1))))
		await store.receive(\.profilePicker.ui.confirm)
		await store.receive(\.event.routedSessionReady)
		await store.finish()
		#expect(store.state.routingInbox.picker == nil)
		expectNoDifference(harness.prepared.value, [harness.personal])
		expectNoDifference(harness.opened.value.map(\.profileID), [harness.personal])
	}

	/// ⌘2 reaches the picker from its panel before the main menu, whose ⌘2 is a space's.
	@Test(.renderTurn)
	internal func profilePickerPanelTakesCommandNumbers() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.liveStore()
		store.send(.ui(.routeURLs([harness.askURL(1)])))
		let panel = try await harness.openPanel(store)
		defer { harness.close(panel) }

		let event = try #require(NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: .command,
			timestamp: ProcessInfo.processInfo.systemUptime,
			windowNumber: panel.windowNumber,
			context: nil,
			characters: "2",
			charactersIgnoringModifiers: "2",
			isARepeat: false,
			keyCode: 19
		))
		#expect(panel.performKeyEquivalent(with: event))
		try await harness.waitUntil { store.routingInbox.picker == nil }
		try await harness.waitUntil { !store.littleWindows.isEmpty }
		expectNoDifference(store.littleWindows.first?.tab.profileID, harness.club.id)
	}

	@Test(.renderTurn)
	internal func profilePickerEscOpensNothing() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.store()

		await store.send(.ui(.routeURLs([harness.askURL(1)])))
		await store.receive(\.processRouteQueue)
		await store.send(.profilePicker(.ui(.cancel)))
		await store.receive(\.processRouteQueue)
		await store.finish()

		#expect(store.state.routingInbox.picker == nil)
		#expect(store.state.routingInbox.requests.isEmpty)
		#expect(store.state.littleWindows.isEmpty)
		expectNoDifference(harness.prepared.value, [])
		expectNoDifference(harness.opened.value, [])
	}

	@Test(.renderTurn)
	internal func profilePickerLosingFocusOpensNothing() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.store()

		await store.send(.ui(.routeURLs([harness.askURL(1)])))
		await store.receive(\.processRouteQueue)
		let requestID = try #require(store.state.routingInbox.picker?.requestID)

		// A panel closing for an earlier link can't cancel this one.
		await store.send(.profilePicker(.ui(.lostFocus(UUID(999)))))
		#expect(store.state.routingInbox.picker?.requestID == requestID)

		await store.send(.profilePicker(.ui(.lostFocus(requestID))))
		await store.receive(\.processRouteQueue)
		await store.finish()
		#expect(store.state.routingInbox.picker == nil)
		#expect(store.state.routingInbox.requests.isEmpty)
		#expect(store.state.littleWindows.isEmpty)
		expectNoDifference(harness.prepared.value, [])
		expectNoDifference(harness.opened.value, [])
	}

	/// Several links ask one at a time, in order. Links behind the picker wait, even ones whose
	/// route needs no answer, so they open in the order they came.
	@Test(.renderTurn)
	internal func profilePickerAsksAboutSeveralLinksOneAtATimeInOrder() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.store()
		let plain = URL(string: "https://plain.example/page")!
		let urls = [harness.askURL(1), plain, harness.askURL(3)]

		await store.send(.ui(.routeURLs(urls)))
		await store.receive(\.processRouteQueue)
		expectNoDifference(store.state.routingInbox.picker?.url, urls[0])
		expectNoDifference(store.state.routingInbox.requests.map(\.status), [.choosingProfile, .queued, .queued])
		expectNoDifference(harness.opened.value, [])

		// The first opens in the chosen profile; then the plain link follows its route.
		await store.send(.profilePicker(.ui(.move(1))))
		await store.send(.profilePicker(.ui(.confirm)))
		await store.receive(\.event.routedSessionReady)
		await store.receive(\.event.routedSessionReady)

		// Then the third asks.
		await store.receive(\.processRouteQueue)
		await store.finish()
		expectNoDifference(harness.opened.value.map(\.restoration.url), [urls[0], urls[1]])
		expectNoDifference(store.state.routingInbox.picker?.url, urls[2])
		expectNoDifference(store.state.routingInbox.requests.map(\.status), [.choosingProfile])

		// The third is dropped.
		await store.send(.profilePicker(.ui(.cancel)))
		await store.receive(\.processRouteQueue)
		await store.finish()
		#expect(store.state.routingInbox.picker == nil)
		#expect(store.state.routingInbox.requests.isEmpty)
		expectNoDifference(harness.opened.value.map(\.restoration.url), [urls[0], urls[1]])
		expectNoDifference(store.state.littleWindows.map(\.tab.restoration.url), [urls[0], urls[1]])
		expectNoDifference(harness.opened.value.map(\.profileID), [harness.club.id, harness.work.id])
	}

	/// Without a window to show the picker, as in headless runs, Ask keeps using Incoming Links.
	@Test(.renderTurn)
	internal func profilePickerFallsBackToIncomingLinksWithoutAHost() async throws {
		var harness = ProfilePickerHarness()
		harness.initialState.routingInbox.picksProfileAtPointer = false
		let store = harness.store()

		await store.send(.ui(.routeURLs([harness.askURL(1)])))
		await store.receive(\.processRouteQueue)
		await store.finish()
		#expect(store.state.routingInbox.picker == nil)
		expectNoDifference(store.state.routingInbox.requests.map(\.status), [.needsDestination(.missingDestination)])
		expectNoDifference(harness.opened.value, [])
	}

	/// The default "Otherwise" route is unchanged: with no route asking, no picker shows.
	@Test(.renderTurn)
	internal func profilePickerShowsOnlyForLinksThatAsk() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.store()

		await store.send(.ui(.routeURLs([URL(string: "https://plain.example")!])))
		await store.receive(\.event.routedSessionReady)
		await store.finish()
		#expect(store.state.routingInbox.picker == nil)
		expectNoDifference(store.state.littleWindows.map(\.spaceID), [harness.workSpace.id])
	}

	/// The search field writes back the same text when its editing ends and starts again, as
	/// with Tab; the highlight stays where the arrow keys left it (DEV-953).
	@Test(.renderTurn)
	internal func profilePickerSameQueryKeepsTheHighlight() async throws {
		let harness = ProfilePickerHarness()
		let store = harness.store()

		await store.send(.ui(.routeURLs([harness.askURL(1)])))
		await store.receive(\.processRouteQueue)
		await store.send(.profilePicker(.ui(.move(1))))
		await store.send(.profilePicker(.ui(.setQuery(""))))
		expectNoDifference(store.state.routingInbox.picker?.highlightedID, harness.club.id)
	}

	@Test(.renderTurn)
	internal func profilePickerOptionsSkipProfilesWithoutSpaces() {
		let harness = ProfilePickerHarness()
		var organization = harness.organization
		organization.profiles.append(.init(id: .init(rawValue: UUID(84)), name: "Empty"))
		let options = RoutingProfilePicker.options(
			organization: organization,
			currentSpaceID: nil,
			recentSpaceIDs: [harness.clubSpace.id]
		)
		expectNoDifference(options.map(\.id), [harness.club.id, harness.personal, harness.work.id])
	}
}

@MainActor
internal struct ProfilePickerHarness {
	internal let organization: BrowserOrganization
	internal let personal: Profile.ID
	internal let personalSpace: Space.ID
	internal let work = Profile(id: .init(rawValue: UUID(80)), name: "Work")
	internal let workSpace: Space
	internal let club = Profile(id: .init(rawValue: UUID(82)), name: "Club")
	internal let clubSpace: Space
	internal var initialState: AppFeature.State
	internal let prepared = LockIsolated<[Profile.ID]>([])
	internal let opened = LockIsolated<[BrowserCore.Tab]>([])

	internal init() {
		var organization = IntegrationFeatureTests().fixture()
		personal = organization.profiles[0].id
		personalSpace = organization.spaces[0].id
		workSpace = Space(id: .init(rawValue: UUID(81)), profileID: work.id, name: "Projects")
		clubSpace = Space(id: .init(rawValue: UUID(83)), profileID: club.id, name: "Reading")
		organization.profiles.append(work)
		organization.profiles.append(club)
		organization.spaces.append(workSpace)
		organization.spaces.append(clubSpace)
		self.organization = organization

		// Work is in front, Club was used before it, and Default before that.
		var state = AppFeature.State(main: .init(organization: organization, spaceID: workSpace.id))
		state.recentSpaceIDs = [workSpace.id, clubSpace.id, personalSpace]
		state.routingInbox.isReady = true
		state.routingInbox.picksProfileAtPointer = true
		state.settings.$routingPreferences.withLock {
			$0.rules = [.init(id: UUID(90), name: "Sign in", host: "accounts.example", destination: .init(scope: .ask))]
		}
		initialState = state
	}

	internal func askURL(_ index: Int) -> URL {
		URL(string: "https://accounts.example/o/oauth2/auth?state=\(index)")!
	}

	internal func liveStore() -> StoreOf<AppFeature> {
		let ids = LockIsolated(20)
		let prepared = prepared
		let opened = opened
		return Store(initialState: initialState) { AppFeature() } withDependencies: {
			$0.uuid = .init {
				ids.withValue {
					defer { $0 += 1 }
					return UUID($0)
				}
			}
			$0.browserEngine.prepareProfile = { id in prepared.withValue { $0.append(id) } }
			$0.browserEngine.open = { tab in opened.withValue { $0.append(tab) } }
		}
	}

	/// The picker's panel as BrowserWindow shows it, with its search field just given the
	/// keyboard, as when the panel becomes key.
	internal func openPanel(_ store: StoreOf<AppFeature>) async throws -> RoutingProfilePickerPanel {
		try await waitUntil { store.routingInbox.picker != nil }
		let picker = try #require(store.routingInbox.picker)
		let content = NSHostingView(rootView: RoutingProfilePickerView(store: store, picker: picker))
		let panel = RoutingProfilePickerPanel(size: content.fittingSize, anchor: .zero)
		panel.contentView = content
		panel.onCancel = { store.send(.profilePicker(.ui(.cancel))) }
		panel.onOpenNumber = { store.send(.profilePicker(.ui(.openNumber($0)))) }
		panel.focusSearchField()
		#expect(panel.firstResponder is NSTextView)
		return panel
	}

	internal func close(_ panel: RoutingProfilePickerPanel) {
		panel.onCancel = nil
		panel.onOpenNumber = nil
		panel.contentView = nil
		panel.close()
	}

	/// A key down and up sent straight to the panel, as the app smoke sends them.
	internal func press(
		keyCode: UInt16,
		characters: String,
		in panel: NSWindow
	) throws {
		for type in [NSEvent.EventType.keyDown, .keyUp] {
			let event = try #require(NSEvent.keyEvent(
				with: type,
				location: .zero,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: panel.windowNumber,
				context: nil,
				characters: characters,
				charactersIgnoringModifiers: characters,
				isARepeat: false,
				keyCode: keyCode
			))
			panel.sendEvent(event)
		}
	}

	/// Gives the main actor's queued work, the store's effects among it, time to run until `ready`.
	internal func waitUntil(_ ready: () -> Bool) async throws {
		await waitWhile { !ready() }
		#expect(ready())
	}

	internal func store() -> TestStoreOf<AppFeature> {
		let ids = LockIsolated(20)
		let prepared = prepared
		let opened = opened
		let store = TestStore(initialState: initialState) { AppFeature() } withDependencies: {
			$0.uuid = .init {
				ids.withValue {
					defer { $0 += 1 }
					return UUID($0)
				}
			}
			$0.browserEngine.prepareProfile = { id in prepared.withValue { $0.append(id) } }
			$0.browserEngine.open = { tab in opened.withValue { $0.append(tab) } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}
