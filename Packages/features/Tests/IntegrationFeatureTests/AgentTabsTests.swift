@testable import AppFeature
import AppUI
import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import Clocks
import CustomDump
import Foundation
import MainFeature
import Testing
import WebKit
import _ComposableArchitecture
import _TestSupport

/// DEV-1022: the tabs an agent opens say which client opened it, the client's next run takes
/// over one it left on the same page, and they're tidied into the archive once unused for
/// Settings' delay, unless the person picked or kept them or left something typed in a form.
@Suite(.dependencies)
@MainActor
internal struct AgentTabsTests {
	private static let clientID: UUID = UUID(80)
	private static let sessionID: UUID = UUID(81)

	/// A connection of the same client that has ended.
	private static let earlierSessionID: UUID = UUID(99)
	private static let agentTabID: BrowserCore.Tab.ID = .init(rawValue: UUID(90))
	private static let story: URL = URL(string: "https://news.example/story")!

	// MARK: - Opening

	/// Opening always makes a new tab in the background: the person's selection and page stay,
	/// and the new tab says which client opened it.
	@Test
	internal func anAgentOpensItsOwnTabAndTheTabSaysWhoOpenedIt() async throws {
		var state = fixture(agentTab: false)
		state.automationPreferences.clients[0].mutationGrantUntil = Date(timeIntervalSince1970: 200)
		var command = try openCommand(state)
		command.url = Self.story
		var responses: [AutomationResult] = []
		var opened: [BrowserCore.Tab] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.automationControl.authorize = { _ in true }
			$0.browserEngine.openAuthorized = { tab, authorize in
				guard authorize() else { throw AutomationFailure.denied }
				opened.append(tab)
			}
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.automation(.event(.host(.request(request(command))))))
		await store.receive(\.automation.event.inspected)
		await store.receive(\.automation.event.opened)
		await store.finish()
		await store.skipReceivedActions(strict: false)

		let tab = try #require(opened.first)
		expectNoDifference(tab.automationClientID, Self.clientID)
		expectNoDifference(store.state.automation.agentTabs[tab.id], AgentTab(clientID: Self.clientID, sessionID: Self.sessionID))
		expectNoDifference(store.state.main.sidebar.tabAgents[tab.id], .opener("Fixture client"))
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, state.main.sidebar.selectedTab?.id)
	}

	/// The client's next run takes over the tab it left on the same page, tracking keys and a
	/// trailing slash aside, instead of opening another beside it.
	@Test
	internal func theNextRunTakesOverTheTabItLeftOnThatPage() async throws {
		var state = fixture()
		state.automationPreferences.clients[0].mutationGrantUntil = Date(timeIntervalSince1970: 200)
		var command = try openCommand(state)
		command.url = URL(string: "https://www.news.example/story/?utm_source=feed")!
		var responses: [AutomationResult] = []
		var loaded: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.automationControl.authorize = { _ in true }

			// Its page loads again if it was unloaded; no new tab is made.
			$0.browserEngine.openAuthorized = { tab, authorize in
				guard authorize() else { throw AutomationFailure.denied }
				loaded.append(tab.id)
			}
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.automation(.event(.host(.request(request(command))))))
		await store.receive(\.automation.event.inspected)
		await store.receive(\.automation.event.agentTabReuseReady)
		await store.receive(\.automation.event.finished)
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(loaded, [Self.agentTabID])
		await store.skipReceivedActions(strict: false)

		// Its page wasn't loaded, so it's loading now.
		expectNoDifference(
			responses.last,
			.command(.init(operationID: command.operationID, status: .acceptedLoading, targetID: Self.agentTabID.rawValue))
		)
		expectNoDifference(store.state.automation.agentTabs[Self.agentTabID]?.sessionID, Self.sessionID)
		#expect(store.state.workspace.tabs.count == state.workspace.tabs.count)
	}

	/// With independent windows, a tab taken over goes to the window the run names, or the main
	/// window when it names none, as a new tab would (DEV-1157).
	@Test(arguments: [false, true])
	internal func aTakenOverTabComesToTheWindowTheRunNames(namesWindow: Bool) async throws {
		let windowID = UUID(50)
		var state = fixture()
		state.automationPreferences.clients[0].mutationGrantUntil = Date(timeIntervalSince1970: 200)
		state.setIndependentWindows(true)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)

		// Left in the other window by the earlier run, or in the main window.
		if !namesWindow { state.windowTabOwners[Self.agentTabID] = windowID }
		state.applyOpenTabFilters()
		var command = try openCommand(state)
		command.url = Self.story
		if namesWindow { command.windowID = windowID }
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, _ in }
			$0.automationControl.authorize = { _ in true }
			$0.browserEngine.openAuthorized = { _, authorize in
				guard authorize() else { throw AutomationFailure.denied }
			}
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.automation(.event(.host(.request(request(command))))))
		await store.receive(\.automation.event.inspected)
		await store.receive(\.automation.event.agentTabReuseReady)
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.windowTabOwners[Self.agentTabID], namesWindow ? windowID : nil)
		#expect(store.state.main.sidebar.windowOpenTabs.contains(Self.agentTabID) == !namesWindow)
	}

	/// Only the same client's tab from an earlier run is taken over: never one this run already
	/// has, another client's, or the person's own.
	@Test
	internal func onlyTheClientsLeftTabIsEverTakenOver() {
		var state = fixture()
		let spaceID = state.workspace.spaces[0].id
		#expect(state.reusableAgentTab(clientID: Self.clientID, sessionID: Self.sessionID, url: Self.story, spaceID: spaceID) == Self.agentTabID)
		// Another page.
		#expect(state.reusableAgentTab(clientID: Self.clientID, sessionID: Self.sessionID, url: URL(string: "https://news.example/other")!, spaceID: spaceID) == nil)
		// Another client.
		#expect(state.reusableAgentTab(clientID: UUID(77), sessionID: Self.sessionID, url: Self.story, spaceID: spaceID) == nil)
		// This run's own tab: it may mean to open a second one.
		state.automation.agentTabs[Self.agentTabID]?.sessionID = Self.sessionID
		#expect(state.reusableAgentTab(clientID: Self.clientID, sessionID: Self.sessionID, url: Self.story, spaceID: spaceID) == nil)
		// The person's tab on the same page.
		state.workspace.tabs[id: Self.agentTabID]?.automationClientID = nil
		state.automation.agentTabs[Self.agentTabID]?.sessionID = Self.earlierSessionID
		#expect(state.reusableAgentTab(clientID: Self.clientID, sessionID: Self.sessionID, url: Self.story, spaceID: spaceID) == nil)
	}

	// MARK: - Tidying

	/// Unused past Settings' delay, the agent's tab goes to the archive, once its page agrees.
	@Test
	internal func anUnusedAgentTabIsTidiedIntoTheArchive() async throws {
		var state = fixture()
		state.automation.agentTabs[Self.agentTabID]?.idle = .seconds(14 * 60)
		let closed = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.evaluateScript = { _, _, _, _, _ in .value("false") }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { id in closed.withValue { $0.append(id) } }
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.tidyAgentTabs)
		await store.receive(\.automation.event.agentTabsChecked)
		await store.receive(\.main.archiveInactiveTabs, [Self.agentTabID])
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(closed.value == [Self.agentTabID])
		#expect(store.state.main.sidebar.organization.tabs[id: Self.agentTabID] == nil)
		#expect(store.state.main.sidebar.organization.archive.contains { $0.tab.id == Self.agentTabID })
	}

	/// A tab with something typed into a form stays, and is looked at again a whole delay later.
	@Test
	internal func aTabWithSomethingTypedStays() async throws {
		var state = fixture()
		state.automation.agentTabs[Self.agentTabID]?.idle = .seconds(15 * 60)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.evaluateScript = { _, script, _, _, _ in
				#expect(script == AgentTabTidying.draftProbe)
				return .value("true")
			}
			$0.browserEngine.permitsClosing = { _ in Issue.record("A drafted tab isn't archived"); return true }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.tidyAgentTabs)
		await store.receive(\.automation.event.agentTabsChecked)
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.workspace.tabs[id: Self.agentTabID] != nil)
		expectNoDifference(store.state.automation.agentTabs[Self.agentTabID]?.idle, .zero)
	}

	/// A page the engine couldn't read now keeps its tab this time; one it can't read at all
	/// (unloaded, private or off the web) has nothing typed to lose.
	@Test
	internal func aPageThatCantBeReadNowStays() async {
		var busy = BrowserEngineClient.testValue
		busy.evaluateScript = { _, _, _, _, _ throws(BrowserDeveloperFailure) in throw .busy }
		#expect(await AgentTabTidying.holdsDraft(Self.agentTabID, engine: busy))
		var unloaded = BrowserEngineClient.testValue
		unloaded.evaluateScript = { _, _, _, _, _ throws(BrowserDeveloperFailure) in throw .stale }
		#expect(await !AgentTabTidying.holdsDraft(Self.agentTabID, engine: unloaded))
	}

	/// The engine's all-frames check decides when it can, without the draft probe; an engine
	/// without it falls back to the probe (DEV-1084).
	@Test
	internal func theEnginesAllFramesCheckComesFirst() async throws {
		var checked = BrowserEngineClient.testValue
		checked.evaluateScript = { _, _, _, _, _ throws(BrowserDeveloperFailure) in
			Issue.record("The engine answered, so the probe doesn't run")
			return .value("false")
		}
		checked.formEdits = { _ in .typed }
		#expect(await AgentTabTidying.holdsDraft(Self.agentTabID, engine: checked))
		checked.formEdits = { _ in .unknown }
		#expect(await AgentTabTidying.holdsDraft(Self.agentTabID, engine: checked))
		checked.formEdits = { _ in .clean }
		#expect(await !AgentTabTidying.holdsDraft(Self.agentTabID, engine: checked))

		var older = BrowserEngineClient.testValue
		older.formEdits = { _ in nil }
		older.evaluateScript = { _, script, _, _, _ throws(BrowserDeveloperFailure) in
			#expect(script == AgentTabTidying.draftProbe)
			return .value("true")
		}
		#expect(await AgentTabTidying.holdsDraft(Self.agentTabID, engine: older))
	}

	/// A tab on screen, selected in its space, pinned, renamed or acted on stays; with Never it
	/// all stays.
	@Test
	internal func aTabInUseStays() {
		var state = fixture()
		#expect(state.isTidyable(Self.agentTabID))

		var selected = state
		selected.workspace.spaces[0].selectedTabID = Self.agentTabID
		#expect(!selected.isTidyable(Self.agentTabID))

		var renamed = state
		renamed.workspace.tabs[id: Self.agentTabID]?.customTitle = "Mine"
		#expect(!renamed.isTidyable(Self.agentTabID))

		var acting = state
		acting.automation.presence[Self.agentTabID] = .init(
			clientID: Self.clientID,
			activeRequests: [UUID(5): Self.clientID],
			lastActed: Date(timeIntervalSince1970: 100)
		)
		#expect(!acting.isTidyable(Self.agentTabID))

		state.automationPreferences.agentTabCleanup = .never
		#expect(state.automationPreferences.agentTabCleanup.delay == nil)
	}

	/// A tab in use counts no unused time: an agent reading it, or the person looking at it,
	/// starts its delay over once that ends.
	@Test
	internal func aTabInUseCountsNoUnusedTime() async throws {
		var state = fixture()
		state.automation.agentTabs[Self.agentTabID]?.idle = .seconds(10 * 60)

		// An agent keeps reading its console: a read, which shows no indicator.
		state.automation.developerLogs[Self.agentTabID] = Self.clientID
		#expect(!state.isTidyable(Self.agentTabID))
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.tidyAgentTabs)
		expectNoDifference(store.state.automation.agentTabs[Self.agentTabID]?.idle, .zero)
		await store.finish()
	}

	/// A tab that came into use while its page was asked stays, whatever the page answered.
	@Test
	internal func aTabUsedWhileItsPageWasAskedStays() async throws {
		var state = fixture()
		state.automation.agentTabsArchiving = [Self.agentTabID: 0]
		state.workspace.spaces[0].selectedTabID = Self.agentTabID
		let entries = state.workspace.archiveEntries(
			for: [Self.agentTabID],
			closedAt: Date(timeIntervalSince1970: 100),
			groupID: UUID(7),
			uuid: { UUID(8) }
		)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.close = { _ in Issue.record("A tab in use isn't archived") }
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.event(.inactiveArchivePermitted(entries, refused: []))))
		await store.receive(\.main.event.archiveFailed)
		await store.finish()
		#expect(store.state.automation.agentTabsArchiving.isEmpty)
	}

	/// A decision taken before the agent used the tab again, or before Settings said Never, is
	/// dropped.
	@Test(arguments: [false, true])
	internal func aStaleDecisionArchivesNothing(never: Bool) async throws {
		var state = fixture()
		if never {
			state.automationPreferences.agentTabCleanup = .never
		} else {
			state.agentUsedTab(Self.agentTabID)
		}
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		// Decided at no uses, before the use or the setting.
		await store.send(.automation(.event(.agentTabsChecked([Self.agentTabID: 0], drafted: [], policy: 0))))
		await store.finish()
		#expect(store.state.automation.agentTabsArchiving.isEmpty)
		#expect(store.state.workspace.tabs[id: Self.agentTabID] != nil)
	}

	/// A new delay drops the decisions taken under the old one, and a WebKit page, which can't be
	/// read for drafts or asked before it closes, is never tidied.
	@Test
	internal func aNewDelayOrAWebKitPageArchivesNothing() async throws {
		let store = TestStore(initialState: fixture()) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.automation(.ui(.agentTabCleanup(.oneHour))))
		await store.send(.automation(.event(.agentTabsChecked([Self.agentTabID: 0], drafted: [], policy: 0))))
		await store.finish()
		#expect(store.state.automation.agentTabsArchiving.isEmpty)
		#expect(store.state.workspace.tabs[id: Self.agentTabID] != nil)

		var webKit = fixture()
		webKit.webKitTabs = [Self.agentTabID]
		#expect(!webKit.isTidyable(Self.agentTabID))
	}

	/// A tab kept while its profile was readied gives way to a new tab. One gone to another page
	/// meanwhile does too, by the same page check `reusableAgentTab` makes.
	@Test
	internal func aTabThatChangedMeanwhileGivesWayToANewOne() async throws {
		var state = fixture()
		state.automationPreferences.clients[0].mutationGrantUntil = Date(timeIntervalSince1970: 200)
		var command = try openCommand(state)
		command.url = Self.story
		var opened: [BrowserCore.Tab] = []

		// The profile is readied only once the test says so, after the person keeps the tab.
		let (ready, readied) = AsyncStream<Void>.makeStream()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, _ in }
			$0.automationControl.authorize = { _ in true }
			$0.browserEngine.prepareProfile = { _ in
				for await _ in ready { break }
			}
			$0.browserEngine.openAuthorized = { tab, _ in opened.append(tab) }
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.automation(.event(.host(.request(request(command))))))
		await store.receive(\.automation.event.inspected)
		await store.send(.main(.delegate(.keepAgentTab(Self.agentTabID))))
		readied.yield()
		readied.finish()
		await store.receive(\.automation.event.agentTabReuseReady)
		await store.receive(\.automation.event.opened)
		await store.finish()
		await store.skipReceivedActions(strict: false)

		let tab = try #require(opened.first)
		#expect(tab.id != Self.agentTabID)
		#expect(store.state.workspace.tabs[id: Self.agentTabID]?.automationClientID == nil)
	}

	@Test
	internal func theDraftProbeKeepsProtectedFieldsAndUntouchedDropdowns() {
		let probe = AgentTabTidying.draftProbe
		#expect(probe.contains("field.type === 'password'"))
		#expect(probe.contains("'cc-number', 'cc-csc', 'cc-exp', 'one-time-code'"))
		// A dropdown starts at its first option that can be chosen, outside a disabled group; a list
		// box with nothing chosen (DEV-1084).
		#expect(probe.contains("options.findIndex(usable)"))
		#expect(probe.contains("option.parentElement.tagName === 'OPTGROUP' && option.parentElement.disabled"))
		#expect(probe.contains("field.size > 1 ? -1"))
		// A filled field counts even when the page keeps its default in step, as React does.
		#expect(probe.contains("if (field.value !== field.defaultValue) return true;"))
		// A cleared default counts too: the comparison comes before the empty check (DEV-1084).
		#expect(probe.range(of: "field.value !== field.defaultValue")!.lowerBound < probe.range(of: "field.value.trim() === ''")!.lowerBound)
		#expect(probe.contains("field.closest('[role=search]')"))
		#expect(probe.contains("field.validity.badInput"))
		#expect(probe.contains("element.shadowRoot"))
	}

	/// The draft probe, run by WebKit on real fields (DEV-1092): a file chosen for upload and a
	/// prefilled field that was cleared are drafts; empty fields and a filled search box aren't.
	@Test
	internal func theDraftProbeSeesAChosenFileAndAClearedField() async throws {
		let empty = """
		<form>
		<input id="name" value="">
		<input id="upload" type="file">
		<textarea id="note"></textarea>
		<input type="search" name="q" value="water mills">
		</form>
		"""
		#expect(try await Self.runDraftProbe(on: empty, after: "") == false)
		let chooseFile = """
		const chosen = new DataTransfer();
		chosen.items.add(new File(['report'], 'report.txt', { type: 'text/plain' }));
		document.getElementById('upload').files = chosen.files;
		"""
		#expect(try await Self.runDraftProbe(on: empty, after: chooseFile) == true)

		// A filled field counts anyway, as pages like React keep its default in step; emptied,
		// it differs from the page's own value.
		let prefilled = """
		<form><input id="name" value="Ann"><textarea id="note">Hello</textarea></form>
		"""
		let clearBoth = "document.getElementById('name').value = ''; document.getElementById('note').value = '';"
		#expect(try await Self.runDraftProbe(on: prefilled, after: clearBoth) == true)
		let clearName = """
		document.getElementById('note').remove();
		document.getElementById('name').value = '';
		"""
		#expect(try await Self.runDraftProbe(on: prefilled, after: clearName) == true)
	}

	/// An agent's tab glanced at between two checks, as with Next Tab, starts its unused time
	/// over when it comes on screen and again when it leaves (DEV-1093), and a tidying decision
	/// taken before is dropped.
	@Test
	internal func showingAnAgentTabBetweenChecksStartsItsUnusedTimeOver() async throws {
		var state = fixture()
		state.automation.agentTabs[Self.agentTabID]?.idle = .seconds(14 * 60)
		let agentTab = try #require(state.workspace.tabs[id: Self.agentTabID])
		let personsTab = try #require(state.workspace.tabs.first { $0.id != Self.agentTabID })
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.viewer(.item(.show(agentTab)))))
		#expect(store.state.automation.agentTabs[Self.agentTabID]?.idle == .zero)
		let shown = try #require(store.state.automation.agentTabs[Self.agentTabID]?.uses)

		// Leaving the screen counts as well.
		await store.send(.main(.viewer(.item(.show(personsTab)))))
		#expect(store.state.automation.agentTabs[Self.agentTabID]?.idle == .zero)
		#expect(store.state.automation.agentTabs[Self.agentTabID]?.uses == shown + 1)
		// Nothing holds it now, but a decision taken before it was shown no longer lets it go.
		#expect(store.state.isTidyable(Self.agentTabID))
		#expect(!store.state.isTidyable(Self.agentTabID, unusedSince: shown - 1))
		await store.finish()
	}

	/// A tab the person pinned or renamed is theirs from the next minute on.
	@Test
	internal func aPinnedOrRenamedTabBecomesThePersons() async throws {
		var state = fixture()
		state.workspace.tabs[id: Self.agentTabID]?.customTitle = "Mine"
		state.main.sidebar.organization = state.workspace
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.tidyAgentTabs)
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.tabs[id: Self.agentTabID]?.automationClientID == nil)
		#expect(store.state.automation.agentTabs[Self.agentTabID] == nil)
	}

	/// An agent's own pin, through MCP, keeps the tab the agent's at the next minute: the sweep
	/// can't tell who pinned, and engine batch 8's AutomationSmoke saw the agent's pinned tab
	/// lose its client.
	@Test
	internal func aTabTheAgentPinnedItselfStaysTheAgents() async throws {
		var state = fixture()
		state.automationPreferences.clients[0].mutationGrantUntil = Date(timeIntervalSince1970: 200)
		let items = AutomationInventoryBuilder.items(
			client: state.automationPreferences.clients[0],
			organization: state.workspace,
			snapshots: [:]
		)
		let tab = try #require(items.first { $0.id == Self.agentTabID.rawValue })
		let space = try #require(items.first { $0.kind == .space })
		let pin = AutomationCommand(
			operationID: UUID(85),
			action: .pinTab,
			targetID: tab.id,
			expectedRevision: tab.revision,
			destinationID: space.id,
			destinationRevision: space.revision
		)
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.automationControl.authorize = { _ in true }
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.automation(.event(.host(.request(request(pin, id: UUID(86)))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		guard case let .command(result)? = responses.last, result.status == .committed else {
			Issue.record("The pin didn't commit: \(String(describing: responses.last))")
			return
		}
		let pinned = try #require(store.state.workspace.tabs[id: Self.agentTabID])
		#expect(pinned.savedDestination != nil)
		expectNoDifference(store.state.automation.agentTabs[Self.agentTabID]?.agentOrganization, .init(pinned))

		await store.send(.tidyAgentTabs)
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.tabs[id: Self.agentTabID]?.automationClientID, Self.clientID)
		#expect(store.state.automation.agentTabs[Self.agentTabID] != nil)
	}

	internal enum PersonsChange: CaseIterable, Sendable {
		case rename
		case repin
		case unpin
	}

	/// A tab the agent pinned becomes the person's once the person renames it, pins it anew or
	/// unpins it.
	@Test(arguments: PersonsChange.allCases)
	internal func thePersonChangingAnAgentsPinMakesItTheirs(change: PersonsChange) async throws {
		var state = fixture()
		state.workspace.tabs[id: Self.agentTabID]?.savedDestination = .init(title: "Story", url: Self.story)
		let left = try #require(state.workspace.tabs[id: Self.agentTabID])
		state.automation.agentTabs[Self.agentTabID]?.agentOrganization = .init(left)
		switch change {
		case .rename: state.workspace.tabs[id: Self.agentTabID]?.customTitle = "Mine"
		case .repin: state.workspace.tabs[id: Self.agentTabID]?.savedDestination?.url = URL(string: "https://news.example/front")!
		case .unpin: state.workspace.tabs[id: Self.agentTabID]?.savedDestination = nil
		}
		state.main.sidebar.organization = state.workspace
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.tidyAgentTabs)
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.tabs[id: Self.agentTabID]?.automationClientID == nil)
		#expect(store.state.automation.agentTabs[Self.agentTabID] == nil)
	}

	/// The agent's own change records only a tab still as it left it: a name the person gave it
	/// first stays theirs, and the agent's pin after it doesn't claim it.
	@Test
	internal func anAgentsPinNeverClaimsThePersonsName() throws {
		var state = fixture()
		let previous = state.workspace
		var renamed = previous
		renamed.tabs[id: Self.agentTabID]?.customTitle = "Mine"
		var pinned = renamed
		pinned.tabs[id: Self.agentTabID]?.savedDestination = .init(title: "Mine", url: Self.story)

		state.noteAgentOrganization(from: renamed, to: pinned, clientID: Self.clientID)
		expectNoDifference(state.automation.agentTabs[Self.agentTabID]?.agentOrganization, nil)
		let tab = try #require(pinned.tabs[id: Self.agentTabID])
		let record = try #require(state.automation.agentTabs[Self.agentTabID])
		#expect(state.isPersonsOrganization(tab, record: record))

		// From a tab as the agent left it, the change is the agent's, and so is undoing it.
		state.noteAgentOrganization(from: previous, to: pinned, clientID: Self.clientID)
		expectNoDifference(state.automation.agentTabs[Self.agentTabID]?.agentOrganization, .init(tab))
		state.noteAgentOrganization(from: pinned, to: previous, clientID: Self.clientID)
		expectNoDifference(state.automation.agentTabs[Self.agentTabID]?.agentOrganization, AgentTab.AgentOrganization.untouched)
		let unpinned = try #require(previous.tabs[id: Self.agentTabID])
		#expect(!state.isPersonsOrganization(unpinned, record: try #require(state.automation.agentTabs[Self.agentTabID])))
	}

	/// Once the acting badge fades, the tab says which client opened it again.
	@Test
	internal func theOpenerShowsAgainAfterTheAgentActs() {
		var state = fixture()
		state.automation.presence[Self.agentTabID] = .init(clientID: Self.clientID, lastActed: Date(timeIntervalSince1970: 100))
		let badge = state.agentPresenceBadges[Self.agentTabID]
		expectNoDifference(badge?.openedBy, "Fixture client")
		#expect(badge?.fadesAt != nil)
	}

	/// The clock counts only time the Mac is awake: a suspending clock, which stands still
	/// while it sleeps, ticks each minute into the tab's unused time.
	@Test
	internal func unusedTimeGrowsWithEachAwakeMinute() async throws {
		let clock = TestClock()
		let store = TestStore(initialState: fixture()) { AppFeature() } withDependencies: {
			$0.suspendingClock = clock
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.startAgentTabs)
		await clock.advance(by: AgentTabTidying.interval)
		await store.receive(\.tidyAgentTabs)
		expectNoDifference(store.state.automation.agentTabs[Self.agentTabID]?.idle, AgentTabTidying.interval)
		await store.skipInFlightEffects()
	}

	// MARK: - The person's tab

	/// Picking the tab in the sidebar, or Keep Tab, makes it the person's: it forgets its
	/// client, loses its label and is never tidied.
	@Test(arguments: [false, true])
	internal func aPickedOrKeptTabBecomesThePersons(viaKeep: Bool) async throws {
		let store = TestStore(initialState: fixture()) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		if viaKeep {
			await store.send(.main(.delegate(.keepAgentTab(Self.agentTabID))))
		} else {
			await store.send(.main(.sidebar(.ui(.sidebar(.select(.tab(Self.agentTabID.rawValue)))))))
			await store.receive(\.automation.event.agentTabKept)
		}
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.workspace.tabs[id: Self.agentTabID]?.automationClientID == nil)
		#expect(store.state.automation.agentTabs[Self.agentTabID] == nil)
		#expect(store.state.main.sidebar.tabAgents[Self.agentTabID] == nil)
	}

	/// Every way the sidebar picks a tab makes it the person's, in the main window and in another:
	/// a click that selects on release, a plain press that selects as the button goes down
	/// (DEV-994), and a click on its member of a Split View group (DEV-1099).
	@Test(arguments: Pick.allCases, [false, true])
	internal func everyWayOfPickingTheTabMakesItThePersons(pick: Pick, inAnotherWindow: Bool) async throws {
		var state = fixture()
		let windowID = UUID(70)
		if inAnotherWindow {
			state.windows.append(.init(organization: state.workspace, spaceID: state.workspace.spaces[0].id, id: windowID))
		}
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let action = pick.action(Self.agentTabID.rawValue)
		if inAnotherWindow {
			await store.send(.windows(.element(id: windowID, action: .sidebar(.ui(.sidebar(action))))))
		} else {
			await store.send(.main(.sidebar(.ui(.sidebar(action)))))
		}
		await store.receive(\.automation.event.agentTabKept)
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.workspace.tabs[id: Self.agentTabID]?.automationClientID == nil)
		#expect(store.state.automation.agentTabs[Self.agentTabID] == nil)
	}

	/// A press that ends the selection, or a press on another tab, leaves the agent's tab alone.
	@Test
	internal func pressingAnotherTabLeavesTheAgentsTab() async throws {
		let state = fixture()
		let other = try #require(state.workspace.tabs.first { $0.id != Self.agentTabID })
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.sidebar(.ui(.sidebar(.selectOnPress(.tab(other.id.rawValue)))))))
		await store.send(.main(.sidebar(.ui(.sidebar(.pressCompleted(.tab(Self.agentTabID.rawValue)))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.workspace.tabs[id: Self.agentTabID]?.automationClientID == Self.clientID)
		#expect(store.state.automation.agentTabs[Self.agentTabID] != nil)
	}

	internal enum Pick: CaseIterable, Sendable {
		case click
		case press
		case splitMember

		fileprivate func action(_ tab: UUID) -> SidebarAction {
			switch self {
			case .click: .select(.tab(tab))
			case .press: .selectOnPress(.tab(tab))
			case .splitMember: .splitGroup(.focus(group: UUID(71), tab: tab))
			}
		}
	}

	@Test
	internal func theDelayIsASetting() async throws {
		let store = TestStore(initialState: fixture()) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.automation(.ui(.agentTabCleanup(.oneHour))))
		#expect(store.state.automationPreferences.agentTabCleanup == .oneHour)
		await store.finish()

		let encoded = try JSONEncoder().encode(AutomationPreferences(agentTabCleanup: .oneHour))
		#expect(try JSONDecoder().decode(AutomationPreferences.self, from: encoded).agentTabCleanup == .oneHour)
		// Preferences saved before the setting existed take the default.
		let earlier = #"{"isEnabled":true,"clients":[]}"#
		#expect(try JSONDecoder().decode(AutomationPreferences.self, from: Data(earlier.utf8)).agentTabCleanup == .fifteenMinutes)
	}

	@Test
	internal func pagesCompareWithoutTrackingKeysSlashesOrFragments() {
		#expect(AgentTabs.page(URL(string: "https://www.news.example/story/?b=2&a=1&utm_medium=x#top")!) == "news.example/story?a=1&b=2")
		#expect(AgentTabs.page(URL(string: "http://news.example:8080/story?gclid=1")!) == "news.example:8080/story")
		#expect(AgentTabs.page(URL(string: "file:///Users/me/story.html")!) == nil)
		// An escaped `&` in a value is part of the value, not another key.
		#expect(AgentTabs.page(URL(string: "https://example.com/?a=x%26b=y")!) != AgentTabs.page(URL(string: "https://example.com/?a=x&b=y")!))
	}

	// MARK: - Fixture

	/// Two opens that chose the same left tab: the first takes it over, and the second, looking
	/// again before its takeover, gets a new tab rather than the same one (DEV-1097).
	@Test
	internal func aTabAnotherOpenTookOverIsntTakenAgain() async throws {
		var state = fixture()
		var first = try openCommand(state)
		first.url = Self.story
		var second = first
		second.operationID = UUID(85)
		let opens = [request(first), request(second, id: UUID(86))]
		for open in opens {
			state.automation.pending[open.id] = .init(request: open, grantRevision: UUID(82))
			state.automation.pending[open.id]?.approved = true
		}
		var loaded: [BrowserCore.Tab.ID] = []
		var responses: [UUID: AutomationResult] = [:]
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { id, value in responses[id] = value }
			$0.automationControl.authorize = { _ in true }
			$0.browserEngine.openAuthorized = { tab, authorize in
				guard authorize() else { throw AutomationFailure.denied }
				loaded.append(tab.id)
			}
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.automation(.event(.agentTabReuseReady(opens[0].id, Self.agentTabID))))
		await store.send(.automation(.event(.agentTabReuseReady(opens[1].id, Self.agentTabID))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(loaded.first, Self.agentTabID)
		expectNoDifference(loaded.count, 2)
		#expect(loaded.last != Self.agentTabID)
		guard case let .command(taken)? = responses[opens[0].id] else {
			Issue.record("The first open has no result.")
			return
		}
		expectNoDifference(taken.targetID, Self.agentTabID.rawValue)
		expectNoDifference(store.state.automation.agentTabs[Self.agentTabID]?.sessionID, Self.sessionID)
	}

	/// Opens don't overlap through requests: while one is pending, another mutation is refused as
	/// busy, so the takeover above is a safeguard.
	@Test
	internal func aSecondOpenWhileOneIsPendingIsBusy() async throws {
		var state = fixture()
		state.automationPreferences.clients[0].mutationGrantUntil = Date(timeIntervalSince1970: 200)
		var first = try openCommand(state)
		first.url = Self.story
		var second = first
		second.operationID = UUID(85)
		var responses: [UUID: AutomationResult] = [:]
		let (ready, readied) = AsyncStream<Void>.makeStream()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { id, value in responses[id] = value }
			$0.automationControl.authorize = { _ in true }
			$0.browserEngine.prepareProfile = { _ in
				for await _ in ready { break }
			}
			$0.browserEngine.openAuthorized = { _, _ in }
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.automation(.event(.host(.request(request(first))))))
		await store.receive(\.automation.event.inspected)
		await store.send(.automation(.event(.host(.request(request(second, id: UUID(86)))))))
		readied.yield()
		readied.finish()
		await store.receive(\.automation.event.agentTabReuseReady)
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(responses[UUID(86)], .failure(.busy))
		guard case let .command(taken)? = responses[UUID(84)] else {
			Issue.record("The first open has no result.")
			return
		}
		expectNoDifference(taken.targetID, Self.agentTabID.rawValue)
	}

	/// A window with the fixture's tabs, an automation client with a live connection, and, unless
	/// told otherwise, a tab the client opened in an earlier connection, off screen and unused.
	/// Loads `html` in WebKit, runs `change`, then the draft probe, and returns its answer.
	private static func runDraftProbe(
		on html: String,
		after change: String
	) async throws -> Bool {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		let view = WKWebView(frame: .init(x: 0, y: 0, width: 480, height: 320), configuration: configuration)
		view.loadHTMLString("<!doctype html><body>\(html)</body>", baseURL: URL(string: "https://form.example/"))

		// Until the page has loaded: a fixed number of polls ran out on a busy Mac and probed a page
		// still loading.
		let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(30))
		while true {
			let state = try? await view.evaluateJavaScript("document.readyState") as? String
			if state == "complete", !view.isLoading { break }
			try #require(ContinuousClock.now < deadline, "The probe's page never finished loading")
			try await Task.sleep(for: .milliseconds(25))
		}
		let answer = try await view.callAsyncJavaScript(
			change + "\n" + AgentTabTidying.draftProbe,
			contentWorld: .defaultClient
		)
		return try #require(answer as? Bool)
	}

	private func fixture(agentTab: Bool = true) -> AppFeature.State {
		var organization = IntegrationFeatureTests().fixture()
		if agentTab {
			organization.tabs.append(.init(
				id: Self.agentTabID,
				profileID: organization.profiles[0].id,
				restoration: .init(title: "Story", url: Self.story),
				automationClientID: Self.clientID
			))
			organization.spaces[0].unpinnedTabs.append(Self.agentTabID)
		}
		let client = AutomationClient(
			id: Self.clientID,
			name: "Fixture client",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: [.space(organization.spaces[0].id, profileID: organization.profiles[0].id)],
			allowsRead: true,
			allowsManagement: true,
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[Self.sessionID] = client.id
		state.automation.agentTabsEnabled = true
		if agentTab {
			state.automation.agentTabs[Self.agentTabID] = .init(clientID: Self.clientID, sessionID: Self.earlierSessionID)
		}
		return state
	}

	private func openCommand(_ state: AppFeature.State) throws -> AutomationCommand {
		let items = AutomationInventoryBuilder.items(
			client: state.automationPreferences.clients[0],
			organization: state.workspace,
			snapshots: [:]
		)
		let space = try #require(items.first { $0.kind == .space })
		return .init(operationID: UUID(83), action: .openTab, targetID: space.id, expectedRevision: space.revision)
	}

	private func request(
		_ command: AutomationCommand,
		id: UUID = UUID(84)
	) -> AutomationRequest {
		.init(id: id, clientID: Self.clientID, sessionID: Self.sessionID, operation: .command(command))
	}
}
