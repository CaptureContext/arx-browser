import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _TestSupport

@testable import AppFeature

/// Every page result goes through `automationResponseValidation` before it reaches
/// the agent. These check that load, PDF, find and dialog replies are released
/// when they should be and held back when the grant or the page changed.
@Suite(.dependencies)
@MainActor
internal struct AutomationResponseGateTests {
	// MARK: - Load

	@Test(arguments: [AutomationLoadResult.Status.loading, .alreadyLoaded])
	internal func loadIsReleasedAfterThePageOpens(status: AutomationLoadResult.Status) throws {
		var fixture = try GateFixture()
		let request = fixture.request(.load(.init(targetID: fixture.tabID, expectedRevision: fixture.revision)))

		// Opening the page creates its session and moves the revision.
		fixture.snapshots[fixture.tab.id]?.revision = 4

		expectNoDifference(
			fixture.validate(request, .load(.init(targetID: fixture.tabID, status: status))),
			nil
		)
	}

	@Test
	internal func loadIsDeniedOnceTheTabIsOutOfScope() throws {
		var fixture = try GateFixture()
		let request = fixture.request(.load(.init(targetID: fixture.tabID, expectedRevision: fixture.revision)))
		fixture.revokeTabScope()

		expectNoDifference(
			fixture.validate(request, .load(.init(targetID: fixture.tabID, status: .loading))),
			.denied
		)
	}

	@Test
	internal func loadForAnotherTabIsRejected() throws {
		let fixture = try GateFixture()
		let request = fixture.request(.load(.init(targetID: fixture.tabID, expectedRevision: fixture.revision)))

		expectNoDifference(
			fixture.validate(request, .load(.init(targetID: fixture.other.id.rawValue, status: .loading))),
			.invalidRequest
		)
	}

	// MARK: - PDF

	@Test
	internal func pdfIsReleasedForTheDocumentItWasMadeFrom() throws {
		let fixture = try GateFixture()
		let pdf = fixture.pdfRequest()

		expectNoDifference(fixture.validate(fixture.request(.pdf(pdf)), .pdf(fixture.pdfResult(pdf))), nil)
	}

	@Test
	internal func pdfIsDeniedWithoutThePageContentGrant() throws {
		var fixture = try GateFixture()
		let pdf = fixture.pdfRequest()
		let request = fixture.request(.pdf(pdf))
		fixture.setCapabilities(pageContent: false)

		expectNoDifference(fixture.validate(request, .pdf(fixture.pdfResult(pdf))), .denied)
	}

	@Test
	internal func pdfOfAnEarlierDocumentIsStale() throws {
		var fixture = try GateFixture()
		let pdf = fixture.pdfRequest()
		var result = fixture.pdfResult(pdf)
		result.documentRevision = 7

		expectNoDifference(fixture.validate(fixture.request(.pdf(pdf)), .pdf(result)), .staleTarget)

		// A navigation after the export moves the tab's revision too.
		fixture.snapshots[fixture.tab.id]?.revision = 4
		expectNoDifference(
			fixture.validate(fixture.request(.pdf(pdf)), .pdf(fixture.pdfResult(pdf))),
			.staleTarget
		)
	}

	// MARK: - Find in page

	@Test
	internal func findIsReleasedAfterItMovesTheRevision() throws {
		var fixture = try GateFixture()
		let find = AutomationFindInPageRequest(targetID: fixture.tabID, expectedRevision: fixture.revision, text: "needle")
		let request = fixture.request(.findInPage(find))
		fixture.snapshots[fixture.tab.id]?.revision = 4
		fixture.snapshots[fixture.tab.id]?.navigation.findResult = .init(matches: 4, active: 2)

		expectNoDifference(
			fixture.validate(request, .findInPage(.init(targetID: fixture.tabID, matches: 4, active: 2, stopped: false))),
			nil
		)
	}

	@Test
	internal func findIsDeniedWithoutTheInteractGrant() throws {
		var fixture = try GateFixture()
		let find = AutomationFindInPageRequest(targetID: fixture.tabID, expectedRevision: fixture.revision, text: "needle")
		let request = fixture.request(.findInPage(find))
		fixture.setCapabilities(interact: false)

		expectNoDifference(
			fixture.validate(request, .findInPage(.init(targetID: fixture.tabID, matches: 4, active: 2, stopped: false))),
			.denied
		)
	}

	@Test
	internal func findIsHeldBackWhenThePageLeftItsScope() throws {
		var fixture = try GateFixture()
		let find = AutomationFindInPageRequest(targetID: fixture.tabID, expectedRevision: fixture.revision, text: "needle")
		let request = fixture.request(.findInPage(find))
		let result = AutomationResult.findInPage(.init(targetID: fixture.tabID, matches: 4, active: 2, stopped: false))

		fixture.snapshots[fixture.tab.id]?.navigation.url = URL(string: "arx://settings")
		expectNoDifference(fixture.validate(request, result), .unsupported)

		fixture.snapshots[fixture.tab.id] = nil
		expectNoDifference(fixture.validate(request, result), .notLoaded)
	}

	@Test
	internal func malformedFindResultsAreRejected() throws {
		let fixture = try GateFixture()
		let find = AutomationFindInPageRequest(targetID: fixture.tabID, expectedRevision: fixture.revision, text: "needle")
		let request = fixture.request(.findInPage(find))

		for result in [
			AutomationFindInPageResult(targetID: fixture.tabID, matches: 2, active: 3, stopped: false),
			AutomationFindInPageResult(targetID: fixture.tabID, matches: 2, active: 1, stopped: true),
			AutomationFindInPageResult(targetID: fixture.other.id.rawValue, matches: 2, active: 1, stopped: false),
		] {
			expectNoDifference(fixture.validate(request, .findInPage(result)), .invalidRequest)
		}
	}

	// MARK: - Dialog

	@Test
	internal func dialogReadIsReleasedForTheCurrentPage() throws {
		let fixture = try GateFixture()
		let read = fixture.dialogRequest(.read)

		expectNoDifference(
			fixture.validate(fixture.request(.dialog(read)), .dialog(.init(targetID: fixture.tabID, dialog: fixture.dialog))),
			nil
		)
	}

	@Test
	internal func dialogReadIsHeldBackAfterTheTabChanged() throws {
		var fixture = try GateFixture()
		let read = fixture.dialogRequest(.read)
		let request = fixture.request(.dialog(read))
		fixture.snapshots[fixture.tab.id]?.revision = 4

		expectNoDifference(
			fixture.validate(request, .dialog(.init(targetID: fixture.tabID, dialog: fixture.dialog))),
			.staleTarget
		)
	}

	@Test(arguments: [AutomationDialogRequest.Action.accept, .dismiss])
	internal func dialogAnswerIsReleasedEvenIfThePageNavigated(action: AutomationDialogRequest.Action) throws {
		var fixture = try GateFixture()
		let answer = fixture.dialogRequest(action)
		let request = fixture.request(.dialog(answer))
		fixture.snapshots[fixture.tab.id]?.revision = 4
		fixture.snapshots[fixture.tab.id]?.navigation.isLoading = true

		expectNoDifference(
			fixture.validate(
				request,
				.dialog(.init(targetID: fixture.tabID, operationID: answer.operationID, answered: true))
			),
			nil
		)
		expectNoDifference(
			fixture.validate(
				request,
				.dialog(.init(targetID: fixture.tabID, operationID: answer.operationID, failure: .staleTarget))
			),
			nil
		)
	}

	@Test
	internal func dialogAnswerIsDeniedWithoutTheInteractGrant() throws {
		var fixture = try GateFixture()
		let answer = fixture.dialogRequest(.accept)
		let request = fixture.request(.dialog(answer))
		fixture.setCapabilities(interact: false)

		expectNoDifference(
			fixture.validate(
				request,
				.dialog(.init(targetID: fixture.tabID, operationID: answer.operationID, answered: true))
			),
			.denied
		)
	}

	@Test
	internal func dialogAnswerIsDeniedOnceTheTabIsOutOfScope() throws {
		var fixture = try GateFixture()
		let answer = fixture.dialogRequest(.dismiss)
		let request = fixture.request(.dialog(answer))
		fixture.revokeTabScope()

		expectNoDifference(
			fixture.validate(
				request,
				.dialog(.init(targetID: fixture.tabID, operationID: answer.operationID, answered: true))
			),
			.denied
		)
	}

	@Test
	internal func mismatchedDialogResultsAreRejected() throws {
		let fixture = try GateFixture()
		let read = fixture.request(.dialog(fixture.dialogRequest(.read)))
		let answer = fixture.dialogRequest(.accept)
		let accept = fixture.request(.dialog(answer))

		// An answer never carries the page's dialog text.
		expectNoDifference(
			fixture.validate(
				accept,
				.dialog(.init(targetID: fixture.tabID, dialog: fixture.dialog))
			),
			.invalidRequest
		)

		// Another operation's outcome.
		expectNoDifference(
			fixture.validate(
				accept,
				.dialog(.init(targetID: fixture.tabID, operationID: UUID(99), answered: true))
			),
			.invalidRequest
		)

		// An answer whose outcome contradicts itself.
		expectNoDifference(
			fixture.validate(
				accept,
				.dialog(.init(targetID: fixture.tabID, operationID: answer.operationID, answered: true, failure: .denied))
			),
			.invalidRequest
		)

		// A read that claims to have answered.
		expectNoDifference(
			fixture.validate(
				read,
				.dialog(.init(targetID: fixture.tabID, answered: true))
			),
			.invalidRequest
		)
	}

	// MARK: - Settings

	@Test
	internal func settingsReadIsReleasedWhileTheSectionIsCurrent() throws {
		var fixture = try GateFixture()
		fixture.state.automationPreferences.clients[0].capabilities.insert(.browserAdmin)
		let client = fixture.state.automationPreferences.clients[0]
		let request = fixture.request(.settings(.init(.read(.searchShortcuts, profileID: nil))))
		let section = try #require(fixture.state.automationSettings(.searchShortcuts, client: client))
		expectNoDifference(fixture.validate(request, .settings(section)), nil)

		// The user changed the section after the read was made.
		fixture.state.settings.$searchShortcuts.withLock { $0 = SearchShortcut.fixtures }
		expectNoDifference(fixture.validate(request, .settings(section)), .staleTarget)

		// A result for another section, or one that claims to be a change, is never released.
		var other = section
		other.section = .routing
		expectNoDifference(fixture.validate(request, .settings(other)), .denied)
		var claimed = try #require(fixture.state.automationSettings(.searchShortcuts, client: client))
		claimed.operationID = UUID(99)
		expectNoDifference(fixture.validate(request, .settings(claimed)), .denied)
	}

	@Test
	internal func settingsAreDeniedWithoutBrowserAdmin() throws {
		var fixture = try GateFixture()
		fixture.state.automationPreferences.clients[0].capabilities.insert(.browserAdmin)
		let client = fixture.state.automationPreferences.clients[0]
		let request = fixture.request(.settings(.init(.read(.keyboardShortcuts, profileID: nil))))
		let section = try #require(fixture.state.automationSettings(.keyboardShortcuts, client: client))
		fixture.state.automationPreferences.clients[0].capabilities.remove(.browserAdmin)

		expectNoDifference(fixture.validate(request, .settings(section)), .denied)
	}

	@Test
	internal func extensionsAreReleasedOnlyForAGrantedProfile() throws {
		var fixture = try GateFixture()
		fixture.state.automationPreferences.clients[0].capabilities.insert(.browserAdmin)
		let profileID = fixture.tab.profileID.rawValue
		let request = fixture.request(.settings(.init(.read(.extensions, profileID: profileID))))
		let result = AutomationSettingsResult(
			section: .extensions,
			revision: String(repeating: "e", count: 64),
			extensions: .init(profileID: profileID, items: [])
		)

		// The fixture grants a single tab, not the whole profile.
		expectNoDifference(fixture.validate(request, .settings(result)), .denied)

		fixture.state.automationPreferences.clients[0].scopes = [.profile(fixture.tab.profileID)]
		expectNoDifference(fixture.validate(request, .settings(result)), nil)
	}

	// MARK: - Pairing

	@Test
	internal func aResultOfAnotherKindIsRejected() throws {
		let fixture = try GateFixture()
		let request = fixture.request(.pdf(fixture.pdfRequest()))

		expectNoDifference(
			fixture.validate(request, .load(.init(targetID: fixture.tabID, status: .loading))),
			.invalidRequest
		)
	}
}

@MainActor
private struct GateFixture {
	let tab: BrowserCore.Tab
	let other: BrowserCore.Tab
	let revision: String
	let dialog = BrowserPageDialog(token: "1f", kind: .confirm, message: "Leave?")
	var state: AppFeature.State
	var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]

	var tabID: UUID { tab.id.rawValue }

	init() throws {
		let organization = IntegrationFeatureTests().fixture()
		self.tab = organization.tabs[0]
		self.other = organization.tabs[1]
		self.snapshots = [
			organization.tabs[0].id: .init(
				navigation: .init(url: organization.tabs[0].restoration.url),
				revision: 3,
				documentRevision: 8
			),
		]
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture",
			credentialDigest: String(repeating: "a", count: 64),
			scopes: [.tab(tab.id, profileID: tab.profileID, location: .space(organization.spaces[0].id))],
			allowsRead: true,
			allowsPageContent: true,
			allowsPageInteraction: true,
			grantRevision: UUID(82)
		)
		self.revision = try #require(AutomationInventoryBuilder.items(
			client: client,
			organization: organization,
			snapshots: snapshots
		).first { $0.id == organization.tabs[0].id.rawValue }).revision
		self.state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[UUID(81)] = client.id
	}

	func request(_ operation: AutomationOperation) -> AutomationRequest {
		.init(id: UUID(84), clientID: UUID(80), sessionID: UUID(81), operation: operation)
	}

	func validate(
		_ request: AutomationRequest,
		_ result: AutomationResult
	) -> AutomationFailure? {
		state.automationResponseValidation(request, result: result, snapshots: snapshots)
	}

	mutating func setCapabilities(
		pageContent: Bool = true,
		interact: Bool = true
	) {
		state.automationPreferences.clients[0].allowsPageContent = pageContent
		state.automationPreferences.clients[0].allowsPageInteraction = interact
	}

	mutating func revokeTabScope() {
		state.automationPreferences.clients[0].scopes = [
			.tab(other.id, profileID: other.profileID, location: .space(state.workspace.spaces[0].id)),
		]
	}

	func pdfRequest() -> AutomationPDFRequest {
		.init(targetID: tabID, expectedRevision: revision, kind: .export)
	}

	func pdfResult(_ request: AutomationPDFRequest) -> AutomationPDFResult {
		let data = Data("%PDF-1.4".utf8)
		return .init(
			request: request,
			profileID: tab.profileID,
			documentRevision: 8,
			documentID: "document",
			data: data,
			totalBytes: data.count,
			pageCount: 1,
			digest: String(repeating: "c", count: 64)
		)
	}

	func dialogRequest(_ action: AutomationDialogRequest.Action) -> AutomationDialogRequest {
		.init(
			action: action,
			targetID: tabID,
			expectedRevision: revision,
			operationID: action == .read ? nil : UUID(86),
			token: action == .read ? nil : dialog.token
		)
	}
}
