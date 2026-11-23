import BrowserCore
import BrowserEngineClient
import Foundation
import Testing

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

/// How Settings sees native's saved-password replies (DEV-721): lists keep
/// sites and usernames, CSV rows keep their reason, and failures keep native's
/// import reason. Nothing here can carry a password.
@Suite
@MainActor
internal struct ChromiumSavedPasswordsMappingTests {
	@Test
	internal func listsKeepSitesUsernamesAndNeverSavedSites() async throws {
		let list = ChromiumBrowserEngine.savedPasswordList(.init(
			listing: "L1",
			passwords: [.init(id: 1, site: "example.com", origin: "https://example.com", username: "me")],
			blocked: [.init(id: 2, site: "never.test", origin: "https://never.test")]
		))
		#expect(list == .init(
			listing: "L1",
			passwords: [.init(id: 1, site: "example.com", origin: "https://example.com", username: "me")],
			neverSaved: [.init(id: 2, site: "never.test", origin: "https://never.test")]
		))
	}

	@Test(arguments: [
		("missingPassword", BrowserPasswordImportSummary.Row.Reason.missingPassword),
		("missingURL", .missingURL),
		("invalidURL", .invalidURL),
		("tooLong", .tooLong),
		("unknown", .unknown),
		("somethingNew", .unknown),
	])
	internal func skippedRowsKeepTheirReason(
		native: String,
		reason: BrowserPasswordImportSummary.Row.Reason
	) async throws {
		let row = ChromiumBrowserEngine.importRow(.init(site: "example.com", username: "me", reason: native))
		#expect(row == .init(site: "example.com", username: "me", reason: reason))
	}

	@Test
	internal func conflictsHaveNoReason() async throws {
		let row = ChromiumBrowserEngine.importRow(.init(site: "example.com", username: "me"))
		#expect(row.reason == nil)
	}

	@Test(arguments: [
		(ChromiumSavedPasswordFailure.invalid(reason: "format"), BrowserSavedPasswordFailure.badFormat),
		(.invalid(reason: "tooLarge"), .fileTooLarge),
		(.invalid(reason: "tooMany"), .tooManyPasswords),
		(.invalid(reason: nil), .invalid),
		(.failed(reason: "io"), .unreadableFile),
		(.failed(reason: "unknown"), .failed),
		(.stale, .stale),
		(.notFound, .notFound),
		(.exists, .exists),
		(.denied, .denied),
		(.busy, .busy),
		(.unavailable, .unavailable),
	])
	internal func failuresKeepNativeImportReasons(
		native: ChromiumSavedPasswordFailure,
		failure: BrowserSavedPasswordFailure
	) async throws {
		#expect(ChromiumBrowserEngine.savedPasswordFailure(native) == failure)
	}

	@Test
	internal func otherErrorsAreFailures() async throws {
		#expect(ChromiumBrowserEngine.savedPasswordFailure(CancellationError()) == .failed)
	}
}
