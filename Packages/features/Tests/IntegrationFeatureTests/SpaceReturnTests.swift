@testable import AppFeature
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import Testing
import ViewerFeature
import _ComposableArchitecture
import _TestSupport

/// Returning to a space restores its presentation with exactly one selectSpace → resume → show
/// pass per affected window, so the restored observation is never replaced right away.
@MainActor
@Suite(.dependencies, .serialized)
internal struct SpaceReturnTests {
	@Test(arguments: [
		Scenario(preservesPresentation: false, hasSecondWindow: false, returnsInSecondWindow: false),
		Scenario(preservesPresentation: true, hasSecondWindow: false, returnsInSecondWindow: false),
		Scenario(preservesPresentation: true, hasSecondWindow: true, returnsInSecondWindow: false),
		Scenario(preservesPresentation: true, hasSecondWindow: true, returnsInSecondWindow: true),
		Scenario(preservesPresentation: false, hasSecondWindow: false, returnsInSecondWindow: false, presentsTab: true),
		Scenario(preservesPresentation: true, hasSecondWindow: true, returnsInSecondWindow: false, presentsTab: true),
	])
	internal func returningToASpaceShowsItsTabOnce(_ scenario: Scenario) async throws {
		var organization = IntegrationFeatureTests().fixture()
		let otherTab = BrowserCore.Tab(
			id: .init(rawValue: UUID(99)),
			profileID: organization.spaces[1].profileID,
			restoration: .init(title: "Other", url: URL(string: "https://other.example")!)
		)
		organization.tabs.append(otherTab)
		organization.spaces[1].unpinnedTabs.append(otherTab.id)
		organization.spaces[1].selectedTabID = otherTab.id

		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = organization.tabs[0]
		main.viewer.preservesPresentation = scenario.preservesPresentation
		var state = AppFeature.State(main: main)
		let windowID = UUID(70)
		if scenario.hasSecondWindow {
			// The second window shows the space's other tab, so both windows can return to it.
			var window = MainFeature.State(
				organization: organization,
				spaceID: organization.spaces[0].id,
				id: windowID
			)
			window.sidebar.select(organization.tabs[1].id)
			window.viewer.item.tab = organization.tabs[1]
			window.viewer.preservesPresentation = scenario.preservesPresentation
			state.windows.append(window)
		}
		let hostID = scenario.returnsInSecondWindow ? windowID : state.main.id
		let returning = scenario.returnsInSecondWindow ? organization.tabs[1] : organization.tabs[0]

		let passes = LockIsolated<[String]>([])
		let mainID = state.main.id
		let store = Store(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { _, action in
				if let label = Self.pass(action, hostID: hostID, mainID: mainID) {
					passes.withValue { $0.append(label) }
				}
				return .none
			}
			AppFeature()
		} withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}

		await store.send(Self.select(organization.spaces[1].id, in: hostID, mainID: state.main.id)).finish()
		passes.setValue([])
		if scenario.presentsTab {
			let host = hostID == store.main.id ? store.main : try #require(store.windows[id: hostID])
			let present = MainFeature.Action.present(returning.id, in: host.viewer.activePaneID)
			await store.send(hostID == mainID ? .main(present) : .windows(.element(id: hostID, action: present))).finish()
		} else {
			await store.send(Self.select(organization.spaces[0].id, in: hostID, mainID: state.main.id)).finish()
		}

		let host = hostID == store.main.id ? store.main : try #require(store.windows[id: hostID])
		#expect(host.viewer.spaceID == organization.spaces[0].id)
		#expect(host.viewer.item.tab?.id == returning.id)
		#expect(passes.value == ["selectSpace", "resume", "show"])
	}

	internal struct Scenario: Sendable, CustomTestStringConvertible {
		var preservesPresentation: Bool
		var hasSecondWindow: Bool
		var returnsInSecondWindow: Bool
		var presentsTab: Bool = false

		var testDescription: String {
			"preserves: \(preservesPresentation), second window: \(hasSecondWindow), "
			+ "returns there: \(returnsInSecondWindow), presents tab: \(presentsTab)"
		}
	}

	private static func select(
		_ spaceID: Space.ID,
		in hostID: UUID,
		mainID: UUID
	) -> AppFeature.Action {
		let action = MainFeature.Action.sidebar(.ui(.spaceSelected(spaceID)))
		return hostID == mainID ? .main(action) : .windows(.element(id: hostID, action: action))
	}

	/// The restoration steps the host's viewer goes through, in order.
	private static func pass(
		_ action: AppFeature.Action,
		hostID: UUID,
		mainID: UUID
	) -> String? {
		let viewer: ViewerFeature.Action
		switch action {
		case let .main(.viewer(value)) where hostID == mainID: viewer = value
		case let .windows(.element(id, .viewer(value))) where id == hostID: viewer = value
		default: return nil
		}

		switch viewer {
		case .selectSpace: return "selectSpace"
		case .resume: return "resume"
		case .show(.some, _), .item(.show(.some)), .panes(.element(_, .item(.show(.some)))): return "show"
		default: return nil
		}
	}
}
