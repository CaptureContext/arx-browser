import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct AutomationRoutingTests {
	private static let url = URL(string: "https://routed.example/docs")!

	@Test
	internal func defaultOpenTabIgnoresRoutingRules() async throws {
		let state = fixture()
		state.settings.$routingPreferences.withLock { $0 = .init(
			rules: [rule(to: .space(state.workspace.spaces[1].id))],
			fallback: .init(scope: .space(state.workspace.spaces[1].id), mode: .mainBrowser)
		) }
		let command = try command(route: false, state: state)
		let (store, responses) = try await run(command, state: state)

		let tab = try #require(store.workspace.tabs.last)
		expectNoDifference(store.workspace.location(of: tab.id), .unpinned(state.workspace.spaces[0].id))
		expectNoDifference(responses(), [.command(.init(
			operationID: command.operationID,
			status: .acceptedLoading,
			targetID: tab.id.rawValue
		))])
	}

	@Test
	internal func routedOpenTabFollowsTheFirstMatchingRule() async throws {
		let state = fixture()
		let destination = state.workspace.spaces[1]
		let matching = rule(to: .space(destination.id))
		state.settings.$routingPreferences.withLock { $0 = .init(
			rules: [
				.init(id: UUID(60), name: "Other", host: "other.example", destination: .init(scope: .currentSpace)),
				matching,
			],
			fallback: .init(scope: .currentSpace, mode: .mainBrowser)
		) }
		let command = try command(route: true, state: state)
		let (store, responses) = try await run(command, state: state)

		let tab = try #require(store.workspace.tabs.last)
		expectNoDifference(tab.profileID, destination.profileID)
		expectNoDifference(store.workspace.location(of: tab.id), .unpinned(destination.id))
		expectNoDifference(responses(), [.command(.init(
			operationID: command.operationID,
			status: .acceptedLoading,
			targetID: tab.id.rawValue,
			route: .init(
				profileID: destination.profileID.rawValue,
				spaceID: destination.id.rawValue,
				mode: .mainBrowser,
				source: .rule,
				ruleID: matching.id,
				ruleName: matching.name
			)
		))])
	}

	@Test
	internal func routedOpenTabFallsBackToTheSourceSpace() async throws {
		let state = fixture()
		state.settings.$routingPreferences.withLock { $0 = .init(
			rules: [.init(id: UUID(60), name: "Other", host: "other.example", destination: .init(scope: .currentSpace))],
			fallback: .init(scope: .currentSpace, mode: .mainBrowser)
		) }

		// The routed source is the explicit target, not the space the main window shows.
		let source = state.workspace.spaces[1]
		let command = try command(route: true, targetID: source.id.rawValue, state: state)
		let (store, responses) = try await run(command, state: state)

		let tab = try #require(store.workspace.tabs.last)
		expectNoDifference(store.workspace.location(of: tab.id), .unpinned(source.id))
		expectNoDifference(responses(), [.command(.init(
			operationID: command.operationID,
			status: .acceptedLoading,
			targetID: tab.id.rawValue,
			route: .init(
				profileID: source.profileID.rawValue,
				spaceID: source.id.rawValue,
				mode: .mainBrowser,
				source: .fallback
			)
		))])
	}

	@Test
	internal func focusedPrivateWindowIsNeverTheRoutedSource() async throws {
		var state = fixture()
		let privateProfile = Profile.ID(rawValue: UUID(90))
		let privateSpace = Space.ID(rawValue: UUID(91))
		let privateWindow = MainFeature.State(
			organization: .init(
				profiles: [.init(id: privateProfile, name: "Private")],
				spaces: [.init(id: privateSpace, profileID: privateProfile, name: "Private")]
			),
			spaceID: privateSpace,
			isPrivate: true,
			id: UUID(92)
		)
		state.windows.append(privateWindow)
		state.focusedWindowID = privateWindow.id
		state.settings.$routingPreferences.withLock { $0 = .init(fallback: .init(scope: .currentSpace, mode: .mainBrowser)) }
		let command = try command(route: true, state: state)
		let (store, responses) = try await run(command, state: state)

		let tab = try #require(store.workspace.tabs.last)
		expectNoDifference(store.workspace.location(of: tab.id), .unpinned(state.workspace.spaces[0].id))
		expectNoDifference(store.windows[id: privateWindow.id]?.sidebar.organization, privateWindow.sidebar.organization)
		guard case let .command(response) = responses().last else {
			Issue.record("No routed receipt")
			return
		}
		expectNoDifference(response.route?.spaceID, state.workspace.spaces[0].id.rawValue)
		expectNoDifference(response.route?.source, .fallback)
	}

	@Test
	internal func ruleNamingAPrivateSpaceIsUnresolved() async throws {
		var state = fixture()
		let privateProfile = Profile.ID(rawValue: UUID(90))
		let privateSpace = Space.ID(rawValue: UUID(91))
		state.windows.append(MainFeature.State(
			organization: .init(
				profiles: [.init(id: privateProfile, name: "Private")],
				spaces: [.init(id: privateSpace, profileID: privateProfile, name: "Private")]
			),
			spaceID: privateSpace,
			isPrivate: true,
			id: UUID(92)
		))
		state.settings.$routingPreferences.withLock { $0 = .init(rules: [rule(to: .space(privateSpace))]) }
		let command = try command(route: true, state: state)
		let (store, responses) = try await run(command, state: state)

		expectNoDifference(store.workspace, state.workspace)
		expectNoDifference(responses(), [.failure(.routeUnresolved)])
	}

	@Test
	internal func missingFallbackIsUnresolved() async throws {
		let state = fixture()
		state.settings.$routingPreferences.withLock { $0 = .init(fallback: nil) }
		let command = try command(route: true, state: state)
		let (store, responses) = try await run(command, state: state)

		expectNoDifference(store.workspace, state.workspace)
		expectNoDifference(responses(), [.failure(.routeUnresolved)])
	}

	@Test
	internal func routedSpaceNeedsItsOwnGrant() async throws {
		var state = fixture()
		state.automationPreferences.clients[0].scopes.removeLast()
		state.settings.$routingPreferences.withLock { $0 = .init(rules: [rule(to: .space(state.workspace.spaces[1].id))]) }
		let command = try command(route: true, state: state)
		let (store, responses) = try await run(command, state: state)

		expectNoDifference(store.workspace, state.workspace)
		expectNoDifference(responses(), [.failure(.denied)])
	}

	@Test(arguments: [false, true])
	internal func littleArxDestinationNeedsAForegroundAttendedRequest(unattended: Bool) async throws {
		var state = fixture()
		state.automation.isUnattended = unattended
		state.settings.$routingPreferences.withLock { $0 = .init(fallback: .init(scope: .currentSpace, mode: .littleArx)) }

		// An attended background request and an unattended foreground one are both refused.
		let command = try command(route: true, focus: unattended, state: state)
		let (store, responses) = try await run(command, state: state)

		expectNoDifference(store.workspace, state.workspace)
		#expect(store.littleWindows.isEmpty)
		expectNoDifference(responses(), [.failure(.unsupported)])
	}

	@Test
	internal func littleArxDestinationOpensALittleArx() async throws {
		var state = fixture()
		state.windowIsOpen = true
		let destination = state.workspace.spaces[1]
		let matching = rule(to: .space(destination.id), mode: .littleArx)
		state.settings.$routingPreferences.withLock { $0 = .init(rules: [matching]) }
		let command = try command(route: true, focus: true, state: state)
		let (store, responses) = try await run(command, state: state)

		expectNoDifference(store.workspace, state.workspace)
		let little = try #require(store.littleWindows.first)
		expectNoDifference(little.spaceID, destination.id)
		expectNoDifference(little.tab.profileID, destination.profileID)
		guard case let .command(response) = responses().last else {
			Issue.record("No routed Little Arx receipt")
			return
		}
		expectNoDifference(response.presentation?.kind, .littleArx)
		expectNoDifference(response.route, .init(
			profileID: destination.profileID.rawValue,
			spaceID: destination.id.rawValue,
			mode: .littleArx,
			source: .rule,
			ruleID: matching.id,
			ruleName: matching.name
		))
	}

	@Test
	internal func routeIsOnlyForOpenTabWithoutDestination() throws {
		let revision = String(repeating: "a", count: 64)
		let url = Self.url
		let routedNavigation = AutomationCommand(
			operationID: UUID(1),
			action: .navigate,
			targetID: UUID(2),
			expectedRevision: revision,
			url: url,
			route: true
		)
		let routedDestination = AutomationCommand(
			operationID: UUID(1),
			action: .openTab,
			targetID: UUID(2),
			expectedRevision: revision,
			destinationID: UUID(3),
			destinationRevision: revision,
			url: url,
			route: true
		)
		#expect(throws: AutomationFailure.invalidRequest) { try routedNavigation.validate() }
		#expect(throws: AutomationFailure.invalidRequest) { try routedDestination.validate() }
	}

	@Test
	internal func crossProfilePinIsRefusedPrecisely() async throws {
		// moveTab reopens in another profile; pinning into another profile's space stays refused.
		var state = fixture()
		let profile = Profile.ID(rawValue: UUID(93))
		let space = Space.ID(rawValue: UUID(94))
		state.workspace.profiles.append(.init(id: profile, name: "Other"))
		state.workspace.spaces.append(.init(id: space, profileID: profile, name: "Elsewhere"))
		state.main.sidebar.organization = state.workspace
		state.automationPreferences.clients[0].scopes.append(.space(space, profileID: profile))
		let client = state.automationPreferences.clients[0]
		let items = AutomationInventoryBuilder.items(client: client, organization: state.workspace, snapshots: [:])
		let target = try #require(items.first { $0.id == state.workspace.tabs[0].id.rawValue })
		let destination = try #require(items.first { $0.id == space.rawValue })
		let command = AutomationCommand(
			operationID: UUID(83),
			action: .pinTab,
			targetID: target.id,
			expectedRevision: target.revision,
			destinationID: destination.id,
			destinationRevision: destination.revision
		)
		let (store, responses) = try await run(command, state: state)

		expectNoDifference(store.workspace, state.workspace)
		expectNoDifference(responses(), [.failure(.crossProfileTransferUnsupported)])
		#expect(AutomationFailure.crossProfileTransferUnsupported.message?.contains("move it") == true)
	}

	// MARK: - Fixture

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture client",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: organization.spaces.map { .space($0.id, profileID: $0.profileID) },
			allowsRead: true,
			allowsManagement: true,
			mutationGrantUntil: Date(timeIntervalSince1970: 200),
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[UUID(81)] = client.id
		return state
	}

	private func rule(
		to scope: RoutingDestination.Scope,
		mode: RoutingWindowMode = .mainBrowser
	) -> RoutingRule {
		.init(id: UUID(61), name: "Docs", host: "routed.example", destination: .init(scope: scope, mode: mode))
	}

	private func command(
		route: Bool,
		targetID: UUID? = nil,
		focus: Bool = false,
		state: AppFeature.State
	) throws -> AutomationCommand {
		let client = state.automationPreferences.clients[0]
		let items = AutomationInventoryBuilder.items(client: client, organization: state.workspace, snapshots: [:])
		let target = try #require(items.first { $0.id == (targetID ?? state.workspace.spaces[0].id.rawValue) })
		return .init(
			operationID: UUID(83),
			action: .openTab,
			targetID: target.id,
			expectedRevision: target.revision,
			url: Self.url,
			focus: focus,
			route: route
		)
	}

	private func run(
		_ command: AutomationCommand,
		state: AppFeature.State
	) async throws -> (StoreOf<AppFeature>, () -> [AutomationResult]) {
		let responses = LockIsolated<[AutomationResult]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.automationControl.respond = { _, value in responses.withValue { $0.append(value) } }
			$0.automationControl.authorize = { _ in true }
			$0.browserEngine.snapshot = { _ in nil }
			$0.browserEngine.openAuthorized = { _, authorize in
				guard authorize() else { throw AutomationFailure.denied }
			}
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
		}
		let request = AutomationRequest(id: UUID(84), clientID: UUID(80), sessionID: UUID(81), operation: .command(command))
		await store.send(.automation(.event(.host(.request(request))))).finish()
		return (store, { responses.value })
	}
}
