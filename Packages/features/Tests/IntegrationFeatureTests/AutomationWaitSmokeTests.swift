import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _MCP
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
internal struct AutomationWaitSmokeTests {
	@Test(arguments: [nil, -105] as [Int?])
	internal func publicEnvelopePreservesHistoricalStoppedAndErrorObservation(error: Int?) async throws {
		let observation = try AutomationWaitSmoke.verify(
			AutomationWaitSmoke.decode(Self.response(error: error)),
			request: Self.request,
			profileID: .init(rawValue: UUID(1))
		)
		expectNoDifference(observation.errorCode, error)
		expectNoDifference(observation.documentRevision, UInt64.max)
		expectNoDifference(observation.observedRevision, String(repeating: "b", count: 64))

		var stale = Self.request
		stale.expectedRevision = String(repeating: "c", count: 64)
		#expect(throws: AutomationSmokeFailure.waitMismatch) {
			try AutomationWaitSmoke.verify(
				.observation(observation),
				request: stale,
				profileID: .init(rawValue: UUID(1))
			)
		}
	}

	@Test(arguments: [
		"trusted", "current", "navigationSuccess", "status", "numericEpoch",
		"changedText", "target", "profile", "revision",
	])
	internal func malformedOverstatedOrWrongSourceEvidenceIsRejected(change: String) async throws {
		#expect(throws: (any Error).self) {
			try AutomationWaitSmoke.verify(
				AutomationWaitSmoke.decode(Self.response(change: change)),
				request: Self.request,
				profileID: .init(rawValue: UUID(1))
			)
		}
	}

	@Test
	@MainActor
	internal func committedLoadingUsesLiveNavigationBeforeDurableRestorationChanges() async {
		let organization = IntegrationFeatureTests().fixture()
		let tab = organization.tabs[0]
		let pageURL = URL(string: "http://127.0.0.1/wait/main")!
		let navigation = BrowserNavigation(
			url: pageURL,
			title: "Arx wait committed",
			isLoading: true,
			history: [.init(id: 4, url: pageURL, title: "Arx wait committed", isCurrent: true)]
		)
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.viewer.item.navigation = navigation
		let store = TestStore(initialState: state) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.viewer(.item(.delegate(.navigation(tab.id, navigation)))))
		await store.finish()

		let snapshot = BrowserSessionSnapshot(navigation: navigation, revision: 3, documentRevision: 8)
		expectNoDifference(store.state.sidebar.organization.tabs[0].restoration.url, tab.restoration.url)
		#expect(tab.restoration.url != pageURL)
		#expect(AutomationWaitSmoke.isCommittedLoading(
			snapshot,
			viewer: store.state.viewer.item.navigation,
			url: pageURL
		))

		var provisional = snapshot
		provisional.documentRevision = nil
		#expect(!AutomationWaitSmoke.isCommittedLoading(provisional, viewer: navigation, url: pageURL))

		var uncommitted = snapshot
		uncommitted.navigation.history = []
		#expect(!AutomationWaitSmoke.isCommittedLoading(
			uncommitted,
			viewer: uncommitted.navigation,
			url: pageURL
		))

		var stopped = snapshot
		stopped.navigation.isLoading = false
		#expect(!AutomationWaitSmoke.isCommittedLoading(stopped, viewer: stopped.navigation, url: pageURL))
		#expect(!AutomationWaitSmoke.isCommittedLoading(snapshot, viewer: .init(), url: pageURL))
	}

	private static var request: AutomationWaitRequest {
		.init(targetID: UUID(2), expectedRevision: String(repeating: "a", count: 64))
	}

	private static func response(
		error: Int? = nil,
		change: String? = nil
	) throws -> CallTool.Result {
		var observation: [String: Value] = [
			"kind": .string("wait"),
			"condition": .string("loadingStopped"),
			"status": .string(error == nil ? "stopped" : "stoppedWithError"),
			"targetID": .string(request.targetID.uuidString),
			"profileID": .string(UUID(1).uuidString),
			"expectedRevision": .string(request.expectedRevision),
			"observedRevision": .string(String(repeating: "b", count: 64)),
			"sessionRevision": .string("4"),
			"documentRevision": .string(String(UInt64.max)),
			"historical": .bool(true),
			"navigationCompleted": .bool(false),
			"errorCode": error.map(Value.int) ?? .null,
		]
		switch change {
		case "current": observation["historical"] = .bool(false)
		case "navigationSuccess": observation["navigationCompleted"] = .bool(true)
		case "status": observation["status"] = .string("stoppedWithError")
		case "numericEpoch": observation["documentRevision"] = .int(8)
		case "target": observation["targetID"] = .string(UUID(9).uuidString)
		case "profile": observation["profileID"] = .string(UUID(9).uuidString)
		case "revision": observation["observedRevision"] = .string("invalid")
		default: break
		}

		let envelope: Value = .object([
			"untrustedData": .bool(change != "trusted"),
			"result": .object(observation),
		])
		let text = change == "changedText"
		? "{}"
		: String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)

		return .init(
			content: [.text(text: text, annotations: nil, _meta: nil)],
			structuredContent: Optional(envelope),
			isError: false
		)
	}
}
