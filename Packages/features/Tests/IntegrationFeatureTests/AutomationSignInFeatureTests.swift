import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport
@testable import AppFeature

@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct AutomationSignInFeatureTests {
	@Test
	internal func consentDoesNotExposeSensitiveHandoffBeforeExactPersistedLockAcknowledgment() async throws {
		let fixture = Fixture()
		let original = fixture.store.persistedPreferences
		await fixture.store.send(.automation(.signIn(.ui(.approve(fixture.id))))).finish()
		#expect(fixture.store.state.automationPrivacyIsLocked)
		expectNoDifference(fixture.status, .securingPrivacy)

		await fixture.store.send(.event(.saveSucceeded(fixture.store.workspace, original))).finish()
		expectNoDifference(fixture.status, .securingPrivacy)

		var foreign = fixture.store.workspace
		foreign.spaces[0].name = "Other save"
		await fixture.store.send(.event(.saveSucceeded(foreign, fixture.store.persistedPreferences))).finish()
		expectNoDifference(fixture.status, .securingPrivacy)

		await fixture.acknowledge()
		expectNoDifference(fixture.status, .userActionRequired)
		await fixture.store.send(.automation(.signIn(.ui(.confirm(fixture.id))))).finish()
		expectNoDifference(fixture.status, .userConfirmed)
		#expect(fixture.store.state.automationPrivacyIsLocked)
	}

	@Test(arguments: ["replacement", "navigation", "origin", "profile", "grant", "unpublishedHost"])
	internal func swappedConsentSourceCannotActivateHandoff(change: String) async throws {
		let fixture = Fixture()
		switch change {
		case "replacement":
			fixture.snapshot.nativePageID = 99 // same epoch, different owner

		case "navigation":
			fixture.snapshot.documentRevision = 4

		case "origin":
			fixture.snapshot.navigation.url = URL(string: "https://foreign.example")

		case "profile":
			fixture.snapshot.nativeProfileID = .init(rawValue: UUID(999))

		case "unpublishedHost":
			var edited = fixture.store.workspace
			edited.spaces[0].name = "Unpublished host edit"
			fixture.store.send(.main(.reconcile(edited)))

		default:
			fixture.store.send(.automation(.ui(.revokeClient(fixture.clientID))))
		}
		await fixture.store.send(.automation(.signIn(.ui(.approve(fixture.id))))).finish()
		#expect(!fixture.store.state.automationPrivacyIsLocked)
		expectNoDifference(fixture.status, .cancelled)
	}

	@Test(arguments: ["failedSave", "uncertainNativeWork", "navigationAfterSave"])
	internal func failureOrUncertainNativeWorkKeepsPrivacyClosed(reason: String) async throws {
		let fixture = Fixture()
		if reason == "uncertainNativeWork" { fixture.uncertainDocuments[fixture.tab.id] = 3 }
		await fixture.store.send(.automation(.signIn(.ui(.approve(fixture.id))))).finish()
		if reason == "failedSave" {
			await fixture.store.send(.event(.saveFailed("Controlled write failure"))).finish()
		} else {
			if reason == "navigationAfterSave" { fixture.snapshot.documentRevision = 4 }
			await fixture.acknowledge()
		}
		#expect(fixture.store.state.automationPrivacyIsLocked)
		#expect(fixture.status != .userActionRequired)
	}

	@Test(arguments: ["otherTab", "samePage"])
	internal func uncertainNativeWorkBlocksOnlyTheBoundPageDocument(location: String) async throws {
		let fixture = Fixture()
		let other = fixture.store.workspace.tabs.first { $0.id != fixture.tab.id }!
		fixture.uncertainDocuments[location == "otherTab" ? other.id : fixture.tab.id] = 3
		await fixture.store.send(.automation(.signIn(.ui(.approve(fixture.id))))).finish()
		await fixture.acknowledge()
		expectNoDifference(fixture.status, location == "otherTab" ? .userActionRequired : .blocked)
		#expect(fixture.store.state.automationPrivacyIsLocked)
	}

	@Test
	internal func navigationReleasesAnEarlierUncertainDocumentForANewHandoff() async throws {
		let fixture = Fixture(seeded: false)
		fixture.uncertainDocuments[fixture.tab.id] = 3
		fixture.snapshot.documentRevision = 4

		await fixture.request(.begin(fixture.id, origin: "https://capturecontext.dev", revision: fixture.revision))
		expectNoDifference(fixture.responses, [.signIn(.init(operationID: fixture.id, status: .approvalRequired))])
		await fixture.store.send(.automation(.signIn(.ui(.approve(fixture.id))))).finish()
		await fixture.acknowledge()
		expectNoDifference(fixture.status, .userActionRequired)
	}

	@Test
	internal func resumeRequiresUniqueDurableAcknowledgmentAndDoesNotRestoreOldGrants() async throws {
		let fixture = Fixture()
		await fixture.store.send(.automation(.signIn(.ui(.approve(fixture.id))))).finish()
		await fixture.acknowledge()
		await fixture.store.send(.automation(.signIn(.ui(.confirm(fixture.id))))).finish()
		await fixture.store.send(.automation(.signIn(.ui(.keepClient(fixture.clientID, false))))).finish()

		var stale = fixture.store.persistedPreferences
		stale.automation.authenticationLockID = nil
		stale.automation.authenticationTransitionID = nil
		stale.automation.clients.removeAll()
		await fixture.store.send(.automation(.signIn(.ui(.resume)))).finish()
		#expect(fixture.store.automationPreferences.clients.isEmpty)
		#expect(fixture.store.state.automationHostPreferences.authenticationLockID != nil)

		await fixture.store.send(.event(.saveSucceeded(fixture.store.workspace, stale))).finish()
		#expect(fixture.store.state.automationPrivacyIsLocked)

		await fixture.acknowledge()
		#expect(!fixture.store.state.automationPrivacyIsLocked)
		#expect(fixture.store.automation.sessions.isEmpty && fixture.store.automation.signIn.records.isEmpty)
		#expect(fixture.store.automationPreferences.clients.isEmpty)
	}

	@Test
	internal func theRequesterStartsSelectedAndKeepsOnlyItsOriginalGrant() async throws {
		let fixture = Fixture()
		await fixture.store.send(.automation(.signIn(.ui(.keepClient(fixture.otherClientID, true))))).finish()
		#expect(fixture.store.automation.signIn.keptClientIDs.isEmpty) // No lock yet, so nothing to choose.

		await fixture.store.send(.automation(.signIn(.ui(.approve(fixture.id))))).finish()
		expectNoDifference(fixture.store.automation.signIn.keptClientIDs, [fixture.clientID])
		await fixture.acknowledge()
		await fixture.store.send(.automation(.signIn(.ui(.confirm(fixture.id))))).finish()

		let before = fixture.store.automationPreferences.clients.first { $0.id == fixture.clientID }!
		await fixture.store.send(.automation(.signIn(.ui(.resume)))).finish()
		await fixture.store.send(.automation(.signIn(.ui(.keepClient(fixture.otherClientID, true))))).finish()
		await fixture.acknowledge()

		#expect(!fixture.store.state.automationPrivacyIsLocked)
		#expect(fixture.store.automation.sessions.isEmpty)
		#expect(fixture.store.automation.signIn.keptClientIDs.isEmpty)
		let clients = fixture.store.automationPreferences.clients
		expectNoDifference(clients.map(\.id), [fixture.clientID])
		#expect(clients[0].grantRevision != before.grantRevision)
		var unchanged = clients[0]
		unchanged.grantRevision = before.grantRevision
		expectNoDifference(unchanged, before)
	}

	@Test
	internal func aSecondClientIsKeptOnlyWhenTheUserChoosesIt() async throws {
		let fixture = Fixture()
		await fixture.store.send(.automation(.signIn(.ui(.approve(fixture.id))))).finish()
		await fixture.acknowledge()
		await fixture.store.send(.automation(.signIn(.ui(.confirm(fixture.id))))).finish()
		await fixture.store.send(.automation(.signIn(.ui(.keepClient(fixture.clientID, false))))).finish()
		await fixture.store.send(.automation(.signIn(.ui(.keepClient(fixture.otherClientID, true))))).finish()

		await fixture.store.send(.automation(.signIn(.ui(.resume)))).finish()
		await fixture.acknowledge()

		expectNoDifference(fixture.store.automationPreferences.clients.map(\.id), [fixture.otherClientID])
	}

	@Test
	internal func beginBindsTheExactSourceAndOnlyItsConnectionReadsStatus() async throws {
		let fixture = Fixture(seeded: false)
		let operation = UUID(760)

		await fixture.request(.begin(operation, origin: "https://foreign.example", revision: fixture.revision))
		await fixture.request(.begin(operation, origin: "https://capturecontext.dev", revision: String(repeating: "b", count: 64)))
		expectNoDifference(fixture.responses, [.failure(.staleTarget), .failure(.staleTarget)])
		#expect(fixture.store.automation.signIn.records.isEmpty)

		await fixture.request(.begin(operation, origin: "https://capturecontext.dev", revision: fixture.revision))
		await fixture.request(.status(operation))
		await fixture.request(.status(operation), sessionID: fixture.otherSessionID, clientID: fixture.otherClientID)
		await fixture.request(.begin(UUID(761), origin: "https://capturecontext.dev", revision: fixture.revision))
		expectNoDifference(fixture.responses.suffix(4), [
			.signIn(.init(operationID: operation, status: .approvalRequired)),
			.signIn(.init(operationID: operation, status: .approvalRequired)),
			.failure(.denied),
			.failure(.busy),
		])
		#expect(!fixture.store.state.automationPrivacyIsLocked)

		await fixture.request(.cancel(operation))
		expectNoDifference(fixture.responses.last, .signIn(.init(operationID: operation, status: .cancelled)))
		await fixture.store.send(.automation(.signIn(.ui(.approve(operation))))).finish()
		#expect(!fixture.store.state.automationPrivacyIsLocked)
	}

	@Test
	internal func clientWithoutTheSignInGrantIsDenied() async throws {
		let fixture = Fixture(seeded: false, otherAllowsSignIn: false)
		await fixture.request(
			.begin(UUID(762), origin: "https://capturecontext.dev", revision: fixture.revision(for: fixture.otherClientID)),
			sessionID: fixture.otherSessionID,
			clientID: fixture.otherClientID
		)
		expectNoDifference(fixture.responses, [.failure(.denied)])
		#expect(fixture.store.automation.signIn.records.isEmpty)
	}

	@Test
	internal func unattendedBeginNeverWaitsForConsent() async throws {
		let fixture = Fixture(seeded: false)
		fixture.store.send(.automation(.ui(.unattended)))
		await fixture.request(.begin(UUID(763), origin: "https://capturecontext.dev", revision: fixture.revision))
		expectNoDifference(fixture.responses, [.failure(.userActionRequired)])
		#expect(fixture.store.automation.signIn.records.isEmpty)
	}

	@Test
	internal func lifetimeExpiryEndsConsentWithoutLocking() async throws {
		let fixture = Fixture()
		fixture.now.setValue(Date(timeIntervalSince1970: 1_000))
		await fixture.store.send(.automation(.signIn(.event(.tick(fixture.id))))).finish()
		expectNoDifference(fixture.status, .expired)
		await fixture.store.send(.automation(.signIn(.ui(.approve(fixture.id))))).finish()
		#expect(!fixture.store.state.automationPrivacyIsLocked)
	}

	@Test
	internal func userNavigationDuringSensitiveInputCancelsButKeepsPrivacyLocked() async throws {
		let fixture = Fixture()
		await fixture.store.send(.automation(.signIn(.ui(.approve(fixture.id))))).finish()
		await fixture.acknowledge()
		expectNoDifference(fixture.status, .userActionRequired)

		fixture.snapshot.documentRevision = 4
		await fixture.store.send(.automation(.signIn(.event(.tick(fixture.id))))).finish()
		expectNoDifference(fixture.status, .cancelled)
		await fixture.store.send(.automation(.signIn(.ui(.confirm(fixture.id))))).finish()
		expectNoDifference(fixture.status, .cancelled)
		#expect(fixture.store.state.automationPrivacyIsLocked)
	}

	@Test
	internal func protectedInteractionRefusesEveryOtherOperationFromEveryClient() async throws {
		let fixture = Fixture()
		await fixture.store.send(.automation(.signIn(.ui(.approve(fixture.id))))).finish()
		await fixture.acknowledge()

		let target = fixture.tab.id.rawValue
		await fixture.request(.inventory(cursor: nil, limit: 10))
		await fixture.request(.capture(.init(targetID: target, expectedRevision: fixture.revision, mode: .viewport)))
		await fixture.request(.inspect(.init(targetID: target, expectedRevision: fixture.revision)))
		await fixture.request(.inventory(cursor: nil, limit: 10), sessionID: fixture.otherSessionID, clientID: fixture.otherClientID)
		await fixture.request(.signIn(.init(operationID: fixture.id, action: .status)))
		expectNoDifference(fixture.responses, [
			.failure(.authenticationProtected),
			.failure(.authenticationProtected),
			.failure(.authenticationProtected),
			.failure(.authenticationProtected),
			.signIn(.init(operationID: fixture.id, status: .userActionRequired)),
		])
	}

	@MainActor
	private final class Fixture {
		internal let id: UUID = UUID(750)
		internal let clientID: UUID = UUID(751)
		internal let sessionID: UUID = UUID(752)
		internal let otherClientID: UUID = UUID(754)
		internal let otherSessionID: UUID = UUID(755)
		internal let tab: BrowserCore.Tab
		internal let now: LockIsolated<Date> = .init(Date(timeIntervalSince1970: 100))
		internal let replies: LockIsolated<[AutomationResult]> = .init([])
		internal var snapshot: BrowserSessionSnapshot

		/// Models the engine ledger: tab to the document epoch with an uncertain action.
		internal var uncertainDocuments: [BrowserCore.Tab.ID: UInt64] = [:]
		internal var store: StoreOf<AppFeature>!
		private var nextRequest: Int = 800

		internal init(
			seeded: Bool = true,
			otherAllowsSignIn: Bool = true
		) {
			let organization = IntegrationFeatureTests().fixture()
			let tab = organization.tabs[0]
			let grant = UUID(753)
			self.tab = tab
			self.snapshot = .init(
				navigation: .init(url: URL(string: "https://capturecontext.dev/login?next=1")),
				revision: 8,
				documentRevision: 3,
				isVisibleForCapture: true,
				nativePageID: 7,
				nativeProfileID: tab.profileID
			)
			var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
			let scopes: [AutomationScope] = [.space(organization.spaces[0].id, profileID: tab.profileID)]
			state.automationPreferences = .init(isEnabled: true, clients: [
				.init(
					id: clientID,
					name: "Controlled",
					credentialDigest: String(repeating: "a", count: 64),
					scopes: scopes,
					allowsRead: true,
					allowsScreenshots: true,
					allowsPageContent: true,
					allowsSignIn: true,
					grantRevision: grant
				),
				.init(
					id: otherClientID,
					name: "Second",
					credentialDigest: String(repeating: "c", count: 64),
					scopes: scopes,
					allowsRead: true,
					allowsScreenshots: true,
					allowsPageContent: true,
					allowsSignIn: otherAllowsSignIn,
					grantRevision: UUID(756)
				),
			])
			state.automation.sessions[sessionID] = clientID
			state.automation.sessions[otherSessionID] = otherClientID
			if seeded {
				state.automation.signIn.records[id] = .init(
					request: .init(
						operationID: id,
						action: .begin,
						targetID: tab.id.rawValue,
						expectedRevision: String(repeating: "a", count: 64),
						origin: "https://capturecontext.dev"
					),
					clientID: clientID,
					sessionID: sessionID,
					grantRevision: grant,
					profileID: tab.profileID,
					tabID: tab.id,
					nativePageID: 7,
					documentRevision: 3,
					sessionRevision: 8,
					status: .approvalRequired,
					expiresAt: Date(timeIntervalSince1970: 1_000)
				)
			}
			self.store = Store(initialState: state) { AppFeature() } withDependencies: { [weak self, now, replies] in
				$0.uuid = .incrementing
				$0.date = .init { now.value }
				$0.continuousClock = TestClock()
				$0.browserEngine.snapshot = { _ in self?.snapshot }
				$0.browserEngine.referenceSubmissionsAreSettled = { id in
					guard let self
					else { return false }
					return self.uncertainDocuments[id] != self.snapshot.documentRevision
				}
				$0.browserEngine.open = { _ in }
				$0.automationControl.revoke = { _ in }
				$0.automationControl.respond = { _, result in replies.withValue { $0.append(result) } }
			}
		}

		internal var status: AutomationSignInResult.Status? { store.automation.signIn.records[id]?.status }

		internal var responses: [AutomationResult] { replies.value }

		internal var revision: String { revision(for: clientID) }

		internal func revision(for client: UUID) -> String {
			let client = store.automationPreferences.clients.first { $0.id == client }!
			return AutomationInventoryBuilder.items(client: client, organization: store.workspace, snapshots: [tab.id: snapshot])
				.first { $0.id == tab.id.rawValue }!.revision
		}

		internal func acknowledge() async {
			await store.send(.event(.saveSucceeded(store.workspace, store.persistedPreferences))).finish()
		}

		internal func request(
			_ operation: AutomationOperation,
			sessionID: UUID? = nil,
			clientID: UUID? = nil
		) async {
			nextRequest += 1
			let request: AutomationRequest = .init(
				id: UUID(nextRequest),
				clientID: clientID ?? self.clientID,
				sessionID: sessionID ?? self.sessionID,
				operation: operation
			)
			let count = replies.value.count
			store.send(.automation(.event(.host(.request(request)))))

			// Generous for a loaded parallel test run; replies normally arrive within milliseconds.
			let end = ContinuousClock.now.advanced(by: .seconds(40))
			while replies.value.count == count, ContinuousClock.now < end {
				await Task.yield()
				try? await Task.sleep(for: .milliseconds(5))
			}
		}
	}
}

extension AutomationOperation {
	@MainActor
	fileprivate static func begin(
		_ id: UUID,
		origin: String,
		revision: String
	) -> Self {
		.signIn(.init(
			operationID: id,
			action: .begin,
			targetID: IntegrationFeatureTests().fixture().tabs[0].id.rawValue,
			expectedRevision: revision,
			origin: origin
		))
	}

	fileprivate static func status(_ id: UUID) -> Self {
		.signIn(.init(operationID: id, action: .status))
	}

	fileprivate static func cancel(_ id: UUID) -> Self {
		.signIn(.init(operationID: id, action: .cancel))
	}
}
