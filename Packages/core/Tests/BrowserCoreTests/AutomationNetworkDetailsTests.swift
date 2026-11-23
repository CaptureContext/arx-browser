import CustomDump
import Foundation
import Testing

@testable import BrowserCore

/// Request details and HAR for `browser_logs` (DEV-924).
internal struct AutomationNetworkDetailsTests {
	@Test
	internal func credentialHeadersAndFieldsAreRedacted() {
		let detail = AutomationRequestDetail(
			sequence: 1,
			method: "POST",
			url: "https://example.com/login",
			requestHeaders: ["Content-Type": "application/json", "X-Api-Key": "abc", "Cookie": "a=b"],
			responseHeaders: ["Set-Cookie": "s=1", "Content-Length": "2"],
			requestBody: #"{"user":"max","password":"hunter2","nested":{"token":"t","keep":1},"tokens":["a","b"],"session":{"id":1}}"#,
			responseBody: "user=max&session_id=42&ok=1"
		)
		let redacted = detail.redactingCredentials()

		expectNoDifference(redacted.requestHeaders["Content-Type"], "application/json")
		expectNoDifference(redacted.requestHeaders["X-Api-Key"], "[redacted]")
		expectNoDifference(redacted.requestHeaders["Cookie"], "[redacted]")
		expectNoDifference(redacted.responseHeaders["Set-Cookie"], "[redacted]")
		expectNoDifference(redacted.responseHeaders["Content-Length"], "2")
		expectNoDifference(
			redacted.requestBody,
			#"{"nested":{"keep":1,"token":"[redacted]"},"password":"[redacted]","session":"[redacted]","tokens":"[redacted]","user":"max"}"#
		)
		expectNoDifference(redacted.responseBody, "user=max&session_id=[redacted]&ok=1")
	}

	@Test
	internal func cutOrBrokenJSONIsLeftOutAndCuttingComesAfterRedaction() {
		var cut = AutomationRequestDetail(sequence: 1, method: "POST", url: "https://example.com/login")
		cut.requestBody = #"{"user":"max","password":"hunt"#
		let redacted = cut.redactingCredentials()
		#expect(redacted.requestBody == nil)
		#expect(redacted.requestBodyOmitted == true)

		var long = AutomationRequestDetail(sequence: 2, method: "POST", url: "https://example.com/login")
		long.requestBody = #"{"password":"hunter2","note":""# + String(repeating: "x", count: 100) + #""}"#
		let short = long.redactingCredentials(bodyBytes: 30)
		#expect(short.requestBodyTruncated == true)
		#expect(short.requestBody?.contains("hunter2") == false)
		#expect((short.requestBody?.utf8.count ?? 0) <= 30)
	}

	@Test
	internal func formsWithEmptyOrBareFieldsAreStillRedacted() {
		expectNoDifference(AutomationRequestDetail.redactingFields("password=hunter2&"), "password=[redacted]&")
		expectNoDifference(AutomationRequestDetail.redactingFields("password=hunter2&flag"), "password=[redacted]&flag")
		expectNoDifference(
			AutomationRequestDetail.redactingFields("a=1&&api%5Fkey=x&user+token=y"),
			"a=1&&api%5Fkey=[redacted]&user+token=[redacted]"
		)
	}

	@Test
	internal func credentialAliasesAndSpacedFormsAreRedacted() {
		expectNoDifference(
			AutomationRequestDetail.redactingFields(#"{"pwd":"hunter2","pass":"x"}"#),
			#"{"pass":"[redacted]","pwd":"[redacted]"}"#
		)
		expectNoDifference(AutomationRequestDetail.redactingFields("pwd=hunter2"), "pwd=[redacted]")
		let spaced = AutomationRequestDetail(
			sequence: 1,
			method: "POST",
			url: "https://example.com/login",
			requestHeaders: ["Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"],
			requestBody: "password=secret&note=hello world"
		)
		expectNoDifference(spaced.redactingCredentials().requestBody, "password=[redacted]&note=hello world")
	}

	@Test
	internal func base64BodiesAreCutWhereTheyStillDecode() throws {
		var binary = AutomationRequestDetail(sequence: 1, method: "GET", url: "https://example.com/a.bin")
		binary.responseBody = "aGVsbG8gd29ybGQ="
		binary.responseBodyBase64 = true
		let cut = binary.redactingCredentials(bodyBytes: 5)
		expectNoDifference(cut.responseBody, "aGVs")
		#expect(Data(base64Encoded: try #require(cut.responseBody)) != nil)
		#expect(cut.responseBodyTruncated == true)
	}

	@Test
	internal func multipartPartsAreRedacted() {
		let body = "--XyZ\r\nContent-Disposition: form-data; name=\"user\"\r\n\r\nmax\r\n"
		+ "--XyZ\r\nContent-Disposition: form-data; name=\"password\"\r\n\r\nhunter2\r\n--XyZ--\r\n"
		let detail = AutomationRequestDetail(
			sequence: 1,
			method: "POST",
			url: "https://example.com/login",
			requestHeaders: ["Content-Type": "multipart/form-data; boundary=XyZ"],
			requestBody: body
		)
		let redacted = detail.redactingCredentials()
		#expect(redacted.requestBody?.contains("hunter2") == false)
		#expect(redacted.requestBody?.contains("max") == true)
		#expect(redacted.requestBody?.contains("[redacted]") == true)
		// Without the header, the delimiter line still finds the parts.
		#expect(AutomationRequestDetail.redactingFields(body)?.contains("hunter2") == false)
		// Unquoted names, and names after filename, are read exactly; a part without a name is hidden.
		let tricky = "--B\r\nContent-Disposition: form-data; name=password\r\n\r\nhunter2\r\n"
		+ "--B\r\nContent-Disposition: form-data; filename=\"blob\"; name=\"pwd\"\r\n\r\nsecret2\r\n"
		+ "--B\r\nContent-Disposition: form-data\r\n\r\nmystery\r\n"
		+ "--B\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nhello\r\n--B--\r\n"
		let parsed = AutomationRequestDetail.redactingFields(tricky, boundary: "B") ?? ""
		#expect(!parsed.contains("hunter2") && !parsed.contains("secret2") && !parsed.contains("mystery"))
		#expect(parsed.contains("hello"))
		// A quoted name may hold semicolons.
		let quoted = "--B\r\nContent-Disposition: form-data; name=\"account;password\"\r\n\r\nhunter3\r\n--B--\r\n"
		#expect(AutomationRequestDetail.redactingFields(quoted, boundary: "B")?.contains("hunter3") == false)
		// Parts that can't be found leave the body out.
		var broken = detail
		broken.requestBody = "--XyZ\r\nno separator password hunter2"
		#expect(broken.redactingCredentials().requestBody == nil)
	}

	@Test
	internal func otherBodiesStayAsTheyAre() {
		expectNoDifference(AutomationRequestDetail.redactingFields("plain text, password=x here"), "plain text, password=x here")
		expectNoDifference(AutomationRequestDetail.redactingFields("<html>token</html>"), "<html>token</html>")
		var binary = AutomationRequestDetail(sequence: 1, method: "GET", url: "https://example.com/a.png")
		binary.responseBody = "cGFzc3dvcmQ9eA=="
		binary.responseBodyBase64 = true
		expectNoDifference(binary.redactingCredentials().responseBody, "cGFzc3dvcmQ9eA==")
	}

	@Test
	internal func harHasTheRequestsAndTheirBodies() throws {
		let detail = AutomationRequestDetail(
			sequence: 3,
			method: "GET",
			url: "https://example.com/data?q=1",
			status: 200,
			statusText: "OK",
			mimeType: "application/json",
			protocol: "h2",
			responseHeaders: ["Content-Type": "application/json"],
			responseBody: "{}",
			bytes: 120,
			time: 1_700_000_000_000,
			duration: 42
		)
		let text = AutomationHAR.text([detail])
		let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
		let log = try #require(object["log"] as? [String: Any])
		expectNoDifference(log["version"] as? String, "1.2")
		let entry = try #require((log["entries"] as? [[String: Any]])?.first)
		let request = try #require(entry["request"] as? [String: Any])
		let response = try #require(entry["response"] as? [String: Any])
		expectNoDifference(request["url"] as? String, "https://example.com/data?q=1")
		expectNoDifference((request["queryString"] as? [[String: String]])?.first, ["name": "q", "value": "1"])
		expectNoDifference(response["status"] as? Int, 200)
		expectNoDifference((response["content"] as? [String: Any])?["text"] as? String, "{}")
		expectNoDifference(entry["time"] as? Double, 42)
	}

	@Test
	internal func detailsNeedTheirGrantAndValidArguments() throws {
		let tab = UUID()
		expectNoDifference(
			AutomationOperation.logs(.init(action: .network, targetID: tab)).requiredCapabilities,
			[.read, .devtools]
		)
		expectNoDifference(
			AutomationOperation.logs(.init(action: .start, targetID: tab, details: true)).requiredCapabilities,
			[.read, .devtools, .networkDetails]
		)
		expectNoDifference(
			AutomationOperation.logs(.init(action: .har, targetID: tab)).requiredCapabilities,
			[.read, .devtools, .networkDetails]
		)
		try AutomationLogRequest(action: .requests, targetID: tab, bodyBytes: 0).validate()
		#expect(throws: AutomationFailure.self) {
			try AutomationLogRequest(action: .requests, targetID: tab, bodyBytes: 70_000).validate()
		}
		#expect(throws: AutomationFailure.self) {
			try AutomationLogRequest(action: .network, targetID: tab, details: true).validate()
		}
	}
}
