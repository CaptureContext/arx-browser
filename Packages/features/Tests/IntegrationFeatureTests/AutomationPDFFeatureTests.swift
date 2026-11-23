import BrowserAutomationClient
import BrowserCaptureClient
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
internal struct AutomationPDFFeatureTests {
	@Test
	internal func exportReturnsThePDFWithoutChangingPresentation() async throws {
		let fixture = PageFixture()
		let before = fixture.store.state
		await fixture.send(try fixture.pdf(.export)).finish()
		guard case let .pdf(result) = try #require(fixture.responses.first) else {
			Issue.record("Export did not return a PDF")
			return
		}

		expectNoDifference(result.data, PageFixture.pdfData)
		expectNoDifference(result.pageCount, 1)
		expectNoDifference(result.digest.count, 64)
		expectNoDifference(fixture.pdfKinds, [.export(landscape: false, printsBackground: false, scale: nil)])
		expectNoDifference(fixture.store.workspace, before.workspace)
		expectNoDifference(fixture.store.main, before.main)
		expectNoDifference(fixture.store.focusedWindowID, before.focusedWindowID)
	}

	@Test
	internal func textReadsThePDFDocumentInChunks() async throws {
		let fixture = PageFixture()
		await fixture.send(try fixture.pdf(.text)).finish()
		guard case let .pdf(result) = try #require(fixture.responses.first) else {
			Issue.record("Text did not return a chunk")
			return
		}

		expectNoDifference(result.text?.trimmingCharacters(in: .whitespacesAndNewlines), "ARX_PDF_TEXT")
		expectNoDifference(result.nextOffset, nil)
		expectNoDifference(fixture.pdfKinds, [.source])
	}

	@Test
	internal func pdfNeedsThePageContentGrant() async throws {
		let fixture = PageFixture(pageContentAllowed: false)
		await fixture.send(try fixture.pdf(.export)).finish()
		expectNoDifference(fixture.responses, [.failure(.denied)])
		expectNoDifference(fixture.pdfKinds, [])
	}

	@Test
	internal func nativeFindAsksFirstThenReportsTheResult() async throws {
		let fixture = PageFixture(interact: true)
		let request = try fixture.find("needle")
		await fixture.send(request).finish()
		#expect(fixture.responses.isEmpty)
		#expect(fixture.store.automation.pending[request.id]?.awaitingApproval == true)

		fixture.findResult = .init(matches: 4, active: 2)
		await fixture.store.send(.automation(.ui(.approve(request.id)))).finish()
		expectNoDifference(fixture.commands, [.find("needle", forward: true, newSession: true)])
		expectNoDifference(
			fixture.responses,
			[.findInPage(.init(targetID: fixture.tab.id.rawValue, matches: 4, active: 2, stopped: false))]
		)
		expectNoDifference(fixture.store.automation.findInPageTexts[fixture.tab.id], "needle")
	}
}

@MainActor
private final class PageFixture {
	/// A one-page PDF whose only text is ARX_PDF_TEXT.
	fileprivate static let pdfData: Data = Data(base64Encoded: """
	JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvQ29udGVudHMgNCAwIFIgL1Jlc291cmNlcyA8PCAvRm9udCA8PCAvRjEgNSAwIFIgPj4gPj4gPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCA0MyA+PgpzdHJlYW0KQlQgL0YxIDI0IFRmIDcyIDcwMCBUZCAoQVJYX1BERl9URVhUKSBUaiBFVAplbmRzdHJlYW0KZW5kb2JqCjUgMCBvYmoKPDwgL1R5cGUgL0ZvbnQgL1N1YnR5cGUgL1R5cGUxIC9CYXNlRm9udCAvSGVsdmV0aWNhID4+CmVuZG9iagp4cmVmCjAgNgowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMDkgMDAwMDAgbiAKMDAwMDAwMDA1OCAwMDAwMCBuIAowMDAwMDAwMTE1IDAwMDAwIG4gCjAwMDAwMDAyNDEgMDAwMDAgbiAKMDAwMDAwMDMzNCAwMDAwMCBuIAp0cmFpbGVyCjw8IC9TaXplIDYgL1Jvb3QgMSAwIFIgPj4Kc3RhcnR4cmVmCjQwNAolJUVPRgo=
	""".replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\t", with: ""))!

	fileprivate let tab: BrowserCore.Tab
	fileprivate var store: StoreOf<BrowserAutomation>!
	fileprivate var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	fileprivate var responses: [AutomationResult] = []
	fileprivate var pdfKinds: [PagePDFRequest.Kind] = []
	fileprivate var commands: [BrowserEngineClient.Command] = []
	fileprivate var findResult: BrowserNavigation.FindResult?
	private var requests: [UUID: AutomationRequest] = [:]

	fileprivate init(
		pageContentAllowed: Bool = true,
		interact: Bool = false
	) {
		let organization = IntegrationFeatureTests().fixture()
		self.tab = organization.tabs[0]
		self.snapshots = [
			tab.id: .init(
				navigation: .init(url: tab.restoration.url),
				revision: 3,
				documentRevision: 8,
				isVisibleForCapture: false
			),
		]
		var client = AutomationClient(
			id: UUID(80),
			name: "Fixture",
			credentialDigest: String(repeating: "a", count: 64),
			scopes: [.tab(tab.id, profileID: tab.profileID, location: .space(organization.spaces[0].id))],
			allowsRead: true,
			allowsPageContent: pageContentAllowed,
			grantRevision: UUID(82)
		)
		if interact { client.capabilities.formUnion([.interact]) }
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[UUID(81)] = client.id
		self.store = Store(initialState: state) { BrowserAutomation() } withDependencies: { [weak self] dependencies in
			dependencies.uuid = .incrementing
			dependencies.date.now = Date(timeIntervalSince1970: 100)
			dependencies.continuousClock = ImmediateClock()
			dependencies.browserEngine.snapshot = { self?.snapshots[$0] }
			dependencies.browserEngine.commandAuthorized = { _, _, command, authorize in
				guard let self, authorize() else { throw AutomationFailure.denied }
				self.commands.append(command)
			}
			dependencies.browserEngine.events = { [weak self] _ in
				AsyncStream { continuation in
					let result = MainActor.assumeIsolated { self?.findResult }
					continuation.yield(.init(url: nil, findResult: result))
					continuation.finish()
				}
			}
			dependencies.browserCapture.pdfIsAvailable = { true }
			dependencies.browserCapture.pdfAuthorized = { request, authorize in
				guard let self, authorize() else { throw PageCaptureFailure.staleDocument }
				self.pdfKinds.append(request.kind)
				return .init(request: request, documentID: "document", data: Self.pdfData)
			}
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

	private func revision() throws -> String {
		let client = store.automationPreferences.clients[0]
		return try #require(AutomationInventoryBuilder.items(
			client: client,
			organization: store.workspace,
			snapshots: snapshots
		).first { $0.id == tab.id.rawValue }).revision
	}

	fileprivate func pdf(_ kind: AutomationPDFRequest.Kind) throws -> AutomationRequest {
		.init(
			id: UUID(84),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .pdf(.init(targetID: tab.id.rawValue, expectedRevision: try revision(), kind: kind))
		)
	}

	fileprivate func find(_ text: String) throws -> AutomationRequest {
		.init(
			id: UUID(85),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .findInPage(.init(targetID: tab.id.rawValue, expectedRevision: try revision(), text: text))
		)
	}

	fileprivate func send(_ request: AutomationRequest) -> StoreTask {
		requests[request.id] = request
		return store.send(.automation(.event(.host(.request(request)))))
	}
}
