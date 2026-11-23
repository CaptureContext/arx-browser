import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct AutomationLoadFeatureTests {
	@Test
	internal func backgroundLoadOpensThePageWithoutChangingPresentation() async throws {
		let fixture = LoadFixture()
		let before = fixture.store.state
		await fixture.send(try fixture.request()).finish()

		expectNoDifference(fixture.responses, [.load(.init(targetID: fixture.tab.id.rawValue, status: .loading))])
		expectNoDifference(fixture.opened, [fixture.tab.id])
		expectNoDifference(fixture.store.workspace, before.workspace)
		expectNoDifference(fixture.store.main, before.main)
		expectNoDifference(fixture.store.windows, before.windows)
		expectNoDifference(fixture.store.focusedWindowID, before.focusedWindowID)
		expectNoDifference(fixture.store.windowIsOpen, before.windowIsOpen)
		#expect(fixture.store.automation.pending.isEmpty)
		#expect(fixture.store.automation.activity.allSatisfy { $0.operation == "load" && $0.outcome == "loading" })
	}

	@Test
	internal func anExistingPageIsNotOpenedAgain() async throws {
		let fixture = LoadFixture()
		fixture.snapshots[fixture.tab.id] = .init(
			navigation: .init(url: fixture.tab.restoration.url),
			revision: 3,
			documentRevision: 8
		)
		await fixture.send(try fixture.request()).finish()

		expectNoDifference(fixture.responses, [.load(.init(targetID: fixture.tab.id.rawValue, status: .alreadyLoaded))])
		expectNoDifference(fixture.opened, [])
	}

	@Test(arguments: ["grant", "foreign", "revision"])
	internal func deniedOrStaleTargetsNeverLoad(reason: String) async throws {
		let fixture = LoadFixture(pageContentAllowed: reason != "grant")
		var request = try fixture.request()
		guard case var .load(load) = request.operation else { return }
		switch reason {
		case "foreign": load.targetID = fixture.other.id.rawValue
		case "revision": load.expectedRevision = String(repeating: "b", count: 64)
		default: break
		}
		request.operation = .load(load)
		await fixture.send(request).finish()

		let failure: AutomationFailure = reason == "revision" ? .staleTarget : .denied
		expectNoDifference(fixture.responses, [.failure(failure)])
		expectNoDifference(fixture.opened, [])
	}
}

@MainActor
private final class LoadFixture {
	fileprivate let tab: BrowserCore.Tab
	fileprivate let other: BrowserCore.Tab
	fileprivate var store: StoreOf<BrowserAutomation>!
	fileprivate var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot] = [:]
	fileprivate var opened: [BrowserCore.Tab.ID] = []
	fileprivate var responses: [AutomationResult] = []
	private var requests: [UUID: AutomationRequest] = [:]

	fileprivate init(pageContentAllowed: Bool = true) {
		let organization = IntegrationFeatureTests().fixture()
		self.tab = organization.tabs[0]
		self.other = organization.tabs[1]
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture",
			credentialDigest: String(repeating: "a", count: 64),
			scopes: [.tab(tab.id, profileID: tab.profileID, location: .space(organization.spaces[0].id))],
			allowsRead: true,
			allowsPageContent: pageContentAllowed,
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[UUID(81)] = client.id
		self.store = Store(initialState: state) { BrowserAutomation() } withDependencies: { [weak self] dependencies in
			dependencies.uuid = .incrementing
			dependencies.date.now = Date(timeIntervalSince1970: 100)
			dependencies.browserEngine.snapshot = { self?.snapshots[$0] }
			dependencies.browserEngine.prepareProfile = { _ in }
			dependencies.browserEngine.openAuthorized = { tab, authorize in
				guard let self, authorize() else { throw AutomationFailure.denied }
				self.opened.append(tab.id)
			}
			dependencies.browserEngine.open = { _ in Issue.record("Load bypassed authorization") }
			dependencies.browserEngine.command = { _, _ in Issue.record("Load navigated or focused") }
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

	fileprivate func request() throws -> AutomationRequest {
		let client = store.automationPreferences.clients[0]
		let item = try #require(AutomationInventoryBuilder.items(
			client: client,
			organization: store.workspace,
			snapshots: snapshots
		).first { $0.id == tab.id.rawValue })
		return .init(
			id: UUID(84),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .load(.init(targetID: item.id, expectedRevision: item.revision))
		)
	}

	fileprivate func send(_ request: AutomationRequest) -> StoreTask {
		requests[request.id] = request
		return store.send(.automation(.event(.host(.request(request)))))
	}
}
