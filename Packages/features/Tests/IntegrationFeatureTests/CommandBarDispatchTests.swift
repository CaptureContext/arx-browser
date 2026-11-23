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
	@Test(
		arguments: [
			"main-delegate", "main-application", "main-local",
			"little-delegate", "little-application", "little-local", "littleURL-local",
		],
		["replacement", "closing", "canceledClose", "unchanged"]
	)
	internal func acceptedCommandKeepsSourceAcrossDeferredDispatch(
		_ route: String,
		_ change: String
	) async throws {
		let parts = route.split(separator: "-")
		let host = String(parts[0])
		let boundary = String(parts[1])
		let organization = fixture()
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = organization.tabs[0]
		var initial = AppFeature.State(main: main)
		let littleID = UUID(20)
		let temporary = BrowserCore.Tab(
			id: .init(rawValue: UUID(40)),
			profileID: organization.profiles[0].id,
			restoration: organization.tabs[0].restoration
		)
		var little = LittleArxFeature.State(id: littleID, spaceID: organization.spaces[0].id, tab: temporary)
		little.viewer.tab = little.tab
		initial.littleWindows.append(little)
		var delayed: AppFeature.Action?
		var holdsDispatch = true
		var commands: [BrowserCore.Tab.ID] = []
		let started = AsyncStream.makeStream(of: Void.self)
		let resume = AsyncStream.makeStream(of: Void.self)
		let store = Store(initialState: initial) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if holdsDispatch {
					switch action {
					case .main(.delegate(.commandFromPane)) where host == "main" && boundary == "delegate",
						.littleWindows(.element(_, .delegate(.command))) where host == "little" && boundary == "delegate",
						.ui(.command) where boundary == "application",
						.main(.dispatchCommand) where host == "main" && boundary == "local",
						.littleWindows(.element(_, .dispatchCommand)) where host == "little" && boundary == "local",
						.littleWindows(.element(_, .navigateFromCommandBar)) where host == "littleURL":
						delayed = action
						return .none

					case .main(.viewer(.suspend)):
						return .none

					default:
						break
					}
				}
				return AppFeature()._reduce(into: &state, action: action)
			}
		} withDependencies: {
			$0.uuid = .constant(UUID(50))
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.permitsClosing = { _ in
				if change == "closing" || change == "canceledClose" {
					started.continuation.yield()
					for await _ in resume.stream { break }
					return false
				}
				return true
			}
			$0.browserEngine.command = { id, _ in commands.append(id) }
		}
		if host == "main" {
			await store.send(.main(.ui(.openCommand(.commands)))).finish()
			await store.send(.main(.commandBar(.ui(.queryChanged("reload"))))).finish()
			await store.send(.main(.commandBar(.ui(.selected("command-reload"))))).finish()
		} else {
			await store.send(.littleWindows(.element(id: littleID, action: .ui(.openCommand(.commands))))).finish()
			let query = host == "littleURL" ? "https://queued.example" : "reload"
			let selection = host == "littleURL" ? "destination" : "command-reload"
			await store.send(.littleWindows(.element(id: littleID, action: .commandBar(.ui(.queryChanged(query)))))).finish()
			await store.send(.littleWindows(.element(id: littleID, action: .commandBar(.ui(.selected(selection)))))).finish()
		}
		let action = try #require(delayed)
		var finishClose: (() async -> Void)?
		if change == "replacement" {
			if host == "main" {
				await store.send(.main(.viewer(.item(.show(organization.tabs[1]))))).finish()
			} else {
				await store.send(.littleWindows(.element(
					id: littleID,
					action: .changeProfile(.init(rawValue: UUID(30)), .init(rawValue: UUID(31)))
				))).finish()
				#expect(store.littleWindows[id: littleID]?.tab.profileID == .init(rawValue: UUID(30)))
			}
		} else if change != "unchanged" {
			if host == "main" {
				await store.send(.ui(.closeWindow)).finish()
				#expect(!store.windowIsOpen)
				if change == "canceledClose" { await store.send(.ui(.openWindow)).finish() }
			} else {
				let close = store.send(.littleWindows(.element(id: littleID, action: .ui(.close))))
				finishClose = { await close.finish() }
				for await _ in started.stream { break }
				#expect(store.littleWindows[id: littleID]?.isClosing == true)
				if change == "canceledClose" {
					resume.continuation.yield()
					await close.finish()
					#expect(store.littleWindows[id: littleID]?.isClosing == false)
				}
			}
		}
		holdsDispatch = false
		await store.send(action).finish()
		expectNoDifference(commands, change == "unchanged" ? [host == "main" ? organization.tabs[0].id : temporary.id] : [])
		resume.continuation.yield()
		await finishClose?()
	}
}
