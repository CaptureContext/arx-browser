import BrowserEngineClient
import MigrationAssistant

extension CredentialDestinationWriter {
	/// Writes decrypted records through the engine's in-memory import calls (ABI46,
	/// DEV-830). On an engine without them `isAvailable` is false, so the step offers
	/// the CSV import and never reads the Keychain.
	public static func browserEngine(_ engine: BrowserEngineClient) -> Self {
		.init(
			isAvailable: { await engine.credentialImportIsAvailable() },
			importPasswords: { profile, records in
				let result: BrowserPasswordRecordImport
				do {
					result = try await engine.importPasswordRecords(profile, records.map(Self.password))
				} catch {
					throw Self.failure(error)
				}
				return .init(
					imported: result.imported.map(Self.passwordKey),
					unconfirmed: result.unconfirmed.map(Self.passwordKey),
					conflicts: result.conflicts,
					skipped: result.skipped
				)
			},
			setCookies: { profile, records in
				let result: BrowserCookieImport
				do {
					result = try await engine.importCookies(profile, records.map(Self.cookie))
				} catch {
					throw Self.failure(error)
				}
				return .init(
					accepted: result.accepted.map(Self.cookieKey),
					existing: result.existing.map(Self.cookieKey),
					rejected: result.rejected.map(Self.cookieKey),
					unconfirmed: result.unconfirmed.map(Self.cookieKey)
				)
			},
			checkCookies: { profile, keys in

				// A failed read-back reports sites as not checked rather than not kept.
				guard let present = try? await engine.checkCookies(profile, keys.map(Self.cookieKey))
				else { return nil }

				return Set(present.map(Self.cookieKey))
			},
			undo: { record in
				do {
					_ = try await engine.undoCredentialImport(
						record.profileID,
						record.passwords.map {
							.init(signonRealm: $0.signonRealm, username: $0.username, dateCreated: $0.dateCreated)
						},
						record.cookies.map(Self.cookieKey)
					)
				} catch {
					throw Self.failure(error)
				}
			}
		)
	}

	private static func password(_ record: CredentialPasswordRecord) -> BrowserImportedPassword {
		.init(
			url: record.url,
			signonRealm: record.signonRealm,
			username: record.username,
			password: record.password
		)
	}

	private static func cookie(_ record: CredentialCookieRecord) -> BrowserImportedCookie {
		.init(
			domain: record.domain,
			name: record.name,
			value: record.value,
			path: record.path,
			created: record.created,
			expires: record.expires,
			lastAccessed: record.lastAccessed,
			isSecure: record.isSecure,
			isHTTPOnly: record.isHTTPOnly,
			sameSite: record.sameSite,
			priority: record.priority,
			sourceScheme: record.sourceScheme,
			sourcePort: record.sourcePort,
			topFrameSiteKey: record.topFrameSiteKey,
			hasCrossSiteAncestor: record.hasCrossSiteAncestor
		)
	}

	private static func passwordKey(_ key: BrowserPasswordKey) -> CredentialUndoRecord.Password {
		.init(signonRealm: key.signonRealm, username: key.username, dateCreated: key.dateCreated)
	}

	private static func cookieKey(_ key: BrowserCookieKey) -> CredentialUndoRecord.Cookie {
		.init(
			domain: key.domain,
			name: key.name,
			path: key.path,
			topFrameSiteKey: key.topFrameSiteKey,
			hasCrossSiteAncestor: key.hasCrossSiteAncestor,
			sourceScheme: key.sourceScheme,
			sourcePort: key.sourcePort
		)
	}

	private static func cookieKey(_ key: CredentialUndoRecord.Cookie) -> BrowserCookieKey {
		.init(
			domain: key.domain,
			name: key.name,
			path: key.path,
			topFrameSiteKey: key.topFrameSiteKey,
			hasCrossSiteAncestor: key.hasCrossSiteAncestor,
			sourceScheme: key.sourceScheme,
			sourcePort: key.sourcePort
		)
	}

	private static func failure(_ error: any Error) -> CredentialMigrationFailure {
		(error as? BrowserCredentialImportFailure) == .unavailable ? .writerUnavailable : .writeFailed
	}
}
