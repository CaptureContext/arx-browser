import CustomDump
import Foundation
import Testing
@testable import BrowserCore

internal struct AutomationSignInTests {
	@Test
	internal func exactOriginsRejectCredentialsQueriesAndAmbiguousLoopback() async throws {
		for origin in ["https://capturecontext.dev", "http://localhost:8080", "http://127.0.0.1:38123"] {
			expectNoDifference(AutomationSignInRequest.canonicalOrigin(origin), origin)
			try AutomationSignInRequest(
				operationID: UUID(),
				action: .begin,
				targetID: UUID(),
				expectedRevision: String(repeating: "a", count: 64),
				origin: origin
			).validate()
		}

		let rejectedOrigins: [String] = [
			"http://capturecontext.dev:8080",
			"http://localhost",
			"http://localhost.evil:1234",
			"http://127.0.0.1.evil:1234",
			"http://127.1:1234",
			"http://2130706433:1234",
			"http://local%68ost:1234",
			"http://[::1]:1234",
			"http://localhost:0",
			"http://localhost:65536",
			"https://user:secret@capturecontext.dev",
			"https://capturecontext.dev/path",
			"https://capturecontext.dev?otp=123456",
			"https://capturecontext.dev#token",
			"https://capturecontext.dev\\@evil.test",
		]

		for origin in rejectedOrigins {
			#expect(throws: AutomationFailure.self) {
				try AutomationSignInRequest(
					operationID: UUID(),
					action: .begin,
					targetID: UUID(),
					expectedRevision: String(repeating: "a", count: 64),
					origin: origin
				).validate()
			}
		}

		#expect(throws: AutomationFailure.self) {
			try AutomationSignInRequest(
				operationID: UUID(),
				action: .status,
				origin: "https://capturecontext.dev"
			).validate()
		}
	}

	@Test
	internal func oldPreferencesDefaultToNoSignInGrantAndRecoveryCannotRestoreAuthority() async throws {
		let data = Data("{\"isEnabled\":true,\"clients\":[]}".utf8)
		let decoded = try JSONDecoder().decode(AutomationPreferences.self, from: data)
		#expect(decoded.authenticationLockID == nil && decoded.authenticationTransitionID == nil)

		let client = AutomationClient(
			id: UUID(),
			name: "Recognizable",
			credentialDigest: String(repeating: "a", count: 64),
			scopes: [.space(.init(rawValue: UUID()), profileID: .init(rawValue: UUID()))],
			allowsRead: true,
			allowsScreenshots: true,
			allowsPageContent: true,
			allowsPageInteraction: true,
			allowsSignIn: true,
			allowsManagement: true,
			mutationGrantUntil: .distantFuture,
			grantRevision: UUID()
		)
		let lock = UUID()
		let revision = UUID()
		let preferences = AutomationPreferences(
			isEnabled: true,
			clients: [client],
			authenticationLockID: lock
		)
		let revoked = preferences.revokingGrants(makeID: { revision })
		let revokedClient = revoked.clients[0]
		#expect(revoked.authenticationLockID == lock && revokedClient.name == "Recognizable")
		#expect(revokedClient.scopes.isEmpty && revokedClient.mutationGrantUntil == nil)
		#expect(
			!revokedClient.allowsRead
			&& !revokedClient.allowsScreenshots
			&& !revokedClient.allowsPageContent
		)
		#expect(
			!revokedClient.allowsPageInteraction
			&& !revokedClient.allowsSignIn
			&& !revokedClient.allowsManagement
		)
		expectNoDifference(revokedClient.grantRevision, revision)
	}

	@Test
	internal func attendedSessionDropsOnlyGrantsPastTheTemporaryWindow() async throws {
		func client(_ until: Date?) -> AutomationClient {
			AutomationClient(
				id: UUID(),
				name: "Arx headless run",
				credentialDigest: String(repeating: "a", count: 64),
				allowsRead: true,
				allowsManagement: true,
				mutationGrantUntil: until,
				grantRevision: UUID()
			)
		}

		let latest = Date(timeIntervalSince1970: 1_000)
		let revision = UUID()
		let preferences = AutomationPreferences(isEnabled: true, clients: [
			client(.distantFuture),
			client(Date(timeIntervalSince1970: 1_001)),
			client(latest),
			client(nil),
		])
		let revoked = preferences.revokingMutationGrants(endingAfter: latest, makeID: { revision })
		expectNoDifference(revoked.clients.map(\.mutationGrantUntil), [nil, nil, latest, nil])
		expectNoDifference(
			revoked.clients.map(\.grantRevision),
			[revision, revision] + preferences.clients[2...].map(\.grantRevision)
		)
		#expect(revoked.clients.allSatisfy { $0.allowsRead && $0.allowsManagement })
		#expect(revoked.isEnabled)
	}
}
