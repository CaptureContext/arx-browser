import AppUI
import BrowserCore
import Foundation
import LittleArxFeature
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature
@testable import MainFeature

@Suite(.dependencies)
@MainActor
internal struct TabMoveAuthorizationTests {
	@Test(arguments: [false, true])
	internal func authorizesCapturedOrdinaryAndDormantSources(_ presented: Bool) throws {
		let state = try fixture(presented: presented)
		#expect(allowed(state))
		#expect(!state.canCommitTabMove(windowID: UUID(99), sourceIDs: [state.workspace.tabs[0].id]))
		#expect(!state.canCommitTabMove(windowID: state.main.id, sourceIDs: [state.workspace.tabs[1].id]))
		#expect(!state.canCommitTabMove(windowID: state.main.id, sourceIDs: []))
	}

	@Test(arguments: ["quit", "quitting", "closed", "private", "closing", "inactive", "missing", "peekClosing"])
	internal func rejectsUnavailableOrClosingHosts(_ reason: String) throws {
		var state = try fixture(isPrivate: reason == "private")
		switch reason {
		case "quit": state.checkingQuit = true
		case "quitting": state.shouldQuit = true
		case "closed": state.windowIsOpen = false
		case "private": break
		case "closing": state.main.isClosing = true
		case "inactive": state.main.transferInProgress = false
		case "missing": state.main.activeTabMove = nil
		default: state.closingPeekHosts.insert(state.main.id)
		}
		#expect(!allowed(state))
	}

	@Test(arguments: ["tree", "workspace", "selection", "generation", "pendingClose"])
	internal func rejectsChangedTransactionInputs(_ reason: String) throws {
		var state = try fixture()
		switch reason {
		case "tree": state.main.sidebar.organization.spaces[0].name = "Changed"
		case "workspace": state.workspace.spaces.removeLast()
		case "selection": state.main.sidebar.moveSelection = [.tab(state.workspace.tabs[1].id.rawValue)]
		case "generation": state.main.viewer.item.generation += 1
		default: state.main.pendingTabCloses.insert(state.workspace.tabs[0].id)
		}
		#expect(!allowed(state))
	}

	@Test
	internal func additionalWindowCanMoveOnlyItsOwnSources() throws {
		var state = try fixture()
		var additional = MainFeature.State(organization: state.workspace, spaceID: state.main.sidebar.spaceID, id: UUID(30))
		additional.activeTabMove = state.main.activeTabMove
		additional.activeTabMove?.sourcePresentations = [:]
		additional.transferInProgress = true
		state.windows.append(additional)
		let ids = [state.workspace.tabs[0].id]
		#expect(!state.canCommitTabMove(windowID: additional.id, sourceIDs: ids))
		state.main.activeTabMove = nil
		state.main.transferInProgress = false
		state.main.viewer.item.tab = nil
		#expect(state.canCommitTabMove(windowID: additional.id, sourceIDs: ids))
		state.windows.removeAll()
		#expect(!state.canCommitTabMove(windowID: additional.id, sourceIDs: ids))
	}

	@Test(arguments: ["presented", "closing", "transfer"])
	internal func rejectsSourceOwnedOrMutatedByAnotherWindow(_ reason: String) throws {
		var state = try fixture()
		var other = MainFeature.State(organization: state.workspace, spaceID: state.main.sidebar.spaceID, id: UUID(31))
		switch reason {
		case "presented": other.viewer.item.tab = state.workspace.tabs[0]
		case "closing": other.pendingTabCloses.insert(state.workspace.tabs[0].id)
		default: other.activeTabMove = state.main.activeTabMove
		}
		state.windows.append(other)
		#expect(!allowed(state))
	}

	@Test
	internal func unrelatedWindowAndItsCurrentSelectionDoNotBlockTransfer() throws {
		var state = try fixture()
		var other = MainFeature.State(organization: state.workspace, spaceID: state.main.sidebar.spaceID, id: UUID(32))
		other.viewer.item.tab = state.workspace.tabs[1]
		state.windows.append(other)
		state.workspace.spaces[0].selectedTabID = state.workspace.tabs[1].id
		state.workspace.tabs[1].restoration.title = "Unrelated navigation"
		#expect(allowed(state))
	}

	@Test(arguments: ["overlay", "borrowed", "source", "little"])
	internal func rejectsTemporaryPresentationOwnership(_ reason: String) throws {
		var state = try fixture()
		let moved = state.workspace.tabs[0]
		let unrelated = state.workspace.tabs[1]
		if reason == "little" {
			state.littleWindows.append(.init(id: UUID(33), spaceID: state.main.sidebar.spaceID, tab: moved))
		} else {
			let source: PeekFeature.Source = .init(
				windowID: reason == "overlay" ? state.main.id : UUID(35),
				paneID: UUID(36),
				tabID: reason == "source" ? moved.id : unrelated.id,
				spaceID: state.main.sidebar.spaceID,
				profileID: moved.profileID,
				identity: "Move test"
			)
			state.peeks.append(.init(
				id: UUID(34),
				source: source,
				tab: reason == "borrowed" ? moved : unrelated,
				isTemporary: reason != "borrowed"
			))
		}
		#expect(!allowed(state))
	}

	private func allowed(_ state: AppFeature.State) -> Bool {
		state.canCommitTabMove(windowID: state.main.id, sourceIDs: [state.workspace.tabs[0].id])
	}

	private func fixture(
		presented: Bool = true,
		isPrivate: Bool = false
	) throws -> AppFeature.State {
		var organization = IntegrationFeatureTests().fixture()
		let profile = Profile.ID(rawValue: UUID(90))
		let destination = Space.ID(rawValue: UUID(91))
		organization.profiles.append(.init(id: profile, name: "Other"))
		organization.spaces.append(.init(id: destination, profileID: profile, name: "Destination"))
		var main = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: isPrivate,
			id: UUID(92)
		)
		if presented { main.viewer.item.tab = organization.tabs[0] }
		let plan = try organization.moving(
			[.tab(organization.tabs[0].id)],
			to: .spaceRoot,
			in: destination,
			newTabID: { .init(rawValue: UUID(93)) }
		)
		main.activeTabMove = .init(
			id: UUID(94),
			plan: plan,
			selection: [],
			sourceSpace: main.sidebar.spaceID,
			selectedTab: main.sidebar.selectedTab?.id,
			sourcePresentations: main.movePresentations(for: plan)
		)
		main.transferInProgress = true
		return .init(main: main)
	}
}
