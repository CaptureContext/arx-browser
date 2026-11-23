import BrowserCore
import BrowserEngineClient
import Foundation
import MigrationAssistant
import Testing
@testable import MigrationAssistantFeature

/// The writer over the engine client (DEV-830), with the engine replaced. Throwaway values only.
@MainActor
internal struct CredentialEngineWriterTests {
	private let profileID: Profile.ID = .init(rawValue: UUID())

	@Test
	internal func anEngineWithoutTheCallsIsUnavailable() async {
		let writer = CredentialDestinationWriter.browserEngine(.init(status: { .ready }))
		#expect(await !writer.isAvailable())
		await #expect(throws: CredentialMigrationFailure.writerUnavailable) {
			try await writer.importPasswords(profileID, [])
		}
	}

	@Test
	internal func passwordsKeepTheEngineStampForUndo() async throws {
		var engine = BrowserEngineClient(status: { .ready })
		engine.credentialImportIsAvailable = { true }
		var sent: [BrowserImportedPassword] = []
		engine.importPasswordRecords = { _, records throws(BrowserCredentialImportFailure) in
			sent = records
			return .init(
				imported: [.init(signonRealm: "https://a.test/", username: "ann", dateCreated: "42")],
				conflicts: 1,
				skipped: 2
			)
		}
		var undone: ([BrowserPasswordKey], [BrowserCookieKey])?
		engine.undoCredentialImport = { _, passwords, cookies throws(BrowserCredentialImportFailure) in
			undone = (passwords, cookies)
			return passwords.count + cookies.count
		}
		let writer = CredentialDestinationWriter.browserEngine(engine)
		#expect(await writer.isAvailable())

		let result = try await writer.importPasswords(profileID, [
			.init(url: "https://a.test/", signonRealm: "https://a.test/", username: "ann", password: "throwaway"),
		])
		#expect(sent.map(\.password) == ["throwaway"])
		#expect(result == .init(
			imported: [.init(signonRealm: "https://a.test/", username: "ann", dateCreated: "42")],
			conflicts: 1,
			skipped: 2
		))

		try await writer.undo(.init(profileID: profileID, passwords: result.imported))
		#expect(undone?.0 == [.init(signonRealm: "https://a.test/", username: "ann", dateCreated: "42")])
		#expect(undone?.1.isEmpty == true)
	}

	@Test
	internal func cookiesTravelWithTheirFullIdentity() async throws {
		let key: BrowserCookieKey = .init(
			domain: ".a.test",
			name: "__Host-id",
			path: "/",
			topFrameSiteKey: "https://top.test",
			hasCrossSiteAncestor: true,
			sourceScheme: 2,
			sourcePort: 443
		)
		var engine = BrowserEngineClient(status: { .ready })
		var sent: [BrowserImportedCookie] = []
		engine.importCookies = { _, cookies throws(BrowserCredentialImportFailure) in
			sent = cookies
			return .init(accepted: [key], existing: [], rejected: [])
		}
		engine.checkCookies = { _, keys throws(BrowserCredentialImportFailure) in Set(keys) }
		let writer = CredentialDestinationWriter.browserEngine(engine)
		let record: CredentialCookieRecord = .init(
			domain: ".a.test",
			name: "__Host-id",
			value: "throwaway",
			path: "/",
			created: Date(timeIntervalSince1970: 1),
			expires: Date(timeIntervalSince1970: 2),
			lastAccessed: Date(timeIntervalSince1970: 3),
			isSecure: true,
			isHTTPOnly: true,
			sameSite: 1,
			priority: 2,
			sourceScheme: 2,
			sourcePort: 443,
			topFrameSiteKey: "https://top.test",
			hasCrossSiteAncestor: true
		)

		let result = try await writer.setCookies(profileID, [record])
		#expect(sent.first?.value == "throwaway")
		#expect(sent.first?.expires == Date(timeIntervalSince1970: 2))
		let undoKey: CredentialUndoRecord.Cookie = .init(record)
		#expect(result.accepted == [undoKey])
		#expect(await writer.checkCookies(profileID, [undoKey]) == [undoKey])
	}

	@Test
	internal func aFailedReadBackReportsSitesAsNotChecked() async {
		var engine = BrowserEngineClient(status: { .ready })
		engine.checkCookies = { _, _ throws(BrowserCredentialImportFailure) in throw .failed }
		let writer = CredentialDestinationWriter.browserEngine(engine)
		#expect(await writer.checkCookies(profileID, [.init(domain: "a.test", name: "id", path: "/")]) == nil)
	}

	@Test
	internal func engineFailuresBecomeWriteFailures() async {
		var engine = BrowserEngineClient(status: { .ready })
		engine.importCookies = { _, _ throws(BrowserCredentialImportFailure) in throw .busy }
		let writer = CredentialDestinationWriter.browserEngine(engine)
		await #expect(throws: CredentialMigrationFailure.writeFailed) {
			try await writer.setCookies(profileID, [])
		}
	}
}
