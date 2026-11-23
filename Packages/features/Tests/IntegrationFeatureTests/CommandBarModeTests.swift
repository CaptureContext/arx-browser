import BrowserCore
import BrowserEngineClient
import CommandBarFeature
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct CommandBarModeTests {
	@Test
	internal func entryPointsPrioritizeDifferentResultsAndHideCommandsUntilAMatch() {
		let entries = candidates()
		let browsing = CommandBarFeature.State(mode: .newTab, candidates: entries)
		let commands = CommandBarFeature.State(mode: .commands, candidates: entries)
		let address = CommandBarFeature.State(mode: .currentTab, candidates: entries)

		expectNoDifference(browsing.entries.map(\.presentation.id), ["tab", "history"])
		expectNoDifference(commands.entries.map(\.presentation.id), ["command", "tab", "history"])
		expectNoDifference(address.entries.map(\.presentation.id), ["tab", "history"])

		// A command named exactly what's typed leads (DEV-1015), then the plain search (DEV-978).
		let matched = CommandBarFeature.State(query: "Sidebar", mode: .newTab, candidates: entries)
		expectNoDifference(Array(matched.entries.map(\.presentation.id).prefix(2)), ["command", "destination"])
		let partial = CommandBarFeature.State(query: "Sideb", mode: .newTab, candidates: entries)
		expectNoDifference(Array(partial.entries.map(\.presentation.id).prefix(2)), ["destination", "command"])
	}

	@Test
	internal func addressPrefillShowsSuggestionsUntilUserEditsAndRepeatedPresentationRefocuses() async {
		let url = "https://capturecontext.dev/current"
		let entries = candidates()
		let store = TestStore(initialState: CommandBarFeature.State()) { CommandBarFeature() }

		await store.send(.present(.currentTab, url, entries)) {
			$0.mode = .currentTab
			$0.isPresented = true
			$0.query = url
			$0.prefilledQuery = url
			$0.candidates = entries
			$0.selectedID = "tab"
			$0.focusRequest = 1
		}
		expectNoDifference(store.state.entries.first?.presentation.id, "tab")

		await store.send(.ui(.queryChanged("Older"))) {
			$0.query = "Older"
			$0.prefilledQuery = nil
			$0.selectedID = "history"
		}
		expectNoDifference(store.state.entries.map(\.presentation.id), ["history", "destination"])

		await store.send(.present(.commands, "", entries)) {
			$0.mode = .commands
			$0.query = ""
			$0.selectedID = "command"
			$0.focusRequest = 2
		}
	}

	@Test
	internal func liveHistoryIsDeduplicatedAndCannotCrossProfileBoundaries() {
		let organization = IntegrationFeatureTests().fixture()
		var state = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)
		state.viewer.item.tab = organization.tabs[0]
		state.viewer.item.navigation.history = [
			.init(
				id: 1,
				url: URL(string: "https://older.example")!,
				title: "Older",
				isCurrent: false
			),
			.init(
				id: 2,
				url: URL(string: "https://older.example")!,
				title: "Newer",
				isCurrent: false
			),
			.init(
				id: 3,
				url: URL(string: "about:blank")!,
				title: "Blank",
				isCurrent: false
			),
			.init(
				id: 4,
				url: organization.tabs[0].restoration.url,
				title: "Open",
				isCurrent: true
			)
		]

		// The open page is listed as history too, so it can be opened again (DEV-810).
		let history = state.commandCandidates.filter { $0.presentation.id.hasPrefix("history-") }
		expectNoDifference(history.map(\.presentation.title), ["Open", "Newer"])

		state.viewer.item.tab = .init(
			id: .init(rawValue: UUID(98)),
			profileID: .init(rawValue: UUID(99)),
			restoration: organization.tabs[0].restoration
		)
		#expect(!state.commandCandidates.contains { $0.presentation.id.hasPrefix("history-") })
	}

	@Test(arguments: [CommandBarFeature.Mode.currentTab, .commands])
	internal func addressAndCommandEntryNavigateTheExistingPage(mode: CommandBarFeature.Mode) async {
		let organization = IntegrationFeatureTests().fixture()
		var initial = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)
		initial.viewer.item.tab = organization.tabs[0]
		let url = URL(string: "https://destination.example")!
		var received: [BrowserEngineClient.Command] = []
		let store = Store(initialState: initial) { MainFeature() } withDependencies: {
			$0.browserEngine.command = { id, command in
				expectNoDifference(id, organization.tabs[0].id)
				received.append(command)
			}
		}

		await store.send(.ui(.openCommand(mode))).finish()
		await store.send(.commandBar(.ui(.queryChanged(url.absoluteString)))).finish()
		await store.send(.commandBar(.ui(.selected("destination")))).finish()
		expectNoDifference(received, [.navigate(url)])
		expectNoDifference(store.sidebar.organization, organization)
	}

	private func candidates() -> [CommandBarFeature.Entry] {
		[
			.init(
				presentation: .init(
					id: "tab",
					title: "Current",
					actionTitle: "Switch",
					symbol: "globe"
				),
				intent: .selectTab(.init(rawValue: UUID(1)))
			),
			.init(
				presentation: .init(
					id: "command",
					title: "Sidebar",
					actionTitle: "Command",
					symbol: "sidebar.left"
				),
				intent: .toggleSidebar
			),
			.init(
				presentation: .init(
					id: "history",
					title: "Older",
					actionTitle: "Open",
					symbol: "clock"
				),
				intent: .open(URL(string: "https://older.example")!)
			)
		]
	}
}
