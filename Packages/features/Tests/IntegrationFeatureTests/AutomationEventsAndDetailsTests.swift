@testable import AppFeature
import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing

/// `arx://events` signals and `browser_logs` request details (DEV-924).
@Suite(.dependencies)
@MainActor
internal struct AutomationEventsAndDetailsTests {
	@Test
	internal func signalsCarryAHashNotTheAddress() {
		let salt = UUID()
		var navigation = BrowserNavigation(url: URL(string: "https://example.com/secret-page"), title: "Secret")
		navigation.isLoading = true
		let snapshot = BrowserSessionSnapshot(navigation: navigation, revision: 1)
		let loading = AppFeature.State.automationSignal(snapshot, dialog: .permission, salt: salt)
		expectNoDifference(loading.state, .loading)
		expectNoDifference(loading.dialog, .permission)
		expectNoDifference(loading.address?.count, 16)
		#expect(loading.address?.contains("example") == false)
		// Another client's salt gives another hash for the same page.
		#expect(AppFeature.State.automationSignal(snapshot, dialog: nil, salt: UUID()).address != loading.address)
		expectNoDifference(AppFeature.State.automationSignal(nil, dialog: nil, salt: salt), .init(state: .unloaded))
	}

	@Test
	internal func requestDetailsAreRedactedAndPaged() throws {
		let tab = UUID()
		let entries = (1...3).map { index in
			"""
			{"sequence":\(index),"method":"POST","url":"https://example.com/\(index)",\
			"requestHeaders":{"Authorization":"[redacted]","Accept":"*/*"},\
			"requestBody":"user=max&password=hunter2"}
			"""
		}
		let data = Data(#"{"capturing":true,"next":3,"dropped":0,"entries":["# .utf8)
		+ Data(entries.joined(separator: ",").utf8)
		+ Data("]}".utf8)

		let request = AutomationLogRequest(action: .requests, targetID: tab, limit: 2)
		guard case let .logs(result) = BrowserAutomation.networkDetails(data, request: request) else {
			Issue.record("Request details didn't decode")
			return
		}
		expectNoDifference(result.requests.map(\.sequence), [1, 2])
		expectNoDifference(result.next, 2)
		expectNoDifference(result.requests.first?.requestBody, "user=max&password=[redacted]")
		expectNoDifference(result.requests.first?.requestHeaders["Authorization"], "[redacted]")

		let har = AutomationLogRequest(action: .har, targetID: tab)
		guard case let .logs(export) = BrowserAutomation.networkDetails(data, request: har) else {
			Issue.record("HAR didn't build")
			return
		}
		#expect(export.requests.isEmpty)
		#expect(export.har?.contains("\"version\":\"1.2\"") == true)
		#expect(export.har?.contains("hunter2") == false)
		expectNoDifference(export.next, 3)
		try export.validate()
	}

	@Test
	internal func garbageFromTheEngineFails() {
		let request = AutomationLogRequest(action: .requests, targetID: UUID())
		expectNoDifference(BrowserAutomation.networkDetails(Data("nope".utf8), request: request), .failure(.engineFailed))
	}
}
