import ChromiumEngine
import Foundation

// `make password-smoke` phases for ABI46 credential migration (DEV-830). Throwaway
// data only, in fresh profiles of the disposable root: no real browser profile or
// Keychain item. Every password and cookie value carries the probe, so the runner's
// leak scan covers replies, logs and the profile on disk.
extension PasswordSmoke {
	internal func verifyCredentialImport(privateID: UUID) async throws {
		guard runtime.supportsCredentialImport else { throw Failure.unsupported }

		let profile = UUID()
		try await runtime.prepareProfile(profile)
		let passwordKeys = try await verifyImportedRecords(profile, privateID: privateID)
		let cookieKeys = try await verifyImportedCookies(profile, privateID: privateID)
		try await verifyImportUndo(profile, passwords: passwordKeys, cookies: cookieKeys.imported, kept: cookieKeys.kept)
	}

	// MARK: - Passwords

	/// Two new rows go in; a pair already saved keeps its password; a non-http(s)
	/// row and one whose realm isn't its URL's are skipped. Returns the keys the
	/// second import added.
	private func verifyImportedRecords(
		_ profile: UUID,
		privateID: UUID
	) async throws -> [ChromiumPasswordKey] {
		let existing = try await importRecords(profile, [
			.init(url: "https://kept.arx.test/login", signonRealm: "https://kept.arx.test/", username: "kept", password: "\(probe)kept"),
		])
		guard existing.imported.count == 1, existing.conflicts == 0, existing.skipped == 0
		else { throw Failure.unexpected("first import \(existing)") }

		let second = try await importRecords(profile, [
			.init(url: "https://one.arx.test/login", signonRealm: "https://one.arx.test/", username: "one", password: "\(probe)one"),
			.init(url: "https://two.arx.test:8443/", signonRealm: "https://two.arx.test:8443/", username: "", password: "\(probe)two"),
			.init(url: "https://kept.arx.test/login", signonRealm: "https://kept.arx.test/", username: "kept", password: "\(probe)changed"),
			.init(url: "ftp://files.arx.test/", signonRealm: "ftp://files.arx.test/", username: "ftp", password: "\(probe)ftp"),
			.init(url: "https://three.arx.test/", signonRealm: "https://other.arx.test/", username: "three", password: "\(probe)three"),
		])
		guard
			Set(second.imported.map(\.signonRealm)) == ["https://one.arx.test/", "https://two.arx.test:8443/"],
			second.unconfirmed.isEmpty,
			second.conflicts == 1,
			second.skipped == 2,
			second.imported.allSatisfy({ !$0.dateCreated.isEmpty })
		else { throw Failure.unexpected("second import \(second)") }

		let sites = try await settingsList(profile).passwords.map(\.site).sorted()
		guard sites == ["kept.arx.test", "one.arx.test", "two.arx.test"]
		else { throw Failure.unexpected("imported list \(sites)") }

		try await expectImportFailure(.unavailable, "private records") {
			_ = try await self.runtime.importPasswordRecords(profile: privateID, records: [
				.init(url: "https://private.arx.test/", signonRealm: "https://private.arx.test/", username: "p", password: "\(self.probe)private"),
			])
		}
		diagnostic("ARX_PASSWORD_SMOKE_IMPORT_RECORDS")
		return second.imported
	}

	// MARK: - Cookies

	/// A domain cookie, a `__Host-` cookie bound to scheme and port, a
	/// partitioned cookie and an old cookie renewed since are set (check finds
	/// the renewed one, so it wasn't capped to expired); a cookie the profile already has is kept, an
	/// expired one is rejected, and an unpartitioned sibling of the partitioned
	/// cookie is neither replaced nor mistaken for it.
	private func verifyImportedCookies(
		_ profile: UUID,
		privateID: UUID
	) async throws -> (imported: [ChromiumCookieKey], kept: [ChromiumCookieKey]) {
		let host = "cookies.arx.test"
		let first = try await importCookies(profile, [
			cookie(host, "keep", value: "\(probe)keep"),
			cookie(host, "part", value: "\(probe)sibling", secure: true, sourceScheme: 2, sourcePort: 443),
		])
		guard first.accepted.count == 2, first.existing.isEmpty, first.rejected.isEmpty
		else { throw Failure.unexpected("first cookies \(first)") }

		let second = try await importCookies(profile, [
			cookie(".arx.test", "domain", value: "\(probe)domain"),
			cookie(host, "__Host-id", value: "\(probe)host", secure: true, sourceScheme: 2, sourcePort: 443),
			cookie(
				host,
				"part",
				value: "\(probe)partitioned",
				secure: true,
				sameSite: 0,
				sourceScheme: 2,
				sourcePort: 443,
				// FromStorage takes the canonical schemeful site (registrable domain):
				// "https://top.arx.test" would canonicalize to arx.test and be rejected.
				topFrameSiteKey: "https://top.test",
				hasCrossSiteAncestor: true
			),
			cookie(host, "keep", value: "\(probe)changed"),
			// Created 500 days ago and renewed since: still valid for 30 days, which
			// the old creation time alone would cap to already expired.
			cookie(
				host,
				"renewed",
				value: "\(probe)renewed",
				created: Date(timeIntervalSinceNow: -500 * 86_400),
				expires: Date(timeIntervalSinceNow: 30 * 86_400)
			),
			cookie(host, "expired", value: "\(probe)expired", expires: Date(timeIntervalSinceNow: -3600)),
		])
		guard
			Set(second.accepted.map(\.name)) == ["domain", "__Host-id", "part", "renewed"],
			second.existing.map(\.name) == ["keep"],
			second.rejected.map(\.name) == ["expired"],
			second.accepted.first(where: { $0.name == "part" })?.topFrameSiteKey == "https://top.test",
			second.unconfirmed.isEmpty,
			second.accepted.first(where: { $0.name == "__Host-id" })?.sourcePort == 443
		else { throw Failure.unexpected("second cookies \(second)") }

		let never: ChromiumCookieKey = .init(
			domain: host,
			name: "never",
			path: "/",
			topFrameSiteKey: "",
			hasCrossSiteAncestor: false,
			sourceScheme: 1,
			sourcePort: 80
		)
		let present = try await checkCookies(profile, second.accepted + first.accepted + [never])
		guard present == Set(second.accepted + first.accepted)
		else { throw Failure.unexpected("check \(present)") }

		try await expectImportFailure(.unavailable, "private cookies") {
			_ = try await self.runtime.importCookies(profile: privateID, cookies: [
				self.cookie(host, "private", value: "\(self.probe)private"),
			])
		}
		diagnostic("ARX_PASSWORD_SMOKE_IMPORT_COOKIES")
		return (second.accepted, first.accepted)
	}

	// MARK: - Undo

	/// Undo removes exactly the second batch: the passwords and cookies saved
	/// before it, including the unpartitioned sibling, stay.
	private func verifyImportUndo(
		_ profile: UUID,
		passwords: [ChromiumPasswordKey],
		cookies: [ChromiumCookieKey],
		kept: [ChromiumCookieKey]
	) async throws {
		let removed = try await importCall("undo") {
			try await self.runtime.undoCredentialImport(profile: profile, passwords: passwords, cookies: cookies)
		}
		guard removed == passwords.count + cookies.count
		else { throw Failure.unexpected("undo removed \(removed)") }

		// Store removals settle asynchronously; the list catches up within seconds.
		var sites: [String] = []
		for _ in 0..<50 {
			sites = try await settingsList(profile).passwords.map(\.site)
			if sites == ["kept.arx.test"] { break }
			try await Task.sleep(for: .milliseconds(100))
		}
		guard sites == ["kept.arx.test"] else { throw Failure.unexpected("undo list \(sites)") }

		let present = try await checkCookies(profile, cookies + kept)
		guard present == Set(kept) else { throw Failure.unexpected("undo check \(present)") }

		// A second undo of the same batch finds nothing left to remove.
		let again = try await importCall("undo again") {
			try await self.runtime.undoCredentialImport(profile: profile, passwords: passwords, cookies: cookies)
		}
		guard again == 0 else { throw Failure.unexpected("undo again \(again)") }
		diagnostic("ARX_PASSWORD_SMOKE_IMPORT_UNDO")
	}

	// MARK: - Helpers

	private func cookie(
		_ domain: String,
		_ name: String,
		value: String,
		secure: Bool = false,
		sameSite: Int32 = 1,
		sourceScheme: Int32 = 1,
		sourcePort: Int32 = 80,
		topFrameSiteKey: String = "",
		hasCrossSiteAncestor: Bool = false,
		created: Date = Date(timeIntervalSinceNow: -7200),
		expires: Date = Date(timeIntervalSinceNow: 86_400)
	) -> ChromiumImportedCookie {
		let now = Date()
		return .init(
			domain: domain,
			name: name,
			value: value,
			path: "/",
			topFrameSiteKey: topFrameSiteKey,
			creationUTC: Self.chromiumTime(created),
			expiresUTC: Self.chromiumTime(expires),
			lastAccessUTC: Self.chromiumTime(now.addingTimeInterval(-60)),
			isSecure: secure,
			isHTTPOnly: true,
			hasCrossSiteAncestor: hasCrossSiteAncestor,
			sameSite: sameSite,
			priority: 1,
			sourceScheme: sourceScheme,
			sourcePort: sourcePort
		)
	}

	private static func chromiumTime(_ date: Date) -> Int64 {
		Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
	}

	private func importRecords(
		_ profile: UUID,
		_ records: [ChromiumImportedPassword]
	) async throws -> ChromiumPasswordRecordImport {
		try await importCall("records") {
			try await self.runtime.importPasswordRecords(profile: profile, records: records)
		}
	}

	private func importCookies(
		_ profile: UUID,
		_ cookies: [ChromiumImportedCookie]
	) async throws -> ChromiumCookieImport {
		try await importCall("cookies") {
			try await self.runtime.importCookies(profile: profile, cookies: cookies)
		}
	}

	private func checkCookies(
		_ profile: UUID,
		_ keys: [ChromiumCookieKey]
	) async throws -> Set<ChromiumCookieKey> {
		try await importCall("check") {
			try await self.runtime.checkCookies(profile: profile, keys: keys)
		}
	}

	/// Prints the reply or failure, which carry keys and counts only.
	private func importCall<Value>(
		_ kind: String,
		_ body: () async throws -> Value
	) async throws -> Value {
		do {
			let value = try await body()
			reply("credential import \(kind)", "\(value)")
			return value
		} catch {
			reply("credential import \(kind)", "\(error)")
			throw error
		}
	}

	private func expectImportFailure(
		_ expected: ChromiumCredentialImportFailure,
		_ label: String,
		_ body: () async throws -> Void
	) async throws {
		do {
			try await body()
		} catch let failure as ChromiumCredentialImportFailure {
			reply("credential import \(label)", "\(failure)")
			guard failure == expected else { throw Failure.unexpected("\(label) \(failure)") }
			return
		}
		throw Failure.unexpected("\(label) succeeded")
	}
}

private func diagnostic(_ message: String) {
	FileHandle.standardError.write(Data("\(message)\n".utf8))
}
