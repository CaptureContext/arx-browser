import BrowserAutomationClient
import BrowserCore
import BrowserMediaClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct AutomationMediaFeatureTests {
	@Test
	internal func listReturnsOnlyPermittedOrdinarySessions() async throws {
		let fixture = try MediaFixture()
		await fixture.send(try fixture.request(.list)).finish()
		guard case let .media(result) = try #require(fixture.responses.last) else {
			Issue.record("List didn't return sessions")
			return
		}

		expectNoDifference(result.sessions, [
			.init(
				targetID: fixture.tab.id.rawValue,
				token: "7.2",
				title: "Fixture video",
				playback: .playing,
				hasVideo: true,
				isInPictureInPicture: false,
				actions: [.pause, .enterPictureInPicture, .seek]
			),
		])
		expectNoDifference(fixture.performed, [])
		#expect(fixture.store.automation.pending.isEmpty)
	}

	@Test(arguments: [AutomationApprovalPolicy.alwaysAsk, .destructiveOnly])
	internal func controlsFollowTheApprovalPolicy(policy: AutomationApprovalPolicy) async throws {
		let fixture = try MediaFixture(approvalPolicy: policy)
		let request = try fixture.request(.pause)
		await fixture.send(request).finish()
		if policy == .alwaysAsk {
			expectNoDifference(fixture.performed, [])
			expectNoDifference(fixture.store.automation.pending[request.id]?.awaitingApproval, true)
			await fixture.store.send(.automation(.ui(.approve(request.id)))).finish()
		}

		expectNoDifference(fixture.performed, [
			BrowserMediaRequest(source: fixture.source, action: .pause),
		])
		guard case let .media(result) = try #require(fixture.responses.last) else {
			Issue.record("Control didn't report its outcome")
			return
		}
		expectNoDifference(result, .init(action: .pause, operationID: UUID(90), performed: true))
	}

	@Test(arguments: [
		AutomationMediaRequest.Action.play,
		.exitPictureInPicture,
	])
	internal func unavailableActionsReportUnsupportedWithoutGuessing(action: AutomationMediaRequest.Action) async throws {
		let fixture = try MediaFixture(approvalPolicy: .never)
		await fixture.send(try fixture.request(action)).finish()
		expectNoDifference(fixture.performed, [])
		expectNoDifference(
			fixture.responses,
			[.media(.init(action: action, operationID: UUID(90), failure: .unsupported))]
		)
	}

	@Test(arguments: ["staleToken", "foreignTab", "grant", "unavailable", "busy", "engineStale", "unattended"])
	internal func refusedControlsNeverReachTheEngineOrReportWhy(reason: String) async throws {
		let fixture = try MediaFixture(
			approvalPolicy: reason == "unattended" ? .alwaysAsk : .never,
			allowsInteract: reason != "grant",
			mediaAvailable: reason != "unavailable",
			mediaCommandPending: reason == "busy"
		)
		var request = try fixture.request(.pause)
		switch reason {
		case "staleToken":
			request.operation = try fixture.request(.pause, token: "7.1").operation

		case "foreignTab":
			guard case var .media(media) = request.operation else { return }
			media.targetID = fixture.other.id.rawValue
			request.operation = .media(media)

		case "engineStale":
			fixture.engineFailure = .staleSource

		case "unattended":
			await fixture.store.send(.automation(.ui(.unattended))).finish()

		default: break
		}
		await fixture.send(request).finish()

		let expected: AutomationResult = switch reason {
		case "staleToken": .media(.init(action: .pause, operationID: UUID(90), failure: .staleTarget))
		case "engineStale": .media(.init(action: .pause, operationID: UUID(90), failure: .staleTarget))
		case "foreignTab", "grant": .failure(.denied)
		case "unavailable": .failure(.unsupported)
		case "busy": .failure(.busy)
		default: .failure(.userActionRequired)
		}
		expectNoDifference(fixture.responses, [expected])
		if reason != "engineStale" {
			expectNoDifference(fixture.performed, [])
		}
	}

	@Test
	internal func seekSendsTheApprovedTimeToTheExactSource() async throws {
		let fixture = try MediaFixture(approvalPolicy: .never)
		await fixture.send(try fixture.request(.seek, seconds: 1.25)).finish()
		expectNoDifference(fixture.performed, [BrowserMediaRequest(source: fixture.source, seekingTo: 1.25)])
		expectNoDifference(
			fixture.responses,
			[.media(.init(action: .seek, operationID: UUID(90), performed: true))]
		)
	}

	@Test
	internal func seekingMediaWithoutSeekToReportsUnsupported() async throws {
		let fixture = try MediaFixture(approvalPolicy: .never, seekable: false)
		await fixture.send(try fixture.request(.seek, seconds: 1)).finish()
		expectNoDifference(fixture.performed, [])
		expectNoDifference(
			fixture.responses,
			[.media(.init(action: .seek, operationID: UUID(90), failure: .unsupported))]
		)
	}

	@Test(arguments: [AutomationMediaRequest.Action.mute, .unmute])
	internal func muteActsOnTheTabAfterApproval(action: AutomationMediaRequest.Action) async throws {
		let fixture = try MediaFixture()
		let request = try fixture.request(action)
		await fixture.send(request).finish()
		expectNoDifference(fixture.muted, [])
		expectNoDifference(fixture.store.automation.pending[request.id]?.awaitingApproval, true)

		await fixture.store.send(.automation(.ui(.approve(request.id)))).finish()
		expectNoDifference(fixture.muted, [MediaFixture.Mute(tabID: fixture.tab.id, isMuted: action == .mute)])
		expectNoDifference(fixture.performed, [])
		expectNoDifference(
			fixture.responses,
			[.media(.init(action: action, operationID: UUID(90), performed: true))]
		)
	}

	@Test
	internal func muteOnAClosedPageReportsStaleTarget() async throws {
		let fixture = try MediaFixture(approvalPolicy: .never)
		fixture.engineFailure = .staleSource
		await fixture.send(try fixture.request(.mute)).finish()
		expectNoDifference(
			fixture.responses,
			[.media(.init(action: .mute, operationID: UUID(90), failure: .staleTarget))]
		)
	}

	@Test
	internal func positionIsReadOnceWithoutApprovalOrState() async throws {
		let fixture = try MediaFixture()
		fixture.position = .init(
			sourceID: fixture.source.id,
			isMuted: false,
			position: 0.75,
			duration: 2,
			playbackRate: 1
		)
		let before = fixture.store.media
		await fixture.send(try fixture.request(.position)).finish()
		expectNoDifference(fixture.positionReads, [fixture.tab.id])
		expectNoDifference(fixture.responses, [
			.media(.init(action: .position, position: .init(
				targetID: fixture.tab.id.rawValue,
				token: "7.2",
				isMuted: false,
				position: 0.75,
				duration: 2,
				playbackRate: 1
			))),
		])
		#expect(fixture.store.automation.pending.isEmpty)
		expectNoDifference(fixture.store.media, before)
	}

	@Test
	internal func aMutedTabWithoutASessionReportsOnlyItsSound() async throws {
		let fixture = try MediaFixture()

		// A source the snapshot doesn't have names no session, so no time is reported.
		fixture.position = .init(
			sourceID: .init(tabID: fixture.tab.id, profileID: fixture.tab.profileID, generation: 8),
			isMuted: true,
			position: 0.5
		)
		await fixture.send(try fixture.request(.position)).finish()
		expectNoDifference(fixture.responses, [
			.media(.init(action: .position, position: .init(targetID: fixture.tab.id.rawValue, token: nil, isMuted: true))),
		])
	}

	@Test(arguments: ["foreignTab", "noPage"])
	internal func positionReadsRefuseTabsTheyCannotRead(reason: String) async throws {
		let fixture = try MediaFixture()
		var request = try fixture.request(.position)
		if reason == "foreignTab" {
			guard case var .media(media) = request.operation else { return }
			media.targetID = fixture.other.id.rawValue
			request.operation = .media(media)
		}
		await fixture.send(request).finish()
		expectNoDifference(fixture.responses, [.failure(reason == "foreignTab" ? .denied : .unsupported)])
		if reason == "foreignTab" { expectNoDifference(fixture.positionReads, []) }
	}

	@Test
	internal func mediaControlsCannotBeBatchSteps() throws {
		let fixture = try MediaFixture()
		let step = try fixture.request(.pause).operation
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationBatchPlan(batchID: UUID(91), steps: [step]).validate()
		}
	}
}

@MainActor
private final class MediaFixture {
	fileprivate let tab: BrowserCore.Tab
	fileprivate let other: BrowserCore.Tab
	fileprivate let source: BrowserMediaSource
	fileprivate var store: StoreOf<BrowserAutomation>!
	fileprivate var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	fileprivate var performed: [BrowserMediaRequest] = []
	fileprivate var responses: [AutomationResult] = []
	fileprivate var engineFailure: BrowserMediaClient.Failure?
	fileprivate var position: BrowserMediaPosition?
	fileprivate var positionReads: [BrowserCore.Tab.ID] = []
	fileprivate var muted: [Mute] = []
	private var requests: [UUID: AutomationRequest] = [:]

	fileprivate init(
		approvalPolicy: AutomationApprovalPolicy = .alwaysAsk,
		allowsInteract: Bool = true,
		mediaAvailable: Bool = true,
		mediaCommandPending: Bool = false,
		seekable: Bool = true
	) throws {
		let organization = IntegrationFeatureTests().fixture()
		self.tab = organization.tabs[0]
		self.other = organization.tabs[1]
		self.snapshots = [
			tab.id: .init(
				navigation: .init(url: tab.restoration.url),
				revision: 3,
				documentRevision: 8,
				isVisibleForCapture: true
			),
		]
		let source = BrowserMediaSource(
			id: .init(tabID: tab.id, profileID: tab.profileID, generation: 7),
			revision: 2,
			title: "Fixture video",
			site: nil,
			hasVideo: true,
			playback: .playing,
			actions: seekable
			? [.play, .pause, .enterPictureInPicture, .exitPictureInPicture, .seek]
			: [.play, .pause, .enterPictureInPicture, .exitPictureInPicture]
		)
		self.source = source
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture",
			credentialDigest: String(repeating: "a", count: 64),
			scopes: [.tab(tab.id, profileID: tab.profileID, location: .space(organization.spaces[0].id))],
			capabilities: allowsInteract ? [.read, .interact] : [.read],
			approvalPolicy: approvalPolicy,
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[UUID(81)] = client.id
		state.media.isAvailable = mediaAvailable
		if mediaCommandPending {
			state.media.pending = .init(
				id: UUID(96),
				request: .init(source: source, action: .pause),
				returnToSource: false
			)
		}
		state.media.snapshot = .init(revision: 1, sources: [
			source,
			// The other tab isn't granted, and private media is never listed.
			.init(
				id: .init(tabID: other.id, profileID: other.profileID, generation: 3),
				revision: 1,
				title: "Other",
				site: nil,
				playback: .paused,
				actions: [.play]
			),
			.init(
				id: .init(tabID: .init(rawValue: UUID(95)), profileID: tab.profileID, generation: 4),
				revision: 1,
				title: "Private",
				site: nil,
				isPrivate: true,
				playback: .playing,
				actions: [.pause]
			),
		])
		self.store = Store(initialState: state) { BrowserAutomation() } withDependencies: { [weak self] dependencies in
			dependencies.uuid = .incrementing
			dependencies.date.now = Date(timeIntervalSince1970: 100)
			dependencies.browserEngine.snapshot = { self?.snapshots[$0] }
			dependencies.browserMedia = .init(
				isAvailable: true,
				perform: { request in
					guard let self else { return }
					self.performed.append(request)
					if let failure = self.engineFailure { throw failure }
				},
				position: { tabID in
					guard let self else { return nil }
					self.positionReads.append(tabID)
					return self.position
				},
				setMuted: { tabID, isMuted in
					guard let self else { return }
					if let failure = self.engineFailure { throw failure }
					self.muted.append(.init(tabID: tabID, isMuted: isMuted))
				}
			)
			dependencies.automationControl.authorize = { id in
				guard let self else { return false }
				return self.store.state.automationCanExecute(id, snapshots: self.snapshots, now: Date(timeIntervalSince1970: 100))
			}
			dependencies.automationControl.respond = { id, result in
				guard let self, let request = self.requests[id] else { return }
				let failure = self.store.state.automationResponseValidation(request, result: result, snapshots: self.snapshots)
				self.responses.append(failure.map(AutomationResult.failure) ?? result)
			}
		}
	}

	fileprivate struct Mute: Equatable {
		fileprivate var tabID: BrowserCore.Tab.ID
		fileprivate var isMuted: Bool
	}

	fileprivate func request(
		_ action: AutomationMediaRequest.Action,
		token: String = "7.2",
		seconds: Double? = nil
	) throws -> AutomationRequest {
		let operation: AutomationMediaRequest
		if action == .list {
			operation = .init(action: .list)
		} else if action == .position {
			operation = .init(action: .position, targetID: tab.id.rawValue)
		} else {
			let client = store.automationPreferences.clients[0]
			let item = try #require(AutomationInventoryBuilder.items(
				client: client,
				organization: store.workspace,
				snapshots: snapshots
			).first { $0.id == tab.id.rawValue })
			operation = .init(
				action: action,
				targetID: tab.id.rawValue,
				expectedRevision: item.revision,
				operationID: UUID(90),
				token: action == .mute || action == .unmute ? nil : token,
				seconds: seconds
			)
		}
		return .init(
			id: UUID(84),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .media(operation)
		)
	}

	fileprivate func send(_ request: AutomationRequest) -> StoreTask {
		requests[request.id] = request
		return store.send(.automation(.event(.host(.request(request)))))
	}
}
