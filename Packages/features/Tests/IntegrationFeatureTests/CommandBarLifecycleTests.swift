import AppFeature
import BrowserCore
import BrowserEngineClient
import CommandBarFeature
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test(arguments: ["url", "space"])
	internal func queuedMainCommandCannotExecuteDuringPrivateCloseApproval(_ destination: String) async throws {
		let organization = fixture()
		let windowID = UUID(20)
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		var window = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: true,
			id: windowID
		)
		window.viewer.item.tab = organization.tabs[0]
		initial.windows.append(window)
		var delayed: CommandBarFeature.Execution?
		var holdsExecution = true
		var commands: [BrowserEngineClient.Command] = []
		let started = AsyncStream.makeStream(of: Void.self)
		let resume = AsyncStream.makeStream(of: Void.self)
		let store = Store(initialState: initial) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if holdsExecution, case let .windows(.element(_, .commandBar(.delegate(.execute(value))))) = action {
					delayed = value
					return .none
				}
				return AppFeature()._reduce(into: &state, action: action)
			}
		} withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.command = { _, command in commands.append(command) }
			$0.browserEngine.permitsClosing = { _ in
				started.continuation.yield()
				for await _ in resume.stream { break }
				return false
			}
		}
		await store.send(.windows(.element(id: windowID, action: .ui(.openCommand(.currentTab))))).finish()
		let query = destination == "url" ? "https://queued.example" : organization.spaces[1].name
		let resultID = destination == "url" ? "destination" : organization.spaces[1].id.rawValue.uuidString
		await store.send(.windows(.element(id: windowID, action: .commandBar(.ui(.queryChanged(query)))))).finish()
		await store.send(.windows(.element(id: windowID, action: .commandBar(.ui(.selected(resultID)))))).finish()
		let execution = try #require(delayed)
		let closing = store.send(.ui(.requestClosePrivateWindow(windowID)))
		for await _ in started.stream { break }
		#expect(store.windows[id: windowID]?.isClosing == true)
		holdsExecution = false
		await store.send(.windows(.element(id: windowID, action: .commandBar(.delegate(.execute(execution)))))).finish()
		expectNoDifference(commands, [])
		expectNoDifference(store.windows[id: windowID]?.sidebar.spaceID, organization.spaces[0].id)
		expectNoDifference(store.windows[id: windowID]?.sidebar.organization, organization)
		resume.continuation.yield()
		await closing.finish()
		#expect(store.windows[id: windowID]?.isClosing == false)
	}

	@Test(arguments: ["profile", "switching", "close", "promotion", "promotionFailed", "dismiss", "generation"])
	internal func littleCommandRejectsChangedOrClosingSource(_ change: String) async throws {
		let organization = fixture()
		var initial = LittleArxFeature.State(id: UUID(20), spaceID: organization.spaces[0].id, tab: organization.tabs[0])
		initial.viewer.tab = initial.tab
		var delayed: CommandBarFeature.Execution?
		var holdsExecution = true
		var commands: [BrowserEngineClient.Command] = []
		let started = AsyncStream.makeStream(of: Void.self)
		let resume = AsyncStream.makeStream(of: Void.self)
		let store = Store(initialState: initial) {
			Reduce<LittleArxFeature.State, LittleArxFeature.Action> { state, action in
				if holdsExecution, case let .commandBar(.delegate(.execute(value))) = action {
					delayed = value
					return .none
				}
				return LittleArxFeature()._reduce(into: &state, action: action)
			}
		} withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.command = { _, command in commands.append(command) }
			$0.browserEngine.permitsClosing = { _ in
				if change == "close" || change == "switching" {
					started.continuation.yield()
					for await _ in resume.stream { break }
					return false
				}
				return true
			}
		}
		await store.send(.ui(.openCommand(.currentTab))).finish()
		await store.send(.commandBar(.ui(.queryChanged("https://queued.example")))).finish()
		await store.send(.commandBar(.ui(.selected("destination")))).finish()
		let execution = try #require(delayed)
		var finishTransition: (() async -> Void)?
		switch change {
		case "profile":
			await store.send(.changeProfile(.init(rawValue: UUID(30)), .init(rawValue: UUID(31)))).finish()

		case "switching", "close":
			let transition = store.send(change == "close" ? .ui(.close) : .changeProfile(.init(rawValue: UUID(30)), .init(rawValue: UUID(31))))
			finishTransition = { await transition.finish() }
			for await _ in started.stream { break }

		case "promotion", "promotionFailed":
			await store.send(.ui(.promote(organization.spaces[0].id, initial.tab.profileID))).finish()
			if change == "promotionFailed" { await store.send(.event(.promotionFailed("Cancelled"))).finish() }

		case "dismiss":
			await store.send(.commandBar(.ui(.dismissed))).finish()

		default:
			await store.send(.viewer(.show(initial.tab))).finish()
		}
		holdsExecution = false
		await store.send(.commandBar(.delegate(.execute(execution)))).finish()
		expectNoDifference(commands, [])
		resume.continuation.yield()
		await finishTransition?()
	}

	@Test(arguments: [false, true])
	internal func littleCommandExecutionIsConsumedOnceAndOldExecutionCannotConsumeReopenedBar(_ reopen: Bool) async throws {
		let organization = fixture()
		var initial = LittleArxFeature.State(id: UUID(20), spaceID: organization.spaces[0].id, tab: organization.tabs[0])
		initial.viewer.tab = initial.tab
		var captured: CommandBarFeature.Execution?
		var commands: [BrowserEngineClient.Command] = []
		let store = Store(initialState: initial) {
			Reduce<LittleArxFeature.State, LittleArxFeature.Action> { state, action in
				if case let .commandBar(.delegate(.execute(value))) = action { captured = value }
				return LittleArxFeature()._reduce(into: &state, action: action)
			}
		} withDependencies: {
			$0.browserEngine.command = { _, command in commands.append(command) }
		}
		let url = URL(string: "https://once.example")!
		await store.send(.ui(.openCommand(.currentTab))).finish()
		await store.send(.commandBar(.ui(.queryChanged(url.absoluteString)))).finish()
		await store.send(.commandBar(.ui(.selected("destination")))).finish()
		let execution = try #require(captured)
		expectNoDifference(commands, [.navigate(url)])
		if reopen { await store.send(.ui(.openCommand(.currentTab))).finish() }
		await store.send(.commandBar(.delegate(.execute(execution)))).finish()
		expectNoDifference(commands, [.navigate(url)])
		if reopen {
			#expect(store.commandBar.isPresented)
			await store.send(.commandBar(.ui(.queryChanged(url.absoluteString)))).finish()
			await store.send(.commandBar(.ui(.selected("destination")))).finish()
			expectNoDifference(commands, [.navigate(url), .navigate(url)])
		}
	}
}

extension IntegrationFeatureTests {
	@Test
	internal func closingMainWindowRejectsQueuedCommandBeforeViewerSuspends() async throws {
		let organization = fixture()
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = organization.tabs[0]
		var delayed: CommandBarFeature.Execution?
		var holdsExecution = true
		var suspensionWasQueued = false
		var commands: [BrowserEngineClient.Command] = []
		let store = Store(initialState: AppFeature.State(main: main)) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if holdsExecution, case let .main(.commandBar(.delegate(.execute(value)))) = action {
					delayed = value
					return .none
				}
				if case .main(.viewer(.suspend)) = action {
					suspensionWasQueued = true
					return .none
				}
				return AppFeature()._reduce(into: &state, action: action)
			}
		} withDependencies: {
			$0.browserEngine.command = { _, command in commands.append(command) }
		}
		await store.send(.main(.ui(.openCommand(.currentTab)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged("https://closed.example"))))).finish()
		await store.send(.main(.commandBar(.ui(.selected("destination"))))).finish()
		let execution = try #require(delayed)
		await store.send(.ui(.closeWindow)).finish()
		#expect(!store.windowIsOpen && suspensionWasQueued)
		expectNoDifference(store.main.viewer.item.generation, main.viewer.item.generation)
		holdsExecution = false
		await store.send(.main(.commandBar(.delegate(.execute(execution))))).finish()
		expectNoDifference(commands, [])
	}

	@Test(arguments: [false, true])
	internal func littleCommandKeepsQueryEditsAndSiteSearchEscapeUsable(_ commandOnly: Bool) async throws {
		SearchShortcut.useFixtures()
		let organization = fixture()
		let initial = LittleArxFeature.State(
			id: UUID(20),
			spaceID: organization.spaces[0].id,
			tab: organization.tabs[0],
			isCommandOnly: commandOnly
		)
		var opened: [BrowserCore.Tab] = []
		var commands: [BrowserEngineClient.Command] = []
		let store = Store(initialState: initial) { LittleArxFeature() } withDependencies: {
			$0.browserEngine.open = { opened.append($0) }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.command = { _, command in commands.append(command) }
		}
		await store.send(.ui(.task)).finish()
		if !commandOnly { await store.send(.ui(.openCommand(.currentTab))).finish() }
		let context = store.commandBarContext
		#expect(context != nil)
		await store.send(.commandBar(.ui(.queryChanged("gh")))).finish()
		await store.send(.commandBar(.ui(.tabPressed))).finish()
		#expect(store.commandBar.siteSearchKeyword == "gh")
		await store.send(.commandBar(.ui(.dismissed))).finish()
		#expect(store.commandBar.siteSearchKeyword == nil && store.commandBar.isPresented)
		expectNoDifference(store.commandBarContext, context)
		let url = URL(string: "https://fresh.example")!
		await store.send(.commandBar(.ui(.queryChanged(url.absoluteString)))).finish()
		await store.send(.commandBar(.ui(.selected("destination")))).finish()
		#expect(store.commandBarContext == nil && !store.isCommandOnly)
		if commandOnly {
			expectNoDifference(opened.map(\.restoration.url), [url])
			expectNoDifference(commands, [])
		} else { expectNoDifference(commands, [.navigate(url)]) }
	}
}
