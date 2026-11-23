import BrowserCore
import BrowserPageInspectionClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct BrowserInspectionCapabilityTests {
	@Test
	internal func retainedClientFollowsReadinessAndShutdown() async throws {
		let fixture = CapabilityFixture()
		let client = fixture.capabilities.inspection
		#expect(!client.isAvailable())
		await #expect(throws: AutomationFailure.notReady) {
			try await client.inspectAuthorized(fixture.request, fixture.source, { true })
		}
		fixture.running = true
		fixture.capabilities.activate()
		#expect(client.isAvailable())
		let snapshot = try await client.inspectAuthorized(fixture.request, fixture.source, { true })
		expectNoDifference(snapshot, fixture.snapshot)
		fixture.capabilities.stop()
		#expect(!client.isAvailable())
		#expect(!client.documentIsCurrent(fixture.result))
		await #expect(throws: AutomationFailure.notReady) {
			try await client.inspectAuthorized(fixture.request, fixture.source, { true })
		}
		expectNoDifference(fixture.calls, 1)
	}

	@Test(arguments: ["profile", "tab", "owner", "runtime"])
	internal func liveOwnershipChangesRejectHeldNativeReply(change: String) async throws {
		let fixture = CapabilityFixture()
		let client = fixture.capabilities.inspection
		fixture.running = true
		fixture.capabilities.activate()
		fixture.holdsReply = true
		let task = Task { try await client.inspectAuthorized(fixture.request, fixture.source, { true }) }
		try await fixture.waitForRead()

		switch change {
		case "profile":
			var workspace = try #require(fixture.owner?.workspace)
			workspace.profiles.removeAll()
			fixture.owner?.send(.delegate(.save(workspace)))

		case "tab":
			var workspace = try #require(fixture.owner?.workspace)
			workspace.tabs.removeAll()
			fixture.owner?.send(.delegate(.save(workspace)))

		case "owner":
			fixture.owner = nil

		default:
			fixture.running = false
		}
		fixture.continuation?.resume()
		fixture.continuation = nil
		await #expect(throws: AutomationFailure.denied) { try await task.value }
		#expect(!client.documentIsCurrent(fixture.result))
		expectNoDifference(fixture.calls, 1)
	}
}

@MainActor
private final class CapabilityFixture {
	fileprivate var running: Bool = false
	fileprivate var holdsReply: Bool = false
	fileprivate var calls: Int = 0
	fileprivate var continuation: CheckedContinuation<Void, Never>?
	fileprivate var capabilities: BrowserCapabilities!
	fileprivate var owner: StoreOf<AppFeature>?
	fileprivate let source: PageInspectionSource
	fileprivate let request: AutomationInspectionRequest
	fileprivate let snapshot: PageInspectionSnapshot

	fileprivate init() {
		let organization = IntegrationFeatureTests().fixture()
		let tab = organization.tabs[0]
		self.source = .init(
			tabID: tab.id,
			profileID: tab.profileID,
			sessionRevision: 3,
			documentRevision: 8,
			scopeID: UUID(99)
		)
		self.request = .init(targetID: tab.id.rawValue, expectedRevision: String(repeating: "a", count: 64))
		self.snapshot = .init(
			snapshotID: "snapshot",
			documentID: "document",
			frameID: "frame",
			domVersion: "4",
			nodes: [],
			omissions: PageInspectionOmission.allCases
		)
		self.capabilities = BrowserCapabilities(
			isRunning: { [weak self] in self?.running == true },
			capture: .init(),
			media: { .init() },
			extensions: { _ in .init() },
			inspection: .init(
				isAvailable: { true },
				inspectAuthorized: { [weak self] _, _, authorize in
					guard let self else { throw AutomationFailure.denied }
					self.calls += 1
					if self.holdsReply {
						await withCheckedContinuation { self.continuation = $0 }
					}
					guard authorize() else { throw AutomationFailure.denied }
					return self.snapshot
				},
				documentIsCurrent: { _ in true }
			)
		)
		self.owner = Store(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) {
			// This fixture changes only the live ownership input, isolating the capability boundary.
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if case let .delegate(.save(organization)) = action { state.workspace = organization }
				return .none
			}
		}
		self.capabilities.store = self.owner
	}

	fileprivate var result: AutomationInspectionResult { .init(request: request, source: source, snapshot: snapshot) }

	fileprivate func waitForRead() async throws {
		for _ in 0..<1000 {
			if continuation != nil { return }
			await Task.yield()
		}
		throw AutomationFailure.timedOut
	}
}
